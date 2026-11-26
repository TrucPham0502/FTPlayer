import XCTest
import UIKit
import CoreVideo
import libavcodec
import libavformat
@testable import FTPlayer

final class FTPlayerHLSTests: UnitTestCase {
    func testDiscontinuityPeriodsPreserveUnsignedSequenceAndInheritedKey() throws {
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:9223372036854775807\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:10,\nfirst.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:10,\nsecond.ts\n#EXT-X-ENDLIST\n"
        let manifest = try XCTUnwrap(FTIndependentHLS.parse(Data(text.utf8), source: URL(string: "https://example.invalid/index.m3u8")!))
        let cache = try FTPlaybackCacheSession()
        defer { cache.close() }
        let hls = try FTIndependentHLS(manifest: manifest, session: cache, cache: false, timeout: 3)
        defer { hls.close() }
        let second = try String(contentsOf: cache.directory.appendingPathComponent("period-1.m3u8"), encoding: .utf8)
        XCTAssertTrue(second.contains("#EXT-X-MEDIA-SEQUENCE:9223372036854775808"))
        XCTAssertTrue(second.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"https://example.invalid/key\""))
        let overflowing = text.replacingOccurrences(of: "9223372036854775807", with: "18446744073709551615")
        let native = try XCTUnwrap(FTIndependentHLS.parse(Data(overflowing.utf8), source: manifest.source))
        XCTAssertNil(native.periods, "An overflowing sequence must not enter SDK period arithmetic")
    }

    func testHLSMasterChoosesFirstVariantAndDefaultAudioInItsGroup() throws {
        let root = URL(string: "https://example.invalid/redirected/master.m3u8")!
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=123456,CODECS=\"avc1.640020,mp4a.40.2\",AUDIO=\"main\"\nvideo/stream\n#EXT-X-STREAM-INF:BANDWIDTH=999999\nunused/stream\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"other\",NAME=\"Other\",DEFAULT=YES,URI=\"wrong.m3u8\"\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"main\",NAME=\"Alternate\",DEFAULT=NO,URI=\"alternate.m3u8\"\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"main\",NAME=\"Main, stereo\",DEFAULT=YES,URI=\"audio/stream\"\n"
        let selected = try XCTUnwrap(FTHLSMasterCache.parse(HTTPDataResponse(data: Data(text.utf8), url: root)))
        XCTAssertEqual(selected.video.absoluteString, "https://example.invalid/redirected/video/stream")
        XCTAssertEqual(selected.audio?.absoluteString, "https://example.invalid/redirected/audio/stream")
        XCTAssertEqual(selected.streamAttributes["CODECS"], "avc1.640020,mp4a.40.2")
        XCTAssertEqual(selected.audioAttributes?["NAME"], "Main, stereo")
    }

    func testHLSUnsupportedControlTagsDoNotBypassFallbackForCompleteMP4() {
        let source = URL(string: "https://example.invalid/index.m3u8")!
        for tag in ["#EXT-X-GAP", "#EXT-X-DEFINE:NAME=\"part\",VALUE=\"main\"", "#EXT-X-I-FRAMES-ONLY"] {
            let playlist = "#EXTM3U\n\(tag)\n#EXTINF:30,\nmain.mp4\n#EXT-X-ENDLIST\n"
            XCTAssertNil(FTIndependentHLS.parse(Data(playlist.utf8), source: source), tag)
        }
    }

    func testFragmentedHLSParsesInitAndContinuousSegments() throws {
        let source = URL(string: "https://example.invalid/video/index.m3u8")!
        let text = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4?token=a,b\"\n#EXTINF:5.46379,\nfirst.m4s\n#EXTINF:5.21354,\nsecond.m4s\n#EXT-X-ENDLIST\n"
        let manifest = try XCTUnwrap(FTIndependentHLS.parse(Data(text.utf8), source: source))
        XCTAssertEqual(manifest.initialization?.absoluteString, "https://example.invalid/video/init.mp4?token=a,b")
        XCTAssertEqual(manifest.segments.count, 2)
        XCTAssertEqual(manifest.segments[1].url.absoluteString, "https://example.invalid/video/second.m4s")
        XCTAssertEqual(manifest.segments.reduce(0) { $0 + $1.duration }, 10.67733, accuracy: 0.000001)
    }

    func testFragmentedHLSLeavesUnsupportedMapTimelinesNative() {
        let source = URL(string: "https://example.invalid/index.m3u8")!
        let map = "#EXT-X-MAP:URI=\"init.mp4\"\n", body = "#EXTINF:2,\nfirst.m4s\n"
        for content in [map.replacingOccurrences(of: "\"\n", with: "\",BYTERANGE=\"100\"\n") + body,
                        map + "#EXT-X-BYTERANGE:100\n" + body,
                        map + "#EXT-X-KEY:METHOD=AES-128,URI=key\n" + body,
                        body + map, map + "#EXTINF:nan,\nfirst.m4s\n"] {
            XCTAssertNil(FTIndependentHLS.parse(Data(("#EXTM3U\n" + content + "#EXT-X-ENDLIST\n").utf8), source: source))
        }
        XCTAssertNil(FTIndependentHLS.parse(Data(("#EXTM3U\n" + map + body).utf8), source: source))
        for content in [map + body + map + body, map + body + "#EXT-X-DISCONTINUITY\n" + body] {
            XCTAssertNotNil(FTIndependentHLS.parse(Data(("#EXTM3U\n"+content+"#EXT-X-ENDLIST\n").utf8), source: source))
        }
    }

    func testIndependentHLSParsesSingleCompleteMP4() throws {
        let source = URL(string: "https://example.invalid/recordings/index.m3u8")!
        let text = "#EXTM3U\n#EXTINF:27\nclip.mp4\n#EXT-X-ENDLIST\n"
        let manifest = try XCTUnwrap(FTIndependentHLS.parse(Data(text.utf8), source: source))
        XCTAssertEqual(manifest.segments.count, 1)
        XCTAssertEqual(manifest.segments.first?.duration, 27)
        XCTAssertEqual(manifest.segments.first?.url, URL(string: "https://example.invalid/recordings/clip.mp4"))
    }

    func testIndependentHLSRejectsMisplacedDiscontinuities() {
        let source = URL(string: "https://example.invalid/index.m3u8")!
        // A count of N-1 tags is insufficient: each MP4 boundary needs its own tag.
        for body in [
            "#EXT-X-DISCONTINUITY\n#EXTINF:2,\nfirst.mp4\n#EXTINF:3,\nsecond.mp4\n",
            "#EXTINF:2,\nfirst.mp4\n#EXTINF:3,\nsecond.mp4\n#EXT-X-DISCONTINUITY\n",
            "#EXTINF:2,\nfirst.mp4\n#EXT-X-DISCONTINUITY\n#EXT-X-DISCONTINUITY\n#EXTINF:3,\nsecond.mp4\n#EXTINF:4,\nthird.mp4\n"
        ] {
            let lines = ("#EXTM3U\n" + body + "#EXT-X-ENDLIST\n").components(separatedBy: .newlines)
            XCTAssertNil(FTIndependentHLS.parseIndependent(lines, source: source), body)
        }
    }

    func testIndependentHLSUsesInjectedPlaylistTransportAndSessionCache() throws {
        let session = try FTPlaybackCacheSession()
        defer { session.close() }
        let source = URL(string: "https://example.invalid/index.m3u8")!
        let loader = PlaylistTransportStub()
        let first = try FTIndependentHLS.prepare(source: source, session: session, timeout: 1,
            interrupted: { false }, preparation: nil, loader: loader)
        XCTAssertEqual(first?.segments.count, 2)
        XCTAssertEqual(loader.requests, [source])
        let cached = try FTIndependentHLS.prepare(source: source, session: session, timeout: 1,
            interrupted: { false }, preparation: nil, loader: loader)
        XCTAssertEqual(cached?.segments.count, 2)
        XCTAssertEqual(loader.requests.count, 1, "Cached manifest should not call transport again")
    }

    func testIndependentHLSParsesCompleteMP4Discontinuities() throws {
        let source = URL(string: "https://example.invalid/recordings/index.m3u8")!
        let text = "#EXTM3U\n#EXTINF:32,\nfirst.mp4\n#EXT-X-DISCONTINUITY\n#EXTINF:31,\nsecond.mp4\n#EXT-X-ENDLIST\n"
        let manifest = try XCTUnwrap(FTIndependentHLS.parse(Data(text.utf8), source: source))
        XCTAssertEqual(manifest.segments.count, 2)
        XCTAssertEqual(manifest.segments.reduce(0) { $0 + $1.duration }, 63)
        XCTAssertEqual(manifest.segments[1].url.absoluteString, "https://example.invalid/recordings/second.mp4")
    }

    func testIndependentHLSRejectsMissingAndInvalidDurationsWithoutCrash() {
        let source = URL(string: "https://example.invalid/index.m3u8")!
        for value in ["", "nan", "inf", "-1", "0", "86400"] {
            let text = "#EXTM3U\n#EXTINF:\(value)\nfirst.mp4\n#EXT-X-DISCONTINUITY\n#EXTINF:31,\nsecond.mp4\n#EXT-X-ENDLIST\n"
            XCTAssertNil(FTIndependentHLS.parse(Data(text.utf8), source: source))
        }
    }

    func testIndependentHLSLeavesOtherPlaylistTypesNative() {
        let source = URL(string: "https://example.invalid/index.m3u8")!
        let body = "#EXTINF:32,\nfirst.mp4\n#EXT-X-DISCONTINUITY\n#EXTINF:31,\nsecond.mp4\n"
        for prefix in ["#EXT-X-MAP:URI=init.mp4\n", "#EXT-X-KEY:METHOD=AES-128,URI=key\n", "#EXT-X-STREAM-INF:BANDWIDTH=1000\n", "#EXT-X-MEDIA:TYPE=AUDIO\n"] {
            XCTAssertNil(FTIndependentHLS.parse(Data(("#EXTM3U\n" + prefix + body + "#EXT-X-ENDLIST\n").utf8), source: source))
        }
        XCTAssertNil(FTIndependentHLS.parse(Data(("#EXTM3U\n" + body).utf8), source: source))
        XCTAssertNotNil(FTIndependentHLS.parse(Data(("#EXTM3U\n" + body.replacingOccurrences(of: ".mp4", with: ".ts") + "#EXT-X-ENDLIST\n").utf8), source: source))
        XCTAssertNotNil(FTIndependentHLS.parse(Data(("#EXTM3U\n#EXT-X-BYTERANGE:1024@0\n"+body+"#EXT-X-ENDLIST\n").utf8), source: source))
    }

    func testNativeHTTPSAndTLSProtocolsAreIncluded() {
        // MP4 byte cache uses URLSession; HLS and its segments need FFmpeg's own TLS.
        for scheme in ["http", "https", "tcp", "tls"] {
            let protocolName = avio_find_protocol_name("\(scheme)://example.invalid/video")
            XCTAssertNotNil(protocolName, "Missing native FFmpeg protocol: \(scheme)")
            if let protocolName { XCTAssertEqual(String(cString: protocolName), scheme) }
        }
    }


    func testHLSByteRangeParserResolvesImplicitOffsetsAndRejectsOverflow() throws {
        let source = URL(string: "https://example.invalid/video/index.m3u8")!
        let map = "#EXTM3U\n#EXT-X-MAP:BYTERANGE=\"100@0\",URI=\"main.mp4\"\n"
        let body = "#EXTINF:2,\n#EXT-X-BYTERANGE:200@100\nmain.mp4\n#EXTINF:3,\n#EXT-X-BYTERANGE:300\nmain.mp4\n#EXT-X-ENDLIST\n"
        let manifest = try XCTUnwrap(FTIndependentHLS.parse(Data((map+body).utf8), source: source))
        XCTAssertEqual(manifest.initializationRange, CachedRange(start: 0, end: 99))
        XCTAssertEqual(manifest.segments.map { $0.byteRange }, [CachedRange(start: 100, end: 299), CachedRange(start: 300, end: 599)])
        for invalid in ["0@0", "-1@0", "2@9223372036854775807", "100@-1", "100@", "100"] {
            XCTAssertNil(FTIndependentHLS.parse(Data((map + "#EXTINF:2,\n#EXT-X-BYTERANGE:\(invalid)\nmain.mp4\n#EXT-X-ENDLIST\n").utf8), source: source))
        }
        XCTAssertNil(FTIndependentHLS.parse(Data((map+body.replacingOccurrences(of: "300\nmain.mp4", with: "300\nother.mp4")).utf8), source: source))
    }

    func testHLSResourceParserPreservesPerSegmentKeyInitAndRange() throws {
        let source = URL(string: "https://example.invalid/video/playlist")!
        let text = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:73\n#EXT-X-ENDLIST\n#EXT-X-DISCONTINUITY\n#EXT-X-KEY:METHOD=AES-128,URI=\"key-a\",IV=0x00000000000000000000000000000049\n#EXT-X-MAP:URI=\"init-a\"\n#EXT-X-BYTERANGE:100@0\n#EXTINF:2,\nmedia\n#EXTINF:3,\n#EXT-X-KEY:METHOD=AES-128,URI=\"key-b\"\n#EXT-X-MAP:URI=\"init-b\"\n#EXT-X-BYTERANGE:200\nmedia\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:4,\nlast\n"
        let manifest = try XCTUnwrap(FTIndependentHLS.parse(Data(text.utf8), source: source))
        XCTAssertTrue(manifest.usesNativeHLS)
        XCTAssertEqual(manifest.auxiliary?.count, 4)
        XCTAssertEqual(manifest.segments.map { $0.dependencies }, [[1,0], [3,2], [3]])
        XCTAssertEqual(manifest.segments[1].byteRange, CachedRange(start: 100, end: 299))
    }

}

private final class PlaylistTransportStub: HTTPDataLoading {
    var requests: [URL] = []
    func load(_ url: URL, timeout: TimeInterval, interrupted: () -> Bool) throws -> HTTPDataResponse {
        requests.append(url)
        return HTTPDataResponse(data: Data("#EXTM3U\n#EXTINF:2,\nfirst.mp4\n#EXT-X-DISCONTINUITY\n#EXTINF:3,\nsecond.mp4\n#EXT-X-ENDLIST\n".utf8), url: url)
    }
}
