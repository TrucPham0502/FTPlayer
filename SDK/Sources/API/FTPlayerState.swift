import Foundation

/// Actual source-opening milestones. HTTP Range states apply only to the custom
/// HTTP cache path; native FFmpeg protocols report connectingToSource/sourceOpened.
/// File input, warm cache and missing audio/video tracks skip inapplicable states.
public enum FTPlayerPreparationState: String, CaseIterable {
    case idle
    case begin
    case validatingSource
    case sourceValidated
    case preparingCache
    case cachePrepared
    case configuringAudioOutput
    case audioOutputConfigured
    case allocatingFormatContext
    case formatContextAllocated
    case connectingToSource
    case requestingHTTPRange
    case httpHeadersReceived
    case receivingInitialData
    case sourceOpened
    case readingStreamInfo
    case streamInfoRead
    case readingMetadata
    case metadataRead
    case selectingTracks
    case tracksSelected
    case openingVideoCodec
    case videoCodecOpened
    case readingVideoParameters
    case videoParametersRead
    case openingAudioCodec
    case audioCodecOpened
    case readingAudioParameters
    case audioParametersRead
    case indexingCache
    case cacheIndexed
    case creatingVideoDecoder
    case videoDecoderCreated
    case creatingAudioDecoder
    case audioDecoderCreated
    case creatingClock
    case clockCreated
    case readingMediaInfo
    case mediaInfoRead
    case publishingMediaInfo
    case mediaInfoPublished
    case readyToDecode
    case readingPackets
    case firstPacketRead
    case decodingFirstFrame
    case firstFrameDecoded
    case waitingForFirstFrame
    case end
    case stopped
    case failed
}

public enum FTPlayerState: Int {
    case none // normal
    case buffering // virtual reality
    case readyToPlay
    case playing
    case suspend
    case finished
    case failed
}
