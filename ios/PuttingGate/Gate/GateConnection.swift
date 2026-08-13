import Foundation
import CoreBluetooth

/// Relay status for a single received putt.
enum RelayStatus: Equatable {
    case sending
    case sent
    case failed(String)
}

/// A putt received over BLE, plus its backend-relay status (for the live view).
struct ReceivedPutt: Identifiable {
    let putt: GatePutt
    var relay: RelayStatus = .sending
    var id: String { putt.id }
}

/// Connects to the ESP32 putting gate over BLE (as a central), receives each
/// putt as a notification, shows it live, and relays it to the backend.
///
/// The `CBCentralManager` is created on the main queue, so all delegate
/// callbacks — and thus every `@Published` mutation — happen on the main thread,
/// which is what SwiftUI requires. The only off-main work is the async relay,
/// whose status update hops back to the main actor.
final class GateConnection: NSObject, ObservableObject {

    // Must match the firmware (putt_tracker.ino).
    private static let serviceUUID = CBUUID(string: "6b1a0001-8c2f-4d3a-9e5b-1f2c3d4e5f60")
    private static let puttCharUUID = CBUUID(string: "6b1a0002-8c2f-4d3a-9e5b-1f2c3d4e5f60")

    enum State: Equatable {
        case poweredOff      // Bluetooth is off
        case unauthorized    // user denied Bluetooth permission
        case scanning        // looking for a gate
        case connecting
        case connected
        case disconnected    // idle / no gate found yet
    }

    /// One discovered gate while scanning.
    struct DiscoveredGate: Identifiable {
        let peripheral: CBPeripheral
        let name: String
        let rssi: Int
        var id: UUID { peripheral.identifier }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var discovered: [DiscoveredGate] = []
    @Published private(set) var putts: [ReceivedPutt] = []
    @Published private(set) var connectedName: String?
    /// The backend session id the current run of putts is being relayed under.
    /// Usually this is the id the firmware mints and stamps on every putt, but a
    /// mid-run change to the putt length or break splits the run into a fresh
    /// session (see `startNewSession()`), so this can diverge from the firmware's
    /// id. Tracked so we can tag the session and re-tag it on a putter change.
    @Published private(set) var activeSessionId: String?

    private var central: CBCentralManager!
    private var gate: CBPeripheral?
    private let relay: GatePuttRelay
    private let config: SessionConfigStore
    private let decoder = JSONDecoder()

    /// The firmware session id of the last putt seen. When the next putt carries a
    /// different id the gate has started a new run (a genuinely new session).
    private var firmwareSessionId: String?
    /// Set when the player changes the length or break mid-run: the next putt
    /// should open a new backend session so the new selection describes a clean
    /// split rather than re-tagging putts already rolled.
    private var startNewSessionRequested = false

    init(settings: AppSettings, auth: AuthManager, config: SessionConfigStore) {
        self.relay = GatePuttRelay(settings: settings, auth: auth)
        self.config = config
        super.init()
        // nil queue → callbacks are delivered on the main thread.
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Re-tag the active session with the player's current selection — called
    /// when they change the putter after putts have already started. No-op until a
    /// session exists.
    func reapplyMetadata() {
        guard let sessionId = activeSessionId else { return }
        Task { await config.apply(to: sessionId) }
    }

    /// Begin a new session for subsequent putts — called when the player changes
    /// the putt length or break. Before the first putt there's nothing to split:
    /// the pending selection simply tags the session the gate is about to create.
    /// Once a session is active, the next putt opens a fresh backend session
    /// carrying the new selection, so a run at a new length/break is recorded
    /// separately from what came before. No empty session is created if no further
    /// putt is rolled.
    func startNewSession() {
        guard activeSessionId != nil else { return }
        startNewSessionRequested = true
    }

    // MARK: Intent

    /// Start (or restart) scanning for a gate. Safe to call repeatedly.
    ///
    /// Scans without a service filter and matches in `didDiscover` (by advertised
    /// UUID or name) instead of `scanForPeripherals(withServices:)`. ESP32s often
    /// can't fit a 128-bit UUID *and* the name in the 31-byte advertisement, so a
    /// UUID-filtered scan can miss the gate; matching by name too is robust.
    func startScan() {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: nil)
    }

