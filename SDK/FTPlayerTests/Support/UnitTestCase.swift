import XCTest
import UIKit
import CoreVideo
import libavcodec
@testable import FTPlayer


// Test-only sinks adapt their existing frame inspection to public video output.
protocol TestVideoSink: FTPlayerVideoOutput {
    func didRenderFrame(_ pb: CVPixelBuffer, time: Int64)
}
extension TestVideoSink {
    func player(_ player: FTPlayer, didOutput pixelBuffer: CVPixelBuffer,
                presentationTime: TimeInterval) {
        didRenderFrame(pixelBuffer, time: Int64(presentationTime * 1_000_000))
    }
}
func attachVideoSink(_ sink: any TestVideoSink, to player: FTPlayer) {
    player.videoOutput = sink
}

enum PlaybackTestError: Error { case assertion(String) }
final class PixelSink: TestVideoSink {
    var inspectFrame: ((CVPixelBuffer, Double) -> Void)?
    private var recentPresentations: [(number: Int, time: Double, wall: Double)] = []
    func presentationTimes(after frameNumber: Int) -> [Double] {
        recentPresentations.filter { $0.number > frameNumber }.map(\.time)
    }
    func presentationEvents(after frameNumber: Int) -> [(time: Double, wall: Double)] {
        recentPresentations.filter { $0.number > frameNumber }.map { ($0.time, $0.wall) }
    }
    var frames = 0
    var lastPresentationTime: Double = 0
    private(set) var firstPresentationTime: Double?
    var dimensions = CGSize.zero
    var pixelFormat: OSType = 0
    func didRenderFrame(_ pb: CVPixelBuffer, time: Int64) {
        frames += 1
        lastPresentationTime = Double(time) / 1_000_000
        recentPresentations.append((frames, lastPresentationTime, ProcessInfo.processInfo.systemUptime))
        if recentPresentations.count > 4096 { recentPresentations.removeFirst(2048) }
        if firstPresentationTime == nil { firstPresentationTime = lastPresentationTime }
        dimensions = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        pixelFormat = CVPixelBufferGetPixelFormatType(pb)
        inspectFrame?(pb, lastPresentationTime)
    }
    func didChangeVideoSize(_ size: CGSize) {}
    func didUpdateCurrentTime(_ sec: Double) {}
}

/// Helpers for in-memory logic tests. No player session, source file or server.
class UnitTestCase: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCTAssertTrue(Thread.isMainThread)
    }
    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
    @discardableResult func until(_ timeout: TimeInterval = 12, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; pump(0.02) }
        return condition()
    }
    func require(_ value: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(value, message, file: file, line: line)
        if !value { throw PlaybackTestError.assertion(message) }
    }
}

final class SeekLoadingObserver: FTPlayerPlaybackDelegate {
    var loading = false
    var events: [String] = []
    func playerBufferingStart(_ player: FTPlayer) { loading = true; events.append("start") }
    func playerBufferingEnd(_ player: FTPlayer) { loading = false; events.append("end") }
}

final class ReviewObserver: FTPlayerDeletegate {
    var progress: [Double] = [], playable: [Double] = []
    var states: [FTPlayerState] = []
    var ready = 0, finished = 0, errors = 0
    func player(_ player: FTPlayer, didChangeState state: FTPlayerState) { states.append(state) }
    func player(_ player: FTPlayer, didUpdateProgress value: TimeInterval) { progress.append(value) }
    func player(_ player: FTPlayer, didUpdatePlayable value: TimeInterval) { playable.append(value) }
    func player(_ player: FTPlayer, didUpdateBufferProgress value: Double) {}
    func player(_ player: FTPlayer, didUpdateDownloadProgress value: Double) {}
    func playerReadyToPlay(_ player: FTPlayer, duration: TimeInterval) { ready += 1 }
    func playerDidFinish(_ player: FTPlayer) { finished += 1 }
    func player(_ player: FTPlayer, didFail error: Error) { errors += 1 }
    func playerBufferingStart(_ player: FTPlayer) {}
    func playerBufferingEnd(_ player: FTPlayer) {}
}

final class TimelineCoverageFrameSource: FTVideoDecoderDataSource {
    func shouldHandle(_ videoDecoder: FTVideoDecoderInfo, decodeFrame packet: AVPacket) -> Bool { true }
    func videoDecoder(_ videoDecoder: FTVideoDecoderInfo, decodeFrame packet: AVPacket) -> FTVideoFrame? {
        let frame = FTCVYUVVideoFrame(pixelBuffer: nil)
        frame.position = Double(packet.pts) * videoDecoder.timebase
        frame.duration = 1 / videoDecoder.fps
        return frame
    }
}

