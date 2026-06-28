import AVFoundation

/// Wraps an AVAssetWriter to encode a sequence of video sample buffers into a
/// single .mov file. The writer is created lazily from the first appended
/// buffer's dimensions, and the session starts at that buffer's timestamp so
/// pre-roll frames keep their original timing.
final class ClipWriter {

    enum WriterError: Error {
        case notStarted
        case writerFailed(Error?)
    }

    let outputURL: URL

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var firstPTS: CMTime = .invalid
    private(set) var lastPTS: CMTime = .invalid

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    /// Append a frame. Safe to call repeatedly; ignores buffers when the input
    /// is not ready or the writer has failed.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if writer == nil {
            guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            setup(width: Int(dims.width), height: Int(dims.height))
        }
        guard let writer, let input else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            lastPTS = pts
        }
    }

    private func setup(width: Int, height: Int) {
        try? FileManager.default.removeItem(at: outputURL)
        guard let w = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        if w.canAdd(inp) { w.add(inp) }
        writer = w
        input = inp
    }

    /// Finalize the file. `completion` receives the clip duration in seconds.
    func finish(completion: @escaping (Result<Double, Error>) -> Void) {
        guard let writer, let input, writer.status == .writing else {
            completion(.failure(WriterError.notStarted))
            return
        }
        input.markAsFinished()
        let duration = max(0, CMTimeGetSeconds(lastPTS - firstPTS))
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(duration))
            } else {
                completion(.failure(WriterError.writerFailed(writer.error)))
            }
        }
    }
}
