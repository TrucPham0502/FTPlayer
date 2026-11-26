import XCTest
import UIKit
import CoreVideo
import libavcodec
@testable import FTPlayer

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
    func testDiagnosticsDoNotPersistCredentialsOrPrivateURLCapabilities() throws {
        diagnostics.isEnabled = true
        let source = "https://basic-user:basic-password@example.test/private-device/private-recording.m3u8?opaque=signed-capability#private-fragment"
        diagnostics.record("error", "test", "HTTP 403 source=\(source) Authorization: Bearer header-secret", fields: [
            "url": source, "serial": "private-device", "httpStatus": 403,
            "nested": ["access_token": "nested-secret", "gis": "header-gis"],
            "items": [["api_key": "api-secret"]]
        ])
        diagnostics.flush()
        let text = try String(contentsOf: diagnostics.currentLogURL)
        for secret in ["basic-user", "basic-password", "private-device", "private-recording", "signed-capability", "private-fragment", "header-secret", "nested-secret", "header-gis", "api-secret"] {
            XCTAssertFalse(text.contains(secret), "Diagnostic persisted sensitive input")
        }
        XCTAssertTrue(text.contains("example.test"))
        XCTAssertTrue(text.contains("403"))
    }

    func testExportRedactsHistoricalLogsAndNotesWithoutChangingOriginalFiles() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = "https://example.test/recording-capability.mp4?opaque=legacy-secret"
        let data = try JSONSerialization.data(withJSONObject: ["message": "old source=\(source)", "fields": ["token": "legacy-token", "code": -1001]])
        let old = directory.appendingPathComponent("historical.jsonl")
        try data.write(to: old)
        let report = try diagnostics.exportLogs(notes: "Authorization: Bearer notes-secret")
        defer { try? FileManager.default.removeItem(at: report) }
        let text = try String(contentsOf: report)
        for secret in ["recording-capability", "legacy-secret", "legacy-token", "notes-secret"] {
            XCTAssertFalse(text.contains(secret), "Export exposed sensitive input")
        }
        XCTAssertTrue(text.contains("-1001"))
        XCTAssertEqual(try Data(contentsOf: old), data)
    }

    func testDiagnosticsRedactBasicAuthCookiesAndMalformedURLs() throws {
        diagnostics.isEnabled = true
        diagnostics.log("Authorization: Basic encoded-auth-secret")
        diagnostics.log("Cookie: session=cookie-secret; path=/")
        diagnostics.log("Invalid URL https://[invalid-host]/malformed-url-secret?access=hidden")
        diagnostics.record("info", "test", "HTTP 403", fields: ["key": "encryption-secret"])
        diagnostics.flush()
        let text = try String(contentsOf: diagnostics.currentLogURL)
        for secret in ["encoded-auth-secret", "cookie-secret", "malformed-url-secret", "encryption-secret"] {
            XCTAssertFalse(text.contains(secret), "Non-Bearer or invalid input bypassed redaction")
        }
        XCTAssertTrue(text.contains("403"))
    }

    func testDiagnosticURLDoesNotExposeUnknownFilenameSuffix() throws {
        diagnostics.isEnabled = true
        diagnostics.log("Failed to open https://example.test/private.grantkey")
        diagnostics.flush()
        let text = try String(contentsOf: diagnostics.currentLogURL)
        XCTAssertFalse(text.contains("grantkey"), "An arbitrary URL suffix can itself be a capability")
        XCTAssertTrue(text.contains("example.test"))
    }

    func testDisabledByDefaultDoesNotEvaluateOrCreateLogsEvenWhenExporting() throws {
        XCTAssertFalse(FTPlayerSDKConfiguration.Diagnostics.enabledByDefault)
        XCTAssertFalse(diagnostics.isEnabled)
        var evaluated = false
        func message() -> String { evaluated = true; return "disabled-marker" }
        func fields() -> [String: Any] { evaluated = true; return ["expensive": true] }
        diagnostics.log(message())
        diagnostics.record("info", "test", message(), fields: fields())
        diagnostics.flush()
        let report = try diagnostics.exportLogs(notes: "explicit export")
        defer { try? FileManager.default.removeItem(at: report) }
        XCTAssertFalse(evaluated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let contents = try String(contentsOf: report)
        XCTAssertTrue(contents.contains("explicit export"))
        XCTAssertFalse(contents.contains("disabled-marker"))
    }
    func testTogglePreservesHistoryAndStopsFileWrites() throws {
        diagnostics.isEnabled = true
        diagnostics.log("before-disable")
        diagnostics.flush()
        let first = diagnostics.currentLogURL
        let saved = try Data(contentsOf: first)
        diagnostics.isEnabled = false
        diagnostics.log("while-disabled")
        diagnostics.flush()
        XCTAssertEqual(try Data(contentsOf: first), saved)
        diagnostics.isEnabled = true
        diagnostics.log("after-enable")
        diagnostics.flush()
        XCTAssertNotEqual(diagnostics.currentLogURL, first)
        XCTAssertEqual(try Data(contentsOf: first), saved)
        diagnostics.isEnabled = false
        let report = try diagnostics.exportLogs()
        defer { try? FileManager.default.removeItem(at: report) }
        let contents = try String(contentsOf: report)
        XCTAssertTrue(contents.contains("before-disable"))
        XCTAssertTrue(contents.contains("after-enable"))
        XCTAssertFalse(contents.contains("while-disabled"))
    }
    func testRecordStartedBeforeDisableCannotLeakIntoNextRecording() throws {
        diagnostics.isEnabled = true
        let formatting = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "Old record returned")
        let recorder = diagnostics!
        DispatchQueue.global().async {
            recorder.record("info", "test", "stale-record", fields: {
                formatting.signal()
                _ = release.wait(timeout: .now() + 5)
                return [:]
            }())
            finished.fulfill()
        }
        defer { release.signal() }
        XCTAssertEqual(formatting.wait(timeout: .now() + 5), .success)
        diagnostics.isEnabled = false
        diagnostics.isEnabled = true
        release.signal()
        wait(for: [finished], timeout: 5)
        diagnostics.log("current-record")
        let report = try diagnostics.exportLogs()
        defer { try? FileManager.default.removeItem(at: report) }
        let contents = try String(contentsOf: report)
        XCTAssertFalse(contents.contains("stale-record"))
        XCTAssertTrue(contents.contains("current-record"))
    }
    func testConcurrentTogglesAndProducersStopWritingAfterDisable() throws {
        let group = DispatchGroup(), recorder = diagnostics!
        for producer in 0..<4 {
            DispatchQueue.global().async(group: group) {
                for index in 0..<30 {
                    if producer == 0 { recorder.isEnabled = index % 2 == 0 }
                    recorder.log("producer-\(producer)-\(index)")
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        diagnostics.isEnabled = true
        diagnostics.log("last-enabled-record")
        diagnostics.flush()
        diagnostics.isEnabled = false
        let file = diagnostics.currentLogURL, saved = try Data(contentsOf: file)
        DispatchQueue.concurrentPerform(iterations: 100) { recorder.log("disabled-\($0)") }
        diagnostics.flush()
        XCTAssertEqual(try Data(contentsOf: file), saved)
    }
}
