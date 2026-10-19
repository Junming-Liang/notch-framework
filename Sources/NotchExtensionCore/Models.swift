import Foundation

public enum ExtensionError: Error, LocalizedError, Equatable {
    case invalidManifest(String), unsafePath(String), invalidPackage(String)
    case notInstalled(String), versionAlreadyInstalled(String), disabled(String)
    case noRollback(String), remoteInstallationRequiresVerifier
    case protocolFailure(String), deadlineExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let s): return "Invalid manifest: \(s)"
        case .unsafePath(let s): return "Unsafe path: \(s)"
        case .invalidPackage(let s): return "Invalid package: \(s)"
        case .notInstalled(let s): return "Not installed: \(s)"
        case .versionAlreadyInstalled(let s): return "Version already installed: \(s)"
        case .disabled(let s): return "Extension is disabled: \(s)"
        case .noRollback(let s): return "No rollback available: \(s)"
        case .remoteInstallationRequiresVerifier: return "Remote executable installation is blocked: no publisher verifier is configured."
        case .protocolFailure(let s): return "Protocol failure: \(s)"
        case .deadlineExceeded: return "Extension request timed out."
        }
    }
}

public struct ExtensionManifest: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var entrypoint: String
    /// Exact regular-file allowlist, excluding manifest.json itself.
    public var files: [String]
    public var protocolVersion: Int
    public init(id: String, name: String, version: String, entrypoint: String, files: [String], protocolVersion: Int = 1) {
        self.id = id; self.name = name; self.version = version; self.entrypoint = entrypoint; self.files = files; self.protocolVersion = protocolVersion
    }
    public func validate() throws {
        guard Self.isIdentifier(id), Self.isVersion(version), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 200 else {
            throw ExtensionError.invalidManifest("Invalid id, version, or name")
        }
        guard protocolVersion == 1 else { throw ExtensionError.invalidManifest("Unsupported protocol version") }
        guard !files.isEmpty, files.count <= 256, Set(files.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == files.count,
              !files.contains("manifest.json"), files.contains(entrypoint) else {
            throw ExtensionError.invalidManifest("Files must be unique and include the entrypoint")
        }
        for path in files { try Self.validateRelativePath(path) }
    }
    static func isIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128, value != ".", value != "..", !value.hasPrefix(".") else { return false }
        return value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) }
    }
    static func isVersion(_ value: String) -> Bool {
        guard value.utf8.count <= 128,
              value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?\z"#, options: .regularExpression) != nil else { return false }
        let withoutBuild = value.split(separator: "+", maxSplits: 1)[0]
        if let separator = withoutBuild.firstIndex(of: "-") {
            let prerelease = withoutBuild[withoutBuild.index(after: separator)...]
            for identifier in prerelease.split(separator: ".") {
                if identifier.allSatisfy({ $0.isNumber }), identifier.count > 1, identifier.first == "0" { return false }
            }
        }
        return true
    }
    static func validateRelativePath(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 512, !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ExtensionError.unsafePath(value)
        }
    }
}

/// Discovery metadata is not an execution authorization or publisher verification.
public struct ExtensionCatalog: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var catalogVersion: Int
    public var distribution: String
    public var entries: [CatalogEntry]
    public init(schemaVersion: Int = 1, catalogVersion: Int = 1, distribution: String = "development", entries: [CatalogEntry]) {
        self.schemaVersion = schemaVersion; self.catalogVersion = catalogVersion; self.distribution = distribution; self.entries = entries
    }
}
public struct CatalogEntry: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var protocolVersion: Int
    public var architecture: String
    public var minHostVersion: String
    public var size: Int
    /// Integrity metadata only. This does not establish publisher authenticity.
    public var sha256: String
    public var downloadURL: URL
    public var capabilities: [String]
    public init(id: String, name: String, version: String, protocolVersion: Int = 1, architecture: String, minHostVersion: String, size: Int, sha256: String, downloadURL: URL, capabilities: [String] = []) {
        self.id = id; self.name = name; self.version = version; self.protocolVersion = protocolVersion
        self.architecture = architecture; self.minHostVersion = minHostVersion; self.size = size
        self.sha256 = sha256; self.downloadURL = downloadURL; self.capabilities = capabilities
    }
}
public struct InstalledExtension: Codable, Equatable, Sendable {
    public var manifest: ExtensionManifest
    public var enabled: Bool
    public var previousVersion: String?
    public var fileSHA256: [String: String]
    public init(manifest: ExtensionManifest, enabled: Bool = false, previousVersion: String? = nil, fileSHA256: [String: String] = [:]) {
        self.manifest = manifest; self.enabled = enabled; self.previousVersion = previousVersion; self.fileSHA256 = fileSHA256
    }
}
public struct HelloRequest: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let requestID: String
    public init(requestID: String = UUID().uuidString) { self.type = "hello"; self.protocolVersion = 1; self.requestID = requestID }
}
public struct HelloResponse: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestID: String
    public var message: String
    public var title: String
    public var subtitle: String
    public var progress: Double
    public init(requestID: String, message: String, title: String = "Hello Notch", subtitle: String = "Local developer fixture", progress: Double = 0.5, type: String = "hello", protocolVersion: Int = 1) {
        self.type = type; self.protocolVersion = protocolVersion; self.requestID = requestID; self.message = message; self.title = title; self.subtitle = subtitle; self.progress = progress
    }
}
