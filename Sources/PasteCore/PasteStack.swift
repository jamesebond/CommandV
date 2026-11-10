import Foundation

public struct PasteStack: Sendable {
    private var queue: [Clip] = []
    public init() {}
    public var isActive: Bool { !queue.isEmpty }
    public var count: Int { queue.count }
    public mutating func push(_ clip: Clip) { queue.append(clip) }
    public func peekNext() -> Clip? { queue.first }
    public mutating func popNext() -> Clip? { queue.isEmpty ? nil : queue.removeFirst() }
    /// Drops queued clips whose id is in `clipIDs`. Returns how many were removed.
    @discardableResult
    public mutating func remove(clipIDs: Set<Int64>) -> Int {
        let before = queue.count
        queue.removeAll { clipIDs.contains($0.id) }
        return before - queue.count
    }
    public var clipIDs: [Int64] { queue.map(\.id) }
    public mutating func clear() { queue.removeAll() }
}
