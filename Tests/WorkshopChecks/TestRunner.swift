import Foundation

// A tiny dependency-free harness so checks also run with Command Line Tools (no XCTest/Xcode required).
private var failures = 0
private struct CheckFailure: Error {}
func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    failures += 1
    print("FAIL \(file):\(line): \(message)")
}
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckFailure() }
    return value
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                   _ message: String = "Values must match", file: StaticString = #filePath, line: UInt = #line) {
    do { if try a() != b() { XCTFail(message, file: file, line: line) } }
    catch { XCTFail("\(error)", file: file, line: line) }
}
func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                      file: StaticString = #filePath, line: UInt = #line) {
    do { if try a() == b() { XCTFail("Values must differ", file: file, line: line) } }
    catch { XCTFail("\(error)", file: file, line: line) }
}
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a > b { XCTFail("\(a) > \(b)", file: file, line: line) }
}
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a <= b { XCTFail("\(a) <= \(b)", file: file, line: line) }
}
func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !expression() { XCTFail("Expected true", file: file, line: line) } }
    catch { XCTFail("\(error)", file: file, line: line) }
}
func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() { XCTFail("Expected false", file: file, line: line) } }
    catch { XCTFail("\(error)", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath,
                            line: UInt = #line, _ handler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); XCTFail("Expected an error", file: file, line: line) }
    catch { handler(error) }
}

@main struct TestRunner {
    static func main() {
        let checks: [(String, (SplitEngineTests) throws -> Void)] = [
            ("Image export, replacement, rotation, and edited-document splitting", { _ in try runSelfTests() }),
            ("Exact size, order, pixel fidelity, unchanged source", { try $0.testActualSizesPageOrderImageFidelityAndOriginalUnchanged() }),
            ("Small document and collision-safe export", { try $0.testOnePartWhenBelowLimitAndRepeatDoesNotOverwrite() }),
            ("Exact byte boundary", { try $0.testExactByteBoundary() }),
            ("Oversized page rolls back previous output", { try $0.testOversizedSinglePageAndLateFailureLeaveNoPartialOutput() }),
            ("Cancellation removes partial files", { try $0.testCancellationRemovesAlreadyWrittenParts() }),
            ("Invalid document and limit", { try $0.testInvalidFileAndInvalidLimits() }),
            ("Password unlock and readable export", { try $0.testEncryptedPDFNeedsCorrectPasswordAndExportsReadableCopy() }),
            ("Page range input validation and input order", { try $0.testPageRangeInputAndFileOrder() }),
            ("Page ranges preserve edited pages and file order", { try $0.testPageRangesPreserveEditedPagesAndSelectedFileOrder() }),
            ("Every page exports as a separate PDF", { try $0.testEveryPageHasItsOwnPDF() }),
            ("Invalid page plans and cancellation remove output", { try $0.testInvalidPagePlansAndCancellationLeaveNoOutput() }),
            ("Page range split unlocks password-protected files", { try $0.testPageRangeSplitUsesPassword() })
        ]
        for (name, check) in checks {
            let before = failures
            let suite = SplitEngineTests()
            do {
                try suite.setUpWithError()
                defer { try? suite.tearDownWithError() }
                try check(suite)
            } catch { XCTFail("\(name): \(error)") }
            print("\(failures == before ? "PASS" : "FAIL") \(name)")
        }
        print("\(checks.count) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
