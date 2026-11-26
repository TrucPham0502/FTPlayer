import XCTest
import CoreVideo
import Accelerate
import libavcodec
@testable import FTPlayer

final class FTPlayerFormatTests: PlaybackTestCase {
    func testHumanDetectSecond5PicturesMatchCodecDisplayOrder() throws {
        let url = try fixture("human-detect-261106.mp4")
        let format = FTFormatContext(contentURL: url, videoFormat: .unknown)
        format.setupSync(useCache: false)
        defer { format.destroy() }
        let codec = try XCTUnwrap(format.videoCodecContext)
        var packet = av_packet_alloc(), raw = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&raw) }
        var reference: [UInt64] = []
        let target = 5.273806
        // Read codec output directly, bypassing the SDK frame queue. Compare
        // picture content: counting equal PTS alone cannot reveal reversal.
        while reference.count < 2, format.readFrame(packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard Int(packet!.pointee.stream_index) == format.videoTrack?.index else { continue }
            _ = avcodec_send_packet(codec, packet)
            while true {
                let result = avcodec_receive_frame(codec, raw)
                if result == FT_AVERROR_INVALIDDATA { continue }
                guard result == 0 else { break }
                defer { av_frame_unref(raw) }
                let value = raw!.pointee
                if abs(Double(value.best_effort_timestamp) * format.videoTimebase - target) < 0.000002 {
                    reference.append(Self.lumaFingerprint(try XCTUnwrap(value.data.0), stride: Int(value.linesize.0),
                        width: Int(value.width), height: Int(value.height)))
                }
            }
        }
        try require(reference.count == 2 && reference[0] != reference[1], "Expected distinct IDR/P reference pictures")
        let session = try start(url, policy: .ffmpeg)
        var observed: [UInt64] = []
        session.sink.inspectFrame = { buffer, pts in
            guard abs(pts - target) < 0.000002 else { return }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
            observed.append(Self.lumaFingerprint(base.assumingMemoryBound(to: UInt8.self),
                stride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
        }
        try require(until(10) { session.sink.lastPresentationTime > 5.5 || session.failure != nil }, "Did not cross second 5")
        session.player.pause()
        session.measurements.append(["operation": "second-5-picture-order",
            "reference": reference.map { String($0) }, "observed": observed.map { String($0) }])
        XCTAssertNil(session.failure)
        XCTAssertEqual(observed, reference, "Equal-PTS pictures were presented in reverse codec display order")
    }

    private static func lumaFingerprint(_ bytes: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for y in Swift.stride(from: 0, to: height, by: 8) {
            for x in Swift.stride(from: 0, to: width, by: 8) {
                hash = (hash ^ UInt64(bytes[y * stride + x])) &* 1099511628211
            }
        }
        return hash
    }


    func testHumanDetect261106Seconds4Through6Automatic() throws {
        try checkHumanDetect261106Seconds4Through6(.automatic)
    }

    func testHumanDetect261106Seconds4Through6FFmpeg() throws {
        try checkHumanDetect261106Seconds4Through6(.ffmpeg)
    }

    func testHumanDetect261106Seconds4Through6Hardware() throws {
        try checkHumanDetect261106Seconds4Through6(.hardware)
    }

    private func checkHumanDetect261106Seconds4Through6(_ policy: FTVideoDecodingPolicy) throws {
        // Independent ffprobe decoding of the untouched fixture. Keep equal
        // PTS entries: these are distinct pictures, not duplicate callbacks.
        let expected = [4.076349, 4.234429, 4.234429, 4.332241, 4.424125, 4.480441,
                        4.572326, 4.639510, 4.720526, 4.786722, 4.871690, 4.965550,
                        5.022854, 5.118690, 5.273806, 5.273806, 5.362726, 5.435838,
                        5.510927, 5.608739, 5.676911, 5.765831, 5.855739, 5.916007]
        let session = try start(try fixture("human-detect-261106.mp4"), policy: policy)
        try assertPlayback(session)
        try require(until(12) { session.sink.lastPresentationTime >= 6.2 || session.failure != nil },
                    "Playback did not cross the reported interval")
        session.player.pause()
        let events = session.sink.presentationEvents(after: 0).filter { $0.time >= 4 && $0.time < 6 }
        let gaps = zip(events, events.dropFirst()).map {
            ["from": $0.time, "to": $1.time, "mediaGap": $1.time - $0.time,
             "wallGap": $1.wall - $0.wall, "addedGap": ($1.wall - $0.wall) - ($1.time - $0.time)]
        }
        session.measurements.append(["operation": "human-detect-261106-seconds-4-through-6",
            "policy": policy.rawValue, "positions": events.map(\.time), "gaps": gaps])
        XCTAssertNil(session.failure)
        XCTAssertEqual(events.count, expected.count, "Pictures were lost or repeated during the reported stutter")
        for (event, reference) in zip(events, expected) {
            XCTAssertEqual(event.time, reference, accuracy: 0.000002)
        }
        // Check excess delay per picture rather than the broad 300 ms freeze
        // limit. Source holds of 155/158 ms remain visible in the measurements.
        XCTAssertLessThan(gaps.compactMap { $0["addedGap"] }.max() ?? .infinity, 0.05,
                          "SDK added over 50 ms to the source's frame interval")
        let stats = session.player.videoDecodingStatistics
        if policy == .hardware {
            XCTAssertGreaterThan(stats.hardwareFrames, 0)
            XCTAssertEqual(stats.ffmpegFrames, 0)
            XCTAssertEqual(stats.videoToolboxSoftwareFrames, 0)
            XCTAssertEqual(stats.videoToolboxUnverifiedFrames, 0)
        }
    }

    func testHumanDetect261106AutomaticFallbackPreservesEveryPicture() throws {
        try checkHumanDetectDecode(.automatic, name: "human-detect-261106.mp4",
                                   pictureCount: 431, lastPTS: 34.418847, maximumGap: 0.197)
    }

    func testHumanDetect261106FFmpegPreservesEveryPicture() throws {
        try checkHumanDetectDecode(.ffmpeg, name: "human-detect-261106.mp4",
                                   pictureCount: 431, lastPTS: 34.418847, maximumGap: 0.197)
    }

    func testHumanDetect261106HardwarePreservesEveryPicture() throws {
        let format = FTFormatContext(contentURL: try fixture("human-detect-261106.mp4"), videoFormat: .unknown)
        format.setupSync(useCache: false)
        defer { format.destroy() }
        XCTAssertNil(format.error)
        let decoder = FTH264VideoToolBox(codecContext: try XCTUnwrap(format.videoCodecContext), timebase: format.videoTimebase)
        decoder.requireHardware = true
        guard decoder.trySetupVTSession(), decoder.usingHardware == true else {
            #if targetEnvironment(simulator)
            throw XCTSkip("Strict hardware unavailable on Simulator: \(decoder.setupFailure)")
            #else
            XCTFail("Hardware setup failed: \(decoder.setupFailure)"); return
            #endif
        }
        defer { decoder.flush() }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var positions: [Double] = []
        var rows: [[String: Any]] = []
        while format.readFrame(packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard Int(packet!.pointee.stream_index) == format.videoTrack?.index else { continue }
            let value = packet!.pointee
            let status = decoder.sendPacket(value)
            rows.append(["pts": Double(value.pts) * format.videoTimebase,
                         "size": Int(value.size), "status": status, "callbackStatus": decoder.decodeStatus])
            while let frame = decoder.receiveFrame() { positions.append(frame.pts) }
        }
        decoder.finishDelayedFrames()
        while let frame = decoder.receiveFrame() { positions.append(frame.pts) }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject:
            ["packets": rows, "positions": positions]), uniformTypeIdentifier: "public.json")
        attachment.name = "human-detect-261106-hardware-pictures"
        attachment.lifetime = .keepAlways; add(attachment)
        // Independent FFmpeg decoding of the untouched fixture produces 431
        // pictures, including 33 distinct picture pairs sharing a PTS.
        XCTAssertEqual(positions.count, 431, "Hardware lost pictures from the original camera recording")
        XCTAssertEqual(positions.last ?? -1, 34.418847, accuracy: 0.00001)
        XCTAssertLessThanOrEqual(zip(positions, positions.dropFirst()).map { $1 - $0 }.max() ?? .infinity,
                                 0.197, "Hardware introduced a gap absent from the source")
    }

    func testHumanDetect261106PlaybackAutomaticCadence() throws {
        try checkHumanDetect261106Cadence(.automatic)
    }

    func testHumanDetect261106PlaybackFFmpegCadence() throws {
        try checkHumanDetect261106Cadence(.ffmpeg)
    }

    private func checkHumanDetect261106Cadence(_ policy: FTVideoDecodingPolicy) throws {
        let session = try start(try fixture("human-detect-261106.mp4"), policy: policy)
        try assertPlayback(session)
        let before = session.sink.frames
        pump(32)
        session.player.pause()
        let events = session.sink.presentationEvents(after: before)
        let gaps = zip(events, events.dropFirst()).map {
            ["from": $0.time, "to": $1.time, "wallGap": $1.wall - $0.wall,
             "mediaGap": $1.time - $0.time]
        }
        session.measurements.append(["operation": "human-detect-261106-cadence",
            "policy": policy.rawValue, "frames": events.count, "gaps": gaps])
        XCTAssertNil(session.failure)
        XCTAssertGreaterThan((events.last?.time ?? 0) - (events.first?.time ?? 0), 30)
        // The original clip's largest decoded PTS gap is 197 ms. Allow
        // scheduling jitter, but reject additional freezes introduced by playback.
        XCTAssertLessThan(gaps.compactMap { $0["wallGap"] }.max() ?? .infinity, 0.3,
                          "Playback froze beyond the camera's original frame cadence")
    }

    func testHumanDetectH264ParameterPacketsPreserveHardwareSession() throws {
        let format = FTFormatContext(contentURL: try fixture("human-detect-h264.mp4"), videoFormat: .unknown)
        format.setupSync(useCache: false)
        defer { format.destroy() }
        let decoder = FTH264VideoToolBox(codecContext: try XCTUnwrap(format.videoCodecContext), timebase: format.videoTimebase)
        decoder.requireHardware = true
        guard decoder.trySetupVTSession(), decoder.usingHardware == true else {
            #if targetEnvironment(simulator)
            throw XCTSkip("Strict hardware unavailable on Simulator: \(decoder.setupFailure)")
            #else
            XCTFail("Hardware setup failed: \(decoder.setupFailure)"); return
            #endif
        }
        defer { decoder.flush() }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var parameterPackets = 0, parameterFailures = 0, pictures = 0
        var submittedPicture = false
        var rows: [[String: Any]] = []
        while format.readFrame(packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard Int(packet!.pointee.stream_index) == format.videoTrack?.index else { continue }
            let value = packet!.pointee
            let type = value.size > 4 ? value.data![4] & 0x1f : 0
            // Isolate configuration handling from pictures this VT implementation
            // independently rejects. The full clip is covered by Auto below.
            guard type == 7 || type == 8 || !submittedPicture && type == 5 else { continue }
            if type == 5 { submittedPicture = true }
            let began = ProcessInfo.processInfo.systemUptime
            let result = decoder.sendPacket(value)
            if type == 7 || type == 8 {
                parameterPackets += 1
                if result != 0 || !decoder.vtSessionToken || decoder.decodeStatus != noErr { parameterFailures += 1 }
            }
            rows.append(["pts": Double(value.pts) * format.videoTimebase, "nalType": Int(type),
                "seconds": ProcessInfo.processInfo.systemUptime - began, "result": result,
                "callbackStatus": decoder.decodeStatus, "sessionActive": decoder.vtSessionToken])
            while decoder.receiveFrame() != nil { pictures += 1 }
        }
        decoder.finishDelayedFrames()
        while decoder.receiveFrame() != nil { pictures += 1 }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows), uniformTypeIdentifier: "public.json")
        attachment.name = "human-detect-hardware-packets"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(parameterPackets, 34)
        XCTAssertEqual(parameterFailures, 0, "SPS/PPS-only samples triggered bad-picture recovery and destroyed the hardware session")
        XCTAssertEqual(pictures, 1)
        XCTAssertEqual(decoder.usingHardware, true)
    }

    func testHumanDetectH264ParameterPacketsAutomatic() throws { try checkHumanDetectDecode(.automatic) }
    func testHumanDetectH264ParameterPacketsFFmpeg() throws { try checkHumanDetectDecode(.ffmpeg) }
    func testHumanDetectH264PlaybackFFmpeg() throws { try checkHumanDetectPlayback(.ffmpeg) }
    func testHumanDetectH264PlaybackAutomatic() throws { try checkHumanDetectPlayback(.automatic) }
    func testHumanDetectH264AutomaticSeekAfterFallback() throws {
        let session = try start(try fixture("human-detect-h264.mp4"))
        try assertPlayback(session)
        try require(until(5) { session.player.currentTime > 1.6 || session.failure != nil }, "No playback through hardware rejection")
        for target in [10.0, 0, 30, 0] {
            let before = session.sink.frames
            var completed: Bool?
            session.player.seek(to: target) { completed = $0 }
            try require(until(8) {
                completed != nil && session.sink.frames >= before + 3 || session.failure != nil
            }, "Seek after decoder handoff stalled at \(target)")
            XCTAssertEqual(completed, true)
            XCTAssertNil(session.failure)
            let positions = session.sink.presentationTimes(after: before)
            XCTAssertTrue(positions.allSatisfy { $0 >= target - 0.1 && $0 < target + 1.5 }, "Stale pictures crossed a seek: \(positions)")
            session.measurements.append(["operation": "human-detect-seek", "target": target, "positions": positions])
        }
    }

    func testSeparateAVCCParameterPacketsApplyNewResolutionAtNextPicture() throws {
        let initial = FTFormatContext(contentURL: try fixture("sample.mp4"), videoFormat: .unknown)
        let changed = FTFormatContext(contentURL: try fixture("padded-848.mp4"), videoFormat: .unknown)
        initial.setupSync(useCache: false); changed.setupSync(useCache: false)
        defer { initial.destroy(); changed.destroy() }
        let codec = try XCTUnwrap(initial.videoCodecContext)
        let nextCodec = try XCTUnwrap(changed.videoCodecContext)
        let decoder = FTH264VideoToolBox(codecContext: codec, timebase: changed.videoTimebase)
        decoder.requireHardware = true
        guard decoder.trySetupVTSession(), decoder.usingHardware == true else {
            #if targetEnvironment(simulator)
            throw XCTSkip("Strict hardware unavailable on Simulator: \(decoder.setupFailure)")
            #else
            XCTFail("Hardware setup failed: \(decoder.setupFailure)"); return
            #endif
        }
        defer { decoder.flush() }
        let config = Array(UnsafeBufferPointer(start: try XCTUnwrap(nextCodec.pointee.extradata), count: Int(nextCodec.pointee.extradata_size)))
        try require(config.count >= 7 && config[0] == 1, "Expected AVCC fixture")
        var offset = 6
        func sendParameterSets(_ count: Int) throws {
            for _ in 0..<count {
                try require(offset + 2 <= config.count, "Truncated configuration length")
                let size = Int(config[offset]) << 8 | Int(config[offset + 1]); offset += 2
                try require(size > 0 && offset + size <= config.count, "Truncated parameter set")
                var packet = av_packet_alloc()
                defer { av_packet_free(&packet) }
                try require(av_new_packet(packet, Int32(size + 4)) == 0, "Cannot allocate parameter packet")
                let bytes = try XCTUnwrap(packet?.pointee.data)
                for index in 0..<4 { bytes[index] = UInt8((size >> (24 - 8 * index)) & 255) }
                for index in 0..<size { bytes[index + 4] = config[offset + index] }
                offset += size
                XCTAssertEqual(decoder.sendPacket(packet!.pointee), 0)
                XCTAssertTrue(decoder.vtSessionToken)
                XCTAssertEqual(decoder.decodeStatus, noErr)
                XCTAssertNil(decoder.receiveFrame(), "Configuration-only sample produced a picture")
            }
        }
        try sendParameterSets(Int(config[5] & 31))
        try require(offset < config.count, "Missing PPS count")
        let ppsCount = Int(config[offset]); offset += 1
        try sendParameterSets(ppsCount)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var widths: [Int] = []
        for _ in 0..<40 {
            guard changed.readFrame(packet) >= 0 else { break }
            defer { av_packet_unref(packet) }
            guard Int(packet!.pointee.stream_index) == changed.videoTrack?.index else { continue }
            XCTAssertEqual(decoder.sendPacket(packet!.pointee), 0)
            while let frame = decoder.receiveFrame() { widths.append(CVPixelBufferGetWidth(try XCTUnwrap(frame.pixelBuffer))) }
            if widths.count >= 3 { break }
        }
        XCTAssertGreaterThanOrEqual(widths.count, 3)
        XCTAssertTrue(widths.allSatisfy { $0 == 848 }, "Separate SPS/PPS did not update the hardware format: \(widths)")
        XCTAssertEqual(decoder.usingHardware, true)
    }

    private func checkHumanDetectPlayback(_ policy: FTVideoDecodingPolicy) throws {
        let session = try start(try fixture("human-detect-h264.mp4"), policy: policy)
        try assertPlayback(session)
        let before = session.sink.frames
        pump(6.2) // Cross three SPS/PPS boundaries with the real audio/video clocks.
        session.player.pause()
        let events = session.sink.presentationEvents(after: before)
        let maxGap = zip(events, events.dropFirst()).map { $1.wall - $0.wall }.max() ?? .infinity
        session.measurements.append(["operation": "human-detect-cadence", "frames": events.count,
            "maximumWallGap": maxGap, "positions": events.map(\.time), "wallTimes": events.map(\.wall)])
        XCTAssertNil(session.failure)
        XCTAssertGreaterThan(events.count, 65)
        XCTAssertGreaterThan((events.last?.time ?? 0) - (events.first?.time ?? 0), 5.5)
        XCTAssertLessThan(maxGap, 0.3, "Camera pictures froze across configuration-only samples")
        let stats = session.player.videoDecodingStatistics
        if policy == .ffmpeg { XCTAssertGreaterThan(stats.ffmpegFrames, 65); XCTAssertEqual(stats.hardwareFrames, 0) }
        #if !targetEnvironment(simulator)
        if policy == .automatic {
            XCTAssertGreaterThan(stats.hardwareFrames, 0); XCTAssertGreaterThan(stats.ffmpegFrames, 0)
            XCTAssertEqual(stats.videoToolboxSoftwareFrames, 0); XCTAssertEqual(stats.videoToolboxUnverifiedFrames, 0)
        }
        #endif
    }

    private func checkHumanDetectDecode(_ policy: FTVideoDecodingPolicy, name: String = "human-detect-h264.mp4",
                                       pictureCount: Int = 454, lastPTS: Double = 34.431691,
                                       maximumGap: Double = 0.159) throws {
        let format = FTFormatContext(contentURL: try fixture(name), videoFormat: .unknown)
        format.setupSync(useCache: false)
        defer { format.destroy() }
        XCTAssertNil(format.error)
        let codec = try XCTUnwrap(format.videoCodecContext)
        let decoder = FTVideoDecoder(codecContext: codec, timebase: format.videoTimebase,
                                     fps: format.videoFPS, delegate: nil, policy: policy)
        if policy == .hardware, !decoder.prepareRequiredHardware() {
            #if targetEnvironment(simulator)
            throw XCTSkip("Strict hardware unavailable on Simulator: \(decoder.hardwareSetupFailure)")
            #else
            XCTFail("Hardware setup failed: \(decoder.hardwareSetupFailure)")
            return
            #endif
        }
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { decoder.decodeFrameThread(); stopped.signal() }
        defer { decoder.destroy(); XCTAssertEqual(stopped.wait(timeout: .now() + 3), .success) }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        while format.readFrame(packet) >= 0 {
            if Int(packet!.pointee.stream_index) == format.videoTrack?.index {
                decoder.putPacket(try XCTUnwrap(av_packet_clone(packet)))
            }
            av_packet_unref(packet)
        }
        decoder.endOfFile = true
        var positions: [Double] = []
        func collect() {
            while let frame = decoder.getFrameAsync() { positions.append(frame.position); frame.cancel() }
        }
        try require(until(15) {
            collect()
            return decoder.error != nil || decoder.packetEmpty() && !decoder.decoding
        }, "Decoder did not drain the camera clip")
        collect()
        let stats = decoder.decodingStatistics
        let metrics: [String: Any] = ["policy": policy.rawValue, "positions": positions,
            "hardwareFrames": stats.hardwareFrames, "ffmpegFrames": stats.ffmpegFrames,
            "videoToolboxSoftwareFrames": stats.videoToolboxSoftwareFrames]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics), uniformTypeIdentifier: "public.json")
        attachment.name = "human-detect-decode-\(policy.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertNil(decoder.error)
        XCTAssertEqual(positions.count, pictureCount, "Parameter-only samples must not interrupt the following picture/reference chain")
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(positions.last ?? -1, lastPTS, accuracy: 0.00001)
        XCTAssertLessThanOrEqual(zip(positions, positions.dropFirst()).map { $1 - $0 }.max() ?? .infinity, maximumGap)
        if policy == .ffmpeg { XCTAssertEqual(stats.ffmpegFrames, pictureCount); XCTAssertEqual(stats.hardwareFrames, 0) }
        #if !targetEnvironment(simulator)
        if policy == .automatic {
            XCTAssertGreaterThan(stats.hardwareFrames, 0); XCTAssertGreaterThan(stats.ffmpegFrames, 0)
            XCTAssertEqual(stats.videoToolboxSoftwareFrames, 0); XCTAssertEqual(stats.videoToolboxUnverifiedFrames, 0)
        }
        #endif
    }

    func testPaddedStride848Pixels() throws { try checkFormat("padded-848.mp4") }
    func testH264MP4() throws { try checkFormat("internet-h264.mp4") }
    func testHEVCMP4() throws { try checkFormat("internet-hevc.mp4") }
    func testH264AACMP4() throws { try checkFormat("sample.mp4") }
    func testMOV() throws { try checkFormat("h264.mov") }
    func testMKV() throws { try checkFormat("h264.mkv") }
    func testMPEGTS() throws { try checkFormat("h264.ts") }
    func testFLV() throws { try checkFormat("h264.flv") }
    func testWebMVP9() throws { try checkFormat("internet-vp9.webm") }
    func testRawH264() throws { try checkFormat("raw.h264", progress: false) }
    func testRawH265() throws { try checkFormat("raw.h265", progress: false) }
    func testAudioOnlyAAC() throws { try checkFormat("audio.m4a", video: false) }
    func testReviewHEVCHardwareDoesNotHoldDecodedReferenceSurfaces() throws {
        let s = PlaybackSession(url: try fixture("photoprism-tsu-hevc.mp4"), policy: .hardware); sessions.append(s)
        let sink = ReviewPictureOrderSink(); let cadence = ReviewDisplayCadence()
        sink.onFirstFrame = { cadence.start() }; attachVideoSink(sink, to: s.player)
        defer { cadence.stop() }
        s.start()
        try require(until(15) { s.ready || s.failure != nil }, "No ready/error callback")
        #if targetEnvironment(simulator)
        if let e = s.failure as NSError?, e.domain == "FTPlayer.VideoDecoder", e.code == -2001 { throw XCTSkip("Hardware unavailable on Simulator") }
        #endif
        try require(s.failure == nil, "Hardware open failed: \(String(describing: s.failure))")
        try require(until(15) { s.finished > 0 || s.failure != nil }, "Hardware clip did not finish")
        cadence.stop()
        let expected = min(596, cadence.ticks)
        let snapshot = s.player.decoder?.diagnosticSnapshot ?? "missing decoder"
        let metrics: [String: Any] = ["displayTicks": cadence.ticks, "expectedFrames": expected, "renderedFrames": sink.samples.count, "decoder": snapshot, "wallTimes": sink.times]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics), uniformTypeIdentifier: "public.json"); attachment.name = "hevc-hardware-cadence"; attachment.lifetime = .keepAlways; add(attachment)
        FTPlayerDiagnostic.shared.log("HEVC hardware cadence rendered=\(sink.samples.count) displayTicks=\(cadence.ticks) \(snapshot)", category: "test")
        XCTAssertGreaterThan(s.player.videoDecodingStatistics.hardwareFrames, 500)
        XCTAssertGreaterThan(expected, 100)
        XCTAssertGreaterThanOrEqual(sink.samples.count, Int(Double(expected) * 0.85), "Decoded frames were held while a readable reference surface was in use")
    }
    func testReviewHEVCBFramePictureOrderHardware() throws { try checkHEVCPictureOrder(.hardware) }
    func testReviewHEVCBFramePictureOrderFFmpeg() throws { try checkHEVCPictureOrder(.ffmpeg) }
    private func checkHEVCPictureOrder(_ policy: FTVideoDecodingPolicy) throws {
        let raw = try Data(contentsOf: fixture("photoprism-tsu-reference.yuv"))
        let frameSize = 64 * 36 * 3 / 2
        let reference = stride(from: 0, to: raw.count - frameSize + 1, by: frameSize).map { start in
            (0..<(64 * 36)).map { Float(raw[start + $0]) }
        }
        let s = PlaybackSession(url: try fixture("photoprism-tsu-hevc.mp4"), policy: policy); sessions.append(s)
        let sink = ReviewPictureOrderSink(); attachVideoSink(sink, to: s.player); s.start()
        try require(until(15) { s.ready || s.failure != nil }, "No ready/error callback")
        #if targetEnvironment(simulator)
        if policy == .hardware, let error = s.failure as NSError?, error.domain == "FTPlayer.VideoDecoder", error.code == -2001 { throw XCTSkip("Hardware unavailable on Simulator; no fallback counted as hardware pass") }
        #endif
        try require(s.failure == nil, "HEVC open failed: \(String(describing: s.failure))")
        try require(until(15) { s.finished > 0 || s.failure != nil }, "HEVC playback did not finish")
        XCTAssertNil(s.failure)
        let stats = s.player.videoDecodingStatistics
        if policy == .hardware { XCTAssertGreaterThan(stats.hardwareFrames, 0); XCTAssertEqual(stats.ffmpegFrames, 0) }
        else { XCTAssertGreaterThan(stats.ffmpegFrames, 0); XCTAssertEqual(stats.hardwareFrames, 0) }
        s.stop()
        var matches: [Int] = [], errors: [Float] = []
        for sample in sink.samples {
            var best = Float.greatestFiniteMagnitude, bestIndex = -1
            for (index, expected) in reference.enumerated() {
                var distance: Float = 0
                vDSP_distancesq(sample, 1, expected, 1, &distance, vDSP_Length(sample.count))
                if distance < best { best = distance; bestIndex = index }
            }
            matches.append(bestIndex); errors.append(best / Float(sample.count))
        }
        let backward = zip(matches, matches.dropFirst()).filter { $1 < $0 }.count
        let metrics: [String: Any] = ["policy": policy.rawValue, "referenceFrames": reference.count, "renderedFrames": matches.count, "referenceFrameIndices": matches, "pixelMSE": errors, "backwardSteps": backward, "wallTimes": sink.times]
        let data = try JSONSerialization.data(withJSONObject: metrics)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.name = "hevc-picture-order-\(policy.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
        FTPlayerDiagnostic.shared.log("HEVC picture order policy=\(policy.rawValue) rendered=\(matches.count) reference=\(reference.count) backwardSteps=\(backward)", category: "test")
        XCTAssertGreaterThan(matches.count, 100)
        try require(!errors.isEmpty, "No decoded pictures to compare against reference")
        XCTAssertLessThan(errors.sorted()[errors.count / 2], 30, "Hardware pictures did not match independent FFmpeg reference")
        XCTAssertEqual(backward, 0, "Pictures moved backwards in time: \(matches)")
    }
    func testReviewFFmpegConversionHandlesResolutionChange() throws {
        let golden = try JSONDecoder().decode([[Int]].self, from: Data(contentsOf: fixture("resolution-change-golden.json")))
        let s = PlaybackSession(url: try fixture("resolution-change.mjpeg"), policy: .ffmpeg); sessions.append(s)
        let sink = ReviewConversionSink(golden: golden); attachVideoSink(sink, to: s.player); s.start()
        try require(until(6) { sink.largeFrames >= 3 || s.failure != nil }, "Resolution change stopped rendering")
        XCTAssertNil(s.failure)
        XCTAssertGreaterThan(sink.smallFrames, 0)
        FTPlayerDiagnostic.shared.log("review converter smallFrames=\(sink.smallFrames) largeFrames=\(sink.largeFrames) chromaMAE=\(sink.chromaErrors)", category: "test")
        let metrics = try JSONSerialization.data(withJSONObject: ["smallFrames": sink.smallFrames, "largeFrames": sink.largeFrames, "chromaMAE": sink.chromaErrors])
        let attachment = XCTAttachment(data: metrics, uniformTypeIdentifier: "public.json")
        attachment.name = "resolution-change-pixel-metrics"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(sink.chromaErrors.allSatisfy { $0 < 8 }, "Resolution change corrupted NV12 chroma: MAE=\(sink.chromaErrors)")
    }

}

