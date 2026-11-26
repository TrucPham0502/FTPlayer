import XCTest
import UIKit
import CoreVideo
import libavcodec
@testable import FTPlayer

final class FTPlayerControlTests: UnitTestCase {
    func testBufferEndpointDoesNotRewindBetweenThrottledProgressUpdates() throws {
        let (player, engine, _, _) = try seekBufferingPlayer()
        defer { player.stop() }
        let observer = BoundaryProgressObserver()
        player.progressDelegate = observer
        player.rate = 16
        player.decoder(engine, didChangeValueOfProgress: 12)
        player.decoder(engine, didChangeValueOfBufferedDuration: 50)
        pump(0.05)
        XCTAssertEqual(player.playableTime, 62)
        // PCM is consumed before the next throttled progress notification.
        player.decoder(engine, didChangeValueOfBufferedDuration: 40)
        pump(0.05)
        XCTAssertEqual(player.playableTime, 62, "Consuming queued frames rewound the buffered endpoint")
        XCTAssertTrue(zip(observer.buffers, observer.buffers.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testBufferEOFPublishesFullBarAndDrainKeepsItFull() throws {
        let (player, engine, _, _) = try seekBufferingPlayer()
        defer { player.stop() }
        let observer = BoundaryProgressObserver()
        player.progressDelegate = observer
        player.decoder(engine, didChangeValueOfProgress: 118)
        player.decoder(engine, didChangeValueOfBufferedDuration: 1)
        pump(0.05)
        player.decoderDidEndOfFile(engine)
        pump(0.05)
        XCTAssertEqual(observer.buffers.last, 1, "EOF did not update the bar's actual delegate callback")
        player.decoder(engine, didChangeValueOfBufferedDuration: 0)
        pump(0.05)
        XCTAssertEqual(player.bufferProgress, 1)
        XCTAssertEqual(observer.buffers.last, 1, "Queue drain left a gap at the right edge")
    }

    func testBufferFinishPublishesFullBarWithoutAnotherQueueChange() throws {
        let (player, engine, _, _) = try seekBufferingPlayer()
        defer { player.stop() }
        let observer = BoundaryProgressObserver()
        player.progressDelegate = observer
        player.decoder(engine, didChangeValueOfProgress: 119)
        player.decoder(engine, didChangeValueOfBufferedDuration: 0)
        pump(0.05)
        engine.playbackFinished = true
        player.decoderDidPlaybackFinished(engine)
        pump(0.05)
        XCTAssertEqual(player.bufferProgress, 1)
        XCTAssertEqual(observer.buffers.last, 1)
    }

    func testBufferSeekResetsEndpointAndRejectsPreviousQueuedEOFAndBuffer() throws {
        let (player, engine, _, _) = try seekBufferingPlayer()
        defer { player.stop() }
        let observer = BoundaryProgressObserver()
        player.progressDelegate = observer
        player.decoderDidEndOfFile(engine)
        pump(0.05)
        XCTAssertEqual(player.bufferProgress, 1)
        observer.buffers.removeAll()
        // Both engine deliveries and already queued observer deliveries must
        // belong to the seek that produced them.
        player.playableTime = 110
        player.decoderDidEndOfFile(engine)
        player.decoder(engine, didChangeValueOfBufferedDuration: 100)
        player.seek(to: 10)
        player.decoder(engine, didChangeValueOfProgress: 10)
        player.decoder(engine, didChangeValueOfBufferedDuration: 2)
        pump(0.1)
        XCTAssertEqual(player.playableTime, 12)
        XCTAssertEqual(observer.buffers.last ?? -1, 0.1, accuracy: 0.00001)
        XCTAssertTrue(observer.buffers.allSatisfy { $0 <= 0.1 }, "Previous seek's buffer update crossed the seek boundary")
    }


    func testSeekBufferingSupersededCompletionIsCancelledExactlyOnce() throws {
        let (player, engine, _, _) = try seekBufferingPlayer()
        defer { player.stop() }
        var first: [Bool] = [], second: [Bool] = []
        player.seek(to: 10) { first.append($0) }
        pump(0.05)
        XCTAssertTrue(first.isEmpty)
        player.seek(to: 20) { second.append($0) }
        pump(0.05)
        XCTAssertEqual(first, [false]); XCTAssertTrue(second.isEmpty)
        engine.buffering = false
        engine.delegate?.decoder(engine, didChangeValueOfBuffering: false)
        try require(until { !second.isEmpty }, "Latest seek completion was lost")
        XCTAssertEqual(first, [false]); XCTAssertEqual(second, [true])
    }

    func testSeekBufferingStopCancelsAcknowledgedSeek() throws {
        let (player, engine, _, _) = try seekBufferingPlayer()
        var results: [Bool] = []
        player.seek(to: 10) { results.append($0) }
        pump(0.05)
        XCTAssertTrue(results.isEmpty)
        player.stop()
        engine.buffering = false
        player.decoder(engine, didChangeValueOfBuffering: false)
        pump(0.05)
        XCTAssertEqual(results, [false], "Stop must cancel a demux-acknowledged seek exactly once")
    }

    func testSeekBufferingRejectsPreviousEndAndSuccessAlreadyQueued() throws {
        let (player, engine, _, observer) = try seekBufferingPlayer()
        defer { player.stop() }
        var first: [Bool] = [], second: [Bool] = []
        player.seek(to: 10) { first.append($0) }
        pump(0.05)
        observer.events.removeAll()
        engine.buffering = false
        engine.delegate?.decoder(engine, didChangeValueOfBuffering: false)
        // The first seek becomes ready in the preceding delivery, but its end
        // and completion observers are queued behind this newer seek.
        DispatchQueue.main.async { player.seek(to: 20) { second.append($0) } }
        pump(0.1)
        XCTAssertEqual(first, [false], "An old success was delivered after a newer seek started")
        XCTAssertTrue(second.isEmpty)
        XCTAssertFalse(observer.events.contains("end"), "Previous buffering end hid the newest seek's loading")
        XCTAssertTrue(observer.loading)
        engine.buffering = false
        engine.delegate?.decoder(engine, didChangeValueOfBuffering: false)
        try require(until { !second.isEmpty }, "Newest seek never completed")
        XCTAssertEqual(second, [true])
        XCTAssertFalse(observer.loading)
    }

    func testSeekBufferingFailureCancelsAcknowledgedSeek() throws {
        let (player, engine, _, _) = try seekBufferingPlayer()
        defer { player.stop() }
        var results: [Bool] = []
        player.seek(to: 10) { results.append($0) }
        pump(0.05)
        player.decoder(engine, didError: NSError(domain: "seek-regression", code: -1))
        pump(0.05)
        engine.buffering = false
        player.decoder(engine, didChangeValueOfBuffering: false)
        pump(0.05)
        XCTAssertEqual(results, [false])
        XCTAssertEqual(player.state, .failed)
    }

    func testSeekBufferingPausedSeekWaitsWithoutResumingAudio() throws {
        let (player, engine, audio, _) = try seekBufferingPlayer()
        defer { player.stop() }
        player.pause() // Seek immediately, before the queued audio pause executes.
        var results: [Bool] = []
        player.seek(to: 10) { results.append($0) }
        pump(0.05)
        XCTAssertTrue(results.isEmpty)
        engine.buffering = false
        engine.delegate?.decoder(engine, didChangeValueOfBuffering: false)
        try require(until { !results.isEmpty }, "Paused seek completion was lost")
        XCTAssertEqual(results, [true])
        XCTAssertEqual(player.state, .suspend)
        XCTAssertFalse(audio.playing)
    }

    private func seekBufferingPlayer() throws -> (FTPlayer, BoundaryEngine, BoundaryAudioOutput, SeekLoadingObserver) {
        let engine = BoundaryEngine(), audio = BoundaryAudioOutput(), observer = SeekLoadingObserver()
        let player = FTPlayer(contentURL: URL(fileURLWithPath: "/unit-test-source-identity.mp4"), components: BoundaryFactory(engine: engine, audio: audio))
        player.playbackDelegate = observer
        player.replaceVideo()
        engine.delegate?.decoderDidPrepareToDecodeFrames(engine)
        engine.delegate?.decoder(engine, didChangeValueOfBuffering: false)
        pump(0.05)
        engine.seekHandler = { [weak engine] _, completion in
            guard let engine else { completion?(false); return }
            engine.buffering = true
            engine.delegate?.decoder(engine, didChangeValueOfBuffering: true)
            completion?(true) // Demux succeeds before any target media is ready.
        }
        return (player, engine, audio, observer)
    }

    func testLegacyDelegateAccessorPreservesWeakOwnership() {
        final class Observer: FTPlayerDeletegate {}
        let player = FTPlayer(contentURL: nil)
        weak var reference: Observer?
        do {
            let observer = Observer()
            reference = observer
            player.delegate = observer
            XCTAssertTrue(player.delegate === observer)
        }
        XCTAssertNil(reference, "Public delegate accessor retained the app's observer")
        XCTAssertNil(player.delegate)
    }

    func testLongSeekPrerollTimesOutOnlyWhenPresentationStopsAdvancing() {
        let watchdog = PlaybackBufferingWatchdog()
        watchdog.begin(at: 0)
        for tick in 0...100 {
            XCTAssertFalse(watchdog.hasTimedOut(at: Double(tick), timeout: 3, waitingForNetwork: false,
                prerollEpoch: 1, prerollPosition: Double(tick) / 10))
        }
        XCTAssertFalse(watchdog.hasTimedOut(at: 102, timeout: 3, waitingForNetwork: false, prerollEpoch: 1, prerollPosition: 10))
        XCTAssertTrue(watchdog.hasTimedOut(at: 103, timeout: 3, waitingForNetwork: false, prerollEpoch: 1, prerollPosition: 10))
        // Reordered/repeated timestamps cannot keep a stuck decode alive.
        XCTAssertTrue(watchdog.hasTimedOut(at: 104, timeout: 3, waitingForNetwork: false, prerollEpoch: 1, prerollPosition: 9))
        // A new backward seek establishes its own progress origin.
        XCTAssertFalse(watchdog.hasTimedOut(at: 105, timeout: 3, waitingForNetwork: false, prerollEpoch: 2, prerollPosition: 1))
        XCTAssertTrue(watchdog.hasTimedOut(at: 108, timeout: 3, waitingForNetwork: false, prerollEpoch: 2, prerollPosition: 1))
    }

    func testBufferingWatchdogPreservesOrdinaryTimeoutAndRecoverableNetworkWait() {
        let watchdog = PlaybackBufferingWatchdog()
        watchdog.begin(at: 0)
        XCTAssertTrue(watchdog.hasTimedOut(at: 3, timeout: 3, waitingForNetwork: false, prerollEpoch: nil, prerollPosition: nil))
        XCTAssertFalse(watchdog.hasTimedOut(at: 10, timeout: 3, waitingForNetwork: true, prerollEpoch: nil, prerollPosition: nil))
        XCTAssertFalse(watchdog.hasTimedOut(at: 12, timeout: 3, waitingForNetwork: false, prerollEpoch: nil, prerollPosition: nil))
        XCTAssertTrue(watchdog.hasTimedOut(at: 13, timeout: 3, waitingForNetwork: false, prerollEpoch: nil, prerollPosition: nil))
        XCTAssertFalse(watchdog.hasTimedOut(at: 100, timeout: 0, waitingForNetwork: false, prerollEpoch: nil, prerollPosition: nil))
    }

    func testAudioSeekTrimsIntersectingPCMAtSamplePrecision() {
        let frame = FTAudioFrame()
        frame.setSamplesLength(4800 * 2 * MemoryLayout<Float>.size)
        frame.position = 13.92; frame.duration = 0.1
        for index in 0..<9600 { frame.samples![index] = Float(index) }
        XCTAssertTrue(frame.trimStart(to: 14, samplingRate: 48000, channels: 2))
        XCTAssertEqual(frame.position, 14, accuracy: 1.0 / 48000)
        XCTAssertEqual(frame.duration, 0.02, accuracy: 1.0 / 48000)
        XCTAssertEqual(frame.outputOffset, 3840 * 2 * MemoryLayout<Float>.size)
        XCTAssertEqual(frame.samples![frame.outputOffset / MemoryLayout<Float>.size], 7680)
        frame.setSamplesLength(480 * 2 * MemoryLayout<Float>.size)
        frame.position = 13.98; frame.duration = 0.01
        XCTAssertFalse(frame.trimStart(to: 14, samplingRate: 48000, channels: 2), "Fully preroll PCM must be discarded")
    }

    func testSeekSuppressesQueuedOldPictureAndAcceptsNewPicture() throws {
        let engine = BoundaryEngine()
        let player = FTPlayer(contentURL: URL(string: "https://example.invalid/video.mp4")!,
            components: BoundaryFactory(engine: engine, audio: BoundaryAudioOutput()))
        defer { player.stop() }
        let sink = PixelSink(); attachVideoSink(sink, to: player); player.replaceVideo()
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let old = FTCVYUVVideoFrame(pixelBuffer: pixel); old.position = 60
        player.send(video: old, from: engine)
        player.seek(to: 5)
        pump(0.05)
        XCTAssertEqual(sink.frames, 0, "A picture queued before seek leaked into the new timeline")
        let fresh = FTCVYUVVideoFrame(pixelBuffer: pixel); fresh.position = 5
        player.send(video: fresh, from: engine)
        pump(0.05)
        XCTAssertEqual(sink.frames, 1)
        XCTAssertEqual(sink.lastPresentationTime, 5)
    }

    func testCurrentFinishAfterSeekStillDeliversOnce() throws {
        let engine = BoundaryEngine(), observer = ReviewObserver()
        let player = FTPlayer(contentURL: URL(string: "https://example.invalid/video.mp4")!,
            components: BoundaryFactory(engine: engine, audio: BoundaryAudioOutput()))
        defer { player.stop() }
        player.delegate = observer; player.replaceVideo(); player.seek(to: 50)
        engine.playbackFinished = true
        player.decoderDidPlaybackFinished(engine)
        pump(0.1)
        XCTAssertEqual(observer.finished, 1)
        XCTAssertEqual(player.state, .finished)
    }

    func testSeekSuppressesQueuedPreviousFinish() throws {
        let engine = BoundaryEngine(), audio = BoundaryAudioOutput(), observer = ReviewObserver()
        let player = FTPlayer(contentURL: URL(string: "https://example.invalid/video.mp4")!, components: BoundaryFactory(engine: engine, audio: audio))
        defer { player.stop() }
        player.delegate = observer; player.replaceVideo()
        engine.playbackFinished = true
        player.decoderDidPlaybackFinished(engine)
        player.seek(to: 50)
        pump(0.1)
        XCTAssertEqual(observer.finished, 0, "A terminal event queued before seek leaked into the new seek epoch")
        XCTAssertNotEqual(player.state, .finished)
    }

    func testSeekSuppressesPreviousFinishObserverAlreadyQueued() throws {
        let engine = BoundaryEngine(), audio = BoundaryAudioOutput(), observer = ReviewObserver()
        let player = FTPlayer(contentURL: URL(string: "https://example.invalid/video.mp4")!, components: BoundaryFactory(engine: engine, audio: audio))
        defer { player.stop() }
        player.delegate = observer; player.replaceVideo()
        engine.playbackFinished = true
        player.decoderDidPlaybackFinished(engine)
        DispatchQueue.main.async { player.seek(to: 50) }
        pump(0.1)
        XCTAssertEqual(observer.finished, 0, "The old didFinish observer was delivered after a newer seek")
    }

    func testHighRateDecodedBufferUsesTimelineCoverage() throws {
        var codec = try XCTUnwrap(avcodec_alloc_context3(nil)) as UnsafeMutablePointer<AVCodecContext>?
        defer { avcodec_free_context(&codec) }
        codec!.pointee.codec_id = AV_CODEC_ID_MPEG4
        let decoder = FTVideoDecoder(codecContext: codec!, timebase: 0.001, fps: 24, delegate: nil, policy: .ffmpeg)
        let source = TimelineCoverageFrameSource()
        decoder.source = source; decoder.playbackRate = 16; decoder.maxDecodeDuration = 100
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { decoder.decodeFrameThread(); stopped.signal() }
        defer { decoder.destroy(); XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success); withExtendedLifetime(source) {} }
        for pts in [Int64(0), 333, 667, 1000] { decoder.putPacket(try catchUpPacket(pts: pts, key: true)) }
        try require(until(2) { decoder.frameCount() == 4 }, "Synthetic decoder did not queue the sampled pictures")
        decoder.presentationTime = 0.25
        XCTAssertEqual(decoder.frameDuration(), 1 + 1.0 / 24 - 0.25, accuracy: 0.01,
                       "Intentional frame sampling must retain the covered media interval")
        decoder.presentationTime = 1.1
        XCTAssertEqual(decoder.frameDuration(), 0, accuracy: 0.001, "Pictures behind the clock are not forward buffer")
        decoder.playbackRate = 1
        XCTAssertEqual(decoder.frameDuration(), 4.0 / 24, accuracy: 0.001)
    }

    func testProtocolEngineDeliversBackgroundProgressOnMain() throws {
        let engine = BoundaryEngine(), audio = BoundaryAudioOutput()
        let player = FTPlayer(contentURL: URL(fileURLWithPath: "/unit-test-source-identity.mp4"),
                              components: BoundaryFactory(engine: engine, audio: audio))
        let observer = BoundaryProgressObserver(), legacy = ReviewObserver()
        player.delegate = legacy
        player.progressDelegate = observer
        player.play()
        defer { player.stop() }
        let delivered = expectation(description: "background progress delivered on main")
        delivered.expectedFulfillmentCount = 2
        observer.onProgress = { delivered.fulfill() }
        DispatchQueue.global().async {
            engine.delegate?.decoder(engine, didChangeValueOfProgress: 1)
            engine.delegate?.decoder(engine, didChangeValueOfProgress: 2)
        }
        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(observer.values, [1, 2])
        XCTAssertTrue(observer.onMain)
        XCTAssertTrue(legacy.progress.isEmpty, "Narrow observer must replace legacy progress, without duplicate delivery")
        XCTAssertTrue(player.engine === engine)
        XCTAssertEqual(audio.volume, 1)
    }

    func testQueuedProgressFromBeforeSeekCannotReplaceRequestedTime() throws {
        let engine = BoundaryEngine()
        let player = FTPlayer(contentURL: URL(fileURLWithPath: "/unit-test-source-identity.mp4"),
                              components: BoundaryFactory(engine: engine, audio: BoundaryAudioOutput()))
        let observer = BoundaryProgressObserver()
        player.progressDelegate = observer
        player.play()
        defer { player.stop() }
        player.progress = 10 // Observer notification is queued before seek.
        let queued = DispatchGroup()
        queued.enter()
        DispatchQueue.global().async {
            engine.delegate?.decoder(engine, didChangeValueOfProgress: 42)
            queued.leave()
        }
        XCTAssertEqual(queued.wait(timeout: .now() + 3), .success)
        player.seek(to: 3)
        // Real FTDecoder publishes the requested target synchronously on main.
        engine.delegate?.decoder(engine, didChangeValueOfProgress: 3)
        XCTAssertEqual(player.progress, 3)
        pump(0.1)
        XCTAssertEqual(player.progress, 3, "Queued pre-seek progress rewound the new playback epoch")
        XCTAssertEqual(observer.values, [3], "Old progress notifications crossed the seek boundary")
    }

    func testProtocolEngineQueuedCallbacksAreCancelledByStop() throws {
        let engine = BoundaryEngine()
        let player = FTPlayer(contentURL: URL(fileURLWithPath: "/unit-test-source-identity.mp4"),
                              components: BoundaryFactory(engine: engine, audio: BoundaryAudioOutput()))
        let observer = BoundaryProgressObserver()
        player.progressDelegate = observer
        player.play()
        let queued = DispatchGroup()
        queued.enter()
        DispatchQueue.global().async {
            engine.delegate?.decoder(engine, didChangeValueOfProgress: 42)
            engine.delegate?.decoderDidPrepareToDecodeFrames(engine)
            queued.leave()
        }
        XCTAssertEqual(queued.wait(timeout: .now() + 3), .success)
        player.stop()
        pump(0.1)
        XCTAssertEqual(player.state, .none)
        XCTAssertEqual(player.preparationState, .stopped)
        XCTAssertEqual(player.progress, 0)
        XCTAssertFalse(observer.values.contains(42))
        XCTAssertEqual(engine.closeCount, 1)
    }


    func testPreparationWorkflowRejectsLateAndTerminalEvents() {
        let workflow = PlaybackPreparationWorkflow()
        workflow.begin()
        XCTAssertTrue(workflow.advance(to: .readingStreamInfo))
        XCTAssertFalse(workflow.advance(to: .sourceOpened))
        XCTAssertTrue(workflow.advance(to: .end))
        XCTAssertFalse(workflow.advance(to: .failed))
        workflow.begin()
        XCTAssertTrue(workflow.advance(to: .failed))
        XCTAssertFalse(workflow.advance(to: .end))
        workflow.begin()
        workflow.stop()
        XCTAssertFalse(workflow.advance(to: .sourceOpened))
        XCTAssertEqual(workflow.state, .stopped)
    }

    func testSeekControllerSupersedesAndCancelsExactlyOnce() throws {
        let controller = PlaybackSeekController()
        var first: [Bool] = []
        var second: [Bool] = []
        XCTAssertEqual(controller.enqueue(time: -10, minimum: 0, duration: 30) { first.append($0) }, 0)
        XCTAssertTrue(controller.isPending)
        XCTAssertEqual(controller.enqueue(time: 100, minimum: 0, duration: 30) { second.append($0) }, 29.95, accuracy: 0.001)
        XCTAssertEqual(first, [false])
        controller.cancel()
        controller.cancel()
        XCTAssertEqual(second, [false])
        XCTAssertFalse(controller.isPending)
        XCTAssertNil(controller.take())
    }

    func testSeekControllerCompletionCanEnqueueWithoutDeadlock() throws {
        let controller = PlaybackSeekController()
        controller.enqueue(time: 1, minimum: 0, duration: 30) { _ in
            controller.enqueue(time: 3, minimum: 0, duration: 30, completion: nil)
        }
        controller.cancel()
        XCTAssertEqual(try XCTUnwrap(controller.take()).time, 3)
        XCTAssertFalse(controller.isPending)
    }

    func testClockContractPreservesPausedPositionAndSeek() {
        let clocks: [any FTPlaybackClock] = [FTAudioMasterClock(), FTSystemMasterClock()]
        for clock in clocks {
            clock.setPaused(true)
            clock.seek(to: 10)
            let position = clock.currentTime
            Thread.sleep(forTimeInterval: 0.02)
            XCTAssertEqual(clock.currentTime, position, accuracy: 0.001)
            clock.seek(to: 15)
            XCTAssertEqual(clock.currentTime - position, 5, accuracy: 0.001)
            clock.setRate(2)
            let changedRatePosition = clock.currentTime
            Thread.sleep(forTimeInterval: 0.02)
            XCTAssertEqual(clock.currentTime, changedRatePosition, accuracy: 0.001)
        }
    }

    func testHighRateCatchUpQueuePreservesKeyframeAndAccounting() throws {
        let queue = FTPacketQueue(timebase: 0.1); defer { queue.destroy() }
        queue.putPacket(try catchUpPacket(pts: 10), duration: 0)
        queue.putPacket(try catchUpPacket(pts: 20), duration: 0)
        let key = try catchUpPacket(pts: 40, key: true)
        queue.putPacket(key, duration: 0)
        queue.putPacket(try catchUpPacket(pts: 50), duration: 0)
        let jump = try XCTUnwrap(queue.discardBeforeKeyframe(notBefore: 3, noLaterThan: 5, timestampOffset: 0))
        XCTAssertEqual(jump.packets, 2); XCTAssertEqual(jump.position, 4)
        XCTAssertEqual(queue.count, 2); XCTAssertEqual(queue.size, 16)
        XCTAssertEqual(queue.duration, 0.2, accuracy: 0.0001)
        var retained = queue.getPacket(timeout: 0.01)
        XCTAssertEqual(retained, key); av_packet_free(&retained)
        XCTAssertEqual(queue.count, 1); XCTAssertEqual(queue.size, 8)
        XCTAssertEqual(queue.duration, 0.1, accuracy: 0.0001)
    }

    func testHighRateCatchUpQueueChoosesLatestBoundedRAPBeforeSeekMarker() throws {
        let queue = FTPacketQueue(timebase: 0.1)
        var marker: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        queue.sentinel = marker
        defer { queue.destroy(); av_packet_free(&marker) }
        for pts in [Int64(10), 20, 30] { queue.putPacket(try catchUpPacket(pts: pts, key: pts == 20), duration: 0) }
        let latest = try catchUpPacket(pts: 40, key: true)
        queue.putPacket(latest, duration: 0)
        queue.putPacket(try catchUpPacket(pts: 50), duration: 0)
        queue.putPacket(try catchUpPacket(pts: 90, key: true), duration: 0)
        queue.putPacket(try XCTUnwrap(marker), duration: 0)
        queue.putPacket(try catchUpPacket(pts: 45, key: true), duration: 0)
        let jump = try XCTUnwrap(queue.discardBeforeKeyframe(notBefore: 1.5, noLaterThan: 5, timestampOffset: 0))
        XCTAssertEqual(jump.position, 4, "A stale earlier RAP adds another flush/reorder delay while a later safe RAP is already queued")
        XCTAssertEqual(jump.packets, 3)
        var retained = queue.getPacket(timeout: 0.01)
        XCTAssertEqual(retained, latest); av_packet_free(&retained)
        XCTAssertEqual(queue.count, 4)
    }

    func testHighRateCatchUpQueueDoesNotDiscardTailOrDistantKeyframe() throws {
        let queue = FTPacketQueue(timebase: 0.1); defer { queue.destroy() }
        queue.putPacket(try catchUpPacket(pts: 10), duration: 0)
        queue.putPacket(try catchUpPacket(pts: 20), duration: 0)
        XCTAssertNil(queue.discardBeforeKeyframe(notBefore: 3, noLaterThan: 5, timestampOffset: 0))
        XCTAssertEqual(queue.count, 2); XCTAssertEqual(queue.size, 16)
        // MP4 edit lists can include keyframes used only for decoder preroll.
        // Their following packets can jump back to an earlier public timestamp.
        let discardedKey = try catchUpPacket(pts: 40, key: true)
        discardedKey.pointee.flags |= AV_PKT_FLAG_DISCARD
        queue.putPacket(discardedKey, duration: 0)
        XCTAssertNil(queue.discardBeforeKeyframe(notBefore: 3, noLaterThan: 5, timestampOffset: 0), "Discard-only preroll is not a presentation recovery point")
        XCTAssertEqual(queue.count, 3); XCTAssertEqual(queue.size, 24)
        queue.putPacket(try catchUpPacket(pts: 100, key: true), duration: 0)
        XCTAssertNil(queue.discardBeforeKeyframe(notBefore: 3, noLaterThan: 5, timestampOffset: 0))
        XCTAssertEqual(queue.count, 4); XCTAssertEqual(queue.size, 32)
        XCTAssertEqual(queue.duration, 0.4, accuracy: 0.0001)
    }

    func testHighRateCatchUpQueueCannotCrossSeekMarkerAndUsesDTSOffset() throws {
        let queue = FTPacketQueue(timebase: 0.1)
        var marker: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        queue.sentinel = marker
        defer { queue.destroy(); av_packet_free(&marker) }
        queue.putPacket(try catchUpPacket(pts: 10), duration: 0)
        queue.putPacket(try XCTUnwrap(marker), duration: 0)
        let key = try catchUpPacket(pts: FT_AV_NOPTS_VALUE, key: true); key.pointee.dts = 60
        queue.putPacket(key, duration: 0)
        XCTAssertNil(queue.discardBeforeKeyframe(notBefore: 3, noLaterThan: 5, timestampOffset: 2))
        XCTAssertEqual(queue.count, 3)
        var first = queue.getPacket(timeout: 0.01); av_packet_free(&first)
        XCTAssertEqual(queue.getPacket(timeout: 0.01), marker)
        let jump = try XCTUnwrap(queue.discardBeforeKeyframe(notBefore: 3, noLaterThan: 5, timestampOffset: 2))
        XCTAssertEqual(jump.packets, 0); XCTAssertEqual(jump.position, 4)
        XCTAssertEqual(queue.count, 1)
    }

    private func catchUpPacket(pts: Int64, key: Bool = false) throws -> UnsafeMutablePointer<AVPacket> {
        let packet = try XCTUnwrap(av_packet_alloc())
        guard av_new_packet(packet, 8) == 0 else {
            var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned)
            throw NSError(domain: "CatchUpPacketTest", code: 1)
        }
        packet.pointee.pts = pts; packet.pointee.dts = pts; packet.pointee.duration = 1
        packet.pointee.flags = key ? AV_PKT_FLAG_KEY : 0
        return packet
    }

    func testNilURLReportsFailure() throws {
        let player = FTPlayer(contentURL: nil); let observer = PlayerObserver()
        var error: Error?; observer.failed = { error = $0 }; player.delegate = observer; player.replaceVideo()
        try require(until { error != nil }, "Nil URL did not return an error")
        player.stop()
    }

    func testReviewAudioClockPausePreservesInterpolatedTime() {
        let clock = FTAudioMasterClock()
        _ = clock.currentTime // Warm AVAudioSession property lookup before measuring.
        clock.update(pts: 10)
        Thread.sleep(forTimeInterval: 0.08)
        let before = clock.currentTime
        clock.setPaused(true)
        let paused = clock.currentTime
        FTPlayerDiagnostic.shared.log("review audio clock before=\(before) paused=\(paused) delta=\(paused - before)", category: "test")
        XCTAssertEqual(paused, before, accuracy: 0.015, "Pause rewound interpolated audio time")
        Thread.sleep(forTimeInterval: 0.04)
        clock.setPaused(true)
        XCTAssertEqual(clock.currentTime, before, accuracy: 0.015, "Repeated pause moved clock")
        clock.setPaused(false)
        XCTAssertEqual(clock.currentTime, before, accuracy: 0.015, "Resume jumped backward")
    }

    func testAudioClockSlewsJitterButPreservesSeekAndDiscontinuities() {
        var now = 0.0
        let clock = FTAudioMasterClock(wallTime: { now })
        clock.updateFromAudio(pts: 5.709, frameDuration: 0.128)
        now += 0.128
        // Source timestamps advance only 68 ms while PCM advances 128 ms.
        clock.updateFromAudio(pts: 5.777, frameDuration: 0.128)
        XCTAssertEqual(clock.consumptionTime, 5.8306, accuracy: 0.000001)
        now += 0.128
        clock.updateFromAudio(pts: 5.907, frameDuration: 0.128)
        XCTAssertEqual(clock.consumptionTime, 5.9522, accuracy: 0.000001)
        clock.seek(to: 20)
        XCTAssertEqual(clock.consumptionTime, 20, accuracy: 0.000001)
        clock.updateFromAudio(pts: 20, frameDuration: 0.128)
        now += 0.128
        clock.updateFromAudio(pts: 23, frameDuration: 0.128)
        XCTAssertEqual(clock.consumptionTime, 23, accuracy: 0.000001)
        clock.setRate(4)
        now += 0.032
        clock.updateFromAudio(pts: 23.068, frameDuration: 0.128)
        XCTAssertEqual(clock.consumptionTime, 23.1216, accuracy: 0.000001)
        clock.resetInterpolation()
        clock.updateFromAudio(pts: 24, frameDuration: 0.128)
        XCTAssertEqual(clock.consumptionTime, 24, accuracy: 0.000001)
    }


    func testPreparationNilURLCanFailAgainWithFreshProgress() throws {
        // Observe the nil-URL player directly; no unused media session is needed.
        final class FailureObserver: FTPlayerDeletegate {
            var errorCount = 0
            var preparationEvents: [[String: Any]] = []
            func player(_ player: FTPlayer, didFail error: Error) { errorCount += 1 }
            func player(_ player: FTPlayer, didChangePreparationState state: FTPlayerPreparationState) {
                preparationEvents.append(["state": state.rawValue])
            }
        }
        let s = FailureObserver()
        let player = FTPlayer(contentURL: nil); player.delegate = s
        player.replaceVideo(); try require(until { s.errorCount == 1 }, "Nil URL did not fail")
        player.replaceVideo(); try require(until { s.errorCount == 2 }, "Second nil URL did not fail")
        XCTAssertEqual(player.preparationState, .failed)
        XCTAssertEqual(s.preparationEvents.filter { $0["state"] as? String == "begin" }.count, 2)
        player.stop()
    }

    func testReviewDelegateReadAndDetachAreAtomic() throws {
        let player = FTPlayer(contentURL: nil)
        // The decoder is never opened: this case exercises delegate ownership only.
        let decoder = FTDecoder(contentURL: URL(fileURLWithPath: "/unit-test-source-identity.mp4"), videoFormat: .mpeg4, videoOutput: player, audioOutput: player)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<250_000 { decoder.delegate = player; decoder.delegate = nil }
            group.leave()
        }
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<250_000 { decoder.delegate?.decoder(decoder, didChangeValueOfBufferedDuration: 0) }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success, "Delegate detach stress deadlocked")
        decoder.delegate = nil
        decoder.closeFile()
    }

}
