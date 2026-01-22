import Foundation

final class Debouncer {
    private var task: Task<Void, Never>?

    /// Run `action` after `delay`, cancelling any previously scheduled action.
    ///
    /// Note: we intentionally keep this type non-actor-isolated to avoid
    /// launch-time crashes caused by actor isolation checks when SwiftUI
    /// constructs views off the main thread.
    func schedule(delay: Duration, _ action: @escaping () async -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await action()
        }
    }
}
