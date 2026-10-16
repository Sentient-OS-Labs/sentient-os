// Converts explicitly failed native replies into content-free error evidence.
// Preserves native/RPC codes and known failure cases, never app text or arbitrary error messages.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import Foundation

nonisolated struct NativeComputerUseFailure: LocalizedError, Sendable, Equatable {
    enum Kind: String, Sendable { case capture, noWindows = "no_windows", permission, connection, timeout, unknown }
    enum Stage: String, Sendable { case initialize, thread, catalog, transport, appState = "app_state", imageDecode = "image_decode", action, recovery, probe }
    enum Detail: String, Sendable, CaseIterable {
        case unspecified, screenshotCaptureFailed, screenCaptureFailed, unknownCaptureFailed, noWindowsAvailable
        case timeoutReached, senderNotAuthenticated, approvalDenied, permissionDenied, disconnected
        case windowNotFoundForID, windowNotFoundAtPosition, failedToGetWindowIDForElement
        case blockedByPolicy, missingImage, invalidImage, malformedResponse, responseTooLarge
        case unexpectedEOF, processExited, requestTimedOut, unexpectedRequest, launchFailed, writeFailed
        case staleState, recoveryExhausted, ambiguousTarget, targetUnavailable, recoveryTimedOut, concurrentCall
        case imageEncodingFailed, displayUnavailable, invalidArguments, testWindowNotObserved
    }
    let kind: Kind
    let code: Int?
    var detail: Detail = .unspecified
    var stage: Stage = .appState
    var rpcCode: Int?
    var systemDomain: String?
    var systemCode: Int?
    var exitCode: Int?
    var stderrDetail: Detail?
    var stderrCode: Int?

    var fields: [String: String] {
        var fields = ["native_kind": kind.rawValue, "native_detail": detail.rawValue,
                      "failure_stage": stage.rawValue, "native_code_present": String(code != nil),
                      "underlying_error_available": String(detail != .unspecified || systemCode != nil),
                      "error_domain": "native_computer_use"]
        if let code { fields["native_error_code"] = String(code); fields["error_code"] = String(code) }
        if let rpcCode { fields["rpc_error_code"] = String(rpcCode) }
        if let systemDomain { fields["system_error_domain"] = systemDomain }
        if let systemCode { fields["system_error_code"] = String(systemCode) }
        if let exitCode { fields["exit_code"] = String(exitCode) }
        if let stderrDetail { fields["stderr_detail"] = stderrDetail.rawValue; fields["stderr_evidence"] = "text_hint" }
        if let stderrCode { fields["stderr_native_code"] = String(stderrCode) }
        return fields
    }

    mutating func recordSystemError(_ error: Error) {
        let error = error as NSError
        systemDomain = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSURLErrorDomain].contains(error.domain)
            ? error.domain : "application"
        systemCode = error.code
    }

    var errorDescription: String? {
        switch kind {
        case .capture: "Sidekick couldn’t capture the app’s window. Open Permissions & Health and choose Check app control, then try again."
        case .noWindows: "Sidekick couldn’t find a readable window. Keep the app open on your current desktop, then try again."
        case .permission: "Computer use could not access the app. Check its permissions in Permissions & Health."
        case .connection: "Computer use lost its connection. Finish active tasks, then restart computer use in Permissions & Health."
        case .timeout: "Computer use took too long to read the window. Open Permissions & Health and choose Check app control."
        case .unknown: "Computer use could not complete the check. Try again in Permissions & Health."
        }
    }
    var allowsWindowRecovery: Bool {
        [.appState, .imageDecode].contains(stage) && [.capture, .noWindows, .timeout, .unknown].contains(kind)
            && ![.blockedByPolicy, .malformedResponse, .responseTooLarge, .requestTimedOut, .invalidArguments].contains(detail)
    }
    static func isError(_ result: [String: Any]) -> Bool {
        result["isError"] as? Bool == true || result["is_error"] as? Bool == true || result["error"] is [String: Any] || result["error"] is String
    }
    static func from(item: [String: Any]) -> Self? {
        guard item["type"] as? String == "mcp_tool_call", item["server"] as? String == "sentient_native" else { return nil }
        let result = item["result"] as? [String: Any] ?? [:]
        guard item["status"] as? String == "failed" || item["error"] is String || item["error"] is [String: Any] || isError(result) else { return nil }
        return classify(["error": item["error"] ?? [:], "result": result],
                        stage: item["tool"] as? String == "get_app_state" ? .appState : .action)
    }

    /// Traversal is limited to protocol error envelopes, including nested data/structuredContent.
    /// Strings are inspected transiently against a closed vocabulary and discarded.
    static func classify(_ value: Any, stage: Stage = .appState) -> Self {
        var texts: [String] = [], codes: [Int] = []
        let domains = ["SCStreamErrorDomain", "com.apple.ScreenCaptureKit.SCStreamErrorDomain", "NSOSStatusErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain"]
        var structuredDomain: String?, structuredCode: Int?
        func read(_ value: Any, depth: Int) {
            guard depth < 7, texts.count < 16 else { return }
            if let string = value as? String {
                let bounded = String(string.prefix(8192)); texts.append(bounded)
                if let data = bounded.data(using: .utf8), let nested = try? JSONSerialization.jsonObject(with: data) {
                    read(nested, depth: depth + 1)
                }
                return
            }
            guard let object = value as? [String: Any] else { return }
            if let domain = object["domain"] as? String, domains.contains(domain) {
                structuredDomain = domain; structuredCode = object["code"] as? Int
            } else if let code = object["code"] as? Int { codes.append(code) }
            for key in ["message", "error", "result", "data", "structuredContent", "failureReason", "reason", "domain"] {
                if let nested = object[key] { read(nested, depth: depth + 1) }
            }
            if let text = object["content"] as? String { read(text, depth: depth + 1) }
            if let blocks = object["content"] as? [[String: Any]] {
                for block in blocks.prefix(8) where block["type"] as? String == "text" {
                    if let text = block["text"] as? String { read(text, depth: depth + 1) }
                }
            }
        }
        read(value, depth: 0)
        let text = String(texts.joined(separator: "\n").prefix(32768)), lower = text.lowercased()
        func number(_ pattern: String) -> Int? {
            guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }
        let nativeCode = number(#"Computer Use server error (-?[0-9]{1,9}):"#)
        var detail = Detail.allCases.first { $0 != .unspecified && lower.contains($0.rawValue.lowercased()) } ?? .unspecified
        if lower.contains("sender process is not authenticated") { detail = .senderNotAuthenticated }
        else if lower.contains("approval denied") || lower.contains("elicitation") { detail = .approvalDenied }
        else if lower.contains("could not create image from display") { detail = .displayUnavailable }
        else if lower.contains("invalid argument") || lower.contains("invalid parameter") { detail = .invalidArguments }
        else if lower.contains("screen capture failed") || lower.contains("screenshot capture failed") { detail = .screenshotCaptureFailed }
        let kind: Kind
        switch detail {
        case .screenshotCaptureFailed, .screenCaptureFailed, .unknownCaptureFailed, .missingImage, .invalidImage, .imageEncodingFailed, .displayUnavailable: kind = .capture
        case .noWindowsAvailable, .windowNotFoundForID, .windowNotFoundAtPosition, .failedToGetWindowIDForElement: kind = .noWindows
        case .senderNotAuthenticated, .approvalDenied, .permissionDenied, .blockedByPolicy: kind = .permission
        case .timeoutReached, .requestTimedOut: kind = .timeout
        case .disconnected, .unexpectedEOF, .processExited, .writeFailed: kind = .connection
        default:
            if lower.contains("permission") || lower.contains("not authorized") { kind = .permission; detail = .permissionDenied }
            else if lower.contains("connection") || lower.contains("disconnected") { kind = .connection; detail = .disconnected }
            else if lower.contains("timed out") || lower.contains("timeout") { kind = .timeout }
            else { kind = .unknown }
        }
        var failure = Self(kind: kind, code: nativeCode ?? codes.first(where: { !(-32768 ... -32000).contains($0) }), detail: detail, stage: stage,
                           rpcCode: codes.first(where: { (-32768 ... -32000).contains($0) }),
                           systemDomain: structuredDomain, systemCode: structuredCode)
        for domain in domains where failure.systemDomain == nil && text.contains(domain) {
            failure.systemDomain = domain
            failure.systemCode = number(NSRegularExpression.escapedPattern(for: domain) + #"[^\n]{0,40}?Code[= :](-?[0-9]{1,9})"#)
            break
        }
        return failure
    }
}
