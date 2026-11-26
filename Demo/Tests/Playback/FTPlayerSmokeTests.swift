import XCTest
import CoreVideo
@testable import FTPlayer

final class FTPlayerCatalogConfigurationTests: PlaybackTestCase {
    func testRemovedLiveSourceRequiresExplicitLocalConfiguration() throws {
        do {
            let _: URL = try configuredInternetSource(nil, id: "hls-master")
            XCTFail("An unconfigured source must not count as successful playback")
        } catch {
            XCTAssertTrue(error is XCTSkip)
        }
    }
    func testMissingPublishedMP4RemainsAFailureInsteadOfSkip() throws {
        do {
            let _: URL = try configuredInternetSource(nil, id: "mp4-h264")
            XCTFail("A missing published MP4 is an invalid catalog")
        } catch {
            XCTAssertFalse(error is XCTSkip)
            XCTAssertTrue(error is PlaybackTestError)
        }
    }
}

final class FTPlayerFrameRateTests: PlaybackTestCase {
    private func picture(_ luma: UInt8, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                         width: Int = 160) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, 90, format, nil, &output), kCVReturnSuccess)
        let pixel = try XCTUnwrap(output)
        if CVPixelBufferGetPlaneCount(pixel) > 0 {
            CVPixelBufferLockBaseAddress(pixel, [])
            defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, 0))
            memset(base, Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) * 90)
        }
        return pixel
    }









    private final class StatisticsSpy: FTPlayerVideoStatisticsDelegate {
        var frameRates: [(value: Double?, upcoming: Double?, wall: TimeInterval)] = []
        var contentRates: [Double?] = []
        var offMainCallbacks = 0
        func player(_ player: FTPlayer, didChangeVideoFrameRate statistics: FTVideoFrameRateStatistics) {
            if !Thread.isMainThread { offMainCallbacks += 1 }
            frameRates.append((statistics.timelineFramesPerSecond, statistics.upcomingTimelineFramesPerSecond,
                               ProcessInfo.processInfo.systemUptime))
        }
        func player(_ player: FTPlayer, didChangeVideoContentChangeRate statistics: FTVideoContentChangeStatistics) {
            if !Thread.isMainThread { offMainCallbacks += 1 }
            contentRates.append(statistics.estimatedChangesPerSecond)
        }
    }

    func testVideoStatisticsDelegateReportsChangesOnMainWithoutChangingRate() throws {
        FTPlayerDiagnostic.shared.isEnabled = false
        let s = try start(fixture("sample.mp4"), policy: .ffmpeg)
        let spy = StatisticsSpy()
        s.player.videoStatisticsDelegate = spy
        try require(until(8) { spy.frameRates.contains { $0.value != nil } }, "No frame-rate callback")
        pump(2)
        XCTAssertEqual(try XCTUnwrap(spy.frameRates.last?.value), 24, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(spy.frameRates.last?.upcoming), 24, accuracy: 0.5, "Packets ahead are reported")
        for (previous, next) in zip(spy.frameRates, spy.frameRates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.wall - previous.wall, 0.49, "Callbacks exceed the notification interval")
            XCTAssertTrue(next.value != previous.value || next.upcoming != previous.upcoming, "Unchanged values must not be repeated")
        }
        XCTAssertTrue(spy.contentRates.isEmpty, "Content callbacks require the opt-in measurement")
        s.player.isVideoContentChangeMeasurementEnabled = true
        try require(until(6) { spy.contentRates.contains { $0 != nil } }, "No content-change callback")
        XCTAssertEqual(spy.offMainCallbacks, 0)
        XCTAssertEqual(s.player.rate, 1, "The SDK reports measurements but never changes rate")
        let delivered = spy.frameRates.count
        s.player.videoStatisticsDelegate = nil
        pump(1)
        XCTAssertEqual(spy.frameRates.count, delivered)
    }


    func testPublicFPSMeasuresPlaybackWithLoggingDisabledAndResetsOnControls() throws {
        FTPlayerDiagnostic.shared.isEnabled = false
        let s = try start(fixture("sample.mp4"), policy: .ffmpeg)
        XCTAssertFalse(s.player.isVideoContentChangeMeasurementEnabled)
        XCTAssertNil(s.player.videoContentChangeStatistics.estimatedChangesPerSecond)
        s.player.isVideoContentChangeMeasurementEnabled = true
        try require(until(8) { s.sink.frames >= 30 }, "No output frames for FPS measurement")
        try require(until(5) { s.player.videoContentChangeStatistics.estimatedChangesPerSecond != nil }, "No content measurement")
        XCTAssertGreaterThan(try XCTUnwrap(s.player.videoContentChangeStatistics.estimatedChangesPerSecond), 0)
        let measured = s.player.videoFrameRateStatistics
        XCTAssertEqual(try XCTUnwrap(measured.timelineFramesPerSecond), 24, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(measured.upcomingTimelineFramesPerSecond), 24, accuracy: 0.5)
        XCTAssertGreaterThan(measured.outputFramesPerSecond, 15)
        XCTAssertLessThan(measured.outputFramesPerSecond, 32)
        s.player.pause()
        XCTAssertNil(s.player.videoContentChangeStatistics.estimatedChangesPerSecond)
        XCTAssertNil(s.player.videoFrameRateStatistics.timelineFramesPerSecond)
        XCTAssertEqual(s.player.videoFrameRateStatistics.outputFramesPerSecond, 0)
        s.player.play()
        try require(until(5) { s.player.videoFrameRateStatistics.sampleFrameCount >= 10 }, "FPS did not resume")
        s.player.rate = 2
        XCTAssertNil(s.player.videoContentChangeStatistics.estimatedChangesPerSecond)
        XCTAssertEqual(s.player.videoFrameRateStatistics.sampleFrameCount, 0)
        s.player.seek(to: 10)
        XCTAssertNil(s.player.videoContentChangeStatistics.estimatedChangesPerSecond)
        XCTAssertEqual(s.player.videoFrameRateStatistics.sampleFrameCount, 0)
        s.player.stop()
        XCTAssertNil(s.player.videoContentChangeStatistics.estimatedChangesPerSecond)
        XCTAssertEqual(s.player.videoFrameRateStatistics.outputFramesPerSecond, 0)
        XCTAssertNil(s.player.videoFrameRateStatistics.timelineFramesPerSecond)
        XCTAssertNil(s.player.videoFrameRateStatistics.upcomingTimelineFramesPerSecond)
    }
}

