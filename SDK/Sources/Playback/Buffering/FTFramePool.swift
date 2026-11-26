//
//  FTFramePool.swift
//
//  Edited by TP on 2024/7/30.
//

import Foundation

class FTFramePool: NSObject, FTFrameDelegate {
    var frameClassName: AnyClass
    var lock = NSLock()
    var playingFrame: FTFrame?
    var unuseFrames = Set<FTFrame>()
    var usedFrames = Set<FTFrame>()

    init(capacity: Int, frameClassName: AnyClass) {
        self.frameClassName = frameClassName
        super.init()
        unuseFrames.reserveCapacity(capacity)
        usedFrames.reserveCapacity(capacity)
    }

    static func videoPool() -> FTFramePool {
        return FTFramePool(capacity: FTPlayerSDKConfiguration.Video.videoFramePoolCapacity, frameClassName: FTAVYUVVideoFrame.self)
    }

    static func audioPool() -> FTFramePool {
        return FTFramePool(capacity: FTPlayerSDKConfiguration.Video.audioFramePoolCapacity, frameClassName: FTAudioFrame.self)
    }

    static func pool(withCapacity number: Int, frameClassName: AnyClass) -> FTFramePool {
        return FTFramePool(capacity: number, frameClassName: frameClassName)
    }

    var count: Int {
        return unuseCount + usedCount + (playingFrame != nil ? 1 : 0)
    }

    var unuseCount: Int {
        return unuseFrames.count
    }

    var usedCount: Int {
        return usedFrames.count
    }

    func getUnuseFrame() -> FTFrame? {
        lock.lock()
        defer { lock.unlock() }

        if let frame = unuseFrames.popFirst() {
            usedFrames.insert(frame)
            return frame
        } else {
            let frame = (frameClassName as! NSObject.Type).init() as! FTFrame
            frame.delegate = self
            usedFrames.insert(frame)
            return frame
        }
    }

    func setFrameUnuse(_ frame: FTFrame?) {
        guard let frame = frame, frame.isKind(of: frameClassName) else { return }
        lock.lock()
        unuseFrames.insert(frame)
        usedFrames.remove(frame)
        lock.unlock()
    }

    func setFramesUnuse(_ frames: [FTFrame]) {
        guard !frames.isEmpty else { return }
        lock.lock()
        for frame in frames where frame.isKind(of: frameClassName) {
            usedFrames.remove(frame)
            unuseFrames.insert(frame)
        }
        lock.unlock()
    }

    func setFrameStartDrawing(_ frame: FTFrame?) {
        guard let frame = frame, frame.isKind(of: frameClassName) else { return }
        lock.lock()
        if let playingFrame = playingFrame {
            unuseFrames.insert(playingFrame)
        }
        playingFrame = frame
        usedFrames.remove(playingFrame!)
        lock.unlock()
    }

    func setFrameStopDrawing(_ frame: FTFrame?) {
        guard let frame = frame, frame.isKind(of: frameClassName) else { return }
        lock.lock()
        if playingFrame == frame {
            unuseFrames.insert(playingFrame!)
            playingFrame = nil
        }
        lock.unlock()
    }

    func flush() {
        lock.lock()
        usedFrames.removeAll()
        playingFrame = nil
        lock.unlock()
    }

    // MARK: - FTFrameDelegate

    func frameDidStartPlaying(_ frame: FTFrame) {
        setFrameStartDrawing(frame)
    }

    func frameDidStopPlaying(_ frame: FTFrame) {
        setFrameStopDrawing(frame)
    }

    func frameDidCancel(_ frame: FTFrame) {
        setFrameUnuse(frame)
    }

    deinit {
        Console.log("FTFramePool release")
    }
}
