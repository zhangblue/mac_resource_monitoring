import Foundation

enum SparklineAxisKind: Equatable {
    case percentage
    case rate
}

struct SparklineAxisPresentation: Equatable {
    let domain: ClosedRange<Double>
    let ticks: [Double]
    let labels: [String]

    init?(values: [Double], kind: SparklineAxisKind) {
        let finite = values.filter(\.isFinite)
        guard let minimum = finite.min(), let maximum = finite.max() else { return nil }

        switch kind {
        case .percentage:
            let bounds = Self.percentageBounds(minimum: minimum, maximum: maximum)
            domain = bounds.lower...bounds.upper
            ticks = [bounds.lower, (bounds.lower + bounds.upper) / 2, bounds.upper]
            labels = ticks.map { MetricFormatter.percent($0 * 100) }
        case .rate:
            let bounds = Self.rateBounds(minimum: max(0, minimum), maximum: max(0, maximum))
            domain = bounds.lower...bounds.upper
            ticks = [bounds.lower, (bounds.lower + bounds.upper) / 2, bounds.upper]
            labels = Self.rateLabels(for: ticks, upperBound: bounds.upper)
        }
    }

    private static func percentageBounds(minimum: Double, maximum: Double) -> (lower: Double, upper: Double) {
        let boundedMinimum = min(1, max(0, minimum))
        let boundedMaximum = min(1, max(0, maximum))
        let span = min(1, max(0.10, (boundedMaximum - boundedMinimum) * 1.2))
        let center = (boundedMinimum + boundedMaximum) / 2
        var lower = center - span / 2
        var upper = center + span / 2

        if lower < 0 {
            upper = min(1, upper - lower)
            lower = 0
        }
        if upper > 1 {
            lower = max(0, lower - (upper - 1))
            upper = 1
        }
        return (lower, upper)
    }

    private static func rateBounds(minimum: Double, maximum: Double) -> (lower: Double, upper: Double) {
        let midpoint = (minimum + maximum) / 2
        let dataSpan = maximum - minimum
        let targetSpan = max(dataSpan * 1.2, abs(midpoint) * 0.2, 1024)
        let padding = (targetSpan - dataSpan) / 2
        let paddedMinimum = max(0, minimum - padding)
        let paddedMaximum = maximum + padding
        var step = niceStep(atLeast: targetSpan / 2)
        var lower = floor(paddedMinimum / step) * step
        var upper = lower + 2 * step

        while upper < paddedMaximum {
            step = niceStep(atLeast: step * 1.01)
            lower = floor(paddedMinimum / step) * step
            upper = lower + 2 * step
        }
        lower = max(0, lower)
        return (lower, upper)
    }

    private static func niceStep(atLeast value: Double) -> Double {
        let magnitude = pow(10, floor(log10(value)))
        let fraction = value / magnitude
        let niceFraction: Double
        if fraction <= 1 {
            niceFraction = 1
        } else if fraction <= 2 {
            niceFraction = 2
        } else if fraction <= 5 {
            niceFraction = 5
        } else {
            niceFraction = 10
        }
        return niceFraction * magnitude
    }

    private static func rateLabels(for ticks: [Double], upperBound: Double) -> [String] {
        let (scale, unit): (Double, String)
        if upperBound >= 1_000_000_000 {
            (scale, unit) = (1_000_000_000, "GB/s")
        } else if upperBound >= 1_000_000 {
            (scale, unit) = (1_000_000, "MB/s")
        } else if upperBound >= 1_000 {
            (scale, unit) = (1_000, "KB/s")
        } else {
            (scale, unit) = (1, "B/s")
        }
        return ticks.map { "\(Self.compact($0 / scale)) \(unit)" }
    }

    private static func compact(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.rounded(.towardZero) == rounded ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
