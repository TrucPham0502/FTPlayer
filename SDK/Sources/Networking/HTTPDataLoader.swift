import Foundation

struct HTTPDataResponse {
    let data: Data
    /// Final URL after redirects; relative document resources resolve against it.
    let url: URL
}

/// Small-document transport used by playlist detection, independent of HLS parsing.
/// Called on a demux worker; cancellation never waits for the main queue.
protocol HTTPDataLoading {
    func load(_ url: URL, timeout: TimeInterval, interrupted: () -> Bool) throws -> HTTPDataResponse
}

struct HTTPDataLoader: HTTPDataLoading {
    func load(_ url: URL, timeout: TimeInterval, interrupted: () -> Bool) throws -> HTTPDataResponse {
        guard !interrupted() else { throw URLError(.cancelled) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let ready = DispatchSemaphore(value: 0), lock = NSLock()
        var payload: Data?, failure: Error?, status = 0, responseURL = url
        let task = session.dataTask(with: url) { data, response, error in
            lock.withLock {
                payload = data
                failure = error
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
                responseURL = response?.url ?? url
            }
            ready.signal()
        }
        task.resume()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ready.wait(timeout: .now() + FTPlayerSDKConfiguration.Network.interruptPollInterval) != .success {
            if interrupted() { throw URLError(.cancelled) }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw URLError(.timedOut) }
        }
        guard !interrupted() else { throw URLError(.cancelled) }
        let result = lock.withLock { (payload, failure, status, responseURL) }
        if let error = result.1 { throw error }
        guard (200..<300).contains(result.2) else {
            throw NSError(domain: "StreamingLoader", code: result.2,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(result.2)"])
        }
        // An empty successful body is a transport success. The document consumer
        // supplies domain-specific context when it is not a valid representation.
        return HTTPDataResponse(data: result.0 ?? Data(), url: result.3)
    }
}
