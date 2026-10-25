import Foundation

/// Synthetische Klangcharaktere. Sie bilden keine konkreten Serienmotoren nach.
nonisolated enum EnginePresetID: String, CaseIterable, Codable, Sendable, Identifiable {
    case sportFour
    case deepV8
    case screamingV10
    case v12Supersport
    case turboBeast
    case demonic
    case sciFiReactor

    var id: String { rawValue }

    /// Index für die Übergabe an den Audiothread.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func fromIndex(_ index: Int) -> EnginePresetID {
        allCases.indices.contains(index) ? allCases[index] : .sportFour
    }

    var title: String {
        switch self {
        case .sportFour: "Sportlicher Vierzylinder"
        case .deepV8: "Tiefer V8"
        case .screamingV10: "Hochdrehender V10"
        case .v12Supersport: "V12-Supersport"
        case .turboBeast: "Turbo Beast"
        case .demonic: "Demonic Engine"
        case .sciFiReactor: "Sci-Fi Reactor"
        }
    }

    var shortTitle: String {
        switch self {
        case .sportFour: "R4 Sport"
        case .deepV8: "V8"
        case .screamingV10: "V10"
        case .v12Supersport: "V12"
        case .turboBeast: "Turbo"
        case .demonic: "Demonic"
        case .sciFiReactor: "Reactor"
        }
    }

    var subtitle: String {
        switch self {
        case .sportFour: "4 Zylinder, gleichmäßige Zündfolge, kerniger Ansaugton"
        case .deepV8: "8 Zylinder, Cross-Plane-Charakter mit unregelmäßigem Bank-Pulsieren"
        case .screamingV10: "10 Zylinder, hohe Drehzahl, heller Obertonschrei"
        case .v12Supersport: "12 Zylinder, sehr dichte Zündfolge, seidig und hell"
        case .turboBeast: "6 Zylinder Reihe, gedämpfter Auspuff, kräftiger Turbo"
        case .demonic: "Tiefes Grollen, aggressive Obertöne, dezenter Dämonen-Layer"
        case .sciFiReactor: "Futuristischer Reaktor, steigt mit Drehzahl und Last"
        }
    }

    var symbolName: String {
        switch self {
        case .sportFour: "engine.combustion"
        case .deepV8: "flame"
        case .screamingV10: "bolt.horizontal"
        case .v12Supersport: "crown"
        case .turboBeast: "fanblades"
        case .demonic: "flame.fill"
        case .sciFiReactor: "atom"
        }
    }

    var supportsTurbo: Bool {
        switch self {
        case .sportFour, .turboBeast, .demonic: true
        default: false
        }
    }

    /// Zylinderzahl des synthetischen Klangmodells (Information für die Oberfläche).
    var cylinderDescription: String {
        switch self {
        case .sportFour: "4 Zylinder · Zündabstand 180°"
        case .deepV8: "8 Zylinder · Zündfolge 1-8-4-3-6-5-7-2"
        case .screamingV10: "10 Zylinder · Zündabstand 72°"
        case .v12Supersport: "12 Zylinder · Zündabstand 60°"
        case .turboBeast: "6 Zylinder · Zündfolge 1-5-3-6-2-4"
        case .demonic: "8 Zylinder · unregelmäßige Impulsabstände"
        case .sciFiReactor: "Kein Verbrennungsmodell · Oszillatoren und Resonanzfilter"
        }
    }
}

/// Einstellbare Klangparameter pro Preset (alle Werte 0…1, sofern nicht anders angegeben).
nonisolated struct SoundSettings: Codable, Equatable, Sendable {
    /// Pegel des Presets (Gesamtlautstärke).
    var level: Double
    var bass: Double
    var aggressiveness: Double
    var harmonics: Double
    var turbo: Double
    /// 0 = sehr direkt, 1 = stark geglättet.
    var smoothing: Double
    /// Virtuelle Leerlaufdrehzahl des Sounds (nur bei laufendem Motor wirksam).
    var virtualIdleRPM: Double
    /// Obere virtuelle Drehzahl des Sounds.
    var virtualMaxRPM: Double
    /// Gemessene Drehzahl linear auf den virtuellen Bereich abbilden.
    var scaleToVirtualRange: Bool

    static func defaults(for preset: EnginePresetID) -> SoundSettings {
        switch preset {
        case .sportFour:
            SoundSettings(level: 0.8, bass: 0.45, aggressiveness: 0.5, harmonics: 0.55, turbo: 0.25, smoothing: 0.3,
                          virtualIdleRPM: 850, virtualMaxRPM: 7500, scaleToVirtualRange: false)
        case .deepV8:
            SoundSettings(level: 0.8, bass: 0.75, aggressiveness: 0.45, harmonics: 0.4, turbo: 0, smoothing: 0.4,
                          virtualIdleRPM: 650, virtualMaxRPM: 6800, scaleToVirtualRange: false)
        case .screamingV10:
            SoundSettings(level: 0.75, bass: 0.35, aggressiveness: 0.55, harmonics: 0.75, turbo: 0, smoothing: 0.25,
                          virtualIdleRPM: 1000, virtualMaxRPM: 9000, scaleToVirtualRange: true)
        case .v12Supersport:
            SoundSettings(level: 0.75, bass: 0.4, aggressiveness: 0.35, harmonics: 0.7, turbo: 0, smoothing: 0.3,
                          virtualIdleRPM: 950, virtualMaxRPM: 9000, scaleToVirtualRange: true)
        case .turboBeast:
            SoundSettings(level: 0.8, bass: 0.6, aggressiveness: 0.5, harmonics: 0.45, turbo: 0.75, smoothing: 0.35,
                          virtualIdleRPM: 800, virtualMaxRPM: 7200, scaleToVirtualRange: false)
        case .demonic:
            SoundSettings(level: 0.75, bass: 0.8, aggressiveness: 0.7, harmonics: 0.6, turbo: 0.2, smoothing: 0.35,
                          virtualIdleRPM: 700, virtualMaxRPM: 7000, scaleToVirtualRange: false)
        case .sciFiReactor:
            SoundSettings(level: 0.7, bass: 0.55, aggressiveness: 0.4, harmonics: 0.6, turbo: 0, smoothing: 0.45,
                          virtualIdleRPM: 900, virtualMaxRPM: 8000, scaleToVirtualRange: true)
        }
    }

    /// Begrenzt alle Werte auf sichere Bereiche.
    func sanitized() -> SoundSettings {
        var s = self
        s.level = Self.unit(level)
        s.bass = Self.unit(bass)
        s.aggressiveness = Self.unit(aggressiveness)
        s.harmonics = Self.unit(harmonics)
        s.turbo = Self.unit(turbo)
        s.smoothing = Self.unit(smoothing)
        s.virtualIdleRPM = (virtualIdleRPM.isFinite ? virtualIdleRPM : 800).clamped(400, 2000)
        s.virtualMaxRPM = (virtualMaxRPM.isFinite ? virtualMaxRPM : 7000).clamped(s.virtualIdleRPM + 1500, 12000)
        return s
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? value.clamped(0, 1) : 0.5
    }
}

/// Optionale, rein synthetische Zusatzeffekte.
nonisolated struct EffectSettings: Codable, Equatable, Sendable {
    var turboWhistle = true
    var blowOff = false
    var shiftSound = false
}
