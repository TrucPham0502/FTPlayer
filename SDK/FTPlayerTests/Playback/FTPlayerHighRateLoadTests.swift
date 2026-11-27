import XCTest
import UIKit
import CoreVideo
import libavcodec
import libavformat
@testable import FTPlayer

final class FTPlayerHighRateLoadTests: UnitTestCase {
    @objc func testHighRateFullQueueRefillsBeforeWallBufferRunsOut() throws {
        var codec = try XCTUnwrap(avcodec_alloc_context3(nil)) as UnsafeMutablePointer<AVCodecContext>?
        defer { avcodec_free_context(&codec) }
        codec!.pointee.codec_id = AV_CODEC_ID_MPEG4
        let decoder = FTVideoDecoder(codecContext: codec!, timebase: 1 / 90_000, fps: 30, delegate: nil, policy: .ffmpeg)
        let source = TimelineCoverageFrameSource()
        decoder.source = source; decoder.playbackRate = 16; decoder.maxDecodeDuration = 2
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { decoder.decodeFrameThread(); stopped.signal() }
        defer { decoder.destroy(); XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success); withExtendedLifetime(source) {} }
        for index in 0..<600 {
            let packet = try XCTUnwrap(av_packet_alloc())
            XCTAssertEqual(av_new_packet(packet, 8), 0)
            packet.pointee.pts = Int64(index * 3000); packet.pointee.dts = packet.pointee.pts
            packet.pointee.duration = 3000; packet.pointee.flags = AV_PKT_FLAG_KEY
            decoder.putPacket(packet)
        }
        let end = ProcessInfo.processInfo.systemUptime + 2
        while decoder.frameDuration() < 2 && ProcessInfo.processInfo.systemUptime < end { pump(0.001) }
        XCTAssertGreaterThanOrEqual(decoder.frameDuration(), 2)
        pump(0.005) // The decode worker is in its full-queue wait, with input still queued.
        while let frame = decoder.getFrameAsync() { frame.cancel() }
        let began = ProcessInfo.processInfo.systemUptime
        while decoder.frameEmpty() && ProcessInfo.processInfo.systemUptime - began < 0.2 { pump(0.001) }
        let latency = ProcessInfo.processInfo.systemUptime - began
        print("HIGH_RATE_REFILL_LATENCY=\(latency)")
        XCTAssertFalse(decoder.frameEmpty())
        XCTAssertLessThan(latency, 0.070, "Fixed 100 ms wait uses nearly the entire 125 ms wall-clock buffer at 16x")
    }

    @objc func testHighRateSamplingKeepsDisplayCadence() throws {
        continueAfterFailure = true
        for fps in [24.0, 30, 60] {
            for rate: Float in [4, 8, 16] {
                var codec = try XCTUnwrap(avcodec_alloc_context3(nil)) as UnsafeMutablePointer<AVCodecContext>?
                defer { avcodec_free_context(&codec) }
                codec!.pointee.codec_id = AV_CODEC_ID_MPEG4
                let decoder = FTVideoDecoder(codecContext: codec!, timebase: 1 / 90_000, fps: fps, delegate: nil, policy: .ffmpeg)
                let source = TimelineCoverageFrameSource()
                decoder.source = source
                decoder.playbackRate = rate
                decoder.maxDecodeDuration = 1000
                let stopped = DispatchSemaphore(value: 0)
                DispatchQueue.global().async { decoder.decodeFrameThread(); stopped.signal() }
                defer { decoder.destroy(); XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success); withExtendedLifetime(source) {} }
                // Exactly two wall seconds of decoded output; no sleep, capacity throttle or missing source frames.
                let count = Int(2 * Double(rate) * fps)
                for index in 0..<count {
                    let packet = try XCTUnwrap(av_packet_alloc())
                    XCTAssertEqual(av_new_packet(packet, 8), 0)
                    packet.pointee.pts = Int64((Double(index) * 90_000 / fps).rounded())
                    packet.pointee.dts = packet.pointee.pts
                    packet.pointee.duration = Int64(90_000 / fps)
                    packet.pointee.flags = AV_PKT_FLAG_KEY
                    decoder.putPacket(packet)
                }
                decoder.endOfFile = true
                try require(until(5) { decoder.packetEmpty() && !decoder.decoding }, "Sampling probe did not drain")
                var positions: [Double] = []
                while let frame = decoder.getFrameAsync() { positions.append(frame.position); frame.cancel() }
                XCTAssertEqual(positions.count, 120, accuracy: 1, "\(fps) fps at \(rate)x lost output solely to the sampling grid")
                let wallGaps = zip(positions, positions.dropFirst()).map { ($1 - $0) / Double(rate) }
                XCTAssertLessThanOrEqual(wallGaps.max() ?? 0, 1 / 60 + 1 / fps / Double(rate) + 0.00001)
            }
        }
    }

    /// AOV recordings alternate video-only stretches with events that carry audio. The read-ahead
    /// decodes an event's first PCM while it is still tens of seconds ahead of playback; that
    /// queued future PCM must not count as the playback buffer (seen at 707 s in a cloud recording).
    @objc func testFutureAudioInReadAheadDoesNotRebufferVideoOnlyPlayback() throws {
        let url = try FutureAudioMedia.write(videoSeconds: 80, audioStart: 60)
        defer { try? FileManager.default.removeItem(at: url) }
        final class StateLog: FTPlayerDeletegate {
            var events: [(state: FTPlayerState, progress: TimeInterval)] = []
            func player(_ player: FTPlayer, didChangeState state: FTPlayerState) { events.append((state, player.progress)) }
        }
        let player = FTPlayer(contentURL: url)
        let log = StateLog(); player.delegate = log
        player.rate = 4
        player.replaceVideo()
        defer { player.delegate = nil; player.stop() }
        try require(until(15) { player.state == .playing }, "Playback did not start")
        let started = log.events.count
        // The read-ahead reaches the 60 s audio while playback is near 20 s.
        try require(until(20) { player.progress >= 35 }, "Playback did not reach 35 s, at \(player.progress)")
        let rebuffers = log.events[started...].filter { $0.state == .buffering }.map(\.progress)
        XCTAssertEqual(rebuffers, [], "Queued PCM starting at 60 s rebuffered video-only playback")
    }

    /// Cameras record sparse 1 s stills between denser motion. A still's long duration
    /// must not let it appear half a second before its timestamp (seen at 686 s in a
    /// cloud recording, where the last still then stayed on screen for ~1.5 s).
    @objc func testSparseLongFrameIsNotPresentedBeforeItsTimestamp() throws {
        continueAfterFailure = true
        let dense = (0..<20).map { Double($0) / 10 }
        let times = dense + [2, 3, 4] + dense.map { $0 + 5 }
        let url = try SparseVideoMedia.write(times: times)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = FTPlayer(contentURL: url)
        let sink = PixelSink(); attachVideoSink(sink, to: player)
        player.replaceVideo()
        defer { player.stop() }
        try require(until(15) { sink.lastPresentationTime >= 6 }, "Playback did not reach 6 s, at \(sink.lastPresentationTime) state=\(player.state) frames=\(sink.frames)")
        let shown = sink.presentationEvents(after: 0)
        func wall(_ pts: Double) throws -> Double {
            try XCTUnwrap(shown.first { abs($0.time - pts) < 0.001 }?.wall, "Frame \(pts) was not presented")
        }
        // Wall time between frames must follow their timestamps, within display-tick jitter.
        for (from, to) in [(1.9, 2.0), (2.0, 4.0), (4.0, 5.0), (1.9, 5.0)] {
            XCTAssertEqual(try wall(to) - wall(from), to - from, accuracy: 0.15, "Frame \(to) presented relative to \(from)")
        }
    }

    /// Video-only read-ahead stops at the 50 s load target. Reading must resume as playback
    /// consumes that buffer, not only once it is empty; otherwise playback rebuffered every
    /// ~50 s of content (16× ran at ~15.8× with frames held 50–100 ms longer, also on Mac).
    @objc func testVideoOnlyReadAheadResumesBeforeBufferRunsOut() throws {
        let url = try SparseVideoMedia.write(times: (0..<120).map(Double.init))
        defer { try? FileManager.default.removeItem(at: url) }
        final class StateLog: FTPlayerDeletegate {
            var events: [(state: FTPlayerState, progress: TimeInterval)] = []
            func player(_ player: FTPlayer, didChangeState state: FTPlayerState) { events.append((state, player.progress)) }
        }
        let player = FTPlayer(contentURL: url)
        let log = StateLog(); player.delegate = log
        player.rate = 16
        player.replaceVideo()
        defer { player.delegate = nil; player.stop() }
        try require(until(15) { player.state == .playing }, "Playback did not start")
        let started = log.events.count
        try require(until(30) { player.progress >= 110 }, "Playback did not reach 110 s, at \(player.progress)")
        let rebuffers = log.events[started...].filter { $0.state == .buffering }.map(\.progress)
        XCTAssertEqual(rebuffers, [], "Video-only playback rebuffered after its read-ahead stopped at the load target")
    }

    /// Video-only buffer is refreshed while the reader idles at the load target; at end of
    /// stream that must not end playback early. A 16× run to the tail, then a seek near the
    /// end at 16×, must still finish once with the clock at the duration.
    @objc func testVideoOnlyTailSeekAtHighRateFinishesAtDuration() throws {
        let url = try SparseVideoMedia.write(times: (0..<300).map { Double($0) / 30 })
        defer { try? FileManager.default.removeItem(at: url) }
        final class FinishLog: FTPlayerDeletegate {
            var finished = 0
            func playerDidFinish(_ player: FTPlayer) { finished += 1 }
        }
        let player = FTPlayer(contentURL: url)
        let log = FinishLog(); player.delegate = log
        player.rate = 16
        player.replaceVideo()
        defer { player.delegate = nil; player.stop() }
        try require(until(15) { player.state == .playing }, "Playback did not start")
        let duration = player.duration
        try require(duration > 9, "Unexpected fixture duration \(duration)")
        try require(until(15) { player.currentTime >= duration - 1 || log.finished > 0 }, "16x playback did not reach the tail, at \(player.currentTime)")

        let finishes = log.finished
        player.pause()
        var completed: Bool?
        player.seek(to: duration - 0.5) { completed = $0 }
        try require(until(10) { completed != nil }, "Tail seek callback missing")
        XCTAssertEqual(completed, true)
        player.play()
        try require(until(10) { log.finished > finishes }, "Tail playback at 16x never finished, at \(player.currentTime)")
        pump(0.2)
        XCTAssertEqual(log.finished, finishes + 1)
        XCTAssertEqual(player.state, .finished)
        XCTAssertEqual(player.currentTime, duration, accuracy: 0.001, "Video-only playback finished before reaching its duration")
    }
}

