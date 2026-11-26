import Foundation
import FTPlayer

/// AOV smart playback for a host app. FTPlayer only reports measurements through
/// `FTPlayerVideoStatisticsDelegate`; this file decides the playback rate from them.
/// Copy this file into an app that links FTPlayer; it needs nothing else.
///
/// Use it on the main thread:
/// 1. After creating the player, call `attach(_:selectedRate:)`. The controller becomes the
///    player's `videoStatisticsDelegate`, so read measurements from `latestFrameRate` /
///    `latestContentChangeRate` instead of setting another statistics delegate.
/// 2. Forward `FTPlayerDeletegate.player(_:didChangeState:)` to `playerDidChangeState(_:)`.
/// 3. Send user seeks through `seek(to:completion:)` and the user's rate choice through `selectRate(_:)`.
/// 4. Change settings with `update { $0.isEnabled = true }`; refresh UI in `onUpdate`.
/// For `.contentChangeRate`, also turn on `player.isVideoContentChangeMeasurementEnabled`.
struct AOVSmartRatePolicy: Equatable {
    enum Source: Int { case frameRate, contentChangeRate }
    var isEnabled = false
    var source = Source.frameRate
    var threshold = 1.0
    var lowRate: Float = 4
    var normalRate: Float = 1
    /// Rate to apply for a measurement; nil keeps the current rate.
    func rate(for measurement: Double?) -> Float? {
        guard isEnabled, let measurement else { return nil }
        return isLow(measurement) ? lowRate : normalRate
    }
    /// Compares the value as displayed (one decimal): AOV recordings measure 0.999...1.003 fps
    /// from timestamp jitter, and the raw value would flip around a threshold of 1.
    func isLow(_ measurement: Double) -> Bool { Self.displayed(measurement) <= threshold }
    static func displayed(_ measurement: Double) -> Double { (measurement * 10).rounded() / 10 }
    /// FTPlayer drops non-reference pictures from 2× up, and frames already decoded at those rates
    /// are sparse. Leaving that range needs a seek in place, or the sparse frames play at the slow rate.
    static let frameDropRate: Float = 2
    static func needsRedecode(from oldRate: Float, to newRate: Float) -> Bool {
        oldRate >= frameDropRate && newRate < frameDropRate
    }
    /// True when the look-ahead measurement turns from low to normal: the event is still ahead of
    /// the decoded frames, so lowering the rate now needs no redecode seek.
    func isFirstSeenAhead(previous: Double?, current: Double?) -> Bool {
        guard let previous, let current else { return false }
        return isLow(previous) && !isLow(current)
    }
    static func threshold(from text: String?) -> Double? {
        guard let value = number(text), value >= 0 else { return nil }
        return value
    }
    /// FTPlayer ignores rates outside 0.25...16.
    static func rate(from text: String?) -> Float? {
        guard let value = number(text), (0.25...16).contains(value) else { return nil }
        return Float(value)
    }
    private static func number(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."),
              let value = Double(text), value.isFinite else { return nil }
        return value
    }
}

final class AOVSmartRateController: NSObject, FTPlayerVideoStatisticsDelegate {
    private(set) var policy = AOVSmartRatePolicy()
    private(set) weak var player: FTPlayer?
    /// The rate the user picked: applied while AOV is off, and the normal-section rate while it is on.
    private(set) var selectedRate: Float = 1
    /// Latest values from the player's statistics delegate; nil until measured again after a reset.
    private(set) var latestFrameRate: FTVideoFrameRateStatistics?
    private(set) var latestContentChangeRate: FTVideoContentChangeStatistics?
    /// Called after a measurement, a setting or the rate changes.
    var onUpdate: (() -> Void)?

    /// The measurement the policy uses. For frame rate it is the packets just ahead of the output
    /// (so an event lowers the rate before it is shown), or the shown frames until those are known.
    var measurement: Double? {
        policy.source == .frameRate
            ? latestFrameRate.flatMap { $0.upcomingTimelineFramesPerSecond ?? $0.timelineFramesPerSecond }
            : latestContentChangeRate?.estimatedChangesPerSecond
    }

