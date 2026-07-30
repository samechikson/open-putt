import AVFoundation

/// Keeps a short rolling window of recent camera footage so a clip of the
/// *previous* couple of seconds can be produced on demand (when the gate detects
/// a putt). A raw in-memory frame ring is far too large at full quality, so this
/// encodes continuously to small on-disk H.264 segments and keeps only the last
/// few; on a trigger it stitches them and exports the tail.
///
/// Fed `CMSampleBuffer`s from `CameraRecorder`'s video data output. All writer
/// state is confined to `queue`.
final class PreRollRecorder {

    private let queue = DispatchQueue(label: "com.puttinggate.preroll")
    private let segmentSeconds = 1.5      // length of each rolling segment
    private let keepSegments = 3          // ~4.5 s of history retained on disk
    private let dir: URL

    private var active = false
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var currentURL: URL?
    private var segmentStartPTS: CMTime = .invalid
    private var lastPTS: CMTime = .invalid

    private struct Segment { let url: URL; let duration: CMTime }
    private var completed: [Segment] = []

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("preroll", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: Lifecycle

    /// Begin buffering. Frames only accumulate while active.
    func start() {
        queue.async { self.active = true }
    }

    /// Stop buffering and drop the retained segments.
    func stop() {
        queue.async {
            self.active = false
            self.finalizeCurrent { }
            for seg in self.completed { try? FileManager.default.removeItem(at: seg.url) }
            self.completed.removeAll()
        }
    }

    /// Feed one captured frame. Called from the camera's video-data queue.
    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.async { self.handle(sampleBuffer) }
    }

    // MARK: Clip export

    /// Produce an `.mp4` of roughly the last `seconds` of footage ending now, or
    /// nil if nothing is buffered yet. Finalizes the in-progress segment first so
    /// the tail up to this moment is included; recording resumes on the next frame.
    func clipLastSeconds(_ seconds: Double) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            queue.async {
                self.finalizeCurrent {
                    // Gather the most recent segments covering >= `seconds`.
                    var chosen: [Segment] = []
                    var acc = 0.0
                    for seg in self.completed.reversed() {
                        chosen.insert(seg, at: 0)
                        acc += seg.duration.seconds
                        if acc >= seconds { break }
                    }
                    guard !chosen.isEmpty else { cont.resume(returning: nil); return }
                    Task {
                        let url = await self.exportClip(chosen, lastSeconds: seconds)
                        cont.resume(returning: url)
                    }
                }
            }
        }
    }

    // MARK: Writer plumbing (queue-confined)

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard active, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if writer == nil { startSegment(with: sampleBuffer) }
        guard let writer, let input, writer.status == .writing else { return }

        if segmentStartPTS == .invalid {
            writer.startSession(atSourceTime: pts)
            segmentStartPTS = pts
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
            lastPTS = pts
        }
        // Rotate to a fresh segment once this one is long enough.
        if segmentStartPTS != .invalid,
           CMTimeSubtract(pts, segmentStartPTS).seconds >= segmentSeconds {
            finalizeCurrent { }
        }
    }

    private func startSegment(with sampleBuffer: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        let url = dir.appendingPathComponent("seg-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dims.width),
            AVVideoHeightKey: Int(dims.height),
        ]
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        guard w.canAdd(inp) else { return }
        w.add(inp)
        guard w.startWriting() else { return }
        writer = w
        input = inp
        currentURL = url
        segmentStartPTS = .invalid
    }

    /// Finalize the current segment (if any), append it to `completed`, trim old
    /// ones, then call `done` on `queue`. Recording restarts on the next frame.
    private func finalizeCurrent(_ done: @escaping () -> Void) {
        guard let writer, let input, let url = currentURL, writer.status == .writing else {
            done(); return
        }
        let start = segmentStartPTS
        let last = lastPTS
        input.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                let dur = (start != .invalid && last != .invalid)
                    ? CMTimeSubtract(last, start) : .zero
                if dur > .zero {
                    self.completed.append(Segment(url: url, duration: dur))
                    while self.completed.count > self.keepSegments {
                        let old = self.completed.removeFirst()
                        try? FileManager.default.removeItem(at: old.url)
                    }
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
                done()
            }
        }
        self.writer = nil
        self.input = nil
        self.currentURL = nil
        self.segmentStartPTS = .invalid
    }

    private func exportClip(_ segments: [Segment], lastSeconds: Double) async -> URL? {
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }

        var cursor = CMTime.zero
        var transformSet = false
        for seg in segments {
            let asset = AVURLAsset(url: seg.url)
            guard let assetTrack = (try? await asset.loadTracks(withMediaType: .video))?.first
            else { continue }
            let dur = (try? await asset.load(.duration)) ?? seg.duration
            do {
                try track.insertTimeRange(
                    CMTimeRange(start: .zero, duration: dur), of: assetTrack, at: cursor
                )
            } catch { continue }
            if !transformSet, let t = try? await assetTrack.load(.preferredTransform) {
                track.preferredTransform = t
                transformSet = true
            }
            cursor = CMTimeAdd(cursor, dur)
        }

        let total = cursor
        guard total > .zero else { return nil }
        let clipDur = CMTime(seconds: lastSeconds, preferredTimescale: 600)
        let startTime = CMTimeMaximum(.zero, CMTimeSubtract(total, clipDur))
        let range = CMTimeRange(start: startTime, duration: CMTimeSubtract(total, startTime))

        let outURL = dir.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outURL)
        guard let export = AVAssetExportSession(
            asset: comp, presetName: AVAssetExportPresetHighestQuality
        ) else { return nil }
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.timeRange = range

        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            export.exportAsynchronously {
                cont.resume(returning: export.status == .completed ? outURL : nil)
            }
        }
    }
}
