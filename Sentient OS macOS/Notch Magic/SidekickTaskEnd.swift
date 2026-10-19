// Fixed-vocabulary task endings, independent of whether a usage phrase is available.
// Text classifiers consume content locally; only the category and its evidence leave the Mac.

import Foundation

nonisolated struct SidekickTaskEnd: Sendable, Equatable {
    enum StopCause: Sendable, Equatable {
        case user, recoveryExpired, offline
    }
    enum Reason: String, Sendable {
        case none, unknown
        case userStop = "user_stop", recoveryExpired = "recovery_expired"
        case setupCancelled = "setup_cancelled", cancelledUnknown = "cancelled_unknown"
        case offline, timeout, permission, connection
        case loginRequired = "login_required", usageLimit = "usage_limit", planDenied = "plan_denied"
        case backendUnavailable = "backend_unavailable", launchFailed = "launch_failed"
        case staleClient = "stale_client", processFailed = "process_failed", providerError = "provider_error"
        case invalidOutput = "invalid_output", inputTooLarge = "input_too_large"
        case completionUnconfirmed = "completion_unconfirmed", modelCouldNot = "model_could_not"
        case appUnavailable = "app_unavailable", staleTarget = "stale_target"
        case screenCapture = "screen_capture"
        case invalidArguments = "invalid_arguments", unavailableTool = "unavailable_tool"
        case toolWhileWaiting = "tool_while_waiting"
    }
    enum Evidence: String, Sendable {
        case none, unknown, app
        case typedError = "typed_error", errorText = "error_text", modelReport = "model_report"
    }
    struct Failure: Sendable, Equatable {
        let reason: Reason
        let evidence: Evidence

        static let unconfirmed = Self(reason: .completionUnconfirmed, evidence: .app)
        static let setupCancelled = Self(reason: .setupCancelled, evidence: .app)

        static func modelReport(_ text: String) -> Self {
            Self(reason: textReason(text) ?? .modelCouldNot, evidence: .modelReport)
        }

        static func error(_ error: Error) -> Self {
            func typed(_ reason: Reason) -> Self { Self(reason: reason, evidence: .typedError) }
            func classified(_ text: String, fallback: Reason) -> Self {
                // Bound provider output before classification and never retain it in this value.
                let text = String(text.prefix(8192))
                let reason: Reason?
                switch CodexFailureReason.classify(text: text) {
                case .notLoggedIn, .tokenExpired, .refreshFailed: reason = .loginRequired
                case .usageLimit: reason = .usageLimit
                case .planDenied: reason = .planDenied
                case .modelNotFound: reason = .backendUnavailable
                case .dns, .tls, .streamDisconnect, .connectTimeout: reason = .connection
                case .http403, .sandboxDenied: reason = .permission
                case .http5xx: reason = .providerError
                case .timeoutOurs: reason = .timeout
                case .staleClient: reason = .staleClient
                case .spawnFailed: reason = .launchFailed
                case .screenCapture: reason = .screenCapture
                case .noWindows: reason = .appUnavailable
                case .notInstalled: reason = .backendUnavailable
                case .unknown: reason = textReason(text)
                }
                return reason.map { Self(reason: $0, evidence: .errorText) } ?? typed(fallback)
            }
            if error is CancellationError { return typed(.cancelledUnknown) }
            if let native = error as? NativeComputerUseFailure {
                switch native.kind {
                case .capture: return typed(.screenCapture)
                case .noWindows: return typed(.appUnavailable)
                case .permission: return typed(.permission)
                case .connection: return typed(.connection)
                case .timeout: return typed(.timeout)
                case .unknown: return typed(.unknown)
                }
            }
            if error is ComputerUseGate.SetupCancelled { return .setupCancelled }
            if error is SidekickInteraction.Failure { return typed(.toolWhileWaiting) }
            if error is SlackActionEvidence.Failure || error is OutlookActionEvidence.Failure
                || error is OutlookCalendarActionEvidence.Failure { return .unconfirmed }
            if error is CodexRuntime.Failure { return typed(.backendUnavailable) }
            if let error = error as? MCPSource.MCPError {
                switch error {
                case .noReadSurface: return typed(.unavailableTool)
                case .connectionChanged: return typed(.connection)
                case .invalidResponse: return typed(.invalidOutput)
                // These wrappers describe the model's report, not an independently verified login.
                case .connectorAuth: return Self(reason: .loginRequired, evidence: .modelReport)
                case .toolFailure: return Self(reason: .modelCouldNot, evidence: .modelReport)
                default: return typed(.unknown)
                }
            }
            if let error = error as? CodexCLI.CLIError {
                switch error {
                case .timedOut: return typed(.timeout)
                case .usageLimit: return typed(.usageLimit)
                case .launchFailed: return typed(.launchFailed)
                case .staleClient: return typed(.staleClient)
                case .badEnvelope: return typed(.invalidOutput)
                case .inputTooLarge: return typed(.inputTooLarge)
                case .notAvailable(.notWorking(let detail)): return classified(detail, fallback: .backendUnavailable)
                case .notAvailable: return typed(.backendUnavailable)
                case .exitFailure(_, let message): return classified(message, fallback: .processFailed)
                }
            }
            if let error = error as? DirectMCPError {
                switch error {
                case .timedOut: return typed(.timeout)
                case .reconnectRequired, .registrationExpired, .accountSetupRequired: return typed(.loginRequired)
                case .authorizationDenied, .keychain: return typed(.permission)
                case .network, .connectionChanged: return typed(.connection)
                case .noTools, .policyUnavailable: return typed(.unavailableTool)
                case .invalidMetadata, .invalidCallback, .invalidResponse, .tooLarge: return typed(.invalidOutput)
                case .unsupportedProvider, .unsupportedRegistration: return typed(.backendUnavailable)
                case .unconfirmedAction: return .unconfirmed
                case .http(let code):
                    switch code {
                    case 401: return typed(.loginRequired)
                    case 403: return typed(.permission)
                    case 429: return typed(.usageLimit)
                    default: return typed(.providerError)
                    }
                case .busy, .duplicateLabel: return typed(.unknown)
                }
            }
            if let error = error as? OpenAIComputerUse.RuntimeError {
                switch error {
                case .permissionRequired: return typed(.permission)
                case .launchFailed: return typed(.launchFailed)
                default: return typed(.backendUnavailable)
                }
            }
            if let error = error as? URLError {
                switch error.code {
                case .cancelled: return typed(.cancelledUnknown)
                case .timedOut: return typed(.timeout)
                case .notConnectedToInternet: return typed(.offline)
                case .userAuthenticationRequired: return typed(.loginRequired)
                case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
                     .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: return typed(.connection)
                default: return typed(.unknown)
                }
            }
            return Self(reason: .unknown, evidence: .unknown)
        }

        private static func textReason(_ text: String) -> Reason? {
            switch AgentRunDiagnostics.Reason.classify(text) {
            case .appUnavailable: .appUnavailable
            case .screenCapture: .screenCapture
            case .noWindows: .appUnavailable
            case .staleTarget: .staleTarget
            case .permission: .permission
            case .authentication: .loginRequired
            case .quota: .usageLimit
            case .timeout: .timeout
            case .connection: .connection
            case .invalidArguments: .invalidArguments
            case .unavailableTool: .unavailableTool
            case .outputSchema: .invalidOutput
            // A model's mention of cancellation does not prove the user pressed Stop.
            case .cancelled, .unknown: nil
            }
        }
    }

    let outcome: CommandRunModel.Outcome
    let reason: Reason
    let evidence: Evidence

    /// A cancellation we initiated wins over the backend's later exit or late DONE sentinel.
    /// Callers latch the FIRST stop cause, so dismissing offline recovery cannot rewrite it.
    init(outcome: CommandRunModel.Outcome, stop: StopCause? = nil, failure: Failure? = nil) {
        if let stop {
            self.outcome = stop == .offline ? .failed : .stopped
            self.reason = switch stop {
            case .user: .userStop
            case .recoveryExpired: .recoveryExpired
            case .offline: .offline
            }
            self.evidence = .app
        } else {
            self.outcome = outcome
            let detail: Failure = switch outcome {
            case .success: Failure(reason: .none, evidence: .none)
            case .stopped: failure ?? Failure(reason: .cancelledUnknown, evidence: .unknown)
            case .failed: failure ?? Failure(reason: .unknown, evidence: .unknown)
            }
            self.reason = detail.reason; self.evidence = detail.evidence
        }
    }

    var parameters: [String: String] {
        ["outcome": outcome.rawValue, "interruption_reason": reason.rawValue,
         "interruption_evidence": evidence.rawValue, "interruption_version": "1"]
    }
}
