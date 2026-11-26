//
//  FTHEVCVideoToolBox.swift
//  FTPlayer
//
//  Created by Truc Pham on 11/3/26.
//

import Foundation
import VideoToolbox
@_implementationOnly import libavcodec


class FTHEVCVideoToolBox : FTVideoHardwareDecoder {
    private var codecContext: UnsafeMutablePointer<AVCodecContext>
    private var vtSession: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?

    var requireHardware = false
    private(set) var usingHardware: Bool?
    private(set) var setupFailure = ""
    var decodeStatus: OSStatus = noErr
    private var pendingFrames: [(frame: VTFrame, poc: Int, sequence: Int)] = []
    private var pictureParser: UnsafeMutablePointer<AVCodecParserContext>?
    private var parserCodecContext: UnsafeMutablePointer<AVCodecContext>?
    private var pictureSequence = 0
    private var drainingPictures = false
    private var randomAccessStart = true
    private var discardLeadingRASL = false
    private var skippedLeadingPictures = 0
    private var reorderDepth: Int { min(16, max(0, Int(codecContext.pointee.has_b_frames) + (codecContext.pointee.has_b_frames > 0 ? 1 : 0))) }
    private let pendingFramesLock = NSLock()
    var vtSessionToken: Bool = false

    private final class SampleTiming {
        let pts: Double
        let duration: Double
        let poc: Int
        let sequence: Int
        init(pts: Double, duration: Double, poc: Int, sequence: Int) {
            self.pts = pts; self.duration = duration; self.poc = poc; self.sequence = sequence
        }
    }
    private var consecutiveErrors = 0
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

    private func setupVTSession() throws {
        setupFailure = ""
        guard let extradata = codecContext.pointee.extradata,
              codecContext.pointee.extradata_size >= 23 else {
            throw FTVideoToolBoxErrorCode.extradataSize
        }

        let isFullRange = codecContext.pointee.color_range == AVCOL_RANGE_JPEG
        self.formatDescription = createHEVCFormatDescription(
            width: codecContext.pointee.width,
            height: codecContext.pointee.height,
            extradata: extradata,
            extradataSize: codecContext.pointee.extradata_size,
            isFullRange: isFullRange
        )

        guard let formatDescription = self.formatDescription else {
            throw FTVideoToolBoxErrorCode.createFormatDescription
        }

        let pixelFormat = isFullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                      : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(pixelFormat),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferOpenGLESCompatibilityKey: true,
            kCVPixelBufferWidthKey: codecContext.pointee.width,
            kCVPixelBufferHeightKey: codecContext.pointee.height
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (refcon, sourceRefcon, status, flags, buffer, pts, duration) in
                let tb = Unmanaged<FTHEVCVideoToolBox>.fromOpaque(refcon!).takeUnretainedValue()
                let timing = sourceRefcon.map { Unmanaged<SampleTiming>.fromOpaque($0).takeRetainedValue() }
                tb.pendingFramesLock.lock()
                tb.decodeStatus = status
                tb.pendingFramesLock.unlock()
                if status == noErr, buffer != nil {
                    let seconds = CMTimeGetSeconds(pts)
                    let pts = seconds.isFinite ? seconds : timing?.pts ?? 0
                    let sampleDuration = CMTimeGetSeconds(duration)
                    let dur = sampleDuration.isFinite ? sampleDuration : timing?.duration ?? 0
                    let frame = VTFrame(pixelBuffer: buffer, pts: pts, duration: dur)
                    tb.pendingFramesLock.lock()
                    tb.pendingFrames.append((frame, timing?.poc ?? 0, timing?.sequence ?? 0))
                    tb.pendingFramesLock.unlock()
                }
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: ffVideoDecoderSpecification(requireHardware: requireHardware),
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &vtSession
        )

