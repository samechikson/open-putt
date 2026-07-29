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

    private var central: CBCentralManager!
    private var gate: CBPeripheral?
    private let relay: GatePuttRelay
    private let decoder = JSONDecoder()

    init(settings: AppSettings, auth: AuthManager) {
        self.relay = GatePuttRelay(settings: settings, auth: auth)
        super.init()
        // nil queue → callbacks are delivered on the main thread.
        central = CBCentralManager(delegate: self, queue: nil)
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

    private func relayPutt(_ putt: GatePutt, json: Data) {
        Task {
            do {
                try await relay.send(json)
                await MainActor.run { self.setStatus(putt.id, .sent) }
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
        putts.insert(ReceivedPutt(putt: putt), at: 0)   // newest first
        relayPutt(putt, json: data)
    }
}
