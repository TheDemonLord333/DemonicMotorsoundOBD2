import Foundation

/// Bytestrom zu einem ELM327-kompatiblen Adapter (BLE, WLAN oder Testattrappe).
protocol OBDTransport: AnyObject {
    /// Wird für jedes empfangene Datenfragment aufgerufen (Hauptthread).
    var onReceive: ((Data) -> Void)? { get set }
    var isReady: Bool { get }
    var transportDescription: String { get }
    func send(_ data: Data)
}

/// Sicherheitsrichtlinie: Die App sendet ausschließlich notwendige Adapterinitialisierungen und
/// lesende Mode-01-Abfragen. Codierungen, Stellgliedtests, Fehlerspeicher löschen (Mode 04),
/// beliebige CAN-Nachrichten oder Header-Manipulationen sind ausgeschlossen.
nonisolated enum ELM327CommandPolicy {
    /// Erlaubte AT-Befehle (nur Adapterkonfiguration bzw. Informationsabfragen).
    static let allowedATCommands: Set<String> = [
        "ATZ",     // Adapter-Reset
        "ATWS",    // Warmstart
        "ATE0",    // Echo aus
        "ATL0",    // Zeilenvorschub aus
        "ATS1",    // Leerzeichen an (robustere Auswertung)
        "ATH1",    // Header an (Trennung mehrerer Steuergeräte)
        "ATH0",    // Header aus (Rückfall für Adapter ohne Header-Unterstützung)
        "ATAT1",   // Adaptives Timing
        "ATSP0",   // Protokoll automatisch wählen
        "ATI",     // Versionskennung
        "ATRV",    // Bordspannung am Adapter lesen
        "ATDPN",   // Protokollnummer lesen
        "ATDP",    // Protokollname lesen
    ]

    static func isAllowed(_ command: String) -> Bool {
        let normalized = command.uppercased().filter { !$0.isWhitespace }
        if allowedATCommands.contains(normalized) { return true }
        // Mode 01 (aktuelle Daten), genau ein PID, optional eine Antwortanzahl-Ziffer (ELM327 ≥ 1.3).
        guard normalized.hasPrefix("01") else { return false }
        let rest = normalized.dropFirst(2)
        guard rest.count == 2 || rest.count == 3, Hex.isHexString(rest.prefix(2)) else { return false }
        if rest.count == 3 {
            guard let digit = rest.last, ("1"..."9").contains(digit) else { return false }
        }
        return true
    }
}