/// Writes a Matroska file: 1 fps raw video for `videoSeconds`, and silent PCM that starts only at
/// `audioStart`, like an AOV recording whose event audio follows a video-only stretch. Each raw
/// frame is ~200 KB, so the 8 MB packet limit holds the read-ahead ~40 s ahead of playback, as
/// with a camera stream, instead of reading the whole local file at startup.
private enum FutureAudioMedia {
    struct Failure: Error { let step: String; let code: Int32 }
    static func check(_ code: Int32, _ step: String) throws { if code < 0 { throw Failure(step: step, code: code) } }
    static let width: Int32 = 480, height: Int32 = 288
    static let sampleRate: Int32 = 8000, samplesPerPacket: Int32 = 128

    static func write(videoSeconds: Int, audioStart: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("future-audio-\(UUID().uuidString).mkv")
        var outputContext: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&outputContext, nil, "matroska", url.path), "output")
        guard let output = outputContext else { throw Failure(step: "output", code: -1) }
        defer { if output.pointee.pb != nil { avio_closep(&output.pointee.pb) }; avformat_free_context(output) }
        guard let video = avformat_new_stream(output, nil), let audio = avformat_new_stream(output, nil),
              let videoParameters = video.pointee.codecpar, let audioParameters = audio.pointee.codecpar else {
            throw Failure(step: "streams", code: -1)
        }
        videoParameters.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        videoParameters.pointee.codec_id = AV_CODEC_ID_RAWVIDEO
        videoParameters.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        videoParameters.pointee.codec_tag = avcodec_pix_fmt_to_codec_tag(AV_PIX_FMT_YUV420P)
        videoParameters.pointee.width = width; videoParameters.pointee.height = height
        video.pointee.time_base = AVRational(num: 1, den: 1000)
        video.pointee.avg_frame_rate = AVRational(num: 1, den: 1)
        audioParameters.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        audioParameters.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
        audioParameters.pointee.format = AV_SAMPLE_FMT_S16.rawValue
        audioParameters.pointee.sample_rate = sampleRate
        audioParameters.pointee.bits_per_coded_sample = 16
        audioParameters.pointee.block_align = 2
        av_channel_layout_default(&audioParameters.pointee.ch_layout, 1)
        audio.pointee.time_base = AVRational(num: 1, den: sampleRate)
        try check(avio_open(&output.pointee.pb, url.path, AVIO_FLAG_WRITE), "open file")
        try check(avformat_write_header(output, nil), "header")

        let lumaBytes = Int(width * height), frameBytes = lumaBytes * 3 / 2
        let audioBytes = Int(samplesPerPacket) * 2
        var sample = Int64(audioStart) * Int64(sampleRate)
        for second in 0..<videoSeconds {
            guard let packet = av_packet_alloc() else { throw Failure(step: "video packet", code: -1) }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&owned) }
            try check(av_new_packet(packet, Int32(frameBytes)), "video data")
            memset(packet.pointee.data, Int32(16 + second % 200), lumaBytes)
            memset(packet.pointee.data + lumaBytes, 128, frameBytes - lumaBytes)
            packet.pointee.stream_index = video.pointee.index
            packet.pointee.pts = av_rescale_q(Int64(second), AVRational(num: 1, den: 1), video.pointee.time_base)
            packet.pointee.dts = packet.pointee.pts
            packet.pointee.duration = av_rescale_q(1, AVRational(num: 1, den: 1), video.pointee.time_base)
            packet.pointee.flags = AV_PKT_FLAG_KEY
            try check(av_interleaved_write_frame(output, packet), "write video")
            // Audio for this second, after its video frame.
            while sample < Int64(second + 1) * Int64(sampleRate) {
                guard let packet = av_packet_alloc() else { throw Failure(step: "audio packet", code: -1) }
                var owned: UnsafeMutablePointer<AVPacket>? = packet
                defer { av_packet_free(&owned) }
                try check(av_new_packet(packet, Int32(audioBytes)), "audio data")
                memset(packet.pointee.data, 0, audioBytes)
                packet.pointee.stream_index = audio.pointee.index
                // The muxer may replace the stream time base in avformat_write_header.
                packet.pointee.pts = av_rescale_q(sample, AVRational(num: 1, den: sampleRate), audio.pointee.time_base)
                packet.pointee.dts = packet.pointee.pts
                packet.pointee.duration = av_rescale_q(Int64(samplesPerPacket), AVRational(num: 1, den: sampleRate), audio.pointee.time_base)
                packet.pointee.flags = AV_PKT_FLAG_KEY
                try check(av_interleaved_write_frame(output, packet), "write audio")
                sample += Int64(samplesPerPacket)
            }
        }
        try check(av_write_trailer(output), "trailer")
        return url
    }
}

