import Foundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSoundReset = false
    @State private var confirmFullReset = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Label("Aktuelle Ausgabe", systemImage: model.audio.routeKind.symbolName)
                    Spacer()
                    Text(model.audio.routeName)
                        .foregroundStyle(DemonTheme.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Ausgabe wählen")
                    Spacer()
                    RoutePickerButton()
                        .frame(width: 36, height: 36)
                }
                if let latency = model.audio.outputLatency {
                    LabeledContent("Vom System gemeldete Latenz", value: "ca. \(Int(latency * 1000)) ms")
                }
                Toggle("Mit anderer Musik mischen", isOn: Binding(get: { model.settings.settings.mixWithOthers },
                                                                  set: { model.setMixWithOthers($0) }))
            } header: {
                Text("Audio")
            } footer: {
                Text("Bluetooth-Audio verursacht zusätzliche Verzögerung (je nach Gerät oft 100–300 ms), die iOS nicht immer vollständig meldet. Eine latenzfreie Wiedergabe ist nicht möglich; AUX/Kabel ist meist am direktesten. Beim Mischen läuft z. B. Musik einer anderen App weiter – ohne Spotify-Anmeldung oder -API.")
            }

            Section {
                Toggle("Automatisch wiederverbinden", isOn: Binding(get: { model.settings.settings.autoReconnect },
                                                                    set: { model.setAutoReconnect($0) }))
            } header: {
                Text("Verbindung")
            } footer: {
                Text("Begrenzte Anzahl Wiederverbindungsversuche nach Verbindungsabbruch sowie automatische Verbindung mit dem zuletzt genutzten BLE-Adapter beim App-Start.")
            }

            Section {
                NavigationLink {
                    VehicleProfileEditor()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(model.settings.settings.vehicleProfile.name, systemImage: "car.fill")
                        Text(model.settings.settings.vehicleProfile.userVerified ? "Angaben vom Nutzer geprüft" : "Vorlage – Angaben nicht verifiziert")
                            .font(.caption)
                            .foregroundStyle(model.settings.settings.vehicleProfile.userVerified ? DemonTheme.green : DemonTheme.warning)
                    }
                }
            } header: {
                Text("Fahrzeugprofil")
            }

            Section {
                Button {
                    model.showGuide = true
                } label: {
                    Label("Anleitung öffnen", systemImage: "book.closed.fill")
                }
                Button {
                    model.showOnboarding = true
                } label: {
                    Label("Ersteinrichtungs-Hinweis erneut zeigen", systemImage: "hand.wave.fill")
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmSoundReset = true
                } label: {
                    Label("Sound-Einstellungen & Favoriten zurücksetzen", systemImage: "arrow.counterclockwise")
                }
                Button(role: .destructive) {
                    confirmFullReset = true
                } label: {
                    Label("Alle Einstellungen zurücksetzen", systemImage: "trash")
                }
            } header: {
                Text("Zurücksetzen")
            } footer: {
                Text("Alle Einstellungen werden nur lokal auf diesem iPhone gespeichert. Es gibt kein Konto und keinen Server.")
            }

            Section("Über") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Text("Die App liest Fahrzeugdaten ausschließlich lesend über OBD2 und erzeugt den Sound auf dem iPhone. Sie verändert keine Motorsteuerung. Die Klänge sind synthetische Charaktere und keine Nachbildung konkreter Motoren.")
                    .font(.footnote)
                    .foregroundStyle(DemonTheme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .demonBackground()
        .navigationTitle("Einstellungen")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { GuideToolbarButton() }
        }
        .confirmationDialog("Sound-Einstellungen zurücksetzen?", isPresented: $confirmSoundReset, titleVisibility: .visible) {
            Button("Zurücksetzen", role: .destructive) { model.resetSoundSettings() }
        } message: {
            Text("Alle Preset-Anpassungen, Effekte, Favoriten und die Lautstärke werden auf Standard gesetzt.")
        }
        .confirmationDialog("Alle Einstellungen zurücksetzen?", isPresented: $confirmFullReset, titleVisibility: .visible) {
            Button("Alles zurücksetzen", role: .destructive) { model.resetAll() }
        } message: {
            Text("Auch Fahrzeugprofil, gespeicherte Adapter und WLAN-Daten werden gelöscht.")
        }
    }
}

struct VehicleProfileEditor: View {
    @Environment(AppModel.self) private var model
    @State private var draft = VehicleProfile.hondaJazz2015
    @State private var cylindersKnown = false
    @State private var cylinders = 4
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Bezeichnung", text: $draft.name)
                TextField("Motorisierung (z. B. aus Fahrzeugschein)", text: $draft.engineDescription)
                Toggle("Zylinderzahl bekannt", isOn: $cylindersKnown)
                if cylindersKnown {
                    Stepper("Zylinder: \(cylinders)", value: $cylinders, in: 1...16)
                }
            } header: {
                Text("Fahrzeug")
            } footer: {
                Text("Die Zylinderzahl dient nur der Information. Der Klang wird über das gewählte Preset bestimmt.")
            }

            Section {
                LabeledSlider(title: "Leerlaufdrehzahl (Annahme)", value: $draft.idleRPMReference, range: 300...2000, step: 50,
                              format: { "\($0.germanInteger) U/min" })
                LabeledSlider(title: "Höchstdrehzahl (Annahme)", value: $draft.maxRPMReference, range: 3000...12000, step: 100,
                              format: { "\($0.germanInteger) U/min" },
                              help: "Bestimmt Tachoskala, roten Bereich und die optionale Skalierung auf die virtuelle Sounddrehzahl.")
            } header: {
                Text("Drehzahlbereich")
            } footer: {
                Text("Diese Werte sind Annahmen. Sie verändern keine gemessenen Werte.")
            }

            Section {
                TextField("Notizen", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...8)
                Toggle("Angaben selbst geprüft", isOn: $draft.userVerified)
            }

            Section {
                Button("Vorlage „Honda Jazz (2015)“ wiederherstellen") {
                    draft = .hondaJazz2015
                    cylindersKnown = false
                }
            } footer: {
                Text("Die Vorlage nimmt weder Motorisierung noch unterstützte PIDs oder Drehzahlgrenzen als verifiziert an. Unterstützte Werte ermittelt die App beim Verbinden direkt vom Fahrzeug.")
            }
        }
        .scrollContentBackground(.hidden)
        .demonBackground()
        .navigationTitle("Fahrzeugprofil")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            draft = model.settings.settings.vehicleProfile
            cylindersKnown = draft.cylinders != nil
            cylinders = draft.cylinders ?? 4
            loaded = true
        }
        .onDisappear(perform: save)
        .onChange(of: draft) { _, _ in save() }
        .onChange(of: cylindersKnown) { _, _ in save() }
        .onChange(of: cylinders) { _, _ in save() }
    }

    private func save() {
        guard loaded else { return }
        var profile = draft
        profile.cylinders = cylindersKnown ? cylinders : nil
        model.updateProfile(profile)
    }
}
