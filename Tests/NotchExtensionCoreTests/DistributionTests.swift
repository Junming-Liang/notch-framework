import XCTest
import CryptoKit
@testable import NotchExtensionCore

final class DistributionTests: XCTestCase {
    private func config(_ key: Curve25519.Signing.PrivateKey, test: Bool = true) -> DistributionConfiguration {
        DistributionConfiguration(trustedKeys: ["test-key": key.publicKey.rawRepresentation], githubOwner: "test-owner", githubRepository: "test-registry", allowLoopbackHTTPForTests: test)
    }
    private func envelope(_ payload: SignedCatalogPayload, key: Curve25519.Signing.PrivateKey, keyID: String = "test-key") throws -> Data {
        let bytes = try JSONEncoder().encode(payload)
        return try JSONEncoder().encode(SignedCatalogEnvelope(keyID: keyID, payload: bytes.base64EncodedString(), signature: key.signature(for: bytes).base64EncodedString()))
    }
    private func payload(expires: Double = Date().timeIntervalSince1970 + 3600, version: Int = 1) -> SignedCatalogPayload {
        SignedCatalogPayload(catalogVersion: version, expiresAt: expires, entries: [])
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCanonicalCacheAcceptsRealParentAndRejectsSymlinkParent() throws {
        let root = try temporaryDirectory()
        let canonical = root.appendingPathComponent("canonical-cache")
        let key = Curve25519.Signing.PrivateKey()
        _ = try SignedPackageTransport(configuration: config(key), cacheDirectory: canonical)
        let alias = root.appendingPathComponent("cache-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: canonical)
        XCTAssertThrowsError(try SignedPackageTransport(configuration: config(key), cacheDirectory: alias.appendingPathComponent("child")))
    }

    func testPythonSignedRFC8032FixtureVerifiesInCryptoKit() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "python-signed-catalog", withExtension: "json", subdirectory: "Fixtures"))
        let hex = Array("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        let publicKey = Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0...($0 + 1)]), radix: 16)! })
        let configuration = DistributionConfiguration(trustedKeys: ["RFC8032-TEST-ONLY": publicKey], githubOwner: "test-owner", githubRepository: "test-registry", allowLoopbackHTTPForTests: true)
        let verified = try SignedPackageTransport.verify(Data(contentsOf: fixture), configuration: configuration)
        XCTAssertEqual(verified.envelope.keyID, "RFC8032-TEST-ONLY")
        XCTAssertEqual(verified.payload.catalogVersion, 1)
        XCTAssertTrue(verified.payload.entries.isEmpty)
    }

    func testValidSignatureAndTamper() throws {
        // Ephemeral test key, never saved or accepted as production trust.
        let key = Curve25519.Signing.PrivateKey()
        let encoded = try envelope(payload(), key: key)
        let verified = try SignedPackageTransport.verify(encoded, configuration: config(key))
        XCTAssertEqual(verified.payload.catalogVersion, 1)
        var bad = try JSONDecoder().decode(SignedCatalogEnvelope.self, from: encoded)
        bad.payload = try JSONEncoder().encode(payload(version: 2)).base64EncodedString()
        XCTAssertThrowsError(try SignedPackageTransport.verify(JSONEncoder().encode(bad), configuration: config(key)))
        bad = try JSONDecoder().decode(SignedCatalogEnvelope.self, from: encoded)
        bad.signature = Data(repeating: 0, count: 64).base64EncodedString()
        XCTAssertThrowsError(try SignedPackageTransport.verify(JSONEncoder().encode(bad), configuration: config(key)))
    }

