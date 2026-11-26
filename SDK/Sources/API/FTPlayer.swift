//
//  FTPlayer.swift
//  FFmpeg
//
//  Created by TrucPham on 28/05/2025.
//

import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
/// Public controls, configuration, observations and output bindings are main-thread
/// APIs. Engine/audio callbacks are marshalled asynchronously to that owner.
public class FTPlayer : NSObject {
    private let components: any PlaybackComponentFactory
    /// Applied to the next replaceVideo(), including replay/reopen.
    public var videoDecodingPolicy: FTVideoDecodingPolicy = FTPlayerSDKConfiguration.Playback.decodingPolicy { willSet { requireMainThread() } }
    public var videoDecodingStatistics: FTVideoDecodingStatistics {
        engine?.decodingStatistics ?? FTVideoDecodingStatistics(policy: videoDecodingPolicy, ffmpegFrames: 0, hardwareFrames: 0, videoToolboxSoftwareFrames: 0, videoToolboxUnverifiedFrames: 0)
    }
    /// Poll on the main thread, including when progress has stopped. Independent
    /// of diagnostics logging and the app's videoOutput binding.
    public var videoFrameRateStatistics: FTVideoFrameRateStatistics {
        requireMainThread()
        return frameRateMeter.snapshot(at: ProcessInfo.processInfo.systemUptime, upcoming: upcomingVideoFrameRate())
    }
    private func upcomingVideoFrameRate() -> Double? {
        guard let position = lastOutputVideoPTS else { return nil }
        return engine?.upcomingVideoFrameRate(from: position, window: FTPlayerSDKConfiguration.Playback.upcomingFrameRateWindow)
    }
    private var frameRateMeter = VideoFrameRateMeter()
    /// Opt-in CPU thumbnail analysis; disabled by default. Set on the main thread.
    public var isVideoContentChangeMeasurementEnabled = false {
        didSet {
            requireMainThread()
            if oldValue != isVideoContentChangeMeasurementEnabled {
                contentChangeMeter.reset()
                contentChangeGate.reset()
            }
        }
    }
    /// Approximate changes in output pictures per media second, independent of
    /// diagnostics. This does not identify the camera's recording mode.
    public var videoContentChangeStatistics: FTVideoContentChangeStatistics {
        requireMainThread()
        return contentChangeMeter.snapshot(at: ProcessInfo.processInfo.systemUptime)
    }
    private var contentChangeMeter = VideoContentChangeMeter()
    private func resetVideoMeasurements() {
        frameRateMeter.reset()
        contentChangeMeter.reset()
        frameRateGate.reset()
        contentChangeGate.reset()
        videoMeasurementRevision &+= 1
    }
    private var frameRateGate = VideoStatisticsChangeGate()
    private var contentChangeGate = VideoStatisticsChangeGate()
    private var videoMeasurementRevision = 0
    private func publishVideoStatistics(at now: TimeInterval) {
        guard playing, let observer = videoStatisticsDelegate else { return }
        let revision = videoMeasurementRevision
        let frameRate = frameRateMeter.snapshot(at: now, upcoming: upcomingVideoFrameRate())
        if frameRateGate.shouldDeliver(frameRate.timelineFramesPerSecond, frameRate.upcomingTimelineFramesPerSecond,
                                       at: now, rate: rate) {
            observer.player(self, didChangeVideoFrameRate: frameRate)
        }
        // The app may change rate, seek or stop in the callback; skip values from before that reset.
        guard revision == videoMeasurementRevision, playing, isVideoContentChangeMeasurementEnabled,
              let observer = videoStatisticsDelegate else { return }
        let content = contentChangeMeter.snapshot(at: now)
        if contentChangeGate.shouldDeliver(content.estimatedChangesPerSecond, at: now, rate: rate) {
            observer.player(self, didChangeVideoContentChangeRate: content)
        }
    }
    public weak var delegate: FTPlayerDeletegate? { willSet { requireMainThread() } }
    /// Reports frame-rate and content-change measurement changes; see the protocol.
    public weak var videoStatisticsDelegate: (any FTPlayerVideoStatisticsDelegate)? { willSet { requireMainThread() } }
    /// Each narrow observer overrides the legacy delegate only for its event group.
    public weak var playbackDelegate: (any FTPlayerPlaybackDelegate)? { willSet { requireMainThread() } }
    public weak var progressDelegate: (any FTPlayerProgressDelegate)? { willSet { requireMainThread() } }
    public weak var preparationDelegate: (any FTPlayerPreparationDelegate)? { willSet { requireMainThread() } }
    private var playbackObserver: (any FTPlayerPlaybackDelegate)? { playbackDelegate ?? delegate }
    private var progressObserver: (any FTPlayerProgressDelegate)? { progressDelegate ?? delegate }
    private var preparationObserver: (any FTPlayerPreparationDelegate)? { preparationDelegate ?? delegate }
    private let traceID = UUID().uuidString
    private let telemetry = PlaybackTelemetry()
    private let lifecycle = PlaybackLifecycleController()
    private let audioFormat = PlaybackAudioFormat()
    private let eventGate = PlaybackEventGate()
    private let progressEventGate = PlaybackEventGate()
    private var publishingSeekProgress = false
    private final class SeekCompletion {
        let generation: Int
        weak var engine: (any PlaybackEngine)?
        let target: TimeInterval
        let began = ProcessInfo.processInfo.systemUptime
        var demuxSucceeded = false // Main-thread state, independent of native acknowledgement.
        private let lock = NSLock()
        private var completed = false
        private var handler: ((Bool) -> Void)?
        private let isCurrent: () -> Bool
        init(generation: Int, engine: any PlaybackEngine, target: TimeInterval, handler: ((Bool) -> Void)?, isCurrent: @escaping () -> Bool) {
            self.generation = generation; self.engine = engine; self.target = target; self.handler = handler
            self.isCurrent = isCurrent
        }
        func complete(_ success: Bool) {
            let callback = lock.withLock { () -> ((Bool) -> Void)? in
                guard !completed else { return nil }
                completed = true
                let callback = handler; handler = nil
                return callback
            }
            let isCurrent = self.isCurrent
            if let callback { DispatchQueue.main.async { callback(success && isCurrent()) } }
        }
    }
    private var pendingSeekCompletion: SeekCompletion?
    private var seekCompletionRevision = 0
    private var generation = 0
    private var failedGeneration: Int?
    private var currentPlaybackFailed: Bool { failedGeneration == generation }
    public var preparationState: FTPlayerPreparationState { preparationWorkflow.state }
    public private(set) var mediaInfo: FTPlayerMediaInfo?
    private let preparationWorkflow = PlaybackPreparationWorkflow()
    private var renderedFrames = 0
    private var lastFrameTime: TimeInterval = 0
    private var lastOutputVideoPTS: TimeInterval?
    private var rateTraceRevision = 0
    // Main-thread counters; progress callbacks never write a log on the audio thread.
    private var progressQueued = 0
    private var progressDelivered = 0
    private var progressInvalidated = 0
    private var progressWithoutObserver = 0
    private var lastProgressQueuedWall: TimeInterval = 0
    private var lastProgressDeliveredWall: TimeInterval = 0
    private var lastProgressDeliveredValue: TimeInterval?
    private func trace(_ message: @autoclosure () -> String) {
        FTPlayerDiagnostic.shared.record("info", "player", message(), fields: ["player": traceID])
    }
    // Events belong to the source generation that queued them. Stop/reopen invalidates
    // pending notifications and pixel buffers before another decoder becomes active.
    private func dispatchEvent(_ event: @escaping (FTPlayer) -> Void) {
        requireMainThread()
        let eventGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == eventGeneration else { return }
            event(self)
        }
    }
    private func receive(from engine: any PlaybackEngine, immediatelyOnMain: Bool = false, _ event: @escaping (FTPlayer) -> Void) {
        guard let token = eventGate.token(for: engine) else { return }
        let delivery = { [weak self] in
            guard let self, self.eventGate.accepts(token), self.engine === engine else { return }
            event(self)
        }
        if immediatelyOnMain && Thread.isMainThread { delivery() }
        else { DispatchQueue.main.async(execute: delivery) }
    }
    private func requireMainThread() {
        precondition(Thread.isMainThread, "FTPlayer must be accessed on the main thread")
    }
    private func beginPreparation() {
        resetVideoMeasurements()
        preparationWorkflow.begin()
        mediaInfo = nil
        dispatchEvent { player in
            player.trace("preparation state=begin")
            player.preparationObserver?.player(player, didChangePreparationState: .begin)
        }
    }

    // Preparation is a forward-only workflow, not a download/time percentage.
    // Late network events from optional concurrent probes cannot rewind the state.
    private func advancePreparation(to state: FTPlayerPreparationState) {
        guard preparationWorkflow.advance(to: state) else { return }
        trace("preparation state=\(state.rawValue)")
        preparationObserver?.player(self, didChangePreparationState: state)
    }

    private func queuePreparation(_ state: FTPlayerPreparationState) {
        dispatchEvent { $0.advancePreparation(to: state) }
    }

    private func startTelemetry() {
        telemetry.start { [weak self] in
            guard let self else { return }
            self.traceRateSnapshot("health")
        }
    }

    private func traceRateSnapshot(_ phase: String, elapsed: TimeInterval? = nil, oldRate: Float? = nil) {
        guard FTPlayerDiagnostic.shared.isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let observer = progressObserver
        let progressDelivery: [String: Any] = [
            "queued": progressQueued, "delivered": progressDelivered,
            "invalidatedBySeek": progressInvalidated, "withoutObserver": progressWithoutObserver,
            "lastQueuedAge": lastProgressQueuedWall == 0 ? -1 : now - lastProgressQueuedWall,
            "lastDeliveredAge": lastProgressDeliveredWall == 0 ? -1 : now - lastProgressDeliveredWall,
            "lastDeliveredProgress": lastProgressDeliveredValue as Any? ?? NSNull(),
            "hasProgressDelegate": progressDelegate != nil, "hasLegacyDelegate": delegate != nil,
            "observerType": observer.map { String(reflecting: type(of: $0)) } as Any? ?? NSNull()
        ]
        var fields: [String: Any] = ["rateTraceSchema": 2, "player": traceID, "generation": generation,
            "rateRevision": rateTraceRevision, "requestedRate": rate, "muted": isMuted,
            "playing": playing, "state": String(describing: state), "progress": progress,
            "outputVideoPTS": lastOutputVideoPTS as Any? ?? NSNull(), "outputFrames": renderedFrames,
            "lastOutputAge": lastFrameTime == 0 ? -1 : ProcessInfo.processInfo.systemUptime - lastFrameTime,
            "progressDelivery": progressDelivery,
            "seekCompletionPending": pendingSeekCompletion != nil,
            "seekCompletionTarget": pendingSeekCompletion?.target as Any? ?? NSNull(),
            "engine": engine?.rateDiagnosticFields ?? [:],
            "audioOutput": audioManager?.rateDiagnosticFields(includeFormats: phase == "health" || phase == "applied") ?? [:]]
        if let elapsed { fields["secondsSinceRateChange"] = elapsed }
        if let oldRate { fields["oldRate"] = oldRate }
        FTPlayerDiagnostic.shared.record("info", "rate", phase, fields: fields)
    }
    private(set) var cacheSession: (any PlaybackCacheSession)?
    private var stoppedCache: (fraction: Double, ranges: [FTPlayerCachedTimeRange], duration: TimeInterval, bytes: FTPlayerCacheProgress)?
    func prepareCacheSession() throws -> any PlaybackCacheSession {
        if let session = cacheSession, !session.isClosed { return session }
        let session = try components.makeCacheSession()
        session.setPlaybackRate(rate)
        cacheSession = session
        return session
    }
    var engine: (any PlaybackEngine)?
    var audioManager: (any PlaybackAudioOutput)?
    /// App-owned video consumer. Output is synchronized to playback on the main queue.
    public weak var videoOutput: (any FTPlayerVideoOutput)? { willSet { requireMainThread() } }
    private(set) var contentURL : URL?
    public init(contentURL: URL?) {
        self.components = DefaultPlaybackComponentFactory()
        self.contentURL = contentURL
        super.init()
        requireMainThread()
        lifecycle.delegate = self
        trace("create source=\(contentURL?.absoluteString ?? "nil")")
    }
    init(contentURL: URL?, components: any PlaybackComponentFactory) {
        self.components = components
        self.contentURL = contentURL
        super.init()
        requireMainThread()
        lifecycle.delegate = self
        trace("create source=\(contentURL?.absoluteString ?? "nil")")
    }

    deinit {
        pendingSeekCompletion?.complete(false)
        telemetry.stop()
        engine?.delegate = nil
        engine?.closeFile()
        audioManager?.destroy()
        cacheSession?.close()
        trace("deinit")
    }
    var backgroundMode: FTPlayerBackgroundMode {
        get { lifecycle.backgroundMode }
        set { requireMainThread(); lifecycle.backgroundMode = newValue }
    }
    var playing = false
    public var rate : Float = FTPlayerSDKConfiguration.Playback.defaultRate {
        didSet {
            requireMainThread()
            guard rate.isFinite, rate >= FTPlayerSDKConfiguration.Playback.minimumRate, rate <= FTPlayerSDKConfiguration.Playback.maximumRate else {
                rate = oldValue
                trace("invalid rate ignored")
                return
            }
            trace("rate \(oldValue) -> \(rate)")
            if rate != oldValue { resetVideoMeasurements() }
            rateTraceRevision += 1
            traceRateSnapshot("requested", oldRate: oldValue)
            self.cacheSession?.setPlaybackRate(rate)
            self.audioManager?.playbackRate = rate
            self.engine?.playbackRate = rate
            self.engine?.minBufferedDuration = adaptiveMinBufferedDuration(for: rate)
            traceRateSnapshot("applied", elapsed: 0, oldRate: oldValue)
            let revision = rateTraceRevision, playbackGeneration = generation
            telemetry.sampleRateTransition { [weak self] elapsed in
                guard let self, self.rateTraceRevision == revision, self.generation == playbackGeneration else { return }
                self.traceRateSnapshot("sample", elapsed: elapsed)
            }
        }
    }

    private func adaptiveMinBufferedDuration(for rate: Float) -> TimeInterval {
        // Giữ ~2s wall-clock buffer: tăng media-time buffer tỉ lệ với rate.
        // Cap tại 10s: packet buffer nội bộ giới hạn ~8MB (~20s ở bitrate thông thường).
        // Nếu threshold vượt quá packet buffer capacity, player sẽ kẹt mãi trong buffering.
        let wallSeconds = FTPlayerSDKConfiguration.Playback.startupWallBuffer
        return min(max(wallSeconds, wallSeconds * Double(rate)), FTPlayerSDKConfiguration.Playback.maximumStartupMediaBuffer)
    }
    public var state: FTPlayerState = .none {
        didSet {
            requireMainThread()
            guard oldValue != state else { return }
            switch state {
            case .none, .suspend, .finished, .failed: resetVideoMeasurements()
            default: break
            }
            let newState = state
            let seekToken = engine.flatMap { progressEventGate.token(for: $0) }
            trace("state \(oldValue) -> \(newState) at=\(progress)")
            // EOF/buffering can arrive from the realtime audio render callback.
            // Starting/stopping AUGraph there can deadlock its own render drain.
            dispatchEvent { player in
                if player.state == newState {
                    if newState == .playing { player.audioManager?.play() }
                    else { player.audioManager?.pause() }
                }
                // Audio must still obey the current pause state when a seek
                // supersedes an observer notification in the same main turn.
                if let seekToken, !player.progressEventGate.accepts(seekToken) { return }
                player.playbackObserver?.player(player, didChangeState: newState)
            }
        }
    }

    public var progress: TimeInterval = 0 {
        didSet {
            requireMainThread()
            guard progress != oldValue else { return }
            progressQueued += 1
            lastProgressQueuedWall = ProcessInfo.processInfo.systemUptime
            let value = progress
            let progressToken = engine.flatMap { progressEventGate.token(for: $0) }
            dispatchEvent { player in
                if let progressToken, !player.progressEventGate.accepts(progressToken) {
                    player.progressInvalidated += 1
                    return
                }
                guard let observer = player.progressObserver else {
                    player.progressWithoutObserver += 1
                    return
                }
                player.progressDelivered += 1
                player.lastProgressDeliveredWall = ProcessInfo.processInfo.systemUptime
                player.lastProgressDeliveredValue = value
                observer.player(player, didUpdateProgress: value)
            }
        }
    }
    var playableTime: TimeInterval = 0 {
        didSet {
            requireMainThread()
            playableTime = min(max(0, playableTime), duration)
            guard playableTime != oldValue else { return }
            let value = playableTime
            let fraction = bufferProgress
            let seekToken = engine.flatMap { progressEventGate.token(for: $0) }
            dispatchEvent { player in
                if let seekToken, !player.progressEventGate.accepts(seekToken) { return }
                player.progressObserver?.player(player, didUpdatePlayable: value)
            }
            dispatchEvent { player in
                if let seekToken, !player.progressEventGate.accepts(seekToken) { return }
                player.progressObserver?.player(player, didUpdateBufferProgress: fraction)
            }
        }
    }

    /// Output level in 0...1. Muting preserves this configured level.
    public var volume: CGFloat = CGFloat(FTPlayerSDKConfiguration.Playback.defaultVolume) {
        didSet {
            requireMainThread()
            guard volume.isFinite, volume >= 0, volume <= 1 else { volume = oldValue; return }
            reloadVolume()
            trace("audio volume=\(volume) muted=\(isMuted)")
        }
    }
    /// Silences the mixer while decoding, playback clocks and video continue.
    public var isMuted: Bool = FTPlayerSDKConfiguration.Playback.mutedByDefault {
        didSet {
            requireMainThread()
            guard oldValue != isMuted else { return }
            reloadVolume()
            trace("audio muted=\(isMuted) volume=\(volume)")
        }
    }
    var playableBufferInterval: TimeInterval = FTPlayerSDKConfiguration.Playback.startupWallBuffer {
        didSet {
            requireMainThread()
            self.reloadVolume()
        }
    }

    var prepareToken: Bool = false


    /// Current playback position in seconds, on the same zero-based timeline as seek.
    public var currentTime: TimeInterval { progress }

    public var duration: TimeInterval {
        return engine?.duration ?? stoppedCache?.duration ?? 0
    }

    /// Buffered endpoint as a fraction of duration. Advances within a playback
    /// interval; an explicit seek starts a new interval at the requested target.
    public var bufferProgress: Double {
        guard duration > 0 else { return 0 }
        return min(playableTime / duration, 1.0)
    }

    /// Cached media intervals, preserving gaps and using demux timestamps rather than byte percentages.
    public var cachedTimeRanges: [FTPlayerCachedTimeRange] { engine?.cachedTimeRanges ?? stoppedCache?.ranges ?? [] }
    /// Use this to distinguish an unknown total from an empty cache. The legacy
    /// downloadProgress remains zero until a byte fraction can be calculated.
    public var cacheProgress: FTPlayerCacheProgress { engine?.cacheProgress ?? stoppedCache?.bytes ?? .empty }

    public var downloadProgress: Double {
        return engine?.cachedFraction ?? stoppedCache?.fraction ?? 0
    }

    /// HTTP file cache belongs to this player session. Stop/replay keeps it;
    /// replaceVideo(with: aDifferentURL) or deinit removes it.
    public var useCache: Bool = FTPlayerSDKConfiguration.Playback.cacheEnabledByDefault { willSet { requireMainThread() } }

    /// Set before opening a source. Defaults follow Media3 streaming time/size
    /// thresholds; this does not change the lifetime of the session disk cache.
    public var loadControlConfiguration = FTPlayerLoadControlConfiguration() { willSet { requireMainThread() } }

    var presentationSize: CGSize {
        return engine?.prepareToDecode == true ? engine?.presentationSize ?? .zero : .zero
    }

    var bitrate: TimeInterval {
        return engine?.prepareToDecode == true ? engine?.bitrate ?? 0 : 0
    }

    func reloadVolume() {
        audioManager?.volume = isMuted ? 0 : Float(volume)
    }

    func reloadPlayableBufferInterval() {
        engine?.minBufferedDuration = adaptiveMinBufferedDuration(for: rate)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    func formatForContentURL(contentURL: URL) -> FTVideoFormat {
        let path: String
        if contentURL.isFileURL {
            path = contentURL.path
        } else {
            path = contentURL.absoluteString
        }
        switch path {
        case _ where path.hasPrefix("rtmp:"):
            return .rtmp
        case _ where path.hasPrefix("rtsp:"):
            return .rtsp
        case _ where path.contains(".flv"):
            return .flv
        case _ where path.contains(".mp4"):
            return .mpeg4
        case _ where path.contains(".m3u8"):
            return .m3u8
        default:
            return .unknown
        }
    }

    /// Same URL keeps this player's cache. A changed URL ends the old cache session.
    public func replaceVideo(with url: URL) {
        requireMainThread()
        let changed = contentURL != url
        let previous = changed ? cacheSession : nil
        if changed { contentURL = url; cacheSession = nil; stoppedCache = nil }
        replaceVideo()
        previous?.close()
    }

    public func replaceVideo() {
        requireMainThread()
        cancelPendingSeek()
        guard let contentURL = self.contentURL else {
            generation += 1
            beginPreparation()
            queuePreparation(.validatingSource)
            errorHandler(error: NSError(domain: "FTPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing content URL"]))
            return
        }
        stoppedCache = nil
        generation += 1
        let requestGeneration = generation
        beginPreparation()
        queuePreparation(.validatingSource)
        queuePreparation(.sourceValidated)
        trace("replaceVideo cache=\(useCache)")
        startTelemetry()
        let session: (any PlaybackCacheSession)?
        if useCache { queuePreparation(.preparingCache) }
        do { session = useCache ? try prepareCacheSession() : nil }
        catch { errorHandler(error: error as NSError); return }

        if useCache { queuePreparation(.cachePrepared) }
        let oldDecoder = self.engine
        eventGate.bind(nil)
        progressEventGate.bind(nil)
        self.engine = nil
        oldDecoder?.delegate = nil
        cleanAudio()
        cleanPlayer()
        playing = true // Autoplay by default; an explicit pause while opening overrides it.

        let createNewDecoder = { [weak self] in
            guard let self = self, self.generation == requestGeneration else { return }
            let decoder = self.components.makeDecoder(contentURL: contentURL,
                                    videoFormat: self.formatForContentURL(contentURL: contentURL),
                                    videoOutput: self,
                                    audioOutput: self.audioFormat)

            decoder.delegate = self
            decoder.useCache = self.useCache
            decoder.loadControlConfiguration = self.loadControlConfiguration
            decoder.cacheSession = session
            decoder.cacheSessionRevision = session?.currentRevision
            decoder.videoDecodingPolicy = self.videoDecodingPolicy
            decoder.playbackRate = self.rate
            decoder.minBufferedDuration = self.adaptiveMinBufferedDuration(for: self.rate)
            self.queuePreparation(.configuringAudioOutput)
            self.audioManager = self.components.makeAudioOutput(source: decoder)
            self.setupAudio()  // phải hoàn thành trước khi decoder bắt đầu fire callback
            self.queuePreparation(.audioOutputConfigured)
            self.engine = decoder
            self.eventGate.bind(decoder)
            self.progressEventGate.bind(decoder)
            decoder.open()
            self.reloadVolume()
            self.reloadPlayableBufferInterval()
        }

        if let decoder = oldDecoder {
            decoder.closeFileWithCompletion { DispatchQueue.main.async(execute: createNewDecoder) }
        } else {
            createNewDecoder()
        }
    }

    private func setupAudio() {
        guard let audioManager else { return }
        let registered = audioManager.registerAudioSession()
        audioFormat.update(channels: audioManager.numberOfChannels, rate: audioManager.samplingRate)
        trace("audio registration success=\(registered) rate=\(audioManager.samplingRate) channels=\(audioManager.numberOfChannels)")
        audioManager.volume = isMuted ? 0 : Float(volume)
        lifecycle.configure(audio: audioManager)
    }
    public func play() {
        requireMainThread()
        trace("play requested at=\(progress)")
        if engine == nil || state == .failed { replaceVideo(); return }
        playing = true
        engine?.resume()

        switch state {
        case .finished:
            // An explicit seek can already have cleared the engine's EOF while
            // its buffering/state callbacks are still queued. Keep that target.
            // resume() handles native replay; other engines may still need zero.
            if engine?.playbackFinished == true { seek(to: 0) }
            state = engine?.buffering == true ? .buffering : .playing
        case .none, .failed, .buffering:
            state = .buffering
        case .readyToPlay, .playing, .suspend:
            state = engine?.buffering == true ? .buffering : .playing
        }
    }
    public func pause() {
        requireMainThread()
        trace("pause requested at=\(progress)")
        playing = false
        lifecycle.didPause()
        engine?.pause()

        switch state {
        case .none, .suspend:
            break
        case .failed, .readyToPlay, .finished, .playing, .buffering:
            state = .suspend
        }
    }

    public func stop() {
        requireMainThread()
        cancelPendingSeek()
        trace("stop requested at=\(progress)")
        if let decoder = engine, cacheSession != nil {
            stoppedCache = (decoder.cachedFraction, decoder.cachedTimeRanges, decoder.duration, decoder.cacheProgress)
        }
        eventGate.bind(nil)
        progressEventGate.bind(nil)
        lifecycle.didStop()
        generation += 1
        let notifyStopped = preparationState != .stopped
        preparationWorkflow.stop()
        telemetry.stop()
        engine?.delegate = nil
        clean()
        // The engine snapshot represents the whole source. A session can own
        // many HLS resource workers; the last worker's fraction is not the
        // aggregate playlist fraction shown before Stop.
        cacheSession?.suspendWorkers()
        if notifyStopped {
            let notify: (FTPlayer) -> Void = { player in
                player.trace("preparation state=stopped")
                player.preparationObserver?.player(player, didChangePreparationState: .stopped)
            }
            if Thread.isMainThread { notify(self) } else { dispatchEvent(notify) }
        }
    }

    /// Success is delivered on main after media at the target is ready, including
    /// seek preroll and buffering. Superseded/stopped/failed seeks complete false.
    public func seek(to time: TimeInterval, completeHandler: ((Bool) -> Void)? = nil) {
        requireMainThread()
        trace("seek requested target=\(time) from=\(progress)")
        guard time.isFinite, let decoder = engine else { completeHandler?(false); return }
        resetVideoMeasurements()
        cancelPendingSeek()
        seekCompletionRevision += 1
        let requestGeneration = generation, requestRevision = seekCompletionRevision
        let began = ProcessInfo.processInfo.systemUptime
        let completion = SeekCompletion(generation: generation, engine: decoder, target: time, handler: { [weak self] success in
            self?.trace("seek completed target=\(time) success=\(success) waited=\(ProcessInfo.processInfo.systemUptime - began)")
            completeHandler?(success)
        }) { [weak self] in
            guard let self else { return false }
            return self.generation == requestGeneration && self.seekCompletionRevision == requestRevision && !self.currentPlaybackFailed
        }
        pendingSeekCompletion = completion
        progressEventGate.bind(decoder)
        let previousPublication = publishingSeekProgress
        publishingSeekProgress = true
        defer { publishingSeekProgress = previousPublication }
        let request = {
            decoder.seek(to: time) { [weak self] success in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { completion.complete(false); return }
                    guard self.pendingSeekCompletion === completion else { return }
                    guard success, self.generation == completion.generation, self.engine === completion.engine,
                          !self.currentPlaybackFailed else {
                        self.finishSeek(completion, success: false)
                        return
                    }
                    completion.demuxSucceeded = true
                    self.trace("seek demux acknowledged target=\(time) buffering=\(self.engine?.buffering ?? false)")
                    self.completeSeekIfReady()
                }
            }
        }
        if decoder.seekEnable, let audioManager { audioManager.performSeek(request) }
        else { request() }
        // Reset after the engine publishes its synchronous seek progress: that
        // publication rebinds the event gate to reject pre-seek audio callbacks.
        // Later queue updates must start from this target, not the old EOF/end.
        if decoder.seekEnable, generation == requestGeneration, seekCompletionRevision == requestRevision,
           !currentPlaybackFailed {
            playableTime = min(max(0, time), duration)
        }
    }

    private func finishSeek(_ completion: SeekCompletion, success: Bool) {
        guard pendingSeekCompletion === completion else { return }
        pendingSeekCompletion = nil
        trace("seek completion queued target=\(completion.target) success=\(success) waited=\(ProcessInfo.processInfo.systemUptime - completion.began)")
        completion.complete(success)
    }

    private func cancelPendingSeek() {
        if let completion = pendingSeekCompletion { finishSeek(completion, success: false) }
    }

    private func completeSeekIfReady() {
        guard let completion = pendingSeekCompletion, completion.demuxSucceeded,
              generation == completion.generation, let decoder = engine, decoder === completion.engine,
              !currentPlaybackFailed, !decoder.buffering, state != .buffering else { return }
        finishSeek(completion, success: true)
    }

}
// MARK: - Clean
extension FTPlayer {

