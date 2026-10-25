import Foundation
import SwiftUI

/// Deutsche Anleitung.
struct GuideView: View {
    private struct Topic: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let text: String
    }

    private let topics: [Topic] = [
        Topic(id: "zweck", title: "Zweck und Funktionsweise", symbol: "sparkles", text: """
        Die App liest über einen OBD2-Adapter die tatsächliche Motordrehzahl und – sofern vorhanden – weitere Werte wie Geschwindigkeit, Last, Gaspedal, Drosselklappe und Kühlmitteltemperatur.

        Daraus berechnet das iPhone in Echtzeit einen synthetischen Motorsound. Der Sound entsteht vollständig auf dem iPhone und wird über die gewählte iOS-Audioausgabe abgespielt, z. B. über das Autoradio per Bluetooth oder AUX.

        OBD2 dient ausschließlich zum Lesen. Die App verändert keine Motorsteuerung, sendet keine Codierungen, löscht keine Fehlerspeicher und gibt keinen Ton über den Adapter aus.
        """),
        Topic(id: "adapter", title: "Geeignete Adapter", symbol: "cpu", text: """
        Geeignet sind ELM327-kompatible Adapter mit
        • Bluetooth Low Energy (BLE, „Bluetooth 4.0“, oft mit iOS-Angabe) oder
        • WLAN.

        Nicht geeignet sind klassische Bluetooth-Adapter (SPP, Kopplung per PIN 1234/0000). iOS erlaubt Apps keinen Zugriff auf solche Geräte – sie erscheinen weder in iOS noch in der App.

        Für einige BLE-Profile ist die Zuordnung dokumentiert und wird automatisch erkannt (siehe Verbindung → Kompatibilität). Andere BLE-Adapter können über die manuelle GATT-Auswahl ausprobiert werden. Eine Garantie für jeden Adapter gibt es nicht; besonders sehr günstige Nachbauten verhalten sich teils fehlerhaft.
        """),
        Topic(id: "ble", title: "Verbindung per Bluetooth LE", symbol: "dot.radiowaves.left.and.right", text: """
        1. Adapter in die OBD2-Buchse stecken (meist im Fußraum unter dem Armaturenbrett auf der Fahrerseite – genaue Lage laut Betriebsanleitung).
        2. Zündung einschalten bzw. Motor starten.
        3. In der App: Verbindung → Bluetooth LE → „Nach BLE-Adaptern suchen“.
        4. Adapter antippen. BLE-Adapter werden nicht in den iOS-Bluetooth-Einstellungen gekoppelt.
        5. Wird kein bekanntes Profil gefunden, unter „Characteristics auswählen“ einen Dienst mit einer Write- und einer Notify-Characteristic wählen.

        Die App initialisiert den Adapter, erkennt die vom Fahrzeug unterstützten Werte und fragt danach laufend ab – die Drehzahl am häufigsten.
        """),
        Topic(id: "wlan", title: "Verbindung per WLAN", symbol: "wifi", text: """
        1. Adapter einstecken, Zündung an.
        2. In den iOS-Einstellungen → WLAN das Netz des Adapters wählen.
        3. In der App IP-Adresse und Port eintragen (häufig 192.168.0.10 und 35000 – maßgeblich ist die Anleitung des Adapters).
        4. Beim ersten Verbinden die Abfrage „Lokales Netzwerk“ erlauben. Falls versehentlich abgelehnt: iOS-Einstellungen → Datenschutz & Sicherheit → Lokales Netzwerk.

        Solange das iPhone mit dem Adapter-WLAN verbunden ist, steht darüber meist kein Internet zur Verfügung.
        """),
        Topic(id: "werte", title: "Fahrzeugdaten vs. Soundparameter", symbol: "arrow.left.arrow.right", text: """
        Tatsächliche OBD-Drehzahl: der vom Fahrzeug gemeldete Wert. Er wird im Cockpit groß angezeigt und durch keine Soundeinstellung verändert.

        Virtuelle Sounddrehzahl: die Drehzahl, mit der der Sound erzeugt wird. Sie kann über virtuelle Leerlaufdrehzahl, oberen virtuellen Bereich und optionale Skalierung angepasst werden und erscheint nur als kleine violette Marke und Zusatzzeile.

        Last: Für die Klangformung nutzt die App – falls verfügbar – die berechnete Motorlast, sonst die Gaspedalstellung, sonst die Drosselklappe. Gaspedal und Drosselklappe sind unterschiedliche Messwerte und werden getrennt angezeigt. Fehlt alles, wird eine Last aus der Drehzahländerung geschätzt und als „geschätzt“ gekennzeichnet.

        Kühlmitteltemperatur ist keine Öltemperatur und kein Nachweis für einen vollständig warmen Motor.
        """),
        Topic(id: "audio", title: "Audioausgabe über Bluetooth oder AUX", symbol: "car.fill", text: """
        Der Sound läuft über die normale iOS-Audioausgabe. Die Ausgabe lässt sich im Kontrollzentrum oder über das AirPlay-Symbol in der App wählen.

        • Bluetooth: iPhone mit dem Autoradio koppeln und als Medienquelle wählen.
        • AUX: Kabel vom iPhone (ggf. mit Adapter) zum AUX-Eingang.

        Wird eine externe Ausgabe während der Wiedergabe getrennt, pausiert die App den Sound, damit er nicht plötzlich laut über den iPhone-Lautsprecher weiterläuft. Ein Neustart erfolgt nur manuell.

        Optional kann der Sound mit Musik anderer Apps gemischt werden (Einstellungen → Audio).
        """),
        Topic(id: "latenz", title: "Bluetooth-Audiolatenz", symbol: "timer", text: """
        Bluetooth-Audio puffert die Wiedergabe. Je nach Autoradio entstehen zusätzlich oft 100–300 ms Verzögerung, die iOS nicht immer vollständig meldet. Hinzu kommt die Abfragezeit des OBD-Adapters. Der Sound folgt der echten Drehzahl daher immer mit etwas Verzögerung – eine latenzfreie Wiedergabe ist technisch nicht möglich. AUX ist meist am direktesten.
        """),
        Topic(id: "fehlend", title: "Fehlende oder nicht unterstützte Werte", symbol: "questionmark.diamond", text: """
        Nicht jedes Fahrzeug liefert alle Werte. Die App fragt beim Verbinden ab, welche Werte das Motorsteuergerät unterstützt, und zeigt alle anderen als „Nicht verfügbar“ an. Werte werden nie erfunden.

        Liefert ein Wert wiederholt keine Daten, wird er nicht mehr abgefragt. Veraltete Werte werden als „Verzögert“ oder „Veraltet“ markiert und nicht als aktuell angezeigt.

        Die Drehzahl ist für den Sound zwingend. Ist nur die Drehzahl verfügbar, funktioniert der Grundsound trotzdem.

        Für den Honda Jazz (2015) ist in der App ein editierbares Profil hinterlegt. Motorisierung, unterstützte Werte und Drehzahlgrenzen sind darin bewusst nicht als verifiziert angenommen.
        """),
        Topic(id: "demo", title: "Demomodus", symbol: "theatermasks.fill", text: """
        Der Demomodus (Verbindung → Demomodus) funktioniert ohne Adapter. Er nutzt dieselbe Audioengine wie der Echtbetrieb.

        • Manuell: Motor starten/stoppen, Drehzahl- und Lastregler.
        • Demofahrt: automatischer Ablauf mit Leerlauf, Beschleunigung, simulierten Gangwechseln und Ausrollen.

        Im Demomodus ist dauerhaft „DEMOMODUS“ eingeblendet, es werden keine Fahrzeugabfragen gesendet und Demo- und Fahrzeugdaten werden strikt getrennt gehalten.
        """),
        Topic(id: "hintergrund", title: "Hintergrundbetrieb und Grenzen", symbol: "moon.fill", text: """
        Solange der Sound läuft, darf die App im Hintergrund und bei gesperrtem Bildschirm weiterarbeiten (Hintergrund-Audio). Die Fahrzeugabfrage läuft dann weiter.

        Ist der Sound gestoppt, pausiert die App die Fahrzeugabfragen im Hintergrund; iOS setzt die App kurz darauf aus. Eine WLAN-Verbindung kann dabei getrennt werden.

        iOS kann Apps jederzeit beenden (z. B. bei Speichermangel). Eine unbegrenzte Hintergrundverbindung ist daher nicht garantiert. Nach Rückkehr in die App werden Status und Datenaktualität sofort neu bewertet; alte Werte erscheinen nicht als aktuell.
        """),
        Topic(id: "fehler", title: "Typische Verbindungsfehler", symbol: "wrench.and.screwdriver.fill", text: """
        • Adapter wird nicht gefunden: Ist es ein BLE-Adapter? Klassische Bluetooth-Adapter funktionieren nicht. Bluetooth-Berechtigung in den iOS-Einstellungen prüfen. „Geräte ohne Namen anzeigen“ aktivieren.
        • „UNABLE TO CONNECT“: Zündung einschalten bzw. Motor starten, Adapter fest einstecken.
        • Zeitüberschreitungen: Adapter kurz abziehen, neu verbinden, „Adapter neu initialisieren“.
        • Unbekanntes Profil: Unter „Characteristics auswählen“ einen Dienst mit Write- und Notify-Characteristic wählen. Wenn danach keine Antwort kommt, ist es vermutlich kein ELM327-kompatibler Adapter.
        • WLAN: iPhone im Adapter-WLAN? IP/Port korrekt? Berechtigung „Lokales Netzwerk“ erteilt?
        • Niedrige Datenrate: Günstige Adapter schaffen oft nur wenige Abfragen pro Sekunde. Die App priorisiert dann die Drehzahl.

        Das Diagnoseprotokoll (Verbindung → Diagnoseprotokoll) zeigt Befehle und Antworten und kann exportiert werden.
        """),
        Topic(id: "sicherheit", title: "Sicherheit", symbol: "exclamationmark.shield.fill", text: """
        Einrichtung und Bedienung nur im Stand. Lautstärke so wählen, dass Verkehrsgeräusche, Signale und Einsatzfahrzeuge jederzeit hörbar bleiben.
        """),
    ]

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image("AppArtwork")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Demonic Motorsound OBD2")
                            .font(.headline)
                        Text("Anleitung")
                            .font(.subheadline)
                            .foregroundStyle(DemonTheme.textSecondary)
                    }
                }
            }
            ForEach(topics) { topic in
                Section {
                    DisclosureGroup {
                        Text(topic.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    } label: {
                        Label(topic.title, systemImage: topic.symbol)
                            .font(.headline)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .demonBackground()
        .navigationTitle("Anleitung")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Kurzer, einmaliger Hinweis bei der Ersteinrichtung.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("AppArtwork")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    .shadow(color: DemonTheme.blurple.opacity(0.5), radius: 24)
                    .accessibilityHidden(true)

                Text("Demonic Motorsound OBD2")
                    .font(.title.weight(.heavy))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DemonTheme.accentGradient)

                Text("Liest die echte Drehzahl über einen OBD2-Adapter und erzeugt daraus einen synthetischen Motorsound auf deinem iPhone – abgespielt über Bluetooth oder AUX.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DemonTheme.textSecondary)

                Label {
                    Text("Einrichtung bitte im Stand durchführen und die Lautstärke so wählen, dass Verkehrsgeräusche hörbar bleiben.")
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(DemonTheme.warning)
                }
                .font(.callout.weight(.semibold))
                .neonPanel(glow: 0.1, padding: 14)

                VStack(spacing: 12) {
                    Button {
                        model.completeOnboarding()
                        model.selectedTab = .connection
                    } label: {
                        Label("Adapter verbinden", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DemonTheme.green)

                    Button {
                        model.completeOnboarding()
                        model.setDemoMode(true)
                        model.selectedTab = .cockpit
                    } label: {
                        Label("Demomodus ausprobieren", systemImage: "theatermasks.fill")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    .tint(DemonTheme.blurple)

                    Button("Anleitung lesen") {
                        model.completeOnboarding()
                        // Erst nach dem Schließen dieses Hinweises die Anleitung zeigen.
                        Task {
                            try? await Task.sleep(for: .milliseconds(600))
                            model.showGuide = true
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .demonBackground()
    }
}
