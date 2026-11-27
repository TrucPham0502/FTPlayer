import XCTest
import CryptoKit
import UIKit
import CoreVideo
import libavcodec
@testable import FTPlayer

final class FTPlayerHTTPTests: UnitTestCase {
    func testLoadControlHysteresisRateAndSizePriority() {
        let config = FTPlayerLoadControlConfiguration(minimumBufferDuration:20,maximumBufferDuration:50,targetBufferBytes:1000)
        var control = FTPlayerLoadControl(configuration:config)
        XCTAssertFalse(control.shouldLoad(mediaAhead:30,bytesAhead:0,rate:1))
        XCTAssertTrue(control.shouldLoad(mediaAhead:19,bytesAhead:0,rate:1))
        XCTAssertTrue(control.shouldLoad(mediaAhead:45,bytesAhead:0,rate:1))
        XCTAssertFalse(control.shouldLoad(mediaAhead:50,bytesAhead:0,rate:1))
        XCTAssertFalse(control.shouldLoad(mediaAhead:30,bytesAhead:0,rate:1))
        XCTAssertTrue(control.shouldLoad(mediaAhead:30,bytesAhead:0,rate:2))
        XCTAssertEqual(config.minimumDuration(rate:16),50)
        XCTAssertFalse(control.shouldLoad(mediaAhead:0,bytesAhead:1000,rate:16))
        var timeFirst = FTPlayerLoadControl(configuration:.init(minimumBufferDuration:20,maximumBufferDuration:50,targetBufferBytes:1000,prioritizesTimeOverSize:true))
        XCTAssertTrue(timeFirst.shouldLoad(mediaAhead:1,bytesAhead:1000,rate:1))
        XCTAssertFalse(timeFirst.shouldLoad(mediaAhead:50,bytesAhead:1000,rate:1))
    }

    func testLoadControlConfigurationHandlesUnknownAndExtremeDurations() {
        for value in [Double.nan,Double.infinity,-1,0,Double.greatestFiniteMagnitude] {
            let config = FTPlayerLoadControlConfiguration(minimumBufferDuration:value,maximumBufferDuration:value)
            XCTAssertTrue(config.minimumBufferDuration.isFinite)
            XCTAssertGreaterThanOrEqual(config.minimumBufferDuration,0.5)
            XCTAssertGreaterThanOrEqual(config.maximumBufferDuration,config.minimumBufferDuration)
            XCTAssertLessThanOrEqual(config.maximumBufferDuration,Double(Int32.max)/1000)
        }
    }

    func testLoadControlDefaultsUseMediaTimeAndSelectedTracks() {
        let config = FTPlayerLoadControlConfiguration()
        for rate: Float in [0.5,1,2,4,8,16] {
            XCTAssertEqual(config.minimumDuration(rate:rate),50)
            var control = FTPlayerLoadControl(configuration:config,video:true,audio:true)
            XCTAssertTrue(control.shouldLoad(mediaAhead:49,bytesAhead:0,rate:rate))
            XCTAssertFalse(control.shouldLoad(mediaAhead:50,bytesAhead:0,rate:rate))
        }
        XCTAssertEqual(config.targetBytes(video:true,audio:true),144179200)
        XCTAssertEqual(config.targetBytes(video:false,audio:true),13107200)
        XCTAssertEqual(config.targetBytes(video:true,audio:false),131072000)
    }


    func testLoadControlVBRWindowIncludesKeyframeAndBothTracks() {
        let video = CacheTrackTimeline(samples:[
            .init(offset:100,size:100,start:0,end:10,keyframe:true),
            .init(offset:1000,size:1000,start:10,end:20,keyframe:false),
            .init(offset:10000,size:10000,start:20,end:30,keyframe:true),
            .init(offset:20000,size:10000,start:30,end:40,keyframe:false)],requiresKeyframe:true)
        let audio = CacheTrackTimeline(samples:[.init(offset:200,size:100,start:0,end:10,keyframe:true),.init(offset:30000,size:500,start:10,end:40,keyframe:true)],requiresKeyframe:false)
        let index = CacheTimelineIndex(tracks:[video,audio],duration:40)
        let window = index.byteWindow(position:12,duration:15)
        XCTAssertEqual(window?.start,100,"Seek preroll requires the preceding keyframe")
        XCTAssertEqual(window?.end,30499,"Audio can lie after the video byte envelope")
        XCTAssertEqual(index.byteWindow(position:25,duration:5)?.start,10000)
    }

