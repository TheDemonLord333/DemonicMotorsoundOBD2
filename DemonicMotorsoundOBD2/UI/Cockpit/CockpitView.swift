import Foundation
import SwiftUI

struct CockpitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                // Querformat: Drehzahlmesser links, Informationen rechts
                HStack(alignment: .top, spacing: 16) {
                    GaugeSection()
                        .frame(maxWidth: 420)
                    ScrollView {
                        VStack(spacing: 14) {
                            SoundControlSection()
                            if model.isDemoMode { DemoControlSection() }
                            VehicleValuesSection()
                            StatusSection()
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        GaugeSection()
                        SoundControlSection()
                        if model.isDemoMode { DemoControlSection() }
                        VehicleValuesSection()
                        StatusSection()
                    }
                    .padding()
                }
            }
        }
        .demonBackground()
        .navigationTitle("Cockpit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { GuideToolbarButton() }
        }
    }
}

// MARK: - Drehzahl

private struct GaugeSection: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var rpmFontSize: CGFloat = 54

    var body: some View {
        let rpm = model.reading(.rpm)
        let profile = model.settings.settings.vehicleProfile
        let soundRunning = model.audio.isRunning && model.sound.presence > 0.01
        let intensity = ((rpm.displayValue ?? 0) / max(profile.maxRPMReference, 1000)).clamped(0, 1)

        VStack(spacing: 10) {
            HStack(spacing: 8) {
                StatusChip(text: model.dataQuality.title, systemImage: model.dataQuality.symbolName, color: model.dataQuality.color)
                Spacer(minLength: 0)
                StatusChip(text: model.audio.routeKind.title, systemImage: model.audio.routeKind.symbolName, color: DemonTheme.blurple)
            }

            TachometerView(
                rpm: rpm.displayValue,
                soundRPM: soundRunning ? model.sound.virtualRPM : nil,
                maxRPM: profile.gaugeMaximum,
                redline: profile.maxRPMReference,
                isDelayed: rpm.freshness == .aging
            ) {
                DemonEmblemView(intensity: intensity, active: rpm.displayValue != nil && soundRunning)
                    .opacity(0.9)
            }
            .frame(maxWidth: 420)

            VStack(spacing: 2) {
                Text(rpm.displayValue.map { $0.germanInteger } ?? "—")
                    .font(.system(size: rpmFontSize, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(rpm.displayValue == nil ? AnyShapeStyle(DemonTheme.textSecondary) : AnyShapeStyle(DemonTheme.accentGradient))
                    .contentTransition(.numericText())
                    .accessibilityLabel(model.isDemoMode ? "Demo-Drehzahl" : "Tatsächliche Drehzahl")
                    .accessibilityValue(rpm.displayValue.map { "\(Int($0)) Umdrehungen pro Minute" } ?? "Kein aktueller Wert")
                Text(model.isDemoMode ? "U/min · Demo-Drehzahl (simuliert)" : "U/min · tatsächliche OBD-Drehzahl")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DemonTheme.textSecondary)
                if rpm.freshness == .aging || rpm.freshness == .stale {
                    Text(rpm.freshness == .aging ? "Wert verzögert (\(rpm.age?.germanDecimal(1) ?? "–") s)" : "Keine aktuellen Drehzahldaten")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(rpm.freshness == .aging ? DemonTheme.warning : DemonTheme.danger)
                }
                if soundRunning {
                    Label("Sounddrehzahl (virtuell): \(model.sound.virtualRPM.germanInteger) U/min", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(DemonTheme.violet)
                }
            }
        }
        .neonPanel(glow: 0.2 + 0.3 * intensity)
    }
}

// MARK: - Sound

private struct SoundControlSection: View {
    @Environment(AppModel.self) private var model
    @State private var volume: Double = 0.5

    var body: some View {
        let status = model.audio.status
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Motorsound", systemImage: "speaker.wave.3.fill")

            Button {
                model.toggleSound()
            } label: {
                HStack {
                    Image(systemName: model.audio.isRunning ? "stop.fill" : "play.fill")
                    Text(model.audio.isRunning ? "Sound stoppen" : (status == .routeLost ? "Sound erneut starten" : "Sound starten"))
                }
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(.black)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(model.audio.isRunning ? AnyShapeStyle(DemonTheme.blurple) : AnyShapeStyle(DemonTheme.accentGradient))
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Startet oder stoppt den virtuellen Motorsound")

            if status != .running && status != .stopped {
                Label(status.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(DemonTheme.warning)
            }
            if let notice = model.audio.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(DemonTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.audio.isRunning {
                Label(model.sound.state.title, systemImage: model.sound.state == .live ? "dot.radiowaves.left.and.right" : "waveform.slash")
                    .font(.footnote)
                    .foregroundStyle(model.sound.state == .live ? DemonTheme.green : DemonTheme.warning)
                if model.audio.routeKind == .speaker {
                    Text("Ausgabe über den iPhone-Lautsprecher. Für das Autoradio Bluetooth oder AUX wählen.")
                        .font(.caption)
                        .foregroundStyle(DemonTheme.textSecondary)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundStyle(DemonTheme.textSecondary)
                Slider(value: $volume, in: 0...1, onEditingChanged: { editing in
                    if !editing { model.setMasterVolume(volume) }
                })
                .onChange(of: volume) { _, newValue in
                    // Pegel sofort hörbar anpassen, Speichern erst am Ende der Geste.
                    model.control.masterGain.store(Float(newValue))
                }
                .accessibilityLabel("Lautstärke")
                .accessibilityValue("\(Int(volume * 100)) Prozent")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(DemonTheme.textSecondary)
                RoutePickerButton()
                    .frame(width: 36, height: 36)
            }

            PresetStrip()

            Label("Last für den Klang: \(model.sound.loadSource.title)", systemImage: model.sound.loadSource.isEstimate ? "questionmark.circle" : "bolt.fill")
                .font(.caption)
                .foregroundStyle(model.sound.loadSource.isEstimate ? DemonTheme.warning : DemonTheme.textSecondary)
            if let event = model.sound.eventText {
                Label(event, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(DemonTheme.violet)
            }
        }
        .neonPanel()
        .onAppear { volume = model.settings.settings.masterVolume }
    }
}

private struct PresetStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(orderedPresets) { preset in
                    let selected = preset == model.selectedPreset
                    Button {
                        model.selectPreset(preset)
                    } label: {
                        Label(preset.shortTitle, systemImage: preset.symbolName)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(selected ? DemonTheme.green.opacity(0.25) : DemonTheme.panelHighlight))
                            .overlay(Capsule().strokeBorder(selected ? DemonTheme.green : DemonTheme.metal, lineWidth: 1))
                            .foregroundStyle(selected ? DemonTheme.neon : .white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var orderedPresets: [EnginePresetID] {
        let favorites = model.settings.settings.favorites
        return EnginePresetID.allCases.filter { favorites.contains($0) } + EnginePresetID.allCases.filter { !favorites.contains($0) }
    }
}

// MARK: - Demo

private struct DemoControlSection: View {
    @Environment(AppModel.self) private var model
    @State private var manualRPM: Double = DemoSimulator.idleRPM
    @State private var manualLoad: Double = 0.2

    var body: some View {
        let snapshot = model.sound
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Demosteuerung", systemImage: "theatermasks.fill")

            Picker("Demoart", selection: Binding(
                get: { snapshot.demoMode },
                set: { model.driver.demo.setMode($0) }
            )) {
                ForEach(DemoSimulator.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button {
                    if snapshot.demoEngineRunning {
                        model.driver.demo.stopEngine()
                    } else {
                        model.driver.demo.startEngine()
                    }
                } label: {
                    Label(snapshot.demoEngineRunning ? "Motor aus" : "Motor starten",
                          systemImage: snapshot.demoEngineRunning ? "power" : "key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(snapshot.demoEngineRunning ? DemonTheme.danger : DemonTheme.green)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(snapshot.demoPhase.title)
                        .font(.caption.weight(.semibold))
                    if let gear = snapshot.demoGear {
                        Text("Gang \(gear) (simuliert)")
                            .font(.caption2)
                            .foregroundStyle(DemonTheme.textSecondary)
                    }
                }
            }

            if snapshot.demoMode == .manual {
                LabeledSlider(
                    title: "Drehzahl (Vorgabe)",
                    value: $manualRPM,
                    range: DemoSimulator.idleRPM...7500,
                    format: { "\($0.germanInteger) U/min" }
                )
                .disabled(!snapshot.demoEngineRunning)
                LabeledSlider(title: "Last / Gas", value: $manualLoad)
                    .disabled(!snapshot.demoEngineRunning)
                Text("Ohne Gangwechsel; Geschwindigkeit ist in diesem Modus bewusst „Nicht verfügbar“.")
                    .font(.caption)
                    .foregroundStyle(DemonTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Automatische Demofahrt: Leerlauf, Beschleunigung mit simulierten Gangwechseln, Konstantfahrt und Ausrollen – in Schleife.")
                    .font(.caption)
                    .foregroundStyle(DemonTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .neonPanel()
        .onAppear {
            manualRPM = model.driver.demo.manualRPM
            manualLoad = model.driver.demo.manualLoad
        }
        .onChange(of: manualRPM) { _, value in model.driver.demo.manualRPM = value }
        .onChange(of: manualLoad) { _, value in model.driver.demo.manualLoad = value }
    }
}

// MARK: - Fahrzeugwerte

private struct VehicleValuesSection: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: model.isDemoMode ? "Simulierte Werte" : "Fahrzeugdaten", systemImage: "car.side.fill")
            LazyVGrid(columns: columns, spacing: 10) {
                ValueTile(reading: model.reading(.speed))
                ValueTile(reading: model.reading(.load))
                ValueTile(reading: model.reading(.pedal))
                ValueTile(reading: model.reading(.throttle))
                ValueTile(reading: model.reading(.coolant),
                          footnote: "Kühlmittel – keine Öltemperatur und kein Nachweis für einen vollständig warmen Motor.")
            }
        }
    }
}

// MARK: - Status

private struct StatusSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.connection.session
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: "Status", systemImage: "info.circle.fill")
            row("Verbindung", model.connectionSummary, symbol: "antenna.radiowaves.left.and.right",
                color: model.connection.hasProblem && !model.isDemoMode ? DemonTheme.danger : DemonTheme.textSecondary)
            row("Preset", model.selectedPreset.title, symbol: model.selectedPreset.symbolName)
            row("Audioausgabe", model.audio.routeName, symbol: model.audio.routeKind.symbolName)
            if !model.isDemoMode, let session, session.phase == .polling {
                row("Datenrate", "\(session.statistics.requestRate.germanDecimal(1)) Werte/s · Drehzahl \(session.statistics.rpmRate.germanDecimal(1))/s",
                    symbol: "speedometer")
            }
            let rpm = model.reading(.rpm)
            row("Alter Drehzahlwert", rpm.age.map { "\($0.germanDecimal(2)) s" } ?? "—", symbol: "clock")
            if !model.isDemoMode, !model.connection.isTransportReady {
                Button {
                    model.selectedTab = .connection
                } label: {
                    Label("Adapter verbinden oder Demomodus wählen", systemImage: "arrow.right.circle.fill")
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .neonPanel(glow: 0.1)
    }

    private func row(_ title: String, _ value: String, symbol: String, color: Color = DemonTheme.textSecondary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
