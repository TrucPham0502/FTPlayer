import Foundation

/// Exact stored bytes and an optional total. A nil fraction means the cache is
/// active but the source's complete byte size is not known yet.
public struct FTPlayerCacheProgress: Equatable {
    public let cachedBytes: Int64
    public let totalBytes: Int64?
    public let fraction: Double?

    init(cachedBytes: Int64, totalBytes: Int64?, fraction: Double? = nil) {
        let stored = max(0, cachedBytes), total = totalBytes.flatMap { $0 > 0 ? $0 : nil }
        self.cachedBytes = stored
        self.totalBytes = total
        if let fraction, fraction.isFinite { self.fraction = min(1, max(0, fraction)) }
        else if let total { self.fraction = min(1, Double(stored)/Double(total)) }
        else { self.fraction = nil }
    }
    static let empty = FTPlayerCacheProgress(cachedBytes: 0, totalBytes: nil)
}
