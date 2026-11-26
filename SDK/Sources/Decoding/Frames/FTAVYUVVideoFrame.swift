//
//  FTAVYUVVideoFrame.swift
//
//  Edited by TP on 2024/7/26.
//

import Foundation
import CoreVideo
@_implementationOnly import libavcodec

@_silgen_name("uvInterleave")
private func uvInterleave(
    _ srcU: UnsafePointer<UInt8>, _ strideU: Int32,
    _ srcV: UnsafePointer<UInt8>, _ strideV: Int32,
    _ dst: UnsafeMutablePointer<UInt8>, _ strideDst: Int32,
    _ width: Int32, _ height: Int32
)
class FTAVYUVVideoFrame: FTVideoFrame {
    var channelPixels = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: FTYUVChannel.count.rawValue)
    private var pixelFormat: AVPixelFormat?
    private var channelPixelsBufferSize = [Int](repeating: 0, count: FTYUVChannel.count.rawValue)
    private var channelLengths = [Int](repeating: 0, count: FTYUVChannel.count.rawValue)
    private var channelLinesize = [Int32](repeating: 0, count: FTYUVChannel.count.rawValue)
    private let lock = NSLock()

    override var type: FTFrameType {
        return .avyuvVideo
    }

    func setFrameData(_ frame: UnsafePointer<AVFrame>, width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        self.pixelFormat = AVPixelFormat(rawValue: frame.pointee.format)

        self.width = width
        self.height = height

        let linesizeY = frame.pointee.linesize.0
        let linesizeU = frame.pointee.linesize.1
        let linesizeV = frame.pointee.linesize.2

        channelLinesize[FTYUVChannel.luma.rawValue] = Int32(width)
        channelLinesize[FTYUVChannel.chromaB.rawValue] = Int32((width + 1) / 2)
        channelLinesize[FTYUVChannel.chromaR.rawValue] = Int32((width + 1) / 2)

        updateChannelBuffer(for: .luma, width: width, height: height, linesize: linesizeY)
        updateChannelBuffer(for: .chromaB, width: (width + 1) / 2, height: (height + 1) / 2, linesize: linesizeU)
        updateChannelBuffer(for: .chromaR, width: (width + 1) / 2, height: (height + 1) / 2, linesize: linesizeV)

        copyFrameData(frame.pointee.data.0!, to: &channelPixels[FTYUVChannel.luma.rawValue],   channel: .luma,    linesize: linesizeY, width: width,     height: height)
        copyFrameData(frame.pointee.data.1!, to: &channelPixels[FTYUVChannel.chromaB.rawValue], channel: .chromaB, linesize: linesizeU, width: (width + 1) / 2, height: (height + 1) / 2)
        copyFrameData(frame.pointee.data.2!, to: &channelPixels[FTYUVChannel.chromaR.rawValue], channel: .chromaR, linesize: linesizeV, width: (width + 1) / 2, height: (height + 1) / 2)
        _pixelBuffer = nil
    }

    var luma: UnsafeMutablePointer<UInt8>? {
        return channelPixels[FTYUVChannel.luma.rawValue]
    }

    var chromaB: UnsafeMutablePointer<UInt8>? {
        return channelPixels[FTYUVChannel.chromaB.rawValue]
    }

    var chromaR: UnsafeMutablePointer<UInt8>? {
        return channelPixels[FTYUVChannel.chromaR.rawValue]
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        width = 0
        height = 0
        for i in 0..<FTYUVChannel.count.rawValue {
            channelLengths[i] = 0
            channelLinesize[i] = 0
            if let pixels = channelPixels[i], channelPixelsBufferSize[i] > 0 {
                memset(pixels, 0, channelPixelsBufferSize[i])
            }
        }
        size = channelLengths.reduce(0, +)
        _pixelBuffer = nil
    }

