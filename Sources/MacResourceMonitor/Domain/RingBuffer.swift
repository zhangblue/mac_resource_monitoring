struct RingBuffer<Element> {
    private var storage: [Element?]
    private var writeIndex = 0
    private(set) var count = 0

    /// 创建固定容量环形缓冲区；历史记录初始化或调整窗口后重建缓冲区时调用。
    /// 底层预分配可选元素数组，后续追加不再扩容；容量必须大于零以保证取模写指针有效。
    init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be greater than zero")
        storage = Array(repeating: nil, count: capacity)
    }

    /// 返回缓冲区容量；历史裁剪和测试容量边界时读取。
    var capacity: Int { storage.count }

    /// 按时间写入顺序导出有效元素；界面绘图或调整历史窗口时读取。
    /// 满载时从写指针（最旧元素）开始循环展开，时间复杂度 O(n)，返回数组与内部存储互不共享。
    var elements: [Element] {
        guard count > 0 else { return [] }
        let start = count == capacity ? writeIndex : 0
        return (0..<count).compactMap { offset in
            storage[(start + offset) % capacity]
        }
    }

    /// 追加一个元素并在满容量后覆盖最旧值；每轮采样写入历史数据时调用。
    /// 写入和索引推进均为 O(1)，count 饱和后保持容量不变。
    mutating func append(_ element: Element) {
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        count = min(count + 1, capacity)
    }

    /// 清空并按顺序装入一组元素；历史窗口缩短或重新裁剪后调用。
    /// 先重置索引再复用 append 的覆盖语义，因此输入超过容量时仍只保留最新元素。
    mutating func replaceContents<S: Sequence>(with elements: S) where S.Element == Element {
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
        for element in elements { append(element) }
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
