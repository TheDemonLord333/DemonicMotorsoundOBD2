import Foundation
import Testing
@testable import DemonicMotorsoundOBD2

@MainActor
struct ELM327ResponseTests {
    @Test func fragmentedResponseIsAssembledAtPrompt() {
        var acc = ELM327ResponseAccumulator()
        #expect(acc.append(Array("7E8 04 41 0".utf8)).isEmpty)
        #expect(acc.append(Array("C 1A F8\r".utf8)).isEmpty)
        let done = acc.append(Array("\r>".utf8))
        #expect(done == ["7E8 04 41 0C 1A F8\r\r"])
        #expect(acc.pendingByteCount == 0)
    }

    @Test func multipleResponsesInOneChunkAndNULBytes() {
        var acc = ELM327ResponseAccumulator()
        let done = acc.append([0x4F, 0x4B, 0x0D, 0x00, 0x3E, 0x4F, 0x4B, 0x3E, 0x34])
        #expect(done == ["OK\r", "OK"])
        #expect(acc.pendingByteCount == 1)
    }

    @Test func echoIsRemoved() {
        let reply = ELM327Reply.parse(raw: "010C\r7E8 04 41 0C 1A F8\r\r", command: "010C")
        #expect(reply.lines == ["7E8 04 41 0C 1A F8"])
        let at = ELM327Reply.parse(raw: "ATE0\rOK\r\r", command: "ATE0")
        #expect(at.lines == ["OK"])
    }

    @Test func searchingAndBusInitAreSkipped() {
        let reply = ELM327Reply.parse(raw: "SEARCHING...\r7E8 06 41 00 BE 3F A8 13\r\r", command: "0100")
        #expect(reply.lines == ["7E8 06 41 00 BE 3F A8 13"])
        let busInit = ELM327Reply.parse(raw: "BUS INIT: ...OK\r48 6B 10 41 00 BE 3F A8 13 C5\r", command: "0100")
        #expect(busInit.lines == ["48 6B 10 41 00 BE 3F A8 13 C5"])
        let busInitError = ELM327Reply.parse(raw: "BUS INIT: ...ERROR\r", command: "0100")
        #expect(busInitError.failure == .busInitError)
    }

    @Test func typicalErrors() {
        #expect(ELM327Reply.parse(raw: "NO DATA\r\r", command: "0149").failure == .noData)
        #expect(ELM327Reply.parse(raw: "?\r\r", command: "010C1").failure == .unknownCommand)
        #expect(ELM327Reply.parse(raw: "SEARCHING...\rUNABLE TO CONNECT\r\r", command: "0100").failure == .unableToConnect)
        #expect(ELM327Reply.parse(raw: "CAN ERROR\r", command: "0100").failure == .canError)
        #expect(ELM327Reply.parse(raw: "BUFFER FULL\r", command: "010C").failure == .bufferFull)
        #expect(ELM327Reply.parse(raw: "STOPPED\r", command: "010C").failure == .stopped)
        #expect(ELM327Reply.parse(raw: "ERR94\r", command: "010C").failure == .internalError("ERR94"))
        #expect(ELM327Reply.parse(raw: "\r\r", command: "010C").failure == .emptyResponse)
    }

    @Test func partialDataErrorKeepsValidLines() {
        let reply = ELM327Reply.parse(raw: "7E8 04 41 0C 1A F8\r7E9 04 41 0C 00<DATA ERROR\r", command: "010C")
        #expect(reply.lines == ["7E8 04 41 0C 1A F8"])
        #expect(reply.errors == [.dataError])
        #expect(reply.failure == nil)
    }

    @Test func commandPolicyAllowsOnlyReadOnlyCommands() {
        #expect(ELM327CommandPolicy.isAllowed("ATZ"))
        #expect(ELM327CommandPolicy.isAllowed("ATE0"))
        #expect(ELM327CommandPolicy.isAllowed("010C"))
        #expect(ELM327CommandPolicy.isAllowed("010C1"))
        #expect(ELM327CommandPolicy.isAllowed("0100"))
        // Fehlerspeicher löschen, Stellglieder, beliebige CAN-Nachrichten, Header setzen: blockiert.
        #expect(!ELM327CommandPolicy.isAllowed("04"))
        #expect(!ELM327CommandPolicy.isAllowed("0300"))
        #expect(!ELM327CommandPolicy.isAllowed("2F 01 02 03"))
        #expect(!ELM327CommandPolicy.isAllowed("ATSH7E0"))
        #expect(!ELM327CommandPolicy.isAllowed("ATMA"))
        #expect(!ELM327CommandPolicy.isAllowed("STPX"))
        #expect(!ELM327CommandPolicy.isAllowed("3E00"))
        #expect(!ELM327CommandPolicy.isAllowed("010C0D"))
        #expect(!ELM327CommandPolicy.isAllowed("010CA"))
    }
}

@MainActor
struct ELM327SessionTests {
    private func makeSession(_ transport: MockELM327Transport, configuration: ELM327Session.Configuration? = nil) -> ELM327Session {
        var config = configuration ?? ELM327Session.Configuration()
        config.postResetDelay = 0.01
        config.minimumPollInterval = 0.005
        return ELM327Session(transport: transport, log: DiagnosticLog(), configuration: config)
    }

