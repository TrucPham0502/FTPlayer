//
//  FTFrame.swift

//
//  Edited by TP on 2024/7/26.
//

import Foundation

enum FTFrameType: UInt {
    case video
    case avyuvVideo
    case cvyuvVideo
    case audio
    case subtitle
    case artwork
}

public class FTFrame: NSObject {
    weak var delegate: FTFrameDelegate?
    private(set) var playing: Bool = false

    private(set) var type: FTFrameType = .video
    public var position: TimeInterval = 0
    public var duration: TimeInterval = 0
    public var size: Int = 0

    func startPlaying() {
        playing = true
        delegate?.frameDidStartPlaying(self)
    }

    func stopPlaying() {
        playing = false
        delegate?.frameDidStopPlaying(self)
    }

    func cancel() {
        playing = false
        delegate?.frameDidCancel(self)
    }
}

protocol FTFrameDelegate: AnyObject {
    func frameDidStartPlaying(_ frame: FTFrame)
    func frameDidStopPlaying(_ frame: FTFrame)
    func frameDidCancel(_ frame: FTFrame)
}

