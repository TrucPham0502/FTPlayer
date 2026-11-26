//
//  FTVideoToolBox.swift
//
//
//  Edited by TP on 2024/7/25.
//

import Foundation
import VideoToolbox
@_implementationOnly import libavcodec
@_implementationOnly import libavdevice


class FTH264VideoToolBox : FTVideoHardwareDecoder {
    private var codecContext: UnsafeMutablePointer<AVCodecContext>
    private var vtSession: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    var requireHardware = false
    private(set) var usingHardware: Bool?
    private(set) var setupFailure = ""
    var decodeStatus: OSStatus = noErr
    private var pendingFrames: [VTFrame] = []
    private let pendingFramesLock = NSLock()

    private var consecutiveErrors = 0
    private var skippedNonReferenceFrames = 0
    private var waitingForRecoveryKeyframe = false
    private var packetsWaitingForKeyframe = 0
    private var recoveryAttemptsWithoutOutput = 0

    var vtSessionToken: Bool = false
    var needConvertNALSize3To4: Bool = false
    private var annexB = false
    private var activeSPS: [UInt8]?
    private var activePPS: [UInt8]?
    private var pendingAVCCSPS: [UInt8]?
    private var pendingAVCCPPS: [UInt8]?
    private var updatedAVCCParameterSets = false
    private var pendingPTS: Int64 = 0
    private var pendingDuration: Int64 = 0
    var timebase: TimeInterval = 0

    init(codecContext: UnsafeMutablePointer<AVCodecContext>, timebase: TimeInterval) {
        self.codecContext = codecContext
        self.timebase = timebase
    }

    func trySetupVTSession() -> Bool {
        if !self.vtSessionToken {
            do {
                try self.setupVTSession()
                self.vtSessionToken = true
            } catch {
                setupFailure = setupFailure.isEmpty ? String(describing: error) : setupFailure
                Console.log(type: .ERROR, "VT session setup failed: \(setupFailure)")
                return false
            }
        }
        return self.vtSessionToken
    }

    func setupVTSession() throws {
        setupFailure = ""
        guard let extradata = codecContext.pointee.extradata else {
            throw FTVideoToolBoxErrorCode.extradataSize
        }
        let extradataSize = codecContext.pointee.extradata_size
        
        if extradataSize < 7 {
            throw FTVideoToolBoxErrorCode.extradataSize
        }

        var config = Array(UnsafeBufferPointer(start: extradata, count: Int(extradataSize)))
        annexB = config.first != 1
        // Packet framing stays the container's framing even after an in-band
        // parameter change rebuilds a four-byte avcC for the VT session.
        needConvertNALSize3To4 = !annexB && config[4] & 3 == 2
        if annexB || updatedAVCCParameterSets {
            let units = annexB ? ffAnnexBNALUnits(config) : []
            guard let sps = activeSPS ?? units.first(where: { $0.first.map { $0 & 0x1f == 7 } == true }), sps.count >= 4,
                  let pps = activePPS ?? units.first(where: { $0.first.map { $0 & 0x1f == 8 } == true }), sps.count <= 65535, pps.count <= 65535 else {
                throw FTVideoToolBoxErrorCode.extradataData
            }
            activeSPS = sps; activePPS = pps
            let status = sps.withUnsafeBufferPointer { sps in pps.withUnsafeBufferPointer { pps in
                var pointers = [sps.baseAddress!, pps.baseAddress!]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &formatDescription)
            } }
            guard status == noErr else { throw FTVideoToolBoxErrorCode.createFormatDescription }
            config = [1, sps[1], sps[2], sps[3], 0xff, 0xe1, UInt8(sps.count >> 8), UInt8(sps.count & 255)] + sps
            config += [1, UInt8(pps.count >> 8), UInt8(pps.count & 255)] + pps
        }
        if config[0] == 1 {
            if config[4] == 0xFE {
                config[4] = 0xFF
                self.needConvertNALSize3To4 = true
            }
            // Nếu codecContext báo là JPEG hoặc Full Range, ta dùng '420f' (875704438)
            let isFullRange = codecContext.pointee.color_range == AVCOL_RANGE_JPEG
            if !annexB && !updatedAVCCParameterSets {
                self.formatDescription = config.withUnsafeBufferPointer { data in
                    createFormatDescription(codecType: kCMVideoCodecType_H264, width: codecContext.pointee.width, height: codecContext.pointee.height, extradata: data.baseAddress!, extradataSize: Int32(data.count), isFullRange: isFullRange)
                }
            }
            if self.formatDescription == nil {
                throw FTVideoToolBoxErrorCode.createFormatDescription
            }
            if !annexB && !updatedAVCCParameterSets {
                activeSPS = parameterSet(at: 0)
                activePPS = parameterSet(at: 1)
            }
            let pixelFormat = isFullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                           : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let dimensions = CMVideoFormatDescriptionGetDimensions(self.formatDescription!)
            let destinationAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: Int(pixelFormat), // Sử dụng số 875704438 ở đây,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferOpenGLESCompatibilityKey: true,
                kCVPixelBufferWidthKey: dimensions.width,
                kCVPixelBufferHeightKey: dimensions.height
            ]

