import Foundation
import Combine
@preconcurrency import CoreBluetooth

struct DiscoveredLabel: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var batteryMillivolts: Int?
}

/// CoreBluetooth runs on the main queue; one transfer owns all delegate requests.
@MainActor
final class LabelBluetooth: NSObject, ObservableObject {
    @Published private(set) var labels: [DiscoveredLabel] = []
    @Published private(set) var phase = "Bluetooth ready"
    @Published private(set) var progress: Double = 0
    @Published private(set) var error: String?
    @Published private(set) var isScanning = false
    @Published private(set) var isWriting = false
    @Published private(set) var bluetoothAvailable = false

    private var central: CBCentralManager!
    private var wantsScan = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var targetID: UUID?
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var transferID: UUID?
    private var transportFailure: Error?
    private var refreshTracker: LabelRefreshTracker?
    private var refreshConfirmation: LabelRefreshConfirmation?
    private var refreshFailure: Error?
    private var refreshRequested = false
    private var cancelled = false

    private enum Event: Equatable {
        case advertisement, connection, services, characteristics
        case read(CBUUID), write(CBUUID), notificationSubscription
    }
    private struct Pending {
        let id: UUID
        let event: Event
        let continuation: CheckedContinuation<Data, Error>
    }
    private var pending: Pending?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        wantsScan = true
        error = nil
        guard !isWriting else { return }
        if central.state == .poweredOn { beginScan() }
        else { updateAvailability() }
    }

    func stopScan() {
        wantsScan = false
        // Keep discovery alive through connection/authentication: the tested
        // label's brief advertisement window is otherwise easily missed.
        if !isWriting {
            central.stopScan()
            isScanning = false
        }
    }

    func cancel() {
        guard isWriting else { stopScan(); return }
        cancelled = true
        failPending(CancellationError())
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    /// Replaces all pixels. Upload progress reaches 1 before physical refresh finishes.
    @discardableResult
    func write(frame: Data, to identifier: UUID) async throws -> String {
        guard !isWriting else { throw BluetoothFailure.alreadyWriting }
        try LabelProtocol.validateFrame(frame)
        let authenticationKey = try LabelKeyStore().load()
        guard central.state == .poweredOn else {
            updateAvailability()
            throw BluetoothFailure.unavailable(availabilityMessage)
        }
        let session = UUID()
        transferID = session
        isWriting = true
        cancelled = false
        targetID = identifier
        transportFailure = nil
        refreshTracker = nil
        refreshConfirmation = nil
        refreshFailure = nil
        refreshRequested = false
        progress = 0
        error = nil

        return try await withTaskCancellationHandler {
            defer { cleanup(session: session) }
            do {
                let confirmation = try await performWrite(frame: frame, authenticationKey: authenticationKey)
                try checkCancellation()
                phase = "Display updated"
                return confirmation.rawValue
            } catch {
                let surfaced: Error
                if cancelled || Task.isCancelled || error is CancellationError {
                    surfaced = BluetoothFailure.cancelled(afterRefresh: refreshRequested)
                    phase = refreshRequested ? "Cancelled · check the label" : "Cancelled"
                } else if refreshRequested, !(error is LabelProtocolError), !(error is BluetoothFailure) {
                    surfaced = BluetoothFailure.unconfirmed
                    phase = "Refresh unconfirmed"
                } else {
                    surfaced = error
                    phase = refreshRequested ? "Refresh unconfirmed" : "Could not update label"
                }
                self.error = surfaced.localizedDescription
                throw surfaced
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.transferID == session else { return }
                self?.cancel()
            }
        }
    }

    private func performWrite(frame: Data, authenticationKey: Data) async throws -> LabelRefreshConfirmation {
        phase = "Waiting for a fresh label signal · up to 5 minutes"
        _ = try await request(.advertisement, timeout: 300) { self.beginScan() }
        try checkCancellation()
        guard let peripheral else { throw BluetoothFailure.unsupported }
        phase = "Connecting to label"
        _ = try await request(.connection, timeout: 30) { self.central.connect(peripheral) }
        peripheral.delegate = self
        _ = try await request(.services) {
            peripheral.discoverServices([CBUUID(string: LabelProtocol.serviceUUID)])
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: LabelProtocol.serviceUUID) }) else {
            throw BluetoothFailure.unsupported
        }
        _ = try await request(.characteristics) { peripheral.discoverCharacteristics(nil, for: service) }
        try validateCharacteristics()
        phase = "Authenticating label"
        let nonce = try await read(LabelProtocol.authUUID)
        let response = try LabelProtocol.authenticationResponse(nonce: nonce, key: authenticationKey)
        try await send(response, to: LabelProtocol.authUUID)
        let status = try LabelProtocol.parseStatus(await read(LabelProtocol.statusUUID))
        if status.error != 0 { throw LabelProtocolError.deviceError(status.error) }
        if status.locked { throw LabelProtocolError.authenticationRejected }
        if status.busy { throw BluetoothFailure.busy }
        let info = try await read(LabelProtocol.infoUUID)
        let battery = try await read(LabelProtocol.batteryUUID)
        guard info.count == 8, battery.count == 2 else { throw BluetoothFailure.unsupported }
        if let index = labels.firstIndex(where: { $0.id == peripheral.identifier }) {
            let bytes = [UInt8](battery)
            labels[index].batteryMillivolts = Int(bytes[0]) | Int(bytes[1]) << 8
        }
        // Dimensions are the user's verified physical profile, not inferred
        // from the version bytes (those are shared by multiple panel sizes).
        central.stopScan()
        isScanning = false
        try await pause(0.5)
        let statusCharacteristic = try characteristic(LabelProtocol.statusUUID)
        _ = try await request(.notificationSubscription) {
            peripheral.setNotifyValue(true, for: statusCharacteristic)
        }
        let capacity = try LabelProtocol.payloadSize(maximumWriteLength: shortWriteLimit(peripheral))
        phase = "Sending image"
        for offset in stride(from: 0, to: frame.count, by: capacity) {
            try checkCancellation()
            let end = min(offset + capacity, frame.count)
            let packet = try LabelProtocol.dataPacket(offset: offset, payload: frame.subdata(in: offset..<end))
            try await send(packet, to: LabelProtocol.dataUUID)
            progress = Double(end) / Double(frame.count)
            try await pause(0.02)
        }
        try await pause(0.5)
        phase = "Refreshing display"
        refreshTracker = LabelRefreshTracker()
        refreshRequested = true
        do {
            try await send(LabelProtocol.refreshPacket(size: frame.count), to: LabelProtocol.dataUUID)
        } catch {
            try checkCancellation()
            // The commit may have arrived even if its ATT acknowledgement did
            // not. Keep queued status evidence and await an explicit outcome.
        }
        return try await awaitRefresh()
    }

    private func awaitRefresh() async throws -> LabelRefreshConfirmation {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        var failureObservedAt: ContinuousClock.Instant?
        while true {
            try checkCancellation()
            if let refreshFailure { throw refreshFailure }
            if let refreshConfirmation { return refreshConfirmation }
            if transportFailure != nil || peripheral?.state != .connected {
                if failureObservedAt == nil { failureObservedAt = .now }
                // Delegate callbacks already queued on the main queue can hold
                // a valid completion even when disconnect/ACK failure comes first.
                if let observed = failureObservedAt, observed.duration(to: .now) >= .milliseconds(150) {
                    throw BluetoothFailure.unconfirmed
                }
            }
            if ContinuousClock.now >= deadline { throw BluetoothFailure.unconfirmed }
            // No status reads while notifying: CoreBluetooth delivers both
            // through the same callback, so a stale FF read cannot be promoted
            // to an explicit completion notification. Notification BUSY→IDLE
            // remains valid evidence as well.
            try await pause(0.05)
        }
    }

    private func request(_ event: Event, timeout: Double = 15, action: () -> Void) async throws -> Data {
        try checkCancellation()
        if let transportFailure { throw transportFailure }
        guard pending == nil else { throw BluetoothFailure.overlappingOperation }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending = Pending(id: id, event: event, continuation: continuation)
            timeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) }
                catch { return }
                guard let self, self.pending?.id == id else { return }
                self.failPending(BluetoothFailure.timedOut(event == .advertisement))
            }
            action()
        }
    }

    private func finish(_ event: Event, result: Result<Data, Error>) {
        guard let operation = pending, operation.event == event else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        operation.continuation.resume(with: result)
    }

    private func failPending(_ error: Error) {
        if let event = pending?.event { finish(event, result: .failure(error)) }
    }

    private func read(_ uuid: String) async throws -> Data {
        let characteristic = try characteristic(uuid)
        guard let peripheral else { throw BluetoothFailure.disconnected }
        return try await request(.read(characteristic.uuid)) { peripheral.readValue(for: characteristic) }
    }

    private func send(_ data: Data, to uuid: String) async throws {
        let characteristic = try characteristic(uuid)
        guard let peripheral else { throw BluetoothFailure.disconnected }
        guard try data.count <= shortWriteLimit(peripheral) else {
            throw LabelProtocolError.writeTooSmall
        }
        _ = try await request(.write(characteristic.uuid)) {
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    private func shortWriteLimit(_ peripheral: CBPeripheral) throws -> Int {
        try LabelProtocol.shortWriteLimit(
            withResponse: peripheral.maximumWriteValueLength(for: .withResponse),
            withoutResponse: peripheral.maximumWriteValueLength(for: .withoutResponse)
        )
    }

    private func characteristic(_ uuid: String) throws -> CBCharacteristic {
        guard let value = characteristics[CBUUID(string: uuid)] else { throw BluetoothFailure.unsupported }
        return value
    }

    private func validateCharacteristics() throws {
        for uuid in [LabelProtocol.dataUUID, LabelProtocol.authUUID] {
            guard try characteristic(uuid).properties.contains(.write) else { throw BluetoothFailure.unsupported }
        }
        for uuid in [LabelProtocol.authUUID, LabelProtocol.infoUUID, LabelProtocol.statusUUID, LabelProtocol.batteryUUID] {
            guard try characteristic(uuid).properties.contains(.read) else { throw BluetoothFailure.unsupported }
        }
        let status = try characteristic(LabelProtocol.statusUUID)
        guard status.properties.contains(.notify) || status.properties.contains(.indicate) else {
            throw BluetoothFailure.unsupported
        }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
        try checkCancellation()
    }

    private func cleanup(session: UUID) {
        guard transferID == session else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        failPending(CancellationError())
        if let peripheral {
            // Disconnect removes the subscription and stops any pending GATT work.
            peripheral.delegate = nil
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        characteristics.removeAll()
        targetID = nil
        transferID = nil
        refreshTracker = nil
        isWriting = false
        if wantsScan && central.state == .poweredOn { beginScan(updatePhase: false) }
        else { central.stopScan(); isScanning = false }
    }

    private func beginScan(updatePhase: Bool = true) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        if updatePhase && !isWriting { phase = "Looking for nearby labels" }
    }

    private var availabilityMessage: String {
        switch central.state {
        case .poweredOff: return "Turn on Bluetooth to find your label."
        case .unauthorized: return "Allow Bluetooth access for Label Studio in Settings."
        case .unsupported: return "Bluetooth is not supported on this device."
        case .resetting: return "Bluetooth is restarting. Try again shortly."
        default: return "Bluetooth is starting. Try again shortly."
        }
    }

    private func updateAvailability() {
        bluetoothAvailable = central.state == .poweredOn
        if bluetoothAvailable {
            if wantsScan && !isWriting { beginScan() }
        } else {
            isScanning = false
            let failure = BluetoothFailure.unavailable(availabilityMessage)
            if isWriting { transportFailure = failure; failPending(failure) }
            else { phase = availabilityMessage }
        }
    }
}

extension LabelBluetooth: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) { updateAvailability() }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let validName = name.range(of: "^WL[0-9a-fA-F]{8}$", options: .regularExpression) != nil
        guard validName || advertisedServices.contains(CBUUID(string: LabelProtocol.serviceUUID)) else { return }
        var battery: Int?
        if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            let bytes = [UInt8](manufacturer)
            if bytes.count >= 12, bytes[0] == 0xaa, bytes[1] == 0xbb {
                battery = Int(bytes[10]) << 8 | Int(bytes[11])
            }
        }
        peripherals[peripheral.identifier] = peripheral
        let label = DiscoveredLabel(id: peripheral.identifier, name: name.isEmpty ? "WoLink label" : name,
                                    rssi: RSSI.intValue, batteryMillivolts: battery)
        if let index = labels.firstIndex(where: { $0.id == label.id }) { labels[index] = label }
        else { labels.append(label) }
        labels.sort { $0.rssi > $1.rssi }
        if pending?.event == .advertisement, peripheral.identifier == targetID,
           peripheral.state == .disconnected,
           (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue != false {
            self.peripheral = peripheral
            finish(.advertisement, result: .success(Data()))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        finish(.connection, result: .success(Data()))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        let failure = error ?? BluetoothFailure.disconnected
        transportFailure = failure
        failPending(failure)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        let failure = error ?? BluetoothFailure.disconnected
        transportFailure = failure
        failPending(failure)
    }
}

