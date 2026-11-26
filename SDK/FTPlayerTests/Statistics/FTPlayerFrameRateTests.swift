import XCTest
import UIKit
import CoreVideo
import libavcodec
@testable import FTPlayer

final class FTPlayerFrameRateTests: UnitTestCase {
    private func picture(_ luma: UInt8, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                         width: Int = 160) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, 90, format, nil, &output), kCVReturnSuccess)
        let pixel = try XCTUnwrap(output)
        if CVPixelBufferGetPlaneCount(pixel) > 0 {
            CVPixelBufferLockBaseAddress(pixel, [])
            defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, 0))
            memset(base, Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) * 90)
        }
        return pixel
    }

    func testContentHeldPicturesThenMotionMeasuresMediaTimeAtDoubleSpeed() throws {
        var meter = VideoContentChangeMeter()
        let dark = try picture(40), light = try picture(90)
        // 10 timestamped frames/sec, but the picture changes once per 13 frames.
        for index in 0...100 {
            meter.record((index / 13).isMultiple(of: 2) ? dark : light,
                         pts: Double(index) / 10, wall: Double(index) / 20)
        }
        let held = meter.snapshot(at: 5)
        XCTAssertEqual(try XCTUnwrap(held.estimatedChangesPerSecond), 0.75, accuracy: 0.001)
        XCTAssertEqual(held.sampleDuration, 4)
        // The next region changes on every frame, still played at 2x.
        for index in 101...141 {
            meter.record(index.isMultiple(of: 2) ? dark : light,
                         pts: Double(index) / 10, wall: Double(index) / 20)
        }
        XCTAssertEqual(try XCTUnwrap(meter.snapshot(at: 7.05).estimatedChangesPerSecond), 10, accuracy: 0.26)
    }

    func testContentStaticNoiseIdleResetAndUnsupportedFormat() throws {
        var meter = VideoContentChangeMeter()
        let pixel = try picture(40)
        meter.record(pixel, pts: 0, wall: 0)
        XCTAssertNil(meter.snapshot(at: 0).estimatedChangesPerSecond)
        for index in 1...40 {
            CVPixelBufferLockBaseAddress(pixel, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, 0))
            base.storeBytes(of: UInt8(index.isMultiple(of: 2) ? 40 : 41), as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(pixel, [])
            meter.record(pixel, pts: Double(index) / 10, wall: Double(index) / 10)
        }
        XCTAssertEqual(try XCTUnwrap(meter.snapshot(at: 4).estimatedChangesPerSecond), 0)
        XCTAssertNil(meter.snapshot(at: 7).estimatedChangesPerSecond)
        meter.reset()
        XCTAssertNil(meter.snapshot(at: 4).estimatedChangesPerSecond)
        meter.record(pixel, pts: 1, wall: 8)
        meter.record(pixel, pts: 0, wall: 9) // seek/discontinuity
        XCTAssertEqual(meter.snapshot(at: 9).sampleDuration, 0)
        meter.record(try picture(40, width: 320), pts: 1, wall: 10)
        XCTAssertNil(meter.snapshot(at: 10).estimatedChangesPerSecond)
        meter.record(try picture(40, format: kCVPixelFormatType_32BGRA), pts: 2, wall: 11)
        XCTAssertNil(meter.snapshot(at: 11).estimatedChangesPerSecond)
    }

    func testContentPixelFormatChangeStartsANewSampleWindow() throws {
        var meter = VideoContentChangeMeter()
        let videoRange = try picture(40)
        meter.record(videoRange, pts: 0, wall: 0)
        meter.record(videoRange, pts: 1, wall: 1)
        XCTAssertNotNil(meter.snapshot(at: 1).estimatedChangesPerSecond)
        let fullRange = try picture(40, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        meter.record(fullRange, pts: 2, wall: 2)
        XCTAssertNil(meter.snapshot(at: 2).estimatedChangesPerSecond,
                     "Different pixel ranges must not share an observation window")
        XCTAssertEqual(meter.snapshot(at: 2).sampleDuration, 0)
    }

    func testSparseToMotionCadenceAndWallRateAreIndependent() throws {
        var meter = VideoFrameRateMeter()
        for second in 0...2 { meter.record(pts: Double(second), wall: Double(second)) }
        XCTAssertEqual(try XCTUnwrap(meter.snapshot(at: 2).timelineFramesPerSecond), 1, accuracy: 0.001)
        XCTAssertEqual(meter.snapshot(at: 2).outputFramesPerSecond, 1, accuracy: 0.001)
        XCTAssertEqual(meter.snapshot(at: 2.75).outputFramesPerSecond, 1, accuracy: 0.001,
                       "A 1 fps stream should not oscillate just because the UI polls between frames")
        // A later 13 fps region played at 2x has 26 output frames/wall second.
        for index in 0...52 {
            meter.record(pts: 10 + Double(index) / 13, wall: 5 + Double(index) / 26)
        }
        let snapshot = meter.snapshot(at: 7)
        XCTAssertEqual(try XCTUnwrap(snapshot.timelineFramesPerSecond), 13, accuracy: 0.001)
        XCTAssertEqual(snapshot.outputFramesPerSecond, 26, accuracy: 0.001)
        // Returning to sparse frames ages the motion region out of the window.
        for second in 0...3 { meter.record(pts: 15 + Double(second), wall: 8 + Double(second)) }
        XCTAssertEqual(try XCTUnwrap(meter.snapshot(at: 11).timelineFramesPerSecond), 1, accuracy: 0.001)
    }

    func testStatisticsGateDeliversOnlyChangedValuesAtInterval() {
        var gate = VideoStatisticsChangeGate(interval: 0.5)
        XCTAssertTrue(gate.shouldDeliver(nil, at: 0), "The first check reports the initial state")
        XCTAssertFalse(gate.shouldDeliver(1, at: 0.2), "Checks are limited to one per interval")
        XCTAssertTrue(gate.shouldDeliver(1, at: 0.5))
        XCTAssertFalse(gate.shouldDeliver(1, at: 1.0), "An unchanged value is not repeated")
        XCTAssertTrue(gate.shouldDeliver(25, at: 1.5))
        XCTAssertTrue(gate.shouldDeliver(nil, at: 2.0), "Losing the measurement is a change")
        gate.reset()
        XCTAssertTrue(gate.shouldDeliver(nil, at: 2.1), "Reset clears the interval and the last value")
    }

    func testStatisticsGateChecksPerMediaIntervalAndCombinedValues() {
        var gate = VideoStatisticsChangeGate(interval: 0.5)
        XCTAssertTrue(gate.shouldDeliver(1, 1, at: 0, rate: 16))
        XCTAssertTrue(gate.shouldDeliver(1, 4, at: 0.04, rate: 16), "At 16x a check covers 0.5 media seconds")
        XCTAssertFalse(gate.shouldDeliver(1, 1, at: 0.05, rate: 16), "Checks are still limited per interval")
        XCTAssertTrue(gate.shouldDeliver(1, 1, at: 0.08, rate: 16), "A change in any value is delivered")
        XCTAssertFalse(gate.shouldDeliver(1, 4, at: 0.3, rate: 0.5), "Slow rates keep the wall interval")
        XCTAssertTrue(gate.shouldDeliver(1, 4, at: 0.6, rate: 0.5))
    }

    func testUpcomingPacketTimelineMeasuresEncodedCadenceAhead() throws {
        let timeline = VideoPacketTimeline()
        for second in [0, 2, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11] { timeline.record(Double(second)) } // demux order may differ
        XCTAssertEqual(try XCTUnwrap(timeline.framesPerSecond(from: 2, window: 3, reachedEnd: false)), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timeline.framesPerSecond(from: 2.5, window: 3, reachedEnd: false)), 1, accuracy: 0.001)
        XCTAssertNil(timeline.framesPerSecond(from: 9, window: 3, reachedEnd: false), "Packets do not cover the window yet")
        XCTAssertEqual(try XCTUnwrap(timeline.framesPerSecond(from: 9, window: 3, reachedEnd: true)), 1, accuracy: 0.001,
                       "At the end of the file the remaining packets are all there is")
        // A 13 fps event from 12 s to 14 s, then 1 fps again.
        for index in 0...26 { timeline.record(12 + Double(index) / 13) }
        for second in 15...20 { timeline.record(Double(second)) }
        XCTAssertGreaterThan(try XCTUnwrap(timeline.framesPerSecond(from: 10, window: 3, reachedEnd: false)), 1.5,
                             "An event inside the window raises the measurement before it is decoded")
        XCTAssertEqual(try XCTUnwrap(timeline.framesPerSecond(from: 15, window: 3, reachedEnd: false)), 1, accuracy: 0.001,
                       "Past the event the measurement is low again")
        timeline.reset()
        XCTAssertNil(timeline.framesPerSecond(from: 15, window: 3, reachedEnd: true), "A seek/flush clears the packets")
    }

    func testPacketTimelineTellsWhetherFramesLieBetweenClockAndNextFrame() {
        let timeline = VideoPacketTimeline()
        for second in 0...5 { timeline.record(Double(second)) }
        for index in 0...12 { timeline.record(6 + Double(index) / 13) }
        XCTAssertFalse(timeline.hasPackets(after: 2.3, before: 3), "1 fps: nothing between the clock and the next frame")
        XCTAssertFalse(timeline.hasPackets(after: 2, before: 3), "Both ends are excluded")
        XCTAssertTrue(timeline.hasPackets(after: 5.5, before: 6.5), "Event frames sampled away at a high rate")
        timeline.reset()
        XCTAssertTrue(timeline.hasPackets(after: 2.3, before: 3), "Unknown packets count as missing frames")
    }

    func testIdleSeekDiscontinuityAndResetDoNotReportStaleFPS() {
        var meter = VideoFrameRateMeter()
        meter.record(pts: 0, wall: 0); meter.record(pts: 1, wall: 1)
        XCTAssertEqual(meter.snapshot(at: 2).outputFramesPerSecond, 0.5, accuracy: 0.001)
        XCTAssertEqual(meter.snapshot(at: 4).outputFramesPerSecond, 0)
        XCTAssertNil(meter.snapshot(at: 4).timelineFramesPerSecond)
        meter.record(pts: 0, wall: 4) // backwards discontinuity
        XCTAssertNil(meter.snapshot(at: 4).timelineFramesPerSecond)
        meter.record(pts: 1, wall: 5)
        meter.reset()
        XCTAssertEqual(meter.snapshot(at: 5).sampleFrameCount, 0)
        meter.record(pts: .nan, wall: 6)
        XCTAssertEqual(meter.snapshot(at: 6).sampleFrameCount, 0)
    }

}
