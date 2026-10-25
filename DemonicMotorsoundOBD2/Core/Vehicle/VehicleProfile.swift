import Foundation

/// Editierbares Fahrzeugprofil. Alle Vorgaben sind Annahmen und ausdrücklich nicht verifiziert.
nonisolated struct VehicleProfile: Codable, Equatable, Sendable {
    var name: String
    /// Motorisierung – bewusst leer, solange sie nicht bekannt ist.
    var engineDescription: String
    /// Zylinderzahl des realen Motors, falls bekannt (nur Information, beeinflusst keine Messwerte).
    var cylinders: Int?
    /// Angenommene Leerlaufdrehzahl des realen Motors (für die optionale Drehzahlskalierung).
    var idleRPMReference: Double
    /// Angenommene Höchstdrehzahl des realen Motors (Tacho-Skala, Skalierung).
    var maxRPMReference: Double
    var notes: String
    /// Wird erst gesetzt, wenn der Nutzer die Angaben selbst geprüft hat.
    var userVerified: Bool

    static let hondaJazz2015 = VehicleProfile(
        name: "Honda Jazz (2015)",
        engineDescription: "",
        cylinders: nil,
        idleRPMReference: 800,
        maxRPMReference: 6500,
        notes: "Vorlage. Motorisierung, unterstützte PIDs und Drehzahlgrenzen sind nicht verifiziert. Bitte anhand der Fahrzeugpapiere bzw. des Drehzahlmessers im Fahrzeug anpassen.",
        userVerified: false
    )

    func sanitized() -> VehicleProfile {
        var copy = self
        copy.idleRPMReference = idleRPMReference.clamped(300, 2000)
        copy.maxRPMReference = maxRPMReference.clamped(copy.idleRPMReference + 1000, 12000)
        if let c = cylinders { copy.cylinders = c.clamped(1, 16) }
        return copy
    }

    /// Obere Grenze der Tachoskala (gerundet auf 1000er).
    var gaugeMaximum: Double {
        max(6000, (maxRPMReference / 1000).rounded(.up) * 1000 + 1000)
    }
}
