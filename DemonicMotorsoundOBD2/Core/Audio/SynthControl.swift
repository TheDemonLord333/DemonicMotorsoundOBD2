import Foundation
import Synchronization

/// Lock-freier Float-Wert für die Übergabe an den Audiothread.
nonisolated struct AtomicFloat: ~Copyable, Sendable {
    private let bits: Atomic<UInt32>

    init(_ value: Float) {
        bits = Atomic(value.bitPattern)
    }

    func load() -> Float {
        Float(bitPattern: bits.load(ordering: .relaxed))
    }

    func store(_ value: Float) {
        bits.store(value.isFinite ? value.bitPattern : Float(0).bitPattern, ordering: .relaxed)
    }
}

/// Gemeinsame Parameter zwischen Steuerlogik (Hauptthread) und Render-Callback (Echtzeitthread).
///
/// Jeder Wert ist ein einzelnes Atomic – der Audiothread liest ohne Locks oder Allokationen.
/// Kleine zeitliche Inkonsistenzen zwischen einzelnen Parametern sind unkritisch, da der
/// Synthesizer alle Werte zusätzlich glättet.
nonisolated final class SynthControl: Sendable {
    // Fahr-/Datenzustand
    let rpm = AtomicFloat(0)
    let load = AtomicFloat(0)
    /// 0 = Motorsound aus (z. B. Motor steht oder Datenverlust), 1 = voll präsent.
    let presence = AtomicFloat(0)

    // Pegel
    let masterGain = AtomicFloat(0.6)
    let presetLevel = AtomicFloat(0.8)

    // Klangparameter
    let bass = AtomicFloat(0.5)
    let aggressiveness = AtomicFloat(0.5)
    let harmonics = AtomicFloat(0.5)
    let turbo = AtomicFloat(0)
    let idleRPM = AtomicFloat(800)
    let maxRPM = AtomicFloat(7000)

    // Schalter (0/1)
    let turboEnabled = AtomicFloat(1)
    let blowOffEnabled = AtomicFloat(0)
    let shiftEnabled = AtomicFloat(0)

    let presetIndex = Atomic<Int>(0)
    /// Ereigniszähler: Jede Erhöhung löst den Effekt einmal aus.
    let blowOffCounter = Atomic<UInt32>(0)
    let shiftCounter = Atomic<UInt32>(0)
    /// Lebenszeichen der Steuerlogik. Bleibt es aus, blendet der Synthesizer selbstständig aus.
    let heartbeat = Atomic<UInt32>(0)

    init() {}

    func triggerBlowOff() {
        blowOffCounter.wrappingAdd(1, ordering: .relaxed)
    }

    func triggerShift() {
        shiftCounter.wrappingAdd(1, ordering: .relaxed)
    }

    func beat() {
        heartbeat.wrappingAdd(1, ordering: .relaxed)
    }

    /// Überträgt die Einstellungen eines Presets.
    func apply(settings: SoundSettings, preset: EnginePresetID, effects: EffectSettings) {
        let s = settings.sanitized()
        presetLevel.store(Float(s.level))
        bass.store(Float(s.bass))
        aggressiveness.store(Float(s.aggressiveness))
        harmonics.store(Float(s.harmonics))
        turbo.store(preset.supportsTurbo ? Float(s.turbo) : 0)
        idleRPM.store(Float(s.virtualIdleRPM))
        maxRPM.store(Float(s.virtualMaxRPM))
        turboEnabled.store(effects.turboWhistle ? 1 : 0)
        blowOffEnabled.store(effects.blowOff ? 1 : 0)
        shiftEnabled.store(effects.shiftSound ? 1 : 0)
        presetIndex.store(preset.index, ordering: .relaxed)
    }
}
