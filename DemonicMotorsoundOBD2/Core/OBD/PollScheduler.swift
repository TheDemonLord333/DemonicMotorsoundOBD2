import Foundation

/// Plant die Reihenfolge der Mode-01-Abfragen.
///
/// - Die Drehzahl hat höchste Priorität und erhält den Großteil der Abfrageslots.
/// - Last/Pedal/Drosselklappe werden mittelschnell, Geschwindigkeit langsamer und die
///   Kühlmitteltemperatur selten abgefragt.
/// - Bei langsamer Verbindung werden die Intervalle der Nebenwerte gestreckt und die Drehzahl
///   bekommt mehr Slots.
nonisolated struct PollScheduler {
    struct Entry: Equatable {
        var pid: OBDPID
        var baseInterval: TimeInterval
        var nextDue: TimeInterval
    }

    private(set) var rpmSupported: Bool
    private(set) var secondary: [Entry]
    private var rpmSinceSecondary = 0

    static func baseInterval(for pid: OBDPID) -> TimeInterval {
        switch pid {
        case .engineRPM: 0
        case .engineLoad, .acceleratorPedalD, .relativeAcceleratorPedal, .throttlePosition: 0.25
        case .vehicleSpeed: 0.5
        case .coolantTemperature: 5
        }
    }

    init(pids: Set<OBDPID>, now: TimeInterval = 0) {
        rpmSupported = pids.contains(.engineRPM)
        // Für das Pedal genügt ein PID: bevorzugt Pedalstellung D, sonst die relative Pedalstellung.
        var chosen = pids.subtracting([.engineRPM])
        if chosen.contains(.acceleratorPedalD) { chosen.remove(.relativeAcceleratorPedal) }
        secondary = chosen
            .sorted { $0.rawValue < $1.rawValue }
            .map { Entry(pid: $0, baseInterval: Self.baseInterval(for: $0), nextDue: now) }
    }

    var allPIDs: [OBDPID] {
        (rpmSupported ? [.engineRPM] : []) + secondary.map(\.pid)
    }

    /// Wie viele Drehzahlabfragen zwischen zwei Nebenwerten erfolgen.
    static func rpmShare(forRate rate: Double) -> Int {
        switch rate {
        case ..<4: 3
        case ..<8: 2
        default: 1
        }
    }

    static func stretchFactor(forRate rate: Double) -> Double {
        switch rate {
        case ..<4: 3
        case ..<8: 1.8
        default: 1
        }
    }

    /// Nächster abzufragender PID. `measuredRate` = erreichte Antworten pro Sekunde.
    mutating func next(now: TimeInterval, measuredRate: Double) -> OBDPID? {
        let overdue = secondary.indices
            .filter { secondary[$0].nextDue <= now }
            .min { secondary[$0].nextDue < secondary[$1].nextDue }

        if rpmSupported {
            let share = Self.rpmShare(forRate: measuredRate)
            if overdue == nil || rpmSinceSecondary < share {
                rpmSinceSecondary += 1
                return .engineRPM
            }
        }
        guard let index = overdue ?? (rpmSupported ? nil : soonestIndex()) else {
            return rpmSupported ? .engineRPM : nil
        }
        rpmSinceSecondary = 0
        let stretch = Self.stretchFactor(forRate: measuredRate)
        secondary[index].nextDue = now + secondary[index].baseInterval * stretch
        return secondary[index].pid
    }

    private func soonestIndex() -> Int? {
        secondary.indices.min { secondary[$0].nextDue < secondary[$1].nextDue }
    }

    /// Entfernt einen PID, der wiederholt keine Daten liefert.
    mutating func remove(_ pid: OBDPID) {
        if pid == .engineRPM {
            rpmSupported = false
        } else {
            secondary.removeAll { $0.pid == pid }
        }
    }

    var isEmpty: Bool { !rpmSupported && secondary.isEmpty }
}
