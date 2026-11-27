//
//  FTDecoder.swift
//
//
//  Edited by TP on 2024/7/11.
//

import Foundation
import CoreGraphics
import AVFoundation
@_implementationOnly import libavcodec
@_implementationOnly import libavformat

class FTDecoder: NSObject {
    private let diagnosticID = UUID().uuidString

    private let delegateLock = NSLock()
    private weak var storedDelegate: FTDecoderDelegate?
    // A weak protocol existential contains both the object and its witness table.
    // Copy them under one lock when Stop detaches while decode/audio reports buffer.
    var delegate: FTDecoderDelegate? {
        get { delegateLock.withLock { storedDelegate } }
        set { delegateLock.withLock { storedDelegate = newValue } }
    }
    private weak var storedSource: FTVideoDecoderDataSource?
    var source: FTVideoDecoderDataSource? {
        get { delegateLock.withLock { storedSource } }
        set { delegateLock.withLock { storedSource = newValue } }
    }
    weak var videoOutput: FTDecoderVideoOutput?
    weak var audioOutput: FTDecoderAudioOutput?

    private var ffmpegOperationQueue: OperationQueue? = OperationQueue()
    private var openFileOperation: Operation?
    private var readPacketOperation: Operation?
    private var decodeFrameOperation: Operation?

    private var formatContext: FTFormatContext?
    private var audioDecoder: FTAudioDecoder?
    private var videoDecoder: FTVideoDecoder?

    private(set) var error: Error?
    private let errorCallbackLock = NSLock()
    private var errorCallbackSent = false
    private(set) var contentURL: URL
    private(set) var videoFormat: FTVideoFormat
    var loadControlConfiguration = FTPlayerLoadControlConfiguration()
    private var lastCachePosition = -Double.infinity
    private let progressNotifications = PlaybackNotificationThrottle(interval: FTPlayerSDKConfiguration.Playback.progressNotificationInterval)
    private let bufferNotifications = PlaybackNotificationThrottle(interval: FTPlayerSDKConfiguration.Playback.bufferNotificationInterval)
    private let cachePositionUpdates = PlaybackNotificationThrottle(interval: FTPlayerSDKConfiguration.Playback.cachePositionInterval)
    private var packetLoadControl = FTPlayerLoadControl()
    private let loadControlLock = NSLock()
    private static let packetBufferLimit = FTPlayerSDKConfiguration.Playback.packetBufferBytes
    @Atomic private var packetCapacityLimited = false
    var loadControlDiagnostics: [String:Int64] {
        loadControlLock.withLock {
            ["minimumMediaMilliseconds":Int64(packetLoadControl.configuration.minimumDuration(rate:playbackRate)*1000),
             "maximumMediaMilliseconds":Int64(packetLoadControl.configuration.maximumBufferDuration*1000),
             "targetBytes":packetLoadControl.targetBytes,"isLoading":packetLoadControl.isLoading ? 1 : 0]
        }
    }
    var useCache: Bool = FTPlayerSDKConfiguration.Demux.cacheEnabledByDefault
    var cacheSession: (any PlaybackCacheSession)?
    var cacheSessionRevision: Int?
    var playbackRate: Float = FTPlayerSDKConfiguration.Playback.defaultRate {
        didSet {
            guard oldValue != playbackRate else { return }
            videoDecoder?.playbackRate = playbackRate
            formatContext?.playbackRate = playbackRate
            playbackClock?.setRate(playbackRate)
            FTPlayerDiagnostic.shared.record("info", "rate", "engine rate applied", fields: [
                "engine": diagnosticID, "oldRate": oldValue, "rate": playbackRate
            ])
            if formatContext?.audioEnable == true {
                // A taken seek is no longer pending in seekController, but
                // its audio clock can still belong to the preceding request.
                // Never replace an explicit target with a rate-recovery seek
                // while paused or while either output is still in seek preroll.
                if oldValue >= FTPlayerSDKConfiguration.Playback.rateRecoveryThreshold && playbackRate < FTPlayerSDKConfiguration.Playback.rateRecoveryThreshold && !paused && !seeking && !audioSeekInProgress &&
                   seekPreroll.audioTarget == nil && seekPreroll.videoTarget == nil {
                    fastForwardQueueToCurrentClock()
                    let nextPTS = videoDecoder?.peekFrame()?.position ?? currentVideoFrame?.position ?? 0
                    let audioPts = audioTimeClock
                    // Sparse video (e.g. 1 fps AOV) is far ahead of the clock with no frame missing in
                    // between; seeking there only stalls and repeats the current picture. The shown
                    // frame can be slightly ahead of the clock at a high rate, so the gap starts after it.
                    let shownPTS = max(audioPts, currentVideoFrame?.position ?? audioPts)
                    let missesFrames = nextPTS < audioPts || videoDecoder?.hasPackets(after: shownPTS, before: nextPTS) != false
                    if abs(nextPTS - audioPts) > FTPlayerSDKConfiguration.Playback.rateRecoverySeekGap, missesFrames, seekEnable {
                        FTPlayerDiagnostic.shared.record("info", "rate", "rate recovery seek", fields: [
                            "engine": diagnosticID, "oldRate": oldValue, "rate": playbackRate,
                            "target": audioPts, "nextVideoPTS": nextPTS
                        ])
                        seek(to: audioPts)
                        activateGracePeriod(duration: FTPlayerSDKConfiguration.Playback.audioRateChangeGrace, multiplier: FTPlayerSDKConfiguration.Playback.audioRateChangeGraceMultiplier)
                    } else {
                        activateGracePeriod(duration: FTPlayerSDKConfiguration.Playback.audioRateChangeGrace, multiplier: FTPlayerSDKConfiguration.Playback.audioRateChangeGraceMultiplier)
                    }
                } else {
                    activateGracePeriod(duration: FTPlayerSDKConfiguration.Playback.audioRateChangeGrace, multiplier: FTPlayerSDKConfiguration.Playback.audioRateChangeGraceMultiplier)
                }
            } else {
                activateGracePeriod(duration: FTPlayerSDKConfiguration.Playback.videoRateChangeGrace, multiplier: FTPlayerSDKConfiguration.Playback.videoRateChangeGraceMultiplier)
            }
        }
    }
    private(set) var playbackClock: (any FTPlaybackClock)?
    private var vsyncDriver: FTVSyncDriver?
    @Atomic private var displayTicks = 0
    @Atomic private var surfaceHoldTicks = 0
    @Atomic private var lateVideoDrops = 0
    @Atomic private var waitingForNetworkVideo = false
    // Owned by the display worker; the resume gate above is shared with readers.
    private var networkVideoStarvationBegan: TimeInterval?
    private(set) var progress: TimeInterval = 0 {
        didSet {
            guard progress != oldValue else {
                return
            }
            let force = seeking || audioSeekInProgress || playbackFinished
            // This runs for every consumed PCM frame. At 16x, a media-time-only
            // interval made cache indexing/refill run up to 64 times per second,
            // often creating tiny HTTP ranges on the audio render thread.
            if (force || abs(progress-lastCachePosition) >= FTPlayerSDKConfiguration.Playback.cachePositionMediaStep), cachePositionUpdates.admit(force: force) {
                lastCachePosition = progress; formatContext?.setPlaybackPosition(progress)
            }
            // Keep the playback clock at PCM precision without making the app
            // format labels/update sliders hundreds of times per second.
            if progressNotifications.admit(force: force) {
                delegate?.decoder(self, didChangeValueOfProgress: progress)
            }
        }
    }
    private(set) var bufferedDuration: TimeInterval = 0 {
        didSet {
            if bufferedDuration > 0 && bufferedDuration <= FTPlayerSDKConfiguration.Precision.timestampEpsilon {
                bufferedDuration = 0
            }
            if bufferedDuration != oldValue,
               bufferNotifications.admit(force: bufferedDuration == 0 || oldValue == 0) {
                delegate?.decoder(self, didChangeValueOfBufferedDuration: bufferedDuration)
            }
            finishPlaybackIfDrained()
            checkBufferingStatus()
        }
    }
    // Packet, display and audio workers all check buffering. Serialize the
    // decision and transition so concurrent checks cannot publish duplicates.
    private let bufferingStateLock = NSRecursiveLock()
    private var storedBuffering = false
    private(set) var buffering: Bool {
        get { bufferingStateLock.withLock { storedBuffering } }
        set {
            bufferingStateLock.withLock {
                guard newValue != storedBuffering else { return }
                storedBuffering = newValue
                if newValue {
                    bufferingWatchdog.begin(at: CACurrentMediaTime())
                    playbackClock?.setPaused(true)
                } else if !paused {
                    playbackClock?.setPaused(false)
                }
                Console.log("buffering=\(newValue) seconds=\(bufferedDuration) threshold=\(minBufferedDuration)")
                delegate?.decoder(self, didChangeValueOfBuffering: newValue)
            }
        }
    }
    private(set) var playbackFinished: Bool = false {
        didSet {
            guard playbackFinished != oldValue,
                  playbackFinished else {
                return
            }
            // The clock may already have clamped progress to duration while its
            // notification was throttled; the end position must still be published.
            if progress == duration {
                delegate?.decoder(self, didChangeValueOfProgress: progress)
            } else {
                progress = duration
            }
            delegate?.decoderDidPlaybackFinished(self)
            checkBufferingStatus()
        }
    }
    private(set) var closed: Bool = false
    private(set) var endOfFile: Bool = false
    private(set) var paused: Bool = false
    var seeking: Bool { seekController.isPending }
    private(set) var prepareToDecode: Bool = false

