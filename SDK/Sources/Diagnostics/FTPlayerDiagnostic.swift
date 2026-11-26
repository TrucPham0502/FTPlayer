import Foundation
import UIKit
import AVFoundation
import Darwin

/// Process-wide, opt-in diagnostics. Recording is disabled by default.
/// Logs survive relaunches; exportLogs() includes current and recent sessions.
public final class FTPlayerDiagnostic {
    public static let shared = FTPlayerDiagnostic()
    public let sessionID = UUID().uuidString
    public let directoryURL: URL
    public private(set) var currentLogURL: URL
    private let queue = DispatchQueue(label: "FTPlayer.diagnostics", qos: .utility)
    private var handle: FileHandle?
    private var bytes = 0
    private var part = 0
    private var observers: [NSObjectProtocol] = []
    private let formatter = ISO8601DateFormatter()
    private let maxBytes = FTPlayerSDKConfiguration.Diagnostics.maximumLogBytes
    private let maxFiles = FTPlayerSDKConfiguration.Diagnostics.maximumLogFiles
    private let stateLock = NSLock()
    private var enabled = FTPlayerSDKConfiguration.Diagnostics.enabledByDefault
    private var revision = 0
    // File state is owned by queue; revisions discard work from earlier toggles.
    private var writerRevision: Int?
    private var hasOpenedFile = false

    /// Safe to change from any thread. Disabling drains the active write, closes
    /// the file, and discards queued records. Existing reports are preserved.
    public var isEnabled: Bool {
        get { stateLock.withLock { enabled } }
        set {
            let token = stateLock.withLock { () -> Int? in
                guard enabled != newValue else { return nil }
                enabled = newValue; revision += 1
                return revision
            }
            guard let token else { return }
            queue.sync {
                guard self.matches(token, enabled: newValue) else { return }
                self.closeFile()
                if newValue { self.beginRecording(token: token) }
            }
            if newValue { recordSessionStart(token: token) }
        }
    }

    // Internal directory injection keeps filesystem regressions isolated from app logs.
    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        directoryURL = directory ?? base.appendingPathComponent(FTPlayerSDKConfiguration.Diagnostics.logDirectoryName, isDirectory: true)
        currentLogURL = directoryURL.appendingPathComponent("\(sessionID)-0.jsonl")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification,
                     UIApplication.didReceiveMemoryWarningNotification, UIApplication.willTerminateNotification,
                     AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                self?.record("info", "lifecycle", note.name.rawValue, fields: ["details": String(describing: note.userInfo ?? [:])])
                self?.flush()
            })
        }
        if enabled {
            queue.sync { beginRecording(token: revision) }
            recordSessionStart(token: revision)
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        try? handle?.close()
    }

    private func matches(_ token: Int, enabled value: Bool = true) -> Bool {
        stateLock.withLock { enabled == value && revision == token }
    }

    private func closeFile() {
        try? handle?.synchronize(); try? handle?.close()
        handle = nil; writerRevision = nil
    }

    private func beginRecording(token: Int) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if hasOpenedFile { part += 1 }
            currentLogURL = directoryURL.appendingPathComponent("\(sessionID)-\(part).jsonl")
            try openFile()
            hasOpenedFile = true; writerRevision = token
        } catch { NSLog("FTPlayer cannot open log: %@", String(describing: error)) }
    }

    private func recordSessionStart(token: Int) {
        guard matches(token) else { return }
        enqueue("info", "session", "start", fields: [
            "sdk": FTPlayerSDKConfiguration.Diagnostics.sdkVersion, "session": sessionID,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "model": UIDevice.current.model,
            "app": Bundle.main.bundleIdentifier ?? "unknown",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "processors": ProcessInfo.processInfo.processorCount, "memoryBytes": ProcessInfo.processInfo.physicalMemory
        ], token: token)
    }

    /// Add reproduction steps or app events to the same timeline as decoder logs.
    public func log(_ message: @autoclosure () -> String, category: String = "app") {
        record("info", category, message())
    }

    func record(_ level: String, _ category: String, _ message: @autoclosure () -> String,
                fields: @autoclosure () -> [String: Any] = [:]) {
        guard let token = stateLock.withLock({ enabled ? revision : nil }) else { return }
        enqueue(level, category, message(), fields: fields(), token: token)
    }

    private func enqueue(_ level: String, _ category: String, _ message: String, fields: [String: Any], token: Int) {
        // Capture thread and monotonic time before dispatching to the writer queue.
        let uptime = ProcessInfo.processInfo.systemUptime
        let thread = pthread_mach_thread_np(pthread_self())
        let main = Thread.isMainThread
        let date = Date()
        queue.async {
            guard self.matches(token), self.writerRevision == token, self.handle != nil else { return }
            var event: [String: Any] = ["time": self.formatter.string(from: date), "uptime": uptime,
                "session": self.sessionID, "level": level, "category": DiagnosticRedaction.text(category),
                "thread": thread, "mainThread": main, "message": DiagnosticRedaction.text(message),
                "fields": DiagnosticRedaction.value(fields)]
            if !JSONSerialization.isValidJSONObject(event) {
                event["fields"] = DiagnosticRedaction.text(String(describing: event["fields"] ?? ""))
            }
            guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            do {
                if self.bytes + data.count > self.maxBytes {
                    try self.handle?.synchronize(); try self.handle?.close()
                    self.part += 1
                    self.currentLogURL = self.directoryURL.appendingPathComponent("\(self.sessionID)-\(self.part).jsonl")
                    try self.openFile()
                }
                guard let handle = self.handle else { return }
                if #available(iOS 13.4, *) { try handle.write(contentsOf: data) }
                else { handle.write(data) }
                self.bytes += data.count
                // Persist each record, including FFmpeg errors immediately preceding a crash.
                try handle.synchronize()
            } catch { NSLog("FTPlayer log write failed: %@", String(describing: error)) }
        }
    }

    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    /// One shareable text file with recent JSONL sessions and the user's notes.
    public func exportLogs(notes: String = "") throws -> URL {
        try queue.sync {
            try handle?.synchronize()
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("FTPlayer-report-\(UUID().uuidString).txt")
            var report = Data("FTPlayer diagnostic report\nSession: \(sessionID)\nNotes: \(DiagnosticRedaction.text(notes))\n\n".utf8)
            for url in try logFiles() {
                report.append(Data("\n--- \(url.lastPathComponent) ---\n".utf8))
                // Older sessions may predate redaction. Sanitize the exported
                // copy as well, without changing the original diagnostic files.
                let contents = try String(contentsOf: url, encoding: .utf8)
                for line in contents.split(separator: "\n") {
                    if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                       let data = try? JSONSerialization.data(withJSONObject: DiagnosticRedaction.value(object), options: [.sortedKeys]) {
                        report.append(data)
                    } else {
                        report.append(Data(DiagnosticRedaction.text(String(line)).utf8))
                    }
                    report.append(0x0A)
                }
            }
            try report.write(to: output, options: .atomic)
            return output
        }
    }

    private func logFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    private func openFile() throws {
        FileManager.default.createFile(atPath: currentLogURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: currentLogURL)
        bytes = 0
        let files = try logFiles()
        for url in files.prefix(max(0, files.count - maxFiles)) where url != currentLogURL {
            try FileManager.default.removeItem(at: url)
        }
    }
}

