//
//  FTFormatContext.swift
//
//
//  Edited by TP on 2024/7/12.
//

import Foundation
import CoreGraphics
@_implementationOnly import libavcodec
@_implementationOnly import libavformat
@_implementationOnly import libavutil
protocol FTFormatContextDelegate: AnyObject {
    func formatContextNeedInterrupt(_ formatContext: FTFormatContext) -> Bool
}

class FTFormatContext {
    weak var delegate: FTFormatContextDelegate?

    private(set) var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private(set) var videoCodecContext: UnsafeMutablePointer<AVCodecContext>?
    private(set) var audioCodecContext: UnsafeMutablePointer<AVCodecContext>?
    private var randomAccessParser: UnsafeMutablePointer<AVCodecParserContext>?
    private var randomAccessParserCodec: UnsafeMutablePointer<AVCodecContext>?
    private var randomAccessParserAttempted = false
    private var randomAccessMetadataCorrected = false
    private var verifiedMP4Anchors: [(position: Double, dts: Int64)] = []
    private var verifiedMP4CoveredThrough = 0.0
    private var cacheIOContext: FTCacheIOContext?
    private var independentHLS: (any HLSCaching)?
    private var independentNeedsReopen = false
    private struct HLSSeekAnchor {
        let position: Double
        let timestamp: Int64
        let streamTimestamp: Int64
        var coveredThrough: Double
    }
    private var nativeHLS = false
    private var nativeHLSAnchors: [HLSSeekAnchor] = []
    private var nativeHLSActiveAnchor: Int?
    private var independentStartTime: TimeInterval = 0
    private var independentBitrate: Double = 0
    private var inputTimeoutSeconds = FTPlayerSDKConfiguration.Demux.initialInputTimeoutSeconds
    var loadControlConfiguration = FTPlayerLoadControlConfiguration()
    func setPlaybackPosition(_ value: Double) {
        cacheIOContext?.setPlaybackPosition(value); independentHLS?.setPlaybackPosition(value)
    }
    var playbackRate: Float = FTPlayerSDKConfiguration.Playback.defaultRate { didSet { independentHLS?.setPlaybackRate(playbackRate) } }
    private let playlistLoader: any HTTPDataLoading
    private var cacheSession: (any PlaybackCacheSession)?
    private let ownsCacheSession: Bool
    private let cacheSessionRevision: Int?

    private var contentURL: URL
    private var videoFormat: FTVideoFormat
    private(set) var error: NSError?
    private(set) var metadata: [AnyHashable: Any] = [:]
    var cacheDiagnostics: [String: Int64] { independentHLS?.diagnostics ?? cacheIOContext?.diagnosticSnapshot ?? [:] }
    var cachedFraction: Double {
        if let hls = independentHLS { return hls.fraction }
        guard cacheTimelineLock.withLock({ reportsFileCacheProgress }) else { return 0 }
        return cacheIOContext?.cachedFraction ?? 0
    }
    var isWaitingForCacheNetwork: Bool { independentHLS?.waiting ?? cacheIOContext?.isWaitingForNetwork ?? false }
    private let cacheTimelineLock = NSLock()
    private var reportsFileCacheProgress = false
    private var cacheTimelineIndex = CacheTimelineIndex(tracks: [], duration: 0)
    private var _cachedTimeRanges: [FTPlayerCachedTimeRange] = []
    var cachedTimeRanges: [FTPlayerCachedTimeRange] { independentHLS?.ranges ?? cacheTimelineLock.withLock { _cachedTimeRanges } }
    var onDownloadProgress: ((Double) -> Void)?
    var onPreparationState: ((FTPlayerPreparationState) -> Void)?

    var mediaInfo: FTPlayerMediaInfo? {
        guard let context = formatContext else { return nil }
        func positive<T: FixedWidthInteger>(_ value: T) -> T? { value > 0 ? value : nil }
        let video = videoCodecContext?.pointee
        let audio = audioCodecContext?.pointee
        let stream = videoTrack.flatMap { context.pointee.streams[$0.index] }
        let frameRate = stream.flatMap { pointer -> Double? in
            let average = pointer.pointee.avg_frame_rate, nominal = pointer.pointee.r_frame_rate
            if average.num > 0 && average.den > 0 { return Double(average.num) / Double(average.den) }
            if nominal.num > 0 && nominal.den > 0 { return Double(nominal.num) / Double(nominal.den) }
            return nil
        }
        let knownDuration = duration.isFinite && duration > 0 && duration < Double(Float.greatestFiniteMagnitude) ? duration : nil
        let nativeName = context.pointee.iformat.flatMap { $0.pointee.name }.map { String(cString: $0) } ?? "unknown"
        return FTPlayerMediaInfo(sourceURL: contentURL, formatName: independentHLS == nil ? nativeName : "hls", duration: knownDuration,
            bitrate: positive(context.pointee.bit_rate),
            videoCodec: video.map { String(cString: avcodec_get_name($0.codec_id)) },
            width: video.flatMap { positive(Int($0.width)) }, height: video.flatMap { positive(Int($0.height)) },
            framesPerSecond: frameRate,
            videoBitrate: video.flatMap { positive($0.bit_rate) },
            audioCodec: audio.map { String(cString: avcodec_get_name($0.codec_id)) },
            audioSampleRate: audio.flatMap { positive(Int($0.sample_rate)) },
            audioChannels: audio.flatMap { positive(Int($0.ch_layout.nb_channels)) },
            audioBitrate: audio.flatMap { positive($0.bit_rate) },
            videoTrackCount: videoTracks.count, audioTrackCount: audioTracks.count)
    }

    var startTime: TimeInterval {
        if independentHLS != nil { return independentStartTime }
        guard let value = formatContext?.pointee.start_time, value != FT_AV_NOPTS_VALUE else { return 0 }
        return Double(value) / Double(AV_TIME_BASE)
    }

