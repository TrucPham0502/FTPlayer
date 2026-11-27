import XCTest
import CryptoKit
import Darwin
@testable import FTPlayer
import libavformat

final class FTPlayerHTTPPlaybackTests: DecodeBackendTestCase {
    func testCloudMP4GzipFullBodyUsesDecodedSizeAndOffsets() throws {
        let original = try Data(contentsOf: fixture("faststart.mp4"))
        let loader = StreamingLoader(url: try http("gzip-full.mp4"))
        defer { loader.invalidate() }
        let done = expectation(description: "Decoded gzip representation")
        var bytes = Data(), size: Int64?, failure: Error?
        loader.onData = { data, offset in XCTAssertEqual(offset, 4096 + Int64(bytes.count)); bytes.append(data) }
        loader.onFileSize = { size = $0 }
        loader.onComplete = { failure = $0; done.fulfill() }
        loader.start(from: 4096)
        wait(for: [done], timeout: 5)
        XCTAssertNil(failure)
        XCTAssertEqual(bytes, original.dropFirst(4096), "Fixture must be transparently decoded before reaching the SDK")
        XCTAssertEqual(size, Int64(original.count), "Content-Length describes gzip wire bytes, not cached decoded MP4 bytes")
    }

    func testCloudMP4GzipCacheStopsAtDecodedEOF() throws {
        continueAfterFailure = true
        let url = try http("gzip-full.mp4"), original = try Data(contentsOf: fixture("faststart.mp4"))
        let worker = CacheWorker(videoURL: url, cacheStore: try CacheStore(videoURL: url))
        defer { worker.close() }
        try require(until(5) { worker.cachedByteRanges.first?.end == Int64(original.count - 1) }, "Gzip response did not populate the decoded file")
        pump(0.15)
        let requests = server!.requests.filter { $0.hasPrefix("GET ") }.count
        let evidence: [String: Any] = ["decodedBytes": original.count, "reportedSize": worker.knownFileSize,
            "getRequests": requests, "fraction": worker.cachedFraction]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "cloud-gzip-cache-eof"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(worker.knownFileSize, Int64(original.count))
        XCTAssertEqual(worker.cachedFraction, 1)
        XCTAssertEqual(requests, 1, "A completed gzip body triggered repeated GETs for nonexistent decoded bytes")
    }

