import Foundation

struct CacheTimelineSample {
    let offset: Int64
    let size: Int64
    let start: Double
    let end: Double
    let keyframe: Bool
}

struct CacheTrackTimeline {
    let samples: [CacheTimelineSample]
    let requiresKeyframe: Bool

    func cachedTimes(in bytes: [CachedRange]) -> [FTPlayerCachedTimeRange] {
        var result: [FTPlayerCachedTimeRange] = []
        var referenceChain = false
        for sample in samples {
            let cached = bytes.contains { $0.start <= sample.offset && $0.end >= sample.offset + sample.size - 1 }
            if !requiresKeyframe || sample.keyframe { referenceChain = cached }
            else { referenceChain = referenceChain && cached }
            guard referenceChain, sample.end > sample.start else { continue }
            if let last = result.last, sample.start <= last.end + FTPlayerSDKConfiguration.Precision.cacheRangeMergeTolerance {
                result[result.count - 1] = FTPlayerCachedTimeRange(start: last.start, end: max(last.end, sample.end))
            } else { result.append(FTPlayerCachedTimeRange(start: sample.start, end: sample.end)) }
        }
        return result
    }
}

struct CacheTimelineIndex {
    let tracks: [CacheTrackTimeline]
    let duration: Double
    // Include the preceding random-access packet and all selected tracks. The
    // byte envelope follows the actual index (including VBR), not file fraction.
    func byteWindow(position: Double, duration seconds: Double) -> CachedRange? {
        guard position.isFinite, seconds.isFinite, position >= 0, seconds > 0, !tracks.isEmpty else { return nil }
        let endTime = min(duration,position+seconds)
        var lower = Int64.max, upper: Int64 = -1
        for track in tracks {
            let samples = track.samples
            guard !samples.isEmpty else { return nil }
            var low = 0, high = samples.count
            while low < high {
                let mid = (low+high)/2
                if samples[mid].end <= position { low = mid+1 } else { high = mid }
            }
            guard low < samples.count else { continue }
            var first = low
            if track.requiresKeyframe { while first > 0 && !samples[first].keyframe { first -= 1 } }
            var i = first
            while i < samples.count && samples[i].start < endTime {
                let sample = samples[i]
                lower = min(lower,sample.offset); upper = max(upper,sample.offset+sample.size-1); i += 1
            }
        }
        return lower <= upper ? CachedRange(start:lower,end:upper) : nil
    }
    func ranges(in bytes: [CachedRange], fileSize: Int64) -> [FTPlayerCachedTimeRange] {
        guard duration.isFinite, duration > 0, !bytes.isEmpty else { return [] }
        if fileSize > 0, bytes.contains(where: { $0.start == 0 && $0.end >= fileSize - 1 }) {
            return [FTPlayerCachedTimeRange(start: 0, end: duration)]
        }
        guard let first = tracks.first else { return [] }
        var result = first.cachedTimes(in: bytes)
        // Both selected audio and video must be cached for offline playback.
        for track in tracks.dropFirst() {
            let other = track.cachedTimes(in: bytes)
            var intersect: [FTPlayerCachedTimeRange] = []
            var i = 0, j = 0
            while i < result.count && j < other.count {
                let start = max(result[i].start, other[j].start)
                let end = min(result[i].end, other[j].end)
                if end > start { intersect.append(FTPlayerCachedTimeRange(start: start, end: end)) }
                if result[i].end < other[j].end { i += 1 } else { j += 1 }
            }
            result = intersect
        }
        return result
    }
}
