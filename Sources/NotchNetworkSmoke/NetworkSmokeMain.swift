import Foundation
import CryptoKit
import NotchExtensionCore

/// Known public RFC 8032 test seed. NEVER use it as a production identity.
/// This executable uses loopback and temporary fixture files only.
@main
struct NetworkSmoke {
    static let testSeed = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
    static func main() async throws {
        guard (2...3).contains(CommandLine.arguments.count) else { throw failure("Usage: NotchNetworkSmoke <trusted locally built Hello fixture> [--serve]") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("notch-network-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tools")
        let archiveURL = root.appendingPathComponent("hello.zip")
        try runPython(tools.appendingPathComponent("build-stored-archive.py"), [fixture.path, archiveURL.path])
        let archive = try Data(contentsOf: archiveURL)
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: fixture.appendingPathComponent("manifest.json")))
        let server = Process(); let pipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-u", tools.appendingPathComponent("fixture-http.py").path, root.path]
        server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() } }
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte.first != 10 {
            line.append(byte); guard line.count < 12 else { throw failure("invalid fixture port") }
        }
        guard let text = String(data: line, encoding: .utf8), let port = Int(text), (1...65535).contains(port) else { throw failure("fixture server unavailable") }
        let base = "http://127.0.0.1:\(port)"
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(testSeed))
        let keyID = "RFC8032-TEST-ONLY"
        let digest = SHA256.hash(data: archive).map { String(format:"%02x",$0) }.joined()
        let entry: [String: Any] = ["id":manifest.id,"name":manifest.name,"version":manifest.version,"protocolVersion":1,"architecture":"universal","minHostVersion":"0.1.0","size":archive.count,"sha256":digest,"downloadURL":"\(base)/hello.zip","capabilities":[]]
        let payload = try JSONSerialization.data(withJSONObject: ["schemaVersion":1,"catalogVersion":Int(Date().timeIntervalSince1970),"expiresAt":Date().timeIntervalSince1970+3600,"entries":[entry]], options: [.sortedKeys])
        let signature = try key.signature(for: payload)
        let envelope = try JSONSerialization.data(withJSONObject: ["keyID":keyID,"payload":payload.base64EncodedString(),"signature":signature.base64EncodedString()], options: [.sortedKeys])
        let catalogURL = root.appendingPathComponent("catalog.json")
        try envelope.write(to: catalogURL)
        if CommandLine.arguments.last == "--serve" {
            let source = try JSONSerialization.data(withJSONObject:["catalogURL":"\(base)/catalog.json","keyID":keyID,"publicKey":key.publicKey.rawRepresentation.base64EncodedString()])
            let sourceURL = root.appendingPathComponent("test-source.json")
            try source.write(to:sourceURL)
            print("Import this temporary public test config in the App: \(sourceURL.path)")
            print("Only local HTTP; public RFC test key is NOT a production publisher identity. Press Return to stop.")
            _ = readLine()
            return
        }
        let config = DistributionConfiguration(trustedKeys: [keyID:key.publicKey.rawRepresentation], githubOwner:"test-owner", githubRepository:"test-registry", allowLoopbackHTTPForTests:true)
        let transport = try SignedPackageTransport(configuration:config, cacheDirectory:root.appendingPathComponent("cache"))
        let fetched = try await transport.fetchCatalog(from: URL(string:"\(base)/catalog.json")!)
        guard fetched.catalogVersion > 0 else { throw failure("catalog version") }
        let prepared = try await transport.preparePackage(id: manifest.id, stagingParent: root.appendingPathComponent("staging"))
        let store = try ExtensionStore(rootURL: root.appendingPathComponent("store"))
        let installed = try store.installVerifiedPackage(prepared)
        guard !installed.enabled else { throw failure("network install must default disabled") }
        try store.setEnabled(id:manifest.id, enabled:true)
        let child = try store.makeProcess(id:manifest.id); defer { child.stop() }
        let response = try await child.requestHello(); child.stop()
        guard response.progress == 0.65 else { throw failure("real IPC mismatch") }
        // Downloaded bytes changed after catalog signing: must not be extracted/installed.
        try Data("tampered".utf8).write(to:archiveURL)
        do {
            _ = try await transport.preparePackage(id:manifest.id, stagingParent:root.appendingPathComponent("tampered-stage"))
            throw failure("SECURITY: tampered archive accepted")
        } catch let error as NSError where error.domain == "NotchNetworkSmoke" { throw error }
        catch { print("PASS: tampered archive rejected") }
        var altered = signature; altered[altered.startIndex] ^= 1
        let badEnvelope = try JSONSerialization.data(withJSONObject:["keyID":keyID,"payload":payload.base64EncodedString(),"signature":altered.base64EncodedString()])
        try badEnvelope.write(to:catalogURL)
        do {
            _ = try await transport.fetchCatalog(from:URL(string:"\(base)/catalog.json")!)
            throw failure("SECURITY: invalid signature accepted")
        } catch let error as NSError where error.domain == "NotchNetworkSmoke" { throw error }
        catch { print("PASS: invalid catalog signature rejected") }
        _ = try store.uninstall(id:manifest.id)
        print("PASS: local HTTP catalog, Ed25519 signature, bounded package download, SHA-256, native ZIP, disabled installation, Hello IPC, uninstall")
    }
    static func hex(_ value: String) -> Data { Data(stride(from:0,to:value.count,by:2).map { offset in let start=value.index(value.startIndex,offsetBy:offset);return UInt8(value[start..<value.index(start,offsetBy:2)],radix:16)! }) }
    static func runPython(_ script:URL,_ arguments:[String]) throws {
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/env");p.arguments=["python3",script.path]+arguments
        try p.run();p.waitUntilExit();guard p.terminationStatus==0 else { throw failure("fixture archive builder failed") }
    }
    static func failure(_ message:String)->NSError { NSError(domain:"NotchNetworkSmoke",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
}
