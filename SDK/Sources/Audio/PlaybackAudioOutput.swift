import Foundation

protocol PlaybackAudioOutput: AnyObject {
    var volume: Float { get set }
    var playbackRate: Float { get set }
    var playing: Bool { get }
    var numberOfChannels: UInt32 { get }
    var samplingRate: Float64 { get }
    func rateDiagnosticFields(includeFormats: Bool) -> [String: Any]
    func registerAudioSession() -> Bool
    func setEventHandlers(interruption: @escaping (FTAudioManagerInterruptionType, FTAudioManagerInterruptionOption) -> Void,
                          routeChange: @escaping (FTAudioManagerRouteChangeReason) -> Void)
    func play()
    func pause()
    /// Drain native rendering before publishing a new source timeline.
    func performSeek(_ request: () -> Void)
    func destroy()
}

extension FTAudioManager: PlaybackAudioOutput {}
extension PlaybackAudioOutput {
    func performSeek(_ request: () -> Void) { request() }
    func rateDiagnosticFields(includeFormats: Bool) -> [String: Any] {
        ["reportedRate": playbackRate, "playing": playing, "sampleRate": samplingRate]
    }
}

/// Decoder format reads never synchronously wait for the UI or audio graph.
final class PlaybackAudioFormat: FTDecoderAudioOutput {
    private let lock = NSLock()
    private var channels: UInt32 = 0
    private var rate: Float64 = 0
    var numberOfChannels: UInt32 { lock.withLock { channels } }
    var samplingRate: Float64 { lock.withLock { rate } }
    func update(channels: UInt32, rate: Float64) {
        lock.withLock { self.channels = channels; self.rate = rate }
    }
}
