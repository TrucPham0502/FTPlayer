import XCTest
import UIKit
import libavcodec
import Darwin
@testable import FTPlayer

final class FTPlayerControlPlaybackTests: DecodeBackendTestCase {

    func testBufferPlaybackStaysMonotonicAndFullAtEndAt1xAnd16x() throws {
        try checkBufferPlayback(files: ["sample.mp4", "short-mpeg4-mp2.avi", "internet-h264.mp4"])
    }


    private func checkBufferPlayback(files: [String]) throws {
        for file in files {
            for rate: Float in [1, 16] {
                let s = PlaybackSession(url: try fixture(file), policy: .ffmpeg)
                sessions.append(s)
                let observer = BoundaryProgressObserver()
                s.player.progressDelegate = observer
                s.player.rate = rate
                s.start()
                try require(until(45) { s.finished == 1 || s.failure != nil }, "Playback did not finish for \(file) at \(rate)x")
                XCTAssertNil(s.failure)
                pump(0.1)
                XCTAssertFalse(observer.buffers.isEmpty)
                XCTAssertEqual(s.player.bufferProgress, 1)
                XCTAssertEqual(observer.buffers.last, 1)
                XCTAssertTrue(zip(observer.buffers, observer.buffers.dropFirst()).allSatisfy { $0 <= $1 }, "Buffer bar moved backward for \(file) at \(rate)x")
                s.player.stop()
            }
        }
    }

