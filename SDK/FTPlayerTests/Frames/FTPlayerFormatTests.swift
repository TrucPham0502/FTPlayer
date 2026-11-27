import XCTest
import UIKit
import CoreVideo
import libavcodec
import libavformat
@testable import FTPlayer

final class FTPlayerFormatTests: UnitTestCase {
    func testHumanDetectEqualTimestampPicturesKeepDecodeOrder() {
        let queue = FTFrameQueue.frameQueue()
        // The camera emits an IDR then a distinct P picture at 5.273806.
        // Put surrounding frames out of order to exercise timestamp sorting
        // while requiring stable order for pictures sharing the timestamp.
        let before = FTVideoFrame(), idr = FTVideoFrame(), predicted = FTVideoFrame(), after = FTVideoFrame()
        before.position = 5.118690
        idr.position = 5.273806
        predicted.position = idr.position
        after.position = 5.362726
        for frame in [after, idr, before, predicted] {
            frame.duration = 0.076921
            queue.putSortFrame(frame)
        }
        XCTAssertTrue(queue.getFrameAsync() === before)
        XCTAssertTrue(queue.getFrameAsync() === idr, "Equal-PTS P picture overtook the earlier IDR, reversing visible motion")
        XCTAssertTrue(queue.getFrameAsync() === predicted)
        XCTAssertTrue(queue.getFrameAsync() === after)
        XCTAssertEqual(queue.duration, 0, accuracy: 0.000001)
        XCTAssertEqual(queue.count, 0)
    }

