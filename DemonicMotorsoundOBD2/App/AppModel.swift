import Foundation
import Observation
import SwiftUI

enum AppTab: Hashable {
    case cockpit
    case sounds
    case connection
    case settings
}

/// Für die Oberfläche gedrosselter Zustand des Motorsounds (ca. 15 Hz statt 50 Hz).
struct SoundSnapshot: Equatable {
    var virtualRPM: Double = 0
    var presence: Double = 0
    var load: Double = 0
    var state: SoundDataState = .noData
    var loadSource: LoadSource = .none
    var demoPhase: DemoSimulator.Phase = .off
    var demoMode: DemoSimulator.Mode = .manual
    var demoEngineRunning = false
    var demoGear: Int?
    var eventText: String?
}

/// Zentrales App-Modell: verbindet Einstellungen, Verbindung, Datenaufbereitung und Audio.
@Observable
final class AppModel {
    let settings: SettingsStore
    let control: SynthControl
    let driver: SoundDriver
    let audio: AudioEngineController
    let connection: ConnectionManager

    var selectedTab: AppTab = .cockpit
    var showGuide = false
    var showOnboarding = false

    /// UI-Uhr (ca. 15 Hz) für Altersanzeigen und Aktualitätsprüfungen.
    private(set) var now: TimeInterval
    private(set) var sound = SoundSnapshot()

    private let clock: TimeSource = ContinuousTimeSource.shared
    private var loopTask: Task<Void, Never>?
    private var isInBackground = false

    init() {
        let control = SynthControl()
        self.control = control
        settings = SettingsStore()
        driver = SoundDriver(control: control)
        audio = AudioEngineController(control: control)
        connection = ConnectionManager()
        now = ContinuousTimeSource.shared.now()

        audio.mixWithOthers = settings.settings.mixWithOthers
        connection.autoReconnect = settings.settings.autoReconnect
        showOnboarding = !settings.settings.hasCompletedOnboarding
        applySettings()

        connection.onSample = { [weak self] sample in
            self?.driver.ingestLive(sample)
        }
        connection.onAvailabilityChange = { [weak self] map in
            self?.driver.liveStore.setAvailability(map)
        }
        connection.onSessionStarted = { [weak self] in
            // Nach (Wieder-)Verbindung keine alten Werte als aktuell zeigen und sanft einblenden.
            self?.driver.liveStore.reset()
            self?.driver.resetFollowerForReconnect()
        }
        connection.ble.savedSelectionProvider = { [weak self] id in
            self?.settings.settings.customGATT[id.uuidString]
        }
        connection.ble.onSelectionConfirmed = { [weak self] id, selection in
            self?.settings.update {
                $0.customGATT[id.uuidString] = selection
                $0.lastBLEPeripheral = id
                $0.transportKind = .bluetoothLE
            }
        }

        startLoop()
        autoConnectIfConfigured()
    }

