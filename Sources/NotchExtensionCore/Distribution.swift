import Foundation
import CryptoKit
import Darwin

public struct SignedCatalogEnvelope: Codable, Sendable {
    public var keyID: String
    public var payload: String
    public var signature: String
    public init(keyID: String, payload: String, signature: String) {
        self.keyID = keyID; self.payload = payload; self.signature = signature
    }
}

/// Signature covers the exact decoded payload bytes, not re-encoded JSON.
public struct SignedCatalogPayload: Codable, Sendable {
    public var schemaVersion: Int
    public var catalogVersion: Int
    /// Unix seconds; expired catalogs never authorize preparation, including offline.
    public var expiresAt: Double
    public var entries: [CatalogEntry]
    public init(schemaVersion: Int = 1, catalogVersion: Int, expiresAt: Double, entries: [CatalogEntry]) {
        self.schemaVersion = schemaVersion; self.catalogVersion = catalogVersion
        self.expiresAt = expiresAt; self.entries = entries
    }
}

public struct DistributionConfiguration: Sendable {
    public let trustedKeys: [String: Data]
    public let githubOwner: String
    public let githubRepository: String
    public let allowLoopbackHTTPForTests: Bool
    public let hostVersion: String
    public let maximumCatalogBytes = 1_048_576
    public let maximumPackageBytes = 32 * 1024 * 1024
    public init(trustedKeys: [String: Data], githubOwner: String, githubRepository: String,
                allowLoopbackHTTPForTests: Bool = false, hostVersion: String = "0.1.0") {
        self.trustedKeys = trustedKeys; self.githubOwner = githubOwner
        self.githubRepository = githubRepository; self.allowLoopbackHTTPForTests = allowLoopbackHTTPForTests
        self.hostVersion = hostVersion
    }
    fileprivate func permits(_ url: URL, package: Bool, redirect: Bool = false) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return false }
        if allowLoopbackHTTPForTests { return scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host) }
        guard scheme == "https", url.port == nil || url.port == 443 else { return false }
        let owner = githubOwner.lowercased(), repo = githubRepository
        guard !owner.isEmpty, owner.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              !repo.isEmpty, repo.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }), repo != ".", repo != ".." else { return false }
        if package {
            if redirect, ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host) { return true }
            guard host == "github.com", url.query == nil, !url.absoluteString.contains("%") else { return false }
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 7 && parts[0].isEmpty && parts[1].lowercased() == owner &&
                parts[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) &&
                parts[3] == "releases" && parts[4] == "download" &&
                parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        }
        guard url.query == nil, !url.absoluteString.contains("%"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return (host == "\(owner).github.io" && url.path.hasPrefix("/\(repo)/")) ||
               (host == "raw.githubusercontent.com" && url.path.hasPrefix("/\(githubOwner)/\(repo)/"))
    }
}

public struct PreparedExtensionPackage: Sendable {
    public let directory: URL
    public let manifest: ExtensionManifest
    public let catalogVersion: Int
    public let keyID: String
    public let fileSHA256: [String: String]
    /// Test trust is never represented as production publisher verification.
    public let provenance: String
}

private final class DistributionSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let configuration: DistributionConfiguration
    let package: Bool
    init(_ configuration: DistributionConfiguration, package: Bool) { self.configuration = configuration; self.package = package }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard task.countOfBytesReceived <= Int64(configuration.maximumPackageBytes),
              let url = request.url, configuration.permits(url, package: package, redirect: true) else {
            completionHandler(nil); return
        }
        var clean = request
        clean.setValue(nil, forHTTPHeaderField: "Authorization")
        clean.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

