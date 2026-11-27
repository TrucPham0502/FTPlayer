import Foundation

class StreamingLoader: NSObject {
    var onData: ((Data, Int64) -> Void)?
    var onFileSize: ((Int64) -> Void)?
    var onComplete: ((Error?) -> Void)?
    var onRangeSupport: ((Bool) -> Void)?
    var onResponse: ((URL?) -> Void)?
    var onActivity: (() -> Void)?

    /// Callback identity and byte offsets belong to a transfer, not to the loader.
    /// A cancelled task already executing a delegate callback must retain its old generation.
    private final class Transfer {
        let task: URLSessionDataTask
        let data: ((Data, Int64) -> Void)?
        let size: ((Int64) -> Void)?
        let complete: ((Error?) -> Void)?
        let rangeSupport: ((Bool) -> Void)?
        let response: ((URL?) -> Void)?
        let activity: (() -> Void)?
        var ignoresRange = false
        var unknownLength = false
        var offset: Int64
        var skip: Int64 = 0
        let end: Int64?
        var received: Int64 = 0
        let started = Date()
        init(task: URLSessionDataTask, offset: Int64, end: Int64?, data: ((Data, Int64) -> Void)?, size: ((Int64) -> Void)?, complete: ((Error?) -> Void)?, rangeSupport: ((Bool) -> Void)?, response: ((URL?) -> Void)?, activity: (() -> Void)?) {
            self.task = task; self.offset = offset; self.end = end
            self.data = data; self.size = size; self.complete = complete; self.rangeSupport = rangeSupport; self.response = response; self.activity = activity
        }
    }
    private let url: URL
    private var session: URLSession!
    private let taskLock = NSLock()
    private var transfer: Transfer?
    private var invalidated = false

    init(url: URL) {
        self.url = url
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Callbacks wake user-initiated proxy reads; don't inherit the caller's (e.g. utility prefetch) QoS.
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        callbacks.qualityOfService = .userInitiated
        session = URLSession(configuration: config, delegate: self, delegateQueue: callbacks)
    }

    func start(from offset: Int64, to end: Int64? = nil) {
        taskLock.lock()
        guard !invalidated else { taskLock.unlock(); return }
        transfer?.task.cancel()
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(end.map(String.init) ?? "")", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        transfer = Transfer(task: task, offset: offset, end: end, data: onData, size: onFileSize, complete: onComplete, rangeSupport: onRangeSupport, response: onResponse, activity: onActivity)
        taskLock.unlock()
        task.resume()
    }

    func cancel() {
        taskLock.withLock { transfer?.task.cancel(); transfer = nil }
    }
    func invalidate() {
        taskLock.withLock { invalidated = true; transfer?.task.cancel(); transfer = nil }
        session.invalidateAndCancel()
    }
    private func context(for task: URLSessionTask) -> Transfer? {
        taskLock.withLock { transfer?.task === task ? transfer : nil }
    }
    private func finish(_ context: Transfer, error: Error?) {
        let current = taskLock.withLock { () -> Bool in
            guard transfer === context else { return false }
            transfer = nil
            return true
        }
        if current {
            let finalError: Error?
            if error == nil && context.received == 0 {
                finalError = NSError(domain: NSURLErrorDomain, code: URLError.zeroByteResource.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Video response is empty", "operation": "download"])
            } else { finalError = error }
            if let finalError {
                Console.log(type: .ERROR, "HTTP failed bytes=\(context.received) offset=\(context.offset) error=\(finalError)")
            }
            // Chunked and close-delimited HTTP 200 responses only reveal their
            // full size at successful EOF. Count the skipped prefix too when a
            // server ignored a nonzero Range; delivered bytes alone are a suffix.
            if finalError == nil, context.ignoresRange, context.unknownLength {
                context.size?(context.received)
            }
            context.complete?(finalError)
        }
    }

    static func responseRange(_ response: HTTPURLResponse) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let fields = header.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }
        let parts = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < Int64.max else { return nil }
        let total: Int64?
        if parts[1] == "*" { total = nil }
        else {
            guard let size = Int64(parts[1]), size > end else { return nil }
            total = size
        }
        guard response.expectedContentLength < 0 || response.expectedContentLength == end - start + 1 else { return nil }
        return (start, end, total)
    }

    static func hasContentEncoding(_ response: HTTPURLResponse) -> Bool {
        (response.value(forHTTPHeaderField: "Content-Encoding") ?? "").split(separator: ",").contains {
            let coding = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !coding.isEmpty && coding != "identity"
        }
    }

    func getFileSize(completion: @escaping (Int64?) -> Void) {
        taskLock.lock(); defer { taskLock.unlock() }
        guard !invalidated else { return }
        var request = URLRequest(url: url); request.httpMethod = "HEAD"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        session.dataTask(with: request) { _, response, error in
            guard error == nil, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  !Self.hasContentEncoding(http) else { completion(nil); return }
            completion(http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init))
        }.resume()
    }
}

