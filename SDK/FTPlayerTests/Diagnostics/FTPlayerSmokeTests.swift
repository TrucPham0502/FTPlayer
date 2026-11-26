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



}