// Keep transport details useful while excluding URL capabilities, credentials
// and camera identifiers. This only changes diagnostic copies, never requests.
private enum DiagnosticRedaction {
    private static let sensitiveKeys: Set<String> = [
        "authorization", "proxyauthorization", "cookie", "setcookie", "token",
        "accesstoken", "refreshtoken", "idtoken", "apikey", "secret", "clientsecret",
        "password", "passwd", "key", "privatekey", "encryptionkey", "aeskey", "signature",
        "serial", "serialnumber", "seriallist", "gis"
    ]
    private static let mediaSuffixes: Set<String> = [
        "m3u8", "m3u", "mpd", "mp4", "mov", "m4v", "m4a", "mp3", "aac",
        "ts", "mkv", "webm", "flv", "h264", "h265", "hevc"
    ]
    private static let urls = try! NSRegularExpression(pattern: #"(?i)\b(?:https?|rtsps?|file)://[^\s<>"'\)\}]+"#)
    private static let replacements: [(NSRegularExpression, String)] = [
        (#"(?i)(\b(?:authorization|proxy-authorization|cookie|set-cookie)\s*[:=]\s*)[^\r\n]+"#, "$1<redacted>"),
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]+"#, "Bearer <redacted>"),
        (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, "<redacted>"),
        (#"(?i)\bc[0-9]{2}[a-z][0-9]{9,}\b"#, "<redacted>"),
        (#"(?i)(["']?\b(?:authorization|proxy-authorization|cookie|set-cookie|token|access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|client[_-]?secret|secret|password|passwd|private[_-]?key|signature|serial(?:[_-]?number|[_-]?list)?|gis)["']?\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;\}\]]+)"#, "$1<redacted>")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func value(_ input: Any) -> Any {
        if let fields = input as? [String: Any] {
            return fields.reduce(into: [String: Any]()) { output, field in
                let key = field.key.lowercased().filter { $0.isLetter || $0.isNumber }
                output[field.key] = sensitiveKeys.contains(key) ? "<redacted>" : value(field.value)
            }
        }
        if let values = input as? [Any] { return values.map(value) }
        if let string = input as? String { return text(string) }
        if let url = input as? URL { return text(url.absoluteString) }
        return input
    }

    static func text(_ input: String) -> String {
        var result = input
        for match in urls.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            guard let parts = URLComponents(string: String(result[range])) else {
                result.replaceSubrange(range, with: "<redacted-url>")
                continue
            }
            var safe = URLComponents()
            safe.scheme = parts.scheme
            safe.host = parts.host
            safe.port = parts.port
            let suffix = (parts.path as NSString).pathExtension.lowercased()
            let usefulSuffix = mediaSuffixes.contains(suffix)
            safe.path = "/<redacted>" + (usefulSuffix ? "." + suffix : "")
            result.replaceSubrange(range, with: safe.string ?? "<redacted-url>")
        }
        for (expression, replacement) in replacements {
            result = expression.stringByReplacingMatches(in: result,
                range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }
}

// Preserve the original engine's Console.log call sites.
enum Console {
    enum Level { case ERROR, INFO }
    static func log(type: Level = .INFO, _ message: @autoclosure () -> String,
                    file: String = #fileID, line: Int = #line, function: String = #function) {
        FTPlayerDiagnostic.shared.record(type == .ERROR ? "error" : "debug", "engine", message(),
            fields: ["file": file, "line": line, "function": function])
    }
}
