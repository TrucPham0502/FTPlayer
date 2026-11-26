import Foundation

/// A single-resource range transport. Each transfer captures its callbacks.
protocol HTTPStreamingLoading: AnyObject {
    var onData: ((Data, Int64) -> Void)? { get set }
    var onFileSize: ((Int64) -> Void)? { get set }
    var onComplete: ((Error?) -> Void)? { get set }
    var onRangeSupport: ((Bool) -> Void)? { get set }
    var onResponse: ((URL?) -> Void)? { get set }
    var onActivity: (() -> Void)? { get set }
    func start(from offset: Int64, to end: Int64?)
    func cancel()
    func invalidate()
    func getFileSize(completion: @escaping (Int64?) -> Void)
}

extension StreamingLoader: HTTPStreamingLoading {}
