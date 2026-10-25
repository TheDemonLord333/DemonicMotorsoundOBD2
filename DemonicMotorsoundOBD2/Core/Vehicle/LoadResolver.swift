import Foundation

/// Quelle der Lastgröße, die den Klang formt.
nonisolated enum LoadSource: Equatable, Sendable {
    case measuredLoad
    case pedal
    case throttle
    case estimated
    case none

    var title: String {
        switch self {
        case .measuredLoad: "Motorlast (gemessen)"
        case .pedal: "Gaspedal (gemessen)"
        case .throttle: "Drosselklappe (gemessen)"
        case .estimated: "Last geschätzt aus Drehzahländerung"
        case .none: "Keine Lastdaten"
        }
    }

    var isEstimate: Bool { self == .estimated }
}

/// Normalisiert Pedal- bzw. Drosselklappenwerte, deren Ruhe- und Vollgasstellung je Fahrzeug
/// unterschiedlich ist (z. B. Pedal D ≈ 15 % in Ruhe). Der Bereich passt sich an beobachtete
/// Werte an, beginnt aber mit vorsichtigen Annahmen.
nonisolated struct AdaptiveRangeNormalizer: Equatable {
    private(set) var low: Double
    private(set) var high: Double
    let minimumSpan: Double

    init(initialLow: Double, initialHigh: Double, minimumSpan: Double = 35) {
        low = initialLow
        high = initialHigh
        self.minimumSpan = minimumSpan
    }

    mutating func normalize(_ percent: Double) -> Double {
        low = min(low, percent)
        high = max(high, percent)
        let span = max(high - low, minimumSpan)
        return ((percent - low) / span).clamped(0, 1)
    }
}

/// Schätzt eine Lastgröße aus der Drehzahländerung, falls keine Lastdaten verfügbar sind.
/// Das Ergebnis ist ausdrücklich eine Schätzung und wird so gekennzeichnet.
nonisolated struct LoadEstimator: Equatable {
    private var lastRPM: Double?
    private var lastTime: TimeInterval?
    private(set) var estimate: Double = 0.2

    mutating func update(rpm: Double, time: TimeInterval) -> Double {
        defer {
            lastRPM = rpm
            lastTime = time
        }
        guard let lastRPM, let lastTime, time > lastTime else { return estimate }
        let dt = time - lastTime
        guard dt < 2 else { return estimate }
        let slope = (rpm - lastRPM) / dt // U/min pro Sekunde
        let target = (0.22 + slope / 2600).clamped(0, 1)
        estimate += (target - estimate) * min(1, dt / 0.35)
        return estimate
    }

    mutating func reset() {
        self = LoadEstimator()
    }
}

/// Bestimmt aus den verfügbaren Werten die Lastgröße für die Klangformung.
nonisolated struct LoadResolver: Equatable {
    private var pedalNormalizer = AdaptiveRangeNormalizer(initialLow: 18, initialHigh: 60)
    private var throttleNormalizer = AdaptiveRangeNormalizer(initialLow: 14, initialHigh: 60)
    private var estimator = LoadEstimator()
    private var lastEstimatorSample: TimeInterval = -1

    /// - Returns: Lastgröße 0…1 und deren Quelle.
    mutating func resolve(load: SignalReading, pedal: SignalReading, throttle: SignalReading, rpm: SignalReading, rpmTimestamp: TimeInterval?) -> (value: Double, source: LoadSource) {
        if load.freshness == .fresh, let value = load.lastValue {
            return ((value / 100).clamped(0, 1), .measuredLoad)
        }
        if pedal.freshness == .fresh, let value = pedal.lastValue {
            return (pedalNormalizer.normalize(value), .pedal)
        }
        if throttle.freshness == .fresh, let value = throttle.lastValue {
            return (throttleNormalizer.normalize(value), .throttle)
        }
        if rpm.freshness == .fresh || rpm.freshness == .aging, let value = rpm.lastValue, let time = rpmTimestamp {
            if time != lastEstimatorSample {
                lastEstimatorSample = time
                _ = estimator.update(rpm: value, time: time)
            }
            return (estimator.estimate, .estimated)
        }
        return (0, .none)
    }

    mutating func reset() {
        self = LoadResolver()
    }
}

/// Erkennt plausible Schaltvorgänge und Lastabfälle für die optionalen Audioeffekte.
/// Beides sind Schätzungen aus Drehzahl- bzw. Lastverlauf – es wird nichts direkt gemessen.
nonisolated struct DrivingEventEstimator: Equatable {
    struct Point: Equatable {
        var time: TimeInterval
        var rpm: Double
        var load: Double
    }

    private var history: [Point] = []
    private var lastShift: TimeInterval = -10
    private var lastBlowOff: TimeInterval = -10
    private var peakLoadTime: TimeInterval = -10

    struct Events: Equatable {
        var shift = false
        var blowOff = false
    }

    mutating func update(time: TimeInterval, rpm: Double, load: Double) -> Events {
        history.append(Point(time: time, rpm: rpm, load: load))
        history.removeAll { time - $0.time > 0.6 }
        if load > 0.6 { peakLoadTime = time }
        var events = Events()
        guard let oldest = history.first, time - oldest.time > 0.1 else { return events }

        let maxRPM = history.map(\.rpm).max() ?? rpm
        // Schaltvorgang: schneller Drehzahlabfall aus mittlerer/hoher Drehzahl.
        if maxRPM > 2200, maxRPM - rpm > 700, (maxRPM - rpm) / maxRPM > 0.18, time - lastShift > 1.2 {
            events.shift = true
            lastShift = time
        }
        // Lastabfall nach hoher Last (Gas weg) – Auslöser für ein synthetisches Blow-off.
        let maxLoad = history.map(\.load).max() ?? load
        if maxLoad > 0.6, load < 0.2, rpm > 1800, time - peakLoadTime < 0.6, time - lastBlowOff > 1.5 {
            events.blowOff = true
            lastBlowOff = time
        }
        return events
    }

    mutating func reset() {
        self = DrivingEventEstimator()
    }
}