    private func clean() {
        cleanDecoder()
        cleanAudio()
        cleanPlayer()
    }

    private func cleanPlayer() {
        resetVideoMeasurements()
        playing = false
        lifecycle.didPause()
        renderedFrames = 0
        lastFrameTime = 0
        lastOutputVideoPTS = nil
        state = .none
        progress = 0
        playableTime = 0
        prepareToken = false
    }

    private func cleanAudio() {
        self.audioManager?.destroy()
        self.audioManager = nil
        audioFormat.update(channels: 0, rate: 0)
    }

    private func cleanDecoder() {
        if let decoder = engine {
            decoder.closeFile()
            self.engine = nil
        }
    }
}
// Compatibility for low-level internal clients; values are lock-protected snapshots.
extension FTPlayer: FTDecoderAudioOutput {
    var numberOfChannels: UInt32 { audioFormat.numberOfChannels }
    var samplingRate: Float64 { audioFormat.samplingRate }
}
extension FTPlayer: FTDecoderVideoOutput {
    func send(video frame: FTVideoFrame, from decoder: any PlaybackEngine) {
        guard let pixel = frame.pixelBuffer, let seekToken = progressEventGate.token(for: decoder) else { return }
        let position = frame.position
        receive(from: decoder) { player in
            guard player.progressEventGate.accepts(seekToken) else { return }
            player.renderedFrames += 1
            player.lastFrameTime = ProcessInfo.processInfo.systemUptime
            player.lastOutputVideoPTS = position
            if player.playing { player.frameRateMeter.record(pts: position, wall: player.lastFrameTime) }
            if player.playing && player.isVideoContentChangeMeasurementEnabled {
                player.contentChangeMeter.record(pixel, pts: position, wall: player.lastFrameTime)
            }
            if player.renderedFrames == 1 { player.trace("first frame pts=\(position) size=\(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel))") }
            player.videoOutput?.player(player, didOutput: pixel, presentationTime: position)
            if decoder === player.engine, !player.currentPlaybackFailed { player.advancePreparation(to: .end) }
            player.publishVideoStatistics(at: player.lastFrameTime)
        }
    }
}