    func testCacheTimelineUsesSampleTimesInsteadOfBytePercentage() {
        let track = CacheTrackTimeline(samples: [
            .init(offset: 0, size: 900, start: 0, end: 1, keyframe: true),
            .init(offset: 900, size: 100, start: 1, end: 10, keyframe: true)
        ], requiresKeyframe: true)
        XCTAssertEqual(track.cachedTimes(in: [.init(start: 0, end: 899)]), [.init(start: 0, end: 1)])
        XCTAssertEqual(track.cachedTimes(in: [.init(start: 900, end: 999)]), [.init(start: 1, end: 10)])
    }

    func testCacheTimelinePreservesGapsAndRequiresCompleteKeyframeChain() {
        var samples: [CacheTimelineSample] = []
        for i in 0..<8 {
            samples.append(CacheTimelineSample(offset: Int64(i * 100), size: 100, start: Double(i), end: Double(i + 1), keyframe: i % 4 == 0))
        }
        let track = CacheTrackTimeline(samples: samples, requiresKeyframe: true)
        XCTAssertEqual(track.cachedTimes(in: [.init(start: 100, end: 399)]), [])
        XCTAssertEqual(track.cachedTimes(in: [.init(start: 0, end: 99), .init(start: 200, end: 599)]), [.init(start: 0, end: 1), .init(start: 4, end: 6)])
        XCTAssertEqual(track.cachedTimes(in: [.init(start: 0, end: 98)]), [])
    }

    func testCacheTimelineIntersectsAudioVideoAndRecognizesCompleteFile() {
        let video = CacheTrackTimeline(samples: [.init(offset: 0, size: 100, start: 0, end: 4, keyframe: true)], requiresKeyframe: true)
        let audio = CacheTrackTimeline(samples: [.init(offset: 100, size: 100, start: 0, end: 2, keyframe: true), .init(offset: 200, size: 100, start: 2, end: 4, keyframe: true)], requiresKeyframe: false)
        let index = CacheTimelineIndex(tracks: [video, audio], duration: 4)
        XCTAssertEqual(index.ranges(in: [.init(start: 0, end: 199)], fileSize: 300), [.init(start: 0, end: 2)])
        XCTAssertEqual(index.ranges(in: [.init(start: 0, end: 299)], fileSize: 300), [.init(start: 0, end: 4)])
    }

    func testCacheTimelinePrerollKeyframeEstablishesReferencesAtZero() {
        let track = CacheTrackTimeline(samples: [
            .init(offset: 0, size: 100, start: 0, end: -0.02, keyframe: true),
            .init(offset: 100, size: 100, start: 0, end: 0.02, keyframe: false),
            .init(offset: 200, size: 100, start: 0.02, end: 0.04, keyframe: false)
        ], requiresKeyframe: true)
        XCTAssertEqual(track.cachedTimes(in: [.init(start: 0, end: 299)]), [.init(start: 0, end: 0.04)])
        XCTAssertEqual(track.cachedTimes(in: [.init(start: 100, end: 299)]), [])
    }

