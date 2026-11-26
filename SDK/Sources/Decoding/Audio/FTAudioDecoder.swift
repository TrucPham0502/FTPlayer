//
//  FTAudioDecoder.swift
//  
//
//  Edited by TP on 2024/7/18.
//

import Foundation
import Accelerate
@_implementationOnly import libavcodec
@_implementationOnly import libswresample
protocol FTAudioDecoderDelegate: AnyObject {
    func audioDecoder(_ audioDecoder: FTAudioDecoder, samplingRate: inout Float64)
    func audioDecoder(_ audioDecoder: FTAudioDecoder, channelCount: inout UInt32)
}

class FTAudioDecoder {
    weak var delegate: FTAudioDecoderDelegate?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var timebase: TimeInterval
    private var samplingRate: Float64 = 0
    private var channelCount: UInt32 = 0
    private var audioSwrContext: OpaquePointer?
    private var audioSwrBuffer: UnsafeMutableRawPointer?
    private var audioSwrBufferSize: Int = 0
    // Track params used to build swr context so we can recreate on change
    private var swrSamplingRate: Float64 = 0
    private var swrChannelCount: UInt32 = 0

    private let levelLock = NSLock()
    private var decodedSampleCount: Int64 = 0
    private var decodedSquareSum: Double = 0
    private var decodedPeak: Float = 0
    // Cumulative PCM before mixer volume; sampled from the decoder thread, never the render callback.
    var levelDescription: String {
        levelLock.lock()
        let count = decodedSampleCount, squareSum = decodedSquareSum, peak = decodedPeak
        levelLock.unlock()
        guard count > 0 else { return "audioDecodedSamples=0" }
        let rmsDB = 10 * log10(max(squareSum / Double(count), FTPlayerSDKConfiguration.Diagnostics.minimumMeasuredPower))
        let peakDB = 20 * log10(max(Double(peak), FTPlayerSDKConfiguration.Diagnostics.minimumMeasuredAmplitude))
        return String(format: "audioDecodedSamples=%lld audioDecodedRMSDBFS=%.2f audioDecodedPeakDBFS=%.2f", count, rmsDB, peakDB)
    }
    private func measureDecodedPCM(_ samples: UnsafePointer<Float>, count: Int) {
        guard FTPlayerDiagnostic.shared.isEnabled else { return }
        var rms: Float = 0, peak: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        levelLock.lock()
        decodedSampleCount += Int64(count)
        decodedSquareSum += Double(rms) * Double(rms) * Double(count)
        decodedPeak = max(decodedPeak, peak)
        levelLock.unlock()
    }

    var timestampOffset: TimeInterval = 0
    private var nextPresentationTime: TimeInterval?
    private var frameQueue: FTFrameQueue
    private var framePool: FTFramePool

    static func decoder(codecContext: UnsafeMutablePointer<AVCodecContext>, timebase: TimeInterval, delegate: FTAudioDecoderDelegate) -> FTAudioDecoder {
        return FTAudioDecoder(codecContext: codecContext, timebase: timebase, delegate: delegate)
    }

    private init(codecContext: UnsafeMutablePointer<AVCodecContext>, timebase: TimeInterval, delegate: FTAudioDecoderDelegate) {
        self.codecContext = codecContext
        self.timebase = timebase
        self.delegate = delegate
        self.frameQueue = FTFrameQueue()
        self.framePool = FTFramePool.audioPool()
        setup()
    }

    private func setup() {
        setupSwsContext()
    }

