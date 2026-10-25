import Foundation
import Synchronization

// MARK: - DSP-Bausteine

/// Zustandsvariablenfilter (TPT-Struktur nach Andrew Simper). Stabil bei Modulation.
nonisolated struct StateVariableFilter {
    private var ic1: Float = 0
    private var ic2: Float = 0
    private var a1: Float = 1
    private var a2: Float = 0
    private var a3: Float = 0
    private var k: Float = 1

    mutating func setup(cutoff: Float, q: Float, sampleRate: Float) {
        let fc = min(max(cutoff, 20), sampleRate * 0.45)
        let g = tanf(Float.pi * fc / sampleRate)
        k = 1 / max(q, 0.1)
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    /// Liefert Tiefpass- und Bandpassausgang.
    @inline(__always)
    mutating func process(_ v0: Float) -> (low: Float, band: Float) {
        let v3 = v0 - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1)
    }

    mutating func reset() {
        ic1 = 0
        ic2 = 0
    }
}

@inline(__always)
nonisolated func softClip(_ x: Float) -> Float {
    // Padé-Näherung von tanh, für |x| > 3 begrenzt.
    let c = min(max(x, -3), 3)
    let c2 = c * c
    return c * (27 + c2) / (27 + 9 * c2)
}

@inline(__always)
nonisolated func smoothingCoefficient(time: Float, sampleRate: Float) -> Float {
    1 - expf(-1 / max(time * sampleRate, 1))
}

// MARK: - Synthesizer

