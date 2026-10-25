import Foundation
@testable import DemonicMotorsoundOBD2

/// Manuell steuerbare Zeitquelle für deterministische Tests.
final class ManualTimeSource: TimeSource, @unchecked Sendable {
    var current: TimeInterval

    init(_ start: TimeInterval = 100) {
        current = start
    }

    func now() -> TimeInterval { current }

    func advance(_ seconds: TimeInterval) {
        current += seconds
    }
}

/// Simulierter ELM327-Adapter ohne Hardware.
///
/// Antworten werden asynchron und optional in Fragmenten zugestellt, wie es bei
/// BLE-Benachrichtigungen bzw. TCP-Paketen vorkommt.
@MainActor
final class MockELM327Transport: OBDTransport {
    var onReceive: ((Data) -> Void)?
    var isReady = true
    let transportDescription = "Testadapter"

    /// Liefert die Rohantwort (inkl. `>`) für einen Befehl oder `nil` für „keine Antwort“.
    var responder: (String) -> String?
    /// Fragmentgröße in Bytes (0 = ungeteilt).
    var fragmentSize = 0
    /// Echo aktiv, bis `ATE0` empfangen wurde.
    var echo = true
    private(set) var sentCommands: [String] = []
    /// Antworten, die erst nach einer Verzögerung zugestellt werden (Befehl → Sekunden).
    var delays: [String: Double] = [:]

    init(responder: @escaping (String) -> String?) {
        self.responder = responder
    }

    func send(_ data: Data) {
        let command = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        sentCommands.append(command)
        guard var reply = responder(command) else { return }
        if echo { reply = command + "\r" + reply }
        if command.uppercased() == "ATE0" { echo = false }
        let bytes = Array(reply.utf8)
        let chunks: [[UInt8]]
        if fragmentSize > 0 {
            chunks = stride(from: 0, to: bytes.count, by: fragmentSize).map { Array(bytes[$0..<min($0 + fragmentSize, bytes.count)]) }
        } else {
            chunks = [bytes]
        }
        let delay = delays[command] ?? 0
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            for chunk in chunks {
                self?.onReceive?(Data(chunk))
                await Task.yield()
            }
        }
    }
}

/// Standardantworten eines typischen CAN-Fahrzeugs (11 Bit, 500 kbit/s) mit Headern.
enum SimulatedVehicle {
    static func canResponder(rpmRaw: (UInt8, UInt8) = (0x1A, 0xF8), multipleECUs: Bool = false) -> (String) -> String? {
        return { command in
            switch command.uppercased() {
            case "ATZ": return "\r\rELM327 v1.5\r\r>"
            case "ATE0", "ATL0", "ATS1", "ATH1", "ATAT1", "ATSP0": return "OK\r\r>"
            case "ATRV": return "12.6V\r\r>"
            case "ATDPN": return "A6\r\r>"
            case "0100":
                var r = "SEARCHING...\r7E8 06 41 00 BE 3F A8 13\r"
                if multipleECUs { r += "7E9 06 41 00 98 18 80 11\r" }
                return r + "\r>"
            case "0120": return "7E8 06 41 20 80 01 A0 01\r\r>"
            case "0140": return "7E8 06 41 40 40 80 00 00\r\r>"
            case "010C", "010C1":
                var r = "7E8 04 41 0C \(Hex.byte(rpmRaw.0)) \(Hex.byte(rpmRaw.1))\r"
                if multipleECUs && command.count == 4 { r += "7E9 04 41 0C 00 00\r" }
                return r + "\r>"
            case "010D", "010D1": return "7E8 03 41 0D 32\r\r>"
            case "0104", "01041": return "7E8 03 41 04 80\r\r>"
            case "0105", "01051": return "7E8 03 41 05 7B\r\r>"
            case "0111", "01111": return "7E8 03 41 11 33\r\r>"
            case "0149", "01491": return "7E8 03 41 49 40\r\r>"
            default: return "NO DATA\r\r>"
            }
        }
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
