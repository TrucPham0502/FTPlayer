//
//  FTVideoHardwareDecoder.swift
//  FTPlayer
//
//  Created by Truc Pham on 11/3/26.
//

import Foundation
import VideoToolbox
@_implementationOnly import libavcodec
enum FTVideoToolBoxErrorCode: Error {
    case extradataSize
    case extradataData
    case createFormatDescription
    case createSession
}
protocol FTVideoHardwareDecoder: AnyObject {
    var requireHardware: Bool { get set }
    var usingHardware: Bool? { get }
    var setupFailure: String { get }
    /// Thử khởi tạo Session giải mã
    func trySetupVTSession() -> Bool
    /// Gửi packet vào bộ giải mã.
    /// Returns: 0 = success, >0 = consecutive -12909 error count, <0 = other failure
    func sendPacket(_ packet: AVPacket) -> Int
    /// Lấy kết quả hình ảnh sau khi giải mã
    func receiveFrame() -> VTFrame?
    /// Dọn dẹp các frame đang chờ
    func finishDelayedFrames()
    func flush()
}
