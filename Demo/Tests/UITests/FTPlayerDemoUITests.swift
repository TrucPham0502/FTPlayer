import XCTest

/// App-level reproduction using a real public video URL, never bundled media.
final class FTPlayerDemoUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if testRun?.hasSucceeded == false && app.state != .notRunning {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "Demo playback failure"
            image.lifetime = .keepAlways
            add(image)
        }
        app.terminate()
    }

    private func publicURL() throws -> URL {
        struct Source: Decodable { let id: String; let url: URL }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SampleStreams", withExtension: "json"))
        let rows = try JSONDecoder().decode([Source].self, from: Data(contentsOf: file))
        return try XCTUnwrap(rows.first { $0.id == "mp4-h264" }).url
    }

    private func launchPublicVideo() throws {
        app.launchArguments = ["--play-url=" + (try publicURL()).absoluteString, "--decode=ffmpeg"]
        app.launch()
        let fps = app.staticTexts["playback.fps"]
        XCTAssertTrue(fps.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(90) { self.position() > 0.2 }, "The public video never advanced")
        XCTAssertTrue(wait(10) { !fps.label.contains("FPS video (PTS): —") }, "No measured output FPS")
        XCTAssertFalse(app.staticTexts["playback.status"].label.hasPrefix("Lỗi:"))
    }

    private func position() -> Double {
        let text = app.staticTexts["playback.time"].label
        let current = text.components(separatedBy: "Current time: ").last?
            .components(separatedBy: " • Duration:").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let parts = current.split(separator: ":").compactMap { Double($0) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private func wait(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout) == .completed
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeUp()
        }
    }

    func testPublicVideoRendersAndShowsMeasuredFPS() throws {
        try launchPublicVideo()
        XCTAssertFalse(app.staticTexts["media.info"].label.isEmpty)
        XCTAssertGreaterThan(position(), 0)
    }

    func testPublicVideoCanPauseAndResumeThroughUI() throws {
        try launchPublicVideo()
        let control = app.buttons["Play / Pause"]
        reveal(control)
        XCTAssertTrue(control.isHittable)
        control.tap()
        XCTAssertTrue(wait(10) { self.app.staticTexts["playback.status"].label.contains("suspend") })
        let paused = position()
        control.tap()
        XCTAssertTrue(wait(15) { self.position() > paused })
    }

    func testPublicCatalogSelectionPlaysTheSelectedURL() throws {
        app.launchArguments = []
        app.launch()
        let open = app.buttons["testStreams.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        reveal(open)
        open.tap()
        let row = app.tables["testStreams.list"].cells["testStreams.mp4-h264"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(wait(90) { self.position() > 0.2 })
        XCTAssertFalse(app.staticTexts["playback.fps"].label.contains("FPS video (PTS): —"))
    }
}
