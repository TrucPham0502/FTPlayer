//
//  FTAudioManager.swift
//  
//
//  Edited by TP on 2024/7/26.
//

import Foundation
import AVFoundation
import Accelerate

enum FTAudioManagerInterruptionType: UInt {
    case begin
    case ended
}

enum FTAudioManagerInterruptionOption: UInt {
    case none
    case shouldResume
}

enum FTAudioManagerRouteChangeReason: UInt {
    case oldDeviceUnavailable
}

class FTAudioManager: NSObject {

    private let decoder: any FTAudioFrameSource
    private var currentAudioFrame: FTAudioFrame?
    private var _outData: UnsafeMutablePointer<Float>?
    private var outputContext: FTAudioOutputContext?

    private var interruptionHandler: ((FTAudioManagerInterruptionType, FTAudioManagerInterruptionOption) -> Void)?
    private var routeChangeHandler: ((FTAudioManagerRouteChangeReason) -> Void)?

    private let lifecycleLock = NSRecursiveLock()
    private var destroyed = false
    private var registered = false
    private var configuredRate: Float = 1
    private var timePitchBypassed = true
    private let diagnosticID = UUID().uuidString
    private let renderCounters = AudioRateRenderCounters()

    #if os(macOS)
    private var audioSession = FTMacAudioSession.shared
    #else
    private var audioSession = AVAudioSession.sharedInstance()
    #endif

    private var error: NSError?
    private var warning: NSError?

    @Atomic private var _playing = false

    // MARK: - Properties

    var volume: Float {
        get {
            lifecycleLock.lock(); defer { lifecycleLock.unlock() }
            guard registered,
                  let audioUnit = outputContext?.mixerNodeContext.audioUnit else { return 1.0 }
            var volume: AudioUnitParameterValue = 1.0
            let param: AudioUnitParameterID = kMultiChannelMixerParam_Volume
            let result = AudioUnitGetParameter(audioUnit,
                                               param,
                                               kAudioUnitScope_Input,
                                               0,
                                               &volume)
            warning = checkError(result, domain: "graph get mixer volume error")
            if warning != nil {
                delegateWarningCallback()
            }
            return volume
        }
        set {
            lifecycleLock.lock(); defer { lifecycleLock.unlock() }
            guard registered,
                  let audioUnit = outputContext?.mixerNodeContext.audioUnit else { return }
            let param: AudioUnitParameterID = kMultiChannelMixerParam_Volume
            let result = AudioUnitSetParameter(audioUnit,
                                               param,
                                               kAudioUnitScope_Input,
                                               0,
                                               newValue,
                                               0)
            warning = checkError(result, domain: "graph set mixer volume error")
            if warning != nil {
                delegateWarningCallback()
            }
        }
    }

