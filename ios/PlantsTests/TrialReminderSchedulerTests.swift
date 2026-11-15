import Foundation
import XCTest
@testable import Plants

@MainActor
final class TrialReminderSchedulerTests: XCTestCase {
    private let owner = UUID()
    private let now = Date(timeIntervalSince1970: 1_793_400_000)

    private func entitlement(
        end: String = "2026-11-01T08:30:00-05:00", validUntil: String = "2026-11-05T18:00:00Z",
        product: String = "app.narat.plants.pro.yearly", state: String = "active", offer: String = "trial"
    ) throws -> SyncWireEntitlementDTO {
        let data = try JSONSerialization.data(withJSONObject: [
            "product_id": product, "state": state, "offer_kind": offer, "valid_until": validUntil,
            "trial_end_at": end, "grace_until": NSNull(), "auto_renew_enabled": true
        ])
        return try JSONDecoder().decode(SyncWireEntitlementDTO.self, from: data)
    }

    func testOptInSchedulesTwentyFourHoursBeforeVerifiedDateAndUpdatesTheSameRequest() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let center = TrialNotificationFixture()
        let scheduler = TrialReminderScheduler(notifications: center, defaults: defaults, clock: { self.now })
        await scheduler.update(ownerId: owner, entitlement: try entitlement(), locale: .en).value
        let firstEnd = try XCTUnwrap(scheduler.trial?.end)
        XCTAssertFalse(scheduler.optedIn)
        XCTAssertNil(center.pending)
        XCTAssertEqual(center.permissionRequests, 0)

        await scheduler.setOptIn(true, ownerId: owner)
        let first = try XCTUnwrap(center.pending)
        XCTAssertEqual(first.date, firstEnd.addingTimeInterval(-86_400))
        XCTAssertEqual(first.date, SQLTimestamp.date(from: "2026-10-31T13:30:00Z"))
        XCTAssertEqual(first.id, "narat.trial-reminder." + owner.uuidString.lowercased())
        XCTAssertEqual(center.permissionRequests, 1)
        let changed = try entitlement(end: "2026-11-05T09:10:00-05:00", validUntil: "2026-11-06T18:00:00Z")
        await scheduler.update(ownerId: owner, entitlement: changed, locale: .pl).value
        let second = try XCTUnwrap(center.pending)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.locale, .pl)
        XCTAssertEqual(second.date, try XCTUnwrap(scheduler.trial?.end).addingTimeInterval(-86_400))
        XCTAssertNotEqual(second.date, first.date)
        XCTAssertEqual(center.permissionRequests, 1)
    }

    func testDeniedPermissionKeepsTheVerifiedDateAndTheLocalPreferenceAcrossRecreation() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let center = TrialNotificationFixture()
        center.permissionReply = false
        let verified = try entitlement()
        let scheduler = TrialReminderScheduler(notifications: center, defaults: defaults, clock: { self.now })
        await scheduler.update(ownerId: owner, entitlement: verified, locale: .en).value
        let end = try XCTUnwrap(scheduler.trial?.end)
        await scheduler.setOptIn(true, ownerId: owner)
        XCTAssertTrue(scheduler.notificationsDenied)
        XCTAssertEqual(scheduler.trial?.end, end)
        XCTAssertNil(center.pending)

        let reopened = TrialReminderScheduler(notifications: center, defaults: defaults, clock: { self.now })
        await reopened.update(ownerId: owner, entitlement: verified, locale: .en).value
        XCTAssertTrue(reopened.optedIn)
        XCTAssertTrue(reopened.notificationsDenied)
        XCTAssertEqual(reopened.trial?.end, end)
        XCTAssertEqual(center.permissionRequests, 1)
        center.allowed = true
        await reopened.update(ownerId: owner, entitlement: verified, locale: .en).value
        XCTAssertNotNil(center.pending)
        XCTAssertEqual(center.permissionRequests, 1)
    }

    func testRevocationExpiryOptOutAndOwnerSwitchRemoveTheReminder() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let center = TrialNotificationFixture()
        center.allowed = true
        var current = now
        let scheduler = TrialReminderScheduler(notifications: center, defaults: defaults, clock: { current })
        let verified = try entitlement()
        await scheduler.update(ownerId: owner, entitlement: verified, locale: .en).value
        await scheduler.setOptIn(true, ownerId: owner)
        XCTAssertNotNil(center.pending)
        await scheduler.setOptIn(false, ownerId: owner)
        XCTAssertNil(center.pending)
        await scheduler.setOptIn(true, ownerId: owner)
        await scheduler.update(ownerId: owner, entitlement: try entitlement(state: "revoked"), locale: .en).value
        XCTAssertNil(scheduler.trial)
        XCTAssertNil(center.pending)

        await scheduler.update(ownerId: owner, entitlement: verified, locale: .en).value
        XCTAssertNotNil(center.pending)
        let other = UUID()
        await scheduler.update(ownerId: other, entitlement: verified, locale: .en).value
        XCTAssertFalse(scheduler.optedIn)
        XCTAssertNil(center.pending)
        await scheduler.setOptIn(true, ownerId: owner)
        XCTAssertNil(center.pending)

        await scheduler.update(ownerId: owner, entitlement: verified, locale: .en).value
        await scheduler.update(ownerId: nil, entitlement: nil, locale: .en).value
        XCTAssertNil(center.pending)
        await scheduler.update(ownerId: owner, entitlement: verified, locale: .en).value
        XCTAssertNotNil(center.pending)
        current = try XCTUnwrap(scheduler.trial?.accessUntil)
        await scheduler.update(ownerId: owner, entitlement: verified, locale: .en).value
        XCTAssertNil(scheduler.trial)
        XCTAssertNil(center.pending)
    }
}

@MainActor
private final class TrialNotificationFixture: TrialReminderNotifications {
    var allowed: Bool?
    var permissionReply = true
    private(set) var permissionRequests = 0
    private(set) var pending: TrialReminderRequest?

    func authorization() async -> Bool? { allowed }

    func requestAuthorization() async throws {
        permissionRequests += 1
        allowed = permissionReply
    }

    func reconcile(_ request: TrialReminderRequest?) async throws {
        pending = request
    }
}
