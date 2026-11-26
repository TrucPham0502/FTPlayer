import Foundation

/// Called on the audio render thread. Implementations must never wait for frames.
protocol FTAudioFrameSource: AnyObject {
    func fetchAudioFrame() -> FTAudioFrame?
}