    var playbackRate: Float {
        get {
            lifecycleLock.lock(); defer { lifecycleLock.unlock() }
            guard registered, let audioUnit = outputContext?.timePitchNodeContext.audioUnit else { return 1.0 }
            var rate: AudioUnitParameterValue = 1.0
            AudioUnitGetParameter(audioUnit, kTimePitchParam_Rate, kAudioUnitScope_Global, 0, &rate)
            return Float(rate)
        }
        set {
            lifecycleLock.lock(); defer { lifecycleLock.unlock() }
            guard registered, let audioUnit = outputContext?.timePitchNodeContext.audioUnit else {
                FTPlayerDiagnostic.shared.record("info", "rate", "audio rate not applied", fields: [
                    "audioOutput": diagnosticID, "requestedRate": newValue, "registered": registered, "destroyed": destroyed
                ])
                return
            }
            let changesRate = newValue != configuredRate
            let resumeAfterChange = changesRate && _playing
            // A parameter readback does not describe TimePitch's buffered render
            // state. Drain before resetting/reconnecting any native processors.
            if resumeAfterChange { pause() }
            defer { if resumeAfterChange { play() } }
            // NewTimePitch hỗ trợ rate từ 1/32 đến 32.0
            let result = AudioUnitSetParameter(audioUnit, kTimePitchParam_Rate, kAudioUnitScope_Global, 0, newValue, 0)
            if result == noErr, changesRate, let context = outputContext {
                let routeStatus = configureTimePitchRoute(context, bypass: newValue == 1)
                if routeStatus == noErr {
                    configuredRate = newValue
                    resetProcessingNodes(context, reason: "rate change")
                } else {
                    // Keep a usable previous route if a native connection fails.
                    let restoreStatus = configureTimePitchRoute(context, bypass: configuredRate == 1)
                    AudioUnitSetParameter(audioUnit, kTimePitchParam_Rate, kAudioUnitScope_Global, 0, configuredRate, 0)
                    FTPlayerDiagnostic.shared.record("error", "rate", "audio route change failed", fields: [
                        "audioOutput": diagnosticID, "status": routeStatus, "restoreStatus": restoreStatus,
                        "requestedRate": newValue, "configuredRate": configuredRate
                    ])
                }
            }
            var applied: AudioUnitParameterValue = 0
            let readStatus = AudioUnitGetParameter(audioUnit, kTimePitchParam_Rate, kAudioUnitScope_Global, 0, &applied)
            FTPlayerDiagnostic.shared.record("info", "rate", "audio rate applied", fields: [
                "audioOutput": diagnosticID, "requestedRate": newValue, "setStatus": result,
                "readStatus": readStatus, "actualRate": readStatus == noErr ? applied as Any : NSNull(),
                "configuredRate": configuredRate, "timePitchBypassed": timePitchBypassed,
                "audioUnit": String(describing: audioUnit)
            ])
            warning = checkError(result, domain: "graph set playback rate error")
            if warning != nil {
                delegateWarningCallback()
            }
        }
    }

    var playing: Bool {
        return _playing
    }

