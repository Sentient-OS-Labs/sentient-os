// Converts explicitly failed native replies into content-free error evidence.
// Preserves native/RPC codes and closed diagnostic cases. Explicit native errors
// retain a bounded model-only excerpt; no arbitrary text enters diagnostic fields.
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
        case focusChanged, inputInterrupted, elementUnavailable
        // Legacy diagnostic values only; no Chromium-specific runtime policy.
        case chromiumAppChanged, chromiumRecoveryExhausted
    }
    var kind: Kind
    let code: Int?
    var detail: Detail = .unspecified
    var stage: Stage = .appState
    var rpcCode: Int?
    var systemDomain: String?
    var systemCode: Int?
    var exitCode: Int?
    var stderrDetail: Detail?
    var stderrCode: Int?
    // A bounded tool-error excerpt for the model only. Never included in diagnostic fields.
    var modelError: String?
    // A transport error can occur after an action was dispatched; retain that fact
    // separately from the diagnostic stage without deciding how the agent proceeds.
    var actionEffectsUnconfirmed: Bool?

    var effectsMayBeUnknown: Bool { actionEffectsUnconfirmed ?? (stage == .action) }

    var modelGuidance: String {
        "This step did not complete as expected; it does not end the task. User clicks, typing or Space changes can interrupt computer use. Pause briefly, re-query the app with get_app_state and retry using fresh controls when appropriate. "
            + (effectsMayBeUnknown ? "The previous action's effects may be unknown; verify whether it already succeeded before deciding whether to retry, to avoid duplicate changes." : "No action was automatically retried.")
            + " If typing was interrupted, inspect and correct the existing field contents before sending. An interrupted interaction alone does not establish a missing macOS grant."
    }

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
        return switch kind {
        case .capture: "Sidekick couldn’t capture the app’s window. Check Screen Recording access in Permissions & Health, then try again."
        case .noWindows: "Sidekick couldn’t find a readable window. Keep the app open on your current desktop, then try again."
        case .permission: "Computer use could not access the app. Check its permissions in Permissions & Health."
        case .connection: "Computer use lost its connection. Try the task again."
        case .timeout: "Computer use took too long to read the window. Keep the app open on your current desktop, then try again."
        case .unknown: "Sidekick couldn’t complete this computer-use step."
        }
    }
    static func isError(_ result: [String: Any]) -> Bool {
        result["isError"] as? Bool == true || result["is_error"] as? Bool == true || result["error"] is [String: Any] || result["error"] is String
    }
    static func from(item: [String: Any]) -> Self? {
        guard item["type"] as? String == "mcp_tool_call", item["server"] as? String == "sentient_native" else { return nil }
        let result = item["result"] as? [String: Any] ?? [:]
        guard item["status"] as? String == "failed" || item["error"] is String || item["error"] is [String: Any] || isError(result) else { return nil }
        // The failed-event guard above is the error signal. Codex may emit error:null
        // and omit isError from result while retaining status:failed and metadata.
        var failure = classify(["isError": true, "error": item["error"] ?? NSNull(), "result": result],
                               stage: item["tool"] as? String == "get_app_state" ? .appState : .action)
        // This contract is produced by the native MCP boundary, never by successful
        // app content. Metadata is diagnostic only; it never decides whether a task continues.
        if let content = (result["structuredContent"] ?? result["structured_content"]) as? [String: Any],
           let evidence = content["sentient_native_failure"] as? [String: Any],
           evidence["version"] as? Int == 1,
           evidence["detail"] as? String == failure.detail.rawValue,
           let kind = (evidence["kind"] as? String).flatMap(Kind.init(rawValue:)),
           let stage = (evidence["stage"] as? String).flatMap(Stage.init(rawValue:)) {
            failure.kind = kind
            failure.stage = stage
            failure.actionEffectsUnconfirmed = evidence["effects_may_be_unknown"] as? Bool
        }
        return failure
    }

    /// Traversal is limited to protocol error envelopes, including nested data/structuredContent.
    /// Diagnostic classification uses a closed vocabulary. A bounded native error excerpt
    /// accompanies the tool reply for the agent, but is excluded from diagnostic fields.
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
        let boundaryDetail: Detail? = explicitError(value) ? texts.compactMap { text in
            // The boundary keeps the native header, full error and recovery guidance in
            // one text block because the model's failed-tool formatter keeps only the first.
            let line = text.components(separatedBy: .newlines).first ?? ""
            let pattern = #"\A(?:Native computer use failed: |Computer Use server error -?[0-9]{1,9}: )([A-Za-z]+)\z"#
            guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { return nil }
            return Detail(rawValue: String(line[range]))
        }.first : nil
        var detail = boundaryDetail ?? Detail.allCases.first { $0 != .unspecified && lower.contains($0.rawValue.lowercased()) } ?? .unspecified
        if boundaryDetail == nil {
            if lower.contains("sender process is not authenticated") { detail = .senderNotAuthenticated }
            else if lower.contains("approval denied") || lower.contains("elicitation") { detail = .approvalDenied }
            else if lower.contains("could not create image from display") { detail = .displayUnavailable }
            else if lower.contains("invalid argument") || lower.contains("invalid parameter") { detail = .invalidArguments }
            else if lower.contains("screen capture failed") || lower.contains("screenshot capture failed") { detail = .screenshotCaptureFailed }
            else if lower.contains("user changed the app") || lower.contains("user has changed the app")
                || lower.contains("focus changed") || lower.contains("lost focus") { detail = .focusChanged }
            else if lower.contains("typing interrupted") || lower.contains("typing was interrupted")
                || lower.contains("input interrupted") { detail = .inputInterrupted }
            else if lower.contains("element not found") || lower.contains("stale element") { detail = .elementUnavailable }
        }
        if detail == .unspecified {
            if codes.contains(where: { [-32700, -32600, -32601].contains($0) }) { detail = .malformedResponse }
            else if codes.contains(-32602) { detail = .invalidArguments }
        }
        let kind: Kind
        switch detail {
        case .screenshotCaptureFailed, .screenCaptureFailed, .unknownCaptureFailed, .missingImage, .invalidImage, .imageEncodingFailed, .displayUnavailable: kind = .capture
        case .noWindowsAvailable, .windowNotFoundForID, .windowNotFoundAtPosition, .failedToGetWindowIDForElement: kind = .noWindows
        case .senderNotAuthenticated, .approvalDenied, .permissionDenied, .blockedByPolicy: kind = .permission
        case .timeoutReached, .requestTimedOut: kind = .timeout
        case .disconnected, .unexpectedEOF, .processExited, .writeFailed, .malformedResponse: kind = .connection
        case .focusChanged, .inputInterrupted, .elementUnavailable, .staleState: kind = .unknown
        default:
            if lower.contains("permission") || lower.contains("not authorized") { kind = .permission; detail = .permissionDenied }
            else if lower.contains("connection") || lower.contains("disconnected") { kind = .connection; detail = .disconnected }
            else if lower.contains("timed out") || lower.contains("timeout") { kind = .timeout }
            else { kind = .unknown }
        }
        var failure = Self(kind: kind, code: nativeCode ?? codes.first(where: { !(-32768 ... -32000).contains($0) }), detail: detail, stage: stage,
                           rpcCode: codes.first(where: { (-32768 ... -32000).contains($0) }),
                           systemDomain: structuredDomain, systemCode: structuredCode)
        if explicitError(value) {
            failure.modelError = texts.first(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
            }).map { String(decoding: $0.utf8.prefix(2048), as: UTF8.self) }
        }
        for domain in domains where failure.systemDomain == nil && text.contains(domain) {
            failure.systemDomain = domain
            failure.systemCode = number(NSRegularExpression.escapedPattern(for: domain) + #"[^\n]{0,40}?Code[= :](-?[0-9]{1,9})"#)
            break
        }
        // SCError.h defines -3801 as the user declining screen capture. Unlike a text hint,
        // the exact OS domain/code is evidence for a permission fix, not a transient retry.
        if ["SCStreamErrorDomain", "com.apple.ScreenCaptureKit.SCStreamErrorDomain"].contains(failure.systemDomain ?? ""),
           failure.systemCode == -3801 {
            failure.kind = .permission; failure.detail = .permissionDenied
        }
        return failure
    }

    private static func explicitError(_ value: Any) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        if isError(object) { return true }
        if object["code"] is Int, object["message"] is String { return true }
        return (object["result"] as? [String: Any]).map(isError) ?? false
    }

}
