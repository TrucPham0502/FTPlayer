import Foundation

/// Disk is the source of truth for both sequential reads and random seeks. The condition
/// only wakes AVIO readers; it never maps discontiguous file ranges into a linear buffer.
class CacheWorker {
    private let sourceURL: URL
    private let cacheStore: CacheStore
    private let streamingLoader: any HTTPStreamingLoading
    private let condition = NSCondition()
    private let readTimeout: TimeInterval
    private let onPreparationState: ((FTPlayerPreparationState) -> Void)?
    private var reportedInitialData = false
    private let chunkSize: Int64 = FTPlayerSDKConfiguration.Cache.requestChunkBytes
    private var bufferAheadBytes: Int64
    private var playbackRate: Float
    private var lastNetworkActivity: TimeInterval = 0
    private var watchdogRevision = 0
    private var stalledReconnects: Int64 = 0
    private var loadControl: FTPlayerLoadControl?
    private var loadIndex = CacheTimelineIndex(tracks: [], duration: 0)
    private var mediaBytesPerSecond: Double = 0
    private var playbackPosition: Double = 0
    private var lastMediaAhead: Double = 0
    private var bootstrapBytes: Int64?
    private var resourceReadAheadBytes: Int64?

    func configureLoadControl(_ configuration: FTPlayerLoadControlConfiguration, index: CacheTimelineIndex,
                              bytesPerSecond: Double, video: Bool, audio: Bool) {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        loadControl = FTPlayerLoadControl(configuration: configuration, video: video, audio: audio)
        loadIndex = index
        mediaBytesPerSecond = bytesPerSecond.isFinite ? max(0,bytesPerSecond) : 0
        bootstrapBytes = nil
        refillLocked(from: _currentOffset,demand:false)
    }
    func setResourceReadAheadBytes(_ bytes: Int64) {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        let target = max(FTPlayerSDKConfiguration.Cache.minimumReadAheadBytes, bytes)
        guard resourceReadAheadBytes != target else { return }
        resourceReadAheadBytes = target
        bufferAheadBytes = resourceReadAheadBytes!
        refillLocked(from:_currentOffset,demand:false)
    }
    func setPlaybackPosition(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        playbackPosition = value
        refillLocked(from: _currentOffset,demand:false)
    }

    private static func readAheadBytes(for rate: Float) -> Int64 {
        // Disk lookahead, independent of the bounded decoded/packet queues.
        Int64(Double(FTPlayerSDKConfiguration.Cache.baseReadAheadBytes) * min(FTPlayerSDKConfiguration.Cache.maximumReadAheadRateMultiplier, max(1, Double(rate))))
    }
    func setPlaybackRate(_ rate: Float) {
        guard rate.isFinite, (FTPlayerSDKConfiguration.Playback.minimumRate...FTPlayerSDKConfiguration.Playback.maximumRate).contains(rate) else { return }
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        playbackRate = rate
        if loadControl != nil { refillLocked(from:_currentOffset,demand:false); return }
        // HLS schedules a bounded set of whole resources. A session rate update
        // must not replace that resource budget with progressive-file lookahead:
        // a paused reader can otherwise leave a large segment permanently partial.
        let target = resourceReadAheadBytes ?? bootstrapBytes ?? Self.readAheadBytes(for: rate)
        guard target != bufferAheadBytes else { return }
        bufferAheadBytes = target
        Console.log("[Cache] rate=\(rate) readAheadTargetBytes=\(target) head=\(_currentOffset)")
        refillLocked(from: _currentOffset, demand: false)
    }

