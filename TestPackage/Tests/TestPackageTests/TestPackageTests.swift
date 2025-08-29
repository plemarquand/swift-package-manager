import Testing
@testable import TestPackage

@Test func testAddition() async throws {
    let result = addNumbers(2, 3)
    #expect(result == 5)
}

@Test func testMultiplication() async throws {
    let result = multiplyNumbers(4, 5)
    #expect(result == 20)
}
