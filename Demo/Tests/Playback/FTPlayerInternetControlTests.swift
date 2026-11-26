import XCTest
@testable import FTPlayer

/// Uses remote URLs directly, including long VOD HLS. No local substitution of failed URLs.
final class FTPlayerInternetControlTests: PlaybackTestCase {
    private func stream(_ id: String) throws -> URL {
        let data = try internetStreamCatalogData()
        let catalog = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let row = try configuredInternetSource(catalog.first { $0["id"] as? String == id }, id: id)
        return try XCTUnwrap(URL(string: row["url"] as! String))
    }
    private func checkSeekAndRate(_ id: String, rate: Float, cache: Bool = false) throws {
        var url = try stream(id)
        if cache {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "ftplayer-test", value: UUID().uuidString)]
            url = parts.url!
        }
        let s = try start(url, cache: cache, timeout: 45)
        try assertPlayback(s, timeout: 20)
        let duration = s.player.duration
        try require(duration.isFinite && duration > 5 && duration < 86400, "Combined seek/rate needs finite VOD duration")
        let target = duration * 0.2
        s.player.rate = rate
        let framesBefore = s.sink.frames
        let requiredFrames = duration > 20 ? 2 : 0
        var complete: Bool?
        s.player.seek(to: target) { complete = $0 }
        try require(until(25) { complete != nil || s.failure != nil }, "PLAYER seek callback timed out at \(rate)x")
        try require(complete == true, "PLAYER seek failed at \(rate)x")
        try require(until(25) {
            s.sink.frames > framesBefore + requiredFrames && (s.player.decoder?.currentVideoFrame?.position ?? -1) >= target - 2 || s.failure != nil
        }, "PLAYER no decoded frames at seek target while running \(rate)x")
        try require(s.failure == nil, "PLAYER error after seek: \(String(describing: s.failure))")
        // Measure media advancement, rather than just checking that rate accepted a value.
        let initial = s.player.progress
        let wall = ProcessInfo.processInfo.systemUptime
        let stateIndex = s.states.count
        let window = min(0.65, max(0.02, (duration - initial) / Double(rate) * 0.25))
        pump(window)
        let elapsed = ProcessInfo.processInfo.systemUptime - wall
        let delta = s.player.progress - initial
        let interrupted = s.states.dropFirst(stateIndex).contains("buffering")
        s.measurements.append(["operation": "seek-at-rate", "requestedRate": rate, "seekTarget": target,
            "elapsed": elapsed, "mediaDelta": delta, "observedRate": delta / elapsed,
            "bufferingDuringMeasurement": interrupted, "lastVideoPTS": s.player.decoder?.currentVideoFrame?.position ?? -1, "masterClock": s.player.decoder?.playbackClock?.currentTime ?? -1, "frames": s.sink.frames])
        try require(s.failure == nil, "PLAYER error during high rate playback")
        try require(s.player.state != .finished, "PLAYER reached EOF much too early after seek at \(rate)x")
        if !interrupted {
            try require(delta >= Double(rate) * elapsed * 0.35, "PLAYER actual media clock advanced too slowly for requested \(rate)x (delta=\(delta), seconds=\(elapsed))")
            try require(delta <= Double(rate) * elapsed * 2.5 + 0.5, "PLAYER actual media clock ran far faster than requested \(rate)x (delta=\(delta))")
        } else {
            try require(until(20) { s.player.progress > initial + 0.1 || s.failure != nil }, "PLAYER stuck buffering after rate/seek")
        }
        // Change rate immediately after another seek, then verify usable playback at 1x.
        let backTarget = min(2.0, duration * 0.05)
        complete = nil
        s.player.seek(to: backTarget) { complete = $0 }
        s.player.rate = 1
        let afterFrames = s.sink.frames
        try require(until(25) { complete != nil || s.failure != nil }, "PLAYER reverse seek after high rate timed out")
        try require(complete == true, "PLAYER reverse seek failed")
        try require(until(25) { s.sink.frames > afterFrames + 2 && s.player.progress >= backTarget + 0.2 || s.failure != nil }, "PLAYER could not return to 1x after high-rate seek")
        try require(s.failure == nil, "PLAYER error returning to normal rate")
    }
    private func rapidSeekAndRate(_ id: String) throws {
        let s = try start(stream(id), timeout: 45); try assertPlayback(s, timeout: 20)
        var callbacks = 0
        let fractions: [Double] = [0.1, 0.6, 0.25, 0.7]
        for (index, rate) in [Float(2), 4, 8, 16].enumerated() {
            s.player.rate = rate
            s.player.seek(to: s.player.duration * fractions[index]) { _ in callbacks += 1 }
            pump(0.03)
        }
        try require(until(30) { callbacks == 4 || s.failure != nil }, "PLAYER lost completion callbacks during rapid seeks (\(callbacks)/4)")
        try require(s.failure == nil, "PLAYER failed during rapid seek/rate changes")
        s.player.rate = 1
        let before = s.sink.frames
        try require(until(20) { s.sink.frames > before + 2 || s.failure != nil }, "PLAYER video stalled after combined stress")
        try require(s.failure == nil, "PLAYER failed after combined stress")
    }
    func testMP4H264AACSeekAt2xThenSeekBackTo1x() throws { try checkSeekAndRate("mp4-h264-w3c", rate: 2) }
    func testMP4H264AACSeekAt4xThenSeekBackTo1x() throws { try checkSeekAndRate("mp4-h264-w3c", rate: 4) }
    func testMP4H264AACSeekAt8xThenSeekBackTo1x() throws { try checkSeekAndRate("mp4-h264-w3c", rate: 8) }
    func testMP4H264AACSeekAt16xThenSeekBackTo1x() throws { try checkSeekAndRate("mp4-h264-w3c", rate: 16) }
    func testMP4H264AACRapidSeekAndRateChanges() throws { try rapidSeekAndRate("mp4-h264-w3c") }
    func testMP4HEVCSeekAt2xThenSeekBackTo1x() throws { try checkSeekAndRate("mp4-hevc", rate: 2) }
    func testMP4HEVCSeekAt4xThenSeekBackTo1x() throws { try checkSeekAndRate("mp4-hevc", rate: 4) }
    func testMP4HEVCSeekAt8xThenSeekBackTo1x() throws { try checkSeekAndRate("mp4-hevc", rate: 8) }
    func testMP4HEVCSeekAt16xThenSeekBackTo1x() throws { try checkSeekAndRate("mp4-hevc", rate: 16) }
    func testMP4HEVCRapidSeekAndRateChanges() throws { try rapidSeekAndRate("mp4-hevc") }
    func testHLSH264AACSeekAt2xThenSeekBackTo1x() throws { try checkSeekAndRate("hls-media", rate: 2) }
    func testHLSH264AACSeekAt4xThenSeekBackTo1x() throws { try checkSeekAndRate("hls-media", rate: 4) }
    func testHLSH264AACSeekAt8xThenSeekBackTo1x() throws { try checkSeekAndRate("hls-media", rate: 8) }
    func testHLSH264AACSeekAt16xThenSeekBackTo1x() throws { try checkSeekAndRate("hls-media", rate: 16) }
    func testHLSH264AACRapidSeekAndRateChanges() throws { try rapidSeekAndRate("hls-media") }
    func testHLSHEVCSeekAt2xThenSeekBackTo1x() throws { try checkSeekAndRate("hls-hevc", rate: 2) }
    func testHLSHEVCSeekAt4xThenSeekBackTo1x() throws { try checkSeekAndRate("hls-hevc", rate: 4) }
    func testHLSHEVCSeekAt8xThenSeekBackTo1x() throws { try checkSeekAndRate("hls-hevc", rate: 8) }
    func testHLSHEVCSeekAt16xThenSeekBackTo1x() throws { try checkSeekAndRate("hls-hevc", rate: 16) }
    func testHLSHEVCRapidSeekAndRateChanges() throws { try rapidSeekAndRate("hls-hevc") }
    func testMP4H264CachedSeekAt8xThenReturnTo1x() throws { try checkSeekAndRate("mp4-h264-w3c", rate: 8, cache: true) }
}
