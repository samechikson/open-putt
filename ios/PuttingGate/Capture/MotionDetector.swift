import CoreVideo
import CoreGraphics

/// Detects motion by comparing a downsampled grayscale grid of the current
/// frame against the previous one, restricted to a region of interest.
///
/// Expects 32BGRA pixel buffers (the format the capture output is configured
/// to deliver).
final class MotionDetector {

    private let cols: Int
    private let rows: Int
    private var previous: [Float]?

    init(cols: Int = 32, rows: Int = 24) {
        self.cols = cols
        self.rows = rows
    }

    /// Returns the normalized mean absolute luma difference (0...1) between the
    /// current frame and the previous one within `roi`. Returns 0 for the first
    /// frame after a reset.
    func difference(pixelBuffer: CVPixelBuffer, roi: CGRect) -> Float {
        let current = Self.sample(
            pixelBuffer: pixelBuffer, roi: roi, cols: cols, rows: rows
        )
        defer { previous = current }
        guard let prev = previous, prev.count == current.count else { return 0 }
        return Self.meanAbsoluteDifference(current, prev)
    }

    /// Forget the previous frame so the next call returns 0.
    func reset() {
        previous = nil
    }

    // MARK: Pure helpers (unit-testable without a capture session)

    /// Mean absolute difference of two equal-length luma grids.
    static func meanAbsoluteDifference(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in 0..<a.count { sum += abs(a[i] - b[i]) }
        return sum / Float(a.count)
    }

    /// Sample a `cols`x`rows` normalized (0...1) luma grid from a 32BGRA buffer
    /// over the given normalized region of interest.
    static func sample(pixelBuffer: CVPixelBuffer, roi: CGRect, cols: Int, rows: Int) -> [Float] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return [Float](repeating: 0, count: cols * rows)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let roiX = Int(roi.minX * CGFloat(width))
        let roiY = Int(roi.minY * CGFloat(height))
        let roiW = max(1, Int(roi.width * CGFloat(width)))
        let roiH = max(1, Int(roi.height * CGFloat(height)))

        var grid = [Float](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let x = min(width - 1, max(0, roiX + (c * roiW) / cols))
                let y = min(height - 1, max(0, roiY + (r * roiH) / rows))
                let offset = y * bytesPerRow + x * 4 // BGRA
                let b = Float(ptr[offset])
                let g = Float(ptr[offset + 1])
                let rr = Float(ptr[offset + 2])
                // Rec. 601 luma, normalized to 0...1.
                grid[r * cols + c] = (0.114 * b + 0.587 * g + 0.299 * rr) / 255.0
            }
        }
        return grid
    }
}
