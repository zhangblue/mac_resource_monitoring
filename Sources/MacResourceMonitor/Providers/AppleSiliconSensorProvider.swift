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

    // A missing temperature is represented by nil; any fan failure throws so the
    // coordinator can emit Reading.unavailable rather than a fictitious zero RPM.
    func sample() throws -> ThermalMetric {
        let fanCount = try transport.read("FNum").decoded()
        guard fanCount.isFinite, fanCount >= 0, fanCount <= 10,
              fanCount.rounded(.towardZero) == fanCount else {
            throw SMCError.invalidFanCount
        }
        let fan: FanMetric
        if fanCount == 0 {
            fan = .fanless
        } else {
            var speeds: [Double] = []
            for index in 0..<Int(fanCount) {
                let key = "F\(index)Ac"
                let speed = try transport.read(key).decoded()
                guard speed.isFinite, speed >= 0 else { throw SMCError.invalidFanSpeed(key) }
                speeds.append(speed)
            }
            fan = .rpm(speeds.max()!)
        }

        var temperatures: [String: Double] = [:]
        // Some temperature keys can be absent, inaccessible, or unsupported even
        // when enumeration succeeds. Keep any other credible processor reading.
        for key in (try? transport.allKeys()) ?? [] where key.hasPrefix("Tp") {
            if let value = try? transport.read(key).decoded() { temperatures[key] = value }
        }
        return ThermalMetric(chipTemperatureCelsius: SensorSelection.chipTemperature(temperatures), fan: fan)
    }
}
