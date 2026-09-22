#if !canImport(XCTest)
import Foundation

open class XCTestCase {
    public init() {}
    open func setUp() async throws {}
    open func tearDown() async throws {}
}

func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        if try !expression() { fail("XCTAssertTrue failed \(message())", file: file, line: line) }
    } catch {
        fail("XCTAssertTrue threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        if try expression() { fail("XCTAssertFalse failed \(message())", file: file, line: line) }
    } catch {
        fail("XCTAssertFalse threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        let left = try a()
        let right = try b()
        if left != right { fail("XCTAssertEqual failed: \(left) != \(right) \(message())", file: file, line: line) }
    } catch {
        fail("XCTAssertEqual threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        let left = try a()
        let right = try b()
        if left == right { fail("XCTAssertNotEqual failed: \(left) == \(right) \(message())", file: file, line: line) }
    } catch {
        fail("XCTAssertNotEqual threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertNil(_ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        if try expression() != nil { fail("XCTAssertNil failed \(message())", file: file, line: line) }
    } catch {
        fail("XCTAssertNil threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertNotNil(_ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        if try expression() == nil { fail("XCTAssertNotNil failed \(message())", file: file, line: line) }
    } catch {
        fail("XCTAssertNotNil threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        let left = try a()
        let right = try b()
        if !(left > right) { fail("XCTAssertGreaterThan failed: \(left) !> \(right) \(message())", file: file, line: line) }
    } catch {
        fail("XCTAssertGreaterThan threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line, _ errorHandler: (Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        fail("XCTAssertThrowsError failed \(message())", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

func XCTFail(_ message: String = "", file: StaticString = #file, line: UInt = #line) {
    fail("XCTFail \(message)", file: file, line: line)
}

private func fail(_ message: String, file: StaticString, line: UInt) {
    TestRuntime.recordFailure("\(file):\(line): \(message)")
}

enum TestRuntime {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var currentTest = ""

    static func recordFailure(_ message: String) {
        failures.append("[\(currentTest)] \(message)")
        print("FAIL: [\(currentTest)] \(message)")
    }
}
#endif
