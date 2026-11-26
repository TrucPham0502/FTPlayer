import Foundation

extension FTIndependentHLS {
    /// Preserve native playlist semantics and describe cache resources separately.
    /// Container probing/decryption stay in FFmpeg, independent of URL suffixes.
    static func parseMediaPlaylist(_ lines: [String], source: URL) -> Manifest? {
        var segments: [Segment] = [], extra: [Auxiliary] = [], template: [PlaylistLine] = []
        var duration: Double?, rangeText: String?, currentMap: Int?, currentKey: Int?
        var pendingDiscontinuity = false, ended = false
        func resource(_ attributes: [String: String], isKey: Bool) -> Int? {
            guard let uri = attributes["URI"], !uri.isEmpty,
                  let url = URL(string: uri, relativeTo: source)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            var range: CachedRange?
            if let value = attributes["BYTERANGE"] {
                guard let parsed = parseByteRange(value, implicitOffset: nil) else { return nil }
                range = parsed
            }
            if let index = extra.firstIndex(where: { $0.url == url && $0.byteRange == range && $0.isKey == isKey }) { return index }
            extra.append(Auxiliary(url: url, byteRange: range, isKey: isKey))
            return extra.count - 1
        }
        for line in lines {
            if line == "#EXT-X-ENDLIST" {
                guard !ended else { return nil }
                ended = true
            } else if line.hasPrefix("#EXT-X-GAP") || line.hasPrefix("#EXT-X-DEFINE:") || line.hasPrefix("#EXT-X-I-FRAMES-ONLY") {
                return nil
            } else if line == "#EXT-X-DISCONTINUITY" {
                guard !pendingDiscontinuity else { return nil }
                pendingDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-MAP:") {
                let isKey = line.hasPrefix("#EXT-X-KEY:"), tag = isKey ? "#EXT-X-KEY:" : "#EXT-X-MAP:"
                let value = String(line.dropFirst(tag.count))
                guard let attributes = parseAttributes(value) else { return nil }
                if isKey, attributes["METHOD"] == "NONE" {
                    guard attributes.count == 1 else { return nil }
                    currentKey = nil; template.append(PlaylistLine(text: line)); continue
                }
                if isKey {
                    guard ["AES-128", "SAMPLE-AES"].contains(attributes["METHOD"] ?? ""),
                          attributes["KEYFORMAT"] == nil || attributes["KEYFORMAT"] == "identity" else { return nil }
                } else {
                    guard Set(attributes.keys).isSubset(of: ["URI", "BYTERANGE"]) else { return nil }
                    if currentMap == nil, !segments.isEmpty, !pendingDiscontinuity { return nil }
                }
                guard value.hasPrefix("URI=\"") || value.contains(",URI=\""),
                      let index = resource(attributes, isKey: isKey) else { return nil }
                if isKey { currentKey = index } else { currentMap = index }
                template.append(PlaylistLine(text: tag, auxiliary: index, attributes: attributes))
                continue
            } else if line.hasPrefix("#EXTINF:") {
                guard duration == nil,
                      let value = line.dropFirst(8).split(separator: ",").first.flatMap({ Double($0) }),
                      value.isFinite, value > 0, value < FTPlayerSDKConfiguration.HLS.maximumSegmentDuration else { return nil }
                duration = value
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                guard rangeText == nil else { return nil }
                rangeText = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if !line.isEmpty, !line.hasPrefix("#") {
                guard let seconds = duration, let url = URL(string: line, relativeTo: source)?.absoluteURL,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                var range: CachedRange?
                if let text = rangeText {
                    let previous = segments.last
                    let offset = previous?.url == url ? previous?.byteRange.map { $0.end+1 } : nil
                    guard let parsed = parseByteRange(text, implicitOffset: offset) else { return nil }
                    range = parsed
                }
                let dependencies = [currentMap, currentKey].compactMap { $0 }
                template.append(PlaylistLine(text: line, media: segments.count))
                segments.append(Segment(url: url, duration: seconds, byteRange: range, dependencies: dependencies))
                duration = nil; rangeText = nil; pendingDiscontinuity = false
                guard segments.count <= FTPlayerSDKConfiguration.HLS.maximumSegments else { return nil }
                continue
            }
            template.append(PlaylistLine(text: line))
        }
        guard ended, !segments.isEmpty, duration == nil, rangeText == nil, !pendingDiscontinuity else { return nil }
        let used = Set(segments.flatMap { $0.dependencies ?? [] })
        let kept = extra.indices.filter { used.contains($0) }
        let remap = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element, $0.offset) })
        let resources = kept.map { extra[$0] }
        let media = segments.map { Segment(url: $0.url, duration: $0.duration, byteRange: $0.byteRange,
                                          dependencies: ($0.dependencies ?? []).compactMap { remap[$0] }) }
        let output = template.compactMap { item -> PlaylistLine? in
            var line = item
            if let index = line.auxiliary {
                guard let mapped = remap[index] else { return nil }
                line.auxiliary = mapped
            }
            return line
        }
        let firstMap = resources.first { !$0.isKey }
        return Manifest(source: source, segments: media, initialization: firstMap?.url,
                        initializationRange: firstMap?.byteRange, auxiliary: resources, playlist: output)
    }

    static func resourceAttributes(_ values: [String: String]) -> String {
        let raw: Set<String> = ["METHOD", "IV"]
        return values.keys.sorted().map { key in
            let value = values[key]!
            return "\(key)=\(raw.contains(key) ? value : "\"\(value)\"")"
        }.joined(separator: ",")
    }
}
