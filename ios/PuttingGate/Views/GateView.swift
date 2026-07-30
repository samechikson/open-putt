import SwiftUI

/// The "Gate" tab: finds the ESP32 gate over Bluetooth, connects, and shows
/// putts live as they roll (relaying each to the backend under the user's login).
struct GateView: View {
    @EnvironmentObject private var gate: GateConnection
    @EnvironmentObject private var recorder: CameraRecorder

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
        .onAppear { gate.startScan() }
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
            // Aim the phone at the gate — the last ~2 s before each putt is saved.
            CameraPreview(session: recorder.captureSession)
                .frame(height: 220)
                .clipped()
                .overlay(alignment: .topLeading) { filmingIndicator }
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

    private var filmingIndicator: some View {
        HStack(spacing: 5) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("Filming").font(.caption2)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(8)
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
            HStack(spacing: 10) {
                videoBadge(received.video)
                relayBadge(received.relay)
            }
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

    /// Review-clip status, shown with a film icon so it reads apart from the
    /// putt-relay checkmark.
    @ViewBuilder
    private func videoBadge(_ status: VideoStatus) -> some View {
        switch status {
        case .none:
            EmptyView()
        case .uploading:
            Image(systemName: "video.badge.ellipsis").foregroundStyle(.secondary)
        case .done:
            Image(systemName: "video.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "video.slash.fill").foregroundStyle(.orange)
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
