import Foundation

struct HLSSeekPeriod {
    let start: Double
    let nativePlaylist: Bool
}

protocol HLSCaching: AnyObject {
    var file: URL { get }
    var inputFormatName: String { get }
    var duration: Double { get }
    var maximumSegmentDuration: Double { get }
    func seekPeriod(for time: Double) -> HLSSeekPeriod?
    var fraction: Double { get }
    var ranges: [FTPlayerCachedTimeRange] { get }
    var diagnostics: [String: Int64] { get }
    var failure: NSError? { get }
    var waiting: Bool { get }
    func configureLoadControl(_ configuration: FTPlayerLoadControlConfiguration, video: Bool, audio: Bool)
    func setPlaybackPosition(_ value: Double)
    func setPlaybackRate(_ value: Float)
    func finishOpening()
    func cancelReads()
    func resumeReads()
    func close()
}

extension HLSCaching {
    func seekPeriod(for time: Double) -> HLSSeekPeriod? { nil }
}

/// Resolves the first declared variant and its default audio rendition. The SDK
/// exposes one selected A/V pair; unused qualities/renditions are not downloaded.
final class FTHLSMasterCache: HLSCaching {
    struct Selection {
        let video: URL
        let audio: URL?
        let streamAttributes: [String: String]
        let audioAttributes: [String: String]?
    }
    struct Configuration: Codable {
        let source: URL
        let video: FTIndependentHLS.Manifest
        let audio: FTIndependentHLS.Manifest?
        let streamAttributes: [String: String]
        let audioAttributes: [String: String]?
    }
    private let configuration: Configuration
    private var children: [FTIndependentHLS] = []
    private let onProgress: ((Double) -> Void)?
    private let masterFile: URL
    var file: URL { children.count == 1 && children[0].inputFormatName == "concat" ? children[0].file : masterFile }
    var inputFormatName: String { children.count == 1 ? children[0].inputFormatName : "hls" }
    func seekPeriod(for time: Double) -> HLSSeekPeriod? {
        children.count == 1 ? children[0].seekPeriod(for: time) : nil
    }
    var duration: Double { children.first?.duration ?? 0 }
    var maximumSegmentDuration: Double { children.first?.maximumSegmentDuration ?? 0 }

