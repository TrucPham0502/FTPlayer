import Foundation

/// Build-time defaults shared by the entire SDK. Change tuning values here.
/// Values are immutable so playback, decode, cache and audio workers always agree.
/// Existing per-player controls and loadControlConfiguration still override defaults.
/// Protocol/codec constants, unit conversions and zero/one state values stay at use sites.
public enum FTPlayerSDKConfiguration {
    enum Playback {
        static let defaultRate: Float = 1
        static let minimumRate: Float = 0.25
        static let maximumRate: Float = 16
        static let defaultVolume: Float = 1
        static let mutedByDefault = false
        static let cacheEnabledByDefault = false
        static let decodingPolicy: FTVideoDecodingPolicy = .automatic
        static let startupWallBuffer: TimeInterval = 2
        static let maximumStartupMediaBuffer: TimeInterval = 10
        static let postSeekMediaBuffer: TimeInterval = 0.5
        static let rebufferMediaThreshold: TimeInterval = 0.2
        static let bufferingTimeout: TimeInterval = 30
        static let openTimeoutSeconds = 30
        static let packetBufferBytes = 8 * 1024 * 1024
        static let progressNotificationInterval: TimeInterval = 1.0 / 30
        static let bufferNotificationInterval: TimeInterval = 1.0 / 30
        /// Minimum spacing between checks for each video statistics callback: wall-clock seconds
        /// at 1× or slower, divided by the rate above 1× so a check covers the same media time.
        static let videoStatisticsNotificationInterval: TimeInterval = 0.5
        /// Media seconds after the last output frame covered by `upcomingTimelineFramesPerSecond`.
        static let upcomingFrameRateWindow: TimeInterval = 3
        static let cachePositionInterval: TimeInterval = 0.25
        static let cachePositionMediaStep: TimeInterval = 0.25
        static let seekReadPollInterval: TimeInterval = 0.05
        static let fullPacketQueuePollInterval: TimeInterval = 0.1
        static let pausedPacketQueuePollInterval: TimeInterval = 0.5
        static let readFailureRetryInterval: TimeInterval = 1
        static let maximumVideoWorkPerTick = 240
        static let maximumAudioPrerollFramesPerCallback = 512
        static let rateRecoveryThreshold: Float = 8
        static let rateRecoverySeekGap: TimeInterval = 0.5
        static let audioRateChangeGrace: TimeInterval = 1
        static let audioRateChangeGraceMultiplier = 2.0
        static let videoRateChangeGrace: TimeInterval = 0.5
        static let videoRateChangeGraceMultiplier = 1.5
        static let firstVideoGrace: TimeInterval = 0.5
        static let firstVideoGraceMultiplier = 3.0
        static let postSeekAudioAdvance: TimeInterval = 0.1
        static let postSeekDropThreshold: TimeInterval = 0.5
        static let postSeekDropRateDivisor = 4.0
        static let earlyFrameDurationFraction = 0.5
        static let videoDropToleranceFrames = 6.0
        static let fallbackVideoFPS = 24.0
        static let audioCatchUpLead: TimeInterval = 0.2
        static let driftCheckInterval: TimeInterval = 2
        static let acceptableAVDrift: TimeInterval = 0.1
        static let moderateAVDrift: TimeInterval = 0.5
        static let acceptableDriftGrowth: TimeInterval = 0.03
        static let driftGrace: TimeInterval = 2
        static let driftGraceMultiplier = 1.5
        static let minimumAudioGap: TimeInterval = 0.1
        static let audioGapDurationMultiplier = 2.0
        static let audioClockCorrectionFraction = 0.05
        static let networkVideoEndTolerance: TimeInterval = 0.1
        static let networkVideoStarvationDelay: TimeInterval = 0.15
        static let finishTolerance: TimeInterval = 0.02
        static let foregroundResumeDebounce: TimeInterval = 1.5
    }