    func testCloudMP4EncodedRangeIsRejectedBeforeCachingBytes() throws {
        continueAfterFailure = true
        let loader = StreamingLoader(url: try http("gzip-range.mp4"))
        defer { loader.invalidate() }
        let done = expectation(description: "Encoded 206")
        var bytes = Data(), failure: NSError?, size: Int64?
        loader.onData = { data, _ in bytes.append(data) }
        loader.onFileSize = { size = $0 }
        loader.onComplete = { failure = $0 as NSError?; done.fulfill() }
        loader.start(from: 0)
        wait(for: [done], timeout: 5)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
            "deliveredBytes": bytes.count, "reportedSize": size ?? -1, "failureCode": failure?.code ?? 0], options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "cloud-encoded-range"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(bytes.isEmpty, "Encoded HTTP range positions must not be assigned to decoded MP4 bytes")
        XCTAssertEqual(failure?.code, URLError.badServerResponse.rawValue)
    }

    func testCloudMP4EncodedHEADCannotDefineDecodedSize() throws {
        let loader = StreamingLoader(url: try http("gzip-full.mp4"))
        defer { loader.invalidate() }
        let done = expectation(description: "Encoded HEAD")
        var size: Int64?
        loader.getFileSize { size = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertNil(size, "A gzip HEAD reports encoded size and cannot define decoded cache offsets")
    }

    func testCloudMP4NonAuthoritativeResponseSuppliesFileSize() throws {
        let original = try Data(contentsOf: fixture("faststart.mp4"))
        let loader = StreamingLoader(url: try http("non-authoritative.mp4"))
        defer { loader.invalidate() }
        let done = expectation(description: "Successful full 203 response")
        var bytes = Data(), size: Int64?, failure: Error?
        loader.onData = { data, _ in bytes.append(data) }
        loader.onFileSize = { size = $0 }
        loader.onComplete = { failure = $0; done.fulfill() }
        loader.start(from: 0)
        wait(for: [done], timeout: 5)
        XCTAssertNil(failure); XCTAssertEqual(bytes, original)
        XCTAssertEqual(size, Int64(original.count), "A full successful 203 response left cache size unknown")
    }

    func testCloudMP4NonAuthoritativeResponsePlaysAndSeeksWithCache() throws {
        let session = try start(http("non-authoritative.mp4"), cache: true, policy: .ffmpeg, timeout: 4)
        try assertPlayback(session)
        try seek(session, target: 10, rate: 1)
        XCTAssertEqual(session.player.downloadProgress, 1)
    }

    func testCloudMP4UnknownRangeTotalCanStillUseHEADFallback() throws {
        let url = try http("unknown-range-total.mp4")
        let original = try Data(contentsOf: fixture("faststart.mp4"))
        let worker = CacheWorker(videoURL: url, cacheStore: try CacheStore(videoURL: url), readTimeout: 1, initialReadAheadBytes: 32768)
        defer { worker.close() }
        worker.beginOpening(timeout: 2)
        XCTAssertEqual(worker.getFileSize(), Int64(original.count))
        worker.finishOpening()
        XCTAssertTrue(server!.requests.contains { $0.hasPrefix("HEAD ") }, "Unknown totals still need a metadata fallback when the caller requests size")
        let offset = original.count - 1024
        worker.seek(to: Int64(offset))
        XCTAssertEqual(worker.read(offset: Int64(offset), length: 1024), original.suffix(1024))
    }

    func testCloudMP4GETSizeCannotBeOverwrittenByDelayedHEAD() throws {
        continueAfterFailure = true
        server = try FixtureHTTPServer(root: fixture(""), mp4HEADDelay: 0.25)
        let url = server!.url("stale-head.mp4")
        let store = try CacheStore(videoURL: url)
        let worker = CacheWorker(videoURL: url, cacheStore: store)
        defer { worker.close() }
        let original = try Data(contentsOf: fixture("faststart.mp4"))
        try require(until(3) { worker.knownFileSize == Int64(original.count) && worker.cachedFraction == 1 }, "GET did not load the object")
        pump(0.5)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
            "expectedSize": original.count, "actualSize": worker.knownFileSize,
            "requests": server!.requests], options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "cloud-mp4-size-authority"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(worker.knownFileSize, Int64(original.count), "Late HEAD metadata replaced the actual GET object size")
        XCTAssertEqual(worker.read(offset: Int64(original.count - 1024), length: 1024), original.suffix(1024), "Cached MP4 tail became unreadable")
        XCTAssertFalse(server!.requests.contains { $0.hasPrefix("HEAD ") }, "GET headers already supply the size; a separate HEAD adds an unnecessary request")
    }

    func testCloudMP4RejectedHEADDoesNotAddStartupRequests() throws {
        server = try FixtureHTTPServer(root: fixture(""), mp4HEADStatus: 403)
        let session = try start(server!.url("faststart.mp4"), cache: true, policy: .ffmpeg)
        try assertPlayback(session)
        XCTAssertFalse(server!.requests.contains { $0.hasPrefix("HEAD ") }, "Signed cloud URLs should open from GET without a rejected HEAD round trip")
        XCTAssertLessThanOrEqual(server!.requests.filter { $0.hasPrefix("GET ") }.count, 2)
    }

    func testCloudMP4RangeResponseMustMatchRequestedOffset() throws {
        continueAfterFailure = true
        for path in ["wrong-range.mp4", "missing-range.mp4", "invalid-total.mp4", "invalid-length.mp4", "backwards-range.mp4"] {
            let loader = StreamingLoader(url: try http(path))
            defer { loader.invalidate() }
            let done = expectation(description: path)
            var received = Data(), failure: NSError?
            loader.onData = { data, _ in received.append(data) }
            loader.onComplete = { failure = $0 as NSError?; done.fulfill() }
            loader.start(from: 4096, to: 5119)
            wait(for: [done], timeout: 4)
            XCTAssertTrue(received.isEmpty, "A wrong 206 body would be written at the requested offset and corrupt the MP4 cache")
            XCTAssertEqual(failure?.domain, NSURLErrorDomain)
            XCTAssertEqual(failure?.code, URLError.badServerResponse.rawValue)
        }
    }

    func testCloudMP4ValidShortRangeAndUnknownTotalRemainReadable() throws {
        let original = try Data(contentsOf: fixture("faststart.mp4"))
        for path in ["short-range.mp4", "unknown-total.mp4"] {
            let loader = StreamingLoader(url: try http(path))
            defer { loader.invalidate() }
            let done = expectation(description: path)
            var received = Data(), size: Int64?, failure: Error?
            loader.onData = { data, offset in
                XCTAssertEqual(offset, 4096 + Int64(received.count)); received.append(data)
            }
            loader.onFileSize = { size = $0 }
            loader.onComplete = { failure = $0; done.fulfill() }
            loader.start(from: 4096, to: 8191)
            wait(for: [done], timeout: 4)
            XCTAssertNil(failure)
            XCTAssertEqual(received, original.subdata(in: 4096..<5120))
            XCTAssertEqual(size, path == "unknown-total.mp4" ? nil : Int64(original.count))
        }
    }

    func testCloudMP4InvalidRangeFailsWithoutCachingOrRetryLoop() throws {
        let url = try http("wrong-range.mp4")
        let worker = CacheWorker(videoURL: url, cacheStore: try CacheStore(videoURL: url), readTimeout: 0.5)
        defer { worker.close() }
        // Bootstrap is valid at zero. Request a distant hole while the source
        // incorrectly keeps returning its first bytes as another 206 response.
        try require(until(3) { !worker.cachedByteRanges.isEmpty }, "Bootstrap did not arrive")
        worker.seek(to: 4096)
        XCTAssertNil(worker.read(offset: 4096, length: 32), "Wrong response bytes were advertised as a cache hit")
        XCTAssertEqual(worker.failure?.code, URLError.badServerResponse.rawValue)
        XCTAssertFalse(worker.cachedByteRanges.contains { $0.start <= 4096 && $0.end >= 4096 })
        let requests = server!.requests.count
        pump(2.2)
        XCTAssertEqual(server!.requests.count, requests, "Invalid range headers caused a retry loop")
    }

    func testHTTPUnknownLengthPublishesFinalSizeAndPreservesOffsets() throws {
        continueAfterFailure = true
        let original = try Data(contentsOf: fixture("faststart.mp4"))
        for path in ["chunked.mp4", "close-delimited.mp4"] {
            let loader = StreamingLoader(url: try http(path))
            defer { loader.invalidate() }
            let done = expectation(description: path)
            var received = Data(), size: Int64?, failure: Error?
            loader.onData = { data, offset in
                XCTAssertEqual(offset, 4096 + Int64(received.count))
                received.append(data)
            }
            loader.onFileSize = { size = $0 }
            loader.onComplete = { failure = $0; done.fulfill() }
            loader.start(from: 4096)
            wait(for: [done], timeout: 5)
            XCTAssertNil(failure)
            XCTAssertEqual(received, original.dropFirst(4096))
            XCTAssertEqual(size, Int64(original.count), "A successful full HTTP 200 body must resolve its size at EOF")
        }
    }

    func testHTTPTruncatedChunkedBodyDoesNotPublishFinalSize() throws {
        let loader = StreamingLoader(url: try http("truncated-chunked.mp4"))
        defer { loader.invalidate() }
        let done = expectation(description: "Incomplete chunked body")
        var size: Int64?, failure: Error?
        loader.onFileSize = { size = $0 }
        loader.onComplete = { failure = $0; done.fulfill() }
        loader.start(from: 0)
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(failure)
        XCTAssertNil(size, "An interrupted body cannot establish the resource size")
    }

    func testCachedChunkedMP4OpensSeeksAndReplaysWithoutNetwork() throws {
        let began = ProcessInfo.processInfo.systemUptime
        let session = try start(http("chunked.mp4"), cache: true, policy: .ffmpeg, timeout: 5)
        let readySeconds = ProcessInfo.processInfo.systemUptime - began
        try require(until(5) { session.sink.frames > 0 || session.failure != nil }, "Chunked MP4 did not render")
        session.measurements.append(["operation": "chunked-startup", "readySeconds": readySeconds,
            "firstFrameSeconds": ProcessInfo.processInfo.systemUptime - began])
        try assertPlayback(session)
        XCTAssertEqual(session.player.downloadProgress, 1)
        try seek(session, target: 10, rate: 1)
        let requests = server!.requests
        session.player.stop()
        server!.setNetworkMode(.disconnect, dropExistingConnections: true)
        let frames = session.sink.frames
        session.player.play()
        try require(until(5) { session.sink.frames > frames + 2 || session.failure != nil }, "Cached chunked replay did not render")
        XCTAssertNil(session.failure)
        XCTAssertEqual(server!.requests, requests)
    }

    func testCachedMP4ProbeReusesTransferAndWarmCache() throws {
        let session = try start(http("faststart.mp4"), cache: true, policy: .ffmpeg)
        try assertPlayback(session)
        try require(until(5) { session.player.downloadProgress == 1 }, "MP4 cache did not finish")
        XCTAssertLessThanOrEqual(server!.requests.filter { $0.hasPrefix("GET ") }.count, 2, "Format probing created a separate HTTP download")
        let requests = server!.requests
        session.ready = false
        let frames = session.sink.frames
        session.player.replaceVideo()
        try require(until(5) { session.ready && session.sink.frames > frames }, "Warm replay did not render")
        XCTAssertEqual(server!.requests, requests, "Warm probing ignored cached bytes")
        XCTAssertEqual(session.player.downloadProgress, 1)
    }

    func testRepeatedAVIOCloseReleasesReadBuffers() throws {
        let url = try http("faststart.mp4")
        let store = try CacheStore(videoURL: url)
        store.setTotalFileSize(1); store.write(Data([0]), at: 0); store.flush()
        let worker = CacheWorker(videoURL: url, cacheStore: store)
        defer { worker.close() }
        func cycle() throws {
            try autoreleasepool {
                let io = try FTCacheIOContext(worker: worker)
                io.close(); io.close() // Also exercise explicit close followed by deinit.
            }
        }
        for _ in 0..<32 { try cycle() }
        func allocatedBytes() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return stats.size_in_use
        }
        let before = allocatedBytes()
        for _ in 0..<256 { try cycle() }
        let after = allocatedBytes()
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: ["beforeBytes": before, "afterBytes": after, "cycles": 256]), uniformTypeIdentifier: "public.json")
        attachment.name = "avio-live-allocations"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertLessThan(after, before + 2 * 1024 * 1024, "Closing 256 AVIO contexts retained their 32 KiB read buffers")
        XCTAssertTrue(server!.requests.isEmpty, "This allocation test must not measure URLSession downloads")
    }

    func testNativeHTTPRetriesConnectionClosedBeforeHeaders() throws {
        let url = try http("internet-h264.mp4")
        let fixtureServer = server!
        fixtureServer.setNetworkMode(.disconnect)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            fixtureServer.setNetworkMode(.online)
        }
        let session = try start(url, cache: false, policy: .ffmpeg, timeout: 10)
        try assertPlayback(session)
        XCTAssertNil(session.failure)
    }

    func testNativeHTTPReconnectsAfterPartialSeekResponse() throws {
        let session = try start(http("internet-h264.mp4"), cache: false, policy: .ffmpeg)
        try assertPlayback(session)
        session.player.pause()
        let requests = server!.rangeRequests.count
        server!.dropNextBody(afterBytes: 4096)
        let target = session.player.duration * 0.6
        let frames = session.sink.frames
        var complete: Bool?
        session.player.seek(to: target) { complete = $0 }
        session.player.play()
        try require(until(12) { complete != nil || session.failure != nil }, "Native seek did not complete")
        XCTAssertEqual(complete, true)
        try require(until(12) {
            session.sink.frames > frames + 2 && (session.player.decoder?.currentVideoFrame?.position ?? -1) >= target - 1 || session.failure != nil
        }, "Native HTTP playback did not recover from a truncated range")
        XCTAssertNil(session.failure)
        XCTAssertGreaterThanOrEqual(server!.rangeRequests.count - requests, 2, "Partial body was not resumed with a new range")
    }

    private func checkCommonLoadControl(_ file: String, video: Bool = true, progress: Bool = true) throws {
        let s = PlaybackSession(url:try http(file),cache:true,policy:.ffmpeg); sessions.append(s)
        s.player.loadControlConfiguration = .init(minimumBufferDuration:12,maximumBufferDuration:70,targetBufferBytes:3*1024*1024)
        s.player.rate = 2; s.start()
        try require(until(15) { s.ready || s.failure != nil },"Source did not open")
        try assertPlayback(s,video:video,progress:progress)
        XCTAssertEqual(s.player.decoder?.loadControlDiagnostics["minimumMediaMilliseconds"],24000)
        XCTAssertEqual(s.player.decoder?.loadControlDiagnostics["maximumMediaMilliseconds"],70000)
        XCTAssertEqual(s.player.decoder?.loadControlDiagnostics["targetBytes"],3*1024*1024)
        s.measurements.append(["operation":"shared-load-control","source":file,"diagnostics":s.player.decoder?.loadControlDiagnostics ?? [:]])
    }
    func testLoadControlSharedMP4() throws { try checkCommonLoadControl("sample.mp4",video:true,progress:true) }
    func testLoadControlSharedHEVCMP4() throws { try checkCommonLoadControl("internet-hevc.mp4",video:true,progress:true) }
    func testLoadControlSharedMOV() throws { try checkCommonLoadControl("h264.mov",video:true,progress:true) }
    func testLoadControlSharedMKV() throws { try checkCommonLoadControl("h264.mkv",video:true,progress:true) }
    func testLoadControlSharedTS() throws { try checkCommonLoadControl("h264.ts",video:true,progress:true) }
    func testLoadControlSharedFLV() throws { try checkCommonLoadControl("h264.flv",video:true,progress:true) }
    func testLoadControlSharedRawH264() throws { try checkCommonLoadControl("raw.h264",video:true,progress:false) }
    func testLoadControlSharedRawHEVC() throws { try checkCommonLoadControl("raw.h265",video:true,progress:false) }
    func testLoadControlSharedAudioOnly() throws { try checkCommonLoadControl("audio.m4a",video:false,progress:true) }
    func testLoadControlSharedHLSTS() throws { try checkCommonLoadControl("hls-ts/index.m3u8",video:true,progress:true) }
    func testLoadControlSharedHLSFMP4() throws { try checkCommonLoadControl("hls-fmp4/index.m3u8",video:true,progress:true) }
    func testLoadControlSharedHLSAES() throws { try checkCommonLoadControl("hls-aes128/index.m3u8",video:true,progress:true) }

    private func checkLoadControlSeekWindow(_ file: String) throws {
        let s = try start(http(file),cache:true,policy:.ffmpeg)
        try assertPlayback(s); s.player.pause()
        try require(until(10) { (s.player.cachedTimeRanges.first?.end ?? 0) >= 45 },"Initial time window missing")
        s.player.play(); try seek(s,target:80,rate:16); s.player.pause()
        try require(until(10) { s.player.cachedTimeRanges.contains { $0.start <= 80 && $0.end >= 125 } },"Seek window did not refill")
        let seekRange = try XCTUnwrap(s.player.cachedTimeRanges.first { $0.start <= 80 && $0.end >= 125 })
        XCTAssertLessThanOrEqual(seekRange.end,136,"Seek demand fetched past the media-time window")
        XCTAssertTrue(s.player.cachedTimeRanges.contains { $0.start < 1 && $0.end >= 45 },"Seek discarded the old cache")
        let diskBefore = s.player.decoder?.cacheDiagnostics["diskReadBytes"] ?? 0
        server!.setNetworkMode(.disconnect,dropExistingConnections:true)
        s.player.play(); try seek(s,target:10,rate:1)
        XCTAssertGreaterThan(s.player.decoder?.cacheDiagnostics["diskReadBytes"] ?? 0,diskBefore)
        XCTAssertNil(s.failure)
        server!.setNetworkMode(.online)
        try seek(s,target:140,rate:1)
        s.measurements.append(["operation":"seek-window-offline-reconnect","rangeEnd":seekRange.end,"cache":s.player.decoder?.cacheDiagnostics ?? [:]])
    }
    func testLoadControlH264SeekOfflineAndReconnect() throws { try checkLoadControlSeekWindow("sustained-h264-aac.mp4") }
    func testLoadControlHEVCSeekOfflineAndReconnect() throws { try checkLoadControlSeekWindow("sustained-hevc-aac.mp4") }

    private func checkLoadControlFile(_ name: String, policy: FTVideoDecodingPolicy) throws {
        #if targetEnvironment(simulator)
        if policy == .hardware { throw XCTSkip("Strict hardware is verified on Mac/device; Simulator software is tested separately") }
        #endif
        let s = try start(http(name),cache:true,policy:policy)
        try assertPlayback(s); try assertBackend(s,policy)
        s.player.pause()
        try require(until(10) { (s.player.cachedTimeRanges.first?.end ?? 0) >= 45 },"File did not fill the time window")
        let before = s.player.downloadProgress
        for rate: Float in [1,2,4,8,16,1] {
            s.player.rate = rate; pump(0.1)
            XCTAssertLessThanOrEqual(s.player.cachedTimeRanges.first?.end ?? 0,55)
            XCTAssertEqual(s.player.decoder?.cacheDiagnostics["loadMaxMediaMilliseconds"],50000)
            XCTAssertGreaterThanOrEqual(s.player.downloadProgress,before)
        }
        s.measurements.append(["operation":"file-load-control","cache":s.player.decoder?.cacheDiagnostics ?? [:],"cachedEnd":s.player.cachedTimeRanges.first?.end ?? 0])
    }
    func testLoadControlH264FFmpeg() throws { try checkLoadControlFile("sustained-h264-aac.mp4",policy:.ffmpeg) }
    func testLoadControlHEVCFFmpeg() throws { try checkLoadControlFile("sustained-hevc-aac.mp4",policy:.ffmpeg) }
    func testLoadControlH264Hardware() throws { try checkLoadControlFile("sustained-h264-aac.mp4",policy:.hardware) }
    func testLoadControlHEVCHardware() throws { try checkLoadControlFile("sustained-hevc-aac.mp4",policy:.hardware) }

    func testLoadControlHTTPFileDoesNotCacheEntireLowBitrateVideo() throws {
        let s = try start(http("sustained-h264-aac.mp4"),cache:true,policy:.ffmpeg)
        s.player.pause(); pump(0.7)
        let end = s.player.cachedTimeRanges.first(where: { $0.start < 1 })?.end ?? 0
        XCTAssertGreaterThan(end,0)
        XCTAssertLessThanOrEqual(end,55,"Low bitrate file filled byte budget instead of stopping at 50 media seconds")
    }
    private func prefixBytes(_ worker: CacheWorker) -> Int64 {
        worker.cachedByteRanges.first(where: { $0.start == 0 }).map { $0.end + 1 } ?? 0
    }
    func testCacheRatePrefetchGrowsAndShrinksWithoutDiscardingCachedBytes() throws {
        let url = try http("cache-large-pattern.bin")
        let player = FTPlayer(contentURL: url), session = try player.prepareCacheSession()
        let worker = try session.makeWorker(videoURL: url)
        defer { worker.close(); session.close() }
        let mb: Int64 = 1024 * 1024
        try require(until(12) { self.prefixBytes(worker) >= 8 * mb }, "1x did not prefetch")
        pump(0.2); XCTAssertEqual(prefixBytes(worker), 8 * mb)
        var budgets: [[String: Int64]] = []
        for (rate, expected) in [(Float(2), 16), (4, 32), (8, 64), (16, 64)] {
            player.rate = rate
            try require(until(12) { self.prefixBytes(worker) >= Int64(expected) * mb }, "Increasing rate did not enlarge real downloaded range at \(rate)x")
            pump(0.15); XCTAssertEqual(prefixBytes(worker), Int64(expected) * mb)
            XCTAssertEqual(worker.diagnosticSnapshot["readAheadTargetBytes"], Int64(expected) * mb)
            budgets.append(worker.diagnosticSnapshot)
        }
        let count = server!.rangeRequests.count
        player.rate = 1; pump(0.25)
        XCTAssertEqual(worker.diagnosticSnapshot["readAheadTargetBytes"], 8 * mb)
        XCTAssertEqual(prefixBytes(worker), 64 * mb, "Lower rate deleted existing session bytes")
        server!.setNetworkMode(.disconnect)
        worker.seek(to: 32 * mb)
        XCTAssertEqual(worker.read(offset: 32 * mb, length: 4096), Data(repeating: 0x5a, count: 4096))
        pump(0.2); XCTAssertEqual(server!.rangeRequests.count, count, "Cached seek or lower rate restarted a transfer")
        XCTAssertTrue(cacheRequests().allSatisfy { $0.count <= 4 * cacheMB })
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: budgets), uniformTypeIdentifier: "public.json")
        attachment.name = "prefetch-budgets-and-downloaded-bytes"; attachment.lifetime = .keepAlways; add(attachment)
        attachCacheRequests("adaptive-prefetch")
    }
    func testCacheRatePrefetchBeforeOpenAndAfterStopReplay() throws {
        let url = try http("cache-large-pattern.bin"), player = FTPlayer(contentURL: try http("cache-large-pattern.bin"))
        player.rate = 16
        let session = try player.prepareCacheSession(), worker = try session.makeWorker(videoURL: url)
        defer { session.close() }
        let mb: Int64 = 1024 * 1024
        try require(until(12) { self.prefixBytes(worker) >= 64 * mb }, "Rate set before source open was not inherited")
        let count = server!.rangeRequests.count
        session.suspendWorkers(); player.rate = 2
        let replay = try session.makeWorker(videoURL: url, revision: session.currentRevision)
        XCTAssertEqual(replay.diagnosticSnapshot["readAheadTargetBytes"], 16 * mb)
        pump(0.2); XCTAssertEqual(server!.rangeRequests.count, count, "Replay downloaded the cached prefix again")
        replay.seek(to: 64 * mb)
        try require(until(12) { self.prefixBytes(replay) == 80 * mb }, "Replay did not continue at its new rate")
        XCTAssertTrue(cacheRequests().dropFirst(count).allSatisfy { $0.lowerBound >= 64 * Int(mb) && $0.upperBound <= 80 * Int(mb) })
        attachCacheRequests("adaptive-replay")
    }
    func testCachePrefetchStalledBodyRecoversBeforeReaderNeedsMissingBytes() throws {
        let url = try http("cache-pattern.bin"), store = try CacheStore(videoURL: try http("cache-pattern.bin"))
        server!.prepareCachePattern()
        server!.stallNextBody(afterBytes: 128 * 1024)
        let worker = CacheWorker(videoURL: url, cacheStore: store, readTimeout: 0.25)
        defer { worker.close() }
        try require(until(12) { self.prefixBytes(worker) >= 128 * 1024 }, "Partial body did not arrive")
        try require(until(3) { self.prefixBytes(worker) >= 8 * 1024 * 1024 }, "Prefetch stayed frozen without an AVIO reader to restart the dead socket")
        let requests = cacheRequests()
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        XCTAssertEqual(requests[1].lowerBound, 128 * 1024, "Reconnect re-downloaded already persisted bytes")
        XCTAssertEqual(worker.diagnosticSnapshot["diskReadBytes"], 0)
        XCTAssertNil(worker.failure)
        let snapshot = worker.diagnosticSnapshot; worker.close(); let count = server!.rangeRequests.count
        pump(0.6); XCTAssertEqual(server!.rangeRequests.count, count, "Closed worker watchdog restarted a transfer")
        FTPlayerDiagnostic.shared.log("PREFETCH STALL RECOVERED \(snapshot)", category: "test")
        attachCacheRequests("prefetch-stall")
    }

    func testCachePrefetchStalledHeadersReconnectWithoutReader() throws {
        let url = try http("cache-large-pattern.bin"), store = try CacheStore(videoURL: try http("cache-large-pattern.bin"))
        store.setTotalFileSize(80 * 1024 * 1024)
        server!.stallNextGETHeaders()
        let worker = CacheWorker(videoURL: url, cacheStore: store, readTimeout: 0.25)
        defer { worker.close() }
        try require(until(4) { self.prefixBytes(worker) >= 8 * 1024 * 1024 }, "Request stuck before HTTP headers never recovered")
        XCTAssertEqual(worker.diagnosticSnapshot["diskReadBytes"], 0)
        XCTAssertEqual(worker.diagnosticSnapshot["networkBytes"], 8 * 1024 * 1024)
        XCTAssertEqual(worker.diagnosticSnapshot["stalledReconnects"], 1)
        XCTAssertEqual(cacheRequests().prefix(2).map { $0.lowerBound }, [0, 0])
        XCTAssertNil(worker.failure)
        attachCacheRequests("prefetch-stalled-headers")
    }

    func testHTTPRangeMP4() throws { try assertPlayback(start(http("sample.mp4"))) }
    func testHTTPRedirect() throws { try assertPlayback(start(http("redirect"))) }
    func testHTTPWithoutExtension() throws { try assertPlayback(start(http("no-extension"))) }
    func testHTTPWrongMIMEStillProbesVideo() throws { try assertPlayback(start(http("wrong-mime.mp4"))) }
    func testHTTPServerWithoutRange() throws { try assertPlayback(start(http("no-range.mp4"))) }
    func testHTTPCacheColdStartAndProgress() throws {
        let s = try start(http("sample.mp4"), cache: true)
        try assertPlayback(s)
        try require(until { s.player.downloadProgress > 0 }, "Cache progress never advanced")
        XCTAssertEqual(s.player.decoder?.cacheDiagnostics["fileSize"], Int64(try Data(contentsOf: fixture("sample.mp4")).count))
        XCTAssertFalse(server!.requests.contains { $0.hasPrefix("HEAD ") }, "GET already supplied the file length")
    }
    func testHTTPCacheSeek() throws {
        let s = try start(http("sample.mp4"), cache: true)
        try assertPlayback(s)
        var complete: Bool?
        s.player.seek(to: 10) { complete = $0 }
        try require(until { complete != nil }, "Cache seek callback missing")
        try require(complete == true, "Cache seek failed")
        try require(until { s.player.progress >= 9.5 }, "Cache seek did not reach target")
    }
    func testHTTPCache404FailsWithoutRetryLoop() throws {
        let s = PlaybackSession(url: try http("status/404"), cache: true); sessions.append(s); s.start()
        try require(until(12) { s.failure != nil }, "Cache kept retrying permanent HTTP 404")
        try require(s.player.state == .failed, "Cache error did not reach failed state")
    }
    func testHTTPCacheReplayWithinSessionUsesCachedBytes() throws {
        let url = try http("sample.mp4")
        let first = try start(url, cache: true); try assertPlayback(first)
        try require(until { first.player.downloadProgress >= 1 }, "Fixture was not fully cached")
        let requests = server!.requests.count
        first.ready = false; first.player.replaceVideo()
        try require(until { first.ready }, "Replay did not become ready"); try assertPlayback(first)
        try require(server!.requests.count == requests, "Same-session replay downloaded cached bytes")
    }
    func testHTTP404() throws { try assertHTTPFailure("status/404") }
    func testHTTP403() throws { try assertHTTPFailure("status/403") }
    func testHTTP500() throws { try assertHTTPFailure("status/500") }
    func testHTMLDisguisedAsMP4() throws { try assertHTTPFailure("html.mp4") }
    func testBrokenHLSMissingSegment() throws { try assertHTTPFailure("invalid.m3u8") }
    private func assertHTTPFailure(_ path: String) throws {
        let s = PlaybackSession(url: try http(path)); sessions.append(s); s.start()
        try require(until(12) { s.failure != nil }, "Invalid input did not fail: \(path)")
        try require(s.player.state == .failed, "Expected failed state")
        try require(s.sink.frames == 0, "Invalid input output frames")
        try require(s.callbackThreadsAreMain, "Error callback was not on main")
    }
    func testCacheStalledReadReturnsTimeoutInsteadOfHanging() throws {
        let url = try http("stall")
        let worker = CacheWorker(videoURL: url, cacheStore: try CacheStore(videoURL: url), readTimeout: 0.2)
        defer { worker.close() }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let started = ProcessInfo.processInfo.systemUptime
        let result = bytes.withUnsafeMutableBufferPointer { worker.readPacket(into: $0.baseAddress!, size: Int32($0.count)) }
        try require(result == -Int32(ETIMEDOUT), "Stalled cache did not return native timeout error")
        try require(ProcessInfo.processInfo.systemUptime - started < 2, "Stalled cache remained blocked")
    }
    func testCachePlaysWhenHEADStallsButGETHasContentRange() throws {
        let s = try start(http("head-stall.mp4"), cache: true, timeout: 10)
        try assertPlayback(s)
        XCTAssertTrue(server!.requests.contains("GET /head-stall.mp4"))
        XCTAssertFalse(server!.requests.contains { $0.hasPrefix("HEAD ") }, "A stalled HEAD must not be needed when GET supplies size")
        XCTAssertEqual(s.player.decoder?.cacheDiagnostics["fileSize"], Int64(try Data(contentsOf: fixture("faststart.mp4")).count))
        try require(s.player.duration > 0, "Range response did not supply file size")
    }
    func testCacheStopCancelsStalledMetadataProbe() throws {
        let s = PlaybackSession(url: try http("stall"), cache: true); sessions.append(s); s.start()
        pump(0.3)
        weak var oldDecoder = s.player.decoder
        s.stop()
        try require(until(4) { oldDecoder == nil }, "Cache metadata wait retained the stopped decoder")
        try require(!s.ready && s.player.state == .none, "Stopped cache unexpectedly opened")
    }
    func testStopDuringStalledOpen() throws {
        let s = PlaybackSession(url: try http("stall")); sessions.append(s); s.start()
        pump(0.2); s.stop(); pump(0.5)
        try require(s.player.state == .none, "Stopped open changed state afterward")
        try require(!s.ready, "Stalled URL incorrectly reported ready")
    }
    func testReviewHTTP200IgnoringRangeKeepsRealByteOffsets() throws {
        let loader = StreamingLoader(url: try http("no-range.mp4")); defer { loader.invalidate() }
        let original = try Data(contentsOf: fixture("faststart.mp4"))
        let offset: Int64 = 4096
        let done = expectation(description: "range ignored response")
        var received = Data(); var offsets: [Int64] = []; var failed: Error?
        loader.onData = { data, position in offsets.append(position); received.append(data) }
        loader.onComplete = { error in failed = error; done.fulfill() }
        loader.start(from: offset)
        wait(for: [done], timeout: 5)
        XCTAssertNil(failed)
        XCTAssertEqual(offsets.first, offset)
        XCTAssertEqual(received, original.subdata(in: Int(offset)..<original.count), "HTTP 200 body was mislabeled as bytes starting at requested offset")
    }
    func testReviewInvalidCacheSeekDoesNotChangeReadHead() throws {
        let url = try http("sample.mp4")
        let worker = CacheWorker(videoURL: url, cacheStore: try CacheStore(videoURL: url)); defer { worker.close() }
        XCTAssertEqual(worker.seekPacket(offset: -1, whence: 0), -1)
        XCTAssertEqual(worker.currentOffset, 0, "Rejected negative seek changed read head")
        XCTAssertEqual(worker.seekPacket(offset: -10, whence: 1), -1)
        XCTAssertEqual(worker.currentOffset, 0, "Negative relative seek changed read head")
    }


    // Cache byte-range regressions: exact payload and actual loopback Range requests.
    private let cacheMB = 1024 * 1024
    private func cachePattern(_ offset: Int, _ count: Int) -> Data {
        Data((offset..<(offset + count)).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 9) ^ ($0 >> 17)) })
    }
    private func seedCache(_ store: CacheStore, spans: [Range<Int>]) {
        store.setTotalFileSize(Int64(24 * cacheMB))
        for span in spans { store.write(cachePattern(span.lowerBound, span.count), at: Int64(span.lowerBound)) }
        store.flush()
    }
    private func cacheRequests() -> [Range<Int>] {
        server!.rangeRequests.map { spec in
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            let first = Int(parts[0])!
            let last = parts.count > 1 ? (Int(parts[1]) ?? 24 * cacheMB - 1) : 24 * cacheMB - 1
            return first..<(last + 1)
        }
    }
    private func attachCacheRequests(_ label: String) {
        let attachment = XCTAttachment(string: server!.rangeRequests.joined(separator: "\n"))
        attachment.name = label + "-http-ranges"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testCacheReviewSparseRequestsNeverDownloadCachedIslands() throws {
        let url = try http("cache-pattern.bin"), store = try CacheStore(videoURL: url)
        let seeded = [0..<cacheMB, (2 * cacheMB)..<(3 * cacheMB), (6 * cacheMB)..<(7 * cacheMB), (20 * cacheMB)..<(24 * cacheMB)]
        seedCache(store, spans: seeded)
        let worker = CacheWorker(videoURL: url, cacheStore: store); defer { worker.close() }
        try require(until(15) { store.isCached(offset: Int64(7 * cacheMB), length: cacheMB) }, "Initial holes did not load")
        attachCacheRequests("sparse")
        for request in cacheRequests() {
            for span in seeded { XCTAssertFalse(request.overlaps(span), "Downloaded existing cached bytes: request=\(request) cached=\(span)") }
        }
    }
    func testCacheReviewSeekCachedBeginningMiddleEndStartsNoRequests() throws {
        let url = try http("cache-pattern.bin"), store = try CacheStore(videoURL: url)
        seedCache(store, spans: [0..<(4 * cacheMB), (8 * cacheMB)..<(12 * cacheMB), (20 * cacheMB)..<(24 * cacheMB)])
        let worker = CacheWorker(videoURL: url, cacheStore: store); defer { worker.close() }
        try require(until(15) { store.isCached(offset: Int64(4 * cacheMB), length: 4 * cacheMB) }, "Initial download missing")
        pump(1)
        let count = server!.rangeRequests.count
        for offset in [0, 10 * cacheMB, 24 * cacheMB - 1024, 10 * cacheMB, 0] {
            worker.seek(to: Int64(offset))
            XCTAssertEqual(worker.read(offset: Int64(offset), length: 1024), cachePattern(offset, 1024))
            pump(0.5)
            XCTAssertEqual(server!.rangeRequests.count, count, "Cached seek at \(offset) started another request")
        }
        attachCacheRequests("cached-begin-middle-end")
    }
    func testCacheReviewColdSeekBeginningMiddleEndAndRepeatExactBytes() throws {
        let url = try http("cache-pattern.bin"), store = try CacheStore(videoURL: url)
        store.setTotalFileSize(Int64(24 * cacheMB))
        let worker = CacheWorker(videoURL: url, cacheStore: store, readTimeout: 10); defer { worker.close() }
        for offset in [0, 24 * cacheMB - 8192, 12 * cacheMB + 333, 0, 12 * cacheMB + 333, 24 * cacheMB - 8192] {
            worker.seek(to: Int64(offset))
            var actual = Data()
            while actual.count < 8192 {
                guard let part = worker.read(offset: Int64(offset + actual.count), length: 8192 - actual.count), !part.isEmpty else {
                    XCTFail("Unexpected EOF/timeout after seek \(offset)"); return
                }
                actual.append(part)
            }
            XCTAssertEqual(actual, cachePattern(offset, 8192), "Cache bytes corrupted after seek \(offset)")
            pump(0.15)
        }
        attachCacheRequests("cold-repeat")
        // Completed cached prefixes must never be requested again on subsequent seeks.
        let count = server!.rangeRequests.count
        for offset in [0, 12 * cacheMB + 333, 24 * cacheMB - 8192] {
            worker.seek(to: Int64(offset)); XCTAssertNotNil(worker.read(offset: Int64(offset), length: 1024)); pump(0.15)
        }
        XCTAssertEqual(server!.rangeRequests.count, count)
    }
    func testCacheReviewClosedWorkerCannotRestartDownloadBySeek() throws {
        let url = try http("cache-pattern.bin"), store = try CacheStore(videoURL: url)
        store.setTotalFileSize(Int64(24 * cacheMB))
        let worker = CacheWorker(videoURL: url, cacheStore: store)
        worker.close(); pump(0.2)
        let count = server!.requests.count
        worker.seek(to: Int64(16 * cacheMB)); pump(0.3)
        XCTAssertEqual(server!.requests.count, count, "Seek restarted a closed cache worker")
        XCTAssertNil(worker.read(offset: Int64(16 * cacheMB), length: 1024))
    }


    func testCacheReviewRapidAlternatingSparseSeekKeepsByteIdentity() throws {
        let url = try http("cache-pattern.bin"), store = try CacheStore(videoURL: url)
        seedCache(store, spans: [0..<cacheMB, (12 * cacheMB)..<(13 * cacheMB), (23 * cacheMB)..<(24 * cacheMB)])
        let worker = CacheWorker(videoURL: url, cacheStore: store, readTimeout: 10); defer { worker.close() }
        for i in 0..<60 {
            worker.cancelRead()
            let offset = [0, 12 * cacheMB + 17, 24 * cacheMB - 1024, 4 * cacheMB, 16 * cacheMB][i % 5]
            worker.seek(to: Int64(offset))
            if i % 5 < 3 { XCTAssertEqual(worker.read(offset: Int64(offset), length: 512), cachePattern(offset, 512)) }
        }
        worker.seek(to: Int64(16 * cacheMB))
        let data = try XCTUnwrap(worker.read(offset: Int64(16 * cacheMB), length: 512))
        XCTAssertEqual(data, cachePattern(16 * cacheMB, data.count))
        attachCacheRequests("rapid-sparse")
    }
    private func checkCachedPlaybackBoundaries(_ filename: String, policy: FTVideoDecodingPolicy) throws {
        let session = PlaybackSession(url: try http(filename), cache: true, policy: policy)
        sessions.append(session); session.start()
        try require(until(25) { session.ready || session.failure != nil }, "Cached player did not open")
        #if targetEnvironment(simulator)
        if policy == .hardware, let error = session.failure as NSError?, error.domain == "FTPlayer.VideoDecoder", error.code == -2001 {
            throw XCTSkip("Simulator has no verified hardware decoder; no software fallback counted")
        }
        #endif
        try assertPlayback(session)
        try assertBackend(session, policy)
        try require(until(15) { session.player.downloadProgress >= 0.999 }, "Full video cache not ready")
        let requests = server!.requests.count
        for rate: Float in [2, 4, 8, 16] {
            try seek(session, target: 0, rate: rate)
            try recordRate(session, rate: rate)
            try seek(session, target: session.player.duration * 0.5, rate: rate)
            // Near-EOF seek at each rate, including when playback has been paused.
            session.player.pause(); var complete: Bool?
            let target = session.player.duration - 0.5
            session.player.seek(to: target) { complete = $0 }
            try require(until(20) { complete != nil || session.failure != nil }, "Near-end cached seek timed out")
            try require(complete == true, "Near-end cached seek failed")
            let frames = session.sink.frames
            session.player.play()
            try require(until(10) { session.sink.frames > frames || session.failure != nil }, "No frame near cached EOF")
            try require(session.failure == nil, "Cached EOF decode failed")
            // Return to a stable point even if high-rate playback reached EOF naturally.
            session.player.rate = 1
            session.player.play()
            try seek(session, target: session.player.duration * 0.1, rate: 1)
            XCTAssertEqual(server!.requests.count, requests, "Warm \(filename) seek at \(rate)x made a network request")
        }
        try assertBackend(session, policy)
        attachCacheRequests("playback-" + filename + "-" + policy.rawValue)
    }
    func testCacheReviewPlaybackH264FFmpegBeginningMiddleEndAt2xTo16x() throws { try checkCachedPlaybackBoundaries("sample.mp4", policy: .ffmpeg) }
    func testCacheReviewPlaybackH264HardwareBeginningMiddleEndAt2xTo16x() throws { try checkCachedPlaybackBoundaries("sample.mp4", policy: .hardware) }
    func testCacheReviewPlaybackHEVCFFmpegBeginningMiddleEndAt2xTo16x() throws { try checkCachedPlaybackBoundaries("photoprism-tsu-hevc.mp4", policy: .ffmpeg) }
    func testCacheReviewPlaybackHEVCHardwareBeginningMiddleEndAt2xTo16x() throws { try checkCachedPlaybackBoundaries("photoprism-tsu-hevc.mp4", policy: .hardware) }

    func testCacheReviewSeekReleasesPreviousBlockedRead() throws {
        let url = try http("stall"), store = try CacheStore(videoURL: url)
        seedCache(store, spans: [(12 * cacheMB)..<(13 * cacheMB)])
        let worker = CacheWorker(videoURL: url, cacheStore: store, readTimeout: 5); defer { worker.close() }
        let finished = expectation(description: "previous AVIO read cancelled by seek")
        DispatchQueue.global().async {
            let old = worker.read(offset: 0, length: 1024)
            XCTAssertNil(old)
            finished.fulfill()
        }
        pump(0.1)
        worker.cancelRead()
        worker.seek(to: Int64(12 * cacheMB))
        XCTAssertEqual(worker.read(offset: Int64(12 * cacheMB), length: 1024), cachePattern(12 * cacheMB, 1024))
        wait(for: [finished], timeout: 2)
    }

    func testCacheReviewServerIgnoringRangeCachesFullBodyOnce() throws {
        let url = try http("cache-no-range.bin"), store = try CacheStore(videoURL: url)
        store.setTotalFileSize(Int64(24 * cacheMB))
        let worker = CacheWorker(videoURL: url, cacheStore: store, readTimeout: 10); defer { worker.close() }
        try require(until(15) { worker.cachedFraction >= 0.999 }, "HTTP 200 full response did not cache to EOF")
        let count = server!.requests.count
        XCTAssertEqual(server!.rangeRequests.count, 1, "Range-ignoring server was restarted and its prefix downloaded repeatedly")
        for offset in [0, 12 * cacheMB, 24 * cacheMB - 1024] {
            worker.seek(to: Int64(offset))
            XCTAssertEqual(worker.read(offset: Int64(offset), length: 1024), cachePattern(offset, 1024))
        }
        pump(0.2); XCTAssertEqual(server!.requests.count, count)
        XCTAssertEqual(worker.diagnosticSnapshot["networkBytes"], Int64(24 * cacheMB))
        attachCacheRequests("no-range-full-body")
    }

    private func checkNetworkReadRecovery(_ mode: FixtureHTTPServer.NetworkMode) throws {
        let url = try http("cache-pattern.bin"), store = try CacheStore(videoURL: url)
        seedCache(store, spans: [0..<cacheMB, (20 * cacheMB)..<(24 * cacheMB)])
        server!.setNetworkMode(mode, dropExistingConnections: true)
        let worker = CacheWorker(videoURL: url, cacheStore: store, readTimeout: 0.15)
        let io = try FTCacheIOContext(worker: worker); defer { io.close() }
        // Known cached data remains available even though every server request fails.
        for offset in [0, 24 * cacheMB - 1024] {
            worker.seek(to: Int64(offset))
            XCTAssertEqual(worker.read(offset: Int64(offset), length: 1024), cachePattern(offset, 1024))
        }
        worker.seek(to: Int64(4 * cacheMB))
        let lock = NSLock(); var completed = false; var received: Data?
        let finished = expectation(description: "resume missing bytes after network returns")
        DispatchQueue.global().async {
            let data = worker.read(offset: Int64(4 * 1024 * 1024), length: 1024)
            lock.withLock { received = data; completed = true }
            finished.fulfill()
        }
        pump(0.7)
        XCTAssertFalse(lock.withLock { completed }, "Temporary network loss became EOF/timeout instead of waiting for missing cache bytes")
        XCTAssertLessThanOrEqual(server!.requests.count, 6, "Network retry loop ignored backoff")
        server!.setNetworkMode(.online)
        wait(for: [finished], timeout: 8)
        let data = try XCTUnwrap(lock.withLock { received })
        XCTAssertEqual(data, cachePattern(4 * cacheMB, data.count))
        XCTAssertGreaterThan(worker.diagnosticSnapshot["networkBytes"] ?? 0, 0)
        attachCacheRequests("network-recovery")
    }
    func testCacheNetworkDisconnectWaitsAndResumesMissingRange() throws { try checkNetworkReadRecovery(.disconnect) }
    func testCacheNetworkStalledConnectionRetriesAfterReturn() throws { try checkNetworkReadRecovery(.stall) }
    func testCacheNetwork503WaitsAndResumesMissingRange() throws { try checkNetworkReadRecovery(.unavailable) }

    private func checkOfflineCachedVideoAndRecovery(policy: FTVideoDecodingPolicy, mode: FixtureHTTPServer.NetworkMode, filename: String = "photoprism-tsu-hevc.mp4") throws {
        let url = try http(filename)
        let original = try Data(contentsOf: fixture(filename))
        let session = PlaybackSession(url: url, cache: true, policy: policy)
        let store = try CacheStore(videoURL: url, directory: session.player.prepareCacheSession().directory)
        store.setTotalFileSize(Int64(original.count))
        let quarter = original.count / 4
        store.write(original.prefix(quarter), at: 0)
        store.write(original.suffix(quarter), at: Int64(original.count - quarter))
        store.saveIndex(); store.closeHandles()
        server!.setNetworkMode(mode, dropExistingConnections: true)

        sessions.append(session); session.start()
        try require(until(15) { session.ready || session.failure != nil }, "Offline cached video did not open")
        #if targetEnvironment(simulator)
        if policy == .hardware, let error = session.failure as NSError?, error.code == -2001 {
            throw XCTSkip("Simulator has no verified hardware decoder")
        }
        #endif
        try assertPlayback(session)
        try assertBackend(session, policy)
        try seek(session, target: 0.3, rate: 1)
        try seek(session, target: session.player.duration - 0.4, rate: 1)
        // A short test timeout reproduces the production 30-second timeout without a long sleep.
        session.player.decoder?.bufferingTimeout = 0.25
        let target = session.player.duration * 0.5
        var completions: [Bool] = []
        var completedWhileBuffering: Bool?
        session.player.seek(to: target) { success in
            completedWhileBuffering = session.player.state == .buffering || session.player.decoder?.buffering == true
            completions.append(success)
        }
        try require(until(5) { session.player.state == .buffering || session.failure != nil },
                    "Seek to missing data did not enter buffering")
        pump(0.8)
        XCTAssertTrue(completions.isEmpty, "Seek completed before missing target media became available")
        XCTAssertNil(session.failure, "Offline cache miss must remain buffering instead of permanently failing")
        XCTAssertEqual(session.finished, 0, "Missing bytes were incorrectly treated as EOF")
        XCTAssertEqual(session.player.state, .buffering)
        let frames = session.sink.frames
        server!.setNetworkMode(.online)
        try require(until(15) {
            !completions.isEmpty && session.sink.frames > frames + 2 && session.player.progress >= target - 0.3 || session.failure != nil
        }, "Seek completion or playback did not resume after network recovery")
        XCTAssertNil(session.failure)
        XCTAssertEqual(completions, [true], "Recovered seek must complete successfully exactly once")
        XCTAssertEqual(completedWhileBuffering, false, "Seek completed before target buffering ended")
        pump(0.3)
        XCTAssertEqual(completions, [true], "Recovered seek delivered a duplicate callback")
        try assertBackend(session, policy)
        session.measurements.append(["operation": "offline-cached-start-end-missing-middle-recover", "target": target, "framesAfterRecovery": session.sink.frames, "progress": session.player.progress])
        attachCacheRequests("video-offline-recovery-" + policy.rawValue)
    }
    func testCacheNetworkFFmpegOfflineStartEndMissingMiddleRecovery() throws { try checkOfflineCachedVideoAndRecovery(policy: .ffmpeg, mode: .disconnect) }
    func testCacheNetworkHardwareOfflineStartEndMissingMiddleRecovery() throws { try checkOfflineCachedVideoAndRecovery(policy: .hardware, mode: .disconnect) }
    func testCacheNetworkFFmpeg503VideoRecovery() throws { try checkOfflineCachedVideoAndRecovery(policy: .ffmpeg, mode: .unavailable) }
    func testCacheNetworkHardware503VideoRecovery() throws { try checkOfflineCachedVideoAndRecovery(policy: .hardware, mode: .unavailable) }

    func testCacheNetworkRepeatedDropsResumeWithoutLosingCachedBytes() throws {
        let url = try http("cache-pattern.bin"), store = try CacheStore(videoURL: url)
        seedCache(store, spans: [0..<cacheMB, (20 * cacheMB)..<(24 * cacheMB)])
        server!.setNetworkMode(.disconnect)
        let worker = CacheWorker(videoURL: url, cacheStore: store, readTimeout: 0.15)
        let io = try FTCacheIOContext(worker: worker); defer { io.close() }
        for round in 0..<3 {
            server!.setNetworkMode(.disconnect, dropExistingConnections: true); pump(0.1)
            let offset = store.firstUncachedByte(from: 0)
            XCTAssertLessThan(offset, Int64(20 * cacheMB))
            worker.seek(to: offset)
            let lock = NSLock(); var completed = false; var received: Data?
            let finished = expectation(description: "network recovery round \(round)")
            DispatchQueue.global().async {
                let data = worker.read(offset: offset, length: 1024)
                lock.withLock { received = data; completed = true }; finished.fulfill()
            }
            pump(0.4)
            XCTAssertFalse(lock.withLock { completed })
            XCTAssertEqual(store.read(at: 0, length: 1024), cachePattern(0, 1024))
            server!.setNetworkMode(.online)
            wait(for: [finished], timeout: 8)
            let data = try XCTUnwrap(lock.withLock { received })
            XCTAssertEqual(data, cachePattern(Int(offset), data.count))
            try require(until(10) { store.isCached(offset: offset, length: cacheMB) }, "Recovered transfer did not continue loading")
        }
        attachCacheRequests("three-network-drops")
    }
    func testCacheNetworkStopWhileWaitingUnblocksImmediately() throws {
        let url = try http("cache-pattern.bin"), store = try CacheStore(videoURL: url)
        store.setTotalFileSize(Int64(24 * cacheMB)); server!.setNetworkMode(.stall)
        let worker = CacheWorker(videoURL: url, cacheStore: store, readTimeout: 0.15)
        let io = try FTCacheIOContext(worker: worker)
        let finished = expectation(description: "offline read stopped")
        DispatchQueue.global().async { XCTAssertNil(worker.read(offset: 0, length: 1024)); finished.fulfill() }
        pump(0.3)
        let start = ProcessInfo.processInfo.systemUptime
        io.close()
        wait(for: [finished], timeout: 1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        pump(0.2); let count = server!.requests.count; pump(0.4)
        XCTAssertEqual(server!.requests.count, count, "Retry continued after Stop")
    }

    func testCacheNetworkSlowFirstByteDoesNotRestartHealthyRequest() throws {
        let session = try start(http("slow-first-byte.mp4"), cache: true, policy: .ffmpeg, timeout: 12)
        try assertPlayback(session)
        XCTAssertEqual(server!.rangeRequests.count, 1, "A healthy slow request was cancelled before its first byte")
        attachCacheRequests("slow-first-byte-six-seconds")
    }

    func testCacheNetworkDropMidBodyResumesAfterLastPersistedByte() throws {
        let url = try http("cache-pattern.bin"), store = try CacheStore(videoURL: url)
        store.setTotalFileSize(Int64(24 * cacheMB))
        let prefix = 128 * 1024
        // Build the debug fixture before arming a 150 ms network-idle watchdog.
        // This test interrupts a response body, not CPU-bound fixture generation.
        server!.prepareCachePattern()
        server!.dropNextBody(afterBytes: prefix, thenDisconnect: true)
        let worker = CacheWorker(videoURL: url, cacheStore: store, readTimeout: 0.15)
        let io = try FTCacheIOContext(worker: worker); defer { io.close() }
        try require(until(12) { store.isCached(offset: 0, length: prefix) }, "Partial response bytes were not persisted")
        server!.setNetworkMode(.disconnect, dropExistingConnections: true)
        XCTAssertEqual(worker.read(offset: 0, length: prefix), cachePattern(0, prefix))
        worker.seek(to: Int64(prefix))
        let lock = NSLock(); var completed = false; var received: Data?
        let finished = expectation(description: "resume interrupted HTTP body")
        DispatchQueue.global().async {
            let data = worker.read(offset: Int64(prefix), length: 1024)
            lock.withLock { received = data; completed = true }; finished.fulfill()
        }
        pump(0.7); XCTAssertFalse(lock.withLock { completed })
        server!.setNetworkMode(.online)
        wait(for: [finished], timeout: 8)
        let data = try XCTUnwrap(lock.withLock { received })
        XCTAssertEqual(data, cachePattern(prefix, data.count))
        for request in cacheRequests().dropFirst() {
            XCTAssertGreaterThanOrEqual(request.lowerBound, prefix, "Reconnect downloaded the persisted prefix again")
        }
        attachCacheRequests("mid-body-drop-resume")
    }

    func testCacheNetworkH264AACFFmpegOfflineRecovery() throws { try checkOfflineCachedVideoAndRecovery(policy: .ffmpeg, mode: .disconnect, filename: "sample.mp4") }
    func testCacheNetworkH264AACHardwareOfflineRecovery() throws { try checkOfflineCachedVideoAndRecovery(policy: .hardware, mode: .disconnect, filename: "sample.mp4") }

    func testPartialFLVCacheDoesNotTreatSparseNativeIndexAsCompleteTimeline() throws {
        let url = try http("h264.flv")
        let bytes = try Data(contentsOf: fixture("h264.flv"))
        let partial = PlaybackSession(url: url, cache: true, policy: .ffmpeg)
        let store = try CacheStore(videoURL: url, directory: partial.player.prepareCacheSession().directory)
        let third = bytes.count / 3
        store.setTotalFileSize(Int64(bytes.count))
        store.write(bytes.prefix(third), at: 0)
        store.write(bytes.suffix(third), at: Int64(bytes.count-third))
        store.saveIndex(); store.closeHandles()
        server!.setNetworkMode(.stall, dropExistingConnections: true)
        sessions.append(partial); partial.start()
        try assertPlayback(partial)
        XCTAssertGreaterThan(partial.player.cacheProgress.cachedBytes, 0)
        XCTAssertGreaterThan(partial.player.downloadProgress, 0)
        XCTAssertLessThan(partial.player.downloadProgress, 1)
        XCTAssertTrue(partial.player.cachedTimeRanges.isEmpty, "Sparse FLV index painted uncached media as available offline")
        partial.player.stop()
        server!.setNetworkMode(.online, dropExistingConnections: true)
        let complete = try start(url, cache: true, policy: .ffmpeg)
        try assertPlayback(complete)
        try require(until(5) { complete.player.downloadProgress == 1 }, "FLV fixture did not finish caching")
        XCTAssertEqual(complete.player.cachedTimeRanges.first?.start, 0)
        XCTAssertEqual(try XCTUnwrap(complete.player.cachedTimeRanges.last?.end), complete.player.duration, accuracy: 0.001)
    }

    private func checkSeekEndOfflineBackToZero(_ policy: FTVideoDecodingPolicy, filename: String) throws {
        let url = try http(filename), original = try Data(contentsOf: fixture(filename))
        let session = PlaybackSession(url: url, cache: true, policy: policy)
        let store = try CacheStore(videoURL: url, directory: session.player.prepareCacheSession().directory), quarter = original.count / 4
        store.setTotalFileSize(Int64(original.count))
        store.write(original.prefix(quarter), at: 0)
        store.write(original.suffix(quarter), at: Int64(original.count - quarter))
        store.saveIndex(); store.closeHandles()
        server!.setNetworkMode(.stall, dropExistingConnections: true)

        sessions.append(session); session.start()
        try require(until(15) { session.ready || session.failure != nil }, "Partial cache failed to open")
        #if targetEnvironment(simulator)
        if policy == .hardware, let error = session.failure as NSError?, error.code == -2001 { throw XCTSkip("Simulator has no verified hardware decoder") }
        #endif
        try assertPlayback(session); try assertBackend(session, policy)
        let cached = session.player.cachedTimeRanges
        XCTAssertTrue(cached.contains { $0.start <= 0.1 && $0.end > 0.3 }, "Cached head missing from timeline: \(cached)")
        XCTAssertFalse(cached.contains { $0.start < session.player.duration * 0.45 && $0.end > session.player.duration * 0.55 }, "Timeline painted uncached middle")
        try seek(session, target: session.player.duration - 0.4, rate: 1)
        server!.setNetworkMode(.disconnect, dropExistingConnections: true)
        let requests = server!.rangeRequests.count, frames = session.sink.frames
        var complete: Bool?
        session.player.seek(to: 0) { complete = $0 }
        try require(until(5) { complete != nil }, "Seek-zero callback missing")
        XCTAssertEqual(complete, true)
        try require(until(5) { session.sink.frames > frames + 3 && session.player.progress >= 0.3 && session.player.progress < 2 }, "Cached beginning did not play offline after seeking to end")
        XCTAssertNil(session.failure)
        for request in server!.rangeRequests.dropFirst(requests) {
            let first = try XCTUnwrap(Int(request.split(separator: "-")[0]))
            XCTAssertGreaterThanOrEqual(first, quarter, "Seek zero downloaded cached prefix again")
        }
        session.measurements.append(["operation": "seek-end-offline-back-to-zero", "frames": session.sink.frames, "progress": session.player.progress, "cachedRanges": cached.map { ["start": $0.start, "end": $0.end] }])
        attachCacheRequests("end-offline-zero-" + filename + policy.rawValue)
    }
    func testCacheTimelineHEVCFFmpegSeekEndOfflineBackToZero() throws { try checkSeekEndOfflineBackToZero(.ffmpeg, filename: "photoprism-tsu-hevc.mp4") }
    func testCacheTimelineHEVCHardwareSeekEndOfflineBackToZero() throws { try checkSeekEndOfflineBackToZero(.hardware, filename: "photoprism-tsu-hevc.mp4") }
    func testCacheTimelineH264FFmpegSeekEndOfflineBackToZero() throws { try checkSeekEndOfflineBackToZero(.ffmpeg, filename: "sample.mp4") }
    func testCacheTimelineH264HardwareSeekEndOfflineBackToZero() throws { try checkSeekEndOfflineBackToZero(.hardware, filename: "sample.mp4") }


    private func checkCachedHTTPFailure(_ code: Int) throws {
        let session = PlaybackSession(url: try http("status/" + String(code)), cache: true, policy: .ffmpeg)
        sessions.append(session); session.start()
        try require(until(5) { session.failure != nil }, "Permanent HTTP error did not surface")
        let error = try XCTUnwrap(session.failure as NSError?)
        XCTAssertEqual(error.domain, "StreamingLoader", "HTTP status lost its loader domain: \(error)")
        XCTAssertEqual(error.code, code, "Original HTTP status was lost: \(error)")
        XCTAssertTrue(error.localizedDescription.contains("HTTP \(code)"))
        XCTAssertEqual(session.player.state, .failed); XCTAssertEqual(session.finished, 0)
        pump(0.3); XCTAssertEqual(session.errorCount, 1); XCTAssertTrue(session.callbackThreadsAreMain)
        let count = server!.rangeRequests.count; pump(0.3)
        XCTAssertEqual(server!.rangeRequests.count, count, "Permanent HTTP error kept retrying")
        attachCacheRequests("fatal-http-" + String(code))
    }
    func testErrorCachedHTTP401PreservesStatus() throws { try checkCachedHTTPFailure(401) }
    func testErrorCachedHTTP403PreservesStatus() throws { try checkCachedHTTPFailure(403) }
    func testErrorCachedHTTP404PreservesStatus() throws { try checkCachedHTTPFailure(404) }
    func testErrorCachedHTTP410PreservesStatus() throws { try checkCachedHTTPFailure(410) }
    func testErrorCachedHTTP416PreservesStatus() throws { try checkCachedHTTPFailure(416) }

    private func checkColdOpenTimeout(_ mode: FixtureHTTPServer.NetworkMode) throws {
        let url = try http("cold-open.mp4"); server!.setNetworkMode(mode)
        let format = FTFormatContext(contentURL: url, videoFormat: .unknown)
        let lock = NSLock(); var completed = false
        let done = expectation(description: "cold cache open bounded by timeout")
        let started = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global().async {
            format.setupSync(timeoutSeconds: 1, useCache: true)
            lock.withLock { completed = true }; done.fulfill()
        }
        let withinBudget = until(2.5) { lock.withLock { completed } }
        if !withinBudget { format.cancelPendingReads() }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(withinBudget, "Cached cold open ignored 1-second timeout and blocked AVIO")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        XCTAssertEqual(format.error?.code, URLError.timedOut.rawValue, "Timeout surfaced as EOF/generic format error")
        format.destroy()
    }
    func testErrorCachedColdStallOpenTimesOut() throws { try checkColdOpenTimeout(.stall) }
    func testErrorCachedColdOfflineOpenTimesOut() throws { try checkColdOpenTimeout(.disconnect) }
    func testErrorCachedColdHTTP500OpenTimesOut() throws { try checkColdOpenTimeout(.httpError(500)) }
    func testErrorCachedColdHTTP503OpenTimesOut() throws { try checkColdOpenTimeout(.unavailable) }
    private func checkMidPlaybackHTTPFailure(_ code: Int, policy: FTVideoDecodingPolicy) throws {
        let filename = "photoprism-tsu-hevc.mp4", url = try http(filename)
        let data = try Data(contentsOf: fixture(filename)), quarter = data.count / 4
        let session = PlaybackSession(url: url, cache: true, policy: policy)
        let store = try CacheStore(videoURL: url, directory: session.player.prepareCacheSession().directory); store.setTotalFileSize(Int64(data.count))
        store.write(data.prefix(quarter), at: 0); store.write(data.suffix(quarter), at: Int64(data.count - quarter))
        store.saveIndex(); store.closeHandles(); server!.setNetworkMode(.stall)
        sessions.append(session); session.start()
        try require(until(10) { session.ready || session.failure != nil }, "Cached video failed to open")
        #if targetEnvironment(simulator)
        if policy == .hardware, let error = session.failure as NSError?, error.code == -2001 { throw XCTSkip("Simulator has no verified hardware decoder") }
        #endif
        try assertPlayback(session); try assertBackend(session, policy)
        server!.setNetworkMode(.httpError(code), dropExistingConnections: true)
        session.player.seek(to: session.player.duration * 0.5)
        try require(until(6) { session.failure != nil }, "Runtime HTTP error became EOF/finish or infinite buffering")
        XCTAssertEqual((session.failure as NSError?)?.code, code)
        pump(0.5); XCTAssertEqual(session.errorCount, 1, "Fatal error was delivered repeatedly")
        XCTAssertEqual(session.finished, 0, "HTTP failure was announced as successful EOF")
        XCTAssertEqual(session.player.state, .failed); XCTAssertTrue(session.callbackThreadsAreMain)
        attachCacheRequests("runtime-http-" + String(code) + policy.rawValue)
    }
    func testErrorRuntime403FFmpeg() throws { try checkMidPlaybackHTTPFailure(403, policy: .ffmpeg) }
    func testErrorRuntime403Hardware() throws { try checkMidPlaybackHTTPFailure(403, policy: .hardware) }
    func testErrorRuntime404FFmpeg() throws { try checkMidPlaybackHTTPFailure(404, policy: .ffmpeg) }
    func testErrorRuntime404Hardware() throws { try checkMidPlaybackHTTPFailure(404, policy: .hardware) }
    func testErrorHTTP408RecoversWithoutFatalFailure() throws { try checkNetworkReadRecovery(.httpError(408)) }
    func testErrorHTTP429RecoversWithoutFatalFailure() throws { try checkNetworkReadRecovery(.httpError(429)) }
    func testErrorHTTP500RecoversWithoutFatalFailure() throws { try checkNetworkReadRecovery(.httpError(500)) }
    func testErrorHTTP502RecoversWithoutFatalFailure() throws { try checkNetworkReadRecovery(.httpError(502)) }
    func testErrorHTTP504RecoversWithoutFatalFailure() throws { try checkNetworkReadRecovery(.httpError(504)) }

    func testErrorFailureCallbackOnlyOncePerPlaybackAndResetsOnReopen() throws {
        let session = try start(fixture("sample.mp4")); try assertPlayback(session)
        let decoder = try XCTUnwrap(session.player.decoder)
        for _ in 0..<3 { session.player.decoder(decoder, didError: NSError(domain: "error-test", code: 403, userInfo: [NSLocalizedDescriptionKey: "HTTP 403"])) }
        pump(0.3); XCTAssertEqual(session.errorCount, 1)
        let reported = try XCTUnwrap(session.failure as NSError?)
        XCTAssertGreaterThan(reported.userInfo["currentTime"] as? Double ?? -1, 0.1)
        XCTAssertEqual(try XCTUnwrap(reported.userInfo["duration"] as? Double), 30, accuracy: 0.001)
        session.ready = false; session.player.replaceVideo()
        try require(until { session.ready }, "Reopen did not reset failure generation")
        let reopened = try XCTUnwrap(session.player.decoder)
        session.player.decoder(reopened, didError: NSError(domain: "error-test", code: 404))
        pump(0.3); XCTAssertEqual(session.errorCount, 2)
    }

    func testErrorCurrentTimeTracksProgressAndSeek() throws {
        let session = try start(fixture("sample.mp4")); try assertPlayback(session)
        XCTAssertEqual(session.player.currentTime, session.player.progress)
        session.player.pause(); var done: Bool?
        session.player.seek(to: 15) { done = $0 }
        try require(until { done != nil }, "Seek callback missing")
        XCTAssertEqual(done, true); XCTAssertEqual(session.player.currentTime, 15, accuracy: 0.2)
        XCTAssertEqual(session.player.duration, 30, accuracy: 0.001)
    }

    private func checkCachedCorruptInput(_ path: String) throws {
        let session = PlaybackSession(url: try http(path), cache: true, policy: .ffmpeg)
        sessions.append(session); session.start()
        try require(until(5) { session.failure != nil }, "Corrupt cached input hung instead of failing")
        XCTAssertFalse(session.ready); XCTAssertEqual(session.finished, 0)
        XCTAssertEqual(session.sink.frames, 0); XCTAssertEqual(session.player.state, .failed)
        pump(0.2); XCTAssertEqual(session.errorCount, 1); XCTAssertTrue(session.callbackThreadsAreMain)
        XCTAssertFalse(session.failure!.localizedDescription.isEmpty)
        let requests = server!.rangeRequests.count; pump(0.3)
        XCTAssertEqual(server!.rangeRequests.count, requests, "Invalid/empty input kept downloading")
        XCTAssertLessThanOrEqual(requests, 2, "Empty response caused a tight retry loop")
    }
    func testErrorCachedHTMLDisguisedAsMP4() throws { try checkCachedCorruptInput("html.mp4") }
    func testErrorCachedEmptyMP4() throws { try checkCachedCorruptInput("empty.mp4") }
    func testErrorCachedTruncatedMP4() throws { try checkCachedCorruptInput("truncated.mp4") }
    func testErrorNonCachedStallHonorsNativeTimeout() throws {
        let format = FTFormatContext(contentURL: try http("stall"), videoFormat: .unknown)
        let lock = NSLock(); var finished = false
        let done = expectation(description: "native open timeout")
        DispatchQueue.global().async { format.setupSync(timeoutSeconds: 1, useCache: false); lock.withLock { finished = true }; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(lock.withLock { finished })
        XCTAssertNotNil(format.error)
        XCTAssertTrue(format.error?.localizedDescription.lowercased().contains("timed out") ?? false)
        format.destroy()
    }
    func testErrorConnectionRefusedFailsWithoutFramesOrFinish() throws {
        let url = try http("sample.mp4"); server!.stop(); server = nil
        let session = PlaybackSession(url: url, cache: false, policy: .ffmpeg); sessions.append(session); session.start()
        try require(until(5) { session.failure != nil }, "Refused connection did not fail")
        XCTAssertEqual(session.player.state, .failed); XCTAssertEqual(session.finished, 0); XCTAssertEqual(session.sink.frames, 0)
        pump(0.2); XCTAssertEqual(session.errorCount, 1); XCTAssertTrue(session.callbackThreadsAreMain)
    }

    private func sessionCacheFiles(_ url: URL) -> Set<URL> {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        let names = ["cache_\(hash).bin", "index_\(hash).json"]
        let iterator = FileManager.default.enumerator(at: CacheStore.cacheDirectory, includingPropertiesForKeys: nil)
        return Set((iterator?.allObjects as? [URL] ?? []).filter { names.contains($0.lastPathComponent) })
    }
    private func fullSession(_ url: URL) throws -> PlaybackSession {
        let session = try start(url, cache: true, policy: .ffmpeg); try assertPlayback(session)
        try require(until(8) { session.player.downloadProgress >= 1 }, "Cache did not complete")
        return session
    }
    func testSessionCacheStopKeepsVideoAndIndex() throws {
        let url = try http("sample.mp4"), session = try fullSession(url)
        let files = sessionCacheFiles(url); XCTAssertGreaterThanOrEqual(files.count, 2)
        session.stop()
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Stop unexpectedly deleted session cache")
        XCTAssertEqual(session.player.downloadProgress, 1)
        XCTAssertEqual(session.player.duration, 30, accuracy: 0.001)
    }
    func testSessionCacheDeinitDeletesWhilePlaying() throws {
        let url = try http("sample.mp4")
        var owner: PlaybackSession? = PlaybackSession(url: url, cache: true, policy: .ffmpeg)
        weak var player = owner?.player
        owner!.start(); try require(until { owner!.ready }, "No ready"); try assertPlayback(owner!)
        try require(until { owner!.player.downloadProgress >= 1 }, "Cache incomplete")
        let files = sessionCacheFiles(url); XCTAssertFalse(files.isEmpty)
        owner = nil
        XCTAssertTrue(until(3) { player == nil }, "Player retained after owner released")
        XCTAssertTrue(until(2) { files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }, "Deinit left cache on disk")
    }
    func testSessionCacheDifferentVideoAfterStopDoesNotKeepPreviousFile() throws {
        let firstURL = try http("sample.mp4"), first = try fullSession(firstURL)
        let oldFiles = sessionCacheFiles(firstURL); first.stop()
        let secondURL = try http("photoprism-tsu-hevc.mp4")
        first.ready = false; first.stopRequested = false; first.player.replaceVideo(with: secondURL)
        try require(until { first.ready && first.player.downloadProgress == 1 }, "Changed URL did not open")
        try assertPlayback(first)
        let second = first
        XCTAssertTrue(oldFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "Switch retained old video cache")
        XCTAssertFalse(sessionCacheFiles(secondURL).isEmpty); XCTAssertGreaterThan(second.player.currentTime, 0.1)
        first.measurements.append(["operation": "changed-url-cleans-cache", "newURL": secondURL.absoluteString, "oldFilesDeleted": oldFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }])
    }
    func testSessionCacheSameURLNewPlayerHasIndependentFiles() throws {
        let url = try http("sample.mp4"), first = try fullSession(url)
        let oldFiles = sessionCacheFiles(url), requests = server!.rangeRequests.count
        let second = try fullSession(url), newFiles = sessionCacheFiles(url).subtracting(oldFiles)
        XCTAssertFalse(newFiles.isEmpty, "New player reused another session's cache files")
        XCTAssertGreaterThan(server!.rangeRequests.count, requests, "New session reused old disk cache")
        first.stop(); first.player.replaceVideo(with: try http("photoprism-tsu-hevc.mp4")); pump(0.3)
        XCTAssertTrue(newFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Old Stop deleted current session cache")
        let frames = second.sink.frames; try require(until { second.sink.frames > frames + 2 }, "Current session stopped after old cleanup")
    }
    func testSessionCacheSamePlayerReplayKeepsCacheWithoutHTTP() throws {
        let url = try http("sample.mp4"), session = try fullSession(url)
        let files = sessionCacheFiles(url), requests = server!.requests.count
        session.ready = false; session.player.replaceVideo()
        try require(until { session.ready }, "Replay failed"); try assertPlayback(session)
        XCTAssertEqual(server!.requests.count, requests)
        XCTAssertEqual(sessionCacheFiles(url), files)
    }
    func testSessionCacheStopThenReopenUsesExistingCache() throws {
        let url = try http("sample.mp4"), first = try fullSession(url)
        let oldFiles = sessionCacheFiles(url); first.stop(); let requests = server!.rangeRequests.count
        first.ready = false; first.stopRequested = false; first.player.play()
        try require(until { first.ready }, "Reopen failed"); try assertPlayback(first)
        XCTAssertEqual(server!.rangeRequests.count, requests, "Stop/reopen downloaded the same video again")
        XCTAssertTrue(oldFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        first.measurements.append(["operation": "stop-play-same-url", "requestsBefore": requests, "requestsAfter": server!.rangeRequests.count, "cacheProgress": first.player.downloadProgress])
    }
    func testSessionCacheStopStalledOpenDoesNotResurrectFiles() throws {
        let url = try http("stall"), session = PlaybackSession(url: try http("stall"), cache: true)
        sessions.append(session); session.start(); pump(0.2)
        let files = sessionCacheFiles(url); XCTAssertFalse(files.isEmpty)
        session.stop(); pump(0.3); session.callbacksAfterStop = 0
        let requests = server!.requests.count; pump(0.5)
        XCTAssertEqual(server!.requests.count, requests)
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Stop removed the retained cache session")
        XCTAssertEqual(session.callbacksAfterStop, 0)
    }

    func testSessionCacheClosedSessionCannotStartHTTPOrRecreateFiles() throws {
        let session = try FTPlaybackCacheSession(), url = try http("sample.mp4"), directory = session.directory
        session.close()
        XCTAssertThrowsError(try session.makeWorker(videoURL: url)) { XCTAssertEqual(($0 as NSError).code, URLError.cancelled.rawValue) }
        let format = FTFormatContext(contentURL: url, videoFormat: .unknown, cacheSession: session)
        format.setupSync(timeoutSeconds: 1, useCache: true)
        XCTAssertEqual(format.error?.code, URLError.cancelled.rawValue)
        XCTAssertTrue(server!.requests.isEmpty, "Ended cache session silently fell back to uncached HTTP")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        format.destroy()
    }
    /// Rapid seek can interrupt AVIO while it refills a seek-back from byte 0,
    /// leaving an empty buffer at position 0. The MP4 demuxer reads that as a
    /// restarted stream; every later seek then failed (Seek failed at 1.0x).
    func testMP4SeekAfterInterruptedSeekbackAtFileStartRecovers() throws {
        let format = FTFormatContext(contentURL: try http("internet-hevc.mp4"), videoFormat: .unknown)
        format.setupSync(timeoutSeconds: 5, useCache: true); XCTAssertNil(format.error)
        defer { format.destroy() }
        let pb = try XCTUnwrap(format.formatContext?.pointee.pb)
        var packet = av_packet_alloc(); defer { av_packet_free(&packet) }
        // What avio_seek's seek-back does before its refill is interrupted:
        // the source is moved to byte 0, then the buffer is left empty at EOF.
        XCTAssertEqual(pb.pointee.seek?(pb.pointee.opaque, 0, SEEK_SET), 0)
        pb.pointee.pos = 0; pb.pointee.buf_ptr = pb.pointee.buffer; pb.pointee.buf_end = pb.pointee.buffer
        pb.pointee.eof_reached = 1
        for target in [6.0, 1.0, 1.5] {
            XCTAssertTrue(format.seekFile(withFFTimebase: target), "Seek to \(target) failed")
            XCTAssertGreaterThanOrEqual(format.readFrame(packet), 0, "No packet after seek to \(target)")
            av_packet_unref(packet)
        }
    }
    func testSessionCacheStandaloneFormatDestroyRemovesOwnedCache() throws {
        let url = try http("sample.mp4"), format = FTFormatContext(contentURL: try http("sample.mp4"), videoFormat: .unknown)
        format.setupSync(timeoutSeconds: 5, useCache: true); XCTAssertNil(format.error)
        let files = sessionCacheFiles(url); XCTAssertFalse(files.isEmpty)
        format.destroy()
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testSessionCacheOldDecoderCannotCreateWorkerAfterStop() throws {
        let session = try FTPlaybackCacheSession(), url = try http("stall"), revision = session.currentRevision
        let old = try session.makeWorker(videoURL: url, revision: revision)
        session.suspendWorkers(); pump(0.2); let requests = server!.requests.count
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
        XCTAssertThrowsError(try session.makeWorker(videoURL: url, revision: revision)) { XCTAssertEqual(($0 as NSError).code, URLError.cancelled.rawValue) }
        old.seek(to: 0); pump(0.3); XCTAssertEqual(server!.requests.count, requests)
        let replay = try session.makeWorker(videoURL: url, revision: session.currentRevision)
        replay.close(); session.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.path))
    }


}
