import Foundation
import libavcodec
import libavformat
import libavutil
@testable import FTPlayer

/// Generates media for SDK tests with the linked FFmpeg encoders and muxers, so
/// player tests never depend on downloaded or bundled video files.
enum SyntheticMedia {
    struct Failure: Error, CustomStringConvertible {
        let step: String, code: Int32
        var description: String { "SyntheticMedia \(step) failed (\(code))" }
    }
    enum VideoCodec { case h264, hevc, mpeg4, mjpeg }
    enum AudioCodec { case aac, mp2, pcmS16BE }
    struct Video {
        var codec: VideoCodec = .h264
        var width: Int32 = 640, height: Int32 = 360
        var fps: Int32 = 24
        /// Frames between keyframes. sample.mp4 had about 1.2 s at 24 fps.
        var gop: Int32 = 29
        var bFrames: Int32 = 2
    }
    struct Audio {
        var codec: AudioCodec = .aac
        var sampleRate: Int32 = 44_100
        var channels: Int32 = 1
        /// Peak of the sine tone, as a fraction of full scale.
        var amplitude: Double = 0.25
        var frequency: Double = 440
    }
    struct Spec {
        var format: String = "mp4"
        var fileExtension: String = "mp4"
        var duration: Double = 30
        var video: Video? = Video()
        var audio: Audio? = Audio()
        /// Audio stops here while video continues; 0 keeps a declared audio track without packets.
        var audioDuration: Double?
        var muxerOptions: [String: String] = [:]
    }

    private static let lock = NSLock()
    private static var cache: [String: URL] = [:]
    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftplayer-synthetic-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Same shape as the former sample.mp4: H.264 High 640x360 24 fps with
    /// B-frames, AAC LC 44.1 kHz mono, 30 s.
    static func sample() throws -> URL { try cached("sample.mp4") { try write(Spec(), to: $0) } }

    /// Same media as `sample()`, 160 s long, for seeks deep into the file.
    static func sustained() throws -> URL { try cached("sustained-h264-aac.mp4") { try write(Spec(duration: 160), to: $0) } }

