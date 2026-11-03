import Foundation

struct SparklineHoverPosition {
    private let location: CGPoint

    /// 保存当前鼠标位置；折线图连续悬停事件更新时调用。
    init(location: CGPoint) {
        self.location = location
    }

    /// 将图内横坐标映射为时间；查找距离鼠标最近的历史点前调用。
    /// 以绘图区内的归一化 x 比例在线性时间域插值；零宽或指针越界直接返回 nil。
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

    /// 计算不会越过绘图区左右边界的提示框位置；选中悬停点后调用。
    /// 提示框最大宽 108 点，优先放在数据点另一侧，最终按半宽钳制中心坐标。
    init(pointX: CGFloat, plotFrame: CGRect) {
        width = min(108, max(0, plotFrame.width))
        let halfWidth = width / 2
        let proposed = pointX <= plotFrame.midX
            ? pointX + halfWidth + 8
            : pointX - halfWidth - 8
        centerX = min(max(proposed, plotFrame.minX + halfWidth), plotFrame.maxX - halfWidth)
    }
}
