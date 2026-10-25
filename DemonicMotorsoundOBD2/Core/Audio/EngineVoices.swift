import Foundation

/// Unveränderliche Klangdefinition eines Presets (nur skalare Werte, damit sie ohne
/// Allokation im Audiothread gelesen werden kann).
nonisolated struct VoiceScalars {
    enum Kind: Int {
        case combustion
        case reactor
    }

    var kind: Kind
    var cylinders: Int
    /// Abklingzeit des Auspuffimpulses in Sekunden.
    var decay: Float
    /// Anstiegszeit des Impulses (Sekunden).
    var attack: Float
    /// Zeitkonstante des tieffrequenten Druckstoßes (Sekunden).
    var thump: Float
    /// Erste und zweite Auspuffresonanz (Hz) – formen den Grundcharakter.
    var resonance1: Float
    var resonance2Ratio: Float
    var resonance2Gain: Float
    var bassWeight: Float
    var resonanceWeight: Float
    /// Verbrennungsrauschen, das mit jedem Zündimpuls moduliert wird.
    var raspWeight: Float
    var raspCenter: Float
    /// Ansaug-/Luftrauschen, das mit Drehzahl und Last steigt.
    var intakeWeight: Float
    var lowpassBase: Float
    var lowpassRPM: Float
    var lowpassLoad: Float
    var drive: Float
    /// Unterton bei halber Zündfrequenz (Bank-Pulsieren / „Grollen“).
    var subOctave: Float
    /// Stärke des dämonischen Zusatzlayers (Formant-Knurren und dissonanter Layer).
    var demonLayer: Float
    /// Zufällige Zyklus-zu-Zyklus-Schwankung der Impulsstärke.
    var jitter: Float
    var turboMinHz: Float
    var turboMaxHz: Float
    var turboGain: Float
    var outputTrim: Float
}

