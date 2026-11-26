import XCTest
import AVFoundation
import AudioToolbox
import libavcodec
@testable import FTPlayer

final class FTPlayerMuteTests: PlaybackTestCase {
    private func tone(sampleRate: Int, amplitudes: [Double]) throws -> URL {
        var pcm = Data()
        for frame in 0..<sampleRate {
            for amplitude in amplitudes {
                var value = Int16((sin(2 * .pi * 1000 * Double(frame) / Double(sampleRate)) * amplitude * 32767).rounded()).littleEndian
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
        }
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + pcm.count)); text("WAVEfmt "); u32(16); u16(1)
        u16(UInt16(amplitudes.count)); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * amplitudes.count * 2))
        u16(UInt16(amplitudes.count * 2)); u16(16); text("data"); u32(UInt32(pcm.count)); data.append(pcm)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ftplayer-tone-\(UUID()).wav")
        try data.write(to: url); return url
    }
    private func checkPCM(inputRate: Int, outputRate: Int, amplitudes: [Double], outputChannels: Int) throws {
        continueAfterFailure = true
        let url = try tone(sampleRate: inputRate, amplitudes: amplitudes)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = AudioPCMProbe(rate: outputRate, channels: outputChannels)
        let decoder = FTDecoder(contentURL: url, videoFormat: .unknown, videoOutput: nil, audioOutput: probe)
        decoder.delegate = probe; decoder.minBufferedDuration = 0.01; decoder.open()
        defer { decoder.delegate = nil; decoder.closeFile() }
        try require(until { decoder.endOfFile || probe.error != nil }, "PCM decode did not finish")
        XCTAssertNil(probe.error)
        var samples: [Float] = []
        while let frame = decoder.fetchAudioFrame() {
            frame.startPlaying()
            if let base = frame.samples { samples.append(contentsOf: UnsafeBufferPointer(start: base, count: frame.size / MemoryLayout<Float>.size)) }
            frame.stopPlaying()
        }
        let frames = samples.count / outputChannels
        try require(frames > outputRate * 8 / 10, "Too little decoded PCM: \(frames)")
        let low = outputRate / 10, high = min(frames, outputRate * 8 / 10)
        var measurements: [[String: Any]] = []
        for channel in 0..<outputChannels {
            let values = (low..<high).map { Double(samples[$0 * outputChannels + channel]) }
            let rms = sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
            let expected = amplitudes[amplitudes.count == 1 ? 0 : channel] / sqrt(2)
            let deltaDB = 20 * log10(max(rms, 1e-12) / expected)
            let peak = values.map(abs).max() ?? 0
            measurements.append(["channel": channel, "rms": rms, "expectedRMS": expected, "deltaDB": deltaDB, "peak": peak])
            XCTAssertEqual(deltaDB, 0, accuracy: 0.12, "Unexpected gain change input\(inputRate)/\(amplitudes.count)ch output\(outputRate)/\(outputChannels)ch channel\(channel)")
            XCTAssertLessThanOrEqual(peak, 1, "Unexpected clipping")
        }
        if amplitudes.count == 1 && outputChannels == 2 {
            var maxDifference: Float = 0
            for frame in low..<high {
                let left: Float = samples[frame * 2]
                let right: Float = samples[frame * 2 + 1]
                maxDifference = max(maxDifference, abs(left - right))
            }
            XCTAssertLessThan(maxDifference, 0.00001, "Mono was not duplicated equally")
        }
        let report: [String: Any] = ["inputRate": inputRate, "outputRate": outputRate, "inputChannels": amplitudes.count, "outputChannels": outputChannels, "outputFrames": frames, "channels": measurements]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.name = name + "-pcm-gain"; attachment.lifetime = .keepAlways; add(attachment)
        FTPlayerDiagnostic.shared.log("AUDIO PCM CHECK \(String(data: data, encoding: .utf8)!)", category: "test")
    }
    func testAudioLevelMono8kToStereo48kPreservesAmplitude() throws { try checkPCM(inputRate: 8000, outputRate: 48000, amplitudes: [0.25], outputChannels: 2) }
    func testAudioLevelMono441ToStereo48kPreservesAmplitude() throws { try checkPCM(inputRate: 44100, outputRate: 48000, amplitudes: [0.25], outputChannels: 2) }
    func testAudioLevelMono48kToStereo48kPreservesAmplitude() throws { try checkPCM(inputRate: 48000, outputRate: 48000, amplitudes: [0.25], outputChannels: 2) }
    func testAudioLevelMono8kToStereo8kPreservesAmplitude() throws { try checkPCM(inputRate: 8000, outputRate: 8000, amplitudes: [0.25], outputChannels: 2) }
    func testAudioLevelMono8kToMono48kUnchanged() throws { try checkPCM(inputRate: 8000, outputRate: 48000, amplitudes: [0.25], outputChannels: 1) }
    func testAudioLevelStereo441ToStereo48kUnchanged() throws { try checkPCM(inputRate: 44100, outputRate: 48000, amplitudes: [0.25, 0.125], outputChannels: 2) }
    func testAudioLevelQuietMonoIsNotAutomaticallyNormalized() throws { try checkPCM(inputRate: 8000, outputRate: 48000, amplitudes: [0.002], outputChannels: 2) }
    func testAudioLevelNearFullScaleMonoDoesNotClip() throws { try checkPCM(inputRate: 8000, outputRate: 48000, amplitudes: [0.95], outputChannels: 2) }

    func testLongAudioSeekPrerollDoesNotFillPacketReadBudget() throws {
        let format = FTFormatContext(contentURL: try fixture("sustained-h264-aac.mp4"), videoFormat: .unknown)
        defer { format.destroy() }
        format.setupSync(useCache: false)
        XCTAssertNil(format.error)
        let parameters = PrerollAudioParameters()
        let decoder = FTAudioDecoder.decoder(codecContext: try XCTUnwrap(format.audioCodecContext),
                                             timebase: format.audioTimebase, delegate: parameters)
        defer { decoder.destroy() }
        decoder.timestampOffset = format.startTime
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var peakBytes = 0
        while format.readFrame(packet) >= 0 {
            let value = try XCTUnwrap(packet?.pointee)
            if Int(value.stream_index) == format.audioTrack?.index {
                XCTAssertGreaterThanOrEqual(decoder.putPacket(packet, minimumPresentationTime: 39.95), 0)
                peakBytes = max(peakBytes, decoder.size())
                let position = Double(value.pts) * format.audioTimebase - format.startTime
                av_packet_unref(packet)
                if position >= 42 { break }
            } else { av_packet_unref(packet) }
        }
        XCTAssertLessThan(peakBytes, 8 * 1024 * 1024, "Preroll PCM blocked the packet reader before reaching the seek target")
        let first = try XCTUnwrap(decoder.getFrameAsync())
        defer { first.cancel() }
        XCTAssertGreaterThanOrEqual(first.position + first.duration, 39.95)
        XCTAssertLessThan(first.position, 40.05)
        XCTAssertGreaterThan(first.size, 0)
    }

    private func gain(_ s: PlaybackSession, _ expected: Float, _ step: String) throws {
        let value = try XCTUnwrap(s.player.audioManager?.volume)
        XCTAssertEqual(value, expected, accuracy: 0.001, step)
        s.measurements.append(["step": step, "muted": s.player.isMuted, "volume": s.player.volume,
                               "mixerGain": value, "frames": s.sink.frames, "progress": s.player.progress])
    }
    func testMutedBeforeOpenPreservesVolumeAndVideo() throws {
        let s = PlaybackSession(url: try fixture("sample.mp4")); sessions.append(s)
        s.player.isMuted = true; s.player.volume = 0.35; s.start()
        try require(until { s.ready || s.failure != nil }, "Open timed out")
        try assertPlayback(s); try gain(s, 0, "muted before open")
        let frames = s.sink.frames
        s.player.volume = 0.6; try gain(s, 0, "volume changed while muted")
        try require(until { s.sink.frames > frames + 3 }, "Muting stopped video")
        s.player.isMuted = false; try gain(s, 0.6, "unmute restores configured volume")
        for invalid in [CGFloat.nan, .infinity, -1, 2] { s.player.volume = invalid }
        try gain(s, 0.6, "invalid volumes keep mixer level")
    }
    func testMuteSurvivesRateSeekAndReopen() throws {
        let s = try start(fixture("sample.mp4")); try assertPlayback(s)
        s.player.volume = 0.5; s.player.isMuted = true
        s.player.rate = 2
        var done: Bool?; s.player.seek(to: 10) { done = $0 }
        try require(until { done != nil }, "Seek callback missing")
        try require(done == true, "Seek failed")
        try gain(s, 0, "muted through 2x seek")
        s.ready = false; s.player.replaceVideo()
        try require(until { s.ready || s.failure != nil }, "Reopen timed out")
        try gain(s, 0, "new audio graph remains muted")
        s.player.isMuted = false; try gain(s, 0.5, "unmute after reopen")
        let frames = s.sink.frames
        try require(until { s.sink.frames > frames + 3 }, "Reopened video stalled")
    }
}

