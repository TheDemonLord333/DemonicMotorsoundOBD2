import Foundation

/// OBD-Protokollfamilie, wie sie `ATDPN` meldet. Bestimmt das Header-Format.
nonisolated enum OBDProtocolFamily: Equatable, Sendable {
    case can11
    case can29
    /// SAE J1850 / ISO 9141-2 / ISO 14230-4: 3 Header-Bytes und Prüfsumme am Zeilenende.
    case legacy
    case unknown

    /// Wertet die Antwort auf `ATDPN` aus (z. B. `A6` = automatisch, aktuell Protokoll 6).
    static func fromDescribeProtocolNumber(_ text: String) -> (family: OBDProtocolFamily, number: Character?) {
        var trimmed = text.uppercased().filter { !$0.isWhitespace }
        if trimmed.hasPrefix("A") && trimmed.count > 1 { trimmed.removeFirst() }
        guard let ch = trimmed.first else { return (.unknown, nil) }
        switch ch {
        case "1", "2", "3", "4", "5": return (.legacy, ch)
        case "6", "8": return (.can11, ch)
        case "7", "9": return (.can29, ch)
        default: return (.unknown, ch)
        }
    }

    static func protocolName(_ number: Character?) -> String {
        switch number {
        case "1": "SAE J1850 PWM"
        case "2": "SAE J1850 VPW"
        case "3": "ISO 9141-2"
        case "4": "ISO 14230-4 KWP (5 Baud)"
        case "5": "ISO 14230-4 KWP (schnell)"
        case "6": "ISO 15765-4 CAN 11 Bit, 500 kbit/s"
        case "7": "ISO 15765-4 CAN 29 Bit, 500 kbit/s"
        case "8": "ISO 15765-4 CAN 11 Bit, 250 kbit/s"
        case "9": "ISO 15765-4 CAN 29 Bit, 250 kbit/s"
        case "A": "SAE J1939 (nicht unterstützt)"
        default: "Unbekannt"
        }
    }
}

/// Vollständige Nachricht eines Steuergeräts (nach ISO-TP-Zusammenbau).
nonisolated struct ECUMessage: Equatable, Sendable {
    /// Kennung des Absenders, z. B. `7E8`, `18DAF110` oder `10` (Legacy). `nil`, wenn ohne Header empfangen.
    var ecu: String?
    /// Nutzdaten beginnend mit dem Service-Byte (z. B. `41 0C 1A F8`).
    var bytes: [UInt8]
}

