import Foundation
import SwiftUI

struct SoundsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    PanelHeader(title: "Synthetische Klangcharaktere", systemImage: "waveform.path.ecg")
                    Text("Alle Sounds werden in Echtzeit prozedural erzeugt (Zündimpulse, Obertöne, gefiltertes Rauschen). Es sind eigenständige Klangcharaktere – keine Aufnahmen und keine garantierte Nachbildung bestimmter Motoren.")
                        .font(.footnote)
                        .foregroundStyle(DemonTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .neonPanel(glow: 0.1)

                ForEach(EnginePresetID.allCases) { preset in
                    PresetRow(preset: preset)
                }

                NavigationLink {
                    PresetEditorView(preset: model.selectedPreset)
                } label: {
                    Label("„\(model.selectedPreset.title)“ anpassen", systemImage: "slider.horizontal.3")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(.black)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DemonTheme.accentGradient))
                }
                .buttonStyle(.plain)

                EffectsSection()
            }
            .padding()
        }
        .demonBackground()
        .navigationTitle("Sounds")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { GuideToolbarButton() }
        }
    }
}

private struct PresetRow: View {
    @Environment(AppModel.self) private var model
    let preset: EnginePresetID

    var body: some View {
        let selected = model.selectedPreset == preset
        let favorite = model.settings.settings.favorites.contains(preset)
        HStack(spacing: 12) {
            Button {
                model.selectPreset(preset)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: preset.symbolName)
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .foregroundStyle(selected ? DemonTheme.neon : DemonTheme.textSecondary)
                        .background(Circle().fill(selected ? DemonTheme.green.opacity(0.2) : DemonTheme.panelHighlight))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preset.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(preset.subtitle)
                            .font(.caption)
                            .foregroundStyle(DemonTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(preset.cylinderDescription)
                            .font(.caption2)
                            .foregroundStyle(DemonTheme.blurple)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(DemonTheme.green)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button {
                model.settings.toggleFavorite(preset)
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(favorite ? DemonTheme.warning : DemonTheme.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen")
        }
        .neonPanel(glow: selected ? 0.35 : 0.05, padding: 12)
    }
}

private struct EffectsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let effects = model.settings.settings.effects
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Zusatzeffekte (nur Audio)", systemImage: "sparkles")
            Toggle("Synthetisches Turbopfeifen", isOn: binding(\.turboWhistle, effects))
            Toggle("Blow-off bei geschätztem Lastabfall", isOn: binding(\.blowOff, effects))
            Toggle("Dezentes Schaltgeräusch (geschätzt)", isOn: binding(\.shiftSound, effects))
            Text("Diese Effekte sind rein synthetisch. Schaltvorgänge und Lastwechsel werden aus dem Drehzahl- und Lastverlauf geschätzt, nicht gemessen. Turbopfeifen und Blow-off sind nur bei Presets mit Turboanteil hörbar. Es gibt keinerlei Eingriff am Fahrzeug.")
                .font(.caption)
                .foregroundStyle(DemonTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .neonPanel(glow: 0.1)
    }

    private func binding(_ keyPath: WritableKeyPath<EffectSettings, Bool>, _ current: EffectSettings) -> Binding<Bool> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { newValue in
                var copy = model.settings.settings.effects
                copy[keyPath: keyPath] = newValue
                model.setEffects(copy)
            }
        )
    }
}

/// Detaileinstellungen eines Presets.
struct PresetEditorView: View {
    @Environment(AppModel.self) private var model
    let preset: EnginePresetID
    @State private var draft = SoundSettings.defaults(for: .sportFour)
    @State private var loaded = false
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Text(preset.subtitle)
                    .font(.footnote)
                    .foregroundStyle(DemonTheme.textSecondary)
            }

            Section("Klang") {
                LabeledSlider(title: "Gesamtlautstärke (Preset-Pegel)", value: $draft.level)
                LabeledSlider(title: "Bassanteil", value: $draft.bass)
                LabeledSlider(title: "Aggressivität", value: $draft.aggressiveness, help: "Sättigung, Rauheit und Verbrennungsrauschen.")
                LabeledSlider(title: "Obertonanteil", value: $draft.harmonics)
                if preset.supportsTurbo {
                    LabeledSlider(title: "Turboanteil", value: $draft.turbo, help: "Pegel des synthetischen Turbopfeifens (Effekt muss aktiviert sein).")
                }
                LabeledSlider(title: "Glättung / Reaktion", value: $draft.smoothing,
                              format: { $0 < 0.34 ? "Direkt" : ($0 < 0.67 ? "Ausgewogen" : "Weich") },
                              help: "Wie schnell der Sound Drehzahländerungen folgt. Stärkere Glättung klingt ruhiger, reagiert aber träger.")
            }

            Section {
                LabeledSlider(title: "Virtuelle Leerlaufdrehzahl", value: $draft.virtualIdleRPM, range: 400...2000, step: 50,
                              format: { "\($0.germanInteger) U/min" },
                              help: "Untergrenze der Sounddrehzahl bei laufendem Motor. Steht der Motor, läuft der Sound trotzdem aus.")
                LabeledSlider(title: "Obere virtuelle Drehzahl", value: $draft.virtualMaxRPM, range: 3000...12000, step: 100,
                              format: { "\($0.germanInteger) U/min" })
                Toggle("Gemessene Drehzahl auf virtuellen Bereich skalieren", isOn: $draft.scaleToVirtualRange)
                if draft.scaleToVirtualRange {
                    let profile = model.settings.settings.vehicleProfile
                    Text("Bildet \(profile.idleRPMReference.germanInteger)–\(profile.maxRPMReference.germanInteger) U/min (Fahrzeugprofil) linear auf \(draft.virtualIdleRPM.germanInteger)–\(draft.virtualMaxRPM.germanInteger) U/min ab.")
                        .font(.caption)
                        .foregroundStyle(DemonTheme.textSecondary)
                }
            } header: {
                Text("Virtuelle Sounddrehzahl")
            } footer: {
                Text("Diese Werte verändern nur den Klang. Die angezeigte tatsächliche OBD-Drehzahl bleibt davon unberührt.")
            }

            Section {
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("Preset auf Standard zurücksetzen", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .demonBackground()
        .navigationTitle(preset.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            draft = model.soundSettings(for: preset)
            loaded = true
        }
        .onChange(of: draft) { _, newValue in
            guard loaded else { return }
            model.updateSoundSettings(newValue, for: preset)
        }
        .confirmationDialog("Preset zurücksetzen?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Zurücksetzen", role: .destructive) {
                model.resetPreset(preset)
                draft = model.soundSettings(for: preset)
            }
        }
    }
}
