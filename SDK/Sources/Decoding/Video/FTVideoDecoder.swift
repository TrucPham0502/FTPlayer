//
//  FTVideoDecoder.swift
//
//
//  Edited by TP on 2024/7/13.
//
//
import Foundation
import AVFoundation
@_implementationOnly import libavcodec
@_implementationOnly import libavutil.error
@_implementationOnly import libavdevice
@_implementationOnly import libswscale

let FT_AVERROR_EOF : Int32 = -541478725
// AVERROR_INVALIDDATA uses FFERRTAG, which Swift cannot import as a C macro.
let FT_AVERROR_INVALIDDATA: Int32 = -1094995529
let FT_AV_NOPTS_VALUE : Int64 = Int64.min

protocol FTVideoDecoderDelegate: AnyObject {
    func videoDecoderDidDecodeFirstFrame(_ videoDecoder: FTVideoDecoder)
    func videoDecoder(_ videoDecoder: FTVideoDecoder, didError error: Error)
    func videoDecoderNeedUpdateBufferedDuration(_ videoDecoder: FTVideoDecoder)
    func videoDecoderNeedCheckBufferingStatus(_ videoDecoder: FTVideoDecoder)
}

struct FTVideoDecoderInfo {
    var codecContext: UnsafeMutablePointer<AVCodecContext>
    var videoToolBoxEnable: Bool
    var maxDecodeDuration: TimeInterval
    var timebase: TimeInterval
    var fps: TimeInterval
}

protocol FTVideoDecoderDataSource: AnyObject {
    func shouldHandle(_ videoDecoder: FTVideoDecoderInfo, decodeFrame packet: AVPacket) -> Bool
    func videoDecoder(_ videoDecoder: FTVideoDecoderInfo, decodeFrame packet: AVPacket) -> FTVideoFrame?
}

class FTVideoDecoder {
    private var codecContext: UnsafeMutablePointer<AVCodecContext>
    private var packetQueue: FTPacketQueue
    private var frameQueue: FTFrameQueue
    private var framePool: FTFramePool?
    private var hardwareDecoder: FTVideoHardwareDecoder?
    @Atomic private var canceled = false
    @Atomic var error: NSError?
    @Atomic var decoding = false

    var vtbMaxResumeAttempts = 1  // số lần tối đa cho phép switch-back VTB, 0 = không bao giờ

    // VTB → FFmpeg fallback state (accessed only from decodeFrameThread)
    private var vtbFallbackActive = false
    private var vtbResumeCount = 0
    private var vtbOutputPositions: [TimeInterval] = []
    private var fallbackOutputPositions: [TimeInterval] = []
    private var vtbIDRBuffer: [UnsafeMutablePointer<AVPacket>] = []  // IDR-anchored, cleared on each IDR
    // flush() is called from readPacketThread; clearVTBIDRBuffer/append are called from decodeFrameThread.
    // Both threads can race on vtbIDRBuffer → double-free → EXC_BAD_ACCESS.
    private let vtbIDRLock = NSLock()

    weak var delegate: FTVideoDecoderDelegate?
    weak var source: FTVideoDecoderDataSource?
    var timestampOffset: TimeInterval = 0
    let decodingPolicy: FTVideoDecodingPolicy
    var videoToolBoxEnable: Bool { decodingPolicy != .ffmpeg }
    private let statisticsLock = NSLock()
    /// Demuxed packet positions, for the frame rate ahead of the output.
    private let packetTimeline = VideoPacketTimeline()
    func upcomingFramesPerSecond(from position: TimeInterval, window: TimeInterval) -> Double? {
        packetTimeline.framesPerSecond(from: position, window: window, reachedEnd: endOfFile)
    }
    /// True when demuxed frames lie strictly between the two positions (or that is unknown).
    func hasPackets(after start: TimeInterval, before end: TimeInterval) -> Bool {
        packetTimeline.hasPackets(after: start, before: end)
    }
    private var ffmpegFrames = 0
    private var hardwareFrames = 0
    private var videoToolboxSoftwareFrames = 0
    private var videoToolboxUnverifiedFrames = 0
    var decodingStatistics: FTVideoDecodingStatistics {
        statisticsLock.lock(); defer { statisticsLock.unlock() }
        return FTVideoDecodingStatistics(policy: decodingPolicy, ffmpegFrames: ffmpegFrames, hardwareFrames: hardwareFrames, videoToolboxSoftwareFrames: videoToolboxSoftwareFrames, videoToolboxUnverifiedFrames: videoToolboxUnverifiedFrames)
    }
    var decodingDescription: String {
        let s = decodingStatistics
        return "policy=\(s.policy.rawValue) ffmpeg=\(s.ffmpegFrames) hardware=\(s.hardwareFrames) vtSoftware=\(s.videoToolboxSoftwareFrames) vtUnverified=\(s.videoToolboxUnverifiedFrames) nextPTS=\(peekFrame()?.position ?? -1) decodedQueueSeconds=\(frameDuration()) catchUpJumps=\(highRateCatchUpJumps) catchUpPackets=\(highRateCatchUpPackets)"
    }
    var hardwareSetupFailure: String { hardwareDecoder?.setupFailure ?? "codec unsupported by VideoToolbox" }
    func prepareRequiredHardware() -> Bool { hardwareDecoder?.trySetupVTSession() == true && hardwareDecoder?.usingHardware == true }
    private func failRequiredHardware(_ reason: String) -> [FTVideoFrame] {
        handleDecodingError(NSError(domain: "FTPlayer.VideoDecoder", code: -2002, userInfo: [NSLocalizedDescriptionKey: "Strict hardware decode failed: \(reason)"]))
        return []
    }
    var maxDecodeDuration: TimeInterval = FTPlayerSDKConfiguration.Video.decodedQueueDuration
    var timebase: TimeInterval
    var fps: TimeInterval
    @Atomic var paused = false
    @Atomic var endOfFile = false