    // MARK: - Steuerschleife

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            var last = ContinuousTimeSource.shared.now()
            var counter = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard let self else { return }
                let t = self.clock.now()
                let dt = t - last
                last = t
                self.driver.tick(now: t, dt: dt)
                counter += 1
                if counter % 4 == 0 {
                    self.publishSnapshot(now: t)
                }
            }
        }
    }

    private func publishSnapshot(now t: TimeInterval) {
        now = t
        let target = driver.target
        let snapshot = SoundSnapshot(
            virtualRPM: target.virtualRPM,
            presence: target.presence,
            load: target.load,
            state: target.state,
            loadSource: driver.loadSource,
            demoPhase: driver.demo.phase,
            demoMode: driver.demo.mode,
            demoEngineRunning: driver.demo.engineRunning,
            demoGear: driver.lastDemoOutput?.gear,
            eventText: driver.lastEventText
        )
        if snapshot != sound { sound = snapshot }
    }

    // MARK: - Lebenszyklus

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isInBackground = false
            // Sofort neu bewerten, damit eingefrorene Werte nicht als aktuell erscheinen.
            publishSnapshot(now: clock.now())
            audio.refreshRoute()
            updatePollingSuspension()
        case .background:
            isInBackground = true
            updatePollingSuspension()
        default:
            break
        }
    }

    /// Fahrzeugabfragen laufen nur im Echtbetrieb und – im Hintergrund – nur bei aktivem Sound.
    private func updatePollingSuspension() {
        let suspend = isDemoMode || (isInBackground && !audio.isRunning)
        connection.setPollingSuspended(suspend)
    }

    private func autoConnectIfConfigured() {
        let s = settings.settings
        guard s.autoReconnect else { return }
        if s.transportKind == .bluetoothLE, let id = s.lastBLEPeripheral {
            connection.log.add(.info, "Automatische Verbindung mit zuletzt genutztem BLE-Adapter")
            connection.connectBLE(id)
        }
    }

    // MARK: - Betriebsart

    var isDemoMode: Bool { driver.mode == .demo }

    func setDemoMode(_ enabled: Bool) {
        driver.setMode(enabled ? .demo : .live)
        updatePollingSuspension()
        connection.log.add(.info, enabled ? "Demomodus aktiviert – keine Fahrzeugabfragen" : "Echtbetrieb aktiviert")
    }

    // MARK: - Sound

    func toggleSound() {
        if audio.isRunning {
            audio.stop()
        } else {
            audio.start()
        }
        updatePollingSuspension()
    }

    var selectedPreset: EnginePresetID { settings.settings.selectedPreset }

    func selectPreset(_ preset: EnginePresetID) {
        settings.update { $0.selectedPreset = preset }
        applySettings()
    }

    func soundSettings(for preset: EnginePresetID) -> SoundSettings {
        settings.soundSettings(for: preset)
    }

    func updateSoundSettings(_ value: SoundSettings, for preset: EnginePresetID) {
        settings.setSoundSettings(value, for: preset)
        applySettings()
    }

    func resetPreset(_ preset: EnginePresetID) {
        settings.resetPreset(preset)
        applySettings()
    }

    func setMasterVolume(_ value: Double) {
        settings.update { $0.masterVolume = value.clamped(0, 1) }
        applySettings()
    }

    func setEffects(_ effects: EffectSettings) {
        settings.update { $0.effects = effects }
        applySettings()
    }

    func setMixWithOthers(_ enabled: Bool) {
        settings.update { $0.mixWithOthers = enabled }
        audio.mixWithOthers = enabled
    }

    func setAutoReconnect(_ enabled: Bool) {
        settings.update { $0.autoReconnect = enabled }
        connection.autoReconnect = enabled
    }

    func updateProfile(_ profile: VehicleProfile) {
        settings.update { $0.vehicleProfile = profile.sanitized() }
        applySettings()
    }

    func resetSoundSettings() {
        settings.resetSound()
        audio.mixWithOthers = settings.settings.mixWithOthers
        applySettings()
    }

    func resetAll() {
        settings.resetAll()
        audio.mixWithOthers = settings.settings.mixWithOthers
        connection.autoReconnect = settings.settings.autoReconnect
        applySettings()
    }

    func completeOnboarding() {
        settings.update { $0.hasCompletedOnboarding = true }
        showOnboarding = false
    }

    func applySettings() {
        let s = settings.settings
        driver.preset = s.selectedPreset
        driver.soundSettings = settings.soundSettings(for: s.selectedPreset)
        driver.effects = s.effects
        driver.profile = s.vehicleProfile
        driver.masterVolume = s.masterVolume
        driver.applySettingsToControl()
    }

    // MARK: - Daten für die Oberfläche

    func reading(_ signal: VehicleSignal) -> SignalReading {
        driver.activeStore.reading(signal, now: now)
    }

    var dataQuality: DataQuality {
        DataQuality.evaluate(rpm: reading(.rpm))
    }

    /// Kurzer Verbindungsstatus für das Cockpit.
    var connectionSummary: String {
        if isDemoMode { return "Demo – keine Fahrzeugverbindung" }
        return connection.statusTitle
    }
}
