import Foundation
import Observation

/// Betriebsart. Demo- und Echtbetrieb sind strikt getrennt.
nonisolated enum OperatingMode: String, Codable, Sendable {
    case live
    case demo
}

/// Verbindet Fahrzeug- bzw. Demodaten mit dem Synthesizer (Steuerrate ca. 50 Hz).
///
/// Hält getrennte Datenspeicher für Echt- und Demodaten und liest ausschließlich aus dem
/// Speicher der aktiven Betriebsart.
@Observable
final class SoundDriver {
    let control: SynthControl
    let liveStore = VehicleDataStore(origin: .vehicle)
    let demoStore = VehicleDataStore(origin: .demo)

    private(set) var mode: OperatingMode = .live
    var demo = DemoSimulator()

    private(set) var target = SoundTarget(virtualRPM: 0, load: 0, presence: 0, state: .noData)
    private(set) var loadSource: LoadSource = .none
    private(set) var loadValue: Double = 0
    private(set) var lastDemoOutput: DemoSimulator.Output?
    /// Letztes geschätztes Ereignis (Anzeige), z. B. „Schaltvorgang (geschätzt)“.
    private(set) var lastEventText: String?
    private(set) var lastEventTime: TimeInterval = -100

    var soundSettings = SoundSettings.defaults(for: .sportFour)
    var preset: EnginePresetID = .sportFour
    var effects = EffectSettings()
    var profile = VehicleProfile.hondaJazz2015
    var masterVolume: Double = 0.5

    private var follower = SoundTargetFollower()
    private var loadResolver = LoadResolver()
    private var events = DrivingEventEstimator()

    init(control: SynthControl) {
        self.control = control
        applySettingsToControl()
    }

    var activeStore: VehicleDataStore {
        mode == .demo ? demoStore : liveStore
    }

    /// Übernimmt Klang- und Pegeleinstellungen in den Audiothread.
    func applySettingsToControl() {
        control.apply(settings: soundSettings, preset: preset, effects: effects)
        control.masterGain.store(Float(masterVolume.clamped(0, 1)))
    }

    /// Wechselt die Betriebsart. Der Sound startet danach immer mit Präsenz 0 (sanftes Einblenden).
    func setMode(_ newMode: OperatingMode) {
        guard newMode != mode else { return }
        mode = newMode
        follower.reset()
        loadResolver.reset()
        events.reset()
        demoStore.reset()
        demo.reset()
        lastDemoOutput = nil
        lastEventText = nil
        target = SoundTarget(virtualRPM: 0, load: 0, presence: 0, state: .noData)
        control.presence.store(0)
        control.rpm.store(0)
        control.load.store(0)
    }

    /// Nimmt einen Fahrzeugmesswert an. Im Demomodus landen Werte zwar im Fahrzeugspeicher,
    /// beeinflussen aber weder Anzeige noch Sound.
    @discardableResult
    func ingestLive(_ sample: SignalSample) -> Bool {
        liveStore.ingest(sample)
    }

    /// Setzt nach einer Wiederverbindung den Sound auf sanftes Einblenden zurück.
    func resetFollowerForReconnect() {
        follower.reset()
        loadResolver.reset()
        events.reset()
    }

    /// Ein Steuerschritt.
    func tick(now: TimeInterval, dt: TimeInterval) {
        if mode == .demo {
            stepDemo(now: now, dt: dt)
        }
        let store = activeStore
        let rpmReading = store.reading(.rpm, now: now)
        let resolved = loadResolver.resolve(
            load: store.reading(.load, now: now),
            pedal: store.reading(.pedal, now: now),
            throttle: store.reading(.throttle, now: now),
            rpm: rpmReading,
            rpmTimestamp: store.latest[.rpm]?.timestamp
        )
        loadSource = resolved.source
        loadValue = resolved.value

        let newTarget = follower.step(
            rpm: store.latest[.rpm],
            previous: store.previous[.rpm],
            load: resolved.value,
            settings: soundSettings,
            profile: profile,
            now: now,
            dt: dt
        )
        if newTarget != target { target = newTarget }

        // Geschätzte Ereignisse (nur Echtbetrieb – die Demo liefert eigene, simulierte Ereignisse).
        if mode == .live, newTarget.state == .live, let rpm = rpmReading.lastValue {
            let detected = events.update(time: now, rpm: rpm, load: resolved.value)
            if detected.shift {
                control.triggerShift()
                note("Schaltvorgang (geschätzt)", now: now)
            }
            if detected.blowOff {
                control.triggerBlowOff()
                note("Lastabfall (geschätzt) – Blow-off", now: now)
            }
        }

        control.rpm.store(Float(newTarget.virtualRPM))
        control.load.store(Float(newTarget.load))
        control.presence.store(Float(newTarget.presence))
        control.beat()

        if lastEventText != nil, now - lastEventTime > 2.5 {
            lastEventText = nil
        }
    }

    private func note(_ text: String, now: TimeInterval) {
        lastEventText = text
        lastEventTime = now
    }

    private func stepDemo(now: TimeInterval, dt: TimeInterval) {
        let output = demo.step(dt: dt)
        lastDemoOutput = output
        let running = demo.phase != .off
        func put(_ signal: VehicleSignal, _ value: Double) {
            demoStore.ingest(SignalSample(signal: signal, value: value, timestamp: now, origin: .demo))
        }
        put(.rpm, output.rpm)
        put(.coolant, output.coolant)
        if running {
            put(.load, output.load * 100)
            put(.pedal, output.pedal)
            put(.throttle, output.throttle)
        } else {
            put(.load, 0)
            put(.pedal, 0)
            put(.throttle, 0)
        }
        if let speed = output.speed {
            put(.speed, speed)
            demoStore.setAvailability(.supported, for: .speed)
        } else {
            demoStore.remove(.speed)
            demoStore.setAvailability(.unsupported, for: .speed)
        }
        if output.shiftEvent {
            control.triggerShift()
            note("Gangwechsel (simuliert)", now: now)
        }
        if output.blowOffEvent {
            control.triggerBlowOff()
        }
    }
}
