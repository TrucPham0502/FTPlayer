import Foundation
@_implementationOnly import libavcodec
@_implementationOnly import libavformat

// MARK: - C Callbacks (must be free functions for @convention(c))

private func cacheReadPacket(
    _ opaque: UnsafeMutableRawPointer?,
    _ buf: UnsafeMutablePointer<UInt8>?,
    _ bufSize: Int32
) -> Int32 {
    guard let opaque, let buf else { return -1 }
    let worker = Unmanaged<CacheWorker>.fromOpaque(opaque).takeUnretainedValue()
    return worker.readPacket(into: buf, size: bufSize)
}

private func cacheSeek(
    _ opaque: UnsafeMutableRawPointer?,
    _ offset: Int64,
    _ whence: Int32
) -> Int64 {
    guard let opaque else { return -1 }
    let worker = Unmanaged<CacheWorker>.fromOpaque(opaque).takeUnretainedValue()
    return worker.seekPacket(offset: offset, whence: whence)
}

// MARK: - FTCacheIOContext

class FTCacheIOContext {
    private let worker: CacheWorker
    private var avioCtx: UnsafeMutablePointer<AVIOContext>?
    private let bufferSize: Int32 = FTPlayerSDKConfiguration.Demux.avioBufferBytes  // 32KB

    var context: UnsafeMutablePointer<AVIOContext>? { avioCtx }
    var failure: NSError? { worker.failure }
    var diagnosticSnapshot: [String: Int64] { worker.diagnosticSnapshot }
    func beginOpening(timeout: TimeInterval) { worker.beginOpening(timeout: timeout) }
    func finishOpening() { worker.finishOpening() }
    var cachedFraction: Double { worker.cachedFraction }
    var cachedByteRanges: [CachedRange] { worker.cachedByteRanges }
    var isWaitingForNetwork: Bool { worker.isWaitingForNetwork }

    init(worker: CacheWorker) throws {
        self.worker = worker
        worker.waitsForNetwork = true

        guard let buffer = av_malloc(Int(bufferSize)) else {
            throw NSError(domain: "FTCacheIOContext", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "av_malloc failed"])
        }

        let opaque = Unmanaged.passUnretained(worker).toOpaque()
        avioCtx = avio_alloc_context(
            buffer.assumingMemoryBound(to: UInt8.self),
            bufferSize,
            0,          // write_flag = 0 (read-only)
            opaque,
            cacheReadPacket,
            nil,        // write_packet = nil
            cacheSeek
        )

        if avioCtx == nil {
            av_free(buffer)
            throw NSError(domain: "FTCacheIOContext", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "avio_alloc_context failed"])
        }
    }

    func configureLoadControl(_ configuration: FTPlayerLoadControlConfiguration, index: CacheTimelineIndex, bytesPerSecond: Double, video: Bool, audio: Bool) {
        worker.configureLoadControl(configuration,index:index,bytesPerSecond:bytesPerSecond,video:video,audio:audio)
    }
    func setPlaybackPosition(_ value: Double) { worker.setPlaybackPosition(value) }
    func cancelRead() { worker.cancelRead() }
    func resumeRead() { worker.resumeRead() }

    /// Peek through AVIO so its buffered bytes are reused by the demuxer. Keep
    /// the reader at zero; an HTTP endpoint need not have a playlist extension.
    func hasHLSHeader() -> Bool {
        var prefix = [UInt8](repeating: 0, count: 7)
        let count = avio_read(avioCtx, &prefix, Int32(prefix.count))
        let rewound = avio_seek(avioCtx, 0, 0)
        return count == 7 && rewound == 0 && prefix.elementsEqual("#EXTM3U".utf8)
    }

    fileprivate func cachedPlaylist(interrupted: () -> Bool) throws -> HTTPDataResponse? {
        let size = worker.knownFileSize
        guard size > 0, size <= FTPlayerSDKConfiguration.HLS.maximumManifestBytes, let url = worker.responseURL else { return nil }
        var data = Data()
        while data.count < size {
            guard !interrupted() else { throw URLError(.cancelled) }
            guard let part = worker.read(offset: Int64(data.count), length: Int(min(Int64(FTPlayerSDKConfiguration.HLS.resourceReadBytes), size - Int64(data.count)))), !part.isEmpty else {
                throw worker.failure ?? URLError(.cannotLoadFromNetwork) as NSError
            }
            data.append(part)
        }
        return HTTPDataResponse(data: data, url: url)
    }

    func close() {
        guard avioCtx != nil else { return }
        // libavformat may replace the original buffer while probing. The caller
        // owns the current buffer as well as the AVIOContext allocation.
        av_free(avioCtx?.pointee.buffer)
        avioCtx?.pointee.buffer = nil
        avio_context_free(&avioCtx)
        worker.close()
    }

    deinit {
        close()
    }
}

/// Reuse the response that identified HLS, including its final redirect URL.
/// Unknown-length responses and legacy warm entries retain the normal transport.
struct FTCachedPlaylistLoader: HTTPDataLoading {
    let cache: FTCacheIOContext
    let fallback: any HTTPDataLoading
    func load(_ url: URL, timeout: TimeInterval, interrupted: () -> Bool) throws -> HTTPDataResponse {
        if let response = try cache.cachedPlaylist(interrupted: interrupted) { return response }
        return try fallback.load(url, timeout: timeout, interrupted: interrupted)
    }
}
