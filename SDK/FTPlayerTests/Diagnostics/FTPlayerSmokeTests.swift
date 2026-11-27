import XCTest
import UIKit
import CoreVideo
import libavcodec
@testable import FTPlayer

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
    func testExportContainsNotesAndValidJSON() throws {
        let diagnostics = FTPlayerDiagnostic.shared
        let marker = "smoke-\(UUID().uuidString)"
        diagnostics.log(marker)
        let report = try diagnostics.exportLogs(notes: "play → seek → export")
        let text = try String(contentsOf: report)
        XCTAssertTrue(text.contains(marker))
        XCTAssertTrue(text.contains("play → seek → export"))
        let lines = try String(contentsOf: diagnostics.currentLogURL).split(separator: "\n")
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertNotNil(json?["time"])
            XCTAssertNotNil(json?["session"])
            XCTAssertNotNil(json?["category"])
        }
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
        let url = try SyntheticMedia.sample()
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
        let url = try SyntheticMedia.sample()
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