    @Atomic var playbackRate: Float = FTPlayerSDKConfiguration.Playback.defaultRate
    @Atomic var presentationTime: TimeInterval? = nil
    @Atomic private var highRateCatchUpJumps = 0
    @Atomic private var highRateCatchUpPackets = 0
    // Decode the complete reorder window after a catch-up flush. NONREF can
    // otherwise require more packets than the next catch-up interval allows,
    // causing repeated flushes with no FFmpeg output (notably H.264 B-frames).
    private var catchUpNeedsOutput = false
    private var appliedRate: Float?
    private var appliedDiscardNonreference: Bool?
    private var lastQueuedPosition: TimeInterval?
    private var nextSamplePosition: TimeInterval?
    private var samplingRate: Float?
    // Some B-frame MP4s omit composition offsets and label every PTS as DTS.
    // Buffer a short probe, then time pictures in codec display order instead of
    // sorting decoded pictures back into the invalid packet timestamp order.
    private var packetTimingSamples = 0
    private var repairDisplayTimeline: Bool?
    private var pendingTimingFrames: [FTVideoFrame] = []
    private var nextDisplayPosition: TimeInterval?
    private func observePacketTiming(_ packet: AVPacket) {
        guard repairDisplayTimeline == nil else { return }
        guard codecContext.pointee.codec_id == AV_CODEC_ID_HEVC, codecContext.pointee.has_b_frames > 0 else { repairDisplayTimeline = false; return }
        guard packet.pts != FT_AV_NOPTS_VALUE, packet.dts != FT_AV_NOPTS_VALUE, packet.pts == packet.dts else {
            repairDisplayTimeline = false
            return
        }
        packetTimingSamples += 1
        if packetTimingSamples >= FTPlayerSDKConfiguration.Video.timestampProbePackets {
            repairDisplayTimeline = true
            Console.log("Repair B-frame display timeline: PTS equals DTS for \(packetTimingSamples) packets fps=\(fps)")
        }
    }
    private func resetDisplayTimeline() {
        pendingTimingFrames.forEach { $0.cancel() }; pendingTimingFrames.removeAll()
        packetTimingSamples = 0; repairDisplayTimeline = nil; nextDisplayPosition = nil
        nextSamplePosition = nil; samplingRate = nil
    }
    private func applyRateOnDecodeThread() {
        let rate = playbackRate
        let canDiscardNonreference = repairDisplayTimeline == false && !catchUpNeedsOutput
        guard appliedRate != rate || appliedDiscardNonreference != canDiscardNonreference else { return }
        appliedRate = rate
        appliedDiscardNonreference = canDiscardNonreference
        // Keep reference packets, including during HEVC seek. Keyframe-only input
        // can leave no output between distant IDRs and strand reordered frames.
        codecContext.pointee.skip_frame = rate >= FTPlayerSDKConfiguration.Video.nonreferenceDiscardRate && canDiscardNonreference ? AVDISCARD_NONREF : AVDISCARD_DEFAULT
        codecContext.pointee.skip_loop_filter = rate >= FTPlayerSDKConfiguration.Video.nonreferenceDiscardRate ? AVDISCARD_ALL : AVDISCARD_DEFAULT
    }

