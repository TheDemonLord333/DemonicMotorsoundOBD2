import Foundation
import Testing
@testable import DemonicMotorsoundOBD2

@MainActor
struct PIDDecodingTests {
    @Test func rpmFormula() {
        // (256·A + B) / 4
        #expect(OBDPID.engineRPM.decode([0x1A, 0xF8]) == 1726)
        #expect(OBDPID.engineRPM.decode([0x00, 0x00]) == 0)
        #expect(OBDPID.engineRPM.decode([0xFF, 0xFF]) == 16383.75)
        #expect(OBDPID.engineRPM.decode([0x1A]) == nil)
    }

    @Test func percentAndTemperatureUnits() {
        #expect(OBDPID.engineLoad.decode([0xFF]) == 100)
        #expect(OBDPID.engineLoad.decode([0x00]) == 0)
        #expect(abs(OBDPID.throttlePosition.decode([0x80])! - 50.196) < 0.01)
        #expect(OBDPID.coolantTemperature.decode([0x00]) == -40)
        #expect(OBDPID.coolantTemperature.decode([0x7B]) == 83)
        #expect(OBDPID.vehicleSpeed.decode([0x32]) == 50)
        #expect(abs(OBDPID.acceleratorPedalD.decode([0x26])! - 14.9) < 0.1)
    }

    @Test func throttleAndPedalAreDistinctSignals() {
        #expect(OBDPID.throttlePosition.signal == .throttle)
        #expect(OBDPID.acceleratorPedalD.signal == .pedal)
        #expect(OBDPID.relativeAcceleratorPedal.signal == .pedal)
        #expect(VehicleSignal.throttle != VehicleSignal.pedal)
        #expect(VehicleSignal.coolant.title == "Kühlmitteltemperatur")
    }

    @Test func supportedPIDBitmask() {
        let set = SupportedPIDDecoder.decode(base: 0x00, data: [0xBE, 0x3F, 0xA8, 0x13][...])
        #expect(set.contains(0x04))
        #expect(set.contains(0x05))
        #expect(set.contains(0x0C))
        #expect(set.contains(0x0D))
        #expect(set.contains(0x11))
        #expect(set.contains(0x20))
        #expect(!set.contains(0x02))
        #expect(!set.contains(0x12))

        let high = SupportedPIDDecoder.decode(base: 0x40, data: [0x40, 0x80, 0x00, 0x00][...])
        #expect(high == [0x42, 0x49])
    }

    @Test func requestStrings() {
        #expect(OBDPID.engineRPM.request == "010C")
        #expect(OBDPID.acceleratorPedalD.request == "0149")
    }
}

@MainActor
struct FrameDecoderTests {
    @Test func can11WithHeadersAndSpaces() {
        let messages = OBDFrameDecoder.decode(lines: ["7E8 04 41 0C 1A F8"], headersEnabled: true, family: .can11)
        #expect(messages == [ECUMessage(ecu: "7E8", bytes: [0x41, 0x0C, 0x1A, 0xF8])])
    }

    @Test func can11WithHeadersWithoutSpaces() {
        let messages = OBDFrameDecoder.decode(lines: ["7E804410C1AF8"], headersEnabled: true, family: .can11)
        #expect(messages == [ECUMessage(ecu: "7E8", bytes: [0x41, 0x0C, 0x1A, 0xF8])])
    }

    @Test func can29Header() {
        let messages = OBDFrameDecoder.decode(lines: ["18 DA F1 10 04 41 0C 0F A0"], headersEnabled: true, family: .can29)
        #expect(messages.first?.ecu == "18DAF110")
        #expect(messages.first?.bytes == [0x41, 0x0C, 0x0F, 0xA0])
    }

    @Test func legacyHeaderStripsChecksum() {
        let messages = OBDFrameDecoder.decode(lines: ["48 6B 10 41 0C 1A F8 C5"], headersEnabled: true, family: .legacy)
        #expect(messages == [ECUMessage(ecu: "10", bytes: [0x41, 0x0C, 0x1A, 0xF8])])
    }

    @Test func withoutHeaders() {
        let messages = OBDFrameDecoder.decode(lines: ["41 0C 1A F8"], headersEnabled: false, family: .can11)
        #expect(messages == [ECUMessage(ecu: nil, bytes: [0x41, 0x0C, 0x1A, 0xF8])])
    }