    func testLoggingCanToggleDuringPlaybackWithoutReopeningPlayer() throws {
        let diagnostics = FTPlayerDiagnostic.shared
        diagnostics.isEnabled = false
        defer { diagnostics.isEnabled = true }
        let s = try start(fixture("sustained-h264-aac.mp4"), cache: true, policy: .ffmpeg)
        try assertPlayback(s)
        var result: Bool?
        s.player.seek(to: 12) { result = $0 }
        try require(until { result != nil }, "Seek did not complete with logging disabled")
        XCTAssertEqual(result, true)
        let before = s.sink.frames
        try require(until { s.sink.frames > before + 5 }, "Playback stopped with logging disabled")
        diagnostics.isEnabled = true
        let began = ProcessInfo.processInfo.systemUptime
        pump(1.3)
        let report = try String(contentsOf: diagnostics.exportLogs())
        let health = report.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["message"] as? String == "health",
                  (event["uptime"] as? Double ?? 0) >= began else { return nil }
            return event
        }
        XCTAssertFalse(health.isEmpty, "Enabling during playback did not resume health diagnostics")
        diagnostics.isEnabled = false
        let file = diagnostics.currentLogURL, saved = try Data(contentsOf: file)
        let frames = s.sink.frames
        pump(1.3)
        XCTAssertGreaterThan(s.sink.frames, frames)
        XCTAssertEqual(try Data(contentsOf: file), saved, "Telemetry kept writing after disabling")
        XCTAssertNil(s.failure)
    }

    private func seekBufferingPlayer() throws -> (FTPlayer, BoundaryEngine, BoundaryAudioOutput, SeekLoadingObserver) {
        let engine = BoundaryEngine(), audio = BoundaryAudioOutput(), observer = SeekLoadingObserver()
        let player = FTPlayer(contentURL: try fixture("sample.mp4"), components: BoundaryFactory(engine: engine, audio: audio))
        player.playbackDelegate = observer
        player.replaceVideo()
        engine.delegate?.decoderDidPrepareToDecodeFrames(engine)
        engine.delegate?.decoder(engine, didChangeValueOfBuffering: false)
        pump(0.05)
        engine.seekHandler = { [weak engine] _, completion in
            guard let engine else { completion?(false); return }
            engine.buffering = true
            engine.delegate?.decoder(engine, didChangeValueOfBuffering: true)
            completion?(true) // Demux succeeds before any target media is ready.
        }
        return (player, engine, audio, observer)
    }


    func testRateDropTransitionMP4H264DefaultCache() throws { try checkRateDropTransition("sample.mp4", cache: nil) }
    func testRateDropTransitionMP4H264Cached() throws { try checkRateDropTransition("sample.mp4", cache: true) }
    func testRateDropTransitionMP4HEVCDefaultCache() throws { try checkRateDropTransition("sustained-hevc-aac.mp4", cache: nil) }
    func testRateDropTransitionMP4HEVCCached() throws { try checkRateDropTransition("sustained-hevc-aac.mp4", cache: true) }
    func testRateDropTransitionHLSH264DefaultCache() throws { try checkRateDropTransition("hls-ts/index.m3u8", cache: nil) }
    func testRateDropTransitionHLSH264Cached() throws { try checkRateDropTransition("hls-ts/index.m3u8", cache: true) }
    func testRateDropTransitionHLSHEVCDefaultCache() throws { try checkRateDropTransition("hls-hevc/index.m3u8", cache: nil) }
    func testRateDropTransitionHLSHEVCCached() throws { try checkRateDropTransition("hls-hevc/index.m3u8", cache: true) }

    private func checkRateDropTransition(_ path: String, cache: Bool?) throws {
        let s = try start(try http(path), cache: cache)
        try assertPlayback(s)
        let decoder = try XCTUnwrap(s.player.decoder), audio = try XCTUnwrap(s.player.audioManager)
        // The small video-only HEVC control needs enough media left for 4x.
        let transitions: [(Float, Float)] = decoder.audioEnable ? [(8, 1), (8, 2), (16, 1), (16, 4)] : [(8, 1), (8, 2), (16, 1)]
        for (high, low) in transitions {
            for phase in ["stable", "seek-burst"] {
                s.player.pause(); s.player.rate = 1
                let target = min(4, s.player.duration * 0.15)
                var ready: Bool?
                s.player.seek(to: target) { ready = $0 }
                try require(until(10) { ready != nil || s.failure != nil }, "Transition setup seek timed out")
                try require(ready == true && s.failure == nil, "Transition setup seek failed")
                s.player.play()
                try require(until(10) { !decoder.buffering && decoder.currentVideoFrame != nil || s.failure != nil }, "Transition setup produced no video")
                s.player.rate = high
                pump(decoder.audioEnable ? 0.25 : 0.08)
                let frames = s.sink.frames, finishes = s.finished
                var callbacks = 0
                if phase == "seek-burst" {
                    for offset in [0.0, 3, 1, 4, 0.5, 2, 0.25, 1.5, 0] {
                        s.player.seek(to: target + offset) { _ in callbacks += 1 }
                    }
                }
                // No wait for seek completion or a new frame: t=0 is the rate setter.
                let began = ProcessInfo.processInfo.systemUptime
                s.player.rate = low
                var samples: [[String: Any]] = []
                var raw: [(wall: Double, progress: Double, audio: Double, clock: Double, picture: Double, ready: Bool)] = []
                var minimumAudioRate = audio.playbackRate, maximumAudioRate = audio.playbackRate
                while ProcessInfo.processInfo.systemUptime - began < 3 && s.failure == nil {
                    let wall = ProcessInfo.processInfo.systemUptime - began
                    let value = (wall, s.player.currentTime, decoder.audioTimeClock, decoder.playbackClock?.currentTime ?? 0,
                                 s.sink.lastPresentationTime, !decoder.buffering && !decoder.seeking)
                    raw.append(value)
                    minimumAudioRate = min(minimumAudioRate, audio.playbackRate); maximumAudioRate = max(maximumAudioRate, audio.playbackRate)
                    samples.append(["wall": wall, "progress": value.1, "audioPTS": value.2, "clock": value.3,
                        "picturePTS": value.4, "ready": value.5, "audioUnitRate": audio.playbackRate,
                        "engineRate": decoder.playbackRate])
                    pump(0.01)
                }
                let events = s.sink.presentationEvents(after: frames)
                var windows: [[String: Any]] = []
                for start in [0.0, 0.25, 0.5, 1, 1.5, 2, 2.5] {
                    guard let first = raw.first(where: { $0.wall >= start }),
                          let last = raw.last(where: { $0.wall <= start + 0.5 }), last.wall > first.wall else { continue }
                    let elapsed = last.wall - first.wall
                    let active = raw.filter { $0.wall >= first.wall && $0.wall <= last.wall }.allSatisfy(\.ready)
                    let clockRate = (last.clock - first.clock) / elapsed
                    let audioRate = (last.audio - first.audio) / elapsed
                    let pictureRate = (last.picture - first.picture) / elapsed
                    windows.append(["start": first.wall, "end": last.wall, "active": active,
                        "progressRate": (last.progress - first.progress) / elapsed,
                        "clockRate": clockRate, "audioConsumptionRate": audioRate, "pictureRate": pictureRate])
                }
                s.measurements.append(["operation": "rate-drop-immediate-transition", "highRate": high, "lowRate": low,
                    "phase": phase, "hasAudio": decoder.audioEnable, "cacheAssigned": cache != nil,
                    "callbacks": callbacks, "minimumAudioUnitRate": minimumAudioRate, "maximumAudioUnitRate": maximumAudioRate,
                    "samples": samples, "windows": windows,
                    "presentations": events.map { ["wall": $0.wall - began, "pts": $0.time] },
                    "decoder": decoder.diagnosticSnapshot])
                // Keep the complete trace before an assertion can stop this test.
                for window in windows where (window["start"] as? Double ?? 0) >= 1 && window["active"] as? Bool == true {
                    XCTAssertEqual(window["clockRate"] as? Double ?? -1, Double(low), accuracy: max(0.4, Double(low) * 0.25), "Master clock retained high rate after a second")
                    if decoder.audioEnable {
                        XCTAssertEqual(window["audioConsumptionRate"] as? Double ?? -1, Double(low), accuracy: max(0.4, Double(low) * 0.25), "PCM consumption retained high rate after a second")
                    }
                    XCTAssertLessThan(window["pictureRate"] as? Double ?? .infinity, Double(low) * 1.5 + 0.5, "Pictures still raced at the old rate after a second")
                }
                XCTAssertNil(s.failure)
                XCTAssertEqual(minimumAudioRate, low, accuracy: 0.001); XCTAssertEqual(maximumAudioRate, low, accuracy: 0.001)
                XCTAssertEqual(decoder.playbackRate, low)
                XCTAssertTrue(raw.contains { $0.wall >= 1 && $0.ready }, "Playback stayed stuck after the rate drop")
                XCTAssertTrue(events.contains { $0.wall - began >= 1 }, "No real picture output after the rate drop")
                XCTAssertEqual(s.finished, finishes, "Premature EOF during rate transition")
                if phase == "seek-burst" { XCTAssertEqual(callbacks, 9) }
            }
        }
    }

    func testRateResetAfterSeekBurstMP4H264DefaultCache() throws { try checkRateResetAfterSeekBurst("sample.mp4", cache: nil) }
    func testRateResetAfterSeekBurstMP4H264Cached() throws { try checkRateResetAfterSeekBurst("sample.mp4", cache: true) }
    func testRateResetAfterSeekBurstMP4HEVCDefaultCache() throws { try checkRateResetAfterSeekBurst("sustained-hevc-aac.mp4", cache: nil) }
    func testRateResetAfterSeekBurstMP4HEVCCached() throws { try checkRateResetAfterSeekBurst("sustained-hevc-aac.mp4", cache: true) }
    func testRateResetAfterSeekBurstHLSH264DefaultCache() throws { try checkRateResetAfterSeekBurst("hls-ts/index.m3u8", cache: nil) }
    func testRateResetAfterSeekBurstHLSH264Cached() throws { try checkRateResetAfterSeekBurst("hls-ts/index.m3u8", cache: true) }
    func testRateResetAfterSeekBurstHLSHEVCDefaultCache() throws { try checkRateResetAfterSeekBurst("hls-hevc/index.m3u8", cache: nil) }
    func testRateResetAfterSeekBurstHLSHEVCCached() throws { try checkRateResetAfterSeekBurst("hls-hevc/index.m3u8", cache: true) }

    private func checkRateResetAfterSeekBurst(_ path: String, cache: Bool?) throws {
        let s = try start(try http(path), cache: cache)
        try assertPlayback(s)
        let decoder = try XCTUnwrap(s.player.decoder)
        let audio = try XCTUnwrap(s.player.audioManager)
        let hasAudio = decoder.audioEnable
        XCTAssertEqual(hasAudio, !path.hasPrefix("hls-hevc/"), "Expected A/V sources and an explicit video-only HEVC control")
        if cache == nil { XCTAssertFalse(s.player.useCache); XCTAssertNil(s.player.cacheSession) }
        for highRate in [Float(8), 12, 16] {
            for resetTiming in ["pending", "completed", "paused"] {
                s.player.rate = highRate; s.player.play()
                XCTAssertEqual(audio.playbackRate, highRate, accuracy: 0.001)
                XCTAssertEqual(decoder.playbackRate, highRate)
                let highOrigin = s.player.currentTime
                try require(until(4) { s.player.currentTime > highOrigin + 0.1 || s.failure != nil }, "High rate never consumed PCM")
                if resetTiming == "paused" { s.player.pause() }
                let framesBefore = s.sink.frames
                var completions: [Bool] = []
                let fractions = [0.05, 0.6, 0.15, 0.5, 0.1, 0.55, 0.2, 0.4, 0.08, 0.45, 0.25, 0.15]
                for (index, fraction) in fractions.enumerated() {
                    s.player.seek(to: s.player.duration * fraction) { completions.append($0) }
                    // Mix queued requests and requests already being handled by demux.
                    if index < fractions.count - 1 && index % 3 == 0 { pump(0.01) }
                }
                if resetTiming == "completed" {
                    try require(until(15) { completions.count == fractions.count || s.failure != nil }, "Seek burst lost callbacks before rate reset")
                }
                let resetWall = ProcessInfo.processInfo.systemUptime
                s.player.rate = 1
                XCTAssertEqual(s.player.rate, 1)
                XCTAssertEqual(audio.playbackRate, 1, accuracy: 0.001, "AudioUnit kept its old rate")
                XCTAssertEqual(decoder.playbackRate, 1, "Engine kept its old rate")
                try require(until(15) { completions.count == fractions.count || s.failure != nil }, "Seek burst lost callbacks after rate reset")
                try require(completions.last == true && s.failure == nil, "Final seek failed")
                if resetTiming == "paused" { s.player.play() }
                // The burst completes before the reset, so the clock may run at the old rate
                // until `rate = 1`. Public progress is throttled and delivered async; start the
                // window only after it has caught up, or that pre-reset motion counts as 1x.
                try require(until(15) {
                    s.failure != nil || !decoder.seeking && !decoder.buffering && s.sink.frames > framesBefore &&
                        abs(s.sink.lastPresentationTime - s.player.duration * 0.15) < 1 &&
                        abs(s.player.currentTime - decoder.progress) < 0.1
                }, "Playback failed to resume at final burst target")
                let finishes = s.finished
                let began = ProcessInfo.processInfo.systemUptime
                let origin = s.player.currentTime, audioOrigin = decoder.audioTimeClock
                let clockOrigin = decoder.playbackClock?.currentTime ?? 0
                let pictureOrigin = s.sink.lastPresentationTime, frames = s.sink.frames
                var samples: [[String: Any]] = []
                var maxAudioRate: Float = 1, minAudioRate: Float = 1
                var minEngineRate: Float = 1, maxEngineRate: Float = 1
                var pictureWall = began, maxImageGap = 0.0, lastPicture = pictureOrigin
                var firstHalfSecondRate: Double?
                while ProcessInfo.processInfo.systemUptime - began < 2 && s.failure == nil {
                    pump(0.02)
                    let now = ProcessInfo.processInfo.systemUptime, elapsed = now - began
                    let audioRate = audio.playbackRate
                    maxAudioRate = max(maxAudioRate, audioRate); minAudioRate = min(minAudioRate, audioRate)
                    maxEngineRate = max(maxEngineRate, decoder.playbackRate); minEngineRate = min(minEngineRate, decoder.playbackRate)
                    if s.sink.lastPresentationTime > lastPicture { lastPicture = s.sink.lastPresentationTime; pictureWall = now }
                    maxImageGap = max(maxImageGap, now - pictureWall)
                    if firstHalfSecondRate == nil && elapsed >= 0.5 { firstHalfSecondRate = (decoder.audioTimeClock - audioOrigin) / elapsed }
                    samples.append(["wall": elapsed, "progress": s.player.currentTime, "audioPTS": decoder.audioTimeClock,
                        "masterClock": decoder.playbackClock?.currentTime ?? 0, "videoPTS": s.sink.lastPresentationTime,
                        "audioUnitRate": audioRate, "engineRate": decoder.playbackRate, "buffering": decoder.buffering])
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                let observed = (s.player.currentTime - origin) / elapsed
                let audioObserved = (decoder.audioTimeClock - audioOrigin) / elapsed
                let masterObserved = ((decoder.playbackClock?.currentTime ?? 0) - clockOrigin) / elapsed
                let pictureObserved = (s.sink.lastPresentationTime - pictureOrigin) / elapsed
                s.measurements.append(["operation": "rate-one-after-seek-burst", "highRate": highRate,
                    "resetTiming": resetTiming, "hasAudio": hasAudio, "cacheAssigned": cache != nil, "useCache": s.player.useCache,
                    "callbacks": completions, "resetRecoverySeconds": began - resetWall,
                    "wall": elapsed, "progressRate": observed, "audioConsumptionRate": audioObserved,
                    "masterClockRate": masterObserved, "pictureRate": pictureObserved,
                    "firstHalfSecondAudioRate": firstHalfSecondRate ?? -1, "maximumImageGap": maxImageGap,
                    "minimumAudioUnitRate": minAudioRate, "maximumAudioUnitRate": maxAudioRate,
                    "minimumEngineRate": minEngineRate, "maximumEngineRate": maxEngineRate,
                    "frames": s.sink.frames - frames, "samples": samples,
                    "decoder": decoder.diagnosticSnapshot])
                XCTAssertNil(s.failure)
                XCTAssertEqual(minAudioRate, 1, accuracy: 0.001); XCTAssertEqual(maxAudioRate, 1, accuracy: 0.001)
                XCTAssertEqual(minEngineRate, 1); XCTAssertEqual(maxEngineRate, 1)
                XCTAssertEqual(observed, 1, accuracy: 0.2, "Public playback stayed at the old high rate")
                if hasAudio { XCTAssertEqual(audioObserved, 1, accuracy: 0.2, "Actual PCM consumption stayed at the old high rate") }
                XCTAssertEqual(masterObserved, 1, accuracy: 0.2, "Master clock kept the old rate")
                XCTAssertEqual(pictureObserved, 1, accuracy: 0.35, "Video stayed at the old high rate")
                if hasAudio { XCTAssertLessThan(firstHalfSecondRate ?? .infinity, 1.75, "Old high-rate audio persisted immediately after seek") }
                XCTAssertGreaterThan(s.sink.frames, frames + 5)
                XCTAssertLessThan(maxImageGap, 0.5)
                XCTAssertEqual(s.finished, finishes, "Premature finish after returning to 1x")
            }
        }
    }

    func testSeekPastSingleLongPrerollFrameReachesTarget() throws {
        // Report 6B5F6918: seek 55s stalls at a lone 35.854766s picture
        // spanning 2.493011s, longer than the decoder's 2s queue budget.
        // Inject that output shape; demux, queues, VSync, audio and completion
        // still run through the real SDK with the existing local fixture.
        let s = try start(fixture("sustained-h264-aac.mp4"), cache: true, policy: .ffmpeg)
        try assertPlayback(s)
        let decoder = try XCTUnwrap(s.player.decoder)
        let source = try LongSeekPrerollFrameSource()
        decoder.source = source
        decoder.bufferingTimeout = 3
        defer { decoder.source = nil; withExtendedLifetime(source) {} }
        var completed: Bool?
        let frames = s.sink.frames
        s.player.seek(to: 55) { completed = $0 }
        try require(until(6) { completed != nil || s.failure != nil }, "Long-frame seek never completed")
        XCTAssertTrue(source.injected, "Test never injected the report's long preroll picture")
        XCTAssertNil(s.failure, "A retained preroll picture blocked decoding until buffering timed out")
        XCTAssertEqual(completed, true)
        try require(until(3) { s.sink.frames > frames && s.sink.lastPresentationTime >= 54.95 }, "Seek target picture was never presented")
        XCTAssertFalse(decoder.buffering)
        let presentations = s.sink.presentationTimes(after: frames)
        // A picture covering the target (within seek tolerance) can start a
        // little earlier. Specifically reject the injected reference picture;
        // presenting it must not be the way the deadlock is resolved.
        XCTAssertFalse(presentations.contains { abs($0 - 35.854766) < 0.001 }, "Seek presented its retained reference picture: \(presentations)")
        s.measurements.append(["operation": "long-frame-seek", "target": 55,
            "presentations": presentations, "decoder": decoder.diagnosticSnapshot])
    }

    func testUncachedAudioTailSeekKeepsLastPictureWhileDecodeIsStillBuffering() throws {
        let s = try start(try http("delayed-eof/bad-pdt/index.m3u8"), cache: nil, policy: .ffmpeg)
        try assertPlayback(s)
        for rate in [Float(4), 16] {
            s.player.pause(); s.player.rate = rate
            let frames = s.sink.frames, finished = s.finished
            var complete: Bool?
            s.player.seek(to: s.player.duration - 0.1) { complete = $0 }
            try require(until(3) { complete != nil }, "Audio-tail seek callback missing")
            XCTAssertEqual(complete, true)
            s.player.play()
            try require(until(8) { s.finished > finished || s.failure != nil }, "Audio-tail seek never finished")
            let presentations = s.sink.presentationTimes(after: frames)
            s.measurements.append(["operation": "buffered-tail-seek", "rate": rate,
                "presentations": presentations, "finishes": s.finished - finished,
                "decoder": s.player.decoder?.diagnosticSnapshot ?? "closed"])
            XCTAssertNil(s.failure)
            XCTAssertTrue(presentations.contains { abs($0 - 15.32) < 0.3 }, "Buffering catch-up discarded the new seek's last video picture")
            XCTAssertEqual(s.finished, finished + 1)
        }
    }

    func testTinyVideoRepeatedBackwardSeekPublishesANewPictureBeforeFinish() throws {
        let s = try start(try fixture("tiny-hevc.mp4"), cache: nil, policy: .ffmpeg)
        try require(until(2) { s.sink.frames > 0 }, "Tiny fixture did not start")
        for _ in 0..<40 {
            for target in [0.05, 0.0] {
                s.player.pause(); s.player.rate = 1
                let frames = s.sink.frames
                var complete: Bool?
                s.player.seek(to: target) { complete = $0 }
                try require(until(2) { complete != nil }, "Tiny seek callback missing")
                XCTAssertEqual(complete, true)
                s.player.play()
                let expected = target == 0 ? 0 : 1.0 / 30
                let rendered = until(0.5) { s.sink.presentationTimes(after: frames).contains { abs($0 - expected) < 0.01 } }
                s.measurements.append(["operation": "tiny-seek", "target": target, "picture": s.sink.lastPresentationTime,
                    "framesBefore": frames, "framesAfter": s.sink.frames, "presentations": s.sink.presentationTimes(after: frames), "finished": s.finished,
                    "decoder": s.player.decoder?.diagnosticSnapshot ?? "closed"])
                try require(rendered,
                    "Tiny backward seek finished without presenting its new picture")
            }
        }
    }

    func testAVFinishWaitsForLastPCMAndKeepsTerminalProgress() throws {
        for url in [try fixture("short-mpeg4-mp2.avi")] {
            let s = try start(url, cache: nil, policy: .ffmpeg)
            try assertPlayback(s)
            s.player.rate = 16
            try require(until(5) { s.finished == 1 }, "A/V input did not finish")
            var minimumTerminalTime = s.player.currentTime
            for _ in 0..<15 { pump(0.002); minimumTerminalTime = min(minimumTerminalTime, s.player.currentTime) }
            XCTAssertEqual(minimumTerminalTime, s.player.duration, accuracy: 0.001, "PCM/tail VSync rewound the published terminal time")
            XCTAssertEqual(s.player.decoder?.progress ?? -1, s.player.duration, accuracy: 0.001)
            XCTAssertEqual(s.finished, 1)
            s.player.pause()
        }
    }


    func testExplicitSeekAtFinishedStateThenImmediatePlayKeepsTarget() throws {
        let s = try start(try fixture("short-mpeg4-mp2.avi"), cache: nil, policy: .ffmpeg)
        try assertPlayback(s)
        s.player.rate = 16
        try require(until(5) { s.finished == 1 }, "Short input did not finish")
        XCTAssertEqual(s.player.state, .finished)
        s.player.rate = 1
        let frames = s.sink.frames
        var completed: Bool?
        s.player.seek(to: 0.5) { completed = $0 }
        s.player.play() // Keep the public finished state; do not pause first.
        try require(until(5) { completed != nil && s.sink.frames > frames }, "Post-EOF seek produced no picture")
        XCTAssertEqual(completed, true)
        XCTAssertEqual(s.sink.lastPresentationTime, 0.5, accuracy: 0.15, "Public Play replaced the accepted seek with replay at zero")
        XCTAssertEqual(s.finished, 1)
    }

    func testExplicitSeekFromFinishedClearsTerminalStateBeforeImmediatePlay() throws {
        let s = try start(try fixture("short-mpeg4-mp2.avi"), cache: nil, policy: .ffmpeg)
        try assertPlayback(s)
        s.player.rate = 16
        try require(until(5) { s.finished > 0 }, "Short input did not finish")
        s.player.pause(); s.player.rate = 1
        let decoder = try XCTUnwrap(s.player.decoder), frames = s.sink.frames
        var completed: Bool?
        s.player.seek(to: 0.5) { completed = $0 }
        XCTAssertFalse(decoder.playbackFinished, "An accepted explicit seek retained EOF and immediate Play can overwrite its target with zero")
        s.player.play()
        try require(until(5) { completed != nil && s.sink.frames > frames }, "Explicit seek from EOF produced no picture")
        XCTAssertEqual(completed, true)
        XCTAssertEqual(s.sink.lastPresentationTime, 0.5, accuracy: 0.15)
    }

    func testCachedRateIncreasePresentsNewestDuePictureFromNormalRateQueue() throws {
        let s = try start(try http("hls-ts/index.m3u8"), cache: true, policy: .ffmpeg)
        try assertPlayback(s)
        s.player.pause()
        var completed: Bool?
        s.player.seek(to: 0) { completed = $0 }
        try require(until(5) { completed != nil && s.player.decoder?.buffering == false }, "Dense-queue seek not ready")
        XCTAssertEqual(completed, true)
        pump(0.2) // Decode a normal-rate queue while the presentation clock is paused.
        let frames = s.sink.frames
        s.player.rate = 16; s.player.play()
        pump(0.2)
        s.player.pause()
        let clock = s.player.currentTime, picture = s.sink.lastPresentationTime
        s.measurements.append(["operation": "dense-queue-rate-increase", "clock": clock, "videoPTS": picture])
        XCTAssertGreaterThan(clock, 2)
        XCTAssertGreaterThan(s.sink.frames, frames + 2)
        XCTAssertGreaterThan(picture, 1, "Dense 1x frames continued playing as FIFO after the 16x rate change")
        XCTAssertLessThan(clock - picture, 1, "Picture did not select the newest frame due at the fast clock")
        XCTAssertNil(s.failure)
    }


    func testShortAVICachedTailSeekRendersNewVideo() throws {
        let s = try start(try http("short-mpeg4-mp2.avi"), cache: true)
        try assertPlayback(s)
        for target in [0.0, 0.684, 1.0944] {
            s.player.pause()
            let frames = s.sink.frames
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(3) { completed != nil }, "AVI seek callback missing")
            XCTAssertEqual(completed, true)
            s.player.play()
            let rendered = until(3) { s.sink.frames > frames && abs(s.sink.lastPresentationTime - target) <= 0.5 }
            s.measurements.append(["operation": "avi-tail-seek", "target": target, "rendered": rendered,
                "lastPTS": s.sink.lastPresentationTime, "decoder": s.player.decoder?.diagnosticSnapshot ?? "closed"])
            try require(rendered, "AVI tail seek lost its final video picture")
        }
    }

    func testShortVideoOnlySeekAt4xReleasesBufferingAtEOF() throws {
        let session = try start(fixture("internet-hevc.mp4"), policy: .ffmpeg)
        try assertPlayback(session)
        session.player.rate = 4
        let before = session.sink.frames
        var completed: Bool?
        session.player.seek(to: 2) { completed = $0 }
        try require(until(5) { completed != nil || session.failure != nil }, "Seek did not complete")
        XCTAssertEqual(completed, true)
        try require(until(5) {
            session.sink.frames > before + 2 && (session.player.decoder?.currentVideoFrame?.position ?? -1) >= 2 || session.failure != nil
        }, "Short video stayed buffering after demux EOF at 4x")
        XCTAssertNil(session.failure)
        XCTAssertFalse(session.player.decoder?.buffering ?? true)
    }

    func testReviewHLSHEVCSeekKeepsFirstRandomAccessPacket() throws {
        let format = FTFormatContext(contentURL: try fixture("hls-hevc/index.m3u8"), videoFormat: .unknown)
        defer { format.destroy() }
        format.setupSync(useCache: false)
        XCTAssertNil(format.error)
        var packet = try XCTUnwrap(av_packet_alloc()) as UnsafeMutablePointer<AVPacket>?
        defer { av_packet_free(&packet) }
        XCTAssertGreaterThanOrEqual(format.readFrame(packet), 0)
        let first = try XCTUnwrap(packet).pointee
        let firstPTS = Double(first.pts) * format.videoTimebase
        let firstDTS = Double(first.dts) * format.videoTimebase
        av_packet_unref(packet)
        XCTAssertTrue(format.seekFile(withFFTimebase: 1))
        XCTAssertGreaterThanOrEqual(format.readFrame(packet), 0)
        let next = try XCTUnwrap(packet).pointee
        let seekPTS = Double(next.pts) * format.videoTimebase
        FTPlayerDiagnostic.shared.log("HLS SEEK firstPTS=\(firstPTS) firstDTS=\(firstDTS) start=\(format.startTime) seekPTS=\(seekPTS) seekDTS=\(Double(next.dts)*format.videoTimebase)", category: "test")
        XCTAssertEqual(next.flags & AV_PKT_FLAG_KEY, AV_PKT_FLAG_KEY)
        XCTAssertEqual(seekPTS, firstPTS, accuracy: 0.001, "Backward seek discarded the first random-access packet and jumped to the next GOP")
    }

    func testHighRateByteTargetDoesNotDeadlockStartupBuffering() throws {
        let s = PlaybackSession(url: try http("sustained-h264-video.mp4"), cache: true, policy: .ffmpeg)
        s.player.loadControlConfiguration = .init(targetBufferBytes: 32 * 1024)
        s.player.rate = 16
        sessions.append(s); s.start()
        try require(until(10) { s.ready || s.failure != nil }, "High-rate capped input did not open")
        XCTAssertNil(s.failure); XCTAssertEqual(s.player.decoder?.minBufferedDuration, 10)
        try require(until(5) { s.player.currentTime > 2 && s.sink.frames > 3 || s.failure != nil },
                    "Decoded video waited for 10s while its byte target prevented loading that much media")
        XCTAssertNil(s.failure)
        XCTAssertGreaterThan(s.player.currentTime, 2)
        s.player.rate = 1
        var completed: Bool?
        s.player.seek(to: 0) { completed = $0 }
        try require(until(5) { completed != nil || s.failure != nil }, "Capped input could not seek after 16x")
        XCTAssertEqual(completed, true)
        let frames = s.sink.frames
        try require(until(5) { s.sink.frames > frames + 3 || s.failure != nil }, "Capped input did not recover at 1x")
    }
    private func catchUpPacket(pts: Int64, key: Bool = false) throws -> UnsafeMutablePointer<AVPacket> {
        let packet = try XCTUnwrap(av_packet_alloc())
        guard av_new_packet(packet, 8) == 0 else {
            var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned)
            throw NSError(domain: "CatchUpPacketTest", code: 1)
        }
        packet.pointee.pts = pts; packet.pointee.dts = pts; packet.pointee.duration = 1
        packet.pointee.flags = key ? AV_PKT_FLAG_KEY : 0
        return packet
    }

    func testReviewSustained16xH264Hardware() throws { try checkSustained16x("sustained-h264-aac.mp4", .hardware) }
    func testReviewSustained16xH264FFmpeg() throws { try checkSustained16x("sustained-h264-aac.mp4", .ffmpeg) }
    func testReviewSustained16xHEVCHardware() throws { try checkSustained16x("sustained-hevc-aac.mp4", .hardware) }
    func testReviewSustained16xHEVCFFmpeg() throws { try checkSustained16x("sustained-hevc-aac.mp4", .ffmpeg) }
    func testReviewSustained16xVideoOnlyHardware() throws { try checkSustained16x("sustained-h264-video.mp4", .hardware) }
    func testReviewSustained16xVideoOnlyFFmpeg() throws { try checkSustained16x("sustained-h264-video.mp4", .ffmpeg) }
    private func checkSustained16x(_ file: String, _ policy: FTVideoDecodingPolicy) throws {
        let session = PlaybackSession(url: try fixture(file), policy: policy); sessions.append(session); session.start()
        try require(until(15) { session.ready || session.failure != nil }, "Open did not complete")
        #if targetEnvironment(simulator)
        if policy == .hardware, let error = session.failure as NSError?, error.code == -2001 {
            throw XCTSkip("Strict hardware unavailable on Simulator")
        }
        #endif
        try require(session.failure == nil, "Open failed")
        try assertPlayback(session)
        var seeked: Bool?
        session.player.seek(to: 20) { seeked = $0 }
        try require(until(15) { seeked != nil || session.failure != nil }, "Initial seek did not complete")
        try require(seeked == true, "Initial seek failed")
        try require(until { (session.player.decoder?.currentVideoFrame?.position ?? -1) >= 19.5 }, "No post-seek frame")
        let throttle = SustainedDecodeThrottle(delay: 0.012)
        session.player.decoder?.source = throttle
        defer { withExtendedLifetime(throttle) {}; session.player.decoder?.source = nil }
        session.player.rate = 16
        let started = ProcessInfo.processInfo.systemUptime
        let initial = session.player.currentTime
        var lastFrames = session.sink.frames, lastImage = started, maximumGap = 0.0
        var samples: [[String: Any]] = []
        while ProcessInfo.processInfo.systemUptime - started < 6 {
            pump(0.025)
            let now = ProcessInfo.processInfo.systemUptime
            if session.sink.frames != lastFrames { lastFrames = session.sink.frames; lastImage = now }
            maximumGap = max(maximumGap, now - lastImage)
            samples.append(["wall": now-started, "progress": session.player.currentTime,
                            "videoPTS": session.player.decoder?.currentVideoFrame?.position ?? -1,
                            "frames": session.sink.frames, "imageAge": now-lastImage,
                            "buffering": session.player.decoder?.buffering ?? true])
            if session.failure != nil { break }
        }
        let stats = session.player.videoDecodingStatistics
        let delta = session.player.currentTime - initial
        session.measurements.append(["operation": "sustained-16x-under-decode-pressure", "maximumImageGap": maximumGap,
                                     "mediaDelta": delta, "samples": samples, "decoder": session.player.decoder?.diagnosticSnapshot ?? "none"])
        FTPlayerDiagnostic.shared.log("SUSTAINED16 policy=\(policy.rawValue) file=\(file) maxImageGap=\(maximumGap) delta=\(delta) hw=\(stats.hardwareFrames) ff=\(stats.ffmpegFrames)", category: "test")
        XCTAssertNil(session.failure)
        XCTAssertLessThan(maximumGap, 1.25, "Clock advanced while every newly decoded picture was discarded as late")
        XCTAssertGreaterThan(delta, 50, "16x clock did not advance through a meaningful interval")
        if policy == .hardware { XCTAssertGreaterThan(stats.hardwareFrames, 0); XCTAssertEqual(stats.ffmpegFrames, 0) }
        else { XCTAssertGreaterThan(stats.ffmpegFrames, 0); XCTAssertEqual(stats.hardwareFrames, 0) }
        // Recover ordinary playback after pressure, then seek backwards using the same player.
        throttle.delay = 0; session.player.rate = 1
        let before = session.sink.frames
        try require(until(12) { session.sink.frames > before + 3 || session.failure != nil }, "1x did not recover")
        seeked = nil; session.player.seek(to: 10) { seeked = $0 }
        try require(until(12) { seeked != nil || session.failure != nil }, "Backward seek lost callback")
        try require(seeked == true, "Backward seek failed")
        try require(until(12) { (session.player.decoder?.currentVideoFrame?.position ?? -1) >= 9.5 && session.player.currentTime < 15 }, "Backward seek did not present the requested interval")
    }
    private func checkPreparation(_ fixtureName: String, policy: FTVideoDecodingPolicy) throws {
        let s = PlaybackSession(url: try fixture(fixtureName), policy: policy); sessions.append(s); s.start()
        try require(until { s.player.preparationState == .end || s.failure != nil }, "Preparation never completed")
        #if targetEnvironment(simulator)
        if policy == .hardware, let error = s.failure as NSError?, error.code == -2001 {
            XCTAssertEqual(s.player.videoDecodingStatistics.ffmpegFrames, 0)
            XCTAssertNotEqual(s.player.preparationState, .end)
            throw XCTSkip("Strict hardware unavailable on Simulator; no software pass counted")
        }
        #endif
        try require(s.failure == nil, "Open failed: \(String(describing: s.failure))")
        let values = s.preparationEvents.compactMap { ($0["state"] as? String).flatMap(FTPlayerPreparationState.init(rawValue:)) }
        XCTAssertEqual(values.first, .begin); XCTAssertEqual(values.last, .end)
        XCTAssertEqual(values.filter { $0 == .end }.count, 1)
        XCTAssertEqual(Set(values).count, values.count)
        let order = values.map { FTPlayerPreparationState.allCases.firstIndex(of: $0)! }
        XCTAssertTrue(zip(order, order.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertTrue(s.preparationEvents.allSatisfy { $0["state"] as? String == $0["property"] as? String })
        for state in [FTPlayerPreparationState.connectingToSource, .sourceOpened, .readingStreamInfo, .streamInfoRead, .readingMetadata, .metadataRead, .selectingTracks, .tracksSelected, .openingVideoCodec, .videoCodecOpened, .readingVideoParameters, .videoParametersRead, .readingMediaInfo, .mediaInfoRead, .creatingVideoDecoder, .videoDecoderCreated, .creatingClock, .clockCreated, .publishingMediaInfo, .mediaInfoPublished, .readyToDecode, .readingPackets, .firstPacketRead, .decodingFirstFrame, .firstFrameDecoded, .waitingForFirstFrame] {
            XCTAssertTrue(values.contains(state), "Missing actual phase \(state)")
        }
        XCTAssertFalse(values.contains(.requestingHTTPRange), "File input fabricated HTTP request")
        XCTAssertFalse(s.preparationCompleteBeforeFrame)
        XCTAssertTrue(s.metadataWasBeforeReady); XCTAssertTrue(s.callbackThreadsAreMain)
        XCTAssertEqual(s.player.preparationState, .end)
        let info = try XCTUnwrap(s.mediaInfoEvents.first)
        if fixtureName == "sample.mp4" {
            XCTAssertTrue(values.contains(.openingAudioCodec)); XCTAssertTrue(values.contains(.audioCodecOpened))
            XCTAssertTrue(values.contains(.creatingAudioDecoder)); XCTAssertTrue(values.contains(.audioDecoderCreated))
        } else {
            XCTAssertFalse(values.contains(.openingAudioCodec)); XCTAssertFalse(values.contains(.creatingAudioDecoder))
        }
        XCTAssertEqual(info.sourceURL, s.url)
        XCTAssertEqual(info.width, Int(s.sink.dimensions.width)); XCTAssertEqual(info.height, Int(s.sink.dimensions.height))
        XCTAssertGreaterThan(info.framesPerSecond ?? 0, 0)
        XCTAssertGreaterThan(info.duration ?? 0, 0)
        XCTAssertGreaterThan(info.bitrate ?? 0, 0)
        XCTAssertEqual(info.videoCodec, fixtureName.contains("hevc") ? "hevc" : "h264")
        if fixtureName == "sample.mp4" {
            XCTAssertEqual(info.width, 640); XCTAssertEqual(info.height, 360)
            XCTAssertEqual(info.framesPerSecond ?? 0, 24, accuracy: 0.01)
            XCTAssertEqual(info.audioCodec, "aac"); XCTAssertGreaterThan(info.audioSampleRate ?? 0, 0)
            XCTAssertGreaterThan(info.audioChannels ?? 0, 0)
            XCTAssertEqual(info.videoTrackCount, 1); XCTAssertEqual(info.audioTrackCount, 1)
        }
        if policy == .hardware { XCTAssertGreaterThan(s.player.videoDecodingStatistics.hardwareFrames, 0) }
    }
    func testPreparationH264FFmpegAndMetadata() throws { try checkPreparation("sample.mp4", policy: .ffmpeg) }
    func testPreparationHEVCFFmpegAndMetadata() throws { try checkPreparation("photoprism-tsu-hevc.mp4", policy: .ffmpeg) }
    func testPreparationH264HardwareAndMetadata() throws { try checkPreparation("sample.mp4", policy: .hardware) }
    func testPreparationHEVCHardwareAndMetadata() throws { try checkPreparation("photoprism-tsu-hevc.mp4", policy: .hardware) }
    func testPreparationAudioOnlyDoesNotWaitForVideoFrame() throws {
        let s = try start(fixture("audio.m4a"))
        try require(until { s.player.preparationState == .end }, "Audio-only preparation stalled")
        let info = try XCTUnwrap(s.player.mediaInfo)
        XCTAssertNil(info.videoCodec); XCTAssertNil(info.width); XCTAssertNil(info.framesPerSecond)
        XCTAssertEqual(info.videoTrackCount, 0); XCTAssertEqual(info.audioCodec, "aac")
        XCTAssertGreaterThan(info.audioSampleRate ?? 0, 0); XCTAssertGreaterThan(info.audioChannels ?? 0, 0)
        XCTAssertEqual(s.sink.frames, 0); XCTAssertTrue(s.callbackThreadsAreMain)
    }
    func testPreparationReadyWhilePausedDoesNotReportFirstFrame() throws {
        let s = PlaybackSession(url: try fixture("sample.mp4")); sessions.append(s); s.start(); s.player.pause()
        try require(until { s.ready || s.failure != nil }, "Paused open stalled")
        pump(0.2)
        XCTAssertNotEqual(s.player.preparationState, .end); XCTAssertEqual(s.sink.frames, 0)
        XCTAssertNotNil(s.player.mediaInfo)
        s.player.play()
        try require(until { s.player.preparationState == .end }, "Resume did not complete preparation")
        XCTAssertFalse(s.preparationCompleteBeforeFrame)
    }
    func testPreparationHTTPFailureNeverCompletesOrPublishesMetadata() throws {
        let s = PlaybackSession(url: try http("missing.mp4"), cache: true); sessions.append(s); s.start()
        try require(until { s.failure != nil }, "Expected HTTP 404")
        XCTAssertEqual(s.player.preparationState, .failed)
        XCTAssertNotEqual(s.player.preparationState, .end)
        XCTAssertFalse(s.preparationEvents.contains { $0["state"] as? String == "end" })
        XCTAssertNil(s.player.mediaInfo); XCTAssertTrue(s.mediaInfoEvents.isEmpty)
        XCTAssertEqual(s.preparationEvents.first?["state"] as? String, "begin")
    }
    func testPreparationStopCancelsStalledSourceAndQueuedEvents() throws {
        let source = try http("sample.mp4"); server?.setNetworkMode(.stall)
        let s = PlaybackSession(url: source, cache: true); sessions.append(s); s.start()
        try require(until { s.preparationEvents.contains { $0["state"] as? String == "connectingToSource" } }, "No opening stage")
        let old = try XCTUnwrap(s.player.decoder)
        s.player.decoder(old, didChangePreparationState: .waitingForFirstFrame)
        s.stop(); let count = s.preparationEvents.count; pump(0.3)
        XCTAssertEqual(s.preparationEvents.count, count); XCTAssertEqual(s.player.preparationState, .stopped)
        XCTAssertNil(s.player.mediaInfo)
    }
    func testPreparationSwitchDropsOldSourceProgressAndMetadata() throws {
        let source = try http("sample.mp4"); server?.setNetworkMode(.stall)
        let s = PlaybackSession(url: source, cache: true); sessions.append(s); s.start()
        try require(until { s.preparationEvents.contains { $0["state"] as? String == "connectingToSource" } }, "No opening stage")
        let old = try XCTUnwrap(s.player.decoder)
        s.player.decoder(old, didChangePreparationState: .waitingForFirstFrame)
        s.preparationEvents.removeAll()
        let target = try fixture("photoprism-tsu-hevc.mp4")
        s.player.replaceVideo(with: target)
        s.player.decoder(old, didChangePreparationState: .end)
        s.player.decoderDidPrepareToDecodeFrames(old)
        try require(until { s.player.preparationState == .end || s.failure != nil }, "Replacement failed")
        XCTAssertNil(s.failure); XCTAssertEqual(s.preparationEvents.first?["state"] as? String, "begin")
        XCTAssertEqual(s.mediaInfoEvents.count, 1); XCTAssertEqual(s.player.mediaInfo?.sourceURL, target)
        XCTAssertEqual(s.player.mediaInfo?.videoCodec, "hevc")
        XCTAssertFalse(s.preparationCompleteBeforeFrame)
    }
    func testPreparationCachedStopPlayStartsAgainWithoutHTTP() throws {
        let s = try start(http("sample.mp4"), cache: true); try assertPlayback(s)
        try require(until { s.player.downloadProgress == 1 }, "Cache incomplete")
        s.stop(); let count = server!.requests.count
        s.preparationEvents.removeAll(); s.stopRequested = false; s.player.play()
        try require(until { s.player.preparationState == .end }, "Cached reopen did not prepare")
        XCTAssertEqual(s.preparationEvents.first?["state"] as? String, "begin")
        XCTAssertEqual(server!.requests.count, count); XCTAssertEqual(s.player.downloadProgress, 1)
    }
    func testPreparationDelegateCanStopFromMediaInfoWithoutLateReady() throws {
        let s = PlaybackSession(url: try fixture("sample.mp4")); sessions.append(s)
        s.onMediaInfo = { [weak player = s.player] in player?.stop() }
        s.start()
        try require(until { !s.mediaInfoEvents.isEmpty }, "Metadata missing")
        pump(0.2)
        XCTAssertFalse(s.ready, "Metadata delegate stopped the source but SDK still delivered ready")
        XCTAssertEqual(s.player.preparationState, .stopped)
        XCTAssertEqual(s.sink.frames, 0)
        XCTAssertFalse(s.preparationEvents.contains { $0["state"] as? String == "end" })
    }
    func testPreparationFailureDelegateCanOpenNewSourceWithoutOldError() throws {
        let s = PlaybackSession(url: try http("missing.mp4"), cache: true); sessions.append(s)
        let target = try fixture("sample.mp4")
        s.onPreparation = { player, _ in
            if player.preparationState == .failed { player.replaceVideo(with: target) }
        }
        s.start()
        try require(until { s.player.preparationState == .end }, "Delegate replacement did not produce a frame")
        XCTAssertEqual(s.player.mediaInfo?.sourceURL, target)
        XCTAssertEqual(s.errorCount, 0, "Old failure callback leaked after progress delegate opened a new URL")
        XCTAssertNil(s.failure)
    }
    func testPreparationSeekAndRateDoNotRestartStartupProgress() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        let count = s.preparationEvents.count
        s.player.rate = 16
        var seekResult: Bool?; s.player.seek(to: 15) { seekResult = $0 }
        try require(until { seekResult != nil }, "Seek incomplete")
        XCTAssertEqual(seekResult, true); pump(0.3)
        XCTAssertEqual(s.preparationEvents.count, count); XCTAssertEqual(s.player.preparationState, .end)
    }

    func testPreparationHTTPRangeHeadersAndInitialDataAreActualEvents() throws {
        let s = try start(http("sample.mp4"), cache: true)
        try require(until { s.player.preparationState == .end }, "HTTP preparation stalled")
        let states = s.preparationEvents.compactMap { $0["state"] as? String }
        for state in ["connectingToSource", "requestingHTTPRange", "httpHeadersReceived", "receivingInitialData", "sourceOpened"] {
            XCTAssertTrue(states.contains(state), "Missing URL IO state \(state)")
        }
        XCTAssertTrue(server!.requests.contains { $0.hasPrefix("GET ") }); XCTAssertFalse(server!.rangeRequests.isEmpty)
        XCTAssertTrue(s.callbackThreadsAreMain)
    }
    func testPreparationWarmCacheSkipsNetworkStatesWithoutHTTP() throws {
        let s = try start(http("sample.mp4"), cache: true)
        try require(until { s.player.downloadProgress == 1 && s.player.preparationState == .end }, "Cache not seeded")
        s.stop(); let requests = server!.requests.count
        s.preparationEvents.removeAll(); s.stopRequested = false; s.player.play()
        try require(until { s.player.preparationState == .end }, "Warm reopen failed")
        XCTAssertEqual(server!.requests.count, requests)
        let states = s.preparationEvents.compactMap { $0["state"] as? String }
        XCTAssertFalse(states.contains("requestingHTTPRange")); XCTAssertFalse(states.contains("httpHeadersReceived")); XCTAssertFalse(states.contains("receivingInitialData"))
    }
    func testPreparationNativeHLSDoesNotFabricateCustomHTTPStates() throws {
        let s = try start(http("hls-ts/index.m3u8"), cache: false)
        try require(until { s.player.preparationState == .end }, "HLS preparation stalled")
        let states = s.preparationEvents.compactMap { $0["state"] as? String }
        XCTAssertTrue(states.contains("connectingToSource")); XCTAssertTrue(states.contains("sourceOpened"))
        XCTAssertFalse(states.contains("requestingHTTPRange")); XCTAssertFalse(states.contains("httpHeadersReceived"))
        XCTAssertTrue(server!.requests.contains { $0.contains("segment") })
    }
    func testPreparationCachedHLSReportsActualRangeStates() throws {
        let s = try start(http("hls-ts/index.m3u8"), cache: true)
        try require(until { s.player.preparationState == .end }, "Cached HLS preparation stalled")
        let states = s.preparationEvents.compactMap { $0["state"] as? String }
        for state in ["requestingHTTPRange", "httpHeadersReceived", "receivingInitialData"] {
            XCTAssertTrue(states.contains(state), "Missing real cached HLS state: \(state)")
        }
        XCTAssertFalse(server!.rangeRequests.isEmpty)
        XCTAssertGreaterThan(s.player.cacheProgress.cachedBytes, 0)
    }

    func testPreparationDelegateCanStopFromConnectingWithoutLaterEvents() throws {
        let s = PlaybackSession(url: try http("sample.mp4"), cache: true); sessions.append(s)
        s.onPreparation = { player, state in if state == .connectingToSource { player.stop() } }
        s.start(); try require(until { s.player.preparationState == .stopped }, "Delegate stop not delivered")
        let count = s.preparationEvents.count; pump(0.3)
        XCTAssertEqual(s.preparationEvents.count, count)
        XCTAssertEqual(s.preparationEvents.last?["state"] as? String, "stopped")
        XCTAssertNil(s.player.mediaInfo); XCTAssertEqual(s.sink.frames, 0)
    }
    func testPreparationDelegateCanReplaceFromPublishingMetadata() throws {
        let s = PlaybackSession(url: try fixture("sample.mp4")); sessions.append(s)
        let next = try fixture("photoprism-tsu-hevc.mp4")
        var replaced = false
        s.onPreparation = { player, state in
            if state == .publishingMediaInfo && !replaced { replaced = true; player.replaceVideo(with: next) }
        }
        s.start(); try require(until { s.player.preparationState == .end }, "Replacement stalled")
        XCTAssertEqual(s.mediaInfoEvents.count, 1); XCTAssertEqual(s.mediaInfoEvents.first?.sourceURL, next)
        XCTAssertNil(s.failure); XCTAssertTrue(s.callbackThreadsAreMain)
    }
    func testPreparationLateLowerAndPostEndStatesAreIgnored() throws {
        let s = try start(fixture("sample.mp4"))
        try require(until { s.player.preparationState == .end }, "Preparation stalled")
        let count = s.preparationEvents.count, decoder = try XCTUnwrap(s.player.decoder)
        s.player.decoder(decoder, didChangePreparationState: .httpHeadersReceived)
        s.player.decoder(decoder, didChangePreparationState: .readingStreamInfo)
        pump(0.1)
        XCTAssertEqual(s.player.preparationState, .end); XCTAssertEqual(s.preparationEvents.count, count)
    }

    private func nativeLogEvents(since uptime: TimeInterval) throws -> [[String: Any]] {
        let diagnostics = FTPlayerDiagnostic.shared
        diagnostics.flush()
        return try FileManager.default.contentsOfDirectory(at: diagnostics.directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(diagnostics.sessionID + "-") && $0.pathExtension == "jsonl" }
            .flatMap { try String(contentsOf: $0).split(separator: "\n").compactMap { line -> [String: Any]? in
                guard let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      event["category"] as? String == "ffmpeg", (event["uptime"] as? Double ?? 0) >= uptime else { return nil }
                return event
            } }
    }
    func testStartupLogNativeCallbackHonorsVerboseLevel() throws {
        let began = ProcessInfo.processInfo.systemUptime
        let s = try start(fixture("sample.mp4")); try assertPlayback(s); s.stop()
        let events = try nativeLogEvents(since: began)
        // AV_LOG_WARNING=24 (vendor libavutil/log.h). Real MP4 parsing emits
        // AVIndex TRACE=56; those callbacks must be filtered before formatting.
        let excess = events.filter { (($0["fields"] as? [String: Any])?["avLevel"] as? Int ?? 0) > 24 }
        XCTAssertEqual(excess.count, 0, "Native callback bypassed FFmpeg level and flooded startup with TRACE/DEBUG")
    }
    func testStartupLogKeepsNativeErrorForCorruptMP4() throws {
        let began = ProcessInfo.processInfo.systemUptime
        let s = PlaybackSession(url: try http("truncated.mp4"), cache: true, policy: .ffmpeg); sessions.append(s); s.start()
        try require(until { s.failure != nil }, "Corrupt input did not fail")
        let events = try nativeLogEvents(since: began)
        XCTAssertTrue(events.contains { ($0["level"] as? String) == "error" && (($0["fields"] as? [String: Any])?["avLevel"] as? Int ?? 99) <= 16 }, "Native error disappeared with verbose filtering")
        XCTAssertEqual(s.errorCount, 1)
    }

    private func checkHLSTail(_ source: String) throws {
        let s = try start(http(source), policy: .ffmpeg); try assertPlayback(s)
        var result: Bool?
        s.player.seek(to: s.player.duration - 0.05) { result = $0 }
        try require(until { result != nil }, "Tail completion missing")
        XCTAssertEqual(result, true)
        try require(until(10) { s.player.state == .finished }, "Empty HLS tail never finished")
        XCTAssertEqual(s.player.currentTime, s.player.duration, accuracy: 0.02)
        let decoder = try XCTUnwrap(s.player.decoder)
        s.player.decoder(decoder, didChangeValueOfBuffering: false)
        pump(0.1)
        XCTAssertEqual(s.player.state, .finished, "Buffering end resurrected a finished epoch")
        XCTAssertNil(s.failure)
    }
    func testSpamSeekHLSH264SingleTail() throws { try checkHLSTail("hls-ts/index.m3u8") }
    func testSpamSeekHLSHEVCSingleTail() throws { try checkHLSTail("hls-hevc/index.m3u8") }

    private func spamTenSeconds(_ source: String, policy: FTVideoDecodingPolicy, profile: String) throws {
        let cached = profile != "NetworkRates" && source.hasSuffix(".mp4")
        let s = PlaybackSession(url: try http(source), cache: cached, policy: policy); sessions.append(s); s.start()
        try require(until(30) { s.ready || s.failure != nil }, "Spam open timed out")
        #if targetEnvironment(simulator)
        if policy == .hardware, let e = s.failure as NSError?, e.code == -2001 { throw XCTSkip("Strict hardware unavailable; software not counted as hardware pass") }
        #endif
        try assertPlayback(s)
        if cached { try require(until { s.player.downloadProgress == 1 }, "Seeded cache incomplete") }
        let requests = server!.requests.count
        let count = profile == "Burst" ? 200 : profile == "NetworkRates" ? 100 : 60
        let interval = profile == "Burst" ? 0.0 : profile == "NetworkRates" ? 0.01 : 0.02
        var cursor = s.player.currentTime, targets: [Double] = []
        var results = Array<Bool?>(repeating: nil, count: count), callbacks = Array(repeating: 0, count: count)
        var main = true
        for i in 0..<count {
            if profile == "NetworkRates" { s.player.rate = i == count - 1 ? 1 : [Float(2), 4, 8, 16][i % 4] }
            let delta: Double = profile == "Edges" ? (i % 8 < 4 ? 10 : -10) : (i % 2 == 0 ? 10 : -10)
            cursor = min(max(0, cursor + delta), max(0, s.player.duration - 0.05)); targets.append(cursor)
            s.player.seek(to: cursor) { success in
                main = main && Thread.isMainThread; callbacks[i] += 1; results[i] = success
            }
            if interval > 0 { pump(interval) }
        }
        try require(until(20) { callbacks.reduce(0, +) == count || s.failure != nil }, "Lost spam callbacks: \(callbacks.filter { $0 == 0 }.count)")
        XCTAssertTrue(callbacks.allSatisfy { $0 == 1 }, "Seek completion must fire exactly once")
        XCTAssertEqual(results.last!, true, "Latest request was canceled/failed after spam stopped")
        XCTAssertTrue(main); XCTAssertNil(s.failure)
        let last = targets.last!, frames = s.sink.frames
        if last >= s.player.duration - 0.1 {
            try require(until(10) { s.player.state == .finished || s.failure != nil }, "Tail spam did not finish")
        } else {
            try require(until(15) { s.sink.frames >= frames + 3 || s.failure != nil }, "Video froze after spam")
            XCTAssertGreaterThanOrEqual(s.player.currentTime, max(0, last - 0.5))
            XCTAssertLessThan(s.player.currentTime, last + 3, "Last request lost to an older seek")
            let framePTS = try XCTUnwrap(s.player.decoder?.currentVideoFrame?.position)
            XCTAssertGreaterThanOrEqual(framePTS, max(0, last - 1))
            XCTAssertLessThan(framePTS, last + 3, "Old video epoch rendered after final seek")
        }
        if cached { XCTAssertEqual(server!.requests.count, requests, "Spam re-downloaded fully cached bytes") }
        let stats = s.player.videoDecodingStatistics
        if policy == .hardware { XCTAssertGreaterThan(stats.hardwareFrames, 0); XCTAssertEqual(stats.ffmpegFrames, 0) }
        else { XCTAssertGreaterThan(stats.ffmpegFrames, 0); XCTAssertEqual(stats.hardwareFrames, 0) }
        s.measurements.append(["operation": "spam-ten-seconds", "profile": profile, "count": count, "interval": interval, "targets": targets, "callbacks": callbacks, "success": results.map { $0 ?? false }, "lastTarget": last, "currentTime": s.player.currentTime])
        FTPlayerDiagnostic.shared.log("SPAM SEEK CHECK profile=\(profile) policy=\(policy.rawValue) count=\(count) callbacks=\(callbacks.reduce(0,+)) last=\(last) current=\(s.player.currentTime)", category: "test")
    }
    func testSpamSeekFFmpegMP4H264Burst() throws { try spamTenSeconds("sample.mp4", policy: .ffmpeg, profile: "Burst") }
    func testSpamSeekFFmpegMP4H264NetworkRates() throws { try spamTenSeconds("sample.mp4", policy: .ffmpeg, profile: "NetworkRates") }
    func testSpamSeekFFmpegMP4H264Edges() throws { try spamTenSeconds("sample.mp4", policy: .ffmpeg, profile: "Edges") }
    func testSpamSeekHardwareMP4H264Burst() throws { try spamTenSeconds("sample.mp4", policy: .hardware, profile: "Burst") }
    func testSpamSeekHardwareMP4H264NetworkRates() throws { try spamTenSeconds("sample.mp4", policy: .hardware, profile: "NetworkRates") }
    func testSpamSeekHardwareMP4H264Edges() throws { try spamTenSeconds("sample.mp4", policy: .hardware, profile: "Edges") }
    func testSpamSeekFFmpegMP4HEVCBurst() throws { try spamTenSeconds("photoprism-tsu-hevc.mp4", policy: .ffmpeg, profile: "Burst") }
    func testSpamSeekFFmpegMP4HEVCNetworkRates() throws { try spamTenSeconds("photoprism-tsu-hevc.mp4", policy: .ffmpeg, profile: "NetworkRates") }
    func testSpamSeekFFmpegMP4HEVCEdges() throws { try spamTenSeconds("photoprism-tsu-hevc.mp4", policy: .ffmpeg, profile: "Edges") }
    func testSpamSeekHardwareMP4HEVCBurst() throws { try spamTenSeconds("photoprism-tsu-hevc.mp4", policy: .hardware, profile: "Burst") }
    func testSpamSeekHardwareMP4HEVCNetworkRates() throws { try spamTenSeconds("photoprism-tsu-hevc.mp4", policy: .hardware, profile: "NetworkRates") }
    func testSpamSeekHardwareMP4HEVCEdges() throws { try spamTenSeconds("photoprism-tsu-hevc.mp4", policy: .hardware, profile: "Edges") }
    func testSpamSeekFFmpegHLSH264Burst() throws { try spamTenSeconds("hls-ts/index.m3u8", policy: .ffmpeg, profile: "Burst") }
    func testSpamSeekFFmpegHLSH264NetworkRates() throws { try spamTenSeconds("hls-ts/index.m3u8", policy: .ffmpeg, profile: "NetworkRates") }
    func testSpamSeekFFmpegHLSH264Edges() throws { try spamTenSeconds("hls-ts/index.m3u8", policy: .ffmpeg, profile: "Edges") }
    func testSpamSeekHardwareHLSH264Burst() throws { try spamTenSeconds("hls-ts/index.m3u8", policy: .hardware, profile: "Burst") }
    func testSpamSeekHardwareHLSH264NetworkRates() throws { try spamTenSeconds("hls-ts/index.m3u8", policy: .hardware, profile: "NetworkRates") }
    func testSpamSeekHardwareHLSH264Edges() throws { try spamTenSeconds("hls-ts/index.m3u8", policy: .hardware, profile: "Edges") }
    func testSpamSeekFFmpegHLSHEVCBurst() throws { try spamTenSeconds("hls-hevc/index.m3u8", policy: .ffmpeg, profile: "Burst") }
    func testSpamSeekFFmpegHLSHEVCNetworkRates() throws { try spamTenSeconds("hls-hevc/index.m3u8", policy: .ffmpeg, profile: "NetworkRates") }
    func testSpamSeekFFmpegHLSHEVCEdges() throws { try spamTenSeconds("hls-hevc/index.m3u8", policy: .ffmpeg, profile: "Edges") }
    func testSpamSeekHardwareHLSHEVCBurst() throws { try spamTenSeconds("hls-hevc/index.m3u8", policy: .hardware, profile: "Burst") }
    func testSpamSeekHardwareHLSHEVCNetworkRates() throws { try spamTenSeconds("hls-hevc/index.m3u8", policy: .hardware, profile: "NetworkRates") }
    func testSpamSeekHardwareHLSHEVCEdges() throws { try spamTenSeconds("hls-hevc/index.m3u8", policy: .hardware, profile: "Edges") }

    func testPauseResumeKeepsPosition() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        s.player.pause(); pump(0.1); let paused = s.player.progress; pump(0.4)
        try require(s.player.state == .suspend, "Pause state incorrect")
        try require(abs(s.player.progress - paused) < 0.15, "Pause clock advanced")
        s.player.play(); try require(until { s.player.progress > paused + 0.2 }, "Resume stalled")
    }
    func testSeekForwardThenBackward() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        for target: Double in [10, 2] {
            var done: Bool?; s.player.seek(to: target) { done = $0 }
            try require(until { done != nil }, "Seek callback missing")
            try require(done == true, "Seek failed")
            try require(until { abs(s.player.progress - target) < 1.5 }, "Seek target not reached")
        }
    }
    func testSeekNearEndIsNotClampedTenSecondsEarly() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        let target = s.player.duration - 2
        var done: Bool?; s.player.seek(to: target) { done = $0 }
        try require(until { done != nil }, "Seek callback missing")
        try require(s.player.progress >= target - 1, "Seek near end was clamped far before the requested time")
    }
    func testSeekNegativeClampsToZero() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        var done: Bool?; s.player.seek(to: -10) { done = $0 }
        try require(until { done != nil }, "Seek callback missing")
        try require(s.player.progress >= 0, "Negative progress")
    }
    func testSeekRejectsNonfiniteValues() throws {
        let s = try start(fixture("sample.mp4"))
        for value in [Double.nan, .infinity, -.infinity] {
            var done: Bool?; s.player.seek(to: value) { done = $0 }
            try require(until { done != nil }, "Invalid seek callback missing")
            try require(done == false, "Nonfinite seek was accepted")
        }
    }
    func testInvalidRatesKeepPreviousRate() throws {
        let s = try start(fixture("sample.mp4"))
        for rate in [Float.nan, .infinity, -1, 0, 100] {
            s.player.rate = rate
            try require(s.player.rate == 1, "Invalid playback rate accepted")
        }
    }
    func testAllSupportedRatesAdvanceAndReturnToNormal() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        for rate: Float in [0.5, 1, 2, 4, 8, 16, 1] {
            s.player.rate = rate
            try require(s.player.rate == rate, "Rate setter rejected supported value")
            let before = s.player.progress
            try require(until(6) { s.player.progress > before + 0.05 || s.player.state == .finished }, "Playback stopped advancing at rate \(rate)")
            if s.player.state == .finished { break }
        }
    }
    func testRepeatedReplaceThenStopDoesNotReopen() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        s.player.replaceVideo(); s.player.replaceVideo(); s.player.replaceVideo(); s.stop(); pump(1)
        try require(s.player.state == .none, "Queued replacement reopened after stop")
    }
    func testStopThenPlayCanReopen() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        s.stop(); pump(0.2)
        s.stopRequested = false; s.ready = false; s.player.replaceVideo()
        try require(until { s.ready || s.failure != nil }, "Player could not reopen")
        try assertPlayback(s)
    }
    func testBackgroundPausesAndForegroundResumes() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        s.player.backgroundMode = .autoPlayAndPause
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try require(s.player.state == .suspend, "Background did not pause")
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try require(s.player.state == .playing || s.player.state == .buffering, "Foreground did not resume")
    }
    func testStopCompletesPendingSeek() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        var completion: Bool?
        s.player.seek(to: 15) { completion = $0 }
        s.stop()
        try require(until(3) { completion != nil }, "Stopping player lost pending seek completion")
    }
    func testVideoOnlyFinishWaitsForTimelineAt16x() throws {
        let s = try start(fixture("internet-h264.mp4")); try assertPlayback(s)
        let remaining = s.player.duration - s.player.progress
        s.player.rate = 16
        let wall = ProcessInfo.processInfo.systemUptime
        try require(until(5) { s.finished > 0 }, "Fast playback did not finish")
        let elapsed = ProcessInfo.processInfo.systemUptime - wall
        try require(elapsed >= remaining / 16 * 0.6, "Video finished when sparse keyframe queue emptied, before the media timeline ended")
    }
    func testPlaybackFinishesAndReplayRestarts() throws {
        let s = try start(fixture("internet-h264.mp4")); try assertPlayback(s)
        try require(until(14) { s.finished == 1 }, "Finish delegate missing")
        try require(s.player.state == .finished, "Finish state incorrect")
        s.player.play()
        try require(until { s.player.progress < 2 && s.player.state != .finished }, "Replay did not restart")
    }
    func testReviewProgressCallbacksKeepSnapshots() throws {
        let s = try start(fixture("sample.mp4")); s.player.pause(); pump(0.1)
        let observer = ReviewObserver(); s.player.delegate = observer
        s.player.progress = 1; s.player.progress = 2; pump(0.1)
        XCTAssertEqual(observer.progress, [1, 2], "Queued progress updates lost their captured values")
    }
    func testReviewPlayableCallbacksIncludeOrdinaryBufferUpdates() throws {
        let s = try start(fixture("sample.mp4")); s.player.pause(); pump(0.1)
        let observer = ReviewObserver(); s.player.delegate = observer
        s.player.playableTime = 3; s.player.playableTime = 4; pump(0.1)
        // A decoder buffer update may follow and raise playableTime again.
        XCTAssertEqual(Array(observer.playable.prefix(2)), [3, 4], "In-range playable updates never reach delegate")
    }
    func testVideoOutputWorksWithoutRenderer() throws {
        let s = PlaybackSession(url: try fixture("sample.mp4")); sessions.append(s)
        let output = ReviewVideoOutput()
        s.player.videoOutput = output
        s.start()
        try require(until(10) { output.positions.count >= 3 || s.failure != nil }, "No pixel buffer output")
        XCTAssertNil(s.failure)
        XCTAssertTrue(output.onMain)
        XCTAssertTrue(output.playerMatches)
        XCTAssertGreaterThanOrEqual(output.positions.count, 3)
        XCTAssertTrue(zip(output.positions, output.positions.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertGreaterThan(output.positions.last ?? 0, output.positions.first ?? 0)
        s.stop()
        let count = output.positions.count
        pump(0.1)
        XCTAssertEqual(output.positions.count, count, "Frame delivered after stop")
        let buffer = try XCTUnwrap(output.retained)
        XCTAssertGreaterThan(CVPixelBufferGetWidth(buffer), 0)
        XCTAssertGreaterThan(CVPixelBufferGetHeight(buffer), 0)
    }
    func testVideoOutputIsWeakAndPlaybackWorksWithoutConsumer() throws {
        let s = PlaybackSession(url: try fixture("sample.mp4")); sessions.append(s)
        var output: ReviewVideoOutput? = ReviewVideoOutput()
        weak var weakOutput = output
        s.player.videoOutput = output
        output = nil
        XCTAssertNil(weakOutput)
        XCTAssertNil(s.player.videoOutput)
        s.start()
        try require(until(10) { s.ready || s.failure != nil }, "No ready/error callback")
        XCTAssertNil(s.failure)
        try require(until(5) { s.player.progress > 0.2 || s.failure != nil }, "Playback needs a video consumer")
        XCTAssertNil(s.failure)
    }
    func testReviewStopSuppressesQueuedReadyFinishAndError() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s); pump(0.1)
        let decoder = try XCTUnwrap(s.player.decoder)
        let observer = ReviewObserver(); s.player.delegate = observer
        s.player.decoderDidPrepareToDecodeFrames(decoder)
        s.player.decoderDidPlaybackFinished(decoder)
        s.player.decoder(decoder, didError: NSError(domain: "review", code: 1))
        s.player.stop(); pump(0.2)
        XCTAssertEqual(observer.ready, 0, "Stopped generation delivered ready")
        XCTAssertEqual(observer.finished, 0, "Stopped generation delivered finish")
        XCTAssertEqual(observer.errors, 0, "Stopped generation delivered error")
        XCTAssertFalse(observer.states.contains { $0 != .none }, "Stopped generation delivered stale state")
    }
    func testReviewStopThenReopenSuppressesQueuedOldFrame() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let sink = PixelSink(); attachVideoSink(sink, to: s.player)
        s.player.send(video: FTCVYUVVideoFrame(pixelBuffer: pixel), from: try XCTUnwrap(s.player.decoder))
        s.player.stop(); s.player.replaceVideo()
        // Marker is behind the obsolete frame, ahead of any next main-queue rendering.
        let checked = expectation(description: "old frame suppressed")
        DispatchQueue.main.async { XCTAssertEqual(sink.frames, 0, "Old decoder frame leaked into replacement"); checked.fulfill() }
        wait(for: [checked], timeout: 2)
    }
    func testReviewInitialHighRateUsesAdaptiveBuffer() throws {
        let s = PlaybackSession(url: try fixture("sample.mp4")); sessions.append(s)
        s.player.rate = 16; s.start()
        XCTAssertEqual(s.player.decoder?.minBufferedDuration, 10, "Initial high-rate threshold overwritten by 2 seconds")
        try require(until { s.ready || s.failure != nil }, "Open timed out")
        try assertPlayback(s)
    }

    func testReviewPauseDuringOpenRemainsPausedWhenReady() throws {
        let s = PlaybackSession(url: try fixture("sample.mp4")); sessions.append(s)
        s.start(); s.player.pause()
        try require(until { s.ready || s.failure != nil }, "Open timed out")
        pump(0.3)
        XCTAssertEqual(s.player.state, .suspend, "Ready callback overrode explicit pause during open")
        XCTAssertTrue(s.player.decoder?.paused == true)
        XCTAssertLessThan(s.player.progress, 0.1)
        s.player.play(); try assertPlayback(s)
    }

    func testReviewFractionalDurationPreserved() throws {
        // Synthetic audio.m4a: 30 s of AAC rounded up to whole frames = 30.000181 seconds.
        let s = try start(fixture("audio.m4a"))
        XCTAssertEqual(s.player.duration, 30.000181, accuracy: 0.000002, "Duration truncated to whole seconds")
        try assertPlayback(s, video: false)
    }
    func testReviewManualPauseCancelsBackgroundAutoResume() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        s.player.pause()
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(s.player.state, .suspend, "Foreground overrode manual pause while backgrounded")
    }

    func testReviewStopStopsAudioGraphBeforeDisposal() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        let audio = try XCTUnwrap(s.player.audioManager)
        XCTAssertTrue(audio.playing)
        s.stop()
        XCTAssertFalse(audio.playing, "Audio graph disposed while still marked playing")
        audio.play()
        XCTAssertFalse(audio.playing, "Disposed audio manager restarted")
    }
    func testReviewRepeatedOpenStopDrainsAudioRendering() throws {
        let s = PlaybackSession(url: try fixture("sample.mp4")); sessions.append(s)
        for iteration in 0..<12 {
            s.ready = false; s.failure = nil; s.stopRequested = false; s.start()
            try require(until(8) { s.ready || s.failure != nil }, "Audio stress open timed out at \(iteration)")
            try require(s.failure == nil, "Audio stress open failed")
            let audio = try XCTUnwrap(s.player.audioManager)
            s.stop()
            XCTAssertFalse(audio.playing, "Iteration \(iteration) disposed a live audio graph")
            pump(0.03)
        }
    }

    func testSeekBufferingCompletionWaitsForDelayedTargetMedia() throws {
        continueAfterFailure = true
        let s = try start(fixture("sustained-h264-aac.mp4"), cache: true, policy: .ffmpeg)
        try assertPlayback(s)
        let observer = SeekLoadingObserver(), delay = SeekPrerollDelaySource()
        let decoder = try XCTUnwrap(s.player.decoder)
        s.player.playbackDelegate = observer
        decoder.source = delay
        defer { decoder.source = nil; withExtendedLifetime(delay) {} }
        delay.arm()
        var result: Bool?, callbackWhileBuffering: Bool?
        s.player.seek(to: 12) { success in
            callbackWhileBuffering = decoder.buffering || s.player.state == .buffering
            result = success
            observer.events.append("completion")
        }
        try require(until { s.player.state == .buffering || result != nil }, "Seek never entered buffering")
        pump(0.1)
        XCTAssertNil(result, "Demux success ended seek while target frames were still decoding")
        XCTAssertTrue(observer.loading, "Loading disappeared before target media was available")
        try require(until(10) { result != nil || s.failure != nil }, "Seek did not complete after decoding target media")
        XCTAssertEqual(result, true)
        XCTAssertEqual(callbackWhileBuffering, false, "Successful completion was delivered with a buffering playback state")
        try require(until(5) { !decoder.buffering && s.sink.lastPresentationTime >= 11.95 }, "Target picture never became available")
        XCTAssertFalse(observer.loading)
        XCTAssertEqual(observer.events.suffix(2), ["end", "completion"], "Loading end must precede successful seek completion")
        s.measurements.append(["operation": "seek-completion-waits-for-target-media", "target": 12,
            "completedWhileBuffering": callbackWhileBuffering as Any? ?? NSNull(), "events": observer.events])
    }


    func testHighRateSeekWaitsForDelayedVideoBeforeStartingAudioClock() throws {
        let session = try start(fixture("sample.mp4"), policy: .ffmpeg)
        try assertPlayback(session)
        let delayed = SeekPrerollDelaySource()
        session.player.decoder?.source = delayed
        let target = min(10, session.player.duration * 0.3)
        let before = session.sink.frames
        delayed.arm()
        session.player.rate = 16
        var complete: Bool?
        session.player.seek(to: target) { complete = $0 }
        try require(until(10) { complete != nil || session.failure != nil }, "Seek callback missing")
        XCTAssertEqual(complete, true)
        try require(until(10) {
            session.sink.frames > before && (session.player.decoder?.currentVideoFrame?.position ?? -1) >= target - 0.3 || session.failure != nil
        }, "Delayed video did not reach seek target")
        XCTAssertNil(session.failure)
        XCTAssertLessThanOrEqual(session.player.decoder?.currentVideoFrame?.position ?? .infinity, target + 4,
                                 "Audio clock skipped the requested picture while video was delayed")
        withExtendedLifetime(delayed) {}
    }

    // ±10 s buttons seek relative to `progress`: an accepted seek must publish its target at once,
    // so rapid taps accumulate instead of restarting from the stale playback position.
    private func checkRelativeSeekBurst(_ deltas: [Double]) throws {
        let s = try start(fixture("sample.mp4"))
        try assertPlayback(s)
        try require(until { s.player.currentTime > 0.2 }, "Playback did not advance")
        s.player.pause(); pump(0.1)
        var expected = s.player.currentTime
        for delta in deltas {
            expected = min(s.player.duration, max(0, expected + delta))
            s.player.seek(to: min(s.player.duration, max(0, s.player.progress + delta)))
            XCTAssertEqual(s.player.progress, expected, accuracy: 0.1, "Pending seek target was not published to progress")
        }
        try require(until { s.player.decoder?.seeking == false || s.failure != nil }, "Seek burst did not settle")
        pump(0.3)
        XCTAssertNil(s.failure)
        XCTAssertEqual(s.player.currentTime, expected, accuracy: 0.5, "Rapid relative seeks used stale progress instead of the pending target")
        s.player.play()
        try require(until { s.player.currentTime > expected + 0.1 || s.player.state == .finished }, "Playback did not resume after the burst")
    }
    func testRelativeSeekBurstDoubleForwardAccumulates() throws { try checkRelativeSeekBurst([10, 10]) }
    func testRelativeSeekBurstMixedDirectionsAccumulate() throws { try checkRelativeSeekBurst([10, 10, 10, -10, -10, 10]) }

    // Replay after a 16x finish: seek(0) must reset the buffer bar before the second pass,
    // which must again fill monotonically to 1.
    func testBufferProgressResetsOnReplayAfter16xFinish() throws {
        let s = PlaybackSession(url: try fixture("sample.mp4"), policy: .ffmpeg)
        sessions.append(s)
        let observer = BoundaryProgressObserver()
        s.player.progressDelegate = observer
        s.player.rate = 16
        s.start()
        try require(until(45) { s.finished == 1 || s.failure != nil }, "First 16x pass did not finish")
        pump(0.1)
        XCTAssertEqual(s.player.bufferProgress, 1)
        s.player.seek(to: 0)
        XCTAssertEqual(s.player.bufferProgress, 0, "Replay retained the previous full buffer endpoint")
        pump(0.02)
        observer.buffers.removeAll()
        s.player.play()
        try require(until(45) { s.finished == 2 || s.failure != nil }, "Replay did not finish")
        pump(0.1)
        XCTAssertNil(s.failure)
        XCTAssertEqual(s.player.bufferProgress, 1, "Buffer bar left a gap after the replay")
        XCTAssertEqual(observer.buffers.last, 1)
        XCTAssertTrue(zip(observer.buffers, observer.buffers.dropFirst()).allSatisfy { $0 <= $1 }, "Buffer bar moved backward during the 16x replay")
    }

    // From 2x up the decoder discards non-reference pictures, so frames already queued at 8x are
    // sparse. Lowering the rate with a seek at the current time must decode again: the output right
    // after the switch is continuous in PTS and never moves backward.
    func testReturnFrom8xTo1xWithRedecodeSeekShowsFullFrameRateImmediately() throws {
        let s = try start(fixture("sample.mp4"))
        try assertPlayback(s)
        s.player.rate = 8
        try require(until(4) { s.player.progress > 8 || s.failure != nil }, "8x did not fill the frame queue")
        s.player.rate = 1
        s.player.seek(to: s.player.currentTime)
        let frames = s.sink.frames
        pump(1.5)
        XCTAssertNil(s.failure)
        let after = s.sink.presentationTimes(after: frames)
        XCTAssertGreaterThan(after.count, 10, "Playback did not resume after the switch")
        let gaps = zip(after, after.dropFirst()).map { $1 - $0 }
        XCTAssertLessThanOrEqual(gaps.max() ?? .infinity, 2.0 / 24 + 0.005,
                                 "Frames sampled for 8x played at 1x: gaps \(gaps.map { String(format: "%.3f", $0) })")
        XCTAssertFalse(after.contains { $0 < after[0] - 0.001 }, "Playback moved backwards")
    }

}