/// Prozeduraler Motorsound-Synthesizer.
///
/// Das Klangmodell erzeugt pro Zylinder phasenkontinuierliche Zündimpulse: Die Phase eines
/// Arbeitsspiels läuft beim Viertakter mit `Drehzahl / 120` Hz (ein Arbeitsspiel = zwei
/// Kurbelwellenumdrehungen), jeder Zylinder zündet einmal pro Arbeitsspiel an seinem Versatz.
/// Die Zündfrequenz beträgt damit `Drehzahl / 60 × Zylinder / 2`. Jeder Impuls besteht aus einem
/// tieffrequenten Druckstoß und gedämpften Auspuffresonanzen; dazu kommen impulsmoduliertes
/// Verbrennungsrauschen, Ansaugrauschen, lastabhängige Filterung und Sättigung.
///
/// Echtzeitregeln: `render` alloziert nicht, nutzt keine Locks, keine Datei- oder Netzwerkzugriffe.
/// Parameter kommen ausschließlich über die Atomics in `SynthControl`.
nonisolated final class EngineSynthesizer: @unchecked Sendable {
    let control: SynthControl
    private(set) var sampleRate: Float

    private let presetCount: Int
    private let voices: UnsafeMutablePointer<VoiceScalars>
    private let offsets: UnsafeMutablePointer<Float>
    private let amplitudes: UnsafeMutablePointer<Float>
    private let resonanceScales: UnsafeMutablePointer<Float>
    private let cylinderPreviousTau: UnsafeMutablePointer<Float>
    private let cylinderJitter: UnsafeMutablePointer<Float>
    private let reactorPhases: UnsafeMutablePointer<Double>

    private struct State {
        // Geglättete Parameter
        var rpm: Float = 0
        var load: Float = 0
        var presence: Float = 0
        var master: Float = 0
        var level: Float = 0.8
        var bass: Float = 0.5
        var aggression: Float = 0.5
        var harmonics: Float = 0.5
        var turbo: Float = 0
        var idle: Float = 800
        var maxRPM: Float = 7000

        var cyclePhase: Double = 0
        var activePreset = 0
        var switchGain: Float = 1
        var switchDirection: Int = 0
        var startRamp: Float = 0

        var tone = StateVariableFilter()
        var rasp = StateVariableFilter()
        var intake = StateVariableFilter()
        var growl1 = StateVariableFilter()
        var growl2 = StateVariableFilter()
        var blow = StateVariableFilter()
        var shift = StateVariableFilter()
        var plasma = StateVariableFilter()
        var turboHiss = StateVariableFilter()
        var bassLow: Float = 0
        var preX: Float = 0
        var preY: Float = 0
        var dcX: Float = 0
        var dcY: Float = 0
        var limiterEnv: Float = 0

        var noise: UInt32 = 0x9E37_79B9

        var spool: Float = 0
        var turboPhase: Double = 0
        var blowEnv: Float = 0
        var lastBlowCounter: UInt32 = 0
        var shiftEnv: Float = 0
        var shiftTime: Float = 1
        var lastShiftCounter: UInt32 = 0

        var detunePhase: Double = 0
        var growlLFO: Double = 0
        var fmPhase: Double = 0
        var carrierPhase: Double = 0
        var throbPhase: Double = 0

        var lastHeartbeat: UInt32 = 0
        var samplesSinceBeat: Int = 0
        var watchdogGain: Float = 1

        var controlCounter = 0
    }

    private var state = State()

    init(control: SynthControl, sampleRate: Double = 48_000) {
        self.control = control
        self.sampleRate = Float(sampleRate)
        let definitions = EnginePresetID.allCases.map { VoiceDefinition.definition(for: $0) }
        presetCount = definitions.count
        let maxCyl = VoiceDefinition.maxCylinders
        voices = .allocate(capacity: presetCount)
        offsets = .allocate(capacity: presetCount * maxCyl)
        amplitudes = .allocate(capacity: presetCount * maxCyl)
        resonanceScales = .allocate(capacity: presetCount * maxCyl)
        offsets.initialize(repeating: 0, count: presetCount * maxCyl)
        amplitudes.initialize(repeating: 0, count: presetCount * maxCyl)
        resonanceScales.initialize(repeating: 1, count: presetCount * maxCyl)
        cylinderPreviousTau = .allocate(capacity: maxCyl)
        cylinderPreviousTau.initialize(repeating: 0, count: maxCyl)
        cylinderJitter = .allocate(capacity: maxCyl)
        cylinderJitter.initialize(repeating: 1, count: maxCyl)
        reactorPhases = .allocate(capacity: 4)
        reactorPhases.initialize(repeating: 0, count: 4)

        for (p, definition) in definitions.enumerated() {
            var scalars = definition.scalars
            scalars.cylinders = min(scalars.cylinders, maxCyl, definition.offsets.count)
            (voices + p).initialize(to: scalars)
            for c in 0..<scalars.cylinders {
                offsets[p * maxCyl + c] = definition.offsets[c]
                amplitudes[p * maxCyl + c] = c < definition.amplitudes.count ? definition.amplitudes[c] : 1
                resonanceScales[p * maxCyl + c] = c < definition.resonanceScale.count ? definition.resonanceScale[c] : 1
            }
        }
        state.activePreset = control.presetIndex.load(ordering: .relaxed).clamped(0, presetCount - 1)
        updateControlRate(&state, voice: voices[state.activePreset], frames: 0)
    }

    deinit {
        voices.deinitialize(count: presetCount)
        voices.deallocate()
        offsets.deallocate()
        amplitudes.deallocate()
        resonanceScales.deallocate()
        cylinderPreviousTau.deallocate()
        cylinderJitter.deallocate()
        reactorPhases.deallocate()
    }

    /// Setzt die Abtastrate. Darf nur aufgerufen werden, während nicht gerendert wird.
    func prepare(sampleRate: Double) {
        self.sampleRate = Float(max(8_000, sampleRate))
        resetForStart()
    }

    /// Setzt den DSP-Zustand zurück und startet mit einer sanften Einblendung.
    /// Darf nur aufgerufen werden, während nicht gerendert wird.
    func resetForStart() {
        var fresh = State()
        fresh.activePreset = control.presetIndex.load(ordering: .relaxed).clamped(0, presetCount - 1)
        fresh.rpm = control.rpm.load()
        fresh.idle = control.idleRPM.load()
        fresh.maxRPM = control.maxRPM.load()
        fresh.lastBlowCounter = control.blowOffCounter.load(ordering: .relaxed)
        fresh.lastShiftCounter = control.shiftCounter.load(ordering: .relaxed)
        fresh.lastHeartbeat = control.heartbeat.load(ordering: .relaxed)
        state = fresh
        cylinderPreviousTau.update(repeating: 0, count: VoiceDefinition.maxCylinders)
        cylinderJitter.update(repeating: 1, count: VoiceDefinition.maxCylinders)
        reactorPhases.update(repeating: 0, count: 4)
        updateControlRate(&state, voice: voices[state.activePreset], frames: 0)
    }

    /// Aktuell aktives Preset im Audiothread (für Tests/Diagnose).
    var activePresetIndex: Int { state.activePreset }

    // MARK: Rendern

    /// Füllt `output` mit `frameCount` Mono-Samples. Gibt `true` zurück, wenn der Block stumm ist.
    @discardableResult
    func render(_ output: UnsafeMutablePointer<Float>, frameCount: Int) -> Bool {
        var s = state
        let sr = sampleRate
        let invSR = 1 / sr
        let invSRd = 1 / Double(sr)
        let c = control

        // Zielwerte lesen (lock-frei)
        let tRPM = max(0, c.rpm.load())
        let tLoad = c.load.load().clamped(0, 1)
        let tPresence = c.presence.load().clamped(0, 1)
        let tMaster = c.masterGain.load().clamped(0, 1)
        let tLevel = c.presetLevel.load().clamped(0, 1)
        let tBass = c.bass.load().clamped(0, 1)
        let tAggr = c.aggressiveness.load().clamped(0, 1)
        let tHarm = c.harmonics.load().clamped(0, 1)
        let tTurbo = c.turbo.load().clamped(0, 1)
        let tIdle = c.idleRPM.load().clamped(300, 3000)
        let tMax = max(c.maxRPM.load(), tIdle + 1000)
        let turboOn = c.turboEnabled.load() > 0.5
        let blowOn = c.blowOffEnabled.load() > 0.5
        let shiftOn = c.shiftEnabled.load() > 0.5

        // Presetwechsel: erst ausblenden, dann umschalten und wieder einblenden.
        let requested = c.presetIndex.load(ordering: .relaxed).clamped(0, presetCount - 1)
        if requested != s.activePreset && s.switchDirection == 0 {
            s.switchDirection = -1
        }

        // Watchdog: Bleibt das Lebenszeichen der Steuerlogik aus, wird ausgeblendet.
        let beat = c.heartbeat.load(ordering: .relaxed)
        if beat != s.lastHeartbeat {
            s.lastHeartbeat = beat
            s.samplesSinceBeat = 0
        } else {
            s.samplesSinceBeat += frameCount
        }
        let watchdogTarget: Float = s.samplesSinceBeat > Int(sr * 1.0) ? 0 : 1

        // Effekt-Auslöser
        let blowCounter = c.blowOffCounter.load(ordering: .relaxed)
        if blowCounter != s.lastBlowCounter {
            s.lastBlowCounter = blowCounter
            let voice = voices[s.activePreset]
            if blowOn && voice.turboGain > 0 && s.spool > 0.2 && tTurbo > 0.01 {
                s.blowEnv = min(1, 0.35 + s.spool)
                s.spool *= 0.35
            }
        }
        let shiftCounter = c.shiftCounter.load(ordering: .relaxed)
        if shiftCounter != s.lastShiftCounter {
            s.lastShiftCounter = shiftCounter
            if shiftOn {
                s.shiftEnv = 1
                s.shiftTime = 0
            }
        }

        let kParam = smoothingCoefficient(time: 0.025, sampleRate: sr)
        let kRPM = smoothingCoefficient(time: 0.012, sampleRate: sr)
        let kPresence = smoothingCoefficient(time: 0.015, sampleRate: sr)
        let kWatchDown = smoothingCoefficient(time: 0.25, sampleRate: sr)
        let kWatchUp = smoothingCoefficient(time: 0.8, sampleRate: sr)
        let switchOutStep = 1 / (0.05 * sr)
        let switchInStep = 1 / (0.09 * sr)
        let startStep = 1 / (1.2 * sr)
        let blowDecay = expf(-1 / (0.38 * sr))
        let shiftDecay = expf(-1 / (0.06 * sr))
        let limiterRelease = expf(-1 / (0.12 * sr))
        let bassCoef = 1 - expf(-2 * Float.pi * 160 * invSR)
        let preHighpass = expf(-2 * Float.pi * 25 * invSR)
        let maxCyl = VoiceDefinition.maxCylinders

        var peak: Float = 0
        var voice = voices[s.activePreset]

        for frame in 0..<frameCount {
            // --- Parameterglättung
            s.rpm += (tRPM - s.rpm) * kRPM
            s.load += (tLoad - s.load) * kParam
            s.presence += (tPresence - s.presence) * kPresence
            s.master += (tMaster - s.master) * kParam
            s.level += (tLevel - s.level) * kParam
            s.bass += (tBass - s.bass) * kParam
            s.aggression += (tAggr - s.aggression) * kParam
            s.harmonics += (tHarm - s.harmonics) * kParam
            s.turbo += (tTurbo - s.turbo) * kParam
            s.idle += (tIdle - s.idle) * kParam
            s.maxRPM += (tMax - s.maxRPM) * kParam
            s.watchdogGain += (watchdogTarget - s.watchdogGain) * (watchdogTarget < s.watchdogGain ? kWatchDown : kWatchUp)
            s.startRamp = min(1, s.startRamp + startStep)

            if s.switchDirection < 0 {
                s.switchGain -= switchOutStep
                if s.switchGain <= 0 {
                    s.switchGain = 0
                    s.activePreset = c.presetIndex.load(ordering: .relaxed).clamped(0, presetCount - 1)
                    voice = voices[s.activePreset]
                    resetFilters(&s)
                    s.switchDirection = 1
                }
            } else if s.switchDirection > 0 {
                s.switchGain += switchInStep
                if s.switchGain >= 1 {
                    s.switchGain = 1
                    s.switchDirection = 0
                }
            }

            // --- Steuerrate (alle 32 Samples): Filterkoeffizienten und Turbo
            if s.controlCounter == 0 {
                updateControlRate(&s, voice: voice, frames: 32)
            }
            s.controlCounter = (s.controlCounter + 1) & 31

            let rpmNorm = ((s.rpm - s.idle) / max(s.maxRPM - s.idle, 1)).clamped(0, 1)
            let cycleRate = s.rpm / 120 // Arbeitsspiele pro Sekunde (Viertakt)
            s.cyclePhase += Double(cycleRate) * invSRd
            if s.cyclePhase >= 1 { s.cyclePhase -= s.cyclePhase.rounded(.down) }
            let phase = Float(s.cyclePhase)

            let white = nextNoise(&s.noise)
            var y: Float = 0

            if voice.kind == .combustion {
                let n = voice.cylinders
                let base = s.activePreset * maxCyl
                let invCycle = 1 / max(cycleRate, 0.5)
                let window = min(Float(0.95), 3.0 / Float(max(n, 1)))
                let invWindow = 1 / window
                let invDecay = 1 / voice.decay
                let invThump = 1 / voice.thump
                let bassGain = voice.bassWeight * (0.55 + s.bass)
                let resGain = voice.resonanceWeight * (0.35 + s.harmonics)
                let twoPiRes = 2 * Float.pi * voice.resonance1
                var exhaust: Float = 0
                var envSum: Float = 0

                for i in 0..<n {
                    var tau = phase - offsets[base + i]
                    if tau < 0 { tau += 1 }
                    if tau < cylinderPreviousTau[i] {
                        // Neuer Zündzeitpunkt dieses Zylinders: Zyklusschwankung würfeln.
                        cylinderJitter[i] = 1 + voice.jitter * nextNoise(&s.noise)
                    }
                    cylinderPreviousTau[i] = tau
                    if tau >= window { continue }
                    let x = tau * invWindow
                    let win = (1 - x) * (1 - x) * (1 + 2 * x)
                    let t = tau * invCycle
                    let env = expf(-t * invDecay)
                    let attack = t / (t + voice.attack)
                    let tx = t * invThump
                    let thump = tx * expf(1 - tx)
                    let ph = twoPiRes * resonanceScales[base + i] * t
                    let resonance = sinf(ph) + voice.resonance2Gain * sinf(ph * voice.resonance2Ratio + 0.7)
                    let a = amplitudes[base + i] * cylinderJitter[i] * win
                    exhaust += a * (bassGain * thump + resGain * attack * env * resonance)
                    envSum += a * attack * env
                }
                exhaust *= 2 / sqrtf(Float(max(n, 1)))
                // Gleichanteil der überlappenden Druckstöße vor der Sättigung entfernen,
                // sonst würde die Sättigungsstufe dauerhaft in die Begrenzung gefahren.
                let highpassed = exhaust - s.preX + preHighpass * s.preY
                s.preX = exhaust
                s.preY = highpassed
                exhaust = highpassed

                let rasp = s.rasp.process(white * envSum * voice.raspWeight * (0.3 + s.aggression)).band
                let intakeAmp = voice.intakeWeight * (0.15 + 0.85 * s.load) * (0.25 + 0.75 * rpmNorm)
                let intake = s.intake.process(white * intakeAmp).band
                var bus = exhaust + rasp * 1.6 + intake * 1.2

                bus = s.tone.process(bus).low
                s.bassLow += (bus - s.bassLow) * bassCoef
                bus += s.bassLow * s.bass * 1.3

                if voice.subOctave > 0 {
                    // Unterton bei halber Zündfrequenz, phasenstarr zur Arbeitsspielphase.
                    let order = Float(max(n, 2)) * 0.5
                    let sub = sinf(2 * Float.pi * phase * order)
                    bus += voice.subOctave * (0.25 + 0.6 * s.bass) * (0.35 + 0.65 * s.load) * sub * 0.6
                }

                if voice.demonLayer > 0 {
                    let growl = s.growl1.process(bus).band * 1.3 + s.growl2.process(bus).band * 0.8
                    bus += voice.demonLayer * growl * (0.3 + 0.7 * s.aggression)
                    // Dezenter, leicht dissonanter Layer (ca. Tritonus unter der Zündfrequenz).
                    let firing = Double(cycleRate) * Double(n)
                    s.detunePhase += firing * 0.7071 * invSRd
                    if s.detunePhase >= 1 { s.detunePhase -= s.detunePhase.rounded(.down) }
                    let dp = Float(s.detunePhase) * 2 * Float.pi
                    let dark = sinf(dp) + 0.35 * sinf(2 * dp)
                    bus += voice.demonLayer * 0.06 * dark * (0.3 + s.load) * (0.5 + s.aggression) * min(1, rpmNorm * 4 + 0.3)
                }

                let drive = voice.drive * (1 + 1.6 * s.aggression + 0.8 * s.load * s.aggression)
                y = softClip(bus * drive * 0.3) / (0.3 * sqrtf(drive))
                y += s.harmonics * 0.12 * y * abs(y)
                y *= 0.55 + 0.45 * s.load
            } else {
                y = renderReactor(&s, rpmNorm: rpmNorm, white: white, invSRd: invSRd, phase: phase)
            }

            // --- Turbo (synthetisch)
            if turboOn && voice.turboGain > 0 && s.turbo > 0.001 {
                let freq = voice.turboMinHz + (voice.turboMaxHz - voice.turboMinHz) * s.spool
                s.turboPhase += Double(freq) * invSRd
                if s.turboPhase >= 1 { s.turboPhase -= s.turboPhase.rounded(.down) }
                let tp = Float(s.turboPhase) * 2 * Float.pi
                let whistle = sinf(tp) + 0.25 * sinf(2 * tp + 0.3)
                let hiss = s.turboHiss.process(white).band
                y += (whistle * 0.055 + hiss * 0.05) * s.turbo * s.spool * s.spool * voice.turboGain
            }

            // --- Blow-off (synthetisch)
            if s.blowEnv > 0.0005 {
                let burst = s.blow.process(white).band
                y += burst * s.blowEnv * 0.32
                s.blowEnv *= blowDecay
            } else {
                s.blowEnv = 0
            }

            // --- Schaltgeräusch (synthetisch, dezent)
            if s.shiftEnv > 0.0005 {
                let click = s.shift.process(white).band * 0.18
                let clunk = sinf(2 * Float.pi * 90 * s.shiftTime) * expf(-s.shiftTime / 0.025) * 0.2
                y += (click + clunk) * s.shiftEnv
                s.shiftEnv *= shiftDecay
                s.shiftTime += invSR
            } else {
                s.shiftEnv = 0
            }

            // --- Pegel, DC-Sperre, Begrenzer
            y *= 0.7 * voice.outputTrim * s.level * s.presence * s.switchGain * s.watchdogGain * s.startRamp
            let dc = y - s.dcX + 0.9985 * s.dcY
            s.dcX = y
            s.dcY = dc
            y = dc

            let magnitude = abs(y)
            s.limiterEnv = magnitude > s.limiterEnv ? magnitude : s.limiterEnv * limiterRelease + magnitude * (1 - limiterRelease)
            let threshold: Float = 0.55
            if s.limiterEnv > threshold { y *= threshold / s.limiterEnv }
            y = 0.89 * softClip(y / 0.89) * s.master

            if !y.isFinite {
                resetFilters(&s)
                s.dcX = 0
                s.dcY = 0
                s.limiterEnv = 0
                y = 0
            }
            output[frame] = y
            peak = max(peak, abs(y))
        }

        state = s
        return peak < 1e-6
    }

    private func renderReactor(_ s: inout State, rpmNorm: Float, white: Float, invSRd: Double, phase: Float) -> Float {
        let f0 = 38 + 170 * rpmNorm + 35 * s.load
        var hum: Float = 0
        for k in 0..<3 {
            let detune: Float = k == 0 ? 1 : (k == 1 ? 1.006 : 0.993)
            reactorPhases[k] += Double(f0 * detune) * invSRd
            if reactorPhases[k] >= 1 { reactorPhases[k] -= reactorPhases[k].rounded(.down) }
            let p = Float(reactorPhases[k]) * 2 * Float.pi
            hum += sinf(p) + 0.5 * sinf(2 * p) + 0.25 * s.harmonics * sinf(3 * p)
        }
        hum *= 0.3 * (0.4 + s.bass)

        s.fmPhase += Double(f0 * 1.5) * invSRd
        if s.fmPhase >= 1 { s.fmPhase -= s.fmPhase.rounded(.down) }
        s.carrierPhase += Double(f0 * 6 * (1 + 0.5 * rpmNorm)) * invSRd
        if s.carrierPhase >= 1 { s.carrierPhase -= s.carrierPhase.rounded(.down) }
        let index = 1 + 3 * s.load
        let whine = sinf(Float(s.carrierPhase) * 2 * Float.pi + index * sinf(Float(s.fmPhase) * 2 * Float.pi))
            * (0.05 + 0.2 * s.harmonics * (0.3 + rpmNorm))

        s.throbPhase += Double(0.6 + 6 * rpmNorm) * invSRd
        if s.throbPhase >= 1 { s.throbPhase -= s.throbPhase.rounded(.down) }
        let throb = 0.5 + 0.5 * sinf(Float(s.throbPhase) * 2 * Float.pi)
        let plasma = s.plasma.process(white).band * (0.12 + 0.35 * s.aggression) * (0.4 + 0.6 * throb)

        // Leichte Kopplung an den Motorrhythmus
        let pulse = sinf(phase * 2 * Float.pi * 3) * 0.08 * (0.3 + s.load)

        var y = hum + whine + plasma + pulse
        y = s.tone.process(y).low
        let drive = 1.2 + 1.5 * s.aggression
        y = softClip(y * drive) / sqrtf(drive)
        return y * (0.6 + 0.4 * s.load)
    }

    private func updateControlRate(_ s: inout State, voice: VoiceScalars, frames: Int) {
        let sr = sampleRate
        let rpmNorm = ((s.rpm - s.idle) / max(s.maxRPM - s.idle, 1)).clamped(0, 1)
        var cutoff = (voice.lowpassBase + voice.lowpassRPM * rpmNorm + voice.lowpassLoad * s.load) * (0.7 + 0.6 * s.harmonics)
        if voice.kind == .reactor {
            cutoff = voice.lowpassBase + voice.lowpassRPM * rpmNorm + voice.lowpassLoad * s.load
        }
        s.tone.setup(cutoff: cutoff, q: 0.7 + 0.6 * s.aggression, sampleRate: sr)
        s.rasp.setup(cutoff: voice.raspCenter * (1 + 0.6 * rpmNorm), q: 0.8, sampleRate: sr)
        s.intake.setup(cutoff: 250 + 1800 * rpmNorm, q: 1.2, sampleRate: sr)
        if voice.demonLayer > 0 {
            s.growlLFO += Double(frames) / Double(sr) * 0.17
            if s.growlLFO >= 1 { s.growlLFO -= 1 }
            let lfo = sinf(Float(s.growlLFO) * 2 * Float.pi)
            s.growl1.setup(cutoff: 320 * (1 + 0.12 * lfo) + 120 * rpmNorm, q: 3.5, sampleRate: sr)
            s.growl2.setup(cutoff: 780 * (1 - 0.1 * lfo) + 300 * rpmNorm, q: 4, sampleRate: sr)
        }
        if voice.kind == .reactor {
            s.plasma.setup(cutoff: 200 + 3800 * (0.5 * rpmNorm + 0.5 * s.load), q: 4, sampleRate: sr)
        }
        if voice.turboGain > 0 {
            // Turbo-Ladedruck (geschätzt aus Last und Drehzahl): langsamer Aufbau, schneller Abbau.
            let target = (s.load * 1.25 - 0.2).clamped(0, 1) * ((rpmNorm - 0.08) * 2.2).clamped(0, 1)
            let dt = Float(frames) / sr
            let tau: Float = target > s.spool ? 0.9 : 0.3
            s.spool += (target - s.spool) * min(1, dt / tau)
            s.turboHiss.setup(cutoff: 5000 + 3000 * s.spool, q: 2, sampleRate: sr)
        }
        if s.blowEnv > 0 {
            s.blow.setup(cutoff: 900 + 2600 * s.blowEnv, q: 1.4, sampleRate: sr)
        }
        if s.shiftEnv > 0 {
            s.shift.setup(cutoff: 1900, q: 3, sampleRate: sr)
        }
    }

    private func resetFilters(_ s: inout State) {
        s.tone.reset()
        s.rasp.reset()
        s.intake.reset()
        s.growl1.reset()
        s.growl2.reset()
        s.plasma.reset()
        s.turboHiss.reset()
        s.bassLow = 0
        s.preX = 0
        s.preY = 0
    }

    @inline(__always)
    private func nextNoise(_ x: inout UInt32) -> Float {
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        return Float(x) * (2.0 / 4_294_967_296.0) - 1
    }
}
