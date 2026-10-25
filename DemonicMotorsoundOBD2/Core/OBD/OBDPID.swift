import Foundation

/// Mode-01-PIDs (SAE J1979 / ISO 15031-5), die die App ausschließlich lesend abfragt.
nonisolated enum OBDPID: UInt8, CaseIterable, Codable, Sendable {
    case engineLoad = 0x04
    case coolantTemperature = 0x05
    case engineRPM = 0x0C
    case vehicleSpeed = 0x0D
    case throttlePosition = 0x11
    case acceleratorPedalD = 0x49
    case relativeAcceleratorPedal = 0x5A

    /// Anzahl Datenbytes in der Antwort.
    var dataByteCount: Int {
        switch self {
        case .engineRPM: 2
        default: 1
        }
    }

    var signal: VehicleSignal {
        switch self {
        case .engineLoad: .load
        case .coolantTemperature: .coolant
        case .engineRPM: .rpm
        case .vehicleSpeed: .speed
        case .throttlePosition: .throttle
        case .acceleratorPedalD, .relativeAcceleratorPedal: .pedal
        }
    }

    var hex: String { Hex.byte(rawValue) }

    /// Anfrage-String, z. B. `010C`.
    var request: String { "01" + hex }

    var title: String {
        switch self {
        case .engineLoad: "Berechnete Motorlast (PID 04)"
        case .coolantTemperature: "Kühlmitteltemperatur (PID 05)"
        case .engineRPM: "Motordrehzahl (PID 0C)"
        case .vehicleSpeed: "Fahrzeuggeschwindigkeit (PID 0D)"
        case .throttlePosition: "Drosselklappenstellung absolut (PID 11)"
        case .acceleratorPedalD: "Gaspedalstellung D (PID 49)"
        case .relativeAcceleratorPedal: "Relative Gaspedalstellung (PID 5A)"
        }
    }

    /// Dekodiert die Datenbytes (ohne `41 xx`) in die physikalische Einheit.
    func decode(_ data: ArraySlice<UInt8>) -> Double? {
        guard data.count >= dataByteCount else { return nil }
        let a = Double(data[data.startIndex])
        switch self {
        case .engineLoad, .throttlePosition, .acceleratorPedalD, .relativeAcceleratorPedal:
            return a * 100.0 / 255.0
        case .coolantTemperature:
            return a - 40.0
        case .engineRPM:
            let b = Double(data[data.startIndex + 1])
            return (a * 256.0 + b) / 4.0
        case .vehicleSpeed:
            return a
        }
    }

    func decode(_ data: [UInt8]) -> Double? { decode(data[...]) }
}

/// Auswertung der Bitmasken-PIDs 00, 20, 40, … („PIDs supported“).
nonisolated enum SupportedPIDDecoder {
    /// Bit 7 des ersten Bytes entspricht PID `base + 1`, Bit 0 des vierten Bytes PID `base + 32`.
    static func decode(base: UInt8, data: ArraySlice<UInt8>) -> Set<UInt8> {
        guard data.count >= 4 else { return [] }
        var result = Set<UInt8>()
        for (byteIndex, byte) in data.prefix(4).enumerated() {
            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                let pid = Int(base) + byteIndex * 8 + bit + 1
                if pid <= 0xFF { result.insert(UInt8(pid)) }
            }
        }
        return result
    }
}