/// Deterministic capacity limit before the real decoder; no synthetic output frames.
private final class SustainedDecodeThrottle: FTVideoDecoderDataSource {
    @Atomic var delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }
    func shouldHandle(_ videoDecoder: FTVideoDecoderInfo, decodeFrame packet: AVPacket) -> Bool {
        let interval = delay
        if interval > 0 { Thread.sleep(forTimeInterval: interval) }
        return false
    }
    func videoDecoder(_ videoDecoder: FTVideoDecoderInfo, decodeFrame packet: AVPacket) -> FTVideoFrame? { nil }
}

private final class LongSeekPrerollFrameSource: FTVideoDecoderDataSource {
    private let pixelBuffer: CVPixelBuffer
    private let lock = NSLock()
    private var didInject = false
    var injected: Bool { lock.withLock { didInject } }

    init() throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
            kCVPixelFormatType_32BGRA, nil, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        pixelBuffer = try XCTUnwrap(buffer)
    }

    func shouldHandle(_ videoDecoder: FTVideoDecoderInfo, decodeFrame packet: AVPacket) -> Bool {
        // Initial playback remains real decode. Only the distant seek epoch
        // reaches these packets before its first output picture.
        Double(packet.pts) * videoDecoder.timebase >= 50
    }

    func videoDecoder(_ videoDecoder: FTVideoDecoderInfo, decodeFrame packet: AVPacket) -> FTVideoFrame? {
        let first = lock.withLock { () -> Bool in
            guard !didInject else { return false }
            didInject = true
            return true
        }
        let frame = FTCVYUVVideoFrame(pixelBuffer: pixelBuffer)
        frame.position = first ? 35.854766 : Double(packet.pts) * videoDecoder.timebase
        frame.duration = first ? 2.493011111111111 : 1 / videoDecoder.fps
        return frame
    }
}

