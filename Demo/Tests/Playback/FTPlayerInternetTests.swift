import XCTest
import UIKit
import CoreVideo
import libavcodec
@testable import FTPlayer

/// Opt-in live endpoint tests. They never silently skip unavailable public URLs.
/// A preflight failure is tagged ENDPOINT; decoder/playback failures are tagged PLAYER.
final class FTPlayerInternetTests: PlaybackTestCase {
    @objc func testReadySeekOnlineMP4H264DefaultCache() throws { try checkOnlineReadySeek("mp4-h264-w3c", cache: nil) }
    @objc func testReadySeekOnlineMP4H264Cached() throws { try checkOnlineReadySeek("mp4-h264-w3c", cache: true) }
    @objc func testReadySeekOnlineMP4HEVCDefaultCache() throws { try checkOnlineReadySeek("mp4-hevc", cache: nil) }
    @objc func testReadySeekOnlineMP4HEVCCached() throws { try checkOnlineReadySeek("mp4-hevc", cache: true) }
    @objc func testReadySeekOnlineHLSH264DefaultCache() throws { try checkOnlineReadySeek("hls-master", cache: nil) }
    @objc func testReadySeekOnlineHLSH264Cached() throws { try checkOnlineReadySeek("hls-master", cache: true) }
    @objc func testReadySeekOnlineHLSHEVCDefaultCache() throws { try checkOnlineReadySeek("hls-hevc", cache: nil) }
    @objc func testReadySeekOnlineHLSHEVCCached() throws { try checkOnlineReadySeek("hls-hevc", cache: true) }

