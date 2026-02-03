import Foundation

/// Simple async timeout helper.
///
/// Cancels the underlying task if the timeout wins the race.
func withTimeout<T>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let ns = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)
            throw TimeoutError(seconds: seconds)
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct TimeoutError: LocalizedError {
    let seconds: Double

    var errorDescription: String? {
        "Timeout na \(Int(seconds)) seconden. Probeer het opnieuw."
    }
}