    private let seekController = PlaybackSeekController()
    private let seekPreroll = PlaybackSeekPreroll()
    private var lastAudioEnd: TimeInterval = 0
    // Render callbacks never wait for a seek. Serialize their clock commit with
    // seek publication, and keep the gate closed after take() removes pending.
    private let audioFrameLock = NSRecursiveLock()
    @Atomic private var audioSeekInProgress = false
    private var selectAudioTrack = false
    private var selectAudioTrackIndex = 0
    private(set) var currentVideoFrame: FTVideoFrame?
    private(set) var currentAudioFrame: FTAudioFrame?

    private var _gracePeriodEnd: TimeInterval = 0
    private var _gracePeriodMultiplier = FTPlayerSDKConfiguration.Playback.audioRateChangeGraceMultiplier
    private var _postSeekGraceActive = false
    private var _postSeekGraceTarget: TimeInterval = 0
    private var _systemClockAnchored = false
    private var _systemClockAnchorTarget: TimeInterval?
    private var _driftCheckNext: TimeInterval = 0
    private var _prevDrift: TimeInterval = 0

    private var _audioTimeClock: TimeInterval = 0
    private let audioTimeClockLock = NSLock()
    var audioTimeClock: TimeInterval {
        audioTimeClockLock.withLock { _audioTimeClock }
    }

    var videoDecodingPolicy: FTVideoDecodingPolicy = FTPlayerSDKConfiguration.Playback.decodingPolicy
    var minBufferedDuration: TimeInterval = 0
    var postSeekBufferedDuration: TimeInterval = FTPlayerSDKConfiguration.Playback.postSeekMediaBuffer
    var bufferingTimeout: TimeInterval = FTPlayerSDKConfiguration.Playback.bufferingTimeout
    private let bufferingWatchdog = PlaybackBufferingWatchdog()
    var reading = false

    var videoEnable: Bool {
        return formatContext?.videoEnable ?? false
    }

    var audioEnable: Bool {
        return formatContext?.audioEnable ?? false
    }

    var videoTrack: FTTrack? {
        return formatContext?.videoTrack
    }

    var audioTrack: FTTrack? {
        return formatContext?.audioTrack
    }

    var videoTracks: [FTTrack] {
        return formatContext?.videoTracks ?? []
    }

    var audioTracks: [FTTrack] {
        return formatContext?.audioTracks ?? []
    }

    var metadata: [String: Any] {
        return formatContext?.metadata as? [String: Any] ?? [:]
    }

    var presentationSize: CGSize {
        return formatContext?.videoPresentationSize ?? .zero
    }

    var aspect: CGFloat {
        return formatContext?.videoAspect ?? 0
    }

    var duration: TimeInterval {
        return formatContext?.duration ?? 0
    }

    var bitrate: TimeInterval {
        return formatContext?.bitrate ?? 0
    }

    var mediaInfo: FTPlayerMediaInfo? { formatContext?.mediaInfo }

    var cachedTimeRanges: [FTPlayerCachedTimeRange] { formatContext?.cachedTimeRanges ?? [] }

    var cachedFraction: Double {
        return formatContext?.cachedFraction ?? 0
    }
    var cacheProgress: FTPlayerCacheProgress {
        let values = cacheDiagnostics
        if values["hlsSegments"] != nil {
            return FTPlayerCacheProgress(cachedBytes: values["hlsStoredBytes"] ?? 0,
                totalBytes: values["hlsCacheMetadataComplete"] == 1 ? values["hlsStorageTotalBytes"] : nil)
        }
        return FTPlayerCacheProgress(cachedBytes: values["cachedBytes"] ?? 0, totalBytes: values["fileSize"])
    }

    var seekEnable: Bool {
        return duration > 0
    }

    init(contentURL: URL, videoFormat: FTVideoFormat, videoOutput: FTDecoderVideoOutput?, audioOutput: FTDecoderAudioOutput?) {
        self.contentURL = contentURL
        self.videoFormat = videoFormat
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
        super.init()
        setupFFmpeg()
    }

    private func setupFFmpeg() {
        DispatchQueue.once(token: "ffmpeg.setup") {
            av_log_set_level(AV_LOG_WARNING)
            av_log_set_callback { context, level, format, args in
                guard FTPlayerDiagnostic.shared.isEnabled else { return }
                // Custom callbacks must apply the threshold themselves, like
                // av_log_default_callback. Filter before formatting/allocating:
                // a single MP4 moov can otherwise emit tens of thousands of TRACE lines.
                let severity = level >= 0 ? level & 0xff : level
                guard severity <= av_log_get_level() else { return }
                guard let format = format,
                      let formatString = String.init(utf8String: format),
                      let args = args else {
                    return
                }
                let message = NSString(format: formatString, arguments: args) as String
                FTPlayerDiagnostic.shared.record(severity <= AV_LOG_ERROR ? "error" : "warning", "ffmpeg",
                    message.trimmingCharacters(in: .whitespacesAndNewlines), fields: ["avLevel": severity])
            }
//            av_register_all()
            avformat_network_init()
        }
    }

    var decodingStatistics: FTVideoDecodingStatistics? { videoDecoder?.decodingStatistics }
    func upcomingVideoFrameRate(from position: TimeInterval, window: TimeInterval) -> Double? {
        videoDecoder?.upcomingFramesPerSecond(from: position, window: window)
    }