private final class SeekPrerollDelaySource: FTVideoDecoderDataSource {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func shouldHandle(_ videoDecoder: FTVideoDecoderInfo, decodeFrame packet: AVPacket) -> Bool {
        let delay = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false
            return true
        }
        if delay { Thread.sleep(forTimeInterval: 0.5) }
        return false
    }
    func videoDecoder(_ videoDecoder: FTVideoDecoderInfo, decodeFrame packet: AVPacket) -> FTVideoFrame? { nil }
}

private final class ReviewVideoOutput: FTPlayerVideoOutput {
    var positions: [TimeInterval] = []
    var retained: CVPixelBuffer?
    var onMain = true
    var playerMatches = true
    func player(_ player: FTPlayer, didOutput pixelBuffer: CVPixelBuffer,
                presentationTime: TimeInterval) {
        onMain = onMain && Thread.isMainThread
        playerMatches = playerMatches && player.videoOutput === self
        retained = pixelBuffer
        positions.append(presentationTime)
    }
}

/// Measures wall-clock work, rather than treating an advancing media clock as smooth video.
final class FTPlayerHighRateLoadPlaybackTests: DecodeBackendTestCase {
    @objc func testHighRateNotificationsAreBounded() throws {
        continueAfterFailure = true
        let s = try start(http("sustained-h264-aac.mp4"), cache: true)
        try assertPlayback(s)
        let observer = HighRateProgressProbe()
        s.player.progressDelegate = observer
        s.player.rate = 16
        pump(0.4)
        observer.reset()
        let initial = s.player.currentTime
        let start = ProcessInfo.processInfo.systemUptime
        pump(3)
        let wall = ProcessInfo.processInfo.systemUptime - start
        let limit = Int(ceil(wall * 31)) + 3
        XCTAssertLessThanOrEqual(observer.progress, limit, "PCM consumption flooded the UI queue at high rate")
        XCTAssertLessThanOrEqual(observer.buffer, limit, "Packet refill flooded the UI queue at high rate")
        XCTAssertGreaterThan(s.player.currentTime - initial, 24)
        // Limiting periodic UI updates must not delay a user-visible seek target.
        s.player.pause()
        s.player.seek(to: 20)
        XCTAssertEqual(s.player.currentTime, 20, accuracy: 0.00001)
    }
    @objc func testHighRateLoadH264() throws { try measureLoad("sustained-h264-aac.mp4") }
    @objc func testHighRateLoadHEVC() throws { try measureLoad("sustained-hevc-aac.mp4") }

