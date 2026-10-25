import Foundation
import Observation

/// Kommunikationssitzung mit einem ELM327-kompatiblen Adapter.
///
/// - Serielle Befehlswarteschlange: Es ist immer höchstens ein Befehl unterwegs; die nächste
///   Anfrage wird erst nach dem Prompt `>` (oder einer Zeitüberschreitung) gesendet.
/// - Nach einer Zeitüberschreitung folgt eine kurze Ruhephase, in der verspätete Antworten
///   verworfen werden, damit sie keiner späteren Anfrage zugeordnet werden.
/// - Es werden ausschließlich Befehle gesendet, die `ELM327CommandPolicy` erlaubt.
@Observable
final class ELM327Session {
    struct Configuration: Sendable {
        var resetTimeout: TimeInterval = 4
        var commandTimeout: TimeInterval = 2
        /// Die erste Fahrzeuganfrage kann wegen der automatischen Protokollsuche lange dauern.
        var searchTimeout: TimeInterval = 15
        var pollTimeout: TimeInterval = 1.2
        var resyncDelay: TimeInterval = 0.35
        var postResetDelay: TimeInterval = 0.3
        /// Untergrenze zwischen zwei Abfragen, um Adapter und Fahrzeugbus nicht zu überlasten.
        var minimumPollInterval: TimeInterval = 0.04
        var maxConsecutiveFailures = 4
        var noDataLimit = 5

        static let standard = Configuration()
    }

    enum Phase: Equatable, Sendable {
        case idle
        case initializing(String)
        case discovering
        case polling
        case paused
        case failed(String)

        var description: String {
            switch self {
            case .idle: "Bereit"
            case .initializing(let step): "Initialisierung: \(step)"
            case .discovering: "Erkenne unterstützte Werte …"
            case .polling: "Liest Fahrzeugdaten"
            case .paused: "Abfrage pausiert"
            case .failed(let message): message
            }
        }
    }

    struct Statistics: Equatable, Sendable {
        var requestRate: Double = 0
        var rpmRate: Double = 0
        var lastLatency: TimeInterval?
        var timeouts = 0
        var errors = 0
    }

    let transport: OBDTransport
    let log: DiagnosticLog
    let configuration: Configuration
    private let clock: TimeSource

    private(set) var phase: Phase = .idle
    private(set) var adapterVersion: String?
    private(set) var batteryVoltage: String?
    private(set) var protocolName: String?
    private(set) var family: OBDProtocolFamily = .unknown
    private(set) var headersEnabled = true
    /// Unterstützte PIDs je Steuergerät (Schlüssel `?`, wenn ohne Header empfangen).
    private(set) var ecuSupport: [String: Set<UInt8>] = [:]
    private(set) var primaryECU: String?
    private(set) var supportedPIDs: Set<OBDPID> = []
    private(set) var statistics = Statistics()
    private(set) var usesResponseCountSuffix = false

    var onSample: ((SignalSample) -> Void)?
    var onAvailabilityChange: (([VehicleSignal: SignalAvailability]) -> Void)?
    /// Wird aufgerufen, wenn der Adapter wiederholt nicht antwortet.
    var onConnectionProblem: ((String) -> Void)?

    private struct Pending {
        let id: Int
        let command: String
        let timeout: TimeInterval
        let logTraffic: Bool
        let continuation: CheckedContinuation<ELM327Reply, Error>
        var sentAt: TimeInterval = 0
    }

    private var queue: [Pending] = []
    private var current: Pending?
    private var nextRequestID = 0
    private var accumulator = ELM327ResponseAccumulator()
    private var quietUntil: TimeInterval = 0
    private var pumpScheduled = false
    private var timeoutTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var scheduler: PollScheduler?
    private var pollingPaused = false
    private var consecutiveFailures = 0
    private var noDataCounts: [OBDPID: Int] = [:]
    private var requestMeter = RateMeter()
    private var rpmMeter = RateMeter()
    private var lastErrorLog: TimeInterval = -100

