import Foundation

struct IntelSensorProvider: Sendable {
    private let transport: any SMCTransport

    init(transport: any SMCTransport) { self.transport = transport }
    init() throws { transport = try SMCClient() }

    func sample() -> ThermalMetric {
        let temperature: Reading<Double>
        if let value = cpuTemperature() {
            temperature = .value(value)
        } else {
            temperature = .unavailable("温度采集失败")
        }
        let fan: Reading<FanMetric>
        do { fan = .value(try SMCSensorReadings.fan(from: transport, allowFloat: false)) }
        catch { fan = .unavailable("风扇采集失败") }
        return ThermalMetric(temperature: temperature, fan: fan)
    }

    private func cpuTemperature() -> Double? {
        // Experimental CPU candidates pending verification on actual Intel hardware.
        // Do not enumerate other T* keys or interpret Apple Silicon flt bytes here.
        for key in ["TC0P", "TC0D"] {
            guard let reading = try? transport.read(key), reading.type == "sp78",
                  let value = try? reading.decoded(), value.isFinite, (10...125).contains(value) else {
                continue
            }
            return value
        }
        return nil
    }
}
