import Foundation

/// Monotone Zeitquelle in Sekunden.
///
/// Verwendet `ContinuousClock`, die auf Apple-Plattformen auch während des Geräteschlafs
/// weiterläuft. Dadurch wird das Alter eines Messwerts nach der Rückkehr aus dem Hintergrund
/// korrekt (und nicht zu jung) berechnet.
nonisolated protocol TimeSource: AnyObject, Sendable {
    func now() -> TimeInterval
}

nonisolated final class ContinuousTimeSource: TimeSource {
    static let shared = ContinuousTimeSource()

    private let origin = ContinuousClock.now

    func now() -> TimeInterval {
        (ContinuousClock.now - origin).seconds
    }
}

nonisolated extension Duration {
    /// Dauer als Gleitkomma-Sekunden.
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }
}

nonisolated extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}

nonisolated enum Hex {
    private static let digits: [Character] = Array("0123456789ABCDEF")

    /// Zweistellige Hex-Darstellung ohne `String(format:)` (plattformunabhängig, allokationsarm).
    static func byte(_ value: UInt8) -> String {
        String([digits[Int(value >> 4)], digits[Int(value & 0x0F)]])
    }

    /// Wandelt eine Hex-Zeichenkette (ohne Leerzeichen) in Bytes um. Liefert `nil` bei ungültigen Zeichen
    /// oder ungerader Länge.
    static func bytes(from text: Substring) -> [UInt8]? {
        guard text.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(text.count / 2)
        var high: UInt8?
        for ch in text.utf8 {
            guard let nibble = nibble(ch) else { return nil }
            if let h = high {
                result.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return result
    }

    static func nibble(_ ch: UInt8) -> UInt8? {
        switch ch {
        case 0x30...0x39: return ch - 0x30
        case 0x41...0x46: return ch - 0x41 + 10
        case 0x61...0x66: return ch - 0x61 + 10
        default: return nil
        }
    }

    static func isHexString(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { nibble($0) != nil }
    }
}