    init(transport: OBDTransport, log: DiagnosticLog, clock: TimeSource = ContinuousTimeSource.shared, configuration: Configuration = .standard) {
        self.transport = transport
        self.log = log
        self.clock = clock
        self.configuration = configuration
        transport.onReceive = { [weak self] data in
            self?.receive(data)
        }
    }

    // MARK: - Lebenszyklus

    /// Initialisiert den Adapter, erkennt unterstützte PIDs und startet die Abfrage.
    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        failAllPending(with: .cancelled)
        if phase != .idle, !isFailed { phase = .idle }
    }

    func pausePolling() {
        pollingPaused = true
    }

    func resumePolling() {
        pollingPaused = false
    }

    var isPollingPaused: Bool { pollingPaused }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func run() async {
        do {
            try await initializeAdapter()
            try await discoverVehicle()
            await pollLoop()
        } catch is CancellationError {
            return
        } catch let error as ELM327Error {
            if error == .cancelled || Task.isCancelled { return }
            fail("Initialisierung fehlgeschlagen: \(error.germanDescription)")
        } catch {
            fail("Initialisierung fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        log.add(.error, message)
    }

    // MARK: - Befehlswarteschlange

    /// Sendet einen erlaubten Befehl und wartet auf die vollständige Antwort.
    func execute(_ command: String, timeout: TimeInterval? = nil, logTraffic: Bool = true) async throws -> ELM327Reply {
        guard ELM327CommandPolicy.isAllowed(command) else {
            log.add(.error, "Blockiert: \(command)")
            throw ELM327Error.notAllowed(command)
        }
        guard transport.isReady else { throw ELM327Error.transportUnavailable }
        try Task.checkCancellation()
        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            queue.append(Pending(id: id, command: command, timeout: timeout ?? configuration.commandTimeout,
                                 logTraffic: logTraffic, continuation: continuation))
            pump()
        }
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let now = clock.now()
        if now < quietUntil {
            guard !pumpScheduled else { return }
            pumpScheduled = true
            let delay = quietUntil - now
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.pumpScheduled = false
                self.pump()
            }
            return
        }
        guard transport.isReady else {
            failAllPending(with: .transportUnavailable)
            return
        }
        var request = queue.removeFirst()
        request.sentAt = now
        current = request
        accumulator.reset()
        if request.logTraffic { log.add(.sent, request.command) }
        transport.send(Data((request.command + "\r").utf8))

        let id = request.id
        let timeout = request.timeout
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.handleTimeout(id: id)
        }
    }

    private func receive(_ data: Data) {
        let responses = accumulator.append(data)
        for raw in responses {
            guard let request = current else {
                if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    log.add(.warning, "Verspätete Antwort verworfen: \(raw)")
                }
                continue
            }
            current = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            let reply = ELM327Reply.parse(raw: raw, command: request.command)
            statistics.lastLatency = clock.now() - request.sentAt
            if request.logTraffic || reply.failure != nil && reply.failure != .noData {
                if !request.logTraffic { log.add(.sent, request.command) }
                log.add(.received, raw.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            request.continuation.resume(returning: reply)
        }
        pump()
    }

    private func handleTimeout(id: Int) {
        guard let request = current, request.id == id else { return }
        current = nil
        timeoutTask = nil
        statistics.timeouts += 1
        quietUntil = clock.now() + configuration.resyncDelay
        accumulator.reset()
        log.add(.warning, "Zeitüberschreitung bei \(request.command)")
        request.continuation.resume(throwing: ELM327Error.timeout)
        pump()
    }

    private func failAllPending(with error: ELM327Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let request = current {
            current = nil
            request.continuation.resume(throwing: error)
        }
        let pending = queue
        queue.removeAll()
        for request in pending {
            request.continuation.resume(throwing: error)
        }
    }

    // MARK: - Initialisierung

    private func initializeAdapter() async throws {
        phase = .initializing("Adapter-Reset")
        log.add(.info, "Starte Initialisierung über \(transport.transportDescription)")
        do {
            let reply = try await execute("ATZ", timeout: configuration.resetTimeout)
            adapterVersion = reply.lines.last { $0.uppercased().contains("ELM") || $0.uppercased().contains("STN") } ?? reply.lines.last
        } catch ELM327Error.timeout {
            log.add(.warning, "Keine Antwort auf ATZ – fahre mit Konfiguration fort")
        }
        try await Task.sleep(for: .seconds(configuration.postResetDelay))

        let steps: [(String, String)] = [
            ("ATE0", "Echo aus"),
            ("ATL0", "Zeilenvorschub aus"),
            ("ATS1", "Leerzeichen an"),
            ("ATH1", "Header an"),
            ("ATAT1", "Adaptives Timing"),
            ("ATSP0", "Automatische Protokollwahl"),
        ]
        for (command, title) in steps {
            phase = .initializing(title)
            let reply: ELM327Reply
            do {
                reply = try await execute(command)
            } catch ELM327Error.timeout {
                if command == "ATE0" { throw ELM327Error.timeout }
                log.add(.warning, "\(command): keine Antwort")
                continue
            }
            let accepted = reply.lines.contains { $0.uppercased().contains("OK") }
            if !accepted {
                log.add(.warning, "\(command) nicht bestätigt: \(reply.raw.trimmingCharacters(in: .whitespacesAndNewlines))")
                if command == "ATH1" {
                    headersEnabled = false
                    log.add(.warning, "Adapter unterstützt keine Header – Antworten mehrerer Steuergeräte können nicht getrennt werden")
                }
            }
        }

        if adapterVersion == nil, let reply = try? await execute("ATI") {
            adapterVersion = reply.lines.last
        }
        if let reply = try? await execute("ATRV"), let line = reply.lines.last {
            batteryVoltage = line
        }
    }

    private func discoverVehicle() async throws {
        phase = .discovering
        let first = try await execute("0100", timeout: configuration.searchTimeout)
        if let failure = first.failure {
            throw failure
        }

        if let dp = try? await execute("ATDPN") , let line = dp.lines.last {
            let result = OBDProtocolFamily.fromDescribeProtocolNumber(line)
            family = result.family
            protocolName = OBDProtocolFamily.protocolName(result.number)
            log.add(.info, "Protokoll: \(protocolName ?? "unbekannt")")
        }

        var support: [String: Set<UInt8>] = [:]
        merge(reply: first, base: 0x00, into: &support)
        for base: UInt8 in [0x20, 0x40] {
            let needed = support.values.contains { $0.contains(base) }
            guard needed else { break }
            let command = "01" + Hex.byte(base)
            if let reply = try? await execute(command), reply.failure == nil {
                merge(reply: reply, base: base, into: &support)
            }
        }
        ecuSupport = support
        primaryECU = Self.choosePrimaryECU(support)

        let primarySet = primaryECU.flatMap { support[$0] } ?? support.values.reduce(into: Set<UInt8>()) { $0.formUnion($1) }
        supportedPIDs = Set(OBDPID.allCases.filter { primarySet.contains($0.rawValue) })
        log.add(.info, "Steuergeräte: \(support.keys.sorted().joined(separator: ", ")) – primär: \(primaryECU ?? "unbekannt")")
        log.add(.info, "Unterstützte Werte: \(supportedPIDs.map(\.title).sorted().joined(separator: ", "))")

        // Antwortanzahl-Suffix („010C1“) beschleunigt CAN-Abfragen, ist aber nur sicher,
        // wenn genau ein Steuergerät antwortet.
        usesResponseCountSuffix = support.count == 1 && (family == .can11 || family == .can29)

        publishAvailability()
        scheduler = PollScheduler(pids: supportedPIDs, now: clock.now())
        if !supportedPIDs.contains(.engineRPM) {
            log.add(.error, "Das Fahrzeug meldet keine Drehzahl (PID 0C) – der Motorsound kann nicht mit Echtdaten arbeiten.")
        }
    }

    private func merge(reply: ELM327Reply, base: UInt8, into support: inout [String: Set<UInt8>]) {
        let messages = OBDFrameDecoder.decode(lines: reply.lines, headersEnabled: headersEnabled, family: family)
        for message in messages {
            guard let data = Mode01Extractor.payload(for: base, in: message) else { continue }
            let key = message.ecu ?? "?"
            support[key, default: []].formUnion(SupportedPIDDecoder.decode(base: base, data: data))
        }
    }

    /// Wählt das Motorsteuergerät: bevorzugt eines, das die Drehzahl liefert, und die üblichen
    /// Motorsteuergeräte-Adressen (7E8 bzw. 18DAF110).
    static func choosePrimaryECU(_ support: [String: Set<UInt8>]) -> String? {
        let withRPM = support.filter { $0.value.contains(OBDPID.engineRPM.rawValue) }
        let pool = withRPM.isEmpty ? support : withRPM
        for preferred in ["7E8", "18DAF110", "10"] where pool[preferred] != nil {
            return preferred
        }
        return pool.max { lhs, rhs in
            lhs.value.count == rhs.value.count ? lhs.key > rhs.key : lhs.value.count < rhs.value.count
        }?.key
    }

    private func publishAvailability() {
        var availability: [VehicleSignal: SignalAvailability] = [:]
        for signal in VehicleSignal.allCases {
            let supported = supportedPIDs.contains { $0.signal == signal }
            availability[signal] = supported ? .supported : .unsupported
        }
        onAvailabilityChange?(availability)
    }

    // MARK: - Abfrage

    private func pollLoop() async {
        consecutiveFailures = 0
        while !Task.isCancelled {
            if pollingPaused {
                if phase != .paused { phase = .paused }
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            if phase != .polling { phase = .polling }
            let started = clock.now()
            guard let pid = scheduler?.next(now: started, measuredRate: statistics.requestRate) else {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            let command = pid.request + (usesResponseCountSuffix ? "1" : "")
            do {
                let reply = try await execute(command, timeout: configuration.pollTimeout, logTraffic: log.logPolling)
                handle(reply: reply, for: pid)
                consecutiveFailures = 0
            } catch ELM327Error.timeout {
                consecutiveFailures += 1
            } catch {
                if Task.isCancelled { return }
                consecutiveFailures += 1
            }
            updateStatistics()

            if consecutiveFailures >= configuration.maxConsecutiveFailures {
                let message = "Adapter antwortet nicht mehr (\(consecutiveFailures) Fehlversuche)"
                fail(message)
                onConnectionProblem?(message)
                return
            }
            let elapsed = clock.now() - started
            if elapsed < configuration.minimumPollInterval {
                try? await Task.sleep(for: .seconds(configuration.minimumPollInterval - elapsed))
            }
        }
    }

    private func handle(reply: ELM327Reply, for pid: OBDPID) {
        let now = clock.now()
        if let failure = reply.failure {
            switch failure {
            case .unknownCommand where usesResponseCountSuffix:
                usesResponseCountSuffix = false
                log.add(.info, "Adapter unterstützt keine Antwortanzahl-Angabe – Standardabfrage aktiv")
            case .noData:
                let count = (noDataCounts[pid] ?? 0) + 1
                noDataCounts[pid] = count
                if count >= configuration.noDataLimit {
                    scheduler?.remove(pid)
                    supportedPIDs.remove(pid)
                    publishAvailability()
                    log.add(.warning, "\(pid.title) liefert wiederholt keine Daten und wird nicht mehr abgefragt")
                }
            default:
                statistics.errors += 1
                if now - lastErrorLog > 2 {
                    lastErrorLog = now
                    log.add(.warning, "\(pid.request): \(failure.germanDescription)")
                }
            }
            return
        }
        let messages = OBDFrameDecoder.decode(lines: reply.lines, headersEnabled: headersEnabled, family: family)
        guard let match = Mode01Extractor.payload(for: pid.rawValue, in: messages, preferredECU: primaryECU),
              let value = pid.decode(match.data) else {
            statistics.errors += 1
            return
        }
        noDataCounts[pid] = 0
        requestMeter.record(now)
        if pid == .engineRPM { rpmMeter.record(now) }
        onSample?(SignalSample(signal: pid.signal, value: value, timestamp: now, origin: .vehicle))
    }

    private func updateStatistics() {
        let now = clock.now()
        statistics.requestRate = requestMeter.rate(now: now)
        statistics.rpmRate = rpmMeter.rate(now: now)
    }
}