    var cacheDiagnostics: [String: Int64] { formatContext?.cacheDiagnostics ?? [:] }
    var rateDiagnosticFields: [String: Any] {
        var fields: [String: Any] = ["engine": diagnosticID, "rate": playbackRate,
            "seekRevision": seekController.revision, "progress": progress,
            "paused": paused, "buffering": buffering, "seeking": seeking,
            "audioSeekInProgress": audioSeekInProgress, "pendingSeek": seekController.isPending,
            "audioPreroll": seekPreroll.audioTarget?.time as Any? ?? NSNull(),
            "videoPreroll": seekPreroll.videoTarget?.time as Any? ?? NSNull(),
            "eof": endOfFile, "finished": playbackFinished, "closed": closed,
            "hasAudio": audioEnable, "audioClock": audioTimeClock,
            "selectedVideoPTS": currentVideoFrame?.position as Any? ?? NSNull(),
            "nextVideoPTS": videoDecoder?.peekFrame()?.position as Any? ?? NSNull(),
            "videoQueueSeconds": videoDecoder?.duration() ?? 0,
            "decodedVideoQueueSeconds": videoDecoder?.frameDuration() ?? 0,
            "audioQueueBytes": audioDecoder?.size() ?? 0, "audioQueuedDuration": audioDecoder?.duration() ?? 0,
            "audioPCM": audioDecoder?.levelDescription ?? "none",
            "postSeekGrace": _postSeekGraceActive, "audioTailClock": audioTailClockActive,
            "displayTicks": displayTicks, "lateVideoDrops": lateVideoDrops,
            "decode": videoDecoder?.decodingDescription ?? "none",
            "bufferedDuration": bufferedDuration, "minimumBufferedDuration": minBufferedDuration,
            "cache": cacheDiagnostics, "loadControl": loadControlDiagnostics]
        if let clock = playbackClock as? FTAudioMasterClock { fields["masterClock"] = clock.rateDiagnosticFields }
        else if let clock = playbackClock as? FTSystemMasterClock { fields["masterClock"] = clock.rateDiagnosticFields }
        else { fields["masterClock"] = NSNull() }
        return fields
    }
    var diagnosticSnapshot: String {
        let audioLevels = audioDecoder?.levelDescription ?? "audioDecodedSamples=0"
        let loadDetails = loadControlDiagnostics.sorted { $0.key < $1.key }.map { "load.\($0.key)=\($0.value)" }.joined(separator:" ")
        let cacheDetails = cacheDiagnostics.sorted { $0.key < $1.key }.map { "cache.\($0.key)=\($0.value)" }.joined(separator: " ")
        return "progress=\(progress) duration=\(duration) buffer=\(bufferedDuration) minBuffer=\(minBufferedDuration) buffering=\(buffering) paused=\(paused) seeking=\(seeking) eof=\(endOfFile) closed=\(closed) reading=\(reading) rate=\(playbackRate) audioClock=\(audioTimeClock) masterClock=\(playbackClock?.currentTime ?? -1) videoPTS=\(currentVideoFrame?.position ?? -1) videoQueueSeconds=\(videoDecoder?.duration() ?? 0) packetBytes=\(videoDecoder?.packetSize() ?? 0) audioQueueBytes=\(audioDecoder?.size() ?? 0) cache=\(cachedFraction) displayTicks=\(displayTicks) surfaceHoldTicks=\(surfaceHoldTicks) lateVideoDrops=\(lateVideoDrops) decode=\(videoDecoder?.decodingDescription ?? "none") \(audioLevels) \(loadDetails) \(cacheDetails)"
    }

    func open() {
        setupOperationQueue()
    }

    private func setupOperationQueue() {
        ffmpegOperationQueue?.maxConcurrentOperationCount = 2
        ffmpegOperationQueue?.qualityOfService = .userInteractive
        setupOpenFileOperation()
    }

    private func setupOpenFileOperation() {
        openFileOperation = BlockOperation { [weak self] in
            self?.openFormatContext()
        }
        openFileOperation?.queuePriority = .veryHigh
        openFileOperation?.qualityOfService = .userInteractive
        ffmpegOperationQueue?.addOperation(openFileOperation!)
    }

    private func setupReadPacketOperation() {
        guard let openFileOp = openFileOperation else { return }
        if error != nil {
            delegateErrorCallback()
            return
        }
        if readPacketOperation == nil || readPacketOperation!.isFinished {
            readPacketOperation = BlockOperation { [weak self] in
                self?.readPacketThread()
            }
            readPacketOperation?.queuePriority = .veryHigh
            readPacketOperation?.qualityOfService = .userInteractive
            readPacketOperation?.addDependency(openFileOp)
            ffmpegOperationQueue?.addOperation(readPacketOperation!)
        }
        if formatContext?.videoEnable == true {
            if decodeFrameOperation == nil || decodeFrameOperation!.isFinished {
                decodeFrameOperation = BlockOperation { [weak self] in
                    self?.videoDecoder?.decodeFrameThread()
                }
                decodeFrameOperation?.queuePriority = .veryHigh
                decodeFrameOperation?.qualityOfService = .userInteractive
                decodeFrameOperation?.addDependency(openFileOp)
                ffmpegOperationQueue?.addOperation(decodeFrameOperation!)
            }
            if vsyncDriver == nil {
                vsyncDriver = FTVSyncDriver()
                vsyncDriver?.onTick = { [weak self] targetTimestamp in
                    self?.vsyncTick(targetTimestamp)
                }
                vsyncDriver?.start()
            }
        }
    }

    private func openFormatContext() {
        delegate?.decoderWillOpenInputStream(self)
        formatContext = FTFormatContext(contentURL: contentURL, videoFormat: videoFormat, cacheSession: cacheSession, cacheSessionRevision: cacheSessionRevision)
        formatContext?.delegate = self
        formatContext?.playbackRate = playbackRate
        formatContext?.loadControlConfiguration = loadControlConfiguration
        formatContext?.onDownloadProgress = { [weak self] fraction in
            guard let self else { return }
            self.delegate?.decoder(self, didUpdateDownloadProgress: fraction)
        }
        formatContext?.onPreparationState = { [weak self] state in
            guard let self, !self.closed else { return }
            self.delegate?.decoder(self, didChangePreparationState: state)
        }
        formatContext?.setupSync(timeoutSeconds: FTPlayerSDKConfiguration.Playback.openTimeoutSeconds, useCache: useCache)
        loadControlLock.withLock { packetLoadControl = FTPlayerLoadControl(configuration:loadControlConfiguration,video:formatContext?.videoEnable == true,audio:formatContext?.audioEnable == true) }
        if let formatError = formatContext?.error {
            error = formatError
            delegateErrorCallback()
            return
        }
        guard !closed, let fc = formatContext else { return }
        if fc.videoEnable {
            guard let codecContext = fc.videoCodecContext else {
                error = NSError(domain: "FTDecoder", code: -1, userInfo: [NSLocalizedDescriptionKey: "video codec context unavailable"])
                delegateErrorCallback()
                return
            }
            delegate?.decoder(self, didChangePreparationState: .creatingVideoDecoder)
            videoDecoder = FTVideoDecoder(codecContext: codecContext, timebase: fc.videoTimebase, fps: fc.videoFPS, delegate: self, policy: videoDecodingPolicy)
            videoDecoder?.timestampOffset = fc.startTime
            videoDecoder?.source = self
            if videoDecodingPolicy == .hardware, !videoDecoder!.prepareRequiredHardware() {
                error = NSError(domain: "FTPlayer.VideoDecoder", code: -2001, userInfo: [NSLocalizedDescriptionKey: "Required hardware decoder unavailable: \(videoDecoder!.hardwareSetupFailure)"])
                delegateErrorCallback()
                return
            }
            videoDecoder?.playbackRate = playbackRate
            delegate?.decoder(self, didChangePreparationState: .videoDecoderCreated)
        }
        if fc.audioEnable {
            guard let codecContext = fc.audioCodecContext else {
                error = NSError(domain: "FTDecoder", code: -1, userInfo: [NSLocalizedDescriptionKey: "audio codec context unavailable"])
                delegateErrorCallback()
                return
            }
            delegate?.decoder(self, didChangePreparationState: .creatingAudioDecoder)
            audioDecoder = FTAudioDecoder.decoder(codecContext: codecContext, timebase: fc.audioTimebase, delegate: self)
        }
        if fc.audioEnable { delegate?.decoder(self, didChangePreparationState: .audioDecoderCreated) }
        delegate?.decoder(self, didChangePreparationState: .creatingClock)
        audioDecoder?.timestampOffset = fc.startTime
        if fc.audioEnable {
            playbackClock = FTAudioMasterClock(rate: playbackRate)
        } else {
            playbackClock = FTSystemMasterClock(startTime: 0, rate: playbackRate)
        }

        guard !closed else { return }
        delegate?.decoder(self, didChangePreparationState: .clockCreated)
        prepareToDecode = true
        delegate?.decoderDidPrepareToDecodeFrames(self)
        guard !closed else { return }
        setupReadPacketOperation()
    }

