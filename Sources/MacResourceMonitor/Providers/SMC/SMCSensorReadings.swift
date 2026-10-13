import Foundation

enum SMCSensorReadings {
    static func fan(from transport: any SMCTransport, allowFloat: Bool = true) throws -> FanMetric {
        let countReading = try transport.read("FNum")
        guard ["ui8 ", "ui16", "ui32"].contains(countReading.type) else {
            throw SMCError.invalidFanCount
        }
        let count = try countReading.decoded()
        guard count.isFinite, (0...10).contains(count), count.rounded(.towardZero) == count else {
            throw SMCError.invalidFanCount
        }
        if count == 0 { return .fanless }
        var maximum = 0.0
        for index in 0..<Int(count) {
            let key = "F\(index)Ac"
            let reading = try transport.read(key)
            guard allowFloat || reading.type != "flt " else { throw SMCError.unsupportedType(reading.type) }
            let speed = try reading.decoded()
            guard speed.isFinite, speed >= 0 else { throw SMCError.invalidFanSpeed(key) }
            maximum = max(maximum, speed)
        }
        return .rpm(maximum)
    }
}
