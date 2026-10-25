import Foundation

/// Simulierte Fahrzeugwerte für den Demomodus. Erzeugt ausschließlich Daten mit Herkunft `.demo`
/// und löst keinerlei Fahrzeugabfragen oder Steuerbefehle aus.
nonisolated struct DemoSimulator: Equatable {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case manual
        case autoDrive

        var id: String { rawValue }
        var title: String {
            switch self {
            case .manual: "Manuell"
            case .autoDrive: "Demofahrt"
            }
        }
    }

    enum Phase: Equatable, Sendable {
        case off
        case cranking
        case idle
        case accelerating
        case shifting
        case cruising
        case coasting
        case stopping

        var title: String {
            switch self {
            case .off: "Motor aus"
            case .cranking: "Motorstart"
            case .idle: "Leerlauf"
            case .accelerating: "Beschleunigen"
            case .shifting: "Gangwechsel (simuliert)"
            case .cruising: "Konstantfahrt"
            case .coasting: "Ausrollen"
            case .stopping: "Motor wird abgestellt"
            }
        }
    }

    struct Output: Equatable, Sendable {
        var rpm: Double
        var load: Double
        var throttle: Double
        var pedal: Double
        var speed: Double?
        var coolant: Double
        var gear: Int?
        var shiftEvent: Bool
        var blowOffEvent: Bool
    }

    static let idleRPM: Double = 850
    static let gearRatios: [Double] = [3.4, 2.05, 1.45, 1.1, 0.88]
    static let finalDrive: Double = 4.1
    static let wheelCircumference: Double = 1.9

    var mode: Mode = .manual
    /// Manuelle Vorgaben (nur im Modus „Manuell“).
    var manualRPM: Double = 850
    var manualLoad: Double = 0.2

    private(set) var engineRunning = false
    private(set) var phase: Phase = .off
    private(set) var rpm: Double = 0
    private(set) var load: Double = 0
    private(set) var speed: Double = 0
    private(set) var coolant: Double = 22
    private(set) var gear = 1
    private var phaseTime: TimeInterval = 0
    private var shiftTargetRPM: Double = 0
    private var autoCycle = 0

    mutating func startEngine() {
        guard !engineRunning else { return }
        engineRunning = true
        enter(.cranking)
    }

    mutating func stopEngine() {
        guard engineRunning || phase != .off else { return }
        engineRunning = false
        enter(.stopping)
    }

    mutating func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        if engineRunning && phase != .cranking {
            enter(.idle)
        }
        if newMode == .manual {
            speed = 0
            gear = 1
        }
    }

    mutating func reset() {
        let keepMode = mode
        self = DemoSimulator()
        mode = keepMode
    }

    private mutating func enter(_ newPhase: Phase) {
        phase = newPhase
        phaseTime = 0
    }

    private static func speedFor(rpm: Double, gear: Int) -> Double {
        let ratio = gearRatios[(gear - 1).clamped(0, gearRatios.count - 1)] * finalDrive
        return rpm / ratio * wheelCircumference * 60 / 1000
    }

    private static func rpmFor(speed: Double, gear: Int) -> Double {
        let ratio = gearRatios[(gear - 1).clamped(0, gearRatios.count - 1)] * finalDrive
        return speed * 1000 / 60 / wheelCircumference * ratio
    }

    private static func approach(_ value: Double, _ target: Double, tau: Double, dt: Double) -> Double {
        value + (target - value) * (1 - exp(-dt / max(tau, 0.001)))
    }

    mutating func step(dt rawDT: TimeInterval) -> Output {
        let dt = rawDT.clamped(0, 0.2)
        phaseTime += dt
        var shiftEvent = false
        var blowOffEvent = false
        var throttle: Double = 0
        var pedal: Double = 0

        // Kühlmittel erwärmt sich langsam bei laufendem Motor (simuliert).
        if engineRunning {
            coolant = Self.approach(coolant, 88, tau: 180, dt: dt)
        } else {
            coolant = Self.approach(coolant, 22, tau: 900, dt: dt)
        }

        switch phase {
        case .off:
            rpm = 0
            load = 0
        case .stopping:
            rpm = max(0, Self.approach(rpm, -50, tau: 0.25, dt: dt))
            load = 0
            speed = max(0, speed - 25 * dt)
            if rpm <= 0 {
                rpm = 0
                enter(.off)
            }
        case .cranking:
            load = 0.15
            if phaseTime < 0.5 {
                rpm = Self.approach(rpm, 260, tau: 0.08, dt: dt)
            } else if phaseTime < 1.0 {
                rpm = Self.approach(rpm, 1350, tau: 0.12, dt: dt)
            } else {
                rpm = Self.approach(rpm, Self.idleRPM, tau: 0.5, dt: dt)
                if phaseTime > 2.2 { enter(.idle) }
            }
        default:
            if mode == .manual {
                let target = max(manualRPM, Self.idleRPM)
                // Reaktion abhängig von der Last: mit Gas steigt die Drehzahl schneller.
                let tau = target > rpm ? 0.35 - 0.25 * manualLoad : 0.45
                rpm = Self.approach(rpm, target, tau: tau, dt: dt)
                load = Self.approach(load, manualLoad, tau: 0.08, dt: dt)
                pedal = manualLoad * 100
                throttle = 12 + manualLoad * 70
                speed = 0
            } else {
                autoDriveStep(dt: dt, shiftEvent: &shiftEvent, blowOffEvent: &blowOffEvent)
                pedal = load > 0.05 ? load * 100 : 0
                throttle = phase == .shifting || phase == .coasting ? 4 : 12 + load * 70
            }
        }

        let throttleOut = phase == .off ? 0 : (mode == .manual || phase == .cranking || phase == .idle ? max(throttle, 12) : throttle)
        return Output(
            rpm: rpm,
            load: load,
            throttle: throttleOut,
            pedal: pedal,
            speed: mode == .autoDrive ? speed : nil,
            coolant: coolant,
            gear: mode == .autoDrive && phase != .off && phase != .idle ? gear : nil,
            shiftEvent: shiftEvent,
            blowOffEvent: blowOffEvent
        )
    }

    private mutating func autoDriveStep(dt: TimeInterval, shiftEvent: inout Bool, blowOffEvent: inout Bool) {
        switch phase {
        case .idle:
            rpm = Self.approach(rpm, Self.idleRPM, tau: 0.3, dt: dt)
            load = Self.approach(load, 0.18, tau: 0.2, dt: dt)
            speed = 0
            gear = 1
            if phaseTime > 3 {
                autoCycle += 1
                enter(.accelerating)
            }
        case .accelerating:
            let maxGear = 4
            let shiftPoint: Double = autoCycle % 2 == 0 ? 6200 : 4800
            load = Self.approach(load, autoCycle % 2 == 0 ? 0.95 : 0.7, tau: 0.12, dt: dt)
            if gear == 1 && speed < 8 {
                // Anfahren mit schleifender Kupplung
                rpm = Self.approach(rpm, 2400, tau: 0.4, dt: dt)
                speed += 6 * dt
            } else {
                let acceleration = [9.0, 6.0, 4.0, 2.8, 2.0][gear - 1] * load // km/h pro Sekunde
                speed += acceleration * dt
                rpm = Self.rpmFor(speed: speed, gear: gear)
            }
            if rpm >= shiftPoint {
                if gear < maxGear {
                    shiftTargetRPM = Self.rpmFor(speed: speed, gear: gear + 1)
                    shiftEvent = true
                    blowOffEvent = load > 0.6
                    enter(.shifting)
                } else {
                    enter(.cruising)
                }
            }
        case .shifting:
            load = Self.approach(load, 0, tau: 0.04, dt: dt)
            rpm = Self.approach(rpm, shiftTargetRPM, tau: 0.09, dt: dt)
            speed = max(0, speed - 1.5 * dt)
            if phaseTime > 0.35 {
                gear += 1
                enter(.accelerating)
            }
        case .cruising:
            load = Self.approach(load, 0.32, tau: 0.3, dt: dt)
            rpm = Self.rpmFor(speed: speed, gear: gear)
            if phaseTime > 4 { enter(.coasting) }
        case .coasting:
            load = Self.approach(load, 0, tau: 0.1, dt: dt)
            speed = max(0, speed - (speed > 30 ? 7 : 10) * dt)
            if gear > 1 && Self.rpmFor(speed: speed, gear: gear) < 1300 {
                gear -= 1
            }
            let coupled = Self.rpmFor(speed: speed, gear: gear)
            rpm = speed < 12 ? Self.approach(rpm, Self.idleRPM, tau: 0.3, dt: dt) : Self.approach(rpm, max(coupled, Self.idleRPM), tau: 0.15, dt: dt)
            if speed <= 0.1 {
                speed = 0
                enter(.idle)
            }
        default:
            break
        }
    }
}
