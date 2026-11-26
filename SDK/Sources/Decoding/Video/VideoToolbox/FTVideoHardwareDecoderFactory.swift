//
//  FTVideoHardwareDecoderFactory.swift
//  FTPlayer
//
//  Created by Truc Pham on 11/3/26.
//
@_implementationOnly import libavcodec
class FTVideoHardwareDecoderFactory {
    static func createDecoder(codecContext: UnsafeMutablePointer<AVCodecContext>, timebase: TimeInterval) -> FTVideoHardwareDecoder? {
        let codecID = codecContext.pointee.codec_id

        switch codecID {
        case AV_CODEC_ID_H264:
            return FTH264VideoToolBox(codecContext: codecContext, timebase: timebase)
        case AV_CODEC_ID_HEVC:
            return FTHEVCVideoToolBox(codecContext: codecContext, timebase: timebase)
        default:
            return nil
        }
    }
}
