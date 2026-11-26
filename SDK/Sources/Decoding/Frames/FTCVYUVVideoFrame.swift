//
//  FTCVYUVVideoFrame.swift
//  
//
//  Edited by TP on 2024/7/26.
//

import Foundation
import CoreVideo

class FTCVYUVVideoFrame: FTVideoFrame {
    let _pixelBuffer : CVPixelBuffer?
    override var pixelBuffer: CVPixelBuffer? { return _pixelBuffer }
    init(pixelBuffer: CVPixelBuffer?) {
        self._pixelBuffer = pixelBuffer
        super.init()
        if let pixelBuffer = pixelBuffer {
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
        }
    }

    override var type: FTFrameType {
        return .cvyuvVideo
    }
}
