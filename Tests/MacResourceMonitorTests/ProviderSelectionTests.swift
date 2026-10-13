import XCTest
@testable import MacResourceMonitor

final class ProviderSelectionTests: XCTestCase {
    func testCompileTimeSliceChoosesCorrespondingSensorPolicy() async throws {
        let providers = ProviderSet.live(
            intelSensor: { StubSensor(temperature: 41) },
            appleSiliconSensor: { StubSensor(temperature: 52) }
        )
        let result = try await providers.sensors.sample()
        #if arch(x86_64)
        XCTAssertEqual(result.temperature.value, 41)
        #elseif arch(arm64)
        XCTAssertEqual(result.temperature.value, 52)
        #else
        XCTFail("Unsupported slice")
        #endif
    }

    func testLiveSelectionIsLazyAndCachesProvider() async throws {
        let counter = Counter()
        let selected = SystemSensorProvider(factory: {
            counter.creations += 1
            return StubSensor(temperature: 63)
        })
        XCTAssertEqual(counter.creations, 0)
        let first = try await selected.sample()
        let second = try await selected.sample()
        XCTAssertEqual(first.temperature.value, 63)
        XCTAssertEqual(second.temperature.value, 63)
        XCTAssertEqual(counter.creations, 1)
    }
}

private struct StubSensor: SensorProviding {
    let temperature: Double
    func sample() async throws -> ThermalMetric {
        ThermalMetric(temperature: .value(temperature), fan: .value(.fanless))
    }
}

private final class Counter: @unchecked Sendable {
    var creations = 0
}
