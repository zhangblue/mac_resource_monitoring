import Foundation

enum SensorSelection {
    static func chipTemperature(_ values: [String: Double]) -> Double? {
        values.filter { $0.key.hasPrefix("Tp") && $0.value.isFinite && (10...125).contains($0.value) }
            .values.max()
    }
}

struct AppleSiliconSensorProvider: Sendable {
    private let transport: any SMCTransport

    init(transport: any SMCTransport) {
        self.transport = transport
    }

    init() throws {
        transport = try SMCClient()
    }

    // Preserve a successful processor reading when the fan read fails (and vice versa).
    func sample() throws -> ThermalMetric {
        let fan: Reading<FanMetric>
        do { fan = .value(try SMCSensorReadings.fan(from: transport)) }
        catch { fan = .unavailable("风扇采集失败") }

        var temperatures: [String: Double] = [:]
        // Some temperature keys can be absent, inaccessible, or unsupported even
        // when enumeration succeeds. Keep any other credible processor reading.
        for key in (try? transport.allKeys()) ?? [] where key.hasPrefix("Tp") {
            if let value = try? transport.read(key).decoded() { temperatures[key] = value }
        }
        let temperature: Reading<Double> = SensorSelection.chipTemperature(temperatures)
            .map(Reading<Double>.value) ?? .unavailable("温度采集失败")
        return ThermalMetric(temperature: temperature, fan: fan)
    }
}
