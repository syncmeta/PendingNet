import Foundation

/// All callers join the same migration. A failed migration stays retryable.
@MainActor
public final class PendingNetHelperRecovery {
    private var flight: Task<Bool, Never>?
    public init() {}
    public func run(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        if let flight { return await flight.value }
        let task = Task { @MainActor in await operation() }
        flight = task
        let result = await task.value
        flight = nil
        return result
    }
}

/// A replaced XPC connection must not invalidate its successor.
public struct PendingNetHelperConnectionState: Sendable {
    public private(set) var current: UUID?
    public init() {}
    public mutating func attach() -> UUID {
        let id = UUID(); current = id; return id
    }
    public func isCurrent(_ id: UUID) -> Bool { current == id }
    @discardableResult
    public mutating func invalidate(_ id: UUID) -> Bool {
        guard isCurrent(id) else { return false }
        current = nil
        return true
    }
    public mutating func clear() { current = nil }
}

/// A timeout or failed cleanup may be logged, but cannot veto app termination.
@MainActor
public final class PendingNetTerminationGate {
    private var completed = false
    public init() {}
    public func finish() -> Bool {
        guard !completed else { return false }
        completed = true
        return true
    }
}