private final class AudioPCMProbe: FTDecoderAudioOutput, FTDecoderDelegate {
    let samplingRate: Float64
    let numberOfChannels: UInt32
    private let lock = NSLock()
    private var storedError: Error?
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    init(rate: Int, channels: Int) { samplingRate = Float64(rate); numberOfChannels = UInt32(channels) }
    func decoderWillOpenInputStream(_ decoder: any PlaybackEngine) {}
    func decoderDidPrepareToDecodeFrames(_ decoder: any PlaybackEngine) {}
    func decoderDidEndOfFile(_ decoder: any PlaybackEngine) {}
    func decoderDidPlaybackFinished(_ decoder: any PlaybackEngine) {}
    func decoder(_ decoder: any PlaybackEngine, didError error: Error) { lock.lock(); storedError = error; lock.unlock() }
    func decoder(_ decoder: any PlaybackEngine, didChangeValueOfBuffering buffering: Bool) {}
    func decoder(_ decoder: any PlaybackEngine, didChangeValueOfBufferedDuration bufferedDuration: TimeInterval) {}
    func decoder(_ decoder: any PlaybackEngine, didChangeValueOfProgress progress: TimeInterval) {}
}

private final class PrerollAudioParameters: FTAudioDecoderDelegate {
    func audioDecoder(_ audioDecoder: FTAudioDecoder, samplingRate: inout Float64) { samplingRate = 48_000 }
    func audioDecoder(_ audioDecoder: FTAudioDecoder, channelCount: inout UInt32) { channelCount = 2 }
}

