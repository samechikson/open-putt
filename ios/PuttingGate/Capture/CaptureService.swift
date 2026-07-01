import AVFoundation
import Combine
import UIKit

/// Owns the AVCaptureSession and drives motion-triggered clip recording.
///
/// Frames are always analyzed (so the preview and motion meter work even when
/// idle), but clips are only written while `sessionState == .active`, i.e.
/// between "Start Session" and "End Session".
final class CaptureService: NSObject, ObservableObject {

    enum SessionState {
        case idle
        case active
    }

    private enum RecordingState {
        case waiting
        case recording(writer: ClipWriter, startPTS: CMTime, lastMotionPTS: CMTime, capturedAt: Date)
    }

    // MARK: Published UI state (main-thread only)

    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var isRecordingClip = false
    @Published private(set) var puttCount = 0
    @Published private(set) var motionLevel: Float = 0
    @Published private(set) var permissionDenied = false

    /// Called on the main actor whenever a clip is finalized. The owner
    /// persists a `Clip` and enqueues the upload.
    var onClipRecorded: ((_ fileURL: URL, _ capturedAt: Date, _ duration: Double, _ index: Int) -> Void)?

    let captureSession = AVCaptureSession()

    private let settings: AppSettings
    private let videoQueue = DispatchQueue(label: "com.puttinggate.capture")
    private let detector = MotionDetector()
    private lazy var ringBuffer = RingBuffer(maxDuration: settings.preRollSeconds)
    private let videoOutput = AVCaptureVideoDataOutput()

    private var recordingState: RecordingState = .waiting
    private var cooldownUntilPTS: CMTime = .invalid
    private var clipIndex = 0
    private var configured = false
    private var latestPTS: CMTime = .invalid

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndRun()
                } else {
                    DispatchQueue.main.async { self.permissionDenied = true }
                }
            }
        default:
            DispatchQueue.main.async { self.permissionDenied = true }
        }
    }

    func stop() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession.stopRunning()
        }
    }

    private func configureAndRun() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.configureSession()
                self.configured = true
            }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    private func configureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset =
            settings.capturePreset == .hd1080 ? .hd1920x1080 : .hd1280x720

        // Prefer the ultra-wide lens so the preview opens at the 0.5x field of
        // view; fall back to the standard wide-angle camera on devices without
        // one (e.g. single-camera iPhones).
        if let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // portrait
        }
        captureSession.commitConfiguration()
    }

    // MARK: Session control (Start/End Session button)

    func startSession() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.clipIndex = 0
            self.recordingState = .waiting
            self.cooldownUntilPTS = .invalid
            self.detector.reset()
            DispatchQueue.main.async {
                self.puttCount = 0
                self.sessionState = .active
            }
        }
    }

    func endSession() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            // Finalize an in-flight clip, then go idle.
            if case let .recording(writer, _, _, capturedAt) = self.recordingState {
                let index = self.clipIndex
                writer.finish { [weak self] result in
                    self?.handleFinish(result, writer: writer, capturedAt: capturedAt, index: index)
                }
                self.recordingState = .waiting
            }
            DispatchQueue.main.async {
                self.isRecordingClip = false
                self.sessionState = .idle
            }
        }
    }

    /// Manual fallback: start a clip immediately, bypassing motion detection.
    func forceRecord() {
        videoQueue.async { [weak self] in
            guard let self, self.sessionState == .active, self.latestPTS.isValid else { return }
            if case .waiting = self.recordingState {
                self.beginClip(at: self.latestPTS)
            }
        }
    }
}

// MARK: - Frame processing

extension CaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        latestPTS = pts

        // Keep pre-roll fresh at all times.
        ringBuffer.maxDuration = settings.preRollSeconds
        ringBuffer.append(sampleBuffer, pts: pts)

        // Motion meter (always on).
        let level: Float
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            level = detector.difference(pixelBuffer: pixelBuffer, roi: settings.roi)
        } else {
            level = 0
        }
        publishMotion(level)

        // Recording only happens during an active session.
        guard sessionStateIsActive else { return }

        let threshold = Float(settings.motionThreshold)
        switch recordingState {
        case .waiting:
            let inCooldown = cooldownUntilPTS.isValid && pts < cooldownUntilPTS
            if level > threshold && !inCooldown {
                beginClip(at: pts)
            }

        case .recording(let writer, let startPTS, var lastMotionPTS, let capturedAt):
            writer.append(sampleBuffer)
            if level > threshold { lastMotionPTS = pts }

            let quietFor = CMTimeGetSeconds(pts - lastMotionPTS)
            let elapsed = CMTimeGetSeconds(pts - startPTS)
            if quietFor >= settings.postRollSeconds || elapsed >= settings.maxClipSeconds {
                finishClip(writer: writer, capturedAt: capturedAt, lastPTS: pts)
            } else {
                recordingState = .recording(
                    writer: writer, startPTS: startPTS,
                    lastMotionPTS: lastMotionPTS, capturedAt: capturedAt
                )
            }
        }
    }

    private func beginClip(at pts: CMTime) {
        let fileName = "clip-\(UUID().uuidString).mov"
        let url = Clip.clipsDirectory.appendingPathComponent(fileName)
        let writer = ClipWriter(outputURL: url)
        // Pre-roll: replay buffered frames (oldest first), which include the
        // current frame as the newest entry.
        for buffer in ringBuffer.snapshot() {
            writer.append(buffer)
        }
        recordingState = .recording(
            writer: writer, startPTS: pts, lastMotionPTS: pts, capturedAt: .now
        )
        DispatchQueue.main.async { self.isRecordingClip = true }
    }

    private func finishClip(writer: ClipWriter, capturedAt: Date, lastPTS: CMTime) {
        recordingState = .waiting
        cooldownUntilPTS = lastPTS + CMTime(seconds: settings.cooldownSeconds, preferredTimescale: lastPTS.timescale)
        detector.reset()
        let index = clipIndex
        clipIndex += 1
        DispatchQueue.main.async { self.isRecordingClip = false }
        writer.finish { [weak self] result in
            self?.handleFinish(result, writer: writer, capturedAt: capturedAt, index: index)
        }
    }

    private func handleFinish(
        _ result: Result<Double, Error>,
        writer: ClipWriter,
        capturedAt: Date,
        index: Int
    ) {
        switch result {
        case .success(let duration):
            DispatchQueue.main.async {
                self.puttCount += 1
                self.onClipRecorded?(writer.outputURL, capturedAt, duration, index)
            }
        case .failure:
            try? FileManager.default.removeItem(at: writer.outputURL)
        }
    }

    // MARK: Thread-safe accessors

    private var sessionStateIsActive: Bool {
        // sessionState is mutated on main but read here on videoQueue; the
        // value is a simple enum so a torn read is not possible.
        sessionState == .active
    }

    private func publishMotion(_ level: Float) {
        DispatchQueue.main.async {
            // Smooth a little to avoid jitter in the UI meter.
            self.motionLevel = self.motionLevel * 0.6 + level * 0.4
        }
    }
}