    private func hasBufferingTimedOut() -> Bool {
        let target = seekPreroll.videoTarget
        // Software decoding a long/high-resolution GOP can take longer than
        // the timeout. Advancing preroll PTS is progress even before the first
        // requested frame can be presented; a stalled PTS still expires.
        return bufferingWatchdog.hasTimedOut(at: CACurrentMediaTime(), timeout: bufferingTimeout,
            waitingForNetwork: formatContext?.isWaitingForCacheNetwork == true,
            prerollEpoch: target?.epoch, prerollPosition: target == nil ? nil : videoDecoder?.peekFrame()?.position)
    }

    private var reportedFirstPacket = false
    private var reportedFirstVideoPacket = false
    private func readPacketThread() {
        if !reportedFirstPacket { delegate?.decoder(self, didChangePreparationState: .readingPackets) }
        videoDecoder?.flush()
        audioDecoder?.flush()
        reading = true
        var finished = false
        
        while !finished {
            var packet = av_packet_alloc()
            if closed || error != nil {
                av_packet_free(&packet)
                break
            }
            if let request = seekController.take() {
                let capturedSeekTime = request.time
                let capturedHandler = request.completion
                reading = true
                vsyncDriver?.suspend()
                _systemClockAnchored = false
                _systemClockAnchorTarget = capturedSeekTime
                endOfFile = false
                packetCapacityLimited = false
                playbackFinished = false
                buffering = true
                seekPreroll.begin(time: capturedSeekTime, hasAudio: formatContext?.audioEnable == true,
                                  hasVideo: formatContext?.videoEnable == true)
                audioDecoder?.flush()
                // Clear the old EOF before publishing the flush marker. Otherwise
                // the codec thread can drain an empty new epoch before packets arrive
                // and never drain the delayed tail when the new seek reaches EOF.
                videoDecoder?.endOfFile = false
                videoDecoder?.flush()
                let seekSucceeded = formatContext?.seekFile(withFFTimebase: capturedSeekTime) ?? false
                playbackClock?.seek(to: capturedSeekTime)
                videoDecoder?.paused = false
                videoDecoder?.endOfFile = false
                audioTimeClockLock.withLock { _audioTimeClock = progress }
                if formatContext?.audioEnable == true {
                    _postSeekGraceActive = true
                    _postSeekGraceTarget = capturedSeekTime
                }
                currentVideoFrame?.stopPlaying()
                currentVideoFrame = nil
                currentAudioFrame = nil
                vsyncDriver?.resume()
                updateBufferedDurationByVideo()
                updateBufferedDurationByAudio()
                audioFrameLock.lock()
                audioSeekInProgress = seeking
                audioFrameLock.unlock()
                FTPlayerDiagnostic.shared.record("info", "rate", "engine seek performed", fields: [
                    "engine": diagnosticID, "seekRevision": request.revision,
                    "target": capturedSeekTime, "success": seekSucceeded, "state": rateDiagnosticFields
                ])
                capturedHandler?(seekSucceeded && !closed)
                av_packet_free(&packet)
                continue
            }
            if selectAudioTrack {
                if formatContext?.selectAudioTrackIndex(selectAudioTrackIndex) == nil {
                    audioDecoder?.destroy()
                    audioDecoder = FTAudioDecoder.decoder(codecContext: formatContext!.audioCodecContext!, timebase: formatContext!.audioTimebase, delegate: self)
                    if !playbackFinished {
                        seek(to: audioTimeClock)
                    }
                }
                selectAudioTrack = false
                selectAudioTrackIndex = 0
                av_packet_free(&packet)
                continue
            }
            if endOfFile {
                // Stay available for a seek even if it races the final packet read.
                // Stop interrupts within this short idle interval; no network I/O here.
                reading = false
                av_packet_free(&packet)
                Thread.sleep(forTimeInterval: FTPlayerSDKConfiguration.Playback.seekReadPollInterval)
                continue
            }
            reading = true
            let size: Int = Int(audioDecoder?.size() ?? 0)
            let packetSize = (videoDecoder?.packetSize() ?? 0)
            // Common to local/progressive/HLS/native inputs. Disk read-ahead is
            // separate; retain the existing decoder RAM safety limit as well.
            // Video-only buffer otherwise refreshes only on packet input, so a reader
            // stopped at the load target would wait for an empty queue (a rebuffer).
            updateBufferedDurationByVideo()
            let keepLoading = loadControlLock.withLock { packetLoadControl.shouldLoad(mediaAhead:bufferedDuration,bytesAhead:Int64(size+packetSize),rate:playbackRate) }
            if !keepLoading || size + packetSize >= Self.packetBufferLimit {
                packetCapacityLimited = true
                checkBufferingStatus()
                let interval = paused ? FTPlayerSDKConfiguration.Playback.pausedPacketQueuePollInterval : FTPlayerSDKConfiguration.Playback.fullPacketQueuePollInterval
                Thread.sleep(forTimeInterval: interval)
                av_packet_free(&packet)
                continue
            }
            packetCapacityLimited = false
            let result = formatContext?.readFrame(packet)
            // Some demuxers return a short/corrupt packet rather than a negative
            // result when seek interrupts an in-flight read. Never submit data
            // from that canceled epoch to either decoder.
            if seeking {
                Console.log("discard interrupted seek read result=\(result ?? -1) packetBytes=\(packet?.pointee.size ?? 0)")
                av_packet_free(&packet)
                continue
            }
            if (result ?? -1) < 0 {
                av_packet_free(&packet)
                if let failure = formatContext?.error {
                    error = failure; delegateErrorCallback(); finished = true; break
                }
                if result == FT_AVERROR_EOF {
                    endOfFile = true
                    videoDecoder?.endOfFile = true
                    // EOF can arrive after the last buffer-duration update. Release
                    // startup/seek buffering even when the remaining tail is shorter
                    // than the rate-scaled threshold, so queued frames can be consumed.
                    checkBufferingStatus()
                    delegate?.decoderDidEndOfFile(self)
                    continue
                }
                Console.log(type: .ERROR, "av_read_frame result=\(result ?? -1) retryPosition=\(progress)")
                // Network / IO error — sleep và tự reconnect, không thoát thread
                Thread.sleep(forTimeInterval: FTPlayerSDKConfiguration.Playback.readFailureRetryInterval)
                if closed { finished = true; break }
                if hasBufferingTimedOut() {
                    error = NSError(domain: "FTDecoder", code: -3,
                                    userInfo: [NSLocalizedDescriptionKey: "Buffering timeout"])
                    delegateErrorCallback()
                    finished = true
                    break
                }
                let retryPosition = progress
                audioDecoder?.flush()
                videoDecoder?.flush()
                formatContext?.seekFile(withFFTimebase: retryPosition)
                updateBufferedDurationByAudio()
                updateBufferedDurationByVideo()
                continue
            }
            if !reportedFirstPacket {
                reportedFirstPacket = true
                delegate?.decoder(self, didChangePreparationState: .firstPacketRead)
            }
            let videoIdx = formatContext?.videoTrack?.index
            let audioIdx = formatContext?.audioTrack?.index
            let streamIndex : Int = Int(packet?.pointee.stream_index ?? -1)
            if streamIndex == videoIdx {
                if !reportedFirstVideoPacket {
                    reportedFirstVideoPacket = true
                    delegate?.decoder(self, didChangePreparationState: .decodingFirstFrame)
                }
                videoDecoder?.putPacket(packet)
                updateBufferedDurationByVideo()
            } else if streamIndex == audioIdx {
                let audioMinimum = seekPreroll.audioTarget.map { $0.time - FTPlayerSDKConfiguration.Precision.seekPrerollTolerance }
                let audioResult = audioDecoder?.putPacket(packet, minimumPresentationTime: audioMinimum) ?? -1
                av_packet_free(&packet)
                if audioResult < 0 {
//                    error = FTCheckErrorCode(result!, errorCode: FTDecoderErrorCode.codecAudioSendPacket.rawValue)
//                    delegateErrorCallback()
                    continue
                }
                updateBufferedDurationByAudio()
            }
            else {
                av_packet_free(&packet)
            }
        }
        reading = false
        checkBufferingStatus()
    }