// Session changes must be exercised with actual rendered PCM, not just state callbacks.
final class FTPlayerAudioSessionTests: PlaybackTestCase {
    private let session = AVAudioSession.sharedInstance()
    private var saved: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions, Double, Double)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        saved = (session.category, session.mode, session.categoryOptions, session.preferredSampleRate, session.preferredIOBufferDuration)
    }
    override func tearDownWithError() throws {
        try? session.setActive(false)
        try? session.setCategory(saved.0, mode: saved.1, options: saved.2)
        if saved.3 > 0 { try? session.setPreferredSampleRate(saved.3) }
        if saved.4 > 0 { try? session.setPreferredIOBufferDuration(saved.4) }
        try super.tearDownWithError()
    }

    @objc func testAudioSessionStablePlaybackAndVoiceModes() throws {
        for (category, mode, rate) in [(AVAudioSession.Category.playback, AVAudioSession.Mode.default, 48_000.0),
            (.playback, .moviePlayback, 44_100), (.playAndRecord, .videoChat, 48_000)] {
            try configure(category, mode: mode, rate: rate)
            try exercise(label: "stable-\(mode.rawValue)") { _, _ in }
        }
    }
    @objc func testAudioSessionPreferencePairBeforeActivation() throws {
        try session.setActive(false)
        try session.setCategory(.playback, mode: .moviePlayback)
        var setup = [mark("inactive before exact preference pair")]
        do { try applyIntegrationPreferences() }
        catch {
            setup.append(mark("exact preference pair rejected", error: error))
            try attachPreferenceSetup(setup)
            throw error
        }
        setup.append(mark("inactive after exact preference pair"))
        try session.setActive(true)
        setup.append(mark("activated after exact preference pair"))
        try attachPreferenceSetup(setup)
        try exercise(label: "preference-pair-before-activation") { _, _ in }
    }
    @objc func testAudioSessionPreferencePairDuringPlayback() throws {
        try configure(.playback, mode: .moviePlayback)
        // Start with a longer real hardware quantum so the 5 ms request is
        // an actual configuration change, rather than a redundant setter.
        try session.setPreferredIOBufferDuration(0.023)
        try exercise(label: "preference-pair-during-playback") { _, steps in
            try self.applyIntegrationPreferences()
            steps.append(self.mark("exact preference pair applied while playing"))
            self.pump(0.25)
            steps.append(self.mark("settled after exact preference pair"))
        }
    }
    @objc func testAudioSessionPreferencePairWithForeignRTCStyleHandoff() throws {
        try configure(.playAndRecord, mode: .videoChat)
        try session.setPreferredIOBufferDuration(0.023)
        let foreign = try AudioSessionForeignOutput(rate: session.sampleRate)
        defer { foreign.stop() }
        try exercise(label: "preference-pair-foreign-handoff") { _, steps in
            foreign.stop()
            do { try self.session.setActive(false); steps.append(self.mark("foreign stopped; deactivated")) }
            catch { steps.append(self.mark("foreign stopped; deactivate rejected", error: error)) }
            try self.session.setCategory(.playback, mode: .moviePlayback, options: [.allowBluetoothA2DP, .allowAirPlay])
            try self.applyIntegrationPreferences()
            steps.append(self.mark("exact preference pair before reactivation"))
            try self.session.setActive(true)
            steps.append(self.mark("playback reactivated after exact preference pair"))
        }
    }
    private func applyIntegrationPreferences() throws {
        // Exact two calls from FTAudioSession.configureForWebRTCIfNeeded().
        try session.setPreferredIOBufferDuration(0.005)
        try session.setPreferredSampleRate(session.sampleRate)
    }
    private func attachPreferenceSetup(_ events: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "exact-preference-pair-activation"; attachment.lifetime = .keepAlways; add(attachment)
        print("AUDIO_PREFERENCE_SETUP \(String(decoding: data, as: UTF8.self))")
    }
    @objc func testAudioSessionCategoryChangeDuringPlayback() throws {
        try configure(.playback, mode: .moviePlayback)
        try exercise(label: "category-change") { _, steps in
            try self.session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            steps.append(self.mark("voice category applied"))
        }
    }
    @objc func testAudioSessionDeactivateReactivateDuringPlayback() throws {
        try configure(.playback, mode: .moviePlayback)
        try exercise(label: "deactivate-reactivate") { _, steps in
            do { try self.session.setActive(false); steps.append(self.mark("deactivated")) }
            catch { steps.append(self.mark("deactivate rejected", error: error)) }
            try self.session.setActive(true)
            steps.append(self.mark("reactivated"))
        }
    }
    @objc func testAudioSessionSampleRateChangeDuringPlayback() throws {
        try configure(.playback, mode: .moviePlayback)
        try exercise(label: "sample-rate-change") { _, steps in
            try self.session.setPreferredSampleRate(44_100)
            steps.append(self.mark("requested 44100"))
            self.pump(1.2)
            try self.session.setPreferredSampleRate(48_000)
            steps.append(self.mark("requested 48000"))
        }
    }
    @objc func testAudioSessionIOBufferChangeDuringPlayback() throws {
        try configure(.playback, mode: .moviePlayback)
        try exercise(label: "io-buffer-change") { _, steps in
            try self.session.setPreferredIOBufferDuration(0.085)
            steps.append(self.mark("requested large IO buffer"))
            self.pump(1.2)
            try self.session.setPreferredIOBufferDuration(0.005)
            steps.append(self.mark("requested small IO buffer"))
        }
    }
    @objc func testAudioSessionForeignUnitChangesSessionWhileFPlayerRuns() throws {
        try configure(.playAndRecord, mode: .videoChat)
        let foreign = try AudioSessionForeignOutput(rate: session.sampleRate)
        defer { foreign.stop() }
        try exercise(label: "foreign-unit-session-handoff") { _, steps in
            // The RTC control path stops its own IO before touching the shared
            // session. It does not stop FTPlayer's graph; reproduce that ordering.
            foreign.stop()
            do { try self.session.setActive(false); steps.append(self.mark("foreign IO stopped; deactivated")) }
            catch { steps.append(self.mark("foreign IO stopped; deactivate rejected", error: error)) }
            try self.session.setCategory(.playback, mode: .moviePlayback, options: [.allowBluetoothA2DP, .allowAirPlay])
            try self.session.setActive(true)
            steps.append(self.mark("foreign owner configured playback"))
        }
    }
    @objc func testAudioSessionCoordinatedHandoffPreservesPCM() throws {
        try configure(.playAndRecord, mode: .videoChat)
        try exercise(label: "coordinated-handoff", permitsTransitionPause: true) { manager, steps in
            manager.pause()
            try self.session.setActive(false)
            try self.session.setCategory(.playback, mode: .moviePlayback, options: [.allowBluetoothA2DP, .allowAirPlay])
            try self.session.setActive(true)
            steps.append(self.mark("all IO stopped; playback configured"))
            manager.play()
        }
    }

    @objc func testAudioSessionPCMMeasurementDetectsPopsAndRepeatedDroppedSamples() throws {
        let rate = 48_000.0, frames = 8192, boundary = 4096
        func signal(shift: Int = 0, gain: Float = 1, pop: Float = 0) -> [Float] {
            (0..<frames).flatMap { frame -> [Float] in
                let index = frame >= boundary ? frame + shift : frame
                let value = gain * Float(0.25 * sin(2 * .pi * 997 * Double(index) / rate)) + (frame == boundary ? pop : 0)
                return [value, value]
            }
        }
        func measure(_ signal: [Float]) -> [String: Double] {
            let tap = AudioSessionPCMCapture(channels: 2, capacity: frames)
            var values = signal
            values.withUnsafeMutableBufferPointer { buffer in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                    mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.size), mData: buffer.baseAddress))
                tap.capture(UInt32(frames), data: &list)
            }
            return tap.measure(from: 0, to: .infinity, rate: rate)
        }
        let clean = measure(signal()), repeated = measure(signal(shift: -256)), dropped = measure(signal(shift: 256))
        let pop = measure(signal(pop: 0.15)), amplified = measure(signal(gain: 1.5))
        XCTAssertLessThan(clean["maxPredictionError"] ?? 1, 0.002)
        XCTAssertLessThan(clean["maxSampleStep"] ?? 1, 0.05)
        XCTAssertEqual(clean["rms"] ?? 0, 0.25 / sqrt(2), accuracy: 0.001)
        for damaged in [repeated, dropped, pop] {
            XCTAssertGreaterThan(damaged["maxPredictionError"] ?? 0, 0.002, "PCM measurement failed to detect corrupted signal")
        }
        XCTAssertGreaterThan(abs((amplified["rms"] ?? 0) - 0.25 / sqrt(2)), 0.015, "Gain measurement missed amplification")
        let data = try JSONSerialization.data(withJSONObject: ["clean": clean, "repeated256": repeated,
            "dropped256": dropped, "pop": pop, "gain1_5": amplified], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "audio-session-measurement-controls"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func configure(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, rate: Double = 48_000) throws {
        try session.setActive(false)
        try session.setCategory(category, mode: mode)
        try session.setPreferredSampleRate(rate)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    }
    private func mark(_ event: String, error: Error? = nil) -> [String: Any] {
        var row: [String: Any] = ["event": event, "wall": ProcessInfo.processInfo.systemUptime,
            "category": session.category.rawValue, "mode": session.mode.rawValue,
            "sampleRate": session.sampleRate, "ioBufferDuration": session.ioBufferDuration,
            "preferredSampleRate": session.preferredSampleRate, "preferredIOBufferDuration": session.preferredIOBufferDuration,
            "channels": session.outputNumberOfChannels]
        if let error { row["error"] = String(describing: error); row["errorCode"] = (error as NSError).code }
        return row
    }
    private func exercise(label: String, permitsTransitionPause: Bool = false,
        change: (FTAudioManager, inout [[String: Any]]) throws -> Void) throws {
        // Collect all failures and attachments even when one PCM contract fails.
        continueAfterFailure = true
        let source = AudioSessionContinuousSource()
        let manager = FTAudioManager(decoder: source)
        defer { manager.destroy() }
        try require(manager.registerAudioSession(), "Cannot create SDK audio graph")
        let channels = Int(manager.numberOfChannels), rate = manager.samplingRate
        source.prepare(channels: channels, rate: rate)
        // Read existing internal graph without exposing production test hooks.
        let optional = try XCTUnwrap(Mirror(reflecting: manager).children.first { $0.label == "outputContext" }?.value)
        let context = try XCTUnwrap(Mirror(reflecting: optional).children.first?.value as? FTAudioOutputContext)
        let units = [try XCTUnwrap(context.converterNodeContext.audioUnit), try XCTUnwrap(context.mixerNodeContext.audioUnit)]
        let taps = units.map { _ in AudioSessionPCMCapture(channels: channels, capacity: Int(rate * 12)) }
        var formats: [[String: Any]] = []
        for (unit, tap) in zip(units, taps) {
            var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            XCTAssertEqual(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size), noErr)
            try require(format.mBitsPerChannel == 32 && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && Int(format.mChannelsPerFrame) == channels,
                "Capture requires the SDK's Float32 graph format")
            formats.append(["sampleRate": format.mSampleRate, "channels": format.mChannelsPerFrame, "flags": format.mFormatFlags])
            XCTAssertEqual(AudioUnitAddRenderNotify(unit, audioSessionCaptureCallback, Unmanaged.passUnretained(tap).toOpaque()), noErr)
        }
        defer {
            manager.pause()
            for (unit, tap) in zip(units, taps) {
                AudioUnitRemoveRenderNotify(unit, audioSessionCaptureCallback, Unmanaged.passUnretained(tap).toOpaque())
            }
        }
        manager.volume = 1; manager.playbackRate = 1
        manager.play()
        let beforeStart = ProcessInfo.processInfo.systemUptime
        pump(1.1)
        let changeStart = ProcessInfo.processInfo.systemUptime
        var steps = [mark("before transition")]
        var changeError: Error?
        do { try change(manager, &steps) } catch { changeError = error; steps.append(mark("transition failed", error: error)) }
        let changeEnd = ProcessInfo.processInfo.systemUptime
        pump(1.4)
        let end = ProcessInfo.processInfo.systemUptime
        manager.pause() // Drain audio callbacks before inspecting storage.
        var measurements: [[String: Any]] = []
        for (index, tap) in taps.enumerated() {
            let before = tap.measure(from: beforeStart + 0.35, to: changeStart, rate: rate)
            let after = tap.measure(from: changeEnd + 0.35, to: end, rate: rate)
            let transition = tap.measure(from: changeStart, to: changeEnd + 0.35, rate: rate)
            measurements.append(["stage": index == 0 ? "converter" : "mixer", "before": before, "after": after,
                "transition": transition, "renderErrors": tap.errors, "captureOverflows": tap.overflows])
            for (phase, metric) in [("before", before), ("after", after)] {
                let step = "\(label)/\(index)/\(phase)"
                XCTAssertGreaterThan(metric["frames"] ?? 0, rate * 0.3, "Audio output stopped: \(step)")
                XCTAssertEqual(metric["rms"] ?? 0, 0.25 / sqrt(2), accuracy: 0.015, "Audio gain changed: \(step)")
                XCTAssertLessThan(metric["maxSampleStep"] ?? 1, 0.05, "PCM discontinuity: \(step)")
                XCTAssertLessThan(metric["maxPredictionError"] ?? 1, 0.002, "Samples repeated/dropped or phase changed: \(step)")
                XCTAssertLessThanOrEqual(metric["longestZeroRun"] ?? .infinity, 1, "Silence inserted into continuous tone: \(step)")
                XCTAssertLessThan(metric["maximumCallbackGap"] ?? 1, 0.25, "Output repeatedly stalls: \(step)")
            }
            if !permitsTransitionPause {
                XCTAssertLessThan(transition["maxSampleStep"] ?? 0, 0.05, "PCM jump during \(label)")
                XCTAssertLessThan(transition["maxPredictionError"] ?? 0, 0.002, "Phase discontinuity during \(label)")
            }
            XCTAssertEqual(tap.errors, 0, "AudioUnit reported render errors: \(label)")
            XCTAssertEqual(tap.overflows, 0)
        }
        let report: [String: Any] = ["scenario": label, "graphRate": rate, "channels": channels,
            "beforeStart": beforeStart, "changeStart": changeStart, "changeEnd": changeEnd, "end": end,
            "sessionEvents": steps, "formatsAtStart": formats, "measurements": measurements,
            "finalSession": mark("finished"), "permitsTransitionPause": permitsTransitionPause]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = label + "-audio-session"; attachment.lifetime = .keepAlways; add(attachment)
        print("AUDIO_SESSION_RESULT \(String(decoding: data, as: UTF8.self))")
        XCTAssertNil(changeError, "Could not apply the scenario under test")
    }
}

