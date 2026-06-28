import XCTest
import CoreMedia
@testable import PuttingGate

final class RingBufferTests: XCTestCase {

    func testEvictsBuffersOlderThanMaxDuration() throws {
        let ring = RingBuffer(maxDuration: 1.0)
        // Append 3 seconds of frames at 1 fps. Only those within the last
        // 1 second (relative to the newest) should remain.
        for i in 0..<3 {
            let pts = CMTime(value: CMTimeValue(i), timescale: 1)
            ring.append(try makeSampleBuffer(pts: pts), pts: pts)
        }
        // Newest pts = 2s, cutoff = 1s, so pts 0 is evicted; 1 and 2 remain.
        XCTAssertEqual(ring.count, 2)
    }

    func testClearEmptiesBuffer() throws {
        let ring = RingBuffer(maxDuration: 5.0)
        let pts = CMTime(value: 0, timescale: 1)
        ring.append(try makeSampleBuffer(pts: pts), pts: pts)
        XCTAssertEqual(ring.count, 1)
        ring.clear()
        XCTAssertEqual(ring.count, 0)
    }

    func testSnapshotPreservesOrder() throws {
        let ring = RingBuffer(maxDuration: 100)
        var ptsList: [CMTime] = []
        for i in 0..<4 {
            let pts = CMTime(value: CMTimeValue(i), timescale: 1)
            ptsList.append(pts)
            ring.append(try makeSampleBuffer(pts: pts), pts: pts)
        }
        let snapshot = ring.snapshot()
        XCTAssertEqual(snapshot.count, 4)
        for (i, buffer) in snapshot.enumerated() {
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer), ptsList[i])
        }
    }

    // MARK: Helpers

    /// Minimal empty CMSampleBuffer carrying only timing info.
    private func makeSampleBuffer(pts: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var formatDesc: CMFormatDescription?
        CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Video,
            mediaSubType: 0,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        return try XCTUnwrap(sampleBuffer, "CMSampleBufferCreate failed: \(status)")
    }
}
