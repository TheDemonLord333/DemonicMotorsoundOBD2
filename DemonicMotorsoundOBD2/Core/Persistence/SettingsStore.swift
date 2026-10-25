import Foundation
import Observation

nonisolated enum TransportKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bluetoothLE
    case wifi

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bluetoothLE: "Bluetooth LE"
        case .wifi: "WLAN"
        }
    }
}

/// Vom Nutzer gewählte GATT-Zuordnung für einen unbekannten BLE-Adapter.
nonisolated struct CustomGATTSelection: Codable, Equatable, Sendable {
    var serviceUUID: String
    var writeUUID: String
    var notifyUUID: String
}

/// Alle lokal gespeicherten Einstellungen.
nonisolated struct PersistedSettings: Codable, Equatable, Sendable {
    var selectedPreset: EnginePresetID = .sportFour
    var presetSettings: [EnginePresetID: SoundSettings] = [:]
    var favorites: Set<EnginePresetID> = [.deepV8, .demonic]
    var effects = EffectSettings()
    var masterVolume: Double = 0.5
    var mixWithOthers = false
    var vehicleProfile = VehicleProfile.hondaJazz2015
    var transportKind: TransportKind = .bluetoothLE
    var wifiHost = "192.168.0.10"
    var wifiPort = 35000
    var lastBLEPeripheral: UUID?
    var customGATT: [String: CustomGATTSelection] = [:]
    var hasCompletedOnboarding = false
    var autoReconnect = true

    init() {}

    // Robuste Dekodierung: fehlende Schlüssel (z. B. nach einem Update) fallen auf Standardwerte zurück.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PersistedSettings()
        selectedPreset = (try? c.decode(EnginePresetID.self, forKey: .selectedPreset)) ?? d.selectedPreset
        presetSettings = (try? c.decode([EnginePresetID: SoundSettings].self, forKey: .presetSettings)) ?? d.presetSettings
        favorites = (try? c.decode(Set<EnginePresetID>.self, forKey: .favorites)) ?? d.favorites
        effects = (try? c.decode(EffectSettings.self, forKey: .effects)) ?? d.effects
        masterVolume = (try? c.decode(Double.self, forKey: .masterVolume)) ?? d.masterVolume
        mixWithOthers = (try? c.decode(Bool.self, forKey: .mixWithOthers)) ?? d.mixWithOthers
        vehicleProfile = (try? c.decode(VehicleProfile.self, forKey: .vehicleProfile)) ?? d.vehicleProfile
        transportKind = (try? c.decode(TransportKind.self, forKey: .transportKind)) ?? d.transportKind
        wifiHost = (try? c.decode(String.self, forKey: .wifiHost)) ?? d.wifiHost
        wifiPort = (try? c.decode(Int.self, forKey: .wifiPort)) ?? d.wifiPort
        lastBLEPeripheral = try? c.decode(UUID.self, forKey: .lastBLEPeripheral)
        customGATT = (try? c.decode([String: CustomGATTSelection].self, forKey: .customGATT)) ?? d.customGATT
        hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
        autoReconnect = (try? c.decode(Bool.self, forKey: .autoReconnect)) ?? d.autoReconnect
    }
}

/// Lädt und speichert Einstellungen in `UserDefaults` (nur lokal, kein Konto, kein Server).
@Observable
final class SettingsStore {
    static let storageKey = "DemonicMotorsound.settings.v1"

    private let defaults: UserDefaults
    private(set) var settings: PersistedSettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(PersistedSettings.self, from: data) {
            settings = decoded
        } else {
            settings = PersistedSettings()
        }
    }

    func update(_ change: (inout PersistedSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: Bequeme Zugriffe

    func soundSettings(for preset: EnginePresetID) -> SoundSettings {
        (settings.presetSettings[preset] ?? .defaults(for: preset)).sanitized()
    }

    var currentSoundSettings: SoundSettings {
        soundSettings(for: settings.selectedPreset)
    }

    func setSoundSettings(_ value: SoundSettings, for preset: EnginePresetID) {
        update { $0.presetSettings[preset] = value.sanitized() }
    }

    func resetPreset(_ preset: EnginePresetID) {
        update { $0.presetSettings[preset] = nil }
    }

    func toggleFavorite(_ preset: EnginePresetID) {
        update {
            if $0.favorites.contains(preset) {
                $0.favorites.remove(preset)
            } else {
                $0.favorites.insert(preset)
            }
        }
    }

    /// Setzt alle Klang-Einstellungen, Favoriten und Effekte zurück. Verbindungsdaten und
    /// Fahrzeugprofil bleiben erhalten.
    func resetSound() {
        update {
            let fresh = PersistedSettings()
            $0.presetSettings = fresh.presetSettings
            $0.favorites = fresh.favorites
            $0.effects = fresh.effects
            $0.masterVolume = fresh.masterVolume
            $0.selectedPreset = fresh.selectedPreset
            $0.mixWithOthers = fresh.mixWithOthers
        }
    }

    /// Setzt alles auf Werkseinstellungen zurück (Ersteinrichtungs-Hinweis bleibt gesehen).
    func resetAll() {
        let onboarding = settings.hasCompletedOnboarding
        settings = PersistedSettings()
        settings.hasCompletedOnboarding = onboarding
        save()
    }
}