    private func measureLoad(_ file: String) throws {
        var results: [[String: Any]] = []
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        let renderer = FTMediaRendererView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        controller.view.addSubview(renderer)
        defer { window.isHidden = true }
        for cache in [false, true] {
            let s = try start(http(file), cache: cache)
            let output = HighRateRenderProbe(sink: s.sink, renderer: renderer)
            s.player.videoOutput = output
            let observer = HighRateProgressProbe()
            s.player.progressDelegate = observer
            try assertPlayback(s)
            for rate: Float in [1, 4, 8, 16] {
                s.player.rate = 1
                var sought: Bool?
                s.player.seek(to: 5) { sought = $0 }
                try require(until(15) { sought != nil }, "Measurement seek timed out")
                try require(sought == true, "Measurement seek failed")
                try require(until(15) { !s.player.decoder!.buffering && s.sink.lastPresentationTime >= 4.9 }, "Measurement preroll stalled")
                s.player.rate = rate
                pump(0.6)
                let heartbeat = HighRateMainHeartbeat()
                let cpu = Self.cpuSeconds()
                let requests = s.player.decoder?.cacheDiagnostics["rangeRequests"] ?? 0
                let initial = s.player.currentTime
                let firstFrame = s.sink.frames
                observer.reset()
                let began = ProcessInfo.processInfo.systemUptime
                pump(4)
                let wall = ProcessInfo.processInfo.systemUptime - began
                let cpuUsed = Self.cpuSeconds() - cpu
                heartbeat.stop()
                let presentations = s.sink.presentationEvents(after: firstFrame)
                let gaps = zip(presentations, presentations.dropFirst()).map { $1.wall - $0.wall }
                let lastAge = presentations.last.map { ProcessInfo.processInfo.systemUptime - $0.wall } ?? wall
                let row: [String: Any] = ["rate": rate, "cache": cache, "wall": wall,
                    "cpuCorePercent": 100 * cpuUsed / wall, "rssBytes": Self.residentBytes(),
                    "mediaDelta": s.player.currentTime - initial, "frames": presentations.count,
                    "maxImageGap": max(gaps.max() ?? 0, lastAge),
                    "mainQueueMaxLatency": heartbeat.maximum, "mainQueueP95Latency": heartbeat.p95,
                    "progressCallbacks": observer.progress, "playableCallbacks": observer.playable,
                    "bufferCallbacks": observer.buffer, "downloadCallbacks": observer.download,
                    "rangeRequests": (s.player.decoder?.cacheDiagnostics["rangeRequests"] ?? 0) - requests,
                    "decoder": s.player.decoder?.diagnosticSnapshot ?? "none"]
                results.append(row)
                print("HIGH_RATE_LOAD " + String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
                XCTAssertNil(s.failure)
                XCTAssertGreaterThan(presentations.count, 0, "No picture output during sustained playback")
                XCTAssertGreaterThan(s.player.currentTime - initial, Double(rate), "Playback did not advance")
                let callbackLimit = Int(ceil(wall * 31)) + 3
                XCTAssertLessThanOrEqual(observer.progress, callbackLimit)
                XCTAssertLessThanOrEqual(observer.buffer, callbackLimit)
            }
            s.player.progressDelegate = nil
            s.stop()
            pump(0.3)
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "high-rate-load-" + file + ".json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

private final class HighRateRenderProbe: FTPlayerVideoOutput {
    let sink: PixelSink
    let renderer: FTMediaRendererView
    init(sink: PixelSink, renderer: FTMediaRendererView) { self.sink = sink; self.renderer = renderer }
    func player(_ player: FTPlayer, didOutput pixelBuffer: CVPixelBuffer, presentationTime: TimeInterval) {
        sink.player(player, didOutput: pixelBuffer, presentationTime: presentationTime)
        renderer.player(player, didOutput: pixelBuffer, presentationTime: presentationTime)
    }
}

private final class HighRateProgressProbe: FTPlayerProgressDelegate {
    var progress = 0, playable = 0, buffer = 0, download = 0
    func reset() { progress = 0; playable = 0; buffer = 0; download = 0 }
    func player(_ player: FTPlayer, didUpdateProgress value: TimeInterval) { progress += 1 }
    func player(_ player: FTPlayer, didUpdatePlayable value: TimeInterval) { playable += 1 }
    func player(_ player: FTPlayer, didUpdateBufferProgress value: Double) { buffer += 1 }
    func player(_ player: FTPlayer, didUpdateDownloadProgress value: Double) { download += 1 }
}

/// Only one heartbeat may be outstanding, so the probe cannot create queue pressure itself.
private final class HighRateMainHeartbeat {
    private let lock = NSLock()
    private var pending = false
    private var active = true
    private var samples: [Double] = []
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test.main-heartbeat"))
    init() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let enqueue = self.lock.withLock { () -> Bool in
                guard self.active, !self.pending else { return false }
                self.pending = true
                return true
            }
            guard enqueue else { return }
            let start = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                self.lock.withLock { self.samples.append(elapsed); self.pending = false }
            }
        }
        timer.resume()
    }
    func stop() { lock.withLock { active = false }; timer.cancel() }
    var maximum: Double { lock.withLock { samples.max() ?? 0 } }
    var p95: Double { lock.withLock { let sorted = samples.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count-1, Int(Double(sorted.count) * 0.95))] } }
    deinit { stop() }
}