    func rateDiagnosticFields(includeFormats: Bool) -> [String: Any] {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        var fields: [String: Any] = ["audioOutput": diagnosticID, "registered": registered,
            "destroyed": destroyed, "playing": _playing,
            "configuredRate": configuredRate, "timePitchBypassed": timePitchBypassed,
            "graphSampleRate": outputContext?.commonFormat.mSampleRate ?? 0,
            "graphChannels": outputContext?.commonFormat.mChannelsPerFrame ?? 0,
            "outputFloatCapacity": FTAudioManager.maxFrameSize * FTAudioManager.maxChan,
            "sessionSampleRate": audioSession.sampleRate, "render": renderCounters.snapshot()]
        #if os(iOS)
        fields["ioBufferDuration"] = audioSession.ioBufferDuration
        fields["outputLatency"] = audioSession.outputLatency
        fields["audioCategory"] = audioSession.category.rawValue
        fields["audioMode"] = audioSession.mode.rawValue
        fields["outputPorts"] = audioSession.currentRoute.outputs.map { $0.portType.rawValue }
        #endif
        guard registered, let context = outputContext, let unit = context.timePitchNodeContext.audioUnit else {
            fields["actualRate"] = NSNull(); fields["rateAvailable"] = false; return fields
        }
        var value: AudioUnitParameterValue = 0
        let status = AudioUnitGetParameter(unit, kTimePitchParam_Rate, kAudioUnitScope_Global, 0, &value)
        fields["audioUnit"] = String(describing: unit)
        fields["readStatus"] = status; fields["rateAvailable"] = status == noErr
        fields["actualRate"] = status == noErr ? value as Any : NSNull()
        if let graph = context.graph {
            var running = DarwinBoolean(false), initialized = DarwinBoolean(false)
            let runningStatus = AUGraphIsRunning(graph, &running)
            let initializedStatus = AUGraphIsInitialized(graph, &initialized)
            fields["graphRunningStatus"] = runningStatus
            fields["graphRunning"] = runningStatus == noErr ? running.boolValue as Any : NSNull()
            fields["graphInitializedStatus"] = initializedStatus
            fields["graphInitialized"] = initializedStatus == noErr ? initialized.boolValue as Any : NSNull()
        }
        if includeFormats {
            var formats: [String: Any] = [:]
            var renderErrors: [String: Any] = [:]
            for (name, node) in [("converter", context.converterNodeContext), ("timePitch", context.timePitchNodeContext),
                                 ("mixer", context.mixerNodeContext), ("output", context.outputNodeContext)] {
                guard let audioUnit = node.audioUnit else { continue }
                var renderError: OSStatus = noErr, errorSize = UInt32(MemoryLayout<OSStatus>.size)
                let errorStatus = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_LastRenderError,
                    kAudioUnitScope_Global, 0, &renderError, &errorSize)
                renderErrors[name] = ["readStatus": errorStatus,
                    "error": errorStatus == noErr ? renderError as Any : NSNull()]
                for (scopeName, scope) in [("input", kAudioUnitScope_Input), ("output", kAudioUnitScope_Output)] {
                    var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                    let result = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, scope, 0, &format, &size)
                    formats["\(name).\(scopeName)"] = ["status": result, "sampleRate": format.mSampleRate,
                        "channels": format.mChannelsPerFrame, "bytesPerFrame": format.mBytesPerFrame,
                        "bitsPerChannel": format.mBitsPerChannel, "flags": format.mFormatFlags, "formatID": format.mFormatID]
                }
                var maximum: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
                let result = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                    kAudioUnitScope_Global, 0, &maximum, &size)
                formats["\(name).maximumFrames"] = ["status": result, "frames": maximum]
            }
            fields["nodeFormats"] = formats
            fields["nodeRenderErrors"] = renderErrors
            if let mixer = context.mixerNodeContext.audioUnit {
                var enabled: AudioUnitParameterValue = 0, volume: AudioUnitParameterValue = 0
                let enableStatus = AudioUnitGetParameter(mixer, kMultiChannelMixerParam_Enable,
                    kAudioUnitScope_Input, 0, &enabled)
                let volumeStatus = AudioUnitGetParameter(mixer, kMultiChannelMixerParam_Volume,
                    kAudioUnitScope_Input, 0, &volume)
                fields["mixerInput"] = ["enableStatus": enableStatus,
                    "enabled": enableStatus == noErr ? enabled as Any : NSNull(),
                    "volumeStatus": volumeStatus,
                    "volume": volumeStatus == noErr ? volume as Any : NSNull()]
            }
        }
        return fields
    }

    var samplingRate: Float64 {
        let number = outputContext?.commonFormat.mSampleRate ?? 0
        return number > 0 ? number : Float64(audioSession.sampleRate)
    }

    var numberOfChannels: UInt32 {
        let number = outputContext?.commonFormat.mChannelsPerFrame ?? 0
        return number > 0 ? number : UInt32(audioSession.outputNumberOfChannels)
    }

    // MARK: - Init & Deinit

    init(decoder: any FTAudioFrameSource) {
        self.decoder = decoder
        super.init()
        _outData = UnsafeMutablePointer<Float>.allocate(capacity: FTAudioManager.maxFrameSize * FTAudioManager.maxChan)

        #if !os(macOS)
        NotificationCenter.default.addObserver(self, selector: #selector(audioSessionInterruptionHandler(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioSessionRouteChangeHandler(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        #endif
    }

    deinit {
        unregisterAudioSession()
        _outData?.deallocate()
        NotificationCenter.default.removeObserver(self)
    }

    func destroy() {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        destroyed = true
        unregisterAudioSession()
    }

    // MARK: - Handlers

    func setEventHandlers(interruption: @escaping (FTAudioManagerInterruptionType, FTAudioManagerInterruptionOption) -> Void,
                          routeChange: @escaping (FTAudioManagerRouteChangeReason) -> Void) {
        interruptionHandler = interruption
        routeChangeHandler = routeChange
    }

    @objc private func audioSessionInterruptionHandler(_ notification: Notification) {
        guard let interruptionHandler else { return }
        let avType = AVAudioSession.InterruptionType(rawValue: notification.userInfo?[AVAudioSessionInterruptionTypeKey] as! UInt)!
        let type: FTAudioManagerInterruptionType = (avType == .ended) ? .ended : .begin
        var option: FTAudioManagerInterruptionOption = .none
        if let avOption = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
            if avOption == AVAudioSession.InterruptionOptions.shouldResume.rawValue {
                option = .shouldResume
            }
        }
        interruptionHandler(type, option)
    }

    @objc private func audioSessionRouteChangeHandler(_ notification: Notification) {
        guard let routeChangeHandler else { return }
        let avReason = AVAudioSession.RouteChangeReason(rawValue: notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as! UInt)!
        if avReason == .oldDeviceUnavailable {
            routeChangeHandler(.oldDeviceUnavailable)
        }
    }

    // MARK: - Setup Audio Unit

    func registerAudioSession() -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard !destroyed else { return false }
        if !registered {
            if setupAudioUnit() {
                registered = true
            }
        }
        return registered
    }

    func unregisterAudioSession() {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        // AUGraphStop drains active rendering before mixer cleanup/free. Disposing
        // a running graph races AudioUnitRender and can crash inside the mixer.
        stop()
        if let graph = outputContext?.graph {
            var result = AUGraphUninitialize(graph)
            warning = checkError(result, domain: "graph uninitialize error")
            if warning != nil { delegateWarningCallback() }
            
            result = AUGraphClose(graph)
            warning = checkError(result, domain: "graph close error")
            if warning != nil { delegateWarningCallback() }
            
            result = DisposeAUGraph(graph)
            warning = checkError(result, domain: "graph dispose error")
            if warning != nil { delegateWarningCallback() }
            
            Console.log("Audio graph disposed status=\(result)")
        }
        outputContext = nil
        registered = false
    }

    private func setupAudioUnit() -> Bool {
        var result: OSStatus
        var outputContext = FTAudioOutputContext()
        defer {
            self.outputContext = outputContext
        }

        result = NewAUGraph(&outputContext.graph)
        error = checkError(result, domain: "create graph error")
        guard error == nil else {
            delegateErrorCallback()
            return false
        }

        // 1. Converter Node
        var converterDescription = AudioComponentDescription(componentType: kAudioUnitType_FormatConverter,
                                                             componentSubType: kAudioUnitSubType_AUConverter,
                                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                                             componentFlags: 0,
                                                             componentFlagsMask: 0)
        result = AUGraphAddNode(outputContext.graph!, &converterDescription, &outputContext.converterNodeContext.node)
        error = checkError(result, domain: "graph add converter node error")
        if error != nil { delegateErrorCallback(); return false }

        // 2. TimePitch Node (Xử lý tốc độ)
        var timePitchDescription = AudioComponentDescription(componentType: kAudioUnitType_FormatConverter,
                                                             componentSubType: kAudioUnitSubType_NewTimePitch,
                                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                                             componentFlags: 0,
                                                             componentFlagsMask: 0)
        result = AUGraphAddNode(outputContext.graph!, &timePitchDescription, &outputContext.timePitchNodeContext.node)
        error = checkError(result, domain: "graph add timepitch node error")
        if error != nil { delegateErrorCallback(); return false }

        // 3. Mixer Node
        var mixerDescription = AudioComponentDescription(componentType: kAudioUnitType_Mixer,
                                                         componentSubType: kAudioUnitSubType_MultiChannelMixer,
                                                         componentManufacturer: kAudioUnitManufacturer_Apple,
                                                         componentFlags: 0,
                                                         componentFlagsMask: 0)
        result = AUGraphAddNode(outputContext.graph!, &mixerDescription, &outputContext.mixerNodeContext.node)
        error = checkError(result, domain: "graph add mixer node error")
        if error != nil { delegateErrorCallback(); return false }

        // 4. Output Node
        var outputDescription = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                          componentSubType: kAudioUnitSubType_RemoteIO,
                                                          componentManufacturer: kAudioUnitManufacturer_Apple,
                                                          componentFlags: 0,
                                                          componentFlagsMask: 0)
        result = AUGraphAddNode(outputContext.graph!, &outputDescription, &outputContext.outputNodeContext.node)
        error = checkError(result, domain: "graph add output node error")
        if error != nil { delegateErrorCallback(); return false }

        result = AUGraphOpen(outputContext.graph!)
        error = checkError(result, domain: "open graph error")
        if error != nil { delegateErrorCallback(); return false }

        // At unity rate no time stretching is required. Keep TimePitch entirely
        // out of the pull chain so stale state cannot consume PCM faster than IO.
        configuredRate = 1
        timePitchBypassed = true
        result = AUGraphConnectNodeInput(outputContext.graph!, outputContext.converterNodeContext.node, 0, outputContext.mixerNodeContext.node, 0)
        error = checkError(result, domain: "graph connect converter and mixer error")
        if error != nil { delegateErrorCallback(); return false }

        result = AUGraphConnectNodeInput(outputContext.graph!, outputContext.mixerNodeContext.node, 0, outputContext.outputNodeContext.node, 0)
        error = checkError(result, domain: "graph connect mixer and output error")
        if error != nil { delegateErrorCallback(); return false }

        // --- Lấy thông tin AudioUnit ---

        AUGraphNodeInfo(outputContext.graph!, outputContext.converterNodeContext.node, nil, &outputContext.converterNodeContext.audioUnit)
        AUGraphNodeInfo(outputContext.graph!, outputContext.timePitchNodeContext.node, nil, &outputContext.timePitchNodeContext.audioUnit)
        AUGraphNodeInfo(outputContext.graph!, outputContext.mixerNodeContext.node, nil, &outputContext.mixerNodeContext.audioUnit)
        AUGraphNodeInfo(outputContext.graph!, outputContext.outputNodeContext.node, nil, &outputContext.outputNodeContext.audioUnit)

        // --- Thiết lập định dạng Stream ---

        var converterCallback = AURenderCallbackStruct(inputProc: renderCallback,
                                                       inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        result = AUGraphSetNodeInputCallback(outputContext.graph!, outputContext.converterNodeContext.node, 0, &converterCallback)
        
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        result = AudioUnitGetProperty(outputContext.outputNodeContext.audioUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputContext.commonFormat, &asbdSize)

        // Cập nhật Sample Rate từ session
        if audioSession.sampleRate != outputContext.commonFormat.mSampleRate {
            outputContext.commonFormat.mSampleRate = audioSession.sampleRate
            AudioUnitSetProperty(outputContext.outputNodeContext.audioUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputContext.commonFormat, asbdSize)
        }

        // Apply format cho tất cả các node trong chuỗi
        let nodes = [outputContext.converterNodeContext.audioUnit, outputContext.timePitchNodeContext.audioUnit, outputContext.mixerNodeContext.audioUnit]
        for unit in nodes {
            guard let au = unit else { continue }
            AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputContext.commonFormat, asbdSize)
            AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &outputContext.commonFormat, asbdSize)
        }

        // Set max frames
        AudioUnitSetProperty(outputContext.mixerNodeContext.audioUnit!, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &FTAudioManager.maxFrameSize, UInt32(MemoryLayout.size(ofValue: FTAudioManager.maxFrameSize)))

        result = AUGraphInitialize(outputContext.graph!)
        error = checkError(result, domain: "graph initialize error")
        if error != nil { delegateErrorCallback(); return false }

        return true
    }
    
    // MARK: - Playback Logic

    /// Only called with the graph stopped and lifecycleLock held.
    private func configureTimePitchRoute(_ context: FTAudioOutputContext, bypass: Bool) -> OSStatus {
        guard let graph = context.graph else { return kAudioUnitErr_Uninitialized }
        // Inspect actual connections so rollback can repair partial edits without
        // disconnecting a non-existent input (which CoreAudio logs as an error).
        var count: UInt32 = 0
        var status = AUGraphGetNumberOfInteractions(graph, &count)
        guard status == noErr else { return status }
        var connections: [AUNodeConnection] = []
        for index in 0..<count {
            var interaction = AUNodeInteraction()
            status = AUGraphGetInteractionInfo(graph, index, &interaction)
            guard status == noErr else { return status }
            if interaction.nodeInteractionType == kAUNodeInteraction_Connection {
                let connection = interaction.nodeInteraction.connection
                if connection.destNode == context.mixerNodeContext.node || connection.destNode == context.timePitchNodeContext.node {
                    connections.append(connection)
                }
            }
        }
        for connection in connections {
            status = AUGraphDisconnectNodeInput(graph, connection.destNode, connection.destInputNumber)
            guard status == noErr else { return status }
        }
        var result: OSStatus
        if bypass {
            result = AUGraphConnectNodeInput(graph, context.converterNodeContext.node, 0, context.mixerNodeContext.node, 0)
        } else {
            result = AUGraphConnectNodeInput(graph, context.converterNodeContext.node, 0, context.timePitchNodeContext.node, 0)
            if result == noErr {
                result = AUGraphConnectNodeInput(graph, context.timePitchNodeContext.node, 0, context.mixerNodeContext.node, 0)
            }
        }
        if result == noErr {
            // A nil out parameter commits synchronously. Rendering must not
            // restart with a pending edit to the old TimePitch path.
            result = AUGraphUpdate(graph, nil)
        }
        if result == noErr { timePitchBypassed = bypass }
        return result
    }

    private func resetProcessingNodes(_ context: FTAudioOutputContext, reason: String) {
        var statuses: [String: Any] = [:]
        for (name, node) in [("converter", context.converterNodeContext),
                             ("timePitch", context.timePitchNodeContext), ("mixer", context.mixerNodeContext)] {
            if let unit = node.audioUnit {
                statuses[name] = AudioUnitReset(unit, kAudioUnitScope_Global, 0)
            }
        }
        FTPlayerDiagnostic.shared.record("info", "rate", "audio render state reset", fields: [
            "audioOutput": diagnosticID, "reason": reason, "statuses": statuses,
            "configuredRate": configuredRate, "timePitchBypassed": timePitchBypassed
        ])
    }

    func performSeek(_ request: () -> Void) {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        let resumeAfterSeek = _playing
        if resumeAfterSeek { pause() }
        // The facade serializes this with target publication: no partially used
        // frame from the old timeline can survive into the new seek epoch.
        currentAudioFrame?.stopPlaying()
        currentAudioFrame = nil
        if let context = outputContext { resetProcessingNodes(context, reason: "seek") }
        request()
        if resumeAfterSeek { play() }
    }

    private func playout(_ outputData: UnsafeMutablePointer<Float>, numberOfFrames: UInt32, numberOfChannels: UInt32,
                         observation: inout AudioRateRenderObservation) {
        guard self.playing else {
            memset(outputData, 0, Int(numberOfFrames * numberOfChannels * UInt32(MemoryLayout<Float>.size)))
            return
        }

        var remainingFrames = numberOfFrames
        var currentOutputData = outputData

        while remainingFrames > 0 {
            if self.currentAudioFrame == nil {
                self.currentAudioFrame = self.decoder.fetchAudioFrame()
                if let frame = self.currentAudioFrame {
                    observation.fetches += 1
                    observation.fetchedFrames += max(0, frame.size - frame.outputOffset) / (max(1, Int(numberOfChannels)) * MemoryLayout<Float>.size)
                    observation.lastFetchedPTS = frame.position
                    observation.lastFetchedDuration = frame.duration
                    observation.lastFetchedBytes = max(0, frame.size - frame.outputOffset)
                } else { observation.nilFetches += 1 }
                self.currentAudioFrame?.startPlaying()
            }

            guard let currentAudioFrame = self.currentAudioFrame else {
                memset(currentOutputData, 0, Int(remainingFrames * numberOfChannels) * MemoryLayout<Float>.size)
                return
            }

            let bytes = UnsafeRawPointer(currentAudioFrame.samples!).advanced(by: Int(currentAudioFrame.outputOffset)).assumingMemoryBound(to: UInt8.self)
            let bytesLeft = currentAudioFrame.size - currentAudioFrame.outputOffset
            let frameSizeOf = Int(numberOfChannels) * MemoryLayout<Float>.size
            let bytesToCopy = min(Int(remainingFrames) * frameSizeOf, bytesLeft)
            let framesToCopy = bytesToCopy / frameSizeOf
            observation.copiedFrames += framesToCopy

            memcpy(currentOutputData, bytes, bytesToCopy)
            remainingFrames -= UInt32(framesToCopy)
            currentOutputData = currentOutputData.advanced(by: framesToCopy * Int(numberOfChannels))

            if bytesToCopy < bytesLeft {
                currentAudioFrame.outputOffset += bytesToCopy
            } else {
                currentAudioFrame.stopPlaying()
                self.currentAudioFrame = nil
            }
        }
    }

    func renderFrames(_ numberOfFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let began = ProcessInfo.processInfo.systemUptime
        renderCounters.enter(wallTime: began)
        var observation = AudioRateRenderObservation(requestedFrames: Int(numberOfFrames), channels: Int(numberOfChannels))
        defer {
            observation.seconds = ProcessInfo.processInfo.systemUptime - began
            renderCounters.record(observation, wallTime: began,
                floatCapacity: FTAudioManager.maxFrameSize * FTAudioManager.maxChan)
        }
        let ioBuffers = UnsafeMutableAudioBufferListPointer(ioData)

        for buffer in ioBuffers {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }

        if playing, let outData = _outData {
            self.playout(outData, numberOfFrames: numberOfFrames, numberOfChannels: numberOfChannels, observation: &observation)

            let numBytesPerSample = outputContext!.commonFormat.mBitsPerChannel / 8
            if numBytesPerSample == 4 {
                var zero: Float = 0.0
                var channelOffset = 0
                for buffer in ioBuffers {
                    let numChannels = buffer.mNumberChannels
                    for j in 0..<Int(numChannels) {
                        vDSP_vsadd(outData + channelOffset + j,
                                   vDSP_Stride(numberOfChannels),
                                   &zero,
                                   buffer.mData!.assumingMemoryBound(to: Float.self) + j,
                                   vDSP_Stride(numChannels),
                                   vDSP_Length(numberOfFrames))
                    }
                    channelOffset += Int(numChannels)
                }
            } else if numBytesPerSample == 2 {
                var scale: Float = Float(INT16_MAX)
                vDSP_vsmul(outData, 1, &scale, outData, 1, vDSP_Length(numberOfFrames * numberOfChannels))

                var channelOffset = 0
                for buffer in ioBuffers {
                    let numChannels = buffer.mNumberChannels
                    for j in 0..<Int(numChannels) {
                        vDSP_vfix16(outData + channelOffset + j,
                                    vDSP_Stride(numberOfChannels),
                                    buffer.mData!.assumingMemoryBound(to: Int16.self) + j,
                                    vDSP_Stride(numChannels),
                                    vDSP_Length(numberOfFrames))
                    }
                    channelOffset += Int(numChannels)
                }
            }
        }

        return noErr
    }

    func play() {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard !destroyed, !_playing,
              let graph = outputContext?.graph else { return }
        if registerAudioSession() {
            let result = AUGraphStart(graph)
            error = checkError(result, domain: "graph start error")
            if error != nil {
                delegateErrorCallback()
            } else {
                _playing = true
                FTPlayerDiagnostic.shared.record("info", "rate", "audio graph started", fields: rateDiagnosticFields(includeFormats: false))
            }
        }
    }

    func pause() {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard _playing,
              let graph = outputContext?.graph else { return }
        _playing = false
        let result = AUGraphStop(graph)
        FTPlayerDiagnostic.shared.record("info", "rate", "audio graph stopped", fields: [
            "audioOutput": diagnosticID, "status": result, "state": rateDiagnosticFields(includeFormats: false)
        ])
        error = checkError(result, domain: "graph stop error")
        if error != nil {
            delegateErrorCallback()
        }
        _playing = false
    }
    
    func stop() {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        pause()
        currentAudioFrame?.stopPlaying()
        currentAudioFrame = nil
    }

    private func delegateErrorCallback() {
        if let error = error { Console.log(type: .ERROR, "audio error domain=\(error.domain) code=\(error.code) details=\(error)") }
    }

    private func delegateWarningCallback() {
        if let warning = warning { Console.log(type: .ERROR, "audio warning=\(warning)") }
    }

    private func checkError(_ result: OSStatus, domain: String) -> NSError? {
        return result == noErr ? nil : NSError(domain: domain, code: Int(result), userInfo: nil)
    }

    private static var maxFrameSize = FTPlayerSDKConfiguration.Audio.maximumRenderFrames
    private static let maxChan = FTPlayerSDKConfiguration.Audio.maximumOutputChannels
}

