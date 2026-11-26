import Foundation

/// Snapshot of the selected streams. Unknown values are nil; bitrates are bits/second.
public struct FTPlayerMediaInfo {
    public let sourceURL: URL
    public let formatName: String
    public let duration: TimeInterval?
    public let bitrate: Int64?
    public let videoCodec: String?
    public let width: Int?
    public let height: Int?
    public let framesPerSecond: Double?
    public let videoBitrate: Int64?
    public let audioCodec: String?
    public let audioSampleRate: Int?
    public let audioChannels: Int?
    public let audioBitrate: Int64?
    public let videoTrackCount: Int
    public let audioTrackCount: Int
}