private final class ReviewConversionSink: TestVideoSink {
    let golden: [[Int]]
    var smallFrames = 0, largeFrames = 0
    var chromaErrors: [Double] = []
    init(golden: [[Int]]) { self.golden = golden }
    func didRenderFrame(_ pb: CVPixelBuffer, time: Int64) {
        if CVPixelBufferGetWidth(pb) == 160 { smallFrames += 1; return }
        guard CVPixelBufferGetWidth(pb) == 320 else { return }
        largeFrames += 1
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return }
        let bytes = raw.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        var actual: [Int] = []
        for y in [16, 64, 128, 176] { for x in [16, 64, 128, 192, 256, 304] { for c in [0, 1] { actual.append(Int(bytes[(y / 2) * stride + x + c])) } } }
        let error = golden.map { row in zip(row, actual).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) } / Double(actual.count) }.min() ?? .infinity
        chromaErrors.append(error)
    }
    func didChangeVideoSize(_ size: CGSize) {}
    func didUpdateCurrentTime(_ sec: Double) {}
}

private final class ReviewPictureOrderSink: TestVideoSink {
    var samples: [[Float]] = []
    var times: [Double] = []
    var onFirstFrame: (() -> Void)?
    func didRenderFrame(_ pb: CVPixelBuffer, time: Int64) {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var row: [Float] = []; row.reserveCapacity(64 * 36)
        for y in 0..<36 { for x in 0..<64 { row.append(Float(bytes[((2*y+1)*h/(2*36))*stride + (2*x+1)*w/(2*64)])) } }
        if samples.isEmpty { onFirstFrame?() }
        samples.append(row); times.append(ProcessInfo.processInfo.systemUptime)
    }
    func didChangeVideoSize(_ size: CGSize) {}
    func didUpdateCurrentTime(_ sec: Double) {}
}

private final class ReviewDisplayCadence: NSObject {
    private var link: CADisplayLink?
    var ticks = 0
    func start() { let link = CADisplayLink(target: self, selector: #selector(tick)); self.link = link; link.add(to: .main, forMode: .common) }
    @objc private func tick() { ticks += 1 }
    func stop() { link?.invalidate(); link = nil }
}
