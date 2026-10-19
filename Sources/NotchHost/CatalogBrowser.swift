import Foundation
import NotchExtensionCore

struct CatalogItem: Codable, Identifiable {
    let id: String
    let name: String?
    let version: String
    let protocolVersion: Int
    let architecture: String
    let minHostVersion: String
    let size: Int
    let sha256: String
    let downloadURL: URL
    let capabilities: [String]
}
struct CatalogDocument: Codable {
    let schemaVersion: Int
    let catalogVersion: Int
    let distribution: String
    let entries: [CatalogItem]
    func validate() throws {
        guard schemaVersion == 1, catalogVersion > 0, entries.count <= 1000,
              Set(entries.map(\.id)).count == entries.count,
              ["development", "production", "unverified-preview"].contains(distribution) else { throw CatalogError.invalid }
        for entry in entries {
            guard entry.protocolVersion == 1, entry.size > 0, entry.size < 2 * 1024 * 1024 * 1024,
                  entry.sha256.count == 64, entry.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  entry.downloadURL.scheme == "https", entry.downloadURL.host == "github.com",
                  entry.downloadURL.user == nil, entry.downloadURL.password == nil,
                  entry.downloadURL.query == nil, entry.downloadURL.fragment == nil,
                  entry.downloadURL.path.contains("/releases/download/"),
                  !entry.downloadURL.path.contains("/latest/") else { throw CatalogError.invalid }
        }
    }
}
enum CatalogError: LocalizedError {
    case invalid, tooLarge, distributionNotConfigured
    var errorDescription: String? {
        switch self {
        case .invalid: return "目录格式或下载地址不符合规则。"
        case .tooLarge: return "目录超过 1 MiB 上限。"
        case .distributionNotConfigured: return "正式分发尚未配置可信发布者；当前只能浏览目录及安装自己构建的本地开发包。"
        }
    }
}
/// Disk cache is a convenience only. It never grants executable trust.
struct CatalogBrowser {
    let cacheURL: URL
    func readLocal(_ url: URL) throws -> CatalogDocument {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 1_048_576 else { throw CatalogError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw CatalogError.tooLarge }
        let catalog = try JSONDecoder().decode(CatalogDocument.self, from: data)
        try catalog.validate()
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        return catalog
    }
    func cached() throws -> CatalogDocument {
        let info = try cacheURL.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= 1_048_576 else { throw CatalogError.tooLarge }
        let data = try Data(contentsOf: cacheURL)
        guard data.count <= 1_048_576 else { throw CatalogError.tooLarge }
        let catalog = try JSONDecoder().decode(CatalogDocument.self, from: data)
        try catalog.validate(); return catalog
    }
    func authorizeRemoteInstall() throws { throw CatalogError.distributionNotConfigured }
}

/// Public browsing is deliberately separate from authenticated install authorization.
private final class BrowseRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func permits(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return (host.hasSuffix(".github.io") && host != ".github.io") || host == "raw.githubusercontent.com"
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.permits(url) else { completionHandler(nil); return }
        completionHandler(request)
    }
}
extension CatalogBrowser {
    func fetchPublicPreview(from url: URL) async throws -> CatalogDocument {
        guard BrowseRedirectPolicy.permits(url) else { throw CatalogError.invalid }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: BrowseRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= 1_048_576, let finalURL = response.url, BrowseRedirectPolicy.permits(finalURL) else { throw CatalogError.invalid }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw CatalogError.tooLarge }; data.append(byte)
        }
        let decoder = JSONDecoder()
        var document: CatalogDocument
        if let direct = try? decoder.decode(CatalogDocument.self, from: data) { document = direct }
        else {
            // Parsing an envelope is only a display preview, never signature verification.
            let envelope = try decoder.decode(SignedCatalogEnvelope.self, from: data)
            guard let payloadData = Data(base64Encoded: envelope.payload) else { throw CatalogError.invalid }
            let payload = try decoder.decode(SignedCatalogPayload.self, from: payloadData)
            let entries = try decoder.decode([CatalogItem].self, from: JSONEncoder().encode(payload.entries))
            document = CatalogDocument(schemaVersion: payload.schemaVersion, catalogVersion: payload.catalogVersion, distribution: "unverified-preview", entries: entries)
        }
        document = CatalogDocument(schemaVersion: document.schemaVersion, catalogVersion: document.catalogVersion, distribution: "unverified-preview", entries: document.entries)
        try document.validate()
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: cacheURL, options: .atomic)
        return document
    }
}