    func testSessionCacheStartupClearsLegacyAndOrphansKeepsCurrentProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default; defer { try? fm.removeItem(at: root) }
        for name in ["videos/old.bin", "index/old.json", "sessions/dead-process/old.bin", "sessions/current/live.bin"] {
            let path = root.appendingPathComponent(name)
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1,2,3]).write(to: path)
        }
        let current = try FTPlaybackCacheSession.prepareProcessDirectory(root: root, processID: "current")
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("live.bin").path))
        for old in ["videos", "index", "sessions/dead-process"] { XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(old).path)) }
        let next = try FTPlaybackCacheSession.prepareProcessDirectory(root: root, processID: "next-process")
        XCTAssertTrue(fm.fileExists(atPath: next.path)); XCTAssertFalse(fm.fileExists(atPath: current.path), "Cache survived into another process/session")
    }


    private let cacheMB = 1024 * 1024
    func testCacheReviewTruncatedBackingFileDropsInvalidCachedRanges() throws {
        let url = URL(fileURLWithPath: "/unit-cache-" + UUID().uuidString + ".bin")
        let directory = isolatedCacheDirectory(), store = try CacheStore(videoURL: url, directory: directory)
        seedCache(store, spans: [0..<(4 * cacheMB)])
        store.saveIndex(); store.closeHandles()
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        let file = directory.appendingPathComponent("videos/cache_\(key).bin")
        let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: UInt64(cacheMB)); try handle.close()
        let reopened = try CacheStore(videoURL: url, directory: directory); defer { reopened.closeHandles() }
        XCTAssertEqual(reopened.firstUncachedByte(from: 0), Int64(cacheMB), "Index still claims truncated bytes exist")
        XCTAssertEqual(reopened.cachedByteCount(from: Int64(cacheMB), maximum: 1024), 0)
    }

    func testCacheReviewSeekEndAndEOFNeverRequestsPastFile() throws {
        let url = URL(fileURLWithPath: "/unit-cache-" + UUID().uuidString + ".bin")
        let directory = isolatedCacheDirectory(), store = try CacheStore(videoURL: url, directory: directory)
        seedCache(store, spans: [0..<(24 * cacheMB)])
        let transport = NoRequestCacheTransport()
        let worker = CacheWorker(videoURL: url, cacheStore: store, loader: transport); defer { worker.close() }
        XCTAssertEqual(worker.seekPacket(offset: -17, whence: 2), Int64(24 * cacheMB - 17))
        var bytes = [UInt8](repeating: 0, count: 1024)
        let read = bytes.withUnsafeMutableBufferPointer { worker.readPacket(into: $0.baseAddress!, size: Int32($0.count)) }
        XCTAssertEqual(read, 17)
        XCTAssertEqual(Data(bytes.prefix(17)), cachePattern(24 * cacheMB - 17, 17))
        XCTAssertNil(worker.read(offset: Int64(24 * cacheMB), length: 1024))
        XCTAssertEqual(worker.seekPacket(offset: 0, whence: 2), Int64(24 * cacheMB))
        XCTAssertEqual(worker.seekPacket(offset: Int64(24 * cacheMB + 100), whence: 0), Int64(24 * cacheMB + 100))
        pump(0.2); XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCacheReviewWarmOfflineReopenAndCancelReadRecovery() throws {
        let url = URL(fileURLWithPath: "/unit-cache-" + UUID().uuidString + ".bin")
        let directory = isolatedCacheDirectory(), store = try CacheStore(videoURL: url, directory: directory)
        seedCache(store, spans: [0..<(24 * cacheMB)])
        store.saveIndex(); store.closeHandles()
        let reopened = try CacheStore(videoURL: url, directory: directory)
        let transport = NoRequestCacheTransport()
        let worker = CacheWorker(videoURL: url, cacheStore: reopened, readTimeout: 0.2, loader: transport); defer { worker.close() }
        for offset in [0, 12 * cacheMB, 24 * cacheMB - 1024, 0] {
            worker.cancelRead()
            XCTAssertNil(worker.read(offset: Int64(offset), length: 1024))
            worker.seek(to: Int64(offset))
            XCTAssertEqual(worker.read(offset: Int64(offset), length: 1024), cachePattern(offset, 1024))
        }
        XCTAssertEqual(worker.diagnosticSnapshot["rangeRequests"], 0)
        XCTAssertEqual(worker.diagnosticSnapshot["networkBytes"], 0)
    }

    func testCacheReviewResumeCancelledReadForBufferedSeek() throws {
        let url = URL(fileURLWithPath: "/unit-cache-" + UUID().uuidString + ".bin")
        let directory = isolatedCacheDirectory(), store = try CacheStore(videoURL: url, directory: directory)
        seedCache(store, spans: [0..<(24 * cacheMB)])
        let transport = NoRequestCacheTransport()
        let worker = CacheWorker(videoURL: url, cacheStore: store, loader: transport); defer { worker.close() }
        worker.seek(to: Int64(cacheMB)); worker.cancelRead()
        XCTAssertNil(worker.read(offset: Int64(cacheMB), length: 1024))
        worker.resumeRead() // AVIO soft seek does not call the byte-seek callback.
        XCTAssertEqual(worker.currentOffset, Int64(cacheMB))
        XCTAssertEqual(worker.read(offset: Int64(cacheMB), length: 1024), cachePattern(cacheMB, 1024))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    private func isolatedCacheDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func cachePattern(_ offset: Int, _ count: Int) -> Data {
        Data((offset..<(offset + count)).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 9) ^ ($0 >> 17)) })
    }

    private func seedCache(_ store: CacheStore, spans: [Range<Int>]) {
        store.setTotalFileSize(Int64(24 * cacheMB))
        for span in spans { store.write(cachePattern(span.lowerBound, span.count), at: Int64(span.lowerBound)) }
        store.flush()
    }

    private func metadataResponse(_ fields: [String: String] = [:]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: URL(fileURLWithPath: "/unit-http-response"),
                                      statusCode: 206, httpVersion: "HTTP/1.1", headerFields: fields))
    }

    func testHTTPRangeParsesKnownAndUnknownTotals() throws {
        let known = StreamingLoader.responseRange(try metadataResponse([
            "Content-Range": "BYTES\t4096-5119/8192", "Content-Length": "1024"]))
        XCTAssertEqual(known?.start, 4096)
        XCTAssertEqual(known?.end, 5119)
        XCTAssertEqual(known?.total, 8192)
        let unknown = StreamingLoader.responseRange(try metadataResponse(["Content-Range": "bytes 4096-5119/*"]))
        XCTAssertEqual(unknown?.start, 4096)
        XCTAssertEqual(unknown?.end, 5119)
        XCTAssertNil(unknown?.total)
    }

    func testHTTPRangeRejectsMissingMalformedAndUnsupportedUnits() throws {
        XCTAssertNil(StreamingLoader.responseRange(try metadataResponse()))
        for value in ["", "bytes", "bytes 0-1", "items 0-1/2", "bytes 0-1/2/3", "bytes 0-1-2/3", "bytes 0-1/2 extra", "bytes */2"] {
            XCTAssertNil(StreamingLoader.responseRange(try metadataResponse(["Content-Range": value])), value)
        }
    }

    func testHTTPRangeRejectsNegativeReversedAndOverflowingBounds() throws {
        for value in ["bytes -1-2/10", "bytes 4-2/10", "bytes 0-9223372036854775807/*", "bytes 0-9223372036854775808/*", "bytes 9223372036854775808-9223372036854775809/*"] {
            XCTAssertNil(StreamingLoader.responseRange(try metadataResponse(["Content-Range": value])), value)
        }
    }

    func testHTTPRangeRejectsTotalsNotContainingResponse() throws {
        for value in ["bytes 0-9/9", "bytes 0-9/0", "bytes 0-9/-1", "bytes 0-9/nan", "bytes 0-9/9223372036854775808"] {
            XCTAssertNil(StreamingLoader.responseRange(try metadataResponse(["Content-Range": value])), value)
        }
    }

    func testHTTPRangeRejectsContentLengthMismatch() throws {
        for length in ["9", "11", "0"] {
            XCTAssertNil(StreamingLoader.responseRange(try metadataResponse([
                "Content-Range": "bytes 100-109/200", "Content-Length": length])), length)
        }
        let valid = StreamingLoader.responseRange(try metadataResponse([
            "Content-Range": "bytes 100-109/200", "Content-Length": "10"]))
        XCTAssertEqual(valid?.start, 100)
        XCTAssertEqual(valid?.end, 109)
    }

    func testHTTPRangeAcceptsSingleByteAndLastRepresentableBounds() throws {
        let first = StreamingLoader.responseRange(try metadataResponse([
            "Content-Range": "bytes 0-0/1", "Content-Length": "1"]))
        XCTAssertEqual(first?.start, 0)
        XCTAssertEqual(first?.end, 0)
        XCTAssertEqual(first?.total, 1)
        let last = StreamingLoader.responseRange(try metadataResponse([
            "Content-Range": "bytes 9223372036854775806-9223372036854775806/9223372036854775807", "Content-Length": "1"]))
        XCTAssertEqual(last?.start, Int64.max - 1)
        XCTAssertEqual(last?.end, Int64.max - 1)
        XCTAssertEqual(last?.total, Int64.max)
    }

    func testHTTPEncodingAcceptsAbsentOrOnlyIdentity() throws {
        XCTAssertFalse(StreamingLoader.hasContentEncoding(try metadataResponse()))
        for value in ["", "identity", "IDENTITY", " identity ", "identity, Identity", ", ,"] {
            XCTAssertFalse(StreamingLoader.hasContentEncoding(try metadataResponse(["Content-Encoding": value])), value)
        }
    }

    func testHTTPEncodingRejectsAnyNonIdentityCoding() throws {
        for value in ["gzip", "GZip", "br", "deflate", "identity, gzip", "gzip, identity", "identity, br, identity"] {
            XCTAssertTrue(StreamingLoader.hasContentEncoding(try metadataResponse(["Content-Encoding": value])), value)
        }
    }

    /// A user-initiated proxy read waits on CacheWorker's condition for these callbacks.
    /// Prefetch starts transfers at utility QoS; the waker must not inherit it.
    func testStreamingLoaderCallbacksRunAtUserInitiatedWhenStartedFromUtility() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loader-qos-\(UUID().uuidString)")
        try Data(count: 1024).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let loader = StreamingLoader(url: file)
        defer { loader.invalidate() }
        let delivered = expectation(description: "data")
        delivered.assertForOverFulfill = false
        var callbackQoS = QOS_CLASS_UNSPECIFIED
        loader.onData = { _, _ in
            callbackQoS = qos_class_self()
            delivered.fulfill()
        }
        DispatchQueue(label: "unit.loader.utility", qos: .utility).async { loader.start(from: 0) }
        wait(for: [delivered], timeout: 5)
        XCTAssertGreaterThanOrEqual(callbackQoS.rawValue, QOS_CLASS_USER_INITIATED.rawValue,
                                    "Waker QoS \(callbackQoS.rawValue) is below the proxy's user-initiated wait")
    }

}

/// No socket/session is created. Any attempted transfer is observable by the test.
private final class NoRequestCacheTransport: HTTPStreamingLoading {
    var onData: ((Data, Int64) -> Void)?
    var onFileSize: ((Int64) -> Void)?
    var onComplete: ((Error?) -> Void)?
    var onRangeSupport: ((Bool) -> Void)?
    var onResponse: ((URL?) -> Void)?
    var onActivity: (() -> Void)?
    private let lock = NSLock()
    private var recorded: [String] = []
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func start(from offset: Int64, to end: Int64?) {
        lock.lock(); recorded.append("range \(offset)-\(end.map(String.init) ?? "")"); lock.unlock()
    }
    func getFileSize(completion: @escaping (Int64?) -> Void) {
        lock.lock(); recorded.append("size"); lock.unlock()
        completion(nil)
    }
    func cancel() {}
    func invalidate() {}
}
