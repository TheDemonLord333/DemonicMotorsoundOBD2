import Foundation
import SwiftUI
import UIKit

struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @State private var transport: TransportKind = .bluetoothLE

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.isDemoMode }, set: { model.setDemoMode($0) })) {
                    Label("Demomodus (ohne Adapter)", systemImage: "theatermasks.fill")
                }
                .tint(DemonTheme.blurple)
            } footer: {
                Text(model.isDemoMode
                     ? "Im Demomodus werden keine Fahrzeugabfragen gesendet. Alle Werte sind simuliert und als DEMO gekennzeichnet."
                     : "Echtbetrieb: Werte stammen ausschließlich vom verbundenen OBD2-Adapter.")
            }

            Section("Verbindungsart") {
                Picker("Verbindungsart", selection: $transport) {
                    ForEach(TransportKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: transport) { _, kind in
                    model.settings.update { $0.transportKind = kind }
                }
            }

            if transport == .bluetoothLE {
                BLESection()
            } else {
                WiFiSection()
            }

            AdapterStatusSection()

            Section {
                NavigationLink {
                    DiagnosticLogView()
                } label: {
                    Label("Diagnoseprotokoll", systemImage: "doc.text.magnifyingglass")
                }
                NavigationLink {
                    CompatibilityView()
                } label: {
                    Label("Kompatibilität & unterstützte Profile", systemImage: "checklist")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .demonBackground()
        .navigationTitle("Verbindung")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { GuideToolbarButton() }
        }
        .onAppear { transport = model.settings.settings.transportKind }
    }
}

// MARK: - BLE

private struct BLESection: View {
    @Environment(AppModel.self) private var model
    @State private var showUnnamed = false

    var body: some View {
        let ble = model.connection.ble
        Section {
            Label(ble.bluetoothStateText, systemImage: ble.isPoweredOn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ble.isPoweredOn ? DemonTheme.green : DemonTheme.warning)

            if model.connection.activeKind == .bluetoothLE, ble.linkState != .idle {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ble.connectedName ?? "Adapter")
                            .font(.headline)
                        Text(ble.linkState.title)
                            .font(.caption)
                            .foregroundStyle(linkColor(ble.linkState))
                        if let profile = ble.matchedProfile {
                            Text("Profil: \(profile.name)")
                                .font(.caption2)
                                .foregroundStyle(DemonTheme.textSecondary)
                        } else if ble.activeSelection != nil {
                            Text("Profil: manuelle GATT-Auswahl")
                                .font(.caption2)
                                .foregroundStyle(DemonTheme.textSecondary)
                        }
                    }
                    Spacer()
                    Button("Trennen", role: .destructive) {
                        model.connection.disconnect()
                    }
                    .buttonStyle(.bordered)
                }
                if ble.linkState == .needsCharacteristicSelection || !ble.services.isEmpty {
                    NavigationLink {
                        GATTExplorerView()
                    } label: {
                        Label(ble.linkState == .needsCharacteristicSelection ? "Characteristics auswählen (erforderlich)" : "Erweitert: GATT-Dienste",
                              systemImage: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(ble.linkState == .needsCharacteristicSelection ? DemonTheme.warning : DemonTheme.blurple)
                    }
                }
            }

            Button {
                if ble.isScanning { ble.stopScan() } else { ble.startScan() }
            } label: {
                HStack {
                    Label(ble.isScanning ? "Suche stoppen" : "Nach BLE-Adaptern suchen",
                          systemImage: ble.isScanning ? "stop.circle" : "magnifyingglass")
                    if ble.isScanning {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            Toggle("Geräte ohne Namen anzeigen", isOn: $showUnnamed)
        } header: {
            Text("Bluetooth Low Energy")
        } footer: {
            Text("Klassische Bluetooth-Adapter (SPP, oft „ELM327 Bluetooth“ mit PIN 1234) funktionieren mit iOS nicht und erscheinen hier nicht. Benötigt wird ein BLE- (Bluetooth 4.0+) oder WLAN-Adapter.")
        }
        .onAppear { ble.activate() }

        let devices = ble.discovered.filter { showUnnamed || $0.name != "Unbenanntes Gerät" }
        if !devices.isEmpty {
            Section("Gefundene Geräte") {
                ForEach(devices) { device in
                    DeviceRow(device: device)
                }
            }
        }
    }

    private func linkColor(_ state: BLEManager.LinkState) -> Color {
        switch state {
        case .ready: DemonTheme.green
        case .failed, .needsCharacteristicSelection: DemonTheme.warning
        default: DemonTheme.textSecondary
        }
    }
}

private struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: DiscoveredPeripheral