    private func setupSwsContext() {
        reloadAudioOutputInfo()
        guard samplingRate > 0, channelCount > 0 else { return }
        if audioSwrContext != nil {
            swr_free(&audioSwrContext)
        }
        var in_ch_layout = AVChannelLayout()
        var out_ch_layout = AVChannelLayout()

        av_channel_layout_default(&out_ch_layout, Int32(channelCount))

        if let codec = codecContext {
            av_channel_layout_copy(&in_ch_layout, &codec.pointee.ch_layout)
        }

        // Use AV_SAMPLE_FMT_FLT (interleaved float) — avoids S16→Float conversion step
        let allocationResult = swr_alloc_set_opts2(&audioSwrContext,
                                    &out_ch_layout,
                                    AV_SAMPLE_FMT_FLT,
                                    Int32(samplingRate),
                                    &in_ch_layout,
                                    codecContext?.pointee.sample_fmt ?? AV_SAMPLE_FMT_NONE,
                                    codecContext?.pointee.sample_rate ?? 0,
                                    0, nil)

        av_channel_layout_uninit(&in_ch_layout)
        av_channel_layout_uninit(&out_ch_layout)

        guard allocationResult >= 0, audioSwrContext != nil else {
            Console.log(type: .ERROR, "Audio resampler allocation failed: \(allocationResult)")
            return
        }
        // A mono programme is dual-mono on stereo speakers, matching AVFoundation.
        // libswresample's default centre-pan matrix is sqrt(1/2) in each channel (-3.01 dB).
        // Set only this 1->2 matrix; keep existing stereo/surround mixing and source level.
        let dualMono = (codecContext?.pointee.ch_layout.nb_channels == 1 && channelCount == 2)
        if dualMono {
            let matrix: [Double] = [1, 1]
            let matrixResult = matrix.withUnsafeBufferPointer { swr_set_matrix(audioSwrContext, $0.baseAddress, 1) }
            guard matrixResult >= 0 else {
                Console.log(type: .ERROR, "Audio mono/stereo matrix setup failed: \(matrixResult)")
                swr_free(&audioSwrContext)
                return
            }
        }
        let result = swr_init(audioSwrContext)
        let error: Error? = FTCheckError(result)
        if error != nil || audioSwrContext == nil {
            if audioSwrContext != nil {
                swr_free(&audioSwrContext)
            }
        } else {
            swrSamplingRate = samplingRate
            swrChannelCount = channelCount
            Console.log("Audio resampler inputRate=\(codecContext?.pointee.sample_rate ?? 0) inputChannels=\(codecContext?.pointee.ch_layout.nb_channels ?? 0) outputRate=\(samplingRate) outputChannels=\(channelCount) dualMonoUnity=\(dualMono)")
        }
    }

    func size() -> Int {
        return Int(frameQueue.size)
    }

    func isEmpty() -> Bool {
        return frameQueue.count <= 0
    }

    func duration() -> TimeInterval {
        return frameQueue.duration
    }

    func flush() {
        nextPresentationTime = nil
        frameQueue.flush()
        framePool.flush()
        if let codecContext = codecContext {
            avcodec_flush_buffers(codecContext)
        }
    }

    func destroy() {
        frameQueue.destroy()
        framePool.flush()
    }

    func getFrameSync() -> FTAudioFrame? {
        return frameQueue.getFrameSync() as? FTAudioFrame
    }

    func getFrameAsync() -> FTAudioFrame? {
        return frameQueue.getFrameAsync() as? FTAudioFrame
    }

    func peekFrame() -> FTAudioFrame? {
        frameQueue.peekFrame() as? FTAudioFrame
    }

    func putPacket(_ packet: UnsafeMutablePointer<AVPacket>?, minimumPresentationTime: TimeInterval? = nil) -> Int {
        guard let packet else { return -1 }
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }
        if packet.pointee.data == nil { return 0 }

        let sendResult = avcodec_send_packet(codecContext, packet)
        if sendResult < 0 && sendResult != AVERROR(EAGAIN) && sendResult != FT_AVERROR_EOF {
            return -1
        }
        var packetSent = (sendResult == 0)

