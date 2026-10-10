// Standalone checks of actual invitation state; no app launch, network, or Keychain writes.
import Foundation

enum AppState { static let onboardingKey = "hasCompletedOnboarding" }

// Diagnostics are outside these offline invitation-state checks.
enum Diagnostics {
    enum BackgroundWork { case invite }
    enum Event { case serviceFailed }
    enum Phase { case refresh }
    static func backgroundRecovered(_ work: BackgroundWork) {}
    static func backgroundFailure(_ work: BackgroundWork) -> [String: Int]? { nil }
    static func report(_ event: Event, phase: Phase, reason: String, error: Error,
                       source: String, counts: [String: Int]) {}
}

@main struct InvitationStateTests {
    @MainActor static func main() {
        let name = "sentient.invitation.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let program = InviteProgram(defaults: defaults, loadCredential: false)
        program.record(.sidekick)
        precondition(!program.eligible, "Onboarding demos must not count")
        defaults.set(true, forKey: AppState.onboardingKey)
        program.record(.doubleTap)
        precondition(!program.eligible, "One successful draft is below threshold")
        let relaunched = InviteProgram(defaults: defaults, loadCredential: false)
        relaunched.record(.doubleTap)
        precondition(relaunched.eligible, "Two drafts across launches qualify")
        relaunched.markBannerShown()
        let restored = InviteProgram(defaults: defaults, loadCredential: false)
        precondition(restored.eligible && restored.bannerShown, "Banner dismissal must persist")
        for use in [InviteProgram.Use.sidekick, .proactive] {
            defaults.removeObject(forKey: "invites.eligible")
            let fresh = InviteProgram(defaults: defaults, loadCredential: false)
            fresh.record(use)
            precondition(fresh.eligible, "A real Sidekick or proactive use qualifies")
        }
        precondition(InviteSnapshot.isValidCode(" a7k-2m9 \n"))
        precondition(InviteSnapshot.isValidCode("012345"))
        precondition(InviteSnapshot.isValidCode("UVWXYZ"))
        for invalid in ["A7K2M", "A7K2M90", "A7K2M!", "Ａ7K2M9", "A7K2Mé", "A7K2M😀"] {
            precondition(!InviteSnapshot.isValidCode(invalid))
        }
        precondition(InviteSnapshot.displayCode("a7k-2m9") == "A7K2M9")
        precondition(InviteSnapshot.isValidCode(" abcd-1234-efab-5678 \n"))
        precondition(!InviteSnapshot.isValidCode("ABCD-1234-EFAB-567Z"))
        precondition(!InviteSnapshot.isValidCode(""))
        precondition(InviteSnapshot.displayCode("ABCD1234EFAB5678") == "ABCD-1234-EFAB-5678")
        let expired = InviteSnapshot(code: "A7K2M9", campaignActive: true,
                                     endsAt: 1, redeemedAt: 1, redemptionCount: 2)
        precondition(!expired.canShare && expired.hasLifetimeAccess, "Expiry stops sharing, never lifetime access")
        print("PASS: invitation milestones, relaunch, dismissal, code parsing, lifetime persistence")
    }
}