    // MARK: - VSync frame selection (Phase 3)

    private func vsyncTick(_ targetTimestamp: TimeInterval) {
        guard !closed, !seeking, !audioSeekInProgress, !playbackFinished, error == nil else { return }
        displayTicks += 1
        let presentationSeekTarget = seekPreroll.videoTarget
        if presentationSeekTarget != nil {
            discardSeekVideoPreroll()
            updateBufferedDurationByVideo()
            checkBufferingStatus()
        }

        // Update audio bufferedDuration on every vsync so checkBufferingStatus fires even
        // while readPacketThread is blocked in readFrame waiting on network I/O.
        updateBufferedDurationByAudio()
        guard !playbackFinished else { return }
        checkNetworkVideoStarvation()
        if buffering {
            // Audio may be ahead after a high-rate seek. Free stale decoded video
            // even while clocks are paused, otherwise a full video queue prevents
            // packet reading from refilling audio and buffering can never end.
            if !paused && formatContext?.audioEnable == true { fastForwardQueueToCurrentClock() }
            if hasBufferingTimedOut() {
                error = NSError(domain: "FTDecoder", code: -3,
                                userInfo: [NSLocalizedDescriptionKey: "Buffering timeout"])
                delegateErrorCallback()
            }
            return
        }
        guard let decoder = videoDecoder else { return }

        if paused {
            if let frame = currentVideoFrame { videoOutput?.send(video: frame, from: self) }
            return
        }

        // Post-seek grace: end when audio clock has advanced past seek target
        if _postSeekGraceActive && seekPreroll.videoTarget == nil && audioTimeClock > _postSeekGraceTarget + FTPlayerSDKConfiguration.Playback.postSeekAudioAdvance {
            _postSeekGraceActive = false
        }

        checkAVDriftIfNeeded()

        if !_systemClockAnchored, formatContext?.audioEnable == false,
           let firstFrame = decoder.peekFrame() {
            if let target = _systemClockAnchorTarget, firstFrame.position + firstFrame.duration < target - FTPlayerSDKConfiguration.Precision.seekPrerollTolerance {
                decoder.getFrameAsync()?.cancel()
                return
            }
            playbackClock?.seek(to: _systemClockAnchorTarget ?? firstFrame.position)
            _systemClockAnchorTarget = nil
            activateGracePeriod(duration: FTPlayerSDKConfiguration.Playback.firstVideoGrace, multiplier: FTPlayerSDKConfiguration.Playback.firstVideoGraceMultiplier)
            _systemClockAnchored = true
        }

        let clockTime = playbackClock?.currentTime ?? 0
        // Do not use an old clock to skip new seek preroll/reference pictures.
        decoder.presentationTime = (_postSeekGraceActive || seekPreroll.videoTarget != nil) ? nil : clockTime
        if formatContext?.audioEnable == false && _systemClockAnchored || audioTailClockActive || audioGapClockActive {
            // UI progress follows the continuous media clock, even when fast playback
            // displays sparse keyframes. Last displayed PTS can be seconds apart.
            progress = min(duration, max(0, clockTime))
        }

        // A successful VT output callback supplies a decoded, readable pixel buffer.
        // IOSurfaceIsInUse counts other users; it is not a GPU write-completion fence.
        // Holding every retained surface for two refreshes throttled 60 fps to 40 fps
        // on a 120 Hz display and discarded otherwise ready B pictures.
        let dropThresh = _postSeekGraceActive
            ? FTPlayerSDKConfiguration.Playback.postSeekDropThreshold * max(1.0, Double(playbackRate) / FTPlayerSDKConfiguration.Playback.postSeekDropRateDivisor)
            : vsyncDropThreshold(rate: playbackRate)
        // Drain late frames in this tick. Dropping only one frame per display refresh
        // cannot catch up with a 60 fps stream at 2x+, leaving the last image frozen.
        // Bound work so a decoder refilling concurrently cannot monopolize the UI.
        // At fast rates select the newest decoded picture already due. A dense
        // queue created at 1x must not continue as FIFO throughout rate-change
        // grace, which can consume an entire short clip with a stale picture.
        var latestDue: FTVideoFrame?
        defer {
            if let frame = latestDue {
                if frame.position > (currentVideoFrame?.position ?? -.infinity) {
                    vsyncRender(frame, decoder: decoder, seekTarget: presentationSeekTarget)
                } else { frame.cancel(); lateVideoDrops += 1 }
            }
        }
        for _ in 0..<FTPlayerSDKConfiguration.Playback.maximumVideoWorkPerTick {
            guard let frame = decoder.peekFrame() else {
                if decoder.frameEmpty() { updateBufferedDurationByVideo() }
                finishPlaybackIfDrained()
                return
            }
            let frameDur = frame.duration > 0 ? frame.duration : (1.0 / decoder.fps)
            let earlyGap = frame.position - clockTime
            let lag = clockTime - (frame.position + frameDur)
            // Half a frame rounds to the nearest display tick; a sparse 1 s still must not appear 0.5 s early.
            let earlyLimit = min(FTPlayerSDKConfiguration.Playback.earlyFrameDurationFraction * frameDur,
                                 FTPlayerSDKConfiguration.Playback.maximumEarlyFrameLead)
            if earlyGap > earlyLimit { return }
            if playbackRate >= FTPlayerSDKConfiguration.Video.samplingRateThreshold || lag > dropThresh {
                guard let frame = decoder.getFrameAsync() else { continue }
                if playbackRate >= FTPlayerSDKConfiguration.Video.samplingRateThreshold {
                    if let previous = latestDue {
                        if frame.position > previous.position {
                            previous.cancel(); latestDue = frame
                        } else { frame.cancel() }
                        lateVideoDrops += 1
                    } else { latestDue = frame }
                } else { frame.cancel(); lateVideoDrops += 1 }
                continue
            }
            guard let frame = decoder.getFrameAsync() else { return }
            if let late = latestDue { late.cancel(); latestDue = nil; lateVideoDrops += 1 }
            vsyncRender(frame, decoder: decoder, seekTarget: presentationSeekTarget)
            if endOfFile { updateBufferedDurationByVideo() }
            return
        }
    }

