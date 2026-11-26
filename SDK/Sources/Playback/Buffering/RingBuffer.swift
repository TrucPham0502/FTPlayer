import Foundation

class RingBuffer {
    private let capacity: Int
    private let readTimeout: TimeInterval
    private var _readTimedOut = false
    var readTimedOut: Bool { cond.lock(); defer { cond.unlock() }; return _readTimedOut }
    private var storage = Data()
    private var baseOffset: Int64 = 0
    private var isCancelled = false
    private var isDone = false
    private let cond = NSCondition()

    var basePosition: Int64 { cond.lock(); defer { cond.unlock() }; return baseOffset }

    var writeOffset: Int64 { baseOffset + Int64(storage.count) }

    init(capacity: Int = FTPlayerSDKConfiguration.Cache.ringBufferCapacity, readTimeout: TimeInterval = FTPlayerSDKConfiguration.Network.readTimeout) {
        self.capacity = capacity
        self.readTimeout = readTimeout
    }

    // MARK: - Writer (network thread)

    func append(_ data: Data) {
        cond.lock()
        storage.append(data)
        if storage.count > capacity {
            let overflow = storage.count - capacity
            storage = Data(storage.dropFirst(overflow))
            baseOffset += Int64(overflow)
        }
        cond.signal()
        cond.unlock()
    }

    // MARK: - Reader (FFmpeg thread) — blocks until available, done, or cancelled

    func read(at fileOffset: Int64, length: Int) -> Data? {
        cond.lock()
        defer { cond.unlock() }
        _readTimedOut = false
        var waited = false
        let waitStart = Date()
        let deadline = waitStart.addingTimeInterval(readTimeout)
        while !isCancelled && !isDone {
            if fileOffset < baseOffset {
                Console.log("[RingBuffer] read offset=\(fileOffset) EVICTED (base=\(baseOffset))")
                return nil
            }
            if fileOffset < writeOffset { break } // AVIO accepts partial reads.
            if Date() >= deadline {
                _readTimedOut = true
                Console.log(type: .ERROR, "Cache read timeout offset=\(fileOffset) seconds=\(readTimeout)")
                return nil
            }
            if !waited {
                Console.log("[RingBuffer] BLOCKING — offset=\(fileOffset) len=\(length) writeOffset=\(writeOffset) base=\(baseOffset) missing=\((fileOffset + Int64(length) - writeOffset)/1024)KB")
                waited = true
            }
            cond.wait(until: min(deadline, Date(timeIntervalSinceNow: FTPlayerSDKConfiguration.Cache.ringBufferWakeInterval)))
        }
        if waited {
            let ms = Int(Date().timeIntervalSince(waitStart) * 1000)
            Console.log("[RingBuffer] UNBLOCKED — offset=\(fileOffset) waited=\(ms)ms isCancelled=\(isCancelled) isDone=\(isDone) writeOffset=\(writeOffset)")
        }
        if isCancelled || fileOffset < baseOffset { return nil }
        let available = Int(writeOffset - fileOffset)
        guard available > 0 else { return nil }
        let count = min(length, available)
        let start = Int(fileOffset - baseOffset)
        return storage.subdata(in: start ..< (start + count))
    }

    func isAvailable(at fileOffset: Int64, length: Int) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        guard !isCancelled, fileOffset >= baseOffset else { return false }
        return fileOffset + Int64(length) <= writeOffset
    }

    // MARK: - Control

    func markDone() {
        cond.lock()
        isDone = true
        cond.signal()
        cond.unlock()
    }

    func reset(to offset: Int64) {
        cond.lock()
        storage = Data()
        baseOffset = offset
        isCancelled = false
        isDone = false
        cond.signal()
        cond.unlock()
    }

    func cancel() {
        cond.lock()
        isCancelled = true
        cond.signal()
        cond.unlock()
    }
}