//    override func stopPlaying() {
//        lock.lock()
//        super.stopPlaying()
//        lock.unlock()
//    }

    func image() -> FTPLFImage {
        lock.lock()
        let immutablePointers: [UnsafePointer<UInt8>?] = channelPixels.map { ptr in
            if let ptr = ptr {
                return UnsafePointer(ptr)
            } else {
                return nil
            }
        }
        let image = FTYUVConvertToImage(srcData: immutablePointers, srcLinesize: channelLinesize, width: width, height: height, pixelFormat: pixelFormat!)!
        lock.unlock()
        return image
    }
    
    // Cache: chỉ tạo CVPixelBuffer 1 lần/frame, tái dùng cho mọi lần render
    private var _pixelBuffer: CVPixelBuffer?

    override var pixelBuffer: CVPixelBuffer? {
            lock.lock(); defer { lock.unlock() }
            if let cached = _pixelBuffer { return cached }
            // 1. Kiểm tra điều kiện đầu vào
            let w = self.width
            let h = self.height
            guard w > 0, h > 0,
                  let lumaPtr = self.luma,
                  let chromaUPtr = self.chromaB,
                  let chromaVPtr = self.chromaR else {
                return nil
            }

            // 2. Chọn format NV12: full range cho yuvj420p, limited range cho yuv420p
            let cvPixelFormat: OSType = (pixelFormat == AV_PIX_FMT_YUVJ420P)
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

            // 3. Attributes để tạo planar buffer; cần khóa kCVPixelBufferIOSurfacePropertiesKey để có layout planar
            let attrs: CFDictionary = [
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary

            var maybeBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, w, h, cvPixelFormat, attrs, &maybeBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer = maybeBuffer else { return nil }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])

            guard
                let baseY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                let baseUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
            else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                return nil
            }
            let bytesPerRowY = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let bytesPerRowUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let srcLineY = Int(self.channelLinesize[FTYUVChannel.luma.rawValue])
            let srcLineU = Int(self.channelLinesize[FTYUVChannel.chromaB.rawValue])
            let srcLineV = Int(self.channelLinesize[FTYUVChannel.chromaR.rawValue])

            for row in 0..<h {
                memcpy(baseY.advanced(by: row * bytesPerRowY), lumaPtr.advanced(by: row * srcLineY), w)
            }

            let halfW = (w + 1) / 2
            let halfH = (h + 1) / 2
            uvInterleave(chromaUPtr, Int32(srcLineU),
                         chromaVPtr, Int32(srcLineV),
                         baseUV.assumingMemoryBound(to: UInt8.self), Int32(bytesPerRowUV),
                         Int32(halfW), Int32(halfH))

            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])


            _pixelBuffer = pixelBuffer
            return pixelBuffer
        }

    deinit {
        for i in 0..<FTYUVChannel.count.rawValue {
            if let pixels = channelPixels[i], channelPixelsBufferSize[i] > 0 {
                free(pixels)
            }
        }
    }

    private func updateChannelBuffer(for channel: FTYUVChannel, width: Int, height: Int, linesize: Int32) {
        let needSize = FTYUVChannelFilterNeedSize(linesize, width, height, 1)
        channelLengths[channel.rawValue] = needSize
        size = channelLengths.reduce(0, +)
        if channelPixelsBufferSize[channel.rawValue] < needSize {
            if channelPixelsBufferSize[channel.rawValue] > 0, let buffer = channelPixels[channel.rawValue] {
                free(buffer)
            }
            channelPixelsBufferSize[channel.rawValue] = needSize
            channelPixels[channel.rawValue] = malloc(needSize)?.assumingMemoryBound(to: UInt8.self)
        }
    }

    private func copyFrameData(_ source: UnsafePointer<UInt8>, to destination: inout UnsafeMutablePointer<UInt8>?, channel: FTYUVChannel, linesize: Int32, width: Int, height: Int) {
        FTYUVChannelFilter(source, linesize, width, height, destination, channelPixelsBufferSize[channel.rawValue], 1)
    }
    
}

func FTYUVChannelFilterNeedSize(_ linesize: Int32, _ width: Int, _ height: Int, _ a: Int) -> Int {
    return width * height
}

func FTYUVChannelFilter(_ source: UnsafePointer<UInt8>, _ linesize: Int32, _ width: Int, _ height: Int, _ destination: UnsafeMutablePointer<UInt8>?, _ bufferSize: Int, _ a: Int) {
    guard let destination = destination else { return }

    let linesize = Int(linesize)
    for y in 0..<height {
        let srcRow = source + y * linesize
        let dstRow = destination + y * width
        memcpy(dstRow, srcRow, width)
    }
}

