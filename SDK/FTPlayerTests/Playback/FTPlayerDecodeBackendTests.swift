import XCTest
@testable import FTPlayer

/// Seek and rate checks per decode backend over the loopback HTTP server.
final class FTPlayerDecodeBackendTests: DecodeBackendTestCase {
    func testFfmpegPhotoprismHEVCSeekAt2xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .ffmpeg, rate: 2) }
    func testFfmpegPhotoprismHEVCSeekAt4xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .ffmpeg, rate: 4) }
    func testFfmpegPhotoprismHEVCSeekAt8xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .ffmpeg, rate: 8) }
    func testFfmpegPhotoprismHEVCSeekAt16xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .ffmpeg, rate: 16) }
    func testFfmpegPhotoprismHEVCRapidSeekAndRate() throws { try checkRapid("photoprism-tsu-hevc.mp4", policy: .ffmpeg) }
    func testHardwarePhotoprismHEVCSeekAt2xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .hardware, rate: 2) }
    func testHardwarePhotoprismHEVCSeekAt4xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .hardware, rate: 4) }
    func testHardwarePhotoprismHEVCSeekAt8xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .hardware, rate: 8) }
    func testHardwarePhotoprismHEVCSeekAt16xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .hardware, rate: 16) }
    func testHardwarePhotoprismHEVCRapidSeekAndRate() throws { try checkRapid("photoprism-tsu-hevc.mp4", policy: .hardware) }
    func testFfmpegMP4H264SeekAt2xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .ffmpeg, rate: 2) }
    func testFfmpegMP4H264SeekAt4xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .ffmpeg, rate: 4) }
    func testFfmpegMP4H264SeekAt8xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .ffmpeg, rate: 8) }
    func testFfmpegMP4H264SeekAt16xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .ffmpeg, rate: 16) }
    func testFfmpegMP4H264RapidSeekAndRate() throws { try checkRapid("sample.mp4", policy: .ffmpeg) }
    func testFfmpegMP4H264PauseSeekAndNearEnd() throws { try checkPauseAndBoundary("sample.mp4", policy: .ffmpeg) }
    func testFfmpegMP4H264EveryIntegerRate2Through16() throws { try checkEveryIntegerRate("sample.mp4", policy: .ffmpeg) }
    func testFfmpegMP4HEVCSeekAt2xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .ffmpeg, rate: 2) }
    func testFfmpegMP4HEVCSeekAt4xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .ffmpeg, rate: 4) }
    func testFfmpegMP4HEVCSeekAt8xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .ffmpeg, rate: 8) }
    func testFfmpegMP4HEVCSeekAt16xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .ffmpeg, rate: 16) }
    func testFfmpegMP4HEVCRapidSeekAndRate() throws { try checkRapid("internet-hevc.mp4", policy: .ffmpeg) }
    func testFfmpegMP4HEVCPauseSeekAndNearEnd() throws { try checkPauseAndBoundary("internet-hevc.mp4", policy: .ffmpeg) }
    func testFfmpegMP4HEVCEveryIntegerRate2Through16() throws { try checkEveryIntegerRate("internet-hevc.mp4", policy: .ffmpeg) }
    func testFfmpegHLSH264SeekAt2xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .ffmpeg, rate: 2) }
    func testFfmpegHLSH264SeekAt4xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .ffmpeg, rate: 4) }
    func testFfmpegHLSH264SeekAt8xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .ffmpeg, rate: 8) }
    func testFfmpegHLSH264SeekAt16xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .ffmpeg, rate: 16) }
    func testFfmpegHLSH264RapidSeekAndRate() throws { try checkRapid("hls-ts/index.m3u8", policy: .ffmpeg) }
    func testFfmpegHLSH264PauseSeekAndNearEnd() throws { try checkPauseAndBoundary("hls-ts/index.m3u8", policy: .ffmpeg) }
    func testFfmpegHLSH264EveryIntegerRate2Through16() throws { try checkEveryIntegerRate("hls-ts/index.m3u8", policy: .ffmpeg) }
    func testFfmpegHLSHEVCSeekAt2xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .ffmpeg, rate: 2) }
    func testFfmpegHLSHEVCSeekAt4xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .ffmpeg, rate: 4) }
    func testFfmpegHLSHEVCSeekAt8xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .ffmpeg, rate: 8) }
    func testFfmpegHLSHEVCSeekAt16xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .ffmpeg, rate: 16) }
    func testFfmpegHLSHEVCRapidSeekAndRate() throws { try checkRapid("hls-hevc/index.m3u8", policy: .ffmpeg) }
    func testFfmpegHLSHEVCPauseSeekAndNearEnd() throws { try checkPauseAndBoundary("hls-hevc/index.m3u8", policy: .ffmpeg) }
    func testFfmpegHLSHEVCEveryIntegerRate2Through16() throws { try checkEveryIntegerRate("hls-hevc/index.m3u8", policy: .ffmpeg) }
    func testHardwareMP4H264SeekAt2xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .hardware, rate: 2) }
    func testHardwareMP4H264SeekAt4xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .hardware, rate: 4) }
    func testHardwareMP4H264SeekAt8xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .hardware, rate: 8) }
    func testHardwareMP4H264SeekAt16xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .hardware, rate: 16) }
    func testHardwareMP4H264RapidSeekAndRate() throws { try checkRapid("sample.mp4", policy: .hardware) }
    func testHardwareMP4H264PauseSeekAndNearEnd() throws { try checkPauseAndBoundary("sample.mp4", policy: .hardware) }
    func testHardwareMP4H264EveryIntegerRate2Through16() throws { try checkEveryIntegerRate("sample.mp4", policy: .hardware) }
    func testHardwareMP4HEVCSeekAt2xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .hardware, rate: 2) }
    func testHardwareMP4HEVCSeekAt4xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .hardware, rate: 4) }
    func testHardwareMP4HEVCSeekAt8xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .hardware, rate: 8) }
    func testHardwareMP4HEVCSeekAt16xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .hardware, rate: 16) }
    func testHardwareMP4HEVCRapidSeekAndRate() throws { try checkRapid("internet-hevc.mp4", policy: .hardware) }
    func testHardwareMP4HEVCPauseSeekAndNearEnd() throws { try checkPauseAndBoundary("internet-hevc.mp4", policy: .hardware) }
    func testHardwareMP4HEVCEveryIntegerRate2Through16() throws { try checkEveryIntegerRate("internet-hevc.mp4", policy: .hardware) }
    func testHardwareHLSH264SeekAt2xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .hardware, rate: 2) }
    func testHardwareHLSH264SeekAt4xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .hardware, rate: 4) }
    func testHardwareHLSH264SeekAt8xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .hardware, rate: 8) }
    func testHardwareHLSH264SeekAt16xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .hardware, rate: 16) }
    func testHardwareHLSH264RapidSeekAndRate() throws { try checkRapid("hls-ts/index.m3u8", policy: .hardware) }
    func testHardwareHLSH264PauseSeekAndNearEnd() throws { try checkPauseAndBoundary("hls-ts/index.m3u8", policy: .hardware) }
    func testHardwareHLSH264EveryIntegerRate2Through16() throws { try checkEveryIntegerRate("hls-ts/index.m3u8", policy: .hardware) }
    func testHardwareHLSHEVCSeekAt2xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .hardware, rate: 2) }
    func testHardwareHLSHEVCSeekAt4xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .hardware, rate: 4) }
    func testHardwareHLSHEVCSeekAt8xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .hardware, rate: 8) }
    func testHardwareHLSHEVCSeekAt16xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .hardware, rate: 16) }
    func testHardwareHLSHEVCRapidSeekAndRate() throws { try checkRapid("hls-hevc/index.m3u8", policy: .hardware) }
    func testHardwareHLSHEVCPauseSeekAndNearEnd() throws { try checkPauseAndBoundary("hls-hevc/index.m3u8", policy: .hardware) }
    func testHardwareHLSHEVCEveryIntegerRate2Through16() throws { try checkEveryIntegerRate("hls-hevc/index.m3u8", policy: .hardware) }
    func testHardwareHLS60FPSSeekAt16xAndBackTo1x() throws { try checkRate("hls-60fps/index.m3u8", policy: .hardware, rate: 16) }

    private func backendSession(_ source: String, policy: FTVideoDecodingPolicy) throws -> PlaybackSession {
        let s = PlaybackSession(url: try http(source), policy: policy)
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
    private func checkRate(_ source: String, policy: FTVideoDecodingPolicy, rate: Float) throws {
        let s = try backendSession(source, policy: policy)
        // Forward seek while already at high rate, then measure the resulting clock.
        try seek(s, target: s.player.duration * 0.20, rate: rate)
        try recordRate(s, rate: rate)
        // Backward seek, with the speed change immediately AFTER the request.
        try seek(s, target: s.player.duration * 0.05, rate: 1, changeAfterSeek: true)
        let before = s.player.progress; let frames = s.sink.frames
        try require(until(25) { s.player.progress > before + 0.2 && s.sink.frames > frames + 2 || s.failure != nil }, "Could not recover 1x playback after backward seek")
        try assertBackend(s, policy)
    }
    private func checkRapid(_ source: String, policy: FTVideoDecodingPolicy) throws {
        let s = try backendSession(source, policy: policy)
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
    private func checkPauseAndBoundary(_ source: String, policy: FTVideoDecodingPolicy) throws {
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
    private func checkEveryIntegerRate(_ source: String, policy: FTVideoDecodingPolicy) throws {
        let s = try backendSession(source, policy: policy)
        for value in 2...16 {
            try seek(s, target: s.player.duration * (value % 2 == 0 ? 0.10 : 0.25), rate: Float(value), changeAfterSeek: value % 2 == 1)
            try recordRate(s, rate: Float(value))
        }
        try seek(s, target: s.player.duration * 0.05, rate: 1)
        try assertBackend(s, policy)
    }
}
