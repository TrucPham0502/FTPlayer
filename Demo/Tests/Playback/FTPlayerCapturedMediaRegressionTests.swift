import XCTest
import CoreVideo
@testable import FTPlayer

import Foundation
import Network

/// A loopback-only HLS source. No upstream URL, cookie or key is exposed to
/// FTPlayer; requests address the lifetime of one source session.
final class CapturedMediaHTTPServer {
    typealias Resource = (data: Data, contentType: String)
    var handler: ((String, @escaping (Result<Resource, Error>) -> Void) -> Void)?
    private let queue = DispatchQueue(label: "tests.captured-media.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var closed = false

    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                var answered = false
                listener.stateUpdateHandler = { [weak listener] state in
                    if !answered {
                        if case .ready = state, let port = listener?.port,
                           let url = URL(string: "http://127.0.0.1:\(port.rawValue)") {
                            answered = true
                            DispatchQueue.main.async { completion(.success(url)) }
                        } else if case .failed(let error) = state {
                            answered = true
                            DispatchQueue.main.async { completion(.failure(error)) }
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: self.queue)
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    func stop() {
        queue.async {
            self.closed = true
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel(); self.listener = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !closed, connections.count < 32 else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: key) }
            if case .failed = state { self?.connections.removeValue(forKey: key); connection?.cancel() }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            var request = buffer
            if let data { request.append(data) }
            if request.count > 16 * 1024 { self.send(connection, status: 431, body: Data()); return }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, request: request)
            } else if complete || error != nil { connection.cancel() }
            else { self.receive(connection, buffer: request) }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        guard let text = String(data: request, encoding: .utf8) else { send(connection, status: 400, body: Data()); return }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])),
              first[1].hasPrefix("/"), let components = URLComponents(string: String(first[1])),
              components.host == nil, components.query == nil else {
            send(connection, status: 400, body: Data()); return
        }
        let isHead = first[0] == "HEAD"
        let range = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("range:") })
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        guard let handler else { send(connection, status: 503, body: Data()); return }
        handler(components.path) { [weak self, weak connection] result in
            guard let self, let connection else { return }
            self.queue.async {
                guard !self.closed else { connection.cancel(); return }
                switch result {
                case .failure(let error):
                    self.send(connection, status: 502, body: Data(error.localizedDescription.utf8), head: isHead)
                case .success(let resource):
                    var body = resource.data
                    var headers = ["Content-Type": resource.contentType, "Accept-Ranges": "bytes"]
                    var status = 200
                    if let range {
                        guard let bounds = Self.byteRange(range, count: body.count) else {
                            self.send(connection, status: 416, body: Data(), headers: ["Content-Range": "bytes */\(body.count)"], head: isHead); return
                        }
                        status = 206
                        headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(body.count)"
                        body = body.subdata(in: bounds.lowerBound..<(bounds.upperBound + 1))
                    }
                    self.send(connection, status: status, body: body, headers: headers, head: isHead)
                }
            }
        }
    }

    static func byteRange(_ value: String, count: Int) -> ClosedRange<Int>? {
        guard count > 0, value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return max(0, count - min(count, suffix))...(count - 1)
        }
        guard let start = Int(parts[0]), start >= 0, start < count else { return nil }
        let end: Int
        if parts[1].isEmpty { end = count - 1 }
        else { guard let parsed = Int(parts[1]), parsed >= start else { return nil }; end = min(parsed, count - 1) }
        return start...end
    }

    private func send(_ connection: NWConnection, status: Int, body: Data,
                      headers: [String: String] = [:], head: Bool = false) {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 416: "Range Not Satisfiable", 431: "Request Header Fields Too Large", 502: "Bad Gateway", 503: "Service Unavailable"][status] ?? "Error"
        var text = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\n"
        for (key, value) in headers { text += "\(key): \(value)\r\n" }
        text += "\r\n"
        var response = Data(text.utf8)
        if !head { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private struct CapturedFixtureID {
    let value: String
    init(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw PlaybackTestError.assertion("Invalid local fixture identifier")
        }
        self.value = value
    }
    func segmentPath(variant: String) throws -> String {
        guard ["v", "vt"].contains(variant) else { throw PlaybackTestError.assertion("Invalid fixture variant") }
        return "/\(value)/\(variant)/index.m3u8"
    }
}

