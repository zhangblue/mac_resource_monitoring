struct RingBuffer<Element> {
    private var storage: [Element?]
    private var writeIndex = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be greater than zero")
        storage = Array(repeating: nil, count: capacity)
    }

    var capacity: Int { storage.count }

    var elements: [Element] {
        guard count > 0 else { return [] }
        let start = count == capacity ? writeIndex : 0
        return (0..<count).compactMap { offset in
            storage[(start + offset) % capacity]
        }
    }

    mutating func append(_ element: Element) {
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        count = min(count + 1, capacity)
    }

    mutating func replaceContents<S: Sequence>(with elements: S) where S.Element == Element {
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
        for element in elements { append(element) }
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
