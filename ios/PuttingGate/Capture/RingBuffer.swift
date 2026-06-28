import CoreMedia

/// A duration-bounded FIFO of recent video sample buffers, used to retain
/// "pre-roll" footage so a clip can begin slightly before motion is detected.
///
/// CMSampleBuffer is a CoreFoundation type and is retained/released
/// automatically by ARC in Swift, so no manual CFRetain is required.
final class RingBuffer {

    private struct Entry {
        let pts: CMTime
        let sampleBuffer: CMSampleBuffer
    }

    private var entries: [Entry] = []

    /// Maximum age (seconds) of buffers to keep relative to the newest frame.
    var maxDuration: Double

    init(maxDuration: Double) {
        self.maxDuration = maxDuration
    }

    /// Append the latest frame and evict anything older than `maxDuration`.
    func append(_ sampleBuffer: CMSampleBuffer, pts: CMTime) {
        entries.append(Entry(pts: pts, sampleBuffer: sampleBuffer))
        let cutoff = pts - CMTime(seconds: maxDuration, preferredTimescale: pts.timescale)
        while let first = entries.first, first.pts < cutoff {
            entries.removeFirst()
        }
    }

    /// All currently buffered sample buffers, oldest first.
    func snapshot() -> [CMSampleBuffer] {
        entries.map(\.sampleBuffer)
    }

    var count: Int { entries.count }

    func clear() {
        entries.removeAll()
    }
}