private struct CapturedPlaylist {
    struct Segment { let duration: Double; let discontinuity: Bool }
    let segments: [Segment]
    var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    func manifest(prefix: String) throws -> Data {
        guard !segments.isEmpty, segments.count <= 10000,
              segments.allSatisfy({ $0.duration.isFinite && $0.duration > 0 && $0.duration < 86400 }) else {
            throw PlaybackTestError.assertion("Invalid captured fixture durations")
        }
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(Int(ceil(segments.map(\.duration).max()!)))\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for (index, segment) in segments.enumerated() {
            if segment.discontinuity { text += "#EXT-X-DISCONTINUITY\n" }
            text += "#EXTINF:\(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), segment.duration)),\n\(prefix)/segment/\(index).ts\n"
        }
        return Data((text + "#EXT-X-ENDLIST\n").utf8)
    }
}

/// Captured source traits are replayed locally through the real SDK. No source
/// resolver or provider API is present, and no private recording/identifier is used.
final class FTPlayerCapturedMediaRegressionTests: PlaybackTestCase {
    func testIDValidationDoesNotAcceptURLsOrPathInjection() throws {
        XCTAssertEqual(try CapturedFixtureID(" clip_123\n").value, "clip_123")
        XCTAssertEqual(try CapturedFixtureID("id_-123").segmentPath(variant: "vt"), "/id_-123/vt/index.m3u8")
        for input in ["", " ", "../video", URL(fileURLWithPath: "/tmp/video.ts").absoluteString, "a/b", "a?x", "a#x"] {
            XCTAssertThrowsError(try CapturedFixtureID(input))
        }
        XCTAssertThrowsError(try CapturedFixtureID("id").segmentPath(variant: "other"))
    }

