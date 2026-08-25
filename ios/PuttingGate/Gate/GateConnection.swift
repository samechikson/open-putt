import Foundation
import CoreBluetooth

/// Relay status for a single received putt.
enum RelayStatus: Equatable {
    case sending
    case sent
    case failed(String)
}

/// A putt received over BLE, plus its persist status (for the live view).
struct ReceivedPutt: Identifiable {
    let putt: GatePutt
    /// The session id this putt was saved under. Usually the firmware's session
    /// id, but a mid-run length/break split saves under a freshly minted id (see
    /// `GateConnection`), so it's captured per-putt so a delete targets the right
    /// session.
    let sessionId: String
    var relay: RelayStatus = .sending
    var id: String { putt.id }
}

/// Connects to the ESP32 putting gate over BLE (as a central), receives each
/// putt as a notification, shows it live, and persists it to Firestore.
///
/// The `CBCentralManager` is created on the main queue, so all delegate
/// callbacks — and thus every `@Published` mutation — happen on the main thread,
/// which is what SwiftUI requires. The only off-main work is the async Firestore
/// write, whose status update hops back to the main actor.
final class GateConnection: NSObject, ObservableObject {

    // Must match the firmware (putt_tracker.ino).
    private static let serviceUUID = CBUUID(string: "6b1a0001-8c2f-4d3a-9e5b-1f2c3d4e5f60")
    private static let puttCharUUID = CBUUID(string: "6b1a0002-8c2f-4d3a-9e5b-1f2c3d4e5f60")

    /// Cap on the in-memory live putt feed. Newest are kept; older ones fall off
    /// the on-screen list (they remain persisted server-side).
    private static let maxLivePutts = 100

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
    private let service: SessionMetadataService
    private let config: SessionConfigStore
    private let calibration: CalibrationStore
    private let decoder = JSONDecoder()

    /// The firmware session id of the last putt seen. When the next putt carries a
    /// different id the gate has started a new run (a genuinely new session).
    private var firmwareSessionId: String?
    /// Set when the player changes the length or break mid-run: the next putt
    /// should open a new backend session so the new selection describes a clean
    /// split rather than re-tagging putts already rolled.
    private var startNewSessionRequested = false

    init(
        config: SessionConfigStore, calibration: CalibrationStore,
        service: SessionMetadataService
    ) {
        self.service = service
        self.config = config
        self.calibration = calibration
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
    ///
    /// The screen clears immediately so the previous session's putts aren't shown
    /// against the new selection — the live view drops back to its "ready" state
    /// until the first putt of the new session rolls.
    func startNewSession() {
        guard activeSessionId != nil else { return }
        startNewSessionRequested = true
        putts.removeAll()
    }

    // MARK: Intent

    /// Start (or restart) scanning for a gate. Safe to call repeatedly.
    ///
    /// Filters on the gate's service UUID. The firmware puts that UUID in the
    /// primary advertisement (and the name in the scan response) precisely so a
    /// UUID-filtered scan finds it — see `putt_tracker.ino`'s `startBLE`. Filtering
    /// is important: an unfiltered (`nil`) scan surfaces and retains an object for
    /// every advertising BLE device nearby, continuously, which steadily grows the
    /// app's memory while the Gate tab is left open (the screen is kept awake).
    func startScan() {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID])
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

    /// Persist a received putt to Firestore under the signed-in user. The session
    /// is created (already complete) by its first putt, so only once that putt is
    /// saved do we tag the session with the player's chosen putter / length /
    /// break. `corrected` already carries any session split (`sessionId`) and
    /// center calibration — the ingest handles the stored sign convention.
    private func relayPutt(_ putt: GatePutt, sessionId: String, tagSession: Bool) {
        Task {
            do {
                try await service.ingest(putt, sessionId: sessionId)
                await MainActor.run { self.setStatus(putt.id, .sent) }
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

    private func setStatus(_ id: String, _ status: RelayStatus) {
        if let idx = putts.firstIndex(where: { $0.id == id }) {
            putts[idx].relay = status
        }
    }

    // MARK: Delete

    /// Remove one putt — a mishit or a false trip — from the live feed and
    /// Firestore. A putt whose write failed never reached Firestore, so it's just
    /// dropped locally; otherwise the Firestore doc is deleted first and the row
    /// is removed only once that succeeds. Throws if the delete fails, leaving the
    /// row in place.
    @MainActor
    func deletePutt(_ received: ReceivedPutt) async throws {
        if case .failed = received.relay {
            putts.removeAll { $0.id == received.id }
            return
        }
        try await service.deletePutt(
            sessionId: received.sessionId, puttIndex: received.putt.puttIndex
        )
        putts.removeAll { $0.id == received.id }
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
        // In calibration mode a centered jig roll trains the baseline instead of
        // being recorded as a putt — don't relay it, list it, or start a session.
        // (The delegate runs on the main thread, so touching the store is safe.)
        if calibration.isCalibrating {
            calibration.record(sensors: (putt.sensors ?? []).compactMap { $0 })
            return
        }
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
        let sessionId = activeSessionId ?? putt.sessionID
        // Apply the active center calibration (if any) so the displayed and
        // persisted reading is the corrected, consistent one.
        let corrected = calibration.active.map { putt.applying($0) } ?? putt
        putts.insert(ReceivedPutt(putt: corrected, sessionId: sessionId), at: 0)   // newest first
        // Bound the live feed so a marathon session can't grow it without limit
        // (every putt is persisted in Firestore; History shows the full record).
        if putts.count > Self.maxLivePutts { putts.removeLast(putts.count - Self.maxLivePutts) }
        relayPutt(corrected, sessionId: sessionId, tagSession: isNewSession)
    }
}
