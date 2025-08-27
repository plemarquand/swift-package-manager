//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import CoreCommands
import Foundation
import PackageModel
import SPMBuildCore
import TSCUtility
import Workspace

#if canImport(WinSDK)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Bionic)
import Bionic
#endif

import struct TSCBasic.FileSystemError
import class Basics.AsyncProcess
import var TSCBasic.stderrStream
import var TSCBasic.stdoutStream
import func TSCBasic.withTemporaryFile
import func TSCBasic.exec

/// Represents the state of LLDB debugging sessions for breakpoint persistence.
struct DebugSessionState {
    let libraries: [TestingLibrary]
    let activeLibrary: TestingLibrary

    /// Whether this session should create the Python script for breakpoint persistence
    var shouldPersistBreakpoints: Bool {
        isMultiSession && isFirst
    }

    /// Whether this session should load existing breakpoints
    var shouldLoadBreakpoints: Bool {
        isMultiSession && isLast
    }

    /// Whether this is part of a multi-session sequence
    var isMultiSession: Bool {
        libraries.count > 1
    }

    /// Whether this is the first session in any sequence
    var isFirst: Bool {
        activeLibrary == libraries.first
    }

    /// Whether this is the last session in any sequence
    var isLast: Bool {
        activeLibrary == libraries.last
    }
}

/// Internal helper functionality for the SwiftTestTool command and for the
/// plugin support.
///
/// Note: In the long term this should be factored into a reusable module that
/// can run and report results on tests from both CLI and libSwiftPM API.
enum TestingSupport {
    /// Locates XCTestHelper tool inside the libexec directory and bin directory.
    /// Note: It is a fatalError if we are not able to locate the tool.
    ///
    /// - Returns: Path to XCTestHelper tool.
    static func xctestHelperPath(swiftCommandState: SwiftCommandState) throws -> AbsolutePath {
        var triedPaths = [AbsolutePath]()

        func findXCTestHelper(swiftBuildPath: AbsolutePath) -> AbsolutePath? {
            // XCTestHelper tool is installed in libexec.
            let maybePath = swiftBuildPath.parentDirectory.parentDirectory.appending(
                components: "libexec", "swift", "pm", "swiftpm-xctest-helper"
            )
            if swiftCommandState.fileSystem.isFile(maybePath) {
                return maybePath
            } else {
                triedPaths.append(maybePath)
                return nil
            }
        }

        if let firstCLIArgument = CommandLine.arguments.first {
            let runningSwiftBuildPath = try AbsolutePath(validating: firstCLIArgument, relativeTo: swiftCommandState.originalWorkingDirectory)
            if let xctestHelperPath = findXCTestHelper(swiftBuildPath: runningSwiftBuildPath) {
                return xctestHelperPath
            }
        }

        // This will be true during swiftpm development or when using swift.org toolchains.
        let xcodePath = try AsyncProcess.checkNonZeroExit(args: "/usr/bin/xcode-select", "--print-path").spm_chomp()
        let installedSwiftBuildPath = try AsyncProcess.checkNonZeroExit(
            args: "/usr/bin/xcrun", "--find", "swift-build",
            environment: ["DEVELOPER_DIR": xcodePath]
        ).spm_chomp()
        if let xctestHelperPath = findXCTestHelper(swiftBuildPath: try AbsolutePath(validating: installedSwiftBuildPath)) {
            return xctestHelperPath
        }

        throw InternalError("XCTestHelper binary not found, tried \(triedPaths.map { $0.pathString }.joined(separator: ", "))")
    }

    static func getTestSuites(
        in testProducts: [BuiltTestProduct],
        swiftCommandState: SwiftCommandState,
        enableCodeCoverage: Bool,
        shouldSkipBuilding: Bool,
        experimentalTestOutput: Bool,
        sanitizers: [Sanitizer]
    ) throws -> [AbsolutePath: [TestSuite]] {
        let testSuitesByProduct = try testProducts
            .map {(
                $0.bundlePath,
                try Self.getTestSuites(
                    fromTestAt: $0.bundlePath,
                    swiftCommandState: swiftCommandState,
                    enableCodeCoverage: enableCodeCoverage,
                    shouldSkipBuilding: shouldSkipBuilding,
                    experimentalTestOutput: experimentalTestOutput,
                    sanitizers: sanitizers
                )
            )}
        return try Dictionary(throwingUniqueKeysWithValues: testSuitesByProduct)
    }

