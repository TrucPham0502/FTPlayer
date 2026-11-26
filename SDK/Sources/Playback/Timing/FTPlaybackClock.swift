import Foundation

// MARK: - Protocol

protocol FTPlaybackClock: AnyObject {
    var currentTime: TimeInterval { get }
    func resetInterpolation()
    func setRate(_ rate: Float)
    func setPaused(_ paused: Bool)
    func seek(to time: TimeInterval)
}