/// Zerlegt Inhaltszeilen eines ELM327 in Steuergerätenachrichten.
///
/// - Mit Headern (`ATH1`) werden Antworten pro Steuergerät gruppiert, sodass Antworten
///   mehrerer ECUs nicht vermischt werden.
/// - ISO-TP-Mehrfachrahmen (First Frame / Consecutive Frames) werden je ECU zusammengesetzt.
/// - Ohne Header wird jede Zeile als eigene Nachricht unbekannter Herkunft behandelt;
///   auch das `N:`-Format des ELM327 für Mehrfachrahmen ohne Header wird unterstützt.
nonisolated enum OBDFrameDecoder {
    static func decode(lines: [String], headersEnabled: Bool, family: OBDProtocolFamily) -> [ECUMessage] {
        if headersEnabled {
            return decodeWithHeaders(lines: lines, family: family)
        }
        return decodeWithoutHeaders(lines: lines)
    }

    // MARK: Mit Headern

    private struct PendingISOTP {
        var expectedLength: Int
        var data: [UInt8]
        var nextSequence: UInt8
    }

    private static func decodeWithHeaders(lines: [String], family: OBDProtocolFamily) -> [ECUMessage] {
        var messages: [ECUMessage] = []
        var pending: [String: PendingISOTP] = [:]
        var order: [String] = []

        for line in lines {
            let hex = Substring(line.filter { !$0.isWhitespace })
            guard Hex.isHexString(hex) else { continue }
            let lineFamily = family == .unknown ? guessFamily(hex) : family

            switch lineFamily {
            case .can11, .can29:
                let headerLength = lineFamily == .can11 ? 3 : 8
                guard hex.count > headerLength + 1 else { continue }
                let header = String(hex.prefix(headerLength))
                guard let frame = Hex.bytes(from: hex.dropFirst(headerLength)), let pci = frame.first else { continue }
                let payload = Array(frame.dropFirst())
                switch pci >> 4 {
                case 0x0: // Single Frame
                    let length = Int(pci & 0x0F)
                    guard length > 0, payload.count >= length else { continue }
                    messages.append(ECUMessage(ecu: header, bytes: Array(payload.prefix(length))))
                case 0x1: // First Frame
                    guard let second = payload.first else { continue }
                    let length = Int(pci & 0x0F) << 8 | Int(second)
                    pending[header] = PendingISOTP(expectedLength: length, data: Array(payload.dropFirst()), nextSequence: 1)
                    if !order.contains(header) { order.append(header) }
                case 0x2: // Consecutive Frame
                    guard var state = pending[header] else { continue }
                    let sequence = pci & 0x0F
                    guard sequence == state.nextSequence else {
                        // Reihenfolgefehler: Nachricht dieses Steuergeräts verwerfen, keine Vermischung.
                        pending[header] = nil
                        continue
                    }
                    state.data.append(contentsOf: payload)
                    state.nextSequence = (state.nextSequence + 1) & 0x0F
                    if state.data.count >= state.expectedLength {
                        messages.append(ECUMessage(ecu: header, bytes: Array(state.data.prefix(state.expectedLength))))
                        pending[header] = nil
                    } else {
                        pending[header] = state
                    }
                default:
                    continue
                }
            case .legacy:
                // 3 Header-Bytes (Priorität, Ziel, Quelle), Daten, 1 Prüfsummenbyte.
                guard let frame = Hex.bytes(from: hex), frame.count >= 5 else { continue }
                let source = Hex.byte(frame[2])
                let data = Array(frame[3..<(frame.count - 1)])
                messages.append(ECUMessage(ecu: source, bytes: data))
            case .unknown:
                continue
            }
        }
        return messages
    }

    /// Heuristik, falls das Protokoll (noch) nicht bekannt ist.
    static func guessFamily(_ hex: Substring) -> OBDProtocolFamily {
        if hex.hasPrefix("18DA") && hex.count >= 10 { return .can29 }
        if hex.count % 2 == 1 { return .can11 }
        return .legacy
    }

    // MARK: Ohne Header

    private static func decodeWithoutHeaders(lines: [String]) -> [ECUMessage] {
        var messages: [ECUMessage] = []
        var multiFrame: [UInt8] = []
        var multiFrameLength: Int?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let colon = trimmed.firstIndex(of: ":") {
                // Format „0: 49 02 01 …“ (Mehrfachrahmen ohne Header).
                let data = Substring(trimmed[trimmed.index(after: colon)...].filter { !$0.isWhitespace })
                if let bytes = Hex.bytes(from: data) { multiFrame.append(contentsOf: bytes) }
                continue
            }
            let hex = Substring(trimmed.filter { !$0.isWhitespace })
            guard Hex.isHexString(hex) else { continue }
            if hex.count == 3, let length = Int(hex, radix: 16) {
                // Längenangabe vor einem Mehrfachrahmen.
                multiFrameLength = length
                continue
            }
            if let bytes = Hex.bytes(from: hex), !bytes.isEmpty {
                messages.append(ECUMessage(ecu: nil, bytes: bytes))
            }
        }
        if !multiFrame.isEmpty {
            let length = multiFrameLength ?? multiFrame.count
            messages.append(ECUMessage(ecu: nil, bytes: Array(multiFrame.prefix(length))))
        }
        return messages
    }
}

/// Extrahiert Mode-01-Werte aus Steuergerätenachrichten.
nonisolated enum Mode01Extractor {
    /// Datenbytes einer Mode-01-Antwort für `pid` (ohne `41 pid`). `nil` bei negativer Antwort
    /// (`7F 01 xx`) oder fehlender Antwort.
    static func payload(for pid: UInt8, in message: ECUMessage) -> ArraySlice<UInt8>? {
        let bytes = message.bytes
        guard bytes.count >= 2, bytes[0] == 0x41, bytes[1] == pid else { return nil }
        return bytes[2...]
    }

    /// Bevorzugt die Antwort des gewählten Steuergeräts; ohne Auswahl die erste passende Antwort.
    static func payload(for pid: UInt8, in messages: [ECUMessage], preferredECU: String?) -> (ecu: String?, data: ArraySlice<UInt8>)? {
        if let preferredECU {
            for message in messages where message.ecu == preferredECU {
                if let data = payload(for: pid, in: message) { return (message.ecu, data) }
            }
            // Andere Steuergeräte werden bewusst ignoriert, um keine Werte zu vermischen.
            if messages.contains(where: { $0.ecu != nil }) { return nil }
        }
        for message in messages {
            if let data = payload(for: pid, in: message) { return (message.ecu, data) }
        }
        return nil
    }
}