    func testUnknownKeyExpiryAndInvalidVersion() throws {
        let key = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try SignedPackageTransport.verify(envelope(payload(), key: key, keyID: "unknown"), configuration: config(key)))
        XCTAssertThrowsError(try SignedPackageTransport.verify(envelope(payload(expires: 0), key: key), configuration: config(key)))
        XCTAssertThrowsError(try SignedPackageTransport.verify(envelope(payload(version: 0), key: key), configuration: config(key)))
        let other = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try SignedPackageTransport.verify(envelope(payload(), key: other), configuration: config(key)))
    }

    func testSignedMetadataURLAndSizeRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        var p = payload()
        var entry = CatalogEntry(id: "test.ext", name: "Test", version: "1.0.0", architecture: "universal", minHostVersion: "1.0.0", size: 42, sha256: String(repeating: "0", count: 64), downloadURL: URL(string: "https://example.com/evil.zip")!)
        p.entries = [entry]
        XCTAssertThrowsError(try SignedPackageTransport.verify(envelope(p, key: key), configuration: config(key)))
        entry.downloadURL = URL(string: "https://github.com/test-owner/test-registry/releases/download/v1.0.0/test.zip")!
        p.entries = [entry]
        XCTAssertNoThrow(try SignedPackageTransport.verify(envelope(p, key: key), configuration: config(key, test: false)))
        XCTAssertThrowsError(try SignedPackageTransport.verify(envelope(p, key: key), configuration: config(key)), "Public test mode must never authorize a GitHub package")
        entry.size = 33 * 1024 * 1024; p.entries = [entry]
        XCTAssertThrowsError(try SignedPackageTransport.verify(envelope(p, key: key), configuration: config(key)))
        entry.size = 42; entry.downloadURL = URL(string: "http://127.0.0.1:8888/package.zip")!; p.entries = [entry]
        XCTAssertThrowsError(try SignedPackageTransport.verify(envelope(p, key: key), configuration: config(key, test: false)))
        XCTAssertNoThrow(try SignedPackageTransport.verify(envelope(p, key: key), configuration: config(key)))
    }

    func testPersistentCacheVerifiesAndExpiredCacheCannotAuthorize() async throws {
        let key = Curve25519.Signing.PrivateKey(), root = try temporaryDirectory()
        let url = root.appendingPathComponent("signed-catalog.json")
        try envelope(payload(version: 7), key: key).write(to: url)
        let transport = try SignedPackageTransport(configuration: config(key), cacheDirectory: root)
        let cached = try await transport.cachedCatalog()
        XCTAssertEqual(cached.catalogVersion, 7)
        try envelope(payload(expires: 0, version: 7), key: key).write(to: url)
        let expired = try SignedPackageTransport(configuration: config(key), cacheDirectory: root)
        do { _ = try await expired.cachedCatalog(); XCTFail("Expired cache authorized use") } catch {}
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try SignedPackageTransport(configuration: config(key), cacheDirectory: root))
    }

    func testReplayFloorAndSameVersionEquivocationSurviveRestart() async throws {
        let key = Curve25519.Signing.PrivateKey(), root = try temporaryDirectory()
        let transport = try SignedPackageTransport(configuration: config(key), cacheDirectory: root)
        let original = try envelope(payload(version: 5), key: key)
        _ = try await transport.acceptCatalog(original)
        _ = try await transport.acceptCatalog(original)
        do {
            _ = try await transport.acceptCatalog(envelope(payload(version: 4), key: key))
            XCTFail("Catalog rollback was accepted")
        } catch {}
        let restarted = try SignedPackageTransport(configuration: config(key), cacheDirectory: root)
        do {
            _ = try await restarted.acceptCatalog(envelope(payload(expires: Date().timeIntervalSince1970 + 7200, version: 5), key: key))
            XCTFail("Same-version equivocation was accepted")
        } catch {}
        do {
            _ = try await restarted.acceptCatalog(envelope(payload(version: 4), key: key))
            XCTFail("Persisted replay floor lost")
        } catch {}
        _ = try await restarted.acceptCatalog(envelope(payload(version: 6), key: key))
        let current = try await restarted.cachedCatalog()
        XCTAssertEqual(current.catalogVersion, 6)
    }

    func testTestModeRejectsRemoteCatalogBeforeNetwork() async throws {
        let key = Curve25519.Signing.PrivateKey(), root = try temporaryDirectory()
        let transport = try SignedPackageTransport(configuration:config(key),cacheDirectory:root)
        for url in ["https://test-owner.github.io/test-registry/catalog.json", "https://raw.githubusercontent.com/test-owner/test-registry/main/catalog.json"] {
            do { _ = try await transport.fetchCatalog(from:URL(string:url)!); XCTFail("Test mode reached a remote catalog") } catch {}
        }
    }
    func testMissingTrustAndForbiddenURLFailClosed() async throws {
        let root = try temporaryDirectory()
        XCTAssertThrowsError(try SignedPackageTransport(configuration: DistributionConfiguration(trustedKeys: [:], githubOwner: "test-owner", githubRepository: "test-registry"), cacheDirectory: root))
        let key = Curve25519.Signing.PrivateKey()
        let transport = try SignedPackageTransport(configuration: config(key, test: false), cacheDirectory: root)
        do { _ = try await transport.fetchCatalog(from: URL(string: "http://127.0.0.1:1/catalog.json")!); XCTFail("Production accepted HTTP") } catch {}
    }

    func testStoredZIPRoundTripAndCRC() throws {
        let zip = archive([("manifest.json", Data("{}".utf8)), ("bin/hello", Data("hello".utf8))])
        let files = try StoredZIP.read(zip, maximumBytes: 4096)
        XCTAssertEqual(files["bin/hello"], Data("hello".utf8))
        XCTAssertEqual(StoredZIP.crc32(Data("123456789".utf8)), 0xcbf43926)
        var bad = zip; bad[30 + "manifest.json".utf8.count] ^= 1
        XCTAssertThrowsError(try StoredZIP.read(bad, maximumBytes: 4096))
    }

    func testStoredZIPRejectsTraversalDuplicatesLinksAndCompression() throws {
        for path in ["../escape", "/absolute", "a/../b", "a\\b", "C:evil", "a//b", "a/", "a\u{0000}b"] {
            XCTAssertThrowsError(try StoredZIP.read(archive([(path, Data())]), maximumBytes: 4096), path)
        }
        for names in [["A", "a"], ["é", "e\u{301}"], ["a", "a/b"], ["a/b", "a"]] {
            XCTAssertThrowsError(try StoredZIP.read(archive(names.map { ($0, Data()) }), maximumBytes: 4096))
        }
        var symlink = archive([("link", Data("target".utf8))])
        let central = 30 + "link".utf8.count + "target".utf8.count
        put32(&symlink, central + 38, 0xa1ff0000)
        XCTAssertThrowsError(try StoredZIP.read(symlink, maximumBytes: 4096))
        var deflate = archive([("file", Data())]); deflate[8] = 8; deflate[34 + 10] = 8
        XCTAssertThrowsError(try StoredZIP.read(deflate, maximumBytes: 4096))
    }

    func testStoredZIPRejectsLocalMismatchTrailingBytesAndOversize() throws {
        let good = archive([("file", Data("hello".utf8))])
        var bad = good; bad[30] = 120
        XCTAssertThrowsError(try StoredZIP.read(bad, maximumBytes: 4096))
        bad = good; bad.append(0)
        XCTAssertThrowsError(try StoredZIP.read(bad, maximumBytes: 4096))
        bad = good; put32(&bad, 39 + 24, 0xffffffff)
        XCTAssertThrowsError(try StoredZIP.read(bad, maximumBytes: 4096))
        XCTAssertThrowsError(try StoredZIP.read(good, maximumBytes: 10))
        for length in 0..<good.count {
            XCTAssertThrowsError(try StoredZIP.read(Data(good.prefix(length)), maximumBytes: 4096))
        }
    }

    /// Minimal independent ZIP_STORED writer, regular files only.
    private func archive(_ files: [(String, Data)]) -> Data {
        var local = Data(), central = Data()
        func u16(_ value: Int) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
        func u32(_ value: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        for (name, bytes) in files {
            let encoded = Data(name.utf8), offset = local.count, crc = Int(StoredZIP.crc32(bytes))
            local += u32(0x04034b50) + u16(20) + u16(0x800) + u16(0) + u16(0) + u16(0)
            local += u32(crc) + u32(bytes.count) + u32(bytes.count) + u16(encoded.count) + u16(0) + encoded + bytes
            central += u32(0x02014b50) + u16(0x314) + u16(20) + u16(0x800) + u16(0) + u16(0) + u16(0)
            central += u32(crc) + u32(bytes.count) + u32(bytes.count) + u16(encoded.count) + u16(0) + u16(0)
            central += u16(0) + u16(0) + u32(0x81a40000) + u32(offset) + encoded
        }
        return local + central + u32(0x06054b50) + u16(0) + u16(0) + u16(files.count) + u16(files.count) + u32(central.count) + u32(local.count) + u16(0)
    }
    private func put32(_ bytes: inout Data, _ offset: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
}
