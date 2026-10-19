import Foundation
import NotchExtensionCore

/// Native end-to-end check for an explicitly supplied locally built Hello fixture.
/// Not invoked on downloaded packages or untrusted registry entries.
@main
struct Smoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "NotchSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: NotchSmoke <trusted locally built Hello fixture directory>"])
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("notch-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ExtensionStore(rootURL: root.appendingPathComponent("store"))
        let first = try store.installDeveloperFixture(from: fixture)
        guard !first.enabled else { throw failure("install must default disabled") }
        try store.setEnabled(id: first.manifest.id, enabled: true)
        let process = try store.makeProcess(id: first.manifest.id)
        defer { process.stop() }
        let response = try await process.requestHello()
        guard response.title == "Hello Notch", response.progress == 0.65 else { throw failure("unexpected Hello response") }
        process.stop(); try store.setEnabled(id: first.manifest.id, enabled: false)
        let next = root.appendingPathComponent("next")
        try FileManager.default.copyItem(at: fixture, to: next)
        var manifest = first.manifest; manifest.version = "0.2.0"
        try JSONEncoder().encode(manifest).write(to: next.appendingPathComponent("manifest.json"), options: .atomic)
        let updated = try store.installDeveloperFixture(from: next)
        guard !updated.enabled, updated.previousVersion == first.manifest.version else { throw failure("upgrade state") }
        let rolled = try store.rollback(id: first.manifest.id)
        guard rolled.manifest.version == first.manifest.version, !rolled.enabled else { throw failure("rollback state") }
        let trash = try store.uninstall(id: first.manifest.id)
        guard try store.list().isEmpty, FileManager.default.fileExists(atPath: trash.appendingPathComponent("installation.json").path) else { throw failure("recoverable uninstall") }
        print("PASS: real Hello IPC, install, enable, disable, upgrade, rollback, recoverable uninstall")
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "NotchSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
}
