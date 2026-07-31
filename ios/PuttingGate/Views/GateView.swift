import SwiftUI
import UIKit

/// The "Gate" tab: finds the ESP32 gate over Bluetooth, connects, and shows
/// putts live as they roll (relaying each to the backend under the user's login).
struct GateView: View {
    @EnvironmentObject private var gate: GateConnection
    @EnvironmentObject private var config: SessionConfigStore

    var body: some View {
        NavigationStack {
            Group {
                switch gate.state {
                case .connected:
                    liveView
                case .poweredOff:
                    statusMessage(
                        icon: "bolt.horizontal.circle",
                        title: "Bluetooth is off",
                        detail: "Turn on Bluetooth to connect to your putting gate."
                    )
                case .unauthorized:
                    statusMessage(
                        icon: "exclamationmark.triangle",
                        title: "Bluetooth access needed",
                        detail: "Allow Bluetooth for PuttingGate in Settings to connect to your gate."
                    )
                default:
                    discoveryView
                }
            }
            .navigationTitle("Gate")
        }
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
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
            Text("Looking for your gate…")
                .font(.headline)
            Text("Power on the gate and keep it nearby.")
                .font(.caption).foregroundStyle(.secondary)

            if !gate.discovered.isEmpty {
                List(gate.discovered) { found in
                    Button { gate.connect(found) } label: {
                        HStack {
                            Image(systemName: "sensor.tag.radiowaves.forward")
                            VStack(alignment: .leading) {
                                Text(found.name)
                                Text(signalLabel(found.rssi))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            Spacer()
        }
        .padding()
    }

    // MARK: Live putts

    private var liveView: some View {
        VStack(spacing: 0) {
            connectionPill
            sessionSetup
            if gate.putts.isEmpty {
                ContentUnavailableView(
                    "Ready",
                    systemImage: "figure.golf",
                    description: Text("Roll a putt through the gate.")
                )
            } else {
                List(gate.putts) { received in
                    puttRow(received)
                }
            }
        }
    }

    // MARK: Session setup

    /// Dropdowns to tag the session — the putter used, the putt length, and the
    /// break. Chosen before rolling; applied to the session once the gate starts
    /// it (its first putt). Changing one mid-session re-tags the active session.
    private var sessionSetup: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Session")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let error = config.loadError {
                    Text(error)
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            setupRow(label: "Putter") {
                Picker("Putter", selection: $config.selectedPutterId) {
                    Text("None").tag(String?.none)
                    ForEach(config.putters) { putter in
                        Text(putter.isActive ? "\(putter.name) (active)" : putter.name)
                            .tag(Optional(putter.id))
                    }
                }
            }
            setupRow(label: "Length") {
                Picker("Length", selection: $config.lengthFeet) {
                    Text("Not set").tag(Int?.none)
                    ForEach(sessionLengthOptionsFeet, id: \.self) { feet in
                        Text("\(feet) ft").tag(Optional(feet))
                    }
                }
            }
            setupRow(label: "Break") {
                Picker("Break", selection: $config.breakType) {
                    Text("Not set").tag(String?.none)
                    ForEach(BreakOption.all) { option in
                        Text(option.label).tag(Optional(option.value))
                    }
                }
            }
        }
        .padding()
        .background(.thinMaterial)
        // Re-tag the live session if a pick changes after putts have started.
        .onChange(of: config.selectedPutterId) { gate.reapplyMetadata() }
        .onChange(of: config.lengthFeet) { gate.reapplyMetadata() }
        .onChange(of: config.breakType) { gate.reapplyMetadata() }
    }

    /// A labeled row holding a menu-style picker (value on the right).
    private func setupRow<P: View>(
        label: String, @ViewBuilder _ picker: () -> P
    ) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            picker()
                .pickerStyle(.menu)
                .labelsHidden()
        }
        .font(.subheadline)
    }

    private var connectionPill: some View {
        HStack {
            Circle().fill(.green).frame(width: 8, height: 8)
            Text("Connected to \(gate.connectedName ?? "gate")")
                .font(.subheadline)
            Spacer()
            Button("Disconnect") { gate.disconnect() }
                .font(.subheadline)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private func puttRow(_ received: ReceivedPutt) -> some View {
        let putt = received.putt
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(putt.golferSideLabel) · \(putt.magnitudeMm, specifier: "%.1f") mm")
                    .font(.headline)
                HStack(spacing: 8) {
                    if let speed = putt.speedMps {
                        Text("\(speed, specifier: "%.2f") m/s")
                    }
                    if let sensors = putt.sensors {
                        Text(sensorSummary(sensors))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            relayBadge(received.relay)
        }
    }

    @ViewBuilder
    private func relayBadge(_ status: RelayStatus) -> some View {
        switch status {
        case .sending:
            ProgressView()
        case .sent:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }

    // MARK: Helpers

    private func statusMessage(icon: String, title: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(detail))
    }

    private func signalLabel(_ rssi: Int) -> String {
        // RSSI is negative; closer to 0 = stronger.
        switch rssi {
        case (-55)...0: return "Strong signal"
        case (-70)..<(-55): return "Good signal"
        default: return "Weak signal"
        }
    }

    /// The per-sensor offsets in the golfer's frame, e.g. "+6.1 / +5.9 / +6.0"
    /// (+ = right). The raw device sign is already the golfer's frame (see
    /// `GatePutt.golferSide`), so show it directly. A sensor with no reading
    /// shows a dash.
    private func sensorSummary(_ sensors: [Double?]) -> String {
        sensors.map { value in
            guard let value else { return "—" }
            let sign = value > 0 ? "+" : (value < 0 ? "−" : "")
            return sign + String(format: "%.1f", abs(value))
        }
        .joined(separator: " / ")
    }
}