/// Reentrant control: seek is called inside the public ready callback itself.
final class FTPlayerReadySeekTests: DecodeBackendTestCase {
    @objc func testReadySeekMP4H264DefaultCache() throws { try checkReadySeek("sustained-h264-aac.mp4", cache: nil) }
    @objc func testReadySeekMP4H264Cached() throws { try checkReadySeek("sustained-h264-aac.mp4", cache: true) }
    @objc func testReadySeekMP4HEVCDefaultCache() throws { try checkReadySeek("sustained-hevc-aac.mp4", cache: nil) }
    @objc func testReadySeekMP4HEVCCached() throws { try checkReadySeek("sustained-hevc-aac.mp4", cache: true) }
    @objc func testReadySeekHLSH264DefaultCache() throws { try checkReadySeek("hls-ts/index.m3u8", cache: nil) }
    @objc func testReadySeekHLSH264Cached() throws { try checkReadySeek("hls-ts/index.m3u8", cache: true) }
    @objc func testReadySeekHLSHEVCDefaultCache() throws { try checkReadySeek("hls-hevc/index.m3u8", cache: nil) }
    @objc func testReadySeekHLSHEVCCached() throws { try checkReadySeek("hls-hevc/index.m3u8", cache: true) }

    private func checkReadySeek(_ source: String, cache: Bool?) throws {
        try checkImmediateReadySeek(url: http(source), cache: cache)
    }
}

