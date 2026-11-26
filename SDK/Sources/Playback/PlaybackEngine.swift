import Foundation
import CoreGraphics

enum FTVideoFormat {
    case error
    case unknown
    case mpeg4
    case flv
    case m3u8
    case rtmp
    case rtsp
}
protocol FTDecoderDelegate: AnyObject {
    func decoderWillOpenInputStream(_ decoder: any PlaybackEngine)
    func decoderDidPrepareToDecodeFrames(_ decoder: any PlaybackEngine)
    func decoderDidEndOfFile(_ decoder: any PlaybackEngine)
    func decoderDidPlaybackFinished(_ decoder: any PlaybackEngine)
    func decoder(_ decoder: any PlaybackEngine, didError error: Error)
    func decoder(_ decoder: any PlaybackEngine, didChangeValueOfBuffering buffering: Bool)
    func decoder(_ decoder: any PlaybackEngine, didChangeValueOfBufferedDuration bufferedDuration: TimeInterval)
    func decoder(_ decoder: any PlaybackEngine, didChangeValueOfProgress progress: TimeInterval)
    func decoder(_ decoder: any PlaybackEngine, didUpdateDownloadProgress fraction: Double)
    func decoder(_ decoder: any PlaybackEngine, didChangePreparationState state: FTPlayerPreparationState)
}

extension FTDecoderDelegate {
    func decoder(_ decoder: any PlaybackEngine, didChangePreparationState state: FTPlayerPreparationState) {}
    func decoder(_ decoder: any PlaybackEngine, didUpdateDownloadProgress fraction: Double) {}
}

protocol FTDecoderVideoOutput: AnyObject {
    func send(video frame: FTVideoFrame, from decoder: any PlaybackEngine)
}

protocol FTDecoderAudioOutput: AnyObject {
    var numberOfChannels: UInt32 { get }
    var samplingRate: Float64 { get }
}

protocol PlaybackEngineControl: AnyObject {
    var delegate: FTDecoderDelegate? { get set }
    var useCache: Bool { get set }
    var loadControlConfiguration: FTPlayerLoadControlConfiguration { get set }
    var cacheSession: (any PlaybackCacheSession)? { get set }
    var cacheSessionRevision: Int? { get set }
    var videoDecodingPolicy: FTVideoDecodingPolicy { get set }
    var playbackRate: Float { get set }
    var minBufferedDuration: TimeInterval { get set }
    func open()
    func resume()
    func pause()
    func closeFile()
    func closeFileWithCompletion(_ completion: @escaping () -> Void)
    func seek(to time: TimeInterval, completeHandler: ((Bool) -> Void)?)
}

protocol PlaybackEngineStatus: AnyObject {
    var duration: TimeInterval { get }
    var presentationSize: CGSize { get }
    var bitrate: TimeInterval { get }
    var mediaInfo: FTPlayerMediaInfo? { get }
    var prepareToDecode: Bool { get }
    var buffering: Bool { get }
    var playbackFinished: Bool { get }
    var videoEnable: Bool { get }
    var audioEnable: Bool { get }
    var seekEnable: Bool { get }
    var cachedTimeRanges: [FTPlayerCachedTimeRange] { get }
    var cachedFraction: Double { get }
    var cacheProgress: FTPlayerCacheProgress { get }
    var decodingStatistics: FTVideoDecodingStatistics? { get }
    var diagnosticSnapshot: String { get }
    var rateDiagnosticFields: [String: Any] { get }
    /// Frames per media second in demuxed video packets over [position, position + window].
    func upcomingVideoFrameRate(from position: TimeInterval, window: TimeInterval) -> Double?
}

protocol PlaybackEngine: PlaybackEngineControl, PlaybackEngineStatus, FTAudioFrameSource {}
extension PlaybackEngineStatus {
    var seekEnable: Bool { true }
    func upcomingVideoFrameRate(from position: TimeInterval, window: TimeInterval) -> Double? { nil }
    var rateDiagnosticFields: [String: Any] { ["snapshot": diagnosticSnapshot] }
    var cacheProgress: FTPlayerCacheProgress {
        FTPlayerCacheProgress(cachedBytes: 0, totalBytes: nil, fraction: cachedFraction > 0 ? cachedFraction : nil)
    }
}
extension FTDecoder: PlaybackEngine {}
