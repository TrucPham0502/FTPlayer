import Foundation

public protocol FTPlayerPlaybackDelegate: AnyObject {
    func player(_ player: FTPlayer, didChangeState state: FTPlayerState)
    func playerReadyToPlay(_ player: FTPlayer, duration: TimeInterval)
    func playerDidFinish(_ player: FTPlayer)
    func player(_ player: FTPlayer, didFail error: Error)
    func playerBufferingStart(_ player: FTPlayer)
    func playerBufferingEnd(_ player: FTPlayer)
}

public protocol FTPlayerProgressDelegate: AnyObject {
    /// Periodic playback updates are limited to 30 per wall-clock second.
    /// Explicit seek targets and playback completion bypass that rate limit.
    func player(_ player: FTPlayer, didUpdateProgress progress: TimeInterval)
    func player(_ player: FTPlayer, didUpdatePlayable playable: TimeInterval)
    func player(_ player: FTPlayer, didUpdateBufferProgress progress: Double)
    func player(_ player: FTPlayer, didUpdateDownloadProgress progress: Double)
}

public protocol FTPlayerPreparationDelegate: AnyObject {
    /// Preparation work is delivered on main; the app owns any percent mapping.
    func player(_ player: FTPlayer, didChangePreparationState state: FTPlayerPreparationState)
    func player(_ player: FTPlayer, didUpdateMediaInfo info: FTPlayerMediaInfo)
}

/// Delivered on main while playing, at most once per 0.5 wall-clock seconds for
/// each measurement, and only when its main value differs from the last one
/// delivered. Measurements restart after rate changes, seeks, pause and stop, so
/// a nil value means not enough samples yet. The SDK never changes `rate` itself.
public protocol FTPlayerVideoStatisticsDelegate: AnyObject {
    /// Called when `timelineFramesPerSecond` changes.
    func player(_ player: FTPlayer, didChangeVideoFrameRate statistics: FTVideoFrameRateStatistics)
    /// Called when `estimatedChangesPerSecond` changes. Requires
    /// `isVideoContentChangeMeasurementEnabled`.
    func player(_ player: FTPlayer, didChangeVideoContentChangeRate statistics: FTVideoContentChangeStatistics)
}

/// Compatibility with existing apps. New consumers can bind only the observer they need.
/// Use a composition so the distributed textual interface preserves the class
/// constraint even when the compiler aliases the FTPlayer module name.
public typealias FTPlayerDeletegate = FTPlayerPlaybackDelegate & FTPlayerProgressDelegate & FTPlayerPreparationDelegate

public extension FTPlayerPlaybackDelegate {
    func player(_ player: FTPlayer, didChangeState state: FTPlayerState) {}
    func playerReadyToPlay(_ player: FTPlayer, duration: TimeInterval) {}
    func playerDidFinish(_ player: FTPlayer) {}
    func player(_ player: FTPlayer, didFail error: Error) {}
    func playerBufferingStart(_ player: FTPlayer) {}
    func playerBufferingEnd(_ player: FTPlayer) {}
}
public extension FTPlayerProgressDelegate {
    func player(_ player: FTPlayer, didUpdateProgress progress: TimeInterval) {}
    func player(_ player: FTPlayer, didUpdatePlayable playable: TimeInterval) {}
    func player(_ player: FTPlayer, didUpdateBufferProgress progress: Double) {}
    func player(_ player: FTPlayer, didUpdateDownloadProgress progress: Double) {}
}
public extension FTPlayerPreparationDelegate {
    func player(_ player: FTPlayer, didChangePreparationState state: FTPlayerPreparationState) {}
    func player(_ player: FTPlayer, didUpdateMediaInfo info: FTPlayerMediaInfo) {}
}
public extension FTPlayerVideoStatisticsDelegate {
    func player(_ player: FTPlayer, didChangeVideoFrameRate statistics: FTVideoFrameRateStatistics) {}
    func player(_ player: FTPlayer, didChangeVideoContentChangeRate statistics: FTVideoContentChangeStatistics) {}
}