    /// Camera stream (2026-11-26): an IDR was lost and the next IDR carried the
    /// PTS of the P picture before it. With gaps_in_frame_num_allowed_flag set,
    /// FFmpeg grows the reorder buffer to 11 and its best_effort_timestamp
    /// switches to packet DTS, which then belongs to a packet 11 frames later.
    /// Pictures must keep their own PTS or video freezes and lags audio.
    func testLostIDRWithDuplicatePTSKeepsPicturePTS() throws {
        let fps: Int32 = 24, gop = 13
        let source = try SyntheticMedia.cached("gop13-h264.mp4") {
            try SyntheticMedia.write(.init(duration: 6, video: .init(fps: fps, gop: Int32(gop), bFrames: 0), audio: nil), to: $0)
        }
        var input: UnsafeMutablePointer<AVFormatContext>?
        try SyntheticMedia.check(avformat_open_input(&input, source.path, nil, nil), "open input")
        defer { avformat_close_input(&input) }
        let stream = try XCTUnwrap(input?.pointee.streams[0])
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        defer { for packet in packets { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) } }
        while true {
            guard let packet = av_packet_alloc() else { break }
            if av_read_frame(input, packet) < 0 { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned); break }
            packets.append(packet)
        }
        let keys = packets.indices.filter { packets[$0].pointee.flags & AV_PKT_FLAG_KEY != 0 }
        try require(keys.count > 4 && keys[3] == 3 * gop && keys[4] == 4 * gop, "Encoder did not place IDRs every \(gop) frames")
        let lostIDR = keys[3], nextIDR = keys[4]
        packets[nextIDR].pointee.pts = packets[nextIDR - 1].pointee.pts
        packets[nextIDR].pointee.dts = packets[nextIDR - 1].pointee.dts
        let lost = packets.remove(at: lostIDR)
        var owned: UnsafeMutablePointer<AVPacket>? = lost; av_packet_free(&owned)

        var context = avcodec_alloc_context3(nil)
        defer { avcodec_free_context(&context) }
        let codec = try XCTUnwrap(context)
        try SyntheticMedia.check(avcodec_parameters_to_context(codec, stream.pointee.codecpar), "parameters")
        try Self.allowFrameNumGaps(codec)
        codec.pointee.pkt_timebase = stream.pointee.time_base
        codec.pointee.thread_count = Int32(min(FTPlayerSDKConfiguration.Demux.maximumCodecThreads, max(1, ProcessInfo.processInfo.activeProcessorCount)))
        try SyntheticMedia.check(avcodec_open2(codec, avcodec_find_decoder(codec.pointee.codec_id), nil), "open decoder")

        let timebase = av_q2d(stream.pointee.time_base)
        let decoder = FTVideoDecoder(codecContext: codec, timebase: timebase, fps: Double(fps), delegate: nil, policy: .ffmpeg)
        decoder.maxDecodeDuration = 100
        for packet in packets { decoder.putPacket(av_packet_clone(packet)) }
        decoder.endOfFile = true
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { decoder.decodeFrameThread(); stopped.signal() }
        defer { decoder.destroy(); XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success) }
        try require(until(20) { decoder.packetEmpty() && !decoder.decoding }, "Decoder did not drain the stream")

        // Each synthetic picture's luma is 40 + its frame index. Pictures of the
        // broken GOP reference the lost IDR, so their content is not checked.
        let broken = Double(lostIDR) / Double(fps)..<Double(nextIDR) / Double(fps)
        var checked = 0, mislabelled: [String] = []
        while let frame = decoder.getFrameAsync() {
            defer { frame.cancel() }
            guard !broken.contains(frame.position + FTPlayerSDKConfiguration.Precision.timestampEpsilon) else { continue }
            let pixel = try XCTUnwrap(frame.pixelBuffer)
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            let row = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, 0)).assumingMemoryBound(to: UInt8.self)
                + CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) * CVPixelBufferGetHeightOfPlane(pixel, 0) / 2
            // The moving bar is 16 px wide, so one row edge always shows background.
            let shown = Int(min(row[1], row[CVPixelBufferGetWidthOfPlane(pixel, 0) - 2])) - 40
            let labelled = Int((frame.position * Double(fps)).rounded())
            if abs(shown - labelled) > 1 { mislabelled.append("\(shown)@\(labelled)") }
            checked += 1
        }
        XCTAssertGreaterThan(checked, packets.count - 2 * gop, "Too few decoded pictures were checked")
        XCTAssertEqual(mislabelled, [], "\(mislabelled.count) of \(checked) pictures were labelled with another frame's time (picture@label)")
    }

    /// Sets gaps_in_frame_num_allowed_flag in the avcC SPS, as the camera does.
    /// VideoToolbox clears it, and FFmpeg then resets its POC history at the gap.
    private static func allowFrameNumGaps(_ codec: UnsafeMutablePointer<AVCodecContext>) throws {
        let extradata = try XCTUnwrap(codec.pointee.extradata)
        guard codec.pointee.extradata_size > 8, extradata[5] & 0x1f >= 1 else { throw PlaybackTestError.assertion("No SPS in avcC") }
        let sps = extradata + 8, size = Int(extradata[6]) << 8 | Int(extradata[7])
        var bit = 8 // after the NAL header
        func read(_ count: Int) -> Int {
            var value = 0
            for _ in 0..<count { value = value << 1 | Int(sps[bit / 8] >> (7 - UInt8(bit % 8)) & 1); bit += 1 }
            return value
        }
        func ue() -> Int { var zeros = 0; while read(1) == 0 { zeros += 1 }; return (1 << zeros) - 1 + read(zeros) }
        let profile = read(8); _ = read(16); _ = ue()
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            if ue() == 3 { _ = read(1) }
            _ = ue(); _ = ue(); _ = read(1)
            guard read(1) == 0 else { throw PlaybackTestError.assertion("SPS scaling lists are not parsed") }
        }
        _ = ue()
        guard ue() == 0 else { throw PlaybackTestError.assertion("Expected pic_order_cnt_type 0") }
        _ = ue(); _ = ue()
        guard bit / 8 < size, !(2..<(bit / 8 + 1)).contains(where: { sps[$0] == 3 && sps[$0 - 1] == 0 && sps[$0 - 2] == 0 }) else {
            throw PlaybackTestError.assertion("SPS emulation prevention before gaps flag")
        }
        sps[bit / 8] |= 0x80 >> UInt8(bit % 8)
    }

    /// A container may declare a packet duration that does not match its samples.
    /// The queued audio duration must be the PCM that will actually play.
    func testAudioFrameDurationComesFromDecodedSamplesNotPacketDuration() throws {
        let sampleRate: Int32 = 48_000, samples: Int32 = 480
        var context = avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_PCM_S16LE))
        defer { avcodec_free_context(&context) }
        let codec = try XCTUnwrap(context)
        codec.pointee.sample_rate = sampleRate
        codec.pointee.sample_fmt = AV_SAMPLE_FMT_S16
        codec.pointee.pkt_timebase = AVRational(num: 1, den: sampleRate)
        av_channel_layout_default(&codec.pointee.ch_layout, 1)
        XCTAssertEqual(avcodec_open2(codec, nil, nil), 0)

        let output = AudioOutput(samplingRate: Float64(sampleRate), channelCount: 1)
        let decoder = FTAudioDecoder.decoder(codecContext: codec, timebase: 1 / Double(sampleRate), delegate: output)
        defer { decoder.destroy() }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let audio = try XCTUnwrap(packet)
        XCTAssertEqual(av_new_packet(audio, samples * 2), 0)
        memset(audio.pointee.data, 0, Int(samples) * 2)
        audio.pointee.pts = 0
        audio.pointee.dts = 0
        audio.pointee.duration = Int64(samples) * 10 // Declared 0.1 s; the payload holds 0.01 s.

        XCTAssertEqual(decoder.putPacket(audio), 0)
        let frame = try XCTUnwrap(decoder.peekFrame())
        XCTAssertEqual(frame.duration, 0.01, accuracy: 0.000001)
        XCTAssertEqual(decoder.duration(), 0.01, accuracy: 0.000001)
    }

    private final class AudioOutput: FTAudioDecoderDelegate {
        let samplingRate: Float64, channelCount: UInt32
        init(samplingRate: Float64, channelCount: UInt32) {
            self.samplingRate = samplingRate
            self.channelCount = channelCount
        }
        func audioDecoder(_ audioDecoder: FTAudioDecoder, samplingRate: inout Float64) { samplingRate = self.samplingRate }
        func audioDecoder(_ audioDecoder: FTAudioDecoder, channelCount: inout UInt32) { channelCount = self.channelCount }
    }
}

