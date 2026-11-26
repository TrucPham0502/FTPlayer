import XCTest
@testable import FTPlayer

class DecodeBackendTestCase: PlaybackTestCase {
    func backendSession(_ source: String, policy: FTVideoDecodingPolicy, internet: Bool = false) throws -> PlaybackSession {
        let url: URL
        if internet && source == "private-playback" {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let override = documents.appendingPathComponent("FTPlayerPrivatePlaybackSource.json")
            if FileManager.default.fileExists(atPath: override.path) {
                struct Source: Decodable { let url: URL }
                let provided = try JSONDecoder().decode(Source.self, from: Data(contentsOf: override))
                try require(["http", "https"].contains(provided.url.scheme?.lowercased() ?? "") && provided.url.host != nil,
                            "Provided PrivatePlayback test source must be an HTTP(S) URL")
                url = provided.url
            } else {
                guard let value = ProcessInfo.processInfo.environment["FTPLAYER_PRIVATE_PLAYBACK_URL"],
                      let configuredURL = URL(string: value),
                      ["http", "https"].contains(configuredURL.scheme?.lowercased() ?? ""),
                      configuredURL.host != nil else {
                    throw XCTSkip("Provide FTPlayerPrivatePlaybackSource.json in Documents or FTPLAYER_PRIVATE_PLAYBACK_URL in the test environment.")
                }
                url = configuredURL
            }
        } else if internet {
            let data = try internetStreamCatalogData()
            let rows = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            url = try XCTUnwrap(URL(string: configuredInternetSource(rows.first { $0["id"] as? String == source }, id: source)["url"] as! String))
        } else { url = try http(source) }
        let s = PlaybackSession(url: url, policy: policy)
        sessions.append(s); s.start()
        try require(until(45) { s.ready || s.failure != nil }, "No ready/error callback")
        #if targetEnvironment(simulator)
        if policy == .hardware, let error = s.failure as NSError?, error.domain == "FTPlayer.VideoDecoder", error.code == -2001 {
            let stats = s.player.videoDecodingStatistics
            try require(stats.ffmpegFrames == 0 && stats.hardwareFrames == 0 && stats.videoToolboxSoftwareFrames == 0, "Strict hardware secretly fell back")
            throw XCTSkip("Hardware unavailable on this Simulator: \(error.localizedDescription). No software fallback counted as hardware pass.")
        }
        #endif
        try require(s.failure == nil, "Backend open failed: \(String(describing: s.failure))")
        try assertPlayback(s, timeout: 25)
        try assertBackend(s, policy)
        return s
    }
    func assertBackend(_ s: PlaybackSession, _ policy: FTVideoDecodingPolicy) throws {
        let stats = s.player.videoDecodingStatistics
        try require(stats.policy == policy, "Wrong requested policy")
        if policy == .ffmpeg {
            try require(stats.ffmpegFrames > 0, "No actual FFmpeg frame")
            try require(stats.hardwareFrames == 0 && stats.videoToolboxSoftwareFrames == 0 && stats.videoToolboxUnverifiedFrames == 0, "Software test used another decoder")
        } else {
            try require(stats.hardwareFrames > 0, "No frame from verified hardware session")
            try require(stats.ffmpegFrames == 0 && stats.videoToolboxSoftwareFrames == 0 && stats.videoToolboxUnverifiedFrames == 0, "Strict hardware used software/unverified frames")
        }
        try require(s.failure == nil, "Decode error: \(String(describing: s.failure))")
    }
    func seek(_ s: PlaybackSession, target: Double, rate: Float, changeAfterSeek: Bool = false) throws {
        var completion: Bool?
        let frames = s.sink.frames
        let started = ProcessInfo.processInfo.systemUptime
        if !changeAfterSeek { s.player.rate = rate }
        s.player.seek(to: target) { completion = $0 }
        if changeAfterSeek { s.player.rate = rate }
        try require(until(30) { completion != nil || s.failure != nil }, "Seek callback timeout at \(rate)x")
        try require(completion == true, "Seek failed at \(rate)x")
        try require(until(25) { s.sink.frames > frames && (s.player.decoder?.currentVideoFrame?.position ?? -1) >= target - 0.3 || s.failure != nil }, "No displayed frame after seek at \(rate)x")
        let pts = s.player.decoder?.currentVideoFrame?.position ?? -1
        s.measurements.append(["operation": "seek", "target": target, "rate": rate, "rateChangedAfterRequest": changeAfterSeek,
            "elapsed": ProcessInfo.processInfo.systemUptime - started, "firstObservedVideoPTS": pts, "ptsError": pts - target, "frames": s.sink.frames])
        try require(pts <= target + max(1, Double(rate) * 0.25), "Seek jumped to distant keyframe: target=\(target), PTS=\(pts)")
        try require(s.failure == nil, "Decode failed after seek")
        try assertBackend(s, s.player.videoDecodingPolicy)
    }
    func recordRate(_ s: PlaybackSession, rate: Float) throws {
        let initial = s.player.progress
        let start = ProcessInfo.processInfo.systemUptime
        let stateIndex = s.states.count
        let bufferingAtStart = s.player.decoder?.buffering == true || s.player.state == .buffering
        let window = min(0.55, max(0.03, (s.player.duration - initial) / Double(rate) * 0.2))
        pump(window)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let delta = s.player.progress - initial
        let bufferingAtEnd = s.player.decoder?.buffering == true || s.player.state == .buffering
        let buffering = bufferingAtStart || bufferingAtEnd || s.states.dropFirst(stateIndex).contains("buffering")
        s.measurements.append(["operation": "verified-backend-seek-rate", "requestedRate": rate, "elapsed": elapsed, "mediaDelta": delta,
            "observedRate": delta / elapsed, "buffering": buffering, "bufferingAtStart": bufferingAtStart, "bufferingAtEnd": bufferingAtEnd, "videoPTS": s.player.decoder?.currentVideoFrame?.position ?? -1,
            "ffmpegFrames": s.player.videoDecodingStatistics.ffmpegFrames, "hardwareFrames": s.player.videoDecodingStatistics.hardwareFrames])
        try require(s.failure == nil, "Playback error during rate measurement")
        try require(s.player.state != .finished, "Premature EOF at high rate")
        if !buffering {
            try require(delta >= Double(rate) * elapsed * 0.30, "Actual clock too slow at \(rate)x: delta=\(delta), wall=\(elapsed)")
            try require(delta <= Double(rate) * elapsed * 2.5 + 0.5, "Clock too fast at \(rate)x")
        } else {
            let recoveryStarted = ProcessInfo.processInfo.systemUptime
            try require(until(25) { (s.player.progress > initial + 0.1 && s.player.decoder?.buffering == false) || s.failure != nil }, "Buffering never recovered")
            s.measurements.append(["operation": "buffering-recovery", "elapsed": ProcessInfo.processInfo.systemUptime - recoveryStarted, "progress": s.player.progress, "buffering": s.player.decoder?.buffering ?? true])
        }
    }
    func checkRate(_ source: String, policy: FTVideoDecodingPolicy, rate: Float, internet: Bool = false) throws {
        let s = try backendSession(source, policy: policy, internet: internet)
        // Forward seek while already at high rate, then measure the resulting clock.
        try seek(s, target: s.player.duration * 0.20, rate: rate)
        try recordRate(s, rate: rate)
        // Backward seek, with the speed change immediately AFTER the request.
        try seek(s, target: s.player.duration * 0.05, rate: 1, changeAfterSeek: true)
        let before = s.player.progress; let frames = s.sink.frames
        try require(until(25) { s.player.progress > before + 0.2 && s.sink.frames > frames + 2 || s.failure != nil }, "Could not recover 1x playback after backward seek")
        try assertBackend(s, policy)
    }
    func checkRapid(_ source: String, policy: FTVideoDecodingPolicy, internet: Bool = false) throws {
        let s = try backendSession(source, policy: policy, internet: internet)
        var results: [Bool] = []
        for (i, rate) in [Float(2), 4, 8, 16, 8, 4, 2, 1].enumerated() {
            s.player.rate = rate
            s.player.seek(to: s.player.duration * [0.1, 0.65, 0.2, 0.7, 0.25, 0.6, 0.1, 0.15][i]) { results.append($0) }
            pump(0.03)
        }
        try require(until(30) { results.count == 8 || s.failure != nil }, "Lost rapid seek callbacks: \(results)")
        s.measurements.append(["operation": "rapid-seek-rate", "callbacks": results])
        try require(results.count == 8, "Not every seek completed/canceled")
        try seek(s, target: s.player.duration * 0.1, rate: 1)
        let frames = s.sink.frames
        try require(until(25) { s.sink.frames > frames + 3 || s.failure != nil }, "Playback stalled after rapid seek")
        try assertBackend(s, policy)
    }
    func checkPauseAndBoundary(_ source: String, policy: FTVideoDecodingPolicy) throws {
        let s = try backendSession(source, policy: policy)
        for rate: Float in [2, 4, 8, 16] {
            try seek(s, target: s.player.duration * 0.2, rate: rate)
            s.player.pause(); pump(0.1); let progress = s.player.progress; pump(0.2)
            try require(abs(s.player.progress - progress) < 0.15, "Paused clock advanced at \(rate)x")
            // Seek while paused must retain suspend; resume must output video.
            var done: Bool?
            s.player.seek(to: s.player.duration * 0.1) { done = $0 }
            try require(until(25) { done != nil || s.failure != nil }, "Paused seek callback lost")
            try require(done == true, "Paused seek failed")
            try require(s.player.state == .suspend, "Paused seek unexpectedly resumed playback")
            s.player.play()
            let before = s.sink.frames
            try require(until(25) { s.sink.frames > before || s.failure != nil }, "Resume after paused seek stalled")
        }
        s.player.rate = 1
        var done: Bool?
        let target = s.player.duration - 1.0
        s.player.seek(to: target) { done = $0 }
        try require(until(25) { done != nil || s.failure != nil }, "Near-end seek timed out")
        try require(done == true, "Near-end seek failed")
        try require(until(25) { s.player.progress >= target - 0.5 || s.failure != nil }, "Near-end seek clamped early")
        try assertBackend(s, policy)
    }
    func checkEveryIntegerRate(_ source: String, policy: FTVideoDecodingPolicy) throws {
        let s = try backendSession(source, policy: policy)
        for value in 2...16 {
            try seek(s, target: s.player.duration * (value % 2 == 0 ? 0.10 : 0.25), rate: Float(value), changeAfterSeek: value % 2 == 1)
            try recordRate(s, rate: Float(value))
        }
        try seek(s, target: s.player.duration * 0.05, rate: 1)
        try assertBackend(s, policy)
    }
}
