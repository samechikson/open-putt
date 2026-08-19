import SwiftUI
import UIKit

/// The "Gate" tab: finds the ESP32 gate over Bluetooth, connects, and shows
/// putts live as they roll (relaying each to the backend under the user's login).
struct GateView: View {
    @EnvironmentObject private var gate: GateConnection
    @EnvironmentObject private var config: SessionConfigStore
    @EnvironmentObject private var calibration: CalibrationStore

    @State private var ringSpin = false
    @State private var showingCalibration = false
    @State private var deleteError: String?

    var body: some View {
        VStack(spacing: 0) {
            PGHeader("Gate")
            Group {
                switch gate.state {
                case .connected:
                    liveView
                case .poweredOff:
                    statusView(
                        icon: "bolt.horizontal.circle",
                        title: "Bluetooth is off",
                        detail: "Turn on Bluetooth to connect to your putting gate."
                    )
                case .unauthorized:
                    statusView(
                        icon: "exclamationmark.triangle",
                        title: "Bluetooth access needed",
                        detail: "Allow Bluetooth for PuttingGate in Settings to connect to your gate."
                    )
                default:
                    discoveryView
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pgScreenBackground()
        .tint(.pgAccent)
        .task { await config.loadPutters() }
        .onAppear {
            gate.startScan()
            // Keep the screen (and thus the app + camera) awake during a session,
            // so putts and clips aren't dropped when the phone would auto-lock.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: Discovery / connect

    private var discoveryView: some View {
        ScrollView {
            VStack(spacing: 20) {
                seekingBadge
                VStack(spacing: 4) {
                    Text("Looking for your gate…")
                        .font(.pgHeading(20, relativeTo: .title3))
                        .foregroundStyle(Color.pgText)
                    Text("Power on the gate and keep it nearby.")
                        .font(.pgBody(13))
                        .foregroundStyle(Color.pgNeutral700)
                }

                if !gate.discovered.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(gate.discovered.enumerated()), id: \.element.id) { index, found in
                            Button { gate.connect(found) } label: {
                                HStack(spacing: 12) {
                                    PGGlyph(barColor: .pgAccent700, dashColor: .pgAccent2_500)
                                        .frame(width: 20, height: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(found.name)
                                            .font(.pgBody(15, weight: .semibold))
                                            .foregroundStyle(Color.pgText)
                                        Text(signalLabel(found.rssi))
                                            .font(.pgBody(12))
                                            .foregroundStyle(Color.pgNeutral700)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.pgNeutral500)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if index < gate.discovered.count - 1 { PGDivider() }
                        }
                    }
                    .pgCard()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 24)
        }
    }

    /// The pulsing "seeking" mark: the gate glyph inside a sage disc ringed by a
    /// slowly rotating dashed circle.
    private var seekingBadge: some View {
        ZStack {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [4, 6]))
                .foregroundStyle(Color.pgAccent2_300)
                .frame(width: 124, height: 124)
                .rotationEffect(.degrees(ringSpin ? 360 : 0))
                .animation(.linear(duration: 14).repeatForever(autoreverses: false), value: ringSpin)
            Circle()
                .fill(Color.pgAccent2_100)
                .frame(width: 104, height: 104)
            PGGlyph(barColor: .pgAccent2_700, dashColor: .pgAccent2_500)
                .frame(width: 46, height: 46)
        }
        .onAppear { ringSpin = true }
    }

    // MARK: Live putts

    private var liveView: some View {
        ScrollView {
            VStack(spacing: 14) {
                connectionPill
                calibrationCard
                sessionSetup
                if let latest = gate.putts.first {
                    latestPutt(latest.putt)
                }
                if gate.putts.isEmpty {
                    readyCard
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        PGSectionHeader("This session")
                        sessionPutts
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showingCalibration) { CalibrationView() }
    }

    private var connectionPill: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.pgAccent2_500).frame(width: 8, height: 8)
            Text("Connected to \(gate.connectedName ?? "gate")")
                .font(.pgBody(14))
                .foregroundStyle(Color.pgText)
            Spacer()
            Button("Disconnect") { gate.disconnect() }
                .buttonStyle(PGGhostButtonStyle(size: 13))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .pgCard()
    }

    // MARK: Center calibration

    /// Status of the center calibration, with a button to (re)capture it and, when
    /// one is set, to clear it. Applied to every putt so centered rolls read ~0.
    private var calibrationCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "scope")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(calibration.active != nil ? Color.pgAccent2_600 : Color.pgNeutral500)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Center calibration")
                        .font(.pgBody(15, weight: .semibold))
                        .foregroundStyle(Color.pgText)
                    Text(calibrationSubtitle)
                        .font(.pgBody(12))
                        .foregroundStyle(Color.pgNeutral700)
                }
                Spacer()
                Button(calibration.active != nil ? "Recalibrate" : "Calibrate") {
                    showingCalibration = true
                }
                .buttonStyle(PGGhostButtonStyle(size: 13))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if calibration.active != nil {
                PGDivider()
                Button { calibration.clear() } label: {
                    HStack {
                        Text("Clear calibration")
                            .font(.pgBody(13, weight: .semibold))
                            .foregroundStyle(Color.pgAccent700)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .pgCard()
    }

    private var calibrationSubtitle: String {
        guard let cal = calibration.active else { return "Not set — readings are raw" }
        let rolls = "\(cal.sampleCount) roll\(cal.sampleCount == 1 ? "" : "s")"
        let date = cal.capturedAt.formatted(date: .abbreviated, time: .omitted)
        return "\(rolls) · \(date)"
    }

    // MARK: Session setup

    /// Dropdowns to tag the session — the putter used, the putt length, and the
    /// break. Chosen before rolling; applied to the session once the gate starts
    /// it (its first putt). Changing the putter mid-session re-tags the active
    /// session; changing the length or break starts a new session for the putts
    /// that follow.
    private var sessionSetup: some View {
        VStack(spacing: 0) {
            setupRow(label: "Putter") {
                Picker("Putter", selection: $config.selectedPutterId) {
                    Text("None").tag(String?.none)
                    ForEach(config.putters) { putter in
                        Text(putter.isActive ? "\(putter.name) (active)" : putter.name)
                            .tag(Optional(putter.id))
                    }
                }
            }
            PGDivider()
            setupRow(label: "Length") {
                Picker("Length", selection: $config.lengthFeet) {
                    Text("Not set").tag(Int?.none)
                    ForEach(sessionLengthOptionsFeet, id: \.self) { feet in
                        Text("\(feet) ft").tag(Optional(feet))
                    }
                }
            }
            PGDivider()
            setupRow(label: "Break") {
                Picker("Break", selection: $config.breakType) {
                    Text("Not set").tag(String?.none)
                    ForEach(BreakOption.all) { option in
                        Text(option.label).tag(Optional(option.value))
                    }
                }
            }
        }
        .pgCard()
        // A putter change re-tags the live session; a length or break change
        // starts a new session for the putts that follow.
        .onChange(of: config.selectedPutterId) { gate.reapplyMetadata() }
        .onChange(of: config.lengthFeet) { gate.startNewSession() }
        .onChange(of: config.breakType) { gate.startNewSession() }
    }

    /// A labeled row holding a menu-style picker (value on the right).
    private func setupRow<P: View>(
        label: String, @ViewBuilder _ picker: () -> P
    ) -> some View {
        HStack {
            Text(label)
                .font(.pgBody(15))
                .foregroundStyle(Color.pgNeutral700)
            Spacer()
            picker()
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.pgAccent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: Latest putt

    private func latestPutt(_ putt: GatePutt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PGSectionHeader("Latest putt")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(putt.magnitudeMm, specifier: "%.1f") mm")
                    .font(.pgHeading(40, relativeTo: .largeTitle))
                    .foregroundStyle(Color.pgText)
                PGTag(biasTag(putt), style: putt.golferSide == .center ? .accent2 : .accent)
            }
            HStack(spacing: 16) {
                if let speed = putt.speedMps {
                    Text("\(speed, specifier: "%.2f") m/s")
                        .font(.pgBody(13))
                        .foregroundStyle(Color.pgNeutral700)
                }
                sensorDots(putt.sensors)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .pgCard()
    }

    private var sessionPutts: some View {
        VStack(spacing: 0) {
            ForEach(Array(gate.putts.enumerated()), id: \.element.id) { index, received in
                puttRow(received)
                if index < gate.putts.count - 1 { PGDivider() }
            }
        }
        .pgCard()
        .alert(
            "Couldn't delete putt",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func puttRow(_ received: ReceivedPutt) -> some View {
        let putt = received.putt
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(putt.golferSideLabel) · \(putt.magnitudeMm, specifier: "%.1f") mm")
                    .font(.pgBody(15, weight: .semibold))
                    .foregroundStyle(Color.pgText)
                if let speed = putt.speedMps {
                    Text("\(speed, specifier: "%.2f") m/s")
                        .font(.pgBody(12))
                        .foregroundStyle(Color.pgNeutral700)
                }
            }
            Spacer()
            relayBadge(received.relay)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        // Long-press to remove a mishit or a false trip from the session. The
        // deletion is permanent (backend + local), so it's a deliberate,
        // red-styled action rather than a stray swipe.
        .contextMenu {
            Button("Delete putt", systemImage: "trash", role: .destructive) {
                Task {
                    do { try await gate.deletePutt(received) }
                    catch { deleteError = error.localizedDescription }
                }
            }
        }
    }

    @ViewBuilder
    private func relayBadge(_ status: RelayStatus) -> some View {
        switch status {
        case .sending:
            ProgressView().controlSize(.small)
        case .sent:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.pgAccent2_600)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.pgAccent)
        }
    }

    private var readyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.golf")
                .font(.system(size: 34))
                .foregroundStyle(Color.pgAccent2_600)
            Text("Ready")
                .font(.pgHeading(20, relativeTo: .title3))
                .foregroundStyle(Color.pgText)
            Text("Roll a putt through the gate.")
                .font(.pgBody(13))
                .foregroundStyle(Color.pgNeutral700)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .pgCard()
    }

    // MARK: Status states

    private func statusView(icon: String, title: String, detail: String) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundStyle(Color.pgAccent)
                Text(title)
                    .font(.pgHeading(20, relativeTo: .title3))
                    .foregroundStyle(Color.pgText)
                Text(detail)
                    .font(.pgBody(14))
                    .foregroundStyle(Color.pgNeutral700)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(28)
            .pgCard()
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: Helpers

    /// The tag next to the latest putt, e.g. "Push · Right" (a right miss is a
    /// push; a left miss a pull). Dead-center putts read simply "Center".
    private func biasTag(_ putt: GatePutt) -> String {
        switch putt.golferSide {
        case .right: return "Push · Right"
        case .left: return "Pull · Left"
        case .center: return "Center"
        }
    }

    /// One dot per gate sensor — sage when that sensor saw the ball. Every shown
    /// putt tripped all its sensors (see `GatePutt.hasAllSensors`), so these read
    /// as a compact "clean pass" indicator.
    @ViewBuilder
    private func sensorDots(_ sensors: [Double?]?) -> some View {
        if let sensors, !sensors.isEmpty {
            HStack(spacing: 5) {
                ForEach(Array(sensors.enumerated()), id: \.offset) { _, value in
                    Circle()
                        .fill(value == nil ? Color.pgNeutral400 : Color.pgAccent2_500)
                        .frame(width: 7, height: 7)
                }
            }
        }
    }

    private func signalLabel(_ rssi: Int) -> String {
        // RSSI is negative; closer to 0 = stronger.
        switch rssi {
        case (-55)...0: return "Strong signal"
        case (-70)..<(-55): return "Good signal"
        default: return "Weak signal"
        }
    }
}
