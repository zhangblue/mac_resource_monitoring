import Foundation

enum MetricFormatter {
    static func rate(_ bytesPerSecond: Double) -> String {
        let value = nonNegativeFinite(bytesPerSecond)
        let units = [(1_000_000_000.0, "GB/s"), (1_000_000.0, "MB/s"), (1_000.0, "KB/s")]
        for (scale, unit) in units where value >= scale {
            return "\(compact(value / scale)) \(unit)"
        }
        return "\(integer(value)) B/s"
    }

    static func menuRate(_ bytesPerSecond: Double) -> String {
        let value = nonNegativeFinite(bytesPerSecond)
        let units = [(1_000_000_000.0, "G"), (1_000_000.0, "M"), (1_000.0, "K")]
        for (scale, unit) in units where value >= scale {
            return "\(compact(value / scale))\(unit)"
        }
        return integer(value)
    }

    static func memory(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        let units = [(1_073_741_824.0, "GiB"), (1_048_576.0, "MiB"), (1_024.0, "KiB")]
        for (scale, unit) in units where value >= scale {
            return "\(compact(value / scale)) \(unit)"
        }
        return "\(integer(value)) B"
    }

    static func percent(_ percentage: Double) -> String {
        "\(integer(nonNegativeFinite(percentage)))%"
    }

    static func rpm(_ revolutionsPerMinute: Double) -> String {
        "\(integer(nonNegativeFinite(revolutionsPerMinute))) RPM"
    }

    private static func compact(_ value: Double) -> String {
        guard value <= Double.greatestFiniteMagnitude / 10 else { return integer(value) }
        let rounded = (value * 10).rounded() / 10
        return rounded.rounded(.towardZero) == rounded ? integer(rounded) : String(format: "%.1f", rounded)
    }

    private static func integer(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = value.rounded()
        guard rounded > 0 else { return "0" }
        guard rounded < Double(Int64.max) else { return "9223372036854775807" }
        return String(Int64(rounded))
    }

    private static func nonNegativeFinite(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}
