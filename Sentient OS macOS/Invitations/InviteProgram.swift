// InviteProgram.swift
// Shared invitation state, real-use milestones, and serialized cloud operations.
// record(_:) counts post-onboarding use; refresh/redeem publish server-confirmed state.

import Foundation
import Observation

@MainActor @Observable
final class InviteProgram {
    static let shared = InviteProgram()
    static let offerTitle = "Exclusive offer"
    static let offerMessage = "You have just 5\u{00A0}invites to share. Give 5\u{00A0}friends Sentient OS free\u{00A0}for\u{00A0}life."

    enum Use { case doubleTap, sidekick, proactive }
    private(set) var snapshot: InviteSnapshot?
    private(set) var isBusy = false
    private(set) var isRedeeming = false
    private(set) var lastGiftWasLate = false
    private(set) var errorMessage: String?
    private(set) var eligible: Bool
    private(set) var bannerShown: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, loadCredential: Bool = true) {
        self.defaults = defaults
        eligible = defaults.bool(forKey: "invites.eligible")
        bannerShown = defaults.bool(forKey: "invites.bannerShown")
        if loadCredential, let data = try? InviteCredential.read("snapshot") {
            snapshot = try? JSONDecoder().decode(InviteSnapshot.self, from: data)
        }
    }

    func record(_ use: Use) {
        guard defaults.bool(forKey: AppState.onboardingKey), !eligible else { return }
        if case .doubleTap = use {
            let count = min(2, defaults.integer(forKey: "invites.doubleTapCount") + 1)
            defaults.set(count, forKey: "invites.doubleTapCount")
            guard count == 2 else { return }
        }
        eligible = true
        defaults.set(true, forKey: "invites.eligible")
    }

    func markBannerShown() {
        bannerShown = true
        defaults.set(true, forKey: "invites.bannerShown")
    }

    @discardableResult
    func refresh(createIfNeeded: Bool = true, quietly: Bool = false) async -> Bool {
        guard !isBusy else { return false }
        if !createIfNeeded {
            do { guard try InviteCredential.read("session") != nil else { return false } }
            catch { if !quietly { errorMessage = error.localizedDescription }; return false }
        }
        return await perform(reportErrors: !quietly)
    }

    @discardableResult
    func redeem(_ code: String, email: String? = nil) async -> Bool {
        guard !isBusy else { return false }
        guard InviteSnapshot.isValidCode(code) else {
            errorMessage = "Enter the invite code you received."
            return false
        }
        if InviteLateUse.matches(code), email.flatMap(MailAccount.normalizedEmail) == nil {
            errorMessage = "Enter a valid email so we can save your gift."
            return false
        }
        return await perform(code: code, email: email)
    }

    func clearError() { errorMessage = nil }

    private func perform(code: String? = nil, email: String? = nil, reportErrors: Bool = true) async -> Bool {
        isBusy = true
        isRedeeming = code != nil
        if reportErrors { errorMessage = nil }
        defer { isBusy = false; isRedeeming = false }
        do {
            let result = try await InviteCloud.shared.fetch(redeeming: code, email: email)
            // Publish only after the receipt is safely cached. A lost response or failed save
            // can be retried; the server returns the same permanent grant.
            try InviteCredential.write("snapshot", data: JSONEncoder().encode(result))
            snapshot = result
            if let code { lastGiftWasLate = InviteLateUse.matches(code) }
            Diagnostics.backgroundRecovered(.invite)
            return true
        } catch is CancellationError { return false }
        catch {
            if case InviteCloud.Failure.rejected = error {} else {
                if let counts = Diagnostics.backgroundFailure(.invite) {
                    Diagnostics.report(.serviceFailed, phase: .refresh, reason: "invite_refresh", error: error, source: "invite", counts: counts)
                }
            }
            if reportErrors { errorMessage = error.localizedDescription }; return false
        }
    }
}
