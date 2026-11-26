import XCTest
import libavformat
import libavcodec
@testable import FTPlayer

final class FTPlayerHLSTests: PlaybackTestCase {
    func testPartialAudioPacketPressureDoesNotOscillateBuffering() throws {
        try checkPartialAudioPacketPressure(cache: true, seek: false)
    }

    func testSeekPartialAudioPacketPressureDoesNotOscillateBuffering() throws {
        try checkPartialAudioPacketPressure(cache: false, seek: true)
    }

    private func checkPartialAudioPacketPressure(cache: Bool, seek: Bool) throws {
        let s = try start(http("partial-audio-pressure.m3u8"), cache: cache, policy: .ffmpeg)
        try require(until(8) { s.sink.frames > 0 || s.failure != nil }, "No first video frame")
        if seek {
            var completed: Bool?
            s.player.seek(to: 0.6) { completed = $0 }
            try require(until(6) { completed == true || s.failure != nil }, "Seek did not prepare target")
            XCTAssertEqual(completed, true)
        }
        let began = ProcessInfo.processInfo.systemUptime
        let clock = s.player.currentTime, frames = s.sink.frames
        let bufferingEvents = s.bufferingEvents.count
        pump(4)
        let transitions = s.bufferingEvents.count - bufferingEvents
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        s.measurements.append(["operation": "partial-audio-packet-pressure", "seek": seek,
            "cache": cache, "wall": elapsed, "mediaDelta": s.player.currentTime - clock,
            "newFrames": s.sink.frames - frames, "bufferingTransitions": transitions,
            "snapshot": s.player.decoder?.diagnosticSnapshot ?? "closed"])
        // A single depletion/recovery is allowed; tick-driven alternating states
        // must not restart the host audio graph while ready media is unchanged.
        XCTAssertLessThanOrEqual(transitions, 6, "Buffering toggled repeatedly on the same partial PCM queue")
        XCTAssertGreaterThan(s.player.currentTime - clock, elapsed * 0.75,
                             "Sparse audio stalled the clock while video was ready")
        XCTAssertGreaterThanOrEqual(s.sink.frames - frames, 2)
        XCTAssertNil(s.failure)
        s.stop()
    }

    func testEmptyAudioTrackHLSStartsCached() throws { try checkEmptyAudioTrackHLS(cache: true) }
    func testEmptyAudioTrackHLSStartsWithoutCache() throws { try checkEmptyAudioTrackHLS(cache: false) }

    func testEmptyAudioFixtureDeclaresTrackWithoutPackets() throws {
        let format = FTFormatContext(contentURL: try fixture("empty-audio.mp4"), videoFormat: .unknown)
        format.setupSync(useCache: false)
        defer { format.destroy() }
        XCTAssertNil(format.error)
        XCTAssertTrue(format.audioEnable)
        var packet = av_packet_alloc(), audioPackets = 0, videoPackets = 0
        defer { av_packet_free(&packet) }
        while format.readFrame(packet) >= 0 {
            if packet?.pointee.stream_index == Int32(format.audioTrack?.index ?? -1) { audioPackets += 1 }
            if packet?.pointee.stream_index == Int32(format.videoTrack?.index ?? -1) { videoPackets += 1 }
            av_packet_unref(packet)
        }
        XCTAssertEqual(audioPackets, 0)
        XCTAssertEqual(videoPackets, 30)
    }

    private func checkEmptyAudioTrackHLS(cache: Bool) throws {
        let s = try start(http("empty-audio-hls.m3u8"), cache: cache, policy: .ffmpeg)
        // Keep the advertised track; it may have real audio in later periods.
        XCTAssertEqual(s.player.mediaInfo?.audioCodec, "aac")
        try require(until(8) { s.sink.frames >= 3 && s.player.currentTime > 1.5 || s.failure != nil },
                    "Video with an empty audio track remained in startup buffering: \(s.player.decoder?.diagnosticSnapshot ?? "closed")")
        XCTAssertNil(s.failure)
        let fps = s.player.videoFrameRateStatistics.timelineFramesPerSecond
        XCTAssertEqual(try XCTUnwrap(fps), 1, accuracy: 0.03)
        s.player.pause(); pump(0.15)
        let paused = s.player.currentTime
        pump(0.3)
        XCTAssertEqual(s.player.currentTime, paused, accuracy: 0.08)
        s.player.play()
        try require(until(3) { s.player.currentTime > paused + 0.5 }, "Silent interval did not resume")
        s.player.rate = 4
        var completed: Bool?
        s.player.seek(to: 35) { completed = $0 }
        try require(until(8) { completed == true && s.sink.lastPresentationTime >= 35 && s.player.currentTime > 36 },
                    "Seek into a silent period did not resume: \(s.player.decoder?.diagnosticSnapshot ?? "closed")")
        let start = s.player.currentTime, wall = ProcessInfo.processInfo.systemUptime
        pump(1)
        let measuredRate = (s.player.currentTime - start) / (ProcessInfo.processInfo.systemUptime - wall)
        XCTAssertEqual(measuredRate, 4, accuracy: 0.6)
        s.measurements.append(["operation": "empty-audio", "cache": cache, "measuredRate": measuredRate,
                               "frames": s.sink.frames, "clock": s.player.currentTime])
        s.stop(); let frames = s.sink.frames; pump(0.2)
        XCTAssertEqual(s.sink.frames, frames)
    }

    func testEmptyAudioPeriodKeepsLaterAudioAndFinishes() throws {
        let s = try start(http("late-audio-hls.m3u8"), cache: true, policy: .ffmpeg)
        try assertPlayback(s)
        var complete: Bool?
        s.player.seek(to: 27) { complete = $0 }
        s.player.rate = 4
        try require(until(8) { complete == true && s.player.currentTime > 34 && s.sink.lastPresentationTime > 33 },
                    "Audio after the silent period did not remain on the timeline")
        XCTAssertEqual(s.player.mediaInfo?.audioCodec, "aac")
        let origin = s.player.currentTime, wall = ProcessInfo.processInfo.systemUptime
        XCTAssertGreaterThan(s.player.decoder?.audioTimeClock ?? 0, 30)
        XCTAssertFalse(s.player.decoder?.diagnosticSnapshot.contains("audioDecodedSamples=0 ") ?? true)
        pump(1)
        XCTAssertEqual((s.player.currentTime - origin) / (ProcessInfo.processInfo.systemUptime - wall), 4, accuracy: 0.6)
        s.player.seek(to: 58)
        try require(until(6) { s.finished == 1 || s.failure != nil }, "Late audio/video tail never finished")
        XCTAssertNil(s.failure)
        XCTAssertEqual(s.finished, 1)
    }

    func testEmptyAudioTrackFileFinishesAtVideoTail() throws {
        let s = try start(fixture("empty-audio.mp4"), policy: .ffmpeg)
        try assertPlayback(s)
        var complete: Bool?
        s.player.seek(to: 27) { complete = $0 }
        s.player.rate = 4
        try require(until(5) { s.finished > 0 || s.failure != nil }, "Empty audio track held video EOF")
        XCTAssertEqual(complete, true)
        XCTAssertEqual(s.finished, 1)
        XCTAssertGreaterThanOrEqual(s.sink.lastPresentationTime, 29)
        XCTAssertGreaterThanOrEqual(s.player.currentTime, 29.8)
        XCTAssertNil(s.failure)
    }

    func testIndependentHLSZeroDurationUsesActualMP4Metadata() throws {
        let source = try http("zero-duration-independent-hls.m3u8")
        let cache = try FTPlaybackCacheSession()
        defer { cache.close() }
        let manifest = try XCTUnwrap(FTIndependentHLS.prepare(source: source, session: cache,
            timeout: 5, interrupted: { false }, preparation: nil),
            "Zero EXTINF fell through to native HLS's 1ms placeholder")
        XCTAssertEqual(Array(manifest.segments.prefix(3)).map(\.duration), [30, 30, 30],
            "Valid declared durations must remain unchanged")
        XCTAssertEqual(try XCTUnwrap(manifest.segments.last).duration, 30.021995, accuracy: 0.000001,
            "The fixture's container includes an audio tail beyond its 30s video")
        XCTAssertNil(manifest.playlist, "Independent complete MP4 files need separate demux timelines")
        let requests = server!.requests
        let restored = try XCTUnwrap(FTIndependentHLS.prepare(source: source, session: cache,
            timeout: 5, interrupted: { false }, preparation: nil))
        XCTAssertEqual(restored.segments.last?.duration, manifest.segments.last?.duration)
        XCTAssertEqual(server!.requests, requests, "Restoring a repaired timeline must not reprobe its media")
    }