/// One actor per private cache directory. Cache ownership and filesystem access are host responsibilities.
/// Cache deletion resets replay memory; this is not hardware-backed rollback protection.
public actor SignedPackageTransport {
    private let configuration: DistributionConfiguration
    private let cacheDirectory: URL
    private var accepted: (envelope: SignedCatalogEnvelope, payload: SignedCatalogPayload, digest: String)?
    private var cacheURL: URL { cacheDirectory.appendingPathComponent("signed-catalog.json") }

    public init(configuration: DistributionConfiguration, cacheDirectory: URL) throws {
        guard !configuration.trustedKeys.isEmpty,
              configuration.trustedKeys.allSatisfy({ !$0.key.isEmpty && $0.value.count == 32 }) else {
            throw ExtensionError.invalidPackage("No valid publisher trust configuration")
        }
        try Self.safeDirectory(cacheDirectory)
        self.configuration = configuration; self.cacheDirectory = cacheDirectory
        // Verify persisted state even when expired, to retain its replay floor.
        let url = cacheDirectory.appendingPathComponent("signed-catalog.json")
        if FileManager.default.fileExists(atPath: url.path) {
            try Self.rejectSymlinks(url)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard let size, size.intValue <= configuration.maximumCatalogBytes else { throw ExtensionError.invalidPackage("Oversized catalog cache") }
            let bytes = try Data(contentsOf: url)
            let result = try Self.verify(bytes, configuration: configuration, requireFresh: false)
            self.accepted = result
        }
    }

    public func fetchCatalog(from url: URL) async throws -> SignedCatalogPayload {
        let bytes = try await download(url, package: false, limit: configuration.maximumCatalogBytes)
        return try acceptCatalog(bytes)
    }

    // Internal seam also exercises persisted replay handling without a network fixture.
    func acceptCatalog(_ bytes: Data) throws -> SignedCatalogPayload {
        let result = try Self.verify(bytes, configuration: configuration, requireFresh: true)
        if let old = accepted {
            guard result.payload.catalogVersion >= old.payload.catalogVersion,
                  result.payload.catalogVersion != old.payload.catalogVersion || result.digest == old.digest else {
                throw ExtensionError.invalidPackage("Catalog rollback or same-version equivocation")
            }
        }
        try Self.rejectSymlinks(cacheURL)
        try bytes.write(to: cacheURL, options: .atomic)
        accepted = result
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        return result.payload
    }

    public func cachedCatalog() throws -> SignedCatalogPayload {
        guard let accepted, accepted.payload.expiresAt > Date().timeIntervalSince1970 else {
            throw ExtensionError.invalidPackage("No unexpired authenticated catalog")
        }
        return accepted.payload
    }

    /// Downloads and verifies only. Never installs, enables, or executes downloaded code.
    /// Caller owns cleanup of the returned private directory and explicit executable consent.
    public func preparePackage(id: String, stagingParent: URL, expectedCatalogVersion: Int? = nil, expectedEntry: CatalogEntry? = nil) async throws -> PreparedExtensionPackage {
        let catalog = try cachedCatalog()
        guard let record = accepted, let entry = catalog.entries.first(where: { $0.id == id }) else {
            throw ExtensionError.invalidPackage("Extension absent from verified catalog")
        }
        guard Self.compatible(entry, hostVersion: configuration.hostVersion) else {
            throw ExtensionError.invalidPackage("Package architecture or minimum host version is incompatible")
        }
        guard expectedCatalogVersion == nil || expectedCatalogVersion == catalog.catalogVersion,
              expectedEntry == nil || expectedEntry == entry else { throw ExtensionError.invalidPackage("Displayed catalog selection changed") }
        let archive = try await download(entry.downloadURL, package: true, limit: entry.size)
        guard archive.count == entry.size, Self.digest(archive) == entry.sha256.lowercased(),
              catalog.expiresAt > Date().timeIntervalSince1970,
              accepted?.digest == record.digest else { throw ExtensionError.invalidPackage("Package integrity or catalog freshness changed") }
        let files = try StoredZIP.read(archive, maximumBytes: configuration.maximumPackageBytes)
        guard let manifestBytes = files["manifest.json"], manifestBytes.count <= 65_536 else {
            throw ExtensionError.invalidPackage("Missing or oversized manifest")
        }
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: manifestBytes)
        try manifest.validate()
        guard manifest.id == entry.id, manifest.version == entry.version, manifest.protocolVersion == entry.protocolVersion,
              Set(files.keys) == Set(["manifest.json"] + manifest.files) else {
            throw ExtensionError.invalidPackage("Signed identity or exact manifest allowlist mismatch")
        }
        try Self.safeDirectory(stagingParent)
        let destination = stagingParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for (path, data) in files {
                let target = destination.appendingPathComponent(path)
                try Self.safeDirectory(target.deletingLastPathComponent())
                try Self.rejectSymlinks(target)
                try data.write(to: target, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: path == manifest.entrypoint ? 0o700 : 0o600], ofItemAtPath: target.path)
            }
            // Independently inspect extracted filesystem, including entry type, count, and content.
            var actual = Set<String>()
            var allowedDirectories = Set<String>()
            for path in files.keys {
                let components = path.split(separator: "/")
                for n in 1..<components.count { allowedDirectories.insert(components.prefix(n).joined(separator: "/")) }
            }
            guard let walker = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else { throw ExtensionError.invalidPackage("Cannot inspect extraction") }
            for case let file as URL in walker {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true else { throw ExtensionError.unsafePath(file.path) }
                let path = String(file.path.dropFirst(destination.path.count + 1))
                if info.isDirectory == true {
                    guard allowedDirectories.contains(path) else { throw ExtensionError.invalidPackage("Unexpected extracted directory") }
                    continue
                }
                guard info.isRegularFile == true, let expected = files[path], try Data(contentsOf: file) == expected else { throw ExtensionError.invalidPackage("Extraction changed") }
                actual.insert(path)
            }
            guard actual == Set(files.keys) else { throw ExtensionError.invalidPackage("Incomplete extraction") }
            return PreparedExtensionPackage(directory: destination, manifest: manifest, catalogVersion: catalog.catalogVersion,
                                            keyID: record.envelope.keyID, fileSHA256: files.mapValues(Self.digest), provenance: configuration.allowLoopbackHTTPForTests ? "development-test" : "caller-configured-publisher")
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }

    private func download(_ url: URL, package: Bool, limit: Int) async throws -> Data {
        guard limit > 0, configuration.permits(url, package: package) else { throw ExtensionError.invalidPackage("Distribution URL is not allowed") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 60
        let delegate = DistributionSessionDelegate(configuration, package: package)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let finalURL = response.url, configuration.permits(finalURL, package: package, redirect: true),
              response.expectedContentLength <= Int64(limit),
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            throw ExtensionError.invalidPackage("Invalid or oversized HTTP response")
        }
        var data = Data(); data.reserveCapacity(min(limit, 65_536))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw ExtensionError.invalidPackage("Download exceeds byte limit") }
            data.append(byte)
        }
        return data
    }

    nonisolated static func verify(_ bytes: Data, configuration: DistributionConfiguration, requireFresh: Bool = true)
        throws -> (envelope: SignedCatalogEnvelope, payload: SignedCatalogPayload, digest: String) {
        guard bytes.count <= configuration.maximumCatalogBytes else { throw ExtensionError.invalidPackage("Catalog exceeds limit") }
        let envelope = try JSONDecoder().decode(SignedCatalogEnvelope.self, from: bytes)
        guard let keyBytes = configuration.trustedKeys[envelope.keyID],
              let payload = Data(base64Encoded: envelope.payload), let signature = Data(base64Encoded: envelope.signature),
              signature.count == 64 else { throw ExtensionError.invalidPackage("Unknown key or malformed signed catalog") }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        guard key.isValidSignature(signature, for: payload) else { throw ExtensionError.invalidPackage("Invalid catalog signature") }
        let catalog = try JSONDecoder().decode(SignedCatalogPayload.self, from: payload)
        guard catalog.schemaVersion == 1, catalog.catalogVersion > 0, catalog.expiresAt.isFinite,
              !requireFresh || catalog.expiresAt > Date().timeIntervalSince1970,
              catalog.entries.count <= 256, Set(catalog.entries.map { $0.id.lowercased() }).count == catalog.entries.count else {
            throw ExtensionError.invalidPackage("Invalid, duplicate, or expired catalog")
        }
        for entry in catalog.entries {
            guard ExtensionManifest.isIdentifier(entry.id), ExtensionManifest.isVersion(entry.version), entry.protocolVersion == 1,
                  ["universal", "arm64", "x86_64"].contains(entry.architecture), ExtensionManifest.isVersion(entry.minHostVersion),
                  entry.size > 0, entry.size <= configuration.maximumPackageBytes,
                  entry.sha256.utf8.count == 64, entry.sha256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  configuration.permits(entry.downloadURL, package: true) else { throw ExtensionError.invalidPackage("Invalid signed package metadata") }
        }
        return (envelope, catalog, digest(payload))
    }
    private nonisolated static func compatible(_ entry: CatalogEntry, hostVersion: String) -> Bool {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unsupported"
        #endif
        guard entry.architecture == "universal" || entry.architecture == architecture else { return false }
        // MVP host compatibility accepts stable numeric versions only; unknown/prerelease
        // requirements fail closed rather than inventing SemVer ordering.
        func components(_ version: String) -> [Int]? {
            let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count == 3 else { return nil }
            let numbers = pieces.compactMap { Int($0) }
            guard numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
            return numbers
        }
        guard let host = components(hostVersion), let minimum = components(entry.minHostVersion) else { return false }
        for i in 0..<3 { if host[i] != minimum[i] { return host[i] > minimum[i] } }
        return true
    }
    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private nonisolated static func safeDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw ExtensionError.unsafePath("Expected private local directory") }
        try rejectSymlinks(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else { throw ExtensionError.unsafePath("Directory ownership or permissions: " + url.path) }
    }
    private nonisolated static func rejectSymlinks(_ url: URL) throws {
        // Use lexical string parents. Foundation URL normalization can rewrite
        // /private/var to /var; never normalize or follow caller-provided links.
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw ExtensionError.unsafePath(path)
        }
        var components = path.split(separator: "/")
        while !components.isEmpty {
            let current = "/" + components.joined(separator: "/")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: current),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ExtensionError.unsafePath(current)
            }
            components.removeLast()
        }
    }
}

