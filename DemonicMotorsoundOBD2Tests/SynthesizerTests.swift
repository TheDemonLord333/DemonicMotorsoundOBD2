import Foundation
import Testing
@testable import DemonicMotorsoundOBD2

@MainActor
struct SynthesizerTests {
    let sampleRate = 48_000.0

    private func makeSynth(preset: EnginePresetID, rpm: Float, load: Float = 0.5, presence: Float = 1) -> (EngineSynthesizer, SynthControl) {
        let control = SynthControl()
        control.apply(settings: .defaults(for: preset), preset: preset, effects: EffectSettings())
        control.masterGain.store(1)
        control.rpm.store(rpm)
        control.load.store(load)
        control.presence.store(presence)
        let synth = EngineSynthesizer(control: control, sampleRate: sampleRate)
        synth.prepare(sampleRate: sampleRate)
        return (synth, control)
    }

    private func render(_ synth: EngineSynthesizer, control: SynthControl? = nil, seconds: Double) -> [Float] {
        let frames = 512
        let total = Int(seconds * sampleRate)
        var output = [Float](repeating: 0, count: total)
        var buffer = [Float](repeating: 0, count: frames)
        var position = 0
        while position < total {
            control?.beat()
            let n = min(frames, total - position)
            _ = buffer.withUnsafeMutableBufferPointer { synth.render($0.baseAddress!, frameCount: n) }
            output.replaceSubrange(position..<(position + n), with: buffer[0..<n])
            position += n
        }
        return output
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1)))
    }

    @Test func allPresetsProduceSafeAudibleOutput() {
        for preset in EnginePresetID.allCases {
            let (synth, control) = makeSynth(preset: preset, rpm: 3500, load: 0.8)
            let out = render(synth, control: control, seconds: 2.0)
            let tail = out[(out.count / 2)...]
            #expect(out.allSatisfy { $0.isFinite }, "\(preset)")
            #expect(out.map(abs).max()! <= 0.9, "Spitzenpegel \(preset)")
            #expect(rms(tail) > 0.01, "hörbar \(preset)")
        }
    }

    @Test func presetsSoundDifferent() {
        var signatures: [EnginePresetID: (Float, Float)] = [:]
        for preset in EnginePresetID.allCases {
            let (synth, control) = makeSynth(preset: preset, rpm: 3000, load: 0.6)
            let out = Array(render(synth, control: control, seconds: 1.5)[24_000...])
            let level = rms(out[...])
            // Grobe spektrale Signatur: Anteil der Differenzenergie (Höhenanteil).
            var diff: Float = 0
            for i in 1..<out.count { diff += (out[i] - out[i - 1]) * (out[i] - out[i - 1]) }
            let brightness = sqrtf(diff / Float(out.count)) / max(level, 1e-6)
            signatures[preset] = (level, brightness)
        }
        let values = signatures.values.map(\.1)
        for (i, a) in values.enumerated() {
            for b in values[(i + 1)...] {
                #expect(abs(a - b) > 0.002)
            }
        }
    }

    @Test func firingFrequencyMatchesFourStrokeRelation() {
        // Vierzylinder bei 3000 U/min: 3000/60 · 4/2 = 100 Hz → Periode 480 Samples.
        let (synth, control) = makeSynth(preset: .sportFour, rpm: 3000, load: 0.5)
        let out = Array(render(synth, control: control, seconds: 1.5)[36_000...])
        func correlation(_ lag: Int) -> Float {
            var sum: Float = 0
            for i in 0..<(out.count - lag) { sum += out[i] * out[i + lag] }
            return sum
        }
        let candidates = Array(300...700)
        let best = candidates.max { correlation($0) < correlation($1) }!
        #expect(abs(best - 480) <= 4, "gefundene Periode \(best)")
    }

    @Test func presenceZeroFadesToSilence() {
        let (synth, control) = makeSynth(preset: .deepV8, rpm: 4000)
        _ = render(synth, control: control, seconds: 1.5)
        control.presence.store(0)
        let out = render(synth, control: control, seconds: 0.5)
        #expect(out.suffix(2400).map(abs).max()! < 1e-4)
        // Kein harter Sprung beim Ausblenden
        var maxStep: Float = 0
        for i in 1..<out.count { maxStep = max(maxStep, abs(out[i] - out[i - 1])) }
        #expect(maxStep < 0.6)
    }

    @Test func watchdogFadesWithoutControlHeartbeat() {
        let (synth, control) = makeSynth(preset: .turboBeast, rpm: 3000)
        _ = render(synth, control: control, seconds: 1.5)
        // Steuerlogik hängt: kein Heartbeat mehr.
        let out = render(synth, control: nil, seconds: 3)
        #expect(out.suffix(4800).map(abs).max()! < 1e-3)
    }

    @Test func presetSwitchIsClickFree() {
        let (synth, control) = makeSynth(preset: .sportFour, rpm: 2500)
        _ = render(synth, control: control, seconds: 1.5)
        control.apply(settings: .defaults(for: .sciFiReactor), preset: .sciFiReactor, effects: EffectSettings())
        let out = render(synth, control: control, seconds: 0.5)
        #expect(synth.activePresetIndex == EnginePresetID.sciFiReactor.index)
        var maxStep: Float = 0
        for i in 1..<out.count { maxStep = max(maxStep, abs(out[i] - out[i - 1])) }
        #expect(maxStep < 0.6)
        #expect(out.allSatisfy { $0.isFinite })
    }

    @Test func startRampAvoidsLoudOnset() {
        let (synth, control) = makeSynth(preset: .demonic, rpm: 5000, load: 1)
        let out = render(synth, control: control, seconds: 1.5)
        let first = rms(out[0..<2400])
        let later = rms(out[60_000...])
        #expect(first < later * 0.25)
    }

    @Test func effectsStayWithinLimits() {
        let (synth, control) = makeSynth(preset: .turboBeast, rpm: 5500, load: 1)
        var effects = EffectSettings()
        effects.blowOff = true
        effects.shiftSound = true
        control.apply(settings: .defaults(for: .turboBeast), preset: .turboBeast, effects: effects)
        _ = render(synth, control: control, seconds: 2.5)
        control.load.store(0)
        control.triggerBlowOff()
        control.triggerShift()
        let out = render(synth, control: control, seconds: 1)
        #expect(out.allSatisfy { $0.isFinite })
        #expect(out.map(abs).max()! <= 0.9)
    }

    @Test func renderTimeIsRealtimeCapable() {
        let (synth, _) = makeSynth(preset: .v12Supersport, rpm: 8000, load: 1)
        var buffer = [Float](repeating: 0, count: 512)
        let start = Date()
        for _ in 0..<(48_000 / 512) {
            synth.control.beat()
            _ = buffer.withUnsafeMutableBufferPointer { synth.render($0.baseAddress!, frameCount: 512) }
        }
        let elapsed = Date().timeIntervalSince(start)
        // Eine Sekunde Audio muss (auch im Debug-Build) deutlich schneller als Echtzeit sein.
        #expect(elapsed < 0.5)
    }
}
