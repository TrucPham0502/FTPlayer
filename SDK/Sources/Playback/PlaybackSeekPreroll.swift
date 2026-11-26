import Foundation

/// Tracks the first usable audio/video output for a seek epoch. Decode may need
/// earlier reference packets, but those packets must not advance presentation.
final class PlaybackSeekPreroll {
    struct Target: Equatable {
        let time: TimeInterval
        let epoch: Int
    }
    private let lock = NSLock()
    private var epoch = 0
    private var audio: Target?
    private var video: Target?

    var audioTarget: Target? { lock.withLock { audio } }
    var videoTarget: Target? { lock.withLock { video } }

    func begin(time: TimeInterval, hasAudio: Bool, hasVideo: Bool) {
        lock.withLock {
            epoch += 1
            let target = Target(time: time, epoch: epoch)
            audio = hasAudio ? target : nil
            video = hasVideo ? target : nil
        }
    }

    static func isBeforeTarget(position: TimeInterval, duration: TimeInterval, target: Target) -> Bool {
        position + max(0, duration) < target.time - FTPlayerSDKConfiguration.Precision.seekPrerollTolerance
    }

    func finishAudio(_ target: Target) {
        lock.withLock { if audio == target { audio = nil } }
    }

    func finishVideo(_ target: Target) {
        lock.withLock { if video == target { video = nil } }
    }

    func reset() {
        lock.withLock { epoch += 1; audio = nil; video = nil }
    }
}

/// Buffering expires after a period without progress, rather than after the
/// total wall time spent decoding a long seek preroll.
final class PlaybackBufferingWatchdog {
    private let lock = NSLock()
    private var stalledSince: TimeInterval?
    private var epoch: Int?
    private var position: TimeInterval?

    func begin(at now: TimeInterval) {
        lock.withLock { stalledSince = now; epoch = nil; position = nil }
    }

    func hasTimedOut(at now: TimeInterval, timeout: TimeInterval, waitingForNetwork: Bool,
                     prerollEpoch: Int?, prerollPosition: TimeInterval?) -> Bool {
        lock.withLock {
            if stalledSince == nil { stalledSince = now }
            if epoch != prerollEpoch {
                epoch = prerollEpoch; position = nil
                if prerollEpoch != nil { stalledSince = now }
            }
            if prerollEpoch != nil, let next = prerollPosition, next.isFinite,
               position == nil || next > position! + FTPlayerSDKConfiguration.Precision.timestampEpsilon {
                position = next; stalledSince = now
            }
            if waitingForNetwork { stalledSince = now }
            return timeout > 0 && now - stalledSince! >= timeout
        }
    }
}
