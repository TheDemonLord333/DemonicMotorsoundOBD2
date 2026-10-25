import CoreBluetooth
import Foundation
import Observation

/// Gefundenes BLE-Gerät.
struct DiscoveredPeripheral: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date
    var advertisesKnownService: Bool
    var isConnectable: Bool
}

/// BLE-Verbindung zu ELM327-kompatiblen Adaptern (CoreBluetooth).
///
/// - Suche, Verbindung, Trennung und begrenzte Wiederverbindungsversuche.
/// - Bekannte, dokumentierte GATT-Profile werden automatisch erkannt (siehe `BLEAdapterProfile`).
/// - Für unbekannte Geräte kann der Nutzer Service, Write- und Notify-Characteristic aus den
///   tatsächlich entdeckten GATT-Diensten auswählen. Es wird nur an Characteristics geschrieben,
///   die Schreiben erlauben; Benachrichtigungen nur auf Notify/Indicate-Characteristics.
/// - Ausgehende Daten werden gemäß `maximumWriteValueLength` fragmentiert und mit Flusskontrolle
///   gesendet.
@Observable
final class BLEManager: OBDTransport {
    enum LinkState: Equatable {
        case idle
        case connecting(String)
        case discovering
        case needsCharacteristicSelection
        case subscribing
        case ready
        case reconnecting(attempt: Int, of: Int)
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Nicht verbunden"
            case .connecting(let name): "Verbinde mit \(name) …"
            case .discovering: "Lese GATT-Dienste …"
            case .needsCharacteristicSelection: "Unbekanntes Profil – bitte Characteristics wählen"
            case .subscribing: "Aktiviere Benachrichtigungen …"
            case .ready: "Verbunden"
            case .reconnecting(let attempt, let total): "Wiederverbindung \(attempt)/\(total) …"
            case .failed(let message): message
            }
        }
    }

    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var isScanning = false
    private(set) var discovered: [DiscoveredPeripheral] = []
    private(set) var linkState: LinkState = .idle
    private(set) var connectedPeripheralID: UUID?
    private(set) var connectedName: String?
    private(set) var services: [GATTServiceInfo] = []
    private(set) var matchedProfile: BLEAdapterProfile?
    private(set) var activeSelection: CustomGATTSelection?
    private(set) var usesWriteWithoutResponse = false
    private(set) var maxWriteLength = 20
    private(set) var selectionError: String?

    var onReceive: ((Data) -> Void)?
    var onLinkStateChange: ((LinkState) -> Void)?
    /// Liefert eine gespeicherte manuelle GATT-Zuordnung für ein Gerät.
    var savedSelectionProvider: ((UUID) -> CustomGATTSelection?)?
    /// Meldet eine erfolgreich aktivierte Zuordnung (zum Speichern).
    var onSelectionConfirmed: ((UUID, CustomGATTSelection) -> Void)?
    var autoReconnect = true
    let maxReconnectAttempts = 3

    private var central: CBCentralManager?
    private let proxy = BLEDelegateProxy()
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var pendingChunks: [Data] = []
    private var awaitingWriteResponse = false
    private var pendingServiceCount = 0
    private var userInitiatedDisconnect = false
    private var reconnectAttempt = 0
    private var pendingConnectID: UUID?
    private var connectTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var scanStopTask: Task<Void, Never>?

    init() {
        proxy.owner = self
    }

    var isReady: Bool { linkState == .ready }
    var transportDescription: String { "Bluetooth LE \(connectedName ?? "")" }

    var isPoweredOn: Bool { bluetoothState == .poweredOn }

    var bluetoothStateText: String {
        switch bluetoothState {
        case .poweredOn: "Bluetooth bereit"
        case .poweredOff: "Bluetooth ist ausgeschaltet"
        case .unauthorized: "Keine Bluetooth-Berechtigung – in den iOS-Einstellungen erlauben"
        case .unsupported: "Dieses Gerät unterstützt kein Bluetooth LE"
        case .resetting: "Bluetooth wird zurückgesetzt …"
        case .unknown: central == nil ? "Bluetooth noch nicht aktiviert" : "Bluetooth-Status wird ermittelt …"
        @unknown default: "Unbekannter Bluetooth-Status"
        }
    }

    /// Erzeugt den Central Manager erst bei Bedarf, damit die Berechtigungsabfrage nicht
    /// ungefragt beim App-Start erscheint.
    func activate() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: proxy, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: - Suche

    func startScan() {
        activate()
        guard let central, central.state == .poweredOn else { return }
        discovered.removeAll { Date().timeIntervalSince($0.lastSeen) > 30 }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        scanStopTask?.cancel()
        scanStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.stopScan()
        }
    }

    func stopScan() {
        scanStopTask?.cancel()
        scanStopTask = nil
        central?.stopScan()
        isScanning = false
    }

    // MARK: - Verbindung

    func connect(to id: UUID) {
        activate()
        stopScan()
        if id == connectedPeripheralID, linkState == .ready { return }
        cleanupLink(cancelConnection: true)
        userInitiatedDisconnect = false
        reconnectAttempt = 0
        guard let central, central.state == .poweredOn else {
            // Verbindung nachholen, sobald Bluetooth bereit ist.
            pendingConnectID = id
            return
        }
        guard let target = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            setLink(.failed("Gerät nicht gefunden – bitte erneut suchen"))
            return
        }
        peripherals[id] = target
        peripheral = target
        connectedPeripheralID = id
        connectedName = target.name ?? discovered.first { $0.id == id }?.name ?? "Adapter"
        startConnecting()
    }

    func disconnect() {
        userInitiatedDisconnect = true
        pendingConnectID = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        cleanupLink(cancelConnection: true)
        peripheral = nil
        connectedPeripheralID = nil
        connectedName = nil
        services = []
        setLink(.idle)
    }

    /// Manuelle Auswahl für unbekannte Adapter.
    func applyCustomSelection(_ selection: CustomGATTSelection) {
        guard linkState == .needsCharacteristicSelection || linkState == .ready || linkState == .subscribing else { return }
        guard GATTProfileMatcher.validate(selection, services: services) else {
            selectionError = "Auswahl ungültig: Die Write-Characteristic muss Schreiben, die Notify-Characteristic Benachrichtigungen unterstützen."
            return
        }
        selectionError = nil
        matchedProfile = nil
        configure(selection)
    }

    private func startConnecting() {
        guard let central, let peripheral else { return }
        setLink(reconnectAttempt > 0 ? .reconnecting(attempt: reconnectAttempt, of: maxReconnectAttempts) : .connecting(connectedName ?? "Adapter"))
        central.connect(peripheral, options: nil)
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, let peripheral = self.peripheral, peripheral.state != .connected else { return }
            self.central?.cancelPeripheralConnection(peripheral)
            self.handleLinkLoss(reason: "Zeitüberschreitung beim Verbinden")
        }
    }

    private func cleanupLink(cancelConnection: Bool) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        if cancelConnection, let peripheral, let central {
            if let notify = notifyCharacteristic, peripheral.state == .connected, notify.isNotifying {
                peripheral.setNotifyValue(false, for: notify)
            }
            central.cancelPeripheralConnection(peripheral)
        }
        writeCharacteristic = nil
        notifyCharacteristic = nil
        pendingChunks.removeAll()
        awaitingWriteResponse = false
        activeSelection = nil
        matchedProfile = nil
    }

    private func handleLinkLoss(reason: String) {
        cleanupLink(cancelConnection: false)
        guard !userInitiatedDisconnect else {
            setLink(.idle)
            return
        }
        if autoReconnect, reconnectAttempt < maxReconnectAttempts, peripheral != nil {
            reconnectAttempt += 1
            let delay = pow(2.0, Double(reconnectAttempt - 1)) // 1 s, 2 s, 4 s
            setLink(.reconnecting(attempt: reconnectAttempt, of: maxReconnectAttempts))
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, !self.userInitiatedDisconnect else { return }
                self.startConnecting()
            }
        } else {
            setLink(.failed("Verbindung verloren: \(reason)"))
        }
    }

    private func setLink(_ state: LinkState) {
        guard state != linkState else { return }
        linkState = state
        onLinkStateChange?(state)
    }

    // MARK: - GATT

    private func buildServiceInfo() {
        guard let peripheral else { return }
        services = (peripheral.services ?? []).map { service in
            GATTServiceInfo(
                uuid: service.uuid.uuidString,
                characteristics: (service.characteristics ?? []).map {
                    GATTCharacteristicInfo(uuid: $0.uuid.uuidString, properties: Self.properties($0.properties))
                }
            )
        }
    }

    private func resolveLink() {
        guard let peripheral else { return }
        if let saved = savedSelectionProvider?(peripheral.identifier), GATTProfileMatcher.validate(saved, services: services) {
            matchedProfile = BLEAdapterProfile.known.first {
                GATTProfileMatcher.same($0.serviceUUID, saved.serviceUUID) && GATTProfileMatcher.same($0.writeUUID, saved.writeUUID)
            }
            configure(saved)
        } else if let profile = GATTProfileMatcher.match(services: services) {
            matchedProfile = profile
            configure(CustomGATTSelection(serviceUUID: profile.serviceUUID, writeUUID: profile.writeUUID, notifyUUID: profile.notifyUUID))
        } else {
            setLink(.needsCharacteristicSelection)
        }
    }

    private func characteristic(service: String, uuid: String) -> CBCharacteristic? {
        guard let peripheral else { return nil }
        let svc = peripheral.services?.first { GATTProfileMatcher.same($0.uuid.uuidString, service) }
        return svc?.characteristics?.first { GATTProfileMatcher.same($0.uuid.uuidString, uuid) }
    }

    private func configure(_ selection: CustomGATTSelection) {
        guard let peripheral,
              let write = characteristic(service: selection.serviceUUID, uuid: selection.writeUUID),
              let notify = characteristic(service: selection.serviceUUID, uuid: selection.notifyUUID),
              write.properties.contains(.write) || write.properties.contains(.writeWithoutResponse),
              notify.properties.contains(.notify) || notify.properties.contains(.indicate) else {
            setLink(.needsCharacteristicSelection)
            return
        }
        writeCharacteristic = write
        notifyCharacteristic = notify
        activeSelection = selection
        // „Ohne Antwort“ ist schneller; Flusskontrolle über canSendWriteWithoutResponse.
        usesWriteWithoutResponse = write.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType = usesWriteWithoutResponse ? .withoutResponse : .withResponse
        maxWriteLength = max(20, peripheral.maximumWriteValueLength(for: type))
        setLink(.subscribing)
        peripheral.setNotifyValue(true, for: notify)
    }

    static func properties(_ p: CBCharacteristicProperties) -> GATTCharacteristicProperties {
        var result: GATTCharacteristicProperties = []
        if p.contains(.read) { result.insert(.read) }
        if p.contains(.write) { result.insert(.write) }
        if p.contains(.writeWithoutResponse) { result.insert(.writeWithoutResponse) }
        if p.contains(.notify) { result.insert(.notify) }
        if p.contains(.indicate) { result.insert(.indicate) }
        return result
    }

    // MARK: - Senden

    func send(_ data: Data) {
        guard isReady else { return }
        var offset = 0
        while offset < data.count {
            let end = min(offset + maxWriteLength, data.count)
            pendingChunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        flushWrites()
    }

    private func flushWrites() {
        guard let peripheral, let write = writeCharacteristic else { return }
        if usesWriteWithoutResponse {
            while !pendingChunks.isEmpty && peripheral.canSendWriteWithoutResponse {
                peripheral.writeValue(pendingChunks.removeFirst(), for: write, type: .withoutResponse)
            }
        } else if !awaitingWriteResponse, !pendingChunks.isEmpty {
            awaitingWriteResponse = true
            peripheral.writeValue(pendingChunks.removeFirst(), for: write, type: .withResponse)
        }
    }

    // MARK: - Delegate-Ereignisse (vom Proxy auf dem Hauptthread weitergereicht)

    fileprivate func centralDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        switch central.state {
        case .poweredOn:
            if let id = pendingConnectID {
                pendingConnectID = nil
                connect(to: id)
            }
        case .poweredOff, .unauthorized, .unsupported, .resetting:
            isScanning = false
            if peripheral != nil, linkState != .idle {
                cleanupLink(cancelConnection: false)
                setLink(.failed(bluetoothStateText))
            }
        default:
            break
        }
    }

    fileprivate func didDiscover(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let known = advertisedServices.contains { uuid in
            BLEAdapterProfile.known.contains { GATTProfileMatcher.same($0.serviceUUID, uuid.uuidString) }
        }
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unbenanntes Gerät"
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let entry = DiscoveredPeripheral(id: peripheral.identifier, name: name, rssi: rssi.intValue, lastSeen: Date(),
                                         advertisesKnownService: known, isConnectable: connectable)
        if let index = discovered.firstIndex(where: { $0.id == entry.id }) {
            discovered[index] = entry
        } else {
            discovered.append(entry)
        }
        discovered.sort {
            if $0.advertisesKnownService != $1.advertisesKnownService { return $0.advertisesKnownService }
            return $0.rssi > $1.rssi
        }
    }

    fileprivate func didConnect(_ peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        connectTimeoutTask?.cancel()
        peripheral.delegate = proxy
        setLink(.discovering)
        peripheral.discoverServices(nil)
    }

    fileprivate func didFailToConnect(_ peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        handleLinkLoss(reason: error?.localizedDescription ?? "Verbindung fehlgeschlagen")
    }

    fileprivate func didDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        if userInitiatedDisconnect {
            setLink(.idle)
        } else {
            handleLinkLoss(reason: error?.localizedDescription ?? "Gerät hat getrennt")
        }
    }

    fileprivate func didDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        if let error {
            setLink(.failed("GATT-Dienste konnten nicht gelesen werden: \(error.localizedDescription)"))
            return
        }
        let list = peripheral.services ?? []
        guard !list.isEmpty else {
            setLink(.failed("Das Gerät bietet keine GATT-Dienste an"))
            return
        }
        pendingServiceCount = list.count
        for service in list {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    fileprivate func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        pendingServiceCount -= 1
        guard pendingServiceCount <= 0 else { return }
        buildServiceInfo()
        resolveLink()
    }

    fileprivate func didUpdateNotificationState(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyCharacteristic?.uuid else { return }
        if let error {
            setLink(.failed("Benachrichtigungen konnten nicht aktiviert werden: \(error.localizedDescription)"))
            return
        }
        guard characteristic.isNotifying, let selection = activeSelection else { return }
        reconnectAttempt = 0
        setLink(.ready)
        onSelectionConfirmed?(peripheral.identifier, selection)
    }

    fileprivate func didUpdateValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == notifyCharacteristic?.uuid, let value = characteristic.value, !value.isEmpty else { return }
        onReceive?(value)
    }

    fileprivate func didWriteValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        awaitingWriteResponse = false
        if error != nil {
            pendingChunks.removeAll()
        }
        flushWrites()
    }

    fileprivate func isReadyToSendWithoutResponse() {
        flushWrites()
    }
}

/// Nicht isolierter Delegate, der CoreBluetooth-Ereignisse an den `BLEManager` weiterreicht.
/// Der Central Manager arbeitet auf der Main-Queue, daher ist `assumeIsolated` hier sicher.
nonisolated final class BLEDelegateProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var owner: BLEManager?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { owner?.centralDidUpdateState(central) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { owner?.didDiscover(peripheral, advertisementData: advertisementData, rssi: RSSI) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { owner?.didConnect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { owner?.didFailToConnect(peripheral, error: error) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { owner?.didDisconnect(peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { owner?.didDiscoverServices(peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { owner?.didDiscoverCharacteristics(peripheral, service: service, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { owner?.didUpdateNotificationState(peripheral, characteristic: characteristic, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { owner?.didUpdateValue(peripheral, characteristic: characteristic, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { owner?.didWriteValue(peripheral, characteristic: characteristic, error: error) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { owner?.isReadyToSendWithoutResponse() }
    }
}
