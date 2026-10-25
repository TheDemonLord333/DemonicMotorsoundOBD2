# Demonic Motorsound OBD2

Native iOS-App (Swift, SwiftUI), die über einen OBD2-Adapter die **tatsächliche Motordrehzahl** und weitere verfügbare Fahrzeugdaten **ausschließlich lesend** abfragt und daraus auf dem iPhone in Echtzeit einen **synthetischen Motorsound** erzeugt. Die Wiedergabe läuft über die normale iOS-Audioausgabe – z. B. Autoradio per Bluetooth oder AUX.

> OBD2 dient nur zum Lesen. Die App verändert keine Motorsteuerung, sendet keine Codierungen, Stellgliedtests, Fehlerspeicher-Löschungen oder freie CAN-Nachrichten und gibt keinen Ton über den Adapter aus.

- Bundle Identifier: `me.thedemonlord333.DemonicMotorsoundOBD2`
- Projekt: `DemonicMotorsoundOBD2.xcodeproj` (Xcode 26, Ordner-synchronisierte Gruppen)
- Mindestversion: **iOS 18.0** (siehe [Entscheidungen](#technische-entscheidungen))
- Sprache der Oberfläche: Deutsch

---

## Einrichtung

1. `DemonicMotorsoundOBD2.xcodeproj` in Xcode 26 öffnen.
2. Unter *Signing & Capabilities* das eigene Team wählen (im Projekt ist `LWL7HM459L` hinterlegt).
3. Auf einem iPhone (iOS 18+) ausführen. Bluetooth und Audio funktionieren im Simulator nur eingeschränkt; der **Demomodus** ist auch im Simulator voll nutzbar.
4. Tests: `⌘U` (Unit-Tests mit Swift Testing, UI-Tests mit XCTest).

Es werden keine Pakete, Konten, Server oder kostenpflichtigen Dienste benötigt.

---

## Funktionsumfang (implementiert)

| Bereich | Inhalt |
|---|---|
| **Cockpit** | Animierter Drehzahlmesser (tatsächliche Drehzahl), große Zahl, separate Marke + Zeile für die virtuelle Sounddrehzahl, Geschwindigkeit, berechnete Last, Gaspedal und Drosselklappe getrennt, Kühlmitteltemperatur (mit Hinweis „keine Öltemperatur“), Preset, Verbindungs- und Datenqualitätsstatus, Alter des Drehzahlwerts, Datenrate, Audioausgabe, „Sound starten/stoppen“, Lautstärke, Ausgabewahl, kompakte Presetauswahl, Dämonen-Emblem (Augen-Glow wächst mit der Drehzahl). Hoch- und Querformat. |
| **Sounds** | 7 Presets, Favoriten, Editor pro Preset (Pegel, Bass, Aggressivität, Obertöne, Turbo, Glättung, virtuelle Leerlauf-/Maximaldrehzahl, Skalierung), Zusatzeffekte (Turbopfeifen, Blow-off, Schaltgeräusch), Zurücksetzen. |
| **Verbindung** | Demomodus-Schalter, BLE-Suche/Verbindung/Trennung/Wiederverbindung, automatische Profilerkennung, GATT-Explorer für unbekannte Adapter, WLAN (IP/Port), Adapterstatus (Version, Protokoll, Spannung, Motorsteuergerät, unterstützte Werte, Datenrate, Antwortzeit, Timeouts), Neuinitialisierung, Diagnoseprotokoll mit Export, Kompatibilitätsseite. |
| **Einstellungen** | Aktuelle Ausgabe + Ausgabewahl, gemeldete Latenz, Mischen mit anderer Musik, Auto-Wiederverbindung, editierbares Fahrzeugprofil (Vorlage Honda Jazz 2015, unverifiziert), Zurücksetzen (Sound / alles). |
| **Anleitung** | Über das Buch-Symbol in jeder Ansicht, in den Einstellungen und bei der Ersteinrichtung erreichbar. |
| **Demomodus** | Manuell (Motor an/aus, Drehzahl-, Lastregler) und automatische Demofahrt (Leerlauf, Beschleunigung, simulierte Gangwechsel, Konstantfahrt, Ausrollen). Dauerhaftes Banner „DEMOMODUS“. Keine Fahrzeugabfragen. |

---

## Architektur

```
DemonicMotorsoundOBD2/
├── Core/                     Plattformunabhängig (nur Foundation/Observation/Synchronization) – unter Linux getestet
│   ├── Common/               Monotone Zeitquelle, Hex-Helfer
│   ├── OBD/                  ELM327-Antwortpuffer & -Parser, Frame-Decoder (CAN 11/29 Bit, Legacy, ISO-TP),
│   │                         PID-Decodierung, Befehls-Freigabeliste, ELM327-Sitzung (serielle Queue),
│   │                         Abfrageplaner, Diagnoseprotokoll, BLE-Profilabgleich
│   ├── Vehicle/              Signale & Aktualität, getrennte Datenspeicher (Fahrzeug/Demo), Lastquelle,
│   │                         Lastschätzung, Schalt-/Lastabfall-Schätzung, Fahrzeugprofil
│   ├── Audio/                Presets & Einstellungen, lock-freie Parameterübergabe (Atomics),
│   │                         prozeduraler Synthesizer, Drehzahl-Folgelogik, SoundDriver (Steuerrate 50 Hz)
│   ├── Demo/                 Demo-Simulator
│   └── Persistence/          Lokale Einstellungen (UserDefaults, JSON)
├── Platform/                 Apple-spezifisch
│   ├── Bluetooth/            CoreBluetooth (BLEManager + nicht isolierter Delegate-Proxy)
│   ├── Network/              Network.framework (NWConnection, TCP)
│   └── Audio/                AVAudioSession + AVAudioEngine + AVAudioSourceNode
├── App/                      AppModel (Verknüpfung), ConnectionManager
└── UI/                       SwiftUI: Theme, Komponenten, Cockpit, Sounds, Verbindung, Einstellungen, Anleitung
```

Datenfluss: `Transport (BLE/WLAN) → ELM327Session → SignalSample(.vehicle) → VehicleDataStore(live)` bzw. `DemoSimulator → SignalSample(.demo) → VehicleDataStore(demo)` → `SoundDriver` (nur der Speicher der aktiven Betriebsart) → `SynthControl` (Atomics) → Render-Callback.

### OBD2 / ELM327

- **Initialisierung:** `ATZ`, `ATE0`, `ATL0`, `ATS1`, `ATH1`, `ATAT1`, `ATSP0`, `ATI`, `ATRV`, dann `0100` (mit langem Timeout wegen `SEARCHING...`), `ATDPN`, `0120`/`0140` nur bei Bedarf.
- **Freigabeliste:** `ELM327CommandPolicy` lässt nur diese AT-Befehle und Mode-01-Einzelabfragen (`01xx`, optional mit Antwortanzahl-Ziffer) zu. Alles andere wird vor dem Senden blockiert (getestet).
- **Robustheit:** Fragmentierte Antworten werden bis zum Prompt `>` gesammelt, NUL-Bytes ignoriert, Echo entfernt, `SEARCHING...`/`BUS INIT` gefiltert, Fehler (`NO DATA`, `?`, `UNABLE TO CONNECT`, `CAN ERROR`, `BUFFER FULL`, `STOPPED`, `ERRxx`, `<DATA ERROR` …) klassifiziert. Nach einem Timeout folgt eine Ruhephase, in der verspätete Antworten verworfen werden.
- **Mehrere Steuergeräte:** Mit Headern (`ATH1`) werden Antworten je Absender (z. B. `7E8`, `7E9`, `18DAF110`) gruppiert, ISO-TP-Mehrfachrahmen je Absender zusammengesetzt; Werte werden nur vom gewählten Motorsteuergerät übernommen.
- **Unterstützte PIDs** werden vor der Abfrage aus den Bitmasken ermittelt. Wiederholt `NO DATA` → Wert wird nicht mehr abgefragt und als „Nicht verfügbar“ markiert.
- **Abfrageplanung:** Drehzahl mit Vorrang; Last/Pedal/Drosselklappe ~4 Hz, Geschwindigkeit ~2 Hz, Kühlmittel alle 5 s. Bei langsamen Adaptern werden Nebenwerte gestreckt und die Drehzahl bekommt mehr Slots. Antwortanzahl-Suffix (`010C1`) nur, wenn genau ein Steuergerät antwortet (mit automatischem Rückfall).
- **PIDs:** 04 (berechnete Last), 05 (Kühlmittel), 0C (Drehzahl), 0D (Geschwindigkeit), 11 (Drosselklappe), 49 (Gaspedal D), 5A (relatives Gaspedal, Ausweichwert). Drosselklappe und Gaspedal sind getrennte Signale.

### Unterstützte Adapter / Profile

| Typ | Status |
|---|---|
| BLE, Service `FFF0`, Notify `FFF1`, Write `FFF2` | automatisch erkannt (Quelle: OBDLink-CX-Adapterhinweise; verbreitet bei ELM327-BLE-Adaptern) |
| BLE, Service `FFE0`, Characteristic `FFE1` (Write + Notify) | automatisch erkannt (Quelle: Datenblatt BLE-Modul HM-10) |
| BLE, Service `18F0`, Notify `2AF0`, Write `2AF1` | automatisch erkannt (Quelle: Community-Dokumentation Vgate iCar Pro BLE 4.0, nicht vom Hersteller bestätigt) |
| Andere BLE-Adapter | manuelle Auswahl von Service/Write/Notify aus den tatsächlich entdeckten GATT-Diensten; nur Characteristics mit passenden Eigenschaften wählbar; Auswahl wird je Gerät gespeichert |
| WLAN (ELM327 über TCP) | IP/Port frei einstellbar (Vorgabe 192.168.0.10:35000 – häufig, aber adapterabhängig) |
| Klassisches Bluetooth (SPP) | **nicht möglich** unter iOS |
| MFi / External Accessory | **nicht implementiert** (bräuchte Herstellerfreigabe und Protokolldoku) |

Auch bei erkanntem Profil wird geprüft, ob die Characteristics Schreiben bzw. Benachrichtigen unterstützen. Ausgehende Daten werden gemäß `maximumWriteValueLength` fragmentiert; „Write without Response“ nutzt die Flusskontrolle `canSendWriteWithoutResponse`. Es gibt keine Garantie, dass jeder BLE-Adapter funktioniert.

### Motorsound-Engine

- `AVAudioEngine` mit `AVAudioSourceNode` (Mono, Hardware-Abtastrate). Der Render-Block wird außerhalb des MainActor erzeugt, alloziert nicht, nutzt keine Locks, keine Datei- oder Netzwerkzugriffe. Parameter kommen über `Synchronization.Atomic`.
- **Prozedurale Synthese:** Pro Zylinder phasenkontinuierliche Zündimpulse (Druckstoß + gedämpfte Auspuffresonanzen) auf einer Arbeitsspiel-Phase, die beim Viertakter mit `Drehzahl/120` Hz läuft. Damit gilt: **Zündfrequenz = Drehzahl/60 × Zylinder/2** (Test: 4 Zylinder bei 3000 U/min → 100 Hz). Zündfolge/Impulsabstände (z. B. Cross-Plane-V8 1-8-4-3-6-5-7-2 mit Bank-Unterschieden, ungleichmäßige Abstände beim Demonic-Preset), Zyklus-Schwankungen, impulsmoduliertes Verbrennungsrauschen, Ansaugrauschen, last- und drehzahlabhängiger Tiefpass, Bass-Shelf, Sättigung, Unterton.
- **Presets:** Sportlicher Vierzylinder, Tiefer V8, Hochdrehender V10, V12-Supersport, Turbo Beast (R6 + Turbo), Demonic Engine (tiefes Grollen, aggressive Obertöne, Formant-Knurren und dezenter dissonanter Layer), Sci-Fi Reactor (verstimmte Oszillatoren, FM-Whine, resonantes Plasma-Rauschen, steigt mit Drehzahl und Last).
- **Effekte (optional, rein synthetisch):** Turbopfeifen (Ladedruck aus Last/Drehzahl geschätzt), Blow-off bei geschätztem Lastabfall, dezentes Schaltgeräusch bei geschätztem Schaltvorgang.
- **Sicherheit:** Parameterglättung, Presetwechsel mit Aus-/Einblenden (klickfrei), Einblendrampe beim Start, DC-Sperre, Begrenzer (Spitzen ≤ −1 dBFS), NaN-Schutz, **Watchdog**: bleibt das Lebenszeichen der Steuerlogik > 1 s aus, blendet der Synthesizer selbstständig aus.
- Die Klänge sind **synthetische Charaktere**, keine Aufnahmen und keine garantierte Nachbildung realer Motoren.

### Tatsächliche vs. virtuelle Drehzahl

- Die Anzeige zeigt immer die **gemessene** Drehzahl; Soundeinstellungen verändern sie nicht.
- Die **virtuelle Sounddrehzahl** entsteht durch: Skalierung (optional, Fahrzeugprofil-Bereich → virtueller Bereich) bzw. Begrenzung auf [virtueller Leerlauf, virtuelles Maximum], Glättung (asymmetrisch, Abfall weicher).
- **Datenaussetzer:** bis 0,25 s begrenzte Extrapolation (max. +10 %), bis 0,9 s Halten, danach Ausblenden in Richtung Leerlauf; ab 2,5 s „Keine Drehzahldaten“. Nie Dauerbetrieb mit letzter hoher Drehzahl.
- **Motorstillstand** (< 250 U/min) → Sound läuft aus, auch wenn eine virtuelle Leerlaufdrehzahl gesetzt ist.
- **Wiedereinstieg** (Datenrückkehr, Wiederverbindung, Moduswechsel) → langsames Einblenden (max. 60 %/s).

### Audio-Session & iOS-Verhalten

- Kategorie `.playback` (Modus `.default`), optional `.mixWithOthers`. Route-Auswahl über `AVRoutePickerView`, aktuelle Route und gemeldete Latenz werden angezeigt.
- Unterbrechungen (Anruf, Siri): Engine stoppt; bei `shouldResume` Neustart mit Einblendung – außer die externe Ausgabe ist inzwischen weg.
- **Verlust der externen Ausgabe** (`oldDeviceUnavailable` bzw. Wechsel von extern auf Lautsprecher): Sound pausiert, Hinweis, **manueller** Neustart.
- Engine-Konfigurationswechsel und Neustart der Mediendienste werden behandelt.
- Hintergrund: `UIBackgroundModes` = `audio` (nur sinnvoll, solange der Sound läuft) und `bluetooth-central` (damit BLE-Daten während der Hintergrundwiedergabe weiter ankommen). Ohne aktiven Sound pausiert die App die Abfragen beim Wechsel in den Hintergrund und iOS suspendiert sie. **Keine Garantie für unbegrenzten Hintergrundbetrieb**; WLAN-Verbindungen können bei Suspendierung abbrechen; keine BLE-State-Restoration implementiert.
- Beim Zurückkehren in den Vordergrund werden Aktualität und Route sofort neu bewertet (monotone `ContinuousClock`, läuft auch im Geräteschlaf weiter).

### Berechtigungen (Info.plist: `Config/DemonicMotorsoundOBD2-Info.plist`)

- `NSBluetoothAlwaysUsageDescription` – deutscher Erklärungstext
- `NSLocalNetworkUsageDescription` – deutscher Erklärungstext
- `UIBackgroundModes`: `audio`, `bluetooth-central`

---

## App-Icon

- Quelle: die im Repository vorhandene Datei `Dämonischer Motor mit Neon-Tacho.png` (Dateiname im Repo in **zerlegter Unicode-Schreibweise**, „a“ + U+0308; der Pfad wurde per Unicode-Normalisierung ermittelt, nicht angenommen).
- Geprüft: echtes PNG (Signatur), 1254 × 1254 px, RGB **ohne Alphakanal** (keine Transparenz zu entfernen), quadratisch.
- Erzeugt: `AppIcon.appiconset/AppIcon-1024.png` (1024 × 1024, Lanczos-Verkleinerung des gesamten Motivs – nichts beschnitten, nicht verzerrt, keine Schrift, kein Rahmen, keine eingebrannten Ecken) für „Any“ und „Dark“, sowie eine Graustufen-Ableitung für „Tinted“ (iOS-18-Darstellung). Xcode 26 nutzt das Single-Size-Format; das Target verweist per `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` darauf.
- Zusätzlich `AppArtwork.imageset` (256/512/768 px) für Emblem, Anleitung und Ersteinrichtung.

---

## Tests

### Was ohne Hardware getestet wurde

Die Kernlogik (`DemonicMotorsoundOBD2/Core`) wurde mit den Unit-Tests aus `DemonicMotorsoundOBD2Tests` in einem **Swift-6.2-Linux-Container** gebaut und ausgeführt (gleiche Compiler-Einstellungen wie im Xcode-Projekt: Swift-5-Modus, Standard-Isolation MainActor, Approachable Concurrency, MemberImportVisibility):

```
scripts/run-core-tests-linux.sh      # benötigt Docker
→ Test run with 58 tests in 10 suites passed
```

Abgedeckt:
- PID-Decodierung und Einheiten, Bitmasken der unterstützten PIDs, Trennung Drosselklappe/Gaspedal
- ELM327: Fragmentierung, NUL-Bytes, mehrere Antworten in einem Paket, Echo, `SEARCHING...`, `BUS INIT`, Fehlerantworten, teilweise `<DATA ERROR`
- Mehrere ECUs (Header, Auswahl des Motorsteuergeräts, kein Vermischen), ISO-TP mit verschachtelten ECUs, Reihenfolgefehler, Mehrfachrahmen ohne Header, CAN 29 Bit, Legacy-Header mit Prüfsumme, negative Antworten
- Vollständige Sitzung gegen simulierten Adapter (fragmentiert, mit Echo): Initialisierungsreihenfolge, Protokoll, PID-Erkennung, Polling, nur erlaubte Befehle; `UNABLE TO CONNECT`; Timeout mit verspäteter Antwort (wird verworfen); wiederholtes `NO DATA`; verstummender Adapter
- Befehls-Freigabeliste (z. B. `04`, `ATSH…`, `2F…` werden blockiert)
- Datenaktualität / veraltete Werte, Herkunftstrennung der Speicher
- Übergang Demo ↔ Echtbetrieb (keine Vermischung, Ausblenden, Neustart mit Präsenz 0)
- Sound-Folgelogik: Einblenden, Überbrücken, Ausblenden bei Datenverlust, Motorstopp trotz virtuellem Leerlauf, Abbildung real → virtuell, Begrenzung unsicherer Parameter
- Synthesizer: alle Presets hörbar, endlich und ≤ 0,9 Spitze; Presets unterscheiden sich; Zündfrequenz-Beziehung; Ausblenden bei Präsenz 0; Watchdog; klickfreier Presetwechsel; Einblendrampe; Effekte im Pegelrahmen; Rechenzeit deutlich unter Echtzeit
- Einstellungen speichern/zurücksetzen

### Was hier **nicht** geprüft werden konnte

In dieser Umgebung (Linux) sind **weder Xcode noch die iOS-SDKs** verfügbar. Ein iOS-Build wurde daher **nicht** ausgeführt; die Apple-spezifischen Schichten (`Platform/`, `App/`, `UI/`, CoreBluetooth, Network, AVFAudio, SwiftUI) sind nicht kompiliert worden. Bitte zuerst in Xcode bauen (`⌘B`) und `⌘U` ausführen; eventuelle Compilerhinweise sind dort zu beheben.

### Notwendige Tests auf echtem iPhone mit Adapter

1. Build & Start auf iOS 18+, Berechtigungsdialoge (Bluetooth, Lokales Netzwerk) mit deutschen Texten.
2. Demomodus: Sound über Lautsprecher, Bluetooth-Radio und AUX; Presetwechsel ohne Klicken; Lautstärke.
3. BLE-Adapter: Suche, Profilerkennung bzw. manuelle GATT-Auswahl, Initialisierung, Datenrate, Wiederverbindung nach Ab-/Anstecken.
4. WLAN-Adapter: Verbindung, Berechtigung, Abbruch und Wiederverbindung.
5. Honda Jazz 2015: tatsächlich unterstützte PIDs, Leerlauf- und Höchstdrehzahl im Profil eintragen, Steuergeräte-Antworten im Diagnoseprotokoll prüfen.
6. Audio-Routen: Trennen der Bluetooth-Verbindung während der Wiedergabe (Sound muss pausieren), Anruf/Siri, CarPlay, Sperrbildschirm/Hintergrund.
7. Latenz subjektiv beurteilen (Bluetooth vs. AUX), CPU-/Akkulast über längere Fahrten (Instruments).
8. Dynamic Type (große Schrift), „Bewegung reduzieren“, Querformat auf kleinen und großen iPhones.

---

## Technische Entscheidungen

- **iOS 18.0 als Mindestversion:** benötigt für `Synchronization.Atomic` (lock-freie, echtzeitsichere Parameterübergabe ohne Fremdpaket). iOS 18 unterstützt dieselben Geräte wie iOS 17 (iPhone XS/XR und neuer), kostet also keine Gerätebasis. Ursprünglich stand im Projekt 26.2.
- **Kein SwiftData** (Vorlage entfernt): Einstellungen sind klein und werden als JSON in `UserDefaults` gespeichert.
- **Swift-5-Sprachmodus** mit Standard-Isolation MainActor (wie vom Xcode-26-Template vorgegeben); echtzeitkritische Typen sind ausdrücklich `nonisolated`.
- **CoreBluetooth/Network auf der Main-Queue:** geringe Datenmengen; vereinfacht die Isolation (Delegates via `MainActor.assumeIsolated`).
- **Header an (`ATH1`)**, damit Antworten mehrerer Steuergeräte sicher getrennt werden können; Rückfall ohne Header mit Warnung.
- **Keine Spotify-Anbindung**: Mischen mit anderer Musik erfolgt ausschließlich über `AVAudioSession.CategoryOptions.mixWithOthers`.

## Bekannte Grenzen

- Konkretes Adaptermodell unbekannt → reale Verbindung ist hardwareabhängig und muss vor Ort geprüft werden.
- Bluetooth-Audio hat zusätzliche, nicht vollständig gemeldete Latenz (typisch 100–300 ms). Keine latenzfreie Wiedergabe.
- Kein unbegrenzter Hintergrundbetrieb; keine BLE-State-Restoration.
- Lastschätzung, Schaltvorgänge und Blow-off-Auslöser sind Schätzungen.
- Kühlmitteltemperatur ist keine Öltemperatur.
- Der lange Anzeigename „Demonic Motorsound OBD2“ wird auf dem Homescreen von iOS gekürzt dargestellt.