    func testIndependentHLSInvalidDurationProbeFailureDoesNotFallBackToFalseEOF() throws {
        let source = try http("zero-duration-independent-hls.m3u8")
        let loader = DurationPlaylistStub("#EXTM3U\n#EXTINF:0,\nmissing.mp4\n#EXT-X-ENDLIST\n")
        let cache = try FTPlaybackCacheSession()
        defer { cache.close() }
        XCTAssertThrowsError(try FTIndependentHLS.prepare(source: source, session: cache,
            timeout: 3, interrupted: { false }, preparation: nil, loader: loader))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.directory.appendingPathComponent("hls-source.json").path))
    }

    func testIndependentHLSInvalidDurationProbeHonorsTimeoutAndCancellation() throws {
        let source = try http("zero-duration-independent-hls.m3u8")
        let loader = DurationPlaylistStub("#EXTM3U\n#EXTINF:0,\nstall.mp4\n#EXT-X-ENDLIST\n")
        for cancel in [false, true] {
            let cache = try FTPlaybackCacheSession()
            defer { cache.close() }
            let began = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try FTIndependentHLS.prepare(source: source, session: cache,
                timeout: cancel ? 3 : 0.3,
                interrupted: { cancel && ProcessInfo.processInfo.systemUptime - began > 0.1 },
                preparation: nil, loader: loader)) { error in
                XCTAssertEqual((error as NSError).domain, NSURLErrorDomain)
                XCTAssertEqual((error as NSError).code, cancel ? URLError.cancelled.rawValue : URLError.timedOut.rawValue)
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.directory.appendingPathComponent("hls-source.json").path))
        }
    }

    func testIndependentHLSInvalidDurationDoesNotProbeOtherPlaylistShapes() throws {
        let source = try http("zero-duration-independent-hls.m3u8")
        let body = "#EXTINF:0,\nfirst.mp4\n#EXT-X-DISCONTINUITY\n#EXTINF:30,\nsecond.mp4\n"
        for text in [
            "#EXTM3U\n" + body, // Live playlist.
            "#EXTM3U\n" + body.replacingOccurrences(of: ".mp4", with: ".ts") + "#EXT-X-ENDLIST\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n" + body + "#EXT-X-ENDLIST\n",
            "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n" + body + "#EXT-X-ENDLIST\n",
            "#EXTM3U\n" + body.replacingOccurrences(of: "#EXT-X-DISCONTINUITY\n", with: "") + "#EXT-X-ENDLIST\n"
        ] {
            let cache = try FTPlaybackCacheSession()
            defer { cache.close() }
            let requests = server!.requests
            XCTAssertNil(try FTIndependentHLS.prepare(source: source, session: cache,
                timeout: 1, interrupted: { false }, preparation: nil, loader: DurationPlaylistStub(text)))
            XCTAssertEqual(server!.requests, requests, "Unsupported playlist shape triggered MP4 probes")
        }
    }

    func testIndependentHLSZeroDurationRepeatedSeekDoesNotReplayCached() throws {
        try checkZeroDurationRepeatedSeek(cache: true)
    }

    func testIndependentHLSZeroDurationRepeatedSeekDoesNotReplayUncached() throws {
        try checkZeroDurationRepeatedSeek(cache: false)
    }

    private func checkZeroDurationRepeatedSeek(cache: Bool) throws {
        let s = try start(http("zero-duration-independent-hls.m3u8"), cache: cache, policy: .ffmpeg)
        try assertPlayback(s)
        let decoder = try XCTUnwrap(s.player.decoder)
        for target in [81.0, 76, 82, 78, 66, 104, 5] {
            let revision = try XCTUnwrap(decoder.rateDiagnosticFields["seekRevision"] as? Int)
            let frames = s.sink.frames
            var completed: Bool?
            s.player.seek(to: target) { success in
                completed = success
                if success { s.player.play() } // Same app sequence as cam0011.
            }
            try require(until(8) { completed != nil || s.failure != nil }, "Seek callback missing at \(target)")
            XCTAssertEqual(completed, true)
            pump(0.25)
            s.measurements.append(["operation": "zero-extinf-seek-play", "target": target,
                "clock": s.player.currentTime, "picture": s.sink.lastPresentationTime,
                "decoder": decoder.diagnosticSnapshot])
            XCTAssertNil(s.failure)
            XCTAssertEqual(decoder.rateDiagnosticFields["seekRevision"] as? Int, revision + 1,
                "play() added an unsolicited replay seek to zero")
            XCTAssertEqual(s.finished, 0, "Seek falsely announced the end of the recording")
            XCTAssertGreaterThanOrEqual(s.player.currentTime, target - 0.1, "Seek restarted at the beginning")
            try require(until(3) { s.sink.frames > frames && s.sink.lastPresentationTime >= target - 0.1 },
                "Seek never presented the requested part of the recording")
        }
    }

    func testMP4RetimedPacketCannotRewriteADifferentIndexedSample() throws {
        let format = FTFormatContext(contentURL: try fixture("sustained-hevc-aac.mp4"), videoFormat: .unknown)
        format.setupSync(useCache: false)
        defer { format.destroy() }
        let context = try XCTUnwrap(format.formatContext)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var collisions = 0
        for _ in 0..<2000 {
            guard av_read_frame(context, packet) >= 0, let value = packet?.pointee else { break }
            defer { av_packet_unref(packet) }
            guard Int(value.stream_index) == format.videoTrack?.index,
                  let stream = context.pointee.streams[Int(value.stream_index)],
                  let entry = avformat_index_get_entry_from_timestamp(stream, value.dts, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY),
                  entry.pointee.timestamp == value.dts, entry.pointee.pos != value.pos,
                  value.flags & AV_PKT_FLAG_KEY != 0, entry.pointee.flags & AVINDEX_KEYFRAME == 0 else { continue }
            let position = entry.pointee.pos, size = entry.pointee.size
            format.validateMP4RandomAccess(packet!)
            let after = try XCTUnwrap(avformat_index_get_entry_from_timestamp(stream, value.dts, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY))
            XCTAssertEqual(after.pointee.pos, position, "Retimed DTS identified a different MOV sample")
            XCTAssertEqual(after.pointee.size, size, "Parser replaced an unrelated indexed sample's byte range")
            XCTAssertEqual(after.pointee.flags & AVINDEX_KEYFRAME, 0)
            collisions += 1
            break
        }
        XCTAssertEqual(collisions, 1, "Fixture did not exercise its edit-list/index timestamp collision")
    }

    func testCorruptPartialMP4PacketCannotRewriteRandomAccessIndex() throws {
        let format = FTFormatContext(contentURL: try fixture("malformed-keyflags/hevc-keyframe.mp4"), videoFormat: .unknown)
        format.setupSync(useCache: false)
        defer { format.destroy() }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        try require(format.readFrame(packet) >= 0, "Missing original HEVC packet")
        let value = try XCTUnwrap(packet)
        let context = try XCTUnwrap(format.formatContext)
        let stream = try XCTUnwrap(context.pointee.streams[Int(value.pointee.stream_index)])
        let entry = try XCTUnwrap(avformat_index_get_entry_from_timestamp(stream, value.pointee.dts, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY))
        let originalSize = entry.pointee.size
        XCTAssertGreaterThan(originalSize, 512)
        // A canceled HTTP read can return a successful but short CORRUPT packet.
        // Its leading NAL still identifies an I picture; its size is not the
        // complete MP4 sample size and must never replace that index entry.
        value.pointee.size = 512
        value.pointee.flags = (value.pointee.flags & ~AV_PKT_FLAG_KEY) | AV_PKT_FLAG_CORRUPT
        format.validateMP4RandomAccess(value)
        XCTAssertEqual(entry.pointee.size, originalSize, "Partial packet poisoned the next native seek")
        XCTAssertEqual(value.pointee.flags & AV_PKT_FLAG_KEY, 0, "Corrupt input must not be promoted to a verified RAP")
    }

    func testMP4EncodedRandomAccessOverridesIncorrectContainerFlags() throws {
        continueAfterFailure = true
        for name in ["avc-keyframe.mp4", "avc-nonkeyframe.mp4", "hevc-keyframe.mp4", "hevc-nonkeyframe.mp4"] {
            let format = FTFormatContext(contentURL: try fixture("malformed-keyflags/" + name), videoFormat: .unknown)
            defer { format.destroy() }
            format.setupSync(useCache: false)
            XCTAssertNil(format.error)
            var packet = av_packet_alloc()
            defer { av_packet_free(&packet) }
            var keys: [Bool] = []
            var rows: [[String: Any]] = []
            for _ in 0..<8 {
                guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
                if Int(value.stream_index) == format.videoTrack?.index {
                    keys.append(value.flags & AV_PKT_FLAG_KEY != 0)
                    rows.append(["pts": value.pts, "dts": value.dts, "flags": value.flags, "pos": value.pos,
                        "start": format.startTime, "timebase": format.videoTimebase])
                }
                av_packet_unref(packet)
            }
            XCTAssertEqual(keys, [true, false], "Container sync flags contradicted the encoded access units: \(name)")
            XCTAssertTrue(format.seekFile(withFFTimebase: 0), "Wrong container flags made seek zero fail: \(name)")
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows), uniformTypeIdentifier: "public.json")
            attachment.name = "encoded-random-access-" + name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testBadPDTAudioFrameTimestampContract() throws {
        let format = FTFormatContext(contentURL: try http("bad-pdt/index.m3u8"), videoFormat: .m3u8)
        defer { format.destroy() }
        format.setupSync(useCache: false)
        XCTAssertNil(format.error)
        let codec = try XCTUnwrap(format.audioCodecContext)
        var packet = av_packet_alloc(), frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        var rows: [[String: Int64]] = []
        for _ in 0..<2000 {
            guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
            if Int(value.stream_index) == format.audioTrack?.index {
                XCTAssertGreaterThanOrEqual(avcodec_send_packet(codec, packet), 0)
                while avcodec_receive_frame(codec, frame) == 0 {
                    let value = frame!.pointee
                    rows.append(["bestEffort": value.best_effort_timestamp, "pts": value.pts, "dts": value.pkt_dts])
                    av_frame_unref(frame)
                }
            }
            av_packet_unref(packet)
            if rows.count >= 6 { break }
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows), uniformTypeIdentifier: "public.json")
        attachment.name = "missing-audio-timestamp-contract"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThan(rows.count, 0)
        XCTAssertNotEqual(rows.first?["pts"], FT_AV_NOPTS_VALUE)
        XCTAssertTrue(rows.contains { $0["bestEffort"] == FT_AV_NOPTS_VALUE && $0["pts"] == FT_AV_NOPTS_VALUE && $0["dts"] == FT_AV_NOPTS_VALUE }, "The fixture must contain untimestamped AAC frames after a real anchor")
    }

    func testBadPDTAudioUnknownBestEffortDoesNotFreezePlaybackClock() throws {
        let s = try start(try http("bad-pdt/index.m3u8"), cache: nil, policy: .ffmpeg)
        try assertPlayback(s, timeout: 4)
        XCTAssertGreaterThanOrEqual(s.player.currentTime, 0)
        XCTAssertLessThan(s.player.currentTime, s.player.duration)
    }

    func testIndependentHLSDefaultCacheClockNeverRewindsAcrossShortDeclaredPeriods() throws {
        // Each public fixture file is 30s, while EXTINF assigns only 16s to it.
        // Decode the file normally, but its extra PCM must not overlap the next
        // period and move the audio master clock backwards. Leave useCache unset.
        let s = try start(try http("independent-hls.m3u8"), cache: nil, policy: .ffmpeg)
        try assertPlayback(s)
        XCTAssertFalse(s.player.useCache)
        for rate in [Float(4), 16] {
            s.player.pause(); s.player.rate = rate
            var completed: Bool?
            s.player.seek(to: 14) { completed = $0 }
            try require(until(5) { completed != nil }, "Period-overlap seek did not complete")
            XCTAssertEqual(completed, true)
            s.player.play()
            try require(until(5) { s.player.currentTime >= 14 && !(s.player.decoder?.buffering ?? true) }, "Period-overlap playback did not start")
            let began = ProcessInfo.processInfo.systemUptime
            var previous = s.player.currentTime, maximumBackwardStep = 0.0
            while s.player.currentTime < 45 && ProcessInfo.processInfo.systemUptime - began < 12 {
                pump(0.01)
                let clock = s.player.currentTime
                maximumBackwardStep = max(maximumBackwardStep, previous - clock)
                previous = clock
            }
            s.measurements.append(["operation": "independent-period-overlap", "requestedRate": rate,
                "maximumBackwardStep": maximumBackwardStep, "clock": s.player.currentTime])
            XCTAssertLessThanOrEqual(maximumBackwardStep, 0.05, "PCM beyond EXTINF overlapped the next file timeline")
            XCTAssertGreaterThanOrEqual(s.player.currentTime, 45)
            XCTAssertEqual(s.player.duration, 512, accuracy: 0.01)
            XCTAssertEqual(s.finished, 0)
            XCTAssertTrue(s.player.cachedTimeRanges.isEmpty)
        }
    }

    func testSoftwareHEVCParallelDecodePreservesPresentationOrder() throws {
        let format = FTFormatContext(contentURL: try http("hls-hevc/index.m3u8"), videoFormat: .m3u8)
        defer { format.destroy() }
        format.setupSync(useCache: false)
        XCTAssertNil(format.error)
        let codec = try XCTUnwrap(format.videoCodecContext)
        if ProcessInfo.processInfo.activeProcessorCount > 1 {
            XCTAssertNotEqual(codec.pointee.active_thread_type, 0, "Software video decoder remained serial on a multicore CPU")
        }
        var packet = av_packet_alloc(), frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        var positions: [Int64] = []
        for _ in 0..<500 {
            guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
            if Int(value.stream_index) == format.videoTrack?.index {
                XCTAssertGreaterThanOrEqual(avcodec_send_packet(codec, packet), 0)
                while avcodec_receive_frame(codec, frame) == 0 {
                    positions.append(frame!.pointee.best_effort_timestamp)
                    av_frame_unref(frame)
                }
            }
            av_packet_unref(packet)
            if positions.count >= 24 { break }
        }
        XCTAssertGreaterThanOrEqual(positions.count, 24)
        XCTAssertEqual(positions, positions.sorted(), "Parallel decoding changed presentation ordering")
        let first = try XCTUnwrap(positions.first), last = try XCTUnwrap(positions.last)
        XCTAssertGreaterThan(last - first, 0)
    }

    func testHLSByteBudgetNeedsMultiplePlaybackWindowsForCachedInterval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hls-byte-windows-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { server?.stop(); try? FileManager.default.removeItem(at: root) }
        let size = 65536
        for index in 0..<8 { try Data(repeating: 0x47, count: size).write(to: root.appendingPathComponent("\(index).ts")) }
        server = try FixtureHTTPServer(root: root)
        let cache = try FTPlaybackCacheSession()
        defer { cache.close() }
        let sizes = Array(repeating: ["total": size, "cached": 0], count: 8)
        try JSONSerialization.data(withJSONObject: sizes).write(to: cache.directory.appendingPathComponent("hls-resources.json"))
        let manifest = FTIndependentHLS.Manifest(source: server!.url("index.m3u8"),
            segments: (0..<8).map { FTIndependentHLS.Segment(url: server!.url("\($0).ts"), duration: 10) })
        let hls = try FTIndependentHLS(manifest: manifest, session: cache, cache: true, timeout: 5)
        defer { hls.close() }
        let budget = Int64(size * 3)
        hls.configureLoadControl(.init(targetBufferBytes: budget), video: true, audio: false)
        hls.finishOpening()
        try require(until(5) { (hls.ranges.first?.end ?? 0) >= 30 }, "Initial byte-limited window did not fill")
        pump(0.1)
        XCTAssertEqual(hls.ranges.first?.end, 30, "Byte cap must remain active despite the 50s time target")
        hls.setPlaybackPosition(32)
        try require(until(5) { (hls.ranges.first?.end ?? 0) >= 60 }, "Second byte-limited window did not fill")
        pump(0.1)
        XCTAssertEqual(hls.ranges.first?.end, 60, "A fixed prime at 32s is insufficient for a 64s test interval")
        hls.setPlaybackPosition(59.9)
        try require(until(5) { (hls.ranges.first?.end ?? 0) >= 70 }, "Advancing the real cache prefix did not complete the interval")
        XCTAssertEqual(hls.diagnostics["loadTargetBytes"], budget)
    }

    func testUnseenHLSDistantSeekBoundsReferencePrerollBySegment() throws {
        let format = FTFormatContext(contentURL: try http("hls-60fps/index.m3u8"), videoFormat: .m3u8)
        defer { format.destroy() }
        format.setupSync(useCache: true)
        XCTAssertNil(format.error)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        for _ in 0..<100 {
            guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
            let video = Int(value.stream_index) == format.videoTrack?.index
            av_packet_unref(packet)
            if video { break }
        }
        XCTAssertTrue(format.seekFile(withFFTimebase: 25))
        var firstKey: Double?
        for _ in 0..<500 {
            guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
            if Int(value.stream_index) == format.videoTrack?.index, value.flags & AV_PKT_FLAG_KEY != 0 {
                firstKey = Double(value.pts) * format.videoTimebase - format.startTime
            }
            av_packet_unref(packet)
            if firstKey != nil { break }
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstKey), 10, "Unseen seek reused the initial GOP and decoded the entire VOD as preroll")
        XCTAssertLessThanOrEqual(try XCTUnwrap(firstKey), 25)
    }

    func testSparseAudioPeriodsKeepRequestedTimelineRate() throws {
        let s = try start(try http("pdt-repeated-ts/index.m3u8"), cache: true)
        try assertPlayback(s)
        try require(until(10) { s.player.downloadProgress == 1 }, "Sparse-audio fixture cache incomplete")
        server!.setNetworkMode(.disconnect, dropExistingConnections: true)
        for (rate, target, window) in [(Float(1), 3.5, 2.0), (Float(16), 0.0, 40.0)] {
            s.player.pause(); s.player.rate = rate
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(5) { completed != nil }, "Sparse-audio seek callback missing")
            XCTAssertEqual(completed, true)
            s.player.play()
            try require(until(5) { s.sink.lastPresentationTime >= target - 0.1 && !(s.player.decoder?.buffering ?? true) }, "Sparse-audio seek not ready")
            let origin = s.player.currentTime, began = ProcessInfo.processInfo.systemUptime
            var previous = origin, maximumBackwardStep = 0.0
            while s.player.currentTime < origin + window && ProcessInfo.processInfo.systemUptime - began < 8 {
                pump(0.02)
                maximumBackwardStep = max(maximumBackwardStep, previous - s.player.currentTime)
                previous = s.player.currentTime
            }
            XCTAssertGreaterThanOrEqual(s.player.currentTime, origin + window, "Sparse audio stopped the clock")
            let actual = (s.player.currentTime - origin) / (ProcessInfo.processInfo.systemUptime - began)
            s.measurements.append(["operation": "sparse-audio-clock", "requestedRate": rate, "measuredRate": actual,
                "maximumBackwardStep": maximumBackwardStep])
            XCTAssertLessThan(maximumBackwardStep, 0.5, "Gap interpolation changed the public clock's latency origin")
            XCTAssertEqual(actual, Double(rate), accuracy: Double(rate) * 0.15, "Clock skipped the missing audio interval")
            XCTAssertNil(s.failure)
        }
    }


    func testHardwareH264ParameterChangesKeepCached16xAdvancing() throws {
        let s = try start(try http("dai-periods/index.m3u8"), cache: true, policy: .hardware)
        try assertPlayback(s)
        try require(until(10) { s.player.downloadProgress == 1 }, "Parameter-change fixture cache incomplete")
        server!.setNetworkMode(.disconnect, dropExistingConnections: true)
        let initialSize = s.sink.dimensions
        var changedSize = false, gap = 0.0, maximumGap = 0.0
        var lastPTS = s.sink.lastPresentationTime, lastWall = ProcessInfo.processInfo.systemUptime
        let began = lastWall
        s.player.rate = 16
        while s.player.currentTime < 28 && s.failure == nil && ProcessInfo.processInfo.systemUptime - began < 8 {
            pump(0.02)
            let now = ProcessInfo.processInfo.systemUptime
            if s.sink.lastPresentationTime > lastPTS { lastPTS = s.sink.lastPresentationTime; gap = 0 }
            else { gap += now - lastWall }
            maximumGap = max(maximumGap, gap); lastWall = now
            if s.sink.dimensions != initialSize { changedSize = true }
        }
        s.measurements.append(["operation": "hardware-parameter-change-16x", "maximumImageGap": maximumGap,
            "lastPTS": lastPTS, "clock": s.player.currentTime, "changedSize": changedSize])
        XCTAssertNil(s.failure)
        XCTAssertTrue(changedSize, "Output did not adopt the new SPS dimensions")
        XCTAssertGreaterThan(lastPTS, 26)
        XCTAssertLessThan(maximumGap, 0.35)
        XCTAssertEqual(s.player.videoDecodingStatistics.ffmpegFrames, 0)
        XCTAssertGreaterThan(s.player.videoDecodingStatistics.hardwareFrames, 0)
    }

    func testEncryptedHLSDiscontinuityPeriodsKeepPlaylistTimelineOffline() throws {
        try checkEncryptedPeriods("index.m3u8")
    }

    func testMasterEncryptedHLSDiscontinuityPeriodsKeepPlaylistTimelineOffline() throws {
        try checkEncryptedPeriods("master.m3u8")
    }

    private func checkEncryptedPeriods(_ name: String) throws {
        let s = try start(try http("dai-periods/" + name), cache: true)
        try assertPlayback(s)
        try require(until(10) { s.player.downloadProgress == 1 }, "Discontinuity fixture did not finish caching")
        server!.setNetworkMode(.disconnect, dropExistingConnections: true)
        for target in [15.0, 25, 0, 15] {
            s.player.pause()
            let frames = s.sink.frames
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(5) { completed != nil }, "Period seek callback missing")
            XCTAssertEqual(completed, true)
            s.player.play()
            let rendered = until(5) { s.sink.frames > frames && abs(s.sink.lastPresentationTime - target) < 0.5 }
            s.measurements.append(["operation": "encrypted-period-seek", "target": target, "PTS": s.sink.lastPresentationTime])
            try require(rendered, "Encrypted/plain discontinuity changed the public timeline at \(target)")
            XCTAssertNil(s.failure)
        }
    }

    func testCustomIVCacheRemainsSeekableWithoutNetwork() throws {
        let s = try start(try http("custom-iv/index.m3u8"), cache: true)
        try assertPlayback(s)
        try require(until(10) { s.player.downloadProgress == 1 }, "Custom IV media/key did not finish caching")
        XCTAssertEqual(s.player.decoder?.cacheDiagnostics["hlsKeyCachedBytes"], 16)
        server!.setNetworkMode(.disconnect, dropExistingConnections: true)
        for target in [10.0, 0, 18, 0] {
            s.player.pause()
            let frames = s.sink.frames
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(5) { completed != nil }, "Offline Custom IV seek callback missing")
            XCTAssertEqual(completed, true)
            s.player.play()
            try require(until(5) { s.sink.frames > frames && abs(s.sink.lastPresentationTime - target) < 0.5 }, "Cached Custom IV seek failed at \(target)")
            XCTAssertNil(s.failure)
        }
    }

    func testRepeatedPublicTSSeeksAcrossSparseAudioPeriods() throws {
        let url = try http("pdt-repeated-ts/index.m3u8")
        let format = FTFormatContext(contentURL: url, videoFormat: .m3u8)
        format.setupSync(useCache: true)
        XCTAssertNil(format.error)
        var packet = av_packet_alloc()
        var rows: [[String: Any]] = []
        for target in [-1.0, 0, 9, 21, 41.242] {
            if target >= 0 { XCTAssertTrue(format.seekFile(withFFTimebase: target)) }
            var count = 0
            for _ in 0..<100 {
                guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
                rows.append(["target": target, "stream": value.stream_index,
                    "PTS": Double(value.pts) * (Int(value.stream_index) == format.videoTrack?.index ? format.videoTimebase : format.audioTimebase) - format.startTime,
                    "key": value.flags & AV_PKT_FLAG_KEY])
                av_packet_unref(packet); count += 1
                if count == 6 { break }
            }
        }
        let a = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows), uniformTypeIdentifier: "public.json")
        a.name = "public-period-packets"; a.lifetime = .keepAlways; add(a)
        av_packet_free(&packet); format.destroy()
        let s = try start(url, cache: true)
        try assertPlayback(s)
        let first = try XCTUnwrap(s.sink.firstPresentationTime)
        for target in [0.0, 9, 21, 41.242, 0] {
            s.player.pause()
            let frames = s.sink.frames
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(5) { completed != nil }, "Repeated TS seek callback missing")
            XCTAssertEqual(completed, true)
            s.player.play()
            let rendered = until(5) { s.sink.frames > frames && abs(s.sink.lastPresentationTime - max(first, target)) < 0.5 }
            s.measurements.append(["operation": "repeated-ts-seek", "target": target, "PTS": s.sink.lastPresentationTime, "first": first])
            try require(rendered, "Repeated TS seek failed at \(target)")
            s.player.pause()
            XCTAssertEqual(s.player.currentTime, target, accuracy: 0.6, "Audio EOF finished the item before the video tail")
        }
    }

    func testHLSVideoPTSOutliersDoNotPoisonCachedSeek() throws {
        let s = try start(try http("av-pts-outliers/index.m3u8"), cache: true)
        try assertPlayback(s)
        let first = try XCTUnwrap(s.sink.firstPresentationTime)
        // Source video ends at 20.359343s; its audio continues to 30.686s.
        for (target, picture) in [(15.343, 15.343), (0.0, first), (29.5, 20.359343), (9.0, 9.0)] {
            let frames = s.sink.frames
            s.player.pause()
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(5) { completed != nil || s.failure != nil }, "PTS outlier seek callback missing")
            XCTAssertEqual(completed, true)
            s.player.play()
            let expected = max(first, picture)
            let rendered = until(5) { s.sink.frames > frames && abs(s.sink.lastPresentationTime - expected) < 0.5 || s.failure != nil }
            s.measurements.append(["operation": "pts-outlier-seek", "target": target,
                "expected": expected, "actualPTS": s.sink.lastPresentationTime])
            try require(rendered, "Isolated outlier PTS poisoned a seek with valid DTS and video at the target")
            XCTAssertNil(s.failure)
        }
    }

    func testEncryptedHLSDTSOffsetSeekZeroKeepsInitialPictureOffline() throws {
        let s = try start(try http("dai-initial/index.m3u8"), cache: true)
        try assertPlayback(s)
        let first = try XCTUnwrap(s.sink.firstPresentationTime)
        for (iteration, target) in [9.0, 0, 9, 0].enumerated() {
            if iteration == 2 {
                try require(until(5) { s.player.downloadProgress == 1 }, "DAI fixture did not finish caching")
                server!.setNetworkMode(.disconnect, dropExistingConnections: true)
            }
            let frames = s.sink.frames
            s.player.pause()
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(5) { completed != nil || s.failure != nil }, "DAI fixture seek callback missing")
            XCTAssertEqual(completed, true)
            s.player.play()
            let expected = max(target, first)
            let rendered = until(5) { s.sink.frames > frames && abs(s.sink.lastPresentationTime - expected) < 0.5 || s.failure != nil }
            s.measurements.append(["operation": "dai-seek", "target": target, "expected": expected,
                "actualPTS": s.sink.lastPresentationTime, "decoder": s.player.decoder?.diagnosticSnapshot ?? "closed"])
            try require(rendered, "HLS zero seek lost the original initial picture")
            XCTAssertNil(s.failure)
        }
    }

    func testLeadingDiscontinuityRepeatingTSKeepsPeriodTimeline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leading-ts-periods-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { server?.stop(); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture("hls-ts/segment0.ts"), to: root.appendingPathComponent("period.ts"))
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n"
        for _ in 0..<4 { text += "#EXT-X-DISCONTINUITY\n#EXTINF:2.416667,\nperiod.ts\n" }
        text += "#EXT-X-ENDLIST\n"
        try text.write(to: root.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
        server = try FixtureHTTPServer(root: root)
        let format = FTFormatContext(contentURL: server!.url("index.m3u8"), videoFormat: .m3u8)
        format.setupSync(useCache: true)
        XCTAssertNil(format.error)
        var packet = av_packet_alloc()
        var packets: [[String: Any]] = []
        for target in [0.0, 5.2] {
            XCTAssertTrue(format.seekFile(withFFTimebase: target))
            for _ in 0..<100 {
                guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
                if Int(value.stream_index) == format.videoTrack?.index {
                    packets.append(["target": target, "PTS": Double(value.pts) * format.videoTimebase - format.startTime,
                        "DTS": Double(value.dts) * format.videoTimebase - format.startTime, "key": value.flags & AV_PKT_FLAG_KEY])
                }
                av_packet_unref(packet)
                if packets.filter({ ($0["target"] as? Double) == target }).count >= 4 { break }
            }
        }
        let a = XCTAttachment(data: try JSONSerialization.data(withJSONObject: packets), uniformTypeIdentifier: "public.json")
        a.name = "leading-period-packets"; a.lifetime = .keepAlways; add(a)
        av_packet_free(&packet); format.destroy()
        let s = try start(server!.url("index.m3u8"), cache: true)
        try assertPlayback(s)
        for target in [5.2, 0.0, 8.0] {
            let frames = s.sink.frames
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(5) { completed != nil || s.failure != nil }, "Period seek callback missing")
            XCTAssertEqual(completed, true)
            try require(until(5) { s.sink.frames > frames && abs(s.sink.lastPresentationTime - target) < 0.4 || s.failure != nil }, "Discontinuity period returned the original file PTS at \(target)")
            XCTAssertNil(s.failure)
        }
    }

    func testHLSPrefetchDoesNotDependOnSizeProbeSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hls-unprobed-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { server?.stop(); try? FileManager.default.removeItem(at: root) }
        let size = 12 * 1024 * 1024
        try Data(repeating: 0x47, count: size).write(to: root.appendingPathComponent("faststart.mp4"))
        server = try FixtureHTTPServer(root: root)
        let cache = try FTPlaybackCacheSession()
        defer { cache.close() }
        let manifest = FTIndependentHLS.Manifest(source: server!.url("index.m3u8"),
            segments: [FTIndependentHLS.Segment(url: server!.url("no-size-probe.mp4"), duration: 12)])
        let hls = try FTIndependentHLS(manifest: manifest, session: cache, cache: true, timeout: 5)
        defer { hls.close() }
        hls.finishOpening()
        try require(until(5) { hls.ranges.first?.end == 12 }, "Failed metadata probe prevented actual segment GET: \(hls.diagnostics)")
        XCTAssertEqual(hls.diagnostics["hlsStoredBytes"], Int64(size))
    }

    func testHLSPrefetchCorrectsRestoredResourceBudgetFromGET() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hls-restored-size-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { server?.stop(); try? FileManager.default.removeItem(at: root) }
        let size = 12 * 1024 * 1024
        try Data(repeating: 0x47, count: size).write(to: root.appendingPathComponent("large.mp4"))
        server = try FixtureHTTPServer(root: root)
        let cache = try FTPlaybackCacheSession()
        defer { cache.close() }
        try Data("[{\"total\":32768,\"cached\":0}]".utf8).write(to: cache.directory.appendingPathComponent("hls-resources.json"))
        let manifest = FTIndependentHLS.Manifest(source: server!.url("index.m3u8"),
            segments: [FTIndependentHLS.Segment(url: server!.url("large.mp4"), duration: 12)])
        let hls = try FTIndependentHLS(manifest: manifest, session: cache, cache: true, timeout: 5)
        defer { hls.close() }
        hls.finishOpening()
        try require(until(5) { hls.ranges.first?.end == 12 }, "Authoritative GET size did not update the HLS worker budget: \(hls.diagnostics)")
        XCTAssertEqual(hls.diagnostics["hlsStoredBytes"], Int64(size))
    }

    func testHLSResourceReadAheadSurvivesPlaybackRateUpdates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hls-resource-rate-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { server?.stop(); try? FileManager.default.removeItem(at: root) }
        let size = 20 * 1024 * 1024
        try Data(repeating: 0x47, count: size).write(to: root.appendingPathComponent("large.mp4"))
        server = try FixtureHTTPServer(root: root)
        let cache = try FTPlaybackCacheSession()
        defer { cache.close() }
        let worker = try cache.makeWorker(videoURL: server!.url("large.mp4"), knownFileSize: Int64(size))
        worker.setResourceReadAheadBytes(Int64(size))
        cache.setPlaybackRate(2)
        XCTAssertEqual(worker.diagnosticSnapshot["readAheadTargetBytes"], Int64(size), "Session rate updates must preserve the HLS resource's download budget")
        try require(until(5) { worker.cachedFraction == 1 }, "Paused HLS resource stopped downloading before EOF")
    }

    func testShortAVITailDemuxRetainsVideoPackets() throws {
        let format = FTFormatContext(contentURL: try fixture("short-mpeg4-mp3.avi"), videoFormat: .unknown)
        defer { format.destroy() }
        format.setupSync(useCache: false)
        XCTAssertNil(format.error)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var rows: [[String: Any]] = []
        for target in [-1.0, 0.0, 0.684, 1.0944] {
            if target >= 0 { XCTAssertTrue(format.seekFile(withFFTimebase: target)) }
            var packets: [[String: Any]] = []
            for _ in 0..<512 {
                guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
                packets.append(["stream": value.stream_index, "pts": value.pts, "dts": value.dts,
                    "duration": value.duration, "flags": value.flags])
                av_packet_unref(packet)
            }
            rows.append(["target": target, "videoTimebase": format.videoTimebase,
                "audioTimebase": format.audioTimebase, "packets": packets])
            XCTAssertTrue(packets.contains { ($0["stream"] as? Int32) == Int32(format.videoTrack!.index) }, "AVI seek returned no video packets at \(target)")
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows), uniformTypeIdentifier: "public.json")
        attachment.name = "avi-tail-packets"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testRoundedHLSDurationsRetainKeyframeForUnseenSeek() throws { try checkRoundedUnseenSeek(cache: true, master: false) }
    func testUncachedRoundedHLSMasterRetainsKeyframeForUnseenSeek() throws { try checkRoundedUnseenSeek(cache: false, master: true) }
    private func checkRoundedUnseenSeek(cache: Bool, master: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rounded-hls-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { server?.stop(); try? FileManager.default.removeItem(at: root) }
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<3 {
            let name = "segment-\(index).ts"
            try FileManager.default.copyItem(at: fixture("hls-60fps/\(name)"), to: root.appendingPathComponent(name))
            text += "#EXTINF:9,\n\(name)\n" // Packets span 10s per segment.
        }
        try (text + "#EXT-X-ENDLIST\n").write(to: root.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
        try "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000\nindex.m3u8\n".write(to: root.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
        server = try FixtureHTTPServer(root: root)
        let format = FTFormatContext(contentURL: server!.url(master ? "master.m3u8" : "index.m3u8"), videoFormat: .m3u8)
        format.loadControlConfiguration = FTPlayerLoadControlConfiguration(minimumBufferDuration: 5, maximumBufferDuration: 5)
        defer { format.destroy() }
        format.setupSync(useCache: cache)
        XCTAssertNil(format.error)
        if !cache { XCTAssertEqual(format.cacheDiagnostics["hlsCachedBytes"], 0) }
        let video = try XCTUnwrap(format.videoTrack)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        for _ in 0..<128 {
            guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
            let first = Int(value.stream_index) == video.index
            av_packet_unref(packet)
            if first { break }
        }
        XCTAssertTrue(format.seekFile(withFFTimebase: 18.5))
        var key: Double?
        for _ in 0..<2048 {
            guard format.readFrame(packet) >= 0, let value = packet?.pointee else { break }
            if Int(value.stream_index) == video.index, value.flags & AV_PKT_FLAG_KEY != 0 {
                key = Double(value.pts) * format.videoTimebase - format.startTime
            }
            av_packet_unref(packet)
            if key != nil { break }
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(key), 18.6, "Playlist durations selected a segment after the requested PTS")
    }

    func testHLSCompletedTransfersKeepCacheReadAndNetworkCounters() throws {
        let upstream = try http("faststart.mp4")
        let bytes = try Data(contentsOf: fixture("faststart.mp4"))
        let cache = try FTPlaybackCacheSession()
        defer { cache.close() }
        let manifest = FTIndependentHLS.Manifest(source: server!.url("counter.m3u8"),
            segments: [FTIndependentHLS.Segment(url: upstream, duration: 10)])
        let hls = try FTIndependentHLS(manifest: manifest, session: cache, cache: true, timeout: 3)
        defer { hls.close() }
        hls.finishOpening()
        try require(until(5) { hls.fraction == 1 }, "HLS prefetch did not persist the resource")
        pump(0.2) // Allow the completed prefetch worker to retire.
        let downloaded = hls.diagnostics["networkBytes"] ?? 0
        XCTAssertGreaterThan(downloaded, 0, "Retiring a completed prefetch must retain its transfer counters")
        let text = try String(contentsOf: hls.file, encoding: .utf8)
        let line = try XCTUnwrap(text.components(separatedBy: .newlines).first { $0.hasPrefix("file '") })
        let proxy = try XCTUnwrap(URL(string: String(line.dropFirst(6).dropLast())))
        server!.setNetworkMode(.disconnect, dropExistingConnections: true)
        let network = URLSession(configuration: .ephemeral)
        defer { network.invalidateAndCancel() }
        for iteration in 1...2 {
            let received = expectation(description: "Cached proxy body \(iteration)")
            var body: Data?, failure: Error?
            network.dataTask(with: proxy) { data, _, error in
                DispatchQueue.main.async { body = data; failure = error; received.fulfill() }
            }.resume()
            wait(for: [received], timeout: 5)
            XCTAssertNil(failure); XCTAssertEqual(body, bytes)
            pump(0.1) // The proxy closes its connection and worker after EOF.
            XCTAssertGreaterThanOrEqual(hls.diagnostics["diskReadBytes"] ?? 0, Int64(bytes.count * iteration))
            XCTAssertEqual(hls.diagnostics["networkBytes"], downloaded, "Offline replay must retain the prior network count without downloading again")
        }
        let beforeClose = hls.diagnostics
        hls.close()
        for key in ["diskReadBytes", "networkBytes", "rangeRequests"] { XCTAssertEqual(hls.diagnostics[key], beforeClose[key]) }
    }

    private func checkFragmentedHLSCache(_ directory: String, playlist: String = "index.m3u8") throws {
        let session = try start(http("\(directory)/\(playlist)"), cache: true, policy: .ffmpeg)
        try assertPlayback(session)
        session.player.pause()
        try require(until(8) { session.player.downloadProgress == 1 || session.failure != nil }, "fMP4 HLS did not cache init and media segments")
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.player.downloadProgress, 1)
        try require(until(2) { session.downloadProgressEvents.contains { $0 > 0 } }, "fMP4 cache progress was not delivered to the UI delegate")
        let duration = session.player.duration
        if directory == "hls-master-audio" {
            XCTAssertEqual(session.player.decoder?.cacheDiagnostics["hlsTracks"], 2)
            XCTAssertEqual(session.player.mediaInfo?.audioCodec, "aac")
            XCTAssertEqual(session.player.mediaInfo?.audioTrackCount, 1)
            XCTAssertGreaterThan(session.player.decoder?.cacheDiagnostics["hlsAudioCachedBytes"] ?? 0, 0)
            XCTAssertFalse(server!.requests.contains { $0.contains("unused-") })
        }
        let ranges = session.player.cachedTimeRanges
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.start ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(ranges.first?.end ?? -1, duration, accuracy: 0.001)
        let cacheDirectory = try XCTUnwrap(session.player.cacheSession?.directory)
        let cachedFiles = try FileManager.default.contentsOfDirectory(at: cacheDirectory.appendingPathComponent("videos"), includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertTrue(try cachedFiles.contains {
            guard $0.pathExtension == "bin" else { return false }
            return (try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0
        }, "No media bytes persisted on disk")
        let requests = server!.requests
        server!.setNetworkMode(.disconnect, dropExistingConnections: true)
        for target in [duration * 0.7, 0.05, duration - 0.6] {
            let frames = session.sink.frames
            var completed: Bool?
            session.player.seek(to: target) { completed = $0 }
            try require(until(8) { completed != nil || session.failure != nil }, "Offline fMP4 seek did not complete")
            XCTAssertEqual(completed, true)
            XCTAssertEqual(session.player.currentTime, target, accuracy: 0.15)
            session.player.play()
            try require(until(8) { session.sink.frames > frames && abs(session.sink.lastPresentationTime-target) <= 0.2 || session.failure != nil }, "Offline seek did not output a frame at the requested time")
            XCTAssertEqual(session.sink.lastPresentationTime, target, accuracy: 0.2)
            session.player.pause()
        }
        session.player.stop()
        session.ready = false
        let frames = session.sink.frames
        session.player.play()
        try require(until(8) { session.ready && session.sink.frames > frames + 3 || session.failure != nil }, "Offline fMP4 Stop/Play did not render")
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.player.cacheSession?.directory, cacheDirectory)
        XCTAssertEqual(session.player.downloadProgress, 1)
        XCTAssertEqual(server!.requests, requests, "Cached init, segments or playlist were requested upstream while offline")
        session.measurements.append(["operation": "fragmented-hls-offline-cache", "fraction": session.player.downloadProgress,
            "ranges": ranges.map { ["start": $0.start, "end": $0.end] }, "requests": requests,
            "cache": session.player.decoder?.cacheDiagnostics ?? [:]])
    }
    func testFragmentedHLSH264CachesInitSegmentsAndReplaysOffline() throws { try checkFragmentedHLSCache("hls-fmp4") }
    func testFragmentedHLSHEVCCachesInitSegmentsAndReplaysOffline() throws { try checkFragmentedHLSCache("hls-hevc") }
    func testFragmentedHLSMasterCachesAndReplaysOffline() throws { try checkFragmentedHLSCache("hls-fmp4", playlist: "master.m3u8") }
    func testFragmentedHLSByteRangesCacheAndReplayOffline() throws { try checkFragmentedHLSCache("hls-ranged") }
    func testFragmentedHLSMasterWithSeparateAudioCachesAndReplaysOffline() throws { try checkFragmentedHLSCache("hls-master-audio", playlist: "master.m3u8") }
    func testFragmentedHLSMasterWithoutExtensionCachesChildPlaylists() throws { try checkFragmentedHLSCache("hls-master-audio", playlist: "stream") }
    func testFragmentedHLSMasterRedirectKeepsRelativeAudioAndVideoURLs() throws { try checkFragmentedHLSCache("hls-master-audio", playlist: "redirect") }
    func testHLSTSMediaCachesAndReplaysOffline() throws { try checkFragmentedHLSCache("hls-ts") }
    func testHLSTSMasterCachesAndReplaysOffline() throws { try checkFragmentedHLSCache("hls-ts", playlist: "master.m3u8") }
    func testHLSAES128CachesKeyAndReplaysOffline() throws { try checkFragmentedHLSCache("hls-aes128") }
    func testHLSAES128MasterCachesKeyAndReplaysOffline() throws { try checkFragmentedHLSCache("hls-aes128", playlist: "master.m3u8") }
    func testHLSRotatingKeysImplicitIVAndPlaintextReplayOffline() throws { try checkFragmentedHLSCache("hls-rotating-aes") }
    func testHLSTSByteRangesExplicitAndImplicitReplayOffline() throws { try checkFragmentedHLSCache("hls-ranged-ts") }
    func testHLSChangingInitMapsReplayOffline() throws { try checkFragmentedHLSCache("hls-changing-map") }
    func testHLSOpaqueTSResourceURLsCacheOffline() throws { try checkFragmentedHLSCache("hls-opaque-ts") }
    func testHLSOpaqueFMP4ResourceURLsCacheOffline() throws { try checkFragmentedHLSCache("hls-opaque-fmp4") }
    func testHLSIndependentOpaqueResourceURLsCacheOffline() throws { try checkFragmentedHLSCache("hls-independent-opaque") }

    func testCachedMasterSeparateAudioSeekKeepsVideoKeyframe() throws {
        let format = FTFormatContext(contentURL: try http("hls-master-audio/master.m3u8"), videoFormat: .m3u8)
        defer { format.destroy() }
        format.setupSync(useCache: true)
        XCTAssertNil(format.error)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var initialPackets: [[String: Int64]] = []
        var observed: [[String: Int64]] = []
        for _ in 0..<512 {
            let result = format.readFrame(packet)
            if observed.count < 8 || result < 0 {
                observed.append(["result": Int64(result), "stream": Int64(packet?.pointee.stream_index ?? -1), "pts": packet?.pointee.pts ?? -1, "dts": packet?.pointee.dts ?? -1])
            }
            guard result >= 0, let value = packet?.pointee else { break }
            if value.stream_index == Int32(format.videoTrack!.index) {
                initialPackets.append(["pts": value.pts, "dts": value.dts, "flags": Int64(value.flags)])
                av_packet_unref(packet)
                if initialPackets.count == 3 { break }
            } else { av_packet_unref(packet) }
        }
        let before = XCTAttachment(data: try JSONSerialization.data(withJSONObject: initialPackets), uniformTypeIdentifier: "public.json")
        before.name = "master-initial-video-packets"; before.lifetime = .keepAlways; add(before)
        let all = XCTAttachment(data: try JSONSerialization.data(withJSONObject: observed), uniformTypeIdentifier: "public.json")
        all.name = "master-initial-packets"; all.lifetime = .keepAlways; add(all)
        for target in [7.07, 0.05, 0] {
            XCTAssertTrue(format.seekFile(withFFTimebase: target))
            for _ in 0..<512 {
                let result = format.readFrame(packet)
                XCTAssertGreaterThanOrEqual(result, 0)
                if packet?.pointee.stream_index == Int32(format.videoTrack!.index) { break }
                av_packet_unref(packet)
            }
            let value = try XCTUnwrap(packet?.pointee)
            let attachment = XCTAttachment(string: "target=\(target) videoIndex=\(format.videoTrack!.index) start=\(format.startTime) pts=\(value.pts) dts=\(value.dts) flags=\(value.flags) tb=\(format.videoTimebase)")
            attachment.name = "master-seek-first-video-packet"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(value.flags & AV_PKT_FLAG_KEY, AV_PKT_FLAG_KEY)
            XCTAssertLessThan(Double(value.pts) * format.videoTimebase - format.startTime, 1)
            av_packet_unref(packet)
        }
    }


    func testHLSByteRangesOnSameURLHaveIndependentCacheViews() throws {
        server = try FixtureHTTPServer(root: fixture(""))
        let session = try FTPlaybackCacheSession()
        defer { session.close() }
        let source = try Data(contentsOf: fixture("faststart.mp4"))
        for path in ["faststart.mp4", "no-range.mp4"] {
            for range in [CachedRange(start: 50, end: 99), CachedRange(start: 200, end: 249)] {
                let worker = try session.makeWorker(videoURL: server!.url(path), knownFileSize: 50, resourceRange: range)
                var bytes: Data?, finished = false
                DispatchQueue.global().async {
                    let data = worker.read(offset: 0, length: 50)
                    DispatchQueue.main.async { bytes = data; finished = true }
                }
                try require(until(5) { finished }, "HLS range view did not complete")
                XCTAssertEqual(bytes, source.subdata(in: Int(range.start)..<Int(range.end+1)))
                XCTAssertEqual(worker.knownFileSize, 50)
                worker.close()
            }
        }
        XCTAssertTrue(server!.rangeRequests.contains("50-99"))
        XCTAssertTrue(server!.rangeRequests.contains("200-249"))
    }
    func testHLSByteRangeOutsideHTTPResourceFailsWithoutCachingBytes() throws {
        let data = try Data(contentsOf: fixture("faststart.mp4"))
        let range = CachedRange(start: Int64(data.count)-20, end: Int64(data.count)+20)
        let session = try FTPlaybackCacheSession()
        defer { session.close() }
        let worker = try session.makeWorker(videoURL: http("faststart.mp4"), resourceRange: range)
        var finished = false, bytes: Data?
        DispatchQueue.global().async {
            let value = worker.read(offset: 0, length: 41)
            DispatchQueue.main.async { bytes = value; finished = true }
        }
        try require(until(5) { finished }, "Invalid HLS range did not fail within budget")
        XCTAssertNil(bytes)
        XCTAssertEqual(worker.failure?.code, URLError.badServerResponse.rawValue)
        XCTAssertEqual(worker.cachedFraction, 0)
    }
    func testHLSMasterTSReportsActualMediaCache() throws {
        let session = try start(http("hls-ts/master.m3u8"), cache: true, policy: .ffmpeg)
        try assertPlayback(session)
        try require(until(5) { session.player.downloadProgress > 0 && !session.player.cachedTimeRanges.isEmpty }, "TS master must report actual segment bytes")
    }


    func testIndependentHLSRepeatedResourceReusesActivePrefetch() throws {
        server = try FixtureHTTPServer(root: fixture(""))
        server!.stallMediaBodies()
        let cache = try FTPlaybackCacheSession()
        defer { cache.close() }
        let manifest = FTIndependentHLS.Manifest(source: server!.url("repeated.m3u8"), segments: (0..<6).map { _ in
            FTIndependentHLS.Segment(url: server!.url("faststart.mp4"), duration: 30)
        })
        let hls = try FTIndependentHLS(manifest: manifest, session: cache, cache: true, timeout: 3)
        defer { hls.close() }
        hls.finishOpening()
        try require(until(5) { hls.diagnostics["hlsKnownSizeSegments"] == 6 && server!.rangeRequests.contains { $0 != "0-0" } }, "Prefetch did not start")
        pump(0.1)
        let prefetchRequests = server!.rangeRequests.filter { $0 != "0-0" }.count
        // Read an occurrence outside the prefetch window. Its URL is already
        // being downloaded, and the requested byte is beyond the held prefix.
        let concat = try String(contentsOf: hls.file, encoding: .utf8)
        let files = concat.components(separatedBy: .newlines).filter { $0.hasPrefix("file '") }
        let url = try XCTUnwrap(URL(string: String(files[4].dropFirst(6).dropLast())))
        var request = URLRequest(url: url)
        request.setValue("bytes=8192-8192", forHTTPHeaderField: "Range")
        let network = URLSession(configuration: .ephemeral)
        defer { network.invalidateAndCancel() }
        let task = network.dataTask(with: request)
        task.resume()
        defer { task.cancel() }
        try require(until(5) { hls.waiting }, "Proxy did not wait for the held media byte")
        let allRequests = server!.rangeRequests.filter { $0 != "0-0" }.count
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
            "prefetchRequests": prefetchRequests, "requestsWithProxyRead": allRequests,
            "ranges": server!.rangeRequests], options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "repeated-hls-prefetch"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(prefetchRequests, 1, "Repeated timeline positions started duplicate prefetch downloads")
        XCTAssertEqual(allRequests, 1, "A proxy read did not adopt the active prefetch for the same resource URL")
    }

    func testIndependentHLSRepeatedResourceSharesCachedTimelineAndMetadata() throws {
        continueAfterFailure = true
        let session = try start(http("repeated-independent.m3u8"), cache: true, policy: .ffmpeg)
        try assertPlayback(session)
        session.player.pause()
        try require(until(5) { session.player.decoder?.cacheDiagnostics["hlsKnownSizeSegments"] == 32 }, "Repeated segment sizes did not resolve")
        let evidence: [String: Any] = ["fraction": session.player.downloadProgress,
            "ranges": session.player.cachedTimeRanges.map { ["start": $0.start, "end": $0.end] },
            "requests": server!.requests, "rangeRequests": server!.rangeRequests]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "repeated-hls-resource"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(session.player.downloadProgress, 1, "One complete resource backs every occurrence in this timeline")
        let resourceBytes = Int64(try Data(contentsOf: fixture("faststart.mp4")).count)
        XCTAssertEqual(session.player.cacheProgress.cachedBytes, resourceBytes, "Repeated timeline positions must not multiply stored bytes")
        XCTAssertEqual(session.player.cacheProgress.totalBytes, resourceBytes)
        XCTAssertEqual(session.player.cachedTimeRanges, [FTPlayerCachedTimeRange(start: 0, end: 960)])
        XCTAssertLessThanOrEqual(server!.rangeRequests.filter { $0 == "0-0" }.count, 1, "Identical resource URLs must share one metadata probe")
    }

    private func checkExtensionlessHLS(_ directory: String, cache: Bool) throws {
        let session = try start(http("\(directory)/stream"), cache: cache, policy: .ffmpeg)
        try assertPlayback(session)
        session.player.pause()
        var completed: Bool?
        let frames = session.sink.frames
        session.player.seek(to: 10) { completed = $0 }
        session.player.play()
        try require(until(8) { completed != nil || session.failure != nil }, "Extensionless HLS seek did not complete")
        XCTAssertEqual(completed, true)
        try require(until(8) { session.sink.frames >= frames + 3 && session.player.progress >= 9.5 || session.failure != nil }, "Extensionless HLS did not render after seek")
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.player.mediaInfo?.formatName, "hls")
        if cache {
            try require(until(5) { session.player.downloadProgress > 0 && !session.player.cachedTimeRanges.isEmpty }, "Extensionless HLS lost its resource cache")
        } else {
            XCTAssertEqual(session.player.downloadProgress, 0, "A cached playlist is not a cached video")
            XCTAssertTrue(session.downloadProgressEvents.allSatisfy { $0 == 0 }, "Playlist probing published a false video-cache percentage")
            XCTAssertTrue(session.player.cachedTimeRanges.isEmpty)
        }
    }
    func testExtensionlessHLSTSWithoutCache() throws { try checkExtensionlessHLS("hls-ts", cache: false) }
    func testExtensionlessHLSTSWithCache() throws { try checkExtensionlessHLS("hls-ts", cache: true) }
    func testExtensionlessHLSFragmentedMP4WithCache() throws { try checkExtensionlessHLS("hls-fmp4", cache: true) }
    func testExtensionlessHLSAES128WithCache() throws { try checkExtensionlessHLS("hls-aes128", cache: true) }
    func testHLSWithMP4ExtensionUsesDetectedFormat() throws {
        let session = try start(http("hls-ts/wrong.mp4"), cache: true, policy: .ffmpeg)
        try assertPlayback(session)
        XCTAssertEqual(session.player.mediaInfo?.formatName, "hls")
        try require(until(5) { session.player.downloadProgress > 0 }, "Detected TS behind .mp4 did not cache media")
    }
    func testExtensionlessHLSRedirectKeepsRelativeResources() throws {
        let session = try start(http("redirect-hls-stream"), cache: true, policy: .ffmpeg)
        try assertPlayback(session)
        XCTAssertTrue(server!.requests.contains { $0.contains("/hls-ts/segment") })
        try require(until(5) { session.player.downloadProgress > 0 }, "Redirected TS playlist lost its cache")
    }
    func testExtensionlessIndependentHLSRetainsCacheAndWarmReplay() throws {
        let session = try start(http("independent-stream"), cache: true, policy: .ffmpeg)
        try assertPlayback(session)
        session.player.pause()
        try require(until(8) {
            session.player.decoder?.cacheDiagnostics["hlsKnownSizeSegments"] == 32 &&
            (session.player.cachedTimeRanges.first?.end ?? 0) >= 50
        }, "Extensionless independent MP4 playlist lost its segment cache")
        XCTAssertGreaterThan(session.player.downloadProgress, 0)
        XCTAssertLessThan(session.player.downloadProgress, 1)
        let playlistRequests = server!.requests.filter { $0.contains("/independent-stream") }
        XCTAssertEqual(playlistRequests.filter { $0.hasPrefix("GET ") }.count, 1, "HLS detection downloaded the same playlist twice")
        let frames = session.sink.frames
        session.player.stop(); session.player.play()
        try require(until(8) { session.sink.frames > frames + 2 || session.failure != nil }, "Warm extensionless HLS replay did not render")
        XCTAssertNil(session.failure)
        XCTAssertEqual(server!.requests.filter { $0.contains("/independent-stream") }, playlistRequests)
    }
    func testExtensionlessIndependentHLSReusesRedirectResponseURL() throws {
        let session = try start(http("redirect-independent-stream"), cache: true, policy: .ffmpeg)
        try assertPlayback(session)
        try require(until(5) { session.player.downloadProgress == 1 }, "Redirected independent HLS did not cache its resources")
        XCTAssertTrue(server!.requests.contains { $0.contains("/recordings/first.mp4") })
        XCTAssertTrue(server!.requests.contains { $0.contains("/recordings/second.mp4") })
        XCTAssertFalse(server!.requests.contains { $0 == "GET /first.mp4" || $0 == "GET /second.mp4" })
        XCTAssertEqual(server!.requests.filter { $0 == "GET /recordings/stream" }.count, 1, "Redirect target playlist was downloaded again")
    }
    func testStopAndReplaceDuringPlaylistProbeReleasesOldDecoder() throws {
        server = try FixtureHTTPServer(root: fixture(""))
        for _ in 0..<10 {
            server!.stallNextGETHeaders()
            let previous = server!.rangeRequests.count
            let session = PlaybackSession(url: server!.url("hls-ts/stream"), cache: true, policy: .ffmpeg)
            sessions.append(session); session.start()
            try require(until(3) { server!.rangeRequests.count > previous }, "Probe did not enter stalled HTTP read")
            weak var oldDecoder = session.player.decoder
            session.player.stop()
            session.player.replaceVideo(with: server!.url("faststart.mp4"))
            try assertPlayback(session)
            try require(until(3) { oldDecoder == nil }, "Cancelled probe retained the old decoder")
            XCTAssertTrue(session.ready)
            XCTAssertEqual(session.errorCount, 0, "Cancelled probe delivered an error into the new playback")
            XCTAssertNotEqual(session.player.mediaInfo?.formatName, "hls")
            session.stop()
        }
    }

    func testIndependentHLSDefersAndBoundsMetadataProbes() throws {
        server = try FixtureHTTPServer(root: fixture(""))
        server!.setNetworkMode(.stall)
        let cache = try FTPlaybackCacheSession()
        defer { cache.close() }
        let manifest = FTIndependentHLS.Manifest(source: server!.url("index.m3u8"), segments: (0..<32).map {
            FTIndependentHLS.Segment(url: URL(string: server!.url("faststart.mp4").absoluteString + "?segment=\($0)")!, duration: 16)
        })
        let hls = try FTIndependentHLS(manifest: manifest, session: cache, cache: true, timeout: 3)
        defer { hls.close() }
        pump(0.2)
        XCTAssertTrue(server!.requests.isEmpty, "Metadata for later segments must not compete with opening the first video resource")
        hls.finishOpening()
        try require(until(3) { server!.rangeRequests.filter { $0 == "0-0" }.count == 2 && server!.rangeRequests.filter { $0 != "0-0" }.count == 2 }, "Metadata and media prefetch did not start after opening")
        pump(0.2)
        XCTAssertEqual(server!.rangeRequests.filter { $0 == "0-0" }.count, 2, "Size probes must remain bounded independently of media downloads")
        XCTAssertEqual(server!.rangeRequests.filter { $0 != "0-0" }.count, 2, "Unknown-size media prefetch must also remain bounded")
        hls.close()
        let requests = server!.requests
        server!.setNetworkMode(.online, dropExistingConnections: true)
        pump(0.3)
        XCTAssertEqual(server!.requests, requests, "Closing must not drain pending metadata URLs into new requests")
    }

    func testIndependentHLSMetadataQueueContinuesAfterFailures() throws {
        server = try FixtureHTTPServer(root: fixture(""))
        let cache = try FTPlaybackCacheSession()
        defer { cache.close() }
        let manifest = FTIndependentHLS.Manifest(source: server!.url("index.m3u8"), segments: (0..<9).map {
            FTIndependentHLS.Segment(url: server!.url($0 == 8 ? "faststart.mp4" : "missing-\($0).mp4"), duration: 16)
        })
        let hls = try FTIndependentHLS(manifest: manifest, session: cache, cache: true, timeout: 3)
        defer { hls.close() }
        hls.finishOpening()
        try require(until(5) { hls.diagnostics["hlsKnownSizeSegments"] == 1 }, "Failed probes prevented later metadata from completing")
        XCTAssertEqual(server!.rangeRequests.filter { $0 == "0-0" }.count, 9, "Each resource must receive only one metadata probe")
        let missingRequests = server!.requests.filter { $0.contains("missing-") }.count
        XCTAssertGreaterThanOrEqual(missingRequests, 8)
        XCTAssertLessThanOrEqual(missingRequests, 12, "Failed segment prefetch must not retry permanent 404 responses")
        XCTAssertEqual(hls.diagnostics["hlsTotalBytes"], Int64(try Data(contentsOf: fixture("faststart.mp4")).count))
    }

    func testIndependentHLSLargePlaylistStartupMeasurements() throws {
        var measurements: [[String: Any]] = []
        for _ in 0..<5 {
            let session = PlaybackSession(url: try http("large-independent-hls.m3u8"), cache: true, policy: .ffmpeg)
            sessions.append(session)
            let began = ProcessInfo.processInfo.systemUptime
            let previousRanges = server!.rangeRequests.count
            var opened: Double?
            session.onPreparation = { _, state in
                if state == .sourceOpened {
                    opened = ProcessInfo.processInfo.systemUptime - began
                }
            }
            session.start()
            try require(until(15) { session.sink.frames > 0 || session.failure != nil }, "No first frame for a large playlist")
            let firstFrame = ProcessInfo.processInfo.systemUptime - began
            try assertPlayback(session)
            // Inspect wire order: public preparation callbacks run on main and
            // may arrive after the demux worker has already advanced to metadata.
            let probesBeforeVideo = server!.rangeRequests.dropFirst(previousRanges).prefix { $0 == "0-0" }.count
            measurements.append(["sourceOpenedSeconds": opened ?? -1, "firstFrameSeconds": firstFrame,
                                 "metadataRequestsBeforeVideo": probesBeforeVideo, "frames": session.sink.frames])
            session.stop()
            pump(0.1)
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "large-hls-startup"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(measurements.allSatisfy { ($0["metadataRequestsBeforeVideo"] as? Int) == 0 }, "Cold open should request video before probing the playlist's later resources")
    }


    func testIndependentHLSSingleMP4CachesAndSeeks() throws {
        let session = try start(http("single-independent-hls.m3u8"), cache: true, policy: .ffmpeg)
        try assertPlayback(session)
        session.player.pause()
        try require(until(8) { session.player.downloadProgress == 1 }, "A single complete MP4 playlist did not use its resource cache")
        XCTAssertEqual(session.player.duration, 30, accuracy: 0.05)
        var complete: Bool?
        let frames = session.sink.frames
        session.player.seek(to: 1.35) { complete = $0 }
        try require(until(5) { complete != nil }, "Seek did not complete")
        XCTAssertEqual(complete, true)
        session.player.play()
        try require(until(5) { session.sink.frames >= frames + 3 }, "Seek did not output frames")
        let position = try XCTUnwrap(session.player.decoder?.currentVideoFrame?.position)
        XCTAssertGreaterThanOrEqual(position, 1.3)
        XCTAssertLessThan(position, 2.35)
    }

    func testNativeHLSHEVCFirstSeekBeforeReadingKeepsInitialKeyframe() throws {
        let format = FTFormatContext(contentURL: try http("hls-hevc/index.m3u8"), videoFormat: .m3u8)
        defer { format.destroy() }
        format.setupSync(useCache: false)
        XCTAssertNil(format.error)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        // No readFrame call has seeded the SDK's observed keyframe index.
        XCTAssertTrue(format.seekFile(withFFTimebase: 1))
        XCTAssertGreaterThanOrEqual(format.readFrame(packet), 0)
        let value = try XCTUnwrap(packet?.pointee)
        XCTAssertEqual(value.flags & AV_PKT_FLAG_KEY, AV_PKT_FLAG_KEY)
        let position = Double(value.pts) * format.videoTimebase - format.startTime
        XCTAssertEqual(position, 0, accuracy: 0.001, "First seek lost the initial IDR before either decoder received a packet")
    }

    func testNativeHLSHEVCBackwardSeekReturnsPacketsNearBeginning() throws {
        let format = FTFormatContext(contentURL: try http("hls-hevc/index.m3u8"), videoFormat: .m3u8)
        defer { format.destroy() }
        format.setupSync(useCache: false)
        XCTAssertNil(format.error)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var samples: [[String: Any]] = []
        func capture(_ stage: String, _ result: Int32) {
            guard let value = packet?.pointee else { return }
            samples.append(["stage": stage, "result": result, "pts": value.pts, "dts": value.dts,
                            "flags": value.flags, "timebase": format.videoTimebase, "startTime": format.startTime,
                            "position": Double(value.pts) * format.videoTimebase - format.startTime])
        }
        let initialResult = format.readFrame(packet)
        capture("initial", initialResult)
        XCTAssertGreaterThanOrEqual(initialResult, 0)
        let initialPTS = try XCTUnwrap(packet?.pointee.pts)
        av_packet_unref(packet)
        XCTAssertTrue(format.seekFile(withFFTimebase: 9.9))
        capture("tail", format.readFrame(packet))
        av_packet_unref(packet)
        XCTAssertTrue(format.seekFile(withFFTimebase: 0.05))
        let result = format.readFrame(packet)
        capture("backward", result)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "native-hls-seek-packets"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThanOrEqual(result, 0)
        let value = try XCTUnwrap(packet?.pointee)
        let position = Double(value.pts) * format.videoTimebase - format.startTime
        XCTAssertLessThan(position, 1, "Backward seek returned a later GOP before either decoder received any packets")
        XCTAssertEqual(value.pts, initialPTS, "Backward seek must retain the first random access packet")
        XCTAssertEqual(value.flags & AV_PKT_FLAG_KEY, AV_PKT_FLAG_KEY)
    }

    func testIndependentHLSStopKeepsAggregateCacheProgress() throws {
        let session = try start(http("independent-hls.m3u8"), cache: true, policy: .ffmpeg)
        session.player.pause()
        try require(until(8) {
            session.player.decoder?.cacheDiagnostics["hlsKnownSizeSegments"] == 32 &&
            (session.player.cachedTimeRanges.first?.end ?? 0) >= 50
        }, "HLS cache window did not complete")
        let fraction = session.player.downloadProgress
        let ranges = session.player.cachedTimeRanges
        XCTAssertGreaterThan(fraction, 0)
        XCTAssertLessThan(fraction, 0.5, "Regression needs a partially cached playlist")
        session.player.stop()
        XCTAssertEqual(session.player.downloadProgress, fraction, accuracy: 0.001,
                       "Stop replaced the playlist fraction with one resource's fraction")
        XCTAssertEqual(session.player.cachedTimeRanges, ranges)
    }

    func testIndependentHLSRedirectResolvesRelativeSegmentsAndReusesManifest() throws {
        server = try FixtureHTTPServer(root: fixture(""))
        let source = server!.url("redirect-independent.m3u8")
        let session = try FTPlaybackCacheSession()
        defer { session.close() }
        let manifest = try XCTUnwrap(FTIndependentHLS.prepare(source: source, session: session, timeout: 3,
            interrupted: { false }, preparation: nil))
        XCTAssertEqual(manifest.source, source, "Session cache must retain the requested source identity")
        XCTAssertEqual(manifest.segments.map(\.url), [server!.url("recordings/first.mp4"), server!.url("recordings/second.mp4")])
        let requests = server!.requests
        let cached = try FTIndependentHLS.prepare(source: source, session: session, timeout: 3,
            interrupted: { false }, preparation: nil)
        XCTAssertEqual(cached?.segments.map(\.url), manifest.segments.map(\.url))
        XCTAssertEqual(server!.requests, requests)
    }

    func testIndependentHLSRedirectPlaybackWithCache() throws {
        try assertPlayback(start(http("redirect-independent.m3u8"), cache: true, policy: .ffmpeg))
    }

    func testIndependentHLSRedirectPlaybackWithoutCache() throws {
        try assertPlayback(start(http("redirect-independent.m3u8"), cache: false, policy: .ffmpeg))
    }



    func testHLSSizeProbeAvoidsRejectedHEADRoundTrip() throws {
        server = try FixtureHTTPServer(root: fixture(""), mp4HEADStatus: 403, mp4HEADDelay: 0.4)
        let probe = HTTPResourceSizeProbe(timeout: 3)
        defer { probe.close() }
        let complete = expectation(description: "Resource size")
        let started = ProcessInfo.processInfo.systemUptime
        var total: Int64?
        probe.size(of: server!.url("faststart.mp4")) { value in total = value; complete.fulfill() }
        wait(for: [complete], timeout: 4)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let requests = server!.requests
        let evidence: [String: Any] = ["seconds": elapsed, "requests": requests, "size": total ?? -1]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "hls-size-probe"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(total, Int64(try Data(contentsOf: fixture("faststart.mp4")).count))
        XCTAssertEqual(requests.filter { $0.hasPrefix("HEAD ") }.count, 0, "A signed URL can reject HEAD; obtain the size directly from GET Range headers")
        XCTAssertEqual(requests.filter { $0.hasPrefix("GET ") }.count, 1)
        XCTAssertEqual(server!.rangeRequests, ["0-0"])
    }

    func testHLSSizeProbeHandlesIgnoredRangeAndHTTPFailure() throws {
        server = try FixtureHTTPServer(root: fixture(""))
        let probe = HTTPResourceSizeProbe(timeout: 3)
        defer { probe.close() }
        let expectedSize = Int64(try Data(contentsOf: fixture("faststart.mp4")).count)
        for (path, expected) in [("no-range.mp4", Optional(expectedSize)), ("status/404", nil)] {
            let complete = expectation(description: path)
            var total: Int64?
            probe.size(of: server!.url(path)) { value in total = value; complete.fulfill() }
            wait(for: [complete], timeout: 4)
            XCTAssertEqual(total, expected)
        }
        XCTAssertEqual(server!.requests.count, 2, "Probe must complete once per response, including cancellation at headers")
        XCTAssertTrue(server!.requests.allSatisfy { $0.hasPrefix("GET ") })
    }


    func testIndependentHLSCacheProgressWhenHEADIsForbidden() throws {
        server = try FixtureHTTPServer(root: fixture(""), mp4HEADStatus: 403)
        let s = try start(server!.url("independent-hls.m3u8"), cache: true, policy: .ffmpeg)
        s.player.pause(); s.player.rate = 16
        try require(until(5) { (s.player.cachedTimeRanges.first?.end ?? 0) >= 50 && s.player.decoder?.cacheDiagnostics["hlsKnownSizeSegments"] == 32 }, "HEAD403 blocked HLS progress/prefetch despite valid GET Range")
        XCTAssertEqual(s.player.decoder?.cacheDiagnostics["hlsKnownSizeSegments"],32)
        XCTAssertEqual(s.player.decoder?.cacheDiagnostics["hlsTotalBytes"],Int64(try Data(contentsOf: fixture("faststart.mp4")).count)*32)
        try require(until { s.downloadProgressEvents.contains { $0 > 0 } }, "Download delegate did not publish completion for Demo")
        XCTAssertTrue(server!.rangeRequests.contains("0-0"), "Metadata fallback did not use a one-byte Range")
        s.measurements.append(["operation":"head403-cache-progress","diagnostics":s.player.decoder?.cacheDiagnostics ?? [:],"delegateLast":s.downloadProgressEvents.last ?? -1])
    }
    func testIndependentHLSReadAheadAt1xWhenHEADIsUnsupported() throws {
        server = try FixtureHTTPServer(root: fixture(""), mp4HEADStatus: 405)
        let s = try start(server!.url("independent-hls.m3u8"), cache: true, policy: .ffmpeg)
        s.player.pause()
        try require(until(5) { (s.player.cachedTimeRanges.first?.end ?? 0) >= 50 && s.player.downloadProgress > 0 }, "1x cache stopped at decoder buffer instead of filling its media-time window")
        XCTAssertLessThanOrEqual(s.player.cachedTimeRanges.first?.end ?? 0,66)
        XCTAssertEqual(s.player.rate,1)
        XCTAssertGreaterThan(s.player.downloadProgress,0)
        XCTAssertLessThan(s.player.downloadProgress,1)
        XCTAssertEqual(s.player.decoder?.cacheDiagnostics["loadMaxMediaMilliseconds"],50000)
        try require(until(2) { s.downloadProgressEvents.contains { $0 > 0 } }, "Cached progress was not delivered to the delegate")
        s.measurements.append(["operation":"head405-1x-prefetch","diagnostics":s.player.decoder?.cacheDiagnostics ?? [:]])
    }

    func testHLSCacheProgressReportsBytesWhenLaterSizesAreUnknown() throws {
        let session = try start(http("hls-unknown-total/index.m3u8"), cache: true, policy: .ffmpeg)
        try assertPlayback(session)
        session.player.pause()
        try require(until(5) { session.player.cacheProgress.cachedBytes > 0 && !session.player.cachedTimeRanges.isEmpty }, "Unknown total hid bytes already stored in cache")
        let progress = session.player.cacheProgress
        XCTAssertNil(progress.totalBytes)
        XCTAssertNil(progress.fraction)
        XCTAssertEqual(session.player.downloadProgress, 0, "Legacy zero is explicitly unknown, not empty")
        session.player.stop()
        XCTAssertGreaterThanOrEqual(session.player.cacheProgress.cachedBytes, progress.cachedBytes)
        XCTAssertNil(session.player.cacheProgress.totalBytes)
        session.measurements.append(["operation": "cache-unknown-total", "cachedBytes": session.player.cacheProgress.cachedBytes])
    }
    func testHLSMetadataProbeRejectsEncodedRepresentationSize() throws {
        server = try FixtureHTTPServer(root: fixture(""))
        let probe = HTTPResourceSizeProbe(timeout: 2)
        defer { probe.close() }
        for path in ["gzip-full.mp4", "gzip-range.mp4"] {
            var completed = false, size: Int64?
            probe.size(of: server!.url(path)) { value in DispatchQueue.main.async { size = value; completed = true } }
            try require(until(3) { completed }, "Encoded size probe did not complete")
            XCTAssertNil(size, "Wire representation size cannot describe decoded cache bytes")
        }
    }
    func testEmptyHLS200SurfacesActionableError() throws {
        let session = PlaybackSession(url: try http("empty.m3u8"), cache: true); sessions.append(session); session.start()
        try require(until(5) { session.failure != nil }, "Empty200 playlist did not fail")
        let error = try XCTUnwrap(session.failure as NSError?)
        XCTAssertEqual(error.domain,NSURLErrorDomain); XCTAssertEqual(error.code,URLError.zeroByteResource.rawValue)
        XCTAssertEqual(error.userInfo["operation"] as? String,"playlist")
        XCTAssertEqual(session.sink.frames,0)
    }

    func testH264TSMediaPlaylist() throws { try assertPlayback(start(http("hls-ts/index.m3u8"))) }
    func testH264TSMasterPlaylist() throws { try assertPlayback(start(http("hls-ts/master.m3u8"))) }
    func testH264FragmentedMP4() throws { try assertPlayback(start(http("hls-fmp4/index.m3u8"))) }
    func testHEVCFragmentedMP4() throws { try assertPlayback(start(http("hls-hevc/index.m3u8"))) }
    func testAES128EncryptedHLS() throws { try assertPlayback(start(http("hls-aes128/index.m3u8"))) }
    func testHLSPauseResume() throws {
        let s = try start(http("hls-ts/index.m3u8")); try assertPlayback(s)
        s.player.pause(); let paused = s.player.progress; pump(0.4)
        try require(abs(s.player.progress - paused) < 0.2, "Paused HLS kept advancing")
        s.player.play(); try require(until { s.player.progress > paused + 0.15 }, "HLS did not resume")
    }
    func testHLSSeekToMiddle() throws {
        let s = try start(http("hls-ts/index.m3u8")); try assertPlayback(s)
        var done: Bool?; s.player.seek(to: 10) { done = $0 }
        try require(until { done != nil }, "HLS seek callback missing")
        try require(done == true, "HLS seek failed")
        try require(until { s.player.progress >= 9.5 }, "HLS seek did not reach target")
    }
    func testHLSCacheEnabledDoesNotLoseRelativeSegmentURLs() throws {
        let s = try start(http("hls-ts/index.m3u8"), cache: true)
        try assertPlayback(s)
        try require(server!.requests.contains { $0.contains("segment") }, "HLS segments were not fetched")
    }

    func testHLSResourceModelPreservesSequenceIVAndPerSegmentDependencies() throws {
        let source = URL(string: "https://example.invalid/video/playlist")!
        let text = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:73\n#EXT-X-ENDLIST\n#EXT-X-DISCONTINUITY\n#EXT-X-KEY:METHOD=AES-128,URI=\"key-a\",IV=0x00000000000000000000000000000049\n#EXT-X-MAP:URI=\"init-a\"\n#EXT-X-BYTERANGE:100@0\n#EXTINF:2,\nmedia\n#EXTINF:3,\n#EXT-X-KEY:METHOD=AES-128,URI=\"key-b\"\n#EXT-X-MAP:URI=\"init-b\"\n#EXT-X-BYTERANGE:200\nmedia\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:4,\nlast\n"
        let manifest = try XCTUnwrap(FTIndependentHLS.parse(Data(text.utf8), source: source))
        XCTAssertTrue(manifest.usesNativeHLS)
        XCTAssertEqual(manifest.auxiliary?.count, 4)
        XCTAssertEqual(manifest.segments.map { $0.dependencies }, [[1,0], [3,2], [3]])
        XCTAssertEqual(manifest.segments[1].byteRange, CachedRange(start: 100, end: 299))
        let session = try FTPlaybackCacheSession()
        defer { session.close() }
        let hls = try FTIndependentHLS(manifest: manifest, session: session, cache: true, timeout: 3)
        defer { hls.close() }
        let rendered = try String(contentsOf: hls.file, encoding: .utf8)
        XCTAssertTrue(rendered.contains("#EXT-X-MEDIA-SEQUENCE:73"))
        XCTAssertTrue(rendered.contains("IV=0x00000000000000000000000000000049"))
        XCTAssertTrue(rendered.contains("#EXT-X-KEY:METHOD=NONE"))
        XCTAssertTrue(rendered.contains("#EXT-X-DISCONTINUITY"))
        XCTAssertFalse(rendered.contains("example.invalid"))
        XCTAssertFalse(rendered.contains("#EXT-X-BYTERANGE:"))
        XCTAssertEqual(hls.fraction, 0)
        XCTAssertTrue(hls.ranges.isEmpty, "No playable cache exists until each segment's own init/key/media are present")
    }

}

private struct DurationPlaylistStub: HTTPDataLoading {
    let text: String
    init(_ text: String) { self.text = text }
    func load(_ url: URL, timeout: TimeInterval, interrupted: () -> Bool) throws -> HTTPDataResponse {
        HTTPDataResponse(data: Data(text.utf8), url: url)
    }
}

private final class PlaylistTransportStub: HTTPDataLoading {
    var requests: [URL] = []
    func load(_ url: URL, timeout: TimeInterval, interrupted: () -> Bool) throws -> HTTPDataResponse {
        requests.append(url)
        return HTTPDataResponse(data: Data("#EXTM3U\n#EXTINF:2,\nfirst.mp4\n#EXT-X-DISCONTINUITY\n#EXTINF:3,\nsecond.mp4\n#EXT-X-ENDLIST\n".utf8), url: url)
    }
}
