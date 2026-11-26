import Foundation
import QuartzCore

// MARK: - FTSystemMasterClock

/// System-master clock for video-only playback.
/// currentTime = baseMediaTime + (CACurrentMediaTime() - baseWallTime) × rate
final class FTSystemMasterClock: FTPlaybackClock {

    private var _baseMediaTime: TimeInterval
    private var _baseWallTime: TimeInterval
    private var _rate: Float
    private var _isPaused: Bool = false
    private var _pauseWallTime: TimeInterval = 0
    private let lock = NSLock()

    init(startTime: TimeInterval = 0, rate: Float = FTPlayerSDKConfiguration.Playback.defaultRate) {
        _baseMediaTime = startTime
        _baseWallTime = CACurrentMediaTime()
        _rate = rate
    }

    var currentTime: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard !_isPaused else { return _baseMediaTime }
        return _baseMediaTime + (CACurrentMediaTime() - _baseWallTime) * Double(_rate)
    }

    var rateDiagnosticFields: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let elapsed = _isPaused ? 0 : CACurrentMediaTime() - _baseWallTime
        return ["kind": "system", "rate": _rate, "paused": _isPaused,
            "anchorPTS": _baseMediaTime, "anchorWallTime": _baseWallTime,
            "wallSinceAnchor": elapsed, "currentTime": _baseMediaTime + elapsed * Double(_rate)]
    }

    /// Rate change with continuity: advances baseMediaTime before switching rate.
    func setRate(_ newRate: Float) {
        lock.lock(); defer { lock.unlock() }
        if _isPaused {
            _rate = newRate
            return
        }
        let now = CACurrentMediaTime()
        _baseMediaTime += (now - _baseWallTime) * Double(_rate)
        _baseWallTime = now
        _rate = newRate
    }

    /// Call after flush — resets clock position to seeked time.
    func seek(to time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _baseMediaTime = time
        _baseWallTime = CACurrentMediaTime()
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        guard !_isPaused else { return }
        let now = CACurrentMediaTime()
        _baseMediaTime += (now - _baseWallTime) * Double(_rate)
        _pauseWallTime = now
        _isPaused = true
    }

    func resume() {
        lock.lock(); defer { lock.unlock() }
        guard _isPaused else { return }
        _baseWallTime = CACurrentMediaTime()
        _isPaused = false
    }

    func setPaused(_ paused: Bool) {
        if paused { pause() } else { resume() }
    }

    func resetInterpolation() {
        lock.lock(); defer { lock.unlock() }
        _baseWallTime = CACurrentMediaTime()
    }

    deinit {
    }
}