private struct AudioRateRenderObservation {
    var requestedFrames: Int
    var channels: Int
    var copiedFrames = 0
    var fetches = 0
    var nilFetches = 0
    var fetchedFrames = 0
    var lastFetchedPTS: TimeInterval?
    var lastFetchedDuration: TimeInterval = 0
    var lastFetchedBytes = 0
    var seconds: TimeInterval = 0
}

/// Best-effort counters only: the render callback never waits for diagnostics,
/// allocates dictionaries, writes logs, or queries AudioUnit properties.
private final class AudioRateRenderCounters {
    private let lock = NSLock()
    private var entered: Int64 = 0
    private var lastEnteredWall: TimeInterval = 0
    private var calls: Int64 = 0, requested: Int64 = 0, copied: Int64 = 0, fetched: Int64 = 0
    private var fetches: Int64 = 0, nilFetches: Int64 = 0, oversized: Int64 = 0
    private var maximumRequest = 0
    private var maximumSeconds: TimeInterval = 0, totalSeconds: TimeInterval = 0, lastWall: TimeInterval = 0
    private var lastPTS: TimeInterval?, lastDuration: TimeInterval = 0, lastBytes = 0
    func enter(wallTime: TimeInterval) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        entered += 1
        lastEnteredWall = wallTime
    }
    func record(_ observation: AudioRateRenderObservation, wallTime: TimeInterval, floatCapacity: Int) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        calls += 1; requested += Int64(observation.requestedFrames); copied += Int64(observation.copiedFrames)
        fetched += Int64(observation.fetchedFrames); fetches += Int64(observation.fetches); nilFetches += Int64(observation.nilFetches)
        maximumRequest = max(maximumRequest, observation.requestedFrames)
        if observation.requestedFrames * observation.channels > floatCapacity { oversized += 1 }
        maximumSeconds = max(maximumSeconds, observation.seconds); totalSeconds += observation.seconds; lastWall = wallTime
        if let pts = observation.lastFetchedPTS {
            lastPTS = pts; lastDuration = observation.lastFetchedDuration; lastBytes = observation.lastFetchedBytes
        }
    }
    func snapshot() -> [String: Any] {
        lock.lock()
        let values: (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int, Double, Double, Double, Double?, Double, Int) =
            (calls, requested, copied, fetched, fetches, nilFetches, oversized, maximumRequest,
             maximumSeconds, totalSeconds, lastWall, lastPTS, lastDuration, lastBytes)
        let entries = entered, lastEntry = lastEnteredWall
        lock.unlock()
        return ["bestEffort": true, "enteredCallbacks": entries, "lastEnteredWallTime": lastEntry,
            "callbacks": values.0, "requestedFrames": values.1, "copiedFrames": values.2,
            "fetchedFrames": values.3, "fetches": values.4, "nilFetches": values.5, "overCapacityRequests": values.6,
            "maximumRequestedFrames": values.7, "maximumCallbackSeconds": values.8, "totalCallbackSeconds": values.9,
            "lastCallbackWallTime": values.10, "lastFetchedPTS": values.11 as Any? ?? NSNull(),
            "lastFetchedDuration": values.12, "lastFetchedBytes": values.13]
    }
}

// MARK: - Helpers & Structs




private func renderCallback(inRefCon: UnsafeMutableRawPointer, ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp: UnsafePointer<AudioTimeStamp>, inOutputBusNumber: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let audioManager = Unmanaged<FTAudioManager>.fromOpaque(inRefCon).takeUnretainedValue()
    return audioManager.renderFrames(inNumberFrames, ioData: ioData!)
}