/// Writes a video-only QuickTime file of tiny raw frames at the given timestamps. As in MP4,
/// each sample's duration is the gap to the next sample, so a sparse still lasts ~1 s.
private enum SparseVideoMedia {
    struct Failure: Error { let step: String; let code: Int32 }
    static func check(_ code: Int32, _ step: String) throws { if code < 0 { throw Failure(step: step, code: code) } }
    static let width: Int32 = 64, height: Int32 = 64, ticksPerSecond: Int32 = 1000

    static func write(times: [Double]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sparse-video-\(UUID().uuidString).mov")
        var outputContext: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&outputContext, nil, "mov", url.path), "output")
        guard let output = outputContext else { throw Failure(step: "output", code: -1) }
        defer { if output.pointee.pb != nil { avio_closep(&output.pointee.pb) }; avformat_free_context(output) }
        guard let video = avformat_new_stream(output, nil), let parameters = video.pointee.codecpar else {
            throw Failure(step: "stream", code: -1)
        }
        parameters.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        parameters.pointee.codec_id = AV_CODEC_ID_RAWVIDEO
        parameters.pointee.format = AV_PIX_FMT_UYVY422.rawValue // QuickTime "2vuy"; the muxer picks the tag.
        parameters.pointee.width = width; parameters.pointee.height = height
        video.pointee.time_base = AVRational(num: 1, den: ticksPerSecond)
        try check(avio_open(&output.pointee.pb, url.path, AVIO_FLAG_WRITE), "open file")
        try check(avformat_write_header(output, nil), "header")
        let frameBytes = Int(width * height) * 2
        for (index, time) in times.enumerated() {
            guard let packet = av_packet_alloc() else { throw Failure(step: "packet", code: -1) }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&owned) }
            try check(av_new_packet(packet, Int32(frameBytes)), "data")
            memset(packet.pointee.data, Int32(16 + index % 200), frameBytes)
            let next = index + 1 < times.count ? times[index + 1] : time + 0.1
            let ticks = { (seconds: Double) in av_rescale_q(Int64((seconds * Double(ticksPerSecond)).rounded()), AVRational(num: 1, den: ticksPerSecond), video.pointee.time_base) }
            packet.pointee.pts = ticks(time)
            packet.pointee.dts = packet.pointee.pts
            packet.pointee.duration = ticks(next) - ticks(time)
            packet.pointee.flags = AV_PKT_FLAG_KEY
            try check(av_interleaved_write_frame(output, packet), "write")
        }
        try check(av_write_trailer(output), "trailer")
        return url
    }
}
