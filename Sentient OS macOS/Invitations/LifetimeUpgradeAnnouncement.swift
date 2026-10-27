// A server-targeted gift, delivered once without opening or activating any window.
// Home owns presentation; notification clicks use the existing explicit Home router.

import AppKit
import Foundation
import Observation

@MainActor @Observable
final class LifetimeUpgradeAnnouncement {
    static let shared = LifetimeUpgradeAnnouncement()

    struct Services {
        var refresh: () async -> InviteSnapshot?
        var acknowledge: (UUID) async -> Bool
        var canNotify: () async -> Bool
        var claimNotification: (UUID) async -> Bool
        var notify: (UUID) async -> Void
        var clearNotification: (UUID) -> Void
        var appIsActive: () -> Bool

        static var live: Self {
            Self(refresh: {
                let program = InviteProgram.shared
                guard await program.refresh(createIfNeeded: false, quietly: true) else { return nil }
                return program.snapshot
            }, acknowledge: { await InviteProgram.shared.acknowledgeUpgrade($0) },
            canNotify: { await Notify.canDeliverLifetimeUpgrade() },
            claimNotification: { await InviteProgram.shared.claimUpgradeNotification($0) },
            notify: { await Notify.lifetimeUpgrade($0) },
            clearNotification: { Notify.clearLifetimeUpgrade($0) },
            appIsActive: { NSApp.isActive })
        }
    }

    private(set) var pending: InviteLifetimeUpgrade?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let services: Services
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var launchTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, services: Services? = nil) {
        self.defaults = defaults
        self.services = services ?? .live
    }

    /// Runs even after a windowless update, but never mints an anonymous identity.
    /// Bounded retries cover launch/network races; a later Home visit tries again.
    func start() {
        guard launchTask == nil else { return }
        launchTask = Task { [weak self] in
            for delay in [3, 30, 120] {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self else { return }
                if await check() { break }
            }
            self?.launchTask = nil
        }
    }

    @discardableResult
    func check() async -> Bool {
        guard !checking else { return false }
        checking = true
        defer { checking = false }
        guard let snapshot = await services.refresh() else { return false }
        guard snapshot.hasLifetimeAccess, let notice = snapshot.lifetimeUpgrade, notice.isValid else {
            pending = nil
            return true
        }
        if notice.seenAt != nil {
            defaults.set(true, forKey: seenKey(notice.id))
            pending = nil
            services.clearNotification(notice.id)
            return true
        }
        if hasSeen(notice.id) {
            pending = nil
            return await services.acknowledge(notice.id)
        }
        pending = notice
        guard notice.notificationClaimedAt == nil, !services.appIsActive(),
              await services.canNotify(), stillPending(notice.id), !services.appIsActive(),
              await services.claimNotification(notice.id) else { return true }
        // The user may have opened Home while permission/claim requests were in flight.
        guard stillPending(notice.id), !services.appIsActive() else { return true }
        await services.notify(notice.id)
        // A visible celebration may have consumed the notice during notification delivery.
        if !stillPending(notice.id) { services.clearNotification(notice.id) }
        return true
    }

    /// Called only when the sheet actually appears. Persist locally before any network
    /// request, so a quit or offline dismissal cannot replay it on the next launch.
    @discardableResult
    func markSeen(_ notice: InviteLifetimeUpgrade) -> Task<Void, Never>? {
        guard stillPending(notice.id) else { return nil }
        defaults.set(true, forKey: seenKey(notice.id))
        pending = nil
        services.clearNotification(notice.id)
        return Task { [services] in
            for delay in [0, 5, 30] {
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
                if await services.acknowledge(notice.id) { return }
            }
        }
    }

    private func stillPending(_ id: UUID) -> Bool { pending?.id == id && !hasSeen(id) }
    private func hasSeen(_ id: UUID) -> Bool { defaults.bool(forKey: seenKey(id)) }
    private func seenKey(_ id: UUID) -> String { "invites.upgrade.seen." + id.uuidString }
}
