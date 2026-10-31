// Presentation only. Unknown helper evidence is neither a granted permission nor a failure.
import Foundation

nonisolated struct PermissionsOverview {
    enum Item: CaseIterable, Identifiable {
        case fullDisk, screenRecording, computerUse, overnightWake, voice, notifications
        var id: Self { self }
    }
    enum State { case granted, needsAttention, unverified, optional, notNeeded }
    let states: [Item: State]

    init(hasProtectedSources: Bool, protectedSourcesReadable: Bool, screenGranted: Bool,
         helperInstalled: Bool, helperVerified: Bool, helperProblem: Bool,
         overnightRequested: Bool, wakeReady: Bool, voiceGranted: Bool, notificationsGranted: Bool) {
        states = [
            .fullDisk: !hasProtectedSources ? .notNeeded : protectedSourcesReadable ? .granted : .needsAttention,
            .screenRecording: screenGranted ? .granted : .needsAttention,
            .computerUse: !helperInstalled ? .notNeeded : helperProblem ? .needsAttention : helperVerified ? .granted : .unverified,
            .overnightWake: !overnightRequested ? .notNeeded : wakeReady ? .granted : .needsAttention,
            .voice: voiceGranted ? .granted : .optional,
            .notifications: notificationsGranted ? .granted : .optional,
        ]
    }

    var visible: [Item] { Item.allCases.filter { states[$0] == .needsAttention || states[$0] == .unverified } }
    var granted: [Item] { Item.allCases.filter { states[$0] == .granted } }
    var optional: [Item] { Item.allCases.filter { states[$0] == .optional } }

    static func shouldOpenTroubleshooting(connectionProblem: Bool, sourceProblem: Bool,
                                          helperProblem: Bool, runtimeMissing: Bool) -> Bool {
        connectionProblem || sourceProblem || helperProblem || runtimeMissing
    }
}
