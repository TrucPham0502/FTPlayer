import CoreVideo
import Foundation
import Accelerate

/// Receives video frames selected for presentation by the playback clock.
/// Callbacks run on the main queue. Presentation time is in seconds on the media
/// timeline. Retain the pixel buffer to use it after the callback returns.
/// The app owns the consumer; FTPlayer holds it weakly.
public protocol FTPlayerVideoOutput: AnyObject {
    func player(_ player: FTPlayer, didOutput pixelBuffer: CVPixelBuffer,
                presentationTime: TimeInterval)
}

/// Recent cadence of frames selected for presentation, sampled over two wall-clock
/// seconds, plus the cadence of the video packets just ahead of the output.
/// These measurements do not inspect pixel changes or GPU scanout.
public struct FTVideoFrameRateStatistics {
    /// Frames per media-timeline second, calculated from output PTS intervals.
    /// Nil until two frames are available. Frame dropping can lower this value
    /// below the encoded frame rate; identical pictures still count as frames.
    public let timelineFramesPerSecond: Double?
    /// Frames per elapsed wall-clock second. Reflects playback speed and stalls;
    /// zero when no recent frames are available or playback is paused/stopped.
    public let outputFramesPerSecond: Double
    public let sampleFrameCount: Int
    /// Frames per media second in the demuxed video packets from the last output frame
    /// to `FTPlayerSDKConfiguration.Playback.upcomingFrameRateWindow` seconds later.
    /// Counts packets, so it is the encoded cadence even while high rates drop frames.
    /// Nil until that span is demuxed (or the file ends there) or after a seek/flush.
    public let upcomingTimelineFramesPerSecond: Double?
}

// Owned by FTPlayer's main queue; never called from the decoder/audio thread.
struct VideoFrameRateMeter {
    private var samples: [(pts: TimeInterval, wall: TimeInterval)] = []
    private var firstFrameWall: TimeInterval?
    private let window: TimeInterval = 2

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        firstFrameWall = nil
    }

    mutating func record(pts: TimeInterval, wall: TimeInterval) {
        guard pts.isFinite, wall.isFinite else { return }
        if let last = samples.last, pts <= last.pts || wall < last.wall { reset() }
        if firstFrameWall == nil { firstFrameWall = wall }
        samples.removeAll { $0.wall < wall - window }
        samples.append((pts, wall))
    }

    func snapshot(at now: TimeInterval, upcoming: Double? = nil) -> FTVideoFrameRateStatistics {
        let recent = samples.filter { $0.wall >= now - window && $0.wall <= now }
        let elapsed = firstFrameWall.map { min(window, max(0, now - $0)) } ?? 0
        // Count arrivals in (start, now]. Excluding the initial baseline avoids
        // startup overcounting; a full window stays stable between 1 fps frames.
        let start = now - elapsed
        let arrivals = recent.filter { $0.wall > start }.count
        let outputFPS = elapsed > 0 ? Double(arrivals) / elapsed : 0
        guard recent.count >= 2, let first = recent.first, let last = recent.last else {
            return FTVideoFrameRateStatistics(timelineFramesPerSecond: nil,
                                             outputFramesPerSecond: outputFPS, sampleFrameCount: recent.count,
                                             upcomingTimelineFramesPerSecond: upcoming)
        }
        let intervals = Double(recent.count - 1)
        let mediaSpan = last.pts - first.pts
        return FTVideoFrameRateStatistics(
            timelineFramesPerSecond: mediaSpan > 0 ? intervals / mediaSpan : nil,
            outputFramesPerSecond: outputFPS,
            sampleFrameCount: recent.count,
            upcomingTimelineFramesPerSecond: upcoming)
    }
}

/// Positions of demuxed video packets not yet presented. Written by the demux thread,
/// read on the main queue.
final class VideoPacketTimeline {
    private let lock = NSLock()
    private var positions: [TimeInterval] = [] // Sorted; demux order differs with B-frames.

    func record(_ position: TimeInterval) {
        guard position.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        var index = positions.endIndex
        while index > positions.startIndex, positions[index - 1] > position { index -= 1 }
        positions.insert(position, at: index)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        positions.removeAll(keepingCapacity: true)
    }

    /// True when a packet lies strictly between `start` and `end`, or when nothing is recorded.
    func hasPackets(after start: TimeInterval, before end: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let first = positions.first, first <= start else { return true }
        return positions.contains { $0 > start && $0 < end }
    }

    /// Frames per media second in [position, position + window]; nil until packets reach the
    /// end of the window, unless `reachedEnd` says no more packets will arrive. Positions before
    /// `position` are dropped: playback only moves forward until the next reset. A position past
    /// the recorded packets (e.g. the last frame before a backward seek) drops nothing.
    func framesPerSecond(from position: TimeInterval, window: TimeInterval, reachedEnd: Bool) -> Double? {
        guard position.isFinite else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let last = positions.last, position <= last else { return nil }
        positions.removeSubrange(..<(positions.firstIndex { $0 >= position } ?? positions.endIndex))
        guard reachedEnd || last >= position + window else { return nil }
        let inWindow = positions.prefix { $0 <= position + window }
        guard inWindow.count >= 2, let first = inWindow.first, let end = inWindow.last, end > first else { return nil }
        return Double(inWindow.count - 1) / (end - first)
    }
}

