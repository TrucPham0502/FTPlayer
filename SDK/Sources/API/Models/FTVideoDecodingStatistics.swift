import Foundation

public struct FTVideoDecodingStatistics {
    public let policy: FTVideoDecodingPolicy
    public let ffmpegFrames: Int
    public let hardwareFrames: Int
    public let videoToolboxSoftwareFrames: Int
    public let videoToolboxUnverifiedFrames: Int
}
