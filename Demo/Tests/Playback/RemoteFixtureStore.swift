import Foundation
import CryptoKit

/// Real-media reproduction belongs to Demo. Fetch exact regression inputs from
/// configured URLs into its temporary sandbox; never fall back to repo/bundle videos.
enum RemoteFixtureStore {
    private struct Asset: Decodable { let path: String; let sha256: String }
    private struct Configuration: Decodable {
        let baseURL: URL?
        let sources: [String: URL]?
    }
    private enum SourceError: Error, CustomStringConvertible {
        case missingConfiguration, missingAsset(String), invalidSource(String)
        case downloadFailed(String, Int), digestMismatch(String)
        var description: String {
            switch self {
            case .missingConfiguration:
                return "NOT_CONFIGURED: provide FTPLAYER_TEST_MEDIA_MANIFEST or Documents/FTPlayerTestMediaSources.json with exact regression media URLs. No bundled/local video fallback."
            case .missingAsset(let path): return "No configured regression media URL for " + path
            case .invalidSource(let path): return "Invalid regression media source for " + path
            case .downloadFailed(let path, let code): return "Regression media download failed: \(path), code \(code)"
            case .digestMismatch(let path): return "Regression media SHA-256 mismatch: " + path
            }
        }
    }
    private final class Download {
        private let lock = NSLock()
        private var value: Result<Data, Error>?
        func finish(_ result: Result<Data, Error>) { lock.lock(); value = result; lock.unlock() }
        var result: Result<Data, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }
    private static var prepared: URL?

    static func file(_ path: String) throws -> URL {
        let directory = try root()
        let file = directory.appendingPathComponent(path)
        guard path.isEmpty || FileManager.default.fileExists(atPath: file.path) else { throw SourceError.missingAsset(path) }
        return file
    }

    static func root() throws -> URL {
        if let prepared { return prepared }
        let bundle = Bundle(for: PlaybackTestCase.self)
        guard let catalog = bundle.url(forResource: "MediaFixtureCatalog", withExtension: "json") else {
            throw SourceError.invalidSource("fixture catalog")
        }
        let assets = try JSONDecoder().decode([Asset].self, from: Data(contentsOf: catalog))
        let configFile: URL
        if let path = ProcessInfo.processInfo.environment["FTPLAYER_TEST_MEDIA_MANIFEST"], !path.isEmpty, !path.hasPrefix("$(") {
            configFile = URL(fileURLWithPath: path)
        } else {
            configFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FTPlayerTestMediaSources.json")
        }
        guard FileManager.default.fileExists(atPath: configFile.path) else { throw SourceError.missingConfiguration }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configFile))
        guard config.baseURL != nil || !(config.sources?.isEmpty ?? true) else {
            throw SourceError.missingConfiguration
        }
        let known = Set(assets.map(\.path))
        if let unknown = config.sources?.keys.first(where: { !known.contains($0) }) {
            throw SourceError.invalidSource(unknown)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FTPlayerRemoteFixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for asset in assets {
                let components = asset.path.split(separator: "/", omittingEmptySubsequences: false)
                guard !components.contains(".."), !components.contains(""), !asset.path.hasPrefix("/") else {
                    throw SourceError.invalidSource(asset.path)
                }
                guard let url = config.sources?[asset.path] ?? config.baseURL?.appendingPathComponent(asset.path) else { continue }
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                    throw SourceError.invalidSource(asset.path)
                }
                let data = try download(url, path: asset.path)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == asset.sha256 else { throw SourceError.digestMismatch(asset.path) }
                let destination = directory.appendingPathComponent(asset.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }
            prepared = directory
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func download(_ url: URL, path: String) throws -> Data {
        let state = Download()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url) { data, response, error in
            if let response = response as? HTTPURLResponse, response.statusCode == 200, let data, error == nil {
                state.finish(.success(data))
            } else {
                state.finish(.failure(SourceError.downloadFailed(path, (response as? HTTPURLResponse)?.statusCode ?? (error as NSError?)?.code ?? -1)))
            }
        }
        task.resume()
        let deadline = Date().addingTimeInterval(95)
        while state.result == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard let result = state.result else { throw SourceError.downloadFailed(path, NSURLErrorTimedOut) }
        return try result.get()
    }
}
