import Foundation
import Observation

/// Speichert die zuletzt empfangenen Werte einer einzigen Datenquelle.
///
/// Es gibt getrennte Instanzen für Fahrzeug- und Demodaten. `ingest` weist Werte mit falscher
/// Herkunft ab, sodass Demo- und Echtdaten nie vermischt werden.
@Observable
final class VehicleDataStore {
    let origin: DataOrigin
    private(set) var latest: [VehicleSignal: SignalSample] = [:]
    private(set) var previous: [VehicleSignal: SignalSample] = [:]
    private(set) var availability: [VehicleSignal: SignalAvailability] = [:]
    private(set) var rejectedSampleCount = 0

    init(origin: DataOrigin) {
        self.origin = origin
    }

    @discardableResult
    func ingest(_ sample: SignalSample) -> Bool {
        guard sample.origin == origin, sample.value.isFinite else {
            rejectedSampleCount += 1
            return false
        }
        if let current = latest[sample.signal] {
            // Ältere oder gleich alte Werte nicht über neuere schreiben.
            guard sample.timestamp > current.timestamp else { return false }
            previous[sample.signal] = current
        }
        latest[sample.signal] = sample
        if availability[sample.signal] != .supported {
            availability[sample.signal] = .supported
        }
        return true
    }

    /// Entfernt einen einzelnen Wert (z. B. wenn die Demo ihn nicht mehr liefert).
    func remove(_ signal: VehicleSignal) {
        latest[signal] = nil
        previous[signal] = nil
    }

    func setAvailability(_ map: [VehicleSignal: SignalAvailability]) {
        availability = map
    }

    func setAvailability(_ value: SignalAvailability, for signal: VehicleSignal) {
        availability[signal] = value
    }

    func reset() {
        latest.removeAll()
        previous.removeAll()
        availability.removeAll()
    }

    func reading(_ signal: VehicleSignal, now: TimeInterval) -> SignalReading {
        let sample = latest[signal]
        let age = sample.map { max(0, now - $0.timestamp) }
        return SignalReading(
            signal: signal,
            lastValue: sample?.value,
            age: age,
            freshness: Freshness.evaluate(age: age, signal: signal),
            availability: availability[signal] ?? .unknown,
            origin: origin
        )
    }
}

/// Gesamtzustand der Datenqualität für die Anzeige.
nonisolated enum DataQuality: Equatable, Sendable {
    case noSource
    case waiting
    case good(age: TimeInterval)
    case delayed(age: TimeInterval)
    case lost(age: TimeInterval)

    static func evaluate(rpm: SignalReading) -> DataQuality {
        guard let age = rpm.age else {
            return rpm.availability == .unsupported ? .noSource : .waiting
        }
        switch rpm.freshness {
        case .fresh: return .good(age: age)
        case .aging: return .delayed(age: age)
        case .stale, .none: return .lost(age: age)
        }
    }

    var title: String {
        switch self {
        case .noSource: "Keine Drehzahl verfügbar"
        case .waiting: "Warte auf Daten"
        case .good: "Daten aktuell"
        case .delayed: "Daten verzögert"
        case .lost: "Datenverlust"
        }
    }
}