        if status != noErr { setupFailure = "VTDecompressionSessionCreate status=\(status)"; throw FTVideoToolBoxErrorCode.createSession }
        usingHardware = ffVTSessionUsesHardware(vtSession!)
        FTPlayerDiagnostic.shared.record("info", "decoder", "VT session", fields: ["codec": "hevc", "requireHardware": requireHardware, "usingHardware": usingHardware.map { String($0) } ?? "unknown"])
        if requireHardware && usingHardware != true { cleanVTSession(); setupFailure = "VT did not confirm hardware acceleration"; throw FTVideoToolBoxErrorCode.createSession }
    }

    func cleanVTSession() {
        self.formatDescription = nil
        if let session = self.vtSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.vtSession = nil
        }
        self.vtSessionToken = false
        if let parser = pictureParser { av_parser_close(parser) }
        pictureParser = nil
        avcodec_free_context(&parserCodecContext)
        pictureSequence = 0
        randomAccessStart = true; discardLeadingRASL = false; skippedLeadingPictures = 0
    }

    func cleanDecodeInfo() {
        self.decodeStatus = noErr
        pendingFramesLock.lock()
        self.pendingFrames.removeAll()
        drainingPictures = false
        pendingFramesLock.unlock()
    }

    // Parse HEVC picture order without decoding pixels on the CPU. Packet PTS
    // cannot order B pictures when a container omits its composition offsets.
    // FFmpeg's HEVC parser exposes the bitstream Picture Order Count directly.
    private func parsePictureOrder(_ packet: AVPacket) -> (Int, Int)? {
        if pictureParser == nil {
            guard let parser = av_parser_init(codecContext.pointee.codec_id) else { return nil }
            guard let context = avcodec_alloc_context3(nil) else { av_parser_close(parser); return nil }
            var parameters = avcodec_parameters_alloc()
            defer { avcodec_parameters_free(&parameters) }
            guard let parameters, avcodec_parameters_from_context(parameters, codecContext) >= 0,
                  avcodec_parameters_to_context(context, parameters) >= 0 else {
                av_parser_close(parser)
                var failed: UnsafeMutablePointer<AVCodecContext>? = context; avcodec_free_context(&failed)
                return nil
            }
            parser.pointee.flags |= PARSER_FLAG_COMPLETE_FRAMES
            pictureParser = parser; parserCodecContext = context
        }
        guard let parser = pictureParser, let context = parserCodecContext else { return nil }
        var output: UnsafeMutablePointer<UInt8>?
        var outputSize: Int32 = 0
        let consumed = av_parser_parse2(parser, context, &output, &outputSize, packet.data,
                                        packet.size, packet.pts, packet.dts, packet.pos)
        guard consumed >= 0, outputSize > 0 else { return nil }
        if parser.pointee.key_frame == 1 { pictureSequence += 1 }
        return (Int(parser.pointee.output_picture_number), pictureSequence)
    }

    private func firstVCLType(_ data: Data, lengthBytes: Int) -> Int? {
        var offset = 0
        while offset + lengthBytes <= data.count {
            var count = 0
            for i in 0..<lengthBytes { count = (count << 8) | Int(data[offset + i]) }
            offset += lengthBytes
            guard count >= 2, count <= data.count - offset else { return nil }
            let type = Int((data[offset] >> 1) & 0x3f)
            if type < 32 { return type }
            offset += count
        }
        return nil
    }

    func sendPacket(_ packet: AVPacket) -> Int {
        guard let vtSession = vtSession, let packetData = packet.data else { return -1 }
        pendingFramesLock.lock(); self.decodeStatus = noErr; pendingFramesLock.unlock()
        guard let (poc, sequence) = parsePictureOrder(packet) else {
            Console.log(type: .ERROR, "HEVC picture-order parser failed")
            return -1
        }

        let packetSize = Int(packet.size)
        let lengthPrefixed = codecContext.pointee.extradata_size > 0 && codecContext.pointee.extradata?[0] == 1
        // A legal 4-byte NAL length of 256...511 begins 00 00 01 xx. It is not
        // an Annex-B start code when hvcC declares length-prefixed packets.
        let isAnnexB = !lengthPrefixed && ((packetSize >= 3 && packetData[0] == 0 && packetData[1] == 0 && packetData[2] == 1) ||
                       (packetSize >= 4 && packetData[0] == 0 && packetData[1] == 0 && packetData[2] == 0 && packetData[3] == 1))

        let hvccData: Data = isAnnexB ? annexBToHVCC(packetData, size: packetSize)
                                      : Data(bytes: packetData, count: packetSize)

        let lengthBytes = isAnnexB ? 4 : Int((codecContext.pointee.extradata?[21] ?? 3) & 3) + 1
        if let type = firstVCLType(hvccData, lengthBytes: lengthBytes) {
            if randomAccessStart, (16...23).contains(type) {
                // CRA/BLA leading RASL pictures may reference the previous GOP.
                // A fresh VT session after seek has no such references. Like a
                // software HEVC decoder at random access, discard those leading
                // pictures rather than failing strict hardware on -17694.
                discardLeadingRASL = (16...18).contains(type) || type == 21
                randomAccessStart = false
            }
            if discardLeadingRASL, type == 8 || type == 9 {
                skippedLeadingPictures += 1
                guard skippedLeadingPictures <= FTPlayerSDKConfiguration.Video.hevcLeadingPictureLimit else { return -1 }
                Console.log("Skip leading HEVC RASL after random access poc=\(poc) pts=\(Double(packet.pts) * timebase)")
                return 0
            }
            if type < 6 { discardLeadingRASL = false }
        }

        return hvccData.withUnsafeBytes { rawPtr -> Int in
            guard let ptr = rawPtr.baseAddress else { return -1 }

            var blockBuffer: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: nil,
                blockLength: hvccData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: hvccData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard status == kCMBlockBufferNoErr, let blockBuffer = blockBuffer else { return -1 }

            guard CMBlockBufferReplaceDataBytes(with: ptr, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: hvccData.count) == noErr else { return -1 }
            var timing = CMSampleTimingInfo(
                duration: CMTime(seconds: Double(packet.duration) * timebase, preferredTimescale: 1_000_000),
                presentationTimeStamp: packet.pts == FT_AV_NOPTS_VALUE ? .invalid : CMTime(seconds: Double(packet.pts) * timebase, preferredTimescale: 1_000_000),
                decodeTimeStamp: .invalid)
            var sampleBuffer: CMSampleBuffer?
            status = CMSampleBufferCreate(
                allocator: nil,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription!,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: [hvccData.count],
                sampleBufferOut: &sampleBuffer
            )
            guard status == noErr, let sampleBuffer = sampleBuffer else { return -1 }

            // Keep native decompression synchronous and reorder the resulting
            // hardware pictures by bitstream POC, independently of malformed PTS.
            var flags: VTDecodeFrameFlags = []
            if packet.flags & AV_PKT_FLAG_DISCARD != 0 { flags.insert(._DoNotOutputFrame) }
            let timestamp = packet.pts != FT_AV_NOPTS_VALUE ? packet.pts : packet.dts
            let callbackTiming = Unmanaged.passRetained(SampleTiming(pts: Double(timestamp) * timebase, duration: Double(packet.duration) * timebase, poc: poc, sequence: sequence))
            status = VTDecompressionSessionDecodeFrame(
                vtSession,
                sampleBuffer: sampleBuffer,
                flags: flags,
                frameRefcon: callbackTiming.toOpaque(),
                infoFlagsOut: nil
            )
            if status != noErr { callbackTiming.release() } // On error VT does not call back.
            let outputStatus = pendingFramesLock.withLock { decodeStatus }
            if status == noErr && outputStatus == noErr { consecutiveErrors = 0; return 0 }
            consecutiveErrors += 1
            Console.log(type: .ERROR, "HEVC VT decode status=\(status) output=\(decodeStatus) consecutive=\(consecutiveErrors)")
            return consecutiveErrors >= FTPlayerSDKConfiguration.Video.hevcErrorFallbackThreshold ? 1 : -1
        }
    }

    private func annexBToHVCC(_ src: UnsafePointer<UInt8>, size: Int) -> Data {
        var output = Data()
        output.reserveCapacity(size)
        var i = 0
        while i < size {
            var startCodeLen = 0
            if i + 3 < size && src[i] == 0 && src[i+1] == 0 && src[i+2] == 0 && src[i+3] == 1 {
                startCodeLen = 4
            } else if i + 2 < size && src[i] == 0 && src[i+1] == 0 && src[i+2] == 1 {
                startCodeLen = 3
            } else {
                i += 1
                continue
            }
            let naluStart = i + startCodeLen
            var naluEnd = naluStart
            while naluEnd < size {
                if naluEnd + 3 < size && src[naluEnd] == 0 && src[naluEnd+1] == 0 && src[naluEnd+2] == 0 && src[naluEnd+3] == 1 { break }
                if naluEnd + 2 < size && src[naluEnd] == 0 && src[naluEnd+1] == 0 && src[naluEnd+2] == 1 { break }
                naluEnd += 1
            }
            var lengthPrefix = UInt32(naluEnd - naluStart).bigEndian
            withUnsafeBytes(of: &lengthPrefix) { output.append(contentsOf: $0) }
            output.append(src + naluStart, count: naluEnd - naluStart)
            i = naluEnd
        }
        return output
    }

    private func createHEVCFormatDescription(width: Int32, height: Int32, extradata: UnsafePointer<UInt8>, extradataSize: Int32, isFullRange: Bool) -> CMFormatDescription? {
        var desc: CMFormatDescription?

        let atoms = ["hvcC": CFDataCreate(kCFAllocatorDefault, extradata, CFIndex(extradataSize))]

        let extensions = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms,
            kCVImageBufferChromaLocationBottomFieldKey: kCVImageBufferChromaLocation_Left,
            kCVImageBufferChromaLocationTopFieldKey: kCVImageBufferChromaLocation_Left,
            "FullRangeVideo": isFullRange
        ] as CFDictionary

        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: width,
            height: height,
            extensions: extensions,
            formatDescriptionOut: &desc
        )
        return status == noErr ? desc : nil
    }

    func receiveFrame() -> VTFrame? {
        pendingFramesLock.lock()
        defer { pendingFramesLock.unlock() }
        guard !pendingFrames.isEmpty, drainingPictures || pendingFrames.count > reorderDepth else { return nil }
        pendingFrames.sort { $0.sequence == $1.sequence ? $0.poc < $1.poc : $0.sequence < $1.sequence }
        return pendingFrames.removeFirst().frame
    }

    func finishDelayedFrames() {
        if let session = vtSession {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        pendingFramesLock.lock(); drainingPictures = true; pendingFramesLock.unlock()
    }

    func flush() {
        cleanVTSession()
        cleanDecodeInfo()
    }

    deinit {
        flush()
    }
}
