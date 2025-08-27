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

struct DebuggableTestTarget {
    struct Pairing {
        let library: TestingLibrary
        let additionalArgs: [String]
        let bundlePath: AbsolutePath
    }

    let libraries: [Pairing]

    /// Whether this is part of a multi-session sequence
    var isMultiSession: Bool {
        libraries.count > 1
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
    private let target: DebuggableTestTarget
    private let buildParameters: BuildParameters
    private let toolchain: UserToolchain
    private let testEnv: Environment
    private let cancellator: Cancellator
    private let fileSystem: FileSystem
    private let observabilityScope: ObservabilityScope

    /// Creates an instance of debug test runner.
    init(
        target: DebuggableTestTarget,
        buildParameters: BuildParameters,
        toolchain: UserToolchain,
        testEnv: Environment,
        cancellator: Cancellator,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) {
        self.target = target
        self.buildParameters = buildParameters
        self.toolchain = toolchain
        self.testEnv = testEnv
        self.cancellator = cancellator
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope
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

        let lldbArgs = try prepareLLDBArguments(for: target)
        observabilityScope.emit(info: "LLDB will run: \(lldbPath.pathString) \(lldbArgs.joined(separator: " "))")

        let result = try runInPty(executable: lldbPath.pathString, args: lldbArgs, environment: testEnv)
        if result != 0 {
            observabilityScope.emit(info: "LLDB debugging session exited with code \(result)")
        }
    }

    /// Returns the path to the Python script file.
    private func pythonScriptFilePath() throws -> AbsolutePath {
        let tempDir = try fileSystem.tempDirectory
        return tempDir.appending("target_switcher.py")
    }

    /// Prepares LLDB arguments for debugging based on the testing library.
    ///
    /// This method creates a temporary LLDB command file with the necessary setup commands
    /// for debugging tests, including target creation, argument configuration, and symbol loading.
    ///
    /// - Parameter library: The testing library being used (XCTest or Swift Testing)
    /// - Returns: Array of LLDB command line arguments
    /// - Throws: Various errors if required tools are not found or file operations fail
    private func prepareLLDBArguments(for target: DebuggableTestTarget) throws -> [String] {
        // Create a temporary LLDB command file for batch execution
        let tempDir = try fileSystem.tempDirectory
        let lldbCommandFile = tempDir.appending("lldb-commands.txt")

        // Build LLDB commands for multi-target setup
        var lldbCommands: [String] = []

        // If we have multiple libraries, set up both targets
        if target.isMultiSession {
            try setupMultipleTargets(&lldbCommands)
        } else {
            try setupSingleTarget(&lldbCommands, for: target.libraries.first!)
        }

        // Write commands to file
        let commandScript = lldbCommands.joined(separator: "\n")
        try fileSystem.writeFileContents(lldbCommandFile, string: commandScript)

        // Return script file arguments without batch mode to allow interactive debugging
        return ["-s", lldbCommandFile.pathString]
    }

    /// Sets up multiple targets when both XCTest and Swift Testing are available
    private func setupMultipleTargets(_ lldbCommands: inout [String]) throws {
        var targetIndex = 0

        // Create targets for each testing library
        for testingLibrary in target.libraries {
            let (executable, args) = try getExecutableAndArgs(for: testingLibrary)
            // Create target
            lldbCommands.append("target create \(executable.pathString)")
            lldbCommands.append("settings clear target.run-args")

            // Add arguments
            for arg in args {
                lldbCommands.append("settings append target.run-args \"\(arg)\"")
            }

            // Determine the module path for symbol loading
            let modulePath = getModulePath(for: testingLibrary)

            // Pre-load the test bundle symbols so breakpoints on test functions work
            lldbCommands.append("target modules add \"\(modulePath.pathString)\"")

            targetIndex += 1
        }

        // Create the target switching Python script
        let scriptPath = try createTargetSwitchingScript()
        lldbCommands.append("command script import \"\(scriptPath.pathString)\"")

        // Select the first target and launch with pause on main
        lldbCommands.append("target select 0")
        lldbCommands.append("script print(\"\\033[H\\033[J\", end=\"\")")
    }

    /// Sets up a single target when only one testing library is available
    private func setupSingleTarget(_ lldbCommands: inout [String], for target: DebuggableTestTarget.Pairing) throws {
        let (executable, args) = try getExecutableAndArgs(for: target)
        // Create target
        lldbCommands.append("target create \(executable.pathString)")
        lldbCommands.append("settings clear target.run-args")

        // Add arguments
        for arg in args {
            lldbCommands.append("settings append target.run-args \"\(arg)\"")
        }

        // Load symbols for the test bundle
        let modulePath = getModulePath(for: target)
        lldbCommands.append("target modules add \"\(modulePath.pathString)\"")

        // Clear screen and show ready message
        // lldbCommands.append("script print(\"\\033[H\\033[J\", end=\"\")")
        let libraryName = target.library == .xctest ? "XCTest" : "Swift Testing"
        let message = "\\n\\nStarting LLDB debugging session for \(libraryName) tests...\\n\\n"
        lldbCommands.append("script print(\"\(message)\", end=\"\")")
    }

    /// Gets the executable path and arguments for a given testing library
    private func getExecutableAndArgs(for target: DebuggableTestTarget.Pairing) throws -> (AbsolutePath, [String]) {
        switch target.library {
        case .xctest:
            guard let xctestPath = toolchain.xctestPath else {
                throw StringError("XCTest not found in toolchain")
            }
            return (xctestPath, [target.bundlePath.pathString] + target.additionalArgs)

        case .swiftTesting:
            #if os(macOS)
            let executable = try toolchain.getSwiftTestingHelper()
            let args = ["--test-bundle-path", target.bundlePath.pathString] + target.additionalArgs
            #else
            let executable = target.bundlePath
            let args = target.additionalArgs
            #endif
            return (executable, args)
        }
    }

    /// Gets the module path for symbol loading
    private func getModulePath(for target: DebuggableTestTarget.Pairing) -> AbsolutePath {
        var modulePath = target.bundlePath
        if target.library == .xctest && buildParameters.triple.isDarwin() {
            if let name = target.bundlePath.components.last?.replacing(".xctest", with: "") {
                if let relativePath = try? RelativePath(validating: "Contents/MacOS/\(name)") {
                    modulePath = target.bundlePath.appending(relativePath)
                }
            }
        }
        return modulePath
    }

    /// Creates a Python script that handles automatic target switching
    private func createTargetSwitchingScript() throws -> AbsolutePath {
        let scriptPath = try pythonScriptFilePath()

        let pythonScript = """
# target_switcher.py
import lldb
import threading
import time

current_target_index = 0
max_targets = 0
debugger_ref = None
known_breakpoints = set()

def sync_breakpoints_to_target(source_target, dest_target):
    \"\"\"Synchronize breakpoints from source target to destination target.\"\"\"
    if not source_target or not dest_target:
        return

    # Get all breakpoints from source target
    for i in range(source_target.GetNumBreakpoints()):
        bp = source_target.GetBreakpointAtIndex(i)
        if not bp.IsValid():
            continue

        # Check if this is a new breakpoint we haven't seen before
        bp_id = (bp.GetLocationAtIndex(0).GetAddress().GetFileAddress() if bp.GetNumLocations() > 0 else 0)

        # For each location in the breakpoint
        for j in range(bp.GetNumLocations()):
            location = bp.GetLocationAtIndex(j)
            if not location.IsValid():
                continue

            addr = location.GetAddress()
            line_entry = addr.GetLineEntry()

            if line_entry.IsValid():
                file_spec = line_entry.GetFileSpec()
                line_number = line_entry.GetLine()

                # Create the same breakpoint in the destination target
                new_bp = dest_target.BreakpointCreateByLocation(file_spec, line_number)
                if new_bp.IsValid():
                    # Copy breakpoint properties
                    new_bp.SetEnabled(bp.IsEnabled())
                    new_bp.SetCondition(bp.GetCondition())
                    new_bp.SetIgnoreCount(bp.GetIgnoreCount())

                    # Copy hit count if possible (read-only property, so we can't actually set it)
            else:
                # Handle function name breakpoints
                for k in range(bp.GetNumLocations()):
                    loc = bp.GetLocationAtIndex(k)
                    if loc.IsValid():
                        symbol = loc.GetAddress().GetSymbol()
                        if symbol.IsValid():
                            symbol_name = symbol.GetName()
                            if symbol_name:
                                new_bp = dest_target.BreakpointCreateByName(symbol_name)
                                if new_bp.IsValid():
                                    new_bp.SetEnabled(bp.IsEnabled())
                                    new_bp.SetCondition(bp.GetCondition())
                                    new_bp.SetIgnoreCount(bp.GetIgnoreCount())
                                break

def sync_breakpoints_to_all_targets():
    \"\"\"Synchronize breakpoints from current target to all other targets.\"\"\"
    global debugger_ref, max_targets

    if not debugger_ref or max_targets <= 1:
        return

    current_target = debugger_ref.GetSelectedTarget()
    if not current_target:
        return

    # Sync to all other targets
    for i in range(max_targets):
        target = debugger_ref.GetTargetAtIndex(i)
        if target and target != current_target:
            sync_breakpoints_to_target(current_target, target)

def monitor_breakpoints():
    \"\"\"Monitor breakpoint changes and sync them across targets.\"\"\"
    global debugger_ref, known_breakpoints, max_targets

    if max_targets <= 1:
        return

    last_breakpoint_count = 0

    while current_target_index < max_targets:
        if debugger_ref:
            current_target = debugger_ref.GetSelectedTarget()
            if current_target:
                current_bp_count = current_target.GetNumBreakpoints()

                # If breakpoint count changed, sync to all targets
                if current_bp_count != last_breakpoint_count:
                    time.sleep(0.1)  # Small delay to ensure breakpoint is fully created
                    sync_breakpoints_to_all_targets()
                    last_breakpoint_count = current_bp_count

        time.sleep(0.5)  # Check every 500ms

def check_process_status():
    \"\"\"Periodically check if the current process has exited.\"\"\"
    global current_target_index, max_targets, debugger_ref

    while current_target_index < max_targets:
        if debugger_ref:
            target = debugger_ref.GetSelectedTarget()
            if target:
                process = target.GetProcess()
                if process and process.GetState() == lldb.eStateExited:
                    # Process has exited, trigger switch
                    current_target_index += 1

                    if current_target_index < max_targets:
                        # Switch to next target and launch immediately
                        debugger_ref.HandleCommand(f'target select {current_target_index}')

                        # Get target name for user feedback
                        new_target = debugger_ref.GetSelectedTarget()
                        target_name = new_target.GetExecutable().GetFilename() if new_target else "Unknown"

                        print(f"\\n\\n=== Switching to next target: {target_name} ===")
                        print("Launching next testing framework automatically...")
                        print("All previously set breakpoints have been synchronized to this target.")

                        # Launch the next target immediately with pause on main
                        debugger_ref.HandleCommand('process launch') # -m to pause on main
                    else:
                        print("\\n\\nAll testing targets completed.")
                        return

        time.sleep(1)  # Check every second

def __lldb_init_module(debugger, internal_dict):
    global max_targets, debugger_ref

    debugger_ref = debugger

    # Count the number of targets
    max_targets = debugger.GetNumTargets()

    if max_targets > 1:
        print(f"\\n=== Multi-target debugging session initialized ===")
        print("Breakpoints set on any target will be automatically synchronized to all targets.")

        # Start the process status checker
        status_thread = threading.Thread(target=check_process_status, daemon=True)
        status_thread.start()

        # Start the breakpoint monitor
        bp_thread = threading.Thread(target=monitor_breakpoints, daemon=True)
        bp_thread.start()
"""

        try fileSystem.writeFileContents(scriptPath, string: pythonScript)
        return scriptPath
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
