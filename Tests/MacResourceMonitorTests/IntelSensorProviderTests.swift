import XCTest
@testable import MacResourceMonitor

final class IntelSensorProviderTests: XCTestCase {
    private let hot = SMCValue(type: "sp78", bytes: [0x36, 0x80])
    private let fast = SMCValue(type: "fpe2", bytes: [0x1C, 0x70])

    func testIntelTemperatureWithoutFan() throws {
        let metric = IntelSensorProvider(transport: Transport(values: ["TC0P": hot])).sample()
        XCTAssertEqual(metric.temperature.value, 54.5)
        XCTAssertTrue(metric.fan.isUnavailable)
    }

    func testIntelFanWithoutTemperature() throws {
        let metric = IntelSensorProvider(transport: Transport(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [1]), "F0Ac": fast
        ])).sample()
        XCTAssertTrue(metric.temperature.isUnavailable)
        XCTAssertEqual(metric.fan.value, .rpm(1820))
    }

    func testVerifiedZeroCountVersusMissingAndStoppedFan() throws {
        let zero = IntelSensorProvider(transport: Transport(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [0])
        ])).sample()
        XCTAssertEqual(zero.fan.value, .fanless)
        for count in [nil, SMCValue(type: "ui8 ", bytes: []),
                      SMCValue(type: "ui8 ", bytes: [11]),
                      SMCValue(type: "sp78", bytes: [0, 0]),
                      SMCValue(type: "sp78", bytes: [0, 0x80])] {
            let values = count.map { ["FNum": $0] } ?? [:]
            XCTAssertTrue(IntelSensorProvider(transport: Transport(values: values)).sample().fan.isUnavailable)
        }
        let stopped = IntelSensorProvider(transport: Transport(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [1]),
            "F0Ac": SMCValue(type: "fpe2", bytes: [0, 0])
        ])).sample()
        XCTAssertEqual(stopped.fan.value, .rpm(0))
    }

    func testCandidatesFailClosedAndSecondCandidateFallback() throws {
        for bad in [SMCValue(type: "sp78", bytes: [0x09, 0]),
                    SMCValue(type: "sp78", bytes: [0x7D, 0x01]),
                    SMCValue(type: "flt ", bytes: [0, 0, 0xC0, 0x7F]),
                    SMCValue(type: "nope", bytes: [0x36, 0x80])] {
            let values = ["TC0P": bad, "TB0T": hot]
            XCTAssertTrue(IntelSensorProvider(transport: Transport(values: values)).sample().temperature.isUnavailable)
            XCTAssertEqual(IntelSensorProvider(transport: Transport(values: values.merging(["TC0D": hot]) { _, second in second })).sample().temperature.value, 54.5)
        }
        // Intel float byte order has not been established on hardware.
        XCTAssertTrue(IntelSensorProvider(transport: Transport(values: [
            "TC0P": SMCValue(type: "flt ", bytes: [0, 0, 0x5A, 0x42])
        ])).sample().temperature.isUnavailable)
        XCTAssertTrue(IntelSensorProvider(transport: Transport(values: ["TB0T": hot])).sample().temperature.isUnavailable)
    }

    func testFirstCredibleCandidateWinsWithoutEnumeration() throws {
        let metric = IntelSensorProvider(transport: Transport(values: [
            "TC0P": hot, "TC0D": SMCValue(type: "sp78", bytes: [0x40, 0])
        ], enumerationFails: true)).sample()
        XCTAssertEqual(metric.temperature.value, 54.5)
    }

    func testPartialMultiFanAndInvalidSpeedDoNotHideTemperature() throws {
        for second in [nil, SMCValue(type: "flt ", bytes: [0, 0, 0xC0, 0x7F])] {
            var values = ["TC0P": hot, "FNum": SMCValue(type: "ui8 ", bytes: [2]), "F0Ac": fast]
            values["F1Ac"] = second
            let metric = IntelSensorProvider(transport: Transport(values: values)).sample()
            XCTAssertEqual(metric.temperature.value, 54.5)
            XCTAssertTrue(metric.fan.isUnavailable)
        }
        let complete = IntelSensorProvider(transport: Transport(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [2]), "F0Ac": fast,
            "F1Ac": SMCValue(type: "fpe2", bytes: [0x20, 0])
        ])).sample()
        XCTAssertEqual(complete.fan.value, .rpm(2048))
    }

    func testIndependentRecoveryAtNextSample() throws {
        let transport = MutableTransport()
        let provider = IntelSensorProvider(transport: transport)
        let first = provider.sample()
        XCTAssertTrue(first.temperature.isUnavailable)
        XCTAssertTrue(first.fan.isUnavailable)
        transport.values = ["TC0P": hot, "FNum": SMCValue(type: "ui8 ", bytes: [1]), "F0Ac": fast]
        let second = provider.sample()
        XCTAssertEqual(second.temperature.value, 54.5)
        XCTAssertEqual(second.fan.value, .rpm(1820))
    }
}

private struct Transport: SMCTransport {
    let values: [String: SMCValue]
    var enumerationFails = false
    func allKeys() throws -> [String] {
        if enumerationFails { throw Failure.missing }
        return Array(values.keys)
    }
    func read(_ key: String) throws -> SMCValue {
        guard let value = values[key] else { throw Failure.missing }
        return value
    }
    enum Failure: Error { case missing }
}

private final class MutableTransport: SMCTransport, @unchecked Sendable {
    var values: [String: SMCValue] = [:]
    func allKeys() throws -> [String] { Array(values.keys) }
    func read(_ key: String) throws -> SMCValue {
        guard let value = values[key] else { throw Transport.Failure.missing }
        return value
    }
}