    @Test func multipleECUsAreKeptSeparate() {
        let lines = ["7E8 06 41 00 BE 3F A8 13", "7E9 06 41 00 98 18 80 11"]
        let messages = OBDFrameDecoder.decode(lines: lines, headersEnabled: true, family: .can11)
        #expect(messages.count == 2)
        #expect(Set(messages.compactMap(\.ecu)) == ["7E8", "7E9"])

        let rpmLines = ["7E9 04 41 0C 00 00", "7E8 04 41 0C 1A F8"]
        let rpmMessages = OBDFrameDecoder.decode(lines: rpmLines, headersEnabled: true, family: .can11)
        let match = Mode01Extractor.payload(for: 0x0C, in: rpmMessages, preferredECU: "7E8")
        #expect(match?.ecu == "7E8")
        #expect(OBDPID.engineRPM.decode(match!.data) == 1726)
    }

    @Test func otherECUIsIgnoredWhenPrimaryMissing() {
        let messages = OBDFrameDecoder.decode(lines: ["7E9 04 41 0C 00 00"], headersEnabled: true, family: .can11)
        #expect(Mode01Extractor.payload(for: 0x0C, in: messages, preferredECU: "7E8") == nil)
    }

    @Test func isoTPMultiFrameInterleavedECUs() {
        // VIN-Antwort (Mode 09) von zwei Steuergeräten, deren Rahmen sich abwechseln.
        let lines = [
            "7E8 10 14 49 02 01 4A 48 4D",
            "7E9 10 14 49 02 01 58 58 58",
            "7E8 21 47 45 38 38 30 30 46",
            "7E9 21 58 58 58 58 58 58 58",
            "7E8 22 53 30 30 30 30 30 31",
            "7E9 22 58 58 58 58 58 58 58",
        ]
        let messages = OBDFrameDecoder.decode(lines: lines, headersEnabled: true, family: .can11)
        #expect(messages.count == 2)
        let e8 = messages.first { $0.ecu == "7E8" }
        #expect(e8?.bytes.count == 0x14)
        #expect(e8?.bytes.prefix(3) == [0x49, 0x02, 0x01])
        #expect(e8?.bytes.contains(0x58) == false)
    }

    @Test func isoTPSequenceErrorDiscardsMessage() {
        let lines = ["7E8 10 0A 49 02 01 4A 48 4D", "7E8 22 47 45 38 38 30 30 46"]
        #expect(OBDFrameDecoder.decode(lines: lines, headersEnabled: true, family: .can11).isEmpty)
    }

    @Test func multiFrameWithoutHeaders() {
        let lines = ["014", "0: 49 02 01 4A 48 4D", "1: 47 45 38 38 30 30 46", "2: 53 30 30 30 30 30 31"]
        let messages = OBDFrameDecoder.decode(lines: lines, headersEnabled: false, family: .can11)
        #expect(messages.count == 1)
        #expect(messages[0].bytes.count == 0x14)
    }

    @Test func negativeResponseYieldsNoValue() {
        let messages = OBDFrameDecoder.decode(lines: ["7E8 03 7F 01 12"], headersEnabled: true, family: .can11)
        #expect(Mode01Extractor.payload(for: 0x0C, in: messages, preferredECU: "7E8") == nil)
    }

    @Test func protocolNumberParsing() {
        #expect(OBDProtocolFamily.fromDescribeProtocolNumber("A6").family == .can11)
        #expect(OBDProtocolFamily.fromDescribeProtocolNumber("7").family == .can29)
        #expect(OBDProtocolFamily.fromDescribeProtocolNumber("A3").family == .legacy)
        #expect(OBDProtocolFamily.fromDescribeProtocolNumber("").family == .unknown)
    }

    @Test func primaryECUPrefersEngineController() {
        #expect(ELM327Session.choosePrimaryECU(["7E9": [0x0C, 0x0D], "7E8": [0x0C]]) == "7E8")
        #expect(ELM327Session.choosePrimaryECU(["7EA": [0x0D], "7E9": [0x0C]]) == "7E9")
        #expect(ELM327Session.choosePrimaryECU([:]) == nil)
    }
}
