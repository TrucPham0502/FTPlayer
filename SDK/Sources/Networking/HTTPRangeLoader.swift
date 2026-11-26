import Foundation

class HTTPRangeLoader {
    private let url: URL
    private let session: URLSession
    private let taskLock = NSLock()
    private var _task: URLSessionDataTask?
    private var task: URLSessionDataTask? {
        get { taskLock.withLock { _task } }
        set { taskLock.withLock { _task = newValue } }
    }

    init(url: URL) {
        self.url = url
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - File Size (HEAD)

    func getFileSize(completion: @escaping (Int64?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let t = session.dataTask(with: request) { _, response, error in
            if error != nil { completion(nil); return }
            guard let http = response as? HTTPURLResponse else { completion(nil); return }
            let size = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
            completion(size)
        }
        t.resume()
    }

    // MARK: - Range Fetch (GET)

    func load(from offset: Int64, length: Int, completion: @escaping (Data?, Error?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let t = session.dataTask(with: request) { [weak self] data, _, error in
            if let error = error as? URLError, error.code == .cancelled {
                completion(nil, nil)
                return
            }
            self?.task = nil
            completion(data, error)
        }
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