final class FTPlayerDiagnosticToggleTests: XCTestCase {
    private var directory: URL!
    private var diagnostics: FTPlayerDiagnostic!
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        diagnostics = FTPlayerDiagnostic(directory: directory)
    }
    override func tearDown() {
        diagnostics.isEnabled = false
        diagnostics = nil
        try? FileManager.default.removeItem(at: directory)
    }




}

final class PlayerObserver: FTPlayerDeletegate {
    var ready: (() -> Void)?
    var failed: ((Error) -> Void)?
    func player(_ player: FTPlayer, didChangeState state: FTPlayerState) {}
    func player(_ player: FTPlayer, didUpdateProgress progress: TimeInterval) {}
    func player(_ player: FTPlayer, didUpdatePlayable playable: TimeInterval) {}
    func player(_ player: FTPlayer, didUpdateBufferProgress progress: Double) {}
    func player(_ player: FTPlayer, didUpdateDownloadProgress progress: Double) {}
    func playerReadyToPlay(_ player: FTPlayer, duration: TimeInterval) { ready?() }
    func playerDidFinish(_ player: FTPlayer) {}
    func player(_ player: FTPlayer, didFail error: Error) { failed?(error) }
    func playerBufferingStart(_ player: FTPlayer) {}
    func playerBufferingEnd(_ player: FTPlayer) {}
}

final class FTPlayerSmokeTests: XCTestCase {
    private var originalDiagnosticsEnabled = false
    override func setUp() {
        originalDiagnosticsEnabled = FTPlayerDiagnostic.shared.isEnabled
        FTPlayerDiagnostic.shared.isEnabled = true
        FTPlayerDiagnostic.shared.log("BEGIN \(name)", category: "test")
    }
    override func tearDown() {
        FTPlayerDiagnostic.shared.log("END \(name) failures=\(testRun?.failureCount ?? 0)", category: "test")
        FTPlayerDiagnostic.shared.flush()
        FTPlayerDiagnostic.shared.isEnabled = originalDiagnosticsEnabled
    }

    func testMissingFileReportsNativeError() {
        let failed = expectation(description: "Native FFmpeg failure callback")
        let player = FTPlayer(contentURL: URL(fileURLWithPath: "/missing-ftplayer-smoke.mp4"))
        let observer = PlayerObserver()
        observer.failed = { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, "FTPlayer.FFmpeg")
            XCTAssertNotNil(error.userInfo["avCode"])
            failed.fulfill()
        }
        player.delegate = observer
        player.replaceVideo()
        wait(for: [failed], timeout: 10)
        XCTAssertEqual(player.state, .failed)
        player.stop()
    }

    func testSampleDecodesRendersAndSeeks() throws {
        let url = try RemoteFixtureStore.file("sample.mp4")
        let ready = expectation(description: "Ready")
        let progress = expectation(description: "Playback advances")
        let seek = expectation(description: "Seek completes")
        let player = FTPlayer(contentURL: url)
        let renderer = FTMediaRendererView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let observer = PlayerObserver()
        observer.ready = { ready.fulfill() }
        observer.failed = { error in XCTFail("Playback error: \(error)") }
        player.delegate = observer
        player.videoOutput = renderer
        player.replaceVideo()
        wait(for: [ready], timeout: 10)
        XCTAssertGreaterThan(player.duration, 20)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            XCTAssertGreaterThan(player.progress, 0)
            player.pause()
            XCTAssertEqual(player.state, .suspend)
            player.seek(to: 10) { success in XCTAssertTrue(success); seek.fulfill() }
            player.play()
            progress.fulfill()
        }
        wait(for: [progress, seek], timeout: 12)
        player.stop()
        let report = try String(contentsOf: FTPlayerDiagnostic.shared.exportLogs())
        XCTAssertTrue(report.contains("first frame"))
        XCTAssertTrue(report.contains("seek completed"))
    }

    func testStopCancelsPendingReplacement() throws {
        let url = try RemoteFixtureStore.file("sample.mp4")
        let ready = expectation(description: "Ready")
        let stopped = expectation(description: "Stopped after queued replacement")
        let player = FTPlayer(contentURL: url)
        let observer = PlayerObserver()
        observer.ready = { ready.fulfill() }
        player.delegate = observer
        player.replaceVideo()
        wait(for: [ready], timeout: 10)
        player.replaceVideo()
        player.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            XCTAssertEqual(player.state, .none)
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 5)
    }
}