    /// Runs the corresponding tool to get tests JSON and create TestSuite array.
    /// On macOS, we use the swiftpm-xctest-helper tool bundled with swiftpm.
    /// On Linux, XCTest can dump the json using `--dump-tests-json` mode.
    ///
    /// - Parameters:
    ///     - path: Path to the XCTest bundle(macOS) or executable(Linux).
    ///
    /// - Throws: TestError, SystemError, TSCUtility.Error
    ///
    /// - Returns: Array of TestSuite
    static func getTestSuites(
        fromTestAt path: AbsolutePath,
        swiftCommandState: SwiftCommandState,
        enableCodeCoverage: Bool,
        shouldSkipBuilding: Bool,
        experimentalTestOutput: Bool,
        sanitizers: [Sanitizer]
    ) throws -> [TestSuite] {
        // Run the correct tool.
        var args = [String]()
        #if os(macOS)
        let data: String = try withTemporaryFile { tempFile in
            args = [try Self.xctestHelperPath(swiftCommandState: swiftCommandState).pathString, path.pathString, tempFile.path.pathString]
            let env = try Self.constructTestEnvironment(
                toolchain: try swiftCommandState.getTargetToolchain(),
                destinationBuildParameters: swiftCommandState.buildParametersForTest(
                    enableCodeCoverage: enableCodeCoverage,
                    shouldSkipBuilding: shouldSkipBuilding,
                    experimentalTestOutput: experimentalTestOutput
                ).productsBuildParameters,
                sanitizers: sanitizers,
                library: .xctest
            )
            try Self.runProcessWithExistenceCheck(
                path: path,
                fileSystem: swiftCommandState.fileSystem,
                args: args,
                env: env
            )

            // Read the temporary file's content.
            return try swiftCommandState.fileSystem.readFileContents(AbsolutePath(tempFile.path))
        }
        #else
        let env = try Self.constructTestEnvironment(
            toolchain: try swiftCommandState.getTargetToolchain(),
            destinationBuildParameters: swiftCommandState.buildParametersForTest(
                enableCodeCoverage: enableCodeCoverage,
                shouldSkipBuilding: shouldSkipBuilding
            ).productsBuildParameters,
            sanitizers: sanitizers,
            library: .xctest
        )
        args = [path.description, "--dump-tests-json"]
        let data = try Self.runProcessWithExistenceCheck(
            path: path,
            fileSystem: swiftCommandState.fileSystem,
            args: args,
            env: env
        )
        #endif
        // Parse json and return TestSuites.
        return try TestSuite.parse(jsonString: data, context: args.joined(separator: " "))
    }

    /// Run a process and throw a more specific error if the file doesn't exist.
    @discardableResult
    private static func runProcessWithExistenceCheck(
        path: AbsolutePath,
        fileSystem: FileSystem,
        args: [String],
        env: Environment
    ) throws -> String {
        do {
            return try AsyncProcess.checkNonZeroExit(arguments: args, environment: env)
        } catch {
            // If the file doesn't exist, throw a more specific error.
            if !fileSystem.exists(path) {
                throw FileSystemError(.noEntry, path)
            }
            throw error
        }
    }

