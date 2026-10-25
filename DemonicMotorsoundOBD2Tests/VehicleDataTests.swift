import Foundation
import Testing
@testable import DemonicMotorsoundOBD2

@MainActor
struct FreshnessTests {
    @Test func freshnessThresholds() {
        #expect(Freshness.evaluate(age: nil, signal: .rpm) == .none)
        #expect(Freshness.evaluate(age: 0.2, signal: .rpm) == .fresh)
        #expect(Freshness.evaluate(age: 1.5, signal: .rpm) == .aging)
        #expect(Freshness.evaluate(age: 5, signal: .rpm) == .stale)
        // Kühlmittel wird selten abgefragt und hat daher längere Grenzen.
        #expect(Freshness.evaluate(age: 10, signal: .coolant) == .fresh)
    }

    @Test func staleValuesAreNotDisplayedAsCurrent() {
        let store = VehicleDataStore(origin: .vehicle)
        store.ingest(SignalSample(signal: .rpm, value: 4500, timestamp: 10, origin: .vehicle))
        let fresh = store.reading(.rpm, now: 10.3)
        #expect(fresh.displayValue == 4500)
        #expect(fresh.statusText == "Aktuell")

        let stale = store.reading(.rpm, now: 20)
        #expect(stale.displayValue == nil)
        #expect(stale.freshness == .stale)
        #expect(stale.statusText == "Veraltet")
        #expect(DataQuality.evaluate(rpm: stale) == .lost(age: 10))
    }

    @Test func unsupportedSignalIsMarked() {
        let store = VehicleDataStore(origin: .vehicle)
        store.setAvailability([.speed: .unsupported])
        #expect(store.reading(.speed, now: 0).statusText == "Nicht verfügbar")
        #expect(store.reading(.speed, now: 0).displayValue == nil)
    }

    @Test func storesRejectForeignOrigin() {
        let live = VehicleDataStore(origin: .vehicle)
        let demo = VehicleDataStore(origin: .demo)
        #expect(!live.ingest(SignalSample(signal: .rpm, value: 3000, timestamp: 1, origin: .demo)))
        #expect(!demo.ingest(SignalSample(signal: .rpm, value: 3000, timestamp: 1, origin: .vehicle)))
        #expect(live.latest.isEmpty)
        #expect(demo.latest.isEmpty)
        #expect(!live.ingest(SignalSample(signal: .rpm, value: .nan, timestamp: 1, origin: .vehicle)))
    }

    @Test func olderSampleDoesNotOverwriteNewer() {
        let store = VehicleDataStore(origin: .vehicle)
        store.ingest(SignalSample(signal: .rpm, value: 2000, timestamp: 5, origin: .vehicle))
        store.ingest(SignalSample(signal: .rpm, value: 1000, timestamp: 4, origin: .vehicle))
        #expect(store.latest[.rpm]?.value == 2000)
    }
}

@MainActor
struct LoadTests {
    private func reading(_ signal: VehicleSignal, _ value: Double?, fresh: Bool = true) -> SignalReading {
        SignalReading(signal: signal, lastValue: value, age: value == nil ? nil : (fresh ? 0.1 : 10),
                      freshness: value == nil ? .none : (fresh ? .fresh : .stale),
                      availability: value == nil ? .unsupported : .supported, origin: .vehicle)
    }

    @Test func measuredLoadHasPriority() {
        var resolver = LoadResolver()
        let result = resolver.resolve(load: reading(.load, 50), pedal: reading(.pedal, 80), throttle: reading(.throttle, 30),
                                      rpm: reading(.rpm, 2000), rpmTimestamp: 1)
        #expect(result.source == .measuredLoad)
        #expect(abs(result.value - 0.5) < 0.001)
    }

    @Test func pedalBeforeThrottle() {
        var resolver = LoadResolver()
        let result = resolver.resolve(load: reading(.load, nil), pedal: reading(.pedal, 18), throttle: reading(.throttle, 70),
                                      rpm: reading(.rpm, 2000), rpmTimestamp: 1)
        #expect(result.source == .pedal)
        #expect(result.value < 0.05)
    }

    @Test func estimateIsLabelledWhenOnlyRPM() {
        var resolver = LoadResolver()
        _ = resolver.resolve(load: reading(.load, nil), pedal: reading(.pedal, nil), throttle: reading(.throttle, nil),
                             rpm: reading(.rpm, 1000), rpmTimestamp: 1)
        let rising = resolver.resolve(load: reading(.load, nil), pedal: reading(.pedal, nil), throttle: reading(.throttle, nil),
                                      rpm: reading(.rpm, 1500), rpmTimestamp: 1.2)
        #expect(rising.source == .estimated)
        #expect(rising.source.isEstimate)
        #expect(rising.value > 0.3)
    }