            var outputCallbackRecord = VTDecompressionOutputCallbackRecord()
            outputCallbackRecord.decompressionOutputCallback = FTH264VideoToolBox.outputCallback
            outputCallbackRecord.decompressionOutputRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: self.formatDescription!,
                decoderSpecification: ffVideoDecoderSpecification(requireHardware: requireHardware),
                imageBufferAttributes: destinationAttributes as CFDictionary,
                outputCallback: &outputCallbackRecord,
                decompressionSessionOut: &self.vtSession
            )

            if status != noErr {
                setupFailure = "VTDecompressionSessionCreate status=\(status)"
                throw FTVideoToolBoxErrorCode.createSession
            }
            usingHardware = ffVTSessionUsesHardware(self.vtSession!)
            FTPlayerDiagnostic.shared.record("info", "decoder", "VT session", fields: ["codec": "h264", "requireHardware": requireHardware, "usingHardware": usingHardware.map { String($0) } ?? "unknown"])
            if requireHardware && usingHardware != true { cleanVTSession(); setupFailure = "VT did not confirm hardware acceleration"; throw FTVideoToolBoxErrorCode.createSession }
        } else {
            throw FTVideoToolBoxErrorCode.extradataData
        }
    }

    func cleanVTSession() {
        self.formatDescription = nil
        if let vtSession = self.vtSession {
            VTDecompressionSessionWaitForAsynchronousFrames(vtSession)
            VTDecompressionSessionInvalidate(vtSession)
            self.vtSession = nil
            // The decoder owns this object; invalidation drains callbacks before release.
        }
        self.needConvertNALSize3To4 = false
        self.vtSessionToken = false
        consecutiveErrors = 0
        pendingFramesLock.lock()
        pendingFrames.removeAll()
        pendingFramesLock.unlock()
    }

    func cleanDecodeInfo() {
        self.decodeStatus = noErr
        pendingFramesLock.lock()
        self.pendingFrames.removeAll()
        pendingFramesLock.unlock()
    }

    func sendPacket(_ packet: AVPacket) -> Int {
        if waitingForRecoveryKeyframe {
            guard packet.flags & AV_PKT_FLAG_KEY != 0 else {
                packetsWaitingForKeyframe += 1
                return packetsWaitingForKeyframe <= FTPlayerSDKConfiguration.Video.h264RecoveryPacketLimit ? 0 : -1
            }
            waitingForRecoveryKeyframe = false
            FTPlayerDiagnostic.shared.record("info", "decoder", "H264 hardware recovery at keyframe", fields: [
                "pts": packet.pts, "skippedPackets": packetsWaitingForKeyframe
            ])
        }
        guard self.trySetupVTSession() else { return -1 }
        self.cleanDecodeInfo()
        // VT can return an invalid CMTime when the packet has no PTS. Keep
        // its real DTS as the fallback instead of exposing AV_NOPTS_VALUE.
        self.pendingPTS = packet.pts != FT_AV_NOPTS_VALUE ? packet.pts : packet.dts
        self.pendingDuration = packet.duration


        var result = false
        var badDataErr = false
        var blockBuffer: CMBlockBuffer?
        var status: OSStatus = noErr

        guard let packetData = packet.data, packet.size >= 4 else { return -1 }
        if annexB {
            let units = ffAnnexBNALUnits(Array(UnsafeBufferPointer(start: packetData, count: Int(packet.size))))
            let sps = units.last(where: { $0.first.map { $0 & 0x1f == 7 } == true }) ?? activeSPS
            let pps = units.last(where: { $0.first.map { $0 & 0x1f == 8 } == true }) ?? activePPS
            if let sps, let pps, sps != activeSPS || pps != activePPS {
                // A discontinuity can change SPS/PPS and dimensions. Recreate
                // VT before submitting its first picture, preserving delayed
                // output from the preceding parameter set.
                finishDelayedFrames()
                pendingFramesLock.lock()
                let delayed = pendingFrames
                pendingFramesLock.unlock()
                cleanVTSession()
                activeSPS = sps; activePPS = pps
                guard trySetupVTSession() else { return -1 }
                pendingFramesLock.lock()
                pendingFrames.append(contentsOf: delayed)
                pendingFramesLock.unlock()
                FTPlayerDiagnostic.shared.record("info", "decoder", "H264 parameter sets changed", fields: ["pts": packet.pts])
            }
            var avcc = Data()
            for unit in units {
                var length = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
                avcc.append(contentsOf: unit)
            }
            guard !avcc.isEmpty else { return -1 }
            status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &blockBuffer)
            if status == noErr { status = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer!, offsetIntoDestination: 0, dataLength: avcc.count) } }
        } else if self.needConvertNALSize3To4 {
            var ioContext: UnsafeMutablePointer<AVIOContext>?
            if avio_open_dyn_buf(&ioContext) < 0 {
                status = -1900
            } else {
                var nalSize: UInt32 = 0
                let end = packet.data?.advanced(by: Int(packet.size))
                var nalStart = packet.data!
                while nalStart < end! {
                    guard end! - nalStart >= 3 else { status = -1900; break }
                    nalSize = (UInt32(nalStart[0]) << 16) | (UInt32(nalStart[1]) << 8) | UInt32(nalStart[2])
                    nalStart += 3
                    guard end! - nalStart >= Int(nalSize) else { status = -1900; break }
                    avio_wb32(ioContext, nalSize)
                    avio_write(ioContext, nalStart, Int32(nalSize))
                    nalStart += UnsafeMutablePointer<UInt8>.Stride(nalSize)
                }
                var demuxBuffer: UnsafeMutablePointer<UInt8>?
                let demuxSize = avio_close_dyn_buf(ioContext, &demuxBuffer)
                // demuxBuffer is malloc'd by avio_close_dyn_buf → kCFAllocatorMalloc frees it
                status = CMBlockBufferCreateWithMemoryBlock(
                    allocator: nil,
                    memoryBlock: demuxBuffer!,
                    blockLength: Int(demuxSize),
                    blockAllocator: kCFAllocatorMalloc,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: Int(demuxSize),
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )
            }
        } else {
            let data = packet.data!
            let packetSize = Int(packet.size)
            let outerNalSize = Int((UInt32(data[0]) << 24) | (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3]))

            if outerNalSize == packetSize - 4 {
                // Outer 4-byte wrapper covers entire content (some encoders embed Annex B start
                // codes within the inner payload). Scan and re-frame as proper per-NALU AVCC.
                // For single-NALU packets with no inner start codes (P/B-frames), output is
                // identical to the input.
                var ioContext: UnsafeMutablePointer<AVIOContext>?
                if avio_open_dyn_buf(&ioContext) < 0 {
                    status = -1900
                } else {
                    let inner = data.advanced(by: 4)
                    let innerEnd = inner.advanced(by: outerNalSize)
                    var nalBegin = inner
                    var pos = inner
                    while pos < innerEnd {
                        let remaining = innerEnd - pos
                        if remaining >= 4 && pos[0] == 0 && pos[1] == 0 && pos[2] == 0 && pos[3] == 1 {
                            let nalLen = nalBegin.distance(to: pos)
                            if nalLen > 0 { avio_wb32(ioContext, UInt32(nalLen)); avio_write(ioContext, nalBegin, Int32(nalLen)) }
                            nalBegin = pos.advanced(by: 4); pos = nalBegin
                        } else if remaining >= 3 && pos[0] == 0 && pos[1] == 0 && pos[2] == 1 {
                            let nalLen = nalBegin.distance(to: pos)
                            if nalLen > 0 { avio_wb32(ioContext, UInt32(nalLen)); avio_write(ioContext, nalBegin, Int32(nalLen)) }
                            nalBegin = pos.advanced(by: 3); pos = nalBegin
                        } else {
                            pos = pos.advanced(by: 1)
                        }
                    }
                    let lastNalLen = nalBegin.distance(to: innerEnd)
                    if lastNalLen > 0 { avio_wb32(ioContext, UInt32(lastNalLen)); avio_write(ioContext, nalBegin, Int32(lastNalLen)) }
                    var avccBuffer: UnsafeMutablePointer<UInt8>?
                    let avccSize = avio_close_dyn_buf(ioContext, &avccBuffer)
                    if let buf = avccBuffer, avccSize > 0 {
                        status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: buf, blockLength: Int(avccSize), blockAllocator: kCFAllocatorMalloc, customBlockSource: nil, offsetToData: 0, dataLength: Int(avccSize), flags: 0, blockBufferOut: &blockBuffer)
                    } else {
                        av_free(avccBuffer)
                        status = -1900
                    }
                }
            } else {
                // Standard multi-NALU AVCC: each NALU already has its own 4-byte prefix
                let copySize = packetSize
                guard let dataCopy = malloc(copySize) else { return -1 }
                memcpy(dataCopy, data, copySize)
                status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: dataCopy, blockLength: copySize, blockAllocator: kCFAllocatorMalloc, customBlockSource: nil, offsetToData: 0, dataLength: copySize, flags: 0, blockBufferOut: &blockBuffer)
            }
        }

        if status == noErr, let blockBuffer, let info = nalInfo(blockBuffer) {
            if !annexB {
                pendingAVCCSPS = info.sps ?? pendingAVCCSPS
                pendingAVCCPPS = info.pps ?? pendingAVCCPPS
            }
            // SPS/PPS, SEI and delimiters carry no picture. Submitting them as
            // one-image samples makes VT reject valid configuration packets and
            // can discard the reference chain during bad-picture recovery.
            if info.onlyMetadata { return 0 }
            if !annexB && !applyAVCCParameterSets() { return -1 }
        }

        if status == noErr, let blockBuffer,
           codecContext.pointee.skip_frame == AVDISCARD_NONREF,
           containsOnlyNonReferenceSlices(blockBuffer) {
            // Match FFmpeg's high-rate policy. These pictures are never references,
            // so omitting them preserves the reference chain while avoiding decode
            // and pixel-buffer work that can starve 60 fps hardware playback at 16x.
            skippedNonReferenceFrames += 1
            if skippedNonReferenceFrames == 1 || skippedNonReferenceFrames % FTPlayerSDKConfiguration.Video.h264SkippedFrameLogInterval == 0 {
                FTPlayerDiagnostic.shared.record("info", "decoder", "H264 high-rate non-reference discard", fields: [
                    "skippedPictures": skippedNonReferenceFrames, "pts": packet.pts, "hardware": usingHardware == true
                ])
            }
            return 0
        }
        if status == noErr {
            var sampleBuffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(seconds: Double(packet.duration) * timebase, preferredTimescale: 1_000_000),
                presentationTimeStamp: packet.pts == FT_AV_NOPTS_VALUE ? .invalid : CMTime(seconds: Double(packet.pts) * timebase, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
            status = CMSampleBufferCreate(
                allocator: nil,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: self.formatDescription!,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )

            if status == noErr {
                let vtStatus = VTDecompressionSessionDecodeFrame(
                    self.vtSession!,
                    sampleBuffer: sampleBuffer!,
                    flags: [],
                    frameRefcon: nil,
                    infoFlagsOut: nil
                )
                status = vtStatus
                if vtStatus == noErr {
                    // Force sync delivery — callback may fire async on hardware
                    VTDecompressionSessionWaitForAsynchronousFrames(self.vtSession!)
                    pendingFramesLock.lock()
                    result = !pendingFrames.isEmpty
                    pendingFramesLock.unlock()
                    if !result && decodeStatus == kVTVideoDecoderBadDataErr {
                        consecutiveErrors += 1
                        badDataErr = true
                        Console.log("[VTB-H264] BadDataErr (async) #\(consecutiveErrors) pts=\(packet.pts)")
                    }
                } else if vtStatus == kVTVideoDecoderBadDataErr {
                    consecutiveErrors += 1
                    badDataErr = true
                    Console.log("[VTB-H264] BadDataErr (sync) #\(consecutiveErrors) pts=\(packet.pts)")
                }
            }
        }
        if result {
            consecutiveErrors = 0
            recoveryAttemptsWithoutOutput = 0
            return 0
        }
        if badDataErr || status != noErr || decodeStatus != noErr {
            FTPlayerDiagnostic.shared.record("error", "decoder", "H264 packet decode failed", fields: [
                "status": status, "callbackStatus": decodeStatus, "pts": packet.pts, "dts": packet.dts,
                "bytes": packet.size, "key": (packet.flags & AV_PKT_FLAG_KEY) != 0,
                "annexB": annexB, "consecutiveErrors": consecutiveErrors
            ])
        }
        if badDataErr {
            // Automatic playback can reconstruct this GOP in FFmpeg immediately.
            // Waiting for another IDR here silently froze otherwise decodable
            // camera recordings for the remainder of the GOP.
            if !requireHardware { return max(1, consecutiveErrors) }
            // A bad-picture callback can poison VT's reference state even when the
            // rejected picture was non-reference. Recreate and resume only at a key
            // packet, always re-verifying hardware. Bound retries and packet skipping.
            recoveryAttemptsWithoutOutput += 1
            if recoveryAttemptsWithoutOutput <= FTPlayerSDKConfiguration.Video.h264RecoveryAttempts {
                FTPlayerDiagnostic.shared.record("warning", "decoder", "H264 hardware recovery waiting for keyframe", fields: [
                    "status": kVTVideoDecoderBadDataErr, "pts": packet.pts,
                    "attemptsWithoutOutput": recoveryAttemptsWithoutOutput
                ])
                waitingForRecoveryKeyframe = true
                packetsWaitingForKeyframe = 0
                cleanVTSession()
                return 0
            }
        }
        return badDataErr ? consecutiveErrors : (status == noErr && decodeStatus == noErr ? 0 : -1)
    }

    private func parameterSet(at index: Int) -> [UInt8]? {
        guard let formatDescription else { return nil }
        var pointer: UnsafePointer<UInt8>?, size = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription,
            parameterSetIndex: index, parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size, parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: size))
    }

    private func applyAVCCParameterSets() -> Bool {
        let sps = pendingAVCCSPS ?? activeSPS, pps = pendingAVCCPPS ?? activePPS
        pendingAVCCSPS = nil; pendingAVCCPPS = nil
        guard sps != activeSPS || pps != activePPS else { return true }
        guard let sps, sps.count >= 4, sps.count <= 65535,
              let pps, !pps.isEmpty, pps.count <= 65535 else { return false }
        // A camera may send its new SPS and PPS as separate samples. Apply the
        // pair at the next picture, and retain delayed output before recreating.
        finishDelayedFrames()
        pendingFramesLock.lock()
        let delayed = pendingFrames
        pendingFramesLock.unlock()
        cleanVTSession()
        activeSPS = sps; activePPS = pps; updatedAVCCParameterSets = true
        guard trySetupVTSession() else { return false }
        pendingFramesLock.lock()
        pendingFrames.append(contentsOf: delayed)
        pendingFramesLock.unlock()
        return true
    }

    private func nalInfo(_ buffer: CMBlockBuffer) -> (onlyMetadata: Bool, sps: [UInt8]?, pps: [UInt8]?)? {
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(buffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
            let pointer, length >= 5 else { return nil }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0, onlyMetadata = true
        var sps: [UInt8]?, pps: [UInt8]?
        while offset + 4 <= length {
            let count = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard count > 0, count <= length - offset, bytes[offset] & 0x80 == 0 else { return nil }
            let type = bytes[offset] & 0x1f
            if !(6...12).contains(type) { onlyMetadata = false }
            if type == 7 { sps = Array(UnsafeBufferPointer(start: bytes + offset, count: count)) }
            if type == 8 { pps = Array(UnsafeBufferPointer(start: bytes + offset, count: count)) }
            offset += count
        }
        guard offset == length else { return nil }
        return (onlyMetadata, sps, pps)
    }

    private func containsOnlyNonReferenceSlices(_ buffer: CMBlockBuffer) -> Bool {
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(buffer, atOffset: 0, lengthAtOffsetOut: nil,
                                         totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer, length >= 5 else { return false }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        var hasSlice = false
        while offset + 4 <= length {
            let count = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard count > 0, count <= length - offset else { return false }
            let header = bytes[offset]
            let type = header & 0x1f
            if (1...5).contains(type) {
                guard type != 5, header & 0x60 == 0 else { return false }
                hasSlice = true
            } else if type == 7 || type == 8 { return false }
            offset += count
        }
        return hasSlice && offset == length
    }

    func receiveFrame() -> VTFrame? {
        pendingFramesLock.lock()
        defer { pendingFramesLock.unlock() }
        return pendingFrames.isEmpty ? nil : pendingFrames.removeFirst()
    }

    func finishDelayedFrames() {
        if let session = vtSession {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    func flush() {
        self.cleanVTSession()
        self.cleanDecodeInfo()
        pendingAVCCSPS = nil; pendingAVCCPPS = nil
        waitingForRecoveryKeyframe = false
        packetsWaitingForKeyframe = 0
        recoveryAttemptsWithoutOutput = 0
    }

    deinit {
        self.flush()
        Console.log("FTVideoToolBox release")
    }

    private static let outputCallback: VTDecompressionOutputCallback = { (
        decompressionOutputRefCon: UnsafeMutableRawPointer?,
        sourceFrameRefCon: UnsafeMutableRawPointer?,
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        presentationDuration: CMTime
    ) in
            let videoToolBox = Unmanaged<FTH264VideoToolBox>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
            videoToolBox.decodeStatus = status
            if status == noErr, let imageBuffer = imageBuffer {
                let seconds = CMTimeGetSeconds(presentationTimeStamp)
                let pts = seconds.isFinite ? seconds : TimeInterval(videoToolBox.pendingPTS) * videoToolBox.timebase
                let dur = TimeInterval(videoToolBox.pendingDuration) * videoToolBox.timebase
                let frame = VTFrame(pixelBuffer: imageBuffer, pts: pts, duration: dur)
                videoToolBox.pendingFramesLock.lock()
                videoToolBox.pendingFrames.append(frame)
                videoToolBox.pendingFramesLock.unlock()
            }
    }

    private func createFormatDescription(codecType: CMVideoCodecType, width: Int32, height: Int32, extradata: UnsafePointer<UInt8>, extradataSize: Int32, isFullRange: Bool) -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?
        var status: OSStatus

        let par: CFMutableDictionary = [
            "HorizontalSpacing": 0,
            "VerticalSpacing": 0
        ] as! CFMutableDictionary as CFMutableDictionary

        let atoms: CFMutableDictionary = [
            "avcC": CFDataCreate(nil, extradata, CFIndex(extradataSize))
        ] as! CFMutableDictionary as CFMutableDictionary

        let extensions: CFMutableDictionary = [
            "CVImageBufferChromaLocationBottomField": "left" as CFString,
            "CVImageBufferChromaLocationTopField": "left" as CFString,
            "FullRangeVideo": isFullRange,
            "CVPixelAspectRatio": par,
            "SampleDescriptionExtensionAtoms": atoms
        ] as! CFMutableDictionary

        status = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: codecType,
            width: width,
            height: height,
            extensions: extensions,
            formatDescriptionOut: &formatDescription
        )

        return status == noErr ? formatDescription : nil
    }
}