    /// Builds a file once per test process and returns the same URL afterwards.
    static func cached(_ name: String, _ build: (URL) throws -> Void) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if let url = cache[name] { return url }
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try build(url)
        cache[name] = url
        return url
    }

    static func check(_ code: Int32, _ step: String) throws { if code < 0 { throw Failure(step: step, code: code) } }

    // MARK: - Encoding

    static func write(_ spec: Spec, to url: URL) throws {
        var outputContext: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&outputContext, nil, spec.format, url.path), "output \(spec.format)")
        guard let output = outputContext else { throw Failure(step: "output", code: -1) }
        defer { if output.pointee.pb != nil { avio_closep(&output.pointee.pb) }; avformat_free_context(output) }
        let globalHeader = (output.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER) != 0

        var video: Encoder?, audio: Encoder?
        if let v = spec.video { video = try Encoder(video: v, output: output, globalHeader: globalHeader) }
        if let a = spec.audio { audio = try Encoder(audio: a, output: output, globalHeader: globalHeader) }
        defer { video?.close(); audio?.close() }

        if output.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 {
            try check(avio_open(&output.pointee.pb, url.path, AVIO_FLAG_WRITE), "open file")
        }
        var options: OpaquePointer?
        for (key, value) in spec.muxerOptions { av_dict_set(&options, key, value, 0) }
        defer { av_dict_free(&options) }
        try check(avformat_write_header(output, &options), "header")

        let frameCount = spec.video.map { Int((spec.duration * Double($0.fps)).rounded()) } ?? 0
        let sampleCount = spec.audio.map { Int64(((spec.audioDuration ?? spec.duration) * Double($0.sampleRate)).rounded()) } ?? 0
        var videoIndex = 0
        var audioSample: Int64 = 0
        // Feed the encoders in timestamp order so the muxer receives interleaved packets.
        while true {
            let videoTime = video.map { _ in Double(videoIndex) / Double(spec.video!.fps) } ?? .infinity
            let audioTime = audio.map { _ in Double(audioSample) / Double(spec.audio!.sampleRate) } ?? .infinity
            let videoDone = video == nil || videoIndex >= frameCount
            let audioDone = audio == nil || audioSample >= sampleCount
            if videoDone && audioDone { break }
            if !videoDone && (audioDone || videoTime <= audioTime) {
                try video!.encodeVideo(index: videoIndex, spec: spec.video!, output: output)
                videoIndex += 1
            } else {
                audioSample += try audio!.encodeAudio(start: audioSample, total: sampleCount, spec: spec.audio!, output: output)
            }
        }
        try video?.flush(output: output)
        try audio?.flush(output: output)
        try check(av_write_trailer(output), "trailer")
    }

    private final class Encoder {
        let context: UnsafeMutablePointer<AVCodecContext>
        let stream: UnsafeMutablePointer<AVStream>
        let frame: UnsafeMutablePointer<AVFrame>
        let packet: UnsafeMutablePointer<AVPacket>

        init(video: Video, output: UnsafeMutablePointer<AVFormatContext>, globalHeader: Bool) throws {
            let name: String, format: AVPixelFormat
            switch video.codec {
            case .h264: name = "h264_videotoolbox"; format = AV_PIX_FMT_NV12
            case .hevc: name = "hevc_videotoolbox"; format = AV_PIX_FMT_NV12
            case .mpeg4: name = "mpeg4"; format = AV_PIX_FMT_YUV420P
            case .mjpeg: name = "mjpeg"; format = AV_PIX_FMT_YUVJ420P
            }
            guard let codec = avcodec_find_encoder_by_name(name) else { throw Failure(step: "find \(name)", code: -1) }
            guard let context = avcodec_alloc_context3(codec) else { throw Failure(step: "context \(name)", code: -1) }
            self.context = context
            context.pointee.width = video.width
            context.pointee.height = video.height
            context.pointee.pix_fmt = format
            context.pointee.time_base = AVRational(num: 1, den: video.fps)
            context.pointee.framerate = AVRational(num: video.fps, den: 1)
            context.pointee.gop_size = video.gop
            context.pointee.max_b_frames = video.codec == .mjpeg ? 0 : video.bFrames
            context.pointee.bit_rate = Int64(video.width) * Int64(video.height) * 2
            if video.codec == .mjpeg { context.pointee.color_range = AVCOL_RANGE_JPEG }
            if globalHeader { context.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER }
            var options: OpaquePointer?
            if video.codec == .h264 { av_dict_set(&options, "profile", "high", 0) }
            if video.codec == .h264 || video.codec == .hevc { av_dict_set(&options, "realtime", "0", 0) }
            defer { av_dict_free(&options) }
            try SyntheticMedia.check(avcodec_open2(context, codec, &options), "open \(name)")
            guard let stream = avformat_new_stream(output, nil) else { throw Failure(step: "video stream", code: -1) }
            self.stream = stream
            stream.pointee.time_base = context.pointee.time_base
            stream.pointee.avg_frame_rate = context.pointee.framerate
            try SyntheticMedia.check(avcodec_parameters_from_context(stream.pointee.codecpar, context), "video parameters")
            guard let frame = av_frame_alloc(), let packet = av_packet_alloc() else { throw Failure(step: "alloc", code: -1) }
            self.frame = frame; self.packet = packet
            frame.pointee.format = format.rawValue
            frame.pointee.width = video.width
            frame.pointee.height = video.height
            try SyntheticMedia.check(av_frame_get_buffer(frame, 0), "video buffer")
        }

        init(audio: Audio, output: UnsafeMutablePointer<AVFormatContext>, globalHeader: Bool) throws {
            let id: AVCodecID, format: AVSampleFormat
            switch audio.codec {
            case .aac: id = AV_CODEC_ID_AAC; format = AV_SAMPLE_FMT_FLTP
            case .mp2: id = AV_CODEC_ID_MP2; format = AV_SAMPLE_FMT_S16
            case .pcmS16BE: id = AV_CODEC_ID_PCM_S16BE; format = AV_SAMPLE_FMT_S16
            }
            guard let codec = avcodec_find_encoder(id) else { throw Failure(step: "find audio", code: -1) }
            guard let context = avcodec_alloc_context3(codec) else { throw Failure(step: "audio context", code: -1) }
            self.context = context
            context.pointee.sample_fmt = format
            context.pointee.sample_rate = audio.sampleRate
            av_channel_layout_default(&context.pointee.ch_layout, audio.channels)
            context.pointee.bit_rate = 64_000 * Int64(audio.channels)
            context.pointee.time_base = AVRational(num: 1, den: audio.sampleRate)
            if globalHeader { context.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER }
            try SyntheticMedia.check(avcodec_open2(context, codec, nil), "open audio")
            guard let stream = avformat_new_stream(output, nil) else { throw Failure(step: "audio stream", code: -1) }
            self.stream = stream
            stream.pointee.time_base = context.pointee.time_base
            try SyntheticMedia.check(avcodec_parameters_from_context(stream.pointee.codecpar, context), "audio parameters")
            guard let frame = av_frame_alloc(), let packet = av_packet_alloc() else { throw Failure(step: "alloc", code: -1) }
            self.frame = frame; self.packet = packet
            frame.pointee.format = format.rawValue
            frame.pointee.sample_rate = audio.sampleRate
            try SyntheticMedia.check(av_channel_layout_copy(&frame.pointee.ch_layout, &context.pointee.ch_layout), "layout")
            frame.pointee.nb_samples = context.pointee.frame_size > 0 ? context.pointee.frame_size : 1024
            try SyntheticMedia.check(av_frame_get_buffer(frame, 0), "audio buffer")
        }

        func close() {
            var c: UnsafeMutablePointer<AVCodecContext>? = context; avcodec_free_context(&c)
            var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f)
            var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p)
        }

        /// Each frame differs (moving bar, changing brightness) so content-change
        /// measurement and per-frame inspection see real motion.
        func encodeVideo(index: Int, spec: Video, output: UnsafeMutablePointer<AVFormatContext>) throws {
            try SyntheticMedia.check(av_frame_make_writable(frame), "writable")
            let width = Int(spec.width), height = Int(spec.height)
            let luma = frame.pointee.data.0!, lumaStride = Int(frame.pointee.linesize.0)
            let background = UInt8(40 + index % 160)
            let bar = (index * 8) % max(width - 16, 1)
            for y in 0..<height {
                let row = luma + y * lumaStride
                memset(row, Int32(background), width)
                memset(row + bar, 235, 16)
            }
            if frame.pointee.format == AV_PIX_FMT_NV12.rawValue {
                let chroma = frame.pointee.data.1!, stride = Int(frame.pointee.linesize.1)
                for y in 0..<(height / 2) { memset(chroma + y * stride, 128, width) }
            } else {
                for plane in 1...2 {
                    let data = plane == 1 ? frame.pointee.data.1! : frame.pointee.data.2!
                    let stride = Int(plane == 1 ? frame.pointee.linesize.1 : frame.pointee.linesize.2)
                    for y in 0..<(height / 2) { memset(data + y * stride, 128, width / 2) }
                }
            }
            frame.pointee.pts = Int64(index)
            try SyntheticMedia.check(avcodec_send_frame(context, frame), "send video")
            try drain(output)
        }

        /// Returns the number of samples encoded.
        func encodeAudio(start: Int64, total: Int64, spec: Audio, output: UnsafeMutablePointer<AVFormatContext>) throws -> Int64 {
            try SyntheticMedia.check(av_frame_make_writable(frame), "writable")
            let count = Int(min(Int64(frame.pointee.nb_samples), total - start))
            let channels = Int(spec.channels)
            for i in 0..<count {
                let t = Double(start + Int64(i)) / Double(spec.sampleRate)
                let value = spec.amplitude * sin(2 * .pi * spec.frequency * t)
                if spec.codec == .aac {
                    for c in 0..<channels {
                        frame.pointee.extended_data[c]!.withMemoryRebound(to: Float.self, capacity: count) { $0[i] = Float(value) }
                    }
                } else {
                    frame.pointee.data.0!.withMemoryRebound(to: Int16.self, capacity: count * channels) {
                        for c in 0..<channels { $0[i * channels + c] = Int16(value * Double(Int16.max)) }
                    }
                }
            }
            // Fixed-size encoders need full frames: pad the tail with silence.
            if count < Int(frame.pointee.nb_samples) {
                av_samples_set_silence(frame.pointee.extended_data, Int32(count), frame.pointee.nb_samples - Int32(count),
                                       spec.channels, AVSampleFormat(frame.pointee.format))
            }
            frame.pointee.pts = start
            try SyntheticMedia.check(avcodec_send_frame(context, frame), "send audio")
            try drain(output)
            return Int64(count)
        }

        func flush(output: UnsafeMutablePointer<AVFormatContext>) throws {
            try SyntheticMedia.check(avcodec_send_frame(context, nil), "flush")
            try drain(output)
        }

        private func drain(_ output: UnsafeMutablePointer<AVFormatContext>) throws {
            while true {
                let result = avcodec_receive_packet(context, packet)
                if result == FT_AVERROR_EOF || result == AVERROR(EAGAIN) { return }
                try SyntheticMedia.check(result, "receive")
                av_packet_rescale_ts(packet, context.pointee.time_base, stream.pointee.time_base)
                packet.pointee.stream_index = stream.pointee.index
                try SyntheticMedia.check(av_interleaved_write_frame(output, packet), "write")
            }
        }
    }

    // MARK: - Remuxing

    /// Copies streams of `source` into another container (TS, MKV, FLV, MOV,
    /// raw Annex B, HLS…) without re-encoding.
    static func remux(_ source: URL, to url: URL, format: String, video: Bool = true, audio: Bool = true,
                      options: [String: String] = [:]) throws {
        var inputContext: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_open_input(&inputContext, source.path, nil, nil), "open input")
        defer { avformat_close_input(&inputContext) }
        guard let input = inputContext else { throw Failure(step: "input", code: -1) }
        try check(avformat_find_stream_info(input, nil), "stream info")
        var outputContext: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&outputContext, nil, format, url.path), "output \(format)")
        guard let output = outputContext else { throw Failure(step: "output", code: -1) }
        defer { if output.pointee.pb != nil { avio_closep(&output.pointee.pb) }; avformat_free_context(output) }
        var mapping = [Int32](repeating: -1, count: Int(input.pointee.nb_streams))
        for index in 0..<Int(input.pointee.nb_streams) {
            let stream = input.pointee.streams[index]!
            let type = stream.pointee.codecpar.pointee.codec_type
            guard (type == AVMEDIA_TYPE_VIDEO && video) || (type == AVMEDIA_TYPE_AUDIO && audio) else { continue }
            guard let copy = avformat_new_stream(output, nil) else { throw Failure(step: "stream", code: -1) }
            try check(avcodec_parameters_copy(copy.pointee.codecpar, stream.pointee.codecpar), "parameters")
            copy.pointee.codecpar.pointee.codec_tag = 0
            copy.pointee.time_base = stream.pointee.time_base
            mapping[index] = copy.pointee.index
        }
        if output.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 {
            try check(avio_open(&output.pointee.pb, url.path, AVIO_FLAG_WRITE), "open file")
        }
        var dictionary: OpaquePointer?
        for (key, value) in options { av_dict_set(&dictionary, key, value, 0) }
        defer { av_dict_free(&dictionary) }
        try check(avformat_write_header(output, &dictionary), "header")
        guard let packet = av_packet_alloc() else { throw Failure(step: "packet", code: -1) }
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&owned) }
        while av_read_frame(input, packet) >= 0 {
            defer { av_packet_unref(packet) }
            let target = mapping[Int(packet.pointee.stream_index)]
            guard target >= 0 else { continue }
            av_packet_rescale_ts(packet, input.pointee.streams[Int(packet.pointee.stream_index)]!.pointee.time_base,
                                 output.pointee.streams[Int(target)]!.pointee.time_base)
            packet.pointee.stream_index = target
            packet.pointee.pos = -1
            try check(av_interleaved_write_frame(output, packet), "write")
        }
        try check(av_write_trailer(output), "trailer")
    }

    /// The sample remuxed into another container, cached per process.
    static func sample(as name: String, format: String, video: Bool = true, audio: Bool = true,
                       options: [String: String] = [:]) throws -> URL {
        let source = try sample()
        return try cached(name) { try remux(source, to: $0, format: format, video: video, audio: audio, options: options) }
    }
}
