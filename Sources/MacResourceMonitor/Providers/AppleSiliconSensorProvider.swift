import Foundation

enum SensorSelection {
    static func chipTemperature(_ values: [String: Double]) -> Double? {
        values.filter { $0.key.hasPrefix("Tp") && $0.value.isFinite && (10...125).contains($0.value) }
            .values.max()
    }
}

struct SensorReadings: Sendable {
    let temperature: Reading<Double>
    let fan: Reading<FanMetric>
}

struct AppleSiliconSensorProvider: Sendable {
    private let transport: any SMCTransport

    init(transport: any SMCTransport) {
        self.transport = transport
    }

    init() throws {
        transport = try SMCClient()
    }

    // A legacy all-on sample retains its existing fan-throw / optional-temperature semantics.
    func sample() throws -> ThermalMetric {
        let fan = try readFan()
        return ThermalMetric(chipTemperatureCelsius: try? readTemperature(), fan: fan)
    }

    func sample(temperature: Bool, fan: Bool) async -> SensorReadings {
        let temperatureReading: Reading<Double>
        if temperature {
            do { temperatureReading = .value(try readTemperature()) }
            catch { temperatureReading = .unavailable("temperatureUnavailable") }
        } else {
            temperatureReading = .unavailable("notSelected")
        }
        let fanReading: Reading<FanMetric>
        if fan {
            do { fanReading = .value(try readFan()) }
            catch { fanReading = .unavailable("fanUnavailable") }
        } else {
            fanReading = .unavailable("notSelected")
        }
        return .init(temperature: temperatureReading, fan: fanReading)
    }

    private func readFan() throws -> FanMetric {
        let fanCount = try transport.read("FNum").decoded()
        guard fanCount.isFinite, fanCount >= 0, fanCount <= 10,
              fanCount.rounded(.towardZero) == fanCount else {
            throw SMCError.invalidFanCount
        }
        if fanCount == 0 { return .fanless }
        var speeds: [Double] = []
        for index in 0..<Int(fanCount) {
            let key = "F\(index)Ac"
            let speed = try transport.read(key).decoded()
            guard speed.isFinite, speed >= 0 else { throw SMCError.invalidFanSpeed(key) }
            speeds.append(speed)
        }
        return .rpm(speeds.max()!)
    }

    private enum TemperatureError: Error { case noPlausibleReading }

    private func readTemperature() throws -> Double {
        var temperatures: [String: Double] = [:]
        // A missing individual key does not hide the other processor readings.
        for key in try transport.allKeys() where key.hasPrefix("Tp") {
            if let value = try? transport.read(key).decoded() { temperatures[key] = value }
        }
        guard let temperature = SensorSelection.chipTemperature(temperatures) else {
            throw TemperatureError.noPlausibleReading
        }
        return temperature
    }
}