    /// Creates the environment needed to test related tools.
    static func constructTestEnvironment(
        toolchain: UserToolchain,
        destinationBuildParameters buildParameters: BuildParameters,
        sanitizers: [Sanitizer],
        library: TestingLibrary
    ) throws -> Environment {
        var env = Environment.current

        // If the standard output or error stream is NOT a TTY, set the NO_COLOR
        // environment variable. This environment variable is a de facto
        // standard used to inform downstream processes not to add ANSI escape
        // codes to their output. SEE: https://www.no-color.org
        if !stdoutStream.isTTY || !stderrStream.isTTY {
            env["NO_COLOR"] = "1"
        }

        // Add the code coverage related variables.
        if buildParameters.testingParameters.enableCodeCoverage {
            // Defines the path at which the profraw files will be written on test execution.
            //
            // `%Nm` will create a pool of N profraw files and append the data from each execution
            // in one of the files. The runtime takes care of selecting a raw profile from the pool,
            // locking it, and updating it before the program exits. If N is not specified, it is
            // inferred to be 1.
            //
            // This is fine for parallel execution within a process, but for parallel tests, SwiftPM
            // repeatedly invokes the test binary with the testcase name as the filter and the
            // locking cannot be enforced by the runtime across the process boundaries.
            //
            // It's also possible that tests themselves will fork (e.g. for exit tests provided by
            // Swift Testing), which will inherit the environment of the parent process, and so
            // write to the same file, leading to profile data corruption.
            //
            // For these reasons, we unilaterally also add a %p, which will cause uniquely named
            // files per process.
            //
            // These are all merged using `llvm-profdata merge` once the outer test command has
            // completed.
            let codecovProfile = buildParameters.buildPath.appending(components: "codecov", "\(library)%m.%p.profraw")
            env["LLVM_PROFILE_FILE"] = codecovProfile.pathString
        }
        #if !os(macOS)
        #if os(Windows)
        if let xctestLocation = toolchain.xctestPath {
            env.prependPath(key: .path, value: xctestLocation.pathString)
        }
        if let swiftTestingLocation = toolchain.swiftTestingPath {
            env.prependPath(key: .path, value: swiftTestingLocation.pathString)
        }
        #endif
        return env
        #else
        // Add path to swift-testing override if there is one
        if let swiftTestingPath = toolchain.swiftTestingPath {
            if swiftTestingPath.extension == "framework" {
                env.appendPath(key: "DYLD_FRAMEWORK_PATH", value: swiftTestingPath.pathString)
            } else {
                env.appendPath(key: "DYLD_LIBRARY_PATH", value: swiftTestingPath.pathString)
            }
        }

        // Add the sdk platform path if we have it.
        // Since XCTestHelper targets macOS, we need the macOS platform paths here.
        if let sdkPlatformPaths = try? SwiftSDK.sdkPlatformPaths(for: .macOS) {
            // appending since we prefer the user setting (if set) to the one we inject
            for frameworkPath in sdkPlatformPaths.frameworks {
                env.appendPath(key: "DYLD_FRAMEWORK_PATH", value: frameworkPath.pathString)
            }
            for libraryPath in sdkPlatformPaths.libraries {
                env.appendPath(key: "DYLD_LIBRARY_PATH", value: libraryPath.pathString)
            }
        }

        // We aren't using XCTest's harness logic to run Swift Testing tests.
        if library == .xctest {
            env["SWIFT_TESTING_ENABLED"] = "0"
        }

        // Fast path when no sanitizers are enabled.
        if sanitizers.isEmpty {
            return env
        }

        // Get the runtime libraries.
        var runtimes = try sanitizers.map({ sanitizer in
            return try toolchain.runtimeLibrary(for: sanitizer).pathString
        })

        // Append any existing value to the front.
        if let existingValue = env["DYLD_INSERT_LIBRARIES"], !existingValue.isEmpty {
            runtimes.insert(existingValue, at: 0)
        }

        env["DYLD_INSERT_LIBRARIES"] = runtimes.joined(separator: ":")
        return env
        #endif
    }
}

/// A class to run tests under LLDB debugger.
final class DebugTestRunner {
    private let bundlePath: AbsolutePath
    private let additionalArguments: [String]
    private let library: TestingLibrary
    private let buildParameters: BuildParameters
    private let toolchain: UserToolchain
    private let testEnv: Environment
    private let cancellator: Cancellator
    private let fileSystem: FileSystem
    private let observabilityScope: ObservabilityScope
    private let sessionState: DebugSessionState

