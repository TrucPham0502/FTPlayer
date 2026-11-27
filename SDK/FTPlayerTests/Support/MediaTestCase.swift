import XCTest
import CoreVideo
@testable import FTPlayer

/// Records every public callback of one player playing synthetic media.
final class PlaybackSession: FTPlayerDeletegate {
    let player: FTPlayer
    let sink = PixelSink()
    let url: URL
    var ready = false
    var failure: Error?
    var errorCount = 0
    var states: [String] = []
    var measurements: [[String: Any]] = []
    var preparationEvents: [[String: Any]] = []
    var mediaInfoEvents: [FTPlayerMediaInfo] = []
    var onMediaInfo: (() -> Void)?
    var onReady: (() -> Void)?
    var onPreparation: ((FTPlayer, FTPlayerPreparationState) -> Void)?
    var preparationCompleteBeforeFrame = false
    var metadataWasBeforeReady = true
    var downloadProgressEvents: [Double] = []
    var progressEvents = 0
    var finished = 0
    var bufferingEvents: [[String: Any]] = []
    var finishEvents: [[String: Any]] = []
    var callbacksAfterStop = 0
    var stopRequested = false
    var callbackThreadsAreMain = true
    init(url: URL, cache: Bool? = false, policy: FTVideoDecodingPolicy = .automatic) {
        self.url = url
        player = FTPlayer(contentURL: url)
        // Lifecycle behavior is exercised explicitly in its own test.
        player.backgroundMode = .continuing
        player.delegate = self
        attachVideoSink(sink, to: player)
        if let cache { player.useCache = cache }
        player.videoDecodingPolicy = policy
    }
    func start() { player.replaceVideo() }
    func stop() { player.stop(); stopRequested = true }
    private func callback() {
        callbackThreadsAreMain = callbackThreadsAreMain && Thread.isMainThread
        if stopRequested { callbacksAfterStop += 1 }
    }
    func player(_ player: FTPlayer, didChangeState state: FTPlayerState) { callback(); states.append(String(describing: state)) }
    func player(_ player: FTPlayer, didUpdateProgress progress: TimeInterval) { callback(); progressEvents += 1 }
    func player(_ player: FTPlayer, didUpdatePlayable playable: TimeInterval) { callback() }
    func player(_ player: FTPlayer, didUpdateBufferProgress progress: Double) { callback() }
    func player(_ player: FTPlayer, didUpdateDownloadProgress progress: Double) { callback(); downloadProgressEvents.append(progress) }
    func player(_ player: FTPlayer, didChangePreparationState value: FTPlayerPreparationState) {
        callback()
        preparationEvents.append(["state": value.rawValue, "property": player.preparationState.rawValue, "frames": sink.frames, "uptime": ProcessInfo.processInfo.systemUptime])
        if value == .end && player.mediaInfo?.videoCodec != nil && sink.frames == 0 { preparationCompleteBeforeFrame = true }
        onPreparation?(player, value)
    }
    func player(_ player: FTPlayer, didUpdateMediaInfo info: FTPlayerMediaInfo) {
        callback(); mediaInfoEvents.append(info); onMediaInfo?()
    }
    func playerReadyToPlay(_ player: FTPlayer, duration: TimeInterval) {
        callback(); metadataWasBeforeReady = metadataWasBeforeReady && !mediaInfoEvents.isEmpty; ready = true
        onReady?()
    }
    func playerDidFinish(_ player: FTPlayer) {
        callback(); finished += 1
        finishEvents.append(["clock": player.currentTime, "duration": player.duration,
            "videoPTS": sink.lastPresentationTime, "uptime": ProcessInfo.processInfo.systemUptime,
            "decoder": player.decoder?.diagnosticSnapshot ?? "closed"])
    }
    func player(_ player: FTPlayer, didFail error: Error) { callback(); failure = error; errorCount += 1 }
    func playerBufferingStart(_ player: FTPlayer) { callback(); bufferingEvents.append(["event": "start", "wall": ProcessInfo.processInfo.systemUptime, "progress": player.currentTime]) }
    func playerBufferingEnd(_ player: FTPlayer) { callback(); bufferingEvents.append(["event": "end", "wall": ProcessInfo.processInfo.systemUptime, "progress": player.currentTime]) }
    var report: [String: Any] {
        let stats = player.videoDecodingStatistics
        return ["decodePolicy": stats.policy.rawValue, "ffmpegFrames": stats.ffmpegFrames, "hardwareFrames": stats.hardwareFrames,
                "videoToolboxSoftwareFrames": stats.videoToolboxSoftwareFrames, "videoToolboxUnverifiedFrames": stats.videoToolboxUnverifiedFrames,
                "url": url.lastPathComponent, "ready": ready, "frames": sink.frames,
                "width": sink.dimensions.width, "height": sink.dimensions.height,
                "pixelFormat": sink.pixelFormat, "progress": player.progress, "duration": player.duration,
                "states": states, "progressEvents": progressEvents, "finished": finished,
                "errorCount": errorCount, "error": failure.map { String(describing: $0) } ?? "", "callbacksOnMain": callbackThreadsAreMain,
                "finishEvents": finishEvents, "preparationEvents": preparationEvents,
                "preparationCompleteBeforeFrame": preparationCompleteBeforeFrame,
                "measurements": measurements, "bufferingEvents": bufferingEvents,
                "decoder": player.decoder?.diagnosticSnapshot ?? "closed"]
    }
}

