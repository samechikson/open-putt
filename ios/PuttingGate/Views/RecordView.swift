import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var recorder: CameraRecorder
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var captureTest = CaptureTestModel()

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
                if captureTest.state != .idle {
                    captureTestCard
                }
                if !recorder.isRecording {
                    exposureControl
                    captureTestButton
                }
                recordButton
            }
            .padding()

            if recorder.permissionDenied {
                permissionOverlay
            }
        }
        .sheet(isPresented: $showLengthPicker) { lengthPickerSheet }
    }

    // MARK: Exposure

    private var exposureControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
            Slider(
                value: exposureBinding,
                in: AppSettings.exposureBiasRange,
                step: AppSettings.exposureBiasStep
            )
            Text(String(format: "%+.1f EV", settings.exposureBias))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var exposureBinding: Binding<Double> {
        Binding(
            get: { settings.exposureBias },
            set: { newValue in
                settings.exposureBias = newValue
                recorder.setExposureBias(newValue)
            }
        )
    }

    // MARK: Capture test

    private var captureTestButton: some View {
        Button {
            captureTest.run(
                url: settings.calibrationCheckURL,
                frame: recorder.captureTestFrame()
            )
        } label: {
            Label("Capture test", systemImage: "checkmark.seal")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(recorder.permissionDenied)
    }

    @ViewBuilder
    private var captureTestCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch captureTest.state {
            case .idle:
                EmptyView()
            case .checking:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking the scene…")
                }
            case let .result(verdict):
                checkRow(label: "Laser gate", found: verdict.gateFound)
                checkRow(label: "Ball at address", found: verdict.ballFound)
                Text(verdict.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case let .failed(message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            Button {
                captureTest.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
    }

    private func checkRow(label: String, found: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: found ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(found ? .green : .red)
            Text(label).font(.subheadline)
        }
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