    var bitrate: TimeInterval {
        if independentHLS != nil { return independentBitrate }
        guard let formatContext = formatContext else {
            return 0
        }
        return Double(formatContext.pointee.bit_rate) / 1000.0
    }
    var duration: TimeInterval {
        if let hls = independentHLS { return hls.duration }
        guard let formatContext = formatContext else {
            return 0
        }
        guard formatContext.pointee.duration != FT_AV_NOPTS_VALUE else {
            return TimeInterval(MAXFLOAT)
        }
        return Double(formatContext.pointee.duration) / Double(AV_TIME_BASE)
    }
    /// Only a progressive file's selected stream has a stable, source-wide end.
    /// Concat/HLS child stream durations must not be mistaken for playlist ends.
    var knownProgressiveVideoEndTime: TimeInterval? {
        guard independentHLS == nil, !nativeHLS, let context = formatContext, let track = videoTrack,
              let stream = context.pointee.streams[track.index], stream.pointee.duration > 0,
              stream.pointee.duration != FT_AV_NOPTS_VALUE else { return nil }
        let scale = Double(stream.pointee.time_base.num) / Double(stream.pointee.time_base.den)
        let start = stream.pointee.start_time == FT_AV_NOPTS_VALUE ? 0 : Double(stream.pointee.start_time) * scale - startTime
        let end = start + Double(stream.pointee.duration) * scale
        return end.isFinite && end > 0 ? end : nil
    }
    private(set) var videoEnable: Bool = false
    private(set) var audioEnable: Bool = false
    private(set) var videoTrack: FTTrack?
    private(set) var audioTrack: FTTrack?
    private(set) var videoTracks: [FTTrack] = []
    private(set) var audioTracks: [FTTrack] = []
    private(set) var videoTimebase: TimeInterval = 0
    private(set) var videoFPS: TimeInterval = 0
    private(set) var videoPresentationSize: CGSize = .zero
    private(set) var videoAspect: CGFloat = 0
    private(set) var audioTimebase: TimeInterval = 0

    static func supportsInputFormat(_ name: String) -> Bool { av_find_input_format(name) != nil }

    init(contentURL: URL, videoFormat: FTVideoFormat, cacheSession: (any PlaybackCacheSession)? = nil, cacheSessionRevision: Int? = nil, playlistLoader: any HTTPDataLoading = HTTPDataLoader()) {
        self.playlistLoader = playlistLoader
        self.cacheSession = cacheSession
        self.cacheSessionRevision = cacheSessionRevision
        self.ownsCacheSession = cacheSession == nil
        self.contentURL = contentURL
        self.videoFormat = videoFormat
    }

    func setupSync(timeoutSeconds: Int = FTPlayerSDKConfiguration.Demux.defaultSetupTimeoutSeconds, useCache: Bool = FTPlayerSDKConfiguration.Demux.cacheEnabledByDefault) {
        self.error = openInput(timeoutSeconds: timeoutSeconds, useCache: useCache)
        if error != nil { return }

        onPreparationState?(.selectingTracks)
        openTracks()
        onPreparationState?(.tracksSelected)
        Console.log("streams video=\(videoTracks.count) audio=\(audioTracks.count) duration=\(duration) bitrate=\(bitrate)")
        if !videoTracks.isEmpty { onPreparationState?(.openingVideoCodec) }
        let videoError = openVideoTrack()
        if !audioTracks.isEmpty { onPreparationState?(.openingAudioCodec) }
        let audioError = openAudioTrack()
        onPreparationState?(.indexingCache)
        snapshotCacheTimeline()
        refreshCacheTimeline()
        configureCacheLoadControl()
        onPreparationState?(.cacheIndexed)

        guard let videoError = videoError, let audioError = audioError else {
            return
        }

        if videoError.code == FTDecoderErrorCode.streamNotFound.rawValue && audioError.code != FTDecoderErrorCode.streamNotFound.rawValue {
            self.error = audioError
        } else {
            self.error = videoError
        }
        return
    }

    private func configureNetworkRecovery(_ options: inout OpaquePointer?) {
        // Resume a seekable HTTP body at the last received byte after a socket/TLS
        // close. Re-seeking the demuxer alone can keep retrying the broken socket.
        // Do not reconnect at real EOF, or retry permanent HTTP status failures.
        for option in FTPlayerSDKConfiguration.Network.ffmpegRecoveryOptions {
            av_dict_set(&options, option.key, option.value, 0)
        }
    }

    private func openInput(timeoutSeconds: Int, useCache: Bool = FTPlayerSDKConfiguration.Demux.cacheEnabledByDefault) -> NSError? {
        inputTimeoutSeconds = timeoutSeconds
        let beganOpening = ProcessInfo.processInfo.systemUptime
        var result: Int32 = 0
        var error: NSError?
        defer {
            if error != nil { cacheIOContext?.cancelRead(); independentHLS?.cancelReads() }
            cacheIOContext?.finishOpening(); independentHLS?.finishOpening()
        }

        self.formatContext = avformat_alloc_context()
        if formatContext == nil {
            result = -1
            error = NSError(domain: "FTDecoderErrorCodeFormatCreate error", code: Int(FTDecoderErrorCode.formatCreate.rawValue), userInfo: nil)
            return error
        }

        onPreparationState?(.formatContextAllocated)
        formatContext?.pointee.interrupt_callback.callback = ffmpeg_interrupt_callback
        formatContext?.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(self).toOpaque()

        var opts = AVDictionary(rawPointer: nil)
        
        av_dict_set(&opts.rawPointer, "timeout", "\(timeoutSeconds*1000000)", 0)
        av_dict_set(&opts.rawPointer, "rw_timeout", "\(timeoutSeconds*1000000)", 0)
        configureNetworkRecovery(&opts.rawPointer)
        
        if videoFormat == .rtsp {
            let ret = av_dict_set(&opts.rawPointer, "rtsp_transport", FTPlayerSDKConfiguration.Network.rtspTransport, 0)
            if ret < 0 {
            }
        }

        let scheme = contentURL.scheme ?? ""
        // Segmented manifests need their base URL for relative segment and key requests.
        let segmented = videoFormat == .m3u8 || contentURL.pathExtension.lowercased() == "mpd"
        onPreparationState?(.connectingToSource)
        if (videoFormat == .m3u8 || contentURL.pathExtension.lowercased() == "m3u8"), ["http", "https"].contains(scheme) {
            do {
                result = try openHLSInput(timeoutSeconds: timeoutSeconds, beganOpening: beganOpening, useCache: useCache, options: &opts.rawPointer)
            } catch let creationError {
                av_dict_free(&opts.rawPointer); avformat_free_context(formatContext); formatContext = nil
                error = creationError as NSError; return error
            }
        } else if useCache, !segmented, scheme == "http" || scheme == "https" {
            do {
                let ioCtx = try makeIOContext()
                cacheIOContext = ioCtx
                ioCtx.beginOpening(timeout: TimeInterval(timeoutSeconds))
                // Keep unknown URLs on the same HLS path as .m3u8 URLs. A
                // playlist alone must never count as a fully cached video.
                if ioCtx.hasHLSHeader() {
                    defer { ioCtx.close(); cacheIOContext = nil }
                    result = try openHLSInput(timeoutSeconds: timeoutSeconds, beganOpening: beganOpening, useCache: useCache, options: &opts.rawPointer,
                                              loader: FTCachedPlaylistLoader(cache: ioCtx, fallback: playlistLoader))
                } else {
                    formatContext?.pointee.pb = ioCtx.context
                    formatContext?.pointee.flags |= 0x0080  // AVFMT_FLAG_CUSTOM_IO
                    cacheTimelineLock.withLock { reportsFileCacheProgress = true }
                    onDownloadProgress?(ioCtx.cachedFraction)
                    result = avformat_open_input(&formatContext, contentURL.absoluteString, nil, &opts.rawPointer)
                }
            } catch let creationError {
                av_dict_free(&opts.rawPointer)
                avformat_free_context(formatContext); formatContext = nil
                error = creationError as NSError
                return error
            }
        } else {
            result = avformat_open_input(&formatContext, contentURL.absoluteString, nil, &opts.rawPointer)
        }
        av_dict_free(&opts.rawPointer)
        error = inputError(result, stage: FTDecoderErrorCode.formatOpenInput.rawValue)
        if error != nil || formatContext == nil {
            if formatContext != nil {
                avformat_close_input(&formatContext)
            }
            return error
        }

        onPreparationState?(.sourceOpened)
        nativeHLS = formatContext?.pointee.iformat?.pointee.name.map {
            String(cString: $0).split(separator: ",").contains("hls")
        } ?? false
        onPreparationState?(.readingStreamInfo)
        result = avformat_find_stream_info(formatContext, nil)
        error = inputError(result, stage: FTDecoderErrorCode.formatFindStreamInfo.rawValue)
        if error != nil || formatContext == nil {
            if formatContext != nil {
                avformat_close_input(&formatContext)
            }
            return error
        }
        if independentHLS != nil, let context = formatContext {
            independentStartTime = context.pointee.start_time == FT_AV_NOPTS_VALUE ? 0 : Double(context.pointee.start_time) / Double(AV_TIME_BASE)
            independentBitrate = Double(context.pointee.bit_rate) / 1000
        }
        onPreparationState?(.streamInfoRead)
        onPreparationState?(.readingMetadata)
        if let avDict = formatContext?.pointee.metadata {
            self.metadata = FTFoundationBrigeOfAVDictionary(avDict) ?? [:]
        } else {
            self.metadata = [:]
        }

        onPreparationState?(.metadataRead)
        return error
    }

