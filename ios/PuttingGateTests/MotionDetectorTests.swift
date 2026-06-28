import XCTest
import CoreVideo
@testable import PuttingGate

final class MotionDetectorTests: XCTestCase {

    func testIdenticalGridsHaveNoDifference() {
        let a: [Float] = [0.1, 0.2, 0.3, 0.4]
        XCTAssertEqual(MotionDetector.meanAbsoluteDifference(a, a), 0, accuracy: 1e-6)
    }

    func testFullySwitchedGridIsMaxDifference() {
        let zeros = [Float](repeating: 0, count: 16)
        let ones = [Float](repeating: 1, count: 16)
        XCTAssertEqual(MotionDetector.meanAbsoluteDifference(zeros, ones), 1, accuracy: 1e-6)
    }

    func testMismatchedLengthsReturnZero() {
        XCTAssertEqual(MotionDetector.meanAbsoluteDifference([0.5], [0.1, 0.2]), 0)
    }

    func testIdenticalFramesProduceNoMotion() throws {
        let frame = try makeBGRABuffer(width: 64, height: 64, luminance: 128)
        let detector = MotionDetector()
        let roi = CGRect(x: 0, y: 0, width: 1, height: 1)
        _ = detector.difference(pixelBuffer: frame, roi: roi) // first frame primes state
        let second = detector.difference(pixelBuffer: frame, roi: roi)
        XCTAssertEqual(second, 0, accuracy: 1e-5)
    }

    func testChangedFrameProducesMotion() throws {
        let dark = try makeBGRABuffer(width: 64, height: 64, luminance: 0)
        let bright = try makeBGRABuffer(width: 64, height: 64, luminance: 255)
        let detector = MotionDetector()
        let roi = CGRect(x: 0, y: 0, width: 1, height: 1)
        _ = detector.difference(pixelBuffer: dark, roi: roi)
        let motion = detector.difference(pixelBuffer: bright, roi: roi)
        XCTAssertGreaterThan(motion, 0.5)
    }

    // MARK: Helpers

    /// Creates a 32BGRA pixel buffer filled with a uniform gray value.
    private func makeBGRABuffer(width: Int, height: Int, luminance: UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb
        )
        let buffer = try XCTUnwrap(pb, "CVPixelBufferCreate failed: \(status)")

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let o = y * bytesPerRow + x * 4
                ptr[o] = luminance     // B
                ptr[o + 1] = luminance // G
                ptr[o + 2] = luminance // R
                ptr[o + 3] = 255       // A
            }
        }
        return buffer
    }
}