/// Player tests on media generated by `SyntheticMedia`.
class MediaTestCase: UnitTestCase {
    var sessions: [PlaybackSession] = []
    private var originalDiagnosticsEnabled = false
    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDiagnosticsEnabled = FTPlayerDiagnostic.shared.isEnabled
        FTPlayerDiagnostic.shared.isEnabled = true
        FTPlayerDiagnostic.shared.log("BEGIN \(name)", category: "test")
    }
    override func tearDownWithError() throws {
        defer { FTPlayerDiagnostic.shared.isEnabled = originalDiagnosticsEnabled }
        for session in sessions {
            let data = try JSONSerialization.data(withJSONObject: session.report, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name + "-playback.json"; attachment.lifetime = .keepAlways; add(attachment)
            session.player.delegate = nil
            session.stop()
        }
        pump(0.25)
        sessions.removeAll()
        FTPlayerDiagnostic.shared.log("END \(name) failures=\(testRun?.failureCount ?? 0)", category: "test")
        FTPlayerDiagnostic.shared.flush()
    }
    func start(_ url: URL, cache: Bool? = false, policy: FTVideoDecodingPolicy = .automatic, timeout: TimeInterval = 15) throws -> PlaybackSession {
        let session = PlaybackSession(url: url, cache: cache, policy: policy)
        sessions.append(session); session.start()
        try require(until(timeout) { session.ready || session.failure != nil }, "No ready/error callback for \(url.lastPathComponent)")
        #if targetEnvironment(simulator)
        // Only an explicit unavailable strict-hardware session is skipped. Codec errors still fail.
        if policy == .hardware, let error = session.failure as NSError?,
           error.domain == "FTPlayer.VideoDecoder", error.code == -2001 {
            let stats = session.player.videoDecodingStatistics
            XCTAssertEqual(stats.ffmpegFrames, 0)
            XCTAssertEqual(stats.hardwareFrames, 0)
            throw XCTSkip("Strict hardware decoder unavailable on Simulator: \(error.localizedDescription)")
        }
        #endif
        try require(session.failure == nil, "Open failed: \(String(describing: session.failure))")
        return session
    }
    func assertPlayback(_ session: PlaybackSession, video: Bool = true, progress: Bool = true, timeout: TimeInterval = 10) throws {
        if video {
            try require(until(timeout) { session.sink.frames >= 3 || session.failure != nil }, "Ready but no decoded video frames: \(session.report)")
            try require(session.sink.frames >= 3, "Video frame output stopped")
            try require(session.sink.dimensions.width > 0 && session.sink.dimensions.height > 0, "Invalid frame size")
        }
        if progress {
            try require(until(timeout) { session.player.progress > 0.2 || session.failure != nil }, "Playback clock did not advance: \(session.report)")
        }
        try require(session.failure == nil, "Playback error: \(String(describing: session.failure))")
        try require(session.callbackThreadsAreMain, "Delegate callback was not on main thread")
    }
    func checkFormat(_ url: URL, video: Bool = true, progress: Bool = true) throws {
        let session = try start(url)
        try assertPlayback(session, video: video, progress: progress)
    }
}

extension FTPlayer {
    var decoder: FTDecoder? { engine as? FTDecoder }
}