    func testManifestContainsOnlyLoopbackSegmentRoutesAndPreservesDiscontinuities() throws {
        let playlist = CapturedPlaylist(segments: [.init(duration: 16.666667, discontinuity: false), .init(duration: 8.3, discontinuity: true)])
        let text = String(decoding: try playlist.manifest(prefix: "/session"), as: UTF8.self)
        XCTAssertTrue(text.contains("#EXT-X-TARGETDURATION:17"))
        XCTAssertTrue(text.contains("#EXT-X-DISCONTINUITY\n#EXTINF:8.300000,\n/session/segment/1.ts"))
        XCTAssertTrue(text.hasSuffix("#EXT-X-ENDLIST\n"))
        XCTAssertFalse(text.contains("KEY")); XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("://"))
    }

    func testManifestRejectsEmptyAndInvalidDurations() {
        for durations: [Double] in [[], [0], [-1], [.nan], [.infinity], [86400]] {
            let source = CapturedPlaylist(segments: durations.map { .init(duration: $0, discontinuity: false) })
            XCTAssertThrowsError(try source.manifest(prefix: "/session"))
        }
    }

    func testByteRangesHandleOpenEndedSuffixAndInvalidRequests() {
        XCTAssertEqual(CapturedMediaHTTPServer.byteRange("bytes=2-5", count: 10), 2...5)
        XCTAssertEqual(CapturedMediaHTTPServer.byteRange("bytes=8-999", count: 10), 8...9)
        XCTAssertEqual(CapturedMediaHTTPServer.byteRange("bytes=3-", count: 10), 3...9)
        XCTAssertEqual(CapturedMediaHTTPServer.byteRange("bytes=-3", count: 10), 7...9)
        for value in ["bytes=10-", "bytes=4-2", "bytes=0-1,4-5", "bytes=-0", "bytes=999999999999999999999999-", "invalid"] {
            XCTAssertNil(CapturedMediaHTTPServer.byteRange(value, count: 10))
        }
        XCTAssertNil(CapturedMediaHTTPServer.byteRange("bytes=0-", count: 0))
    }

    func testLoopbackServerReturnsPartialContentAndHEADWithoutBody() throws {
        let server = CapturedMediaHTTPServer(); defer { server.stop() }
        let bytes = Data("0123456789".utf8)
        server.handler = { _, done in done(.success((bytes, "video/mp2t"))) }
        let url = try startServer(server)
        XCTAssertEqual(url.host, "127.0.0.1")
        let done = expectation(description: "range/head/invalid range"); done.expectedFulfillmentCount = 3
        var get = URLRequest(url: url.appendingPathComponent("segment.ts")); get.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        URLSession.shared.dataTask(with: get) { body, response, error in
            XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 2-5/10")
            XCTAssertEqual(body, Data("2345".utf8)); done.fulfill()
        }.resume()
        var head = URLRequest(url: url); head.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: head) { body, response, error in
            XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "10")
            XCTAssertEqual(body?.count ?? 0, 0); done.fulfill()
        }.resume()
        var bad = URLRequest(url: url); bad.setValue("bytes=10-", forHTTPHeaderField: "Range")
        URLSession.shared.dataTask(with: bad) { _, response, error in
            XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 416); done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
    }

    // Retain the original case names and assertions on duration, decoded frames,
    // seek completion, near-target output and progress. Source resolution becomes
    // a deterministic fixture lookup; it is not counted as a live API check.
    func testIDResolvesAndFPlayerRendersThenSeeks() throws { try verifyPlayback(cache: false, fixtureID: "baseline", partial: false) }
    func testCachedIDRendersAndSeeksForwardThenBackward() throws { try verifyPlayback(cache: true, fixtureID: "cached", partial: false) }
    func testReportedIDRendersAndSeeksForwardThenBackward() throws { try verifyPlayback(cache: true, fixtureID: "reported-a", partial: false) }
    func testReportedV1IDRendersAndSeeksForwardThenBackward() throws { try verifyPlayback(cache: true, fixtureID: "reported-b", partial: true) }

    private func startServer(_ server: CapturedMediaHTTPServer) throws -> URL {
        let ready = expectation(description: "loopback media ready")
        var result: Result<URL, Error>?
        server.start { result = $0; ready.fulfill() }
        wait(for: [ready], timeout: 5)
        return try XCTUnwrap(result).get()
    }

    private func verifyPlayback(cache: Bool, fixtureID: String, partial: Bool) throws {
        let id = try CapturedFixtureID(fixtureID)
        let prefix = "/\(id.value)"
        let payload = try Data(contentsOf: fixture(partial ? "captured-leading-partial.ts" : "h264.ts"))
        let source = CapturedPlaylist(segments: (0..<36).map { .init(duration: 30, discontinuity: $0 > 0) })
        let manifest = try source.manifest(prefix: prefix)
        let media = CapturedMediaHTTPServer(); defer { media.stop() }
        media.handler = { path, done in
            if path == prefix + "/index.m3u8" {
                done(.success((manifest, "application/vnd.apple.mpegurl")))
            } else if path.hasPrefix(prefix + "/segment/"), path.hasSuffix(".ts") {
                done(.success((payload, "video/mp2t")))
            } else { done(.failure(PlaybackTestError.assertion("Unknown local captured fixture route"))) }
        }
        let base = try startServer(media)
        let url = base.appendingPathComponent(id.value).appendingPathComponent("index.m3u8")
        if partial {
            let checked = expectation(description: "first partial packet fixture")
            URLSession.shared.dataTask(with: url.deletingLastPathComponent().appendingPathComponent("segment/0.ts")) { data, response, error in
                XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertEqual(data, payload, "Fixture transport altered captured packet bytes")
                checked.fulfill()
            }.resume()
            wait(for: [checked], timeout: 5)
        }
        let s = try start(url, cache: cache, policy: .automatic)
        try require(until(60) { s.sink.frames >= 10 || s.failure != nil }, "No decoded source frames")
        XCTAssertNil(s.failure); XCTAssertGreaterThanOrEqual(s.sink.frames, 10)
        XCTAssertGreaterThan(s.player.duration, 1000)
        for target in [s.player.duration * 0.5, 30, s.player.duration * 0.8] {
            let frame = s.sink.frames
            var completed: Bool?
            s.player.seek(to: target) { completed = $0 }
            try require(until(partial ? 180 : 60) {
                completed != nil && s.sink.presentationTimes(after: frame).filter { $0 >= target - 0.15 && $0 <= target + 3 }.count >= 10 || s.failure != nil
            }, "Source did not render ten frames near seek target")
            XCTAssertEqual(completed, true); XCTAssertNil(s.failure)
            XCTAssertEqual(s.player.progress, target, accuracy: 4)
            s.measurements.append(["operation": "captured-source-seek", "fixture": fixtureID, "partialPacket": partial, "cache": cache,
                                   "target": target, "clock": s.player.currentTime, "duration": s.player.duration, "completed": completed == true, "newFrames": s.sink.frames - frame,
                                   "nearTargetFrames": s.sink.presentationTimes(after: frame).filter { $0 >= target - 0.15 && $0 <= target + 3 }.count])
        }
        XCTAssertGreaterThan(s.sink.frames, 10)
        s.stop()
    }
}
