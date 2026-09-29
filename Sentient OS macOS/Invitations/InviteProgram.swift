// InviteProgram.swift
// Shared invitation state, real-use milestones, and serialized cloud operations.
// record(_:) counts post-onboarding use; refresh/redeem publish server-confirmed state.

import Foundation
import Observation

@MainActor @Observable
final class InviteProgram {
    static let shared = InviteProgram()
    static let offerTitle = "Limited-time offer!"
    static let offerMessage = "Give your friends Sentient OS free for life."

    enum Use { case doubleTap, sidekick, proactive }
    private(set) var snapshot: InviteSnapshot?
    private(set) var isBusy = false
    private(set) var isRedeeming = false
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

    func redeem(_ code: String) async {
        guard !isBusy else { return }
        guard InviteSnapshot.isValidCode(code) else {
            errorMessage = "Enter the 16-character invite code your friend shared."
            return
        }
        _ = await perform(code: code)
    }

    func clearError() { errorMessage = nil }

    private func perform(code: String? = nil, reportErrors: Bool = true) async -> Bool {
        isBusy = true
        isRedeeming = code != nil
        if reportErrors { errorMessage = nil }
        defer { isBusy = false; isRedeeming = false }
        do {
            let result = try await InviteCloud.shared.fetch(redeeming: code)
            // Publish only after the receipt is safely cached. A lost response or failed save
            // can be retried; the server returns the same permanent grant.
            try InviteCredential.write("snapshot", data: JSONEncoder().encode(result))
            snapshot = result
            return true
        } catch is CancellationError { return false }
        catch { if reportErrors { errorMessage = error.localizedDescription }; return false }
    }
}