/// Exercises the actual AUGraph pull chain, including a TimePitch node whose
/// processing rate is deliberately stale. Parameter readback alone cannot prove
/// the PCM consumption rate (the iPhone report showed 1 while consuming at 3x).
final class FTPlayerRateRecoveryTests: PlaybackTestCase {
    func testProgressContinuesWhenTimePitchStopsPullingPCMAtUnityRate() throws {
        continueAfterFailure = true
        let s = PlaybackSession(url: try fixture("sustained-h264-aac.mp4"), cache: true)
        sessions.append(s)
        s.player.isMuted = true
        s.start()
        try require(until { s.ready || s.failure != nil }, "Playback did not open")
        try assertPlayback(s)
        let decoder = try XCTUnwrap(s.player.decoder), audio = try XCTUnwrap(s.player.audioManager)
        s.player.rate = 8
        pump(0.15)
        var sought: Bool?
        s.player.seek(to: 5) { sought = $0 }
        try require(until { sought == true && !decoder.seeking && !decoder.buffering }, "High-rate seek did not finish")
        s.player.rate = 1
        let optional = try XCTUnwrap(Mirror(reflecting: audio).children.first { $0.label == "outputContext" }?.value)
        let context = try XCTUnwrap(Mirror(reflecting: optional).children.first?.value as? FTAudioOutputContext)
        let timePitch = try XCTUnwrap(context.timePitchNodeContext.audioUnit)
        audio.pause()
        // Fault injection models the report's missing upstream pulls, without
        // depending on reproducing the native iOS failure. TimePitch can render
        // silence successfully but never asks the SDK for PCM. At 1x this node
        // must be outside the active path, preserving real audio and progress.
        var callback = AURenderCallbackStruct(inputProc: progressSilentTimePitchInput,
            inputProcRefCon: Unmanaged.passUnretained(s.player).toOpaque())
        try require(AudioUnitSetProperty(timePitch, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
            "Could not inject the missing TimePitch input pulls")
        audio.play()
        pump(0.35)
        func copiedFrames() -> Double {
            let render = audio.rateDiagnosticFields(includeFormats: false)["render"] as? [String: Any]
            return (render?["copiedFrames"] as? NSNumber)?.doubleValue ?? 0
        }
        let began = ProcessInfo.processInfo.systemUptime, pcm = copiedFrames()
        let progress = s.player.progress, video = s.sink.lastPresentationTime, callbacks = s.progressEvents
        pump(2)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let pcmRate = (copiedFrames() - pcm) / audio.samplingRate / elapsed
        let progressRate = (s.player.progress - progress) / elapsed
        let videoRate = (s.sink.lastPresentationTime - video) / elapsed
        s.measurements.append(["operation": "timepitch-stops-upstream-pulls-at-1x",
            "wallSeconds": elapsed, "pcmRate": pcmRate, "progressRate": progressRate, "videoRate": videoRate,
            "progressCallbacks": s.progressEvents - callbacks,
            "audio": audio.rateDiagnosticFields(includeFormats: true)])
        XCTAssertNil(s.failure)
        XCTAssertEqual(videoRate, 1, accuracy: 0.3, "Video did not continue as it does in the report")
        XCTAssertGreaterThan(s.progressEvents - callbacks, 5, "didUpdateProgress stopped while video kept playing")
        XCTAssertEqual(progressRate, 1, accuracy: 0.2, "Progress froze while video continued")
        XCTAssertEqual(pcmRate, 1, accuracy: 0.2, "Native input stopped despite successful audio graph rendering")
    }

    func testRateOneAfterPacedHighRateSeeksMuted() throws { try checkPacedSeeks(muted: true) }
    func testRateOneAfterPacedHighRateSeeksAudible() throws { try checkPacedSeeks(muted: false) }

    private func checkPacedSeeks(muted: Bool) throws {
        let s = PlaybackSession(url: try fixture("sustained-h264-aac.mp4"), cache: true)
        sessions.append(s)
        s.player.isMuted = muted
        s.start()
        try require(until { s.ready || s.failure != nil }, "Playback did not open")
        try assertPlayback(s)
        let decoder = try XCTUnwrap(s.player.decoder), audio = try XCTUnwrap(s.player.audioManager)
        s.player.rate = 8
        pump(0.2)
        var completions = 0
        for index in 0..<17 {
            s.player.seek(to: 3 + Double(index) * 0.3) { _ in completions += 1 }
            pump(0.25)
        }
        try require(until { completions == 17 && !decoder.seeking && !decoder.buffering }, "Paced seek did not finish")
        s.player.rate = 1
        // Exclude only the short native pipeline transition; measure sustained
        // consumption so a 3x processor or a stalled progress path cannot pass.
        pump(0.35)
        func copiedFrames() -> Double {
            let render = audio.rateDiagnosticFields(includeFormats: false)["render"] as? [String: Any]
            return (render?["copiedFrames"] as? NSNumber)?.doubleValue ?? 0
        }
        let began = ProcessInfo.processInfo.systemUptime, pcm = copiedFrames()
        let progress = s.player.progress, video = s.sink.lastPresentationTime, callbacks = s.progressEvents
        pump(4)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let pcmRate = (copiedFrames() - pcm) / audio.samplingRate / elapsed
        let progressRate = (s.player.progress - progress) / elapsed
        let videoRate = (s.sink.lastPresentationTime - video) / elapsed
        s.measurements.append(["operation": "paced-17-seeks-at-8x-then-1x", "muted": muted,
            "wallSeconds": elapsed, "pcmRate": pcmRate, "progressRate": progressRate, "videoRate": videoRate,
            "progressCallbacks": s.progressEvents - callbacks,
            "audio": audio.rateDiagnosticFields(includeFormats: true)])
        XCTAssertNil(s.failure)
        XCTAssertEqual(audio.playbackRate, 1, accuracy: 0.001)
        XCTAssertEqual(pcmRate, 1, accuracy: 0.15, "Native graph still consumes PCM faster than 1x")
        XCTAssertEqual(progressRate, 1, accuracy: 0.2, "Public progress runs too fast or stalls")
        XCTAssertEqual(videoRate, 1, accuracy: 0.25, "Video remains at the old rate")
        XCTAssertGreaterThan(s.progressEvents - callbacks, 5, "didUpdateProgress stopped after the rate drop")
    }

    func testUnityPlaybackIgnoresStaleTimePitchProcessingRate() throws {
        let source = AudioSessionContinuousSource()
        let manager = FTAudioManager(decoder: source)
        defer { manager.destroy() }
        try require(manager.registerAudioSession(), "Cannot create SDK audio graph")
        source.prepare(channels: Int(manager.numberOfChannels), rate: manager.samplingRate)
        let optional = try XCTUnwrap(Mirror(reflecting: manager).children.first { $0.label == "outputContext" }?.value)
        let context = try XCTUnwrap(Mirror(reflecting: optional).children.first?.value as? FTAudioOutputContext)
        let timePitch = try XCTUnwrap(context.timePitchNodeContext.audioUnit)
        manager.volume = 0
        manager.playbackRate = 8
        manager.play()
        pump(0.15)
        // Match the repeated stop/start of audio during paced high-rate seeks.
        for _ in 0..<17 { manager.pause(); manager.play(); pump(0.025) }
        manager.playbackRate = 1
        // Fault injection: leave the real native processor at the observed bad
        // throughput. This is not a reproduction of Apple's internal rate state.
        XCTAssertEqual(AudioUnitSetParameter(timePitch, kTimePitchParam_Rate,
            kAudioUnitScope_Global, 0, 3, 0), noErr)
        pump(0.25)
        func copiedFrames() -> Double {
            let fields = manager.rateDiagnosticFields(includeFormats: false)
            let render = fields["render"] as? [String: Any]
            return (render?["copiedFrames"] as? NSNumber)?.doubleValue ?? 0
        }
        let first = copiedFrames(), began = ProcessInfo.processInfo.systemUptime
        pump(1.5)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let consumed = copiedFrames() - first
        let measured = consumed / manager.samplingRate / elapsed
        let report: [String: Any] = ["injectedTimePitchRate": 3, "requestedRate": 1,
            "wallSeconds": elapsed, "copiedFrames": consumed, "observedPCMRate": measured,
            "audio": manager.rateDiagnosticFields(includeFormats: true)]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
            uniformTypeIdentifier: "public.json")
        attachment.name = "stale-timepitch-unity-consumption"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(measured, 1, accuracy: 0.15, "A stale TimePitch processor still controls 1x PCM consumption")
    }
}

