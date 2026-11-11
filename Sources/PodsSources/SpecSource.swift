public import Foundation
public import PodsCore
public import PodsSpec

/// A repository of podspecs (the trunk CDN or a git spec repo).
public protocol SpecSource: Sendable {
    /// The URL written in the Podfile (`source '...'`).
    var url: String { get }
    /// The key used in Podfile.lock `SPEC REPOS` (`trunk` for the CDN).
    var lockfileName: String { get }
    /// All published versions of a root pod, or an empty array if the source doesn't have it.
    func versions(of name: String) async throws -> [Version]
    /// The root specification of a pod at a version.
    func specification(of name: String, version: Version) async throws -> Specification
    /// Brings local caches up to date (`pod repo update`).
    func update() async throws
}

/// Minimal HTTP abstraction so that sources can be tested without the network.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }
}

/// `URLSession` backed client.
public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.setValue("swiftpods", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        var responseHeaders: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            responseHeaders[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPResponse(status: http?.statusCode ?? 0, body: data, headers: responseHeaders)
    }
}

/// Default locations for caches.
public enum CacheLocations {
    public static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["SWIFTPODS_CACHE_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftPods", isDirectory: true)
    }
}