extension FTPlayer: FTDecoderDelegate {
    func decoderWillOpenInputStream(_ decoder: any PlaybackEngine) {
        receive(from: decoder) { player in
            guard !player.currentPlaybackFailed else { return }
            player.state = .buffering
            player.advancePreparation(to: .allocatingFormatContext)
        }
    }

    func decoder(_ decoder: any PlaybackEngine, didChangePreparationState state: FTPlayerPreparationState) {
        receive(from: decoder) { $0.advancePreparation(to: state) }
    }

    func decoderDidPrepareToDecodeFrames(_ decoder: any PlaybackEngine) {
        receive(from: decoder) { player in
            guard !player.currentPlaybackFailed else { return }
            player.trace("ready duration=\(decoder.duration) size=\(decoder.presentationSize) video=\(decoder.videoEnable) audio=\(decoder.audioEnable)")
            player.prepareToken = true
            player.state = .readyToPlay
            let duration = decoder.duration
            let info = decoder.mediaInfo
            let videoEnabled = decoder.videoEnable
            for step in [FTPlayerPreparationState.readingMediaInfo, .mediaInfoRead, .publishingMediaInfo] {
                guard decoder === player.engine, !player.currentPlaybackFailed else { return }
                player.advancePreparation(to: step)
            }
            guard decoder === player.engine, !player.currentPlaybackFailed else { return }
            if let info {
                player.mediaInfo = info
                player.preparationObserver?.player(player, didUpdateMediaInfo: info)
            }
            for step in [FTPlayerPreparationState.mediaInfoPublished, .readyToDecode] {
                guard decoder === player.engine, !player.currentPlaybackFailed else { return }
                player.advancePreparation(to: step)
            }
            guard decoder === player.engine, !player.currentPlaybackFailed else { return }
            if !videoEnabled { player.advancePreparation(to: .end) }
            guard decoder === player.engine, !player.currentPlaybackFailed else { return }
            player.audioManager?.playbackRate = player.rate
            decoder.playbackRate = player.rate
            if player.playing { player.play() }
            else { decoder.pause(); player.state = .suspend }
            player.playbackObserver?.playerReadyToPlay(player, duration: duration)
        }
    }

