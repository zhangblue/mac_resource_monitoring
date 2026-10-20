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
        XCTAssertEqual(metric.fan, .fanless)
        XCTAssertEqual(metric.chipTemperatureCelsius, 54.5)
    }

    func testMultipleFansUseHighestActualRPMIncludingStoppedFans() throws {
        let metric = try AppleSiliconSensorProvider(transport: FakeSMC(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [2]),
            "F0Ac": SMCValue(type: "fpe2", bytes: [0, 0]),
            "F1Ac": SMCValue(type: "fpe2", bytes: [0x1C, 0x70])
        ])).sample()
        XCTAssertEqual(metric.fan, .rpm(1820))
        XCTAssertNil(metric.chipTemperatureCelsius)
    }

    func testMissingFanCountOrAnyFanReadingThrowsInsteadOfInventingZero() {
        XCTAssertThrowsError(try AppleSiliconSensorProvider(transport: FakeSMC(values: [:])).sample())
        XCTAssertThrowsError(try AppleSiliconSensorProvider(transport: FakeSMC(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [2]),
            "F0Ac": SMCValue(type: "fpe2", bytes: [0x1C, 0x70])
        ])).sample())
    }

    func testInvalidFanValuesAreUnavailable() {
        for bytes: [UInt8] in [[0, 0, 0xC0, 0x7F], [0, 0, 0x80, 0xBF]] {
            XCTAssertThrowsError(try AppleSiliconSensorProvider(transport: FakeSMC(values: [
                "FNum": SMCValue(type: "ui8 ", bytes: [1]),
                "F0Ac": SMCValue(type: "flt ", bytes: bytes)
            ])).sample())
        }
    }

    func testTemperatureReadOrEnumerationFailureDoesNotInventTemperature() throws {
        let metric = try AppleSiliconSensorProvider(transport: FakeSMC(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [0]),
            "Tp01": SMCValue(type: "sp78", bytes: [])
        ])).sample()
        XCTAssertNil(metric.chipTemperatureCelsius)
        let failedEnumeration = try AppleSiliconSensorProvider(transport: FakeSMC(
            values: ["FNum": SMCValue(type: "ui8 ", bytes: [0])], enumerationFails: true
        )).sample()
        XCTAssertNil(failedEnumeration.chipTemperatureCelsius)
        XCTAssertEqual(failedEnumeration.fan, .fanless)
    }

    func testLegacySensorFailureKeepsUnselectedFanAsNotSelected() async {
        let legacy = ThrowingLegacySensor()
        let provider: any SensorProviding = legacy
        let readings = await provider.sample(temperature: true, fan: false)
        guard case .unavailable("temperatureUnavailable") = readings.temperature else {
            return XCTFail("Requested temperature failure should be unavailable")
        }
        guard case .unavailable("notSelected") = readings.fan else {
            return XCTFail("Unselected fan must not be marked failed")
        }
        let calls = await legacy.sampleCount
        XCTAssertEqual(calls, 1)
    }

    func testLegacySensorFailureKeepsUnselectedTemperatureAsNotSelected() async {
        let legacy = ThrowingLegacySensor()
        let provider: any SensorProviding = legacy
        let readings = await provider.sample(temperature: false, fan: true)
        guard case .unavailable("notSelected") = readings.temperature else {
            return XCTFail("Unselected temperature must not be marked failed")
        }
        guard case .unavailable("fanUnavailable") = readings.fan else {
            return XCTFail("Requested fan failure should be unavailable")
        }
        let calls = await legacy.sampleCount
        XCTAssertEqual(calls, 1)
    }

    func testLegacySensorNeitherSelectedSkipsThrowingSample() async {
        let legacy = ThrowingLegacySensor()
        let provider: any SensorProviding = legacy
        let readings = await provider.sample(temperature: false, fan: false)
        guard case .unavailable("notSelected") = readings.temperature,
              case .unavailable("notSelected") = readings.fan else {
            return XCTFail("Unselected sensors must remain notSelected")
        }
        let calls = await legacy.sampleCount
        XCTAssertEqual(calls, 0)
    }

    func testSystemSensorInitializationFailureKeepsUnselectedFanAsNotSelected() async {
        let factory = FailingSensorFactory()
        let provider: any SensorProviding = SystemSensorProvider(makeProvider: { try factory.make() })
        let readings = await provider.sample(temperature: true, fan: false)
        guard case .unavailable("temperatureUnavailable") = readings.temperature,
              case .unavailable("notSelected") = readings.fan else {
            return XCTFail("Only requested temperature should be marked unavailable")
        }
        XCTAssertEqual(factory.attempts, 1)
    }

    func testSystemSensorInitializationFailureKeepsUnselectedTemperatureAsNotSelected() async {
        let factory = FailingSensorFactory()
        let provider: any SensorProviding = SystemSensorProvider(makeProvider: { try factory.make() })
        let readings = await provider.sample(temperature: false, fan: true)
        guard case .unavailable("notSelected") = readings.temperature,
              case .unavailable("fanUnavailable") = readings.fan else {
            return XCTFail("Only requested fan should be marked unavailable")
        }
        XCTAssertEqual(factory.attempts, 1)
    }

    func testSystemSensorNeitherSelectedDoesNotInitializeSMC() async {
        let factory = FailingSensorFactory()
        let provider: any SensorProviding = SystemSensorProvider(makeProvider: { try factory.make() })
        let readings = await provider.sample(temperature: false, fan: false)
        guard case .unavailable("notSelected") = readings.temperature,
              case .unavailable("notSelected") = readings.fan else {
            return XCTFail("Neither sensor requested: neither should be marked failed")
        }
        XCTAssertEqual(factory.attempts, 0)
    }

    func testTemperatureOnlySkipsAllFanKeysAndFanOnlySkipsEnumeration() async {
        let transport = CountingSMC(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [1]),
            "F0Ac": SMCValue(type: "fpe2", bytes: [0x1C, 0x70]),
            "Tp01": SMCValue(type: "sp78", bytes: [0x36, 0x80])
        ])
        let provider = AppleSiliconSensorProvider(transport: transport)
        let temperature = await provider.sample(temperature: true, fan: false)
        XCTAssertEqual(temperature.temperature.value, 54.5)
        XCTAssertNil(temperature.fan.value)
        XCTAssertEqual(transport.keysRead, ["Tp01"])
        XCTAssertEqual(transport.enumerations, 1)

        transport.reset()
        let fan = await provider.sample(temperature: false, fan: true)
        XCTAssertNil(fan.temperature.value)
        XCTAssertEqual(fan.fan.value, .rpm(1820))
        XCTAssertEqual(transport.keysRead, ["FNum", "F0Ac"])
        XCTAssertEqual(transport.enumerations, 0)

        transport.reset()
        let both = await provider.sample(temperature: true, fan: true)
        XCTAssertEqual(both.temperature.value, 54.5)
        XCTAssertEqual(both.fan.value, .rpm(1820))
        XCTAssertEqual(transport.enumerations, 1)
        XCTAssertEqual(transport.keysRead.filter { $0 == "FNum" }.count, 1)
    }

    func testIndependentSensorFailureAndNoSelectionSkipsSMC() async {
        let transport = CountingSMC(values: ["Tp01": SMCValue(type: "sp78", bytes: [0x36, 0x80])])
        let provider = AppleSiliconSensorProvider(transport: transport)
        let neither = await provider.sample(temperature: false, fan: false)
        XCTAssertNil(neither.temperature.value)
        XCTAssertNil(neither.fan.value)
        XCTAssertEqual(transport.keysRead.count, 0)
        XCTAssertEqual(transport.enumerations, 0)
        let fanFailure = await provider.sample(temperature: true, fan: true)
        XCTAssertEqual(fanFailure.temperature.value, 54.5)
        XCTAssertTrue(fanFailure.fan.isUnavailable)

        let missingTemperature = await AppleSiliconSensorProvider(transport: CountingSMC(values: [
            "FNum": SMCValue(type: "ui8 ", bytes: [0])
        ], enumerationFails: true)).sample(temperature: true, fan: true)
        XCTAssertTrue(missingTemperature.temperature.isUnavailable)
        XCTAssertEqual(missingTemperature.fan.value, .fanless)
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

private final class FailingSensorFactory: @unchecked Sendable {
    enum Failure: Error { case cannotOpen }
    private let lock = NSLock()
    private var count = 0
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
    func make() throws -> AppleSiliconSensorProvider {
        lock.lock(); count += 1; lock.unlock()
        throw Failure.cannotOpen
    }
}

private actor ThrowingLegacySensor: SensorProviding {
    enum Failure: Error { case unavailable }
    private(set) var sampleCount = 0
    func sample() throws -> ThermalMetric {
        sampleCount += 1
        throw Failure.unavailable
    }
}

private final class CountingSMC: SMCTransport, @unchecked Sendable {
    let values: [String: SMCValue]
    let enumerationFails: Bool
    private let lock = NSLock()
    private var recordedKeys: [String] = []
    private var enumerationCount = 0
    var keysRead: [String] { lock.lock(); defer { lock.unlock() }; return recordedKeys }
    var enumerations: Int { lock.lock(); defer { lock.unlock() }; return enumerationCount }

    init(values: [String: SMCValue], enumerationFails: Bool = false) {
        self.values = values
        self.enumerationFails = enumerationFails
    }

    func reset() { lock.lock(); defer { lock.unlock() }; recordedKeys = []; enumerationCount = 0 }
    func allKeys() throws -> [String] {
        lock.lock(); enumerationCount += 1; lock.unlock()
        if enumerationFails { throw FakeSMC.Failure.missing }
        return Array(values.keys)
    }
    func read(_ key: String) throws -> SMCValue {
        lock.lock(); recordedKeys.append(key); lock.unlock()
        guard let value = values[key] else { throw FakeSMC.Failure.missing }
        return value
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