    /// Creates an instance of debug test runner.
    init(
        bundlePath: AbsolutePath,
        additionalArguments: [String] = [],
        library: TestingLibrary,
        buildParameters: BuildParameters,
        toolchain: UserToolchain,
        testEnv: Environment,
        cancellator: Cancellator,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        sessionState: DebugSessionState
    ) {
        self.bundlePath = bundlePath
        self.additionalArguments = additionalArguments
        self.library = library
        self.buildParameters = buildParameters
        self.toolchain = toolchain
        self.testEnv = testEnv
        self.cancellator = cancellator
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope
        self.sessionState = sessionState
    }

    /// Launches the test binary under LLDB for interactive debugging.
    ///
    /// This method:
    /// 1. Discovers LLDB using the toolchain
    /// 2. Configures the environment for debugging
    /// 3. Launches LLDB with the proper test runner as target
    /// 4. Provides interactive debugging experience through appropriate process management
    ///
    /// **Implementation approach varies by testing library:**
    /// - **XCTest**: Uses PTY (pseudo-terminal) via `runInPty()` to support LLDB's full-screen
    ///   terminal features while maintaining parent process control for sequential execution
    /// - **Swift Testing**: Uses `exec()` to replace the current process (works because Swift Testing
    ///   is always the last library in the sequence, avoiding the need for sequential execution)
    ///
    /// The PTY approach is necessary for XCTest because LLDB requires advanced terminal features
    /// (ANSI escape sequences, raw input mode, terminal sizing) that simple stdin/stdout redirection
    /// cannot provide, while still allowing the parent process to show completion messages and
    /// run multiple testing libraries sequentially.
    ///
    /// - Throws: Various errors if LLDB cannot be found or launched
    func run() throws {
        let lldbPath: AbsolutePath
        do {
            lldbPath = try toolchain.getLLDB()
        } catch {
            observabilityScope.emit(error: "LLDB not found in toolchain: \(error)")
            throw error
        }

        // Validate that the test binary exists
        guard fileSystem.exists(bundlePath) else {
            observabilityScope.emit(error: "Test binary not found at: \(bundlePath)")
            throw FileSystemError(.noEntry, bundlePath)
        }

        let lldbArgs = try prepareLLDBArguments(for: library)

        observabilityScope.emit(info: "LLDB will run: \(lldbPath.pathString) \(lldbArgs.joined(separator: " "))")

        if !additionalArguments.isEmpty {
            observabilityScope.emit(info: "Additional test arguments: \(additionalArguments.joined(separator: " "))")
        }

        let result = try runInPty(executable: lldbPath.pathString, args: lldbArgs, environment: testEnv)
        if result != 0 {
            observabilityScope.emit(info: "LLDB debugging session exited with code \(result)")
        }

        // Clean up breakpoints file if this is the last session or a single session
        if sessionState.isLast && sessionState.isMultiSession {
            let breakpointFile = try breakpointFilePath()
            try? fileSystem.removeFileTree(breakpointFile)
        }
    }

    /// Returns the path to the breakpoint persistence file.
    private func breakpointFilePath() throws -> AbsolutePath {
        let tempDir = try fileSystem.tempDirectory
        return tempDir.appending("lldb_breakpoints.txt")
    }

    /// Returns the path to the Python script file for quit/exit override.
    private func pythonScriptFilePath() throws -> AbsolutePath {
        let tempDir = try fileSystem.tempDirectory
        return tempDir.appending("save_breakpoints.py")
    }

