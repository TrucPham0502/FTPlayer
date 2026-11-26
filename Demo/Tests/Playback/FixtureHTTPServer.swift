import Foundation
import Network
import CommonCrypto

/// Loopback HTTP fixture server. Records requests, supports Range, redirects and controlled failures.
final class FixtureHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FTPlayer.tests.http")
    private lazy var patternData: Data = {
        var bytes = Data(count: 24 * 1024 * 1024)
        bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i ^ (i >> 9) ^ (i >> 17)) }
        }
        return bytes
    }()
    private lazy var largePatternData = Data(repeating: 0x5a, count: 80 * 1024 * 1024)
    private let root: URL
    private lazy var rangedTS: (playlist: Data, media: Data) = {
        var media = Data(), playlist = "#EXTM3U\n#EXT-X-VERSION:4\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n"
        let source = (try? String(contentsOf: root.appendingPathComponent("hls-ts/index.m3u8"), encoding: .utf8)) ?? ""
        var duration = "", index = 0
        for line in source.components(separatedBy: .newlines) {
            if line.hasPrefix("#EXTINF:") { duration = line }
            if line.hasSuffix(".ts"), let part = try? Data(contentsOf: root.appendingPathComponent("hls-ts/\(line)")) {
                let offset = index % 2 == 0 ? "@\(media.count)" : ""
                playlist += "\(duration)\n#EXT-X-BYTERANGE:\(part.count)\(offset)\nmain.ts\n"
                media.append(part); index += 1
            }
        }
        return (Data((playlist+"#EXT-X-ENDLIST\n").utf8), media)
    }()
    private lazy var rotatingAESPlaylist: Data = {
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:73\n"
        let source = (try? String(contentsOf: root.appendingPathComponent("hls-ts/index.m3u8"), encoding: .utf8)) ?? ""
        var duration = "", index = 0
        for line in source.components(separatedBy: .newlines) {
            if line.hasPrefix("#EXTINF:") { duration = line }
            if line.hasSuffix(".ts") {
                if index < 9, index % 3 == 0 { text += "#EXT-X-KEY:METHOD=AES-128,URI=\"key\((index/3)%2).bin\"\n" }
                if index == 9 { text += "#EXT-X-KEY:METHOD=NONE\n" }
                text += "\(duration)\nsegment\(index).ts\n"; index += 1
            }
        }
        return Data((text+"#EXT-X-ENDLIST\n").utf8)
    }()
    private func encryptedTestSegment(_ data: Data, index: Int) -> Data {
        let key = Data(repeating: (index/3)%2 == 0 ? 0x5a : 0xa5, count: 16)
        var iv = Data(count: 16)
        for byte in 0..<8 { iv[15-byte] = UInt8(truncatingIfNeeded: UInt64(73+index) >> (8*byte)) }
        let capacity = data.count + kCCBlockSizeAES128
        var output = Data(count: capacity), count = 0
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key.baseAddress, 16, iv.baseAddress, source.baseAddress, data.count,
                        destination.baseAddress, capacity, &count)
            } } }
        }
        precondition(status == kCCSuccess)
        return output.prefix(count)
    }
    private lazy var rangedHLS: (playlist: Data, media: Data) = {
        var media = (try? Data(contentsOf: root.appendingPathComponent("hls-fmp4/init.mp4"))) ?? Data()
        var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:3\n#EXT-X-MAP:URI=\"main.mp4\",BYTERANGE=\"\(media.count)@0\"\n"
        let source = (try? String(contentsOf: root.appendingPathComponent("hls-fmp4/index.m3u8"), encoding: .utf8)) ?? ""
        var duration = ""
        for line in source.components(separatedBy: .newlines) {
            if line.hasPrefix("#EXTINF:") { duration = line }
            if line.hasSuffix(".m4s"), let part = try? Data(contentsOf: root.appendingPathComponent("hls-fmp4/\(line)")) {
                playlist += "\(duration)\n#EXT-X-BYTERANGE:\(part.count)@\(media.count)\nmain.mp4\n"
                media.append(part)
            }
        }
        playlist += "#EXT-X-ENDLIST\n"
        return (Data(playlist.utf8), media)
    }()
    // Stored DEFLATE blocks keep the fixture self-contained. Its gzip wire size
    // differs from the decoded MP4 size that URLSession delivers to the SDK.
    private lazy var gzipVideo: Data = {
        let source = (try? Data(contentsOf: root.appendingPathComponent("faststart.mp4"))) ?? Data()
        var result = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255])
        for offset in stride(from: 0, to: source.count, by: 65535) {
            let count = min(65535, source.count - offset)
            result.append(offset + count == source.count ? 1 : 0)
            result.append(contentsOf: [UInt8(count & 255), UInt8(count >> 8), UInt8((~count) & 255), UInt8(((~count) >> 8) & 255)])
            result.append(source.subdata(in: offset..<(offset + count)))
        }
        var crc: UInt32 = 0xffffffff
        for byte in source {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        for value in [~crc, UInt32(source.count)] {
            for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        return result
    }()
    private let mp4HEADStatus: Int?
    private let mp4HEADDelay: TimeInterval
    private var connections: [NWConnection] = []
    private let lock = NSLock()
    enum NetworkMode { case online, disconnect, stall, unavailable, httpError(Int) }
    private var networkMode: NetworkMode = .online
    private var bodyBytesPerSecond: Int?
    private var bodyBurstBytes = 0
    private var deliveredThrottledBytes: Int64 = 0
    var throttledBytes: Int64 { lock.withLock { deliveredThrottledBytes } }
    /// Pace actual response bytes; metadata/HEAD remain available. Changing the
    /// limit also affects already-running paced responses on their next chunk.
    func setBodyBytesPerSecond(_ value: Int?, initialBurstBytes: Int = 0, dropExistingConnections: Bool = false) {
        lock.withLock { bodyBytesPerSecond = value.map { max(1, $0) }; bodyBurstBytes = max(0, initialBurstBytes) }
        if dropExistingConnections { queue.sync { connections.forEach { $0.cancel() } } }
    }
    private var dropNextBodyAfter: Int?
    private var disconnectAfterBodyDrop = false
    private var stallAfterBodyDrop = false
    private var stallNextHeaders = false
    private var holdMediaBodies = false
    func stallMediaBodies() { lock.lock(); holdMediaBodies = true; lock.unlock() }
    func stallNextGETHeaders() { lock.lock(); stallNextHeaders = true; lock.unlock() }
    func prepareCachePattern() { queue.sync { _ = patternData } }
    func dropNextBody(afterBytes: Int, thenDisconnect: Bool = false) {
        lock.lock(); dropNextBodyAfter = afterBytes; disconnectAfterBodyDrop = thenDisconnect; stallAfterBodyDrop = false; lock.unlock()
    }
    func stallNextBody(afterBytes: Int) {
        lock.lock(); dropNextBodyAfter = afterBytes; disconnectAfterBodyDrop = false; stallAfterBodyDrop = true; lock.unlock()
    }
    func setNetworkMode(_ mode: NetworkMode, dropExistingConnections: Bool = false) {
        lock.lock(); networkMode = mode; lock.unlock()
        if dropExistingConnections { queue.sync { connections.forEach { $0.cancel() } } }
    }
    private var recorded: [String] = []
    private var recordedRanges: [String] = []
    var rangeRequests: [String] { lock.lock(); defer { lock.unlock() }; return recordedRanges }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }

    init(root: URL, mp4HEADStatus: Int? = nil, mp4HEADDelay: TimeInterval = 0) throws {
        self.root = root; self.mp4HEADStatus = mp4HEADStatus; self.mp4HEADDelay = mp4HEADDelay
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            throw NSError(domain: "FixtureHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Loopback listener did not start"])
        }
    }
    func url(_ path: String) -> URL { baseURL.appendingPathComponent(path) }
    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                self.respond(connection, text)
            } else if error == nil && !complete && request.count < 65536 {
                self.receive(connection, accumulated: request)
            } else { connection.cancel() }
        }
    }
    private func respond(_ connection: NWConnection, _ text: String, allowDelay: Bool = true, recordRequest: Bool = true) {
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { connection.cancel(); return }
        let method = String(first[0]), target = String(first[1])
        if allowDelay, method == "GET", target.hasPrefix("/slow-first-byte.mp4") {
            queue.asyncAfter(deadline: .now() + 6) { [weak self] in self?.respond(connection, text, allowDelay: false) }
            return
        }
        lock.lock()
        if recordRequest { recorded.append(method + " " + target) }
        if recordRequest, method == "GET", let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            recordedRanges.append(range.components(separatedBy: "bytes=").last!.trimmingCharacters(in: .whitespaces))
        }
        let mode = networkMode
        let stallHeaders = method == "GET" && stallNextHeaders
        if stallHeaders { stallNextHeaders = false }
        lock.unlock()
        if stallHeaders { return }
        switch mode {
        case .disconnect: connection.cancel(); return
        case .stall: return
        case .unavailable:
            send(connection, status: 503, body: Data("temporary network failure".utf8), head: method == "HEAD"); return
        case .httpError(let code):
            send(connection, status: code, body: Data("controlled HTTP error".utf8), head: method == "HEAD"); return
        case .online: break
        }
        if allowDelay, method == "HEAD", target.contains(".mp4"), mp4HEADDelay > 0 {
            queue.asyncAfter(deadline: .now() + mp4HEADDelay) { [weak self] in self?.respond(connection, text, allowDelay: false, recordRequest: false) }
            return
        }
        let components = URLComponents(string: "http://localhost" + target)!
        var path = components.path
        let delayedEOF = path.hasPrefix("/delayed-eof/")
        if delayedEOF { path = String(path.dropFirst("/delayed-eof".count)) }
        if path == "/gzip-full.mp4" || path == "/gzip-range.mp4" {
            var headers = ["Content-Type": "video/mp4", "Content-Encoding": "gzip"]
            let ranged = path == "/gzip-range.mp4"
            if ranged { headers["Content-Range"] = "bytes 0-\(gzipVideo.count - 1)/\(gzipVideo.count)" }
            send(connection, status: ranged ? 206 : 200, headers: headers, body: gzipVideo, head: method == "HEAD"); return
        }
        if path == "/non-authoritative.mp4" {
            let data = (try? Data(contentsOf: root.appendingPathComponent("faststart.mp4"))) ?? Data()
            send(connection, status: 203, headers: ["Content-Type": "video/mp4"], body: data, head: method == "HEAD"); return
        }
        if path == "/stale-head.mp4", method == "HEAD" {
            // A delayed metadata response disagrees with the actual GET object.
            send(connection, status: 200, body: Data([0]), head: true); return
        }
        if path == "/stale-head.mp4" { path = "/faststart.mp4" }
        if path == "/no-size-probe.mp4" {
            if lines.contains(where: { $0.lowercased() == "range: bytes=0-0" }) {
                send(connection, status: 403, body: Data(), head: method == "HEAD"); return
            }
            path = "/faststart.mp4"
        }
        let rangeCases = ["/wrong-range.mp4", "/missing-range.mp4", "/invalid-total.mp4", "/invalid-length.mp4", "/backwards-range.mp4", "/unknown-total.mp4", "/short-range.mp4"]
        if rangeCases.contains(path) {
            let body = (try? Data(contentsOf: root.appendingPathComponent("faststart.mp4"))) ?? Data()
            var headers = ["Content-Type": "video/mp4"]
            if path == "/wrong-range.mp4" { headers["Content-Range"] = "bytes 0-1023/\(body.count)" }
            if path == "/invalid-total.mp4" { headers["Content-Range"] = "bytes 4096-5119/5119" }
            if path == "/invalid-length.mp4" { headers["Content-Range"] = "bytes 4096-6143/\(body.count)" }
            if path == "/backwards-range.mp4" { headers["Content-Range"] = "bytes 5119-4096/\(body.count)" }
            let valid = path == "/unknown-total.mp4" || path == "/short-range.mp4"
            if valid { headers["Content-Range"] = "bytes 4096-5119/\(path == "/unknown-total.mp4" ? "*" : String(body.count))" }
            send(connection, status: 206, headers: headers, body: valid ? body.subdata(in: 4096..<5120) : Data(body.prefix(1024)), head: method == "HEAD"); return
        }
        if path == "/chunked.mp4" || path == "/close-delimited.mp4" || path == "/truncated-chunked.mp4" {
            let body = (try? Data(contentsOf: root.appendingPathComponent("faststart.mp4"))) ?? Data()
            let chunked = path != "/close-delimited.mp4"
            var response = Data(("HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nConnection: close\r\n" +
                (chunked ? "Transfer-Encoding: chunked\r\n" : "") + "\r\n").utf8)
            if method != "HEAD" {
                if path == "/truncated-chunked.mp4" {
                    response.append(Data("1000\r\n".utf8)); response.append(body.prefix(1024))
                } else if chunked {
                    for start in stride(from: 0, to: body.count, by: 8192) {
                        let part = body.subdata(in: start..<min(start + 8192, body.count))
                        response.append(Data("\(String(part.count, radix: 16))\r\n".utf8))
                        response.append(part); response.append(Data("\r\n".utf8))
                    }
                    response.append(Data("0\r\n\r\n".utf8))
                } else { response.append(body) }
            }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        if path == "/partial-audio-pressure.m3u8" {
            var playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:30\n"
            for i in 0..<256 {
                if i > 0 { playlist += "#EXT-X-DISCONTINUITY\n" }
                playlist += "#EXTINF:30,\n\(i == 0 ? "partial-audio.mp4" : "empty-audio.mp4")?segment=\(i)\n"
            }
            playlist += "#EXT-X-ENDLIST\n"
            send(connection, status: 200, body: Data(playlist.utf8), head: method == "HEAD"); return
        }
        if path == "/empty-audio-hls.m3u8" {
            var playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:30\n"
            // More packets than the RAM budget; EOF cannot release startup.
            for i in 0..<256 {
                if i > 0 { playlist += "#EXT-X-DISCONTINUITY\n" }
                playlist += "#EXTINF:30,\nempty-audio.mp4?segment=\(i)\n"
            }
            playlist += "#EXT-X-ENDLIST\n"
            send(connection, status: 200, body: Data(playlist.utf8), head: method == "HEAD"); return
        }
        if path == "/late-audio-hls.m3u8" {
            let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:30\n#EXTINF:30,\nempty-audio.mp4\n#EXT-X-DISCONTINUITY\n#EXTINF:30,\naudio-present.mp4\n#EXT-X-ENDLIST\n"
            send(connection, status: 200, body: Data(playlist.utf8), head: method == "HEAD"); return
        }
        if path == "/repeated-independent.m3u8" {
            var playlist = "#EXTM3U\n"
            for i in 0..<32 {
                if i > 0 { playlist += "#EXT-X-DISCONTINUITY\n" }
                playlist += "#EXTINF:30,\nfaststart.mp4\n"
            }
            playlist += "#EXT-X-ENDLIST\n"
            send(connection, status: 200, body: Data(playlist.utf8), head: method == "HEAD"); return
        }
        if path == "/hls-ranged/index.m3u8" {
            send(connection, status: 200, body: rangedHLS.playlist, head: method == "HEAD"); return
        }
        if path == "/hls-ranged-ts/index.m3u8" {
            send(connection, status: 200, body: rangedTS.playlist, head: method == "HEAD"); return
        }
        if path == "/hls-rotating-aes/index.m3u8" {
            send(connection, status: 200, body: rotatingAESPlaylist, head: method == "HEAD"); return
        }
        if path == "/hls-rotating-aes/key0.bin" || path == "/hls-rotating-aes/key1.bin" {
            send(connection, status: 200, body: Data(repeating: path.contains("key0") ? 0x5a : 0xa5, count: 16), head: method == "HEAD"); return
        }
        if path == "/hls-aes128/master.m3u8" {
            send(connection, status: 200, body: Data("#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXT-X-STREAM-INF:BANDWIDTH=500000\nindex.m3u8\n".utf8), head: method == "HEAD"); return
        }
        if path == "/hls-independent-opaque/index.m3u8" {
            let text = "#EXTM3U\n#EXTINF:30,\nasset?part=0\n#EXT-X-DISCONTINUITY\n#EXTINF:30,\nasset?part=1\n#EXT-X-ENDLIST\n"
            send(connection, status: 200, body: Data(text.utf8), head: method == "HEAD"); return
        }
        if path == "/hls-unknown-total/index.m3u8" {
            let text = "#EXTM3U\n#EXTINF:30,\n../faststart.mp4?part=0\n#EXT-X-DISCONTINUITY\n#EXTINF:30,\n../faststart.mp4?part=1\n#EXT-X-DISCONTINUITY\n#EXTINF:30,\n../status/503?part=2\n#EXT-X-DISCONTINUITY\n#EXTINF:30,\n../status/503?part=3\n#EXT-X-ENDLIST\n"
            send(connection, status: 200, body: Data(text.utf8), head: method == "HEAD"); return
        }
        if path == "/hls-independent-opaque/asset" { path = "/faststart.mp4" }
        for (opaque, original, suffix) in [("hls-opaque-ts", "hls-ts", "ts"), ("hls-opaque-fmp4", "hls-fmp4", "m4s")] {
            if path == "/\(opaque)/index.m3u8" {
                let source = (try? String(contentsOf: root.appendingPathComponent("\(original)/index.m3u8"), encoding: .utf8)) ?? ""
                send(connection, status: 200, body: Data(source.replacingOccurrences(of: ".\(suffix)\n", with: ".payload\n").utf8), head: method == "HEAD"); return
            }
            if path.hasPrefix("/\(opaque)/") {
                path = path.replacingOccurrences(of: "/\(opaque)/", with: "/\(original)/").replacingOccurrences(of: ".payload", with: ".\(suffix)")
            }
        }
        if path == "/hls-changing-map/index.m3u8" {
            let source = (try? String(contentsOf: root.appendingPathComponent("hls-fmp4/index.m3u8"), encoding: .utf8)) ?? ""
            let text = source.replacingOccurrences(of: "#EXTINF:2.416667,\nsegment4.m4s", with: "#EXT-X-MAP:URI=\"init.mp4?generation=2\"\n#EXTINF:2.416667,\nsegment4.m4s")
            send(connection, status: 200, body: Data(text.utf8), head: method == "HEAD"); return
        }
        if path.hasPrefix("/hls-changing-map/") { path = path.replacingOccurrences(of: "/hls-changing-map/", with: "/hls-fmp4/") }
        if path == "/hls-master-audio/redirect" {
            send(connection, status: 302, headers: ["Location": url("hls-master-audio/stream").absoluteString], body: Data(), head: method == "HEAD"); return
        }
        if path == "/hls-master-audio/stream" { path = "/hls-master-audio/master.m3u8" }
        if path == "/hls-master-audio/master.m3u8" {
            let playlist = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"sound\",NAME=\"Audio, main\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"sound\",NAME=\"Unused\",DEFAULT=NO,URI=\"unused-audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=500000,CODECS=\"hvc1,mp4a.40.2\",AUDIO=\"sound\"\n../hls-hevc/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO=\"sound\"\nunused-video.m3u8\n"
            send(connection, status: 200, body: Data(playlist.utf8), head: method == "HEAD"); return
        }
        if path == "/hls-master-audio/audio.m3u8" {
            let media = (try? Data(contentsOf: root.appendingPathComponent("hls-master-audio.mp4"))) ?? Data()
            var offset = 0
            while offset + 8 <= media.count {
                let size = media[offset..<(offset+4)].reduce(0) { ($0 << 8) | Int($1) }
                if String(data: media.subdata(in: (offset+4)..<(offset+8)), encoding: .ascii) == "moof" { break }
                guard size >= 8 else { break }; offset += size
            }
            let playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:31\n#EXT-X-MAP:URI=\"main.mp4\",BYTERANGE=\"\(offset)@0\"\n#EXTINF:30.022,\n#EXT-X-BYTERANGE:\(media.count-offset)@\(offset)\nmain.mp4\n#EXT-X-ENDLIST\n"
            send(connection, status: 200, body: Data(playlist.utf8), head: method == "HEAD"); return
        }
        if path == "/hls-master-audio/main.mp4" { path = "/hls-master-audio.mp4" }
        if path == "/redirect-independent.m3u8" {
            send(connection, status: 302, headers: ["Location": url("recordings/index.m3u8").absoluteString], body: Data(), head: method == "HEAD"); return
        }
        if path == "/redirect-hls-stream" {
            send(connection, status: 302, headers: ["Location": url("hls-ts/stream").absoluteString], body: Data(), head: method == "HEAD"); return
        }
        if path == "/redirect-independent-stream" {
            send(connection, status: 302, headers: ["Location": url("recordings/stream").absoluteString], body: Data(), head: method == "HEAD"); return
        }
        if path == "/recordings/index.m3u8" || path == "/recordings/stream" {
            let playlist = "#EXTM3U\n#EXTINF:16,\nfirst.mp4\n#EXT-X-DISCONTINUITY\n#EXTINF:16,\nsecond.mp4\n#EXT-X-ENDLIST\n"
            send(connection, status: 200, body: Data(playlist.utf8), head: method == "HEAD"); return
        }
        if path == "/recordings/first.mp4" || path == "/recordings/second.mp4" { path = "/faststart.mp4" }
        for directory in ["hls-ts", "hls-fmp4", "hls-aes128"] {
            if path == "/\(directory)/stream" || path == "/\(directory)/wrong.mp4" { path = "/\(directory)/index.m3u8" }
        }
        if path == "/independent-stream" { path = "/independent-hls.m3u8" }
        if path == "/zero-duration-independent-hls.m3u8" {
            var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:30\n"
            for index in 0..<4 {
                if index > 0 { playlist += "#EXT-X-DISCONTINUITY\n" }
                playlist += "#EXTINF:\(index == 3 ? 0 : 30),\nfaststart.mp4?segment=\(index)\n"
            }
            playlist += "#EXT-X-ENDLIST\n"
            send(connection, status: 200, body: Data(playlist.utf8), head: method == "HEAD"); return
        }
        if path == "/independent-hls.m3u8" || path == "/single-independent-hls.m3u8" || path == "/large-independent-hls.m3u8" {
            var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n"
            let single = path == "/single-independent-hls.m3u8"
            for i in 0..<(single ? 1 : (path == "/large-independent-hls.m3u8" ? 512 : 32)) {
                if i > 0 { playlist += "#EXT-X-DISCONTINUITY\n" }
                playlist += "#EXTINF:\(single ? 30 : 16),\nfaststart.mp4?segment=\(i)\n"
            }
            playlist += "#EXT-X-ENDLIST\n"
            send(connection, status: 200, body: Data(playlist.utf8), head: method == "HEAD"); return
        }
        if method == "HEAD", path.hasSuffix(".mp4"), let status = mp4HEADStatus {
            send(connection, status: status, body: Data(), head: true); return
        }
        if path == "/slow-first-byte.mp4" { path = "/faststart.mp4" }
        if path == "/head-stall.mp4" && method == "HEAD" { return }
        if path == "/head-stall.mp4" { path = "/faststart.mp4" }
        if path == "/stall" || path == "/stall.mp4" { return } // Keep socket open until stop().
        if path == "/redirect" {
            send(connection, status: 302, headers: ["Location": url("sample.mp4").absoluteString], body: Data(), head: method == "HEAD"); return
        }
        if path.hasPrefix("/status/") {
            send(connection, status: Int(path.split(separator: "/").last!) ?? 500, body: Data("controlled error".utf8), head: method == "HEAD"); return
        }
        if path == "/invalid.m3u8" {
            send(connection, status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:2,\nmissing-segment.ts\n#EXT-X-ENDLIST\n".utf8), head: method == "HEAD"); return
        }
        if path == "/empty.mp4" || path == "/empty.m3u8" { send(connection, status: 200, body: Data(), head: method == "HEAD"); return }
        if path == "/truncated.mp4" {
            let data = (try? Data(contentsOf: root.appendingPathComponent("sample.mp4"))) ?? Data()
            send(connection, status: 200, body: Data(data.prefix(512)), head: method == "HEAD"); return
        }
        if path == "/html.mp4" {
            send(connection, status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>not a video</html>".utf8), head: method == "HEAD"); return
        }
        let noRange = path == "/no-range.mp4" || path == "/cache-no-range.bin"
        let unknownRangeTotal = path == "/unknown-range-total.mp4"
        if unknownRangeTotal { path = "/faststart.mp4" }
        if path == "/no-range.mp4" { path = "/faststart.mp4" }
        if path == "/no-extension" || path == "/wrong-mime.mp4" { path = "/sample.mp4" }
        let source: Data?
        if path.hasPrefix("/hls-rotating-aes/segment"),
           let index = Int(path.components(separatedBy: "segment").last!.replacingOccurrences(of: ".ts", with: "")),
           let bytes = try? Data(contentsOf: root.appendingPathComponent("hls-ts/segment\(index).ts")) {
            source = index < 9 ? encryptedTestSegment(bytes, index: index) : bytes
        }
        else if path == "/hls-ranged-ts/main.ts" { source = rangedTS.media }
        else if path == "/hls-ranged/main.mp4" { source = rangedHLS.media }
        else if path == "/cache-large-pattern.bin" { source = largePatternData }
        else if path == "/cache-pattern.bin" || path == "/cache-no-range.bin" {
            // 24 MB, position-dependent content; no large binary fixture in the SDK repository.
            source = patternData
        } else { source = try? Data(contentsOf: root.appendingPathComponent(String(path.dropFirst()))) }
        guard !path.contains(".."), let data = source else {
            send(connection, status: 404, body: Data(), head: method == "HEAD"); return
        }
        if delayedEOF, path.hasSuffix(".ts"), method == "GET" {
            // Deliver the unchanged TS bytes before its HTTP EOF. This leaves
            // the final decoded picture waiting while the demux read is busy.
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)
            response.append(Data("\(String(data.count, radix: 16))\r\n".utf8))
            response.append(data); response.append(Data("\r\n".utf8))
            connection.send(content: response, completion: .contentProcessed { error in
                guard error == nil else { connection.cancel(); return }
                self.queue.asyncAfter(deadline: .now() + 0.4) {
                    connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            })
            return
        }
        var headers = ["Accept-Ranges": "bytes", "Content-Type": mime(path)]
        if components.path == "/wrong-mime.mp4" { headers["Content-Type"] = "text/plain" }
        if noRange { headers.removeValue(forKey: "Accept-Ranges") }
        if !noRange, let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let spec = rangeLine.components(separatedBy: "bytes=").last {
            let range = spec.split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(range[0]) ?? 0
            guard start >= 0, start < data.count else {
                send(connection, status: 416, headers: ["Content-Range": "bytes */\(data.count)"], body: Data(), head: method == "HEAD"); return
            }
            let end = min(data.count - 1, range.count > 1 ? (Int(range[1]) ?? data.count - 1) : data.count - 1)
            headers["Content-Range"] = "bytes \(start)-\(end)/\(unknownRangeTotal ? "*" : String(data.count))"
            // Keep an explicitly requested trailing moov index readable during
            // bandwidth tests. It is metadata, not forward media lookahead.
            let metadata = isMP4MetadataRange(data, start: start, end: end)
            send(connection, status: 206, headers: headers, body: data.subdata(in: start..<(end + 1)), head: method == "HEAD", paceBody: !metadata)
        } else { send(connection, status: 200, headers: headers, body: data, head: method == "HEAD") }
    }
    private func mime(_ path: String) -> String {
        switch (path as NSString).pathExtension {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "mp4", "m4s", "m4a": return "video/mp4"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }
    private func isMP4MetadataRange(_ data: Data, start: Int, end: Int) -> Bool {
        guard lock.withLock({ bodyBytesPerSecond != nil }), data.count >= 8,
              String(data: data.subdata(in: 4..<8), encoding: .ascii) == "ftyp" else { return false }
        var offset = 0
        while offset + 8 <= data.count {
            var size = data[offset..<(offset+4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            if size == 1 {
                guard offset + 16 <= data.count else { return false }
                size = data[(offset+8)..<(offset+16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
            guard size >= 8, size <= UInt64(data.count-offset) else { return false }
            if String(data: data.subdata(in: (offset+4)..<(offset+8)), encoding: .ascii) == "moov" {
                return start >= offset && end < offset + Int(size)
            }
            offset += Int(size)
        }
        return false
    }
    private func send(_ connection: NWConnection, status: Int, headers: [String: String] = [:], body: Data, head: Bool, paceBody: Bool = true) {
        var header = "HTTP/1.1 \(status) Response\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (key, value) in headers { header += "\(key): \(value)\r\n" }
        header += "\r\n"
        var response = Data(header.utf8)
        lock.lock()
        let hold = holdMediaBodies && !head && status == 206 && body.count > 1
        let dropAfter = hold ? 4096 : (!head && status == 206 ? dropNextBodyAfter : nil)
        let stall = hold || (dropAfter != nil && stallAfterBodyDrop)
        if dropAfter != nil {
            stallAfterBodyDrop = false
            dropNextBodyAfter = nil
            // Atomically stay offline after sending the partial response. A slow
            // main-thread test poll must not let a retry finish the file first.
            if disconnectAfterBodyDrop { networkMode = .disconnect }
            disconnectAfterBodyDrop = false
        }
        lock.unlock()
        let paced = lock.withLock { bodyBytesPerSecond != nil }
        if paced, paceBody, !head, status == 200 || status == 206, body.count > 4096, dropAfter == nil {
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                guard error == nil else { connection.cancel(); return }
                self?.sendPacedBody(connection, body: body, offset: 0)
            })
            return
        }
        if !head { response.append(dropAfter.map { Data(body.prefix($0)) } ?? body) }
        if stall {
            // Keep headers + a partial body open, with no FIN, until client timeout.
            connection.send(content: response, completion: .contentProcessed { error in if error != nil { connection.cancel() } })
        } else if dropAfter != nil {
            // Deliver the prefix on an open TCP stream before sending FIN.
            // Coalescing body + FIN into one send lets CFNetwork report a short
            // response before all its delegate data callbacks have been delivered.
            // The response still promises the original, longer Content-Length.
            connection.send(content: response, isComplete: false, completion: .contentProcessed { error in
                guard error == nil else { connection.cancel(); return }
                self.queue.asyncAfter(deadline: .now() + 0.1) {
                    connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { error in if error != nil { connection.cancel() } })
                }
            })
        } else {
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    private func sendPacedBody(_ connection: NWConnection, body: Data, offset: Int) {
        guard offset < body.count else { connection.cancel(); return }
        let (limit, burst) = lock.withLock { () -> (Int?, Int) in
            let burst = min(body.count-offset, bodyBurstBytes)
            bodyBurstBytes -= burst
            return (bodyBytesPerSecond, burst)
        }
        let count = burst > 0 ? burst : min(body.count - offset, limit.map { max(1, min(4096, $0 / 10)) } ?? body.count)
        connection.send(content: body.subdata(in: offset..<(offset + count)), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            if limit != nil, burst == 0 { self.lock.withLock { self.deliveredThrottledBytes += Int64(count) } }
            guard offset + count < body.count else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + (burst > 0 ? 0 : limit.map { Double(count) / Double($0) } ?? 0)) { [weak self] in
                self?.sendPacedBody(connection, body: body, offset: offset + count)
            }
        })
    }
}
