import Foundation

/// Forward-only preparation state. Event dispatch and UI callbacks belong to the facade.
final class PlaybackPreparationWorkflow {
    private(set) var state: FTPlayerPreparationState = .idle
    private var active = false

    func begin() {
        state = .begin
        active = true
    }

    @discardableResult
    func advance(to next: FTPlayerPreparationState) -> Bool {
        guard active, next != state else { return false }
        let states = FTPlayerPreparationState.allCases
        guard next == .failed || states.firstIndex(of: next)! > states.firstIndex(of: state)! else { return false }
        state = next
        if next == .end || next == .failed { active = false }
        return true
    }

    func stop() {
        active = false
        state = .stopped
    }
}
