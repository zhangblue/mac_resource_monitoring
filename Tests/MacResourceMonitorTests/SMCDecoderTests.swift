import XCTest
@testable import MacResourceMonitor

final class SMCDecoderTests: XCTestCase {
    func testDecodesSP78Temperature() throws {
        XCTAssertEqual(try SMCDecoder.decode(bytes: [0x36, 0x80], type: "sp78"), 54.5, accuracy: 0.001)
        XCTAssertEqual(try SMCDecoder.decode(bytes: [0xFF, 0x80], type: "sp78"), -0.5, accuracy: 0.001)
    }

    func testDecodesFPE2FanSpeed() throws {
        XCTAssertEqual(try SMCDecoder.decode(bytes: [0x1C, 0x70], type: "fpe2"), 1820, accuracy: 0.001)
    }

    func testDecodesIntegerByteOrderAndLittleEndianFloat() throws {
        XCTAssertEqual(try SMCDecoder.decode(bytes: [0xAB], type: "ui8 "), 171)
        XCTAssertEqual(try SMCDecoder.decode(bytes: [0x12, 0x34], type: "ui16"), 4660)
        XCTAssertEqual(try SMCDecoder.decode(bytes: [0x12, 0x34, 0x56, 0x78], type: "ui32"), 305419896)
        XCTAssertEqual(try SMCDecoder.decode(bytes: [0, 0, 0x5A, 0x42], type: "flt "), 54.5)
    }

    func testRejectsOverlongTypedPayloadsRatherThanDecodingPrefixes() {
        for (type, bytes): (String, [UInt8]) in [
            ("sp78", [0x36, 0x80, 0]), ("fpe2", [0x1C, 0x70, 0]),
            ("flt ", [0, 0, 0x5A, 0x42, 0]), ("ui8 ", [0, 0]),
            ("ui16", [0, 0, 0]), ("ui32", [0, 0, 0, 0, 0])
        ] {
            XCTAssertThrowsError(try SMCDecoder.decode(bytes: bytes, type: type), "\(type)")
        }
    }

