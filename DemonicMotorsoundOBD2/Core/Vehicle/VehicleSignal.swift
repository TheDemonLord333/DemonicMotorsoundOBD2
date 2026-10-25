import Foundation

/// Fahrzeugwerte, die die App (sofern vom Fahrzeug unterstützt) liest.
///
/// Drosselklappe und Gaspedal sind bewusst getrennte Signale: Die Drosselklappe ist ein
/// Stellglied der Motorsteuerung, das Gaspedal der Fahrerwunsch. Bei elektronischem Gaspedal
/// können beide deutlich voneinander abweichen.
nonisolated enum VehicleSignal: String, CaseIterable, Codable, Sendable, Identifiable {
    case rpm
    case speed
    case throttle
    case pedal
    case load
    case coolant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rpm: "Drehzahl"
        case .speed: "Geschwindigkeit"
        case .throttle: "Drosselklappe"
        case .pedal: "Gaspedal"
        case .load: "Motorlast (berechnet)"
        case .coolant: "Kühlmitteltemperatur"
        }
    }

    var shortTitle: String {
        switch self {
        case .rpm: "Drehzahl"
        case .speed: "Tempo"
        case .throttle: "Drosselkl."
        case .pedal: "Pedal"
        case .load: "Last"
        case .coolant: "Kühlmittel"
        }
    }

    var unit: String {
        switch self {
        case .rpm: "U/min"
        case .speed: "km/h"
        case .throttle, .pedal, .load: "%"
        case .coolant: "°C"
        }
    }

    var symbolName: String {
        switch self {
        case .rpm: "gauge.with.dots.needle.67percent"
        case .speed: "speedometer"
        case .throttle: "wind"
        case .pedal: "arrowtriangle.down.fill"
        case .load: "bolt.fill"
        case .coolant: "thermometer.medium"
        }
    }

    /// Bis zu diesem Alter gilt ein Wert als aktuell.
    var freshLimit: TimeInterval {
        switch self {
        case .rpm: 0.75
        case .speed: 2.0
        case .throttle, .pedal, .load: 1.5
        case .coolant: 15
        }
    }

    /// Ab diesem Alter wird kein Zahlenwert mehr angezeigt, sondern „Keine aktuellen Daten“.
    var staleLimit: TimeInterval {
        switch self {
        case .rpm: 2.5
        case .speed: 5
        case .throttle, .pedal, .load: 4
        case .coolant: 45
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .rpm: String(Int(value.rounded()))
        case .speed, .coolant: String(Int(value.rounded()))
        case .throttle, .pedal, .load: String(Int(value.rounded()))
        }
    }
}

/// Herkunft eines Messwerts. Demo- und Fahrzeugdaten werden niemals vermischt.
nonisolated enum DataOrigin: String, Codable, Sendable {
    case vehicle
    case demo
}

nonisolated struct SignalSample: Equatable, Sendable {
    var signal: VehicleSignal
    var value: Double
    var timestamp: TimeInterval
    var origin: DataOrigin
}

/// Unterstützung eines Signals durch das verbundene Fahrzeug.
nonisolated enum SignalAvailability: Equatable, Sendable {
    /// Noch nicht ermittelt (keine Verbindung oder Erkennung läuft).
    case unknown
    case supported
    case unsupported
}

nonisolated enum Freshness: Equatable, Sendable {
    /// Wert wurde nie empfangen.
    case none
    case fresh
    /// Leicht verzögert; Wert wird mit Hinweis angezeigt.
    case aging
    /// Zu alt: Wert wird nicht mehr als Zahl angezeigt.
    case stale

    static func evaluate(age: TimeInterval?, signal: VehicleSignal) -> Freshness {
        guard let age else { return .none }
        if age <= signal.freshLimit { return .fresh }
        if age <= signal.staleLimit { return .aging }
        return .stale
    }

    var label: String {
        switch self {
        case .none: "Keine Daten"
        case .fresh: "Aktuell"
        case .aging: "Verzögert"
        case .stale: "Veraltet"
        }
    }
}

/// Aufbereiteter Wert für die Anzeige.
nonisolated struct SignalReading: Equatable, Sendable {
    var signal: VehicleSignal
    /// Letzter gemessener Wert (auch wenn veraltet) – nur für interne Logik.
    var lastValue: Double?
    var age: TimeInterval?
    var freshness: Freshness
    var availability: SignalAvailability
    var origin: DataOrigin

    /// Wert, der angezeigt werden darf. Veraltete Werte werden nicht als aktuell ausgegeben.
    var displayValue: Double? {
        switch freshness {
        case .fresh, .aging: lastValue
        case .none, .stale: nil
        }
    }

    var statusText: String {
        if availability == .unsupported { return "Nicht verfügbar" }
        switch freshness {
        case .none: return availability == .supported ? "Warte auf Daten" : "Nicht verfügbar"
        case .fresh: return origin == .demo ? "Demo" : "Aktuell"
        case .aging: return "Verzögert"
        case .stale: return "Veraltet"
        }
    }
}