nonisolated struct VoiceDefinition {
    static let maxCylinders = 16

    var scalars: VoiceScalars
    /// Zündzeitpunkte als Anteil eines Arbeitsspiels (2 Kurbelwellenumdrehungen beim Viertakter).
    var offsets: [Float]
    var amplitudes: [Float]
    /// Resonanzfaktor je Zylinder (unterschiedliche Krümmerlängen / Bänke).
    var resonanceScale: [Float]

    /// Gleichmäßige Zündabstände.
    static func even(_ n: Int) -> [Float] {
        (0..<n).map { Float($0) / Float(n) }
    }

    static func definition(for preset: EnginePresetID) -> VoiceDefinition {
        switch preset {
        case .sportFour:
            return VoiceDefinition(
                scalars: VoiceScalars(kind: .combustion, cylinders: 4, decay: 0.006, attack: 0.00035, thump: 0.0022,
                                      resonance1: 520, resonance2Ratio: 2.6, resonance2Gain: 0.45,
                                      bassWeight: 0.8, resonanceWeight: 0.7, raspWeight: 0.35, raspCenter: 2400,
                                      intakeWeight: 0.3, lowpassBase: 1400, lowpassRPM: 4200, lowpassLoad: 1800,
                                      drive: 1.6, subOctave: 0, demonLayer: 0, jitter: 0.04,
                                      turboMinHz: 2800, turboMaxHz: 7800, turboGain: 0.6, outputTrim: 1.0),
                offsets: even(4),
                amplitudes: [1.0, 0.96, 1.03, 0.98],
                resonanceScale: [1.0, 1.02, 0.99, 1.01])
        case .deepV8:
            // Zündfolge 1-8-4-3-6-5-7-2: Bankfolge L R R L R L L R erzeugt das typische Blubbern.
            let bank: [Bool] = [true, false, false, true, false, true, true, false]
            return VoiceDefinition(
                scalars: VoiceScalars(kind: .combustion, cylinders: 8, decay: 0.011, attack: 0.0006, thump: 0.0045,
                                      resonance1: 180, resonance2Ratio: 2.35, resonance2Gain: 0.5,
                                      bassWeight: 1.25, resonanceWeight: 0.55, raspWeight: 0.25, raspCenter: 1500,
                                      intakeWeight: 0.15, lowpassBase: 650, lowpassRPM: 2200, lowpassLoad: 1400,
                                      drive: 1.4, subOctave: 0.25, demonLayer: 0, jitter: 0.06,
                                      turboMinHz: 0, turboMaxHz: 0, turboGain: 0, outputTrim: 0.9),
                offsets: even(8),
                amplitudes: bank.map { $0 ? 1.0 : 0.8 },
                resonanceScale: bank.map { $0 ? 1.0 : 1.12 })
        case .screamingV10:
            return VoiceDefinition(
                scalars: VoiceScalars(kind: .combustion, cylinders: 10, decay: 0.0045, attack: 0.00025, thump: 0.0016,
                                      resonance1: 680, resonance2Ratio: 2.8, resonance2Gain: 0.55,
                                      bassWeight: 0.6, resonanceWeight: 0.9, raspWeight: 0.3, raspCenter: 3200,
                                      intakeWeight: 0.3, lowpassBase: 2000, lowpassRPM: 6500, lowpassLoad: 2000,
                                      drive: 1.8, subOctave: 0, demonLayer: 0, jitter: 0.02,
                                      turboMinHz: 0, turboMaxHz: 0, turboGain: 0, outputTrim: 0.95),
                offsets: even(10),
                amplitudes: (0..<10).map { $0 % 2 == 0 ? 1.0 : 0.93 },
                resonanceScale: (0..<10).map { $0 % 2 == 0 ? 1.0 : 1.05 })
        case .v12Supersport:
            return VoiceDefinition(
                scalars: VoiceScalars(kind: .combustion, cylinders: 12, decay: 0.0038, attack: 0.00025, thump: 0.0014,
                                      resonance1: 820, resonance2Ratio: 2.9, resonance2Gain: 0.6,
                                      bassWeight: 0.55, resonanceWeight: 0.85, raspWeight: 0.15, raspCenter: 3600,
                                      intakeWeight: 0.3, lowpassBase: 2400, lowpassRPM: 7000, lowpassLoad: 1800,
                                      drive: 1.3, subOctave: 0, demonLayer: 0, jitter: 0.012,
                                      turboMinHz: 0, turboMaxHz: 0, turboGain: 0, outputTrim: 0.9),
                offsets: even(12),
                amplitudes: (0..<12).map { $0 % 2 == 0 ? 1.0 : 0.96 },
                resonanceScale: (0..<12).map { $0 % 2 == 0 ? 1.0 : 1.03 })
        case .turboBeast:
            return VoiceDefinition(
                scalars: VoiceScalars(kind: .combustion, cylinders: 6, decay: 0.008, attack: 0.0005, thump: 0.0032,
                                      resonance1: 260, resonance2Ratio: 2.7, resonance2Gain: 0.4,
                                      bassWeight: 1.0, resonanceWeight: 0.6, raspWeight: 0.2, raspCenter: 1800,
                                      intakeWeight: 0.35, lowpassBase: 750, lowpassRPM: 2600, lowpassLoad: 1600,
                                      drive: 1.5, subOctave: 0.1, demonLayer: 0, jitter: 0.03,
                                      turboMinHz: 2200, turboMaxHz: 9000, turboGain: 1.0, outputTrim: 0.95),
                offsets: even(6),
                amplitudes: [1.0, 0.98, 1.02, 0.97, 1.01, 0.99],
                resonanceScale: [1.0, 1.01, 0.99, 1.02, 1.0, 0.98])
        case .demonic:
            let bank: [Bool] = [true, false, false, true, false, true, true, false]
            let deviation: [Float] = [0, 0.018, -0.012, 0.025, -0.02, 0.01, 0.022, -0.015]
            return VoiceDefinition(
                scalars: VoiceScalars(kind: .combustion, cylinders: 8, decay: 0.013, attack: 0.0007, thump: 0.0055,
                                      resonance1: 140, resonance2Ratio: 3.3, resonance2Gain: 0.55,
                                      bassWeight: 1.4, resonanceWeight: 0.75, raspWeight: 0.4, raspCenter: 1300,
                                      intakeWeight: 0.2, lowpassBase: 700, lowpassRPM: 2600, lowpassLoad: 2200,
                                      drive: 2.4, subOctave: 0.55, demonLayer: 1.0, jitter: 0.06,
                                      turboMinHz: 1600, turboMaxHz: 5200, turboGain: 0.5, outputTrim: 0.85),
                offsets: zip(even(8), deviation).map { ($0 + $1 + 1).truncatingRemainder(dividingBy: 1) },
                amplitudes: bank.map { $0 ? 1.0 : 0.72 },
                resonanceScale: bank.map { $0 ? 1.0 : 1.18 })
        case .sciFiReactor:
            return VoiceDefinition(
                scalars: VoiceScalars(kind: .reactor, cylinders: 0, decay: 0.01, attack: 0.001, thump: 0.004,
                                      resonance1: 0, resonance2Ratio: 1, resonance2Gain: 0,
                                      bassWeight: 1, resonanceWeight: 1, raspWeight: 0, raspCenter: 1000,
                                      intakeWeight: 0, lowpassBase: 900, lowpassRPM: 5000, lowpassLoad: 2500,
                                      drive: 1.3, subOctave: 0, demonLayer: 0, jitter: 0,
                                      turboMinHz: 0, turboMaxHz: 0, turboGain: 0, outputTrim: 0.9),
                offsets: [], amplitudes: [], resonanceScale: [])
        }
    }
}