    func connect(_ found: DiscoveredGate) {
        central.stopScan()
        gate = found.peripheral
        found.peripheral.delegate = self
        connectedName = found.name
        state = .connecting
        central.connect(found.peripheral)
    }

    func disconnect() {
        if let gate { central.cancelPeripheralConnection(gate) }
    }

    // MARK: Relay

    private func relayPutt(_ putt: GatePutt, json: Data, sessionId: String, tagSession: Bool) {
        // The BLE payload is the exact `/device/putts` body, relayed verbatim —
        // except when we've split the firmware's run into a new session, where the
        // outgoing session id must be swapped for the one we minted.
        let body = Self.rewritingSessionId(in: json, from: putt.sessionID, to: sessionId)
        Task {
            do {
                try await relay.send(body)
                await MainActor.run { self.setStatus(putt.id, .sent) }
                // The session row is created backend-side by its first putt, so
                // only now — once that putt is saved — can we tag the session
                // with the player's chosen putter / length / break.
                if tagSession {
                    await config.apply(to: sessionId)
                }
            } catch {
                await MainActor.run {
                    self.setStatus(putt.id, .failed(error.localizedDescription))
                }
            }
        }
    }

    /// Return the putt JSON with its `session_id` swapped to `to`, or the bytes
    /// unchanged when the ids already match (the common, verbatim-relay case).
    private static func rewritingSessionId(in json: Data, from: String, to: String) -> Data {
        guard from != to,
              var obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        else { return json }
        obj["session_id"] = to
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? json
    }

    private func setStatus(_ id: String, _ status: RelayStatus) {
        if let idx = putts.firstIndex(where: { $0.id == id }) {
            putts[idx].relay = status
        }
    }
}

extension GateConnection: CBCentralManagerDelegate, CBPeripheralDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: startScan()
        case .poweredOff: state = .poweredOff
        case .unauthorized: state = .unauthorized
        default: state = .disconnected
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        // Only our gate: it advertises our service UUID and/or the name.
        let advUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let isGate = advUUIDs.contains(Self.serviceUUID) || advName == "PuttingGate"
        guard isGate else { return }

        let name = advName ?? "Putting gate"
        let found = DiscoveredGate(peripheral: peripheral, name: name, rssi: RSSI.intValue)
        if let idx = discovered.firstIndex(where: { $0.id == found.id }) {
            discovered[idx] = found
        } else {
            discovered.append(found)
        }
        // Auto-connect when exactly one gate is visible.
        if discovered.count == 1 { connect(found) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        gate = nil
        connectedName = nil
        startScan()
    }

    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        gate = nil
        connectedName = nil
        state = .disconnected
        startScan()   // try to find it again
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID })
        else { return }
        peripheral.discoverCharacteristics([Self.puttCharUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == Self.puttCharUUID })
        else { return }
        peripheral.setNotifyValue(true, for: ch)   // subscribe to putt notifications
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard let data = characteristic.value,
              let putt = try? decoder.decode(GatePutt.self, from: data)
        else { return }
        // Ignore errant reads: a real putt trips every sensor, so a partial
        // reading (some sensor missing) is dropped here — not shown, not relayed,
        // and never treated as the start of a session. Mirrors the firmware and
        // backend guards.
        guard putt.hasAllSensors else { return }
        // A new session starts when the gate begins a new run (a putt bearing a
        // firmware session id we haven't seen) or when the player changed the
        // length/break mid-run (`startNewSessionRequested`).
        let firmwareChanged = putt.sessionID != firmwareSessionId
        firmwareSessionId = putt.sessionID
        let isNewSession = firmwareChanged || startNewSessionRequested
        if isNewSession {
            // A fresh firmware run already carries a new session id we can relay
            // verbatim; a mid-run length/break split has none, so mint one.
            activeSessionId = (startNewSessionRequested && !firmwareChanged)
                ? UUID().uuidString.lowercased()
                : putt.sessionID
            startNewSessionRequested = false
            putts.removeAll()   // "This session" begins fresh
        }
        putts.insert(ReceivedPutt(putt: putt), at: 0)   // newest first
        relayPutt(putt, json: data, sessionId: activeSessionId ?? putt.sessionID,
                  tagSession: isNewSession)
    }
}
