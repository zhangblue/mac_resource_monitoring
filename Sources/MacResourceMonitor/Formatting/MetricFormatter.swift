import Foundation

enum MetricFormatter {
    /// 将字节每秒格式化为详情面板速率；网络卡片和进程榜单展示时调用。
    /// 速率使用十进制 1000 进位，输入先钳制为有限非负值，防止 NaN、无穷或负数进入界面。
    static func rate(_ bytesPerSecond: Double) -> String {
        let value = nonNegativeFinite(bytesPerSecond)
        let units = [(1_000_000_000.0, "GB/s"), (1_000_000.0, "MB/s"), (1_000.0, "KB/s")]
        for (scale, unit) in units where value >= scale {
            return "\(compact(value / scale)) \(unit)"
        }
        return "\(integer(value)) B/s"
    }

    /// 将字节每秒压缩为菜单栏短文本；菜单栏上传、下载读数刷新时调用。
    static func menuRate(_ bytesPerSecond: Double) -> String {
        let value = nonNegativeFinite(bytesPerSecond)
        let units = [(1_000_000_000.0, "G"), (1_000_000.0, "M"), (1_000.0, "K")]
        for (scale, unit) in units where value >= scale {
            return "\(compact(value / scale))\(unit)"
        }
        return integer(value)
    }

    /// 将字节数格式化为二进制容量单位；内存和磁盘容量展示时调用。
    /// 容量使用 1024 进位的 KiB/MiB/GiB，与速率的十进制单位明确区分。
    static func memory(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        let units = [(1_073_741_824.0, "GiB"), (1_048_576.0, "MiB"), (1_024.0, "KiB")]
        for (scale, unit) in units where value >= scale {
            return "\(compact(value / scale)) \(unit)"
        }
        return "\(integer(value)) B"
    }

    /// 将百分比格式化为整数文本；总 CPU 和内存用量展示时调用。
    static func percent(_ percentage: Double) -> String {
        "\(integer(nonNegativeFinite(percentage)))%"
    }

    /// 将进程百分比保留一位小数；CPU 进程榜单展示时调用。
    static func processPercent(_ percentage: Double) -> String {
        let value = nonNegativeFinite(percentage)
        let rounded = value <= Double.greatestFiniteMagnitude / 10 ? (value * 10).rounded() / 10 : value
        return String(format: "%.1f%%", rounded)
    }

    /// 将风扇转速格式化为 RPM；传感器卡片展示时调用。
    static func rpm(_ revolutionsPerMinute: Double) -> String {
        "\(integer(nonNegativeFinite(revolutionsPerMinute))) RPM"
    }

    /// 生成最多一位小数的紧凑数字；容量与速率格式化内部调用。
    private static func compact(_ value: Double) -> String {
        guard value <= Double.greatestFiniteMagnitude / 10 else { return integer(value) }
        let rounded = (value * 10).rounded() / 10
        return rounded.rounded(.towardZero) == rounded ? integer(rounded) : String(format: "%.1f", rounded)
    }

    /// 安全地生成整数文本；所有整数型指标格式化内部调用。
    /// 转换前检查有限性和 Int64 上界，避免浮点到整数转换触发运行时陷阱。
    private static func integer(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = value.rounded()
        guard rounded > 0 else { return "0" }
        guard rounded < Double(Int64.max) else { return "9223372036854775807" }
        return String(Int64(rounded))
    }

    /// 将负数及非有限值归零；格式化外部采集值前调用以避免异常文本。
    private static func nonNegativeFinite(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}
