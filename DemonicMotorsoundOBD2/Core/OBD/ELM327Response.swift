import Foundation

/// Sammelt eingehende Bytes eines ELM327-kompatiblen Adapters, bis der Prompt `>` eintrifft.
///
/// BLE-Benachrichtigungen und TCP-Pakete können eine Antwort beliebig zerteilen
/// (z. B. `41 0` + `C 1A F8\r\r>`). Erst der Prompt markiert das Ende einer Antwort.
nonisolated struct ELM327ResponseAccumulator {
    private var buffer: [UInt8] = []
    /// Schutz gegen ausufernde Puffer, falls ein Adapter nie einen Prompt sendet.
    var maximumBufferSize = 8192

    var pendingByteCount: Int { buffer.count }

    /// Fügt Bytes hinzu und liefert alle dadurch abgeschlossenen Rohantworten (ohne `>`).
    mutating func append<S: Sequence>(_ bytes: S) -> [String] where S.Element == UInt8 {
        var completed: [String] = []
        for byte in bytes {
            switch byte {
            case 0x3E: // ">"
                completed.append(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
            case 0x00:
                // Einige Adapter senden NUL-Bytes vor dem Prompt; diese sind bedeutungslos.
                continue
            default:
                buffer.append(byte)
            }
        }
        if buffer.count > maximumBufferSize {
            buffer.removeFirst(buffer.count - maximumBufferSize)
        }
        return completed
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}

/// Bekannte Fehler- und Statusmeldungen des ELM327 (laut Datenblatt) und kompatibler Adapter.
nonisolated enum ELM327Error: Error, Equatable, Sendable {
    case noData
    case unknownCommand
    case unableToConnect
    case busInitError
    case canError
    case busBusy
    case busError
    case bufferFull
    case dataError
    case feedbackError
    case receiveError
    case stopped
    case lowVoltageReset
    case activityAlert
    case internalError(String)
    case timeout
    case emptyResponse
    case notAllowed(String)
    case transportUnavailable
    case cancelled

    var germanDescription: String {
        switch self {
        case .noData: "Keine Daten (NO DATA)"
        case .unknownCommand: "Befehl vom Adapter nicht verstanden (?)"
        case .unableToConnect: "Adapter erreicht das Fahrzeug nicht (UNABLE TO CONNECT) – Zündung an?"
        case .busInitError: "Bus-Initialisierung fehlgeschlagen (BUS INIT ERROR)"
        case .canError: "CAN-Fehler (CAN ERROR)"
        case .busBusy: "Bus ausgelastet (BUS BUSY)"
        case .busError: "Busfehler (BUS ERROR)"
        case .bufferFull: "Adapterpuffer voll (BUFFER FULL)"
        case .dataError: "Datenfehler (DATA ERROR)"
        case .feedbackError: "Rückmeldefehler (FB ERROR)"
        case .receiveError: "Empfangsfehler (RX ERROR)"
        case .stopped: "Vorgang abgebrochen (STOPPED)"
        case .lowVoltageReset: "Adapter-Neustart wegen Unterspannung (LV RESET)"
        case .activityAlert: "Keine Busaktivität (ACT ALERT)"
        case .internalError(let code): "Interner Adapterfehler (\(code))"
        case .timeout: "Zeitüberschreitung – keine Antwort vom Adapter"
        case .emptyResponse: "Leere Antwort"
        case .notAllowed(let cmd): "Befehl aus Sicherheitsgründen blockiert: \(cmd)"
        case .transportUnavailable: "Keine Verbindung zum Adapter"
        case .cancelled: "Abgebrochen"
        }
    }
}

/// Aufbereitete Antwort auf einen einzelnen Befehl.
nonisolated struct ELM327Reply: Equatable, Sendable {
    /// Inhaltszeilen ohne Echo, ohne `SEARCHING...` und ohne Fehlerzeilen.
    var lines: [String]
    /// Fehler, die in der Antwort enthalten waren (z. B. ein Steuergerät mit `<DATA ERROR`).
    var errors: [ELM327Error]
    var raw: String

    /// Primärer Fehler, wenn keine verwertbaren Zeilen vorhanden sind.
    var failure: ELM327Error? {
        guard lines.isEmpty else { return nil }
        return errors.first ?? .emptyResponse
    }

    /// Zerlegt eine Rohantwort (Text vor dem Prompt).
    static func parse(raw: String, command: String) -> ELM327Reply {
        let normalizedCommand = normalize(command)
        var lines: [String] = []
        var errors: [ELM327Error] = []
        let parts = raw.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        var echoChecked = false
        for part in parts {
            let line = part.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Echo der Anfrage entfernen (erste Inhaltszeile; tritt auf, solange ATE1 aktiv ist).
            if !echoChecked {
                echoChecked = true
                if !normalizedCommand.isEmpty, normalize(line) == normalizedCommand { continue }
            }
            let upper = line.uppercased()
            if upper.hasPrefix("SEARCHING") { continue }
            if upper.hasPrefix("BUS INIT") {
                if upper.contains("ERROR") { errors.append(.busInitError) }
                // „BUS INIT: ...OK“ kann direkt Daten enthalten – Rest der Zeile prüfen.
                if let okRange = upper.range(of: "OK") {
                    let rest = upper[okRange.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { lines.append(rest) }
                }
                continue
            }
            if let error = classifyError(upper) {
                errors.append(error)
                continue
            }
            lines.append(line)
        }
        return ELM327Reply(lines: lines, errors: errors, raw: raw)
    }

    static func classifyError(_ upper: String) -> ELM327Error? {
        let compact = upper.replacingOccurrences(of: " ", with: "")
        switch compact {
        case "NODATA": return .noData
        case "?": return .unknownCommand
        case "UNABLETOCONNECT": return .unableToConnect
        case "CANERROR": return .canError
        case "BUSBUSY": return .busBusy
        case "BUSERROR": return .busError
        case "BUFFERFULL": return .bufferFull
        case "FBERROR": return .feedbackError
        case "STOPPED": return .stopped
        case "LVRESET": return .lowVoltageReset
        case "ACTALERT": return .activityAlert
        default: break
        }
        if compact.contains("DATAERROR") { return .dataError }
        if compact.contains("RXERROR") { return .receiveError }
        if compact.hasPrefix("ERR"), compact.count == 5, compact.dropFirst(3).allSatisfy(\.isNumber) {
            return .internalError(compact)
        }
        return nil
    }

    static func normalize(_ text: String) -> String {
        text.uppercased().filter { !$0.isWhitespace }
    }
}
