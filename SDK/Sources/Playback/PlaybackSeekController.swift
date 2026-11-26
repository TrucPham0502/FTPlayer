import Foundation

/// Owns the pending seek and its completion. Callbacks always run outside the lock.
final class PlaybackSeekController {
    struct Request {
        let revision: Int
        let time: TimeInterval
        let completion: ((Bool) -> Void)?
    }

    private let lock = NSLock()
    private var pending: Request?
    private var serial = 0
    var revision: Int { lock.withLock { serial } }

    var isPending: Bool { lock.withLock { pending != nil } }

    @discardableResult
    func enqueue(time: TimeInterval, minimum: TimeInterval, duration: TimeInterval,
                 completion: ((Bool) -> Void)?) -> TimeInterval {
        let maximum = max(minimum, duration - FTPlayerSDKConfiguration.Precision.seekEndMargin)
        let target = min(maximum, max(minimum, time))
        let superseded = lock.withLock { () -> Request? in
            let previous = pending
            serial += 1
            pending = Request(revision: serial, time: target, completion: completion)
            return previous
        }
        superseded?.completion?(false)
        return target
    }

    func take() -> Request? {
        lock.withLock {
            let request = pending
            pending = nil
            return request
        }
    }

    func cancel() {
        take()?.completion?(false)
    }
}