    func decoderDidEndOfFile(_ decoder: any PlaybackEngine) {
        guard let seekToken = progressEventGate.token(for: decoder) else { return }
        receive(from: decoder) { player in
            guard !player.currentPlaybackFailed, player.progressEventGate.accepts(seekToken) else { return }
            player.playableTime = decoder.duration
        }
    }

    func decoderDidPlaybackFinished(_ decoder: any PlaybackEngine) {
        guard let seekToken = progressEventGate.token(for: decoder) else { return }
        receive(from: decoder) { player in
            guard !player.currentPlaybackFailed, player.progressEventGate.accepts(seekToken), decoder.playbackFinished else { return }
            player.playableTime = decoder.duration
            player.state = .finished
            player.trace("playback finished")
            player.dispatchEvent {
                guard $0.progressEventGate.accepts(seekToken), decoder.playbackFinished else { return }
                $0.playbackObserver?.playerDidFinish($0)
            }
            player.completeSeekIfReady()
        }
    }

    func decoder(_ decoder: any PlaybackEngine, didError error: Error) {
        receive(from: decoder) { $0.errorHandler(error: error as NSError) }
    }

    func decoder(_ decoder: any PlaybackEngine, didChangeValueOfBuffering buffering: Bool) {
        guard let seekToken = progressEventGate.token(for: decoder) else { return }
        receive(from: decoder) { player in
            guard !player.currentPlaybackFailed, player.progressEventGate.accepts(seekToken) else { return }
            // An EOF notification must not restart an already-finished engine.
            if decoder.playbackFinished {
                if !buffering {
                    player.dispatchEvent {
                        guard $0.progressEventGate.accepts(seekToken) else { return }
                        $0.trace("buffering delegate end")
                        $0.playbackObserver?.playerBufferingEnd($0)
                    }
                    player.completeSeekIfReady()
                }
                return
            }
            if buffering {
                if player.playing || player.state != .suspend { player.state = .buffering }
                player.dispatchEvent {
                    guard $0.progressEventGate.accepts(seekToken) else { return }
                    $0.trace("buffering delegate start")
                    $0.playbackObserver?.playerBufferingStart($0)
                }
            } else {
                if player.playing {
                    player.state = .playing
                } else if !player.prepareToken {
                    player.state = .readyToPlay
                    player.prepareToken = true
                } else {
                    player.state = .suspend
                }
                player.dispatchEvent {
                    guard $0.progressEventGate.accepts(seekToken) else { return }
                    $0.trace("buffering delegate end")
                    $0.playbackObserver?.playerBufferingEnd($0)
                }
                player.completeSeekIfReady()
            }
        }
    }