    private func checkOnlineReadySeek(_ identifier: String, cache: Bool?) throws {
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: internetStreamCatalogData()) as? [[String: Any]])
        let value = try configuredInternetSource(rows.first { $0["id"] as? String == identifier }?["url"] as? String, id: identifier)
        try checkImmediateReadySeek(url: XCTUnwrap(URL(string: value)), cache: cache, timeout: 90)
    }

    private struct MalformedMediaSource {
        let id: String
        let catalogID: String
        let twoFrames: Bool
        let mayReject: Bool
        let videoEnd: Double?
        init(_ id: String, _ catalogID: String, twoFrames: Bool = false, mayReject: Bool = false, videoEnd: Double? = nil) {
            self.id = id; self.catalogID = catalogID; self.twoFrames = twoFrames; self.mayReject = mayReject; self.videoEnd = videoEnd
        }
    }
    private static let malformedMedia: [MalformedMediaSource] = [
        .init("reference-list", "malformed-reference-list"),
        .init("avc-keyframe-non-sync", "malformed-avc-keyframe-non-sync", twoFrames: true),
        .init("avc-non-keyframe-sync", "malformed-avc-non-keyframe-sync", twoFrames: true),
        .init("hevc-keyframe-non-sync", "malformed-hevc-keyframe-non-sync", twoFrames: true),
        .init("hevc-non-keyframe-sync", "malformed-hevc-non-keyframe-sync", twoFrames: true),
        .init("mid-file-timestamp", "malformed-mid-file-timestamp"),
        .init("duplicate-track-id", "malformed-duplicate-track-id", mayReject: true),
        .init("corrupt-webm", "malformed-corrupt-webm", mayReject: true),
        // Independently scanned PES: last real video PTS is 136.28s, while
        // EXTINF sums to 142s. A seek beyond the video must retain its last image.
        .init("bad-pdt", "malformed-bad-pdt", videoEnd: 136.28),
        .init("bad-pts-dts", "hls-custom-iv")
    ]
    func testMalformedDefault_ReferenceList() throws { try checkMalformedMedia(0, cache: nil) }
    func testMalformedCached_ReferenceList() throws { try checkMalformedMedia(0, cache: true) }
    func testMalformedDefault_AVCKeyframeNonSync() throws { try checkMalformedMedia(1, cache: nil) }
    func testMalformedCached_AVCKeyframeNonSync() throws { try checkMalformedMedia(1, cache: true) }
    func testMalformedDefault_AVCNonKeyframeSync() throws { try checkMalformedMedia(2, cache: nil) }
    func testMalformedCached_AVCNonKeyframeSync() throws { try checkMalformedMedia(2, cache: true) }
    func testMalformedDefault_HEVCKeyframeNonSync() throws { try checkMalformedMedia(3, cache: nil) }
    func testMalformedCached_HEVCKeyframeNonSync() throws { try checkMalformedMedia(3, cache: true) }
    func testMalformedDefault_HEVCNonKeyframeSync() throws { try checkMalformedMedia(4, cache: nil) }
    func testMalformedCached_HEVCNonKeyframeSync() throws { try checkMalformedMedia(4, cache: true) }
    func testMalformedDefault_MidFileTimestamp() throws { try checkMalformedMedia(5, cache: nil) }
    func testMalformedCached_MidFileTimestamp() throws { try checkMalformedMedia(5, cache: true) }
    func testMalformedDefault_DuplicateTrackID() throws { try checkMalformedMedia(6, cache: nil) }
    func testMalformedCached_DuplicateTrackID() throws { try checkMalformedMedia(6, cache: true) }
    func testMalformedDefault_CorruptWebM() throws { try checkMalformedMedia(7, cache: nil) }
    func testMalformedCached_CorruptWebM() throws { try checkMalformedMedia(7, cache: true) }
    func testMalformedDefault_BadPDT() throws { try checkMalformedMedia(8, cache: nil) }
    func testMalformedCached_BadPDT() throws { try checkMalformedMedia(8, cache: true) }
    func testMalformedDefault_BadPTSDTS() throws { try checkMalformedMedia(9, cache: nil) }
    func testMalformedCached_BadPTSDTS() throws { try checkMalformedMedia(9, cache: true) }

    private func checkMalformedMedia(_ index: Int, cache: Bool?) throws {
        let source = Self.malformedMedia[index]
        let catalog = try JSONDecoder().decode([Stream].self, from: internetStreamCatalogData())
        let url = try configuredInternetSource(catalog.first { $0.id == source.catalogID }, id: source.catalogID).url
        let s = PlaybackSession(url: url, cache: cache)
        sessions.append(s); s.start(); s.player.pause()
        s.measurements.append(["operation": "malformed-scope", "id": source.id,
            "cacheAssigned": cache != nil, "useCache": s.player.useCache, "twoFrames": source.twoFrames])
        try require(until(45) { s.ready || s.failure != nil }, "Malformed source gave neither ready nor error: \(source.id)")
        if cache == nil { XCTAssertFalse(s.player.useCache); XCTAssertNil(s.player.cacheSession) }
        if source.mayReject {
            if s.failure == nil {
                s.player.play()
                try require(until(15) { s.failure != nil || s.sink.frames > 0 || s.finished > 0 },
                            "Malformed payload hung after headers: \(source.id)")
            }
            if let error = s.failure as NSError? {
                // Transport failures cannot count as successful invalid-media rejection.
                let avCode = (error.userInfo["avCode"] as? NSNumber)?.intValue
                XCTAssertEqual(error.domain, "FTPlayer.FFmpeg")
                XCTAssertTrue(avCode == -1094995529 || avCode == Int(FT_AVERROR_EOF), "Transport/HTTP errors do not prove invalid-media rejection")
                XCTAssertEqual(s.errorCount, 1)
                XCTAssertEqual(s.finished, 0, "Invalid media reported successful EOF")
                XCTAssertTrue(s.callbackThreadsAreMain)
                s.measurements.append(["operation": "malformed-outcome", "outcome": "graceful-rejection",
                    "domain": error.domain, "code": error.code, "avCode": avCode ?? 0])
                return
            }
            try require(s.sink.frames > 0, "Invalid media reported didFinish without a decoded picture: \(source.id)")
        }
        try require(s.failure == nil && s.ready, "Recoverable malformed source failed to open: \(source.id): \(String(describing: s.failure))")
        s.player.play()
        try require(until(15) { s.sink.frames >= (source.twoFrames ? 1 : 3) || s.failure != nil },
                    "Malformed source produced no real decoded output: \(source.id)")
        try require(s.failure == nil && s.sink.frames > 0, "Malformed source failed during initial decode: \(source.id)")
        s.player.pause()
        let duration = s.player.duration, firstPTS = s.sink.firstPresentationTime ?? 0
        try require(duration.isFinite && duration > 0 && duration < 86400, "Invalid public duration for \(source.id)")
        let fps = s.player.mediaInfo?.framesPerSecond ?? 30
        let step = 1 / max(1, fps)
        var shortPresentationTimes: [Double] = []
        if source.twoFrames {
            // These two-frame AVC cuts retain reordered PTS and can end after
            // the declared duration. Read real timestamps from the byte-identical
            // offline sample; duration - 1/fps is not its last picture's PTS.
            let codec = source.id.hasPrefix("hevc") ? "hevc" : "avc"
            let kind = source.id.contains("non-keyframe") ? "nonkeyframe" : "keyframe"
            let format = FTFormatContext(contentURL: try fixture("malformed-keyflags/\(codec)-\(kind).mp4"), videoFormat: .unknown)
            format.setupSync(useCache: false)
            defer { format.destroy() }
            var packet = av_packet_alloc()
            defer { av_packet_free(&packet) }
            for _ in 0..<8 {
                guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
                if Int(value.stream_index) == format.videoTrack?.index, value.pts != FT_AV_NOPTS_VALUE {
                    shortPresentationTimes.append(Double(value.pts) * format.videoTimebase - format.startTime)
                }
                av_packet_unref(packet)
            }
            shortPresentationTimes.sort()
            XCTAssertEqual(shortPresentationTimes.count, 2)
            s.measurements.append(["operation": "malformed-source-timestamps", "presentationTimes": shortPresentationTimes])
        }
        if cache == true {
            try require(until(30) { s.player.cacheProgress.cachedBytes > 0 && s.player.downloadProgress > 0 || s.failure != nil }, "Malformed input cache metadata/bytes did not become available")
            XCTAssertGreaterThan(s.player.cacheProgress.cachedBytes, 0)
            XCTAssertGreaterThan(s.player.downloadProgress, 0)
        }
        func seek(_ target: Double, rate: Float, pauseAfter: Bool = true) throws {
            s.player.pause(); s.player.rate = rate
            let frames = s.sink.frames, began = ProcessInfo.processInfo.systemUptime
            let decodedBefore = s.player.videoDecodingStatistics.ffmpegFrames, finishesBefore = s.finished
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(20) { completed != nil || s.failure != nil }, "Malformed seek callback missing: \(source.id)")
            XCTAssertEqual(completed, true)
            s.player.play()
            let expected = source.twoFrames
                ? max(firstPTS, shortPresentationTimes.last(where: { $0 <= target + 0.000001 }) ?? firstPTS)
                : max(firstPTS, min(target, source.videoEnd ?? duration))
            let tolerance = source.twoFrames ? max(step * 0.6, Double(rate) * 0.025) : max(0.5, Double(rate) * 0.05)
            let rendered = until(15) { s.failure != nil || s.sink.presentationTimes(after: frames).contains { abs($0 - expected) <= tolerance } }
            s.measurements.append(["operation": "malformed-seek", "target": target, "rate": rate,
                "expected": expected, "picture": s.sink.lastPresentationTime, "clock": s.player.currentTime,
                "presentations": s.sink.presentationTimes(after: frames),
                "decodedBefore": decodedBefore, "decodedAfter": s.player.videoDecodingStatistics.ffmpegFrames,
                "finishesBefore": finishesBefore, "finishesAfter": s.finished,
                "decoder": s.player.decoder?.diagnosticSnapshot ?? "closed",
                "seconds": ProcessInfo.processInfo.systemUptime - began,
                "cache": s.player.decoder?.cacheDiagnostics ?? [:]])
            try require(rendered && s.failure == nil, "Malformed seek did not render target: \(source.id) \(target) @\(rate)x")
            if pauseAfter { s.player.pause() }
        }
        for rate in [Float(1), 4, 16] {
            for target in [0.0, duration / 2, max(0, duration - min(0.3, duration * 0.2)), 0] { try seek(target, rate: rate) }
        }
        if !source.twoFrames {
            let end = min(32, duration - 0.5)
            if cache == true {
                try seek(0, rate: 1)
                try require(until(45) { s.player.cachedTimeRanges.contains { $0.start <= 0.05 && $0.end >= end } || s.failure != nil },
                            "Malformed source cache interval did not fill: \(source.id)")
                XCTAssertFalse(s.player.cachedTimeRanges.isEmpty)
            }
            try seek(0, rate: 1)
            let began = ProcessInfo.processInfo.systemUptime, origin = s.player.currentTime, frames = s.sink.frames
            var previous = origin, backwards = 0.0, lastPTS = s.sink.lastPresentationTime
            var lastPictureWall = began, maximumGap = 0.0
            var previousWall = began, previousBuffering = s.player.decoder?.buffering ?? true
            var activeWall = 0.0, activeClockDelta = 0.0, activePictureDelta = 0.0
            var activeGap = 0.0, maximumActiveGap = 0.0
            var samples: [[String: Any]] = []
            s.player.rate = 16; s.player.play()
            while s.player.currentTime < end && ProcessInfo.processInfo.systemUptime - began < 8 && s.failure == nil {
                pump(0.02)
                let clock = s.player.currentTime, now = ProcessInfo.processInfo.systemUptime
                let buffering = s.player.decoder?.buffering ?? true, pts = s.sink.lastPresentationTime
                if !buffering && !previousBuffering {
                    activeWall += now - previousWall
                    activeClockDelta += max(0, clock - previous)
                    activePictureDelta += max(0, pts - lastPTS)
                    activeGap = pts > lastPTS + 0.0001 ? 0 : activeGap + now - previousWall
                    maximumActiveGap = max(maximumActiveGap, activeGap)
                } else { activeGap = 0 }
                backwards = max(backwards, previous - clock); previous = clock
                if pts > lastPTS + 0.0001 { lastPictureWall = now }
                lastPTS = pts; previousWall = now; previousBuffering = buffering
                maximumGap = max(maximumGap, now - lastPictureWall)
                samples.append(["wall": now - began, "clock": clock, "videoPTS": pts, "buffering": buffering])
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            s.measurements.append(["operation": "malformed-rate", "requestedRate": 16,
                "actualRate": (s.player.currentTime - origin) / elapsed, "maximumBackwardClockStep": backwards,
                "maximumImageGap": maximumGap, "frames": s.sink.frames - frames,
                "activeWall": activeWall, "activeClockRate": activeClockDelta / max(0.001, activeWall),
                "activePictureRate": activePictureDelta / max(0.001, activeWall),
                "maximumActiveImageGap": maximumActiveGap, "samples": samples])
            try require(s.failure == nil && s.sink.frames > frames + 2, "Malformed fast playback stopped producing pictures")
            XCTAssertGreaterThanOrEqual(s.player.currentTime, end)
            if cache == true {
                XCTAssertEqual((s.player.currentTime - origin) / elapsed, 16, accuracy: 3.2, "Cached malformed source did not sustain the requested 16x media clock")
                XCTAssertLessThan(maximumGap, 0.5, "Cached malformed source stopped presenting pictures at 16x")
            } else {
                // Native HTTP can buffer while downloading at high rates. Keep
                // its whole-window cost in the report; require real 16x clock
                // and picture advancement during active playback, plus bounded
                // recovery to the target within the overall eight-second budget.
                XCTAssertGreaterThan(activeWall, 0.1)
                XCTAssertEqual(activeClockDelta / max(0.001, activeWall), 16, accuracy: 4)
                XCTAssertGreaterThan(activePictureDelta / max(0.001, activeWall), 8)
                XCTAssertLessThan(maximumActiveGap, 0.5, "Uncached malformed source stopped presenting pictures outside buffering")
            }
            XCTAssertLessThan(backwards, 0.1)
            try seek(0, rate: 1)
        } else {
            s.measurements.append(["operation": "malformed-rate-scope", "scope": "2-frame seek/EOF at 16x; no sustained-rate measurement"])
        }
        let finishes = s.finished
        try seek(max(0, duration - min(0.5, duration * 0.5)), rate: 16, pauseAfter: false)
        try require(until(10) { s.finished > finishes || s.failure != nil }, "Malformed valid tail never finished: \(source.id)")
        XCTAssertNil(s.failure)
        XCTAssertEqual(s.finished, finishes + 1)
        XCTAssertEqual(s.player.state, .finished)
        XCTAssertEqual(s.player.currentTime, duration, accuracy: 0.001)
        XCTAssertTrue(s.callbackThreadsAreMain)
        if cache == true { XCTAssertGreaterThan(s.player.decoder?.cacheDiagnostics["diskReadBytes"] ?? 0, 0) }
        s.measurements.append(["operation": "malformed-outcome", "outcome": "played-seek-rate-cache",
            "clock": s.player.currentTime, "duration": duration])
    }
    func testSeparatedAudioPublicDistantSeekWithUntouchedCacheDefault() throws {
        try checkSeparatedAudioPublicDistantSeek(cache: nil)
    }
    func testSeparatedAudioPublicDistantSeekWithCacheEnabled() throws {
        try checkSeparatedAudioPublicDistantSeek(cache: true)
    }
    private func checkSeparatedAudioPublicDistantSeek(cache: Bool?) throws {
        let streams = try JSONDecoder().decode([Stream].self, from: internetStreamCatalogData())
        let source = try configuredInternetSource(streams.first { $0.id == "hls-elephants-audio" }, id: "hls-elephants-audio")
        let s = try start(source.url, cache: cache, timeout: 90)
        try assertPlayback(s, timeout: 20)
        for target in [0.0, s.player.duration / 2, s.player.duration - 0.8, 0] {
            s.player.pause()
            let frames = s.sink.frames, began = ProcessInfo.processInfo.systemUptime
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(35) { completed != nil || s.failure != nil }, "Separated-audio seek callback missing")
            XCTAssertEqual(completed, true)
            s.player.play()
            let rendered = until(20) { s.failure != nil || s.sink.frames > frames && abs(s.sink.lastPresentationTime - target) <= 0.5 }
            s.measurements.append(["operation": "separated-audio-seek", "cacheAssigned": cache != nil,
                "useCache": s.player.useCache, "target": target, "picture": s.sink.lastPresentationTime,
                "clock": s.player.currentTime, "seconds": ProcessInfo.processInfo.systemUptime - began,
                "decoder": s.player.decoder?.diagnosticSnapshot ?? "closed"])
            try require(rendered && s.failure == nil, "Separated-audio distant seek did not render its target")
        }
    }

    private struct PrivateHLSInput: Decodable {
        struct Clip: Decodable {
            let label: String
            let url: URL
            let expectedDuration: Double
            let segmentDurations: [Double]
        }
        let clips: [Clip]
    }

    private func checkPrivateHLS(_ index: Int, cache: Bool, policy: FTVideoDecodingPolicy, leaveCacheDefault: Bool = false) throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let file = documents.appendingPathComponent("FTPlayerPrivateHLSReview.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Opt-in private HLS review input is absent") }
        let input = try JSONDecoder().decode(PrivateHLSInput.self, from: Data(contentsOf: file))
        let clip = try XCTUnwrap(input.clips.indices.contains(index) ? input.clips[index] : nil)
        let s = try start(clip.url, cache: leaveCacheDefault ? nil : cache, policy: policy, timeout: 90)
        try assertPlayback(s, timeout: 20)
        if leaveCacheDefault {
            XCTAssertFalse(s.player.useCache)
            XCTAssertNil(s.player.cacheSession)
            XCTAssertTrue(s.player.cachedTimeRanges.isEmpty)
            XCTAssertEqual(s.player.cacheProgress.cachedBytes, 0)
            s.measurements.append(["operation": "cache-default-untouched", "effectiveUseCache": s.player.useCache])
        }
        XCTAssertEqual(s.player.duration, clip.expectedDuration, accuracy: 0.2)
        let first = s.sink.firstPresentationTime ?? 0
        if cache {
            try require(until(60) { s.player.cachedTimeRanges.contains { $0.start <= 0.001 && $0.end >= min(12, s.player.duration) } || s.failure != nil }, "Private HLS initial cache did not fill")
            XCTAssertGreaterThan(s.player.cacheProgress.cachedBytes, 0)
        }
        func measure(_ phase: String, rate: Float, seconds: Double) throws {
            s.player.rate = rate; s.player.play()
            let began = ProcessInfo.processInfo.systemUptime, origin = s.player.currentTime
            let initialPTS = s.sink.lastPresentationTime, initialFrames = s.sink.frames
            var previousPTS = initialPTS, gap = 0.0, maximumGap = 0.0, previousWall = began, backwards = 0
            var activeWall = 0.0, activeClockDelta = 0.0, activePictureDelta = 0.0, activeGap = 0.0, maximumActiveGap = 0.0
            var previousClock = origin, previousSamplePTS = initialPTS
            var previousBuffering = s.player.decoder?.buffering ?? true
            let finishedBefore = s.finished
            var maximumBackwardClockStep = 0.0, minimumDuration = s.player.duration, maximumDuration = s.player.duration
            var samples: [[String: Any]] = []
            while ProcessInfo.processInfo.systemUptime - began < seconds && s.failure == nil {
                pump(0.03)
                let now = ProcessInfo.processInfo.systemUptime, pts = s.sink.lastPresentationTime
                let clock = s.player.currentTime, buffering = s.player.decoder?.buffering ?? true
                maximumBackwardClockStep = max(maximumBackwardClockStep, previousClock - clock)
                minimumDuration = min(minimumDuration, s.player.duration); maximumDuration = max(maximumDuration, s.player.duration)
                if !buffering && !previousBuffering {
                    activeWall += now - previousWall
                    activeClockDelta += max(0, clock - previousClock)
                    activePictureDelta += max(0, pts - previousSamplePTS)
                    activeGap = pts > previousSamplePTS + 0.0001 ? 0 : activeGap + now - previousWall
                    maximumActiveGap = max(maximumActiveGap, activeGap)
                } else { activeGap = 0 }
                if pts < previousPTS - 0.1 { backwards += 1 }
                if pts > previousPTS + 0.0001 { gap = 0; previousPTS = pts }
                else { gap += now - previousWall }
                maximumGap = max(maximumGap, gap); previousWall = now
                previousClock = clock; previousSamplePTS = pts; previousBuffering = buffering
                samples.append(["wall": now - began, "clock": clock, "duration": s.player.duration,
                    "videoPTS": pts, "buffering": buffering, "finished": s.finished])
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let delta = s.player.currentTime - origin, videoDelta = s.sink.lastPresentationTime - initialPTS
            s.measurements.append(["operation": "private-hls-rate", "clip": clip.label, "phase": phase,
                "requestedRate": rate, "wall": elapsed, "clockRate": delta / elapsed, "pictureRate": videoDelta / elapsed,
                "maximumImageGap": maximumGap, "backwards": backwards, "frames": s.sink.frames - initialFrames,
                "activeWall": activeWall, "activeClockRate": activeClockDelta / max(0.001, activeWall),
                "activePictureRate": activePictureDelta / max(0.001, activeWall), "maximumActiveImageGap": maximumActiveGap,
                "maximumBackwardClockStep": maximumBackwardClockStep, "minimumDuration": minimumDuration,
                "maximumDuration": maximumDuration, "finishCallbacks": s.finished - finishedBefore,
                "samples": samples,
                "cache": s.player.decoder?.cacheDiagnostics ?? [:], "decoder": s.player.decoder?.diagnosticSnapshot ?? "closed"])
            XCTAssertNil(s.failure)
            if leaveCacheDefault {
                XCTAssertLessThanOrEqual(maximumBackwardClockStep, 0.05, "Default-cache playback clock moved backwards at a segment boundary")
                XCTAssertEqual(minimumDuration, clip.expectedDuration, accuracy: 0.2)
                XCTAssertEqual(maximumDuration, clip.expectedDuration, accuracy: 0.2)
                XCTAssertEqual(s.finished, finishedBefore, "didFinish arrived before the measured interval reached the VOD end")
                XCTAssertTrue(s.player.cachedTimeRanges.isEmpty)
            }
            XCTAssertEqual(backwards, 0)
            XCTAssertGreaterThan(s.sink.frames, initialFrames + 3)
            if cache {
                XCTAssertEqual(delta / elapsed, Double(rate), accuracy: Double(rate) * 0.25)
                XCTAssertGreaterThan(videoDelta / elapsed, Double(rate) * 0.65, "Clock advanced but private HLS picture did not follow")
                XCTAssertLessThan(maximumGap, 0.5, "Private HLS picture stalled with cache enabled")
            } else {
                // Uncached file boundaries include synchronous network opens.
                // Report their whole-window cost, then verify rate while the
                // SDK is playing and bounded recovery from any buffering.
                XCTAssertGreaterThan(activeWall, elapsed * 0.25)
                XCTAssertGreaterThan(delta / elapsed, Double(rate) * 0.3)
                XCTAssertEqual(activeClockDelta / max(0.001, activeWall), Double(rate), accuracy: Double(rate) * 0.25)
                XCTAssertGreaterThan(activePictureDelta / max(0.001, activeWall), Double(rate) * 0.65)
                XCTAssertLessThan(maximumActiveGap, 0.5, "Uncached picture stalled outside buffering")
                if s.player.decoder?.buffering == true {
                    let frameCount = s.sink.frames
                    try require(until(15) { s.failure != nil || s.player.decoder?.buffering == false && s.sink.frames > frameCount }, "Uncached boundary never recovered")
                }
            }
        }
        func seek(_ target: Double, rate: Float) throws {
            s.player.pause(); s.player.rate = rate
            let frames = s.sink.frames, began = ProcessInfo.processInfo.systemUptime
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(20) { completed != nil || s.failure != nil }, "Private HLS seek callback missing")
            XCTAssertEqual(completed, true)
            s.player.play()
            let expected = max(first, target), forwardTolerance = max(0.75, Double(rate) * 0.1)
            let rendered = until(20) {
                s.failure != nil || s.sink.frames > frames && s.sink.lastPresentationTime >= expected - 0.75 &&
                    s.sink.lastPresentationTime <= expected + forwardTolerance
            }
            s.measurements.append(["operation": "private-hls-seek", "clip": clip.label, "rate": rate,
                "target": target, "picture": s.sink.lastPresentationTime, "clock": s.player.currentTime,
                "seconds": ProcessInfo.processInfo.systemUptime - began, "decoder": s.player.decoder?.diagnosticSnapshot ?? "closed"])
            try require(rendered && s.failure == nil, "Private HLS seek did not render its target")
        }
        for rate in [Float(2), 4, 8, 16] {
            try seek(0, rate: 1)
            try measure("initial-\(rate)x", rate: rate, seconds: 3)
        }
        for rate in [Float(1), 2, 4, 8, 16] {
            for target in [0.0, s.player.duration / 2, s.player.duration - 2, 0] { try seek(target, rate: rate) }
        }
        if let boundary = clip.segmentDurations.first, s.player.duration > boundary + 5 {
            for rate in (leaveCacheDefault ? [Float(1), 2, 4, 8, 16] : [Float(2), 4, 8, 16]) {
                try seek(max(0, boundary - 2), rate: rate)
                let seconds = leaveCacheDefault && rate >= 4 ? min(12, (s.player.duration - s.player.currentTime - 8) / Double(rate)) : 3.5
                try measure("segment-boundary-\(rate)x", rate: rate, seconds: seconds)
                XCTAssertGreaterThan(s.sink.lastPresentationTime, boundary + 1)
            }
        }
        try seek(0, rate: 1)
        try measure("return-1x", rate: 1, seconds: 1)
        if leaveCacheDefault {
            let finishedBefore = s.finished
            try seek(s.player.duration - 2, rate: 16)
            try require(until(15) { s.finished > finishedBefore || s.failure != nil }, "Default-cache playback did not finish its actual tail")
            XCTAssertNil(s.failure)
            XCTAssertEqual(s.finished, finishedBefore + 1)
            XCTAssertEqual(s.player.currentTime, clip.expectedDuration, accuracy: 0.2)
            pump(0.1)
            XCTAssertEqual(s.finished, finishedBefore + 1, "Duplicate didFinish at actual EOF")
            // Exercise the client sequence directly: no wait between seek and Play.
            let target = clip.expectedDuration / 2, frames = s.sink.frames
            var completed: Bool?
            s.player.rate = 1
            s.player.seek(to: target) { completed = $0 }
            s.player.play()
            try require(until(20) { s.failure != nil || completed == true && s.sink.frames > frames && abs(s.sink.lastPresentationTime - target) < 0.75 }, "Immediate Play after seeking from EOF lost the requested target")
            XCTAssertNil(s.failure)
            XCTAssertEqual(s.finished, finishedBefore + 1, "Old didFinish leaked into post-EOF seek")
            s.measurements.append(["operation": "default-cache-natural-end-and-immediate-seek", "target": target,
                "clock": s.player.currentTime, "picture": s.sink.lastPresentationTime, "finishCallbacks": s.finished - finishedBefore])
        }
        if cache { XCTAssertGreaterThan(s.player.decoder?.cacheDiagnostics["diskReadBytes"] ?? 0, 0) }
        if policy == .hardware { XCTAssertGreaterThan(s.player.videoDecodingStatistics.hardwareFrames, 0) }
        if policy == .ffmpeg { XCTAssertGreaterThan(s.player.videoDecodingStatistics.ffmpegFrames, 0) }
    }

    func testPrivateHLSClip1AutomaticHighRatesSeekCache() throws { try checkPrivateHLS(0, cache: true, policy: .automatic) }
    func testPrivateHLSClip2AutomaticHighRatesSeekCache() throws { try checkPrivateHLS(1, cache: true, policy: .automatic) }
    func testPrivateHLSClip1FFmpegHighRatesSeekCache() throws { try checkPrivateHLS(0, cache: true, policy: .ffmpeg) }
    func testPrivateHLSClip2FFmpegHighRatesSeekCache() throws { try checkPrivateHLS(1, cache: true, policy: .ffmpeg) }
    func testPrivateHLSClip1FFmpegHighRatesSeekWithoutCache() throws { try checkPrivateHLS(0, cache: false, policy: .ffmpeg) }
    func testPrivateHLSClip2FFmpegHighRatesSeekWithoutCache() throws { try checkPrivateHLS(1, cache: false, policy: .ffmpeg) }
    func testPrivateHLSClip1HardwareHighRatesSeekCache() throws { try checkPrivateHLS(0, cache: true, policy: .hardware) }
    func testPrivateHLSClip2HardwareHighRatesSeekCache() throws { try checkPrivateHLS(1, cache: true, policy: .hardware) }
    func testPrivateHLSClip1UntouchedCacheDefaultHighRatesSeek() throws { try checkPrivateHLS(0, cache: false, policy: .automatic, leaveCacheDefault: true) }
    func testPrivateHLSClip2UntouchedCacheDefaultHighRatesSeek() throws { try checkPrivateHLS(1, cache: false, policy: .automatic, leaveCacheDefault: true) }

    /// Private API recordings are installed in app Documents, never in Git.
    func testCloudMP4ReviewControlsAndWarmReplayFromManifest() throws {
        struct Clip: Decodable {
            let file_url: URL
            let duration: Double
            let method: String
            let is_encrypted: Bool
        }
        struct Input: Decodable { let recordings: [Clip] }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let file = documents.appendingPathComponent("FTPlayerCloudMP4Review.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("Opt-in: install FTPlayerCloudMP4Review.json for actual cloud MP4 playback")
        }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: file))
        XCTAssertFalse(input.recordings.isEmpty)
        for clip in input.recordings.prefix(3) {
            XCTAssertEqual(clip.method, "cloud-mp4"); XCTAssertFalse(clip.is_encrypted)
            XCTAssertTrue(["http", "https"].contains(clip.file_url.scheme?.lowercased() ?? ""))
            let session = try start(clip.file_url, cache: true, policy: .ffmpeg, timeout: 35)
            try assertPlayback(session, timeout: 15)
            XCTAssertEqual(session.player.duration, clip.duration, accuracy: 2)
            XCTAssertGreaterThan(session.player.videoDecodingStatistics.ffmpegFrames, 0)
            XCTAssertEqual(session.player.videoDecodingStatistics.hardwareFrames, 0)
            let directory = session.player.cacheSession?.directory
            try require(until(12) { session.player.downloadProgress > 0 }, "Cloud MP4 cache did not report received bytes")
            for (rate, fraction) in [(Float(1), 0.5), (4, 0.05), (16, 0.85), (1, 0.002)] {
                session.player.rate = rate
                let target = session.player.duration * fraction
                let frames = session.sink.frames, began = ProcessInfo.processInfo.systemUptime
                var completed: Bool?
                session.player.seek(to: target) { completed = $0 }
                try require(until(20) { completed != nil || session.failure != nil }, "Cloud seek callback missing")
                XCTAssertEqual(completed, true)
                try require(until(15) {
                    let pts = session.player.decoder?.currentVideoFrame?.position ?? -1
                    return session.failure != nil || session.sink.frames > frames && pts >= target - 0.3 && pts <= target + max(1.5, Double(rate) * 0.3)
                }, "Cloud MP4 seek did not render the requested position")
                session.measurements.append(["operation": "cloud-mp4-seek", "rate": rate, "target": target,
                    "actualPTS": session.player.decoder?.currentVideoFrame?.position ?? -1,
                    "seconds": ProcessInfo.processInfo.systemUptime - began])
                // A seek preview can precede clock restart. If the network
                // buffers, require recovery at the same rate and a stable sample.
                var verifiedRate = false
                for attempt in 1...3 {
                    let warmup = session.player.currentTime
                    try require(until(8) {
                        session.failure != nil || session.player.currentTime > warmup + 0.15 && session.player.decoder?.buffering == false
                    }, "Cloud playback clock did not resume at the requested rate")
                    let stateIndex = session.states.count, framesBefore = session.sink.frames
                    let progress = session.player.currentTime, started = ProcessInfo.processInfo.systemUptime
                    pump(0.8)
                    let elapsed = ProcessInfo.processInfo.systemUptime - started, delta = session.player.currentTime - progress
                    let buffering = session.player.decoder?.buffering != false || session.states.dropFirst(stateIndex).contains("buffering")
                    session.measurements.append(["operation": "cloud-mp4-rate", "rate": rate, "attempt": attempt,
                        "wallSeconds": elapsed, "mediaDelta": delta, "buffering": buffering])
                    XCTAssertNil(session.failure)
                    if !buffering {
                        XCTAssertGreaterThanOrEqual(delta, Double(rate) * elapsed * 0.3)
                        XCTAssertLessThanOrEqual(delta, Double(rate) * elapsed * 2.5 + 0.5)
                        XCTAssertGreaterThan(session.sink.frames, framesBefore)
                        verifiedRate = true; break
                    }
                }
                XCTAssertTrue(verifiedRate, "Cloud playback never completed a stable sample at the requested rate")
            }
            session.player.pause(); pump(0.1)
            let paused = session.player.currentTime; pump(0.25)
            XCTAssertEqual(session.player.currentTime, paused, accuracy: 0.1)
            session.player.isMuted = true; XCTAssertTrue(session.player.isMuted)
            let target = session.player.duration - 2
            var completed: Bool?
            session.player.seek(to: target) { completed = $0 }
            try require(until(20) { completed != nil || session.failure != nil }, "Paused cloud seek timed out")
            XCTAssertEqual(completed, true); XCTAssertEqual(session.player.currentTime, target, accuracy: 0.15)
            let frames = session.sink.frames
            session.player.play()
            try require(until(10) { session.sink.frames > frames + 3 || session.failure != nil }, "Muted resume did not render")
            session.player.isMuted = false
            session.player.stop()
            let cached = session.player.downloadProgress
            session.ready = false
            let beforeReplay = session.sink.frames
            session.player.play()
            try require(until(20) { session.ready && session.sink.frames > beforeReplay + 3 || session.failure != nil }, "Cloud MP4 warm replay did not render")
            XCTAssertNil(session.failure)
            XCTAssertEqual(session.player.cacheSession?.directory, directory)
            XCTAssertGreaterThanOrEqual(session.player.downloadProgress, cached - 0.001)
            XCTAssertGreaterThan(session.player.decoder?.cacheDiagnostics["diskReadBytes"] ?? 0, 0)
            let stats = session.player.videoDecodingStatistics
            XCTAssertGreaterThan(stats.ffmpegFrames, 0); XCTAssertEqual(stats.hardwareFrames, 0)
            session.measurements.append(["operation": "cloud-mp4-warm-replay", "retainedFraction": cached,
                "replayFraction": session.player.downloadProgress, "cache": session.player.decoder?.cacheDiagnostics ?? [:],
                "ffmpegFrames": stats.ffmpegFrames, "hardwareFrames": stats.hardwareFrames])
            session.stop()
        }
    }

    private struct Stream: Decodable {
        let id: String
        let url: URL
        let video: Bool
        let videoEnd: Double?
    }
    func testHlsMuxMasterCachedSustained16x() throws { try checkMuxCachedSustained16x(.automatic) }
    func testHlsMuxMasterFFmpegCachedSustained16x() throws { try checkMuxCachedSustained16x(.ffmpeg) }
    func testHlsMuxMasterHardwareCachedSustained16x() throws { try checkMuxCachedSustained16x(.hardware) }
    private func checkMuxCachedSustained16x(_ policy: FTVideoDecodingPolicy) throws {
        let catalog = try JSONDecoder().decode([Stream].self, from: internetStreamCatalogData())
        let url = try configuredInternetSource(catalog.first { $0.id == "hls-master" }, id: "hls-master").url
        let session = try start(url, cache: true, policy: policy, timeout: 45)
        let controller = UIViewController(), render = FTMediaRendererView()
        controller.view = render
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller; window.makeKeyAndVisible()
        let adapter = StartupBenchmarkRenderer(view: render, sink: session.sink)
        attachVideoSink(adapter, to: session.player)
        defer { window.isHidden = true }
        try assertPlayback(session)
        session.player.pause()
        try require(until(35) { session.player.cachedTimeRanges.contains { $0.start == 0 && $0.end >= 50 } }, "Mux master did not cache the initial playback window")
        session.player.rate = 16
        session.player.play()
        let began = ProcessInfo.processInfo.systemUptime, initial = session.player.currentTime
        var last = began, lastPTS = session.sink.lastPresentationTime, cachedGap = 0.0, maxGap = 0.0, cachedWall = 0.0, maxCachedLag = 0.0
        var backwardImages = 0
        var samples: [[String: Any]] = []
        while ProcessInfo.processInfo.systemUptime-began < 16 && session.failure == nil && session.finished == 0 {
            pump(0.05)
            let now = ProcessInfo.processInfo.systemUptime, elapsed = now-last
            last = now
            let position = session.player.currentTime, pts = session.sink.lastPresentationTime
            let covered = session.player.cachedTimeRanges.contains { $0.start <= position && $0.end >= position+1 }
            if covered { cachedWall += elapsed; maxCachedLag = max(maxCachedLag, (position-pts)/16) }
            if pts < lastPTS-0.05 { backwardImages += 1 }
            if pts > lastPTS + 0.0001 { cachedGap = 0; lastPTS = pts }
            else if covered { cachedGap += elapsed }
            else { cachedGap = 0 }
            maxGap = max(maxGap, cachedGap)
            if samples.isEmpty || now-began-(samples.last?["wall"] as? Double ?? 0) >= 0.25 {
                samples.append(["wall": now-began, "progress": position, "videoPTS": pts, "frames": session.sink.frames,
                    "cached": covered, "cachedImageGap": cachedGap, "buffering": session.player.decoder?.buffering ?? true,
                    "decoder": session.player.decoder?.diagnosticSnapshot ?? "closed"])
            }
        }
        session.measurements.append(["operation": "mux-master-cached-sustained16", "policy": policy.rawValue,
            "mediaDelta": session.player.currentTime-initial, "cachedWall": cachedWall, "maxCachedImageGap": maxGap, "maxCachedAVLagWall": maxCachedLag, "backwardImages": backwardImages, "samples": samples])
        XCTAssertNil(session.failure)
        XCTAssertGreaterThan(cachedWall, 4, "Not enough playback in an already cached interval")
        XCTAssertLessThan(maxGap, 0.35, "Video froze at 16x while media was already cached")
        XCTAssertLessThan(maxCachedLag, 0.75, "Updating images still lagged far behind the audio clock")
        XCTAssertEqual(backwardImages, 0, "Displayed PTS moved backward without a seek")
        let statistics = session.player.videoDecodingStatistics
        if policy == .hardware { XCTAssertGreaterThan(statistics.hardwareFrames, 0); XCTAssertEqual(statistics.ffmpegFrames, 0) }
        if policy == .ffmpeg { XCTAssertGreaterThan(statistics.ffmpegFrames, 0); XCTAssertEqual(statistics.hardwareFrames, 0) }
        XCTAssertGreaterThan(session.player.currentTime-initial, 80, "16x playback did not advance through multiple segments")
        session.player.rate = 1
        let frames = session.sink.frames
        try require(until(10) { session.sink.frames > frames+3 || session.failure != nil }, "No recovery after returning from16x")
        XCTAssertNil(session.failure)
    }
    func testHLSMasterCachedPacketSeekKeepsAudioVideoOrigins() throws { try checkMasterPacketOrigins("hls-apple-fmp4") }
    func testHLSTSMasterCachedPacketSeekKeepsAudioVideoOrigins() throws { try checkMasterPacketOrigins("hls-apple-ts") }
    private func checkMasterPacketOrigins(_ id: String) throws {
        continueAfterFailure = true
        let catalog = try JSONDecoder().decode([Stream].self, from: internetStreamCatalogData())
        let url = try configuredInternetSource(catalog.first { $0.id == id }, id: id).url
        let format = FTFormatContext(contentURL: url, videoFormat: .m3u8)
        defer { format.destroy() }
        format.setupSync(timeoutSeconds: 90, useCache: true)
        XCTAssertNil(format.error)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var rows: [[String: Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "master-packet-origins"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        for target in [Double(-1), 9, 0, 10, 8.992005, 0] {
            if target >= 0 { XCTAssertTrue(format.seekFile(withFFTimebase: target)) }
            var audio: Double?, video: Double?, firstKey: Double?, videoIsKey = false
            for _ in 0..<2048 {
                let result = format.readFrame(packet)
                guard result >= 0, let value = packet?.pointee else { break }
                if value.stream_index == Int32(format.audioTrack!.index), audio == nil { audio = Double(value.pts) * format.audioTimebase - format.startTime }
                if value.stream_index == Int32(format.videoTrack!.index), video == nil {
                    video = Double(value.pts) * format.videoTimebase - format.startTime
                    videoIsKey = value.flags & AV_PKT_FLAG_KEY != 0
                }
                if value.stream_index == Int32(format.videoTrack!.index), firstKey == nil, value.flags & AV_PKT_FLAG_KEY != 0 {
                    firstKey = Double(value.pts) * format.videoTimebase - format.startTime
                }
                av_packet_unref(packet)
                if audio != nil && video != nil && firstKey != nil { break }
            }
            rows.append(["target": target, "start": format.startTime, "audio": audio ?? -999, "video": video ?? -999, "videoIsKey": videoIsKey, "firstKey": firstKey ?? -999,
                         "audioTimebase": format.audioTimebase, "videoTimebase": format.videoTimebase])
            if target >= 0 {
                XCTAssertLessThanOrEqual(try XCTUnwrap(firstKey), target + 0.1, "Seek lost the keyframe needed to decode the requested position")
                XCTAssertLessThanOrEqual(try XCTUnwrap(audio), target + 0.1)
                XCTAssertLessThanOrEqual(try XCTUnwrap(video), target + 0.1)
            }
            if target != 0 {
                for _ in 0..<4096 {
                    let result = format.readFrame(packet)
                    guard result >= 0, let value = packet?.pointee else { break }
                    let reached = value.stream_index == Int32(format.videoTrack!.index) && Double(value.pts) * format.videoTimebase - format.startTime >= 20
                    av_packet_unref(packet)
                    if reached { break }
                }
            }
        }
    }
    func testCatalogControls_mp4_h264() throws { try checkCatalogControls("mp4-h264") }
    func testCatalogControls_mp4_hevc() throws { try checkCatalogControls("mp4-hevc") }
    func testCatalogControls_webm_vp9() throws { try checkCatalogControls("webm-vp9") }
    func testCatalogControls_hls_master() throws { try checkCatalogControls("hls-master") }
    func testCatalogControls_hls_media() throws { try checkCatalogControls("hls-media") }
    func testCatalogControls_hls_apple_ts() throws { try checkCatalogControls("hls-apple-ts") }
    func testCatalogControls_hls_apple_fmp4() throws { try checkCatalogControls("hls-apple-fmp4") }
    func testCatalogControls_hls_hevc() throws { try checkCatalogControls("hls-hevc") }
    func testCatalogControls_dash_h264() throws { try checkCatalogControls("dash-h264") }
    func testCatalogControls_flv_public() throws { try checkCatalogControls("flv-public") }
    func testCatalogControls_mp4_h264_w3c() throws { try checkCatalogControls("mp4-h264-w3c") }
    func testCatalogControls_mp4_hevc_photoprism_tsu() throws { try checkCatalogControls("mp4-hevc-photoprism-tsu") }
    func testCatalogControls_mp4_hevc_jellyfish_1080() throws { try checkCatalogControls("mp4-hevc-jellyfish-1080") }
    func testCatalogControls_mp4_hevc_photoprism_1080() throws { try checkCatalogControls("mp4-hevc-photoprism-1080") }
    func testCatalogControls_mp4_hevc_photoprism_4k() throws { try checkCatalogControls("mp4-hevc-photoprism-4k") }
    func testCatalogControls_hls_hevc_720p60() throws { try checkCatalogControls("hls-hevc-720p60") }
    func testCatalogControls_hls_hevc_1080p60() throws { try checkCatalogControls("hls-hevc-1080p60") }
    func testCatalogControls_webm_vp8() throws { try checkCatalogControls("webm-vp8") }
    func testCatalogControls_mkv_h264() throws { try checkCatalogControls("mkv-h264") }
    func testCatalogControls_hls_mux_pts_shift() throws { try checkCatalogControls("hls-mux-pts-shift") }
    func testCatalogControls_hls_hevc_ts_public() throws { try checkCatalogControls("hls-hevc-ts-public") }
    func testCatalogControls_hls_apple_hdr10plus() throws { try checkCatalogControls("hls-apple-hdr10plus") }
    func testCatalogControls_mp4_hevc_camera() throws { try checkCatalogControls("mp4-hevc-camera") }
    func testCatalogControls_mov_pcm_s16be() throws { try checkCatalogControls("mov-pcm-s16be") }
    func testCatalogControls_hls_oceans_aes128() throws { try checkCatalogControls("hls-oceans-aes128") }
    func testCatalogControls_hls_mux_sample_aes() throws { try checkCatalogControls("hls-mux-sample-aes") }
    func testCatalogControls_hls_aes128_audio() throws { try checkCatalogControls("hls-aes128-audio") }
    func testCatalogControls_hls_shaka_angel_one() throws { try checkCatalogControls("hls-shaka-angel-one") }
    func testCatalogControls_hls_unified_tos() throws { try checkCatalogControls("hls-unified-tos") }
    func testCatalogControls_hls_jw_muxed_fmp4() throws { try checkCatalogControls("hls-jw-muxed-fmp4") }
    func testCatalogControls_hls_fdr() throws { try checkCatalogControls("hls-fdr") }
    func testCatalogControls_hls_surveillance() throws { try checkCatalogControls("hls-surveillance") }
    func testCatalogControls_hls_mp3_vod() throws { try checkCatalogControls("hls-mp3-vod") }
    func testCatalogControls_hls_captions() throws { try checkCatalogControls("hls-captions") }
    func testCatalogControls_hls_elephants_audio() throws { try checkCatalogControls("hls-elephants-audio") }
    func testCatalogControls_hls_wistia_pes() throws { try checkCatalogControls("hls-wistia-pes") }
    func testCatalogControls_hls_hevc_4k() throws { try checkCatalogControls("hls-hevc-4k") }
    func testCatalogControls_mov_camera() throws { try checkCatalogControls("mov-camera") }
    func testCatalogControls_webm_vp9_earth() throws { try checkCatalogControls("webm-vp9-earth") }
    func testCatalogControls_avi_mpeg4_mp3() throws { try checkCatalogControls("avi-mpeg4-mp3") }
    func testCatalogControls_hls_dai_discontinuity() throws { try checkCatalogControls("hls-dai-discontinuity") }
    func testCatalogControls_hls_custom_iv() throws { try checkCatalogControls("hls-custom-iv") }
    func testCatalogControls_hls_pdt_large_gaps() throws { try checkCatalogControls("hls-pdt-large-gaps") }
    func testCatalogControls_hls_av_start_gap() throws { try checkCatalogControls("hls-av-start-gap") }
    func testCatalogControls_hls_audio_pdt_gap() throws { try checkCatalogControls("hls-audio-pdt-gap") }

    private func checkCatalogControls(_ id: String, availableDuration: Double? = nil) throws {
        if id == "dash-h264", !FTFormatContext.supportsInputFormat("dash") {
            try testDASHCapabilityAndGracefulFailure()
            return // Capability/error only; never report seek/16x as exercised.
        }
        let streams = try JSONDecoder().decode([Stream].self, from: internetStreamCatalogData())
        let stream = try configuredInternetSource(streams.first { $0.id == id }, id: id)
        let s = try start(stream.url, cache: true, timeout: 90)
        let controller = UIViewController(), render = FTMediaRendererView()
        controller.view = render
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller; window.makeKeyAndVisible()
        let adapter = StartupBenchmarkRenderer(view: render, sink: s.sink)
        attachVideoSink(adapter, to: s.player)
        defer { window.isHidden = true }
        try assertPlayback(s, video: stream.video, timeout: 20)
        let duration = availableDuration ?? s.player.duration, initialVideoPTS = s.sink.firstPresentationTime ?? 0
        s.measurements.append(["operation": "catalog-control-scope", "id": id, "declaredDuration": s.player.duration,
            "testedDuration": duration, "policy": "automatic", "width": s.player.mediaInfo?.width ?? 0, "height": s.player.mediaInfo?.height ?? 0])
        try require(duration.isFinite && duration > 0.5 && duration < 86400, "Catalog controls require a finite VOD duration")
        let directory = try XCTUnwrap(s.player.cacheSession?.directory)
        func decodedAudio() -> Int64 {
            let field = s.player.decoder?.diagnosticSnapshot.split(separator: " ").first { $0.hasPrefix("audioDecodedSamples=") }
            return field.flatMap { Int64($0.dropFirst("audioDecodedSamples=".count)) } ?? 0
        }
        func cached(through end: Double) -> Bool {
            s.player.cachedTimeRanges.contains { $0.start <= 0.001 && $0.end + 0.001 >= end }
        }
        func seek(_ target: Double, phase: String) throws {
            s.player.pause()
            s.player.rate = 1
            let frames = s.sink.frames, began = ProcessInfo.processInfo.systemUptime
            let covered = s.player.cachedTimeRanges.contains { $0.start <= target && $0.end >= min(duration, target + 0.1) }
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(35) { completed != nil || s.failure != nil }, "Seek callback missing: \(id) target=\(target)")
            XCTAssertEqual(completed, true)
            s.player.play()
            let expected = max(min(target, stream.videoEnd ?? duration), initialVideoPTS)
            let rendered = until(20) {
                s.failure != nil || (stream.video ? s.sink.frames > frames && abs(s.sink.lastPresentationTime - expected) <= 0.5
                    : decodedAudio() > 0 && s.player.currentTime >= target && s.player.currentTime <= target + 0.5)
            }
            s.measurements.append(["operation": "catalog-control-seek", "id": id, "phase": phase,
                "target": target, "expectedVideoPTS": expected, "actualVideoPTS": s.sink.lastPresentationTime,
                "clock": s.player.currentTime, "cachedBeforeSeek": covered, "seconds": ProcessInfo.processInfo.systemUptime - began,
                "cache": s.player.decoder?.cacheDiagnostics ?? [:]])
            try require(rendered && s.failure == nil, "Seek did not render the requested position: \(id) target=\(target)")
            s.player.pause()
            // Leading audio can keep the common clock at the requested time
            // while the first video picture starts later. Video-only inputs
            // instead anchor their clock to that first available picture.
            XCTAssertGreaterThanOrEqual(s.player.currentTime, target - 0.6)
            XCTAssertLessThanOrEqual(s.player.currentTime, max(target, initialVideoPTS) + 0.6)
        }
        for (target, phase) in [(0.0, "begin"), (duration * 0.5, "middle"),
                                 (duration - min(0.8, duration * 0.2), "near-end"), (0.0, "backward")] {
            try seek(target, phase: phase)
        }
        let fastEnd = min(64, duration - min(0.5, duration * 0.25))
        try require(until(90) { cached(through: min(32, fastEnd)) || s.failure != nil }, "Initial control window was not cached: \(id)")
        var primingSeeks = 0
        while !cached(through: fastEnd) {
            // The byte budget may fill before the 50s time window on 4K input.
            // Advance from the real contiguous prefix rather than assuming
            // one seek to 32s will cache every byte through 64s.
            try require(primingSeeks < 32, "Cache priming did not converge: \(id)")
            let prefix = s.player.cachedTimeRanges.first(where: { $0.start <= 0.001 })?.end ?? 0
            primingSeeks += 1
            try seek(max(0, prefix - 0.1), phase: "prime-fast-window-\(primingSeeks)")
            try require(until(90) { cached(through: min(fastEnd, prefix + 1)) || s.failure != nil }, "Cache prefix stopped advancing: \(id)")
        }
        s.measurements.append(["operation": "catalog-cache-window-prepared", "id": id,
            "end": fastEnd, "primingSeeks": primingSeeks, "cacheBytes": s.player.cacheProgress.cachedBytes])
        try seek(0, phase: "cached-before-16x")
        try require(cached(through: fastEnd) && s.player.cacheProgress.cachedBytes > 0, "16x must start with its whole test interval cached")
        let stored = s.player.cacheProgress.cachedBytes
        let framesBefore = s.sink.frames, finishedBefore = s.finished
        let began = ProcessInfo.processInfo.systemUptime, origin = s.player.currentTime
        var last = began, lastPTS = s.sink.lastPresentationTime
        var gap = 0.0, maxGap = 0.0, cachedWall = 0.0, maxLag = 0.0, backward = 0
        var samples: [[String: Any]] = []
        s.player.rate = 16; s.player.play()
        while s.player.currentTime < fastEnd && s.finished == finishedBefore && s.failure == nil && ProcessInfo.processInfo.systemUptime - began < 15 {
            pump(0.02)
            let now = ProcessInfo.processInfo.systemUptime, elapsed = now - last
            last = now
            let clock = s.player.currentTime, pts = s.sink.lastPresentationTime
            let covered = s.player.cachedTimeRanges.contains { $0.start <= clock && $0.end + 0.001 >= min(duration, clock + 0.05) }
            if covered { cachedWall += elapsed }
            if stream.video && clock > origin + 0.05 {
                let hasVideo = stream.videoEnd.map { clock <= $0 + 1 / max(1, s.player.mediaInfo?.framesPerSecond ?? 1) } ?? true
                if pts < lastPTS - 0.05 { backward += 1 }
                if pts > lastPTS + 0.0001 { gap = 0; lastPTS = pts }
                else if covered && hasVideo { gap += elapsed }
                else { gap = 0 }
                maxGap = max(maxGap, gap)
                if covered && hasVideo { maxLag = max(maxLag, (clock - pts) / 16) }
            }
            if samples.isEmpty || now - began - (samples.last?["wall"] as? Double ?? 0) >= 0.1 {
                samples.append(["wall": now - began, "clock": clock, "videoPTS": pts, "frames": s.sink.frames,
                    "cached": covered, "buffering": s.player.decoder?.buffering ?? true])
            }
        }
        // Very short A/V inputs can cross the sample end or audio EOF between display ticks.
        // Give the queued final picture the same bounded render deadline before
        // pausing; pausing immediately on the audio callback freezes that queue.
        if stream.video, fastEnd < 2 || s.finished > finishedBefore {
            let minimumImageAdvance = min(1, (fastEnd - origin) * 0.25)
            _ = until(0.3) { s.sink.lastPresentationTime - max(origin, initialVideoPTS) > minimumImageAdvance }
        }
        s.player.pause()
        let elapsed = ProcessInfo.processInfo.systemUptime - began, delta = s.player.currentTime - origin
        let stats = s.player.videoDecodingStatistics
        s.measurements.append(["operation": "catalog-control-16x", "id": id, "requestedRate": 16,
            "mediaDelta": delta, "wall": elapsed, "measuredRate": delta / max(0.001, elapsed), "cachedWall": cachedWall,
            "maxCachedImageGap": maxGap, "maxCachedAVLagWall": maxLag, "backwardImages": backward,
            "frames": s.sink.frames - framesBefore, "hardwareFrames": stats.hardwareFrames, "ffmpegFrames": stats.ffmpegFrames,
            "cacheBytesBefore": stored, "cache": s.player.decoder?.cacheDiagnostics ?? [:], "samples": samples])
        XCTAssertNil(s.failure)
        try require(s.player.currentTime >= fastEnd - 0.1 || s.finished > finishedBefore, "16x did not traverse its cached test window")
        XCTAssertGreaterThan(delta, fastEnd * 0.8)
        XCTAssertGreaterThan(delta / max(0.001, elapsed), 6.4, "16x clock ran much slower than requested")
        XCTAssertGreaterThan(cachedWall, elapsed * 0.7, "16x ran outside cached coverage")
        if stream.video {
            XCTAssertGreaterThan(s.sink.frames - framesBefore, 2)
            // Short clips finish before a normal decode/reorder delay can be
            // expressed as a useful percentage of their total media duration.
            // Require multiple advancing pictures, then bound staleness in wall
            // time with the same freeze/clock-lag checks used for longer inputs.
            XCTAssertGreaterThan(s.sink.lastPresentationTime - max(origin, initialVideoPTS), min(1, (fastEnd - origin) * 0.25), "Clock advanced while the picture stayed behind")
            XCTAssertLessThan(maxGap, 0.35, "Picture froze at 16x in cached media")
            XCTAssertLessThan(maxLag, 0.75, "Cached 16x picture lagged the clock")
            XCTAssertEqual(backward, 0)
        } else { XCTAssertGreaterThan(decodedAudio(), 0) }
        XCTAssertGreaterThan(s.player.decoder?.cacheDiagnostics["diskReadBytes"] ?? 0, 0)
        s.player.rate = 1
        try seek(0, phase: "return-1x")
        let resumeClock = s.player.currentTime, resumeFrames = s.sink.frames
        s.player.play()
        try require(until(10) {
            s.failure != nil || s.player.currentTime > resumeClock + 0.15 && (!stream.video || s.sink.frames > resumeFrames + 2)
        }, "No 1x recovery after seek/16x")
        XCTAssertNil(s.failure)
        s.player.pause(); pump(0.05)
        let paused = s.player.currentTime; pump(0.2)
        XCTAssertEqual(s.player.currentTime, paused, accuracy: 0.1)
        s.player.stop(); s.ready = false
        let replayFrames = s.sink.frames
        s.player.play()
        try require(until(35) {
            s.failure != nil || s.ready && (stream.video ? s.sink.frames > replayFrames + 2 : s.player.currentTime > 0.1 && decodedAudio() > 0)
        }, "Cached warm replay failed after seek/16x")
        XCTAssertNil(s.failure)
        XCTAssertEqual(s.player.cacheSession?.directory, directory)
        XCTAssertGreaterThanOrEqual(s.player.cacheProgress.cachedBytes, stored)
        XCTAssertGreaterThan(s.player.decoder?.cacheDiagnostics["diskReadBytes"] ?? 0, 0)
        s.measurements.append(["operation": "catalog-control-recovered", "id": id, "rate": s.player.rate,
            "cache": s.player.decoder?.cacheDiagnostics ?? [:]])
    }

    func testOceansDistantCachedSeekRetainsPrerollKeyframe() throws {
        let streams = try JSONDecoder().decode([Stream].self, from: internetStreamCatalogData())
        let url = try configuredInternetSource(streams.first { $0.id == "hls-oceans-aes128" }, id: "hls-oceans-aes128").url
        let format = FTFormatContext(contentURL: url, videoFormat: .m3u8)
        defer { format.destroy() }
        format.setupSync(timeoutSeconds: 90, useCache: true)
        XCTAssertNil(format.error)
        let video = try XCTUnwrap(format.videoTrack)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        for _ in 0..<128 {
            guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
            let initialVideo = value.stream_index == Int32(video.index)
            av_packet_unref(packet)
            if initialVideo { break }
        }
        var rows: [[String: Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                a.name = "oceans-distant-seek-packets"; a.lifetime = .keepAlways; add(a)
            }
        }
        for target in [59.0, 117.2, 0] {
            XCTAssertTrue(format.seekFile(withFFTimebase: target))
            var key: Double?
            for _ in 0..<2048 {
                guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
                if value.stream_index == Int32(video.index), value.flags & AV_PKT_FLAG_KEY != 0 {
                    key = Double(value.pts) * format.videoTimebase - format.startTime
                }
                av_packet_unref(packet)
                if key != nil { break }
            }
            rows.append(["target": target, "firstKeyPTS": key ?? -1, "start": format.startTime])
            XCTAssertLessThanOrEqual(try XCTUnwrap(key), target + 0.1, "Distant HLS seek skipped the keyframe needed to reach the target")
        }
    }

    func testCatalogFLVDeclaredDurationExceedsPacketExtent() throws {
        let streams = try JSONDecoder().decode([Stream].self, from: internetStreamCatalogData())
        let url = try configuredInternetSource(streams.first { $0.id == "flv-public" }, id: "flv-public").url
        let format = FTFormatContext(contentURL: url, videoFormat: .unknown)
        defer { format.destroy() }
        format.setupSync(timeoutSeconds: 90, useCache: true)
        XCTAssertNil(format.error)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var videoEnd = 0.0, audioEnd = 0.0, count = 0, eof = false
        for _ in 0..<20000 {
            let result = format.readFrame(packet)
            if result < 0 { eof = result == FT_AVERROR_EOF; break }
            guard let value = packet?.pointee else { break }
            count += 1
            if value.pts != Int64.min {
                if Int(value.stream_index) == format.videoTrack?.index {
                    videoEnd = max(videoEnd, Double(value.pts + max(0, value.duration)) * format.videoTimebase - format.startTime)
                } else if Int(value.stream_index) == format.audioTrack?.index {
                    audioEnd = max(audioEnd, Double(value.pts + max(0, value.duration)) * format.audioTimebase - format.startTime)
                }
            }
            av_packet_unref(packet)
        }
        let data = try JSONSerialization.data(withJSONObject: ["metadataDuration": format.duration, "videoEnd": videoEnd,
            "audioEnd": audioEnd, "packets": count, "eof": eof, "cache": format.cacheDiagnostics], options: [.prettyPrinted, .sortedKeys])
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        a.name = "flv-source-packet-extent"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(eof); XCTAssertGreaterThan(videoEnd, 5)
        XCTAssertLessThan(max(videoEnd, audioEnd), format.duration * 0.2, "Re-audit the public partial FLV if its media extent changes")
        // Keep the ordinary full-metadata catalog case failing for its missing
        // tail. Separately exercise controls inside the packet extent that exists.
        try checkCatalogControls("flv-public", availableDuration: max(videoEnd, audioEnd))
    }

    private func check(_ id: String, expectHLSCache: Bool = false, expectInitialization: Bool = false, expectedHLSTracks: Int? = nil, expectedCodec: String? = nil, expectedSize: CGSize? = nil, minimumFPS: Double? = nil, expectedAudioCodec: String? = nil, expectKeyCache: Bool = false) throws {
        let streams = try JSONDecoder().decode([Stream].self, from: internetStreamCatalogData())
        let stream = try configuredInternetSource(streams.first { $0.id == id }, id: id)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: stream.url)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        var completed = false
        var endpointError: Error?
        var status = 0
        let task = session.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async { endpointError = error; status = (response as? HTTPURLResponse)?.statusCode ?? 0; completed = true }
        }
        task.resume()
        try require(until(35) { completed }, "ENDPOINT preflight timed out: \(stream.url)")
        try require(endpointError == nil && (200..<300).contains(status), "ENDPOINT HTTP \(status) error=\(String(describing: endpointError)): \(stream.url)")
        // Apple masters expose many video/audio variants. Independent ffprobe took
        // ~50s on this network; keep a bounded 90s startup budget for those masters.
        let startupBudget: TimeInterval = id == "hls-apple-ts" || id == "hls-apple-fmp4" ? 90 : 45
        let opened = ProcessInfo.processInfo.systemUptime
        // Match the Demo's default: every public link is opened with cache enabled.
        let playback = try start(stream.url, cache: true, timeout: startupBudget)
        let startup = ProcessInfo.processInfo.systemUptime - opened
        playback.measurements.append(["operation": "startup", "elapsed": startup, "budget": startupBudget])
        FTPlayerDiagnostic.shared.log("public startup id=\(id) seconds=\(startup) budget=\(startupBudget)", category: "test")
        try assertPlayback(playback, video: stream.video, timeout: 20)
        func decodedAudioSamples() -> Int64 {
            let field = playback.player.decoder?.diagnosticSnapshot.split(separator: " ").first { $0.hasPrefix("audioDecodedSamples=") }
            return field.flatMap { Int64($0.dropFirst("audioDecodedSamples=".count)) } ?? 0
        }
        if !stream.video {
            XCTAssertNil(playback.player.mediaInfo?.videoCodec)
            try require(until(5) { decodedAudioSamples() > 0 }, "Audio-only input did not decode PCM samples")
        }
        let initialVideoPTS = playback.sink.firstPresentationTime ?? 0
        let info = try XCTUnwrap(playback.player.mediaInfo)
        if let expectedCodec { XCTAssertEqual(info.videoCodec, expectedCodec, "Test must decode the requested codec") }
        if let expectedAudioCodec { XCTAssertEqual(info.audioCodec, expectedAudioCodec) }
        if let expectedSize {
            XCTAssertEqual(info.width, Int(expectedSize.width)); XCTAssertEqual(info.height, Int(expectedSize.height))
        }
        if let minimumFPS { XCTAssertGreaterThanOrEqual(info.framesPerSecond ?? 0, minimumFPS) }
        playback.measurements.append(["operation": "public-media", "id": id,
            "videoCodec": info.videoCodec ?? "", "width": info.width ?? 0, "height": info.height ?? 0,
            "fps": info.framesPerSecond ?? 0, "audioCodec": info.audioCodec ?? "", "initialVideoPTS": initialVideoPTS])
        let isFile = !["m3u8", "mpd"].contains(stream.url.pathExtension.lowercased())
        if isFile || expectHLSCache {
            try require(until(15) { playback.player.cacheProgress.cachedBytes > 0 || playback.failure != nil }, "Public source received no cache progress: \(id)")
            try require(playback.failure == nil && playback.player.cacheProgress.cachedBytes > 0, "Public source cache failed: \(id)")
        }
        if expectHLSCache {
            try require(until(15) { !playback.player.cachedTimeRanges.isEmpty }, "HLS media cache has no playable timeline")
            try require(until(2) { !playback.downloadProgressEvents.isEmpty && playback.player.cacheProgress.cachedBytes > 0 }, "HLS cache progress did not reach the UI delegate")
            if expectInitialization { XCTAssertGreaterThan(playback.player.decoder?.cacheDiagnostics["hlsInitCachedBytes"] ?? 0, 0) }
            if expectKeyCache { XCTAssertGreaterThan(playback.player.decoder?.cacheDiagnostics["hlsKeyCachedBytes"] ?? 0, 0, "Encrypted media must cache its decryption key") }
            if let expectedHLSTracks {
                XCTAssertEqual(playback.player.decoder?.cacheDiagnostics["hlsTracks"], Int64(expectedHLSTracks))
                XCTAssertNotNil(playback.player.mediaInfo?.audioCodec)
                XCTAssertGreaterThan(playback.player.decoder?.cacheDiagnostics["hlsAudioCachedBytes"] ?? 0, 0)
            }
            playback.player.pause()
            try require(until(20) {
                (playback.player.cachedTimeRanges.first(where: { $0.start == 0 })?.end ?? 0) >= min(12, playback.player.duration)
            }, "Master prefetch did not complete an initial A/V cache window")
            let cachedEnd = playback.player.cachedTimeRanges.first(where: { $0.start == 0 })!.end
            for target in [min(9, cachedEnd / 2), 0] {
                // A source may contain leading audio before its first video PTS.
                // Seeking there must preserve the original first picture; there
                // is no video at public time zero to assert against.
                let expectedPTS = max(target, initialVideoPTS)
                let frames = playback.sink.frames
                var completed: Bool?
                playback.player.seek(to: target) { completed = $0 }
                try require(until(15) { completed != nil || playback.failure != nil }, "Master cached seek did not complete")
                XCTAssertEqual(completed, true)
                playback.player.play()
                var firstPTS: Double?
                let rendered = until(15) {
                    if playback.sink.frames > frames, firstPTS == nil { firstPTS = playback.sink.lastPresentationTime }
                    return playback.failure != nil || playback.sink.frames > frames && abs(playback.sink.lastPresentationTime-expectedPTS) <= 0.5
                }
                playback.measurements.append(["operation": "public-master-cached-seek", "target": target,
                    "actualPTS": playback.sink.lastPresentationTime, "firstPTS": firstPTS ?? -1, "expectedPTS": expectedPTS,
                    "decoder": playback.player.decoder?.diagnosticSnapshot ?? "closed"])
                if !rendered {
                    FTPlayerDiagnostic.shared.flush()
                    let data = try Data(contentsOf: FTPlayerDiagnostic.shared.currentLogURL)
                    let seekLogs = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).filter {
                        $0.contains("seek keyframe") || $0.contains("seek target=") || $0.contains("reopened")
                    }.joined(separator: "\n")
                    let attachment = XCTAttachment(string: seekLogs); attachment.name = "failed-seek-anchors"; attachment.lifetime = .keepAlways; add(attachment)
                }
                try require(rendered, "Master cached seek did not output a frame at the requested time")
                playback.player.pause()
            }
            playback.player.play()
        }
        let directory = playback.player.cacheSession?.directory
        let fraction = playback.player.downloadProgress
        let storedBytes = playback.player.cacheProgress.cachedBytes
        if id == "flv-public", fraction < 1 {
            XCTAssertFalse(playback.player.cachedTimeRanges.contains { $0.start == 0 && $0.end >= playback.player.duration },
                           "Sparse FLV index reported the whole uncached file as available offline")
        }
        playback.measurements.append(["operation": "public-cache", "id": id,
            "fraction": fraction, "ranges": playback.player.cachedTimeRanges.map { ["start": $0.start, "end": $0.end] },
            "delegateFraction": playback.downloadProgressEvents.last ?? 0,
            "cachedBytes": playback.player.cacheProgress.cachedBytes, "totalBytesKnown": playback.player.cacheProgress.totalBytes != nil,
            "cache": playback.player.decoder?.cacheDiagnostics ?? [:]])
        if isFile {
            playback.player.stop()
            playback.ready = false
            let frames = playback.sink.frames
            playback.player.play()
            try require(until(30) {
                playback.failure != nil || playback.ready && (stream.video ? playback.sink.frames > frames + 2 : playback.player.currentTime > 0.1 && decodedAudioSamples() > 0)
            }, "Public file warm replay did not render: \(id)")
            try require(playback.failure == nil, "Public file warm replay failed: \(id)")
            XCTAssertEqual(playback.player.cacheSession?.directory, directory)
            XCTAssertGreaterThanOrEqual(playback.player.downloadProgress, fraction - 0.001)
            XCTAssertGreaterThanOrEqual(playback.player.cacheProgress.cachedBytes, storedBytes)
            XCTAssertGreaterThan(playback.player.decoder?.cacheDiagnostics["diskReadBytes"] ?? 0, 0)
            playback.measurements.append(["operation": "public-cache-warm-replay", "id": id,
                "fraction": playback.player.downloadProgress, "cache": playback.player.decoder?.cacheDiagnostics ?? [:]])
        } else if expectHLSCache {
            playback.player.stop()
            playback.ready = false
            let frames = playback.sink.frames
            playback.player.play()
            try require(until(30) { playback.failure != nil || playback.ready && playback.sink.frames > frames + 2 }, "HLS cache replay did not render")
            XCTAssertNil(playback.failure)
            XCTAssertEqual(playback.player.cacheSession?.directory, directory)
            XCTAssertGreaterThanOrEqual(playback.player.downloadProgress, fraction - 0.001)
            XCTAssertGreaterThanOrEqual(playback.player.cacheProgress.cachedBytes, storedBytes)
            XCTAssertGreaterThan(playback.player.decoder?.cacheDiagnostics["diskReadBytes"] ?? 0, 0, "HLS replay must read cached media from disk")
            playback.measurements.append(["operation": "public-cache-warm-replay", "id": id,
                "fraction": playback.player.downloadProgress, "cache": playback.player.decoder?.cacheDiagnostics ?? [:]])
        }
    }
    /// Opt-in batch startup benchmark. Input is private app Documents, never a
    /// token/recording URL checked into source. A fresh player owns a new cache per clip.
    func testRecordingDailyStartupBenchmarkFromManifest() throws {
        struct Clip: Decodable {
            let duration: Double
            let start_time: String
            let end_time: String
            let file_url: String
            let is_encrypted: Bool
        }
        struct Manifest: Decodable { let date: String; let recordings: [Clip] }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let input = documents.appendingPathComponent("FTPlayerStartupBenchmark.json")
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw XCTSkip("Opt-in: install FTPlayerStartupBenchmark.json in app Documents to benchmark a recording list")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: input))
        XCTAssertFalse(manifest.recordings.isEmpty)
        continueAfterFailure = true
        let output = documents.appendingPathComponent("FTPlayerStartupResults.jsonl")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output); defer { try? writer.close() }
        let controller = UIViewController(); controller.view.backgroundColor = .systemBackground
        let label = UILabel(); label.numberOfLines = 0; label.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        let render = FTMediaRendererView(); render.heightAnchor.constraint(equalToConstant: 400).isActive = true
        let stack = UIStackView(arrangedSubviews: [label, render]); stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 24)])
        let window = UIWindow(frame: UIScreen.main.bounds); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var failed = 0
        for (offset, clip) in manifest.recordings.enumerated() {
            try autoreleasepool {
                let index = offset + 1
                label.text = "Startup \(manifest.date) • \(index)/\(manifest.recordings.count)\n\(clip.start_time) → \(clip.end_time)\nĐang mở video — Auto decoder / cache mới"
                controller.view.layoutIfNeeded()
                let started = ProcessInfo.processInfo.systemUptime
                var row: [String: Any] = ["index": index, "date": manifest.date, "start": clip.start_time, "end": clip.end_time, "apiDuration": clip.duration, "budgetSeconds": 40, "openedUptime": started, "policy": "automatic", "coldCache": true]
                FTPlayerDiagnostic.shared.log("DAY STARTUP BEGIN index=\(index) total=\(manifest.recordings.count) start=\(clip.start_time)", category: "benchmark")
                if clip.is_encrypted || URL(string: clip.file_url) == nil {
                    row["result"] = "unsupported-input"; failed += 1
                } else {
                    let session = PlaybackSession(url: URL(string: clip.file_url)!, cache: true, policy: .automatic)
                    session.player.isMuted = true
                    let adapter = StartupBenchmarkRenderer(view: render, sink: session.sink)
                    attachVideoSink(adapter, to: session.player)
                    let cacheBefore = session.player.cacheSession?.directory
                    session.start()
                    let deadline = started + 40
                    while session.player.preparationState != .end && session.failure == nil && ProcessInfo.processInfo.systemUptime < deadline {
                        pump(0.01)
                    }
                    let firstFrame = session.preparationEvents.first { $0["state"] as? String == "end" }?["uptime"] as? Double
                    if firstFrame != nil {
                        let verifyUntil = ProcessInfo.processInfo.systemUptime + 4
                        while session.failure == nil && (session.sink.frames < 3 || session.player.currentTime < 0.15) && session.player.state != .finished && ProcessInfo.processInfo.systemUptime < verifyUntil { pump(0.01) }
                    }
                    let info = session.player.mediaInfo
                    let stats = session.player.videoDecodingStatistics
                    let progressed = session.sink.frames >= 3 && (session.player.currentTime >= 0.15 || session.player.state == .finished)
                    row["result"] = session.failure != nil ? "player-error" : firstFrame == nil ? "startup-timeout" : progressed ? "played" : "playback-stalled"
                    if row["result"] as? String != "played" { failed += 1 }
                    row["firstFrameSeconds"] = firstFrame.map { $0 - started } as Any?
                    row["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
                    row["states"] = session.preparationEvents
                    row["frames"] = session.sink.frames; row["currentTime"] = session.player.currentTime
                    row["ready"] = session.ready; row["callbacksMain"] = session.callbackThreadsAreMain
                    row["hardwareFrames"] = stats.hardwareFrames; row["ffmpegFrames"] = stats.ffmpegFrames; row["vtSoftwareFrames"] = stats.videoToolboxSoftwareFrames
                    row["cacheFraction"] = session.player.downloadProgress
                    row["cacheDirectory"] = session.player.cacheSession?.directory.lastPathComponent ?? ""
                    row["newCacheBeforeOpen"] = cacheBefore == nil
                    row["decoder"] = session.player.decoder?.diagnosticSnapshot ?? "none"
                    row["media"] = ["duration": info?.duration ?? 0, "format": info?.formatName ?? "", "videoCodec": info?.videoCodec ?? "", "width": info?.width ?? 0, "height": info?.height ?? 0, "fps": info?.framesPerSecond ?? 0, "audioCodec": info?.audioCodec ?? "", "sampleRate": info?.audioSampleRate ?? 0, "channels": info?.audioChannels ?? 0] as [String: Any]
                    if let error = session.failure as NSError? { row["error"] = ["domain": error.domain, "code": error.code] }
                    session.player.delegate = nil; session.player.stop()
                    // No session is retained in the superclass: release it and its cache
                    // before the next source. UI/renderer are reused, the player is not.
                }
                let status = row["result"] as? String ?? "unknown"
                label.text = "Startup \(manifest.date) • \(index)/\(manifest.recordings.count)\n\(clip.start_time) • \(status)\nFrame đầu: \(row["firstFrameSeconds"] ?? "—") giây"
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(0x0A)
                if #available(iOS 13.4, *) { try writer.write(contentsOf: data) }
                else { writer.write(data) }
                try writer.synchronize()
                FTPlayerDiagnostic.shared.log("DAY STARTUP END index=\(index) result=\(status) firstFrame=\(row["firstFrameSeconds"] ?? "—")", category: "benchmark")
                FTPlayerDiagnostic.shared.flush()
            }
            pump(0.15)
        }
        let attachment = XCTAttachment(data: try Data(contentsOf: output), uniformTypeIdentifier: "public.jsonl")
        attachment.name = "Daily-startup-benchmark-\(manifest.date)"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(failed, 0, "Some recordings failed; every item is retained in the JSONL report")
    }
    func testLoadControlHLSDoesNotReadTwentyMinutesAt16x() throws {
        let input = try hlsReviewInput(), s = try hlsReviewSession(input,mirror:true)
        s.player.pause(); s.player.rate = 16; pump(1.5)
        let end = s.player.cachedTimeRanges.first(where: { $0.start == 0 })?.end ?? 0
        XCTAssertGreaterThan(end,0)
        XCTAssertLessThanOrEqual(end,50+(input.segmentDurations.max() ?? 0),"16x warmed far beyond ExoPlayer's maximum media duration")
        s.measurements.append(["operation":"hls-media-time-window","cachedEnd":end,"cache":s.player.decoder?.cacheDiagnostics ?? [:]])
    }

    func testHLSReviewOnlineCacheProgressAndPrefetchFromManifest() throws {
        let input = try hlsReviewInput(), s = try hlsReviewSession(input)
        s.player.pause()
        var checkpoints: [[String: Int64]] = []
        for rate: Float in [1, 16] {
            s.player.rate = rate
            try require(until(25) {
                let stats = s.player.decoder?.cacheDiagnostics ?? [:]
                return stats["hlsKnownSizeSegments"] == Int64(input.segmentCount) && (s.player.cachedTimeRanges.first?.end ?? 0) >= min(50,input.expectedDuration)
            }, "Online HLS cache metadata/lookahead failed at \(rate)x")
            XCTAssertLessThanOrEqual(s.player.cachedTimeRanges.first?.end ?? 0,50+(input.segmentDurations.max() ?? 0))
            XCTAssertGreaterThan(s.player.downloadProgress,0)
            XCTAssertLessThanOrEqual(s.player.downloadProgress,1)
            try require(until { s.downloadProgressEvents.contains { $0 > 0 } }, "Demo download delegate still reported only zero")
            checkpoints.append(s.player.decoder?.cacheDiagnostics ?? [:])
        }
        s.measurements.append(["operation":"hls-online-cache-progress","checkpoints":checkpoints,"delegateLast":s.downloadProgressEvents.last ?? -1,"fraction":s.player.downloadProgress])
    }

    func testHLSReviewRateBasedPrefetchAndOfflineFromManifest() throws {
        let input = try hlsReviewInput(), session = try hlsReviewSession(input, mirror: true)
        session.player.pause()
        var budgets: [[String: Int64]] = []
        for rate: Float in [2, 4, 8, 16] {
            session.player.rate = rate
            let loaded = until(15) {
                let stats = session.player.decoder?.cacheDiagnostics ?? [:]
                return stats["hlsKnownSizeSegments"] == Int64(input.segmentCount) && (session.player.cachedTimeRanges.first?.end ?? 0) >= min(50,input.expectedDuration)
            }
            XCTAssertTrue(loaded, "HLS lookahead did not reach media-time target at \(rate)x")
            let stats = session.player.decoder?.cacheDiagnostics ?? [:]; budgets.append(stats)
            XCTAssertEqual(stats["loadMinMediaMilliseconds"],50000)
            XCTAssertEqual(stats["loadMaxMediaMilliseconds"],50000)
            XCTAssertLessThanOrEqual(session.player.cachedTimeRanges.first?.end ?? 0,50+(input.segmentDurations.max() ?? 0))
        }
        XCTAssertGreaterThan(session.player.downloadProgress,0)
        XCTAssertLessThanOrEqual(session.player.downloadProgress,1)
        let cachedEnd = try XCTUnwrap(session.player.cachedTimeRanges.first(where: { $0.start == 0 })).end
        let whole = session.player.downloadProgress >= 0.999
        var cachedPaths = Set<String>(), position = 0.0
        for (index, seconds) in input.segmentDurations.enumerated() {
            if position + seconds <= cachedEnd + 0.001 { cachedPaths.insert(String(format: "/segments/%03d.mp4",index)) }
            position += seconds
        }
        let before = session.player.decoder?.cacheDiagnostics["hlsCachedBytes"], requests = server!.requests.count
        session.player.rate = 1; pump(0.25)
        XCTAssertEqual(session.player.decoder?.cacheDiagnostics["loadMaxMediaMilliseconds"],50000)
        XCTAssertEqual(session.player.decoder?.cacheDiagnostics["hlsCachedBytes"],before)
        server!.setNetworkMode(.disconnect,dropExistingConnections:true)
        session.player.play()
        _ = hlsReviewSeek(session,target:cachedEnd/2,rate:16)
        _ = hlsReviewSeek(session,target:cachedEnd-2,rate:1)
        let after = server!.requests.dropFirst(requests)
        XCTAssertFalse(after.contains { line in cachedPaths.contains { line.contains($0) } },"Cached HLS resource was downloaded again")
        if whole { XCTAssertEqual(server!.requests.count,requests,"Fully cached HLS attempted upstream HTTP") }
        session.measurements.append(["operation":"hls-prefetch-rate-budgets","budgets":budgets])
    }

    private func hlsReviewWithoutCache(_ policy: FTVideoDecodingPolicy) throws {
        let input = try hlsReviewInput(), session = try start(hlsReviewSource(input), cache: false, policy: policy, timeout: 35)
        try assertPlayback(session)
        XCTAssertNil(session.player.cacheSession)
        XCTAssertTrue(hlsReviewSeek(session, target: session.player.duration/2, rate: 16))
        let start = ProcessInfo.processInfo.systemUptime, initial = session.player.currentTime
        var previous = initial, backwards = 0
        while ProcessInfo.processInfo.systemUptime-start < 5 && session.failure == nil {
            pump(0.05); let current = session.player.currentTime
            if current < previous-0.5 { backwards += 1 }; previous = current
        }
        session.measurements.append(["operation": "hls-cache-disabled16", "policy": policy.rawValue, "wall": ProcessInfo.processInfo.systemUptime-start, "mediaDelta": session.player.currentTime-initial, "backwardJumps": backwards])
        XCTAssertEqual(backwards, 0); XCTAssertGreaterThan(session.player.currentTime-initial, 40)
        XCTAssertEqual(session.player.downloadProgress, 0); XCTAssertTrue(session.player.cachedTimeRanges.isEmpty)
        XCTAssertTrue(hlsReviewSeek(session, target: 2, rate: 1)); hlsReviewBackend(session, policy: policy)
    }
    func testHLSReviewCacheDisabledHardwareFromManifest() throws { try hlsReviewWithoutCache(.hardware) }
    func testHLSReviewCacheDisabledFFmpegFromManifest() throws { try hlsReviewWithoutCache(.ffmpeg) }

    private struct HLSReviewInput: Decodable {
        let url: URL
        let expectedDuration: Double
        let mirrorDirectory: String
        let segmentDurations: [Double]
        let segmentCount: Int
        let useMirrorForAll: Bool?
    }
    private func hlsReviewInput() throws -> HLSReviewInput {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let file = documents.appendingPathComponent("FTPlayerHLSReview.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Opt-in HLS review: install FTPlayerHLSReview.json and mirrored segments in Documents") }
        return try JSONDecoder().decode(HLSReviewInput.self, from: Data(contentsOf: file))
    }
    private func hlsReviewSource(_ input: HLSReviewInput, mirror: Bool = false) throws -> URL {
        if mirror || input.useMirrorForAll == true {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            server = try FixtureHTTPServer(root: documents.appendingPathComponent(URL(fileURLWithPath: input.mirrorDirectory).lastPathComponent))
            return server!.url("index.m3u8")
        }
        return input.url
    }
    private func hlsReviewSession(_ input: HLSReviewInput, policy: FTVideoDecodingPolicy = .automatic, mirror: Bool = false) throws -> PlaybackSession {
        let session = try start(hlsReviewSource(input, mirror: mirror), cache: true, policy: policy, timeout: 35)
        try assertPlayback(session, timeout: 15)
        return session
    }
    @discardableResult
    private func hlsReviewSeek(_ session: PlaybackSession, target: Double, rate: Float) -> Bool {
        let frames = session.sink.frames, began = ProcessInfo.processInfo.systemUptime
        session.player.rate = rate
        var complete: Bool?
        session.player.seek(to: target) { complete = $0 }
        let callback = until(10) { complete != nil || session.failure != nil }
        let tolerance = max(1.5, Double(rate) * 0.3)
        let rendered = until(8) {
            let pts = session.player.decoder?.currentVideoFrame?.position ?? -1
            return session.failure != nil || (session.sink.frames > frames && abs(pts - target) <= tolerance) || session.player.state == .finished
        }
        let pts = session.player.decoder?.currentVideoFrame?.position ?? -1
        let ok = callback && complete == true && rendered && session.sink.frames > frames && abs(pts - target) <= tolerance && session.failure == nil
        session.measurements.append(["operation": "hls-seek", "target": target, "rate": rate, "callback": complete as Any? ?? "missing", "renderedPTS": pts, "frames": session.sink.frames, "elapsed": ProcessInfo.processInfo.systemUptime-began, "passed": ok, "decoder": session.player.decoder?.diagnosticSnapshot ?? "closed"])
        XCTAssertTrue(ok, "HLS seek failed: target=\(target), rate=\(rate), callback=\(String(describing: complete)), actualPTS=\(pts)")
        return ok
    }
    private func hlsReviewBackend(_ session: PlaybackSession, policy: FTVideoDecodingPolicy) {
        let stats = session.player.videoDecodingStatistics
        if policy == .hardware {
            XCTAssertGreaterThan(stats.hardwareFrames, 0); XCTAssertEqual(stats.ffmpegFrames, 0)
            XCTAssertEqual(stats.videoToolboxSoftwareFrames, 0); XCTAssertEqual(stats.videoToolboxUnverifiedFrames, 0)
        } else { XCTAssertGreaterThan(stats.ffmpegFrames, 0); XCTAssertEqual(stats.hardwareFrames, 0) }
    }
    func testHLSReviewDurationCurrentTimePauseMuteFromManifest() throws {
        let input = try hlsReviewInput(), session = try hlsReviewSession(input)
        XCTAssertEqual(session.player.duration, input.expectedDuration, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(session.player.mediaInfo?.duration), input.expectedDuration, accuracy: 0.05)
        let first = session.player.currentTime; pump(1)
        XCTAssertGreaterThan(session.player.currentTime, first + 0.2)
        XCTAssertLessThan(session.player.currentTime, session.player.duration)
        session.player.pause(); pump(0.1); let paused = session.player.currentTime; pump(0.35)
        XCTAssertEqual(session.player.currentTime, paused, accuracy: 0.1)
        session.player.isMuted = true; XCTAssertTrue(session.player.isMuted)
        session.player.play(); let before = session.sink.frames
        try require(until(5) { session.sink.frames > before + 3 }, "Resume while muted did not render")
        session.player.isMuted = false; XCTAssertFalse(session.player.isMuted)
        session.measurements.append(["operation": "duration-current-pause-mute", "declaredDuration": input.expectedDuration, "sdkDuration": session.player.duration, "pausedCurrentTime": paused, "metadata": session.player.mediaInfo?.formatName ?? "unknown"])
    }
    private func hlsReviewControlMatrix(_ policy: FTVideoDecodingPolicy) throws {
        continueAfterFailure = true
        let input = try hlsReviewInput(), session = try hlsReviewSession(input, policy: policy)
        for (rate, fraction) in [(Float(1), 0.01), (2, 0.25), (4, 0.5), (8, 0.75), (16, 0.1)] {
            guard hlsReviewSeek(session, target: session.player.duration * fraction, rate: rate) else { continue }
            let start = ProcessInfo.processInfo.systemUptime, initial = session.player.currentTime
            pump(0.8)
            let wall = ProcessInfo.processInfo.systemUptime-start, delta = session.player.currentTime-initial
            let buffering = session.player.decoder?.buffering ?? true
            session.measurements.append(["operation": "hls-rate", "rate": rate, "wall": wall, "mediaDelta": delta, "buffering": buffering])
            XCTAssertNil(session.failure)
            if !buffering { XCTAssertGreaterThanOrEqual(delta, Double(rate)*wall*0.3); XCTAssertLessThanOrEqual(delta, Double(rate)*wall*2.5+0.5) }
        }
        _ = hlsReviewSeek(session, target: 2, rate: 1)
        hlsReviewBackend(session, policy: policy)
    }
    func testHLSReviewHardwareRateAndSeekFromManifest() throws { try hlsReviewControlMatrix(.hardware) }
    func testHLSReviewFFmpegRateAndSeekFromManifest() throws { try hlsReviewControlMatrix(.ffmpeg) }
    private func hlsReviewSustained(_ policy: FTVideoDecodingPolicy) throws {
        let input = try hlsReviewInput(), session = try hlsReviewSession(input, policy: policy)
        session.player.rate = 16
        let began = ProcessInfo.processInfo.systemUptime, initial = session.player.currentTime
        var previous = initial, backwardJumps = 0, lastImage = began, frames = session.sink.frames, maxGap = 0.0, bufferingSamples = 0
        var samples: [[String: Any]] = []
        while ProcessInfo.processInfo.systemUptime-began < 16 && session.failure == nil && session.finished == 0 {
            pump(0.05); let now = ProcessInfo.processInfo.systemUptime, current = session.player.currentTime
            let buffering = session.player.decoder?.buffering ?? true
            if current < previous - 0.5 { backwardJumps += 1 }
            previous = current
            if session.sink.frames != frames || buffering { lastImage = now; frames = session.sink.frames }
            maxGap = max(maxGap, now-lastImage); if buffering { bufferingSamples += 1 }
            samples.append(["wall": now-began, "progress": current, "videoPTS": session.player.decoder?.currentVideoFrame?.position ?? -1, "frames": frames, "imageAge": now-lastImage, "buffering": buffering])
        }
        let delta = session.player.currentTime-initial
        session.measurements.append(["operation": "hls-sustained16", "policy": policy.rawValue, "wall": ProcessInfo.processInfo.systemUptime-began, "mediaDelta": delta, "backwardJumps": backwardJumps, "maxActiveImageGap": maxGap, "bufferingSamples": bufferingSamples, "samples": samples])
        XCTAssertNil(session.failure); XCTAssertEqual(backwardJumps, 0, "Clock moved backwards across EXT-X-DISCONTINUITY")
        XCTAssertGreaterThan(delta, 80, "16x did not traverse multiple segments")
        XCTAssertLessThan(maxGap, 1.5, "Frames froze outside network buffering")
        session.player.rate = 1; let frameCount = session.sink.frames
        XCTAssertTrue(until(8) { session.sink.frames > frameCount + 3 || session.failure != nil }, "No recovery at1x")
        hlsReviewBackend(session, policy: policy)
    }
    func testHLSReviewHardwareSustained16xFromManifest() throws { try hlsReviewSustained(.hardware) }
    func testHLSReviewFFmpegSustained16xFromManifest() throws { try hlsReviewSustained(.ffmpeg) }
    func testHLSReviewBeginningMiddleEndAndPausedSeekFromManifest() throws {
        continueAfterFailure = true
        let input = try hlsReviewInput(), session = try hlsReviewSession(input)
        for target in [0.0, session.player.duration / 2, session.player.duration - 1] {
            session.player.rate = 1; session.player.pause()
            var done: Bool?; session.player.seek(to: target) { done = $0 }
            XCTAssertTrue(until(10) { done != nil || session.failure != nil }); XCTAssertEqual(done, true)
            XCTAssertEqual(session.player.state, .suspend)
            session.player.play(); _ = hlsReviewSeek(session, target: target, rate: 1)
        }
        let finished = until(10) { session.finished > 0 || session.failure != nil }
        XCTAssertTrue(finished && session.finished > 0, "Tail seek did not reach EOF")
        session.player.play(); XCTAssertTrue(until(10) { session.player.currentTime > 0.1 && session.player.currentTime < 5 }, "Replay did not restart at beginning")
    }
    func testHLSReviewSpamSeekAndRateFromManifest() throws {
        continueAfterFailure = true
        let input = try hlsReviewInput(), session = try hlsReviewSession(input)
        var callbacks: [Bool] = []
        for i in 0..<20 {
            session.player.rate = [Float(2), 4, 8, 16][i%4]
            session.player.seek(to: session.player.duration * [0.02, 0.5, 0.95, 0.25][i%4]) { callbacks.append($0) }
            pump(0.025)
        }
        XCTAssertTrue(until(20) { callbacks.count == 20 || session.failure != nil })
        XCTAssertEqual(callbacks.count, 20, "Superseded seek callbacks missing")
        session.measurements.append(["operation": "hls-spam-seek", "callbackCount": callbacks.count, "callbacks": callbacks])
        _ = hlsReviewSeek(session, target: session.player.duration * 0.2, rate: 1)
    }
    func testHLSReviewCacheOfflineSeekAndNetworkReturnFromManifest() throws {
        continueAfterFailure = true
        let input = try hlsReviewInput(), session = try hlsReviewSession(input, mirror: true)
        XCTAssertTrue(until(8) { session.player.downloadProgress > 0 && !session.player.cachedTimeRanges.isEmpty }, "HLS resource cache/size metadata was not published")
        let initialFraction = session.player.downloadProgress, initialRanges = session.player.cachedTimeRanges
        let tailPassed = hlsReviewSeek(session, target: session.player.duration-5, rate: 1)
        let onlineRequests = server!.requests.count
        session.measurements.append(["operation": "hls-cache-before-offline", "fraction": initialFraction, "ranges": initialRanges.map { ["start": $0.start, "end": $0.end] }, "tailSeekPassed": tailPassed, "requests": server!.requests, "cache": session.player.decoder?.cacheDiagnostics ?? [:]])
        XCTAssertGreaterThan(initialFraction, 0, "HLS bytes were not stored in session cache")
        XCTAssertFalse(initialRanges.isEmpty, "HLS cache ranges missing")
        server!.setNetworkMode(.disconnect, dropExistingConnections: true)
        let cachedReadPassed = hlsReviewSeek(session, target: 0, rate: 1)
        pump(0.5)
        let offlineRequests = server!.requests.count-onlineRequests
        session.measurements.append(["operation": "hls-cache-offline", "cachedReadPassed": cachedReadPassed, "offlineRequests": offlineRequests, "decoder": session.player.decoder?.diagnosticSnapshot ?? "none"])
        XCTAssertTrue(cachedReadPassed, "Offline seek could not read a previously downloaded segment")
        XCTAssertEqual(offlineRequests, 0, "Cached seek attempted HTTP while offline")
        server!.setNetworkMode(.online)
        session.ready = false; session.player.replaceVideo()
        XCTAssertTrue(until(15) { session.ready || session.failure != nil }, "Network return failed to reopen")
        XCTAssertTrue(session.ready); _ = hlsReviewSeek(session, target: 2, rate: 1)
    }
    func testHLSReviewCacheStopReplaySwitchAndDeinitFromManifest() throws {
        continueAfterFailure = true
        let input = try hlsReviewInput()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        server = try FixtureHTTPServer(root: documents.appendingPathComponent(URL(fileURLWithPath: input.mirrorDirectory).lastPathComponent))
        var session: PlaybackSession? = PlaybackSession(url: server!.url("index.m3u8"), cache: true)
        weak var weakPlayer = session?.player
        session!.start(); XCTAssertTrue(until(15) { session!.ready || session!.failure != nil })
        try assertPlayback(session!)
        XCTAssertTrue(until(8) { session!.player.decoder?.cacheDiagnostics["hlsKnownSizeSegments"] == Int64(input.segmentCount) }, "Resource size metadata did not complete")
        pump(0.2)
        let directory = try XCTUnwrap(session!.player.cacheSession?.directory), requests = server!.requests.count
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(files.isEmpty, "No HLS resource persisted in cache directory")
        let cachedFraction = session!.player.downloadProgress
        session!.player.stop(); XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(session!.player.downloadProgress,cachedFraction,accuracy:0.001,"Stop replaced aggregate HLS fraction with one resource's fraction")
        session!.ready = false; session!.start(); XCTAssertTrue(until(15) { session!.ready || session!.failure != nil })
        try assertPlayback(session!); XCTAssertEqual(server!.requests.count, requests, "Stop/replay re-downloaded HLS resources")
        session!.player.replaceVideo(with: URL(string: server!.url("index.m3u8").absoluteString + "?another-source=1")!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Source switch retained previous cache")
        let lastDirectory = session!.player.cacheSession?.directory
        session!.player.delegate = nil; session!.stop(); session = nil
        XCTAssertTrue(until(6) { weakPlayer == nil }, "Deinit retained HLS player")
        if let lastDirectory { XCTAssertFalse(FileManager.default.fileExists(atPath: lastDirectory.path), "Deinit retained HLS cache") }
    }

    /// Opt-in private recording; the file/URL and signed link remain outside source control.
    func testReviewSustained16xCameraFromManifest() throws {
        struct Input: Decodable { let filename: String?; let url: String?; let seek: Double; let window: Double; let cleanupAfterRun: Bool?; let warmup: Double?; let requireFinish: Bool? }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let inputURL = documents.appendingPathComponent("FTPlayerHighRateSource.json")
        guard FileManager.default.fileExists(atPath: inputURL.path) else { throw XCTSkip("Opt-in: install FTPlayerHighRateSource.json in app Documents") }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: inputURL))
        let url: URL
        if let filename = input.filename { url = documents.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent) }
        else { url = try XCTUnwrap(input.url.flatMap(URL.init(string:))) }
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let session = PlaybackSession(url: url, cache: true, policy: .hardware); sessions.append(session)
        defer {
            session.stop(); UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled
            if input.cleanupAfterRun == true {
                try? FileManager.default.removeItem(at: inputURL)
                if input.filename == "FTPlayerHighRateCamera.mp4" { try? FileManager.default.removeItem(at: url) }
            }
        }
        session.start()
        try require(until(35) { session.ready || session.failure != nil }, "Camera open did not complete")
        #if targetEnvironment(simulator)
        if let error = session.failure as NSError?, error.code == -2001 { throw XCTSkip("Strict hardware unavailable on Simulator") }
        #endif
        try require(session.failure == nil, "Camera open failed")
        try assertPlayback(session)
        var seeked: Bool?
        session.player.seek(to: input.seek) { seeked = $0 }
        try require(until(30) { seeked != nil || session.failure != nil }, "Camera seek did not finish")
        try require(seeked == true, "Camera seek failed")
        try require(until(20) { (session.player.decoder?.currentVideoFrame?.position ?? -1) >= input.seek - 0.5 }, "Camera did not render seek target")
        pump(min(20, max(0, input.warmup ?? 2)))
        session.player.rate = 16
        let start = ProcessInfo.processInfo.systemUptime, initial = session.player.currentTime
        var lastImage = start, frames = session.sink.frames, maxActiveGap = 0.0
        var samples: [[String: Any]] = []
        // Opt-in recordings may exceed an hour; preserve the requested stress
        // window up to 15 minutes so a full 16x run can actually reach EOF.
        let window = min(900, max(5, input.window))
        while ProcessInfo.processInfo.systemUptime - start < window && session.failure == nil && session.finished == 0 {
            pump(0.05)
            let now = ProcessInfo.processInfo.systemUptime
            let buffering = session.player.decoder?.buffering ?? true
            if session.sink.frames != frames || buffering { frames = session.sink.frames; lastImage = now }
            maxActiveGap = max(maxActiveGap, now - lastImage)
            samples.append(["wall": now-start, "frames": session.sink.frames, "progress": session.player.currentTime,
                            "videoPTS": session.player.decoder?.currentVideoFrame?.position ?? -1,
                            "imageAge": now-lastImage, "buffering": buffering, "downloadProgress": session.player.downloadProgress,
                            "cacheDiagnostics": session.player.decoder?.cacheDiagnostics ?? [:]])
        }
        let stats = session.player.videoDecodingStatistics
        session.measurements.append(["operation": "camera-sustained16", "maxActiveImageGap": maxActiveGap,
                                     "mediaDelta": session.player.currentTime-initial, "samples": samples,
                                     "hardwareFrames": stats.hardwareFrames, "ffmpegFrames": stats.ffmpegFrames,
                                     "videoToolboxSoftwareFrames": stats.videoToolboxSoftwareFrames,
                                     "videoToolboxUnverifiedFrames": stats.videoToolboxUnverifiedFrames,
                                     "decoder": session.player.decoder?.diagnosticSnapshot ?? "none"])
        FTPlayerDiagnostic.shared.log("CAMERA16 maxActiveGap=\(maxActiveGap) delta=\(session.player.currentTime-initial) hw=\(stats.hardwareFrames) ff=\(stats.ffmpegFrames)", category: "test")
        XCTAssertNil(session.failure); XCTAssertLessThan(maxActiveGap, 1.25)
        XCTAssertGreaterThan(stats.hardwareFrames, 0); XCTAssertEqual(stats.ffmpegFrames, 0)
        XCTAssertEqual(stats.videoToolboxSoftwareFrames, 0); XCTAssertEqual(stats.videoToolboxUnverifiedFrames, 0)
        if input.requireFinish == true { XCTAssertGreaterThan(session.finished, 0, "Network source did not reach EOF within the test budget") }
        session.player.rate = 1
        if session.finished > 0 { session.player.play() }
        let before = session.sink.frames
        try require(until(15) { session.sink.frames > before + 3 || session.failure != nil }, "Camera did not recover at 1x")
    }
    func testMp4H264() throws { try check("mp4-h264") }
    func testPublicRound3FDR() throws { try check("hls-fdr", expectHLSCache: true, expectedCodec: "h264", expectedAudioCodec: "aac") }
    func testPublicRound3Surveillance() throws { try check("hls-surveillance", expectHLSCache: true, expectedCodec: "h264") }
    func testPublicRound3MP3VOD() throws { try check("hls-mp3-vod", expectHLSCache: true, expectedCodec: "h264", expectedAudioCodec: "mp3") }
    func testPublicRound3Captions() throws { try check("hls-captions", expectHLSCache: true, expectedCodec: "h264", expectedAudioCodec: "aac") }
    func testPublicRound3ElephantsAudio() throws { try check("hls-elephants-audio", expectHLSCache: true, expectedHLSTracks: 2, expectedCodec: "h264", expectedAudioCodec: "aac") }
    func testRound3ElephantsNativeDistantSeekReference() throws {
        let catalog = try JSONDecoder().decode([Stream].self, from: internetStreamCatalogData())
        let url = try configuredInternetSource(catalog.first { $0.id == "hls-elephants-audio" }, id: "hls-elephants-audio").url
        let s = try start(url, cache: false, timeout: 90)
        try assertPlayback(s, timeout: 20)
        let frames = s.sink.frames
        var completed: Bool?
        s.player.pause(); s.player.seek(to: 324) { completed = $0 }
        try require(until(35) { completed != nil || s.failure != nil }, "Native reference seek callback missing")
        XCTAssertEqual(completed, true)
        s.player.play()
        try require(until(20) { s.sink.frames > frames && abs(s.sink.lastPresentationTime - 324) < 0.5 || s.failure != nil }, "Native reference seek failed to render")
        XCTAssertNil(s.failure)
        s.measurements.append(["operation": "native-elephants-seek", "target": 324, "actualPTS": s.sink.lastPresentationTime])
    }
    func testPublicRound3WistiaPES() throws { try check("hls-wistia-pes", expectHLSCache: true, expectedCodec: "h264") }
    func testPublicRound3HEVC4K() throws { try check("hls-hevc-4k", expectHLSCache: true, expectInitialization: true, expectedCodec: "hevc", expectedSize: CGSize(width: 3840, height: 2160)) }
    func testPublicRound3MOVCamera() throws { try check("mov-camera", expectedCodec: "hevc") }
    func testPublicRound3VP9Earth() throws { try check("webm-vp9-earth", expectedCodec: "vp9", expectedSize: CGSize(width: 1280, height: 720)) }
    func testPublicRound3AVIMPEG4() throws { try check("avi-mpeg4-mp3", expectedCodec: "mpeg4", expectedAudioCodec: "mp3") }
    func testStressDAIDiscontinuity() throws { try check("hls-dai-discontinuity", expectHLSCache: true, expectedCodec: "h264", expectKeyCache: true) }
    func testStressCustomIV() throws { try check("hls-custom-iv", expectHLSCache: true, expectedCodec: "h264", expectKeyCache: true) }
    func testStressPDTLargeGaps() throws { try check("hls-pdt-large-gaps", expectHLSCache: true, expectedCodec: "h264") }
    func testStressAVStartGap() throws { try check("hls-av-start-gap", expectHLSCache: true, expectedCodec: "h264") }
    func testStressAudioPDTGap() throws { try check("hls-audio-pdt-gap", expectHLSCache: true, expectedHLSTracks: 2, expectedCodec: "h264") }
    func testHlsPublicHevcTS() throws { try check("hls-hevc-ts-public", expectHLSCache: true, expectedCodec: "hevc", expectedSize: CGSize(width: 1920, height: 1080), minimumFPS: 59) }
    func testHlsAppleHDR10Plus() throws { try check("hls-apple-hdr10plus", expectHLSCache: true, expectInitialization: true, expectedCodec: "hevc", expectedSize: CGSize(width: 1280, height: 720)) }
    func testHevcCameraMP4() throws { try check("mp4-hevc-camera", expectedCodec: "hevc") }
    func testMovPCM16BigEndian() throws { try check("mov-pcm-s16be", expectedAudioCodec: "pcm_s16be") }
    func testHlsOceansAES128() throws { try check("hls-oceans-aes128", expectHLSCache: true, expectedCodec: "h264", expectedAudioCodec: "aac", expectKeyCache: true) }
    func testHlsMuxSampleAES() throws { try check("hls-mux-sample-aes", expectHLSCache: true, expectedCodec: "h264", expectedAudioCodec: "aac", expectKeyCache: true) }
    func testHlsMuxSampleAESNativeReference() throws {
        let streams = try JSONDecoder().decode([Stream].self, from: internetStreamCatalogData())
        let url = try configuredInternetSource(streams.first { $0.id == "hls-mux-sample-aes" }, id: "hls-mux-sample-aes").url
        let playback = try start(url, cache: false, timeout: 45)
        try assertPlayback(playback, timeout: 20)
    }
    func testHlsAES128SeparateAudio() throws { try check("hls-aes128-audio", expectHLSCache: true, expectedHLSTracks: 2, expectedCodec: "h264", expectedAudioCodec: "aac", expectKeyCache: true) }
    func testHlsShakaAngelOne() throws { try check("hls-shaka-angel-one", expectHLSCache: true, expectInitialization: true, expectedHLSTracks: 2, expectedCodec: "h264", expectedAudioCodec: "aac") }
    func testHlsUnifiedTearsOfSteel() throws { try check("hls-unified-tos", expectHLSCache: true, expectedCodec: "h264", expectedAudioCodec: "aac") }
    func testHlsJWMuxedFMP4() throws { try check("hls-jw-muxed-fmp4", expectHLSCache: true, expectInitialization: true, expectedCodec: "h264", expectedAudioCodec: "aac") }
    func testHevcJellyfish1080() throws { try check("mp4-hevc-jellyfish-1080", expectedCodec: "hevc", expectedSize: CGSize(width: 1920, height: 1080)) }
    func testHevcPhotoprism1080() throws { try check("mp4-hevc-photoprism-1080", expectedCodec: "hevc", expectedSize: CGSize(width: 1920, height: 1080)) }
    func testHevcPhotoprism4K() throws { try check("mp4-hevc-photoprism-4k", expectedCodec: "hevc", expectedSize: CGSize(width: 3840, height: 2160)) }
    func testHlsHevc720p60() throws { try check("hls-hevc-720p60", expectHLSCache: true, expectInitialization: true, expectedCodec: "hevc", expectedSize: CGSize(width: 1280, height: 720), minimumFPS: 59) }
    func testHlsHevc1080p60() throws { try check("hls-hevc-1080p60", expectHLSCache: true, expectInitialization: true, expectedCodec: "hevc", expectedSize: CGSize(width: 1920, height: 1080), minimumFPS: 59) }
    func testWebmVp8() throws { try check("webm-vp8", expectedCodec: "vp8") }
    func testMkvH264() throws { try check("mkv-h264", expectedCodec: "h264") }
    func testHlsMuxPTSShift() throws { try check("hls-mux-pts-shift", expectHLSCache: true, expectedCodec: "h264") }
    func testMp4Hevc() throws { try check("mp4-hevc") }
    func testMp4H264W3C() throws { try check("mp4-h264-w3c") }
    func testHevcPhotoprismTSU() throws { try check("mp4-hevc-photoprism-tsu") }
    func testWebmVp9() throws { try check("webm-vp9") }
    func testHlsMaster() throws { try check("hls-master", expectHLSCache: true) }
    func testHlsMedia() throws { try check("hls-media", expectHLSCache: true) }
    func testHlsAppleTs() throws { try check("hls-apple-ts", expectHLSCache: true, expectedHLSTracks: 2) }
    func testHlsAppleFmp4() throws { try check("hls-apple-fmp4", expectHLSCache: true, expectInitialization: true, expectedHLSTracks: 2) }
    func testHlsHevc() throws { try check("hls-hevc", expectHLSCache: true, expectInitialization: true) }
    func testDASHCapabilityAndGracefulFailure() throws {
        if FTFormatContext.supportsInputFormat("dash") { try check("dash-h264"); return }
        let catalog = try JSONDecoder().decode([Stream].self, from: internetStreamCatalogData())
        let source = try configuredInternetSource(catalog.first { $0.id == "dash-h264" }, id: "dash-h264")
        let s = PlaybackSession(url: source.url, cache: true)
        sessions.append(s); s.start()
        try require(until(35) { s.failure != nil }, "Bundled FFmpeg has no DASH demuxer but failed to return an error")
        try require(s.player.state == .failed && s.sink.frames == 0, "Unsupported DASH input was not rejected cleanly")
        let attachment = XCTAttachment(string: "DASH demuxer is absent in the supplied FFmpeg binary; graceful structured failure verified.")
        attachment.lifetime = .keepAlways; add(attachment)
    }
    func testFlvPublic() throws { try check("flv-public") }
}

private final class StartupBenchmarkRenderer: TestVideoSink {
    let view: FTMediaRendererView
    let sink: PixelSink
    init(view: FTMediaRendererView, sink: PixelSink) { self.view = view; self.sink = sink }
    func didRenderFrame(_ pb: CVPixelBuffer, time: Int64) {
        sink.didRenderFrame(pb, time: time); view.didRenderFrame(pb, time: time)
    }
    func didChangeVideoSize(_ size: CGSize) { view.didChangeVideoSize(size); sink.didChangeVideoSize(size) }
    func didUpdateCurrentTime(_ sec: Double) { view.didUpdateCurrentTime(sec) }
}
