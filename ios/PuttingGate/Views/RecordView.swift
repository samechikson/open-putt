import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var recorder: CameraRecorder

    @State private var lengthFeet = 9
    @State private var breakType: PuttBreak = .straight
    @State private var showLengthPicker = false

    private let lengthRange = Array(stride(from: 3, through: 60, by: 3))

    var body: some View {
        ZStack {
            CameraPreview(session: recorder.captureSession)
                .ignoresSafeArea()

            VStack {
                puttInfoBar
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
        .sheet(isPresented: $showLengthPicker) { lengthPickerSheet }
    }

    // MARK: Putt info

    private var puttInfoBar: some View {
        HStack(spacing: 10) {
            Button {
                showLengthPicker = true
            } label: {
                infoField(label: "Length", value: "\(lengthFeet) ft")
            }

            Menu {
                Picker("Break", selection: $breakType) {
                    ForEach(PuttBreak.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
            } label: {
                infoField(label: "Break", value: breakType.displayName)
            }
        }
        .disabled(recorder.isRecording)
        .opacity(recorder.isRecording ? 0.5 : 1)
    }

    private func infoField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var lengthPickerSheet: some View {
        NavigationStack {
            Picker("Length", selection: $lengthFeet) {
                ForEach(lengthRange, id: \.self) { feet in
                    Text("\(feet) ft").tag(feet)
                }
            }
            .pickerStyle(.wheel)
            .navigationTitle("Putt length")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLengthPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: Recording controls

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
                recorder.startRecording(lengthFeet: lengthFeet, breakType: breakType)
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