// Main-queue state deciding when a measurement is reported to the app.
struct VideoStatisticsChangeGate {
    private let interval: TimeInterval
    init(interval: TimeInterval = FTPlayerSDKConfiguration.Playback.videoStatisticsNotificationInterval) {
        self.interval = interval
    }
    private var lastCheck: TimeInterval?
    private var delivered: [Double?]? // nil until values have been delivered.
    mutating func reset() {
        lastCheck = nil
        delivered = nil
    }
    /// True when `values` should be delivered at `now`: at most once per interval, and only
    /// when any value changed. Above 1× the interval shrinks so a check covers the same media time.
    mutating func shouldDeliver(_ values: Double?..., at now: TimeInterval, rate: Float = 1) -> Bool {
        if let lastCheck, now - lastCheck < interval / max(1, Double(rate)) { return false }
        lastCheck = now
        if let delivered, delivered == values { return false }
        delivered = values
        return true
    }
}

/// Approximate picture changes among frames selected for output. This is not the
/// camera's capture FPS or an AOV detector; static scenes can report zero.
public struct FTVideoContentChangeStatistics {
    /// Significant thumbnail changes per media-timeline second, over up to four
    /// seconds. Nil while disabled, unsupported, idle, or before one second of samples.
    public let estimatedChangesPerSecond: Double?
    public let sampleDuration: TimeInterval
}

// Thumbnail luma differences suppress small compression changes. NV12 and planar
// 8-bit YUV cover the SDK's software and VideoToolbox outputs. Other formats are
// reported unavailable rather than treating their bytes as luma.
struct VideoContentChangeMeter {
    private let width = 160, height = 90
    private let window: TimeInterval = 4
    private let threshold = 0.05 // Mean absolute luma difference on the 0...255 scale.
    private var previous: [UInt8]?
    private var sourceSize: (width: Int, height: Int)?
    private var sourceFormat: OSType?
    private var firstPTS: TimeInterval?
    private var lastPTS: TimeInterval?
    private var lastWall: TimeInterval?
    private var changes: [TimeInterval] = []

    mutating func reset() { self = VideoContentChangeMeter() }

    mutating func record(_ pixel: CVPixelBuffer, pts: TimeInterval, wall: TimeInterval) {
        guard pts.isFinite, wall.isFinite else { return }
        let format = CVPixelBufferGetPixelFormatType(pixel)
        guard [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
               kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
               kCVPixelFormatType_420YpCbCr8Planar,
               kCVPixelFormatType_420YpCbCr8PlanarFullRange].contains(format),
              CVPixelBufferGetPlaneCount(pixel) > 0,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
            reset(); return
        }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let sourceWidth = CVPixelBufferGetWidthOfPlane(pixel, 0)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(pixel, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0), sourceWidth > 0, sourceHeight > 0 else {
            reset(); return
        }
        if let lastPTS, pts <= lastPTS { reset() }
        if let lastWall, wall < lastWall || wall - lastWall > 2 { reset() }
        if let sourceSize, sourceSize.width != sourceWidth || sourceSize.height != sourceHeight { reset() }
        if let sourceFormat, sourceFormat != format { reset() }
        var source = vImage_Buffer(data: base, height: vImagePixelCount(sourceHeight),
                                   width: vImagePixelCount(sourceWidth), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixel, 0))
        var thumbnail = [UInt8](repeating: 0, count: width * height)
        let result = thumbnail.withUnsafeMutableBytes { bytes -> vImage_Error in
            var destination = vImage_Buffer(data: bytes.baseAddress!, height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: width)
            return vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
        }
        guard result == kvImageNoError else { reset(); return }
        if let previous {
            var difference = 0
            for index in thumbnail.indices { difference += abs(Int(thumbnail[index]) - Int(previous[index])) }
            if Double(difference) / Double(thumbnail.count) > threshold { changes.append(pts) }
        }
        if firstPTS == nil { firstPTS = pts }
        previous = thumbnail
        sourceSize = (sourceWidth, sourceHeight)
        sourceFormat = format
        lastPTS = pts; lastWall = wall
        changes.removeAll { $0 <= pts - window }
    }

    func snapshot(at now: TimeInterval) -> FTVideoContentChangeStatistics {
        guard let firstPTS, let lastPTS, let lastWall, now >= lastWall, now - lastWall <= 2 else {
            return FTVideoContentChangeStatistics(estimatedChangesPerSecond: nil, sampleDuration: 0)
        }
        let elapsed = min(window, lastPTS - firstPTS)
        return FTVideoContentChangeStatistics(
            estimatedChangesPerSecond: elapsed >= 1 ? Double(changes.count) / elapsed : nil,
            sampleDuration: elapsed)
    }
}
