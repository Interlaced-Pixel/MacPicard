import Foundation

public enum BackgroundComputation {
    /// Detached CPU work with explicit cancellation propagation and a final
    /// cancellation gate before its result can be staged in the UI model.
    public static func run<Value: Sendable>(priority: TaskPriority = .userInitiated,
        _ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let worker = Task.detached(priority: priority, operation: operation)
        let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return value
    }
}
