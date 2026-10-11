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
    @MainActor static func main() async {
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
        for code in ["A", "A7K2M", "A7K2M90", "A7K2M!", "Ａ7K2M9", "A7K2Mé", "A7K2M😀",
                     "Founder's Circle / 2026! 🚀", "-", "ABCD-1234-EFAB-567Z", String(repeating: "Long!", count: 2_000)] {
            precondition(InviteSnapshot.isValidCode(code))
            precondition(InviteSnapshot.normalize(code) == code, "Custom invite text must be preserved")
        }
        precondition(InviteSnapshot.normalize(" \ta7k-2m9\n") == "a7k-2m9")
        precondition(InviteSnapshot.normalize("\u{00A0}Founder's Circle / 2026! 🚀\u{200B}") == "Founder's Circle / 2026! 🚀")
        precondition(InviteSnapshot.isValidCode(" abcd-1234-efab-5678 \n"))
        for blank in ["", " \t\r\n", "\u{00A0}\u{200B}\u{202F}\u{3000}"] {
            precondition(!InviteSnapshot.isValidCode(blank))
            await program.redeem(blank)
            precondition(program.errorMessage == "Enter the invite code you received.")
            precondition(!program.isBusy && program.snapshot == nil)
        }
        let expired = InviteSnapshot(code: "A7K2M9", campaignActive: true,
                                     endsAt: 1, redeemedAt: 1, redemptionCount: 2)
        precondition(!expired.canShare && expired.hasLifetimeAccess, "Expiry stops sharing, never lifetime access")
        print("PASS: invitation milestones, relaunch, dismissal, code parsing, lifetime persistence")
    }
}
