import AVFoundation
import Combine
import CoreImage
import UIKit

/// Owns the AVCaptureSession and records plain video clips to disk. All putt
/// analysis happens on the backend, so this does nothing but capture and hand
/// the finished file to its owner for upload.
final class CameraRecorder: NSObject, ObservableObject {

    // MARK: Published UI state (main-thread only)

    @Published private(set) var isRecording = false
    @Published private(set) var permissionDenied = false

    /// Called on the main actor when a recording finishes writing, along with
    /// the putt metadata that was set when recording started.
    var onRecordingFinished: ((_ fileURL: URL, _ capturedAt: Date, _ duration: Double,
                               _ lengthFeet: Int, _ breakType: PuttBreak,
                               _ putterID: String?) -> Void)?

    let captureSession = AVCaptureSession()

    private let settings: AppSettings
    private let sessionQueue = DispatchQueue(label: "com.puttinggate.capture")
    private let movieOutput = AVCaptureMovieFileOutput()

    // A live-frame tap used only for the on-demand "Capture test": the latest
    // preview frame is retained so it can be handed to the backend pre-flight
    // check. Written on `videoDataQueue`, read on the main thread, so guarded.
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoDataQueue = DispatchQueue(label: "com.puttinggate.videodata")
    private let frameLock = NSLock()
    private var latestSampleBuffer: CMSampleBuffer?
    private let ciContext = CIContext()

    private var configured = false
    /// The active capture device, kept so exposure can be re-tuned live.
    private var videoDevice: AVCaptureDevice?
    /// When the in-flight recording began, so we can timestamp the file.
    private var recordingStartedAt: Date?
    /// Putt metadata captured at the moment recording started.
    private var pendingLengthFeet = 9
    private var pendingBreakType: PuttBreak = .straight
    private var pendingPutterID: String?

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
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
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

        if let device = Self.backCaptureDevice(),
           let input = try? AVCaptureDeviceInput(device: device),
           captureSession.canAddInput(input) {
            captureSession.addInput(input)
            videoDevice = device
            // Prefer high-frame-rate capture for crisper ball tracking. Selecting
            // an activeFormat overrides the session preset and resets exposure, so
            // it must run before configureExposure.
            configureFrameRate(device)
            configureExposure(device)
        }

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }
        if let connection = movieOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // portrait
        }

        // A second, lightweight output feeds the "Capture test" a still frame.
        if captureSession.canAddOutput(videoDataOutput) {
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
            captureSession.addOutput(videoDataOutput)
            if let connection = videoDataOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90 // match the recorded portrait
            }
        }
        captureSession.commitConfiguration()
    }

    /// The frame rate we'd like to record at, when the lens supports it.
    private static let targetFrameRate = 120.0

    /// Switch the device to a high-frame-rate format at (or near) the chosen
    /// resolution and pin capture to `targetFrameRate`.
    ///
    /// Best-effort: 120 fps isn't available on every lens (the ultra-wide 0.5×
    /// lens we prefer often caps lower than the main wide lens). When no format
    /// supports it, we leave the session preset — and its default ~30 fps — in
    /// place rather than switching lenses, which would break the 0.5×
    /// calibration.
    private func configureFrameRate(_ device: AVCaptureDevice) {
        let target = Self.targetFrameRate
        let desiredArea = settings.capturePreset == .hd1080
            ? 1920 * 1080 : 1280 * 720

        func area(_ format: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(d.width) * Int(d.height)
        }

        // Formats whose frame-rate range reaches the target.
        let hfrFormats = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= target }
        }
        guard !hfrFormats.isEmpty else { return }

        // Prefer an exact resolution match; otherwise the largest format that
        // doesn't exceed the chosen resolution, then the smallest as a floor.
        let format = hfrFormats.first(where: { area($0) == desiredArea })
            ?? hfrFormats.filter { area($0) <= desiredArea }.max(by: { area($0) < area($1) })
            ?? hfrFormats.min(by: { area($0) < area($1) })!

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: Int32(target))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        } catch {
            // Non-fatal: fall back to the session preset's default frame rate.
        }
    }

    /// The back camera to record with. Prefer the ultra-wide lens — that's the
    /// native camera's "0.5×" view — and fall back to the standard wide-angle
    /// lens on devices without an ultra-wide (e.g. iPhone SE).
    private static func backCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Bias auto-exposure by the user's setting. Bright outdoor scenes overexpose
    /// the white ball and green (washing out detail the backend needs), so the
    /// default aims darker; dim indoor scenes need it raised. Auto-exposure still
    /// tracks the scene — this just offsets its target.
    private func configureExposure(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(clampedBias(Float(settings.exposureBias), device))
            device.unlockForConfiguration()
        } catch {
            // Non-fatal: fall back to the default auto-exposure.
        }
    }

    /// Re-apply the exposure bias while the session is live, e.g. as the user
    /// drags the exposure slider.
    func setExposureBias(_ ev: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(self.clampedBias(Float(ev), device))
                device.unlockForConfiguration()
            } catch {
                // Non-fatal: keep the previous bias.
            }
        }
    }

    /// Clamp a requested EV bias into the device's supported range.
    private func clampedBias(_ ev: Float, _ device: AVCaptureDevice) -> Float {
        max(device.minExposureTargetBias, min(device.maxExposureTargetBias, ev))
    }

    // MARK: Recording control

    func startRecording(lengthFeet: Int, breakType: PuttBreak, putterID: String?) {
        sessionQueue.async { [weak self] in
            guard let self, self.captureSession.isRunning, !self.movieOutput.isRecording else { return }
            let fileName = "recording-\(UUID().uuidString).mov"
            let url = Recording.recordingsDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: url)
            self.recordingStartedAt = .now
            self.pendingLengthFeet = lengthFeet
            self.pendingBreakType = breakType
            self.pendingPutterID = putterID
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    // MARK: Capture test

    /// The most recent preview frame as portrait JPEG data, for the backend
    /// pre-flight check. Returns nil until the first frame has arrived (or if
    /// encoding fails). Shares the same lens/exposure as recording, so a passing
    /// check reflects what the real clip will look like.
    func captureTestFrame() -> Data? {
        frameLock.lock()
        let sample = latestSampleBuffer
        frameLock.unlock()
        guard let sample,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Retain only the newest frame; the previous one is released here.
        frameLock.lock()
        latestSampleBuffer = sampleBuffer
        frameLock.unlock()
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        DispatchQueue.main.async { self.isRecording = true }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let capturedAt = recordingStartedAt ?? .now
        recordingStartedAt = nil

        // A stop is reported as an error, but the file is still usable, so only
        // discard when the recording is explicitly unusable.
        if let error, (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
            try? FileManager.default.removeItem(at: outputFileURL)
            DispatchQueue.main.async { self.isRecording = false }
            return
        }

        let asset = AVURLAsset(url: outputFileURL)
        let duration = CMTimeGetSeconds(asset.duration)
        let lengthFeet = pendingLengthFeet
        let breakType = pendingBreakType
        let putterID = pendingPutterID

        DispatchQueue.main.async {
            self.isRecording = false
            self.onRecordingFinished?(
                outputFileURL, capturedAt, max(0, duration), lengthFeet, breakType, putterID
            )
        }
    }
}