    /// Creates the Python script that overrides quit and exit commands to save breakpoints.
    private func createPythonScript() throws -> AbsolutePath {
        let scriptPath = try pythonScriptFilePath()
        let breakpointFile = try breakpointFilePath()

        let pythonScript = """
# autosave_bps.py
import lldb
import threading
import os

OUT_PATH = "\(breakpointFile.pathString)"

def breakpoint_event_loop(listener, debugger):
    \"\"\"Background thread that listens for breakpoint events.\"\"\"
    event = lldb.SBEvent()

    while True:
        if listener.WaitForEvent(5, event):  # timeout prevents blocking forever
            if lldb.SBBreakpoint.EventIsBreakpointEvent(event):
                ev_type = lldb.SBBreakpoint.GetBreakpointEventTypeFromEvent(event)

                if ev_type == lldb.eBreakpointEventTypeAdded:
                    debugger.HandleCommand(f'breakpoint write -f "{OUT_PATH}"')

                elif ev_type == lldb.eBreakpointEventTypeRemoved:
                    target = debugger.GetSelectedTarget()
                    if target and target.GetNumBreakpoints() > 0:
                        debugger.HandleCommand(f'breakpoint write "{OUT_PATH}"')
                    else:
                        try:
                            os.remove(OUT_PATH)
                        except FileNotFoundError:
                            pass

def __lldb_init_module(debugger, internal_dict):
    target = debugger.GetSelectedTarget()
    if not target:
        return

    listener = lldb.SBListener("breakpoint_listener")
    target.GetBroadcaster().AddListener(listener, lldb.SBTarget.eBroadcastBitBreakpointChanged)

    t = threading.Thread(target=breakpoint_event_loop, args=(listener, debugger), daemon=True)
    t.start()
"""

        try fileSystem.writeFileContents(scriptPath, string: pythonScript)
        return scriptPath
    }

    /// Prepares LLDB arguments for debugging based on the testing library.
    ///
    /// This method creates a temporary LLDB command file with the necessary setup commands
    /// for debugging tests, including target creation, argument configuration, and symbol loading.
    ///
    /// - Parameter library: The testing library being used (XCTest or Swift Testing)
    /// - Returns: Array of LLDB command line arguments
    /// - Throws: Various errors if required tools are not found or file operations fail
    private func prepareLLDBArguments(for library: TestingLibrary) throws -> [String] {
        // Determine the target executable and initial program arguments
        let targetExecutable: AbsolutePath
        var programArgs: [String] = []

        // switch library {
        // case .xctest:
        //     // For XCTest, we need to launch xctest with the bundle as an argument
        //     guard let xctestPath = toolchain.xctestPath else {
        //         throw StringError("XCTest not found in toolchain")
        //     }
        //     targetExecutable = xctestPath
        //     programArgs = [bundlePath.pathString]

        // case .swiftTesting:
        //     // For Swift Testing, use swiftpm-testing-helper with --test-bundle-path
        //     #if os(macOS)
        //     targetExecutable = try toolchain.getSwiftTestingHelper()
        //     programArgs = ["--test-bundle-path", bundlePath.pathString]
        //     #else
        //     targetExecutable = bundlePath
        //     #endif
        // }
        // Implementation taken from SwiftTestCommand.swift -> TestRunner.args(forTestAt:), should be refactored
        #if os(macOS)
            switch library {
            case .xctest:
                guard let xctestPath = self.toolchain.xctestPath else {
                    throw TestError.xcodeNotInstalled
                }
                targetExecutable = xctestPath
            case .swiftTesting:
                targetExecutable = try self.toolchain.getSwiftTestingHelper()
                programArgs += ["--test-bundle-path", bundlePath.pathString]
            }
            programArgs += self.additionalArguments
        #else
            targetExecutable = bundlePath
            programArgs += self.additionalArguments
        #endif

        // Add any additional arguments
        // programArgs.append(contentsOf: additionalArguments)

        // Create a temporary LLDB command file for batch execution
        let tempDir = try fileSystem.tempDirectory
        let lldbCommandFile = tempDir.appending("lldb-commands.txt")

        // Build LLDB commands
        var lldbCommands = [
            "target create \(targetExecutable.pathString)",
            "settings clear target.run-args"
        ]

        // Add each argument individually using settings append to avoid -- parsing issues
        for arg in programArgs {
            lldbCommands.append("settings append target.run-args \"\(arg)\"")
        }

        // Determine the module path for symbol loading
        var modulePath = bundlePath
        if library == .xctest && buildParameters.triple.isDarwin() {
            guard let name = bundlePath.components.last?.replacing(".xctest", with: "") else {
                throw InternalError("Invalid bundle path: \(bundlePath)")
            }
            modulePath = bundlePath.appending(try RelativePath(validating: "Contents/MacOS/\(name)"))
        }

        // Pre-load the test bundle symbols so breakpoints on test functions work
        lldbCommands.append("target modules add \"\(modulePath.pathString)\"")

        // Add breakpoint persistence support
        if sessionState.shouldPersistBreakpoints {
            // Ensure there is no leftover breakpoints file from a previous run
            let breakpointFile = try breakpointFilePath()
            try? fileSystem.removeFileTree(breakpointFile)

            let scriptPath = try createPythonScript()
            lldbCommands.append("command script import \"\(scriptPath.pathString)\"")
        }

        // Load breakpoints from previous session
        if sessionState.shouldLoadBreakpoints {
            let breakpointFile = try breakpointFilePath()
            if fileSystem.exists(breakpointFile) {
                lldbCommands.append("breakpoint read -f \"\(breakpointFile.pathString)\"")
            }
        }

        // Clear the screen of the commands we've already run, and if we're running multiple
        // sessions print what testing library we're using to help orient the user.
        if sessionState.isMultiSession {
            let libraryNames = sessionState.libraries.map { $0 == .xctest ? "XCTest" : "Swift Testing" }
            let libraryName = library == .xctest ? "XCTest" : "Swift Testing"
            let activeLibraries = sessionState.isLast ? "" : "Multiple testing libraries are enabled: \(libraryNames.joined(separator: " and "))\\n"
            let startingSession = "Starting LLDB debugging session for \(libraryName) tests..."
            let exitMessage = sessionState.isLast ? "" : "\\nUse \\`quit\\` or \\`exit\\` to terminate the LLDB session and begin debugging \(libraryNames.last!)"
            let message = "\\n\\n\(activeLibraries)\(startingSession)\(exitMessage)\\n\\n"
            lldbCommands.append("script print(\"\\033[H\\033[J\(message)\", end=\"\")")
        } else {
            lldbCommands.append("script print(\"\\033[H\\033[J\", end=\"\")")
        }

        // Write commands to file
        let commandScript = lldbCommands.joined(separator: "\n")
        try fileSystem.writeFileContents(lldbCommandFile, string: commandScript)

        // Return script file arguments without batch mode to allow interactive debugging
        return ["-s", lldbCommandFile.pathString]
    }