extension LabelBluetooth: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        finish(.services, result: error.map { .failure($0) } ?? .success(Data()))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, service.uuid == CBUUID(string: LabelProtocol.serviceUUID) else { return }
        for value in service.characteristics ?? [] { characteristics[value.uuid] = value }
        finish(.characteristics, result: error.map { .failure($0) } ?? .success(Data()))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if characteristic.uuid == CBUUID(string: LabelProtocol.statusUUID), refreshTracker != nil {
            if let error { transportFailure = error }
            else if let value = characteristic.value {
                do {
                    if let confirmation = try refreshTracker?.observe(value, source: .notification) {
                        refreshConfirmation = confirmation
                    }
                } catch { refreshFailure = error }
            }
        }
        if let error { finish(.read(characteristic.uuid), result: .failure(error)) }
        else if let value = characteristic.value { finish(.read(characteristic.uuid), result: .success(value)) }
        else { finish(.read(characteristic.uuid), result: .failure(LabelProtocolError.malformedStatus)) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        finish(.write(characteristic.uuid), result: error.map { .failure($0) } ?? .success(Data()))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic.uuid == CBUUID(string: LabelProtocol.statusUUID) else { return }
        if let error { finish(.notificationSubscription, result: .failure(error)) }
        else if characteristic.isNotifying { finish(.notificationSubscription, result: .success(Data())) }
        else { finish(.notificationSubscription, result: .failure(BluetoothFailure.unsupported)) }
    }
}

private enum BluetoothFailure: LocalizedError {
    case alreadyWriting, unavailable(String), unsupported, busy, overlappingOperation
    case timedOut(Bool), disconnected, unconfirmed, cancelled(afterRefresh: Bool)

    var errorDescription: String? {
        switch self {
        case .alreadyWriting: return "An image is already being sent. Wait for it to finish."
        case .unavailable(let message): return message
        case .unsupported: return "This device does not expose the supported WoLink label service."
        case .busy: return "The label is busy refreshing. Wait before sending another image."
        case .overlappingOperation: return "Another Bluetooth operation is still running."
        case .timedOut(let scanning): return scanning ? "No fresh label signal arrived within five minutes. Keep it nearby and disconnect other apps." : "The label did not respond in time. Try again when it advertises."
        case .disconnected: return "The label disconnected before the transfer finished."
        case .unconfirmed: return "The image was sent, but refresh was not confirmed. The label may still update; check it before retrying."
        case .cancelled(let afterRefresh): return afterRefresh ? "Cancelled after requesting refresh. The label may still update; check it before retrying." : "The transfer was cancelled."
        }
    }
}
