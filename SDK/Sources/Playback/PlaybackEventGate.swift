import Foundation

/// The only state shared by decoder callbacks and the main-thread facade.
/// Check before enqueueing (including detached-engine storms), then again on main.
final class PlaybackEventGate {
    private let lock = NSLock()
    private weak var engine: (any PlaybackEngine)?
    private var revision = 0
    func bind(_ value: (any PlaybackEngine)?) {
        lock.withLock { engine = value; revision += 1 }
    }
    func token(for value: any PlaybackEngine) -> Int? {
        lock.withLock { engine === value ? revision : nil }
    }
    func accepts(_ token: Int) -> Bool { lock.withLock { token == revision } }
}
