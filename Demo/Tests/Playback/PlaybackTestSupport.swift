import XCTest
import UIKit
import CoreVideo
@testable import FTPlayer

// Test-only sinks adapt their existing frame inspection to public video output.
protocol TestVideoSink: FTPlayerVideoOutput {
    func didRenderFrame(_ pb: CVPixelBuffer, time: Int64)
}
extension TestVideoSink {
    func player(_ player: FTPlayer, didOutput pixelBuffer: CVPixelBuffer,
                presentationTime: TimeInterval) {
        didRenderFrame(pixelBuffer, time: Int64(presentationTime * 1_000_000))
    }
}
func attachVideoSink(_ sink: any TestVideoSink, to player: FTPlayer) {
    player.videoOutput = sink
}

enum PlaybackTestError: Error { case assertion(String) }
final class PixelSink: TestVideoSink {
    var inspectFrame: ((CVPixelBuffer, Double) -> Void)?
    private var recentPresentations: [(number: Int, time: Double, wall: Double)] = []
    func presentationTimes(after frameNumber: Int) -> [Double] {
        recentPresentations.filter { $0.number > frameNumber }.map(\.time)
    }
    func presentationEvents(after frameNumber: Int) -> [(time: Double, wall: Double)] {
        recentPresentations.filter { $0.number > frameNumber }.map { ($0.time, $0.wall) }
    }
    var frames = 0
    var lastPresentationTime: Double = 0
    private(set) var firstPresentationTime: Double?
    var dimensions = CGSize.zero
    var pixelFormat: OSType = 0
    func didRenderFrame(_ pb: CVPixelBuffer, time: Int64) {
        frames += 1
        lastPresentationTime = Double(time) / 1_000_000
        recentPresentations.append((frames, lastPresentationTime, ProcessInfo.processInfo.systemUptime))
        if recentPresentations.count > 4096 { recentPresentations.removeFirst(2048) }
        if firstPresentationTime == nil { firstPresentationTime = lastPresentationTime }
        dimensions = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        pixelFormat = CVPixelBufferGetPixelFormatType(pb)
        inspectFrame?(pb, lastPresentationTime)
    }
    func didChangeVideoSize(_ size: CGSize) {}
    func didUpdateCurrentTime(_ sec: Double) {}
}
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
        // Decoder/transport tests must keep running if the tester changes Mac focus.
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
        return ["decodePolicy": stats.policy.rawValue, "ffmpegFrames": stats.ffmpegFrames, "hardwareFrames": stats.hardwareFrames, "videoToolboxSoftwareFrames": stats.videoToolboxSoftwareFrames, "videoToolboxUnverifiedFrames": stats.videoToolboxUnverifiedFrames,
"url": url.absoluteString, "ready": ready, "frames": sink.frames,
         "width": sink.dimensions.width, "height": sink.dimensions.height,
         "pixelFormat": sink.pixelFormat, "progress": player.progress, "duration": player.duration,
         "states": states, "progressEvents": progressEvents, "finished": finished,
         "errorCount": errorCount, "error": failure.map { String(describing: $0) } ?? "", "callbacksOnMain": callbackThreadsAreMain, "finishEvents": finishEvents,
         "preparationEvents": preparationEvents, "preparationCompleteBeforeFrame": preparationCompleteBeforeFrame,
         "mediaInfoEvents": mediaInfoEvents.map { ["format": $0.formatName, "videoCodec": $0.videoCodec ?? "none", "width": $0.width ?? 0, "height": $0.height ?? 0, "fps": $0.framesPerSecond ?? 0, "audioCodec": $0.audioCodec ?? "none", "sampleRate": $0.audioSampleRate ?? 0, "channels": $0.audioChannels ?? 0, "duration": $0.duration ?? 0, "bitrate": $0.bitrate ?? 0] as [String: Any] },
         "measurements": measurements, "bufferingEvents": bufferingEvents, "decoder": player.decoder?.diagnosticSnapshot ?? "closed"]
    }
}
class PlaybackTestCase: XCTestCase {
    // Public distribution only includes approved MP4 samples. Optional live
    // inputs are supplied locally and are never bundled into the app/repository.
    private var unpublishedInternetSourceIDs: Set<String> { [
        "avi-mpeg4-mp3",
        "dash-h264",
        "flv-public",
        "hls-aes128-audio",
        "hls-apple-fmp4",
        "hls-apple-hdr10plus",
        "hls-apple-ts",
        "hls-audio-pdt-gap",
        "hls-av-start-gap",
        "hls-captions",
        "hls-custom-iv",
        "hls-dai-discontinuity",
        "hls-elephants-audio",
        "hls-fdr",
        "hls-hevc",
        "hls-hevc-1080p60",
        "hls-hevc-4k",
        "hls-hevc-720p60",
        "hls-hevc-ts-public",
        "hls-jw-muxed-fmp4",
        "hls-master",
        "hls-media",
        "hls-mp3-vod",
        "hls-mux-pts-shift",
        "hls-mux-sample-aes",
        "hls-oceans-aes128",
        "hls-pdt-large-gaps",
        "hls-shaka-angel-one",
        "hls-surveillance",
        "hls-unified-tos",
        "hls-wistia-pes",
        "malformed-bad-pdt",
        "malformed-corrupt-webm",
        "mkv-h264",
        "mov-camera",
        "mov-pcm-s16be",
        "webm-vp8",
        "webm-vp9",
        "webm-vp9-earth",
    ] }