    /// Starts handling `player`, whose current rate is the user's `selectedRate`.
    func attach(_ player: FTPlayer, selectedRate: Float) {
        self.player = player
        self.selectedRate = selectedRate
        player.videoStatisticsDelegate = self
        clearMeasurements()
        apply()
    }

    /// Turning AOV off restores the rate the user picked.
    func update(_ change: (inout AOVSmartRatePolicy) -> Void) {
        let wasEnabled = policy.isEnabled
        change(&policy)
        if wasEnabled && !policy.isEnabled, let player { setRate(selectedRate, on: player) }
        apply()
    }

    /// With AOV on, the user's rate is the normal-section rate; low sections keep the low rate.
    func selectRate(_ rate: Float) {
        selectedRate = rate
        if policy.isEnabled {
            policy.normalRate = rate
            if measurement == nil, let player { setRate(rate, on: player) }
        } else {
            player?.rate = rate
        }
        apply()
    }

    /// The new position is not measured yet. With AOV on it plays at the normal rate until it is, or a seek
    /// from a boosted 1 fps section into an event would skip the start of the event at the low rate.
    func seek(to time: TimeInterval, completion: ((Bool) -> Void)? = nil) {
        guard let player else { completion?(false); return }
        if policy.isEnabled {
            clearMeasurements()
            player.rate = policy.normalRate // No redecode seek needed: this seek decodes again.
            apply()
        }
        player.seek(to: time, completeHandler: completion)
    }

    /// No frames arrive while stopped, so the delegate cannot report the cleared measurement.
    func playerDidChangeState(_ state: FTPlayerState) {
        guard [.none, .suspend, .finished, .failed].contains(state) else { return }
        clearMeasurements()
        apply()
    }

    var statusText: String {
        guard policy.isEnabled else { return "AOV thông minh: tắt" }
        let name = policy.source == .frameRate ? "FPS" : "Nhịp đổi"
        guard let measurement else {
            return "AOV thông minh: chờ số đo \(name) • đang \(String(format: "%g", player?.rate ?? selectedRate))×"
        }
        let low = policy.isLow(measurement)
        let mode = low ? "tăng tốc \(String(format: "%g", policy.lowRate))×" : "tốc độ thường \(String(format: "%g", policy.normalRate))×"
        return "AOV thông minh: \(mode) (\(name) \(String(format: "%.1f", AOVSmartRatePolicy.displayed(measurement))) \(low ? "≤" : ">") \(String(format: "%g", policy.threshold)))"
    }

    func player(_ player: FTPlayer, didChangeVideoFrameRate statistics: FTVideoFrameRateStatistics) {
        guard player === self.player else { return }
        let seenAhead = policy.source == .frameRate && policy.isFirstSeenAhead(
            previous: latestFrameRate?.upcomingTimelineFramesPerSecond, current: statistics.upcomingTimelineFramesPerSecond)
        latestFrameRate = statistics
        apply(seenAhead: seenAhead)
    }

    func player(_ player: FTPlayer, didChangeVideoContentChangeRate statistics: FTVideoContentChangeStatistics) {
        guard player === self.player else { return }
        latestContentChangeRate = statistics
        apply()
    }

    /// `seenAhead`: the normal section was found in the packets ahead, before its frames were decoded.
    private func apply(seenAhead: Bool = false) {
        if let player, let rate = policy.rate(for: measurement), player.rate != rate {
            setRate(rate, on: player, redecode: !seenAhead)
        }
        onUpdate?()
    }

    /// Frames decoded at a frame-dropping rate are sparse; `redecode` decodes them again with a seek in
    /// place. Not needed when the change was seen ahead: the frames already decoded are still 1 fps ones.
    private func setRate(_ rate: Float, on player: FTPlayer, redecode: Bool = true) {
        let oldRate = player.rate
        player.rate = rate
        if redecode, AOVSmartRatePolicy.needsRedecode(from: oldRate, to: rate) { player.seek(to: player.currentTime) }
    }

    private func clearMeasurements() {
        latestFrameRate = nil
        latestContentChangeRate = nil
    }
}