private func progressSilentTimePitchInput(_ context: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32, _ frames: UInt32, _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    if let data {
        for buffer in UnsafeMutableAudioBufferListPointer(data) {
            if let samples = buffer.mData { memset(samples, 0, Int(buffer.mDataByteSize)) }
        }
    }
    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}

private final class AudioSessionContinuousSource: FTAudioFrameSource {
    private let frame = FTAudioFrame()
    private var signal: [Float] = []
    private var offset = 0
    func prepare(channels: Int, rate: Double) {
        frame.setSamplesLength(1024 * channels * MemoryLayout<Float>.size)
        frame.duration = 1024 / rate
        signal = [Float](repeating: 0, count: (Int(rate * 16) + 1024) * channels)
        for i in 0..<(signal.count / channels) {
            // 997 Hz is deliberately not periodic at 128/256/512/1024 sample
            // callback boundaries, so repeated blocks cannot hide in the tone.
            let value = Float(0.25 * sin(2 * .pi * 997 * Double(i) / rate))
            for channel in 0..<channels { signal[i * channels + channel] = value }
        }
    }
    func fetchAudioFrame() -> FTAudioFrame? {
        let count = frame.size / MemoryLayout<Float>.size
        guard offset + count <= signal.count else { return nil }
        signal.withUnsafeBufferPointer { memcpy(frame.samples!, $0.baseAddress! + offset, frame.size) }
        offset += count; frame.outputOffset = 0; return frame
    }
}

