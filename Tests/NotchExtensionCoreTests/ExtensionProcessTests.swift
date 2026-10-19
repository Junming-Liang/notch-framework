import Foundation
import XCTest
@testable import NotchExtensionCore

final class ExtensionProcessTests: XCTestCase {
    private func withScript(_ script: String, test: (ExtensionProcess) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture.sh")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let process = ExtensionProcess(executableURL: executable)
        defer { process.stop() }
        try test(process)
    }
    func testStoppedOwnerNeverLaunches() throws {
        let process = ExtensionProcess(executableURL:URL(fileURLWithPath:"/bin/cat"))
        process.stop()
        XCTAssertThrowsError(try process.requestHelloSynchronously(timeout:1))
        XCTAssertFalse(process.isRunning)
    }
    func testStoppedOwnerRejectsAsyncQueuedRequest() async throws {
        let process = ExtensionProcess(executableURL:URL(fileURLWithPath:"/bin/cat"))
        process.stop()
        do { _ = try await process.requestHello(timeout:1); XCTFail("Stopped owner launched") } catch {}
        XCTAssertFalse(process.isRunning)
    }
    func testHelloRoundTripAndExplicitStop() throws {
        try withScript(#"""
        while IFS= read -r request; do
          id=$(printf '%s' "$request" | /usr/bin/sed -n 's/.*"requestID":"\([^"]*\)".*/\1/p')
          printf '{"type":"hello","protocolVersion":1,"requestID":"%s","message":"ok","title":"Hello","subtitle":"fixture","progress":0.5}\n' "$id"
        done
        """#) { process in
            let response = try process.requestHelloSynchronously(timeout: 2)
            XCTAssertEqual(response.title, "Hello")
            XCTAssertEqual(response.progress, 0.5)
            XCTAssertTrue(process.isRunning)
            process.stop()
            XCTAssertFalse(process.isRunning)
        }
    }
    func testMismatchedRequestIDRejected() throws {
        try withScript(#"""
        IFS= read -r request
        printf '{"type":"hello","protocolVersion":1,"requestID":"wrong","message":"ok","title":"Hello","subtitle":"fixture","progress":0.5}\n'
        """#) { process in
            XCTAssertThrowsError(try process.requestHelloSynchronously(timeout: 1))
            XCTAssertFalse(process.isRunning)
        }
    }
    func testTimeoutTerminatesProcess() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("hang.sh")
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let process = ExtensionProcess(executableURL: executable)
        let start = Date()
        XCTAssertThrowsError(try process.requestHelloSynchronously(timeout: 0.1)) { error in
            XCTAssertEqual(error as? ExtensionError, .deadlineExceeded)
        }
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testMalformedResponseStopsProcess() throws {
        let process = ExtensionProcess(executableURL: URL(fileURLWithPath: "/bin/cat"))
        // cat echoes a request, which lacks required response fields.
        XCTAssertThrowsError(try process.requestHelloSynchronously(timeout: 1))
        XCTAssertFalse(process.isRunning)
    }
    #if canImport(Darwin)
    func testImmediateExitDoesNotSignalHost() throws {
        try withScript("exit 0\n") { process in
            XCTAssertThrowsError(try process.requestHelloSynchronously(timeout: 1))
            XCTAssertFalse(process.isRunning)
        }
    }
    #endif
    func testInvalidDeadlineRejected() throws {
        let process = ExtensionProcess(executableURL: URL(fileURLWithPath: "/bin/cat"))
        XCTAssertThrowsError(try process.requestHelloSynchronously(timeout: 0))
        XCTAssertThrowsError(try process.requestHelloSynchronously(timeout: .infinity))
        XCTAssertFalse(process.isRunning)
    }
}