final class BoundaryProgressObserver: FTPlayerProgressDelegate {
    var values: [Double] = []
    var buffers: [Double] = []
    var onMain = true
    var onProgress: (() -> Void)?
    func player(_ player: FTPlayer, didUpdateProgress progress: TimeInterval) {
        onMain = onMain && Thread.isMainThread
        values.append(progress)
        onProgress?()
    }
    func player(_ player: FTPlayer, didUpdateBufferProgress progress: Double) { buffers.append(progress) }
}

final class BoundaryEngine: PlaybackEngine {
    weak var delegate: FTDecoderDelegate?
    var useCache = false
    var loadControlConfiguration = FTPlayerLoadControlConfiguration()
    var cacheSession: (any PlaybackCacheSession)?
    var cacheSessionRevision: Int?
    var videoDecodingPolicy: FTVideoDecodingPolicy = .automatic
    var playbackRate: Float = 1
    var minBufferedDuration: TimeInterval = 2
    let duration: TimeInterval = 120
    let presentationSize = CGSize(width: 640, height: 360)
    let bitrate: TimeInterval = 100_000
    let mediaInfo: FTPlayerMediaInfo? = nil
    let prepareToDecode = true
    var buffering = false
    var seekHandler: ((TimeInterval, ((Bool) -> Void)?) -> Void)?
    var playbackFinished = false
    let videoEnable = true
    let audioEnable = false
    let cachedTimeRanges: [FTPlayerCachedTimeRange] = []
    let cachedFraction: Double = 0
    let decodingStatistics: FTVideoDecodingStatistics? = nil
    let diagnosticSnapshot = "protocol test engine"
    private(set) var closeCount = 0
    func open() {}
    func resume() {}
    func pause() {}
    func closeFile() { closeCount += 1 }
    func closeFileWithCompletion(_ completion: @escaping () -> Void) { closeFile(); completion() }
    func seek(to time: TimeInterval, completeHandler: ((Bool) -> Void)?) {
        playbackFinished = false
        if let seekHandler { seekHandler(time, completeHandler) }
        else { completeHandler?(true) }
    }
    func fetchAudioFrame() -> FTAudioFrame? { nil }
}

final class BoundaryAudioOutput: PlaybackAudioOutput {
    var volume: Float = 1
    var playbackRate: Float = 1
    private(set) var playing = false
    let numberOfChannels: UInt32 = 2
    let samplingRate: Float64 = 48_000
    func registerAudioSession() -> Bool { true }
    func setEventHandlers(interruption: @escaping (FTAudioManagerInterruptionType, FTAudioManagerInterruptionOption) -> Void,
                          routeChange: @escaping (FTAudioManagerRouteChangeReason) -> Void) {}
    func play() { playing = true }
    func pause() { playing = false }
    func destroy() { playing = false }
}

struct BoundaryFactory: PlaybackComponentFactory {
    let engine: BoundaryEngine
    let audio: BoundaryAudioOutput
    func makeDecoder(contentURL: URL, videoFormat: FTVideoFormat,
                     videoOutput: FTDecoderVideoOutput, audioOutput: FTDecoderAudioOutput) -> any PlaybackEngine { engine }
    func makeAudioOutput(source: any FTAudioFrameSource) -> any PlaybackAudioOutput { audio }
    func makeCacheSession() throws -> any PlaybackCacheSession { try FTPlaybackCacheSession() }
}

final class PlayerObserver: FTPlayerDeletegate {
    var ready: (() -> Void)?
    var failed: ((Error) -> Void)?
    func player(_ player: FTPlayer, didChangeState state: FTPlayerState) {}
    func player(_ player: FTPlayer, didUpdateProgress progress: TimeInterval) {}
    func player(_ player: FTPlayer, didUpdatePlayable playable: TimeInterval) {}
    func player(_ player: FTPlayer, didUpdateBufferProgress progress: Double) {}
    func player(_ player: FTPlayer, didUpdateDownloadProgress progress: Double) {}
    func playerReadyToPlay(_ player: FTPlayer, duration: TimeInterval) { ready?() }
    func playerDidFinish(_ player: FTPlayer) {}
    func player(_ player: FTPlayer, didFail error: Error) { failed?(error) }
    func playerBufferingStart(_ player: FTPlayer) {}
    func playerBufferingEnd(_ player: FTPlayer) {}
}