/// Container and codec coverage on media generated at test time.
final class FTPlayerFormatPlaybackTests: MediaTestCase {
    private func generated(_ name: String, _ spec: SyntheticMedia.Spec) throws -> URL {
        try SyntheticMedia.cached(name) { try SyntheticMedia.write(spec, to: $0) }
    }
    /// 848 px rows are padded by CoreVideo, so conversion must honour the plane stride.
    private func padded848() throws -> URL {
        try generated("padded-848.mp4", .init(duration: 6, video: .init(width: 848, height: 480), audio: nil))
    }

    func testPaddedStride848Pixels() throws { try checkFormat(try padded848()) }
    func testH264MP4() throws {
        try checkFormat(try generated("h264-video.mp4", .init(duration: 10, audio: nil)))
    }
    func testHEVCMP4() throws {
        try checkFormat(try generated("hevc.mp4", .init(duration: 10, video: .init(codec: .hevc))))
    }
    func testH264AACMP4() throws { try checkFormat(try SyntheticMedia.sample()) }
    func testMOV() throws { try checkFormat(try SyntheticMedia.sample(as: "h264.mov", format: "mov")) }
    func testMKV() throws { try checkFormat(try SyntheticMedia.sample(as: "h264.mkv", format: "matroska")) }
    func testMPEGTS() throws { try checkFormat(try SyntheticMedia.sample(as: "h264.ts", format: "mpegts")) }
    func testFLV() throws { try checkFormat(try SyntheticMedia.sample(as: "h264.flv", format: "flv")) }
    func testRawH264() throws {
        try checkFormat(try SyntheticMedia.sample(as: "raw.h264", format: "h264", audio: false), progress: false)
    }
    func testRawH265() throws {
        let spec = SyntheticMedia.Spec(format: "hevc", fileExtension: "h265", duration: 10, video: .init(codec: .hevc), audio: nil)
        try checkFormat(try generated("raw.h265", spec), progress: false)
    }
    func testAudioOnlyAAC() throws {
        try checkFormat(try SyntheticMedia.sample(as: "audio.m4a", format: "ipod", video: false), video: false)
    }

    func testSeparateAVCCParameterPacketsApplyNewResolutionAtNextPicture() throws {
        let initial = FTFormatContext(contentURL: try SyntheticMedia.sample(), videoFormat: .unknown)
        let changed = FTFormatContext(contentURL: try padded848(), videoFormat: .unknown)
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
        try require(config.count >= 7 && config[0] == 1, "Expected AVCC configuration")
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
}
