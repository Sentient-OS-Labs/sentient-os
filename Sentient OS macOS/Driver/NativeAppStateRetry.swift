import Foundation

/// Read-only grace for an app whose window is still opening or becoming capturable.
/// Actions, authorization failures and broken transport/protocol contracts never qualify.
nonisolated enum NativeAppStateRetry {
    static let delays: [TimeInterval] = [2, 3, 5]
    static let timeout: TimeInterval = 90

    static func delay(afterAttempt attempt: Int, failure: NativeComputerUseFailure,
                      elapsed: TimeInterval) -> TimeInterval? {
        guard (1...delays.count).contains(attempt), elapsed.isFinite, elapsed >= 0,
              failure.stage == .appState || failure.stage == .imageDecode else { return nil }
        switch failure.detail {
        case .timeoutReached, .noWindowsAvailable, .windowNotFoundForID,
             .windowNotFoundAtPosition, .failedToGetWindowIDForElement,
             .screenshotCaptureFailed, .screenCaptureFailed, .unknownCaptureFailed:
            break
        default: return nil
        }
        guard failure.kind == .timeout || failure.kind == .noWindows || failure.kind == .capture,
              elapsed + delays[attempt - 1] < timeout else { return nil }
        return delays[attempt - 1]
    }
}
