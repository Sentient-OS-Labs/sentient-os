// Applies repeat retention only to SDK app-hang events; crashes and other exceptions pass through.
// Normalizes stack addresses against image UUIDs so ASLR does not create a fresh daily allowance.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import Foundation
import Sentry

nonisolated enum SentryHangPolicy {
    static func apply(_ event: Event, identity: String, release: String,
                      budget: DiagnosticEventBudget = .shared, now: Date = Date()) -> Event? {
        guard let exceptions = event.exceptions, exceptions.count == 1,
              let exception = exceptions.first, exception.mechanism?.type == "AppHang",
              exception.type == "App Hanging", event.level != .fatal else { return event }
        let frames = exception.stacktrace?.frames ?? event.threads?.first(where: { $0.isMain?.boolValue == true })?.stacktrace?.frames ?? []
        guard let signature = signature(frames: frames, images: event.debugMeta ?? []) else { return event }
        let decision = budget.claim(signature: "hang:" + signature, release: event.releaseName ?? release,
                                    identity: identity, now: now)
        guard decision.allowed else { return nil }
        var extra = event.extra ?? [:]
        extra["reporting_policy"] = "hang_signature_daily_v1"
        extra["reporting_daily_limit"] = DiagnosticEventBudget.dailyLimit
        extra["suppressed_since_last_report"] = decision.suppressed
        event.extra = extra
        return event
    }

    static func signature(frames: [Frame], images: [DebugMeta]) -> String? {
        let byAddress = Dictionary(images.compactMap { image -> (UInt64, String)? in
            guard let base = image.imageAddress.flatMap(address), let id = image.debugID ?? image.uuid,
                  let uuid = UUID(uuidString: id) else { return nil }
            return (base, uuid.uuidString)
        }, uniquingKeysWith: { first, _ in first })
        let normalized = frames.suffix(32).compactMap { frame -> String? in
            if let baseText = frame.imageAddress,
               let base = address(baseText), let image = byAddress[base],
               let instruction = frame.instructionAddress.flatMap(address), instruction >= base {
                let symbol = frame.symbolAddress.flatMap(address)
                let position = symbol.flatMap { $0 >= base && $0 <= instruction ? $0 : nil } ?? instruction
                return image + ":" + String(position - base, radix: 16)
            }
            if let function = frame.function, !function.isEmpty,
               let module = frame.module ?? frame.package, !module.isEmpty {
                return URL(fileURLWithPath: module).lastPathComponent + ":" + function
            }
            return nil
        }
        // Incomplete attribution must not turn unrelated unknown hangs into one shared bucket.
        guard !frames.isEmpty, normalized.count == min(frames.count, 32) else { return nil }
        return DiagnosticEventBudget.digest(normalized.joined(separator: "\n"))
    }

    private static func address(_ value: String) -> UInt64? {
        UInt64(value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value, radix: 16)
    }
}
