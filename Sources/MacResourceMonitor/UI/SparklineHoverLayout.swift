import Foundation

struct SparklineHoverPosition {
    private let location: CGPoint

    init(location: CGPoint) {
        self.location = location
    }

    func timestamp(in timeDomain: ClosedRange<Date>, plotFrame: CGRect) -> Date? {
        guard plotFrame.width > 0, plotFrame.contains(location) else { return nil }
        let fraction = Double((location.x - plotFrame.minX) / plotFrame.width)
        return timeDomain.lowerBound.addingTimeInterval(
            timeDomain.upperBound.timeIntervalSince(timeDomain.lowerBound) * fraction
        )
    }
}

struct SparklineHoverTooltipLayout {
    let width: CGFloat
    let centerX: CGFloat

    init(pointX: CGFloat, plotFrame: CGRect) {
        width = min(108, max(0, plotFrame.width))
        let halfWidth = width / 2
        let proposed = pointX <= plotFrame.midX
            ? pointX + halfWidth + 8
            : pointX - halfWidth - 8
        centerX = min(max(proposed, plotFrame.minX + halfWidth), plotFrame.maxX - halfWidth)
    }
}