    private func checkNetworkVideoStarvation() {
        // Audio packets can be interleaved well ahead of a large video picture.
        // An audio-only buffer metric then keeps reporting playing while video
        // has no input and the cache read is blocked on the network.
        guard !buffering, !paused, !endOfFile, formatContext?.audioEnable == true,
              formatContext?.isWaitingForCacheNetwork == true,
              let decoder = videoDecoder, decoder.empty(), let frame = currentVideoFrame,
              let videoEnd = formatContext?.knownProgressiveVideoEndTime,
              frame.position + frame.duration < videoEnd - FTPlayerSDKConfiguration.Playback.networkVideoEndTolerance,
              (playbackClock?.currentTime ?? 0) > frame.position + frame.duration else {
            networkVideoStarvationBegan = nil
            return
        }
        let now = CACurrentMediaTime()
        if networkVideoStarvationBegan == nil { networkVideoStarvationBegan = now }
        guard now - networkVideoStarvationBegan! >= FTPlayerSDKConfiguration.Playback.networkVideoStarvationDelay else { return }
        waitingForNetworkVideo = true
        buffering = true
    }

    private func discardSeekVideoPreroll() {
        guard let target = seekPreroll.videoTarget, let decoder = videoDecoder else { return }
        // Free reference-picture preroll in batches while the master clock is
        // paused, rather than spending real playback time on pre-seek frames.
        for _ in 0..<FTPlayerSDKConfiguration.Playback.maximumVideoWorkPerTick {
            guard let frame = decoder.peekFrame(),
                  PlaybackSeekPreroll.isBeforeTarget(position: frame.position, duration: frame.duration, target: target) else { return }
            // Audio can outlast video. Keep the newest preroll picture until we
            // know whether another picture follows; at drained EOF it is the
            // correct still image for a seek into the audio-only tail.
            if decoder.frameCount() == 1 {
                if endOfFile && decoder.packetEmpty() && !decoder.decoding,
                   let last = decoder.getFrameAsync() {
                    seekPreroll.finishVideo(target)
                    vsyncRender(last, decoder: decoder, seekTarget: nil)
                }
                return
            }
            decoder.getFrameAsync()?.cancel()
        }
    }

    private func vsyncRender(_ raw: FTVideoFrame?, decoder: FTVideoDecoder, seekTarget: PlaybackSeekPreroll.Target?) {
        guard let f = raw else { return }
        currentVideoFrame?.stopPlaying()
        currentVideoFrame = f
        f.startPlaying()
        if let target = seekTarget,
           !PlaybackSeekPreroll.isBeforeTarget(position: f.position, duration: f.duration, target: target) {
            seekPreroll.finishVideo(target)
        }
        videoOutput?.send(video: f, from: self)
        updateProgressByVideo()
    }

    private func vsyncDropThreshold(rate: Float) -> TimeInterval {
        // VTB pipeline delay ≈ N frame durations in wall time (B-frame reorder + buffer).
        // Threshold in wall time is rate-independent; multiply by rate to get media time.
        let fps = videoDecoder?.fps ?? FTPlayerSDKConfiguration.Playback.fallbackVideoFPS
        let base = (FTPlayerSDKConfiguration.Playback.videoDropToleranceFrames / fps) * Double(rate)
        return CACurrentMediaTime() < _gracePeriodEnd ? base * _gracePeriodMultiplier : base
    }

    func activateGracePeriod(duration: TimeInterval = FTPlayerSDKConfiguration.Playback.audioRateChangeGrace, multiplier: Double = FTPlayerSDKConfiguration.Playback.audioRateChangeGraceMultiplier) {
        _gracePeriodEnd = CACurrentMediaTime() + duration
        _gracePeriodMultiplier = multiplier
    }

    private func fastForwardQueueToCurrentClock() {
        // Seek preroll owns these reference pictures. In an audio-only tail,
        // its final video picture must survive until EOF confirms it is last.
        // Audio-clock catch-up must not empty that queue while decode is busy.
        guard seekPreroll.videoTarget == nil else { return }
        let target = audioTimeClock - FTPlayerSDKConfiguration.Playback.audioCatchUpLead
        for _ in 0..<FTPlayerSDKConfiguration.Playback.maximumVideoWorkPerTick {
            guard let peeked = videoDecoder?.peekFrame(), peeked.position < target else { break }
            videoDecoder?.getFrameAsync()?.cancel()
        }
    }

    private func checkAVDriftIfNeeded() {
        guard formatContext?.audioEnable == true else { return }
        guard !_postSeekGraceActive, let currentFrame = currentVideoFrame else { return }
        let now = CACurrentMediaTime()
        guard now >= _driftCheckNext else { return }
        _driftCheckNext = now + FTPlayerSDKConfiguration.Playback.driftCheckInterval

        let clock = audioTimeClock
        let videoPTS = currentFrame.position
        let drift = clock - videoPTS

        if abs(drift) < FTPlayerSDKConfiguration.Playback.acceptableAVDrift {
            // OK — no action
        } else if abs(drift) < FTPlayerSDKConfiguration.Playback.moderateAVDrift {
            // Only compare against previous above-threshold reading to avoid false "growing" detection
            let driftChange = abs(abs(drift) - abs(_prevDrift))
            _prevDrift = drift
            if driftChange < FTPlayerSDKConfiguration.Playback.acceptableDriftGrowth {
            } else {
                activateGracePeriod(duration: FTPlayerSDKConfiguration.Playback.driftGrace, multiplier: FTPlayerSDKConfiguration.Playback.driftGraceMultiplier)
            }
        } else {
            _prevDrift = drift
            fastForwardQueueToCurrentClock()
        }
    }


    func pause() {
        videoDecoder?.presentationTime = nil
        paused = true
        playbackClock?.setPaused(true)
    }

    func resume() {
        paused = false
        if !buffering {
            playbackClock?.setPaused(false)
        }
        if playbackFinished {
            seek(to: 0)
        }
    }

    func seek(to time: TimeInterval, completeHandler: ((Bool) -> Void)? = nil) {
        guard seekEnable, error == nil, !closed else {
            completeHandler?(false)
            return
        }
        audioFrameLock.lock()
        defer { audioFrameLock.unlock() }
        audioSeekInProgress = true
        waitingForNetworkVideo = false
        // Resume must not replace an accepted explicit seek with replay at zero.
        playbackFinished = false
        // Pause the codec before publishing the request: once enqueued, the read
        // thread may take it and unpause first, and a later pause would stick.
        videoDecoder?.presentationTime = nil
        videoDecoder?.paused = true
        let target = seekController.enqueue(time: time, minimum: 0, duration: duration,
                                            completion: completeHandler)
        FTPlayerDiagnostic.shared.record("info", "rate", "engine seek accepted", fields: [
            "engine": diagnosticID, "seekRevision": seekController.revision,
            "requested": time, "target": target, "rate": playbackRate
        ])
        lastAudioEnd = target
        formatContext?.cancelPendingReads()
        self.progress = target
        if endOfFile {
            setupReadPacketOperation()
        }
    }

