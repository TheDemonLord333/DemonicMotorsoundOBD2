import Foundation
import Observation

/// Verwaltet die aktive Adapterverbindung (BLE oder WLAN) und die ELM327-Sitzung darauf.
@Observable
final class ConnectionManager {
    let log = DiagnosticLog()
    let ble = BLEManager()
    let wifi = WiFiTransport()

    private(set) var session: ELM327Session?
    private(set) var activeKind: TransportKind?
    private(set) var lastProblem: String?

    var onSample: ((SignalSample) -> Void)?
    var onAvailabilityChange: (([VehicleSignal: SignalAvailability]) -> Void)?
    /// Neue Sitzung gestartet (z. B. nach Wiederverbindung) – Sound soll sanft neu einblenden.
    var onSessionStarted: (() -> Void)?
    var autoReconnect = true {
        didSet { ble.autoReconnect = autoReconnect }
    }

    private var pollingSuspended = false
    private var reinitAttempts = 0
    private var wifiTarget: (host: String, port: Int)?
    private var wifiWasReady = false
    private var wifiReconnectAttempt = 0
    private var wifiReconnectTask: Task<Void, Never>?

    init() {
        ble.onLinkStateChange = { [weak self] state in
            self?.bleStateChanged(state)
        }
        wifi.onStateChange = { [weak self] state in
            self?.wifiStateChanged(state)
        }
    }

    // MARK: - Zustand für die Oberfläche

    var isTransportReady: Bool {
        switch activeKind {
        case .bluetoothLE: ble.isReady
        case .wifi: wifi.isReady
        case nil: false
        }
    }

    var statusTitle: String {
        guard let activeKind else { return "Kein Adapter verbunden" }
        if let session, isTransportReady {
            return session.phase.description
        }
        switch activeKind {
        case .bluetoothLE: return ble.linkState.title
        case .wifi: return wifi.state.title
        }
    }

    var isPolling: Bool { session?.phase == .polling }

    var hasProblem: Bool {
        if case .failed = session?.phase { return true }
        if case .failed = ble.linkState, activeKind == .bluetoothLE { return true }
        if case .failed = wifi.state, activeKind == .wifi { return true }
        return false
    }

    // MARK: - Aktionen

    func connectBLE(_ id: UUID) {
        stopSession()
        if activeKind == .wifi { disconnectWiFi() }
        activeKind = .bluetoothLE
        lastProblem = nil
        ble.connect(to: id)
    }

    func connectWiFi(host: String, port: Int) {
        stopSession()
        if activeKind == .bluetoothLE { ble.disconnect() }
        activeKind = .wifi
        lastProblem = nil
        wifiTarget = (host, port)
        wifiReconnectAttempt = 0
        wifiWasReady = false
        wifi.connect(host: host, port: port)
    }

    func disconnect() {
        stopSession()
        ble.disconnect()
        disconnectWiFi()
        activeKind = nil
        onAvailabilityChange?([:])
        log.add(.info, "Verbindung getrennt")
    }

    /// Initialisiert den Adapter auf der bestehenden Verbindung neu.
    func reinitialize() {
        reinitAttempts = 0
        startSessionIfReady()
    }

    /// Pausiert die Fahrzeugabfragen (Demomodus oder Hintergrund ohne aktiven Sound).
    func setPollingSuspended(_ suspended: Bool) {
        pollingSuspended = suspended
        if suspended {
            session?.pausePolling()
        } else {
            session?.resumePolling()
        }
    }

    private func disconnectWiFi() {
        wifiReconnectTask?.cancel()
        wifiReconnectTask = nil
        wifiTarget = nil
        wifi.disconnect()
    }

    // MARK: - Sitzung

    private func stopSession() {
        session?.stop()
        session = nil
    }

    private func startSessionIfReady() {
        stopSession()
        let transport: OBDTransport?
        switch activeKind {
        case .bluetoothLE: transport = ble.isReady ? ble : nil
        case .wifi: transport = wifi.isReady ? wifi : nil
        case nil: transport = nil
        }
        guard let transport else { return }
        let newSession = ELM327Session(transport: transport, log: log)
        newSession.onSample = { [weak self] sample in
            self?.onSample?(sample)
        }
        newSession.onAvailabilityChange = { [weak self] map in
            self?.onAvailabilityChange?(map)
        }
        newSession.onConnectionProblem = { [weak self] message in
            self?.handleSessionProblem(message)
        }
        if pollingSuspended { newSession.pausePolling() }
        session = newSession
        newSession.start()
        onSessionStarted?()
    }

    private func handleSessionProblem(_ message: String) {
        lastProblem = message
        // Ein bis zwei automatische Neuinitialisierungen, dann bleibt der Fehler sichtbar.
        guard autoReconnect, reinitAttempts < 2, isTransportReady else { return }
        reinitAttempts += 1
        log.add(.info, "Automatische Neuinitialisierung (\(reinitAttempts)/2)")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.startSessionIfReady()
        }
    }

    private func bleStateChanged(_ state: BLEManager.LinkState) {
        guard activeKind == .bluetoothLE else { return }
        log.add(.info, "BLE: \(state.title)")
        switch state {
        case .ready:
            reinitAttempts = 0
            startSessionIfReady()
        case .failed(let message):
            lastProblem = message
            stopSession()
            onAvailabilityChange?([:])
        case .reconnecting, .idle:
            stopSession()
        default:
            break
        }
    }

    private func wifiStateChanged(_ state: WiFiTransport.State) {
        guard activeKind == .wifi else { return }
        log.add(.info, "WLAN: \(state.title)")
        switch state {
        case .ready:
            wifiWasReady = true
            wifiReconnectAttempt = 0
            reinitAttempts = 0
            startSessionIfReady()
        case .failed(let message):
            lastProblem = message
            stopSession()
            scheduleWiFiReconnect()
        case .idle:
            stopSession()
        default:
            break
        }
    }

    private func scheduleWiFiReconnect() {
        guard autoReconnect, wifiWasReady, let target = wifiTarget, wifiReconnectAttempt < 3 else { return }
        wifiReconnectAttempt += 1
        let delay = pow(2.0, Double(wifiReconnectAttempt))
        log.add(.info, "WLAN-Wiederverbindung \(wifiReconnectAttempt)/3 in \(Int(delay)) s")
        wifiReconnectTask?.cancel()
        wifiReconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.activeKind == .wifi else { return }
            self.wifi.connect(host: target.host, port: target.port)
        }
    }
}