    func internetStreamCatalogData() throws -> Data {
        let bundle = Bundle(for: PlaybackTestCase.self)
        let file = try XCTUnwrap(bundle.url(forResource: "SampleStreams", withExtension: "json"))
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        if let path = ProcessInfo.processInfo.environment["FTPLAYER_TEST_CATALOG_PATH"], !path.isEmpty {
            let additional = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]])
            var ids = Set(rows.compactMap { $0["id"] as? String })
            for row in additional {
                let id = try XCTUnwrap(row["id"] as? String)
                guard ids.insert(id).inserted else { throw PlaybackTestError.assertion("Optional catalog duplicates an existing source ID") }
                rows.append(row)
            }
        }
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty,
                  let text = row["url"] as? String, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw PlaybackTestError.assertion("Invalid test catalog entry; no request was sent")
            }
        }
        return try JSONSerialization.data(withJSONObject: rows)
    }

    func configuredInternetSource<T>(_ value: T?, id: String) throws -> T {
        if let value { return value }
        if unpublishedInternetSourceIDs.contains(id) {
            throw XCTSkip("This live source is not distributed in the MP4-only catalog. Supply FTPLAYER_TEST_CATALOG_PATH locally to run it.")
        }
        throw PlaybackTestError.assertion("A required published test source is missing")
    }

    var sessions: [PlaybackSession] = []
    var server: FixtureHTTPServer?
    private var originalIdleTimerDisabled = false
    private var originalDiagnosticsEnabled = false
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCTAssertTrue(Thread.isMainThread)
        // Enables test tooling to install private opt-in inputs in the actual
        // platform container without assuming a simulator/macOS sandbox layout.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        print("FTPLAYER_TEST_DOCUMENTS=\(documents.path)")
        // Long physical-device suites must not lose RemoteIO to auto-lock.
        originalIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        originalDiagnosticsEnabled = FTPlayerDiagnostic.shared.isEnabled
        FTPlayerDiagnostic.shared.isEnabled = true
        FTPlayerDiagnostic.shared.log("BEGIN \(name)", category: "test")
    }
    override func tearDownWithError() throws {
        defer {
            UIApplication.shared.isIdleTimerDisabled = originalIdleTimerDisabled
            FTPlayerDiagnostic.shared.isEnabled = originalDiagnosticsEnabled
        }
        for session in sessions {
            let data = try JSONSerialization.data(withJSONObject: session.report, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name + "-playback.json"; attachment.lifetime = .keepAlways; add(attachment)
            session.player.delegate = nil
            session.stop()
        }
        pump(0.25)
        server?.stop()
        sessions.removeAll()
        FTPlayerDiagnostic.shared.log("END \(name) failures=\(testRun?.failureCount ?? 0)", category: "test")
        FTPlayerDiagnostic.shared.flush()
    }
    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
    @discardableResult func until(_ timeout: TimeInterval = 12, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { pump(0.02) }
        return condition()
    }
    func require(_ value: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(value, message, file: file, line: line)
        if !value { throw PlaybackTestError.assertion(message) }
    }
    func fixture(_ path: String) throws -> URL {
        try RemoteFixtureStore.file(path)
    }
    func http(_ path: String) throws -> URL {
        if server == nil { server = try FixtureHTTPServer(root: fixture("")) }
        return server!.url(path)
    }
    func start(_ url: URL, cache: Bool? = false, policy: FTVideoDecodingPolicy = .automatic, timeout: TimeInterval = 15) throws -> PlaybackSession {
        let session = PlaybackSession(url: url, cache: cache, policy: policy)
        sessions.append(session); session.start()
        try require(until(timeout) { session.ready || session.failure != nil }, "No ready/error callback for \(url)")
        #if targetEnvironment(simulator)
        // Match backend-suite capability handling: only an explicit unavailable
        // strict-hardware session is skipped. Network and codec errors still fail.
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
    func checkFormat(_ name: String, video: Bool = true, progress: Bool = true) throws {
        let session = try start(fixture(name))
        try assertPlayback(session, video: video, progress: progress)
    }
}

// Concrete inspection is confined to integration tests.
extension FTPlayer {
    var decoder: FTDecoder? { engine as? FTDecoder }
}