    func fetchAudioFrame() -> FTAudioFrame? {
        // An audio callback that began before seek must finish before the new
        // target is published; it cannot overwrite that target with an old PTS.
        guard audioFrameLock.try() else { return nil }
        defer { audioFrameLock.unlock() }
        if closed || seeking || audioSeekInProgress || buffering || paused || playbackFinished || formatContext?.audioEnable != true {
            return nil
        }
        // Use non-blocking getFrameAsync so the CoreAudio render thread is never blocked.
        // getFrameSync can call NSCondition.wait() if flush() races with this call,
        // causing the render thread to stall → audio crackling.
        currentAudioFrame = nil
        let audioPrerollTarget = seekPreroll.audioTarget
        // Bound work on the render thread. If a very long preroll needs another
        // callback, return silence without advancing the audio master clock.
        for _ in 0..<FTPlayerSDKConfiguration.Playback.maximumAudioPrerollFramesPerCallback {
            guard let frame = audioDecoder?.peekFrame() else { break }
            if let target = audioPrerollTarget {
                if PlaybackSeekPreroll.isBeforeTarget(position: frame.position, duration: frame.duration, target: target) {
                    audioDecoder?.getFrameAsync()?.cancel()
                    continue
                }
            }
            if isHeldUntilDue(frame), let clock = playbackClock as? FTAudioMasterClock {
                // Return silence while preserving the clock's interpolation.
                // Keep future PCM queued until its timestamp is actually due.
                let position = min(duration, max(progress, clock.consumptionTime))
                progress = position
                audioTimeClockLock.withLock { _audioTimeClock = position }
                updateBufferedDurationByAudio()
                return nil
            }
            currentAudioFrame = audioDecoder?.getFrameAsync()
            if let target = audioPrerollTarget, let frame = currentAudioFrame {
                // Keep codec preroll, but do not play the prefix of a PCM frame
                // that straddles the requested time. Otherwise its older PTS
                // rewinds the target already published by seek().
                if !frame.trimStart(to: target.time, samplingRate: audioOutput?.samplingRate ?? 0,
                                    channels: audioOutput?.numberOfChannels ?? 0) {
                    frame.cancel(); currentAudioFrame = nil
                    continue
                }
                seekPreroll.finishAudio(target)
            }
            break
        }
        if currentAudioFrame == nil {
            updateBufferedDurationByAudio()
            if audioGapClockActive, let clock = playbackClock as? FTAudioMasterClock {
                // The audio renderer supplies silence when no PCM is returned.
                // Keep interpolation through buffered video, preserving this
                // audio track for packets that may arrive in later periods.
                let position = min(duration, max(progress, clock.currentTime))
                progress = position
                audioTimeClockLock.withLock { _audioTimeClock = position }
                return nil
            }
            // Re-anchor wall time so clock doesn't over-advance during audio decoder gaps.
            // Without this, wallElapsed grows up to ~174ms → clockTime jumps ahead → video renders early.
            if !audioTailClockActive { playbackClock?.resetInterpolation() }
            return nil
        }
        if endOfFile {
            updateBufferedDurationByAudio()
        }
        updateProgressByAudio()
        let pts = currentAudioFrame?.position ?? 0
        lastAudioEnd = pts + (currentAudioFrame?.duration ?? 0)
        audioTimeClockLock.withLock { _audioTimeClock = pts }
        if let clock = playbackClock as? FTAudioMasterClock {
            clock.updateFromAudio(pts: pts, frameDuration: currentAudioFrame?.duration ?? 0)
        } else {
            playbackClock?.seek(to: pts)
        }
        return currentAudioFrame
    }

    func closeFile() {
        closeFileAsync(true)
    }

    func closeFileWithCompletion(_ completion: @escaping () -> Void) {
        closeFileAsync(true, completion: completion)
    }

    private func closeFileAsync(_ async: Bool, completion: (() -> Void)? = nil) {
        if closed {
            completion?()
            return
        }
        closed = true
        seekController.cancel()
        formatContext?.cancelPendingReads()
        videoDecoder?.destroy()
        audioDecoder?.destroy()
        if async {
            DispatchQueue.global().async { [self] in
                self.ffmpegOperationQueue?.cancelAllOperations()
                self.ffmpegOperationQueue?.waitUntilAllOperationsAreFinished()
                self.closePropertyValue()
                self.formatContext?.destroy()
                self.closeOperation()
                completion?()
            }
        } else {
            ffmpegOperationQueue?.cancelAllOperations()
            ffmpegOperationQueue?.waitUntilAllOperationsAreFinished()
            closePropertyValue()
            formatContext?.destroy()
            closeOperation()
            completion?()
        }
    }

    private func closePropertyValue() {
        vsyncDriver?.stop()
        vsyncDriver = nil
        seekPreroll.reset()
        buffering = false
        paused = false
        prepareToDecode = false
        endOfFile = false
        playbackFinished = false
        currentVideoFrame?.stopPlaying()
        currentVideoFrame = nil
        currentAudioFrame = nil
        lastAudioEnd = 0
        videoDecoder?.paused = false
        videoDecoder?.endOfFile = false
        selectAudioTrack = false
        selectAudioTrackIndex = 0
    }

    private func closeOperation() {
        readPacketOperation = nil
        openFileOperation = nil
        decodeFrameOperation = nil
        ffmpegOperationQueue = nil
    }

    private var reachedVideoEndTime: Bool {
        guard duration > 0, duration < FTPlayerSDKConfiguration.Demux.maximumIndexedDuration else { return true }
        return (playbackClock?.currentTime ?? progress) >= duration - FTPlayerSDKConfiguration.Playback.finishTolerance
    }

    private func finishPlaybackIfDrained() {
        guard !playbackFinished, !closed, !paused, !seeking, !audioSeekInProgress,
              endOfFile, bufferedDuration <= 0, audioFrameLock.try() else { return }
        defer { audioFrameLock.unlock() }
        guard !paused, !seeking, !audioSeekInProgress else { return }
        if formatContext?.audioEnable == true {
            // Removing the last PCM from the queue is not consumption: the
            // render callback still owns it. The next fetch retires that frame.
            guard currentAudioFrame == nil, audioDecoder?.isEmpty() != false, videoOutputDrained else { return }
        } else {
            guard reachedVideoEndTime else { return }
        }
        playbackFinished = true
    }

    private var videoOutputDrained: Bool {
        guard let videoDecoder else { return true }
        guard seekPreroll.videoTarget == nil, videoDecoder.empty(), !videoDecoder.decoding else { return false }
        guard let frame = currentVideoFrame else { return true }
        return (playbackClock?.currentTime ?? progress) >= frame.position + frame.duration - FTPlayerSDKConfiguration.Playback.finishTolerance
    }

    private var audioTailClockActive: Bool {
        endOfFile && formatContext?.audioEnable == true && currentAudioFrame == nil &&
            (audioDecoder?.duration() ?? 0) <= 0 && videoDecoder != nil
    }

    private var audioGapClockActive: Bool {
        formatContext?.audioEnable == true && currentAudioFrame == nil &&
            audioDecoder?.isEmpty() == true && videoCanBridgeAudioGap
    }

    /// PCM after an audio gap stays queued until the clock reaches it (fetchAudioFrame).
    private func isHeldUntilDue(_ frame: FTAudioFrame) -> Bool {
        let gapThreshold = max(FTPlayerSDKConfiguration.Playback.minimumAudioGap, frame.duration * FTPlayerSDKConfiguration.Playback.audioGapDurationMultiplier)
        guard frame.position > lastAudioEnd + gapThreshold, let clock = playbackClock as? FTAudioMasterClock else { return false }
        return clock.consumptionTime < frame.position
    }

