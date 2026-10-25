import Foundation

/// Zustand der Datenbasis für den Motorsound.
nonisolated enum SoundDataState: Equatable, Sendable {
    /// Keine Drehzahl vorhanden.
    case noData
    /// Aktuelle Daten.
    case live
    /// Kurzer Aussetzer wird mit begrenzter Extrapolation bzw. Halten überbrückt.
    case bridging
    /// Daten fehlen zu lange – Sound wird ausgeblendet.
    case fadingOut
    /// Motorstillstand erkannt – Sound läuft aus.
    case engineOff

    var title: String {
        switch self {
        case .noData: "Keine Drehzahldaten"
        case .live: "Live"
        case .bridging: "Aussetzer wird überbrückt"
        case .fadingOut: "Datenverlust – Sound wird ausgeblendet"
        case .engineOff: "Motor aus – Sound läuft aus"
        }
    }
}

/// Ergebnis der Steuerlogik für den Synthesizer.
nonisolated struct SoundTarget: Equatable, Sendable {
    /// Virtuelle Sounddrehzahl (nicht die gemessene Drehzahl!).
    var virtualRPM: Double
    var load: Double
    /// 0…1: Präsenz des Motorsounds.
    var presence: Double
    var state: SoundDataState
}

/// Leitet aus der tatsächlichen OBD-Drehzahl die virtuelle Sounddrehzahl ab.
///
/// - Kurze Aussetzer werden mit begrenzter Extrapolation (max. `extrapolationLimit`) und
///   anschließendem Halten überbrückt.
/// - Danach wird der Sound weich ausgeblendet; nie läuft er unbegrenzt mit der letzten hohen
///   Drehzahl weiter.
/// - Nach Datenverlust oder Wiederverbindung blendet der Sound langsam ein.
/// - Bei Motorstillstand läuft der Sound aus. Die virtuelle Leerlaufdrehzahl gilt nur bei
///   laufendem Motor.
nonisolated struct SoundTargetFollower: Equatable {
    struct Configuration: Equatable {
        var extrapolationLimit: TimeInterval = 0.25
        var bridgeWindow: TimeInterval = 0.9
        var fadeWindow: TimeInterval = 2.5
        var maxSlope: Double = 6000 // U/min pro Sekunde
        var engineOffRPM: Double = 250
        /// Einblenden: maximal so viel Präsenz pro Sekunde.
        var presenceRiseRate: Double = 0.6
        var presenceFallTime: TimeInterval = 0.45
        var engineOffFallTime: TimeInterval = 0.7
    }

    var configuration = Configuration()
    private(set) var virtualRPM: Double = 0
    private(set) var load: Double = 0
    private(set) var presence: Double = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func reset() {
        virtualRPM = 0
        load = 0
        presence = 0
    }

    /// Bildet die gemessene auf die virtuelle Drehzahl ab.
    static func mapToVirtual(realRPM: Double, settings: SoundSettings, profile: VehicleProfile) -> Double {
        let s = settings.sanitized()
        let p = profile.sanitized()
        if s.scaleToVirtualRange {
            let span = max(p.maxRPMReference - p.idleRPMReference, 500)
            let normalized = (realRPM - p.idleRPMReference) / span
            let mapped = s.virtualIdleRPM + normalized * (s.virtualMaxRPM - s.virtualIdleRPM)
            return mapped.clamped(s.virtualIdleRPM, s.virtualMaxRPM)
        }
        return realRPM.clamped(s.virtualIdleRPM, s.virtualMaxRPM)
    }

    /// Ein Steuerschritt (typisch 50 Hz).
    mutating func step(rpm: SignalSample?, previous: SignalSample?, load loadInput: Double,
                       settings: SoundSettings, profile: VehicleProfile,
                       now: TimeInterval, dt: TimeInterval) -> SoundTarget {
        let c = configuration
        let dt = dt.clamped(0, 0.25)
        var presenceTarget: Double
        var rpmTarget: Double
        var state: SoundDataState
        var fallTime = c.presenceFallTime

        if let rpm {
            let age = max(0, now - rpm.timestamp)
            var estimate = rpm.value
            if age <= c.bridgeWindow, let previous, rpm.timestamp > previous.timestamp, rpm.timestamp - previous.timestamp < 1.5 {
                // Begrenzte Extrapolation entlang der letzten Steigung.
                let slope = ((rpm.value - previous.value) / (rpm.timestamp - previous.timestamp)).clamped(-c.maxSlope, c.maxSlope)
                estimate = rpm.value + slope * min(age, c.extrapolationLimit)
                let ceiling = max(rpm.value, previous.value) * 1.1
                estimate = estimate.clamped(0, ceiling)
            }

            if age > c.bridgeWindow {
                state = age > c.fadeWindow ? .noData : .fadingOut
                presenceTarget = 0
                // Beim Ausblenden nicht auf hoher Drehzahl verharren, sondern Richtung Leerlauf sinken.
                rpmTarget = settings.sanitized().virtualIdleRPM
            } else if estimate < c.engineOffRPM {
                state = .engineOff
                presenceTarget = 0
                rpmTarget = 0
                fallTime = c.engineOffFallTime
            } else {
                state = age > c.extrapolationLimit + 0.1 ? .bridging : .live
                presenceTarget = 1
                rpmTarget = Self.mapToVirtual(realRPM: estimate, settings: settings, profile: profile)
            }
        } else {
            state = .noData
            presenceTarget = 0
            rpmTarget = virtualRPM
        }

        // Wiedereinstieg aus der Stille: direkt auf Ziel springen (kein Hochheulen aus 0).
        if presence < 0.01 && presenceTarget > 0 {
            virtualRPM = rpmTarget
        }

        let smoothing = settings.sanitized().smoothing
        let tauUp = 0.03 + smoothing * 0.32
        let tau = rpmTarget >= virtualRPM ? tauUp : tauUp * 1.6
        if state == .engineOff {
            // Auslaufen: Drehzahl sinkt hörbar, während der Pegel abnimmt.
            virtualRPM += (rpmTarget - virtualRPM) * (1 - exp(-dt / 0.6))
        } else {
            virtualRPM += (rpmTarget - virtualRPM) * (1 - exp(-dt / tau))
        }

        let loadTarget = presenceTarget > 0 ? loadInput.clamped(0, 1) : 0
        load += (loadTarget - load) * (1 - exp(-dt / 0.08))

        if presenceTarget > presence {
            presence = min(presenceTarget, presence + c.presenceRiseRate * dt)
        } else {
            presence += (presenceTarget - presence) * (1 - exp(-dt / fallTime))
            if presence < 0.005 { presence = 0 }
        }

        return SoundTarget(virtualRPM: virtualRPM, load: load, presence: presence, state: state)
    }
}
