import SwiftUI

struct SessionView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @EnvironmentObject private var settings: AppSettings

    private var capture: CaptureService { coordinator.capture }

    var body: some View {
        ZStack {
            CameraPreview(session: capture.captureSession)
                .ignoresSafeArea()
            GateOverlay()
                .ignoresSafeArea()

            VStack {
                statusBar
                Spacer()
                controls
            }
            .padding()

            if capture.permissionDenied {
                permissionOverlay
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if capture.isRecordingClip {
                Circle().fill(.red).frame(width: 12, height: 12)
                Text("Recording").bold()
            } else if coordinator.isSessionActive {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("AUTO")
            } else {
                Text("Idle")
            }
            Spacer()
            Label("\(capture.puttCount)", systemImage: "figure.golf")
                .bold()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(alignment: .bottom) { motionMeter.offset(y: 14) }
    }

    private var motionMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.25))
                Capsule()
                    .fill(capture.motionLevel > Float(settings.motionThreshold) ? .red : .green)
                    .frame(width: geo.size.width * meterFraction)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 24)
    }

    private var meterFraction: CGFloat {
        // Scale relative to twice the threshold for a readable meter.
        let denom = max(0.0001, Float(settings.motionThreshold) * 2)
        return CGFloat(min(1, capture.motionLevel / denom))
    }

    private var controls: some View {
        VStack(spacing: 16) {
            if coordinator.isSessionActive {
                Button {
                    capture.forceRecord()
                } label: {
                    Label("Record a putt now", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            Button {
                if coordinator.isSessionActive {
                    coordinator.endSession()
                } else {
                    coordinator.startSession()
                }
            } label: {
                Text(coordinator.isSessionActive ? "End Session" : "Start Session")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(coordinator.isSessionActive ? .red : .green)
        }
        .padding(.bottom)
    }

    private var permissionOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill").font(.largeTitle)
            Text("Camera access is required")
                .font(.headline)
            Text("Enable camera access in Settings to record putts.")
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }
}