    private func openHLSInput(timeoutSeconds: Int, beganOpening: TimeInterval, useCache: Bool,
                              options: inout OpaquePointer?, loader: (any HTTPDataLoading)? = nil) throws -> Int32 {
        if cacheSession == nil { cacheSession = try FTPlaybackCacheSession() }
        let remaining = max(FTPlayerSDKConfiguration.Network.minimumReadTimeout, Double(timeoutSeconds) - (ProcessInfo.processInfo.systemUptime - beganOpening))
        let interrupted: () -> Bool = { [weak self] in
            guard let self else { return true }; return self.delegate?.formatContextNeedInterrupt(self) == true
        }
        var unsupported: HTTPDataResponse?
        let restored = useCache ? FTHLSMasterCache.restore(source: contentURL, session: cacheSession!) : nil
        let manifest = restored == nil ? try FTIndependentHLS.prepare(source: contentURL, session: cacheSession!, timeout: remaining, interrupted: interrupted,
            preparation: onPreparationState, loader: loader ?? playlistLoader, onUnsupported: { unsupported = $0 }) : nil
        let segmentBudget = max(FTPlayerSDKConfiguration.Network.minimumReadTimeout, Double(timeoutSeconds) - (ProcessInfo.processInfo.systemUptime - beganOpening))
        let hls: any HLSCaching
        let progress: (Double) -> Void = { [weak self] value in self?.onDownloadProgress?(value) }
        if let manifest {
            hls = try FTIndependentHLS(manifest: manifest, session: cacheSession!, cache: useCache, timeout: segmentBudget, onPreparation: onPreparationState, onProgress: progress)
        } else if let configuration = try restored ?? unsupported.flatMap({ response in
            try FTHLSMasterCache.prepare(source: contentURL, response: response, session: cacheSession!, timeout: segmentBudget,
                interrupted: interrupted, preparation: onPreparationState, loader: playlistLoader)
        }) {
            let budget = max(FTPlayerSDKConfiguration.Network.minimumReadTimeout, Double(timeoutSeconds) - (ProcessInfo.processInfo.systemUptime - beganOpening))
            hls = try FTHLSMasterCache(configuration: configuration, session: cacheSession!, cache: useCache, timeout: budget, onPreparation: onPreparationState, onProgress: progress)
        } else { return avformat_open_input(&formatContext, contentURL.absoluteString, nil, &options) }
        independentHLS = hls
        hls.setPlaybackRate(playbackRate)
        av_dict_set(&options, "safe", "0", 0)
        av_dict_set(&options, "allowed_extensions", "ALL", 0)
        av_dict_set(&options, "extension_picky", "0", 0) // Cache URI suffixes do not define the container.
        av_dict_set(&options, "protocol_whitelist", "file,http,https,tcp,tls,crypto", 0)
        if hls.inputFormatName == "concat" {
            // Preserve each declared period's bounds through packet/frame
            // metadata so decoded PCM can be clipped without dropping codec input.
            av_dict_set(&options, "segment_time_metadata", "1", 0)
        }
        return avformat_open_input(&formatContext, hls.file.path, av_find_input_format(hls.inputFormatName), &options)
    }

    private func inputError(_ result: Int32, stage: Int) -> NSError? {
        guard let native = FTCheckErrorCode(result, errorCode: stage) else { return nil }
        guard let cause = independentHLS?.failure ?? cacheIOContext?.failure else { return native }
        var info = cause.userInfo
        info["avCode"] = result; info["stage"] = stage; info["ffmpegError"] = native
        return NSError(domain: cause.domain, code: cause.code, userInfo: info)
    }

    private func openTracks() {
        var videoTracks: [FTTrack] = []
        var audioTracks: [FTTrack] = []

        for i in 0..<Int((formatContext?.pointee.nb_streams ?? 0)) {
            let stream = formatContext?.pointee.streams[i]
            switch stream?.pointee.codecpar.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                let track = FTTrack(index: i, type: .video)
                videoTracks.append(track)
            case AVMEDIA_TYPE_AUDIO:
                let track = FTTrack(index: i, type: .audio)
                audioTracks.append(track)
            default:
                break
            }
        }

