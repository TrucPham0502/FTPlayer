//
//  VTFrame.swift
//  FTPlayer
//
//  Created by Như Trục on 12/3/26.
//

import VideoToolbox
struct VTFrame {
    let pixelBuffer: CVPixelBuffer?
    let pts: TimeInterval
    let duration: TimeInterval
}
