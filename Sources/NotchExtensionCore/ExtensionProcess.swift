import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// JSON-lines developer-process runner. This is NOT an OS sandbox.
/// Executables run with the host user's privileges; enable only explicitly trusted local fixtures.
public final class ExtensionProcess: @unchecked Sendable {
    public let executableURL: URL
    private let operationLock = NSLock()
    private let stateLock = NSLock()
    private var stopped = false
    private var retiring: Process?
    private var child: Process?
    private var input: Pipe?
    private var output: Pipe?

    public init(executableURL: URL) { self.executableURL = executableURL }
    deinit { stop(immediate: true) }

    public func requestHello(timeout: TimeInterval = 3) async throws -> HelloResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try self.requestHelloSynchronously(timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func requestHelloSynchronously(timeout: TimeInterval = 3) throws -> HelloResponse {
        operationLock.lock(); defer { operationLock.unlock() }
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw ExtensionError.protocolFailure("Timeout must be in (0, 60]") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            let handles = try startIfNeeded()
            let request = HelloRequest()
            var encoded = try JSONEncoder().encode(request); encoded.append(0x0a)
            try writeRequest(encoded, to: handles.0, deadline: deadline)
            var line = Data()
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw ExtensionError.deadlineExceeded }
                var descriptor = pollfd(fd: handles.1.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, 100)))
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw ExtensionError.protocolFailure("Pipe polling failed")
                }
                if ready == 0 { continue }
                guard descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else { throw ExtensionError.protocolFailure("Pipe closed") }
                guard let byte = try handles.1.read(upToCount: 1), !byte.isEmpty else { throw ExtensionError.protocolFailure("Unexpected EOF") }
                if byte.first == 0x0a { break }
                line.append(byte)
                guard line.count <= 65_536 else { throw ExtensionError.protocolFailure("Response exceeds 64 KiB") }
            }
            let response = try JSONDecoder().decode(HelloResponse.self, from: line)
            guard response.type == "hello", response.protocolVersion == 1, response.requestID == request.requestID,
                  response.progress.isFinite, (0...1).contains(response.progress) else {
                throw ExtensionError.protocolFailure("Response type, version, request ID, or progress is invalid")
            }
            return response
        } catch { stop(); throw error }
    }
    private func writeRequest(_ data: Data, to handle: FileHandle, deadline: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ExtensionError.deadlineExceeded }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, 100)))
            if ready < 0 {
                if errno == EINTR { continue }
                throw ExtensionError.protocolFailure("Input pipe polling failed")
            }
            if ready == 0 { continue }
            guard descriptor.revents & Int16(POLLNVAL | POLLERR | POLLHUP) == 0 else {
                throw ExtensionError.protocolFailure("Input pipe closed")
            }
            let count: Int = data.withUnsafeBytes { buffer in
                #if canImport(Darwin)
                return Darwin.write(handle.fileDescriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                #else
                return Glibc.write(handle.fileDescriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                #endif
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw ExtensionError.protocolFailure("Input pipe write failed")
            }
            offset += count
        }
    }
    private func startIfNeeded() throws -> (FileHandle, FileHandle) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !stopped else { throw ExtensionError.protocolFailure("Process owner was stopped; create a new owner to launch") }
        if let child = child, child.isRunning, let input = input, let output = output {
            return (input.fileHandleForWriting, output.fileHandleForReading)
        }
        let process = Process(); let stdin = Pipe(); let stdout = Pipe()
        #if canImport(Darwin)
        // A fixture that exits before reading must not deliver SIGPIPE to the host.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw ExtensionError.protocolFailure("Could not protect the input pipe")
        }
        #endif
        let flags = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_GETFL)
        guard flags != -1, fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw ExtensionError.protocolFailure("Could not make input writes deadline-bounded")
        }
        process.executableURL = executableURL
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        child = process; input = stdin; output = stdout
        return (stdin.fileHandleForWriting, stdout.fileHandleForReading)
    }
    /// Bounded shutdown; ignored SIGTERM escalates to SIGKILL. Does not claim descendant sandboxing.
    public func stop(immediate: Bool = false) {
        stateLock.lock()
        stopped = true
        let process = child ?? retiring; child = nil; retiring = process
        input = nil
        output = nil
        stateLock.unlock()
        if let process = process, process.isRunning {
            if immediate { _ = kill(process.processIdentifier, SIGKILL); return }
            process.terminate()
            // Never spin/sleep on the caller (which may be the App main actor).
            // Retain this exact Process until escalation; do not target a name or stale PID.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
        // An in-flight request retains its handles. Let ARC close them after its read
        // finishes, avoiding descriptor reuse while another thread is polling.
    }
    public var hasLiveProcess: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return child?.isRunning == true || retiring?.isRunning == true
    }
    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return child?.isRunning ?? false
    }
}
