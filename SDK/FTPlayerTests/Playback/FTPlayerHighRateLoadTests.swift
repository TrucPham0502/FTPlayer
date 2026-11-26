import XCTest
import UIKit
import CoreVideo
import libavcodec
@testable import FTPlayer

final class FTPlayerHighRateLoadTests: UnitTestCase {
    @objc func testHighRateFullQueueRefillsBeforeWallBufferRunsOut() throws {
        var codec = try XCTUnwrap(avcodec_alloc_context3(nil)) as UnsafeMutablePointer<AVCodecContext>?
        defer { avcodec_free_context(&codec) }
        codec!.pointee.codec_id = AV_CODEC_ID_MPEG4
        let decoder = FTVideoDecoder(codecContext: codec!, timebase: 1 / 90_000, fps: 30, delegate: nil, policy: .ffmpeg)
        let source = TimelineCoverageFrameSource()
        decoder.source = source; decoder.playbackRate = 16; decoder.maxDecodeDuration = 2
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { decoder.decodeFrameThread(); stopped.signal() }
        defer { decoder.destroy(); XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success); withExtendedLifetime(source) {} }
        for index in 0..<600 {
            let packet = try XCTUnwrap(av_packet_alloc())
            XCTAssertEqual(av_new_packet(packet, 8), 0)
            packet.pointee.pts = Int64(index * 3000); packet.pointee.dts = packet.pointee.pts
            packet.pointee.duration = 3000; packet.pointee.flags = AV_PKT_FLAG_KEY
            decoder.putPacket(packet)
        }
        let end = ProcessInfo.processInfo.systemUptime + 2
        while decoder.frameDuration() < 2 && ProcessInfo.processInfo.systemUptime < end { pump(0.001) }
        XCTAssertGreaterThanOrEqual(decoder.frameDuration(), 2)
        pump(0.005) // The decode worker is in its full-queue wait, with input still queued.
        while let frame = decoder.getFrameAsync() { frame.cancel() }
        let began = ProcessInfo.processInfo.systemUptime
        while decoder.frameEmpty() && ProcessInfo.processInfo.systemUptime - began < 0.2 { pump(0.001) }
        let latency = ProcessInfo.processInfo.systemUptime - began
        print("HIGH_RATE_REFILL_LATENCY=\(latency)")
        XCTAssertFalse(decoder.frameEmpty())
        XCTAssertLessThan(latency, 0.070, "Fixed 100 ms wait uses nearly the entire 125 ms wall-clock buffer at 16x")
    }

    @objc func testHighRateSamplingKeepsDisplayCadence() throws {
        continueAfterFailure = true
        for fps in [24.0, 30, 60] {
            for rate: Float in [4, 8, 16] {
                var codec = try XCTUnwrap(avcodec_alloc_context3(nil)) as UnsafeMutablePointer<AVCodecContext>?
                defer { avcodec_free_context(&codec) }
                codec!.pointee.codec_id = AV_CODEC_ID_MPEG4
                let decoder = FTVideoDecoder(codecContext: codec!, timebase: 1 / 90_000, fps: fps, delegate: nil, policy: .ffmpeg)
                let source = TimelineCoverageFrameSource()
                decoder.source = source
                decoder.playbackRate = rate
                decoder.maxDecodeDuration = 1000
                let stopped = DispatchSemaphore(value: 0)
                DispatchQueue.global().async { decoder.decodeFrameThread(); stopped.signal() }
                defer { decoder.destroy(); XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success); withExtendedLifetime(source) {} }
                // Exactly two wall seconds of decoded output; no sleep, capacity throttle or missing source frames.
                let count = Int(2 * Double(rate) * fps)
                for index in 0..<count {
                    let packet = try XCTUnwrap(av_packet_alloc())
                    XCTAssertEqual(av_new_packet(packet, 8), 0)
                    packet.pointee.pts = Int64((Double(index) * 90_000 / fps).rounded())
                    packet.pointee.dts = packet.pointee.pts
                    packet.pointee.duration = Int64(90_000 / fps)
                    packet.pointee.flags = AV_PKT_FLAG_KEY
                    decoder.putPacket(packet)
                }
                decoder.endOfFile = true
                try require(until(5) { decoder.packetEmpty() && !decoder.decoding }, "Sampling probe did not drain")
                var positions: [Double] = []
                while let frame = decoder.getFrameAsync() { positions.append(frame.position); frame.cancel() }
                XCTAssertEqual(positions.count, 120, accuracy: 1, "\(fps) fps at \(rate)x lost output solely to the sampling grid")
                let wallGaps = zip(positions, positions.dropFirst()).map { ($1 - $0) / Double(rate) }
                XCTAssertLessThanOrEqual(wallGaps.max() ?? 0, 1 / 60 + 1 / fps / Double(rate) + 0.00001)
            }
        }
    }

}
