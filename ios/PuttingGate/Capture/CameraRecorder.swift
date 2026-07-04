import AVFoundation
import Combine
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
                               _ lengthFeet: Int, _ breakType: PuttBreak) -> Void)?

    let captureSession = AVCaptureSession()

    private let settings: AppSettings
    private let sessionQueue = DispatchQueue(label: "com.puttinggate.capture")
    private let movieOutput = AVCaptureMovieFileOutput()

    private var configured = false
    /// When the in-flight recording began, so we can timestamp the file.
    private var recordingStartedAt: Date?
    /// Putt metadata captured at the moment recording started.
    private var pendingLengthFeet = 9
    private var pendingBreakType: PuttBreak = .straight

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
            configureExposure(device)
        }

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }
        if let connection = movieOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // portrait
        }
        captureSession.commitConfiguration()
    }

    /// The back camera to record with. Prefer the ultra-wide lens — that's the
    /// native camera's "0.5×" view — and fall back to the standard wide-angle
    /// lens on devices without an ultra-wide (e.g. iPhone SE).
    private static func backCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Underexpose slightly. Bright outdoor scenes otherwise overexpose the
    /// white ball and green, washing out the detail the backend needs; a
    /// lower exposure keeps highlights intact. Auto-exposure still tracks the
    /// scene — it just aims a couple of stops darker.
    private static let exposureBiasEV: Float = -2.0

    private func configureExposure(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            // Clamp into the device's supported range.
            let bias = max(device.minExposureTargetBias,
                           min(device.maxExposureTargetBias, Self.exposureBiasEV))
            device.setExposureTargetBias(bias)
            device.unlockForConfiguration()
        } catch {
            // Non-fatal: fall back to the default auto-exposure.
        }
    }

    // MARK: Recording control

    func startRecording(lengthFeet: Int, breakType: PuttBreak) {
        sessionQueue.async { [weak self] in
            guard let self, self.captureSession.isRunning, !self.movieOutput.isRecording else { return }
            let fileName = "recording-\(UUID().uuidString).mov"
            let url = Recording.recordingsDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: url)
            self.recordingStartedAt = .now
            self.pendingLengthFeet = lengthFeet
            self.pendingBreakType = breakType
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
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

        DispatchQueue.main.async {
            self.isRecording = false
            self.onRecordingFinished?(outputFileURL, capturedAt, max(0, duration), lengthFeet, breakType)
        }
    }
}
