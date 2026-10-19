import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A local developer store, not a sandbox or production trust verifier.
/// Use one instance per root. Private storage must not be writable by other users/processes.
public final class ExtensionStore: @unchecked Sendable {
    public let rootURL: URL
    private let fm = FileManager.default
    private let lock = NSRecursiveLock()
    private var indexURL: URL { rootURL.appendingPathComponent("installed.json") }

    public init(rootURL: URL) throws {
        guard rootURL.isFileURL else { throw ExtensionError.unsafePath("Store must be local") }
        self.rootURL = rootURL.standardizedFileURL
        try Self.rejectSymlinkAncestors(self.rootURL)
        try fm.createDirectory(at: self.rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.checkPrivateDirectory(self.rootURL)
        for name in ["versions", "staging", "trash", "verification"] {
            let url = self.rootURL.appendingPathComponent(name)
            try Self.rejectSymlinkAncestors(url)
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.checkPrivateDirectory(url)
        }
    }
    public func list() throws -> [InstalledExtension] {
        lock.lock(); defer { lock.unlock() }
        return try readIndex().values.sorted { $0.manifest.id < $1.manifest.id }
    }
    /// The caller must make developer executable consent explicit. Never call this for downloaded catalog packages.
    @discardableResult public func installDeveloperFixture(from directory: URL) throws -> InstalledExtension {
        try installDirectory(from: directory, expectedFileSHA256: nil)
    }
    /// Only accepts a package produced by the signature-verified transport. Hashes bind
    /// staged bytes to the verified archive; they are not themselves a trust root.
    @discardableResult public func installVerifiedPackage(_ package: PreparedExtensionPackage) throws -> InstalledExtension {
        try installDirectory(from: package.directory, expectedFileSHA256: package.fileSHA256)
    }
    private func installDirectory(from directory: URL, expectedFileSHA256: [String: String]?) throws -> InstalledExtension {
        lock.lock(); defer { lock.unlock() }
        let manifest = try validatePackage(directory)
        var index = try readIndex()
        let destination = versionURL(id: manifest.id, version: manifest.version)
        try Self.rejectSymlinkAncestors(destination)
        guard !fm.fileExists(atPath: destination.path) else { throw ExtensionError.versionAlreadyInstalled(manifest.version) }
        let stage = rootURL.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Copy only the validated allowlist, then independently revalidate the staged package.
        for relative in ["manifest.json"] + manifest.files {
            try Task.checkCancellation()
            let source = directory.appendingPathComponent(relative)
            try Self.rejectSymlinkAncestors(source)
            let target = stage.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: source, to: target)
        }
        guard try validatePackage(stage) == manifest else { throw ExtensionError.invalidPackage("Manifest changed during copy") }
        let integrity = try contentDigests(stage, manifest:manifest)
        if let expected = expectedFileSHA256 {
            guard integrity == expected else { throw ExtensionError.invalidPackage("Verified package changed before activation") }
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.appendingPathComponent(manifest.entrypoint).path)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Task.checkCancellation()
        let verification = integrityURL(id:manifest.id, version:manifest.version)
        try Self.rejectSymlinkAncestors(verification)
        try fm.createDirectory(at:verification.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(integrity).write(to:verification,options:.atomic)
        do { try fm.moveItem(at: stage, to: destination) }
        catch { try? fm.removeItem(at:verification); throw error }
        let installed = InstalledExtension(manifest: manifest, enabled: false, previousVersion: index[manifest.id]?.manifest.version, fileSHA256:integrity)
        index[manifest.id] = installed
        do { try writeIndex(index) } catch { try? fm.removeItem(at: destination); try? fm.removeItem(at:verification); throw error }
        return installed
    }
    public func installRemote(from url: URL) throws {
        // HTTPS, a SHA digest, or a GitHub account alone does not prove publisher authorization.
        throw ExtensionError.remoteInstallationRequiresVerifier
    }
    public func setEnabled(id: String, enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        var index = try readIndex()
        guard var item = index[id] else { throw ExtensionError.notInstalled(id) }
        if enabled {
            guard try validatePackage(versionURL(id: id, version: item.manifest.version)) == item.manifest else {
                throw ExtensionError.invalidPackage("Installed manifest changed")
            }
        }
        item.enabled = enabled; index[id] = item
        try writeIndex(index)
    }
    @discardableResult public func rollback(id: String) throws -> InstalledExtension {
        lock.lock(); defer { lock.unlock() }
        var index = try readIndex()
        guard let current = index[id] else { throw ExtensionError.notInstalled(id) }
        guard let previous = current.previousVersion else { throw ExtensionError.noRollback(id) }
        let manifest = try validatePackage(versionURL(id: id, version: previous))
        guard manifest.id == id, manifest.version == previous else { throw ExtensionError.invalidPackage("Rollback identity mismatch") }
        let integrity = try readIntegrity(id:id,version:previous)
        guard try contentDigests(versionURL(id:id,version:previous),manifest:manifest) == integrity else { throw ExtensionError.invalidPackage("Rollback bytes changed") }
        let restored = InstalledExtension(manifest: manifest, enabled: false, previousVersion: current.manifest.version, fileSHA256:integrity)
        index[id] = restored; try writeIndex(index)
        return restored
    }
    /// Removes activation first; retains complete versions and metadata in a recoverable trash directory.
    @discardableResult public func uninstall(id: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        var index = try readIndex()
        guard let item = index.removeValue(forKey: id) else { throw ExtensionError.notInstalled(id) }
        let backup = rootURL.appendingPathComponent("trash").appendingPathComponent("\(id)-\(UUID().uuidString)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(item).write(to: backup.appendingPathComponent("installation.json"), options: .atomic)
        let versions = rootURL.appendingPathComponent("versions").appendingPathComponent(id)
        try Self.rejectSymlinkAncestors(versions)
        // Copy before committing removal: failure preserves the active installation.
        try fm.copyItem(at: versions, to: backup.appendingPathComponent("versions"))
        let verification = rootURL.appendingPathComponent("verification").appendingPathComponent(id)
        try Self.rejectSymlinkAncestors(verification)
        try fm.copyItem(at:verification,to:backup.appendingPathComponent("verification"))
        try writeIndex(index)
        try? fm.removeItem(at: versions)
        try? fm.removeItem(at:verification)
        return backup
    }
    public func makeProcess(id: String) throws -> ExtensionProcess {
        lock.lock(); defer { lock.unlock() }
        guard let item = try readIndex()[id] else { throw ExtensionError.notInstalled(id) }
        guard item.enabled else { throw ExtensionError.disabled(id) }
        let package = versionURL(id: id, version: item.manifest.version)
        guard try validatePackage(package) == item.manifest, try contentDigests(package,manifest:item.manifest) == item.fileSHA256 else { throw ExtensionError.invalidPackage("Installed manifest changed") }
        return ExtensionProcess(executableURL: package.appendingPathComponent(item.manifest.entrypoint))
    }
    private func versionURL(id: String, version: String) -> URL {
        rootURL.appendingPathComponent("versions").appendingPathComponent(id).appendingPathComponent(version)
    }
    private func integrityURL(id:String,version:String) -> URL {
        rootURL.appendingPathComponent("verification").appendingPathComponent(id).appendingPathComponent(version + ".json")
    }
    private func readIntegrity(id:String,version:String) throws -> [String:String] {
        let url = integrityURL(id:id,version:version)
        try Self.rejectSymlinkAncestors(url)
        let attributes = try fm.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 131072 else { throw ExtensionError.invalidPackage("Invalid integrity record") }
        return try JSONDecoder().decode([String:String].self,from:Data(contentsOf:url))
    }
    private func contentDigests(_ directory:URL,manifest:ExtensionManifest) throws -> [String:String] {
        #if canImport(CryptoKit)
        var result = [String:String]()
        for path in ["manifest.json"] + manifest.files {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(path);try Self.rejectSymlinkAncestors(url)
            let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
            var hash = SHA256(); var total = 0
            while let chunk = try handle.read(upToCount:65536), !chunk.isEmpty {
                try Task.checkCancellation(); total += chunk.count
                guard total <= 32*1024*1024 else { throw ExtensionError.invalidPackage("Oversized installed file") }
                hash.update(data:chunk)
            }
            result[path] = hash.finalize().map { String(format:"%02x",$0) }.joined()
        }
        return result
        #else
        throw ExtensionError.remoteInstallationRequiresVerifier
        #endif
    }
    private func readIndex() throws -> [String: InstalledExtension] {
        try Self.rejectSymlinkAncestors(indexURL)
        guard fm.fileExists(atPath: indexURL.path) else { return [:] }
        let attributes = try fm.attributesOfItem(atPath:indexURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16*1024*1024 else { throw ExtensionError.invalidPackage("Invalid or oversized installation index") }
        let result = try JSONDecoder().decode([String: InstalledExtension].self, from: Data(contentsOf: indexURL))
        for (id, item) in result {
            try item.manifest.validate()
            guard id == item.manifest.id, item.previousVersion.map(ExtensionManifest.isVersion) ?? true,
                  Set(item.fileSHA256.keys) == Set(["manifest.json"] + item.manifest.files),
                  item.fileSHA256.values.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
                throw ExtensionError.invalidPackage("Invalid stored identity")
            }
        }
        return result
    }
    private func writeIndex(_ index: [String: InstalledExtension]) throws {
        try Self.rejectSymlinkAncestors(indexURL)
        // Foundation atomic replacement makes activation a single-file commit.
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }
    private func validatePackage(_ directory: URL) throws -> ExtensionManifest {
        guard directory.isFileURL else { throw ExtensionError.unsafePath("Package must be local") }
        try Self.rejectSymlinkAncestors(directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try Self.rejectSymlinkAncestors(manifestURL)
        let attributes = try fm.attributesOfItem(atPath: manifestURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65_536 else {
            throw ExtensionError.invalidPackage("Invalid or oversized manifest")
        }
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: manifestURL))
        try manifest.validate()
        let allowed = Set(["manifest.json"] + manifest.files)
        var allowedDirectories = Set<String>()
        for path in manifest.files {
            let components = path.split(separator: "/")
            if components.count > 1 { for end in 1..<components.count { allowedDirectories.insert(components.prefix(end).joined(separator: "/")) } }
        }
        var actual = Set<String>(); var total: UInt64 = 0; var entryCount = 0
        func walk(_ url: URL, prefix: String) throws {
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try Task.checkCancellation()
                entryCount += 1
                guard entryCount <= 1024 else { throw ExtensionError.invalidPackage("Too many package entries") }
                let relative = prefix + child.lastPathComponent
                let attr = try fm.attributesOfItem(atPath: child.path)
                let kind = attr[.type] as? FileAttributeType
                if kind == .typeDirectory {
                    guard allowedDirectories.contains(relative) else { throw ExtensionError.invalidPackage("Unlisted directory: \(relative)") }
                    try walk(child, prefix: relative + "/")
                } else if kind == .typeRegular {
                    guard allowed.contains(relative) else { throw ExtensionError.invalidPackage("Unlisted file: \(relative)") }
                    let size = (attr[.size] as? NSNumber)?.uint64Value ?? UInt64.max
                    guard size <= 32 * 1024 * 1024 else { throw ExtensionError.invalidPackage("Oversized file") }
                    total += size
                    guard total <= 32 * 1024 * 1024 else { throw ExtensionError.invalidPackage("Package exceeds 32 MiB") }
                    actual.insert(relative)
                } else { throw ExtensionError.unsafePath(relative) }
            }
        }
        try walk(directory, prefix: "")
        guard actual == allowed else { throw ExtensionError.invalidPackage("Missing allowlisted files") }
        return manifest
    }
    private static func checkPrivateDirectory(_ url:URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else { throw ExtensionError.unsafePath("Directory ownership or permissions: " + url.path) }
    }
    private static func rejectSymlinkAncestors(_ url: URL) throws {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: current.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ExtensionError.unsafePath(current.path)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }; current = parent
        }
    }
}
