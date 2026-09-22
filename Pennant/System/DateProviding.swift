import Foundation

public protocol DateProviding: Sendable {
    var now: Date { get }
}

public struct SystemDateProvider: DateProviding, Sendable {
    public init() {}
    public var now: Date { Date() }
}

public final class FakeDateProvider: DateProviding, @unchecked Sendable {
    public var now: Date
    public init(_ now: Date) { self.now = now }
}

public protocol SchedulerProtocol: Sendable {
    func schedule(after interval: TimeInterval, id: String, work: @escaping @Sendable () -> Void)
    func cancel(id: String)
    func cancelAll()
}

public final class ImmediateScheduler: SchedulerProtocol, @unchecked Sendable {
    private var workItems: [String: () -> Void] = [:]
    private var intervals: [String: TimeInterval] = [:]
    private let lock = NSLock()

    public init() {}

    public func schedule(after interval: TimeInterval, id: String, work: @escaping @Sendable () -> Void) {
        lock.lock()
        workItems[id] = work
        intervals[id] = interval
        lock.unlock()
    }

    public func cancel(id: String) {
        lock.lock()
        workItems.removeValue(forKey: id)
        intervals.removeValue(forKey: id)
        lock.unlock()
    }

    public func cancelAll() {
        lock.lock()
        workItems.removeAll()
        intervals.removeAll()
        lock.unlock()
    }

    public func fire(id: String) {
        lock.lock()
        let work = workItems.removeValue(forKey: id)
        intervals.removeValue(forKey: id)
        lock.unlock()
        work?()
    }

    public func scheduledInterval(id: String) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return intervals[id]
    }

    public func fireAll() {
        lock.lock()
        let all = workItems
        workItems.removeAll()
        intervals.removeAll()
        lock.unlock()
        for (_, work) in all { work() }
    }
}