    // URLSession can keep a dead socket alive while the reader is still consuming
    // cached bytes. Recover without waiting for that reader to encounter a hole.
    private var networkIdleLimit: TimeInterval {
        openDeadline == nil ? min(readTimeout, FTPlayerSDKConfiguration.Network.idleReconnectTimeout) : readTimeout
    }
    private func scheduleWatchdogLocked() {
        watchdogRevision += 1
        let token = watchdogRevision, gen = generation
        scheduleWatchdogLocked(generation: gen, token: token, delay: networkIdleLimit)
    }
    private func scheduleWatchdogLocked(generation gen: Int, token: Int, delay: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + max(FTPlayerSDKConfiguration.Network.minimumReadTimeout, delay)) { [weak self] in
            guard let self else { return }
            self.condition.lock(); defer { self.condition.unlock() }
            guard !self.closed, !self.readCancelled, !self.terminalError, self._failure == nil,
                  self.generation == gen, self.watchdogRevision == token, self.activeRange != nil,
                  !self.openingExpiredLocked() else { return }
            let idle = ProcessInfo.processInfo.systemUptime - self.lastNetworkActivity
            if idle < self.networkIdleLimit {
                self.scheduleWatchdogLocked(generation: gen, token: token, delay: self.networkIdleLimit - idle)
                return
            }
            self.generation += 1
            self.streamingLoader.cancel()
            self.activeRange = nil
            self.stalledReconnects += 1
            Console.log("[Cache] reconnect idleSeconds=\(idle) head=\(self._currentOffset) nextMissing=\(self.cacheStore.firstUncachedByte(from: self._currentOffset)) readAheadTargetBytes=\(self.bufferAheadBytes)")
            self.refillLocked(from: self._currentOffset, demand: false)
            self.condition.broadcast()
        }
    }
    private var generation = 0
    private var activeRange: CachedRange?
    private var closed = false
    private var readCancelled = false
    private var readTimedOut = false
    private var readRevision = 0
    private var terminalError = false
    private var _failure: NSError?
    private var lastNetworkError: NSError?
    private var _responseURL: URL?
    private var receivedRangeHeaders = false
    private var sizeProbeStarted = false
    var responseURL: URL? { condition.lock(); defer { condition.unlock() }; return _responseURL }
    private var openDeadline: TimeInterval?
    private var openTimeout: TimeInterval = 0
    var failure: NSError? { condition.lock(); defer { condition.unlock() }; return _failure }
    func beginOpening(timeout: TimeInterval) {
        condition.lock(); defer { condition.unlock() }
        openTimeout = max(FTPlayerSDKConfiguration.Network.minimumOpeningTimeout, timeout)
        openDeadline = ProcessInfo.processInfo.systemUptime + openTimeout
        if activeRange != nil { scheduleWatchdogLocked() }
        condition.broadcast()
    }
    func finishOpening() {
        condition.lock(); defer { condition.unlock() }
        openDeadline = nil
        if activeRange != nil { scheduleWatchdogLocked() }
        condition.broadcast()
    }
    // Called with condition held. A cold open has a finite budget; after ready,
    // missing cached bytes remain recoverable until Stop or replacement.
    private func openingExpiredLocked() -> Bool {
        guard let deadline = openDeadline, ProcessInfo.processInfo.systemUptime >= deadline else { return false }
        if _failure == nil {
            var info: [String: Any] = [NSLocalizedDescriptionKey: "Video open timed out after \(openTimeout) seconds", "operation": "open", "timeoutSeconds": openTimeout]
            if let cause = lastNetworkError { info[NSUnderlyingErrorKey] = cause }
            _failure = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue, userInfo: info)
            readTimedOut = true
            generation += 1
            streamingLoader.cancel(); activeRange = nil
            condition.broadcast()
            Console.log(type: .ERROR, "[Cache] open timeout seconds=\(openTimeout) offset=\(_currentOffset) underlying=\(String(describing: lastNetworkError))")
        }
        return true
    }
    private func boundedWakeLocked(_ date: Date) -> Date {
        guard let deadline = openDeadline else { return date }
        return min(date, Date().addingTimeInterval(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
    }
    private var retryAfter = Date.distantPast
    private var _waitsForNetwork = false
    private var waitingReaders = 0
    var waitsForNetwork: Bool {
        get { condition.lock(); defer { condition.unlock() }; return _waitsForNetwork }
        set { condition.lock(); _waitsForNetwork = newValue; condition.broadcast(); condition.unlock() }
    }
    var isWaitingForNetwork: Bool {
        condition.lock(); defer { condition.unlock() }
        return _waitsForNetwork && waitingReaders > 0 && !closed && !terminalError
    }
    private var _currentOffset: Int64 = 0
    private var lastReportedFraction: Double = 0
    private var hitBytes: Int64 = 0
    private var networkBytes: Int64 = 0
    private var requestCount: Int64 = 0
    private var cachedSeeks: Int64 = 0
    private var missingSeeks: Int64 = 0
    private let progressLock = NSLock()
    private var progressCallback: ((Double) -> Void)?
    var onProgress: ((Double) -> Void)? {
        get { progressLock.withLock { progressCallback } }
        set { progressLock.withLock { progressCallback = newValue } }
    }
    var currentOffset: Int64 { condition.lock(); defer { condition.unlock() }; return _currentOffset }

    var diagnosticSnapshot: [String: Int64] {
        condition.lock(); defer { condition.unlock() }
        var values: [String:Int64] = ["fileSize": cacheStore.totalFileSize(), "diskReadBytes": hitBytes, "networkBytes": networkBytes, "rangeRequests": requestCount,
                "cachedBytes": cacheStore.cachedRanges().reduce(0) { $0 + $1.end - $1.start + 1 },
                "cachedSeeks": cachedSeeks, "missingSeeks": missingSeeks,
                "readAheadTargetBytes": bufferAheadBytes, "contiguousAheadBytes": max(0, cacheStore.firstUncachedByte(from: _currentOffset) - _currentOffset),
                "currentOffset": _currentOffset, "playbackRateMilli": Int64(playbackRate * 1000),
                "networkIdleMilliseconds": activeRange == nil ? 0 : Int64(max(0, ProcessInfo.processInfo.systemUptime - lastNetworkActivity) * 1000),
                "stalledReconnects": stalledReconnects]
        if let control = loadControl {
            values["loadMinMediaMilliseconds"] = Int64(control.configuration.minimumDuration(rate:playbackRate)*1000)
            values["loadMaxMediaMilliseconds"] = Int64(control.configuration.maximumBufferDuration*1000)
            values["loadTargetBytes"] = control.targetBytes
            values["loadBufferedMilliseconds"] = Int64(min(Double(Int32.max),max(0,lastMediaAhead.isFinite ? lastMediaAhead*1000 : 0)))
            values["loadIsLoading"] = control.isLoading ? 1 : 0
            values["loadIndexed"] = loadIndex.tracks.isEmpty ? 0 : 1
        }
        return values
    }

    let resourceRangeForDiagnostics: CachedRange?
    init(videoURL: URL, cacheStore: CacheStore, readTimeout: TimeInterval = FTPlayerSDKConfiguration.Network.readTimeout, playbackRate: Float = FTPlayerSDKConfiguration.Playback.defaultRate, initialReadAheadBytes: Int64? = nil, loader: (any HTTPStreamingLoading)? = nil, onPreparationState: ((FTPlayerPreparationState) -> Void)? = nil, resourceRange: CachedRange? = nil) {
        self.resourceRangeForDiagnostics = resourceRange
        self.sourceURL = videoURL
        self.onPreparationState = onPreparationState
        self.cacheStore = cacheStore
        self.streamingLoader = loader ?? StreamingLoader(url: videoURL)
        self.readTimeout = max(FTPlayerSDKConfiguration.Network.minimumReadTimeout, readTimeout)
        let rate = playbackRate.isFinite && (FTPlayerSDKConfiguration.Playback.minimumRate...FTPlayerSDKConfiguration.Playback.maximumRate).contains(playbackRate) ? playbackRate : FTPlayerSDKConfiguration.Playback.defaultRate
        self.playbackRate = rate
        self.bootstrapBytes = initialReadAheadBytes.map { max(FTPlayerSDKConfiguration.Cache.minimumReadAheadBytes,$0) }
        self.bufferAheadBytes = self.bootstrapBytes ?? Self.readAheadBytes(for: rate)
        condition.lock()
        refillLocked(from: 0, demand: false)
        condition.unlock()
    }

    var videoURLForDiagnostics: URL { sourceURL }
    var knownFileSize: Int64 { cacheStore.totalFileSize() }
    var cachedByteRanges: [CachedRange] { cacheStore.cachedRanges() }

    var cachedFraction: Double {
        let size = cacheStore.totalFileSize()
        guard size > 0 else { return 0 }
        let cached = cacheStore.cachedRanges().reduce(Int64(0)) { $0 + ($1.end - $1.start + 1) }
        return min(1, Double(cached) / Double(size))
    }

    // Caller holds condition. Only missing bytes, bounded by the next cached island,
    // are requested. A cached seek itself never starts or cancels a transfer.
    private func refillLocked(from offset: Int64, demand: Bool) {
        guard !closed, !readCancelled, !terminalError, _failure == nil, Date() >= retryAfter else { return }
        let size = cacheStore.totalFileSize()
        guard size <= 0 || offset < size else { return }
        if let active = activeRange {
            if !demand || (active.start <= offset && offset <= active.end) { return }
            generation += 1
            streamingLoader.cancel()
            activeRange = nil
        }
        if !demand, var control = loadControl {
            let bytes = cacheStore.cachedRanges()
            var window = loadIndex.byteWindow(position:playbackPosition,duration:control.configuration.maximumBufferDuration)
            if !loadIndex.tracks.isEmpty {
                lastMediaAhead = loadIndex.ranges(in:bytes,fileSize:size).first(where: { $0.start <= playbackPosition+FTPlayerSDKConfiguration.Cache.playableRangeTolerance && $0.end > playbackPosition })
                    .map { $0.end-playbackPosition } ?? 0
            } else if mediaBytesPerSecond > 0 {
                let origin = Int64(min(Double(Int64.max/2),playbackPosition*mediaBytesPerSecond))
                let length = Int64(min(Double(Int64.max/2),control.configuration.maximumBufferDuration*mediaBytesPerSecond))
                window = CachedRange(start:origin,end:origin+max(1,length)-1)
                lastMediaAhead = Double(cacheStore.firstUncachedByte(from:origin)-origin)/mediaBytesPerSecond
            }
            if var span = window {
                if !control.configuration.prioritizesTimeOverSize { span.end = min(span.end,span.start+min(control.targetBytes-1,Int64.max-span.start)) }
                if size > 0 { span.end = min(span.end,size-1) }
                bufferAheadBytes = max(0,span.end-span.start+1)
                let aheadBytes = bytes.reduce(Int64(0)) { $0 + max(0,min($1.end,span.end)-max($1.start,span.start)+1) }
                let shouldLoad = control.shouldLoad(mediaAhead:lastMediaAhead,bytesAhead:aheadBytes,rate:playbackRate)
                loadControl = control
                guard shouldLoad, span.end >= span.start,
                      var missing = cacheStore.nextMissingRange(from:span.start,maximumLength:chunkSize), missing.start <= span.end else { return }
                missing.end = min(missing.end,span.end)
                startLocked(missing)
                return
            }
            // No time mapping yet (live/unindexed input with no bitrate): use a
            // bounded byte fallback while demux demand discovers the stream.
            bufferAheadBytes = min(control.targetBytes,Int64(FTPlayerSDKConfiguration.Cache.baseReadAheadBytes))
        }
        guard var range = cacheStore.nextMissingRange(from: offset, maximumLength: bootstrapBytes.map { min(chunkSize,$0) } ?? chunkSize) else { return }
        if demand, let control = loadControl {
            if let span = loadIndex.byteWindow(position:playbackPosition,duration:control.configuration.maximumBufferDuration), range.start >= span.start, range.start <= span.end {
                range.end = min(range.end,span.end)
            } else if !loadIndex.tracks.isEmpty {
                // Demux metadata outside the media window is still required for
                // opening/seeking, but must not trigger a speculative 4MiB read.
                range.end = min(range.end,range.start+min(FTPlayerSDKConfiguration.Cache.bootstrapBytes-1,Int64.max-range.start))
            }
        }
        guard demand || range.start - offset < bufferAheadBytes else { return }
        startLocked(range)
    }

    private func startLocked(_ range: CachedRange) {
        generation += 1
        let gen = generation
        activeRange = range
        receivedRangeHeaders = false
        lastNetworkActivity = ProcessInfo.processInfo.systemUptime
        requestCount += 1
        onPreparationState?(.requestingHTTPRange)
        streamingLoader.onActivity = { [weak self] in
            guard let self else { return }
            self.condition.lock(); defer { self.condition.unlock() }
            guard !self.closed, self.generation == gen else { return }
            self.lastNetworkActivity = ProcessInfo.processInfo.systemUptime
        }
        streamingLoader.onResponse = { [weak self] responseURL in
            guard let self else { return }
            self.condition.lock(); defer { self.condition.unlock() }
            guard !self.closed, self.generation == gen else { return }
            self._responseURL = responseURL
            self.lastNetworkActivity = ProcessInfo.processInfo.systemUptime
            self.onPreparationState?(.httpHeadersReceived)
        }
        streamingLoader.onFileSize = { [weak self] size in
            guard let self else { return }
            self.condition.lock(); defer { self.condition.unlock() }
            guard !self.closed, self.generation == gen else { return }
            self.cacheStore.setTotalFileSize(size)
            self.condition.broadcast()
        }
        streamingLoader.onRangeSupport = { [weak self] supportsRange in
            guard let self else { return }
            self.condition.lock(); defer { self.condition.unlock() }
            guard !self.closed, self.generation == gen else { return }
            self.receivedRangeHeaders = true
            self.condition.broadcast()
            guard !supportsRange else { return }
            // HTTP 200 is a sequential full-body download. Keep it alive when a seek
            // lands further ahead; restarting would download the prefix all over again.
            let size = self.cacheStore.totalFileSize()
            self.activeRange = CachedRange(start: range.start, end: size > 0 ? size - 1 : Int64.max - 1)
        }
        streamingLoader.onData = { [weak self] data, offset in
            guard let self else { return }
            self.condition.lock()
            guard !self.closed, self.generation == gen else { self.condition.unlock(); return }
            if !self.reportedInitialData && !data.isEmpty {
                self.reportedInitialData = true
                self.onPreparationState?(.receivingInitialData)
            }
            // Publish bytes to disk before waking a waiting reader or planning another range.
            self.cacheStore.write(data, at: offset)
            self.cacheStore.flush()
            self.networkBytes += Int64(data.count)
            self.lastNetworkError = nil
            let fraction = self.cachedFraction
            let progress = fraction - self.lastReportedFraction >= FTPlayerSDKConfiguration.Cache.progressFractionStep
            if progress { self.lastReportedFraction = fraction }
            let callback = self.onProgress
            self.condition.broadcast()
            self.condition.unlock()
            if progress { callback?(fraction) }
        }
        streamingLoader.onComplete = { [weak self] error in
            guard let self else { return }
            self.condition.lock()
            guard !self.closed, self.generation == gen else { self.condition.unlock(); return }
            defer {
                let callback = self.onProgress
                let fraction = self.cachedFraction
                self.condition.unlock()
                callback?(fraction) // Report even a completed hole smaller than the progress throttle.
            }
            self.activeRange = nil
            self.cacheStore.saveIndex()
            if let error {
                let ns = error as NSError
                self.lastNetworkError = ns
                let permanentHTTP = ns.domain == "StreamingLoader" && (400..<500).contains(ns.code) && ns.code != 408 && ns.code != 429
                let emptyResponse = ns.domain == NSURLErrorDomain && ns.code == URLError.zeroByteResource.rawValue
                let invalidRange = ns.domain == NSURLErrorDomain && ns.code == URLError.badServerResponse.rawValue && ns.userInfo["operation"] as? String == "range-response"
                if permanentHTTP || emptyResponse || invalidRange {
                    self.terminalError = true
                    self._failure = ns
                    Console.log(type: .ERROR, "Terminal cache input/network error: \(ns.domain)/\(ns.code)")
                } else {
                    self.retryAfter = Date().addingTimeInterval(FTPlayerSDKConfiguration.Network.retryDelay)
                    Console.log(type: .ERROR, "[Cache] retry generation=\(gen) error=\(error)")
                    DispatchQueue.global().asyncAfter(deadline: .now() + FTPlayerSDKConfiguration.Network.retryDelay) { [weak self] in
                        guard let self else { return }
                        self.condition.lock(); defer { self.condition.unlock() }
                        guard !self.closed, self.generation == gen else { return }
                        self.refillLocked(from: self._currentOffset, demand: false)
                    }
                }
            } else {
                self.refillLocked(from: self._currentOffset, demand: false)
            }
            self.condition.broadcast()
        }
        streamingLoader.start(from: range.start, to: range.end)
        scheduleWatchdogLocked()
    }

    // MARK: - AVIO reads and seeks

    func read(offset: Int64, length: Int) -> Data? {
        guard offset >= 0, length > 0 else { return nil }
        condition.lock(); defer { condition.unlock() }
        readTimedOut = false
        var deadline = Date().addingTimeInterval(readTimeout)
        var waiting = false
        defer { if waiting { waitingReaders -= 1 } }
        let revision = readRevision
        while !closed && !readCancelled && readRevision == revision {
            let size = cacheStore.totalFileSize()
            if size > 0 && offset >= size { return nil }
            let count = size > 0 ? min(length, Int(size - offset)) : length
            let cached = cacheStore.cachedByteCount(from: offset, maximum: count)
            if cached > 0, let data = cacheStore.read(at: offset, length: cached) {
                hitBytes += Int64(data.count)
                return data
            }
            if terminalError || _failure != nil || openingExpiredLocked() { return nil }
            if !waiting {
                waiting = true
                waitingReaders += 1
            }
            refillLocked(from: offset, demand: true)
            if Date() >= deadline {
                if !_waitsForNetwork {
                    readTimedOut = true
                    _failure = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue, userInfo: [NSLocalizedDescriptionKey: "Cache read timed out", "operation": "read", "offset": offset])
                    Console.log(type: .ERROR, "Cache read timeout offset=\(offset) seconds=\(readTimeout)")
                    return nil
                }
                // A dead socket can survive a network transition. Restart only its
                // missing span; keep AVIO blocked so FFmpeg never mistakes an outage for EOF.
                if activeRange != nil {
                    generation += 1
                    streamingLoader.cancel()
                    activeRange = nil
                    Console.log("[Cache] reconnect stalled transfer offset=\(offset)")
                }
                refillLocked(from: offset, demand: true)
                deadline = Date().addingTimeInterval(readTimeout)
            }
            let wake = retryAfter > Date() ? min(deadline, retryAfter) : deadline
            condition.wait(until: boundedWakeLocked(wake))
        }
        return nil
    }

    func readForProxy(offset: Int64, length: Int) -> Data? {
        guard let data = read(offset: offset, length: length) else { return nil }
        condition.lock(); defer { condition.unlock() }
        _currentOffset = offset + Int64(data.count)
        refillLocked(from: _currentOffset, demand: false)
        return data
    }

    func seek(to offset: Int64) {
        guard offset >= 0, offset <= Int64.max - chunkSize else { return }
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        let wasCancelled = readCancelled
        _currentOffset = offset
        readRevision += 1
        readCancelled = false
        readTimedOut = false
        if !terminalError && openDeadline == nil { _failure = nil }
        let size = cacheStore.totalFileSize()
        let cached = cacheStore.cachedByteCount(from: offset, maximum: 1) > 0
        if cached {
            cachedSeeks += 1
        } else if size > 0 && offset >= size {
            generation += 1
            streamingLoader.cancel()
            activeRange = nil
        } else {
            missingSeeks += 1
            Console.log("[Cache] seek miss offset=\(offset)")
            refillLocked(from: offset, demand: true)
        }
        if wasCancelled, activeRange != nil { scheduleWatchdogLocked() }
        condition.broadcast()
    }

    func getFileSize() -> Int64 {
        condition.lock(); defer { condition.unlock() }
        let cachedSize = cacheStore.totalFileSize()
        if cachedSize > 0 { return cachedSize }
        let deadline = Date().addingTimeInterval(FTPlayerSDKConfiguration.Network.sizeProbeTimeout)
        while !closed && !readCancelled && !terminalError {
            let size = cacheStore.totalFileSize()
            if size > 0 { return size }
            guard Date() < deadline, !openingExpiredLocked(), _failure == nil else { break }
            // GET normally supplies the authoritative size. Only fall back to
            // HEAD when its headers have arrived without a total and a caller
            // actually needs that total (e.g. Content-Range: bytes .../*).
            if receivedRangeHeaders, !sizeProbeStarted {
                sizeProbeStarted = true
                condition.unlock()
                streamingLoader.getFileSize { [weak self] size in
                    guard let self else { return }
                    self.condition.lock(); defer { self.condition.unlock() }
                    guard !self.closed else { return }
                    if let size, size > 0, self.cacheStore.totalFileSize() <= 0 {
                        self.cacheStore.setTotalFileSize(size)
                    }
                    self.condition.broadcast()
                }
                condition.lock()
                continue
            }
            condition.wait(until: boundedWakeLocked(deadline))
        }
        Console.log(type: .ERROR, "Cache file-size probe unavailable/canceled/timed out")
        return -1
    }

    func resumeRead() {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        readCancelled = false
        readTimedOut = false
        if activeRange != nil { scheduleWatchdogLocked() }
        condition.broadcast()
        Console.log("[Cache] resume AVIO reads offset=\(_currentOffset) revision=\(readRevision)")
    }

    func cancelRead() {
        condition.lock(); defer { condition.unlock() }
        readCancelled = true
        readRevision += 1
        condition.broadcast()
    }

    func close() {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        closed = true
        generation += 1
        streamingLoader.invalidate()
        condition.broadcast()
        cacheStore.saveIndex()
        cacheStore.closeHandles()
        Console.log("[Cache] close diskReadBytes=\(hitBytes) networkBytes=\(networkBytes) requests=\(requestCount) cachedSeeks=\(cachedSeeks) missingSeeks=\(missingSeeks)")
    }

    func readPacket(into buffer: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        guard let data = read(offset: currentOffset, length: Int(size)), !data.isEmpty else {
            condition.lock(); defer { condition.unlock() }
            if readTimedOut { return -Int32(ETIMEDOUT) }
            return _failure != nil ? -Int32(EIO) : FT_AVERROR_EOF
        }
        data.copyBytes(to: buffer, count: data.count)
        condition.lock(); defer { condition.unlock() }
        _currentOffset += Int64(data.count)
        refillLocked(from: _currentOffset, demand: false)
        return Int32(data.count)
    }

    func seekPacket(offset: Int64, whence: Int32) -> Int64 {
        let target: Int64
        switch whence & ~Int32(0x20000) {
        case 0x10000: return getFileSize()
        case 0: target = offset
        case 1:
            if offset == 0 { return currentOffset }
            let (value, overflow) = currentOffset.addingReportingOverflow(offset)
            guard !overflow else { return -1 }; target = value
        case 2:
            let size = getFileSize()
            guard size > 0 else { return -1 }
            let (value, overflow) = size.addingReportingOverflow(offset)
            guard !overflow else { return -1 }; target = value
        default: return -1
        }
        guard target >= 0, target <= Int64.max - chunkSize else {
            Console.log(type: .ERROR, "Rejected invalid cache seek offset=\(offset) whence=\(whence)")
            return -1
        }
        seek(to: target)
        return currentOffset
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
