//
//  FTFrameQueue.swift
//
//  Edited by TP on 2024/7/30.
//

import Foundation

class FTFrameQueue: NSObject {
    static let maxVideoDuration: TimeInterval = FTPlayerSDKConfiguration.Video.frameQueueDuration
    private(set) var size: Int = 0
    var count: Int { frames.count }
    var duration: TimeInterval {
        condition.lock()
        defer { condition.unlock() }
        return _duration
    }
    /// Sampled video holds a picture until the next retained timestamp. Count
    /// that media coverage rather than only the original per-picture duration.
    func timelineDuration(from position: TimeInterval?) -> TimeInterval {
        condition.lock(); defer { condition.unlock() }
        guard let first = frames.first, let last = frames.last else { return 0 }
        let start = position ?? first.position
        let end = last.position + max(0, last.duration)
        guard start.isFinite, end.isFinite else { return _duration }
        return max(0, end - start)
    }
    private var _duration: TimeInterval = 0

    private var frames: [FTFrame] = []
    private var condition = NSCondition()
    private var destroyToken = false
    private var removals = 0

    static func frameQueue() -> FTFrameQueue {
        return FTFrameQueue()
    }

    static func sleepTimeIntervalForFull() -> TimeInterval {
        return maxVideoDuration / FTPlayerSDKConfiguration.Video.frameQueueSleepDivisor
    }

    static func sleepTimeIntervalForFullAndPaused() -> TimeInterval {
        return maxVideoDuration / FTPlayerSDKConfiguration.Video.pausedFrameQueueSleepDivisor
    }

    func putFrame(_ frame: FTFrame?) {
        guard let frame = frame else { return }
        condition.lock()
        if destroyToken {
            condition.unlock()
            return
        }
        frames.append(frame)
        _duration += frame.duration
        size += frame.size
        condition.signal()
        condition.unlock()
    }

    func putSortFrame(_ frame: FTFrame?) {
        guard let frame = frame else { return }
        condition.lock()
        if destroyToken {
            condition.unlock()
            return
        }
        var added = false
        if !frames.isEmpty {
            for i in stride(from: frames.count - 1, through: 0, by: -1) {
                // Keep codec display order for distinct pictures sharing PTS.
                // Inserting before equal timestamps reverses their motion.
                if frame.position >= frames[i].position {
                    frames.insert(frame, at: i + 1)
                    added = true
                    break
                }
            }
        }
        if !added {
            frames.insert(frame, at: 0)
        }
        _duration += frame.duration
        size += frame.size
        condition.signal()
        condition.unlock()
    }

    func getFrameSync() -> FTFrame? {
        condition.lock()
        while frames.isEmpty {
            if destroyToken {
                condition.unlock()
                return nil
            }
            condition.wait()
        }
        let frame = frames.removeFirst()
        _duration -= frame.duration
        if _duration < 0 || count <= 0 {
            _duration = 0
        }
        size -= frame.size
        if size <= 0 || count <= 0 {
            size = 0
        }
        removals += 1
        condition.broadcast()
        condition.unlock()
        return frame
    }

    func peekFrame() -> FTFrame? {
        condition.lock()
        defer { condition.unlock() }
        guard !destroyToken else { return nil }
        return frames.first
    }

    func getFrameAsync() -> FTFrame? {
        condition.lock()
        guard !destroyToken, !frames.isEmpty else {
            condition.unlock()
            return nil
        }
        let frame = frames.removeFirst()
        _duration -= frame.duration
        if _duration < 0 || count <= 0 {
            _duration = 0
        }
        size -= frame.size
        if size <= 0 || count <= 0 {
            size = 0
        }
        removals += 1
        condition.broadcast()
        condition.unlock()
        return frame
    }

    /// Blocks a producer until a frame is removed, the queue is flushed or
    /// destroyed, or `timeout` elapses.
    func waitForRemoval(timeout: TimeInterval) {
        condition.lock()
        defer { condition.unlock() }
        let observed = removals, deadline = Date(timeIntervalSinceNow: timeout)
        while removals == observed && !destroyToken && condition.wait(until: deadline) {}
    }

    func flush() {
        condition.lock()
        frames.forEach { $0.cancel() }
        frames.removeAll()
        _duration = 0
        size = 0
        removals += 1
        condition.broadcast()
        condition.unlock()
    }

    func destroy() {
        flush()
        condition.lock()
        destroyToken = true
        condition.broadcast()
        condition.unlock()
    }
}

