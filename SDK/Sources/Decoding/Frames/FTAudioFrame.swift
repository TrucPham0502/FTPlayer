//
//  FTAudioFrame.swift
//
//  Edited by TP on 2024/7/26.
//

import Foundation

public class FTAudioFrame: FTFrame {
    public var samples: UnsafeMutablePointer<Float>?
    public var outputOffset: Int = 0
    private var bufferSize: Int = 0

    override var type: FTFrameType {
        return .audio
    }

    func setSamplesLength(_ samplesLength: Int) {
        if bufferSize < samplesLength {
            if bufferSize > 0, let samples = samples {
                samples.deallocate()
            }
            bufferSize = samplesLength
            samples = UnsafeMutablePointer<Float>.allocate(capacity: (bufferSize + MemoryLayout<Float>.size - 1) / MemoryLayout<Float>.size)
        }
        size = samplesLength
        outputOffset = 0
    }

    /// Trim an unsubmitted PCM frame at sample precision without copying on
    /// the render thread. Call after removing it from the duration-accounted queue.
    func trimStart(to time: TimeInterval, samplingRate: Double, channels: UInt32) -> Bool {
        guard time.isFinite, samplingRate.isFinite, samplingRate > 0, channels > 0 else { return false }
        guard time > position else { return outputOffset < size }
        let stride = Int(channels) * MemoryLayout<Float>.size
        let frames = size / stride
        let skipped = min(Double(frames), max(0, ceil((time - position) * samplingRate - FTPlayerSDKConfiguration.Precision.sampleRoundingEpsilon)))
        outputOffset = Int(skipped) * stride
        position += skipped / samplingRate
        duration = Double(frames - Int(skipped)) / samplingRate
        return outputOffset < size
    }

    deinit {
        if bufferSize > 0, let samples = samples {
            samples.deallocate()
        }
    }
}