private final class AudioSessionPCMCapture {
    let channels: Int, capacity: Int
    let samples: UnsafeMutablePointer<Float>
    private let blocks: UnsafeMutablePointer<(offset: Int, frames: Int, wall: Double)>
    private var blockCount = 0, frames = 0
    private(set) var errors = 0, overflows = 0
    init(channels: Int, capacity: Int) {
        self.channels = channels; self.capacity = capacity
        samples = .allocate(capacity: capacity * channels)
        blocks = .allocate(capacity: 65536)
    }
    deinit { samples.deallocate(); blocks.deallocate() }
    func capture(_ count: UInt32, data: UnsafeMutablePointer<AudioBufferList>) {
        guard frames + Int(count) <= capacity, blockCount < 65536 else { overflows += 1; return }
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        var channelOffset = 0
        for buffer in buffers {
            let channelCount = Int(buffer.mNumberChannels)
            guard let values = buffer.mData?.assumingMemoryBound(to: Float.self), channelOffset + channelCount <= channels,
                Int(buffer.mDataByteSize) >= Int(count) * channelCount * MemoryLayout<Float>.size else { errors += 1; return }
            for i in 0..<Int(count) {
                for channel in 0..<channelCount { samples[(frames + i) * channels + channelOffset + channel] = values[i * channelCount + channel] }
            }
            channelOffset += channelCount
        }
        if channelOffset != channels { errors += 1; return }
        blocks[blockCount] = (frames, Int(count), ProcessInfo.processInfo.systemUptime)
        blockCount += 1; frames += Int(count)
    }
    func renderError() { errors += 1 }
    /// Called only after stopping/draining the audio graph.
    func exportPCM(to url: URL) throws -> Int {
        try Data(bytes: samples, count: frames * channels * MemoryLayout<Float>.size).write(to: url)
        return frames
    }
    func measure(from start: Double, to end: Double, rate: Double) -> [String: Double] {
        var squareSum = 0.0, count = 0, peak = 0.0, maximumStep = 0.0, longestZeroRun = 0
        var zeroRun = [Int](repeating: 0, count: channels), previous = [Double?](repeating: nil, count: channels)
        var previousTwo = [Double?](repeating: nil, count: channels), maximumPredictionError = 0.0
        let coefficient = 2 * cos(2 * .pi * 997 / rate)
        var previousWall: Double?, maximumGap = 0.0
        for i in 0..<blockCount {
            let block = blocks[i]
            guard block.wall >= start && block.wall < end else { continue }
            if let previousWall { maximumGap = max(maximumGap, block.wall - previousWall) }
            previousWall = block.wall
            for frame in block.offset..<(block.offset + block.frames) {
                for channel in 0..<channels {
                    let value = Double(samples[frame * channels + channel])
                    squareSum += value * value; peak = max(peak, abs(value)); count += 1
                    if let prior = previous[channel] { maximumStep = max(maximumStep, abs(value - prior)) }
                    if let prior = previous[channel], let second = previousTwo[channel] {
                        maximumPredictionError = max(maximumPredictionError, abs(value - coefficient * prior + second))
                    }
                    previousTwo[channel] = previous[channel]
                    previous[channel] = value
                    zeroRun[channel] = abs(value) < 0.000001 ? zeroRun[channel] + 1 : 0
                    longestZeroRun = max(longestZeroRun, zeroRun[channel])
                }
            }
        }
        return ["frames": Double(count / channels), "rms": count > 0 ? sqrt(squareSum / Double(count)) : 0,
            "peak": peak, "maxSampleStep": maximumStep, "longestZeroRun": Double(longestZeroRun),
            "maxPredictionError": maximumPredictionError,
            "maximumCallbackGap": maximumGap]
    }
}