extension DecodeBackendTestCase {
    func checkImmediateReadySeek(url: URL, cache: Bool?, timeout: TimeInterval = 20) throws {
        for rate: Float in [1, 8, 16] {
            let s = PlaybackSession(url: url, cache: cache, policy: .ffmpeg)
            sessions.append(s)
            let progress = BoundaryProgressObserver()
            s.player.progressDelegate = progress
            s.player.rate = rate
            var readyCount = 0, completions = 0, progressIndex = 0, framesAtReady = 0
            var target = -1.0, immediateProgress = -1.0
            var completed: Bool?, returnedFromReady = false, completionOnMain = false
            s.onReady = { [weak s] in
                guard let s else { return }
                readyCount += 1
                framesAtReady = s.sink.frames
                progressIndex = progress.values.count
                target = min(40, s.player.duration * 0.35)
                XCTAssertTrue(Thread.isMainThread)
                // Deliberately no async dispatch, sleep, pump or wait for a first frame.
                s.player.seek(to: target) { success in
                    completions += 1; completed = success
                    completionOnMain = Thread.isMainThread
                }
                immediateProgress = s.player.currentTime
                returnedFromReady = true
            }
            s.start()
            try require(until(timeout) { completed != nil || s.failure != nil }, "Seek issued inside ready did not complete: \(url.host ?? "local")")
            XCTAssertNil(s.failure)
            XCTAssertTrue(returnedFromReady)
            XCTAssertEqual(readyCount, 1)
            XCTAssertEqual(completed, true)
            XCTAssertEqual(completions, 1)
            XCTAssertTrue(completionOnMain)
            XCTAssertEqual(immediateProgress, target, accuracy: 0.00001, "Ready seek did not publish its requested target synchronously")
            try require(until(timeout) { s.sink.frames >= framesAtReady + 3 || s.failure != nil || s.finished > 0 }, "Ready seek never produced post-target video")
            pump(0.15)
            let positions = s.sink.presentationTimes(after: framesAtReady)
            let updates = Array(progress.values.dropFirst(progressIndex))
            XCTAssertNil(s.failure)
            XCTAssertEqual(completions, 1, "Seek completion was delivered twice")
            XCTAssertEqual(readyCount, 1, "Seeking restarted ready notification")
            XCTAssertEqual(s.finished, 0, "Startup EOF/finish crossed the immediate ready seek")
            XCTAssertGreaterThanOrEqual(positions.count, 3)
            // A frame spans an interval: the seek preroll allows the image
            // whose end reaches target - 50 ms, not only images starting there.
            let sourceFrameDuration = 1 / max(1, s.player.mediaInfo?.framesPerSecond ?? 24)
            XCTAssertTrue(positions.allSatisfy { $0 + sourceFrameDuration >= target - 0.05001 }, "Pre-seek pictures crossed the ready callback boundary: \(positions.prefix(8))")
            XCTAssertFalse(updates.isEmpty)
            XCTAssertEqual(updates.first ?? -1, target, accuracy: 0.00001)
            XCTAssertTrue(updates.allSatisfy { $0 >= target - 0.00001 }, "Startup progress overwrote ready's explicit seek target")
            XCTAssertTrue(progress.onMain)
            XCTAssertGreaterThan(s.player.currentTime, target, "Playback remained stuck after ready seek")
            s.measurements.append(["operation": "seek-directly-inside-playerReadyToPlay", "rate": rate,
                "cacheAssigned": cache != nil, "useCache": s.player.useCache, "readyCount": readyCount,
                "target": target, "immediateProgress": immediateProgress, "completionCount": completions,
                "sourceFrameDuration": sourceFrameDuration,
                "framesAtReady": framesAtReady, "postSeekVideoPTS": positions, "progressUpdates": updates,
                "decoder": s.player.decoder?.diagnosticSnapshot ?? "none"])
            s.onReady = nil
            s.stop()
            pump(0.1)
        }
    }
}