        if !videoTracks.isEmpty {
            self.videoTracks = videoTracks
        }
        if !audioTracks.isEmpty {
            self.audioTracks = audioTracks
        }
    }

    private func openVideoTrack() -> NSError? {
        var error: NSError?

        if !videoTracks.isEmpty {
            for track in videoTracks {
                let index = track.index
                guard let stream = formatContext?.pointee.streams[Int(index)] else { continue }
                if (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) == 0 {
                    var codecContext: UnsafeMutablePointer<AVCodecContext>?
                    error = openCodec(trackIndex: Int(index), codecContext: &codecContext, domain: "video")
                    if error == nil {
                        onPreparationState?(.videoCodecOpened)
                        onPreparationState?(.readingVideoParameters)
                        self.videoTrack = track
                        self.videoEnable = true
                        self.videoTimebase = FTStreamGetTimebase(stream, defaultTimebase: FTPlayerSDKConfiguration.Demux.fallbackVideoTimebase)
                        self.videoFPS = FTStreamGetFPS(stream, timebase: self.videoTimebase)
                        let width = CGFloat(codecContext?.pointee.width ?? 0)
                        let height = CGFloat(codecContext?.pointee.height ?? 0)
                        self.videoPresentationSize = CGSize(width: width, height: height)
                        self.videoAspect = height > 0 ? width / height : 0
                        self.videoCodecContext = codecContext
                        onPreparationState?(.videoParametersRead)
                        break
                    }
                }
            }
        } else {
            error = NSError(domain: "video stream not found", code: Int(FTDecoderErrorCode.streamNotFound.rawValue), userInfo: nil)
        }

        return error
    }

    private func openAudioTrack() -> NSError? {
        var error: NSError?

        if !audioTracks.isEmpty {
            for track in audioTracks {
                let index = track.index
                var codecContext: UnsafeMutablePointer<AVCodecContext>?
                error = openCodec(trackIndex: Int(index), codecContext: &codecContext, domain: "audio")
                if error == nil, let stream = formatContext?.pointee.streams[Int(index)] {
                    onPreparationState?(.audioCodecOpened)
                    onPreparationState?(.readingAudioParameters)
                    self.audioTrack = track
                    self.audioEnable = true
                    self.audioTimebase = FTStreamGetTimebase(stream, defaultTimebase: FTPlayerSDKConfiguration.Demux.fallbackAudioTimebase)
                    self.audioCodecContext = codecContext
                    onPreparationState?(.audioParametersRead)
                    break
                }
            }
        } else {
            error = NSError(domain: "audio stream not found", code: Int(FTDecoderErrorCode.streamNotFound.rawValue), userInfo: nil)
        }

        return error
    }

    private func openCodec(trackIndex: Int, codecContext: inout UnsafeMutablePointer<AVCodecContext>?, domain: String) -> NSError? {
        var result: Int32 = 0
        var error: NSError?

        let stream = formatContext?.pointee.streams[trackIndex]
        codecContext = avcodec_alloc_context3(nil)
        if codecContext == nil {
            error = NSError(domain: "\(domain) codec context create error", code: Int(FTDecoderErrorCode.codecContextCreate.rawValue), userInfo: nil)
            return error
        }

        result = avcodec_parameters_to_context(codecContext, stream?.pointee.codecpar)
        error = FTCheckErrorCode(result, errorCode: FTDecoderErrorCode.codecContextSetParam.rawValue)
        if error != nil {
            avcodec_free_context(&codecContext)
            return error
        }
//        av_codec_set_pkt_timebase(codecContext, (stream?.pointee.time_base)!)
        codecContext?.pointee.pkt_timebase = (stream?.pointee.time_base)!

        let codec = avcodec_find_decoder((codecContext?.pointee.codec_id)!)
        if codec == nil {
            avcodec_free_context(&codecContext)
            error = NSError(domain: "\(domain) codec not found decoder", code: Int(FTDecoderErrorCode.codecFindDecoder.rawValue), userInfo: nil)
            return error
        }
        codecContext?.pointee.codec_id = (codec?.pointee.id)!

        if codecContext?.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
            // The library default is serial. Bound parallel video decoding to
            // available cores and four workers to limit frame delay/memory.
            codecContext?.pointee.thread_count = Int32(min(FTPlayerSDKConfiguration.Demux.maximumCodecThreads, max(1, ProcessInfo.processInfo.activeProcessorCount)))
        }

        result = avcodec_open2(codecContext, codec, nil)
        error = FTCheckErrorCode(result, errorCode: FTDecoderErrorCode.codecOpen2.rawValue)
        if error != nil {
            avcodec_free_context(&codecContext)
            return error
        }

        Console.log("codec opened type=\(domain) id=\(codecContext?.pointee.codec_id.rawValue ?? 0) result=\(result)")
        return error
    }

    // Reopen transactionally when concat lost an interrupted child, or cached
    // native HLS needs its initial A/V baselines after reading later fragments.
    // Existing codec contexts are independent copies of the stream parameters.
    private func reopenIndependentInput() -> Bool {
        guard let hls = independentHLS else { return true }
        var candidate = avformat_alloc_context()
        guard candidate != nil else { return false }
        candidate?.pointee.interrupt_callback.callback = ffmpeg_interrupt_callback
        candidate?.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(self).toOpaque()
        var options: OpaquePointer?
        av_dict_set(&options, "safe", "0", 0)
        av_dict_set(&options, "allowed_extensions", "ALL", 0)
        av_dict_set(&options, "extension_picky", "0", 0)
        av_dict_set(&options, "protocol_whitelist", "file,http,https,tcp,tls,crypto", 0)
        if hls.inputFormatName == "concat" { av_dict_set(&options, "segment_time_metadata", "1", 0) }
        av_dict_set(&options, "rw_timeout", "\(inputTimeoutSeconds * 1000000)", 0)
        configureNetworkRecovery(&options)
        let opened = avformat_open_input(&candidate, hls.file.path, av_find_input_format(hls.inputFormatName), &options)
        av_dict_free(&options)
        guard opened >= 0, avformat_find_stream_info(candidate, nil) >= 0 else { avformat_close_input(&candidate); return false }
        var previous = formatContext
        formatContext = candidate
        avformat_close_input(&previous)
        independentNeedsReopen = false
        Console.log("[HLS] reopened \(hls.inputFormatName) input")
        return true
    }

    @discardableResult
    func seekFile(withFFTimebase time: TimeInterval) -> Bool {
        // AVIO may seek entirely inside its 32 KB buffer and never invoke cacheSeek.
        // Clear the interrupted-read latch independently of a physical byte seek.
        cacheIOContext?.resumeRead()
        independentHLS?.resumeReads()
        setPlaybackPosition(time)
        if time == 0, independentHLS != nil {
            // Native HLS seeks in its DTS timeline. A stream whose initial DTS
            // differs substantially from PTS can otherwise skip the first GOP.
            // Reopen the existing VOD description and keep its initial packets.
            nativeHLSActiveAnchor = nil
            return reopenIndependentInput()
        }
        if independentNeedsReopen, !reopenIndependentInput() { return false }
        if let io = formatContext?.pointee.pb {
            io.pointee.eof_reached = 0
            io.pointee.error = 0
            // An interrupted AVIO seek-back near the file start leaves an empty
            // buffer at byte 0. The MP4 demuxer treats that as a restarted stream,
            // reparses the root atoms and fails every later seek. Refill first.
            if io.pointee.pos == 0, io.pointee.buf_ptr == io.pointee.buf_end {
                _ = avio_r8(io)
                avio_seek(io, 0, SEEK_SET)
                if io.pointee.pos == 0 { return false } // Still interrupted; the next seek retries.
            }
        }
        // A seek may arrive immediately after ready, before the packet loop has
        // observed the first keyframe. Seed from the already opened input only
        // when seeking; normal startup does no extra read or playlist request.
        if nativeHLS, duration > 0, duration < FTPlayerSDKConfiguration.Demux.maximumIndexedDuration, nativeHLSAnchors.isEmpty {
            var packet = av_packet_alloc()
            defer { av_packet_free(&packet) }
            var bytes = 0
            for _ in 0..<FTPlayerSDKConfiguration.Demux.seekProbePackets {
                if delegate?.formatContextNeedInterrupt(self) == true { return false }
                let read = av_read_frame(formatContext, packet)
                guard read >= 0, let value = packet?.pointee else { break }
                validateHLSVideoPresentationTimestamp(packet)
                indexNativeHLSPacket(packet!.pointee)
                bytes += Int(value.size)
                av_packet_unref(packet)
                if !nativeHLSAnchors.isEmpty || bytes >= FTPlayerSDKConfiguration.Demux.seekProbeBytes { break }
            }
        }
        let ts = Int64((time + startTime) * Double(AV_TIME_BASE))
        // HLS translates the seek threshold from its first track's origin onto
        // each rendition's DTS origin. External audio may begin before video:
        // passing the absolute video DTS would apply that offset a second time.
        // Normalize the observed keyframe onto the public origin, in video ticks,
        // then keep one full tick of preroll (a microsecond can round away).
        // ANY preserves this threshold; SDK preroll selects the requested PTS.
        // Preroll may extend into an unread part of the same nearby GOP. Requiring
        // prior coverage makes a first seek depend on a patched native demuxer.
        // Bound new preroll by the media buffer window, capped at 50 seconds;
        // distant unseen seeks still use native segment lookup.
        let preroll = min(FTPlayerSDKConfiguration.Demux.maximumSeekPreroll, loadControlConfiguration.maximumBufferDuration)
        let unreadPreroll = min(preroll, independentHLS?.maximumSegmentDuration ?? preroll)
        let firstAnchor = nativeHLSAnchors.min { $0.position < $1.position }
        let videoStart: Double? = videoTrack.flatMap { track in
            guard let stream = formatContext?.pointee.streams[track.index],
                  stream.pointee.start_time != FT_AV_NOPTS_VALUE else { return nil }
            return Double(stream.pointee.start_time) * videoTimebase - startTime
        }
        // External audio can begin before the first video PTS. Seeking in that
        // leading audio interval must retain the initial video keyframe even
        // though its PTS is just after the public target. Check the track start
        // so a later GOP never substitutes for a missing initial keyframe.
        let beforeVideo = videoStart.map { start in
            time < start && firstAnchor.map { abs($0.position-start) <= 1 / max(1, videoFPS) } == true
        } ?? false
        if nativeHLS, beforeVideo, audioEnable, independentHLS?.inputFormatName == "hls" {
            // A fresh cached input preserves the leading audio and initial video
            // DTS origins. Reusing native fragment indexes from a later seek can
            // advance audio by a fragment even when the video keyframe survives.
            // Buffered packets provide preroll; do not seek the new input again.
            return reopenIndependentInput()
        }
        let anchor = nativeHLS ? nativeHLSAnchors.filter {
            ($0.position <= time + FTPlayerSDKConfiguration.Precision.timestampEpsilon || beforeVideo && $0.timestamp == firstAnchor?.timestamp) &&
            time <= max($0.coveredThrough, $0.position + unreadPreroll) + 1 / max(1, videoFPS)
        }.max { $0.position < $1.position } : nil
        nativeHLSActiveAnchor = nil
        let seekStream = anchor == nil ? -1 : Int32(videoTrack!.index)
        let originTicks = firstAnchor.map { max(0, $0.streamTimestamp - Int64((startTime / videoTimebase).rounded())) } ?? 0
        // Rounded EXTINF durations can drift from packet timestamps. For an
        // unseen distant target, start one declared segment earlier so native
        // segment lookup cannot discard the GOP needed to reach the target.
        // The existing decoder preroll still presents the requested time.
        let segmentPreroll = nativeHLS && anchor == nil ? min(preroll, independentHLS?.maximumSegmentDuration ?? 0) : 0
        if segmentPreroll > 0, time <= segmentPreroll, independentHLS != nil {
            // The required GOP is in the first segment. Native timestamp seek
            // can skip it when video DTS leads the common audio origin.
            return reopenIndependentInput()
        }
        let fallbackTimestamp: Int64
        if let period = independentHLS?.seekPeriod(for: time) {
            // A TS child may support timestamp/byte seeking without a complete
            // keyframe index. Begin at its period boundary and decode preroll.
            // A native HLS child must be selected at its exact boundary; one
            // tick earlier asks the preceding child to seek beyond its end.
            let boundary = max(0, period.start - (period.nativePlaylist ? 0 : 1 / Double(AV_TIME_BASE)))
            fallbackTimestamp = Int64((boundary + startTime) * Double(AV_TIME_BASE))
        } else {
            fallbackTimestamp = segmentPreroll > 0 ? Int64((max(0, time - segmentPreroll) + startTime) * Double(AV_TIME_BASE)) : ts
        }
        let seekTimestamp = anchor.map { $0.streamTimestamp - originTicks - 1 } ?? fallbackTimestamp
        let verifiedMP4 = randomAccessMetadataCorrected && time <= verifiedMP4CoveredThrough + FTPlayerSDKConfiguration.Precision.timestampEpsilon
            ? verifiedMP4Anchors.filter { $0.position <= time + FTPlayerSDKConfiguration.Precision.timestampEpsilon }.max { $0.position < $1.position } : nil
        var result: Int32
        if let verifiedMP4, let track = videoTrack {
            // The container's index may still reject its original non-sync
            // sample. ANY is safe here because the encoded RAP was verified.
            result = av_seek_frame(formatContext, Int32(track.index), verifiedMP4.dts,
                                   AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY)
            Console.log("[MP4] verified RAP position=\(verifiedMP4.position) dts=\(verifiedMP4.dts) target=\(time) result=\(result)")
        } else {
            result = av_seek_frame(formatContext, seekStream, seekTimestamp,
                                   anchor == nil ? AVSEEK_FLAG_BACKWARD : AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY)
            if randomAccessMetadataCorrected { Console.log("[MP4] native seek target=\(time) covered=\(verifiedMP4CoveredThrough) anchors=\(verifiedMP4Anchors.count) result=\(result)") }
        }
        if let anchor {
            Console.log("[HLS] seek keyframe position=\(anchor.position) timestamp=\(anchor.timestamp) stream=\(seekStream) ticks=\(seekTimestamp) originTicks=\(originTicks) timebase=\(videoTimebase) target=\(time) result=\(result)")
            if result < 0, delegate?.formatContextNeedInterrupt(self) != true {
                if let io = formatContext?.pointee.pb { io.pointee.eof_reached = 0; io.pointee.error = 0 }
                result = av_seek_frame(formatContext, -1, ts, AVSEEK_FLAG_BACKWARD)
            }
        }
        Console.log("seek target=\(time) result=\(result)")
        // HLS segment bounds use the first DTS, while the public timeline starts
        // at PTS. With reordered video, a valid final PTS can lie past the
        // demuxer's seek range. Retry from an earlier keyframe; the decoder keeps
        // the requested clock and discards preroll as usual. Never retry an
        // interrupted seek, a live stream, or a request away from the VOD tail.
        if result < 0, nativeHLS, duration > 0, duration < FTPlayerSDKConfiguration.Demux.maximumIndexedDuration,
           time > max(0, duration - FTPlayerSDKConfiguration.Demux.endSeekRetryWindow), delegate?.formatContextNeedInterrupt(self) != true {
            let retryTime = max(0, time - FTPlayerSDKConfiguration.Demux.fallbackSeekBackoff)
            if let io = formatContext?.pointee.pb {
                io.pointee.eof_reached = 0
                io.pointee.error = 0
            }
            result = av_seek_frame(formatContext, -1, Int64((retryTime + startTime) * Double(AV_TIME_BASE)), AVSEEK_FLAG_BACKWARD)
            Console.log("seek tail preroll target=\(time) retry=\(retryTime) result=\(result)")
        }
        return result >= 0
    }

    // Demux-thread-only index. Reuse observed coverage or bounded nearby preroll;
    // distant unseen seeks retain native segment lookup. Keep memory bounded.
    private func indexNativeHLSPacket(_ packet: AVPacket) {
        guard nativeHLS, duration > 0, duration < FTPlayerSDKConfiguration.Demux.maximumIndexedDuration,
              let track = videoTrack, Int(packet.stream_index) == track.index else { return }
        guard packet.pts != FT_AV_NOPTS_VALUE, packet.size > 0,
              packet.flags & AV_PKT_FLAG_CORRUPT == 0 else { nativeHLSActiveAnchor = nil; return }
        let position = Double(packet.pts) * videoTimebase - startTime
        let length = packet.duration > 0 ? Double(packet.duration) * videoTimebase : 1 / max(1, videoFPS)
        guard position.isFinite, length.isFinite, length > 0 else { nativeHLSActiveAnchor = nil; return }
        if packet.flags & AV_PKT_FLAG_KEY != 0 {
            guard packet.dts != FT_AV_NOPTS_VALUE,
                  let stream = formatContext?.pointee.streams[track.index],
                  stream.pointee.time_base.num > 0, stream.pointee.time_base.den > 0 else { nativeHLSActiveAnchor = nil; return }
            let timestamp = av_rescale_q_rnd(packet.dts, stream.pointee.time_base,
                                             AVRational(num: 1, den: AV_TIME_BASE), AV_ROUND_DOWN)
            guard timestamp > Int64.min, packet.dts > Int64.min else { nativeHLSActiveAnchor = nil; return }
            if let index = nativeHLSAnchors.firstIndex(where: { $0.timestamp == timestamp - 1 }) {
                nativeHLSActiveAnchor = index
            } else {
                if nativeHLSAnchors.count >= FTPlayerSDKConfiguration.Demux.maximumSeekAnchors { nativeHLSAnchors.remove(at: 1) }
                nativeHLSAnchors.append(HLSSeekAnchor(position: position, timestamp: timestamp - 1, streamTimestamp: packet.dts, coveredThrough: position))
                nativeHLSActiveAnchor = nativeHLSAnchors.count - 1
            }
        }
        if let index = nativeHLSActiveAnchor {
            nativeHLSAnchors[index].coveredThrough = max(nativeHLSAnchors[index].coveredThrough, position + length)
        }
    }

    func readFrame(_ packet: UnsafeMutablePointer<AVPacket>?) -> Int32 {
        if independentNeedsReopen { return -Int32(EAGAIN) }
        let result = av_read_frame(formatContext, packet)
        // A canceled native HTTP read can report a successful partial packet.
        // It must not replace the full sample's size/flags in a seek index.
        if result >= 0, let packet, delegate?.formatContextNeedInterrupt(self) != true {
            validateMP4RandomAccess(packet)
            validateHLSVideoPresentationTimestamp(packet)
            indexNativeHLSPacket(packet.pointee)
        }
        else { nativeHLSActiveAnchor = nil }
        if independentHLS?.inputFormatName == "concat" && result < 0 { independentNeedsReopen = true }
        if result < 0, let failure = independentHLS?.failure ?? cacheIOContext?.failure {
            // Some demuxers translate a failed custom read to EOF. A permanent
            // network error must not announce a successful playback finish.
            error = failure
            return -Int32(EIO)
        }
        return result
    }

    func validateMP4RandomAccess(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard let track = videoTrack, Int(packet.pointee.stream_index) == track.index,
              packet.pointee.flags & AV_PKT_FLAG_CORRUPT == 0,
              packet.pointee.size > 0, packet.pointee.data != nil,
              let stream = formatContext?.pointee.streams[track.index],
              let name = formatContext?.pointee.iformat?.pointee.name,
              String(cString: name).split(separator: ",").contains("mov") else { return }
        if !randomAccessParserAttempted {
            randomAccessParserAttempted = true
            let id = stream.pointee.codecpar.pointee.codec_id
            guard id == AV_CODEC_ID_H264 || id == AV_CODEC_ID_HEVC else { return }
            guard let parser = av_parser_init(id) else { return }
            var codec = avcodec_alloc_context3(nil)
            guard codec != nil, avcodec_parameters_to_context(codec, stream.pointee.codecpar) >= 0 else {
                av_parser_close(parser); avcodec_free_context(&codec); return
            }
            // The parser gets its own context: it must not mutate a codec that
            // is concurrently decoding on the video thread.
            parser.pointee.flags |= PARSER_FLAG_COMPLETE_FRAMES
            randomAccessParser = parser; randomAccessParserCodec = codec
        }
        guard let parser = randomAccessParser, let codec = randomAccessParserCodec else { return }
        parser.pointee.key_frame = -1
        var output: UnsafeMutablePointer<UInt8>?, size: Int32 = 0
        let consumed = av_parser_parse2(parser, codec, &output, &size, packet.pointee.data,
            packet.pointee.size, packet.pointee.pts, packet.pointee.dts, packet.pointee.pos)
        guard consumed == packet.pointee.size, size > 0, parser.pointee.key_frame >= 0 else { return }
        let encodedKey = parser.pointee.key_frame == 1
        let entry = packet.pointee.dts == FT_AV_NOPTS_VALUE ? nil : avformat_index_get_entry_from_timestamp(
            stream, packet.pointee.dts, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY)
        // MOV edit lists can retime a packet onto another sample's native DTS.
        // Timestamp equality alone does not establish index entry identity.
        let matchingEntry = entry.flatMap { value in
            value.pointee.timestamp == packet.pointee.dts && value.pointee.pos == packet.pointee.pos ? value : nil
        }
        if packet.pointee.pts != FT_AV_NOPTS_VALUE {
            let position = Double(packet.pointee.pts) * videoTimebase - startTime
            let length = packet.pointee.duration > 0 ? Double(packet.pointee.duration) * videoTimebase : 1 / max(1, videoFPS)
            verifiedMP4CoveredThrough = max(verifiedMP4CoveredThrough, position + length)
            if encodedKey, matchingEntry != nil,
               !verifiedMP4Anchors.contains(where: { $0.dts == packet.pointee.dts }) {
                if verifiedMP4Anchors.count >= FTPlayerSDKConfiguration.Demux.maximumSeekAnchors { verifiedMP4Anchors.remove(at: 1) }
                verifiedMP4Anchors.append((position, packet.pointee.dts))
            }
        }
        // H.264 demux parsing can already repair packet.flags while leaving
        // MOV's seek index stale. Compare both representations with the parser.
        let staleIndex = matchingEntry.map { (($0.pointee.flags & AVINDEX_KEYFRAME != 0) != encodedKey) } ?? false
        guard staleIndex || encodedKey != (packet.pointee.flags & AV_PKT_FLAG_KEY != 0) else { return }
        randomAccessMetadataCorrected = true
        if encodedKey { packet.pointee.flags |= AV_PKT_FLAG_KEY }
        else { packet.pointee.flags &= ~AV_PKT_FLAG_KEY }
        // Updating the public demux index fixes later seeks too. Correcting only
        // the packet would leave a fake sync sample as a seek entry point.
        if let original = matchingEntry?.pointee {
            let flags = encodedKey ? original.flags | AVINDEX_KEYFRAME : original.flags & ~AVINDEX_KEYFRAME
            av_add_index_entry(stream, original.pos, original.timestamp,
                original.size, original.min_distance, flags)
        }
    }

    private func validateHLSVideoPresentationTimestamp(_ packet: UnsafeMutablePointer<AVPacket>?) {
        guard let packet, nativeHLS, independentHLS != nil,
              Int(packet.pointee.stream_index) == videoTrack?.index,
              packet.pointee.pts != FT_AV_NOPTS_VALUE, packet.pointee.dts != FT_AV_NOPTS_VALUE else { return }
        let span = duration
        guard span.isFinite, span > 0, span < FTPlayerSDKConfiguration.Demux.maximumIndexedDuration else { return }
        let pts = Double(packet.pointee.pts) * videoTimebase - startTime
        let dts = Double(packet.pointee.dts) * videoTimebase - startTime
        // The video track may lead audio/the common origin. Do not reject a
        // valid negative DTS merely because that track began before time zero.
        guard dts >= -span, dts <= span * FTPlayerSDKConfiguration.Demux.timestampOutlierDurationMultiplier,
              abs(pts - dts) > span, pts < -span || pts > span * FTPlayerSDKConfiguration.Demux.timestampOutlierDurationMultiplier else { return }
        // An isolated PTS far outside a finite playlist cannot describe the
        // picture while its DTS remains in-range. Let the codec derive a best
        // effort presentation timestamp; preserve the original decode ordering.
        Console.log("[HLS] ignore outlier video PTS=\(pts) DTS=\(dts) duration=\(span)")
        packet.pointee.pts = FT_AV_NOPTS_VALUE
    }

    func containAudioTrack(_ audioTrackIndex: Int) -> Bool {
        return audioTracks.contains { $0.index == audioTrackIndex }
    }

    func selectAudioTrackIndex(_ audioTrackIndex: Int) -> NSError? {
        guard audioTrackIndex != (audioTrack?.index ?? -1),
              containAudioTrack(audioTrackIndex) else { return nil }

        var codecContext: UnsafeMutablePointer<AVCodecContext>?
        let error = openCodec(trackIndex: audioTrackIndex, codecContext: &codecContext, domain: "audio select")
        if error == nil, let stream = formatContext?.pointee.streams[audioTrackIndex] {
            if audioCodecContext != nil {
                avcodec_free_context(&audioCodecContext)
                audioCodecContext = nil
            }
            audioTrack = audioTracks.first { $0.index == audioTrackIndex }
            audioEnable = true
            audioTimebase = FTStreamGetTimebase(stream, defaultTimebase: FTPlayerSDKConfiguration.Demux.fallbackAudioTimebase)
            audioCodecContext = codecContext
            snapshotCacheTimeline()
            refreshCacheTimeline()
            configureCacheLoadControl()
        } else if error != nil {
        }
        return error
    }

    var contentURLString: String {
        if contentURL.isFileURL {
            return contentURL.path
        } else {
            return contentURL.absoluteString
        }
    }

    func destroyAudioTrack() {
        audioEnable = false
        audioTrack = nil
        audioTracks = []

        if audioCodecContext != nil {
            avcodec_free_context(&audioCodecContext)
            audioCodecContext = nil
        }
    }

    func destroyVideoTrack() {
        videoEnable = false
        videoTrack = nil
        videoTracks = []

        if videoCodecContext != nil {
            avcodec_free_context(&videoCodecContext)
            videoCodecContext = nil
        }
    }

    private func makeIOContext() throws -> FTCacheIOContext {
        if cacheSession == nil { cacheSession = try FTPlaybackCacheSession() }
        let worker = try cacheSession!.makeWorker(videoURL: contentURL, revision: cacheSessionRevision, initialReadAheadBytes:FTPlayerSDKConfiguration.Cache.bootstrapBytes, onPreparationState: { [weak self] state in
            self?.onPreparationState?(state)
        })
        worker.onProgress = { [weak self] fraction in
            guard let self, self.cacheTimelineLock.withLock({ self.reportsFileCacheProgress }) else { return }
            self.refreshCacheTimeline()
            self.onDownloadProgress?(fraction)
        }
        return try FTCacheIOContext(worker: worker)
    }

    // Snapshot native index entries only on the demux/open thread. UI/network threads
    // subsequently read Swift value arrays and never touch mutable AVStream pointers.
    private func snapshotCacheTimeline() {
        guard cacheIOContext != nil else { return }
        guard duration.isFinite, duration > 0, duration < FTPlayerSDKConfiguration.Demux.maximumIndexedDuration else {
            cacheTimelineLock.withLock { cacheTimelineIndex = CacheTimelineIndex(tracks:[],duration:0) }
            return
        }
        var tracks: [CacheTrackTimeline] = []
        for track in [videoTrack, audioTrack].compactMap({ $0 }) {
            guard let stream = formatContext?.pointee.streams[track.index] else { continue }
            let count = avformat_index_get_entries_count(stream)
            // A sparse seek index (e.g. FLV/WebM) can grow while probing. Without
            // a known frame count it cannot prove that every media sample exists;
            // extending its final entry to duration would paint uncached media.
            guard count > 0, stream.pointee.nb_frames > 0,
                  Int64(count) >= stream.pointee.nb_frames else { tracks.removeAll(); break }
            let timebase = Double(stream.pointee.time_base.num) / Double(stream.pointee.time_base.den)
            var samples: [CacheTimelineSample] = []
            for i in 0..<count {
                guard let pointer = avformat_index_get_entry(stream, i) else { continue }
                let entry = pointer.pointee
                let size = Int64(entry.size)
                guard entry.pos >= 0, size > 0, entry.pos <= Int64.max - size, entry.timestamp != FT_AV_NOPTS_VALUE else { continue }
                let start = max(0, Double(entry.timestamp) * timebase - startTime)
                let next = i + 1 < count ? avformat_index_get_entry(stream, i + 1).map { Double($0.pointee.timestamp) * timebase - startTime } : nil
                let end = min(duration, next ?? duration)
                // Keep preroll keyframes with negative DTS: their bytes establish
                // references for the first visible frame even when their span is empty.
                samples.append(CacheTimelineSample(offset: entry.pos, size: size, start: start, end: end, keyframe: entry.flags & 1 != 0))
            }
            guard !samples.isEmpty else { tracks.removeAll(); break }
            tracks.append(CacheTrackTimeline(samples: samples, requiresKeyframe: track.type == .video))
        }
        cacheTimelineLock.withLock { cacheTimelineIndex = CacheTimelineIndex(tracks: tracks, duration: duration) }
        Console.log("[Cache] timeline indexed tracks=\(tracks.count) samples=\(tracks.map { $0.samples.count })")
    }

    private func configureCacheLoadControl() {
        let index = cacheTimelineLock.withLock { cacheTimelineIndex }
        let nativeRate = max(0,(formatContext?.pointee.bit_rate ?? 0))
        let size = cacheIOContext?.diagnosticSnapshot["fileSize"] ?? 0
        let byteRate = nativeRate > 0 ? Double(nativeRate)/8 : (duration.isFinite && duration > 0 && duration < FTPlayerSDKConfiguration.Demux.maximumIndexedDuration && size > 0 ? Double(size)/duration : 0)
        cacheIOContext?.configureLoadControl(loadControlConfiguration,index:index,bytesPerSecond:byteRate,video:videoEnable,audio:audioEnable)
        independentHLS?.configureLoadControl(loadControlConfiguration,video:videoEnable,audio:audioEnable)
    }

    private func refreshCacheTimeline() {
        guard let io = cacheIOContext else { return }
        let index = cacheTimelineLock.withLock { cacheTimelineIndex }
        let ranges = io.cachedFraction >= 1 && index.duration > 0 ? [FTPlayerCachedTimeRange(start: 0, end: index.duration)] : index.ranges(in: io.cachedByteRanges, fileSize: 0)
        cacheTimelineLock.withLock { _cachedTimeRanges = ranges }
    }

    func cancelPendingReads() { cacheIOContext?.cancelRead(); independentHLS?.cancelReads() }

    func destroy() {
        if let parser = randomAccessParser { av_parser_close(parser); randomAccessParser = nil }
        avcodec_free_context(&randomAccessParserCodec)
        randomAccessParserAttempted = false
        randomAccessMetadataCorrected = false; verifiedMP4Anchors.removeAll(); verifiedMP4CoveredThrough = 0
        nativeHLS = false; nativeHLSAnchors.removeAll(); nativeHLSActiveAnchor = nil
        destroyVideoTrack()
        destroyAudioTrack()
        if formatContext != nil {
            if cacheIOContext != nil {
                formatContext?.pointee.pb = nil  // prevent avformat_close_input from touching our avio
            }
            avformat_close_input(&formatContext)
            formatContext = nil
        }
        cacheIOContext?.close()
        cacheIOContext = nil
        independentHLS?.close(); independentHLS = nil
        if ownsCacheSession { cacheSession?.close(); cacheSession = nil }
    }

    deinit {
        destroy()
        Console.log("FTFormatContext release")
    }
}

func ffmpeg_interrupt_callback(ctx: UnsafeMutableRawPointer?) -> Int32 {
    let obj = Unmanaged<FTFormatContext>.fromOpaque(ctx!).takeUnretainedValue()
    return obj.delegate?.formatContextNeedInterrupt(obj) == true ? 1 : 0
}

