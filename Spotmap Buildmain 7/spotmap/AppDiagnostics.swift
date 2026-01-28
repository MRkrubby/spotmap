import Foundation
import os

// C-compatible exception handler must not capture Swift context.
private func AppDiagnosticsUncaughtExceptionHandler(_ exception: NSException) -> Void {
    // Use a static logger that doesn't require capturing from surrounding scope.
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "spotmap", category: "App")
    let reason = exception.reason ?? ""
    logger.fault("Uncaught NSException: \(exception.name.rawValue, privacy: .public) \(reason, privacy: .public)")
}

/// Small diagnostics utilities to help catch "black screen" style crashes.
///
/// This intentionally avoids heavy/complex crash reporting dependencies.
enum AppDiagnostics {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "spotmap", category: "App")

    static func setup() {
        log.info("SpotMap launching")

        // Log unexpected Objective‑C exceptions (rare in SwiftUI apps but still possible).
        NSSetUncaughtExceptionHandler(AppDiagnosticsUncaughtExceptionHandler)

        // Helpful in Xcode console to ensure we reached here.
        #if DEBUG
        print("[SpotMap] AppDiagnostics.setup() OK")
        #endif
    }
}

