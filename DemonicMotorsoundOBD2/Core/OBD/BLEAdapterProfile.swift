import Foundation

/// Dokumentierte GATT-Profile ELM327-kompatibler BLE-Adapter.
///
/// Es werden nur Profile aufgeführt, für die eine öffentliche Quelle existiert. Auch bei einem
/// passenden Profil prüft die App zur Laufzeit, ob die Characteristics die nötigen Eigenschaften
/// (Schreiben bzw. Benachrichtigen) tatsächlich besitzen. Ein Profil-Treffer garantiert nicht,
/// dass der Adapter ELM327-Befehle versteht.
nonisolated struct BLEAdapterProfile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let serviceUUID: String
    let writeUUID: String
    let notifyUUID: String
    let source: String

    static let known: [BLEAdapterProfile] = [
        BLEAdapterProfile(
            id: "fff0",
            name: "UART-Service FFF0 (Notify FFF1 · Write FFF2)",
            serviceUUID: "FFF0", writeUUID: "FFF2", notifyUUID: "FFF1",
            source: "Adapterhinweise zum OBDLink CX (OBDLink-Support); ebenso bei vielen ELM327-kompatiblen BLE-Adaptern anzutreffen"
        ),
        BLEAdapterProfile(
            id: "ffe0",
            name: "HM-10/CC254x-UART FFE0 (FFE1 Write + Notify)",
            serviceUUID: "FFE0", writeUUID: "FFE1", notifyUUID: "FFE1",
            source: "Datenblatt des BLE-Moduls HM-10 (Jinan Huamao), in günstigen ELM327-BLE-Adaptern verbreitet"
        ),
        BLEAdapterProfile(
            id: "18f0",
            name: "Service 18F0 (Notify 2AF0 · Write 2AF1)",
            serviceUUID: "18F0", writeUUID: "2AF1", notifyUUID: "2AF0",
            source: "Community-Dokumentation zum Vgate iCar Pro BLE 4.0 (nicht vom Hersteller bestätigt)"
        ),
    ]
}

/// Eigenschaften einer Characteristic (plattformunabhängige Abbildung).
nonisolated struct GATTCharacteristicProperties: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let read = GATTCharacteristicProperties(rawValue: 1 << 0)
    static let write = GATTCharacteristicProperties(rawValue: 1 << 1)
    static let writeWithoutResponse = GATTCharacteristicProperties(rawValue: 1 << 2)
    static let notify = GATTCharacteristicProperties(rawValue: 1 << 3)
    static let indicate = GATTCharacteristicProperties(rawValue: 1 << 4)

    var canWrite: Bool { contains(.write) || contains(.writeWithoutResponse) }
    var canNotify: Bool { contains(.notify) || contains(.indicate) }

    var labels: [String] {
        var result: [String] = []
        if contains(.read) { result.append("Lesen") }
        if contains(.write) { result.append("Schreiben") }
        if contains(.writeWithoutResponse) { result.append("Schreiben o. Antwort") }
        if contains(.notify) { result.append("Notify") }
        if contains(.indicate) { result.append("Indicate") }
        return result
    }
}

nonisolated struct GATTCharacteristicInfo: Identifiable, Hashable, Sendable {
    var id: String { uuid }
    let uuid: String
    let properties: GATTCharacteristicProperties
}

nonisolated struct GATTServiceInfo: Identifiable, Hashable, Sendable {
    var id: String { uuid }
    let uuid: String
    let characteristics: [GATTCharacteristicInfo]
}

nonisolated enum GATTProfileMatcher {
    /// Vergleicht UUIDs unabhängig von Groß-/Kleinschreibung und 16-/128-Bit-Schreibweise.
    static func same(_ a: String, _ b: String) -> Bool {
        expand(a) == expand(b)
    }

    static func expand(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        if upper.count == 4 { return "0000\(upper)-0000-1000-8000-00805F9B34FB" }
        if upper.count == 8 { return "\(upper)-0000-1000-8000-00805F9B34FB" }
        return upper
    }

    /// Liefert das erste bekannte Profil, dessen Characteristics vorhanden sind und passende
    /// Eigenschaften besitzen.
    static func match(services: [GATTServiceInfo], profiles: [BLEAdapterProfile] = BLEAdapterProfile.known) -> BLEAdapterProfile? {
        for profile in profiles {
            guard let service = services.first(where: { same($0.uuid, profile.serviceUUID) }) else { continue }
            let write = service.characteristics.first { same($0.uuid, profile.writeUUID) }
            let notify = service.characteristics.first { same($0.uuid, profile.notifyUUID) }
            if let write, let notify, write.properties.canWrite, notify.properties.canNotify {
                return profile
            }
        }
        return nil
    }

    /// Prüft eine manuelle Auswahl gegen die tatsächlich entdeckten Eigenschaften.
    static func validate(_ selection: CustomGATTSelection, services: [GATTServiceInfo]) -> Bool {
        guard let service = services.first(where: { same($0.uuid, selection.serviceUUID) }) else { return false }
        let write = service.characteristics.first { same($0.uuid, selection.writeUUID) }
        let notify = service.characteristics.first { same($0.uuid, selection.notifyUUID) }
        return write?.properties.canWrite == true && notify?.properties.canNotify == true
    }
}