final class FTPlayerWeakNetworkRateTests: DecodeBackendTestCase {
    @objc func testWeakNetworkH264DefaultCache() throws { try checkWeakNetwork("sustained-h264-aac.mp4", cache: nil) }
    @objc func testWeakNetworkH264Cached() throws { try checkWeakNetwork("sustained-h264-aac.mp4", cache: true) }
    @objc func testWeakNetworkHEVCDefaultCache() throws { try checkWeakNetwork("sustained-hevc-aac.mp4", cache: nil) }
    @objc func testWeakNetworkHEVCCached() throws { try checkWeakNetwork("sustained-hevc-aac.mp4", cache: true) }
    @objc func testWeakNetworkVideoOnlyDefaultCache() throws { try checkWeakNetwork("sustained-h264-video.mp4", cache: nil) }
    @objc func testWeakNetworkVideoOnlyCached() throws { try checkWeakNetwork("sustained-h264-video.mp4", cache: true) }
    @objc func testWeakNetworkHLSDefaultCache() throws { try checkWeakNetwork("independent-hls.m3u8", cache: nil) }
    @objc func testWeakNetworkHLSCached() throws { try checkWeakNetwork("independent-hls.m3u8", cache: true) }
    @objc func testWeakNetworkHEVCStartsSlowWithAudioAhead() throws {
        try checkWeakNetwork("sustained-hevc-aac.mp4", cache: true, startsSlow: true)
    }

    private func checkWeakNetwork(_ path: String, cache: Bool?, startsSlow: Bool = false) throws {
        let url = try http(path)
        let network = try XCTUnwrap(server)
        defer { network.setBodyBytesPerSecond(nil); network.setNetworkMode(.online, dropExistingConnections: true) }
        for rate: Float in [8, 16] {
            // Pace from the first byte as well, so startup cannot enqueue the
            // whole small file into TCP before the bandwidth limit is applied.
            // Opening/probing is separate from the playback-starvation interval.
            let startupBandwidth = path.contains("hevc") ? 4 * 1024 * 1024 : 128 * 1024
            network.setBodyBytesPerSecond(startsSlow ? 1024 : startupBandwidth,
                                          initialBurstBytes: startsSlow ? 2 * 1024 * 1024 : 0)
            let s = try start(url, cache: cache, policy: .ffmpeg)
            try assertPlayback(s)
            let stateStart = s.states.count, eventStart = s.bufferingEvents.count
            let byteStart = network.throttledBytes
            network.setBodyBytesPerSecond(1024)
            s.player.rate = rate
            let start = ProcessInfo.processInfo.systemUptime
            var lastPictureWall = start, lastFrames = s.sink.frames, maxSilentStall = 0.0
            var bufferingSince: TimeInterval?
            var worstStallSnapshot = ""
            var samples: [[String: Any]] = []
            // Low bandwidth must drain RAM/disk lookahead without seeking into a
            // fabricated cache hole. The player itself decides when to rebuffer.
            while ProcessInfo.processInfo.systemUptime - start < 20 {
                pump(0.02)
                let now = ProcessInfo.processInfo.systemUptime
                if s.sink.frames != lastFrames { lastFrames = s.sink.frames; lastPictureWall = now }
                if s.player.state != .playing { lastPictureWall = now }
                if s.player.state == .playing, now - lastPictureWall > maxSilentStall {
                    maxSilentStall = now - lastPictureWall
                    if maxSilentStall > 0.4 { worstStallSnapshot = s.player.decoder?.diagnosticSnapshot ?? "none" }
                }
                samples.append(["wall": now-start, "state": String(describing: s.player.state), "progress": s.player.currentTime,
                    "frames": s.sink.frames, "videoPTS": s.sink.lastPresentationTime,
                    "bufferSeconds": s.player.decoder?.bufferedDuration ?? -1,
                    "engineBuffering": s.player.decoder?.buffering ?? false])
                if s.player.state == .buffering {
                    bufferingSince = bufferingSince ?? now
                    if now - bufferingSince! >= 0.4 { break }
                } else { bufferingSince = nil }
                if s.failure != nil || s.finished > 0 { break }
            }
            let entered = s.player.state == .buffering
            let stalledAt = s.player.currentTime
            let framesAtBuffering = s.sink.frames
            // Remain bandwidth-starved to detect an erroneous immediate switch
            // back to playing without receiving enough media.
            pump(0.6)
            let stayed = s.player.state == .buffering
            let drift = s.player.currentTime - stalledAt
            let stateWhileWeak = Array(s.states.dropFirst(stateStart))
            let eventsWhileWeak = Array(s.bufferingEvents.dropFirst(eventStart))
            let weakBytes = network.throttledBytes - byteStart
            network.setBodyBytesPerSecond(nil)
            network.setNetworkMode(.online, dropExistingConnections: true)
            let recovered = until(20) { s.failure != nil || s.player.state == .playing && s.sink.frames > framesAtBuffering + 3 && s.player.currentTime > stalledAt + 0.2 }
            s.measurements.append(["operation": "high-rate-actual-low-bandwidth-buffering", "rate": rate,
                "cacheAssigned": cache != nil, "useCache": s.player.useCache, "bandwidthBytesPerSecond": 1024,
                "startupBytesPerSecond": startupBandwidth, "worstStallSnapshot": worstStallSnapshot,
                "startsSlow": startsSlow,
                "pacedBytes": weakBytes, "enteredBuffering": entered, "stayedBuffering": stayed,
                "clockDriftWhileBuffering": drift, "maximumPictureStallWhilePlaying": maxSilentStall,
                "statesWhileWeak": stateWhileWeak, "eventsWhileWeak": eventsWhileWeak,
                "recovered": recovered, "samples": samples, "decoder": s.player.decoder?.diagnosticSnapshot ?? "none"])
            XCTAssertNil(s.failure)
            XCTAssertEqual(s.finished, 0, "Network starvation was treated as EOF")
            XCTAssertTrue(entered, "Insufficient download never changed public state to buffering")
            XCTAssertTrue(stayed, "Player reported playing while bandwidth was still insufficient")
            XCTAssertTrue(eventsWhileWeak.contains { $0["event"] as? String == "start" }, "Buffering-start delegate was not delivered")
            XCTAssertLessThan(maxSilentStall, 0.8, "Pictures froze while public state remained playing")
            XCTAssertLessThan(abs(drift), 0.3, "Clock kept advancing while buffering")
            XCTAssertTrue(recovered, "Returning network did not resume pictures/progress")
            XCTAssertTrue(s.bufferingEvents.dropFirst(eventStart).contains { $0["event"] as? String == "end" }, "Buffering-end delegate was not delivered")
            s.stop()
            pump(0.15)
        }
    }
}
