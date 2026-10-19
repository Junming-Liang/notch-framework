import Darwin
import Foundation
import XCTest
@testable import NotchExtensionCore

final class ExtensionStoreTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        // macOS /tmp is itself a symlink. Resolve only the test fixture's trusted parent.
        temporary = (try physicalFixtureParent(FileManager.default.temporaryDirectory)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    private func fixture(version: String = "1.0.0", files: [String] = ["bin/hello"]) throws -> URL {
        let directory = temporary.appendingPathComponent("fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: directory.appendingPathComponent("bin/hello"))
        let manifest = ExtensionManifest(id: "dev.test.hello", name: "Hello", version: version, entrypoint: "bin/hello", files: files)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
    private func store() throws -> ExtensionStore { try ExtensionStore(rootURL: temporary.appendingPathComponent("store")) }
    func testTrustedTemporaryPathStagesDiagnostic() throws {
        let supplied = FileManager.default.temporaryDirectory
        let resolved = supplied.resolvingSymlinksInPath()
        let physical = try physicalFixtureParent(supplied)
        print("TEMP-PATH supplied=\(supplied.path) foundationResolved=\(resolved.path) posixRealpath=\(physical.path)")
        var ancestor = physical
        for stage in 0..<32 {
            print("TEMP-PATH stage=\(stage) URL-parent=\(ancestor.path)")
            if ancestor.path == "/" { break }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        // Verify the caller's physical path without permitting the /var alias.
        let directory = physical.appendingPathComponent("diagnostic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ExtensionStore(rootURL: directory)
        XCTAssertEqual(store.rootURL.path, directory.path)
    }
    func testCanonicalStoreRootIsPreservedAndAliasIsRejected() throws {
        let canonical = temporary.appendingPathComponent("canonical-store")
        let store = try ExtensionStore(rootURL: canonical)
        XCTAssertEqual(store.rootURL.path, canonical.path)
        let alias = temporary.appendingPathComponent("store-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: canonical)
        XCTAssertThrowsError(try ExtensionStore(rootURL: alias.appendingPathComponent("child")))
    }
    func testInstallDisabledEnablePersistsAndDisablePersists() throws {
        let store = try store()
        let item = try store.installDeveloperFixture(from: fixture())
        XCTAssertFalse(item.enabled)
        XCTAssertThrowsError(try store.makeProcess(id: item.manifest.id))
        try store.setEnabled(id: item.manifest.id, enabled: true)
        XCTAssertTrue(try self.store().list().first!.enabled)
        _ = try store.makeProcess(id: item.manifest.id)
        try store.setEnabled(id: item.manifest.id, enabled: false)
        XCTAssertFalse(try self.store().list().first!.enabled)
    }
    func testPersistedIntegrityRejectsChangedExecutableOnEnableAndLaunch() throws {
        let store = try store()
        let installed = try store.installDeveloperFixture(from:fixture())
        XCTAssertEqual(Set(installed.fileSHA256.keys), Set(["manifest.json", "bin/hello"]))
        try store.setEnabled(id:installed.manifest.id,enabled:true)
        let binary = store.rootURL.appendingPathComponent("versions/dev.test.hello/1.0.0/bin/hello")
        try Data("#!/bin/sh\nexit 7\n".utf8).write(to:binary)
        XCTAssertThrowsError(try store.makeProcess(id:installed.manifest.id))
        try store.setEnabled(id:installed.manifest.id,enabled:false)
        XCTAssertThrowsError(try self.store().setEnabled(id:installed.manifest.id,enabled:true))
        XCTAssertFalse(try self.store().list().first!.enabled)
        XCTAssertThrowsError(try self.store().makeProcess(id:installed.manifest.id))
    }
    func testRollbackRejectsTamperedPreviousVersion() throws {
        let store = try store()
        try store.installDeveloperFixture(from:fixture())
        try store.installDeveloperFixture(from:fixture(version:"2.0.0"))
        let previous = store.rootURL.appendingPathComponent("versions/dev.test.hello/1.0.0/bin/hello")
        try Data("changed".utf8).write(to:previous)
        XCTAssertThrowsError(try store.rollback(id:"dev.test.hello"))
        XCTAssertEqual(try store.list().first?.manifest.version,"2.0.0")
    }
    func testUpgradeRollbackAndRecoverableUninstall() throws {
        let store = try store()
        try store.installDeveloperFixture(from: fixture())
        try store.setEnabled(id: "dev.test.hello", enabled: true)
        let second = try store.installDeveloperFixture(from: fixture(version: "2.0.0"))
        XCTAssertFalse(second.enabled)
        XCTAssertEqual(second.previousVersion, "1.0.0")
        let rolled = try store.rollback(id: "dev.test.hello")
        XCTAssertEqual(rolled.manifest.version, "1.0.0")
        XCTAssertFalse(rolled.enabled)
        let trash = try store.uninstall(id: "dev.test.hello")
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("installation.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("versions/1.0.0/bin/hello").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("versions/2.0.0/bin/hello").path))
    }
    func testSameVersionCannotOverwriteAndFailedUpgradePreservesActivation() throws {
        let store = try store(); let first = try fixture()
        try store.installDeveloperFixture(from: first)
        XCTAssertThrowsError(try store.installDeveloperFixture(from: first))
        let invalid = try fixture(version: "2.0.0")
        try Data().write(to: invalid.appendingPathComponent("extra"))
        XCTAssertThrowsError(try store.installDeveloperFixture(from: invalid))
        XCTAssertEqual(try store.list().first?.manifest.version, "1.0.0")
    }
    func testTraversalAbsoluteDuplicateAndManifestFileRejected() throws {
        for path in ["../escape", "/etc/passwd", "bin/../hello", "bin//hello", "bin\\hello", "bin/./hello", "bin/", "C:hello"] {
            let manifest = ExtensionManifest(id: "dev.test", name: "Test", version: "1.0.0", entrypoint: path, files: [path])
            XCTAssertThrowsError(try manifest.validate(), path)
        }
        XCTAssertThrowsError(try ExtensionManifest(id: "../test", name: "Test", version: "1.0.0", entrypoint: "hello", files: ["hello"]).validate())
        XCTAssertThrowsError(try ExtensionManifest(id: "test", name: "Test", version: "..", entrypoint: "hello", files: ["hello"]).validate())
        XCTAssertThrowsError(try ExtensionManifest(id: "test", name: "Test", version: "1.0.0", entrypoint: "hello", files: ["hello", "hello"]).validate())
        XCTAssertThrowsError(try ExtensionManifest(id: "test", name: "Test", version: "1.0.0", entrypoint: "hello", files: ["hello", "manifest.json"]).validate())
    }
    func testCaseCollisionsAndInvalidSemverRejected() throws {
        let collision = ExtensionManifest(id: "dev.test", name: "Test", version: "1.0.0", entrypoint: "hello", files: ["hello", "HELLO"])
        XCTAssertThrowsError(try collision.validate())
        for version in ["1", "01.0.0", "1.2.3-01", "1.2.3/4"] {
            XCTAssertFalse(ExtensionManifest.isVersion(version))
        }
        XCTAssertTrue(ExtensionManifest.isVersion("1.2.3-beta.1+build.4"))
    }
    func testMissingExtraFilesAndEmptyDirectoriesRejected() throws {
        let store = try store()
        let missing = try fixture(); try FileManager.default.removeItem(at: missing.appendingPathComponent("bin/hello"))
        XCTAssertThrowsError(try store.installDeveloperFixture(from: missing))
        let extra = try fixture(); try Data().write(to: extra.appendingPathComponent("hidden"))
        XCTAssertThrowsError(try store.installDeveloperFixture(from: extra))
        let empty = try fixture(); try FileManager.default.createDirectory(at: empty.appendingPathComponent("empty"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.installDeveloperFixture(from: empty))
    }
    func testSymlinkFileDirectoryAndRootRejected() throws {
        let store = try store(); let fixture = try fixture()
        let original = fixture.appendingPathComponent("bin/hello")
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertThrowsError(try store.installDeveloperFixture(from: fixture))
        let valid = try self.fixture()
        let link = temporary.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
        XCTAssertThrowsError(try store.installDeveloperFixture(from: link))
        XCTAssertThrowsError(try ExtensionStore(rootURL: link.appendingPathComponent("store")))
    }
    func testRemoteInstallationAlwaysBlocked() throws {
        XCTAssertThrowsError(try store().installRemote(from: URL(string: "https://example.com/extension.zip")!)) { error in
            XCTAssertEqual(error as? ExtensionError, .remoteInstallationRequiresVerifier)
        }
    }
    func testManifestAndCatalogCodableRoundTrip() throws {
        let manifest = ExtensionManifest(id: "dev.hello", name: "Hello", version: "1.0.0", entrypoint: "hello", files: ["hello"])
        XCTAssertEqual(try JSONDecoder().decode(ExtensionManifest.self, from: JSONEncoder().encode(manifest)), manifest)
        let catalog = ExtensionCatalog(entries: [])
        XCTAssertEqual(try JSONDecoder().decode(ExtensionCatalog.self, from: JSONEncoder().encode(catalog)), catalog)
    }
}

// Resolve only a trusted, existing fixture parent. Never use this on package paths.
private func physicalFixtureParent(_ url: URL) throws -> URL {
    guard let pointer = realpath(url.path, nil) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
}