    var body: some View {
        let ble = model.connection.ble
        let isCurrent = ble.connectedPeripheralID == device.id && model.connection.activeKind == .bluetoothLE
        Button {
            model.connection.connectBLE(device.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Text("Signal \(device.rssi) dBm")
                        if device.advertisesKnownService {
                            Text("· bekanntes OBD-Profil")
                                .foregroundStyle(DemonTheme.green)
                        }
                        if !device.isConnectable {
                            Text("· nicht verbindbar")
                                .foregroundStyle(DemonTheme.warning)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(DemonTheme.textSecondary)
                }
                Spacer()
                if isCurrent {
                    Text(ble.linkState == .ready ? "Verbunden" : "…")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ble.linkState == .ready ? DemonTheme.green : DemonTheme.textSecondary)
                } else {
                    Image(systemName: "link")
                        .foregroundStyle(DemonTheme.blurple)
                }
            }
        }
        .disabled(!device.isConnectable || (isCurrent && ble.linkState == .ready))
        .accessibilityHint("Mit diesem Gerät verbinden")
    }
}

// MARK: - WLAN

private struct WiFiSection: View {
    @Environment(AppModel.self) private var model
    @State private var host = ""
    @State private var port = ""

    var body: some View {
        let wifi = model.connection.wifi
        Section {
            TextField("IP-Adresse", text: $host)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Port", text: $port)
                .keyboardType(.numberPad)
            if model.connection.activeKind == .wifi, wifi.state != .idle {
                Label(wifi.state.title, systemImage: wifi.isReady ? "checkmark.circle.fill" : "wifi.exclamationmark")
                    .foregroundStyle(wifi.isReady ? DemonTheme.green : DemonTheme.warning)
                    .font(.subheadline)
                Button("Trennen", role: .destructive) {
                    model.connection.disconnect()
                }
            }
            Button {
                let portNumber = Int(port) ?? 0
                model.settings.update {
                    $0.wifiHost = host
                    $0.wifiPort = portNumber
                    $0.transportKind = .wifi
                }
                model.connection.connectWiFi(host: host, port: portNumber)
            } label: {
                Label("Verbinden", systemImage: "wifi")
            }
            .disabled(host.isEmpty || Int(port) == nil)
        } header: {
            Text("WLAN-Adapter")
        } footer: {
            Text("1. Adapter einstecken, Zündung an.\n2. In den iOS-Einstellungen das WLAN des Adapters wählen (Name z. B. „WiFi_OBDII“ bzw. laut Anleitung).\n3. Hier IP-Adresse und Port eintragen. Häufig sind 192.168.0.10 und Port 35000 – maßgeblich ist die Anleitung des Adapters.\n4. Beim ersten Verbinden den Zugriff auf das lokale Netzwerk erlauben.\nHinweis: Solange das iPhone mit dem Adapter-WLAN verbunden ist, hat es darüber meist kein Internet.")
        }
        .onAppear {
            host = model.settings.settings.wifiHost
            port = String(model.settings.settings.wifiPort)
        }
    }
}

// MARK: - Adapterstatus