    @Test func shiftAndBlowOffEstimation() {
        var estimator = DrivingEventEstimator()
        var shift = false
        var t = 0.0
        for rpm in stride(from: 3000.0, through: 5500, by: 250) {
            t += 0.05
            _ = estimator.update(time: t, rpm: rpm, load: 0.9)
        }
        for rpm in [4800.0, 4100, 3600] {
            t += 0.05
            let e = estimator.update(time: t, rpm: rpm, load: 0.05)
            shift = shift || e.shift
        }
        #expect(shift)
    }
}

@MainActor
struct SoundFollowerTests {
    let settings = SoundSettings.defaults(for: .sportFour)
    let profile = VehicleProfile.hondaJazz2015

    private func sample(_ rpm: Double, _ t: TimeInterval) -> SignalSample {
        SignalSample(signal: .rpm, value: rpm, timestamp: t, origin: .vehicle)
    }

    @Test func fadeInIsGradualAndFollowsRPM() {
        var follower = SoundTargetFollower()
        let first = follower.step(rpm: sample(3000, 0), previous: nil, load: 0.5, settings: settings, profile: profile, now: 0, dt: 0.02)
        #expect(first.presence <= 0.02)
        #expect(first.state == .live)
        var target = first
        for i in 1...100 {
            let t = Double(i) * 0.02
            target = follower.step(rpm: sample(3000, t), previous: sample(3000, t - 0.02), load: 0.5, settings: settings, profile: profile, now: t, dt: 0.02)
        }
        #expect(target.presence > 0.99)
        #expect(abs(target.virtualRPM - 3000) < 5)
    }

    @Test func dataLossBridgesBrieflyThenFadesOut() {
        var follower = SoundTargetFollower()
        var t = 0.0
        for _ in 0..<150 {
            t += 0.02
            _ = follower.step(rpm: sample(5000, t), previous: sample(4990, t - 0.02), load: 0.8, settings: settings, profile: profile, now: t, dt: 0.02)
        }
        let lastSample = sample(5000, t)
        let previous = sample(4990, t - 0.02)
        // Kurzer Aussetzer: überbrückt, Sound bleibt an.
        var target = follower.step(rpm: lastSample, previous: previous, load: 0.8, settings: settings, profile: profile, now: t + 0.5, dt: 0.02)
        #expect(target.state == .bridging)
        #expect(target.presence > 0.9)
        // Begrenzte Extrapolation: nie mehr als +10 % über dem letzten Messwert.
        #expect(target.virtualRPM <= 5000 * 1.1)

        var now = t + 0.5
        while now < t + 3.5 {
            now += 0.02
            target = follower.step(rpm: lastSample, previous: previous, load: 0.8, settings: settings, profile: profile, now: now, dt: 0.02)
        }
        #expect(target.presence < 0.01)
        // Nicht auf der hohen Drehzahl verharren.
        #expect(target.virtualRPM < 2000)
        #expect(target.state == .noData)
    }

    @Test func engineStopFadesOutDespiteVirtualIdle() {
        var follower = SoundTargetFollower()
        var t = 0.0
        for _ in 0..<150 {
            t += 0.02
            _ = follower.step(rpm: sample(800, t), previous: sample(800, t - 0.02), load: 0.2, settings: settings, profile: profile, now: t, dt: 0.02)
        }
        var target = SoundTarget(virtualRPM: 0, load: 0, presence: 1, state: .live)
        for _ in 0..<200 {
            t += 0.02
            target = follower.step(rpm: sample(0, t), previous: sample(0, t - 0.02), load: 0, settings: settings, profile: profile, now: t, dt: 0.02)
        }
        #expect(target.state == .engineOff)
        #expect(target.presence < 0.01)
    }

    @Test func virtualMappingDoesNotTouchRealValue() {
        var s = SoundSettings.defaults(for: .screamingV10)
        s.scaleToVirtualRange = true
        let mapped = SoundTargetFollower.mapToVirtual(realRPM: profile.maxRPMReference, settings: s, profile: profile)
        #expect(abs(mapped - s.virtualMaxRPM) < 1)
        let idle = SoundTargetFollower.mapToVirtual(realRPM: profile.idleRPMReference, settings: s, profile: profile)
        #expect(abs(idle - s.virtualIdleRPM) < 1)
        s.scaleToVirtualRange = false
        #expect(SoundTargetFollower.mapToVirtual(realRPM: 3000, settings: s, profile: profile) == 3000)
        // Unterhalb der virtuellen Leerlaufdrehzahl wird auf diese angehoben (nur bei laufendem Motor).
        #expect(SoundTargetFollower.mapToVirtual(realRPM: 700, settings: s, profile: profile) == s.virtualIdleRPM)
    }