extension StreamingLoader: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let context = context(for: dataTask) else { completionHandler(.cancel); return }
        if let http = response as? HTTPURLResponse {
            if http.statusCode >= 400 {
                completionHandler(.cancel)
                finish(context, error: NSError(domain: "StreamingLoader", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
                return
            }
            context.response?(response.url)
            if http.statusCode == 206 {
                // Never label a different response span with the requested byte
                // offset. Validate before any body can reach the sparse cache.
                guard !Self.hasContentEncoding(http), let range = Self.responseRange(http), range.start == context.offset else {
                    completionHandler(.cancel)
                    finish(context, error: NSError(domain: NSURLErrorDomain, code: URLError.badServerResponse.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP 206 does not provide the requested unencoded resource bytes",
                                   "operation": "range-response", "offset": context.offset]))
                    return
                }
                if let total = range.total { context.size?(total) }
                context.rangeSupport?(true)
            } else if (200..<300).contains(http.statusCode) {
                context.ignoresRange = true
                context.unknownLength = http.expectedContentLength < 0
                context.skip = context.offset
                Console.log("[Cache] server ignored Range prefixToSkip=\(context.skip); network reuse requires HTTP 206")
                if http.expectedContentLength > 0 { context.size?(http.expectedContentLength) }
                context.rangeSupport?(false)
            }
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let context = context(for: dataTask) else { return }
        if !data.isEmpty { context.activity?() }
        context.received += Int64(data.count)
        let skipped = Int(min(context.skip, Int64(data.count)))
        context.skip -= Int64(skipped)
        let available = data.count - skipped
        let effectiveEnd = context.ignoresRange ? nil : context.end
        let count = effectiveEnd.map { Int(max(0, min(Int64(available), $0 - context.offset + 1))) } ?? available
        if count > 0 {
            let offset = context.offset
            context.offset += Int64(count)
            context.data?(data.subdata(in: skipped..<(skipped + count)), offset)
        }
        if let end = effectiveEnd, context.offset > end {
            // A bounded 206 transfer is complete; stale delegate callbacks retain this context.
            dataTask.cancel()
            finish(context, error: nil)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let context = context(for: task) else { return }
        if let error = error as? URLError, error.code == .cancelled { return }
        finish(context, error: error)
    }
}

/// Reads only response headers. Probe GET Range directly: signed media URLs can
/// reject or stall HEAD, adding a round trip or timeout before useful metadata.
/// Cancel at headers even when a server ignores Range, avoiding a full video download.
final class HTTPResourceSizeProbe: NSObject, URLSessionDataDelegate {
    private struct Request {
        let url: URL
        let completion: (Int64?) -> Void
    }
    private let lock = NSLock()
    private var pending: [Int: Request] = [:]
    private var closed = false
    private var network: URLSession!

    init(timeout: TimeInterval = FTPlayerSDKConfiguration.Network.metadataProbeTimeout) {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpMaximumConnectionsPerHost = FTPlayerSDKConfiguration.Network.maximumProbeConnectionsPerHost
        network = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func size(of url: URL, completion: @escaping (Int64?) -> Void) {
        start(Request(url: url, completion: completion))
    }
    private func start(_ value: Request) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        var request = URLRequest(url: value.url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let task = network.dataTask(with: request)
        pending[task.taskIdentifier] = value
        lock.unlock()
        task.resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let request = lock.withLock { pending.removeValue(forKey: dataTask.taskIdentifier) }
        // Always stop before receiving the body, including a full 200 response.
        completionHandler(.cancel)
        guard let request else { return }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        var total: Int64?
        if let http, !StreamingLoader.hasContentEncoding(http) {
            if status == 206, let range = StreamingLoader.responseRange(http), range.start == 0 {
                total = range.total
            } else if (200..<300).contains(status), status != 206, response.expectedContentLength > 0 {
                total = response.expectedContentLength
            }
        }
        if let total, total > 0 {
            Console.log("[HLSCache] size method=GET Range status=\(status) bytes=\(total)")
            request.completion(total)
        } else {
            Console.log("[HLSCache] GET size unavailable status=\(status)")
            request.completion(nil)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        request.completion(nil)
    }
    func close() {
        lock.lock(); guard !closed else { lock.unlock(); return }
        closed = true; pending.removeAll(); lock.unlock()
        network.invalidateAndCancel()
    }
}