private struct AdapterStatusSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if let session = model.connection.session {
                LabeledContent("Zustand", value: session.phase.description)
                if let version = session.adapterVersion { LabeledContent("Adapter", value: version) }
                if let proto = session.protocolName { LabeledContent("Protokoll", value: proto) }
                if let voltage = session.batteryVoltage { LabeledContent("Spannung am Adapter", value: voltage) }
                if let ecu = session.primaryECU {
                    LabeledContent("Motorsteuergerät", value: ecu + (session.ecuSupport.count > 1 ? " (von \(session.ecuSupport.count) antwortenden)" : ""))
                }
                if !session.headersEnabled {
                    Text("Adapter ohne Header-Unterstützung: Antworten mehrerer Steuergeräte können nicht sicher getrennt werden.")
                        .font(.caption)
                        .foregroundStyle(DemonTheme.warning)
                }
                LabeledContent("Datenrate", value: "\(session.statistics.requestRate.germanDecimal(1)) Werte/s")
                LabeledContent("Drehzahl-Updates", value: "\(session.statistics.rpmRate.germanDecimal(1)) /s")
                if let latency = session.statistics.lastLatency {
                    LabeledContent("Antwortzeit", value: "\(Int(latency * 1000)) ms")
                }
                let rpmAge = model.driver.liveStore.reading(.rpm, now: model.now).age
                LabeledContent("Alter letzter Drehzahlwert", value: rpmAge.map { "\($0.germanDecimal(2)) s" } ?? "—")
                if session.statistics.timeouts > 0 {
                    LabeledContent("Zeitüberschreitungen", value: "\(session.statistics.timeouts)")
                }
                if session.phase != .idle {
                    Button {
                        model.connection.reinitialize()
                    } label: {
                        Label("Adapter neu initialisieren", systemImage: "arrow.clockwise")
                    }
                }
            } else {
                Text(model.connection.statusTitle)
                    .foregroundStyle(DemonTheme.textSecondary)
            }
            if let problem = model.connection.lastProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DemonTheme.warning)
            }
        } header: {
            Text("Adapter & Fahrzeug")
        }

        if model.connection.session != nil {
            Section {
                ForEach(VehicleSignal.allCases) { signal in
                    let availability = model.driver.liveStore.availability[signal] ?? .unknown
                    HStack {
                        Label(signal.title, systemImage: signal.symbolName)
                        Spacer()
                        Text(availabilityText(availability))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(availability == .supported ? DemonTheme.green : DemonTheme.textSecondary)
                    }
                }
            } header: {
                Text("Vom Fahrzeug gemeldete Werte")
            } footer: {
                Text("Nur Werte, die das Fahrzeug als unterstützt meldet, werden abgefragt. Nicht unterstützte Werte werden als „Nicht verfügbar“ angezeigt – es werden keine Werte erfunden.")
            }
        }
    }

    private func availabilityText(_ availability: SignalAvailability) -> String {
        switch availability {
        case .supported: "Unterstützt"
        case .unsupported: "Nicht verfügbar"
        case .unknown: "Wird ermittelt"
        }
    }
}

// MARK: - GATT-Explorer

struct GATTExplorerView: View {
    @Environment(AppModel.self) private var model
    @State private var serviceUUID = ""
    @State private var writeUUID = ""
    @State private var notifyUUID = ""

