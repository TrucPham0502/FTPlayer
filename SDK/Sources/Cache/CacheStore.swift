import Foundation
import CryptoKit

struct CachedRange: Codable, Equatable {
    var start: Int64
    var end: Int64  // inclusive
}

private struct CacheIndex: Codable {
    var totalFileSize: Int64
    var cachedRanges: [CachedRange]
}

class CacheStore {
    private let cacheFile: URL
    private let indexFile: URL
    private let queue = DispatchQueue(label: "com.ftplayer.cachestore", attributes: .concurrent)
    private var _cachedRanges: [CachedRange] = []
    private var _totalFileSize: Int64 = 0
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?

    // Playback passes an owned session directory. The default supports isolated
    // low-level store tests; production never uses URL-global persistent storage.
    init(videoURL: URL, directory base: URL = CacheStore.cacheDirectory, resourceRange: CachedRange? = nil) throws {
        let videosDir = base.appendingPathComponent("videos")
        let indexDir  = base.appendingPathComponent("index")
        for dir in [videosDir, indexDir] {
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        let key = CacheStore.stableKey(for: videoURL) + (resourceRange.map { "_range_\($0.start)_\($0.end)" } ?? "")
        cacheFile = videosDir.appendingPathComponent("cache_\(key).bin")
        indexFile = indexDir.appendingPathComponent("index_\(key).json")

        if !FileManager.default.fileExists(atPath: cacheFile.path) {
            FileManager.default.createFile(atPath: cacheFile.path, contents: nil)
        }
        writeHandle = try FileHandle(forWritingTo: cacheFile)
        readHandle  = try FileHandle(forReadingFrom: cacheFile)
        loadIndex()
    }

    private static func stableKey(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    // MARK: - Write / Read

    func write(_ data: Data, at offset: Int64) {
        guard offset >= 0, !data.isEmpty, offset <= Int64.max - Int64(data.count) else { return }
        queue.async(flags: .barrier) {
            guard let handle = self.writeHandle else { return }
            handle.seek(toFileOffset: UInt64(offset))
            handle.write(data)
            let newRange = CachedRange(start: offset, end: offset + Int64(data.count) - 1)
            self._cachedRanges.append(newRange)
            self._cachedRanges = self.mergeRanges(self._cachedRanges)
        }
    }

    func read(at offset: Int64, length: Int) -> Data? {
        guard offset >= 0, length > 0, offset <= Int64.max - Int64(length) else { return nil }
        var result: Data?
        // barrier: serialise with concurrent writes so seek+read is atomic
        queue.sync(flags: .barrier) {
            guard let handle = self.readHandle else { return }
            let fileSize = handle.seekToEndOfFile()
            guard UInt64(offset) + UInt64(length) <= fileSize else { return }
            handle.seek(toFileOffset: UInt64(offset))
            let data = handle.readData(ofLength: length)
            result = data.count == length ? data : nil
        }
        return result
    }

    // MARK: - Range Tracking

    func cachedByteCount(from offset: Int64, maximum: Int) -> Int {
        guard offset >= 0, maximum > 0 else { return 0 }
        return queue.sync {
            guard let range = _cachedRanges.first(where: { $0.start <= offset && $0.end >= offset }) else { return 0 }
            return min(maximum, Int(range.end - offset + 1))
        }
    }

    func isCached(offset: Int64, length: Int) -> Bool {
        guard offset >= 0, length > 0, offset <= Int64.max - Int64(length) else { return false }
        var result = false
        queue.sync {
            let end = offset + Int64(length) - 1
            result = _cachedRanges.contains { $0.start <= offset && $0.end >= end }
        }
        return result
    }

    /// Returns the first byte NOT in cache starting from `offset`.
    /// If `offset` itself is cached it skips past contiguous cached ranges.
    func firstUncachedByte(from offset: Int64) -> Int64 {
        var result = offset
        queue.sync {
            // _cachedRanges is always kept merged+sorted by mergeRanges()
            for range in _cachedRanges {
                if range.start <= result && range.end >= result {
                    result = range.end + 1
                } else if range.start > result {
                    break
                }
            }
        }
        return result
    }

    /// The next missing span, stopping before an existing cached island and EOF.
    /// Callers must never assume all bytes after the first hole are also missing.
    func nextMissingRange(from offset: Int64, maximumLength: Int64) -> CachedRange? {
        guard offset >= 0, maximumLength > 0 else { return nil }
        return queue.sync {
            var start = offset
            var nextCachedStart: Int64?
            for range in _cachedRanges {
                if range.end < start { continue }
                if range.start <= start {
                    guard range.end < Int64.max else { return nil }
                    start = range.end + 1
                } else {
                    nextCachedStart = range.start
                    break
                }
            }
            if _totalFileSize > 0 && start >= _totalFileSize { return nil }
            let remaining = min(maximumLength - 1, Int64.max - start)
            var end = start + remaining
            if _totalFileSize > 0 { end = min(end, _totalFileSize - 1) }
            if let nextCachedStart { end = min(end, nextCachedStart - 1) }
            return end >= start ? CachedRange(start: start, end: end) : nil
        }
    }

    func cachedRanges() -> [CachedRange] {
        var result: [CachedRange] = []
        queue.sync { result = _cachedRanges }
        return result
    }

    private func mergeRanges(_ ranges: [CachedRange]) -> [CachedRange] {
        guard ranges.count > 1 else { return ranges }
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged = [sorted[0]]
        for range in sorted.dropFirst() {
            if range.start <= merged[merged.count - 1].end + 1 {
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, range.end)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    // MARK: - File Size

    func setTotalFileSize(_ size: Int64) {
        queue.async(flags: .barrier) { self._totalFileSize = size }
    }

    func totalFileSize() -> Int64 {
        var result: Int64 = 0
        queue.sync { result = _totalFileSize }
        return result
    }

    // MARK: - Index Persist

    func saveIndex() {
        queue.async(flags: .barrier) {
            let index = CacheIndex(totalFileSize: self._totalFileSize, cachedRanges: self._cachedRanges)
            if let data = try? JSONEncoder().encode(index) {
                try? data.write(to: self.indexFile, options: .atomic)
            }
        }
    }

    private func loadIndex() {
        guard FileManager.default.fileExists(atPath: indexFile.path),
              let data = try? Data(contentsOf: indexFile),
              let index = try? JSONDecoder().decode(CacheIndex.self, from: data) else { return }
        _totalFileSize = max(0, index.totalFileSize)
        // The OS/user may remove or truncate the backing file while its index survives.
        // Never advertise bytes that can no longer be read from disk.
        let diskSize = (try? cacheFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let limit = _totalFileSize > 0 ? min(Int64(diskSize), _totalFileSize) : Int64(diskSize)
        _cachedRanges = mergeRanges(index.cachedRanges.compactMap { range in
            guard range.start >= 0, range.end >= range.start, range.start < limit else { return nil }
            return CachedRange(start: range.start, end: min(range.end, limit - 1))
        })
        if _cachedRanges != index.cachedRanges { Console.log("[Cache] repaired stale index diskBytes=\(diskSize) ranges=\(_cachedRanges)") }
    }

    // MARK: - Clear / Flush

    func flush() {
        queue.sync(flags: .barrier) {}
    }

    func closeHandles() {
        queue.sync(flags: .barrier) {
            try? self.writeHandle?.close()
            try? self.readHandle?.close()
            self.writeHandle = nil
            self.readHandle  = nil
        }
    }

    func clear() {
        queue.async(flags: .barrier) {
            try? self.writeHandle?.close()
            try? self.readHandle?.close()
            self.writeHandle = nil
            self.readHandle  = nil
            try? FileManager.default.removeItem(at: self.cacheFile)
            try? FileManager.default.removeItem(at: self.indexFile)
            FileManager.default.createFile(atPath: self.cacheFile.path, contents: nil)
            self.writeHandle = try? FileHandle(forWritingTo: self.cacheFile)
            self.readHandle  = try? FileHandle(forReadingFrom: self.cacheFile)
            self._cachedRanges  = []
            self._totalFileSize = 0
        }
    }

    deinit {
        try? writeHandle?.close()
        try? readHandle?.close()
    }
}

// MARK: - Global cache management

extension CacheStore {
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Caches/FTPlayerCache")
    }

}