    static func parse(_ response: HTTPDataResponse) -> Selection? {
        guard response.data.count <= FTPlayerSDKConfiguration.HLS.maximumManifestBytes,
              let text = String(data: response.data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !lines.contains(where: { $0.hasPrefix("#EXT-X-DEFINE:") }) else { return nil }
        var stream: [String: String]?, video: URL?, renditions: [[String: String]] = []
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:"), stream == nil {
                guard let attributes = FTIndependentHLS.parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count))),
                      attributes["BANDWIDTH"].flatMap(Int64.init).map({ $0 > 0 }) == true else { return nil }
                stream = attributes
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                guard let attributes = FTIndependentHLS.parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count))) else { return nil }
                renditions.append(attributes)
            } else if !line.isEmpty, !line.hasPrefix("#"), stream != nil, video == nil {
                video = URL(string: line, relativeTo: response.url)?.absoluteURL
            }
        }
        guard let stream, let video, ["http", "https"].contains(video.scheme?.lowercased() ?? ""), stream["VIDEO"] == nil else { return nil }
        var audio: URL?, selectedAudio: [String: String]?
        if let group = stream["AUDIO"] {
            let matches = renditions.filter { $0["TYPE"] == "AUDIO" && $0["GROUP-ID"] == group }
            guard let selected = matches.first(where: { $0["DEFAULT"] == "YES" }) ?? matches.first(where: { $0["AUTOSELECT"] == "YES" }) ?? matches.first else { return nil }
            if let uri = selected["URI"] {
                guard let url = URL(string: uri, relativeTo: response.url)?.absoluteURL,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url != video else { return nil }
                audio = url; selectedAudio = selected
            }
        }
        return Selection(video: video, audio: audio, streamAttributes: stream, audioAttributes: selectedAudio)
    }

    static func restore(source: URL, session: any PlaybackCacheSession) -> Configuration? {
        guard let data = try? Data(contentsOf: session.directory.appendingPathComponent("master-hls-source.json")),
              let value = try? JSONDecoder().decode(Configuration.self, from: data), value.source == source else { return nil }
        return value
    }
    static func prepare(source: URL, response: HTTPDataResponse, session: any PlaybackCacheSession,
                        timeout: Double, interrupted: () -> Bool, preparation: ((FTPlayerPreparationState) -> Void)?,
                        loader: any HTTPDataLoading) throws -> Configuration? {
        guard let selected = parse(response) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func media(_ url: URL, name: String) throws -> FTIndependentHLS.Manifest? {
            try FTIndependentHLS.prepare(source: url, session: session,
                timeout: max(FTPlayerSDKConfiguration.Network.minimumReadTimeout, deadline - ProcessInfo.processInfo.systemUptime), interrupted: interrupted,
                preparation: preparation, loader: loader, cacheName: name)
        }
        guard let video = try media(selected.video, name: "video"),
              selected.audio == nil || video.playlist != nil || video.initialization != nil else { return nil }
        var audio: FTIndependentHLS.Manifest?
        if let url = selected.audio {
            guard let value = try media(url, name: "audio"), value.playlist != nil || value.initialization != nil else { return nil }
            audio = value
        }
        guard !session.isClosed, !interrupted() else { throw URLError(.cancelled) }
        let value = Configuration(source: source, video: video, audio: audio,
                                  streamAttributes: selected.streamAttributes, audioAttributes: selected.audioAttributes)
        try JSONEncoder().encode(value).write(to: session.directory.appendingPathComponent("master-hls-source.json"), options: .atomic)
        return value
    }

    init(configuration: Configuration, session: any PlaybackCacheSession, cache: Bool = true, timeout: Double,
         onPreparation: ((FTPlayerPreparationState) -> Void)?, onProgress: ((Double) -> Void)?) throws {
        self.configuration = configuration; self.onProgress = onProgress
        masterFile = session.directory.appendingPathComponent("cached-master.m3u8")
        func child(_ manifest: FTIndependentHLS.Manifest, name: String) throws -> FTIndependentHLS {
            try FTIndependentHLS(manifest: manifest, session: session, cache: cache, timeout: timeout,
                onPreparation: onPreparation, onProgress: { [weak self] _ in
                    guard let self else { return }; self.onProgress?(self.fraction)
                }, cacheName: name, normalizeDiscontinuities: configuration.audio == nil)
        }
        children.append(try child(configuration.video, name: "video"))
        if let audio = configuration.audio { children.append(try child(audio, name: "audio")) }
        var stream = configuration.streamAttributes
        // The SDK renders selected audio/video only. Do not retain references to
        // subtitle/closed-caption groups that are absent from the cached master.
        stream.removeValue(forKey: "SUBTITLES"); stream.removeValue(forKey: "CLOSED-CAPTIONS")
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n"
        if children.count == 2, var attributes = configuration.audioAttributes {
            attributes["URI"] = children[1].file.absoluteString
            text += "#EXT-X-MEDIA:\(Self.attributeText(attributes))\n"
        } else { stream.removeValue(forKey: "AUDIO") }
        text += "#EXT-X-STREAM-INF:\(Self.attributeText(stream))\n\(children[0].file.absoluteString)\n"
        try Data(text.utf8).write(to: masterFile, options: .atomic)
    }
    private static func attributeText(_ attributes: [String: String]) -> String {
        let unquoted: Set<String> = ["TYPE", "DEFAULT", "AUTOSELECT", "FORCED", "BANDWIDTH", "AVERAGE-BANDWIDTH", "RESOLUTION", "FRAME-RATE", "VIDEO-RANGE", "HDCP-LEVEL"]
        return attributes.keys.sorted().map { key in
            let value = attributes[key]!
            return "\(key)=\(unquoted.contains(key) ? value : "\"\(value)\"")"
        }.joined(separator: ",")
    }
    var fraction: Double {
        let values = children.map { $0.diagnostics }
        guard values.allSatisfy({ $0["hlsCacheMetadataComplete"] == 1 }) else { return 0 }
        let total = values.reduce(Int64(0)) { $0 + ($1["hlsStorageTotalBytes"] ?? 0) }
        let cached = values.reduce(Int64(0)) { $0 + ($1["hlsStoredBytes"] ?? 0) }
        return total > 0 ? min(1, Double(cached) / Double(total)) : 0
    }
    var ranges: [FTPlayerCachedTimeRange] {
        var result = children.first?.ranges ?? []
        for child in children.dropFirst() {
            let other = child.ranges
            var intersection: [FTPlayerCachedTimeRange] = [], i = 0, j = 0
            while i < result.count && j < other.count {
                let start = max(result[i].start, other[j].start), end = min(result[i].end, other[j].end)
                if start < end { intersection.append(FTPlayerCachedTimeRange(start: start, end: end)) }
                if result[i].end < other[j].end { i += 1 } else { j += 1 }
            }
            result = intersection
        }
        return result
    }
    var diagnostics: [String: Int64] {
        var result = children.first?.diagnostics ?? [:]
        let totals = ["hlsCachedBytes", "hlsTotalBytes", "hlsStoredBytes", "hlsStorageTotalBytes", "hlsSegments", "hlsCachedSegments", "hlsKnownSizeSegments", "hlsInitCachedBytes", "hlsInitTotalBytes", "hlsKeyCachedBytes", "hlsKeyTotalBytes", "hlsReadAheadTargetBytes", "networkBytes", "diskReadBytes", "rangeRequests"]
        let values = children.map { $0.diagnostics }
        for key in totals { result[key] = values.reduce(0) { $0 + ($1[key] ?? 0) } }
        result["hlsCacheMetadataComplete"] = values.allSatisfy { $0["hlsCacheMetadataComplete"] == 1 } ? 1 : 0
        result["hlsTracks"] = Int64(children.count)
        result["hlsVideoCachedBytes"] = values.first?["hlsCachedBytes"] ?? 0
        if values.count == 2 { result["hlsAudioCachedBytes"] = values[1]["hlsCachedBytes"] ?? 0 }
        return result
    }
    var failure: NSError? { children.compactMap { $0.failure }.first }
    var waiting: Bool { children.contains { $0.waiting } }
    func configureLoadControl(_ configuration: FTPlayerLoadControlConfiguration, video: Bool, audio: Bool) {
        for (index, child) in children.enumerated() {
            child.configureLoadControl(configuration, video: index == 0 && video, audio: children.count == 1 ? audio : index == 1 && audio)
        }
    }
    func setPlaybackPosition(_ value: Double) { children.forEach { $0.setPlaybackPosition(value) } }
    func setPlaybackRate(_ value: Float) { children.forEach { $0.setPlaybackRate(value) } }
    func finishOpening() { children.forEach { $0.finishOpening() } }
    func cancelReads() { children.forEach { $0.cancelReads() } }
    func resumeReads() { children.forEach { $0.resumeReads() } }
    func close() { children.forEach { $0.close() } }
    deinit { close() }
}
