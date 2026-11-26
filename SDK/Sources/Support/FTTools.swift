//
//  FTTools.swift
//  
//
//  Edited by TP on 2024/7/19.
//

import Foundation
@_implementationOnly import libavcodec
@_implementationOnly import libavdevice

enum FTDecoderErrorCode: Int {
    case formatCreate = 0
    case formatOpenInput
    case formatFindStreamInfo
    case streamNotFound
    case codecContextCreate
    case codecContextSetParam
    case codecFindDecoder
    case codecVideoSendPacket
    case codecAudioSendPacket
    case codecVideoReceiveFrame
    case codecAudioReceiveFrame
    case codecOpen2
    case audioSwrInit
}

// MARK: - Utility Functions

func FTLog(context: UnsafeMutableRawPointer?, level: Int32, format: UnsafePointer<CChar>, args: CVaListPointer) {
#if F_FFMPEG_LOG_ENABLED
    let message = NSString(format: NSString(utf8String: format)! as String, arguments: args) as String
#endif
}

func FTCheckError(_ result: Int32) -> NSError? {
    return FTCheckErrorCode(result, errorCode: -1)
}

func FTCheckErrorCode(_ result: Int32, errorCode: Int) -> NSError? {
    guard result < 0 else { return nil }

    var errorBuffer = [CChar](repeating: 0, count: FTPlayerSDKConfiguration.Diagnostics.ffmpegErrorBufferBytes)
    av_strerror(result, &errorBuffer, errorBuffer.count)

    let errorString = String(cString: errorBuffer)
    let errorDescription = "ffmpeg code: \(result), ffmpeg msg: \(errorString)"
    FTPlayerDiagnostic.shared.record("error", "ffmpeg.error", errorDescription, fields: ["stage": errorCode, "avCode": result])
    return NSError(domain: "FTPlayer.FFmpeg", code: errorCode,
        userInfo: [NSLocalizedDescriptionKey: errorDescription, "avCode": result, "stage": errorCode])
}

func FTStreamGetTimebase(_ stream: UnsafePointer<AVStream>, defaultTimebase: Double) -> Double {
    let timebase: Double
    if stream.pointee.time_base.den > 0 && stream.pointee.time_base.num > 0 {
        timebase = av_q2d(stream.pointee.time_base)
    } else {
        timebase = defaultTimebase
    }
    return timebase
}

func FTStreamGetFPS(_ stream: UnsafePointer<AVStream>, timebase: Double) -> Double {
    let fps: Double
    if stream.pointee.avg_frame_rate.den > 0 && stream.pointee.avg_frame_rate.num > 0 {
        fps = av_q2d(stream.pointee.avg_frame_rate)
    } else if stream.pointee.r_frame_rate.den > 0 && stream.pointee.r_frame_rate.num > 0 {
        fps = av_q2d(stream.pointee.r_frame_rate)
    } else {
        fps = 1.0 / timebase
    }
    return fps
}

func FTFoundationBrigeOfAVDictionary(_ avDictionary: OpaquePointer?) -> [String: String]? {
    guard let avDictionary = avDictionary else { return nil }

    var dictionary: [String: String] = [:]
    var entry: UnsafeMutablePointer<AVDictionaryEntry>? = nil

    while let nextEntry = av_dict_get(avDictionary, "", entry, AV_DICT_IGNORE_SUFFIX) {
        if let key = nextEntry.pointee.key, let value = nextEntry.pointee.value {
            let keyString = String(cString: key)
            let valueString = String(cString: value)
            dictionary[keyString] = valueString
        }
        entry = nextEntry
    }

    return dictionary.isEmpty ? nil : dictionary
}
