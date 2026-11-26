import Foundation

/// Streaming load thresholds follow Media3 DefaultLoadControl's time/size rules.
/// Durations are media seconds; the minimum scales with rate up to the maximum.
/// Disk cache already retained behind the playhead is not counted toward this target.
public struct FTPlayerLoadControlConfiguration: Equatable {
    public let minimumBufferDuration: TimeInterval
    public let maximumBufferDuration: TimeInterval
    public let targetBufferBytes: Int64?
    public let prioritizesTimeOverSize: Bool
    public init(minimumBufferDuration: TimeInterval = FTPlayerSDKConfiguration.LoadControl.minimumBufferDuration, maximumBufferDuration: TimeInterval = FTPlayerSDKConfiguration.LoadControl.maximumBufferDuration,
                targetBufferBytes: Int64? = nil, prioritizesTimeOverSize: Bool = FTPlayerSDKConfiguration.LoadControl.prioritizesTimeOverSize) {
        // Match the representable millisecond range of Media3's configuration.
        let limit = Double(Int32.max)/1000
        let low = minimumBufferDuration.isFinite ? min(limit,max(FTPlayerSDKConfiguration.LoadControl.minimumAllowedBufferDuration,minimumBufferDuration)) : FTPlayerSDKConfiguration.LoadControl.minimumBufferDuration
        self.minimumBufferDuration = low
        self.maximumBufferDuration = maximumBufferDuration.isFinite ? min(limit,max(low,maximumBufferDuration)) : max(low,FTPlayerSDKConfiguration.LoadControl.maximumBufferDuration)
        self.targetBufferBytes = targetBufferBytes.map { max(1,$0) }
        self.prioritizesTimeOverSize = prioritizesTimeOverSize
    }
    func targetBytes(video: Bool, audio: Bool) -> Int64 {
        // Media3's video/audio allocation targets: 2000/200 blocks of 64 KiB.
        if let targetBufferBytes { return targetBufferBytes }
        let videoBytes: Int64 = video ? FTPlayerSDKConfiguration.LoadControl.videoTargetBytes : 0
        let audioBytes: Int64 = audio ? FTPlayerSDKConfiguration.LoadControl.audioTargetBytes : 0
        return max(FTPlayerSDKConfiguration.LoadControl.audioTargetBytes,videoBytes+audioBytes)
    }
    func minimumDuration(rate: Float) -> Double {
        min(maximumBufferDuration,minimumBufferDuration*max(1,Double(rate.isFinite ? rate : 1)))
    }
}
