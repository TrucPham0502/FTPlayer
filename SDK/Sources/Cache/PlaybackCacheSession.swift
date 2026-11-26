import Foundation

struct CacheWorkerRequest {
    let videoURL: URL
    var revision: Int?
    var knownFileSize: Int64?
    var initialReadAheadBytes: Int64?
    var onPreparationState: ((FTPlayerPreparationState) -> Void)?
    var resourceRange: CachedRange? = nil
}

protocol PlaybackCacheSession: AnyObject {
    var directory: URL { get }
    var currentRevision: Int { get }
    var isClosed: Bool { get }
    func setPlaybackRate(_ rate: Float)
    func makeWorker(_ request: CacheWorkerRequest) throws -> CacheWorker
    @discardableResult func suspendWorkers() -> Double?
    func close()
}

extension PlaybackCacheSession {
    func makeWorker(videoURL: URL, revision: Int? = nil, knownFileSize: Int64? = nil,
                    initialReadAheadBytes: Int64? = nil,
                    onPreparationState: ((FTPlayerPreparationState) -> Void)? = nil,
                    resourceRange: CachedRange? = nil) throws -> CacheWorker {
        try makeWorker(CacheWorkerRequest(videoURL: videoURL, revision: revision,
            knownFileSize: knownFileSize, initialReadAheadBytes: initialReadAheadBytes,
            onPreparationState: onPreparationState, resourceRange: resourceRange))
    }
}
extension FTPlaybackCacheSession: PlaybackCacheSession {
    func makeWorker(_ request: CacheWorkerRequest) throws -> CacheWorker {
        try makeWorker(videoURL: request.videoURL, revision: request.revision,
                       knownFileSize: request.knownFileSize, initialReadAheadBytes: request.initialReadAheadBytes,
                       onPreparationState: request.onPreparationState, resourceRange: request.resourceRange)
    }
}
