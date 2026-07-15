import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var recorder: CameraRecorder
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var auth: AuthManager
    @StateObject private var captureTest = CaptureTestModel()
    @StateObject private var putters = PuttersModel()
    @Environment(\.scenePhase) private var scenePhase

    @State private var lengthFeet = 9
    @State private var breakType: PuttBreak = .straight
    @State private var showLengthPicker = false
    /// The putter to tag this session with; defaults to the user's active putter
    /// once the list loads, and is then left to the user's choice.
    @State private var selectedPutterID: String?
    @State private var hasDefaultedPutter = false

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
                if !recorder.isRecording {
                    if captureTest.state != .idle {
                        captureTestCard
                    }
                    exposureControl
                }
                recordButton
            }
            .padding()

            if recorder.permissionDenied {
                permissionOverlay
            }
        }
        .sheet(isPresented: $showLengthPicker) { lengthPickerSheet }
        .task { await loadPutters() }
        // Auto-calibration: keep pre-flighting the scene while lining up so the
        // user records something that will actually analyze. The loop self-stops
        // once a check passes; these events re-arm it.
        .onAppear { startAutoIfPossible() }
        .onDisappear { captureTest.stopAuto() }
        .onChange(of: recorder.isRecording) { _, isRecording in
            if isRecording { captureTest.stopAuto() } else { startAutoIfPossible() }
        }
        .onChange(of: recorder.permissionDenied) { _, _ in startAutoIfPossible() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                startAutoIfPossible()
                // Pick up putters added/activated elsewhere (e.g. on the web).
                Task { await loadPutters() }
            } else {
                captureTest.stopAuto()
            }
        }
    }

    /// Load the user's putters and, the first time they arrive, default the
    /// selection to their active putter. Once defaulted (or once the user picks
    /// one), later refreshes leave the choice alone.
    private func loadPutters() async {
        await putters.load(url: settings.puttersURL, auth: auth)
        if !hasDefaultedPutter, let active = putters.active {
            selectedPutterID = active.id
            hasDefaultedPutter = true
        }
    }

    /// Start (or re-arm) the auto-calibration loop when the scene is in a state
    /// to check: camera available and not currently recording.
    private func startAutoIfPossible() {
        guard !recorder.permissionDenied, !recorder.isRecording else { return }
        captureTest.startAuto(
            url: settings.calibrationCheckURL,
            auth: auth,
            frameProvider: { [weak recorder] in recorder?.captureTestFrame() }
        )
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
                if verdict.ok {
                    Label("Ready to record", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
                checkRow(label: "Laser gate", found: verdict.gateFound)
                checkRow(label: "Ball at address", found: verdict.ballFound)
                Text(verdict.ok ? "Tap to re-check." : verdict.message)
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
            if captureTest.isRefreshing {
                ProgressView().padding(8)
            }
        }
        // Tap anywhere on the card to force an immediate re-check.
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { startAutoIfPossible() }
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

            Menu {
                Picker("Putter", selection: $selectedPutterID) {
                    Text("None").tag(String?.none)
                    ForEach(putters.putters) { putter in
                        Text(putter.name).tag(String?.some(putter.id))
                    }
                }
            } label: {
                infoField(label: "Putter", value: selectedPutterName)
            }
            .disabled(putters.putters.isEmpty)
        }
        .disabled(recorder.isRecording)
        .opacity(recorder.isRecording ? 0.5 : 1)
    }

    /// Display name for the selected putter, falling back to a placeholder when
    /// none is chosen (or the user hasn't set any putters up yet).
    private var selectedPutterName: String {
        putters.putters.first { $0.id == selectedPutterID }?.name ?? "None"
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
                recorder.startRecording(
                    lengthFeet: lengthFeet,
                    breakType: breakType,
                    putterID: selectedPutterID
                )
            }
        } label: {
            ZStack {
                // Ring turns green when the latest auto-check says the scene is
                // ready — advisory only; the button stays tappable regardless.
                Circle()
                    .stroke(captureTest.isReady ? Color.green : .white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                    .animation(.easeInOut(duration: 0.2), value: captureTest.isReady)
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
