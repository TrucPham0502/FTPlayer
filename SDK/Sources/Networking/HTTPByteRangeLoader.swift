import Foundation

/// Presents one HLS byte range as an independent zero-based cache resource.
/// HTTP validation/redirect/retry behavior remains in the normal streaming loader.
final class HTTPByteRangeLoader: HTTPStreamingLoading {
    var onData: ((Data, Int64) -> Void)?
    var onFileSize: ((Int64) -> Void)?
    var onComplete: ((Error?) -> Void)?
    var onRangeSupport: ((Bool) -> Void)?
    var onResponse: ((URL?) -> Void)?
    var onActivity: (() -> Void)?
    private let loader: any HTTPStreamingLoading
    private let range: CachedRange
    private let lock = NSLock()
    private var transfer: UUID?

    init(url: URL, range: CachedRange) {
        self.loader = StreamingLoader(url: url); self.range = range
    }
    private var length: Int64 { range.end - range.start + 1 }

    func start(from offset: Int64, to end: Int64?) {
        let data = onData, size = onFileSize, complete = onComplete, support = onRangeSupport
        guard offset >= 0, offset < length, (end ?? (length - 1)) >= offset else {
            complete?(URLError(.badServerResponse)); return
        }
        let token = UUID(), first = range.start + offset
        let last = range.start + min(end ?? (length - 1), length - 1)
        lock.lock(); transfer = token
        loader.onActivity = onActivity
        loader.onResponse = onResponse
        loader.onRangeSupport = { _ in support?(true) }
        loader.onFileSize = { [weak self] total in
            guard let self else { return }
            if total <= last {
                self.finish(token, error: Self.invalidRange(), completion: complete)
            } else { size?(self.length) }
        }
        loader.onData = { [weak self] bytes, absolute in
            guard let self else { return }
            let start = max(first, absolute), stop = min(last + 1, absolute + Int64(bytes.count))
            self.lock.lock()
            guard self.transfer == token else { self.lock.unlock(); return }
            let done = stop == last + 1
            if done { self.transfer = nil; self.loader.cancel() }
            self.lock.unlock()
            if stop > start {
                data?(bytes.subdata(in: Int(start - absolute)..<Int(stop - absolute)), start - self.range.start)
            }
            if done { complete?(nil) }
        }
        loader.onComplete = { [weak self] error in
            // Success was already completed at the requested last byte. A clean
            // early EOF must not turn a truncated fragment into a cached segment.
            self?.finish(token, error: error ?? Self.invalidRange(), completion: complete)
        }
        loader.start(from: first, to: last)
        lock.unlock()
    }
    private static func invalidRange() -> NSError {
        NSError(domain: NSURLErrorDomain, code: URLError.badServerResponse.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "HLS byte range is not fully present in the HTTP resource", "operation": "range-response"])
    }
    private func finish(_ token: UUID, error: Error, completion: ((Error?) -> Void)?) {
        lock.lock()
        guard transfer == token else { lock.unlock(); return }
        transfer = nil; loader.cancel(); lock.unlock()
        completion?(error)
    }
    func cancel() { lock.withLock { transfer = nil; loader.cancel() } }
    func invalidate() { lock.withLock { transfer = nil; loader.invalidate() } }
    func getFileSize(completion: @escaping (Int64?) -> Void) { completion(length) }
}
