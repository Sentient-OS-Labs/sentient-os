// Compile with LifetimeUpgradeAnnouncement.swift, InviteCloud.swift and MailAccount.swift.
// Exercises the real delivery coordinator with isolated defaults and no network/notifications.
import Foundation

@MainActor final class InviteProgram {
    static let shared = InviteProgram()
    var snapshot: InviteSnapshot? { fatalError("Live service used in offline test") }
    func refresh(createIfNeeded: Bool, quietly: Bool) async -> Bool { fatalError("Live service used") }
    func acknowledgeUpgrade(_ id: UUID) async -> Bool { fatalError("Live service used") }
    func claimUpgradeNotification(_ id: UUID) async -> Bool { fatalError("Live service used") }
}
@MainActor enum Notify {
    static func canDeliverLifetimeUpgrade() async -> Bool { fatalError("Live notification used") }
    static func lifetimeUpgrade(_ id: UUID) async { fatalError("Live notification used") }
    static func clearLifetimeUpgrade(_ id: UUID) { fatalError("Live notification used") }
}

@MainActor final class Fixture {
    let notice = InviteLifetimeUpgrade(id: UUID(), upgradedAt: 1234)
    var snapshot: InviteSnapshot
    var active = false
    var permitted = true
    var online = true
    var acknowledgeSucceeds = true
    var pausePermission = false
    var permission: CheckedContinuation<Bool, Never>?
    var claims = 0, notifications = 0, acknowledgements = 0, cleared = 0
    init() {
        snapshot = InviteSnapshot(code: nil, campaignActive: true, endsAt: nil, redeemedAt: 123,
                                  redemptionCount: 0, lifetimeUpgrade: notice)
    }
    var services: LifetimeUpgradeAnnouncement.Services {
        .init(refresh: { self.online ? self.snapshot : nil }, acknowledge: { id in
            self.acknowledgements += 1
            guard self.acknowledgeSucceeds else { return false }
            precondition(id == self.notice.id)
            self.snapshot.lifetimeUpgrade?.seenAt = 4567
            return true
        }, canNotify: {
            if self.pausePermission { return await withCheckedContinuation { self.permission = $0 } }
            return self.permitted
        }, claimNotification: { id in
            self.claims += 1
            guard self.snapshot.lifetimeUpgrade?.notificationClaimedAt == nil,
                  self.snapshot.lifetimeUpgrade?.seenAt == nil else { return false }
            self.snapshot.lifetimeUpgrade?.notificationClaimedAt = 3456
            return true
        }, notify: { _ in self.notifications += 1 }, clearNotification: { _ in self.cleared += 1 },
        appIsActive: { self.active })
    }
}

@main struct Checks {
    @MainActor static func main() async {
        let suite = "sentient.upgrade.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let denied = Fixture(); denied.permitted = false
        let first = LifetimeUpgradeAnnouncement(defaults: defaults, services: denied.services)
        _ = await first.check()
        precondition(first.pending?.id == denied.notice.id && denied.notifications == 0 && denied.claims == 0)
        await first.markSeen(denied.notice)?.value
        precondition(first.pending == nil && denied.acknowledgements == 1 && denied.cleared == 1)
        precondition(first.markSeen(denied.notice) == nil)
        let relaunched = LifetimeUpgradeAnnouncement(defaults: defaults, services: denied.services)
        _ = await relaunched.check()
        precondition(relaunched.pending == nil && denied.notifications == 0)

        let background = Fixture()
        let delivery = LifetimeUpgradeAnnouncement(defaults: defaults, services: background.services)
        _ = await delivery.check(); _ = await delivery.check()
        let anotherLaunch = LifetimeUpgradeAnnouncement(defaults: defaults, services: background.services)
        _ = await anotherLaunch.check()
        precondition(background.claims == 1 && background.notifications == 1)
        precondition(delivery.pending != nil, "Sending a notification must not consume the in-app gift")

        let foreground = Fixture(); foreground.active = true
        let home = LifetimeUpgradeAnnouncement(defaults: defaults, services: foreground.services)
        _ = await home.check()
        precondition(home.pending != nil && foreground.claims == 0 && foreground.notifications == 0)

        let unrelated = Fixture(); unrelated.snapshot.lifetimeUpgrade = nil
        let notTargeted = LifetimeUpgradeAnnouncement(defaults: defaults, services: unrelated.services)
        _ = await notTargeted.check()
        precondition(notTargeted.pending == nil && unrelated.claims == 0 && unrelated.notifications == 0)

        let race = Fixture(); race.pausePermission = true
        let racing = LifetimeUpgradeAnnouncement(defaults: defaults, services: race.services)
        let checking = Task { await racing.check() }
        while race.permission == nil { await Task.yield() }
        await racing.markSeen(race.notice)?.value
        race.permission?.resume(returning: true)
        _ = await checking.value
        precondition(racing.pending == nil && race.claims == 0 && race.notifications == 0,
                     "Opening Home during a pending notification must cancel the nudge")

        let offline = Fixture(); offline.active = true; offline.acknowledgeSucceeds = false
        let beforeQuit = LifetimeUpgradeAnnouncement(defaults: defaults, services: offline.services)
        _ = await beforeQuit.check()
        let ack = beforeQuit.markSeen(offline.notice)
        while offline.acknowledgements == 0 { await Task.yield() }
        ack?.cancel(); await ack?.value
        let afterQuit = LifetimeUpgradeAnnouncement(defaults: defaults, services: offline.services)
        _ = await afterQuit.check()
        precondition(afterQuit.pending == nil && offline.notifications == 0,
                     "Failed server acknowledgement must not replay a seen gift")
        offline.acknowledgeSucceeds = true
        let synced = await afterQuit.check()
        precondition(synced)
        precondition(offline.snapshot.lifetimeUpgrade?.seenAt != nil)

        print("PASS: exact targeting, permission denied, foreground silence, one notification across relaunches, independent in-app gift, delivery race, offline acknowledgement retry, and persistent once-only presentation")
    }
}
