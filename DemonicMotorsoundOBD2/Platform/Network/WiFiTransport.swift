import Foundation
import Network
import Observation

/// TCP-Verbindung zu einem WLAN-OBD2-Adapter (Network.framework).
///
/// Viele WLAN-Adapter spannen ein eigenes WLAN auf; das iPhone muss zuvor in den
/// iOS-Einstellungen mit diesem WLAN verbunden werden. iOS fragt beim ersten Zugriff nach der
/// Berechtigung für das lokale Netzwerk.
@Observable
final class WiFiTransport: OBDTransport {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        case waiting(String)
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Nicht verbunden"
            case .connecting: "Verbinde …"
            case .ready: "Verbunden"
            case .waiting(let reason): "Wartet: \(reason)"
            case .failed(let reason): reason
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var endpointDescription = ""

    var onReceive: ((Data) -> Void)?
    var onStateChange: ((State) -> Void)?

    private var connection: NWConnection?
    private var timeoutTask: Task<Void, Never>?

    var isReady: Bool { state == .ready }
    var transportDescription: String { "WLAN \(endpointDescription)" }

    func connect(host: String, port: Int) {
        disconnect()
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, (1...65_535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            set(.failed("Ungültige IP-Adresse oder ungültiger Port"))
            return
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Adapter-WLAN hat meist kein Internet; keine Mobilfunk-Ausweichroute verwenden.
        parameters.prohibitedInterfaceTypes = [.cellular]

        let newConnection = NWConnection(host: NWEndpoint.Host(trimmedHost), port: nwPort, using: parameters)
        connection = newConnection
        endpointDescription = "\(trimmedHost):\(port)"
        set(.connecting)

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] newState in
            MainActor.assumeIsolated {
                guard let self, let newConnection, self.connection === newConnection else { return }
                self.handle(newState)
            }
        }
        newConnection.start(queue: .main)
        receive(on: newConnection)

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, self.connection === newConnection, self.state != .ready else { return }
            self.teardown()
            self.set(.failed("Zeitüberschreitung: Adapter unter \(self.endpointDescription) nicht erreichbar"))
        }
    }

    func disconnect() {
        teardown()
        if state != .idle { set(.idle) }
    }

    func send(_ data: Data) {
        guard let connection, state == .ready else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.fail("Senden fehlgeschlagen: \(error.localizedDescription)")
            }
        })
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let connection, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.onReceive?(data)
                }
                if let error {
                    self.fail("Verbindungsfehler: \(error.localizedDescription)")
                    return
                }
                if isComplete {
                    self.fail("Der Adapter hat die Verbindung geschlossen")
                    return
                }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            timeoutTask?.cancel()
            set(.ready)
        case .waiting(let error):
            set(.waiting(Self.describe(error)))
        case .failed(let error):
            fail("Verbindung fehlgeschlagen: \(Self.describe(error))")
        case .cancelled:
            break
        case .preparing, .setup:
            if state != .connecting { set(.connecting) }
        @unknown default:
            break
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return "Verbindung abgelehnt – Port prüfen"
        case .posix(let code) where code == .ENETUNREACH || code == .EHOSTUNREACH:
            return "Netz nicht erreichbar – ist das iPhone mit dem Adapter-WLAN verbunden?"
        case .posix(let code) where code == .ETIMEDOUT:
            return "Zeitüberschreitung"
        default:
            return "\(error.localizedDescription) – WLAN des Adapters und Berechtigung „Lokales Netzwerk“ prüfen"
        }
    }

    private func fail(_ message: String) {
        teardown()
        set(.failed(message))
    }

    private func teardown() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let connection {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connection = nil
    }

    private func set(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }
}
