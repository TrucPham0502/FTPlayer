import Foundation
import AVFoundation

// MARK: - FTAudioMasterClock

/// Audio-master clock: interpolates between CoreAudio callbacks (~10ms) for smooth reads.
/// currentTime = lastAudioPTS + wallElapsed × rate - totalOutputLatency(rate)
final class FTAudioMasterClock: FTPlaybackClock {

    private var _lastAudioPTS: TimeInterval = 0
    private var _lastAudioWallTime: TimeInterval
    private var _rate: Float
    private var _isPaused: Bool = false
    private var hasAudioAnchor = false
    private let wallTime: () -> TimeInterval
    private let lock = NSLock()

    init(rate: Float = FTPlayerSDKConfiguration.Playback.defaultRate,
         wallTime: @escaping () -> TimeInterval = CACurrentMediaTime) {
        _rate = rate
        self.wallTime = wallTime
        _lastAudioWallTime = wallTime()
    }

    var currentTime: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        if _isPaused {
            return _lastAudioPTS - totalOutputLatency(_rate)
        }
        let wallElapsed = wallTime() - _lastAudioWallTime
        let interpolated = _lastAudioPTS + wallElapsed * Double(_rate)
        return interpolated - totalOutputLatency(_rate)
    }

    // PCM scheduling precedes output latency compensation. Use this timeline
    // to wait through missing audio instead of submitting a future PTS early.
    var consumptionTime: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return _lastAudioPTS + (_isPaused ? 0 : wallTime() - _lastAudioWallTime) * Double(_rate)
    }

    var rateDiagnosticFields: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let elapsed = _isPaused ? 0 : wallTime() - _lastAudioWallTime
        let consumption = _lastAudioPTS + elapsed * Double(_rate)
        let latency = totalOutputLatency(_rate)
        return ["kind": "audio", "rate": _rate, "paused": _isPaused,
            "anchorPTS": _lastAudioPTS, "anchorWallTime": _lastAudioWallTime,
            "wallSinceAnchor": elapsed, "consumptionTime": consumption,
            "outputLatencyCompensation": latency, "currentTime": consumption - latency]
    }

    /// Call from fetchAudioFrame() — must be called with the new PTS and current wall time atomically.
    func update(pts: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _lastAudioPTS = pts
        _lastAudioWallTime = wallTime()
        hasAudioAnchor = false
    }

    /// Follow audio PTS without turning timestamp jitter into video clock jumps.
    /// Explicit seeks still use update(pts:) and take effect immediately.
    func updateFromAudio(pts: TimeInterval, frameDuration: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let now = wallTime()
        let elapsed = max(0, now - _lastAudioWallTime) * Double(_rate)
        let predicted = _lastAudioPTS + (_isPaused ? 0 : elapsed)
        let error = pts - predicted
        let discontinuity = max(FTPlayerSDKConfiguration.Playback.minimumAudioGap,
                                frameDuration * FTPlayerSDKConfiguration.Playback.audioGapDurationMultiplier)
        if hasAudioAnchor, !_isPaused, abs(error) < discontinuity {
            // Bound phase correction by elapsed media time so frequent callbacks
            // cannot accumulate arbitrary jumps. Catch up at at most 5% speed.
            let correction = elapsed * FTPlayerSDKConfiguration.Playback.audioClockCorrectionFraction
            _lastAudioPTS = predicted + min(correction, max(-correction, error))
        } else {
            _lastAudioPTS = pts
        }
        _lastAudioWallTime = now
        hasAudioAnchor = true
    }

    func updateRate(_ newRate: Float) {
        lock.lock(); defer { lock.unlock() }
        if !_isPaused {
            let now = wallTime()
            _lastAudioPTS += (now - _lastAudioWallTime) * Double(_rate)
            _lastAudioWallTime = now
        }
        _rate = newRate
    }

    func setPaused(_ paused: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard paused != _isPaused else { return }
        let now = wallTime()
        if paused { _lastAudioPTS += (now - _lastAudioWallTime) * Double(_rate) }
        _lastAudioWallTime = now
        _isPaused = paused
    }

    func resetInterpolation() {
        lock.lock(); defer { lock.unlock() }
        _lastAudioWallTime = wallTime()
        hasAudioAnchor = false
    }

    func setRate(_ rate: Float) { updateRate(rate) }

    func seek(to time: TimeInterval) { update(pts: time) }

    // MARK: - Latency

    private func totalOutputLatency(_ rate: Float) -> TimeInterval {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return session.outputLatency + session.ioBufferDuration + timePitchLatency(rate)
        #else
        return FTPlayerSDKConfiguration.Audio.desktopOutputLatency + FTPlayerSDKConfiguration.Audio.desktopIOBufferDuration + timePitchLatency(rate)
        #endif
    }

    /// Estimated NewTimePitch processing latency per rate band.
    /// These are empirical estimates — measure per device to tune.
    private func timePitchLatency(_ rate: Float) -> TimeInterval {
        switch rate {
        case ..<FTPlayerSDKConfiguration.Audio.timePitchLatencyBelow2.upperBound:
            return FTPlayerSDKConfiguration.Audio.timePitchLatencyBelow2.seconds
        case ..<FTPlayerSDKConfiguration.Audio.timePitchLatencyBelow4.upperBound:
            return FTPlayerSDKConfiguration.Audio.timePitchLatencyBelow4.seconds
        case ..<FTPlayerSDKConfiguration.Audio.timePitchLatencyBelow8.upperBound:
            return FTPlayerSDKConfiguration.Audio.timePitchLatencyBelow8.seconds
        case ..<FTPlayerSDKConfiguration.Audio.timePitchLatencyBelow12.upperBound:
            return FTPlayerSDKConfiguration.Audio.timePitchLatencyBelow12.seconds
        case ..<FTPlayerSDKConfiguration.Audio.timePitchLatencyBelow16.upperBound:
            return FTPlayerSDKConfiguration.Audio.timePitchLatencyBelow16.seconds
        default:
            return FTPlayerSDKConfiguration.Audio.maximumTimePitchLatency
        }
    }

    deinit {
    }
}