    enum Precision {
        static let timestampEpsilon: TimeInterval = 0.000001
        static let sampleRoundingEpsilon = 0.000001
        static let seekPrerollTolerance: TimeInterval = 0.05
        static let seekEndMargin: TimeInterval = 0.05
        static let cacheRangeMergeTolerance: TimeInterval = 0.0001
        static let hlsRangeMergeTolerance: TimeInterval = 0.001
    }

    /// Public because these values also appear in public initializer defaults.
    public enum LoadControl {
        public static let minimumBufferDuration: TimeInterval = 50
        public static let maximumBufferDuration: TimeInterval = 50
        public static let prioritizesTimeOverSize = false
        static let minimumAllowedBufferDuration: TimeInterval = 0.5
        static let videoTargetBytes: Int64 = 131_072_000
        static let audioTargetBytes: Int64 = 13_107_200
    }

    enum Video {
        static let decodedQueueDuration: TimeInterval = 2
        static let frameQueueDuration: TimeInterval = 1
        static let frameQueueSleepDivisor = 2.0
        static let pausedFrameQueueSleepDivisor = 1.1
        static let videoFramePoolCapacity = 60
        static let audioFramePoolCapacity = 500
        static let nonreferenceDiscardRate: Float = 2
        static let samplingRateThreshold: Float = 4
        static let sampledOutputFPS = 60.0
        static let timestampProbePackets = 16
        static let minimumCatchUpLag: TimeInterval = 0.5
        static let catchUpLagWallTime: TimeInterval = 0.1
        static let catchUpPastAnchorWallTime: TimeInterval = 0.5
        static let catchUpFutureAnchorWallTime: TimeInterval = 0.1
        static let pausedDecodePollInterval: TimeInterval = 0.01
        static let fullQueueSleep: TimeInterval = 0.1
        static let pausedFullQueueSleep: TimeInterval = 0.5
        static let minimumFullQueueSleep: TimeInterval = 0.001
        static let fullQueueWallTimeDivisor = 4.0
        static let packetWaitTimeout: TimeInterval = 0.1
        static let minimumHardwareFrameDuration: TimeInterval = 0.0001
        static let h264RecoveryAttempts = 3
        static let h264RecoveryPacketLimit = 1000
        static let h264SkippedFrameLogInterval = 1000
        static let hevcErrorFallbackThreshold = 3
        static let hevcLeadingPictureLimit = 16
    }

    enum Audio {
        static let maximumRenderFrames = 4096
        static let maximumOutputChannels = 2
        static let resamplerCapacityMultiplier: Int32 = 2
        static let desktopOutputLatency: TimeInterval = 0.01
        static let desktopIOBufferDuration: TimeInterval = 0.01
        // Measured estimates, in seconds, for each exclusive upper rate bound.
        static let timePitchLatencyBelow2: (upperBound: Float, seconds: TimeInterval) = (2, 0)
        static let timePitchLatencyBelow4: (upperBound: Float, seconds: TimeInterval) = (4, 0.02)
        static let timePitchLatencyBelow8: (upperBound: Float, seconds: TimeInterval) = (8, 0.08)
        static let timePitchLatencyBelow12: (upperBound: Float, seconds: TimeInterval) = (12, 0.2)
        static let timePitchLatencyBelow16: (upperBound: Float, seconds: TimeInterval) = (16, 0.3)
        static let maximumTimePitchLatency: TimeInterval = 0.4
    }

    enum Network {
        static let readTimeout: TimeInterval = 30
        static let minimumReadTimeout: TimeInterval = 0.01
        static let minimumOpeningTimeout: TimeInterval = 0.001
        static let metadataProbeTimeout: TimeInterval = 15
        static let maximumProbeConnectionsPerHost = 4
        static let interruptPollInterval: TimeInterval = 0.05
        static let idleReconnectTimeout: TimeInterval = 10
        static let retryDelay: TimeInterval = 2
        static let sizeProbeTimeout: TimeInterval = 30
        static let rtspTransport = "tcp"
        static let ffmpegRecoveryOptions: [(key: String, value: String)] = [
            ("reconnect", "1"), ("reconnect_on_network_error", "1"),
            ("reconnect_delay_max", "2"), ("reconnect_max_retries", "2"),
            ("reconnect_delay_total_max", "5")
        ]
    }