/// Deliberately narrow ZIP v1: STORED files only, no encryption, descriptors, ZIP64,
/// extras, comments, links, directory records or prepended/trailing bytes. Parent
/// directories are synthesized from file paths. Every local record must be indexed.
/// Rejection is preferable to ambiguously interpreting a second ZIP dialect.
enum StoredZIP {
    static func read(_ data: Data, maximumBytes: Int) throws -> [String: Data] {
        let b = [UInt8](data)
        func fail() -> ExtensionError { .invalidPackage("Unsupported or unsafe ZIP (v1 requires ZIP_STORED regular files)") }
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= b.count - 2 else { throw fail() }
            return Int(b[offset]) | Int(b[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= b.count - 4 else { throw fail() }
            return Int(b[offset]) | Int(b[offset + 1]) << 8 | Int(b[offset + 2]) << 16 | Int(b[offset + 3]) << 24
        }
        guard b.count >= 22, b.count <= maximumBytes else { throw fail() }
        let end = b.count - 22
        guard try u32(end) == 0x06054b50, try u16(end + 4) == 0, try u16(end + 6) == 0,
              try u16(end + 8) == u16(end + 10), try u16(end + 20) == 0 else { throw fail() }
        let count = try u16(end + 10), centralSize = try u32(end + 12), centralStart = try u32(end + 16)
        guard count > 0, count <= 257, centralStart + centralSize == end else { throw fail() }
        var central = centralStart, local = 0, total = 0
        var files = [String: Data](), canonical = Set<String>(), filePaths = Set<String>(), parentPaths = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            guard central + 46 <= end, try u32(central) == 0x02014b50 else { throw fail() }
            let needed = try u16(central + 6)
            let flags = try u16(central + 8), method = try u16(central + 10), crc = try u32(central + 16)
            let compressed = try u32(central + 20), size = try u32(central + 24), nameSize = try u16(central + 28)
            let extra = try u16(central + 30), comment = try u16(central + 32), external = try u32(central + 38)
            let offset = try u32(central + 42), mode = (external >> 16) & 0xf000
            guard needed <= 20, flags == 0 || flags == 0x800, method == 0, compressed == size, extra == 0, comment == 0,
                  try u16(central + 34) == 0, offset == local,
                  mode == 0 || mode == 0x8000, external & 0x10 == 0,
                  nameSize > 0, nameSize <= 512, central + 46 + nameSize <= end,
                  size <= maximumBytes, total <= maximumBytes - size else { throw fail() }
            let nameBytes = Array(b[(central + 46)..<(central + 46 + nameSize)])
            guard let name = String(bytes: nameBytes, encoding: .utf8) else { throw fail() }
            try ExtensionManifest.validateRelativePath(name)
            // Unicode case/normalization collisions are rejected before touching the filesystem.
            let folded = name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard canonical.insert(folded).inserted, !parentPaths.contains(folded) else { throw fail() }
            let components = folded.split(separator: "/")
            for n in 1..<components.count {
                let parent = components.prefix(n).joined(separator: "/")
                guard !filePaths.contains(parent) else { throw fail() }
                parentPaths.insert(parent)
            }
            filePaths.insert(folded)
            guard local + 30 <= centralStart, try u32(local) == 0x04034b50,
                  try u16(local + 4) == needed,
                  try u16(local + 6) == flags, try u16(local + 8) == method,
                  try u32(local + 14) == crc, try u32(local + 18) == compressed, try u32(local + 22) == size,
                  try u16(local + 26) == nameSize, try u16(local + 28) == 0,
                  local + 30 + nameSize + size <= centralStart else { throw fail() }
            guard Array(b[(local + 30)..<(local + 30 + nameSize)]) == nameBytes else { throw fail() }
            let start = local + 30 + nameSize
            let content = Data(b[start..<(start + size)])
            guard Int(crc32(content)) == crc else { throw fail() }
            files[name] = content; total += size
            local = start + size; central += 46 + nameSize
        }
        guard central == end, local == centralStart else { throw fail() }
        return files
    }
    static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ 0xffffffff
    }
}