        while true {
            let receiveResult = avcodec_receive_frame(codecContext, frame)
            if receiveResult == 0 {
                autoreleasepool {
                    if let audioFrame = decode(frame) {
                        // Decode reference state normally, but do not retain PCM
                        // before the pending seek. Audio output is paused during
                        // buffering, so render-time pruning alone can fill the RAM
                        // limit and prevent demux from ever reaching the target.
                        if let minimumPresentationTime,
                           audioFrame.position + max(0, audioFrame.duration) < minimumPresentationTime {
                            audioFrame.cancel()
                        } else {
                            frameQueue.putFrame(audioFrame)
                        }
                    }
                }
                av_frame_unref(frame)
            } else if receiveResult == AVERROR(EAGAIN) {
                if !packetSent {
                    let retryResult = avcodec_send_packet(codecContext, packet)
                    if retryResult == 0 {
                        packetSent = true
                        continue
                    }
                    if retryResult < 0 && retryResult != AVERROR(EAGAIN) && retryResult != FT_AVERROR_EOF {
                        break
                    }
                }
                break
            } else if receiveResult == FT_AVERROR_EOF {
                break
            } else {
                break
            }
        }
        return 0
    }

    private func decode(_ frame: UnsafeMutablePointer<AVFrame>?) -> FTAudioFrame? {
        guard let tempFrame = frame, tempFrame.pointee.data.0 != nil else { return nil }

        let value = tempFrame.pointee
        let timestamp = [value.best_effort_timestamp, value.pts, value.pkt_dts].first { $0 != FT_AV_NOPTS_VALUE }
        let sampleRate = value.sample_rate > 0 ? value.sample_rate : (codecContext?.pointee.sample_rate ?? 0)
        guard sampleRate > 0, value.nb_samples > 0,
              let position = timestamp.map({ Double($0) * timebase - timestampOffset }) ?? nextPresentationTime,
              position.isFinite else { return nil }
        // A PES may timestamp only its first AAC frame. Later decoded frames
        // inherit that anchor by their actual sample count, never AV_NOPTS_VALUE.
        // A new real timestamp still wins, preserving genuine audio gaps.
        let decodedDuration = Double(value.nb_samples) / Double(sampleRate)
        nextPresentationTime = position + decodedDuration

        reloadAudioOutputInfo()

        guard samplingRate > 0, channelCount > 0 else { return nil }

        // Recreate swr context if device audio params changed since last setup.
        // Guard against 0 values (device not ready yet) to avoid repeated failed inits.
        if samplingRate > 0 && channelCount > 0 && (samplingRate != swrSamplingRate || channelCount != swrChannelCount) {
            setupSwsContext()
        }

        var numberOfFrames: Int
        var audioDataBuffer: UnsafeMutableRawPointer
        let inputChannels = codecContext?.pointee.ch_layout.nb_channels ?? 1
        let usingSwr = audioSwrContext != nil

        if let audioSwrContext = audioSwrContext {
            let ratio = max(1, Int(samplingRate / Float64(codecContext?.pointee.sample_rate ?? 1))) * max(1, Int(channelCount / UInt32(inputChannels))) * Int(FTPlayerSDKConfiguration.Audio.resamplerCapacityMultiplier)
            // FLT = 4 bytes/sample; allocate buffer sized for worst-case output
            let bufferSize = av_samples_get_buffer_size(nil, Int32(channelCount), tempFrame.pointee.nb_samples * Int32(ratio), AV_SAMPLE_FMT_FLT, 1)

            if audioSwrBuffer == nil || audioSwrBufferSize < bufferSize {
                let newSize = Int(bufferSize)
                if let newBuffer = realloc(audioSwrBuffer, newSize) {
                    audioSwrBuffer = newBuffer
                    audioSwrBufferSize = newSize
                } else {
                    return nil
                }
            }

            var outputBuffer: [UnsafeMutablePointer<UInt8>?] = [audioSwrBuffer?.assumingMemoryBound(to: UInt8.self), nil]
            // Call swr_convert inside withMemoryRebound so inputPtr stays valid for the entire call
            numberOfFrames = withUnsafeMutablePointer(to: &tempFrame.pointee.data) {
                $0.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: Int(inputChannels)) { inputPtr in
                    Int(swr_convert(audioSwrContext, &outputBuffer, tempFrame.pointee.nb_samples * Int32(ratio), inputPtr, tempFrame.pointee.nb_samples))
                }
            }
            if FTCheckError(Int32(numberOfFrames)) != nil {
                return nil
            }
            audioDataBuffer = audioSwrBuffer!
        } else {
            if codecContext?.pointee.sample_fmt != AV_SAMPLE_FMT_S16 {
                Console.log(type: .ERROR, "audio format error")
                return nil
            }
            audioDataBuffer = UnsafeMutableRawPointer(tempFrame.pointee.data.0!)
            numberOfFrames = Int(tempFrame.pointee.nb_samples)
        }

        guard numberOfFrames > 0 else { return nil }
        guard let audioFrame = framePool.getUnuseFrame() as? FTAudioFrame else {
            return nil
        }

        audioFrame.position = position
        audioFrame.duration = Double(tempFrame.pointee.duration) * timebase

        if audioFrame.duration <= 0 { audioFrame.duration = Double(numberOfFrames) / samplingRate }

        let numberOfElements = numberOfFrames * Int(channelCount)
        audioFrame.setSamplesLength(numberOfElements * MemoryLayout<Float32>.size)

        guard let samples = audioFrame.samples else { audioFrame.cancel(); return nil }
        if usingSwr {
            // swr output is AV_SAMPLE_FMT_FLT (interleaved float) — copy directly
            memcpy(samples, audioDataBuffer, numberOfElements * MemoryLayout<Float32>.size)
        } else {
            // Fallback: raw S16 interleaved — convert to Float32 with correct scale (1/32768)
            var scale: Float32 = 1.0 / 32768.0
            let audioDataPointer = audioDataBuffer.bindMemory(to: Int16.self, capacity: numberOfElements)
            vDSP_vflt16(audioDataPointer, 1, samples, 1, vDSP_Length(numberOfElements))
            vDSP_vsmul(samples, 1, &scale, samples, 1, vDSP_Length(numberOfElements))
        }

        // A complete file may contain audio beyond its EXTINF duration. Concat
        // shifts the next file to that declared boundary, but does not trim PCM.
        // Use metadata carried by the decoded frame (also correct for delayed
        // codecs), rather than whichever packet the decoder is currently sending.
        if let metadata = tempFrame.pointee.metadata,
           let startEntry = av_dict_get(metadata, "lavf.concatdec.start_time", nil, 0),
           let durationEntry = av_dict_get(metadata, "lavf.concatdec.duration", nil, 0),
           let startUS = Double(String(cString: startEntry.pointee.value)),
           let durationUS = Double(String(cString: durationEntry.pointee.value)),
           startUS.isFinite, durationUS.isFinite, durationUS > 0 {
            let start = startUS / 1_000_000 - timestampOffset
            let end = start + durationUS / 1_000_000
            let first = min(Double(numberOfFrames), max(0, ceil((start - audioFrame.position) * samplingRate - FTPlayerSDKConfiguration.Precision.sampleRoundingEpsilon)))
            let last = min(Double(numberOfFrames), max(0, floor((end - audioFrame.position) * samplingRate + FTPlayerSDKConfiguration.Precision.sampleRoundingEpsilon)))
            guard last > first else { audioFrame.cancel(); return nil }
            let firstSample = Int(first), keptFrames = Int(last - first)
            let elements = keptFrames * Int(channelCount)
            if firstSample > 0 { memmove(samples, samples.advanced(by: firstSample * Int(channelCount)), elements * MemoryLayout<Float>.size) }
            audioFrame.setSamplesLength(elements * MemoryLayout<Float>.size)
            audioFrame.position += Double(firstSample) / samplingRate
            audioFrame.duration = Double(keptFrames) / samplingRate
        }
        measureDecodedPCM(UnsafePointer(samples), count: audioFrame.size / MemoryLayout<Float>.size)
        return audioFrame
    }

    private func reloadAudioOutputInfo() {
        delegate?.audioDecoder(self, samplingRate: &samplingRate)
        delegate?.audioDecoder(self, channelCount: &channelCount)
    }

    deinit {
        if audioSwrBuffer != nil {
            free(audioSwrBuffer)
            audioSwrBuffer = nil
            audioSwrBufferSize = 0
        }
        if audioSwrContext != nil {
            swr_free(&audioSwrContext)
        }
        Console.log("FTAudioDecoder release")
    }
}