    @Test func settingsAreSanitized() {
        var s = SoundSettings.defaults(for: .deepV8)
        s.bass = 7
        s.aggressiveness = -2
        s.harmonics = .nan
        s.virtualIdleRPM = 50
        s.virtualMaxRPM = 100
        let safe = s.sanitized()
        #expect(safe.bass == 1)
        #expect(safe.aggressiveness == 0)
        #expect(safe.harmonics == 0.5)
        #expect(safe.virtualIdleRPM == 400)
        #expect(safe.virtualMaxRPM >= safe.virtualIdleRPM + 1500)
    }
}

@MainActor
struct ModeTransitionTests {
    @Test func demoAndLiveDataNeverMix() {
        let driver = SoundDriver(control: SynthControl())
        var now = 0.0
        // Echtbetrieb mit 3000 U/min
        for _ in 0..<120 {
            now += 0.02
            driver.ingestLive(SignalSample(signal: .rpm, value: 3000, timestamp: now, origin: .vehicle))
            driver.tick(now: now, dt: 0.02)
        }
        #expect(driver.target.presence > 0.9)

        // Wechsel in die Demo: Motor der Demo ist aus → kein Sound, obwohl Live-Daten weiterlaufen.
        driver.setMode(.demo)
        #expect(driver.control.presence.load() == 0)
        for _ in 0..<50 {
            now += 0.02
            driver.ingestLive(SignalSample(signal: .rpm, value: 3000, timestamp: now, origin: .vehicle))
            driver.tick(now: now, dt: 0.02)
        }
        #expect(driver.target.presence < 0.01)
        #expect(driver.activeStore.origin == .demo)
        #expect(driver.activeStore.latest[.rpm]?.origin == .demo)
        #expect(driver.activeStore.latest[.rpm]?.value == 0)

        // Demo-Motor starten
        driver.demo.startEngine()
        for _ in 0..<250 {
            now += 0.02
            driver.tick(now: now, dt: 0.02)
        }
        #expect(driver.target.presence > 0.9)
        #expect(abs((driver.activeStore.latest[.rpm]?.value ?? 0) - DemoSimulator.idleRPM) < 60)
        #expect(driver.liveStore.latest.values.allSatisfy { $0.origin == .vehicle })

        // Zurück in den Echtbetrieb ohne neue Daten: Sound blendet ein, aber nur mit frischen Live-Daten.
        driver.setMode(.live)
        now += 5
        driver.tick(now: now, dt: 0.02)
        #expect(driver.target.presence < 0.02)
        #expect(driver.target.state == .noData)
    }

    @Test func demoAutoDriveShiftsGears() {
        var demo = DemoSimulator()
        demo.setMode(.autoDrive)
        demo.startEngine()
        var shifts = 0
        var maxRPM = 0.0
        var maxSpeed = 0.0
        for _ in 0..<(50 * 40) {
            let out = demo.step(dt: 0.02)
            if out.shiftEvent { shifts += 1 }
            maxRPM = max(maxRPM, out.rpm)
            maxSpeed = max(maxSpeed, out.speed ?? 0)
        }
        #expect(shifts >= 3)
        #expect(maxRPM > 4500)
        #expect(maxSpeed > 60)
        demo.stopEngine()
        for _ in 0..<100 { _ = demo.step(dt: 0.02) }
        #expect(demo.phase == .off)
        #expect(demo.rpm == 0)
    }
}

@MainActor
struct SettingsStoreTests {
    @Test func persistAndReset() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        var s = store.soundSettings(for: .demonic)
        s.bass = 0.1
        store.setSoundSettings(s, for: .demonic)
        store.toggleFavorite(.sciFiReactor)
        store.update { $0.selectedPreset = .demonic }

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.soundSettings(for: .demonic).bass == 0.1)
        #expect(reloaded.settings.favorites.contains(.sciFiReactor))
        #expect(reloaded.settings.selectedPreset == .demonic)

        reloaded.resetPreset(.demonic)
        #expect(reloaded.soundSettings(for: .demonic) == SoundSettings.defaults(for: .demonic).sanitized())
        reloaded.resetSound()
        #expect(reloaded.settings.selectedPreset == .sportFour)
        defaults.removePersistentDomain(forName: suite)
    }
}