    /// Runs an executable in a pseudo-terminal (PTY) with proper terminal interaction support.
    ///
    /// This function is necessary for running interactive terminal applications like LLDB that require
    /// full terminal control features. We cannot use simpler approaches because:
    ///
    /// 1. **execv() limitation**: execv() would replace the current swift-package-manager process entirely,
    ///    preventing us from running multiple testing libraries sequentially or showing completion messages.
    ///
    /// 2. **Simple stdin/stdout/stderr redirection limitation**: LLDB is a full-screen terminal application
    ///    that uses advanced terminal features including:
    ///    - ANSI escape sequences for cursor positioning and screen control
    ///    - Raw terminal mode for immediate character input (no line buffering)
    ///    - Terminal size detection and dynamic resizing
    ///    - Color output and text formatting
    ///    - Interactive command line editing with history
    ///
    /// 3. **PTY solution**: A pseudo-terminal provides a complete terminal emulation layer that:
    ///    - Presents as a real terminal to the child process (LLDB)
    ///    - Handles all terminal control sequences properly
    ///    - Supports raw mode input for immediate character processing
    ///    - Maintains proper terminal state and signal handling
    ///    - Allows the parent process to remain in control while providing full terminal functionality
    ///
    /// The implementation uses posix_spawn with file descriptor redirection to connect the child process
    /// to the PTY slave, while the parent process relays data between the user's terminal and the PTY master.
    ///
    /// - Parameters:
    ///   - executable: Path to the executable to run
    ///   - args: Command line arguments to pass to the executable
    ///   - environment: Environment variables to set for the child process
    /// - Returns: Exit status of the child process
    /// - Throws: System errors related to PTY creation or process spawning
    func runInPty(executable: String, args: [String], environment: Environment) throws -> Int32 {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var winSize = winsize()
        if ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &winSize) == -1 {
            // fallback if not a tty
            winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }

        if openpty(&masterFD, &slaveFD, nil, nil, &winSize) == -1 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        // Prepare argv for posix_spawn
        let cargs = [executable] + args
        var argv: [UnsafeMutablePointer<CChar>?] = cargs.map { strdup($0) }
        argv.append(nil)

        // Prepare environment variables for posix_spawn
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { key, value in
            return strdup("\(key)=\(value)")
        }
        envp.append(nil)

        #if os(macOS)
        // On macOS, posix_spawn uses optional types
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, STDERR_FILENO)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        #else
        // On Linux, posix_spawn uses non-optional types
        var fileActions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, STDERR_FILENO)

        var attr = posix_spawnattr_t()
        posix_spawnattr_init(&attr)
        // On Linux, POSIX_SPAWN_SETSID might not be available, use 0 for now
        posix_spawnattr_setflags(&attr, 0)
        #endif

        // Clear the screen
        print("\u{1B}[2J\u{1B}[H", terminator: "")

        var pid: pid_t = 0
        #if os(macOS)
        let spawnResult = posix_spawn(&pid, executable, &fileActions, &attr, &argv, &envp)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
        #else
        let spawnResult = posix_spawn(&pid, executable, &fileActions, &attr, &argv, &envp)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
        #endif
        argv.forEach { free($0) }
        envp.forEach { free($0) }

        if spawnResult != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(spawnResult))
        }

        close(slaveFD)

        // Put stdin in raw mode
        var origTerm = termios()
        tcgetattr(STDIN_FILENO, &origTerm)
        var raw = origTerm
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)

        // Relay loop using poll()
        var fds: [pollfd] = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
        ]

        var buf = [UInt8](repeating: 0, count: 1024)
        relay: while true {
            let ready = poll(&fds, nfds_t(fds.count), -1)
            if ready > 0 {
                // Input from user → child
                if (fds[0].revents & Int16(POLLIN)) != 0 {
                    let n = read(STDIN_FILENO, &buf, buf.count)
                    if n > 0 {
                        write(masterFD, buf, n)
                    }
                }
                // Output from child → user
                if (fds[1].revents & Int16(POLLIN)) != 0 {
                    let n = read(masterFD, &buf, buf.count)
                    if n > 0 {
                        write(STDOUT_FILENO, buf, n)
                    } else {
                        break relay // child closed
                    }
                }
            } else {
                break relay
            }
        }

        // Restore terminal
        tcsetattr(STDIN_FILENO, TCSANOW, &origTerm)

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return status
    }
}

extension SwiftCommandState {
    func buildParametersForTest(
        enableCodeCoverage: Bool,
        enableTestability: Bool? = nil,
        shouldSkipBuilding: Bool = false,
        experimentalTestOutput: Bool = false
    ) throws -> (productsBuildParameters: BuildParameters, toolsBuildParameters: BuildParameters) {
        let productsBuildParameters = buildParametersForTest(
            modifying: try productsBuildParameters,
            enableCodeCoverage: enableCodeCoverage,
            enableTestability: enableTestability,
            shouldSkipBuilding: shouldSkipBuilding,
            experimentalTestOutput: experimentalTestOutput
        )
        let toolsBuildParameters = buildParametersForTest(
            modifying: try toolsBuildParameters,
            enableCodeCoverage: enableCodeCoverage,
            enableTestability: enableTestability,
            shouldSkipBuilding: shouldSkipBuilding,
            experimentalTestOutput: experimentalTestOutput
        )
        return (productsBuildParameters, toolsBuildParameters)
    }

    private func buildParametersForTest(
        modifying parameters: BuildParameters,
        enableCodeCoverage: Bool,
        enableTestability: Bool?,
        shouldSkipBuilding: Bool,
        experimentalTestOutput: Bool
    ) -> BuildParameters {
        var parameters = parameters
        parameters.testingParameters.enableCodeCoverage = enableCodeCoverage
        // for test commands, we normally enable building with testability
        // but we let users override this with a flag
        parameters.testingParameters.explicitlyEnabledTestability = enableTestability ?? true
        parameters.shouldSkipBuilding = shouldSkipBuilding
        parameters.testingParameters.experimentalTestOutput = experimentalTestOutput
        return parameters
    }
}