    @Test func initializationDiscoveryAndPollingWithFragments() async {
        let transport = MockELM327Transport(responder: SimulatedVehicle.canResponder())
        transport.fragmentSize = 5
        let session = makeSession(transport)
        var samples: [SignalSample] = []
        var availability: [VehicleSignal: SignalAvailability] = [:]
        session.onSample = { samples.append($0) }
        session.onAvailabilityChange = { availability = $0 }
        session.start()

        let polled = await waitUntil { samples.filter { $0.signal == .rpm }.count >= 3 && samples.contains { $0.signal != .rpm } }
        session.stop()
        #expect(polled)
        #expect(session.adapterVersion == "ELM327 v1.5")
        #expect(session.family == .can11)
        #expect(session.primaryECU == "7E8")
        #expect(session.supportedPIDs.contains(.engineRPM))
        #expect(session.supportedPIDs.contains(.acceleratorPedalD))
        #expect(availability[.rpm] == .supported)
        #expect(availability[.pedal] == .supported)
        #expect(samples.first { $0.signal == .rpm }?.value == 1726)
        #expect(samples.allSatisfy { $0.origin == .vehicle })
        // Initialisierung in definierter Reihenfolge, Echo wird vor ATE0 korrekt entfernt.
        #expect(Array(transport.sentCommands.prefix(7)) == ["ATZ", "ATE0", "ATL0", "ATS1", "ATH1", "ATAT1", "ATSP0"])
        // Nur ein Steuergerät → Antwortanzahl-Suffix wird genutzt.
        #expect(transport.sentCommands.contains("010C1"))
        // Alle gesendeten Befehle entsprechen der Leserichtlinie.
        #expect(transport.sentCommands.allSatisfy { ELM327CommandPolicy.isAllowed($0) })
    }

    @Test func multipleECUsUsePrimaryAndNoSuffix() async {
        let transport = MockELM327Transport(responder: SimulatedVehicle.canResponder(multipleECUs: true))
        let session = makeSession(transport)
        var rpmValues: [Double] = []
        session.onSample = { if $0.signal == .rpm { rpmValues.append($0.value) } }
        session.start()
        let ok = await waitUntil { rpmValues.count >= 3 }
        session.stop()
        #expect(ok)
        #expect(session.ecuSupport.keys.sorted() == ["7E8", "7E9"])
        #expect(!session.usesResponseCountSuffix)
        // Die 0-Antwort des zweiten Steuergeräts darf nie als Drehzahl erscheinen.
        #expect(rpmValues.allSatisfy { $0 == 1726 })
    }

    @Test func unableToConnectFailsWithGermanMessage() async {
        let base = SimulatedVehicle.canResponder()
        let transport = MockELM327Transport { command in
            command == "0100" ? "SEARCHING...\rUNABLE TO CONNECT\r\r>" : base(command)
        }
        let session = makeSession(transport)
        session.start()
        let failed = await waitUntil {
            if case .failed = session.phase { return true }
            return false
        }
        #expect(failed)
        if case .failed(let message) = session.phase {
            #expect(message.contains("Zündung"))
        }
        session.stop()
    }

    @Test func timeoutDiscardsLateResponseAndRecovers() async {
        let transport = MockELM327Transport(responder: SimulatedVehicle.canResponder())
        transport.echo = false
        var config = ELM327Session.Configuration()
        config.commandTimeout = 0.1
        config.resyncDelay = 0.3
        let session = makeSession(transport, configuration: config)
        // ATRV antwortet zu spät – die Antwort darf nicht dem nächsten Befehl zugeordnet werden.
        transport.delays["ATRV"] = 0.2

        await #expect(throws: ELM327Error.timeout) {
            _ = try await session.execute("ATRV")
        }
        let reply = try? await session.execute("ATDPN")
        #expect(reply?.lines == ["A6"])
        #expect(session.statistics.timeouts == 1)
        #expect(session.log.entries.contains { $0.text.contains("Verspätete Antwort verworfen") })
    }

    @Test func blockedCommandIsNeverSent() async {
        let transport = MockELM327Transport(responder: SimulatedVehicle.canResponder())
        let session = makeSession(transport)
        await #expect(throws: ELM327Error.notAllowed("04")) {
            _ = try await session.execute("04")
        }
        #expect(transport.sentCommands.isEmpty)
    }

    @Test func repeatedNoDataRemovesPID() async {
        let base = SimulatedVehicle.canResponder()
        let transport = MockELM327Transport { command in
            command.hasPrefix("0105") ? "NO DATA\r\r>" : base(command)
        }
        var config = ELM327Session.Configuration()
        config.noDataLimit = 2
        let session = makeSession(transport, configuration: config)
        var availability: [VehicleSignal: SignalAvailability] = [:]
        session.onAvailabilityChange = { availability = $0 }
        session.start()
        let removed = await waitUntil(timeout: 15) { availability[.coolant] == .unsupported }
        session.stop()
        #expect(removed)
        #expect(!session.supportedPIDs.contains(.coolantTemperature))
    }

    @Test func adapterSilenceLeadsToConnectionProblem() async {
        let base = SimulatedVehicle.canResponder()
        var silent = false
        let transport = MockELM327Transport { command in
            silent ? nil : base(command)
        }
        var config = ELM327Session.Configuration()
        config.pollTimeout = 0.05
        config.resyncDelay = 0.01
        let session = makeSession(transport, configuration: config)
        var problem: String?
        var rpmCount = 0
        session.onConnectionProblem = { problem = $0 }
        session.onSample = { if $0.signal == .rpm { rpmCount += 1 } }
        session.start()
        _ = await waitUntil { rpmCount > 2 }
        silent = true
        let detected = await waitUntil { problem != nil }
        #expect(detected)
        session.stop()
    }
}