private func audioSessionCaptureCallback(_ context: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32, _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let tap = Unmanaged<AudioSessionPCMCapture>.fromOpaque(context).takeUnretainedValue()
    if flags.pointee.contains(.unitRenderAction_PostRenderError) { tap.renderError() }
    if flags.pointee.contains(.unitRenderAction_PostRender), let data { tap.capture(frames, data: data) }
    return noErr
}

/// A second real RemoteIO unit models the foreign owner's output lifecycle. It
/// does not emulate WebRTC's DSP, network, ADM, microphone or VoiceProcessingIO.
private final class AudioSessionForeignOutput {
    private let unit: AUAudioUnit
    init(rate: Double) throws {
        unit = try AUAudioUnit(componentDescription: AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
        unit.isInputEnabled = false; unit.isOutputEnabled = true
        try unit.inputBusses[0].setFormat(try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: rate, channels: 2, interleaved: true)))
        unit.outputProvider = { flags, _, _, _, data in
            for buffer in UnsafeMutableAudioBufferListPointer(data) {
                if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
            }
            flags.pointee.insert(.unitRenderAction_OutputIsSilence)
            return noErr
        }
        try unit.allocateRenderResources(); try unit.startHardware()
    }
    func stop() { unit.stopHardware(); unit.deallocateRenderResources() }
    deinit { stop() }
}

