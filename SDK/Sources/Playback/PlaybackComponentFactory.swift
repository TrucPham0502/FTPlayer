import Foundation

/// Composition boundary: the public facade coordinates components without
/// owning their concrete construction. Tests can supply alternative factories.
protocol PlaybackComponentFactory {
    func makeDecoder(contentURL: URL, videoFormat: FTVideoFormat,
                     videoOutput: FTDecoderVideoOutput, audioOutput: FTDecoderAudioOutput) -> any PlaybackEngine
    func makeAudioOutput(source: any FTAudioFrameSource) -> any PlaybackAudioOutput
    func makeCacheSession() throws -> any PlaybackCacheSession
}

struct DefaultPlaybackComponentFactory: PlaybackComponentFactory {
    func makeDecoder(contentURL: URL, videoFormat: FTVideoFormat,
                     videoOutput: FTDecoderVideoOutput, audioOutput: FTDecoderAudioOutput) -> any PlaybackEngine {
        FTDecoder(contentURL: contentURL, videoFormat: videoFormat,
                  videoOutput: videoOutput, audioOutput: audioOutput)
    }

    func makeAudioOutput(source: any FTAudioFrameSource) -> any PlaybackAudioOutput {
        FTAudioManager(decoder: source)
    }

    func makeCacheSession() throws -> any PlaybackCacheSession {
        try FTPlaybackCacheSession()
    }
}