    enum Cache {
        static let requestChunkBytes: Int64 = 4 * 1024 * 1024
        static let minimumReadAheadBytes: Int64 = 32 * 1024
        static let baseReadAheadBytes = 8 * 1024 * 1024
        static let maximumReadAheadRateMultiplier = 8.0
        static let bootstrapBytes: Int64 = 256 * 1024
        static let progressFractionStep = 0.005
        static let playableRangeTolerance: TimeInterval = 0.05
        static let ringBufferCapacity = 8 * 1024 * 1024
        static let ringBufferWakeInterval: TimeInterval = 5
    }

    enum Demux {
        // Standalone engine/demux default; FTPlayer supplies its own cache choice.
        static let cacheEnabledByDefault = true
        static let initialInputTimeoutSeconds = 30
        static let defaultSetupTimeoutSeconds = 10
        static let maximumCodecThreads = 4
        static let fallbackVideoTimebase = 0.00004
        static let fallbackAudioTimebase = 0.000025
        static let maximumIndexedDuration: TimeInterval = 31_536_000
        static let seekProbePackets = 512
        static let seekProbeBytes = 8 * 1024 * 1024
        static let maximumSeekAnchors = 4096
        static let maximumSeekPreroll: TimeInterval = 50
        static let fallbackSeekBackoff: TimeInterval = 1
        static let endSeekRetryWindow: TimeInterval = 1
        static let timestampOutlierDurationMultiplier = 2.0
        static let avioBufferBytes: Int32 = 32 * 1024
    }

    enum HLS {
        static let maximumManifestBytes = 4 * 1024 * 1024
        static let maximumSegmentDuration: TimeInterval = 86_400
        static let maximumSegments = 10_000
        static let proxyStartTimeout: TimeInterval = 5
        static let proxyHeaderReadBytes = 8192
        static let maximumProxyHeaderBytes = 32 * 1024
        static let resourceReadBytes = 65_536
    }

    public enum Diagnostics {
        /// Runtime override: FTPlayerDiagnostic.shared.isEnabled.
        public static let enabledByDefault = false
        static let sdkVersion = "1.0.0"
        static let logDirectoryName = "FTPlayerLogs"
        static let maximumLogBytes = 8 * 1024 * 1024
        static let maximumLogFiles = 12
        static let healthInterval: TimeInterval = 1
        static let rateSampleOffsets: [TimeInterval] = [0.1, 0.25, 0.5, 1, 2, 3]
        static let ffmpegErrorBufferBytes = 256
        static let minimumMeasuredPower = 1e-24
        static let minimumMeasuredAmplitude = 1e-12
    }

    enum Rendering {
        static let brightness: Float = -0.05
        static let contrast: Float = 1
        static let saturation: Float = 0.9
        static let applyGammaCorrection = false
        static let hdColorMatrixMinimumWidth: CGFloat = 1280
        static let brightnessAnalysisFrameInterval = 30
        static let brightnessAnalysisPixelStep = 32
        static let minimumAnalyzedLuma: Float = 0.01
        static let darkLumaThreshold: Float = 0.25
        static let brightLumaThreshold: Float = 0.7
        static let darkLumaTarget: Float = 0.3
        static let brightLumaTarget: Float = 0.6
        static let brightnessAdjustmentGain: Float = 0.5
        static let darkContrast: Float = 1.1
        static let brightContrast: Float = 0.9
        static let previousAnalysisWeight: Float = 0.9
        static let newAnalysisWeight: Float = 0.1
    }
}