    private func discardLateDecodeBacklog(_ packet: AVPacket) -> Bool {
        let rate = Double(playbackRate)
        guard rate >= Double(FTPlayerSDKConfiguration.Video.samplingRateThreshold), let clock = presentationTime, clock.isFinite else { return false }
        let timestamp = packet.pts != FT_AV_NOPTS_VALUE ? packet.pts : packet.dts
        guard timestamp != FT_AV_NOPTS_VALUE else { return false }
        let position = Double(timestamp) * timebase - timestampOffset
        // Bound lag in wall time. Dropping decoded images alone cannot help a
        // decoder that is processing reference pictures slower than the clock.
        let lagLimit = max(FTPlayerSDKConfiguration.Video.minimumCatchUpLag, rate * FTPlayerSDKConfiguration.Video.catchUpLagWallTime)
        // Input PTS can trail useful queued pictures during seek/B-frame preroll.
        // Only abandon a GOP when the decoded output has also fallen behind.
        guard let outputPosition = lastQueuedPosition, clock - outputPosition > lagLimit,
              clock - position > lagLimit,
              let jump = packetQueue.discardBeforeKeyframe(notBefore: max(position + timebase, clock - rate * FTPlayerSDKConfiguration.Video.catchUpPastAnchorWallTime),
                                                           noLaterThan: clock + rate * FTPlayerSDKConfiguration.Video.catchUpFutureAnchorWallTime,
                                                           timestampOffset: timestampOffset) else { return false }
        // A past RAP still advances decoding through a long GOP when the RAM
        // packet cap has not admitted the next RAP near the clock. Keep forward
        // overshoot small: far-future pictures would wait for the audio clock.
        avcodec_flush_buffers(codecContext)
        catchUpNeedsOutput = true
        hardwareDecoder?.flush()
        // Decoded pictures own their pixels independently of codec references.
        // Keep them for the next display tick: another catch-up can otherwise
        // erase the newly decoded picture before VSync presents it, repeatedly.
        clearVTBIDRBuffer()
        resetDisplayTimeline()
        lastQueuedPosition = nil
        highRateCatchUpJumps += 1
        highRateCatchUpPackets += jump.packets + 1 // also discard the current stale packet
        FTPlayerDiagnostic.shared.record("info", "decoder", "High-rate keyframe catch-up", fields: [
            "rate": rate, "clock": clock, "inputPTS": position, "resumePTS": jump.position,
            "discardedPackets": jump.packets + 1, "jumps": highRateCatchUpJumps, "policy": decodingPolicy.rawValue,
            "threads": codecContext.pointee.thread_count, "activeThreads": codecContext.pointee.active_thread_type,
            "codecDelay": codecContext.pointee.delay, "bFrames": codecContext.pointee.has_b_frames, "swSends": _swSendCount
        ])
        return true
    }

    lazy var flushPacket: UnsafeMutablePointer<AVPacket> = {
        let pkt = av_packet_alloc()!
        pkt.pointee.duration = 0
        return pkt
    }()

    init(codecContext: UnsafeMutablePointer<AVCodecContext>, timebase: TimeInterval, fps: TimeInterval, delegate: FTVideoDecoderDelegate?, policy: FTVideoDecodingPolicy = FTPlayerSDKConfiguration.Playback.decodingPolicy) {
        self.decodingPolicy = policy
        self.codecContext = codecContext
        self.hardwareDecoder = FTVideoHardwareDecoderFactory.createDecoder(codecContext: codecContext, timebase: timebase)
        self.hardwareDecoder?.requireHardware = policy == .hardware
        self.timebase = timebase
        self.fps = fps
        self.delegate = delegate
        self.packetQueue = FTPacketQueue(timebase: timebase)
        self.frameQueue = FTFrameQueue()
        self.framePool = FTFramePool.videoPool()
        self.packetQueue.sentinel = flushPacket
    }

    func packetSize() -> Int {
        return Int(packetQueue.size)
    }

    func empty() -> Bool {
        return packetEmpty() && frameEmpty()
    }

    func packetEmpty() -> Bool {
        return packetQueue.count <= 0
    }

    func frameEmpty() -> Bool {
        return frameQueue.count <= 0
    }
    
    func frameCount() -> Int {
        return frameQueue.count
    }

    func duration() -> TimeInterval {
        return packetDuration() + frameDuration()
    }

    func packetDuration() -> TimeInterval {
        return packetQueue.duration
    }

    func frameDuration() -> TimeInterval {
        playbackRate >= FTPlayerSDKConfiguration.Video.samplingRateThreshold ? frameQueue.timelineDuration(from: presentationTime) : frameQueue.duration
    }

    func getFrameSync() -> FTVideoFrame? {
        return frameQueue.getFrameSync() as? FTVideoFrame
    }

    func getFrameAsync() -> FTVideoFrame? {
        return frameQueue.getFrameAsync() as? FTVideoFrame
    }

    func peekFrame() -> FTVideoFrame? {
        return frameQueue.peekFrame() as? FTVideoFrame
    }

    // NOTE: now we accept ownership of an allocated AVPacket pointer
    func putPacket(_ packet: UnsafeMutablePointer<AVPacket>?) {
        guard let packet = packet else { return }
        if packet != flushPacket {
            let timestamp = packet.pointee.pts != FT_AV_NOPTS_VALUE ? packet.pointee.pts : packet.pointee.dts
            if timestamp != FT_AV_NOPTS_VALUE { packetTimeline.record(Double(timestamp) * timebase - timestampOffset) }
        }
        var duration: TimeInterval = 0
        if packet.pointee.duration <= 0 && packet.pointee.size > 0 && packet != self.flushPacket {
            duration = 1.0 / fps
        }
        packetQueue.putPacket(packet, duration: duration)
    }
        
    func flush() {
        presentationTime = nil
        packetTimeline.reset()
        packetQueue.flush(excluding: flushPacket)
        frameQueue.flush()
        framePool?.flush()
        vtbFallbackActive = false
        vtbResumeCount = 0
        clearVTBIDRBuffer()
        putPacket(self.flushPacket)
    }

    func destroy() {
        canceled = true
        frameQueue.destroy()
        packetQueue.destroy()
        framePool?.flush()
    }

