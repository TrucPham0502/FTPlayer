import Foundation

/// Media time interval whose packets are present in the disk cache. Video intervals
/// start from a cached keyframe; gaps are preserved rather than filling from zero.
public struct FTPlayerCachedTimeRange: Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public init(start: TimeInterval, end: TimeInterval) { self.start = start; self.end = end }
}