/// Opt-in recording test: no private URL or media is checked into Git.
final class FTPlayerPrivateAudioSessionTests: PlaybackTestCase {
    @objc func testPrivateURLWithExactAudioPreferences() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let manifest = documents.appendingPathComponent("FTPlayerAudioPreferenceInput.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw XCTSkip("Install FTPlayerAudioPreferenceInput.json with a url in app Documents") }
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        let url = try XCTUnwrap((input?["url"] as? String).flatMap(URL.init(string:)))
        let session = AVAudioSession.sharedInstance()
        let saved = (session.category, session.mode, session.categoryOptions, session.preferredSampleRate, session.preferredIOBufferDuration)
        defer {
            try? session.setActive(false)
            try? session.setCategory(saved.0, mode: saved.1, options: saved.2)
            if saved.3 > 0 { try? session.setPreferredSampleRate(saved.3) }
            if saved.4 > 0 { try? session.setPreferredIOBufferDuration(saved.4) }
        }
        func snapshot() -> [String: Any] {
            ["wall": ProcessInfo.processInfo.systemUptime, "category": session.category.rawValue,
                "mode": session.mode.rawValue, "rate": session.sampleRate, "preferredRate": session.preferredSampleRate,
                "buffer": session.ioBufferDuration, "preferredBuffer": session.preferredIOBufferDuration]
        }
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
        let before = snapshot()
        // Requested reproduction: call both lines, then play the supplied URL.
        try session.setPreferredIOBufferDuration(0.005)
        try session.setPreferredSampleRate(session.sampleRate)
        let after = snapshot()
        let factory = AudioPreferenceRecordingFactory()
        let player = FTPlayer(contentURL: url, components: factory)
        player.backgroundMode = .continuing; player.useCache = true
        player.isMuted = false; player.volume = 1; player.rate = 1
        let sink = PixelSink(); attachVideoSink(sink, to: player)
        defer { factory.stopCapture(); player.stop() }
        player.replaceVideo()
        XCTAssertNil(factory.captureError)
        try require(until(45) { player.state == .playing || player.state == .failed }, "Private URL did not start")
        try require(player.state != .failed, "Private URL failed to open")
        let manager = try XCTUnwrap(factory.manager), source = try XCTUnwrap(factory.source)
        let rate = manager.samplingRate, channels = Int(manager.numberOfChannels)
        // Capture was installed by the factory before decoder.open(). Do not
        // seek or restart audio: include the very first playback buffers.
        let reachedMinute = until(90) { player.currentTime >= 61 || player.state == .failed || player.state == .finished }
        factory.stopCapture()
        var stages: [[String: Any]] = []
        for (index, tap) in factory.taps.enumerated() {
            let label = ["converter", "mixer"][index]
            let frames = try tap.exportPCM(to: documents.appendingPathComponent("FTPlayerExactPreferences-\(label).f32"))
            stages.append(["stage": label, "frames": frames, "renderErrors": tap.errors, "overflow": tap.overflows])
            XCTAssertGreaterThan(frames, Int(rate * 60))
            XCTAssertEqual(tap.errors + tap.overflows, 0)
        }
        let report: [String: Any] = ["beforeCalls": before, "afterCalls": after, "finalSession": snapshot(),
            "graphRate": rate, "channels": channels, "captureStart": factory.captureStart, "target": 0, "stages": stages,
            "state": String(describing: player.state), "videoFrames": sink.frames,
            "mixerGain": manager.volume, "unitRate": manager.playbackRate,
            "audioFetches": source.fetches, "decoder": player.decoder?.diagnosticSnapshot ?? "none"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: documents.appendingPathComponent("FTPlayerExactPreferences-report.json"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "private-recording-exact-preferences"; attachment.lifetime = .keepAlways; add(attachment)
        print("PRIVATE_AUDIO_PREFERENCES_RESULT \(String(decoding: data, as: UTF8.self))")
        XCTAssertEqual(player.state, .playing)
        XCTAssertTrue(reachedMinute)
        XCTAssertGreaterThanOrEqual(player.currentTime, 60)
        XCTAssertEqual(factory.taps.count, 2)
        let audibleFrames = source.fetches.filter { ($0["bytes"] as? Int ?? 0) > 0 }
        XCTAssertLessThanOrEqual(audibleFrames.first?["pts"] as? Double ?? .infinity, 0.13, "Capture missed the start of the source")
        XCTAssertGreaterThanOrEqual(audibleFrames.last?["pts"] as? Double ?? -1, 60, "Capture did not cover the first minute")
        XCTAssertGreaterThan(sink.frames, 20)
        XCTAssertEqual(manager.volume, 1, accuracy: 0.001)
        XCTAssertEqual(manager.playbackRate, 1, accuracy: 0.001)
    }
}

private final class AudioPreferenceRecordingSource: FTAudioFrameSource {
    let source: any FTAudioFrameSource
    private var capturing = false
    private var events: [(wall: Double, pts: Double, bytes: Int, buffering: Bool, seeking: Bool)] = []
    var fetches: [[String: Any]] {
        events.map { ["wall": $0.wall, "pts": $0.pts, "bytes": $0.bytes, "buffering": $0.buffering, "seeking": $0.seeking] }
    }
    init(_ source: any FTAudioFrameSource) { self.source = source; events.reserveCapacity(2048) }
    func beginCapture() { capturing = true }
    func fetchAudioFrame() -> FTAudioFrame? {
        let frame = source.fetchAudioFrame()
        if capturing, events.count < 2048 {
            let decoder = source as? FTDecoder
            events.append((ProcessInfo.processInfo.systemUptime, frame?.position ?? -1,
                frame.map { $0.size - $0.outputOffset } ?? 0, decoder?.buffering ?? false, decoder?.seeking ?? false))
        }
        return frame
    }
}

private final class AudioPreferenceRecordingFactory: PlaybackComponentFactory {
    var manager: FTAudioManager?, source: AudioPreferenceRecordingSource?
    private(set) var taps: [AudioSessionPCMCapture] = []
    private var units: [AudioUnit] = []
    private(set) var captureStart: Double = 0
    private(set) var captureError: String?
    func makeDecoder(contentURL: URL, videoFormat: FTVideoFormat, videoOutput: FTDecoderVideoOutput,
        audioOutput: FTDecoderAudioOutput) -> any PlaybackEngine {
        DefaultPlaybackComponentFactory().makeDecoder(contentURL: contentURL, videoFormat: videoFormat,
            videoOutput: videoOutput, audioOutput: audioOutput)
    }
    func makeAudioOutput(source: any FTAudioFrameSource) -> any PlaybackAudioOutput {
        let proxy = AudioPreferenceRecordingSource(source); self.source = proxy
        let manager = FTAudioManager(decoder: proxy); self.manager = manager
        // Registration here is idempotent with facade.setupAudio(). It gives
        // the test access to the graph before any playback starts.
        guard manager.registerAudioSession(),
            let optional = Mirror(reflecting: manager).children.first(where: { $0.label == "outputContext" })?.value,
            let context = Mirror(reflecting: optional).children.first?.value as? FTAudioOutputContext,
            let converter = context.converterNodeContext.audioUnit, let mixer = context.mixerNodeContext.audioUnit else {
            captureError = "Unable to install capture before audio starts"; return manager
        }
        units = [converter, mixer]
        taps = units.map { _ in AudioSessionPCMCapture(channels: Int(manager.numberOfChannels), capacity: Int(manager.samplingRate * 90)) }
        captureStart = ProcessInfo.processInfo.systemUptime
        for (unit, tap) in zip(units, taps) {
            let result = AudioUnitAddRenderNotify(unit, audioSessionCaptureCallback, Unmanaged.passUnretained(tap).toOpaque())
            if result != noErr { captureError = "AudioUnitAddRenderNotify failed: \(result)" }
        }
        proxy.beginCapture()
        return manager
    }
    func stopCapture() {
        manager?.pause()
        for (unit, tap) in zip(units, taps) {
            AudioUnitRemoveRenderNotify(unit, audioSessionCaptureCallback, Unmanaged.passUnretained(tap).toOpaque())
        }
        units.removeAll()
    }
    func makeCacheSession() throws -> any PlaybackCacheSession { try FTPlaybackCacheSession() }
}