    func testAppleSiliconFiniteFloatFanSpeedIsAccepted() throws {
        let metric = try AppleSiliconSensorProvider(transport: FakeSMC(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [1]),
            "F0Ac": SMCValue(type: "flt ", bytes: [0, 0x80, 0xE3, 0x44])
        ])).sample()
        XCTAssertEqual(metric.fan.value, .rpm(1820))
    }

    func testRejectsShortValuesAndUnknownTypes() {
        for (type, bytes) in [("sp78", [UInt8](repeating: 0, count: 1)), ("fpe2", [0]),
                              ("flt ", [0, 0, 0]), ("ui8 ", []), ("ui16", [0]), ("ui32", [0, 0, 0])] {
            XCTAssertThrowsError(try SMCDecoder.decode(bytes: bytes, type: type))
        }
        XCTAssertThrowsError(try SMCDecoder.decode(bytes: [0, 0], type: "nope"))
    }

    func testSensorSelectionUsesHottestPlausibleProcessorReading() {
        let values = ["TB0T": 32.0, "Tp01": 51.0, "Tp09": 54.0, "Tp99": 180.0]
        XCTAssertEqual(SensorSelection.chipTemperature(values), 54.0)
        XCTAssertNil(SensorSelection.chipTemperature(["TC0P": 60, "Tp01": 9.9, "Tp02": .nan]))
        XCTAssertEqual(SensorSelection.chipTemperature(["Tp01": 10, "Tp02": 125]), 125)
    }

    func testZeroFansIsFanlessAndHottestTemperatureWins() throws {
        let provider = AppleSiliconSensorProvider(transport: FakeSMC(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [0]),
            "Tp01": SMCValue(type: "sp78", bytes: [0x36, 0x80]),
            "TB0T": SMCValue(type: "sp78", bytes: [0x50, 0])
        ]))
        let metric = try provider.sample()
        XCTAssertEqual(metric.fan.value, .fanless)
        XCTAssertEqual(metric.temperature.value, 54.5)
    }

    func testAppleSiliconFanFailureRetainsTemperature() throws {
        let metric = try AppleSiliconSensorProvider(transport: FakeSMC(values: [
            "Tp01": SMCValue(type: "sp78", bytes: [0x36, 0x80])
        ])).sample()
        XCTAssertEqual(metric.temperature.value, 54.5)
        XCTAssertTrue(metric.fan.isUnavailable)
    }

    func testMultipleFansUseHighestActualRPMIncludingStoppedFans() throws {
        let metric = try AppleSiliconSensorProvider(transport: FakeSMC(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [2]),
            "F0Ac": SMCValue(type: "fpe2", bytes: [0, 0]),
            "F1Ac": SMCValue(type: "fpe2", bytes: [0x1C, 0x70])
        ])).sample()
        XCTAssertEqual(metric.fan.value, .rpm(1820))
        XCTAssertTrue(metric.temperature.isUnavailable)
    }

    func testMissingFanCountOrAnyFanReadingIsUnavailableInsteadOfInventingZero() throws {
        XCTAssertTrue(try AppleSiliconSensorProvider(transport: FakeSMC(values: [:])).sample().fan.isUnavailable)
        XCTAssertTrue(try AppleSiliconSensorProvider(transport: FakeSMC(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [2]),
            "F0Ac": SMCValue(type: "fpe2", bytes: [0x1C, 0x70])
        ])).sample().fan.isUnavailable)
    }

    func testInvalidFanValuesAreUnavailable() throws {
        for bytes: [UInt8] in [[0, 0, 0xC0, 0x7F], [0, 0, 0x80, 0xBF]] {
            XCTAssertTrue(try AppleSiliconSensorProvider(transport: FakeSMC(values: [
                "FNum": SMCValue(type: "ui8 ", bytes: [1]),
                "F0Ac": SMCValue(type: "flt ", bytes: bytes)
            ])).sample().fan.isUnavailable)
        }
    }

    func testTemperatureReadOrEnumerationFailureDoesNotInventTemperature() throws {
        let metric = try AppleSiliconSensorProvider(transport: FakeSMC(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [0]),
            "Tp01": SMCValue(type: "sp78", bytes: [])
        ])).sample()
        XCTAssertTrue(metric.temperature.isUnavailable)
        let failedEnumeration = try AppleSiliconSensorProvider(transport: FakeSMC(
            values: ["FNum": SMCValue(type: "ui8 ", bytes: [0])], enumerationFails: true
        )).sample()
        XCTAssertTrue(failedEnumeration.temperature.isUnavailable)
        XCTAssertEqual(failedEnumeration.fan.value, .fanless)
    }

    func testWireLayoutMatchesCABIAndFourCharacterKeyByteOrder() throws {
        XCTAssertTrue(SMCKeyData.hasValidLayout)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.size, 80)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.result), 40)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.data8), 42)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.data32), 44)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.bytes), 48)
        XCTAssertEqual(try SMCFourCC.encode("#KEY"), 0x234B4559)
        XCTAssertEqual(SMCFourCC.decode(0x666C7420), "flt ")
        XCTAssertThrowsError(try SMCFourCC.encode("Tp001"))
        XCTAssertThrowsError(try SMCFourCC.encode("温度"))
    }

    func testResponseValidationAcceptsOnlyZeroResultAndStatus() throws {
        try SMCResponseValidation.check(command: 5, result: 0, status: 0)
        for (result, status): (UInt8, UInt8) in [(1, 0), (0, 2), (3, 4)] {
            XCTAssertThrowsError(try SMCResponseValidation.check(command: 5, result: result, status: status)) { error in
                guard case let SMCError.deviceFailure(command, actualResult, actualStatus) = error else {
                    return XCTFail("Expected raw AppleSMC result and status, got \(error)")
                }
                XCTAssertEqual(command, 5)
                XCTAssertEqual(actualResult, result)
                XCTAssertEqual(actualStatus, status)
            }
        }
    }
}

private struct FakeSMC: SMCTransport {
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