    var body: some View {
        let ble = model.connection.ble
        Form {
            Section {
                Text("Nur nötig, wenn kein dokumentiertes Profil erkannt wurde. Wähle den Dienst sowie je eine Characteristic zum Schreiben und für Benachrichtigungen. Es werden nur Characteristics mit passenden Eigenschaften angeboten. Ob der Adapter ELM327-Befehle versteht, zeigt sich erst bei der Initialisierung.")
                    .font(.footnote)
                    .foregroundStyle(DemonTheme.textSecondary)
            }

            ForEach(ble.services) { service in
                Section("Dienst \(service.uuid)") {
                    ForEach(service.characteristics) { characteristic in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(characteristic.uuid)
                                .font(.subheadline.monospaced())
                            Text(characteristic.properties.labels.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(DemonTheme.textSecondary)
                            HStack {
                                if characteristic.properties.canWrite {
                                    selectButton("Write", selected: serviceUUID == service.uuid && writeUUID == characteristic.uuid) {
                                        if serviceUUID != service.uuid { notifyUUID = "" }
                                        serviceUUID = service.uuid
                                        writeUUID = characteristic.uuid
                                    }
                                }
                                if characteristic.properties.canNotify {
                                    selectButton("Notify", selected: serviceUUID == service.uuid && notifyUUID == characteristic.uuid) {
                                        if serviceUUID != service.uuid { writeUUID = "" }
                                        serviceUUID = service.uuid
                                        notifyUUID = characteristic.uuid
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                if let error = ble.selectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(DemonTheme.danger)
                }
                Button {
                    ble.applyCustomSelection(CustomGATTSelection(serviceUUID: serviceUUID, writeUUID: writeUUID, notifyUUID: notifyUUID))
                } label: {
                    Label("Auswahl verwenden", systemImage: "checkmark.circle.fill")
                }
                .disabled(serviceUUID.isEmpty || writeUUID.isEmpty || notifyUUID.isEmpty)
            } footer: {
                Text("Eine erfolgreiche Auswahl wird für dieses Gerät gespeichert.")
            }
        }
        .scrollContentBackground(.hidden)
        .demonBackground()
        .navigationTitle("GATT-Dienste")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let active = ble.activeSelection {
                serviceUUID = active.serviceUUID
                writeUUID = active.writeUUID
                notifyUUID = active.notifyUUID
            }
        }
    }

    private func selectButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(selected ? DemonTheme.green : DemonTheme.blurple)
    }
}

// MARK: - Diagnoseprotokoll

struct DiagnosticLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let log = model.connection.log
        List {
            Section {
                Toggle("Regelmäßige Abfragen mitprotokollieren", isOn: Binding(get: { log.logPolling }, set: { log.logPolling = $0 }))
                ShareLink(item: DiagnosticExport(text: exportText(log)), preview: SharePreview("Diagnoseprotokoll")) {
                    Label("Protokoll exportieren", systemImage: "square.and.arrow.up")
                }
                Button("Protokoll leeren", role: .destructive) { log.clear() }
            } footer: {
                Text("Begrenzt auf die letzten \(log.capacity) Einträge. Enthält nur Adapterbefehle und -antworten, keine persönlichen Daten.")
            }
            Section("Einträge") {
                if log.entries.isEmpty {
                    Text("Noch keine Einträge").foregroundStyle(DemonTheme.textSecondary)
                }
                ForEach(log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption2)
                            .foregroundStyle(DemonTheme.textSecondary)
                        Text("\(entry.kind.rawValue) \(entry.text)")
                            .font(.caption.monospaced())
                            .foregroundStyle(color(entry.kind))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .demonBackground()
        .navigationTitle("Diagnoseprotokoll")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func exportText(_ log: DiagnosticLog) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var header = "Demonic Motorsound OBD2 \(version) – Diagnoseprotokoll\n"
        if let session = model.connection.session {
            header += "Adapter: \(session.adapterVersion ?? "?"), Protokoll: \(session.protocolName ?? "?"), Steuergerät: \(session.primaryECU ?? "?")\n"
            header += "Datenrate: \(session.statistics.requestRate.germanDecimal(1)) Werte/s"
        }
        return log.exportText(header: header)
    }

    private func color(_ kind: DiagnosticLog.Kind) -> Color {
        switch kind {
        case .sent: DemonTheme.blurple
        case .received: DemonTheme.green
        case .info: .white
        case .warning: DemonTheme.warning
        case .error: DemonTheme.danger
        }
    }
}

// MARK: - Kompatibilität

struct CompatibilityView: View {
    var body: some View {
        List {
            Section {
                ForEach(BLEAdapterProfile.known) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name).font(.subheadline.weight(.semibold))
                        Text("Service \(profile.serviceUUID) · Write \(profile.writeUUID) · Notify \(profile.notifyUUID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(DemonTheme.textSecondary)
                        Text("Quelle: \(profile.source)")
                            .font(.caption2)
                            .foregroundStyle(DemonTheme.textSecondary)
                    }
                }
            } header: {
                Text("Implementierte BLE-Profile")
            } footer: {
                Text("Auch bei passendem Profil prüft die App die Eigenschaften der Characteristics. Andere BLE-Adapter können über die manuelle GATT-Auswahl versucht werden. Es gibt keine Garantie, dass jeder BLE-Adapter funktioniert.")
            }

            Section("WLAN") {
                Text("TCP-Verbindung zu ELM327-kompatiblen WLAN-Adaptern mit frei einstellbarer IP-Adresse und Port.")
            }

            Section("Nicht unterstützt") {
                Label("Klassisches Bluetooth (SPP/RFCOMM): iOS erlaubt Apps keinen Zugriff auf SPP-Geräte. Solche Adapter funktionieren nur unter Android/Windows.", systemImage: "xmark.circle")
                Label("MFi-Adapter (External Accessory): nicht implementiert. Dafür wären eine Freigabe des Adapterherstellers und dessen Protokolldokumentation nötig.", systemImage: "xmark.circle")
                Label("Herstellerspezifische Protokolle (z. B. erweiterte STN/OBDLink-Befehle) werden nicht genutzt – nur ELM327-Standardbefehle.", systemImage: "info.circle")
            }

            Section("Gesendete Befehle") {
                Text("Nur Initialisierung (ATZ, ATE0, ATL0, ATS1, ATH1, ATAT1, ATSP0, ATI, ATRV, ATDPN) und lesende Mode-01-Abfragen. Keine Codierungen, Stellgliedtests, Fehlerspeicher-Löschung oder freie CAN-Nachrichten – technisch durch eine Befehlsfreigabeliste erzwungen.")
            }
        }
        .scrollContentBackground(.hidden)
        .demonBackground()
        .navigationTitle("Kompatibilität")
        .navigationBarTitleDisplayMode(.inline)
    }
}
