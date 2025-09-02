import XCTest
@testable import TestPackage

final class TestPackageXCTests: XCTestCase {
    func testAddition() {
        let result = addNumbers(3, 4)
        XCTAssertEqual(result, 7)
    }

    func testMultiplication() {
        let result = multiplyNumbers(6, 7)
        XCTAssertEqual(result, 42)
    }
}