    func decodeFrameThread() {
        decoding = true
        let finished = false
        var drainedEOF = false
        while !finished {
            if canceled || error != nil {
                break
            }
            if paused {
                Thread.sleep(forTimeInterval: FTPlayerSDKConfiguration.Video.pausedDecodePollInterval)
                continue
            }
            if endOfFile && packetEmpty() && !drainedEOF {
                enqueueDecodedFrames(drainDelayedFrames(), finalizing: true)
                drainedEOF = true
                decoding = false
                delegate?.videoDecoderNeedCheckBufferingStatus(self)
            }
            let queuedDuration = frameDuration()
            // Seek preroll retains its newest picture until a successor or
            // drained EOF proves whether it is the video tail. A single long
            // picture can exceed the duration budget by itself; allow one more
            // output so that retained picture cannot block decoding forever.
            if !drainedEOF && frameCount() > 1 && queuedDuration >= maxDecodeDuration {
                // Decode limits are media seconds. A fixed 100 ms sleep used
                // almost all of a 2-second queue at 16x (125 ms of wall time),
                // leaving too little time to decode/reorder its replacement.
                let wallAhead = queuedDuration / max(1, Double(playbackRate))
                let interval = paused ? max_video_frame_sleep_full_and_pause_time_interval
                    : min(max_video_frame_sleep_full_time_interval, max(FTPlayerSDKConfiguration.Video.minimumFullQueueSleep, wallAhead / FTPlayerSDKConfiguration.Video.fullQueueWallTimeDivisor))
                // Wake as soon as a picture leaves the queue. At <= 1 fps two
                // pictures fill the budget, and seek preroll discards each one
                // within a display tick; a fixed sleep cost 100 ms per picture.
                frameQueue.waitForRemoval(timeout: interval)
                continue
            }
            // Keep the worker alive after draining EOF. A seek may arrive while EOF
            // draining is still running; an Operation.isFinished check cannot restart
            // that race safely. A flush marker wakes this idle worker for the next seek.
            guard let packet = packetQueue.getPacket(timeout: drainedEOF ? nil : FTPlayerSDKConfiguration.Video.packetWaitTimeout) else {
                continue
            }
            decoding = true
            if endOfFile {
                delegate?.videoDecoderNeedUpdateBufferedDuration(self)
            }
            if packet == self.flushPacket {
                drainedEOF = false
                catchUpNeedsOutput = false
                // EOF drain can publish delayed old frames after the read thread's
                // first flush. Clear them here on the codec thread before new packets.
                frameQueue.flush()
                avcodec_flush_buffers(codecContext)
                hardwareDecoder?.flush()
                lastQueuedPosition = nil
                vtbOutputPositions.removeAll(); fallbackOutputPositions.removeAll()
                resetDisplayTimeline()
                continue
            }
            if packet.pointee.stream_index < 0 || packet.pointee.data == nil {
                var invalidPacket: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&invalidPacket)
                continue
            }
            autoreleasepool {
                observePacketTiming(packet.pointee)
                applyRateOnDecodeThread()
                if !discardLateDecodeBacklog(packet.pointee) {
                    enqueueDecodedFrames(decodeFrame(packet: packet))
                }
            }
            var freePkt: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&freePkt)
        }
        decoding = false
        delegate?.videoDecoderNeedCheckBufferingStatus(self)
    }

    private var reportedFirstDecodedFrame = false
    private func enqueueDecodedFrames(_ frames: [FTVideoFrame], finalizing: Bool = false) {
        if !frames.isEmpty { catchUpNeedsOutput = false }
        if !frames.isEmpty && !reportedFirstDecodedFrame {
            reportedFirstDecodedFrame = true
            delegate?.videoDecoderDidDecodeFirstFrame(self)
        }
        pendingTimingFrames.append(contentsOf: frames)
        if repairDisplayTimeline == nil {
            guard finalizing else { return }
            repairDisplayTimeline = codecContext.pointee.codec_id == AV_CODEC_ID_HEVC && codecContext.pointee.has_b_frames > 0 && packetTimingSamples > 0
        }
        let ready = pendingTimingFrames
        pendingTimingFrames.removeAll(keepingCapacity: true)
        for frame in ready {
            frame.position -= timestampOffset
            if repairDisplayTimeline == true {
                let step = 1.0 / max(1, fps)
                frame.position = nextDisplayPosition ?? max(0, frame.position)
                frame.duration = step
                nextDisplayPosition = frame.position + step
            }
            let rate = playbackRate
            let spacing = rate >= FTPlayerSDKConfiguration.Video.samplingRateThreshold ? Double(rate) / FTPlayerSDKConfiguration.Video.sampledOutputFPS : 0
            if samplingRate != rate || frame.position < (lastQueuedPosition ?? -.infinity) {
                nextSamplePosition = nil
                samplingRate = rate
            }
            // Advance a fixed media-time grid, rather than starting a new gap
            // at each retained frame. Rounding to source-frame boundaries on
            // every step lowered 24 fps at 4x to 48 fps and could nearly halve
            // 30 fps output because of floating-point comparisons at the edge.
            if spacing > 0, let next = nextSamplePosition, frame.position + FTPlayerSDKConfiguration.Precision.timestampEpsilon < next {
                frame.cancel()
                continue
            }
            if spacing > 0 {
                let next = nextSamplePosition ?? frame.position
                nextSamplePosition = next + (floor(max(0, frame.position - next) / spacing) + 1) * spacing
            } else { nextSamplePosition = nil }
            lastQueuedPosition = frame.position
            _ = frame.pixelBuffer
            frameQueue.putSortFrame(frame)
        }
    }

    private func drainDelayedFrames() -> [FTVideoFrame] {
        var frames: [FTVideoFrame] = []
        if videoToolBoxEnable, !vtbFallbackActive, let hardwareDecoder {
            hardwareDecoder.finishDelayedFrames()
            while let frame = hardwareDecoder.receiveFrame() {
                if let result = videoFrameFromHardware(frame) { frames.append(result) }
            }
            if decodingPolicy == .hardware { return frames }
        }
        avcodec_send_packet(codecContext, nil)
        var raw = av_frame_alloc()
        defer { av_frame_free(&raw) }
        while let raw {
            let result = avcodec_receive_frame(codecContext, raw)
            // Frame-threaded H.264 can report a queued SPS/PPS-only sample
            // as invalid data before returning later delayed pictures. That
            // packet's error is consumed; keep draining until EOF/EAGAIN.
            if result == FT_AVERROR_INVALIDDATA { continue }
            guard result == 0 else { break }
            let fmt = raw.pointee.format
            var converted = fmt != AV_PIX_FMT_YUV420P.rawValue && fmt != AV_PIX_FMT_YUVJ420P.rawValue ? convertToYUV420P(raw) : nil
            if (converted != nil || fmt == AV_PIX_FMT_YUV420P.rawValue || fmt == AV_PIX_FMT_YUVJ420P.rawValue),
               let frame = videoFrameFromTempFrame(converted ?? raw) { frames.append(frame) }
            if converted != nil { av_frame_free(&converted) }
            av_frame_unref(raw)
        }
        return frames
    }

    private func decodeFrame(packet: UnsafeMutablePointer<AVPacket>) -> [FTVideoFrame] {
        let info = FTVideoDecoderInfo(codecContext: codecContext, videoToolBoxEnable: videoToolBoxEnable, maxDecodeDuration: maxDecodeDuration, timebase: timebase, fps: fps)
        if self.source?.shouldHandle(info, decodeFrame: packet.pointee) == true {
            if let videoFrame = self.source?.videoDecoder(info, decodeFrame: packet.pointee) {
                return [videoFrame]
            }
            return []
        }

        if videoToolBoxEnable, let hwDecoder = hardwareDecoder {
            if vtbFallbackActive {
                let isKey = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                if isKey && vtbResumeCount < vtbMaxResumeAttempts {
                    return tryResumeVTB(hwDecoder: hwDecoder, packet: packet)
                }
                return decodeFrameWithFFmpeg(packet: packet)
            }
            return self.decodeFrameWithVideoTool(hwDecoder: hwDecoder, packet: packet)
        }

        if decodingPolicy == .hardware { return failRequiredHardware("no hardware decoder") }
        return decodeFrameWithFFmpeg(packet: packet)
    }
    
    private func canUseVTSession(_ decoder: FTVideoHardwareDecoder) -> Bool {
        guard decoder.trySetupVTSession() else { return false }
        if decodingPolicy == .automatic {
            if #available(iOS 17.0, *), decoder.usingHardware != true {
                FTPlayerDiagnostic.shared.record("info", "decoder", "Automatic selected FFmpeg: VT session did not confirm hardware", fields: ["hardware": decoder.usingHardware.map { String($0) } ?? "unknown"])
                return false
            }
        }
        return true
    }

    private func decodeFrameWithVideoTool(hwDecoder: FTVideoHardwareDecoder, packet: UnsafeMutablePointer<AVPacket>) -> [FTVideoFrame] {
        // IDR-anchored buffer: clear on keyframe so buffer always starts at last IDR
        if (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 {
            clearVTBIDRBuffer()
            vtbOutputPositions.removeAll(keepingCapacity: true)
        }
        appendToVTBIDRBuffer(packet)

        guard canUseVTSession(hwDecoder) else {
            if decodingPolicy == .hardware { return failRequiredHardware(hwDecoder.setupFailure) }
            vtbFallbackActive = true
            return warmUpAndSwitchToFFmpeg()
        }
        let sendResult = hwDecoder.sendPacket(packet.pointee)
        guard sendResult == 0 else {
            if decodingPolicy == .hardware { return failRequiredHardware("packet status=\(sendResult)") }
            if sendResult > 0 {
                // consecutive -12909 errors — permanent fallback to FFmpeg
                vtbFallbackActive = true
                vtbResumeCount = vtbMaxResumeAttempts
                return warmUpAndSwitchToFFmpeg()
            }
            // sendResult < 0: other failure — per-packet FFmpeg
            return decodeFrameWithFFmpeg(packet: packet)
        }
        var frames: [FTVideoFrame] = []
        while let vtFrame = hwDecoder.receiveFrame() {
            if let vf = videoFrameFromHardware(vtFrame) {
                frames.append(vf)
            }
        }
        return frames
    }

    // MARK: - VTB Fallback Helpers

    private func tryResumeVTB(hwDecoder: FTVideoHardwareDecoder, packet: UnsafeMutablePointer<AVPacket>) -> [FTVideoFrame] {
        vtbResumeCount += 1
        hwDecoder.flush()
        clearVTBIDRBuffer()
        vtbOutputPositions.removeAll(keepingCapacity: true)

        guard canUseVTSession(hwDecoder) else {
            Console.log("[FFmpeg→VTB] Session setup failed, stay FFmpeg")
            return decodeFrameWithFFmpeg(packet: packet)
        }
        guard hwDecoder.sendPacket(packet.pointee) == 0 else {
            Console.log("[FFmpeg→VTB] IDR send failed, stay FFmpeg")
            return decodeFrameWithFFmpeg(packet: packet)
        }
        appendToVTBIDRBuffer(packet)
        vtbFallbackActive = false
        Console.log("[FFmpeg→VTB] Switch-back successful")
        var frames: [FTVideoFrame] = []
        while let vtFrame = hwDecoder.receiveFrame() {
            if let vf = videoFrameFromHardware(vtFrame) { frames.append(vf) }
        }
        return frames
    }

    private func clearVTBIDRBuffer() {
        // Capture under lock, free outside — av_packet_free must not be called under lock
        // because it could trigger deallocation callbacks. The capture itself is the critical section.
        let toFree = vtbIDRLock.withLock { () -> [UnsafeMutablePointer<AVPacket>] in
            let copy = vtbIDRBuffer
            vtbIDRBuffer.removeAll()
            return copy
        }
        for pkt in toFree {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
        }
    }

    private func appendToVTBIDRBuffer(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard let copy = av_packet_alloc() else { return }
        guard av_packet_ref(copy, packet) == 0 else {
            var p: UnsafeMutablePointer<AVPacket>? = copy; av_packet_free(&p); return
        }
        vtbIDRLock.withLock { vtbIDRBuffer.append(copy) }
    }

    // Rebuild software references from the buffered IDR. Only pictures already
    // returned by VT are discarded; delayed pictures that VT never emitted stay.
    private func warmUpAndSwitchToFFmpeg() -> [FTVideoFrame] {
        let buffer = vtbIDRLock.withLock { () -> [UnsafeMutablePointer<AVPacket>] in
            let copy = vtbIDRBuffer
            vtbIDRBuffer.removeAll()
            return copy
        }
        guard !buffer.isEmpty else { return [] }

        avcodec_flush_buffers(codecContext)
        // Threaded FFmpeg can emit warm-up pictures on later packets or EOF.
        // Match each picture already supplied by VT once, preserving reordered
        // pictures and distinct pictures that legitimately share a timestamp.
        fallbackOutputPositions = vtbOutputPositions
        var frames: [FTVideoFrame] = []
        for packet in buffer { frames.append(contentsOf: decodeFrameWithFFmpeg(packet: packet)) }

        for pkt in buffer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
        Console.log("[VTB→FFmpeg] Switched to FFmpeg. Replayed \(buffer.count) packets, new output: \(frames.count) frames")
        return frames
    }

// Re-frames a hybrid AVCC+AnnexB packet into proper per-NALU AVCC.
    // Returns malloc'd (buffer, size) when re-framing was applied, nil otherwise.
    // Same logic as FTH264VideoToolBox.sendPacket's outer-wrapper branch.
    private func reframeHybridAVCCIfNeeded(data: UnsafeMutablePointer<UInt8>, size: Int) -> (UnsafeMutablePointer<UInt8>, Int)? {
        guard size >= 8 else { return nil }
        let outerNalSize = Int((UInt32(data[0]) << 24) | (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3]))
        guard outerNalSize == size - 4 else { return nil }

        var ioContext: UnsafeMutablePointer<AVIOContext>?
        guard avio_open_dyn_buf(&ioContext) >= 0 else { return nil }

        let inner = data.advanced(by: 4)
        let innerEnd = inner.advanced(by: outerNalSize)
        var nalBegin = inner
        var pos = inner
        var naluTypes: [UInt8] = []
        while pos < innerEnd {
            let remaining = innerEnd - pos
            if remaining >= 4 && pos[0] == 0 && pos[1] == 0 && pos[2] == 0 && pos[3] == 1 {
                let nalLen = nalBegin.distance(to: pos)
                if nalLen > 0 {
                    naluTypes.append(nalBegin[0] & 0x1F)
                    avio_wb32(ioContext, UInt32(nalLen)); avio_write(ioContext, nalBegin, Int32(nalLen))
                }
                nalBegin = pos.advanced(by: 4); pos = nalBegin
            } else if remaining >= 3 && pos[0] == 0 && pos[1] == 0 && pos[2] == 1 {
                let nalLen = nalBegin.distance(to: pos)
                if nalLen > 0 {
                    naluTypes.append(nalBegin[0] & 0x1F)
                    avio_wb32(ioContext, UInt32(nalLen)); avio_write(ioContext, nalBegin, Int32(nalLen))
                }
                nalBegin = pos.advanced(by: 3); pos = nalBegin
            } else {
                pos = pos.advanced(by: 1)
            }
        }
        let lastNalLen = nalBegin.distance(to: innerEnd)
        if lastNalLen > 0 {
            naluTypes.append(nalBegin[0] & 0x1F)
            avio_wb32(ioContext, UInt32(lastNalLen)); avio_write(ioContext, nalBegin, Int32(lastNalLen))
        }


        var avccBuffer: UnsafeMutablePointer<UInt8>?
        let avccSize = avio_close_dyn_buf(ioContext, &avccBuffer)
        guard let buf = avccBuffer, avccSize > 0 else { av_free(avccBuffer); return nil }
        return (buf, Int(avccSize))
    }

    private func decodeFrameWithFFmpeg(packet: UnsafeMutablePointer<AVPacket>) -> [FTVideoFrame] {

        var frames: [FTVideoFrame] = []
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }

        // Re-frame hybrid AVCC+AnnexB → proper per-NALU AVCC before sending to FFmpeg
        var reframed: (UnsafeMutablePointer<UInt8>, Int)? = nil
        if codecContext.pointee.codec_id == AV_CODEC_ID_H264, let data = packet.pointee.data {
            reframed = reframeHybridAVCCIfNeeded(data: data, size: Int(packet.pointee.size))
        }
        defer { reframed.map { av_free($0.0) } }

        let sendPacket: UnsafeMutablePointer<AVPacket>
        var tempPkt: UnsafeMutablePointer<AVPacket>? = nil
        if let (buf, sz) = reframed, let pkt = av_packet_alloc() {
            if av_new_packet(pkt, Int32(sz)) == 0 {
                memcpy(pkt.pointee.data, buf, sz)
                pkt.pointee.pts = packet.pointee.pts
                pkt.pointee.dts = packet.pointee.dts
                pkt.pointee.flags = packet.pointee.flags
                pkt.pointee.stream_index = packet.pointee.stream_index
                tempPkt = pkt
                sendPacket = pkt
            } else {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                av_packet_free(&p)
                sendPacket = packet
            }
        } else {
            sendPacket = packet
        }
        defer { if tempPkt != nil { av_packet_free(&tempPkt) } }

        let sendResult = avcodec_send_packet(codecContext, sendPacket)
        _swSendCount += 1

        if sendResult < 0 && sendResult != AVERROR(EAGAIN) && sendResult != FT_AVERROR_EOF {
            FTPlayerDiagnostic.shared.record("warning", "decoder", "FFmpeg packet rejected", fields: ["code": sendResult, "pts": packet.pointee.pts])
            return []
        }
        var packetSent = (sendResult == 0)

        var receiveCount = 0
        while true {
            let receiveResult = avcodec_receive_frame(codecContext, frame)
            if receiveResult == 0 {
                receiveCount += 1
                let fmt = frame!.pointee.format
                let needConvert = fmt != AV_PIX_FMT_YUV420P.rawValue && fmt != AV_PIX_FMT_YUVJ420P.rawValue
                var convertedFrame: UnsafeMutablePointer<AVFrame>? = needConvert ? convertToYUV420P(frame!) : nil
                let frameToPass = needConvert ? convertedFrame : frame
                if let videoFrame = videoFrameFromTempFrame(frameToPass) {
                    frames.append(videoFrame)
                }
                if convertedFrame != nil { av_frame_free(&convertedFrame) }
                av_frame_unref(frame)
            } else if receiveResult == AVERROR(EAGAIN) {
                if !packetSent {
                    let retryResult = avcodec_send_packet(codecContext, sendPacket)
                    if retryResult == 0 { packetSent = true; continue }
                    if retryResult < 0 && retryResult != AVERROR(EAGAIN) && retryResult != FT_AVERROR_EOF { break }
                }
                break
            } else if receiveResult == FT_AVERROR_EOF {
                break
            } else {
                break
            }
        }

        return frames
    }

    private var _swSendCount = 0
    private var swsContext: UnsafeMutablePointer<SwsContext>? = nil
    private var swsSrcFormat: Int32 = -1
    private var swsWidth: Int32 = 0
    private var swsHeight: Int32 = 0
    private var _swsScaleCount = 0

    private func convertToYUV420P(_ src: UnsafeMutablePointer<AVFrame>) -> UnsafeMutablePointer<AVFrame>? {
        let fmt = AVPixelFormat(rawValue: src.pointee.format)
        let w = src.pointee.width
        let h = src.pointee.height

        if swsSrcFormat != src.pointee.format || swsWidth != w || swsHeight != h || swsContext == nil {
            if swsContext != nil { sws_freeContext(swsContext) }
            swsContext = sws_getContext(w, h, fmt, w, h, AV_PIX_FMT_YUV420P, Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
            swsSrcFormat = src.pointee.format
            swsWidth = w; swsHeight = h
            Console.log("Video converter configured size=\(w)x\(h) format=\(src.pointee.format) success=\(swsContext != nil)")
        }
        guard let ctx = swsContext else { return nil }

        guard let dst = av_frame_alloc() else { return nil }
        dst.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        dst.pointee.width  = w
        dst.pointee.height = h
        guard av_frame_get_buffer(dst, 0) == 0 else {
            var tmp: UnsafeMutablePointer<AVFrame>? = dst; av_frame_free(&tmp); return nil
        }

        let srcDataPtrs: [UnsafePointer<UInt8>?] = [
            src.pointee.data.0.map { UnsafePointer($0) }, src.pointee.data.1.map { UnsafePointer($0) },
            src.pointee.data.2.map { UnsafePointer($0) }, src.pointee.data.3.map { UnsafePointer($0) },
            src.pointee.data.4.map { UnsafePointer($0) }, src.pointee.data.5.map { UnsafePointer($0) },
            src.pointee.data.6.map { UnsafePointer($0) }, src.pointee.data.7.map { UnsafePointer($0) }
        ]
        let srcLineSizes: [Int32] = [
            src.pointee.linesize.0, src.pointee.linesize.1, src.pointee.linesize.2, src.pointee.linesize.3,
            src.pointee.linesize.4, src.pointee.linesize.5, src.pointee.linesize.6, src.pointee.linesize.7
        ]
        var dstDataPtrs: [UnsafeMutablePointer<UInt8>?] = [
            dst.pointee.data.0, dst.pointee.data.1, dst.pointee.data.2, dst.pointee.data.3,
            dst.pointee.data.4, dst.pointee.data.5, dst.pointee.data.6, dst.pointee.data.7
        ]
        var dstLineSizes: [Int32] = [
            dst.pointee.linesize.0, dst.pointee.linesize.1, dst.pointee.linesize.2, dst.pointee.linesize.3,
            dst.pointee.linesize.4, dst.pointee.linesize.5, dst.pointee.linesize.6, dst.pointee.linesize.7
        ]

        let result = sws_scale(ctx, srcDataPtrs, srcLineSizes, 0, h, &dstDataPtrs, &dstLineSizes)
        _swsScaleCount += 1

        guard result > 0 else {
            var tmp: UnsafeMutablePointer<AVFrame>? = dst; av_frame_free(&tmp); return nil
        }
        dst.pointee.pts = src.pointee.pts
        dst.pointee.best_effort_timestamp = src.pointee.best_effort_timestamp
        dst.pointee.duration = src.pointee.duration
        dst.pointee.repeat_pict = src.pointee.repeat_pict
        return dst
    }

    func videoFrameFromTempFrame(_ frame : UnsafeMutablePointer<AVFrame>?) -> FTVideoFrame? {
        guard let frame = frame,
              frame.pointee.data.0 != nil,
              frame.pointee.format != AV_PIX_FMT_NONE.rawValue else {
            return nil
        }

        let videoFrame = framePool?.getUnuseFrame() as? FTAVYUVVideoFrame ?? FTAVYUVVideoFrame()
        videoFrame.setFrameData(frame, width: Int(frame.pointee.width), height: Int(frame.pointee.height))
        // Prefer the picture's own PTS. After one duplicate PTS, FFmpeg's
        // best_effort_timestamp switches to pkt_dts, which belongs to a later
        // packet when the decoder delays output (camera lost-IDR streams).
        let pts = frame.pointee.pts
        videoFrame.position = Double(pts != FT_AV_NOPTS_VALUE ? pts : frame.pointee.best_effort_timestamp) * timebase

        let rawDuration = frame.pointee.duration
        if rawDuration != 0 {
            videoFrame.duration = TimeInterval(rawDuration) * timebase + TimeInterval(frame.pointee.repeat_pict) * timebase * 0.5
        } else {
            videoFrame.duration = 1.0 / fps
        }

        statisticsLock.lock(); ffmpegFrames += 1; let firstFFmpegFrame = ffmpegFrames == 1; statisticsLock.unlock()
        if firstFFmpegFrame { FTPlayerDiagnostic.shared.record("info", "decoder", "first decoded FFmpeg frame", fields: ["policy": decodingPolicy.rawValue]) }
        // VT rounds timestamps to microseconds; FFmpeg retains the stream ticks.
        if let index = fallbackOutputPositions.firstIndex(where: { abs($0 - videoFrame.position) <= FTPlayerSDKConfiguration.Precision.timestampEpsilon }) {
            fallbackOutputPositions.remove(at: index)
            videoFrame.cancel()
            return nil
        }
        return videoFrame
    }

    private func videoFrameFromHardware(_ frame : VTFrame?) -> FTVideoFrame? {
        guard let frame = frame else { return nil }
        let videoFrame = FTCVYUVVideoFrame(pixelBuffer: frame.pixelBuffer)
        statisticsLock.lock()
        if hardwareDecoder?.usingHardware == true { hardwareFrames += 1 } else if hardwareDecoder?.usingHardware == false { videoToolboxSoftwareFrames += 1 } else { videoToolboxUnverifiedFrames += 1 }
        statisticsLock.unlock()
        videoFrame.position = frame.pts
        vtbOutputPositions.append(frame.pts)
        // VTFrame.duration thường = 0 với H.265, fallback về 1/fps
        videoFrame.duration = frame.duration > FTPlayerSDKConfiguration.Video.minimumHardwareFrameDuration ? frame.duration : (1.0 / fps)
        return videoFrame
    }

    private func handleDecodingError(_ error: NSError?) {
        self.error = error
        delegateErrorCallback()
    }

    private func delegateErrorCallback() {
        if let error = error {
            delegate?.videoDecoder(self, didError: error)
        }
    }

    deinit {
        var pkt: UnsafeMutablePointer<AVPacket>? = flushPacket
        av_packet_free(&pkt)
        if swsContext != nil { sws_freeContext(swsContext) }
        clearVTBIDRBuffer()
    }
}


private let max_video_frame_sleep_full_time_interval = FTPlayerSDKConfiguration.Video.fullQueueSleep
private let max_video_frame_sleep_full_and_pause_time_interval = FTPlayerSDKConfiguration.Video.pausedFullQueueSleep
