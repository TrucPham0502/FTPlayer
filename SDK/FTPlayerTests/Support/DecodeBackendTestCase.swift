import XCTest
@testable import FTPlayer

/// Playback tests over the loopback `FixtureHTTPServer`, with checks that the
/// requested decode backend produced the frames.
class DecodeBackendTestCase: MediaTestCase {
    var server: FixtureHTTPServer?
    override func tearDownWithError() throws {
        try super.tearDownWithError()
        server?.stop()
    }
    func fixture(_ path: String) throws -> URL { try SyntheticMedia.fixtureRoot().appendingPathComponent(path) }
    func http(_ path: String) throws -> URL {
        if server == nil { server = try FixtureHTTPServer(root: fixture("")) }
        return server!.url(path)
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
}
