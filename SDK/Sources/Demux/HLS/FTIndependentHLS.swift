import Foundation
import Network

/// A VOD made of independently initialized MP4 files needs a file timeline, rather
/// than concatenating their bytes (each file's tfdt starts again near zero).
/// A single complete MP4 uses the same cache and accurate file seek path.
/// Native HLS VOD preserves playlist control tags while media, maps and keys
/// use the same session cache, regardless of media container or URL suffix.
final class FTIndependentHLS: HLSCaching {
    struct Segment: Codable {
        let url: URL; let duration: Double; let byteRange: CachedRange?; let dependencies: [Int]?
        init(url: URL, duration: Double, byteRange: CachedRange? = nil, dependencies: [Int]? = nil) {
            self.url = url; self.duration = duration; self.byteRange = byteRange; self.dependencies = dependencies
        }
    }
    struct Auxiliary: Codable { let url: URL; let byteRange: CachedRange?; let isKey: Bool }
    struct PlaylistLine: Codable {
        let text: String; var media: Int? = nil; var auxiliary: Int? = nil; var attributes: [String: String]? = nil
    }
    struct Manifest: Codable {
        let source: URL
        let segments: [Segment]
        let initialization: URL?
        let initializationRange: CachedRange?
        let auxiliary: [Auxiliary]?
        let playlist: [PlaylistLine]?
        // TS discontinuities introduce independent timestamp origins. Keep each
        // period as HLS (including encryption), then join its public timeline.
        var periods: [[Int]]? {
            guard !segments.isEmpty, let playlist, !playlist.contains(where: { $0.text.hasPrefix("#EXT-X-MAP:") }),
                  segments.allSatisfy({ $0.byteRange == nil && $0.url.pathExtension.lowercased() == "ts" }) else { return nil }
            if let line = playlist.first(where: { $0.text.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }) {
                guard let sequence = UInt64(line.text.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)),
                      sequence <= UInt64.max - UInt64(segments.count - 1) else { return nil }
            }
            var result: [[Int]] = [], current: [Int] = []
            for line in playlist {
                if line.text == "#EXT-X-DISCONTINUITY", !current.isEmpty {
                    result.append(current); current = []
                }
                if let media = line.media { current.append(media) }
            }
            if !current.isEmpty { result.append(current) }
            return result.count > 1 ? result : nil
        }
        var usesNativeHLS: Bool { (playlist != nil || initialization != nil) && periods == nil }
        init(source: URL, segments: [Segment], initialization: URL? = nil, initializationRange: CachedRange? = nil,
             auxiliary: [Auxiliary]? = nil, playlist: [PlaylistLine]? = nil) {
            self.source = source; self.segments = segments; self.initialization = initialization
            self.initializationRange = initializationRange
            self.auxiliary = auxiliary; self.playlist = playlist
        }
    }
    private struct Resource: Codable { var total: Int64 = 0; var cached: Int64 = 0 }
    let manifest: Manifest
    private let joinedPeriods: [[Int]]?
    let file: URL
    let cacheEnabled: Bool
    private let session: any PlaybackCacheSession
    private let revision: Int
    private let lock = NSLock()
    private var resources: [Resource]
    private let resourceURLs: [URL]
    private let resourceRanges: [CachedRange?]
    private let resourceKeys: [String]
    private let resourceIndicesByKey: [String: [Int]]
    private let auxiliary: [Auxiliary]
    private let indexFile: URL
    private var workers: [UUID: CacheWorker] = [:]
    private static let transferCounterKeys = ["diskReadBytes", "networkBytes", "rangeRequests"]
    // Connections and prefetch workers retire after EOF. Their completed work
    // still belongs to this HLS input, even when no worker is currently active.
    private var completedTransferCounters: [String: Int64] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var listener: NWListener?
    private var prefetch: [Int: CacheWorker] = [:]
    private var prefetchFailed = Set<Int>()
    private var rate: Float = FTPlayerSDKConfiguration.Playback.defaultRate
    private var playbackPosition = 0.0
    private var loadControl = FTPlayerLoadControl()
    private var lastMediaAhead = 0.0
    private let prefetchQueue = DispatchQueue(label: "FTPlayer.hls.prefetch", qos: .utility)
    private let proxyQueue = DispatchQueue(label: "FTPlayer.hls.proxy")
    private let token = UUID().uuidString
    private var closed = false
    private var opening = true
    private var nextMetadataIndex = 0
    private var activeMetadataProbes = 0
    private var probedMetadataURLs = Set<URL>()
    private var openDeadline: TimeInterval
    private var lastFailure: NSError?
    private let metadataProbe: HTTPResourceSizeProbe
    private let onProgress: ((Double) -> Void)?
    private let onPreparation: ((FTPlayerPreparationState) -> Void)?
    var duration: Double { manifest.segments.reduce(0) { $0 + $1.duration } }
    var maximumSegmentDuration: Double { manifest.segments.map { $0.duration }.max() ?? 0 }
    var inputFormatName: String { joinedPeriods == nil && (manifest.playlist != nil || manifest.initialization != nil) ? "hls" : "concat" }
    func seekPeriod(for time: Double) -> HLSSeekPeriod? {
        guard inputFormatName == "concat" else { return nil }
        var position = 0.0, lastStart = 0.0
        let durations = joinedPeriods?.map { indices in indices.reduce(0.0) { $0 + manifest.segments[$1].duration } }
            ?? manifest.segments.map(\.duration)
        for duration in durations {
            lastStart = position
            if time < position + duration { return HLSSeekPeriod(start: position, nativePlaylist: joinedPeriods != nil) }
            position += duration
        }
        return HLSSeekPeriod(start: lastStart, nativePlaylist: joinedPeriods != nil)
    }
    private static func resourceKey(_ url: URL, _ range: CachedRange?) -> String {
        url.absoluteString + (range.map { "\n\($0.start)-\($0.end)" } ?? "")
    }
    private func matches(_ worker: CacheWorker, _ index: Int) -> Bool {
        worker.videoURLForDiagnostics == resourceURLs[index] && worker.resourceRangeForDiagnostics == resourceRanges[index]
    }

    static func parse(_ data: Data, source: URL) -> Manifest? {
        guard data.count <= FTPlayerSDKConfiguration.HLS.maximumManifestBytes, let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.filter({ $0 == "#EXT-X-ENDLIST" }).count == 1,
              !lines.contains(where: {
                  $0.hasPrefix("#EXT-X-STREAM-INF:") || $0.hasPrefix("#EXT-X-MEDIA:") ||
                  $0.hasPrefix("#EXT-X-GAP") || $0.hasPrefix("#EXT-X-DEFINE:") || $0.hasPrefix("#EXT-X-I-FRAMES-ONLY")
              }) else { return nil }
        if !lines.contains(where: { $0.hasPrefix("#EXT-X-MAP:") || $0.hasPrefix("#EXT-X-KEY:") || $0.hasPrefix("#EXT-X-BYTERANGE:") }),
           let independent = parseIndependent(lines, source: source) { return independent }
        return parseMediaPlaylist(lines, source: source)
    }

    static func parseIndependent(_ lines: [String], source: URL) -> Manifest? {
        var segments: [Segment] = [], nextDuration: Double?
        var discontinuity = false
        for line in lines {
            if line == "#EXT-X-DISCONTINUITY" {
                // A leading discontinuity starts the first period; it does not
                // remove the need for a tag at every subsequent file boundary.
                guard !discontinuity else { return nil }
                discontinuity = true
            }
            else if line.hasPrefix("#EXTINF:") {
                guard nextDuration == nil else { return nil }
                nextDuration = line.dropFirst(8).split(separator: ",").first.flatMap { Double($0) }
            }
            else if !line.isEmpty && !line.hasPrefix("#") {
                guard segments.isEmpty || discontinuity,
                      let seconds = nextDuration, seconds.isFinite, seconds > 0, seconds < FTPlayerSDKConfiguration.HLS.maximumSegmentDuration,
                      let url = URL(string: line, relativeTo: source)?.absoluteURL,
                      ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                segments.append(Segment(url: url, duration: seconds)); nextDuration = nil; discontinuity = false
            }
        }
        guard !segments.isEmpty, segments.count <= FTPlayerSDKConfiguration.HLS.maximumSegments, nextDuration == nil, !discontinuity else { return nil }
        if segments.count == 1, segments[0].url.pathExtension.lowercased() != "mp4" { return nil }
        return Manifest(source: source, segments: segments)
    }

    static func parseByteRange(_ text: String, implicitOffset: Int64?) -> CachedRange? {
        let fields = text.split(separator: "@", omittingEmptySubsequences: false)
        guard fields.count == 1 || fields.count == 2, let length = Int64(fields[0]), length > 0,
              let offset = fields.count == 2 ? Int64(fields[1]) : implicitOffset,
              offset >= 0, offset <= Int64.max - length else { return nil }
        return CachedRange(start: offset, end: offset + length - 1)
    }

    static func parseAttributes(_ text: String) -> [String: String]? {
        var result: [String: String] = [:], cursor = text.startIndex
        while cursor < text.endIndex {
            guard let equals = text[cursor...].firstIndex(of: "=") else { return nil }
            let key = String(text[cursor..<equals]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(","), result[key] == nil else { return nil }
            cursor = text.index(after: equals)
            guard cursor < text.endIndex else { return nil }
            let value: String
            if text[cursor] == "\"" {
                cursor = text.index(after: cursor)
                guard let quote = text[cursor...].firstIndex(of: "\"") else { return nil }
                value = String(text[cursor..<quote]); cursor = text.index(after: quote)
            } else {
                let comma = text[cursor...].firstIndex(of: ",") ?? text.endIndex
                value = String(text[cursor..<comma]); cursor = comma
            }
            result[key] = value
            if cursor == text.endIndex { break }
            guard text[cursor] == "," else { return nil }
            cursor = text.index(after: cursor)
            guard cursor < text.endIndex else { return nil }
        }
        return result
    }

    static func prepare(source: URL, session: any PlaybackCacheSession, timeout: Double,
                        interrupted: () -> Bool, preparation: ((FTPlayerPreparationState) -> Void)?,
                        loader: any HTTPDataLoading = HTTPDataLoader(), cacheName: String = "",
                        onUnsupported: ((HTTPDataResponse) -> Void)? = nil) throws -> Manifest? {
        let prefix = cacheName.isEmpty ? "" : "\(cacheName)-"
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let cached = session.directory.appendingPathComponent("\(prefix)hls-source.json")
        if let data = try? Data(contentsOf: cached), let value = try? JSONDecoder().decode(Manifest.self, from: data), value.source == source { return value }
        let response = try loader.load(source, timeout: timeout, interrupted: interrupted)
        guard !response.data.isEmpty else {
            throw NSError(domain: NSURLErrorDomain, code: URLError.zeroByteResource.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: "HLS playlist response is empty", "operation": "playlist"])
        }
        // Detection alone is not custom AVIO: native HLS must not publish
        // range milestones. Cache workers report those for actual range requests.
        let parsed = try parse(response.data, source: response.url) ?? recoverIndependentDurations(
            response.data, source: response.url, deadline: deadline, interrupted: interrupted)
        guard let parsed else { onUnsupported?(response); return nil }
        // Resolve relative resources against the final response URL, while replay
        // continues to identify this manifest by the URL originally requested.
        let manifest = Manifest(source: source, segments: parsed.segments, initialization: parsed.initialization, initializationRange: parsed.initializationRange,
                                auxiliary: parsed.auxiliary, playlist: parsed.playlist)
        guard !session.isClosed, !interrupted() else { throw NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue) }
        try JSONEncoder().encode(manifest).write(to: cached, options: .atomic)
        return manifest
    }

    /// An invalid EXTINF must not turn independently initialized MP4 files into
    /// one native HLS byte stream: MOV then skips later moov atoms and seek can
    /// reach EOF without ever producing the requested media. Recover only this
    /// file-timeline shape, using actual container duration, never a guessed one.
    private static func recoverIndependentDurations(_ data: Data, source: URL, deadline: TimeInterval,
                                                   interrupted: () -> Bool) throws -> Manifest? {
        guard data.count <= FTPlayerSDKConfiguration.HLS.maximumManifestBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: .newlines)
        var missing: Set<Int> = [], segment = 0
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXTINF:") else { continue }
            let value = line.dropFirst(8).split(separator: ",", omittingEmptySubsequences: false).first.flatMap { Double($0) }
            if value.map({ !$0.isFinite || $0 <= 0 }) ?? true {
                missing.insert(segment)
                // Placeholder is used only to validate the complete playlist
                // structure. It is never persisted or passed to a demuxer.
                lines[index] = "#EXTINF:1,"
            }
            segment += 1
        }
        guard !missing.isEmpty,
              let candidate = parse(Data(lines.joined(separator: "\n").utf8), source: source),
              candidate.playlist == nil, candidate.initialization == nil,
              candidate.segments.allSatisfy({ $0.url.pathExtension.lowercased() == "mp4" }) else { return nil }
        var segments: [Segment] = []
        for (index, item) in candidate.segments.enumerated() {
            let duration = missing.contains(index)
                ? try probeIndependentDuration(item.url, deadline: deadline, interrupted: interrupted) : item.duration
            segments.append(Segment(url: item.url, duration: duration))
        }
        Console.log("[HLS] recovered container durations segments=\(missing.count)")
        return Manifest(source: source, segments: segments)
    }

    private final class DurationProbeInterrupt: FTFormatContextDelegate {
        let interrupted: () -> Bool
        init(_ interrupted: @escaping () -> Bool) { self.interrupted = interrupted }
        func formatContextNeedInterrupt(_ formatContext: FTFormatContext) -> Bool { interrupted() }
    }

    private static func probeIndependentDuration(_ url: URL, deadline: TimeInterval,
                                                 interrupted: () -> Bool) throws -> Double {
        // The delegate is synchronous and destroyed before this scope returns.
        try withoutActuallyEscaping(interrupted) { check in
            guard !check() else { throw URLError(.cancelled) }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw URLError(.timedOut) }
            let interrupt = DurationProbeInterrupt { check() || ProcessInfo.processInfo.systemUptime >= deadline }
            let format = FTFormatContext(contentURL: url, videoFormat: .unknown)
            format.delegate = interrupt
            defer { format.destroy(); withExtendedLifetime(interrupt) {} }
            format.setupSync(timeoutSeconds: Int(ceil(remaining)), useCache: false)
            guard !check() else { throw URLError(.cancelled) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
            if let error = format.error { throw error }
            guard format.mediaInfo?.formatName.split(separator: ",").contains("mov") == true,
                  format.duration.isFinite, format.duration > 0,
                  format.duration < FTPlayerSDKConfiguration.HLS.maximumSegmentDuration else {
                throw NSError(domain: "FTPlayer.HLS", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot determine duration of an independent MP4 segment",
                    "operation": "segment-duration"])
            }
            return format.duration
        }
    }

    init(manifest: Manifest, session: any PlaybackCacheSession, cache: Bool, timeout: Double, onPreparation: ((FTPlayerPreparationState) -> Void)? = nil, onProgress: ((Double) -> Void)? = nil, cacheName: String = "", normalizeDiscontinuities: Bool = true) throws {
        joinedPeriods = normalizeDiscontinuities ? manifest.periods : nil
        self.onProgress = onProgress; self.onPreparation = onPreparation
        self.manifest = manifest; self.session = session; revision = session.currentRevision; cacheEnabled = cache
        let extra = manifest.auxiliary ?? (manifest.initialization.map { [Auxiliary(url: $0, byteRange: manifest.initializationRange, isKey: false)] } ?? [])
        auxiliary = extra
        let urls = manifest.segments.map { $0.url } + extra.map { $0.url }
        let ranges = manifest.segments.map { $0.byteRange } + extra.map { $0.byteRange }
        let keys = urls.indices.map { Self.resourceKey(urls[$0], ranges[$0]) }
        resourceURLs = urls
        resourceRanges = ranges; resourceKeys = keys
        resourceIndicesByKey = Dictionary(grouping: keys.indices, by: { keys[$0] })
        let prefix = cacheName.isEmpty ? "" : "\(cacheName)-"
        indexFile = session.directory.appendingPathComponent("\(prefix)hls-resources.json")
        let nativeInput = joinedPeriods == nil && (manifest.playlist != nil || manifest.initialization != nil)
        file = session.directory.appendingPathComponent(prefix + (nativeInput ? "cached-media.m3u8" : "independent-hls.ffconcat"))
        openDeadline = ProcessInfo.processInfo.systemUptime + timeout
        metadataProbe = HTTPResourceSizeProbe()
        resources = ranges.map { Resource(total: $0.map { $0.end - $0.start + 1 } ?? 0) }
        if cache, let data = try? Data(contentsOf: indexFile), let values = try? JSONDecoder().decode([Resource].self, from: data), values.count == resources.count { resources = values }
        var proxyBase: String?
        if cache {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let service = try NWListener(using: parameters), ready = DispatchSemaphore(value: 0)
            service.stateUpdateHandler = { state in if case .ready = state { ready.signal() }; if case .failed = state { ready.signal() } }
            service.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener = service; service.start(queue: proxyQueue)
            guard ready.wait(timeout: .now() + FTPlayerSDKConfiguration.HLS.proxyStartTimeout) == .success, let port = service.port else { service.cancel(); throw NSError(domain: "FTPlayer.HLSCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to start local segment cache transport"]) }
            proxyBase = "http://127.0.0.1:\(port.rawValue)/\(token)/"
        }
        var text: String
        if let lines = manifest.playlist {
            func url(_ index: Int) -> String {
                guard let proxyBase else { return resourceURLs[index].absoluteString }
                let suffix = index >= manifest.segments.count && extra[index-manifest.segments.count].isKey ? "key" : (resourceURLs[index].pathExtension.isEmpty ? "ts" : resourceURLs[index].pathExtension)
                return proxyBase + "\(index).\(suffix)"
            }
            text = ""
            for line in lines {
                if let index = line.media { text += url(index) + "\n" }
                else if let index = line.auxiliary, var attributes = line.attributes {
                    attributes["URI"] = url(manifest.segments.count + index)
                    if cache { attributes.removeValue(forKey: "BYTERANGE") }
                    text += line.text + Self.resourceAttributes(attributes) + "\n"
                } else if !cache || !line.text.hasPrefix("#EXT-X-BYTERANGE:") { text += line.text + "\n" }
            }
        } else if let initialization = manifest.initialization {
            let target = Int(ceil(manifest.segments.map { $0.duration }.max() ?? 1))
            let map = proxyBase.map { $0 + "\(manifest.segments.count).mp4" } ?? initialization.absoluteString
            let mapRange = !cache ? manifest.initializationRange.map { ",BYTERANGE=\"\($0.end-$0.start+1)@\($0.start)\"" } ?? "" : ""
            text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"\(map)\"\(mapRange)\n"
            for (index, segment) in manifest.segments.enumerated() {
                let url = proxyBase.map { $0 + "\(index).m4s" } ?? segment.url.absoluteString
                text += "#EXTINF:\(segment.duration),\n"
                if !cache, let range = segment.byteRange { text += "#EXT-X-BYTERANGE:\(range.end-range.start+1)@\(range.start)\n" }
                text += "\(url)\n"
            }
            text += "#EXT-X-ENDLIST\n"
        } else {
            text = "ffconcat version 1.0\n"
            for (index, segment) in manifest.segments.enumerated() {
                let url = proxyBase.map { $0 + "\(index).mp4" } ?? segment.url.absoluteString
                let escaped = url.replacingOccurrences(of: "'", with: "'\\''")
                text += "file '\(escaped)'\nduration \(segment.duration)\n"
            }
        }
        if let periods = joinedPeriods {
            // Render standalone period playlists from the already rewritten
            // resource URLs. Preserve key state and sequence-derived AES IVs.
            let lines = text.components(separatedBy: .newlines)
            let sequence = lines.first(where: { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") })
                .flatMap { UInt64($0.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) } ?? 0
            var activeKey: String?, media = 0, period = 0
            var body = "", output = "ffconcat version 1.0\n"
            func finishPeriod() throws {
                guard !body.isEmpty else { return }
                let indices = periods[period]
                let target = Int(ceil(indices.map { manifest.segments[$0].duration }.max() ?? 1))
                let header = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(sequence + UInt64(indices[0]))\n"
                let child = session.directory.appendingPathComponent("\(prefix)period-\(period).m3u8")
                try Data((header + body + "#EXT-X-ENDLIST\n").utf8).write(to: child, options: .atomic)
                let escaped = child.path.replacingOccurrences(of: "'", with: "'\\''")
                let duration = indices.reduce(0.0) { $0 + manifest.segments[$1].duration }
                output += "file '\(escaped)'\nduration \(duration)\noption allowed_extensions ALL\noption extension_picky 0\n"
                body = ""; period += 1
            }
            for line in lines {
                if line == "#EXT-X-DISCONTINUITY" {
                    if period < periods.count, media > periods[period][0] {
                        try finishPeriod()
                        if let activeKey { body += activeKey + "\n" }
                    }
                } else if line.hasPrefix("#EXT-X-KEY:") {
                    activeKey = line; body += line + "\n"
                } else if line.hasPrefix("#EXTINF:") || !line.isEmpty && !line.hasPrefix("#") {
                    body += line + "\n"
                    if !line.hasPrefix("#") { media += 1 }
                }
            }
            try finishPeriod()
            text = output
        }
        try Data(text.utf8).write(to: file, options: .atomic)
        Console.log("[HLS] \(inputFormatName) timeline segments=\(manifest.segments.count) duration=\(duration) cache=\(cache)")
    }

    // Opening needs the first resource, not sizes for the whole playlist. Keep
    // metadata off the demux thread and leave connection capacity for video reads.
    // A failed probe advances too; it must not starve the remaining resources.
    private func refillMetadataProbes() {
        lock.lock(); defer { lock.unlock() }
        guard cacheEnabled, !opening, !closed, !session.isClosed,
              session.currentRevision == revision else { return }
        while activeMetadataProbes < 2, nextMetadataIndex < resources.count {
            let index = nextMetadataIndex
            nextMetadataIndex += 1
            guard resources[index].total <= 0 else { continue }
            let url = resourceURLs[index]
            guard probedMetadataURLs.insert(url).inserted else { continue }
            activeMetadataProbes += 1
            metadataProbe.size(of: url) { [weak self] total in
                guard let self else { return }
                self.lock.lock()
                self.activeMetadataProbes -= 1
                guard !self.closed else { self.lock.unlock(); return }
                if let total, total > 0 {
                    for alias in self.resourceIndicesByKey[self.resourceKeys[index]] ?? [] { self.resources[alias].total = total }
                    self.persistLocked()
                }
                self.lock.unlock()
                self.onProgress?(self.fraction)
                self.prefetchQueue.async { [weak self] in self?.refillMetadataProbes() }
                self.schedulePrefetch()
            }
        }
    }

    private func persistLocked() {
        guard !closed, !session.isClosed, session.currentRevision == revision,
              let data = try? JSONEncoder().encode(resources) else { return }
        try? data.write(to: indexFile, options: .atomic)
    }
    private func update(_ worker: CacheWorker, index: Int) {
        let bytes = worker.cachedByteRanges.reduce(Int64(0)) { $0 + $1.end - $1.start + 1 }, total = worker.knownFileSize
        lock.lock(); guard !closed else { lock.unlock(); return }
        // CacheStore keys bytes by URL. A repeated segment has distinct timeline
        // positions but shares those bytes, sizes and active workers.
        for alias in resourceIndicesByKey[resourceKeys[index]] ?? [] {
            resources[alias].cached = bytes
            if total > 0 { resources[alias].total = total }
        }
        let resourceBudget = min(loadControl.targetBytes, max(FTPlayerSDKConfiguration.Cache.minimumReadAheadBytes, total))
        persistLocked(); lock.unlock()
        // A proxy request can create its worker before metadata probing finishes.
        // Once GET reveals the size, finish the selected segment within the HLS
        // budget even if paused demux stops consuming its body halfway through.
        worker.setResourceReadAheadBytes(resourceBudget)
        onProgress?(fraction)
        schedulePrefetch()
    }
    var fraction: Double {
        lock.withLock {
            let unique = uniqueResources(resources)
            guard cacheEnabled, unique.allSatisfy({ $0.total > 0 }) else { return 0 }
            let total = unique.reduce(Int64(0)) { $0 + $1.total }, loaded = unique.reduce(Int64(0)) { $0 + min($1.total, $1.cached) }
            return total > 0 ? min(1, Double(loaded)/Double(total)) : 0
        }
    }
    private func uniqueResources(_ values: [Resource]) -> [Resource] {
        resourceIndicesByKey.values.compactMap { $0.first.map { values[$0] } }
    }
    var ranges: [FTPlayerCachedTimeRange] {
        lock.withLock {
            guard cacheEnabled else { return [] }
            var values: [FTPlayerCachedTimeRange] = [], position = 0.0
            for (i, segment) in manifest.segments.enumerated() {
                let end = position + segment.duration
                if mediaIsCached(i, resources) {
                    if let last = values.last, abs(last.end-position) < FTPlayerSDKConfiguration.Precision.hlsRangeMergeTolerance { values[values.count-1] = FTPlayerCachedTimeRange(start: last.start, end: end) }
                    else { values.append(FTPlayerCachedTimeRange(start: position, end: end)) }
                }
                position = end
            }
            return values
        }
    }
    var failure: NSError? { lock.withLock { lastFailure } }
    var waiting: Bool { lock.withLock { Array(workers.values) }.contains { $0.isWaitingForNetwork } }
    var diagnostics: [String: Int64] {
        let current = lock.withLock { (Array(workers.values), resources, loadControl, lastMediaAhead, rate, playbackPosition,
                                       completedTransferCounters, Array(prefetch.values)) }
        var time = 0.0, windowBytes: Int64 = 0
        for (i,segment) in manifest.segments.enumerated() {
            let end = time+segment.duration
            if end > current.5 && time < current.5+current.2.configuration.maximumBufferDuration { windowBytes += current.1[i].total }
            time = end
        }
        let media = current.1.prefix(manifest.segments.count)
        var result = ["hlsReadAheadTargetBytes": windowBytes, "hlsKnownSizeSegments": Int64(media.filter { $0.total > 0 }.count), "hlsTotalBytes": current.1.reduce(0) { $0 + $1.total }, "hlsSegments": Int64(manifest.segments.count), "hlsCachedSegments": Int64(media.filter { $0.total > 0 && $0.cached >= $0.total }.count), "hlsCachedBytes": current.1.reduce(0) { $0 + $1.cached }]
        let unique = uniqueResources(current.1)
        result["hlsStoredBytes"] = unique.reduce(0) { $0 + $1.cached }
        result["hlsStorageTotalBytes"] = unique.reduce(0) { $0 + $1.total }
        for isKey in [false, true] {
            let items = auxiliary.indices.filter { auxiliary[$0].isKey == isKey }.map { current.1[manifest.segments.count+$0] }
            let label = isKey ? "hlsKey" : "hlsInit"
            result[label+"TotalBytes"] = items.reduce(0) { $0 + $1.total }
            result[label+"CachedBytes"] = items.reduce(0) { $0 + $1.cached }
        }
        result["hlsCacheMetadataComplete"] = current.1.allSatisfy { $0.total > 0 } ? 1 : 0
        result["loadMinMediaMilliseconds"] = Int64(current.2.configuration.minimumDuration(rate:current.4)*1000)
        result["loadMaxMediaMilliseconds"] = Int64(current.2.configuration.maximumBufferDuration*1000)
        result["loadTargetBytes"] = current.2.targetBytes
        result["loadBufferedMilliseconds"] = Int64(max(0,current.3)*1000)
        result["loadIsLoading"] = current.2.isLoading ? 1 : 0
        var seen = Set<ObjectIdentifier>()
        for worker in current.0 where seen.insert(ObjectIdentifier(worker)).inserted {
            for (key, value) in worker.diagnosticSnapshot where !Self.transferCounterKeys.contains(key) { result[key, default: 0] += value }
        }
        result.merge(current.6, uniquingKeysWith: +)
        seen.removeAll()
        for worker in current.0 + current.7 where seen.insert(ObjectIdentifier(worker)).inserted {
            let values = worker.diagnosticSnapshot
            for key in Self.transferCounterKeys { result[key, default: 0] += values[key] ?? 0 }
        }
        return result
    }
    // Caller holds lock, and has removed the worker's last active reference.
    private func retireWorkerLocked(_ worker: CacheWorker) {
        worker.close()
        let values = worker.diagnosticSnapshot
        for key in Self.transferCounterKeys { completedTransferCounters[key, default: 0] += values[key] ?? 0 }
    }
    func configureLoadControl(_ configuration: FTPlayerLoadControlConfiguration, video: Bool, audio: Bool) {
        lock.withLock { loadControl = FTPlayerLoadControl(configuration:configuration,video:video,audio:audio) }
        schedulePrefetch()
    }
    func setPlaybackPosition(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        lock.withLock { playbackPosition = value }
        schedulePrefetch()
    }
    func setPlaybackRate(_ value: Float) {
        guard value.isFinite, (FTPlayerSDKConfiguration.Playback.minimumRate...FTPlayerSDKConfiguration.Playback.maximumRate).contains(value) else { return }
        lock.withLock { rate = value }
        schedulePrefetch()
    }
    private func newWorkerLocked(_ index: Int) throws -> CacheWorker {
        if let worker = prefetch.removeValue(forKey: index) { return worker }
        let url = resourceURLs[index]
        if let entry = prefetch.first(where: { matches($0.value, index) }) {
            prefetch.removeValue(forKey: entry.key)
            return entry.value
        }
        if let worker = workers.values.first(where: { matches($0, index) }) { return worker }
        let worker = try session.makeWorker(videoURL: url, revision: revision, knownFileSize: resources[index].total, onPreparationState: onPreparation, resourceRange: resourceRanges[index])
        worker.setResourceReadAheadBytes(min(loadControl.targetBytes,max(FTPlayerSDKConfiguration.Cache.minimumReadAheadBytes,resources[index].total)))
        worker.onProgress = { [weak self, weak worker] _ in if let worker { self?.update(worker, index: index) } }
        return worker
    }
    private func schedulePrefetch() { prefetchQueue.async { [weak self] in self?.refillPrefetch() } }
    private func dependencies(_ index: Int) -> [Int] {
        manifest.segments[index].dependencies ?? (manifest.initialization == nil ? [] : [0])
    }
    private func mediaIsCached(_ index: Int, _ values: [Resource]) -> Bool {
        ([index] + dependencies(index).map { manifest.segments.count + $0 }).allSatisfy {
            values[$0].total > 0 && values[$0].cached >= values[$0].total
        }
    }
    private func refillPrefetch() {
        lock.lock()
        guard cacheEnabled, !opening, !closed, !session.isClosed, session.currentRevision == revision else { lock.unlock(); return }
        var release: [(Int, CacheWorker)] = []
        var wanted = Set<Int>(), bytesAhead: Int64 = 0
        let endTime = playbackPosition+loadControl.configuration.maximumBufferDuration
        var position = 0.0, mediaAhead = 0.0
        for (i,segment) in manifest.segments.enumerated() {
            let end = position+segment.duration
            defer { position = end }
            guard end > playbackPosition, position < endTime else { continue }
            if mediaIsCached(i, resources) && position <= playbackPosition+mediaAhead+FTPlayerSDKConfiguration.Cache.playableRangeTolerance {
                mediaAhead = end-playbackPosition
            }
            bytesAhead += resources[i].cached
        }
        lastMediaAhead = mediaAhead
        let loading = loadControl.shouldLoad(mediaAhead:mediaAhead,bytesAhead:bytesAhead,rate:rate)
        if loading {
            position = 0
            var planned: Int64 = 0
            for (i,segment) in manifest.segments.enumerated() {
                let end = position+segment.duration
                defer { position = end }
                guard end > playbackPosition, position < endTime else { continue }
                if planned >= loadControl.targetBytes && !loadControl.configuration.prioritizesTimeOverSize { break }
                wanted.insert(i); planned += max(1,resources[i].total)
                wanted.formUnion(dependencies(i).map { manifest.segments.count + $0 })
            }
        }
        for (index, worker) in prefetch where !wanted.contains(index) || worker.cachedFraction >= 1 || worker.failure != nil {
            prefetch.removeValue(forKey: index)
            if worker.failure != nil { prefetchFailed.insert(index) }
            // Persist its byte index before another request can open this resource.
            retireWorkerLocked(worker)
            release.append((index, worker))
        }
        // Size probing is advisory. A failed/slow probe must not prevent the
        // actual segment GET from discovering its size and filling the window.
        for index in wanted.sorted() where prefetch.count < 2 && (resources[index].total <= 0 || resources[index].cached < resources[index].total) && !prefetchFailed.contains(index) {
            if prefetch.values.contains(where: { matches($0, index) }) || workers.values.contains(where: { matches($0, index) }) { continue }
            do { prefetch[index] = try newWorkerLocked(index) } catch { prefetchFailed.insert(index) }
        }
        lock.unlock()
        for (index, worker) in release { update(worker, index: index) }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        lock.lock(); guard !closed else { lock.unlock(); connection.cancel(); return }; connections[id] = connection; lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.finish(id) }
            if case .failed = state { self?.finish(id) }
        }
        connection.start(queue: proxyQueue)
        receive(connection, id: id, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: FTPlayerSDKConfiguration.HLS.proxyHeaderReadBytes) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated; if let data { bytes.append(data) }
            if let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.respond(connection, id: id, request: text) }
            } else if error == nil && !complete && bytes.count < FTPlayerSDKConfiguration.HLS.maximumProxyHeaderBytes { self.receive(connection, id: id, accumulated: bytes) }
            else { self.finish(id) }
        }
    }
    private func finish(_ id: UUID) {
        lock.lock(); let connection = connections.removeValue(forKey: id), worker = workers.removeValue(forKey: id)
        let shared = worker.map { old in workers.values.contains { $0 === old } || prefetch.values.contains { $0 === old } } ?? false
        if let worker, !shared { worker.cancelRead(); retireWorkerLocked(worker) }
        lock.unlock()
        connection?.stateUpdateHandler = nil; connection?.cancel()
        if let worker, !shared {
            if let index = resourceURLs.indices.first(where: { matches(worker, $0) }) { update(worker, index: index) }
            if let failure = worker.failure { lock.withLock { lastFailure = failure } }
        }
    }
    private func send(_ data: Data, connection: NWConnection, id: UUID, then: @escaping () -> Void) {
        guard lock.withLock({ connections[id] != nil && !closed }) else { finish(id); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.finish(id) }
            else { DispatchQueue.global(qos: .userInitiated).async(execute: then) }
        })
    }
    private func respond(_ connection: NWConnection, id: UUID, request: String) {
        let lines = request.components(separatedBy: "\r\n"), first = (request.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        guard first.count >= 2, first[0] == "GET" || first[0] == "HEAD" else { finish(id); return }
        let parts = first[1].split(separator: "/")
        guard parts.count == 2, parts[0] == Substring(token), let index = Int(parts[1].split(separator: ".")[0]), resourceURLs.indices.contains(index) else { finish(id); return }
        lock.lock()
        guard !closed, connections[id] != nil else { lock.unlock(); return }
        let worker: CacheWorker
        do { worker = try newWorkerLocked(index) } catch { lock.unlock(); finish(id); return }
        workers[id] = worker
        let wasOpening = opening, remaining = openDeadline-ProcessInfo.processInfo.systemUptime; lock.unlock()
        worker.waitsForNetwork = true
        worker.resumeRead()
        if wasOpening { worker.beginOpening(timeout: max(FTPlayerSDKConfiguration.Network.minimumReadTimeout, remaining)) }
        schedulePrefetch()
        let size = worker.getFileSize()
        guard size > 0 else { if let error = worker.failure { lock.withLock { lastFailure = error } }; finish(id); return }
        update(worker, index: index)
        var start: Int64 = 0, end = size-1, ranged = false
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") })?.components(separatedBy: "bytes=").last {
            let pair = range.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
            if pair.count == 2, let number = Int64(pair[0]) { start = number; end = min(size-1, Int64(pair[1]) ?? size-1); ranged = true }
        }
        guard start >= 0, start < size, end >= start else { finish(id); return }
        let rangeHeader = ranged ? "Content-Range: bytes \(start)-\(end)/\(size)\r\n" : ""
        let mediaType: String
        switch resourceURLs[index].pathExtension.lowercased() {
        case "ts": mediaType = "video/mp2t"
        case "aac": mediaType = "audio/aac"
        case "mp4", "m4s", "m4a": mediaType = "video/mp4"
        default: mediaType = "application/octet-stream"
        }
        let header = "HTTP/1.1 \(ranged ? "206 Partial Content" : "200 OK")\r\nContent-Length: \(end-start+1)\r\nAccept-Ranges: bytes\r\nContent-Type: \(mediaType)\r\nConnection: close\r\n\(rangeHeader)\r\n"
        worker.seek(to: start)
        send(Data(header.utf8), connection: connection, id: id) { [weak self] in
            guard let self else { return }
            if first[0] == "HEAD" { self.finish(id) }
            else { self.produce(worker, offset: start, end: end, connection: connection, id: id) }
        }
    }
    private func produce(_ worker: CacheWorker, offset: Int64, end: Int64, connection: NWConnection, id: UUID) {
        guard lock.withLock({ connections[id] != nil && !closed }) else { finish(id); return }
        if offset > end { finish(id); return }
        guard let bytes = worker.readForProxy(offset: offset, length: Int(min(Int64(FTPlayerSDKConfiguration.HLS.resourceReadBytes), end-offset+1))), !bytes.isEmpty else { finish(id); return }
        send(bytes, connection: connection, id: id) { [weak self] in self?.produce(worker, offset: offset+Int64(bytes.count), end: end, connection: connection, id: id) }
    }
    func finishOpening() {
        let all = lock.withLock { opening = false; return Array(workers.values) }
        all.forEach { $0.finishOpening() }
        prefetchQueue.async { [weak self] in self?.refillMetadataProbes() }
        schedulePrefetch()
    }
    func cancelReads() { lock.withLock { Array(workers.values) }.forEach { $0.cancelRead() } }
    func resumeReads() { lock.withLock { lastFailure = nil; return Array(workers.values) }.forEach { $0.resumeRead() } }
    func close() {
        lock.lock(); guard !closed else { lock.unlock(); return }; persistLocked(); closed = true
        let all = Array(connections.keys), warm = Array(prefetch.values); prefetch.removeAll()
        warm.forEach { retireWorkerLocked($0) }; lock.unlock()
        listener?.cancel(); metadataProbe.close(); all.forEach { finish($0) }
    }
    deinit { close() }
}
