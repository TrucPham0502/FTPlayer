import Foundation

/// One player's cache lifetime. Stop closes workers and retains bytes for replay.
/// A changed URL or player deinit closes all workers before unlinking files.
final class FTPlaybackCacheSession {
    private final class WeakWorker {
        weak var value: CacheWorker?
        init(_ value: CacheWorker) { self.value = value }
    }
    private static let processID = UUID().uuidString
    private static let processDirectory: URL = {
        let root = CacheStore.cacheDirectory
        do { return try prepareProcessDirectory(root: root, processID: processID) }
        catch {
            Console.log(type: .ERROR, "[CacheSession] startup cleanup failed: \(error)")
            return root.appendingPathComponent("sessions/\(processID)")
        }
    }()
    static func prepareProcessDirectory(root: URL, processID: String) throws -> URL {
        let fm = FileManager.default, sessions = root.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        // Old releases used persistent URL-keyed cache. It must not be imported.
        for name in ["videos", "index"] {
            let legacy = root.appendingPathComponent(name)
            if fm.fileExists(atPath: legacy.path) { try fm.removeItem(at: legacy) }
        }
        let current = sessions.appendingPathComponent(processID)
        for old in try fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil) where old.standardizedFileURL.path != current.standardizedFileURL.path {
            try fm.removeItem(at: old)
        }
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }
    let directory: URL
    private let lock = NSLock()
    private var workers: [WeakWorker] = []
    private var closed = false
    private var revision = 0
    private var playbackRate: Float = FTPlayerSDKConfiguration.Playback.defaultRate
    func setPlaybackRate(_ rate: Float) {
        guard rate.isFinite, (FTPlayerSDKConfiguration.Playback.minimumRate...FTPlayerSDKConfiguration.Playback.maximumRate).contains(rate) else { return }
        lock.lock()
        guard !closed else { lock.unlock(); return }
        playbackRate = rate
        let live = workers.compactMap { $0.value }
        lock.unlock()
        live.forEach { $0.setPlaybackRate(rate) }
    }
    var currentRevision: Int { lock.withLock { revision } }
    var isClosed: Bool { lock.withLock { closed } }
    init() throws {
        directory = Self.processDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Console.log("[CacheSession] begin directory=\(directory.path)")
    }
    func makeWorker(videoURL: URL, revision expected: Int? = nil, knownFileSize: Int64? = nil, initialReadAheadBytes: Int64? = nil, onPreparationState: ((FTPlayerPreparationState) -> Void)? = nil, resourceRange: CachedRange? = nil) throws -> CacheWorker {
        try lock.withLock {
            guard !closed, expected == nil || expected == revision else {
                throw NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "Playback cache session has ended"])
            }
            if let range = resourceRange {
                guard range.start >= 0, range.end >= range.start, range.end < Int64.max else { throw URLError(.badServerResponse) }
            }
            let store = try CacheStore(videoURL: videoURL, directory: directory, resourceRange: resourceRange)
            let size = resourceRange.map { $0.end - $0.start + 1 } ?? knownFileSize
            if let size, size > 0, store.totalFileSize() <= 0 { store.setTotalFileSize(size) }
            let rangeLoader = resourceRange.map { HTTPByteRangeLoader(url: videoURL, range: $0) }
            let worker = CacheWorker(videoURL: videoURL, cacheStore: store, playbackRate: playbackRate, initialReadAheadBytes: initialReadAheadBytes, loader: rangeLoader, onPreparationState: onPreparationState, resourceRange: resourceRange)
            workers.removeAll { $0.value == nil }
            workers.append(WeakWorker(worker))
            return worker
        }
    }
    @discardableResult
    func suspendWorkers() -> Double? {
        lock.lock()
        revision += 1
        let live = workers.compactMap { $0.value }; workers.removeAll()
        lock.unlock()
        live.forEach { $0.close() }
        Console.log("[CacheSession] stop retained directory=\(directory.path) workers=\(live.count)")
        return live.last?.cachedFraction
    }
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let live = workers.compactMap { $0.value }; workers.removeAll()
        lock.unlock()
        // Invalidate URLSession callbacks and drain queued disk writes before removal.
        live.forEach { $0.close() }
        do {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            Console.log("[CacheSession] removed directory=\(directory.path) workers=\(live.count)")
        } catch { Console.log(type: .ERROR, "[CacheSession] remove failed directory=\(directory.path) error=\(error)") }
    }
    deinit { close() }
}
