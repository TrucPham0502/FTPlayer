import XCTest
import UIKit
import CoreVideo
import libavcodec
@testable import FTPlayer

final class FTPlayerFormatTests: UnitTestCase {
    func testHumanDetectEqualTimestampPicturesKeepDecodeOrder() {
        let queue = FTFrameQueue.frameQueue()
        // The camera emits an IDR then a distinct P picture at 5.273806.
        // Put surrounding frames out of order to exercise timestamp sorting
        // while requiring stable order for pictures sharing the timestamp.
        let before = FTVideoFrame(), idr = FTVideoFrame(), predicted = FTVideoFrame(), after = FTVideoFrame()
        before.position = 5.118690
        idr.position = 5.273806
        predicted.position = idr.position
        after.position = 5.362726
        for frame in [after, idr, before, predicted] {
            frame.duration = 0.076921
            queue.putSortFrame(frame)
        }
        XCTAssertTrue(queue.getFrameAsync() === before)
        XCTAssertTrue(queue.getFrameAsync() === idr, "Equal-PTS P picture overtook the earlier IDR, reversing visible motion")
        XCTAssertTrue(queue.getFrameAsync() === predicted)
        XCTAssertTrue(queue.getFrameAsync() === after)
        XCTAssertEqual(queue.duration, 0, accuracy: 0.000001)
        XCTAssertEqual(queue.count, 0)
    }

}
