//
//  FTVideoFrame.swift
//
//
//  Edited by TP on 2024/7/26.
//

import Foundation
import CoreVideo

enum FTYUVChannel: Int {
    case luma = 0
    case chromaB = 1
    case chromaR = 2
    case count = 3
}

public class FTVideoFrame: FTFrame {
    public var width: Int = 0
    public var height: Int = 0
    public var pixelBuffer: CVPixelBuffer? { return nil }

    override var type: FTFrameType {
        return .video
    }
}
