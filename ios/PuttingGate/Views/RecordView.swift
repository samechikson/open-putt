import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var recorder: CameraRecorder

    var body: some View {
        ZStack {
            CameraPreview(session: recorder.captureSession)
                .ignoresSafeArea()

            VStack {
                if recorder.isRecording {
                    recordingIndicator
                }
                Spacer()
                recordButton
            }
            .padding()

            if recorder.permissionDenied {
                permissionOverlay
            }
        }
    }

    private var recordingIndicator: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 12, height: 12)
            Text("Recording").bold()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stopRecording()
            } else {
                recorder.startRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: recorder.isRecording ? 6 : 30)
                    .fill(.red)
                    .frame(
                        width: recorder.isRecording ? 32 : 60,
                        height: recorder.isRecording ? 32 : 60
                    )
                    .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom)
        .disabled(recorder.permissionDenied)
    }

    private var permissionOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill").font(.largeTitle)
            Text("Camera access is required")
                .font(.headline)
            Text("Enable camera access in Settings to record videos.")
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