    func decoder(_ decoder: any PlaybackEngine, didChangeValueOfBufferedDuration bufferedDuration: TimeInterval) {
        guard let seekToken = progressEventGate.token(for: decoder) else { return }
        receive(from: decoder) { player in
            guard !player.currentPlaybackFailed, player.progressEventGate.accepts(seekToken) else { return }
            // Queue occupancy falls as PCM/pictures are consumed. Progress is
            // throttled independently, so adding the two can temporarily give
            // an older endpoint, especially at 16x. Keep the furthest endpoint
            // reached in this seek interval, including EOF while queues drain.
            player.playableTime = max(player.playableTime, player.progress + bufferedDuration)
        }
    }

    func decoder(_ decoder: any PlaybackEngine, didUpdateDownloadProgress fraction: Double) {
        receive(from: decoder) { player in
            player.dispatchEvent { $0.progressObserver?.player($0, didUpdateDownloadProgress: fraction) }
        }
    }

    func decoder(_ decoder: any PlaybackEngine, didChangeValueOfProgress progress: TimeInterval) {
        // Seek reports its requested position synchronously on main. Preserve that
        // state update so a second relative seek starts from the pending target.
        // Public progress notifications remain asynchronous through the observer.
        guard eventGate.token(for: decoder) != nil else { return }
        // FTDecoder serializes its synchronous seek publication with the audio
        // callback. Invalidate again here so an old callback queued while the
        // main thread waited for that serialization cannot arrive after target.
        if Thread.isMainThread && publishingSeekProgress { progressEventGate.bind(decoder) }
        guard let progressToken = progressEventGate.token(for: decoder) else { return }
        receive(from: decoder, immediatelyOnMain: true) { player in
            guard player.progressEventGate.accepts(progressToken) else { return }
            player.progress = progress
        }
    }

    func errorHandler(error: NSError) {
        requireMainThread()
        guard failedGeneration != generation else { return }
        failedGeneration = generation
        cancelPendingSeek()
        var info = error.userInfo
        info["currentTime"] = currentTime; info["duration"] = duration
        info["rate"] = rate; info["cacheProgress"] = downloadProgress
        let error = NSError(domain: error.domain, code: error.code, userInfo: info)
        engine?.pause()
        FTPlayerDiagnostic.shared.record("error", "player", error.localizedDescription,
            fields: ["player": traceID, "domain": error.domain, "code": error.code, "currentTime": currentTime, "duration": duration, "rate": rate, "cacheProgress": downloadProgress, "userInfo": String(describing: error.userInfo)])
        FTPlayerDiagnostic.shared.flush()
        self.state = .failed
        let errorGeneration = generation
        dispatchEvent { player in
            player.advancePreparation(to: .failed)
            // A preparation delegate may synchronously stop or open another source.
            guard player.generation == errorGeneration else { return }
            player.playbackObserver?.player(player, didFail: error)
        }

    }


}

extension FTPlayer: PlaybackLifecycleDelegate {}