    /// The read-ahead decodes an event's first PCM long before it is due. Until then
    /// video still bridges the gap, so that PCM must not count as the playback buffer.
    private var videoBuffersAudioGap: Bool {
        if audioGapClockActive { return true }
        guard formatContext?.audioEnable == true, currentAudioFrame == nil,
              let frame = audioDecoder?.peekFrame(), isHeldUntilDue(frame) else { return false }
        return videoCanBridgeAudioGap
    }

    private var videoCanBridgeAudioGap: Bool {
        guard let videoDecoder, videoDecoder.peekFrame() != nil else { return false }
        // Metadata alone does not guarantee PCM. Only ready video with enough
        // buffered media can bridge a gap. EOF/packet pressure also allow ready
        // video to drain; network/video starvation still buffers normally.
        return videoDecoder.duration() >= minBufferedDuration || endOfFile || packetCapacityLimited
    }

    private func checkBufferingStatus() {
        bufferingStateLock.lock()
        defer { bufferingStateLock.unlock() }
        guard error == nil else { return }
        // Under packet pressure, playing ready output is the only way to admit
        // more input. Apply the SAME exemption on entry and exit: otherwise a
        // 32 ms PCM queue qualifies both to rebuffer and to leave buffering on
        // consecutive ticks. Include PCM already handed to the audio renderer;
        // pausing before its next fetch prevents that last frame from retiring.
        let decodedReady = formatContext?.audioEnable == true
            ? (audioDecoder?.duration() ?? 0) > 0 || currentAudioFrame != nil || audioGapClockActive
            : videoDecoder?.peekFrame() != nil
        let canDrainAtCapacity = packetCapacityLimited && decodedReady
        if buffering {
            // Receiving more audio alone cannot resolve a video starvation.
            // The declared video tail is excluded when entering this state.
            if waitingForNetworkVideo, !endOfFile, videoDecoder?.peekFrame() == nil { return }
            if let target = seekPreroll.videoTarget {
                let ready = videoDecoder?.peekFrame().map {
                    !PlaybackSeekPreroll.isBeforeTarget(position: $0.position, duration: $0.duration, target: target)
                } ?? false
                let drained = endOfFile && videoDecoder?.empty() == true && videoDecoder?.decoding == false
                guard ready || drained else { return }
                if drained { seekPreroll.finishVideo(target) }
            }
            // Video-only seeks also discard reference-picture preroll. A cached
            // interval may have enough target frames but less than the startup
            // threshold after those earlier pictures are removed, with the next
            // bytes temporarily offline. Use the seek threshold until first output.
            let threshold = (_postSeekGraceActive || seekPreroll.videoTarget != nil)
                ? postSeekBufferedDuration : minBufferedDuration
            // High bitrate can fill the byte budget before the rate-scaled
            // startup/rebuffer duration is reachable. Once decoded media is
            // ready, consuming it is the only way to admit more packets.
            if bufferedDuration >= threshold || endOfFile || canDrainAtCapacity {
                if audioGapClockActive {
                    // Time spent opening/probing must not advance playback.
                    playbackClock?.seek(to: progress)
                }
                waitingForNetworkVideo = false
                buffering = false
            }
        } else if bufferedDuration <= FTPlayerSDKConfiguration.Playback.rebufferMediaThreshold && !endOfFile && !canDrainAtCapacity {
            buffering = true
        }
    }

    private func updateBufferedDurationByVideo() {
        if formatContext?.audioEnable == false || videoBuffersAudioGap {
            bufferedDuration = videoDecoder?.duration() ?? 0.0
        }
    }

    private func updateBufferedDurationByAudio() {
        if formatContext?.audioEnable == true {
            bufferedDuration = videoBuffersAudioGap ? videoDecoder?.duration() ?? 0 : audioDecoder?.duration() ?? 0
        }
    }

    private func updateProgressByVideo() {
        if !playbackFinished, formatContext?.audioEnable == false && formatContext?.videoEnable == true {
            let timeline = playbackClock?.currentTime ?? currentVideoFrame?.position ?? 0
            progress = min(duration, max(0, timeline))
        }
    }

    private func updateProgressByAudio() {
        if !playbackFinished, formatContext?.audioEnable == true {
            progress = currentAudioFrame?.position ?? 0
        }
    }

    private func delegateErrorCallback() {
        guard let error else { return }
        let send = errorCallbackLock.withLock { () -> Bool in
            guard !errorCallbackSent else { return false }
            errorCallbackSent = true; return true
        }
        guard send else { return }
        formatContext?.cancelPendingReads()
        delegate?.decoder(self, didError: error)
    }

    deinit {
        closeFileAsync(false)
    }
}

/// A wall-clock budget shared safely by the packet, display and audio workers.
/// Playback state, seek targets and terminal notifications are never throttled.
private final class PlaybackNotificationThrottle {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var nextTime: TimeInterval = -.infinity
    init(interval: TimeInterval) { self.interval = interval }
    func admit(force: Bool = false) -> Bool {
        let now = CACurrentMediaTime()
        return lock.withLock {
            guard force || now >= nextTime else { return false }
            nextTime = now + interval
            return true
        }
    }
}

// MARK: - Extensions and Utility Functions

extension DispatchQueue {
    private static var onceTracker = [String]()

    class func once(token: String, block: () -> Void) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        if onceTracker.contains(token) {
            return
        }
        onceTracker.append(token)
        block()
    }
}

extension FTDecoder: FTFormatContextDelegate {
    public func formatContextNeedInterrupt(_ formatContext: FTFormatContext) -> Bool {
        return closed || seeking
    }
}

extension FTDecoder: FTAudioDecoderDelegate {
    func audioDecoder(_ audioDecoder: FTAudioDecoder, samplingRate: inout Float64) {
        samplingRate = audioOutput?.samplingRate ?? 0
    }
    
    func audioDecoder(_ audioDecoder: FTAudioDecoder, channelCount: inout UInt32) {
        channelCount = audioOutput?.numberOfChannels ?? 0
    }
}

extension FTDecoder: FTVideoDecoderDelegate {
    func videoDecoderDidDecodeFirstFrame(_ videoDecoder: FTVideoDecoder) {
        guard !closed else { return }
        delegate?.decoder(self, didChangePreparationState: .firstFrameDecoded)
        delegate?.decoder(self, didChangePreparationState: .waitingForFirstFrame)
    }

    func videoDecoderNeedUpdateBufferedDuration(_ videoDecoder: FTVideoDecoder) {
        updateBufferedDurationByVideo()
    }

    func videoDecoderNeedCheckBufferingStatus(_ videoDecoder: FTVideoDecoder) {
        checkBufferingStatus()
    }

    func videoDecoder(_ videoDecoder: FTVideoDecoder, didError error: Error) {
        self.error = error
        delegateErrorCallback()
    }
}

extension FTDecoder: FTVideoDecoderDataSource {

    func shouldHandle(_ videoDecoder: FTVideoDecoderInfo, decodeFrame packet: AVPacket) -> Bool {
        return source?.shouldHandle(videoDecoder, decodeFrame: packet) ?? false
    }

    func videoDecoder(_ videoDecoder: FTVideoDecoderInfo, decodeFrame packet: AVPacket) -> FTVideoFrame? {
        return source?.videoDecoder(videoDecoder, decodeFrame: packet)
    }
}


