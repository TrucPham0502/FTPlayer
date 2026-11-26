import Foundation

/// Owns the diagnostic timer independently of playback state transitions.
final class PlaybackTelemetry {
    private var timer: Timer?
    private var rateTimers: [Timer] = []
    private let rateSampleOffsets = FTPlayerSDKConfiguration.Diagnostics.rateSampleOffsets
    func start(_ sample: @escaping () -> Void) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: FTPlayerSDKConfiguration.Diagnostics.healthInterval, repeats: true) { _ in
            if FTPlayerDiagnostic.shared.isEnabled { sample() }
        }
    }
    func sampleRateTransition(_ sample: @escaping (TimeInterval) -> Void) {
        rateTimers.forEach { $0.invalidate() }; rateTimers.removeAll()
        guard FTPlayerDiagnostic.shared.isEnabled else { return }
        let began = ProcessInfo.processInfo.systemUptime
        for offset in rateSampleOffsets {
            let timer = Timer(timeInterval: offset, repeats: false) { _ in
                if FTPlayerDiagnostic.shared.isEnabled { sample(ProcessInfo.processInfo.systemUptime - began) }
            }
            rateTimers.append(timer); RunLoop.main.add(timer, forMode: .common)
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        rateTimers.forEach { $0.invalidate() }; rateTimers.removeAll()
    }
    deinit { stop() }
}
