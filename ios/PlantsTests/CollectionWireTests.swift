import XCTest
import Combine
import SwiftData
import UserNotifications
import UIKit
@testable import Plants

extension CollectionWireTests {
    private func notificationRequest(_ candidate: CareReminderPlan.Candidate) throws -> UNNotificationRequest {
        try CareReminderNotificationFactory.request(.init(candidate: candidate, attemptId: operationId), now: receiptNow)
    }

    @MainActor
    func testCareUNFactoryUsesRealPlanStableIDsAndMinimalContent() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        let rows = [reminderRow(serverPlantId, controls: [reminderControl(1)])]
        let base = reminderPlan(try reminderState(local, rows: rows)).candidates
        XCTAssertEqual(base.count, 2)
        let changed = reminderPlan(try reminderState(local, rows: rows, mode: "english", hour: 15),
            locale: "en", zone: try XCTUnwrap(TimeZone(identifier: "America/New_York"))).candidates
        XCTAssertEqual(Set(base.map(\.id)), Set(changed.map(\.id)))
        for c in base + changed {
            let request = try notificationRequest(c)
            XCTAssertEqual(request.identifier, CareReminderNotificationFactory.prefix + c.id)
            let route = try XCTUnwrap(CareReminderNotificationFactory.parse(
                identifier: request.identifier, userInfo: request.content.userInfo))
            XCTAssertEqual(route.candidate, c)
            XCTAssertEqual(route.attemptId, operationId)
            let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
            XCTAssertFalse(trigger.repeats)
            let parts = trigger.dateComponents
            XCTAssertEqual(parts.calendar?.identifier, .gregorian)
            XCTAssertEqual(parts.timeZone, TimeZone(secondsFromGMT: 0))
            XCTAssertEqual(parts.calendar?.date(from: parts), c.absoluteFireDate)
            XCTAssertEqual([parts.hour, parts.minute, parts.second].compactMap { $0 }.count, 3)
            XCTAssertEqual(request.content.title, c.locale == "pl" ? "Pielęgnacja roślin" : "Plant care")
            XCTAssertEqual(request.content.body, c.locale == "pl"
                ? "Sprawdź zadania pielęgnacji w Narat." : "Check your care tasks in Narat.")
            XCTAssertNotNil(request.content.sound)
            XCTAssertEqual(request.content.userInfo.count, 10)
            XCTAssertTrue(request.content.userInfo.values.allSatisfy { $0 is String })
            XCTAssertTrue(PropertyListSerialization.propertyList(request.content.userInfo, isValidFor: .binary))
        }
    }

    func testCareUNStrictRouteAcceptsPostFireAndRejectsForgedMetadata() throws {
        let c = try receiptCandidate(occurrence: .routine(ruleId: operationId))
        let request = try notificationRequest(c)
        let parse = CareReminderNotificationFactory.parse
        XCTAssertNotNil(parse(request.identifier, request.content.userInfo))
        // Parsing has no clock or future guard, including when observed after firing.
        let observed = c.absoluteFireDate.addingTimeInterval(60)
        XCTAssertNotNil(CareReminderNotificationFactory.inventory(pending: [],
            delivered: [(request: request, deliveredAt: observed)]).delivered.first?.route)
        let mutations: [(String, Any?)] = [
            ("version", "2"), ("version", true), ("owner", "invalid"),
            ("owner", otherSyncOwner.uuidString.lowercased()), ("plant", "invalid"),
            ("occurrence", "care/forged"), ("kind", "unknown"), ("kind", "first-aid"),
            ("rule", UUID().uuidString.lowercased()), ("attemptId", 1), ("attemptId", "invalid"),
            ("sourceYMD", "2026-02-30"), ("sourceYMD", "2026-11-26"),
            ("absoluteFire", "nan"), ("absoluteFire", 123), ("locale", "de"),
            ("version", nil), ("extra", "unexpected")
        ]
        for (key, value) in mutations {
            var info = request.content.userInfo
            info["narat.care." + key] = value
            XCTAssertNil(parse(request.identifier, info), key)
        }
        for id in [TrialReminderRequest.prefix + c.id, "foreign", request.identifier + "/forged"] {
            XCTAssertNil(parse(id, request.content.userInfo))
        }
    }

    func testCareUNInventoryRetainsUntrustedOwnItemsAndFiltersDeletion() throws {
        let c = try receiptCandidate()
        let valid = try notificationRequest(c)
        let trigger = try XCTUnwrap(valid.trigger as? UNCalendarNotificationTrigger)
        var nonUTC = trigger.dateComponents
        nonUTC.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var wrongFire = trigger.dateComponents
        wrongFire.second = 1
        var partial = DateComponents()
        partial.hour = 9
        let badTriggers: [UNNotificationTrigger?] = [
            UNCalendarNotificationTrigger(dateMatching: trigger.dateComponents, repeats: true),
            UNCalendarNotificationTrigger(dateMatching: nonUTC, repeats: false),
            UNCalendarNotificationTrigger(dateMatching: wrongFire, repeats: false),
            UNCalendarNotificationTrigger(dateMatching: partial, repeats: false),
            UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false), nil
        ]
        let untrusted = badTriggers.map {
            UNNotificationRequest(identifier: valid.identifier, content: valid.content, trigger: $0)
        }
        let rawID = CareReminderNotificationFactory.prefix + "malformed"
        let malformed = UNNotificationRequest(identifier: rawID, content: UNMutableNotificationContent(), trigger: nil)
        let foreign = [TrialReminderRequest.prefix + "keep", "other.keep"].map {
            UNNotificationRequest(identifier: $0, content: valid.content, trigger: valid.trigger)
        }
        let observed = c.absoluteFireDate.addingTimeInterval(30)
        let inventory = CareReminderNotificationFactory.inventory(
            pending: [valid, malformed] + untrusted + foreign,
            delivered: [(valid, observed), (malformed, observed), (foreign[0], observed)])
        XCTAssertEqual(inventory.otherPendingCount, 2)
        XCTAssertEqual(inventory.pending.count, 8)
        XCTAssertEqual(inventory.pending.compactMap(\.route).count, 1)
        XCTAssertTrue(inventory.pending.allSatisfy { $0.deliveredAt == nil })
        XCTAssertEqual(inventory.pending[1].rawIdentifier, rawID)
        XCTAssertNil(inventory.pending[1].route)
        XCTAssertTrue(inventory.pending.dropFirst(2).allSatisfy { $0.route == nil })
        XCTAssertEqual(inventory.delivered.count, 2)
        XCTAssertEqual(inventory.delivered[0].route?.candidate, c)
        XCTAssertEqual(inventory.delivered[0].deliveredAt, observed)
        XCTAssertNil(inventory.delivered[1].route)
        XCTAssertEqual(CareReminderNotificationFactory.ownIdentifiers(
            [valid.identifier, foreign[0].identifier, rawID, foreign[1].identifier]), [valid.identifier, rawID])
        XCTAssertTrue(CareReminderNotificationFactory.inventory(pending: [], delivered: []).delivered.isEmpty)
    }

    func testCareUNAbsoluteUTCAndInvalidProposals() throws {
        let c = try receiptCandidate()
        let original = try notificationRequest(c)
        let savedZone = NSTimeZone.default
        defer { NSTimeZone.default = savedZone }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        let otherCalendar = Calendar(identifier: .buddhist)
        let changed = try notificationRequest(c)
        let parts = try XCTUnwrap((changed.trigger as? UNCalendarNotificationTrigger)?.dateComponents)
        XCTAssertEqual(parts, (original.trigger as? UNCalendarNotificationTrigger)?.dateComponents)
        XCTAssertNotEqual(otherCalendar.component(.year, from: c.absoluteFireDate), parts.year)
        XCTAssertEqual(parts.calendar?.date(from: parts), c.absoluteFireDate)
        for fire in [c.absoluteFireDate.addingTimeInterval(0.5), receiptNow, receiptNow.addingTimeInterval(-1),
                     Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan)] {
            let bad = CareReminderPlan.Candidate(id: c.id, ownerId: c.ownerId, plantId: c.plantId,
                occurrence: c.occurrence, sourceDueYMD: c.sourceDueYMD, absoluteFireDate: fire, locale: c.locale)
            XCTAssertThrowsError(try notificationRequest(bad))
        }
        XCTAssertThrowsError(try notificationRequest(receiptCandidate(id: "forged")))
        XCTAssertThrowsError(try notificationRequest(receiptCandidate(locale: "de")))
        XCTAssertThrowsError(try CareReminderNotificationFactory.request(
            .init(candidate: c, attemptId: operationId), now: Date(timeIntervalSince1970: .nan)))
    }
}

extension CollectionWireTests {
    private var receiptNow: Date { SQLTimestamp.date(from: "2026-11-20T00:00:00Z")! }

    private func receiptCandidate(
        due: String = "2026-11-25", hour: Int = 9, zone: TimeZone? = nil, locale: String = "pl",
        owner: UUID? = nil, occurrence: CareReminderPlan.Occurrence? = nil, id: String? = nil
    ) throws -> CareReminderPlan.Candidate {
        let owner = owner ?? syncOwner
        let occurrence = occurrence ?? .firstAid(controlId: operationId)
        return CareReminderPlan.Candidate(
            id: id ?? CareReminderPlan.identity(ownerId: owner, plantId: serverPlantId,
                occurrence: occurrence, sourceDueYMD: due),
            ownerId: owner, plantId: serverPlantId, occurrence: occurrence, sourceDueYMD: due,
            absoluteFireDate: try XCTUnwrap(CareReminderPlan.resolve(
                sourceYMD: due, hour: hour, timeZone: zone ?? TimeZone(secondsFromGMT: 0)!)), locale: locale)
    }

    private func coldReceipts(_ ledger: CareReminderReceipts) throws -> CareReminderReceipts {
        try JSONDecoder().decode(CareReminderReceipts.self, from: JSONEncoder().encode(ledger))
    }

    func testReminderReceiptsCodecRejectsCorruptAndForeignMetadata() throws {
        let candidate = try receiptCandidate()
        var ledger = CareReminderReceipts(ownerId: syncOwner)
        XCTAssertEqual(try ledger.prepare(candidate, now: receiptNow), .newlyPrepared)
        XCTAssertEqual(try coldReceipts(ledger), ledger)
        XCTAssertNoThrow(try ledger.validate(expectedOwner: syncOwner))
        XCTAssertThrowsError(try ledger.validate(expectedOwner: otherSyncOwner))
        let data = try JSONEncoder().encode(ledger)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for mutation in 0..<11 {
            var wire = original
            var records = wire["entries"] as! [[String: Any]]
            var entry = records[0]["entry"] as! [String: Any]
            switch mutation {
            case 0: wire["version"] = 2
            case 1: wire.removeValue(forKey: "version")
            case 2: entry["ownerId"] = otherSyncOwner.uuidString
            case 3: entry["id"] = "care/malformed"
            case 4: entry["phase"] = "delivered"
            case 5: entry["sourceDueYMD"] = "2026-02-30"
            case 6: records[0]["key"] = "wrong-key"
            case 7: break // Duplicate record below.
            case 8: entry["phase"] = "cancelledBeforeFire" // Missing proof.
            case 9: entry["currentFireDate"] = "NaN"
            default: entry["originalFireDate"] = (entry["originalFireDate"] as! Double) + 1
            }
            records[0]["entry"] = entry
            if mutation == 7 { records.append(records[0]) }
            wire["entries"] = records
            XCTAssertThrowsError(try JSONDecoder().decode(CareReminderReceipts.self,
                from: JSONSerialization.data(withJSONObject: wire)), "mutation \(mutation)")
        }
    }

    func testReminderReceiptsRepeatedPrepareACKAndElapsedStayConsumedAfterCodec() throws {
        let candidate = try receiptCandidate()
        for armed in [false, true] {
            var ledger = CareReminderReceipts(ownerId: syncOwner)
            XCTAssertEqual(try ledger.prepare(candidate, now: receiptNow), .newlyPrepared)
            let attempt = try XCTUnwrap(ledger.entries[candidate.id]?.attemptId)
            XCTAssertEqual(try ledger.prepare(candidate, now: receiptNow), .existing)
            XCTAssertFalse(try ledger.acknowledge(id: candidate.id, attemptId: UUID(), now: receiptNow))
            if armed {
                XCTAssertTrue(try ledger.acknowledge(id: candidate.id, attemptId: attempt, now: receiptNow))
            }
            ledger = try coldReceipts(ledger)
            let changed = try receiptCandidate(due: "2026-11-28", hour: 11,
                zone: TimeZone(identifier: "America/New_York"), locale: "en")
            XCTAssertEqual(changed.id, candidate.id)
            XCTAssertEqual(try ledger.prepare(changed, now: receiptNow), .blocked)
            XCTAssertEqual(try ledger.prepare(changed, now: candidate.absoluteFireDate), .blocked)
            XCTAssertEqual(ledger.entries[candidate.id]?.phase, .spent)
            ledger = try coldReceipts(ledger)
            XCTAssertEqual(try ledger.prepare(changed,
                now: candidate.absoluteFireDate.addingTimeInterval(3600)), .blocked)
            XCTAssertFalse(try ledger.acknowledge(id: candidate.id, attemptId: attempt, now: receiptNow))
        }
    }

    func testReminderReceiptsVerifiedCancellationPreservesOriginalAndFencesOldACK() throws {
        let candidate = try receiptCandidate()
        var ledger = CareReminderReceipts(ownerId: syncOwner)
        _ = try ledger.prepare(candidate, now: receiptNow)
        let oldAttempt = try XCTUnwrap(ledger.entries[candidate.id]?.attemptId)
        XCTAssertTrue(try ledger.cancel(id: candidate.id, attemptId: oldAttempt,
            proof: .removedAndReadBackAbsent(confirmedAt: receiptNow), now: receiptNow))
        let cancelled = try coldReceipts(ledger)
        XCTAssertEqual(cancelled.entries[candidate.id]?.phase, .cancelledBeforeFire)
        ledger = cancelled
        let changed = try receiptCandidate(due: "2026-11-28", hour: 10)
        XCTAssertEqual(try ledger.prepare(changed, now: receiptNow), .newlyPrepared)
        XCTAssertFalse(try ledger.acknowledge(id: candidate.id, attemptId: oldAttempt, now: receiptNow))
        let entry = try XCTUnwrap(ledger.entries[candidate.id])
        XCTAssertEqual(entry.originalFireDate, candidate.absoluteFireDate)
        XCTAssertEqual(entry.currentFireDate, changed.absoluteFireDate)
        XCTAssertEqual(entry.cancellation, cancelled.entries[candidate.id]?.cancellation)
        XCTAssertNoThrow(try ledger.validateReplacement(of: cancelled))
        XCTAssertTrue(try ledger.acknowledge(id: candidate.id, attemptId: entry.attemptId, now: receiptNow))
        XCTAssertEqual(try coldReceipts(ledger), ledger)
        XCTAssertThrowsError(try CareReminderReceipts(ownerId: syncOwner).validateReplacement(of: ledger))
    }

    func testReminderReceiptsMissingFailedLateProofAndUnknownNeverRearm() throws {
        let candidate = try receiptCandidate()
        let changed = try receiptCandidate(due: "2026-11-28")
        let proofs: [CareReminderReceipts.RemovalProof] = [
            .missing, .readbackFailed,
            .removedAndReadBackAbsent(confirmedAt: candidate.absoluteFireDate),
            .removedAndReadBackAbsent(confirmedAt: candidate.absoluteFireDate.addingTimeInterval(1))
        ]
        for (index, proof) in proofs.enumerated() {
            var ledger = CareReminderReceipts(ownerId: syncOwner)
            _ = try ledger.prepare(candidate, now: receiptNow)
            let attempt = try XCTUnwrap(ledger.entries[candidate.id]?.attemptId)
            let now = index < 2 ? receiptNow : candidate.absoluteFireDate.addingTimeInterval(Double(index - 2))
            XCTAssertFalse(try ledger.cancel(id: candidate.id, attemptId: attempt, proof: proof, now: now))
            ledger = try coldReceipts(ledger)
            XCTAssertEqual(try ledger.prepare(changed, now: receiptNow), .blocked)
        }
        for delivered in [false, true] {
            var ledger = CareReminderReceipts(ownerId: syncOwner)
            _ = try ledger.prepare(candidate, now: receiptNow)
            try ledger.observe(id: candidate.id, now: receiptNow, delivered: delivered, unknown: !delivered)
            ledger = try coldReceipts(ledger)
            XCTAssertEqual(try ledger.prepare(changed, now: receiptNow), .blocked)
            XCTAssertEqual(ledger.entries[candidate.id]?.phase, delivered ? .spent : .uncertain)
        }
    }

    func testReminderReceiptsRejectDeadForeignMismatchAndRetainOldRoutine() throws {
        let candidate = try receiptCandidate(occurrence: .routine(ruleId: operationId))
        var ledger = CareReminderReceipts(ownerId: syncOwner)
        XCTAssertThrowsError(try ledger.prepare(candidate, now: candidate.absoluteFireDate))
        XCTAssertThrowsError(try ledger.prepare(receiptCandidate(owner: otherSyncOwner), now: receiptNow))
        XCTAssertThrowsError(try ledger.prepare(receiptCandidate(id: "care/invalid"), now: receiptNow))
        XCTAssertThrowsError(try ledger.prepare(candidate, now: Date(timeIntervalSinceReferenceDate: .infinity)))
        _ = try ledger.prepare(candidate, now: receiptNow)
        try ledger.observe(id: candidate.id, now: candidate.absoluteFireDate)
        let spent = try coldReceipts(ledger)
        let next = try receiptCandidate(due: "2026-11-26", occurrence: .routine(ruleId: operationId))
        XCTAssertNotEqual(next.id, candidate.id)
        XCTAssertEqual(try ledger.prepare(next, now: receiptNow), .newlyPrepared)
        XCTAssertEqual(ledger.entries.count, 2)
        XCTAssertEqual(ledger.entries[candidate.id], spent.entries[candidate.id])
        XCTAssertNoThrow(try ledger.validateReplacement(of: spent))
    }

    private func reminderRow(_ id: UUID, due: String = "2026-11-26",
                             controls: [[String: Any]] = []) -> [String: Any] {
        var row = overviewRow(id, dated: true, controls: controls)
        let anchor = due == "2026-11-27" ? "2026-11-20" : "2026-11-19"
        var care = careProjection(anchor: anchor, due: due)
        care["plant_id"] = id.uuidString
        care["routine_check"] = [
            "rule_id": operationId.uuidString, "care_revision": 2, "due_local_date": due,
            "anchor_local_date": anchor, "anchor_kind": "water"
        ]
        row["care_recommendation"] = care
        return row
    }

    private func reminderControl(_ index: Int, due: String = "2026-11-25") -> [String: Any] {
        var control = overviewControl()
        control["control_id"] = String(format: "00000000-0000-4000-8000-%012d", index)
        var policy = control["policy"] as! [String: Any]
        policy["due_on"] = due
        control["policy"] = policy
        return control
    }

    private func reminderState(
        _ local: LocalCareOverviewPresentation, rows: [[String: Any]], mode: String = "",
        hour: Int = 9, deadline: String? = nil
    ) throws -> CareOverviewViewState {
        let now = SQLTimestamp.date(from: "2026-11-20T00:00:00Z")!
        var page = overviewPage(rows.sorted { ($0["plant_id"] as! String).lowercased() < ($1["plant_id"] as! String).lowercased() })
        page["reminder_hour_local"] = hour
        page["verified_access_until"] = deadline.map { $0 as Any } ?? NSNull()
        let profile = try JSONDecoder().decode(SyncWireProfileDTO.self, from: Data(syncJSON([
            "preferred_locale": "pl", "reminder_hour_local": hour, "trial_reminder_enabled": false
        ]).utf8))
        let entitlement = try deadline.map {
            try JSONDecoder().decode(SyncWireEntitlementDTO.self, from: Data(syncJSON([
                "product_id": "paid", "state": "active", "offer_kind": "paid", "valid_until": $0,
                "grace_until": NSNull(), "trial_end_at": NSNull(), "auto_renew_enabled": true
            ]).utf8))
        }
        let pending = ["plant.edit", "plant.delete", "care.record", "care.routine.undo",
                       "plant.photo", "profile.update", "global"].contains(mode)
            ? [OutboxEntrySnapshot(operationId: UUID(), ownerId: syncOwner,
                plantId: mode == "profile.update" || mode == "global" ? nil : serverPlantId,
                commandName: mode == "global" ? "care.record" : mode, payloadJSON: "{}", sequenceNumber: 1)] : []
        let cards = rows.map {
            CatalogueCardSummary(id: UUID(uuidString: $0["plant_id"] as! String)!,
                speciesSlug: nil, taxonId: nil, mainPhotoId: nil, personalName: nil,
                currentConditionSnapshotId: nil, revision: 2, careRevision: 2)
        }
        var modified = LocalCareOverviewPresentation(
            ownerId: local.ownerId, canonicalGeneration: mode == "nilGeneration" ? nil : local.canonicalGeneration,
            snapshotGeneration: mode == "generation" ? UUID() : local.snapshotGeneration,
            cached: mode == "absent" ? nil : CachedCareOverview(
                snapshot: try overviewSnapshot([page]), fetchedAt: now,
                snapshotLocale: mode == "english" ? "en" : "pl", state: .cached,
                canonicalGenerationMatches: mode != "readOnly"),
            cards: mode == "deleted" ? [] : cards, pending: pending,
            profile: mode == "nilHour" ? nil : profile, entitlement: entitlement,
            canonicalAccessKnown: mode != "unknown", careRows: []
        )
        if mode == "invalidated" { modified.knownInvalidation = .canonicalRevalidation }
        let failure: CareOverviewViewState.Failure? = mode == "offline" ? .transport
            : mode == "denied" ? .authorizationDenied : mode == "revalidate" ? .revalidationRequired : nil
        return CareOverviewViewState(local: modified, now: now, origin: .cache, failure: failure)
    }

    private func reminderPlan(
        _ state: CareOverviewViewState?, owner: UUID? = nil, optedIn: Bool = true,
        authorization: CareReminderPlan.Authorization = .authorized, locale: String = "pl",
        now: String = "2026-11-20T00:00:00Z", zone: TimeZone? = nil
    ) -> CareReminderPlan {
        CareReminderPlan(expectedOwnerId: owner ?? syncOwner, state: state, optedIn: optedIn,
            authorization: authorization, now: SQLTimestamp.date(from: now)!,
            timeZone: zone ?? TimeZone(secondsFromGMT: 0)!, locale: locale)
    }

    @MainActor
    func testCareReminderAllOccurrencesIdentityOrderingAndCapacity() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        let controls = (1...40).map { reminderControl($0, due: $0 % 2 == 0 ? "2026-11-27" : "2026-11-25") }
        let row = reminderRow(serverPlantId, controls: controls)
        let state = try reminderState(local, rows: [row])
        let plan = reminderPlan(state)
        XCTAssertEqual(plan.eligibleCandidateCount, 41)
        XCTAssertEqual(plan.requests.count, 32)
        XCTAssertEqual(plan.omittedCount, 9)
        XCTAssertEqual(Set(plan.candidates.map(\.id)).count, 41)
        XCTAssertEqual(CareReminderPlan.orderedUnique(plan.candidates + Array(plan.candidates.reversed())),
                       plan.candidates)
        let shifted = reminderPlan(state, zone: try XCTUnwrap(TimeZone(identifier: "America/New_York")))
        XCTAssertEqual(shifted.candidates.map(\.id), plan.candidates.map(\.id))
        XCTAssertNotEqual(shifted.candidates.first?.absoluteFireDate, plan.candidates.first?.absoluteFireDate)
        XCTAssertTrue(plan.candidates.contains { $0.sourceDueYMD == "2026-11-27" })
        XCTAssertEqual(TodayCalendar(state: state, now: SQLTimestamp.date(from: "2026-11-20T00:00:00Z")!).sections.count, 1)
        XCTAssertEqual(plan, reminderPlan(try reminderState(local, rows: [
            reminderRow(serverPlantId, controls: Array(controls.reversed()))
        ])))
        let moved = reminderPlan(try reminderState(local, rows: [
            reminderRow(serverPlantId, due: "2026-11-27", controls: [reminderControl(1, due: "2026-11-28")])
        ], mode: "english", hour: 10), locale: "en")
        let first = try XCTUnwrap(plan.candidates.first { $0.occurrence == .firstAid(controlId:
            UUID(uuidString: "00000000-0000-4000-8000-000000000001")!) })
        let changed = try XCTUnwrap(moved.candidates.first { $0.id == first.id })
        XCTAssertNotEqual(changed.sourceDueYMD, first.sourceDueYMD)
        XCTAssertNotEqual(changed.absoluteFireDate, first.absoluteFireDate)
        XCTAssertEqual(changed.locale, "en")
        var receipts = CareReminderReceipts(ownerId: syncOwner)
        let beforeFire = SQLTimestamp.date(from: "2026-11-20T00:00:00Z")!
        XCTAssertEqual(try receipts.prepare(first, now: beforeFire), .newlyPrepared)
        receipts = try coldReceipts(receipts)
        XCTAssertEqual(try receipts.prepare(changed, now: beforeFire), .blocked)
        let routine = try XCTUnwrap(plan.candidates.first { $0.occurrence == .routine(ruleId: operationId) })
        XCTAssertTrue(routine.id.hasSuffix("/routine/\(operationId.uuidString.lowercased())/2026-11-26"))
        XCTAssertFalse(moved.candidates.contains { $0.id == routine.id })
        // The accepted shared DTO also rejects repeated identities before projection.
        XCTAssertThrowsError(try reminderState(local, rows: [
            reminderRow(serverPlantId, controls: [controls[0], controls[0]])
        ]))
    }

    @MainActor
    func testCareReminderOwnerPermissionAndSharedEligibilityGates() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        let rows = [reminderRow(serverPlantId), reminderRow(otherSyncOwner)]
        let state = try reminderState(local, rows: rows)
        XCTAssertEqual(reminderPlan(state).eligibleCandidateCount, 2)
        for authorization in [CareReminderPlan.Authorization.notDetermined, .denied, .authorized] {
            for optedIn in [true, false] {
                let plan = reminderPlan(state, optedIn: optedIn, authorization: authorization)
                XCTAssertEqual(plan.eligibleCandidateCount, 2)
                XCTAssertEqual(plan.requests.count, optedIn && authorization == .authorized ? 2 : 0)
            }
        }
        XCTAssertTrue(reminderPlan(state, owner: otherSyncOwner).candidates.isEmpty)
        for locale in ["en", "de", "pl-PL", ""] {
            XCTAssertTrue(reminderPlan(state, locale: locale).candidates.isEmpty)
        }
        XCTAssertTrue(reminderPlan(nil).candidates.isEmpty)
        for mode in ["unknown", "readOnly", "generation", "nilGeneration", "absent", "nilHour",
                     "profile.update", "global", "deleted", "invalidated", "denied", "revalidate"] {
            XCTAssertTrue(reminderPlan(try reminderState(local, rows: rows, mode: mode)).candidates.isEmpty, mode)
        }
        for mode in ["plant.edit", "plant.delete", "care.record", "care.routine.undo", "plant.photo"] {
            let plan = reminderPlan(try reminderState(local, rows: rows, mode: mode))
            XCTAssertEqual(plan.candidates.map(\.plantId), [otherSyncOwner], mode)
        }
        XCTAssertEqual(reminderPlan(state), reminderPlan(try reminderState(local, rows: rows, mode: "offline")))
        XCTAssertTrue(reminderPlan(try reminderState(local, rows: [overviewRow(serverPlantId)])).candidates.isEmpty)
    }

    @MainActor
    func testCareReminderExpiryAndNoCatchUp() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        let rows = [reminderRow(serverPlantId, controls: [reminderControl(1)])]
        let free = try reminderState(local, rows: rows)
        XCTAssertEqual(free.access, .free)
        XCTAssertEqual(reminderPlan(free).requests.count, 2)
        for (deadline, count) in [("2026-11-20T00:00:00Z", 0), ("2026-11-25T09:00:00Z", 0),
                                  ("2026-11-26T09:00:00Z", 1), ("2026-11-26T09:00:01Z", 2)] {
            let state = try reminderState(local, rows: rows, deadline: deadline)
            XCTAssertEqual(reminderPlan(state).requests.count, count, deadline)
        }
        XCTAssertEqual(reminderPlan(free, now: "2026-11-25T09:00:00Z").requests.count, 1)
        for now in ["2026-11-26T09:00:00Z", "2026-11-27T00:00:00Z"] {
            XCTAssertTrue(reminderPlan(free, now: now).candidates.isEmpty)
        }
    }

    func testCareReminderGregorianSourceDayDSTAndInvalidDates() throws {
        let cases: [(String, Int, String, String?)] = [
            ("2026-03-08", 2, "America/New_York", "2026-03-08T07:00:00Z"),
            ("2026-11-01", 1, "America/New_York", "2026-11-01T05:00:00Z"),
            ("2011-12-30", 9, "Pacific/Apia", nil),
            ("2026-11-26", 9, "America/Los_Angeles", "2026-11-26T17:00:00Z"),
            ("2026-11-26", 0, "America/Los_Angeles", "2026-11-26T08:00:00Z"),
            ("2026-11-26", 23, "Etc/UTC", "2026-11-26T23:00:00Z"),
            ("2026-02-30", 9, "Etc/UTC", nil), ("2026-2-03", 9, "Etc/UTC", nil),
            ("2026-11-26", -1, "Etc/UTC", nil), ("2026-11-26", 24, "Etc/UTC", nil)
        ]
        for (day, hour, zone, expected) in cases {
            let actual = CareReminderPlan.resolve(sourceYMD: day, hour: hour,
                                                  timeZone: try XCTUnwrap(TimeZone(identifier: zone)))
            XCTAssertEqual(actual, expected.flatMap(SQLTimestamp.date(from:)), "\(day) \(hour) \(zone)")
        }
        let ny = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertNotEqual(CareReminderPlan.resolve(sourceYMD: "2026-11-26", hour: 9, timeZone: ny),
                          CareReminderPlan.resolve(sourceYMD: "2026-11-26", hour: 9, timeZone: utc))
    }
}

@MainActor
private final class TodayReadBarrier {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func wait() async {
        await withCheckedContinuation {
            release = $0
            entered = true
            arrival?.resume()
            arrival = nil
        }
    }

    func open() {
        release?.resume()
        release = nil
    }
}

extension CollectionWireTests {
    @MainActor
    func testTodayLatestLocalWaitPreservesAuthorizedPassAndFencesInvalidation() async throws {
        for mode in ["ready", "cancel", "owner", "locale", "generation", "failure", "localCancel"] {
            var page = overviewPage([overviewRow(serverPlantId, dated: true)])
            page["verified_access_until"] = NSNull()
            let transport = CatalogueTransport([.http(200, try syncJSON(page))])
            let (url, _, api, lease, repo) = try await overviewRepositoryFixture(transport)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let model = TodayModel()
            let scope = model.activate(ownerId: lease.ownerId, generation: lease.generation, locale: .pl)
            let cached = try await repo.cachedCareOverview(context: lease)
            let coordinator = CareLifecycleCoordinator()
            let first = TodayReadBarrier(), second = TodayReadBarrier()
            var revision: UInt64 = 0
            var local: Task<Void, Never>?
            func requestLocal(_ gate: TodayReadBarrier?, fail: Bool = false) {
                revision &+= 1
                local?.cancel()
                local = Task { @MainActor in
                    await model.rereadLocal(scope: scope) {
                        if let gate { await gate.wait() }
                        if fail { throw URLError(.notConnectedToInternet) }
                        return cached
                    }
                }
            }
            requestLocal(first)
            await first.waitUntilEntered()
            let l1 = try XCTUnwrap(local)
            let capturedFirst = expectation(description: "external pass awaits L1: \(mode)")
            let capturedSecond = expectation(description: "external pass follows L2: \(mode)")
            let finished = expectation(description: "external pass finished: \(mode)")
            var sawFirst = false, sawSecond = false, didFinish = false
            var passes = 0
            coordinator.request {
                passes += 1
                defer { didFinish = true; finished.fulfill() }
                do {
                    try await TodayModel.waitLatestLocalRead(current: {
                        if revision == 1 && !sawFirst {
                            sawFirst = true
                            capturedFirst.fulfill()
                        }
                        if revision == 2 && !sawSecond {
                            sawSecond = true
                            capturedSecond.fulfill()
                        }
                        return (revision, local)
                    }, validate: {
                        guard model.scope == scope else { throw CancellationError() }
                        try api.syncAuthority.withPermanentBoundValid(lease) {}
                    })
                    guard !model.needsLocalRead else { return .completed }
                    await model.refresh(scope: scope) {
                        try Task.checkCancellation()
                        return try await repo.refreshCareOverview(locale: scope.locale, context: lease)
                    }
                    return .completed
                } catch {
                    return nil
                }
            }
            await fulfillment(of: [capturedFirst], timeout: 1)
            requestLocal(second, fail: mode == "failure")
            let l2 = try XCTUnwrap(local)
            await second.waitUntilEntered()
            first.open()
            await l1.value
            await fulfillment(of: [capturedSecond], timeout: 1)
            XCTAssertFalse(didFinish, mode)
            XCTAssertTrue(model.needsLocalRead, mode)
            let before = await transport.capturedRequests()
            XCTAssertTrue(before.isEmpty, mode)
            switch mode {
            case "cancel": coordinator.suspend()
            case "owner":
                await api.bindSyncSession(try profileSession(ownerId: otherSyncOwner))
                model.activate(ownerId: otherSyncOwner, generation: lease.generation, locale: .pl)
            case "locale":
                model.activate(ownerId: lease.ownerId, generation: lease.generation, locale: .en)
            case "generation":
                model.activate(ownerId: lease.ownerId, generation: lease.generation + 1, locale: .pl)
            case "localCancel": l2.cancel()
            default: break
            }
            second.open()
            await l2.value
            await fulfillment(of: [finished], timeout: 1)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, mode == "ready" ? 1 : 0, mode)
            XCTAssertEqual(passes, 1, mode)
            if ["owner", "locale", "generation", "localCancel", "failure"].contains(mode) {
                XCTAssertNil(model.state, mode)
            }
            if mode == "ready" {
                XCTAssertEqual(requests.first?.httpMethod, "GET")
                XCTAssertEqual(model.state?.origin, .network)
                // A subsequent canonical/local notification owns only a cache read.
                requestLocal(nil)
                await local?.value
                coordinator.didBecomeIdle()
                let afterLocal = await transport.capturedRequests()
                XCTAssertEqual(afterLocal.count, 1)
                XCTAssertEqual(passes, 1)
            }
            let worker = coordinator.suspend()
            await worker?.value
        }
    }

    @MainActor
    func testTodayRefreshCannotRestoreDatesOverDurableLocalOverlay() async throws {
        let (url, store, api, lease, repo) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = TodayModel()
        let scope = model.activate(ownerId: lease.ownerId, generation: lease.generation, locale: .pl)
        let old = try await repo.cachedCareOverview(context: lease)
        await model.rereadLocal(scope: scope) { old }
        XCTAssertEqual(model.state?.plants.first?.routine?.dueLocalDate, "2026-11-05")
        let gate = TodayReadBarrier()
        let refresh = Task { await model.refresh(scope: scope) { await gate.wait(); return old } }
        await gate.waitUntilEntered()
        let events = await store.localOutboxUpdates(ownerId: lease.ownerId)
        var iterator = events.makeAsyncIterator()
        let care = try ManualWateringAction.record.envelope(plantId: serverPlantId)
        try await store.enqueueSavedPlantWatering(care, context: lease, authority: api.syncAuthority)
        let signal = await iterator.next()
        XCTAssertNotNil(signal)
        let localGate = TodayReadBarrier()
        let local = Task {
            await model.rereadLocal(scope: scope) {
                await localGate.wait()
                return try await repo.cachedCareOverview(context: lease)
            }
        }
        await localGate.waitUntilEntered()
        XCTAssertNil(model.state)
        XCTAssertTrue(model.needsLocalRead)
        XCTAssertFalse(model.refreshing)
        localGate.open()
        await local.value
        XCTAssertEqual(model.state?.pending.map(\.operationId), [care.operationId])
        XCTAssertNil(model.state?.plants.first?.routine)
        gate.open()
        await refresh.value
        XCTAssertEqual(model.state?.pending.map(\.operationId), [care.operationId])
        XCTAssertNil(model.state?.plants.first?.routine)
        XCTAssertFalse(model.state?.plants.first?.automatedActionsAllowed ?? true)
        XCTAssertFalse(model.readingLocal)
        XCTAssertFalse(model.refreshing)
        XCTAssertFalse(model.hasError)
    }

    @MainActor
    func testTodayOverlappingLocalReadsFenceOldSuccessAndFailure() async throws {
        let (url, store, api, lease, repo) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let old = try await repo.cachedCareOverview(context: lease)
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        let latest = CareOverviewViewState(local: local, now: Date(), origin: .network)
        for fail in [false, true] {
            let model = TodayModel()
            let scope = model.activate(ownerId: lease.ownerId, generation: lease.generation, locale: .pl)
            let first = TodayReadBarrier(), second = TodayReadBarrier()
            let a = Task {
                await model.rereadLocal(scope: scope) {
                    await first.wait()
                    if fail { throw URLError(.notConnectedToInternet) }
                    return old
                }
            }
            await first.waitUntilEntered()
            let b = Task {
                await model.rereadLocal(scope: scope) { await second.wait(); return latest }
            }
            await second.waitUntilEntered()
            first.open()
            await a.value
            XCTAssertNil(model.state)
            XCTAssertTrue(model.readingLocal)
            XCTAssertTrue(model.needsLocalRead)
            XCTAssertFalse(model.hasError)
            second.open()
            await b.value
            XCTAssertEqual(model.state?.origin, .network)
            XCTAssertFalse(model.readingLocal)
            XCTAssertFalse(model.needsLocalRead)
            XCTAssertFalse(model.hasError)
        }
    }

    @MainActor
    func testTodayScopeABAReactivationLocaleAndSuspendFenceLateCallbacks() async throws {
        var page = overviewPage([overviewRow(serverPlantId, dated: true)])
        page["verified_access_until"] = NSNull()
        let transport = CatalogueTransport([.http(200, try syncJSON(page))])
        let (url, _, _, lease, repo) = try await overviewRepositoryFixture(transport)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let old = try await repo.cachedCareOverview(context: lease)
        for mode in 0..<5 {
            let model = TodayModel()
            let scope = model.activate(ownerId: lease.ownerId, generation: lease.generation, locale: .pl)
            await model.rereadLocal(scope: scope) { old }
            let gate = TodayReadBarrier()
            let task = Task {
                await model.refresh(scope: scope) {
                    await gate.wait()
                    if mode.isMultiple(of: 2) { throw URLError(.notConnectedToInternet) }
                    return old
                }
            }
            await gate.waitUntilEntered()
            switch mode {
            case 0: model.suspend()
            case 1:
                model.activate(ownerId: otherSyncOwner, generation: lease.generation, locale: .pl)
                model.activate(ownerId: lease.ownerId, generation: lease.generation, locale: .pl)
            case 2: model.activate(ownerId: lease.ownerId, generation: lease.generation, locale: .en)
            case 3: model.activate(ownerId: lease.ownerId, generation: lease.generation + 1, locale: .pl)
            default: model.activate(ownerId: lease.ownerId, generation: lease.generation, locale: .pl)
            }
            XCTAssertNotEqual(model.scope, scope)
            XCTAssertNil(model.state)
            XCTAssertFalse(model.refreshing)
            gate.open()
            await task.value
            var staleCalls = 0
            await model.rereadLocal(scope: scope) { staleCalls += 1; return old }
            XCTAssertEqual(staleCalls, 0)
            XCTAssertNil(model.state)
            XCTAssertTrue(model.needsLocalRead)
            XCTAssertFalse(model.readingLocal)
            XCTAssertFalse(model.refreshing)
            XCTAssertFalse(model.hasError)
        }

        // The durable cache still contains PL after EN activation. A completed local
        // read must hide it without blocking the explicit EN network refresh.
        let model = TodayModel()
        let scope = model.activate(ownerId: lease.ownerId, generation: lease.generation, locale: .en)
        await model.rereadLocal(scope: scope) { try await repo.cachedCareOverview(context: lease) }
        XCTAssertNil(model.state)
        XCTAssertFalse(model.needsLocalRead)
        XCTAssertTrue(model.needsRevalidation)
        XCTAssertFalse(model.readingLocal)
        let gate = TodayReadBarrier()
        let refresh = Task {
            await model.refresh(scope: scope) {
                await gate.wait()
                return try await repo.refreshCareOverview(locale: .en, context: lease)
            }
        }
        await gate.waitUntilEntered()
        XCTAssertTrue(model.refreshing)
        XCTAssertNil(model.state)
        gate.open()
        await refresh.value
        XCTAssertEqual(model.state?.snapshotLocale, "en")
        XCTAssertEqual(model.state?.origin, .network)
        XCTAssertFalse(model.refreshing)
        XCTAssertFalse(model.needsLocalRead)
        XCTAssertFalse(model.needsRevalidation)
        XCTAssertFalse(model.hasError)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Client-Locale"), "en")
    }

    @MainActor
    func testTodayCancellationCannotPublishSuccessOrError() async throws {
        let (url, _, _, lease, repo) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let old = try await repo.cachedCareOverview(context: lease)
        for local in [false, true] {
            for fail in [false, true] {
                let model = TodayModel()
                let scope = model.activate(ownerId: lease.ownerId, generation: lease.generation, locale: .pl)
                await model.rereadLocal(scope: scope) { old }
                let gate = TodayReadBarrier()
                let task = Task {
                    let read: @MainActor () async throws -> CareOverviewViewState = {
                        await gate.wait()
                        if fail { throw URLError(.cancelled) }
                        return old
                    }
                    if local { await model.rereadLocal(scope: scope, read: read) }
                    else { await model.refresh(scope: scope, read: read) }
                }
                await gate.waitUntilEntered()
                task.cancel()
                gate.open()
                await task.value
                XCTAssertFalse(model.refreshing)
                XCTAssertFalse(model.readingLocal)
                XCTAssertFalse(model.hasError)
                XCTAssertEqual(model.needsLocalRead, local)
                if local { XCTAssertNil(model.state) }
                else { XCTAssertEqual(model.state?.origin, .cache) }
            }
        }
    }

    @MainActor
    func testTodayVerifiedDeadlineUsesExactMinimumAndRetainsAccessContract() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        let canonicalRaw = "2026-12-01T00:00:00.123456Z"
        let canonical = try XCTUnwrap(SQLTimestamp.date(from: canonicalRaw))
        let now = try XCTUnwrap(SQLTimestamp.date(from: "2026-11-20T00:00:00Z"))
        let entitlement = try JSONDecoder().decode(SyncWireEntitlementDTO.self, from: Data(syncJSON([
            "product_id": "paid", "state": "grace", "offer_kind": "paid",
            "valid_until": canonicalRaw, "grace_until": "2027-01-01T00:00:00Z",
            "trial_end_at": NSNull(), "auto_renew_enabled": true
        ]).utf8))
        func project(_ server: String?, paid: Bool = true, known: Bool = true, at: Date) throws -> CareOverviewViewState {
            var page = overviewPage([overviewRow(serverPlantId, dated: true)])
            page["verified_access_until"] = server.map { $0 as Any } ?? NSNull()
            let modified = LocalCareOverviewPresentation(
                ownerId: local.ownerId, canonicalGeneration: local.canonicalGeneration,
                snapshotGeneration: local.snapshotGeneration,
                cached: CachedCareOverview(
                    snapshot: try overviewSnapshot([page]), fetchedAt: now, snapshotLocale: "pl",
                    state: .cached, canonicalGenerationMatches: true
                ),
                cards: local.cards, pending: [], profile: local.profile,
                entitlement: paid ? entitlement : nil, canonicalAccessKnown: known, careRows: []
            )
            return CareOverviewViewState(local: modified, now: at, origin: .cache)
        }
        let earlyRaw = "2026-11-25T00:00:00.654321Z"
        let early = try XCTUnwrap(SQLTimestamp.date(from: earlyRaw))
        XCTAssertEqual(try project(earlyRaw, at: now).verifiedAccessUntil, early)
        XCTAssertEqual(try project("2026-12-10T00:00:00Z", at: now).verifiedAccessUntil, canonical)
        XCTAssertEqual(try project(nil, at: now).verifiedAccessUntil, canonical)
        let expired = try project(earlyRaw, at: canonical)
        XCTAssertEqual(expired.access, .expired)
        XCTAssertEqual(expired.verifiedAccessUntil, early)
        XCTAssertNil(expired.plants.first?.routine)
        XCTAssertTrue(expired.plants.first?.manualJournalAvailable == true)
        let free = try project(nil, paid: false, at: now)
        XCTAssertEqual(free.access, .free)
        XCTAssertNil(free.verifiedAccessUntil)
        let unknown = try project(nil, paid: false, known: false, at: now)
        XCTAssertEqual(unknown.access, .unknown)
        XCTAssertNil(unknown.verifiedAccessUntil)
        XCTAssertNil(unknown.plants.first?.routine)
    }
}

private actor SavedWateringReplayTransport: PlantsAPITransport {
    private let baseline: String
    private let plantId: UUID
    private let entryId = UUID()
    private var accepted: CommandEnvelopeDTO?
    private var lostResponse = false
    private var requests: [URLRequest] = []

    init(baseline: String, plantId: UUID) {
        self.baseline = baseline
        self.plantId = plantId
    }

    func capturedRequests() -> [URLRequest] { requests }
    func journalCount() -> Int { accepted == nil ? 0 : 1 }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let watermark = "2026-11-03T09:10:00.000001+00:00"
        var object: [String: Any]
        if request.httpMethod == "POST" {
            let command = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(request.httpBody))
            XCTAssertEqual(command.plantId, plantId)
            XCTAssertEqual(ManualWateringAction(envelope: command), .record)
            if let accepted { XCTAssertEqual(command, accepted) } else { accepted = command }
            if !lostResponse {
                lostResponse = true
                throw URLError(.networkConnectionLost) // Committed before losing the response.
            }
            object = ["plant_id": plantId.uuidString, "entry_id": entryId.uuidString,
                      "reversal_id": NSNull(), "state": "active", "watermark": watermark]
        } else {
            object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(baseline.utf8)) as? [String: Any])
            if let accepted {
                object["until"] = watermark
                object["next_since"] = watermark
                // The saved plant is already at the requested since watermark.
                var rows: [[String: Any]] = []
                rows.append([
                    "entity_type": "care_entries", "id": entryId.uuidString,
                    "updated_at": watermark, "deleted_at": NSNull(),
                    "data": ["id": entryId.uuidString, "plant_id": plantId.uuidString,
                             "operation_id": accepted.operationId.uuidString, "task_id": NSNull(),
                             "action_code": "water", "state": "active", "timezone": "UTC",
                             "occurred_at": "2026-11-02T07:00:00Z", "occurred_local_date": "2026-11-02"]
                ])
                object["changes"] = rows
                // A canonical final pull at the accepted watermark is an empty delta.
                // Compare parsed instants, not equivalent timestamp spellings.
                let since = request.url.flatMap {
                    URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name == "since" })?.value
                }
                if let since, let start = SQLTimestamp.microseconds(from: since),
                   let acceptedAt = SQLTimestamp.microseconds(from: watermark), start >= acceptedAt {
                    object["changes"] = []
                }
            }
        }
        return (try JSONSerialization.data(withJSONObject: object),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension CollectionWireTests {
    private func savedWateringBaseline(_ state: String = "none") throws -> String {
        var page = syncObject()
        var plant = syncChange(id: serverPlantId.uuidString)
        plant["data"] = ["id": serverPlantId.uuidString, "revision": 1, "care_revision": 1]
        page["changes"] = [plant] // No plant profile, rule, membership, or create receipt.
        if state != "none" {
            var entitlement = paidSyncEntitlement()
            entitlement["state"] = state
            page["entitlement"] = entitlement
        }
        return try syncJSON(page)
    }

    @MainActor
    func testSavedWateringLostAcceptedResponseReplaysFromDiskWithoutCareOrCreateProof() async throws {
        for state in ["none", "paused", "expired"] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = SavedWateringReplayTransport(baseline: try savedWateringBaseline(state), plantId: serverPlantId)
            let frozen: CommandEnvelopeDTO
            do {
                let api = client(transport)
                await api.bindSyncSession(try profileSession())
                let lease = try await api.captureSyncContext(ownerId: syncOwner)
                let store = LocalStore(modelContainer: try diskContainer(url))
                let engine = SyncEngine(store: store, apiClient: api)
                _ = try await engine.pullDelta(for: syncOwner)
                let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
                let proof = try await store.catalogueCreateConfirmation(ownerId: syncOwner, operationId: operationId)
                XCTAssertNil(proof)
                try await repo.enqueueWateringEdit(.record, plantId: serverPlantId, context: lease)
                let pending = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
                frozen = try XCTUnwrap(pending)
                let repeated = try await repo.enqueueSavedPlantWatering(
                    plantId: serverPlantId, date: Date(), timezone: TimeZone(secondsFromGMT: 0)!, context: lease
                )
                XCTAssertEqual(repeated, frozen)
                let outcome = try await repo.retrySavedPlantWatering(frozen, context: lease)
                XCTAssertEqual(outcome, .pending)
                let count = await transport.journalCount()
                XCTAssertEqual(count, 1)
            }
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            let restored = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
            XCTAssertEqual(restored, frozen)
            let outcome = try await repo.retrySavedPlantWatering(frozen, context: lease)
            let repeated = try await repo.retrySavedPlantWatering(frozen, context: lease)
            XCTAssertEqual(outcome, .confirmed)
            XCTAssertEqual(repeated, .confirmed)
            let posts = await transport.capturedRequests().filter { $0.httpMethod == "POST" }
            XCTAssertEqual(posts.count, 2)
            XCTAssertEqual(posts.first?.httpBody, posts.last?.httpBody)
            XCTAssertEqual(posts.first?.value(forHTTPHeaderField: "X-Operation-Id"),
                           posts.last?.value(forHTTPHeaderField: "X-Operation-Id"))
            let count = await transport.journalCount()
            XCTAssertEqual(count, 1)
            let rows = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "care_entries")
            let remaining = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(rows.count, 1)
            XCTAssertTrue(remaining.isEmpty)
            let fact = try JSONDecoder().decode(CatalogueCareJournalEntry.self, from: Data(XCTUnwrap(rows.first).payloadJSON.utf8))
            XCTAssertEqual(fact.operationId, frozen.operationId)
            XCTAssertEqual(fact.occurredAt, "2026-11-02T07:00:00Z")
        }
    }

    @MainActor
    func testSavedWateringGuardsLeaveDiskAndTransportUntouched() async throws {
        for mode in ["missing", "deleted", "foreign", "malformed", "deleting", "competing",
                     "other-record", "future", "invalid-date", "invalid-payload", "anonymous", "stale", "aba"] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = CatalogueTransport([])
            let api = client(transport)
            await api.bindSyncSession(try profileSession(claims: [
                "sub": syncOwner.uuidString, "is_anonymous": mode == "anonymous"
            ]))
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            if mode != "missing" {
                let payload = try syncJSON(["id": serverPlantId.uuidString, "revision": 1, "care_revision": 1])
                try await store.applySyncedItems([
                    SyncItemDTO(entityType: "plants", id: serverPlantId, updatedAt: Date(),
                                deletedAt: mode == "deleted" ? Date() : nil,
                                payloadJSON: mode == "deleted" ? "null" : mode == "malformed" ? "{}" : payload)
                ], ownerId: mode == "foreign" ? otherSyncOwner : syncOwner)
            }
            if mode == "deleting" { _ = try await repo.enqueuePlantDeletion(plantId: serverPlantId, context: lease) }
            if mode == "competing" {
                let command = try ManualWateringAction.undo(UUID()).envelope(plantId: serverPlantId)
                _ = try await store.enqueueCommand(operationId: command.operationId, ownerId: syncOwner,
                    plantId: serverPlantId, commandName: command.commandName, payloadJSON: command.payloadJSON)
            }
            if mode == "other-record" {
                let command = try ManualWateringAction.record.envelope(plantId: serverPlantId)
                try await store.enqueueSavedPlantWatering(command, context: lease, authority: api.syncAuthority)
            }
            if mode == "stale" || mode == "aba" {
                await api.bindSyncSession(try profileSession(ownerId: otherSyncOwner))
                if mode == "aba" { await api.bindSyncSession(try profileSession()) }
            }
            let before = try await store.pendingOutboxEntries(for: syncOwner)
            do {
                if mode == "other-record" || mode == "invalid-payload" {
                    let command = mode == "other-record"
                        ? try ManualWateringAction.record.envelope(plantId: serverPlantId)
                        : CommandEnvelopeDTO(operationId: UUID(), commandName: "care.record",
                                             plantId: serverPlantId, payloadJSON: "{}")
                    try await store.enqueueSavedPlantWatering(command, context: lease, authority: api.syncAuthority)
                } else {
                    let date = mode == "future" ? Date().addingTimeInterval(3600)
                        : mode == "invalid-date" ? Date(timeIntervalSince1970: .nan) : Date()
                    _ = try await repo.enqueueSavedPlantWatering(
                        plantId: serverPlantId, date: date, timezone: TimeZone(secondsFromGMT: 0)!, context: lease
                    )
                }
                XCTFail("Unexpected enqueue: \(mode)")
            } catch is SyncWireValidationError {
            } catch is OutboxEnqueueError {}
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let after = try await reopened.pendingOutboxEntries(for: syncOwner)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(after, before, mode)
            XCTAssertTrue(requests.isEmpty, mode)
        }
    }

    @MainActor
    func testSavedWateringTerminalRetryRejectsWithoutChangingGenericDrainSemantics() async throws {
        for (status, code) in [(400, "VALIDATION_ERROR"), (403, "FORBIDDEN"), (404, "NOT_FOUND"), (409, "CONFLICT")] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let error = try syncJSON(["error": ["code": code, "message": "Fixture rejection", "retryable": false]])
            let transport = CatalogueTransport([
                .http(200, try savedWateringBaseline()), .http(status, error), .http(status, error)
            ])
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let engine = SyncEngine(store: store, apiClient: api)
            _ = try await engine.pullDelta(for: syncOwner)
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
            try await repo.enqueueWateringEdit(.record, plantId: serverPlantId, context: lease)
            let first = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
            let command = try XCTUnwrap(first)
            let committed = try await engine.flushOutbox(context: lease)
            let retained = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
            XCTAssertEqual(committed, 0)
            XCTAssertEqual(retained, command)
            let rejected = try await repo.retrySavedPlantWatering(command, context: lease)
            let absent = try await repo.retrySavedPlantWatering(command, context: lease)
            XCTAssertEqual(rejected, .rejected)
            XCTAssertEqual(absent, .unconfirmed)
            let remaining = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertTrue(remaining.isEmpty)
            try await repo.enqueueWateringEdit(.record, plantId: serverPlantId, context: lease)
            let next = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
            XCTAssertNotEqual(try XCTUnwrap(next).operationId, command.operationId)
        }
    }
}

extension CollectionWireTests {
    @MainActor
    func testProfileOutboxRejectsBoundGuestOrUnprovenAccountBeforeDiskAndHTTP() async throws {
        let invalidClaims: [[String: Any]] = [
            ["sub": syncOwner.uuidString, "is_anonymous": true],
            ["sub": syncOwner.uuidString],
            ["sub": otherSyncOwner.uuidString, "is_anonymous": false],
            ["is_anonymous": false],
            ["sub": syncOwner.uuidString, "is_anonymous": "false"],
            ["sub": syncOwner.uuidString, "is_anonymous": 0]
        ]
        let sessions = try invalidClaims.map { try profileSession(claims: $0) } + [syncSession]
        for session in sessions {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = CatalogueTransport([])
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let oldLease = try await api.captureSyncContext(ownerId: syncOwner)
            // A permanent binding must not lend proof to a later guest with the same owner.
            await api.bindSyncSession(session)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let engine = SyncEngine(store: store, apiClient: api)
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
            for context in [oldLease, lease] {
                do {
                    _ = try await repo.enqueueProfileReminderHour(reminderHourLocal: 10, context: context)
                    XCTFail("Unproven or stale account must not enqueue")
                } catch SyncWireValidationError.invalidSession {}
            }
            let emptyStore = LocalStore(modelContainer: try diskContainer(url))
            let empty = try await emptyStore.pendingOutboxEntries(for: syncOwner)
            XCTAssertTrue(empty.isEmpty)

            // Seed an existing disk command to exercise retry and background draining independently.
            let command = try ProfileReminderHourCommand.make(reminderHourLocal: 10)
            _ = try await store.enqueueCommand(
                operationId: command.envelope.operationId, ownerId: syncOwner, plantId: nil,
                commandName: command.envelope.commandName, payloadJSON: command.envelope.payloadJSON
            )
            for action in 0..<5 {
                do {
                    switch action {
                    case 0:
                        _ = try await repo.pendingProfileReminderHour(context: lease)
                    case 1:
                        _ = try await repo.retryProfileReminderHour(command, context: lease)
                    case 2:
                        _ = try await engine.flushOutbox(context: lease)
                    case 3:
                        _ = try await api.updateProfileReminderHour(command, context: lease)
                    default:
                        _ = try await store.finishProfileReminderHour(
                            command, receipt: nil, context: lease, authority: api.syncAuthority
                        )
                    }
                    XCTFail("Unproven account must not read, dispatch or acknowledge profile.update")
                } catch SyncWireValidationError.invalidSession {}
            }
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let rows = try await reopened.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(rows.map(\.envelope), [command.envelope])
            XCTAssertEqual(rows.first?.retryCount, 0)
            let profile = try await reopened.syncedProfile(ownerId: syncOwner)
            XCTAssertNil(profile)
            let requests = await transport.capturedRequests()
            XCTAssertTrue(requests.isEmpty)

            // Returning to the original permanent account requires a fresh generation.
            await api.bindSyncSession(try profileSession())
            do {
                _ = try await repo.pendingProfileReminderHour(context: oldLease)
                XCTFail("ABA must not revive the original lease")
            } catch SyncWireValidationError.invalidSession {}
            let freshLease = try await api.captureSyncContext(ownerId: syncOwner)
            let saved = try await repo.pendingProfileReminderHour(context: freshLease)
            XCTAssertEqual(saved?.envelope, command.envelope)
        }
    }

    @MainActor
    func testProfileOutboxLostReplyReopensExactOperationAndConfirmsLatestHour() async throws {
        // Exact replay can confirm the original value, a no-op, or a newer external value.
        for latestHour in [9, 17] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let command: ProfileReminderHourCommand
            let firstBody: Data
            let foreign = try ProfileReminderHourCommand.make(reminderHourLocal: 4)
            let globalId = UUID()
            let plantId = UUID()
            do {
                let transport = CatalogueTransport([.network])
                let api = client(transport)
                await api.bindSyncSession(try profileSession())
                let lease = try await api.captureSyncContext(ownerId: syncOwner)
                let store = LocalStore(modelContainer: try diskContainer(url))
                let engine = SyncEngine(store: store, apiClient: api)
                let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
                command = try await repo.enqueueProfileReminderHour(reminderHourLocal: 9, context: lease)
                let same = try await repo.enqueueProfileReminderHour(reminderHourLocal: 9, context: lease)
                XCTAssertEqual(same.envelope, command.envelope)
                do {
                    _ = try await repo.enqueueProfileReminderHour(reminderHourLocal: 10, context: lease)
                    XCTFail("Cannot replace an unresolved operation")
                } catch OutboxEnqueueError.operationIdentityMismatch {}
                _ = try await store.enqueueCommand(
                    operationId: foreign.envelope.operationId, ownerId: otherSyncOwner, plantId: nil,
                    commandName: "profile.update", payloadJSON: foreign.envelope.payloadJSON
                )
                for (id, plant) in [(globalId, Optional<UUID>.none), (plantId, Optional(serverPlantId))] {
                    _ = try await store.enqueueCommand(
                        operationId: id, ownerId: syncOwner, plantId: plant,
                        commandName: "fixture.unrelated", payloadJSON: "{}"
                    )
                }
                let outcome = try await repo.retryProfileReminderHour(command, context: lease)
                XCTAssertEqual(outcome, .pending)
                let profile = try await store.syncedProfile(ownerId: syncOwner)
                XCTAssertNil(profile)
                do {
                    try await store.finishOutboxEntry(
                        operationId: command.envelope.operationId, context: lease, authority: api.syncAuthority
                    )
                    XCTFail("Generic deletion cannot acknowledge profile.update")
                } catch CatalogueCreateAcknowledgementError.invalidCommand {}
                let requests = await transport.capturedRequests()
                firstBody = try XCTUnwrap(requests.first?.httpBody)
                XCTAssertEqual(requests.count, 1)
            }
            var canonical = syncObject()
            canonical["profile"] = ["preferred_locale": "en", "reminder_hour_local": latestHour,
                                    "trial_reminder_enabled": false] as [String: Any]
            if latestHour != 9 {
                canonical["until"] = "2026-11-03T10:00:00.000001+00:00"
                canonical["next_since"] = "2026-11-03T10:00:00.000001+00:00"
            }
            let transport = CatalogueTransport([
                .http(200, try profileResponse(hour: 9, receipt: true)), .http(200, try syncJSON(canonical))
            ])
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            let saved = try await repo.pendingProfileReminderHour(context: lease)
            XCTAssertEqual(saved?.envelope, command.envelope)
            let wrongOwner = try await repo.retryProfileReminderHour(foreign, context: lease)
            XCTAssertEqual(wrongOwner, .unconfirmed)
            let outcome = try await repo.retryProfileReminderHour(command, context: lease)
            XCTAssertEqual(outcome, .confirmed(hour: latestHour))
            let absent = try await repo.retryProfileReminderHour(command, context: lease)
            XCTAssertEqual(absent, .unconfirmed)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET"])
            XCTAssertEqual(requests[0].httpBody, firstBody)
            XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Operation-Id"),
                           command.envelope.operationId.uuidString.lowercased())
            XCTAssertNil(requests[0].value(forHTTPHeaderField: "X-Installation-Credential"))
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let profile = try await reopened.syncedProfile(ownerId: syncOwner)
            XCTAssertEqual(profile?.reminderHourLocal, latestHour)
            let ownRows = try await reopened.pendingOutboxEntries(for: syncOwner)
            let foreignRows = try await reopened.pendingOutboxEntries(for: otherSyncOwner)
            XCTAssertEqual(Set(ownRows.map(\.operationId)), Set([globalId, plantId]))
            XCTAssertEqual(foreignRows.map(\.envelope), [foreign.envelope])
        }
    }

    @MainActor
    func testProfileOutboxRequiresCorrectReceiptAndCompleteCanonicalSync() async throws {
        var baseline = syncObject()
        baseline["until"] = syncSince
        baseline["next_since"] = syncSince
        var missingProfile = syncObject()
        missingProfile.removeValue(forKey: "profile")
        var malformedProfile = syncObject()
        malformedProfile["profile"] = ["preferred_locale": "pl", "reminder_hour_local": 24,
                                       "trial_reminder_enabled": false] as [String: Any]
        let goodReceipt = try profileResponse(hour: 10, receipt: true)
        let cases: [[CatalogueTransport.Reply]] = [
            [.http(200, goodReceipt), .network],
            [.http(200, goodReceipt), .http(200, try syncJSON(missingProfile))],
            [.http(200, goodReceipt), .http(200, try syncJSON(malformedProfile))],
            [.http(200, goodReceipt), .http(200, try syncJSON(baseline))],
            [.http(200, try profileResponse(hour: 11, receipt: true))],
            [.http(200, try profileResponse(hour: 10))],
            [.http(200, goodReceipt), .http(403, try syncJSON([
                "error": ["code": "FORBIDDEN", "message": "Sync rejected", "retryable": false] as [String: Any]
            ]))]
        ]
        for replies in cases {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = CatalogueTransport([.http(200, try syncJSON(baseline))] + replies)
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let engine = SyncEngine(store: store, apiClient: api)
            _ = try await engine.performFullRefresh(context: lease)
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
            let command = try await repo.enqueueProfileReminderHour(reminderHourLocal: 10, context: lease)
            let outcome = try await repo.retryProfileReminderHour(command, context: lease)
            XCTAssertEqual(outcome, .pending)
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let profile = try await reopened.syncedProfile(ownerId: syncOwner)
            let rows = try await reopened.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(profile?.reminderHourLocal, 9)
            XCTAssertEqual(rows.map(\.envelope), [command.envelope])
            XCTAssertEqual(rows.first?.retryCount, 1)
        }
    }

    @MainActor
    func testProfileOutboxTerminalRejectionRetryableFailureAndCancellation() async throws {
        for code in ["CONFLICT", "FORBIDDEN", "VALIDATION_ERROR", "NOT_FOUND"] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let status = code == "FORBIDDEN" ? 403 : code == "NOT_FOUND" ? 404 : code == "CONFLICT" ? 409 : 400
            func failure(_ retryable: Bool) throws -> String {
                try syncJSON(["error": ["code": code, "message": "Fixture", "retryable": retryable] as [String: Any]])
            }
            let transport = CatalogueTransport([
                .http(status, try failure(true)), .http(status, try failure(false)), .http(status, try failure(false))
            ])
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let engine = SyncEngine(store: store, apiClient: api)
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
            let command = try await repo.enqueueProfileReminderHour(reminderHourLocal: 10, context: lease)
            let pending = try await repo.retryProfileReminderHour(command, context: lease)
            XCTAssertEqual(pending, .pending)
            let rejected = try await repo.retryProfileReminderHour(command, context: lease)
            XCTAssertEqual(rejected, .rejected)
            let absent = try await repo.retryProfileReminderHour(command, context: lease)
            XCTAssertEqual(absent, .unconfirmed)
            let background = try await repo.enqueueProfileReminderHour(reminderHourLocal: 10, context: lease)
            let count = try await engine.flushOutbox(context: lease)
            XCTAssertEqual(count, 0)
            let removed = try await repo.retryProfileReminderHour(background, context: lease)
            XCTAssertEqual(removed, .unconfirmed)
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let rows = try await reopened.pendingOutboxEntries(for: syncOwner)
            XCTAssertTrue(rows.isEmpty)
            let profile = try await reopened.syncedProfile(ownerId: syncOwner)
            XCTAssertNil(profile)
        }
        for cancellation in [CatalogueTransport.Reply.cancelled, .urlCancelled] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = CatalogueTransport([cancellation])
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            let command = try await repo.enqueueProfileReminderHour(reminderHourLocal: 10, context: lease)
            do {
                _ = try await repo.retryProfileReminderHour(command, context: lease)
                XCTFail("Cancellation must propagate")
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {}
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let rows = try await reopened.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(rows.map(\.envelope), [command.envelope])
            XCTAssertEqual(rows.first?.retryCount, 0)
        }
    }

    @MainActor
    func testProfileOutboxOwnerChangesAndABACannotAcknowledge() async throws {
        for mode in 0..<4 {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = SuspendedCollectionTransport(try profileResponse(hour: 10, receipt: true))
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            let command = try await repo.enqueueProfileReminderHour(reminderHourLocal: 10, context: lease)
            let task = Task { try await repo.retryProfileReminderHour(command, context: lease) }
            await transport.waitForRequest()
            if mode == 3 {
                task.cancel()
            } else if mode == 2 {
                await api.bindSyncSession(nil)
            } else {
                await api.bindSyncSession(NativeAuthSession(
                    userId: otherSyncOwner,
                    accessToken: try profileSession(ownerId: otherSyncOwner).accessToken,
                    expiresAt: .distantFuture
                ))
                let otherLease = try await api.captureSyncContext(ownerId: otherSyncOwner)
                let foreign = try await repo.retryProfileReminderHour(command, context: otherLease)
                XCTAssertEqual(foreign, .unconfirmed)
                if mode == 1 { await api.bindSyncSession(try profileSession()) }
            }
            await transport.resume()
            do {
                _ = try await task.value
                XCTFail("Stale or cancelled lease cannot acknowledge")
            } catch SyncWireValidationError.invalidSession {
            } catch is CancellationError {}
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let rows = try await reopened.pendingOutboxEntries(for: syncOwner)
            let profile = try await reopened.syncedProfile(ownerId: syncOwner)
            XCTAssertEqual(rows.map(\.envelope), [command.envelope])
            XCTAssertEqual(rows.first?.retryCount, 0)
            XCTAssertNil(profile)
            do {
                _ = try await repo.enqueueProfileReminderHour(reminderHourLocal: 10, context: lease)
                if mode != 3 { XCTFail("Stale lease accepted for enqueue") }
            } catch SyncWireValidationError.invalidSession {}
        }
    }

    @MainActor
    func testProfileOutboxMalformedEnvelopeNeverUsesGenericTransport() async throws {
        for payload in [
            #"{"reminder_hour_local":true}"#, #"{"reminder_hour_local":9.0}"#,
            #"{"reminder_hour_local":24}"#, #"{"reminder_hour_local":9,"extra":1}"#,
            #"{"reminder_hour_local":9,"reminder_hour_local":9}"#, "{}"
        ] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = CatalogueTransport([])
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let row = try await store.enqueueCommand(
                ownerId: syncOwner, plantId: nil, commandName: "profile.update", payloadJSON: payload
            )
            XCTAssertNil(ProfileReminderHourCommand(row.envelope))
            let engine = SyncEngine(store: store, apiClient: api)
            let count = try await engine.flushOutbox(context: lease)
            XCTAssertEqual(count, 0)
            do {
                _ = try await api.sendOutboxCommand(row.envelope, context: lease)
                XCTFail("Generic transport must reject profile.update")
            } catch SyncWireValidationError.invalidRequest {}
            let requests = await transport.capturedRequests()
            XCTAssertTrue(requests.isEmpty)
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let rows = try await reopened.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(rows.map(\.envelope), [row.envelope])
        }
        let command = try ProfileReminderHourCommand.make(reminderHourLocal: 9)
        XCTAssertNil(ProfileReminderHourCommand(CommandEnvelopeDTO(
            operationId: command.envelope.operationId, commandName: "profile.update",
            plantId: serverPlantId, payloadJSON: command.envelope.payloadJSON
        )))
        XCTAssertNil(ProfileReminderHourCommand(CommandEnvelopeDTO(
            operationId: command.envelope.operationId, commandName: "foreign.update",
            payloadJSON: command.envelope.payloadJSON
        )))
    }
}

extension CollectionWireTests {
    private func profileSession(
        ownerId: UUID? = nil, claims: [String: Any]? = nil
    ) throws -> NativeAuthSession {
        let owner = ownerId ?? syncOwner
        let json = try syncJSON(claims ?? ["sub": owner.uuidString, "is_anonymous": false])
        let payload = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return NativeAuthSession(
            userId: owner, accessToken: "eyJhbGciOiJIUzI1NiJ9.\(payload).fixture-signature",
            expiresAt: .distantFuture
        )
    }

    private func profileResponse(hour: Int = 9, locale: String = "pl", receipt: Bool = false) throws -> String {
        var object: [String: Any] = [
            "profile": ["preferred_locale": locale, "reminder_hour_local": hour]
        ]
        if receipt { object["watermark"] = timestamp }
        return try syncJSON(object)
    }

    @MainActor
    func testProfileSettingsAuthenticatedReadAndExactUpdateRetry() async throws {
        let command = try ProfileReminderHourCommand.make(reminderHourLocal: 23, operationId: operationId)
        let json = try profileResponse(hour: 23, receipt: true)
        let transport = CatalogueTransport([
            .http(200, try profileResponse()), .network, .http(200, json), .http(200, json)
        ])
        let api = client(transport)
        try await api.updateClientLocale("pl")
        await api.bindSyncSession(try profileSession())
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let settings = try await api.fetchProfileSettings(context: lease)
        XCTAssertEqual(settings.preferredLocale, "pl")
        XCTAssertEqual(settings.reminderHourLocal, 9)
        do {
            _ = try await api.updateProfileReminderHour(command, context: lease)
            XCTFail("Network error must propagate")
        } catch is URLError {}
        for _ in 0..<2 {
            let receipt = try await api.updateProfileReminderHour(command, context: lease)
            XCTAssertEqual(receipt.profile.reminderHourLocal, 23)
            XCTAssertEqual(receipt.watermarkRaw, timestamp)
            XCTAssertEqual(receipt.watermark, SQLTimestamp.microseconds(from: timestamp))
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 4)
        let read = try XCTUnwrap(requests.first)
        XCTAssertEqual(read.url?.absoluteString, "https://example.invalid/functions/v1/plants-api/me")
        XCTAssertEqual(read.httpMethod, "GET")
        XCTAssertNil(read.httpBody)
        XCTAssertNil(read.value(forHTTPHeaderField: "X-Operation-Id"))
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(try profileSession().accessToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Locale"), "pl")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Installation-Credential"))
        }
        let body = try XCTUnwrap(requests[1].httpBody)
        for request in requests.dropFirst() {
            XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/functions/v1/plants-api/commands")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), operationId.uuidString.lowercased())
            XCTAssertEqual(request.httpBody, body)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set(["operation_id", "command_name", "payload_json"]))
            XCTAssertEqual(object["command_name"] as? String, "profile.update")
            XCTAssertEqual((object["operation_id"] as? String)?.lowercased(), operationId.uuidString.lowercased())
            let payload = try XCTUnwrap(object["payload_json"] as? String)
            XCTAssertEqual(payload, #"{"reminder_hour_local":23}"#)
        }
    }

    @MainActor
    func testProfileReminderHourBoundsAndMalformedResponses() async throws {
        for hour in [Int.min, -1, 24, Int.max] {
            XCTAssertThrowsError(try ProfileReminderHourCommand.make(reminderHourLocal: hour))
        }
        for hour in [0, 23] {
            let command = try ProfileReminderHourCommand.make(reminderHourLocal: hour)
            let transport = CatalogueTransport([.http(200, try profileResponse(hour: hour, locale: "en", receipt: true))])
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let receipt = try await api.updateProfileReminderHour(command, context: lease)
            XCTAssertEqual(receipt.profile.reminderHourLocal, hour)
            XCTAssertEqual(receipt.profile.preferredLocale, "en")
        }
        let command = try ProfileReminderHourCommand.make(reminderHourLocal: 9)
        let profiles: [[String: Any]] = [
            [:], ["preferred_locale": "en"], ["reminder_hour_local": 9],
            ["preferred_locale": "EN", "reminder_hour_local": 9],
            ["preferred_locale": "de", "reminder_hour_local": 9],
            ["preferred_locale": "en", "reminder_hour_local": -1],
            ["preferred_locale": "en", "reminder_hour_local": 24],
            ["preferred_locale": "en", "reminder_hour_local": true],
            ["preferred_locale": "en", "reminder_hour_local": "9"],
            ["preferred_locale": "en", "reminder_hour_local": 9.5],
            ["preferred_locale": NSNull(), "reminder_hour_local": 9]
        ]
        for profile in profiles {
            let transport = CatalogueTransport([
                .http(200, try syncJSON(["profile": profile])),
                .http(200, try syncJSON(["profile": profile, "watermark": timestamp]))
            ])
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            do {
                _ = try await api.fetchProfileSettings(context: lease)
                XCTFail("Malformed profile accepted")
            } catch {}
            do {
                _ = try await api.updateProfileReminderHour(command, context: lease)
                XCTFail("Malformed receipt accepted")
            } catch {}
        }
        var invalidReceipts = [
            try profileResponse(hour: 8, receipt: true),
            try profileResponse(),
            "{}",
            #"{"profile":null,"watermark":null}"#
        ]
        let watermarks: [Any] = [NSNull(), 123, "2026-11-03", "2026-02-30T09:00:00Z",
                                 "1969-12-31T23:59:59.999999Z"]
        for watermark in watermarks {
            invalidReceipts.append(try syncJSON([
                "profile": ["preferred_locale": "en", "reminder_hour_local": 9],
                "watermark": watermark
            ]))
        }
        for json in invalidReceipts {
            let api = client(CatalogueTransport([.http(200, json)]))
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            do {
                _ = try await api.updateProfileReminderHour(command, context: lease)
                XCTFail("Stale hour or malformed receipt accepted")
            } catch {}
        }
    }

    @MainActor
    func testProfileRequiresCurrentBoundOwnerBeforeHTTP() async throws {
        let command = try ProfileReminderHourCommand.make(reminderHourLocal: 9)
        for writing in [false, true] {
            let transport = CatalogueTransport([])
            let api = client(transport)
            let unbound = try await api.captureSyncContext(ownerId: syncOwner)
            let other = client(transport)
            await other.bindSyncSession(try profileSession())
            let foreign = try await other.captureSyncContext(ownerId: syncOwner)
            await api.bindSyncSession(try profileSession())
            let stale = try await api.captureSyncContext(ownerId: syncOwner)
            await api.bindSyncSession(NativeAuthSession(
                userId: otherSyncOwner, accessToken: "other-owner-token", expiresAt: .distantFuture
            ))
            for lease in [unbound, foreign, stale] {
                do {
                    if writing {
                        _ = try await api.updateProfileReminderHour(command, context: lease)
                    } else {
                        _ = try await api.fetchProfileSettings(context: lease)
                    }
                    XCTFail("Invalid owner lease accepted")
                } catch SyncWireValidationError.invalidSession {}
            }
            await api.bindSyncSession(nil)
            do {
                if writing {
                    _ = try await api.updateProfileReminderHour(command, context: stale)
                } else {
                    _ = try await api.fetchProfileSettings(context: stale)
                }
                XCTFail("Signed-out lease accepted")
            } catch SyncWireValidationError.invalidSession {}
            let requests = await transport.capturedRequests()
            XCTAssertTrue(requests.isEmpty)
        }
    }

    @MainActor
    func testProfileRejectsInFlightOwnerChangesAndCancellation() async throws {
        let command = try ProfileReminderHourCommand.make(reminderHourLocal: 9)
        for writing in [false, true] {
            for mode in 0..<4 {
                let transport = SuspendedCollectionTransport(try profileResponse(receipt: writing))
                let api = client(transport)
                await api.bindSyncSession(try profileSession())
                let lease = try await api.captureSyncContext(ownerId: syncOwner)
                let operation = Task {
                    if writing {
                        _ = try await api.updateProfileReminderHour(command, context: lease)
                    } else {
                        _ = try await api.fetchProfileSettings(context: lease)
                    }
                }
                await transport.waitForRequest()
                if mode == 3 {
                    operation.cancel()
                } else if mode == 2 {
                    await api.bindSyncSession(nil)
                } else {
                    await api.bindSyncSession(NativeAuthSession(
                        userId: otherSyncOwner, accessToken: "other-owner-token", expiresAt: .distantFuture
                    ))
                    if mode == 1 { await api.bindSyncSession(try profileSession()) }
                }
                await transport.resume()
                do {
                    try await operation.value
                    XCTFail("Stale or cancelled profile response accepted")
                } catch is CancellationError {
                    XCTAssertEqual(mode, 3)
                } catch SyncWireValidationError.invalidSession {
                    XCTAssertNotEqual(mode, 3)
                }
            }
        }
    }
}

extension CollectionWireTests {
    private func routineUndoReceipt(_ command: RoutineSoilCheckUndoCommand) -> [String: Any] {
        [
            "plant_id": serverPlantId.uuidString, "task_id": command.taskId.uuidString,
            "entry_id": command.entryId.uuidString,
            "reversal_id": "19190000-0000-4000-8000-000000000004",
            "state": "voided", "watermark": timestamp
        ]
    }

    @MainActor
    func testRoutineUndoExactTypedRetryUsesBoundOwnerAndEN() async throws {
        let command = try RoutineSoilCheckUndoCommand.make(
            plantId: serverPlantId, taskId: UUID(), entryId: UUID(), operationId: operationId
        )
        let restored = try XCTUnwrap(RoutineSoilCheckUndoCommand(
            JSONDecoder().decode(CommandEnvelopeDTO.self, from: JSONEncoder().encode(command.envelope)),
            taskId: command.taskId
        ))
        let receipt = try syncJSON(routineUndoReceipt(command))
        let transport = CatalogueTransport([.network, .http(200, receipt), .http(200, receipt)])
        let api = client(transport)
        try await api.updateClientLocale("pl")
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        do {
            _ = try await api.sendOutboxCommand(command, context: lease)
            XCTFail("Lost response must propagate")
        } catch is URLError {}
        for _ in 0..<2 {
            let result = try await api.sendOutboxCommand(restored, context: lease)
            XCTAssertEqual(result.plantId, serverPlantId)
            XCTAssertEqual(result.taskId, command.taskId)
            XCTAssertEqual(result.entryId, command.entryId)
            XCTAssertEqual(result.reversalId, UUID(uuidString: "19190000-0000-4000-8000-000000000004"))
            XCTAssertEqual(result.state, .voided)
            XCTAssertEqual(result.watermark, SQLTimestamp.microseconds(from: timestamp))
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        let body = try XCTUnwrap(requests.first?.httpBody)
        for request in requests {
            XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/functions/v1/plants-api/commands")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.httpBody, body)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(syncSession.accessToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), operationId.uuidString.lowercased())
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "en")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Locale"), "en")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Installation-Credential"))
            let envelope = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(request.httpBody))
            XCTAssertEqual(envelope, command.envelope)
            XCTAssertEqual(envelope.commandName, "care.check_soil.undo")
            XCTAssertEqual(envelope.plantId, serverPlantId)
            XCTAssertEqual(envelope.operationId, operationId)
            let payload = try JSONDecoder().decode([String: UUID].self, from: Data(envelope.payloadJSON.utf8))
            XCTAssertEqual(payload, ["entry_id": command.entryId])
        }
        for payload in ["{}", #"{"entry_id":"bad"}"#,
                        String(command.envelope.payloadJSON.dropLast()) + #","extra":true}"#] {
            XCTAssertNil(RoutineSoilCheckUndoCommand(CommandEnvelopeDTO(
                operationId: operationId, commandName: RoutineSoilCheckUndoCommand.name,
                plantId: serverPlantId, payloadJSON: payload
            ), taskId: command.taskId))
        }
        XCTAssertNil(RoutineSoilCheckUndoCommand(CommandEnvelopeDTO(
            operationId: operationId, commandName: "care.undo", plantId: serverPlantId,
            payloadJSON: command.envelope.payloadJSON
        ), taskId: command.taskId))
        XCTAssertNil(RoutineSoilCheckUndoCommand(CommandEnvelopeDTO(
            operationId: operationId, commandName: RoutineSoilCheckUndoCommand.name,
            payloadJSON: command.envelope.payloadJSON
        ), taskId: command.taskId))
    }

    @MainActor
    func testRoutineUndoRejectsMalformedUnrelatedAndNonVoidedReceipts() async throws {
        let command = try RoutineSoilCheckUndoCommand.make(
            plantId: serverPlantId, taskId: UUID(), entryId: UUID()
        )
        let canonical = routineUndoReceipt(command)
        var invalid: [[String: Any]] = []
        for key in canonical.keys {
            var missing = canonical
            missing.removeValue(forKey: key)
            invalid.append(missing)
            var null = canonical
            null[key] = NSNull()
            invalid.append(null)
        }
        let changes: [(String, Any)] = [
            ("plant_id", UUID().uuidString), ("task_id", UUID().uuidString),
            ("entry_id", UUID().uuidString), ("plant_id", "bad"), ("task_id", "bad"),
            ("entry_id", "bad"), ("reversal_id", "bad"), ("state", "completed"),
            ("state", "active"), ("watermark", "2026-11-03"), ("watermark", 123),
            ("watermark", "1969-12-31T23:59:59.999999+00:00")
        ]
        for (key, value) in changes {
            var changed = canonical
            changed[key] = value
            invalid.append(changed)
        }
        for object in invalid {
            let transport = CatalogueTransport([.http(200, try syncJSON(object))])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            do {
                _ = try await api.sendOutboxCommand(command, context: lease)
                XCTFail("Malformed or unrelated undo receipt must fail")
            } catch {}
        }
        var epoch = canonical
        epoch["watermark"] = "1970-01-01T00:00:00+00:00"
        let decoded = try JSONDecoder().decode(
            RoutineSoilCheckUndoReceipt.self, from: Data(try syncJSON(epoch).utf8)
        )
        try decoded.validate(for: command)
        XCTAssertEqual(decoded.watermark, 0)
    }

    @MainActor
    func testRoutineUndoRequiresBoundOwnerAndDedicatedRoute() async throws {
        let transport = CatalogueTransport([])
        let api = client(transport)
        let command = try RoutineSoilCheckUndoCommand.make(
            plantId: serverPlantId, taskId: UUID(), entryId: UUID()
        )
        let unbound = try await api.captureSyncContext(ownerId: syncOwner)
        do {
            _ = try await api.sendOutboxCommand(command, context: unbound)
            XCTFail("Unbound request must fail")
        } catch SyncWireValidationError.invalidSession {}
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let otherAPI = client(transport)
        await otherAPI.bindSyncSession(syncSession)
        let foreign = try await otherAPI.captureSyncContext(ownerId: syncOwner)
        do {
            _ = try await api.sendOutboxCommand(command, context: foreign)
            XCTFail("Foreign authority must fail")
        } catch SyncWireValidationError.invalidSession {}
        do {
            _ = try await api.sendOutboxCommand(command.envelope, context: lease)
            XCTFail("Generic route must reject typed undo")
        } catch SyncWireValidationError.invalidRequest {}
        await api.bindSyncSession(NativeAuthSession(
            userId: otherSyncOwner, accessToken: "other-owner-token", expiresAt: .distantFuture
        ))
        do {
            _ = try await api.sendOutboxCommand(command, context: lease)
            XCTFail("Account switch must invalidate captured owner")
        } catch SyncWireValidationError.invalidSession {}
        await api.bindSyncSession(nil)
        do {
            _ = try await api.sendOutboxCommand(command, context: lease)
            XCTFail("Signed-out retry must fail")
        } catch SyncWireValidationError.invalidSession {}
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }
}

extension CollectionWireTests {
    private var routineRuleId: UUID { UUID(uuidString: "19190000-0000-4000-8000-000000000001")! }

    private func routineCompletionContext(
        plantId: UUID? = nil, revision: Int = 2, due: String = "2026-11-03"
    ) -> PlantCareRecommendation.RoutineContext {
        .init(plantId: plantId ?? serverPlantId, check: .init(
            ruleId: routineRuleId, careRevision: revision, dueLocalDate: due,
            anchorLocalDate: "2026-11-01", anchorKind: .water
        ))
    }

    private func routineCompletionCommand() throws -> RoutineSoilCheckCompletionCommand {
        try .make(
            plantId: serverPlantId, routineContext: routineCompletionContext(),
            occurredAt: timestamp, timezone: "Europe/Warsaw", operationId: operationId
        )
    }

    private func routineCompletionReceipt() -> [String: Any] {
        [
            "plant_id": serverPlantId.uuidString, "rule_id": routineRuleId.uuidString,
            "care_revision": 2, "occurrence_key": "fixture-routine-occurrence",
            "due_local_date": "2026-11-03",
            "task_id": "19190000-0000-4000-8000-000000000002",
            "entry_id": "19190000-0000-4000-8000-000000000003",
            "state": "completed", "watermark": timestamp
        ]
    }

    private func routineCompletionPage(
        operation: UUID, taskChanges: [String: Any] = [:], entryChanges: [String: Any] = [:],
        time: String = "2026-11-03T09:10:00.000001+00:00"
    ) -> [String: Any] {
        let receipt = routineCompletionReceipt()
        var task: [String: Any] = [
            "id": receipt["task_id"]!, "plant_id": serverPlantId.uuidString,
            "rule_id": routineRuleId.uuidString, "occurrence_key": receipt["occurrence_key"]!,
            "due_local_date": "2026-11-03", "action_code": "check_soil",
            "state": "completed", "completed_entry_id": receipt["entry_id"]!
        ]
        var entry: [String: Any] = [
            "id": receipt["entry_id"]!, "plant_id": serverPlantId.uuidString,
            "task_id": receipt["task_id"]!, "operation_id": operation.uuidString,
            "action_code": "check_soil", "state": "active",
            "occurred_at": timestamp, "occurred_local_date": "2026-11-03", "timezone": "Europe/Warsaw"
        ]
        task.merge(taskChanges) { _, new in new }
        entry.merge(entryChanges) { _, new in new }
        var taskRow = syncChange(time, id: receipt["task_id"] as! String, entity: "care_tasks")
        taskRow["data"] = task
        var entryRow = syncChange(time, id: receipt["entry_id"] as! String, entity: "care_entries")
        entryRow["data"] = entry
        var page = syncObject()
        page["until"] = time
        page["next_since"] = time
        page["changes"] = [entryRow, taskRow]
        return page
    }

    private func routineUndoBaseline(
        taskChanges: [String: Any] = [:], entryChanges: [String: Any] = [:]
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "condition_code": "check_soil_first",
            "occurrence_key": routineRuleId.uuidString.lowercased() + ":2026-11-03"
        ]
        fields.merge(taskChanges) { _, new in new }
        var page = routineCompletionPage(operation: operationId, taskChanges: fields, entryChanges: entryChanges)
        page["changes"] = (routineCompletionBaseline()["changes"] as! [[String: Any]])
            + (page["changes"] as! [[String: Any]])
        return page
    }

    private func routineUndoCanonical(
        _ command: RoutineSoilCheckUndoCommand, minute: Int, recompleted: Bool, fault: String?
    ) -> [String: Any] {
        let time = String(format: "2026-11-03T09:%02d:00.000001+00:00", minute)
        let replacementId = UUID(uuidString: "19190000-0000-4000-8000-000000000005")!
        var task: [String: Any] = [
            "condition_code": "check_soil_first", "state": recompleted ? "completed" : "superseded",
            "completed_entry_id": recompleted ? replacementId.uuidString : command.entryId.uuidString,
            "occurrence_key": routineRuleId.uuidString.lowercased() + ":2026-11-03"
        ]
        if fault == "task" { task["occurrence_key"] = "another-occurrence" }
        var entry: [String: Any] = ["state": "voided"]
        if fault == "active" { entry["state"] = "active" }
        if fault == "entry" { entry["task_id"] = UUID().uuidString }
        var page = routineCompletionPage(operation: operationId, taskChanges: task, entryChanges: entry, time: time)
        var changes = page["changes"] as! [[String: Any]]
        if fault != "missing" {
            let id = "19190000-0000-4000-8000-000000000004"
            var reversal = syncChange(time, id: id, entity: "care_reversals")
            reversal["data"] = [
                "id": id, "entry_id": fault == "reversal-entry" ? UUID().uuidString : command.entryId.uuidString,
                "operation_id": fault == "reversal-operation" ? UUID().uuidString : command.envelope.operationId.uuidString
            ]
            changes.append(reversal)
        }
        if recompleted {
            var replacement = syncChange(time, id: replacementId.uuidString, entity: "care_entries")
            replacement["data"] = [
                "id": replacementId.uuidString, "plant_id": serverPlantId.uuidString,
                "task_id": fault == "replacement" ? UUID().uuidString : command.taskId.uuidString,
                "operation_id": "19190000-0000-4000-8000-000000000006",
                "action_code": "check_soil", "state": "active", "occurred_at": time,
                "occurred_local_date": "2026-11-03", "timezone": "Europe/Warsaw"
            ]
            changes.append(replacement)
        }
        // All changes share this timestamp; canonical sync also orders by entity and id.
        page["changes"] = changes.sorted {
            ($0["entity_type"] as! String, $0["id"] as! String)
                < ($1["entity_type"] as! String, $1["id"] as! String)
        }
        return page
    }

    @MainActor
    func testRoutineUndoDiskLossReopenExactReplayAndIndependentReversal() async throws {
        for recompleted in [false, true] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let command: RoutineSoilCheckUndoCommand
            let firstBody: Data
            do {
                let transport = CatalogueTransport([.http(200, try syncJSON(routineUndoBaseline())), .network])
                let api = client(transport)
                await api.bindSyncSession(syncSession)
                let lease = try await api.captureSyncContext(ownerId: syncOwner)
                let store = LocalStore(modelContainer: try diskContainer(url))
                let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
                _ = try await repo.collectionCards(context: lease)
                let identity = routineCompletionReceipt()
                command = try await repo.enqueueRoutineUndo(
                    plantId: serverPlantId, taskId: UUID(uuidString: identity["task_id"] as! String)!,
                    entryId: UUID(uuidString: identity["entry_id"] as! String)!, context: lease
                )
                let outcome = try await repo.retryRoutineUndo(command, context: lease)
                XCTAssertEqual(outcome, .pending)
                let requests = await transport.capturedRequests()
                firstBody = try XCTUnwrap(requests.last?.httpBody)
            }
            let faults: [String?] = [
                "missing", "reversal-operation", "reversal-entry", "task", "entry", "active"
            ] + (recompleted ? ["replacement"] : []) + [nil]
            for (index, fault) in faults.enumerated() {
                var receipt = routineUndoReceipt(command)
                receipt["watermark"] = "2026-11-03T09:20:00.000001+00:00"
                let transport = CatalogueTransport([
                    .http(200, try syncJSON(receipt)),
                    .http(200, try syncJSON(routineUndoCanonical(
                        command, minute: 20 + index, recompleted: recompleted, fault: fault
                    )))
                ])
                let api = client(transport)
                await api.bindSyncSession(syncSession)
                let lease = try await api.captureSyncContext(ownerId: syncOwner)
                let store = LocalStore(modelContainer: try diskContainer(url))
                let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
                let replay = try await repo.enqueueRoutineUndo(
                    plantId: serverPlantId, taskId: command.taskId, entryId: command.entryId, context: lease
                )
                XCTAssertEqual(replay.envelope, command.envelope)
                let result = try await repo.retryRoutineUndo(replay, context: lease)
                // Negative linkage cases must reach validation after a successful sync.
                let watermark = try await store.currentWatermarkRaw(ownerId: syncOwner)
                XCTAssertEqual(watermark, String(format: "2026-11-03T09:%02d:00.000001+00:00", 20 + index))
                XCTAssertEqual(result, fault == nil ? .confirmed : .pending, fault ?? "valid replay")
                let requests = await transport.capturedRequests()
                XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET"])
                XCTAssertEqual(requests.first?.httpBody, firstBody)
                let reopened = LocalStore(modelContainer: try diskContainer(url))
                let pending = try await reopened.pendingOutboxEntries(for: syncOwner)
                XCTAssertEqual(pending.map(\.envelope), fault == nil ? [] : [command.envelope])
                if fault == nil {
                    let absent = try await repo.retryRoutineUndo(command, context: lease)
                    XCTAssertEqual(absent, .unconfirmed)
                    let tasks = try await reopened.activeSyncedEntities(ownerId: syncOwner, entityType: "care_tasks")
                    let task = try XCTUnwrap(tasks.first)
                    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(task.payloadJSON.utf8)) as? [String: Any])
                    XCTAssertEqual(fields["state"] as? String, recompleted ? "completed" : "superseded")
                    if recompleted {
                        XCTAssertEqual(fields["completed_entry_id"] as? String, "19190000-0000-4000-8000-000000000005")
                    }
                }
            }
        }
    }

    @MainActor
    func testRoutineUndoLocksCompetingMarkAndUndoAndRejectsWithoutFalseSuccess() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rejection = try syncJSON(["error": [
            "code": "CONFLICT", "message": "stale entry", "retryable": false
        ] as [String: Any]])
        let transport = CatalogueTransport([.http(200, try syncJSON(routineUndoBaseline())), .http(409, rejection)])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        _ = try await repo.collectionCards(context: lease)
        let identity = routineCompletionReceipt()
        let command = try await repo.enqueueRoutineUndo(
            plantId: serverPlantId, taskId: UUID(uuidString: identity["task_id"] as! String)!,
            entryId: UUID(uuidString: identity["entry_id"] as! String)!, context: lease
        )
        let unrelated = try await store.enqueueCommand(
            ownerId: syncOwner, plantId: UUID(), commandName: "fixture.unrelated", payloadJSON: "{}"
        )
        do {
            _ = try await repo.enqueueRoutineCompletion(
                plantId: serverPlantId, routineContext: routineCompletionContext(),
                occurredAt: timestamp, timezone: "UTC", context: lease
            )
            XCTFail("Competing mark accepted")
        } catch OutboxEnqueueError.operationIdentityMismatch {}
        do {
            _ = try await repo.enqueueRoutineUndo(
                plantId: serverPlantId, taskId: command.taskId, entryId: UUID(), context: lease
            )
            XCTFail("Competing undo accepted")
        } catch OutboxEnqueueError.operationIdentityMismatch {}
        let wrongTask = try XCTUnwrap(RoutineSoilCheckUndoCommand(command.envelope, taskId: UUID()))
        let wrongOutcome = try await repo.retryRoutineUndo(wrongTask, context: lease)
        XCTAssertEqual(wrongOutcome, .unconfirmed)
        await api.bindSyncSession(NativeAuthSession(userId: otherSyncOwner, accessToken: "other", expiresAt: .distantFuture))
        let foreign = try await api.captureSyncContext(ownerId: otherSyncOwner)
        let foreignOutcome = try await repo.retryRoutineUndo(command, context: foreign)
        XCTAssertEqual(foreignOutcome, .unconfirmed)
        await api.bindSyncSession(syncSession)
        do {
            _ = try await repo.retryRoutineUndo(command, context: lease)
            XCTFail("Account ABA accepted")
        } catch SyncWireValidationError.invalidSession {}
        let current = try await api.captureSyncContext(ownerId: syncOwner)
        let rejected = try await repo.retryRoutineUndo(command, context: current)
        XCTAssertEqual(rejected, .rejected)
        let absent = try await repo.retryRoutineUndo(command, context: current)
        XCTAssertEqual(absent, .unconfirmed)
        let remaining = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertEqual(remaining, [unrelated])
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    }

    @MainActor
    private func routineHistoryFixture(
        _ page: [String: Any], container: ModelContainer, careOwner: UUID? = nil
    ) async throws -> (repo: CollectionRepository, api: PlantsAPIClient, lease: SyncSessionLease) {
        let disk = container.mainContext
        for row in page["changes"] as! [[String: Any]] {
            let entity = row["entity_type"] as! String
            disk.insert(SyncedEntityRecord(
                ownerId: entity == "plants" ? syncOwner : (careOwner ?? syncOwner),
                entityType: entity, entityId: UUID(uuidString: row["id"] as! String)!,
                updatedAt: Date(), deletedAt: row["deleted_at"] is String ? Date() : nil,
                payloadJSON: try syncJSON(row["data"] as? [String: Any] ?? [:])
            ))
        }
        try disk.save()
        let api = client(CatalogueTransport([]))
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: container)
        return (CollectionRepository(
            store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api)
        ), api, lease)
    }

    @MainActor
    func testRoutineHistoryActiveVoidedAndRecompletedWithoutDuplicates() async throws {
        let identity = routineCompletionReceipt()
        let taskId = UUID(uuidString: identity["task_id"] as! String)!
        let entryId = UUID(uuidString: identity["entry_id"] as! String)!
        let command = try RoutineSoilCheckUndoCommand.make(plantId: serverPlantId, taskId: taskId, entryId: entryId)
        for scenario in ["active", "voided", "recompleted", "same-instant"] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            var page = routineUndoBaseline()
            if scenario != "active" {
                let canonical = routineUndoCanonical(
                    command, minute: 20, recompleted: scenario != "voided", fault: nil
                )
                var changes = canonical["changes"] as! [[String: Any]]
                if scenario == "same-instant" {
                    for index in changes.indices where changes[index]["entity_type"] as? String == "care_entries" {
                        var entry = changes[index]["data"] as! [String: Any]
                        entry["occurred_at"] = timestamp
                        changes[index]["data"] = entry
                    }
                }
                page["changes"] = (routineCompletionBaseline()["changes"] as! [[String: Any]]) + changes
            }
            let fixture = try await routineHistoryFixture(page, container: diskContainer(url))
            let history = try await fixture.repo.collectionRoutineSoilCheckHistory(
                plantId: serverPlantId, context: fixture.lease
            )
            let replacementId = UUID(uuidString: "19190000-0000-4000-8000-000000000005")!
            let expected = scenario == "recompleted" ? [replacementId, entryId]
                : scenario == "same-instant" ? [entryId, replacementId] : [entryId]
            XCTAssertEqual(history.map(\.id), expected, scenario)
            XCTAssertEqual(Set(history.map(\.id)).count, history.count, scenario)
            XCTAssertTrue(history.allSatisfy { $0.taskId == taskId && $0.occurredLocalDate == "2026-11-03" })
            XCTAssertEqual(history.first(where: { $0.id == entryId })?.state, scenario == "active" ? "active" : "voided")
            let repeated = try await fixture.repo.collectionRoutineSoilCheckHistory(
                plantId: serverPlantId, context: fixture.lease
            )
            XCTAssertEqual(repeated, history)
        }
    }

    @MainActor
    func testRoutineHistoryExcludesNonRoutineUnlinkedForeignAndTombstonedRows() async throws {
        let invalid: [([String: Any], [String: Any])] = [
            (["condition_code": "manual"], [:]),
            (["action_code": "water"], [:]),
            (["rule_id": NSNull()], [:]),
            (["rule_id": "not-a-uuid"], [:]),
            (["occurrence_key": "arbitrary"], [:]),
            (["occurrence_key": routineRuleId.uuidString.lowercased() + ":2026-11-04"], [:]),
            (["rule_id": "AAAAAAAA-0000-4000-8000-000000000001",
              "occurrence_key": "AAAAAAAA-0000-4000-8000-000000000001:2026-11-03"], [:]),
            (["due_local_date": "2026-02-30"], [:]),
            (["plant_id": UUID().uuidString], [:]),
            (["id": UUID().uuidString], [:]),
            (["state": "pending"], [:]),
            (["completed_entry_id": UUID().uuidString], [:]),
            ([:], ["action_code": "water"]),
            ([:], ["task_id": NSNull()]),
            ([:], ["task_id": UUID().uuidString]),
            ([:], ["plant_id": UUID().uuidString]),
            ([:], ["id": UUID().uuidString])
        ]
        for (task, entry) in invalid {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let fixture = try await routineHistoryFixture(
                routineUndoBaseline(taskChanges: task, entryChanges: entry), container: diskContainer(url)
            )
            let history = try await fixture.repo.collectionRoutineSoilCheckHistory(
                plantId: serverPlantId, context: fixture.lease
            )
            XCTAssertTrue(history.isEmpty, "\(task) / \(entry)")
        }
        for exclusion in ["owner", "care_tasks", "care_entries"] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            var page = routineUndoBaseline()
            var changes = page["changes"] as! [[String: Any]]
            for index in changes.indices where changes[index]["entity_type"] as? String == exclusion {
                changes[index]["deleted_at"] = timestamp
            }
            page["changes"] = changes
            let fixture = try await routineHistoryFixture(
                page, container: diskContainer(url), careOwner: exclusion == "owner" ? otherSyncOwner : nil
            )
            let history = try await fixture.repo.collectionRoutineSoilCheckHistory(
                plantId: serverPlantId, context: fixture.lease
            )
            XCTAssertTrue(history.isEmpty, exclusion)
        }
    }

    @MainActor
    func testRoutineHistoryRejectsWrongPlantOwnerStaleLeaseAndCancellation() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fixture = try await routineHistoryFixture(routineUndoBaseline(), container: diskContainer(url))
        do {
            _ = try await fixture.repo.collectionRoutineSoilCheckHistory(plantId: UUID(), context: fixture.lease)
            XCTFail("Unknown plant accepted")
        } catch SyncWireValidationError.invalidPage {}
        let cancelled = Task {
            try await fixture.repo.collectionRoutineSoilCheckHistory(plantId: serverPlantId, context: fixture.lease)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled history read accepted")
        } catch is CancellationError {}
        await fixture.api.bindSyncSession(
            NativeAuthSession(userId: otherSyncOwner, accessToken: "other", expiresAt: .distantFuture)
        )
        let foreign = try await fixture.api.captureSyncContext(ownerId: otherSyncOwner)
        do {
            _ = try await fixture.repo.collectionRoutineSoilCheckHistory(plantId: serverPlantId, context: foreign)
            XCTFail("Foreign owner's plant accepted")
        } catch SyncWireValidationError.invalidPage {}
        do {
            _ = try await fixture.repo.collectionRoutineSoilCheckHistory(plantId: serverPlantId, context: fixture.lease)
            XCTFail("Stale session accepted")
        } catch SyncWireValidationError.invalidSession {}
    }

    @MainActor
    func testRoutineUndoRequiresActiveLinkedOrdinaryCheck() async throws {
        let invalid: [([String: Any], [String: Any])] = [
            (["condition_code": "manual"], [:]),
            (["action_code": "water"], [:]),
            (["occurrence_key": " "], [:]),
            (["occurrence_key": "arbitrary"], [:]),
            (["occurrence_key": routineRuleId.uuidString.lowercased() + ":2026-11-04"], [:]),
            (["state": "superseded"], [:]),
            (["completed_entry_id": UUID().uuidString], [:]),
            (["plant_id": UUID().uuidString], [:]),
            ([:], ["state": "voided"]),
            ([:], ["task_id": NSNull()]),
            ([:], ["task_id": UUID().uuidString]),
            ([:], ["plant_id": UUID().uuidString]),
            ([:], ["action_code": "water"])
        ]
        for (task, entry) in invalid {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = CatalogueTransport([.http(200, try syncJSON(
                routineUndoBaseline(taskChanges: task, entryChanges: entry)
            ))])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            _ = try await repo.collectionCards(context: lease)
            let identity = routineCompletionReceipt()
            do {
                _ = try await repo.enqueueRoutineUndo(
                    plantId: serverPlantId, taskId: UUID(uuidString: identity["task_id"] as! String)!,
                    entryId: UUID(uuidString: identity["entry_id"] as! String)!, context: lease
                )
                XCTFail("Invalid routine undo accepted")
            } catch {}
            let pending = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertTrue(pending.isEmpty)
        }
    }

    private func routineCompletionBaseline() -> [String: Any] {
        var row = syncChange(syncUntil, id: serverPlantId.uuidString)
        row["data"] = ["id": serverPlantId.uuidString, "revision": 2, "care_revision": 2] as [String: Any]
        var page = syncObject()
        page["changes"] = [row]
        return page
    }

    @MainActor
    func testRoutineCompletionDiskLossReopenExactRetryAndCanonicalLinkage() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command: RoutineSoilCheckCompletionCommand
        let firstBody: Data
        do {
            let transport = CatalogueTransport([.http(200, try syncJSON(routineCompletionBaseline())), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            _ = try await repo.collectionCards(context: lease)
            command = try await repo.enqueueRoutineCompletion(
                plantId: serverPlantId, routineContext: routineCompletionContext(),
                occurredAt: timestamp, timezone: "Europe/Warsaw", context: lease
            )
            let outcome = try await repo.retryRoutineCompletion(command, context: lease)
            XCTAssertEqual(outcome, .pending)
            let requests = await transport.capturedRequests()
            firstBody = try XCTUnwrap(requests.last?.httpBody)
        }
        let mismatches: [([String: Any], [String: Any])] = [
            (["completed_entry_id": UUID().uuidString], [:]),
            (["state": "open"], [:]),
            (["plant_id": UUID().uuidString], [:]),
            (["rule_id": UUID().uuidString], [:]),
            (["occurrence_key": "arbitrary"], [:]),
            (["due_local_date": "2026-11-04"], [:]),
            ([:], ["operation_id": UUID().uuidString]),
            ([:], ["task_id": UUID().uuidString]),
            ([:], ["plant_id": UUID().uuidString]),
            ([:], ["action_code": "water"]),
            ([:], ["state": "voided"])
        ]
        for (index, mismatch) in mismatches.enumerated() {
            let (task, entry) = mismatch
            let transport = CatalogueTransport([
                .http(200, try syncJSON(routineCompletionReceipt())),
                .http(200, try syncJSON(routineCompletionPage(
                    operation: command.envelope.operationId, taskChanges: task, entryChanges: entry,
                    time: String(format: "2026-11-03T09:%02d:00.000001+00:00", 10 + index)
                )))
            ])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            let replay = try await repo.enqueueRoutineCompletion(
                plantId: serverPlantId, routineContext: routineCompletionContext(),
                occurredAt: "2026-11-03T09:01:00Z", timezone: "UTC", context: lease
            )
            XCTAssertEqual(replay.envelope, command.envelope)
            let outcome = try await repo.retryRoutineCompletion(replay, context: lease)
            XCTAssertEqual(outcome, .pending)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.first?.httpBody, firstBody)
            let disk = LocalStore(modelContainer: try diskContainer(url))
            let rows = try await disk.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(rows.map(\.envelope), [command.envelope])
        }
        var arbitrary = routineCompletionReceipt()
        arbitrary["entry_id"] = UUID().uuidString
        var future = routineCompletionReceipt()
        future["watermark"] = "2026-11-03T10:00:00Z"
        let pages = try (30...32).map { minute in
            try syncJSON(routineCompletionPage(
                operation: command.envelope.operationId,
                time: String(format: "2026-11-03T09:%02d:00.000001+00:00", minute)
            ))
        }
        let transport = CatalogueTransport([
            .http(200, try syncJSON(arbitrary)), .http(200, pages[0]),
            .http(200, try syncJSON(future)), .http(200, pages[1]),
            .http(200, try syncJSON(routineCompletionReceipt())), .http(200, pages[2])
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        for expected in [RoutineCompletionOutcome.pending, .pending, .confirmed, .unconfirmed] {
            let outcome = try await repo.retryRoutineCompletion(command, context: lease)
            XCTAssertEqual(outcome, expected)
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.compactMap(\.httpBody), [firstBody, firstBody, firstBody])
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let remaining = try await reopened.pendingOutboxEntries(for: syncOwner)
        XCTAssertTrue(remaining.isEmpty)
        let receipt = try JSONDecoder().decode(
            RoutineSoilCheckCompletionReceipt.self, from: Data(try syncJSON(routineCompletionReceipt()).utf8)
        )
        try await reopened.validateRoutineCompletion(receipt, command: command, context: lease, authority: api.syncAuthority)
    }

    @MainActor
    func testRoutineCompletionRejectsForeignDeadAndChangedContextAndTerminalError() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rejection = try syncJSON(["error": [
            "code": "CONFLICT", "message": "stale occurrence", "retryable": false
        ] as [String: Any]])
        let transport = CatalogueTransport([
            .http(200, try syncJSON(routineCompletionBaseline())), .http(409, rejection)
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        _ = try await repo.collectionCards(context: lease)
        let command = try await repo.enqueueRoutineCompletion(
            plantId: serverPlantId, routineContext: routineCompletionContext(),
            occurredAt: timestamp, timezone: "UTC", context: lease
        )
        for changed in [routineCompletionContext(revision: 3), routineCompletionContext(due: "2026-11-04"),
                        routineCompletionContext(plantId: UUID())] {
            do {
                _ = try await repo.enqueueRoutineCompletion(
                    plantId: serverPlantId, routineContext: changed, occurredAt: timestamp, timezone: "UTC", context: lease
                )
                XCTFail("Changed context replaced durable completion")
            } catch {}
        }
        await api.bindSyncSession(NativeAuthSession(
            userId: otherSyncOwner, accessToken: "other-owner-token", expiresAt: .distantFuture
        ))
        let foreign = try await api.captureSyncContext(ownerId: otherSyncOwner)
        let foreignOutcome = try await repo.retryRoutineCompletion(command, context: foreign)
        XCTAssertEqual(foreignOutcome, .unconfirmed)
        do {
            _ = try await repo.enqueueRoutineCompletion(
                plantId: serverPlantId, routineContext: routineCompletionContext(),
                occurredAt: timestamp, timezone: "UTC", context: foreign
            )
            XCTFail("Foreign card accepted")
        } catch {}
        do {
            _ = try await repo.retryRoutineCompletion(command, context: lease)
            XCTFail("Stale lease accepted")
        } catch {}
        await api.bindSyncSession(syncSession)
        let current = try await api.captureSyncContext(ownerId: syncOwner)
        let rejected = try await repo.retryRoutineCompletion(command, context: current)
        XCTAssertEqual(rejected, .rejected)
        let absent = try await repo.retryRoutineCompletion(command, context: current)
        XCTAssertEqual(absent, .unconfirmed)
        try await store.applySyncedItems([SyncItemDTO(
            entityType: "plants", id: serverPlantId, updatedAt: .distantFuture,
            deletedAt: .distantFuture, payloadJSON: "{}"
        )], ownerId: syncOwner)
        do {
            _ = try await repo.enqueueRoutineCompletion(
                plantId: serverPlantId, routineContext: routineCompletionContext(),
                occurredAt: timestamp, timezone: "UTC", context: current
            )
            XCTFail("Dead card accepted")
        } catch {}
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    }

    func testRoutineCompletionValidatesCardAndExactPayloadBeforeTransport() throws {
        let command = try routineCompletionCommand()
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(command.envelope.payloadJSON.utf8)
        ) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set([
            "rule_id", "expected_care_revision", "due_local_date", "occurred_at", "timezone"
        ]))
        XCTAssertEqual(fields["rule_id"] as? String, routineRuleId.uuidString)
        XCTAssertEqual(fields["expected_care_revision"] as? Int, 2)
        XCTAssertEqual(fields["due_local_date"] as? String, "2026-11-03")
        XCTAssertEqual(fields["occurred_at"] as? String, timestamp)
        XCTAssertEqual(fields["timezone"] as? String, "Europe/Warsaw")
        XCTAssertEqual(command.envelope.operationId, operationId)
        XCTAssertEqual(command.envelope.plantId, serverPlantId)
        for context in [
            routineCompletionContext(plantId: UUID()),
            routineCompletionContext(revision: 0),
            routineCompletionContext(revision: Int(Int32.max) + 1),
            routineCompletionContext(due: "2026-02-30")
        ] {
            XCTAssertThrowsError(try RoutineSoilCheckCompletionCommand.make(
                plantId: serverPlantId, routineContext: context,
                occurredAt: timestamp, timezone: "Europe/Warsaw"
            ))
        }
        let invalid: [(String, Any)] = [
            ("rule_id", "bad-uuid"), ("expected_care_revision", 0),
            ("expected_care_revision", -1), ("expected_care_revision", Int(Int32.max) + 1),
            ("expected_care_revision", true), ("expected_care_revision", 1.5),
            ("expected_care_revision", "2"), ("due_local_date", "2026-11-3"),
            ("due_local_date", "2026-02-30"), ("occurred_at", "2026-11-03T09:00:00"),
            ("timezone", "GMT+0300"), ("timezone", "invalid/zone"), ("extra", "unexpected")
        ]
        for (key, value) in invalid {
            var changed = fields
            changed[key] = value
            let envelope = CommandEnvelopeDTO(
                operationId: operationId, commandName: RoutineSoilCheckCompletionCommand.name,
                plantId: serverPlantId, payloadJSON: try syncJSON(changed)
            )
            XCTAssertNil(RoutineSoilCheckCompletionCommand(envelope), key)
        }
        for key in fields.keys {
            for value in [nil, NSNull()] as [Any?] {
                var changed = fields
                changed[key] = value
                XCTAssertNil(RoutineSoilCheckCompletionCommand(CommandEnvelopeDTO(
                    operationId: operationId, commandName: RoutineSoilCheckCompletionCommand.name,
                    plantId: serverPlantId, payloadJSON: try syncJSON(changed)
                )), key)
            }
        }
        XCTAssertNil(RoutineSoilCheckCompletionCommand(CommandEnvelopeDTO(
            operationId: operationId, commandName: "care.record", plantId: serverPlantId,
            payloadJSON: command.envelope.payloadJSON
        )))
        XCTAssertNil(RoutineSoilCheckCompletionCommand(CommandEnvelopeDTO(
            operationId: operationId, commandName: RoutineSoilCheckCompletionCommand.name,
            payloadJSON: command.envelope.payloadJSON
        )))
    }

    @MainActor
    func testRoutineCompletionExactRetryAndTypedReplayUseBoundOwnerAndEN() async throws {
        let command = try routineCompletionCommand()
        let persisted = try JSONEncoder().encode(command.envelope)
        let restored = try XCTUnwrap(RoutineSoilCheckCompletionCommand(
            JSONDecoder().decode(CommandEnvelopeDTO.self, from: persisted)
        ))
        let receipt = try syncJSON(routineCompletionReceipt())
        let transport = CatalogueTransport([.http(503, "{}"), .network, .http(200, receipt), .http(200, receipt)])
        let api = client(transport)
        try await api.updateClientLocale("pl")
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        for _ in 0..<2 {
            do {
                _ = try await api.sendOutboxCommand(command, context: lease)
                XCTFail("Fixture failure must propagate for exact retry")
            } catch is URLError {}
        }
        for _ in 0..<2 {
            let result = try await api.sendOutboxCommand(restored, context: lease)
            XCTAssertEqual(result.plantId, serverPlantId)
            XCTAssertEqual(result.ruleId, routineRuleId)
            XCTAssertEqual(result.careRevision, 2)
            XCTAssertEqual(result.occurrenceKey, "fixture-routine-occurrence")
            XCTAssertEqual(result.dueLocalDate, "2026-11-03")
            XCTAssertEqual(result.taskId.uuidString.lowercased(), "19190000-0000-4000-8000-000000000002")
            XCTAssertEqual(result.entryId.uuidString.lowercased(), "19190000-0000-4000-8000-000000000003")
            XCTAssertEqual(result.state, .completed)
            XCTAssertEqual(result.watermark, SQLTimestamp.microseconds(from: timestamp))
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 4)
        let firstBody = try XCTUnwrap(requests.first?.httpBody)
        for request in requests {
            XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/functions/v1/plants-api/commands")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.httpBody, firstBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(syncSession.accessToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), operationId.uuidString.lowercased())
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Locale"), "en")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Installation-Credential"))
            XCTAssertEqual(try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(request.httpBody)),
                           command.envelope)
        }
    }

    @MainActor
    func testRoutineCompletionRejectsMalformedAndMismatchedReceipts() async throws {
        let command = try routineCompletionCommand()
        let canonical = routineCompletionReceipt()
        var invalid: [[String: Any]] = []
        for key in canonical.keys {
            var missing = canonical
            missing.removeValue(forKey: key)
            invalid.append(missing)
            var null = canonical
            null[key] = NSNull()
            invalid.append(null)
        }
        let changes: [(String, Any)] = [
            ("plant_id", UUID().uuidString), ("rule_id", UUID().uuidString),
            ("care_revision", 3), ("care_revision", 0), ("care_revision", Int(Int32.max) + 1),
            ("care_revision", true), ("due_local_date", "2026-11-04"),
            ("due_local_date", "2026-02-30"), ("occurrence_key", " \n"),
            ("task_id", "bad-uuid"), ("entry_id", "bad-uuid"),
            ("state", "active"), ("watermark", "2026-11-03")
        ]
        for (key, value) in changes {
            var changed = canonical
            changed[key] = value
            invalid.append(changed)
        }
        for object in invalid {
            let transport = CatalogueTransport([.http(200, try syncJSON(object))])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            do {
                _ = try await api.sendOutboxCommand(command, context: lease)
                XCTFail("Malformed or mismatched completion must fail")
            } catch {}
        }
    }

    @MainActor
    func testRoutineCompletionRequiresBoundAuthorityAndDedicatedRoute() async throws {
        let transport = CatalogueTransport([])
        let api = client(transport)
        let command = try routineCompletionCommand()
        let legacy = try await api.captureSyncContext(ownerId: syncOwner)
        do {
            _ = try await api.sendOutboxCommand(command, context: legacy)
            XCTFail("Unbound request must fail")
        } catch SyncWireValidationError.invalidSession {}
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let otherAPI = client(transport)
        await otherAPI.bindSyncSession(syncSession)
        let foreignLease = try await otherAPI.captureSyncContext(ownerId: syncOwner)
        do {
            _ = try await api.sendOutboxCommand(command, context: foreignLease)
            XCTFail("Foreign authority must fail")
        } catch SyncWireValidationError.invalidSession {}
        do {
            _ = try await api.sendOutboxCommand(command.envelope, context: lease)
            XCTFail("Generic route must not discard a completion receipt")
        } catch SyncWireValidationError.invalidRequest {}
        await api.bindSyncSession(NativeAuthSession(
            userId: otherSyncOwner, accessToken: "other-owner-token", expiresAt: .distantFuture
        ))
        do {
            _ = try await api.sendOutboxCommand(command, context: lease)
            XCTFail("Captured owner must fail after account switch")
        } catch SyncWireValidationError.invalidSession {}
        await api.bindSyncSession(nil)
        do {
            _ = try await api.sendOutboxCommand(command, context: lease)
            XCTFail("Signed-out replay must fail")
        } catch SyncWireValidationError.invalidSession {}
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testRoutineCompletionRejectsInFlightSessionChangesAndCancellation() async throws {
        let command = try routineCompletionCommand()
        for mode in 0..<3 {
            let transport = SuspendedCollectionTransport(try syncJSON(routineCompletionReceipt()))
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let operation = Task { try await api.sendOutboxCommand(command, context: lease) }
            await transport.waitForRequest()
            if mode == 2 {
                operation.cancel()
            } else {
                await api.bindSyncSession(NativeAuthSession(
                    userId: otherSyncOwner, accessToken: "other-owner-token", expiresAt: .distantFuture
                ))
                if mode == 1 { await api.bindSyncSession(syncSession) }
            }
            await transport.resume()
            do {
                _ = try await operation.value
                XCTFail("Stale or cancelled completion must fail")
            } catch is CancellationError {
                XCTAssertEqual(mode, 2)
            } catch SyncWireValidationError.invalidSession {
                XCTAssertNotEqual(mode, 2)
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"),
                           "Bearer \(syncSession.accessToken)")
        }
    }
}

extension CollectionWireTests {
    /// Exact agreed wire6d689b7 responses, embedded for Simulator execution.
    private var accessFixtures: [(name: String, json: String)] {
        [
            ("free_starter_and_shared_month", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":false,"starter":{"identification_remaining":1,"diagnosis_remaining":0,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":"2026-11-01T10:20:00.123456Z"},"monthly":{"quota_kind":"free_monthly","registered_at":"2026-10-31T10:20:00.123456Z","period_start":"2026-10-31T10:20:00.123456Z","period_end":"2026-11-30T10:20:00.123456Z","limit":3,"consumed":2,"reserved":0,"remaining":1,"status":"ready"},"modes":{"identification":{"mode":"identification","allowed":true,"activeQuotaKind":"starter_identification","remaining":1,"limit":1,"inProgressJobId":null,"nextResetAt":null},"diagnosis":{"mode":"diagnosis","allowed":true,"activeQuotaKind":"free_monthly","remaining":1,"limit":3,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z"}}}"#),
            ("trial_or_paid_same_spend", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":false,"starter":{"identification_remaining":1,"diagnosis_remaining":0,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":"2026-11-01T10:20:00.123456Z"},"monthly":{"quota_kind":"paid_monthly","registered_at":"2026-10-31T10:20:00.123456Z","period_start":"2026-10-31T10:20:00.123456Z","period_end":"2026-11-30T10:20:00.123456Z","limit":100,"consumed":2,"reserved":0,"remaining":98,"status":"ready"},"modes":{"identification":{"mode":"identification","allowed":true,"activeQuotaKind":"paid_monthly","remaining":98,"limit":100,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z"},"diagnosis":{"mode":"diagnosis","allowed":true,"activeQuotaKind":"paid_monthly","remaining":98,"limit":100,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z"}}}"#),
            ("expired_paid_no_refill", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":false,"starter":{"identification_remaining":0,"diagnosis_remaining":0,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":"2026-11-01T10:20:00.123456Z"},"monthly":{"quota_kind":"free_monthly","registered_at":"2026-10-31T10:20:00.123456Z","period_start":"2026-10-31T10:20:00.123456Z","period_end":"2026-11-30T10:20:00.123456Z","limit":3,"consumed":7,"reserved":0,"remaining":0,"status":"ready"},"modes":{"identification":{"mode":"identification","allowed":false,"activeQuotaKind":"free_monthly","remaining":0,"limit":3,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z","reason":"free_monthly_exhausted"},"diagnosis":{"mode":"diagnosis","allowed":false,"activeQuotaKind":"free_monthly","remaining":0,"limit":3,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z","reason":"free_monthly_exhausted"}}}"#),
            ("legacy_unknown_starter_still_available", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":false,"starter":{"identification_remaining":1,"diagnosis_remaining":0,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":"2026-11-01T10:20:00.123456Z"},"monthly":{"quota_kind":"free_monthly","registered_at":null,"period_start":null,"period_end":null,"limit":null,"consumed":null,"reserved":null,"remaining":null,"status":"registration_required"},"modes":{"identification":{"mode":"identification","allowed":true,"activeQuotaKind":"starter_identification","remaining":1,"limit":1,"inProgressJobId":null,"nextResetAt":null},"diagnosis":{"mode":"diagnosis","allowed":false,"activeQuotaKind":"free_monthly","remaining":0,"limit":3,"inProgressJobId":null,"nextResetAt":null,"reason":"quota_registration_required"}}}"#),
            ("legacy_spend_unresolved", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":false,"starter":{"identification_remaining":1,"diagnosis_remaining":0,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":"2026-11-01T10:20:00.123456Z"},"monthly":{"quota_kind":"free_monthly","registered_at":"2026-10-31T10:20:00.123456Z","period_start":"2026-10-31T10:20:00.123456Z","period_end":"2026-11-30T10:20:00.123456Z","limit":null,"consumed":null,"reserved":null,"remaining":null,"status":"history_unresolved"},"modes":{"identification":{"mode":"identification","allowed":true,"activeQuotaKind":"starter_identification","remaining":1,"limit":1,"inProgressJobId":null,"nextResetAt":null},"diagnosis":{"mode":"diagnosis","allowed":false,"activeQuotaKind":"free_monthly","remaining":0,"limit":3,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z","reason":"quota_history_unresolved"}}}"#),
            ("guest_two_independent_starters", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":true,"starter":{"identification_remaining":1,"diagnosis_remaining":1,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":null},"monthly":{"quota_kind":null,"registered_at":null,"period_start":null,"period_end":null,"limit":null,"consumed":null,"reserved":null,"remaining":null,"status":"not_applicable"},"modes":{"identification":{"mode":"identification","allowed":true,"activeQuotaKind":"starter_identification","remaining":1,"limit":1,"inProgressJobId":null,"nextResetAt":null},"diagnosis":{"mode":"diagnosis","allowed":true,"activeQuotaKind":"starter_diagnosis","remaining":1,"limit":1,"inProgressJobId":null,"nextResetAt":null}}}"#),
            ("paid_exhausted_no_starter_fallback", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":false,"starter":{"identification_remaining":1,"diagnosis_remaining":0,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":"2026-11-01T10:20:00.123456Z"},"monthly":{"quota_kind":"paid_monthly","registered_at":"2026-10-31T10:20:00.123456Z","period_start":"2026-10-31T10:20:00.123456Z","period_end":"2026-11-30T10:20:00.123456Z","limit":100,"consumed":100,"reserved":0,"remaining":0,"status":"ready"},"modes":{"identification":{"mode":"identification","allowed":false,"activeQuotaKind":"paid_monthly","remaining":0,"limit":100,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z","reason":"paid_monthly_exhausted"},"diagnosis":{"mode":"diagnosis","allowed":false,"activeQuotaKind":"paid_monthly","remaining":0,"limit":100,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z","reason":"paid_monthly_exhausted"}}}"#)
        ]
    }

    private var accessOwner: UUID { UUID(uuidString: "16380000-0000-4000-8000-000000000001")! }
    private var accessSession: NativeAuthSession {
        NativeAuthSession(userId: accessOwner, accessToken: "captured-access-token", expiresAt: .distantFuture)
    }

    private func accessObject(_ index: Int = 0) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(accessFixtures[index].json.utf8)) as? [String: Any])
    }

    private func decodeAccess(_ object: [String: Any]) throws -> AnalysisAccessWireDTO {
        try JSONDecoder().decode(AnalysisAccessWireDTO.self, from: Data(syncJSON(object).utf8))
    }

    private func setAccessValue(_ object: inout [String: Any], path: [String], value: Any?) {
        let key = path[0]
        if path.count == 1 {
            object[key] = value
        } else {
            var child = object[key] as! [String: Any]
            setAccessValue(&child, path: Array(path.dropFirst()), value: value)
            object[key] = child
        }
    }

    func testAccessSevenCanonicalFixturesThroughRealBoundTransport() async throws {
        let limits: [Int?] = [3, 100, 3, nil, nil, nil, 100]
        let consumed: [Int?] = [2, 2, 7, nil, nil, nil, 100]
        let reserved: [Int?] = [0, 0, 0, nil, nil, nil, 0]
        let remaining: [Int?] = [1, 98, 0, nil, nil, nil, 0]
        let statuses: [AnalysisAccessWireDTO.Status] = [
            .ready, .ready, .ready, .registrationRequired, .historyUnresolved, .notApplicable, .ready
        ]
        let identificationKinds: [AnalysisAccessWireDTO.QuotaKind] = [
            .starterIdentification, .paidMonthly, .freeMonthly, .starterIdentification,
            .starterIdentification, .starterIdentification, .paidMonthly
        ]
        for (index, fixture) in accessFixtures.enumerated() {
            let direct = try JSONDecoder().decode(AnalysisAccessWireDTO.self, from: Data(fixture.json.utf8))
            let transport = CatalogueTransport([.http(200, fixture.json)])
            let api = client(transport)
            await api.bindSyncSession(accessSession)
            let context = try await api.captureSyncContext(ownerId: accessOwner)
            let snapshot = try await api.fetchAnalysisAccess(context: context, expectedGuest: index == 5)
            XCTAssertEqual(snapshot, direct, fixture.name)
            XCTAssertEqual(snapshot.ownerId, accessOwner)
            XCTAssertEqual(snapshot.isGuest, index == 5)
            XCTAssertEqual(snapshot.monthly.status, statuses[index])
            XCTAssertEqual(snapshot.monthly.limit, limits[index])
            XCTAssertEqual(snapshot.monthly.consumed, consumed[index])
            XCTAssertEqual(snapshot.monthly.reserved, reserved[index])
            XCTAssertEqual(snapshot.monthly.remaining, remaining[index])
            XCTAssertEqual(snapshot.modes["identification"]?.activeQuotaKind, identificationKinds[index])
            XCTAssertEqual(snapshot.modes["identification"]?.allowed, ![2, 6].contains(index))
            XCTAssertEqual(snapshot.modes["diagnosis"]?.allowed, [0, 1, 5].contains(index))
            XCTAssertEqual(snapshot.starter.identificationRemaining, index == 2 ? 0 : 1)
            XCTAssertEqual(snapshot.starter.diagnosisRemaining, index == 5 ? 1 : 0)
            XCTAssertNil(snapshot.starter.identificationInProgressJobId)
            XCTAssertNil(snapshot.starter.diagnosisInProgressJobId)
            XCTAssertEqual(snapshot.starter.firstStarterSuccessAt, index == 5 ? nil : "2026-11-01T10:20:00.123456Z")
            let knownPeriod = ![3, 5].contains(index)
            XCTAssertEqual(snapshot.monthly.registeredAt, knownPeriod ? "2026-10-31T10:20:00.123456Z" : nil)
            XCTAssertEqual(snapshot.monthly.periodStart, knownPeriod ? "2026-10-31T10:20:00.123456Z" : nil)
            XCTAssertEqual(snapshot.monthly.periodEnd, knownPeriod ? "2026-11-30T10:20:00.123456Z" : nil)
            if index == 1 || index == 2 || index == 6 {
                // Both modes read the same monthly pool, including consumed > current limit.
                XCTAssertEqual(snapshot.modes["identification"]?.remaining, remaining[index])
                XCTAssertEqual(snapshot.modes["diagnosis"]?.remaining, remaining[index])
                XCTAssertEqual(snapshot.modes["diagnosis"]?.limit, limits[index])
            }
            if index == 3 || index == 4 {
                XCTAssertNil(snapshot.monthly.remaining)
                XCTAssertEqual(snapshot.modes["diagnosis"]?.remaining, 0)
                XCTAssertEqual(snapshot.modes["diagnosis"]?.limit, 3)
                XCTAssertEqual(snapshot.modes["diagnosis"]?.reason,
                               index == 3 ? .registrationRequired : .historyUnresolved)
            }
            if index == 6 {
                XCTAssertEqual(snapshot.starter.identificationRemaining, 1)
                XCTAssertEqual(snapshot.modes["identification"]?.reason, .paidMonthlyExhausted)
                XCTAssertFalse(try XCTUnwrap(snapshot.modes["identification"]).allowed)
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/functions/v1/plants-api/analysis/access")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Operation-Id"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer captured-access-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Installation-Credential"),
                           index == 5 ? "fixture-installation" : nil)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Locale"), "en")
        }
    }

    func testAccessRequiredKeysNullsAndMalformedValuesFailClosed() throws {
        let required: [[String]] = [
            ["owner_id"], ["is_guest"], ["starter"], ["monthly"], ["modes"],
            ["starter", "identification_remaining"], ["starter", "diagnosis_remaining"],
            ["monthly", "status"], ["modes", "identification"], ["modes", "diagnosis"]
        ] + ["mode", "allowed", "activeQuotaKind", "remaining", "limit"].map { ["modes", "identification", $0] }
        let nullable: [[String]] = [
            ["starter", "identification_in_progress_job_id"], ["starter", "diagnosis_in_progress_job_id"],
            ["starter", "first_starter_success_at"]
        ] + ["quota_kind", "registered_at", "period_start", "period_end", "limit", "consumed", "reserved", "remaining"]
            .map { ["monthly", $0] }
          + ["inProgressJobId", "nextResetAt"].map { ["modes", "identification", $0] }
        for path in required + nullable {
            var object = try accessObject()
            setAccessValue(&object, path: path, value: nil)
            XCTAssertThrowsError(try decodeAccess(object), "Missing \(path)")
        }
        for path in required {
            var object = try accessObject()
            setAccessValue(&object, path: path, value: NSNull())
            XCTAssertThrowsError(try decodeAccess(object), "Null \(path)")
        }
        // Ready fields are nullable on the wire only in the explicitly unknown states.
        for key in ["quota_kind", "registered_at", "period_start", "period_end", "limit", "consumed", "reserved", "remaining"] {
            var object = try accessObject()
            setAccessValue(&object, path: ["monthly", key], value: NSNull())
            XCTAssertThrowsError(try decodeAccess(object), key)
        }
        let invalid: [([String], Any)] = [
            (["owner_id"], "foreign-not-a-uuid"), (["is_guest"], "false"),
            (["monthly", "status"], "unknown"), (["monthly", "quota_kind"], "starter_identification"),
            (["monthly", "quota_kind"], "unknown"), (["monthly", "registered_at"], "2026-02-30T00:00:00Z"),
            (["monthly", "period_start"], "2026-11-30T10:20:00.123456Z"),
            (["monthly", "period_end"], "2026-10-30T10:20:00.123456Z"),
            (["monthly", "consumed"], -1), (["monthly", "reserved"], -1),
            (["monthly", "remaining"], 2), (["monthly", "limit"], 100),
            (["monthly", "consumed"], 1.5), (["monthly", "reserved"], NSNumber(value: UInt64.max)),
            (["starter", "identification_remaining"], 2), (["starter", "diagnosis_remaining"], -1),
            (["starter", "first_starter_success_at"], "2026-11-01"),
            (["starter", "identification_in_progress_job_id"], "bad-job"),
            (["modes", "identification", "mode"], "diagnosis"),
            (["modes", "identification", "activeQuotaKind"], "unknown"),
            (["modes", "identification", "activeQuotaKind"], "starter_diagnosis"),
            (["modes", "identification", "remaining"], -1),
            (["modes", "identification", "remaining"], 2),
            (["modes", "identification", "remaining"], 0),
            (["modes", "identification", "allowed"], 1),
            (["modes", "identification", "inProgressJobId"], "not-a-uuid"),
            (["modes", "identification", "nextResetAt"], "2026-11-30T10:20:00Z"),
            (["modes", "diagnosis", "remaining"], 2),
            (["modes", "diagnosis", "nextResetAt"], "2026-11-30T10:20:00.123457Z")
        ]
        for (path, value) in invalid {
            var object = try accessObject()
            setAccessValue(&object, path: path, value: value)
            XCTAssertThrowsError(try decodeAccess(object), "\(path): \(value)")
        }
        var renamed = try accessObject()
        var modes = renamed["modes"] as! [String: Any]
        modes["care"] = modes.removeValue(forKey: "diagnosis")
        renamed["modes"] = modes
        XCTAssertThrowsError(try decodeAccess(renamed))
        for index in [3, 4, 5] {
            var object = try accessObject(index)
            setAccessValue(&object, path: ["monthly", "limit"], value: 0)
            XCTAssertThrowsError(try decodeAccess(object))
        }
        var guestMismatch = try accessObject(5)
        guestMismatch["is_guest"] = false
        XCTAssertThrowsError(try decodeAccess(guestMismatch))
    }

    func testAccessRawBoundariesAdditiveFieldsInProgressAndOverflowSafeCounts() throws {
        for offset in ["Z", "+02:30", "-03:30"] {
            var object = try accessObject()
            let start = "2026-11-01T10:20:00.000001\(offset)"
            let end = "2026-11-01T10:20:00.000002\(offset)"
            setAccessValue(&object, path: ["monthly", "registered_at"], value: start)
            setAccessValue(&object, path: ["monthly", "period_start"], value: start)
            setAccessValue(&object, path: ["monthly", "period_end"], value: end)
            setAccessValue(&object, path: ["modes", "diagnosis", "nextResetAt"], value: end)
            setAccessValue(&object, path: ["starter", "first_starter_success_at"], value: start)
            let decoded = try decodeAccess(object)
            XCTAssertEqual(decoded.monthly.registeredAt, start)
            XCTAssertEqual(decoded.monthly.periodStart, start)
            XCTAssertEqual(decoded.monthly.periodEnd, end)
            XCTAssertEqual(decoded.starter.firstStarterSuccessAt, start)
            XCTAssertEqual(decoded.modes["diagnosis"]?.nextResetAt, end)
            for path in [["future"], ["starter", "future"], ["monthly", "future"], ["modes", "diagnosis", "future"]] {
                setAccessValue(&object, path: path, value: ["additive": true])
            }
            XCTAssertEqual(try decodeAccess(object), decoded)
        }
        var inProgress = try accessObject(5)
        let job = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        setAccessValue(&inProgress, path: ["starter", "identification_in_progress_job_id"], value: job)
        setAccessValue(&inProgress, path: ["modes", "identification", "allowed"], value: false)
        setAccessValue(&inProgress, path: ["modes", "identification", "inProgressJobId"], value: job)
        setAccessValue(&inProgress, path: ["modes", "identification", "reason"], value: "starter_in_progress")
        let denied = try decodeAccess(inProgress)
        XCTAssertEqual(denied.modes["identification"]?.reason, .starterInProgress)
        XCTAssertEqual(denied.modes["identification"]?.inProgressJobId, UUID(uuidString: job))
        XCTAssertEqual(denied.modes["identification"]?.remaining, 1)
        var huge = try accessObject(2)
        setAccessValue(&huge, path: ["monthly", "consumed"], value: Int.max)
        setAccessValue(&huge, path: ["monthly", "reserved"], value: Int.max)
        let saturated = try decodeAccess(huge)
        XCTAssertEqual(saturated.monthly.remaining, 0)
        XCTAssertEqual(saturated.monthly.consumed, Int.max)
        XCTAssertEqual(saturated.monthly.reserved, Int.max)
    }

    func testAccessGuestCredentialPermanentAccountAndENPLHeaders() async throws {
        let credentials: [String?] = [nil, "", " \n "]
        for credential in credentials {
            let transport = CatalogueTransport([])
            let api = PlantsAPIClient(transport: transport, installationCredential: credential)
            await api.bindSyncSession(accessSession)
            let lease = try await api.captureSyncContext(ownerId: accessOwner)
            do {
                _ = try await api.fetchAnalysisAccess(context: lease, expectedGuest: true)
                XCTFail("Guest must provide an installation credential")
            } catch AnalysisAccessWireError.missingInstallationCredential {}
            let requests = await transport.capturedRequests()
            XCTAssertTrue(requests.isEmpty)
        }
        let transport = CatalogueTransport([.http(200, accessFixtures[0].json), .http(200, accessFixtures[0].json)])
        let api = PlantsAPIClient(transport: transport, installationCredential: nil, clientLocale: "en")
        await api.bindSyncSession(accessSession)
        let lease = try await api.captureSyncContext(ownerId: accessOwner)
        _ = try await api.fetchAnalysisAccess(context: lease, expectedGuest: false)
        try await api.updateClientLocale("pl")
        _ = try await api.fetchAnalysisAccess(context: lease, expectedGuest: false)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "X-Client-Locale") }, ["en", "pl"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Installation-Credential") == nil })
    }

    func testAccessRepositoryUsesClaimCredentialForGuestAndAccountOnlyForPermanent() async throws {
        let transport = CatalogueTransport([.http(200, accessFixtures[5].json), .http(200, accessFixtures[0].json)])
        let api = PlantsAPIClient(transport: transport, installationCredential: "old-client-installation", clientLocale: "en")
        let repository = AnalysisAccessRepository()
        let credential = "same-fixture-installation-used-for-claim"
        await api.bindSyncSession(accessSession)
        let guest = try await api.captureSyncContext(ownerId: accessOwner)
        let guestAccess = try await repository.fetchSnapshot(
            api: api, context: guest, expectedGuest: true, guestCredential: credential
        )
        XCTAssertTrue(guestAccess.isGuest)

        let signedIn = NativeAuthSession(userId: accessOwner, accessToken: "permanent-bearer", expiresAt: .distantFuture)
        await api.bindSyncSession(signedIn)
        let permanent = try await api.captureSyncContext(ownerId: accessOwner)
        let access = try await repository.fetchSnapshot(
            api: api, context: permanent, expectedGuest: false, guestCredential: credential
        )
        XCTAssertFalse(access.isGuest)
        do {
            _ = try await repository.fetchSnapshot(api: api, context: guest, expectedGuest: true, guestCredential: credential)
            XCTFail("An expired guest lease must not be used after sign-in")
        } catch SyncWireValidationError.invalidSession {}

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer captured-access-token", "Bearer permanent-bearer"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "X-Installation-Credential") }, [credential, nil])
        let nonRedirectingRequests = await transport.nonRedirectingRequests
        XCTAssertEqual(nonRedirectingRequests, 2)
    }

    func testAccessExplicitRetryErrorsWrongSuccessAndForeignScope() async throws {
        let error = #"{"error":{"code":"INTERNAL_ERROR","message":"Try again","retryable":true}}"#
        let transport = CatalogueTransport([.http(503, error), .http(200, accessFixtures[0].json)])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let lease = try await api.captureSyncContext(ownerId: accessOwner)
        do {
            _ = try await api.fetchAnalysisAccess(context: lease, expectedGuest: false)
            XCTFail("503 must propagate")
        } catch let failure as APIErrorResponse {
            XCTAssertEqual(failure.error.code, "INTERNAL_ERROR")
            XCTAssertTrue(failure.error.retryable)
        }
        let beforeRetry = await transport.capturedRequests()
        XCTAssertEqual(beforeRetry.count, 1)
        _ = try await api.fetchAnalysisAccess(context: lease, expectedGuest: false)
        let afterRetry = await transport.capturedRequests()
        XCTAssertEqual(afterRetry.count, 2)
        XCTAssertEqual(afterRetry.first, afterRetry.last)
        for (status, code) in [(401, "UNAUTHORIZED"), (403, "FORBIDDEN")] {
            let json = #"{"error":{"code":"__CODE__","message":"Denied","retryable":false}}"#
                .replacingOccurrences(of: "__CODE__", with: code)
            let mock = CatalogueTransport([.http(status, json)])
            let failingAPI = client(mock)
            await failingAPI.bindSyncSession(accessSession)
            let context = try await failingAPI.captureSyncContext(ownerId: accessOwner)
            do {
                _ = try await failingAPI.fetchAnalysisAccess(context: context, expectedGuest: false)
                XCTFail("Auth errors must propagate")
            } catch let failure as APIErrorResponse { XCTAssertEqual(failure.error.code, code) }
            let requests = await mock.capturedRequests()
            XCTAssertEqual(requests.count, 1)
        }
        for reply in [CatalogueTransport.Reply.network, .cancelled, .urlCancelled] {
            let mock = CatalogueTransport([reply])
            let failingAPI = client(mock)
            await failingAPI.bindSyncSession(accessSession)
            let context = try await failingAPI.captureSyncContext(ownerId: accessOwner)
            do {
                _ = try await failingAPI.fetchAnalysisAccess(context: context, expectedGuest: false)
                XCTFail("Transport errors must propagate")
            } catch is CancellationError {
                if case .cancelled = reply {} else { XCTFail("Wrong cancellation") }
            } catch let failure as URLError {
                if case .network = reply { XCTAssertEqual(failure.code, .networkConnectionLost) }
                else { XCTAssertEqual(failure.code, .cancelled) }
            }
            let requests = await mock.capturedRequests()
            XCTAssertEqual(requests.count, 1)
        }
        var foreign = try accessObject()
        foreign["owner_id"] = otherSyncOwner.uuidString
        let invalidReplies: [(Int, String)] = [
            (201, accessFixtures[0].json), (204, accessFixtures[0].json),
            (200, "{}"), (200, "null"), (200, "invalid-json"),
            (200, try syncJSON(foreign)), (200, accessFixtures[5].json)
        ]
        for (status, json) in invalidReplies {
            let mock = CatalogueTransport([.http(status, json)])
            let failingAPI = client(mock)
            await failingAPI.bindSyncSession(accessSession)
            let context = try await failingAPI.captureSyncContext(ownerId: accessOwner)
            do {
                _ = try await failingAPI.fetchAnalysisAccess(context: context, expectedGuest: false)
                XCTFail("Wrong success or foreign scope must be rejected")
            } catch {}
            let requests = await mock.capturedRequests()
            XCTAssertEqual(requests.count, 1)
        }
        let wrongGuest = client(CatalogueTransport([.http(200, accessFixtures[0].json)]))
        await wrongGuest.bindSyncSession(accessSession)
        let guestLease = try await wrongGuest.captureSyncContext(ownerId: accessOwner)
        do {
            _ = try await wrongGuest.fetchAnalysisAccess(context: guestLease, expectedGuest: true)
            XCTFail("Permanent response cannot satisfy guest scope")
        } catch AnalysisAccessWireError.identityMismatch {}
    }

    func testAccessUnboundForeignStaleAndInvalidSessionsNeverDispatch() async throws {
        let transport = CatalogueTransport([])
        let api = client(transport)
        let explicitSessions: [NativeAuthSession?] = [nil, accessSession]
        for explicit in explicitSessions {
            let legacy = try api.syncAuthority.capture(ownerId: accessOwner, explicitSession: explicit)
            do {
                _ = try await api.fetchAnalysisAccess(context: legacy, expectedGuest: false)
                XCTFail("Legacy bearer-only/explicit context is not bound proof")
            } catch SyncWireValidationError.invalidSession {}
        }
        await api.bindSyncSession(accessSession)
        let lease = try await api.captureSyncContext(ownerId: accessOwner)
        let otherAPI = client(transport)
        await otherAPI.bindSyncSession(accessSession)
        do {
            _ = try await otherAPI.fetchAnalysisAccess(context: lease, expectedGuest: false)
            XCTFail("A lease from another authority is invalid")
        } catch SyncWireValidationError.invalidSession {}
        await api.bindSyncSession(accessSession)
        do {
            _ = try await api.fetchAnalysisAccess(context: lease, expectedGuest: false)
            XCTFail("Even rebinding the same session invalidates old leases")
        } catch SyncWireValidationError.invalidSession {}
        for session in [
            NativeAuthSession(userId: accessOwner, accessToken: "", expiresAt: .distantFuture),
            NativeAuthSession(userId: accessOwner, accessToken: "expired", expiresAt: .distantPast),
            NativeAuthSession(userId: otherSyncOwner, accessToken: "foreign", expiresAt: .distantFuture)
        ] {
            await api.bindSyncSession(session)
            do {
                _ = try await api.captureSyncContext(ownerId: accessOwner)
                XCTFail("Invalid session cannot be captured")
            } catch SyncWireValidationError.invalidSession {}
        }
        await api.bindSyncSession(nil)
        do {
            _ = try await api.captureSyncContext(ownerId: accessOwner)
            XCTFail("Signed-out authority cannot be captured")
        } catch SyncWireValidationError.invalidSession {}
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testAccessSuspendedSignoutRefreshABABACancelAndLocaleCapture() async throws {
        for action in 0...6 {
            let transport = SuspendedCollectionTransport(accessFixtures[0].json)
            let api = client(transport)
            let session = accessSession
            await api.bindSyncSession(session)
            let lease = try await api.captureSyncContext(ownerId: accessOwner)
            let operation = Task { try await api.fetchAnalysisAccess(context: lease, expectedGuest: false) }
            await transport.waitForRequest()
            switch action {
            case 0: await api.bindSyncSession(nil)
            case 1:
                await api.bindSyncSession(NativeAuthSession(
                    userId: accessOwner, accessToken: "refreshed-token", expiresAt: .distantFuture
                ))
            case 2, 3:
                await api.bindSyncSession(NativeAuthSession(
                    userId: otherSyncOwner, accessToken: "owner-b-token", expiresAt: .distantFuture
                ))
                if action == 3 { await api.bindSyncSession(session) }
            case 4:
                await api.updateContext(installationCredential: "changed", clientLocale: "pl", bearerToken: "changed")
            case 5: operation.cancel()
            default: try await api.updateClientLocale("pl")
            }
            await transport.resume()
            do {
                let snapshot = try await operation.value
                XCTAssertEqual(action, 6, "Stale/cancelled snapshots must never publish")
                XCTAssertEqual(snapshot.ownerId, accessOwner)
            } catch is CancellationError {
                XCTAssertEqual(action, 5)
            } catch SyncWireValidationError.invalidSession {
                XCTAssertLessThan(action, 5)
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer captured-access-token")
            XCTAssertNil(requests.first?.value(forHTTPHeaderField: "X-Installation-Credential"))
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Client-Locale"), "en")
        }
    }
}

private actor CatalogueTransport: PlantsAPITransport {
    enum Reply: Sendable {
        case http(Int, String)
        case held(Int, String)
        case redirect(String)
        case inspect(@Sendable ([URLRequest]) throws -> String)
        case photo(Data, mime: String)
        case network
        case cancelled
        case urlCancelled
    }

    private var held: CheckedContinuation<Void, Never>?
    private var heldObservers: [CheckedContinuation<Void, Never>] = []
    func waitForHeld() async {
        if held != nil { return }
        await withCheckedContinuation { heldObservers.append($0) }
    }
    func releaseHeld() { held?.resume(); held = nil }

    private var replies: [Reply]
    private var requests: [URLRequest] = []
    private(set) var nonRedirectingRequests = 0

    init(_ replies: [Reply]) { self.replies = replies }

    func capturedRequests() -> [URLRequest] { requests }

    func sendWithoutRedirect(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        nonRedirectingRequests += 1
        return try await send(request)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        switch replies.removeFirst() {
        case .network:
            throw URLError(.networkConnectionLost)
        case .cancelled:
            throw CancellationError()
        case .urlCancelled:
            throw URLError(.cancelled)
        case let .redirect(location):
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                             headerFields: ["Location": location])!)
        case let .held(status, json):
            await withCheckedContinuation { continuation in
                held = continuation
                for observer in heldObservers { observer.resume() }
                heldObservers.removeAll()
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                                    httpVersion: nil, headerFields: nil)!)
        case let .http(status, json):
            return (
                Data(json.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        case let .inspect(makeBody):
            return (Data(try makeBody(requests).utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case let .photo(bytes, mime):
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": mime])!)
        }
    }
}

final class CollectionWireTests: XCTestCase {
    private let operationId = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let serverPlantId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let timestamp = "2026-11-03T09:00:00.999999+00:00"

    private func receiptJSON() -> String {
        """
        {"plant_id":"22222222-2222-4222-8222-222222222222","care_revision":1,
         "context_state":"current","next_available_step":"enable_basic_care",
         "paid_action":"generate_full_routine_plan","plan_availability":"available",
         "watermark":"\(timestamp)","future_field":{"ignored":true}}
        """
    }

    private func envelope(_ payload: String = #"{"creation_source":"catalogue","plant_id":"fixture_collection_cap"}"#)
        -> CommandEnvelopeDTO {
        CommandEnvelopeDTO(operationId: operationId, commandName: "plant.create", payloadJSON: payload)
    }

    private func client(_ transport: any PlantsAPITransport) -> PlantsAPIClient {
        PlantsAPIClient(
            baseURL: URL(string: "https://example.invalid/functions/v1/plants-api")!,
            transport: transport,
            installationCredential: "fixture-installation",
            clientLocale: "en",
            bearerToken: "fixture-user-token"
        )
    }

    func testCanonicalReceiptAndExactRequestRetryAfter503() async throws {
        let error = #"{"error":{"code":"INTERNAL_ERROR","message":"Try again","retryable":true}}"#
        let transport = CatalogueTransport([.http(503, error), .http(200, receiptJSON())])
        let api = client(transport)
        let command = envelope(#"{ "creation_source":"catalogue", "plant_id":"fixture_collection_cap", "display_name":null }"#)
        do {
            _ = try await api.sendCatalogueCreate(command)
            XCTFail("503 must not confirm creation")
        } catch let failure as APIErrorResponse {
            XCTAssertEqual(failure.error.code, "INTERNAL_ERROR")
            XCTAssertTrue(failure.error.retryable)
        }
        let receipt = try await api.sendCatalogueCreate(command)
        XCTAssertEqual(receipt.plantId, serverPlantId)
        XCTAssertEqual(receipt.careRevision, 1)
        XCTAssertEqual(receipt.contextState, "current")
        XCTAssertEqual(receipt.nextAvailableStep, "enable_basic_care")
        XCTAssertEqual(receipt.planAvailability, "available")
        XCTAssertEqual(receipt.paidAction, "generate_full_routine_plan")
        XCTAssertEqual(receipt.watermarkRaw, timestamp)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/functions/v1/plants-api/commands")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-user-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Installation-Credential"), "fixture-installation")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Locale"), "en")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), operationId.uuidString.lowercased())
            let body = try XCTUnwrap(request.httpBody)
            XCTAssertEqual(try JSONDecoder().decode(CommandEnvelopeDTO.self, from: body), command)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["operation_id", "command_name", "payload_json"])
            XCTAssertEqual(object["payload_json"] as? String, command.payloadJSON)
        }
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        let encoded = try JSONEncoder().encode(receipt)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["watermark"] as? String, timestamp)
        XCTAssertNil(object["status"])
        XCTAssertNil(object["operation_id"])
        XCTAssertNil(object["replayed"])
    }

    func testSQLTimestampsAndOptionalPaidAction() async throws {
        let base = ISO8601DateFormatter().date(from: "2026-11-03T09:00:00Z")!
        let variants: [(String, TimeInterval)] = [
            ("2026-11-03T09:00:00Z", 0),
            ("2026-11-03T09:00:00.1Z", 0.1),
            ("2026-11-03T09:00:00.12+02:30", 0.12 - 9000),
            ("2026-11-03T09:00:00.123-03:30", 0.123 + 12600),
            ("2026-11-03T09:00:00.1234Z", 0.1234),
            ("2026-11-03T09:00:00.12345+15:59", 0.12345 - 57540),
            ("2026-11-03T09:00:00.999999-15:59", 0.999999 + 57540)
        ]
        for (raw, delta) in variants {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receiptJSON().utf8)) as? [String: Any])
            object["watermark"] = raw
            object["paid_action"] = NSNull()
            let data = try JSONSerialization.data(withJSONObject: object)
            let transport = CatalogueTransport([.http(200, String(decoding: data, as: UTF8.self))])
            let receipt = try await client(transport).sendCatalogueCreate(envelope())
            XCTAssertNil(receipt.paidAction)
            XCTAssertEqual(receipt.watermarkRaw, raw)
            XCTAssertEqual(receipt.watermark.timeIntervalSince1970, base.timeIntervalSince1970 + delta, accuracy: 0.000001)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receiptJSON().utf8)) as? [String: Any])
        object.removeValue(forKey: "paid_action")
        let receipt = try JSONDecoder().decode(PlantCreateReceiptDTO.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(receipt.paidAction)
    }

    func testInvalidSuccessIsRejectedByTypedAPI() async throws {
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receiptJSON().utf8)) as? [String: Any])
        let required = ["plant_id", "care_revision", "context_state", "next_available_step", "plan_availability", "watermark"]
        var invalid: [[String: Any]] = []
        for key in required {
            var missing = valid
            missing.removeValue(forKey: key)
            invalid.append(missing)
            for value in [NSNull(), true, ["unexpected": "object"]] as [Any] {
                var object = valid
                object[key] = value
                invalid.append(object)
            }
        }
        let malformed: [(String, [Any])] = [
            ("plant_id", ["not-a-uuid", ""]),
            ("care_revision", [0, -1, 1.5, "1", 9_007_199_254_740_992]),
            ("context_state", ["", " \n"]),
            ("next_available_step", ["", " "]),
            ("plan_availability", ["", " "]),
            ("paid_action", [false, 1, ["action": "invented"]]),
            ("watermark", ["2026-11-03T09:00:00", "2026-02-30T09:00:00Z",
                           "2025-02-29T09:00:00Z", "2026-11-03T24:00:00Z",
                           "2026-11-03T09:00:60Z", "2026-11-03T09:00:00.1234567Z",
                           "2026-11-03T09:00:00+16:00", "2026-11-03T09:00:00+00:60",
                           "2026-11-03T09:00:00Z\n", "garbage"])
        ]
        for (key, values) in malformed {
            for value in values {
                var object = valid
                object[key] = value
                invalid.append(object)
            }
        }
        var jsons = try invalid.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        jsons += ["null", "[]", "{}", #"{"status":"committed","operation_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","replayed":false}"#]
        for json in jsons {
            let transport = CatalogueTransport([.http(200, json)])
            do {
                _ = try await client(transport).sendCatalogueCreate(envelope())
                XCTFail("Invalid receipt accepted: \(json)")
            } catch is DecodingError {
                // A 200 response is not sufficient evidence of creation.
            }
        }
    }

    func testErrorsPropagateWithoutConfirmationAndNetworkRetryKeepsOperation() async throws {
        for (status, code, retryable) in [
            (409, "COLLECTION_LIMIT_REACHED", false), (409, "CONFLICT", false),
            (401, "UNAUTHORIZED", false), (403, "FORBIDDEN", false),
            (400, "VALIDATION_ERROR", false), (503, "INTERNAL_ERROR", true)
        ] {
            let json = """
            {"error":{"code":"\(code)","message":"Server message","retryable":\(retryable)}}
            """
            let transport = CatalogueTransport([.http(status, json)])
            do {
                _ = try await client(transport).sendCatalogueCreate(envelope())
                XCTFail("Error response must throw")
            } catch let error as APIErrorResponse {
                XCTAssertEqual(error.error.code, code)
                XCTAssertEqual(error.error.message, "Server message")
                XCTAssertEqual(error.error.retryable, retryable)
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 1)
        }
        let transport = CatalogueTransport([.network, .http(200, receiptJSON())])
        let api = client(transport)
        do {
            _ = try await api.sendCatalogueCreate(envelope())
            XCTFail("Network error must throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        _ = try await api.sendCatalogueCreate(envelope())
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Operation-Id"),
                       requests[1].value(forHTTPHeaderField: "X-Operation-Id"))
    }

    func testDiagnosisSaveCheckpointKeepsTheJobAndRejectsMissingPhotoReceipt() throws {
        let input = CatalogueInput(diagnosisJobId: UUID(), speciesSlug: "monstera_deliciosa", personalName: "Window")
        let envelope = try input.makeEnvelope(operationId: UUID())
        let restored = try CatalogueInput.fromCheckpoint(envelope)
        XCTAssertEqual(restored, input)
        XCTAssertEqual(try restored.makeEnvelope(operationId: envelope.operationId), envelope)
        XCTAssertEqual(CatalogueCreateWire.diagnosisSpecies(envelope), "monstera_deliciosa")
        XCTAssertNil(CatalogueCreateWire.identificationTaxon(envelope))
        let json = """
            {
              "plant_id":"00000000-0000-0000-0000-000000000001",
              "care_revision":1,"context_state":"current","next_available_step":"view_plant",
              "paid_action":null,"plan_availability":"available","watermark":"2026-11-16T12:00:00Z"
            }
            """
        let receipt = try JSONDecoder().decode(PlantCreateReceiptDTO.self, from: Data(json.utf8))
        XCTAssertThrowsError(try CatalogueCreateWire.validate(receipt, for: envelope))
    }

    func testCataloguePayloadValidationDoesNotSendOrSubstituteIdentity() async throws {
        let transport = CatalogueTransport([])
        let api = client(transport)
        let invalid = [
            "null", "[]", "{}", #"{"creation_source":"camera","plant_id":"slug"}"#,
            #"{"creation_source":"catalogue"}"#,
            #"{"creation_source":"catalogue","plant_id":" "}"#,
            #"{"creation_source":"catalogue","taxon_id":"bad"}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","owner_id":"injected"}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","conditions":{"owner_id":"injected"}}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","overrides":{"plan_availability":"available"}}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","photo_id":"unverified"}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","conditions":{"light_source":"camera_estimate"}}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","conditions":{"light_confirmed":1}}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","overrides":null}"#
        ]
        for payload in invalid {
            do {
                _ = try await api.sendCatalogueCreate(envelope(payload))
                XCTFail("Invalid payload sent")
            } catch CatalogueCreateValidationError.invalidPayload {
                // Rejected before transport.
            }
        }
        for command in [
            CommandEnvelopeDTO(operationId: operationId, commandName: "plant.update", payloadJSON: envelope().payloadJSON),
            CommandEnvelopeDTO(operationId: operationId, commandName: "plant.create", plantId: UUID(), payloadJSON: envelope().payloadJSON)
        ] {
            do {
                _ = try await api.sendCatalogueCreate(command)
                XCTFail("Invalid command sent")
            } catch CatalogueCreateValidationError.invalidCommand {
                // The SQL-created instance must not be replaced by a client target.
            }
        }
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCanonicalOverridesAndNullConditionsPassUnchanged() async throws {
        let payload = """
        {"creation_source":"catalogue","plant_id":null,
         "origin_flow_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","photo_id":null,
         "creation_intent":"care","add_method":"catalogue","personal_name":"My plant",
         "conditions":{"light_code":"medium","light_source":"manual","light_confirmed":true,
                       "watering_code":"weekly","drainage_code":"yes","pot_type":null},
         "overrides":{"taxon_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","display_name":null}}
        """
        let transport = CatalogueTransport([.http(200, receiptJSON())])
        let receipt = try await client(transport).sendCatalogueCreate(envelope(payload))
        XCTAssertEqual(receipt.plantId, serverPlantId)
        let requests = await transport.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        let command = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(command.payloadJSON, payload)
        XCTAssertEqual(command.operationId, operationId)
        XCTAssertNil(command.plantId)
    }
}

extension CollectionWireTests {
    @MainActor
    func testRestoredCardReadsCanonicalManualWateringWithoutWrites() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let flow = UUID()
        let input = CatalogueInput(speciesSlug: "fixture_collection_cap", personalName: "Saved plant")
        let command = try input.makeEnvelope(operationId: operationId)
        let receipt = try decodedCreateReceipt()
        let schema = Schema([
            LocalOutboxRecord.self, CatalogueCreateConfirmationRecord.self,
            CatalogueInputCheckpointRecord.self, GuestDraftCacheRecord.self,
            SyncedEntityRecord.self, SyncCheckpointRecord.self
        ])
        func reopen() throws -> LocalStore {
            LocalStore(modelContainer: try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url)
            ]))
        }
        // Persist the actual input journal and typed confirmation, then release the store.
        do {
            let seed = try reopen()
            let api = client(CatalogueTransport([]))
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            _ = try await seed.checkpointCatalogueInput(
                input, flowId: flow, operationId: operationId,
                context: lease, authority: api.syncAuthority
            )
            _ = try await queueCreate(command, ownerId: syncOwner, in: seed)
            try await seed.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: lease, authority: api.syncAuthority
            )
        }
        let activeId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let voidedId = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        func fact(_ id: UUID, plant: UUID, task: UUID? = nil,
                  action: String = "water", state: String = "active",
                  occurred: String = "2026-11-02T23:30:00.000001Z",
                  day: String = "2026-11-03") -> [String: Any] {
            ["entity_type": "care_entries", "id": id.uuidString,
             "updated_at": syncUntil, "deleted_at": NSNull(),
             "data": ["id": id.uuidString, "plant_id": plant.uuidString,
                      "task_id": task.map { $0.uuidString as Any } ?? NSNull(),
                      "action_code": action, "state": state, "occurred_at": occurred,
                      "occurred_local_date": day]]
        }
        let plant: [String: Any] = [
            "entity_type": "plants", "id": serverPlantId.uuidString,
            "updated_at": syncUntil, "deleted_at": NSNull(),
            "data": ["id": serverPlantId.uuidString, "plant_id": input.speciesIdentifier,
                     "personal_name": "Saved plant", "revision": 1, "care_revision": 1]
        ]
        var changes = [
            fact(activeId, plant: serverPlantId),
            fact(voidedId, plant: serverPlantId, state: "voided",
                 occurred: "2026-11-03T01:00:00.000001Z"),
            fact(UUID(), plant: otherSyncOwner),
            fact(UUID(), plant: serverPlantId, task: UUID()),
            fact(UUID(), plant: serverPlantId, action: "fertilize"),
            plant
        ]
        changes.sort {
            let lhs = ($0["entity_type"] as! String, $0["id"] as! String)
            let rhs = ($1["entity_type"] as! String, $1["id"] as! String)
            return lhs < rhs
        }
        var page = syncObject()
        page["changes"] = changes
        var invalidHistory = syncObject()
        invalidHistory["changes"] = [
            fact(activeId, plant: serverPlantId, state: "invalid"), plant
        ]
        var empty = syncObject()
        empty["changes"] = [plant]
        let recommendation = try syncJSON([
            "plant_id": serverPlantId.uuidString, "status": "available",
            "recommendation": [
                "action_id": "verified-water-rule", "action_code": "check_soil",
                "text": "Check the substrate before watering.", "next_check_interval_days": NSNull(),
                "source": ["url": "https://example.invalid/watering", "locator": "Growing"]
            ] as [String: Any]
        ])
        let transport = CatalogueTransport([
            .http(200, try syncJSON(page)), .network, .http(200, recommendation),
            .http(200, try syncJSON(invalidHistory)),
            .network, .http(200, try syncJSON(empty))
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let store = try reopen()
        let repository = CollectionRepository(
            store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api)
        )
        let wrongFlow = await CatalogueSaveModel.restore(
            store: store, apiClient: api, repository: repository,
            ownerId: syncOwner, flowId: UUID(), session: syncSession, isAnonymous: false
        )
        guard case .absent = wrongFlow else { return XCTFail("Unrelated flow restored") }
        let result = await CatalogueSaveModel.restore(
            store: store, apiClient: api, repository: repository,
            ownerId: syncOwner, flowId: flow, session: syncSession, isAnonymous: false
        )
        guard case let .restored(model) = result else { return XCTFail("Expected durable restore") }
        XCTAssertEqual(model.wateringHistoryState, .idle)
        await model.loadCareRecommendation()
        XCTAssertEqual(model.careRecommendationState, .unavailable)
        await model.loadCard()
        XCTAssertEqual(model.cardSummary?.id, serverPlantId)
        guard case let .loaded(entries) = model.wateringHistoryState else {
            return XCTFail("Expected canonical history")
        }
        XCTAssertEqual(entries.map(\.id), [voidedId, activeId])
        XCTAssertEqual(entries.map(\.state), ["voided", "active"])
        XCTAssertEqual(entries.map(\.occurredLocalDate), ["2026-11-03", "2026-11-03"])
        await model.loadCareRecommendation()
        XCTAssertEqual(model.careRecommendationState, .failed)
        XCTAssertEqual(model.cardSummary?.id, serverPlantId)
        await model.loadCareRecommendation()
        await model.loadCareRecommendation(retry: true)
        guard case let .available(rule) = model.careRecommendationState else {
            return XCTFail("Expected a rule on the restored canonical card")
        }
        XCTAssertEqual(rule.text, "Check the substrate before watering.")
        XCTAssertEqual(rule.source.url, URL(string: "https://example.invalid/watering"))
        await model.loadCard()
        XCTAssertEqual(model.cardSummary?.id, serverPlantId)
        XCTAssertEqual(model.wateringHistoryState, .unavailable)
        await model.loadCard()
        XCTAssertNil(model.cardSummary)
        XCTAssertEqual(model.cardState, .unavailable)
        XCTAssertEqual(model.wateringHistoryState, .unavailable)
        await model.loadCard()
        XCTAssertEqual(model.wateringHistoryState, .loaded([]))
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), Array(repeating: "GET", count: 6))
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent },
                       ["sync", "recommendation", "recommendation", "sync", "sync", "sync"])
        let pending = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertTrue(pending.isEmpty)
        await api.bindSyncSession(nil)
        await api.bindSyncSession(syncSession)
        XCTAssertNil(model.cardSummary)
        XCTAssertEqual(model.wateringHistoryState, .unavailable)
        XCTAssertEqual(model.careRecommendationState, .unavailable)
        await model.loadCard()
        await model.loadCareRecommendation(retry: true)
        let afterABA = await transport.capturedRequests()
        XCTAssertEqual(afterABA.count, 6)
    }

    private var syncSince: String { "2026-11-03T08:00:00.000001+00:00" }
    private var syncUntil: String { "2026-11-03T09:00:00.999999+00:00" }
    private var syncOwner: UUID { UUID(uuidString: "11111111-1111-4111-8111-111111111111")! }
    private var syncSession: NativeAuthSession {
        NativeAuthSession(userId: syncOwner, accessToken: "sync-session-token", expiresAt: .distantFuture)
    }

    private func syncObject() -> [String: Any] {
        [
            "until": syncUntil, "has_more": false, "last_cursor": NSNull(), "next_since": syncUntil,
            "profile": ["preferred_locale": "pl", "reminder_hour_local": 9,
                        "report_notifications_enabled": true, "trial_reminder_enabled": false],
            "entitlement": NSNull(), "changes": [], "future_field": ["ignored": true]
        ]
    }

    private func syncChange(
        _ time: String? = nil, id: String = "22222222-2222-4222-8222-222222222222",
        entity: String = "plants"
    ) -> [String: Any] {
        ["entity_type": entity, "id": id, "updated_at": time ?? syncUntil,
         "deleted_at": NSNull(), "data": ["name": "Plant"]]
    }

    private func syncJSON(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func syncCursorObject(_ change: [String: Any]) -> [String: Any] {
        ["since": syncSince, "until": syncUntil, "updated_at": change["updated_at"]!,
         "entity_type": change["entity_type"]!, "id": change["id"]!]
    }

    private func assertSyncRejected(
        _ object: [String: Any], since: String? = nil, until: String? = nil,
        cursor: SyncWireCursorDTO? = nil, limit: Int = 200,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let transport = CatalogueTransport([.http(200, try syncJSON(object))])
        do {
            _ = try await client(transport).fetchSyncWirePage(
                session: syncSession, since: since, until: until, cursor: cursor, limit: limit
            )
            XCTFail("Invalid SQL page accepted", file: file, line: line)
        } catch is DecodingError {
        } catch SyncWireValidationError.invalidPage {
        }
    }

    func testSyncSQLNestedDataTombstoneAndAuthenticatedOwner() async throws {
        var object = syncObject()
        var live = syncChange("2026-11-03T09:00:00.123456+00:00")
        live["data"] = [
            "nested": ["array": [true, NSNull(), ["number": 123, "text": "żółty"]]],
            "decimal": 1.25, "owner_id": "projection-value"
        ]
        var tombstone = syncChange()
        tombstone["deleted_at"] = syncUntil
        tombstone["data"] = NSNull()
        object["changes"] = [live, tombstone]
        object["owner_id"] = "99999999-9999-4999-8999-999999999999"
        object["entitlement"] = [
            "product_id": "app.narat.plants.pro.yearly", "state": "active", "offer_kind": "paid",
            "valid_until": syncUntil, "grace_until": NSNull(), "trial_end_at": NSNull(),
            "auto_renew_enabled": true, "future": 1
        ]
        let transport = CatalogueTransport([.http(200, try syncJSON(object))])
        let result = try await client(transport).fetchSyncWirePage(session: syncSession, since: syncSince)
        XCTAssertEqual(result.ownerId, syncOwner)
        XCTAssertEqual(result.page.profile.preferredLocale, "pl")
        XCTAssertEqual(result.page.entitlement?.validUntil, syncUntil)
        XCTAssertNil(result.page.entitlement?.graceUntil)
        XCTAssertEqual(result.page.changes[1].data, .null)
        XCTAssertEqual(result.page.changes[1].deletedAt, syncUntil)
        guard case let .object(data) = result.page.changes[0].data else { return XCTFail("Expected SQL object") }
        XCTAssertEqual(data["nested"], .object([
            "array": .array([.bool(true), .null, .object(["number": .number(123), "text": .string("żółty")])])
        ]))
        XCTAssertEqual(data["decimal"], .number(Decimal(string: "1.25")!))
        let roundTrip = try JSONDecoder().decode(SyncWireJSON.self, from: JSONEncoder().encode(result.page.changes[0].data))
        XCTAssertEqual(roundTrip, result.page.changes[0].data)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sync-session-token")
    }

    func testSyncEmptyPageAndRawTimestampQueriesAcrossFractionsAndOffsets() async throws {
        let variants = [
            "2026-11-03T09:00:00Z", "2026-11-03T09:00:00.1Z",
            "2026-11-03T09:00:00.12+02:30", "2026-11-03T09:00:00.123-03:30",
            "2026-11-03T09:00:00.1234Z", "2026-11-03T09:00:00.12345+15:59",
            "2026-11-03T09:00:00.123456-15:59"
        ]
        for raw in variants {
            var object = syncObject()
            object["until"] = raw
            object["next_since"] = raw
            let transport = CatalogueTransport([.http(200, try syncJSON(object))])
            let result = try await client(transport).fetchSyncWirePage(
                session: syncSession, since: raw, until: raw, limit: 1
            )
            XCTAssertTrue(result.page.changes.isEmpty)
            XCTAssertNil(result.page.entitlement)
            XCTAssertFalse(result.page.profile.trialReminderEnabled)
            XCTAssertEqual(result.page.profile.reminderHourLocal, 9)
            XCTAssertEqual(result.page.until, raw)
            XCTAssertEqual(result.page.nextSince, raw)
            let requests = await transport.capturedRequests()
            let request = try XCTUnwrap(requests.first)
            let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/functions/v1/plants-api/sync")
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["since": raw, "until": raw, "limit": "1"])
            if raw.contains("+") { XCTAssertTrue(request.url!.absoluteString.contains("%2B")) }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sync-session-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Locale"), "en")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Installation-Credential"), "fixture-installation")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Operation-Id"))
        }
    }

    func testSyncPaginationKeepsWindowAndAdvancesOneMicrosecond() async throws {
        var first = syncObject()
        let change = syncChange("2026-11-03T09:00:00.999998+00:00")
        first["has_more"] = true
        first["next_since"] = NSNull()
        first["last_cursor"] = syncCursorObject(change)
        first["changes"] = [change]
        var final = syncObject()
        final["changes"] = [syncChange()]
        let transport = CatalogueTransport([.http(200, try syncJSON(first)), .http(200, try syncJSON(final))])
        let api = client(transport)
        let start = try await api.fetchSyncWirePage(session: syncSession, since: syncSince, until: syncUntil, limit: 1)
        let cursor = try XCTUnwrap(start.page.lastCursor)
        XCTAssertNil(start.page.nextSince)
        XCTAssertEqual(cursor.updatedAt, "2026-11-03T09:00:00.999998+00:00")
        XCTAssertEqual(cursor.since, syncSince)
        XCTAssertEqual(cursor.until, syncUntil)
        let end = try await api.fetchSyncWirePage(
            session: syncSession, since: cursor.since, until: cursor.until, cursor: cursor, limit: 1
        )
        XCTAssertEqual(end.page.nextSince, syncUntil)
        XCTAssertFalse(end.page.hasMore)
        XCTAssertNil(end.page.lastCursor)
        let requests = await transport.capturedRequests()
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, [
            "since": syncSince, "until": syncUntil, "limit": "1",
            "cursor_updated_at": cursor.updatedAt, "cursor_entity_type": "plants",
            "cursor_id": serverPlantId.uuidString.lowercased()
        ])
    }

    func testSyncStrictTupleOrderWithEqualTimestampAndEquivalentOffsets() async throws {
        let time = "2026-11-03T09:00:00.999999Z"
        let cursor = SyncWireCursorDTO(
            since: syncSince, until: syncUntil, updatedAt: time, entityType: "care_tasks", id: serverPlantId
        )
        var object = syncObject()
        object["changes"] = [
            syncChange(time, id: "33333333-3333-4333-8333-333333333333", entity: "care_tasks"),
            syncChange("2026-11-03T11:00:00.999999+02:00")
        ]
        let transport = CatalogueTransport([.http(200, try syncJSON(object))])
        let result = try await client(transport).fetchSyncWirePage(
            session: syncSession, since: syncSince, until: syncUntil, cursor: cursor
        )
        XCTAssertEqual(result.page.changes.count, 2)
        object["changes"] = [syncChange(time, entity: "care_tasks")]
        try await assertSyncRejected(object, since: syncSince, until: syncUntil, cursor: cursor)
        object["changes"] = [syncChange(time), syncChange(time)]
        try await assertSyncRejected(object)
        object["changes"] = [syncChange(time), syncChange(time, entity: "care_tasks")]
        try await assertSyncRejected(object)
    }

    func testSyncInvalidRequestsNeverReachTransport() async throws {
        let transport = CatalogueTransport([])
        let api = client(transport)
        let invalidDates = [
            "", "2026-11-03T09:00:00", "2026-02-30T09:00:00Z", "2025-02-29T09:00:00Z",
            "2026-11-03T24:00:00Z", "2026-11-03T09:00:60Z", "2026-11-03T09:00:00.1234567Z",
            "2026-11-03T09:00:00+16:00", "2026-11-03T09:00:00+00:60", "2026-11-03T09:00:00Z\n"
        ]
        var requests: [(String?, String?, SyncWireCursorDTO?, Int)] = invalidDates.flatMap { raw -> [(String?, String?, SyncWireCursorDTO?, Int)] in
            [(raw, nil, nil, 200), (nil, raw, nil, 200)]
        }
        requests += [(syncUntil, syncSince, nil, 200), (nil, nil, nil, 0), (nil, nil, nil, 501)]
        for (time, entity, end, start) in [
            (syncSince, "plants", syncUntil, syncSince),
            ("2026-11-03T09:00:01Z", "plants", syncUntil, syncSince),
            (syncUntil, "rooms", syncUntil, syncSince),
            ("bad", "plants", syncUntil, syncSince),
            (syncUntil, "plants", syncSince, syncSince)
        ] {
            let cursor = SyncWireCursorDTO(since: start, until: end, updatedAt: time, entityType: entity, id: serverPlantId)
            requests.append((syncSince, syncUntil, cursor, 200))
        }
        let cursor = SyncWireCursorDTO(since: syncSince, until: syncUntil, updatedAt: syncUntil, entityType: "plants", id: serverPlantId)
        requests += [(syncSince, nil, cursor, 200), (nil, syncUntil, cursor, 200)]
        for (since, until, cursor, limit) in requests {
            do {
                _ = try await api.fetchSyncWirePage(session: syncSession, since: since, until: until, cursor: cursor, limit: limit)
                XCTFail("Invalid query sent")
            } catch SyncWireValidationError.invalidRequest {}
        }
        for session in [
            NativeAuthSession(userId: syncOwner, accessToken: " ", expiresAt: .distantFuture),
            NativeAuthSession(userId: syncOwner, accessToken: "expired", expiresAt: .distantPast)
        ] {
            do {
                _ = try await api.fetchSyncWirePage(session: session)
                XCTFail("Invalid session sent")
            } catch SyncWireValidationError.invalidSession {}
        }
        let captured = await transport.capturedRequests()
        XCTAssertTrue(captured.isEmpty)
    }

    func testSyncMalformedEnvelopeAndProjectionsAreRejected() async throws {
        let valid = syncObject()
        for key in ["until", "has_more", "last_cursor", "next_since", "profile", "entitlement", "changes"] {
            var missing = valid
            missing.removeValue(forKey: key)
            try await assertSyncRejected(missing)
            var wrong = valid
            wrong[key] = ["wrong": true]
            try await assertSyncRejected(wrong)
        }
        let profile = try XCTUnwrap(valid["profile"] as? [String: Any])
        let entitlement: [String: Any] = [
            "product_id": "product", "state": "active", "offer_kind": "paid",
            "valid_until": NSNull(), "grace_until": NSNull(), "trial_end_at": NSNull(),
            "auto_renew_enabled": true
        ]
        for (projection, fields) in [("profile", profile), ("entitlement", entitlement), ("change", syncChange())] {
            for key in fields.keys {
                for replacement in [nil, ["unexpected": true]] as [Any?] {
                    if projection == "profile", key == "report_notifications_enabled", replacement == nil { continue }
                    var malformed = fields
                    malformed[key] = key == "data" && replacement != nil ? true : replacement
                    var object = valid
                    if projection == "change" { object["changes"] = [malformed] }
                    else { object[projection] = malformed }
                    try await assertSyncRejected(object)
                }
            }
        }
        for (field, value) in [
            ("preferred_locale", "de" as Any), ("reminder_hour_local", 24),
            ("reminder_hour_local", 1.5), ("report_notifications_enabled", 1),
            ("report_notifications_enabled", NSNull())
        ] {
            var malformed = profile
            malformed[field] = value
            var object = valid
            object["profile"] = malformed
            try await assertSyncRejected(object)
        }
        for (field, value) in [
            ("id", "invalid" as Any), ("entity_type", "rooms"), ("entity_type", "free_care_slots"),
            ("updated_at", "2026-02-30T09:00:00Z"), ("deleted_at", "invalid"),
            ("data", NSNull()), ("data", []), ("data", "scalar")
        ] {
            var change = syncChange()
            change[field] = value
            var object = valid
            object["changes"] = [change]
            try await assertSyncRejected(object)
        }
        for field in ["valid_until", "grace_until", "trial_end_at", "offer_kind"] {
            var malformed = entitlement
            malformed[field] = "invalid"
            var object = valid
            object["entitlement"] = malformed
            try await assertSyncRejected(object)
        }
        var object = valid
        var tombstone = syncChange()
        tombstone["deleted_at"] = syncUntil
        object["changes"] = [tombstone]
        try await assertSyncRejected(object)
    }

    func testSyncPaginationRejectsPartialMismatchedAndCrossWindowPages() async throws {
        var page = syncObject()
        let change = syncChange()
        page["has_more"] = true
        page["next_since"] = NSNull()
        page["last_cursor"] = syncCursorObject(change)
        page["changes"] = [change]
        for key in ["since", "until", "updated_at", "entity_type", "id"] {
            var malformed = syncCursorObject(change)
            malformed.removeValue(forKey: key)
            var object = page
            object["last_cursor"] = malformed
            try await assertSyncRejected(object, since: syncSince)
        }
        for (key, value) in [
            ("since", syncUntil), ("until", syncSince), ("updated_at", syncSince),
            ("entity_type", "care_tasks"), ("id", "33333333-3333-4333-8333-333333333333")
        ] {
            var malformed = syncCursorObject(change)
            malformed[key] = value
            var object = page
            object["last_cursor"] = malformed
            try await assertSyncRejected(object, since: syncSince)
        }
        var empty = page
        empty["changes"] = []
        try await assertSyncRejected(empty, since: syncSince)
        var nextOnIntermediate = page
        nextOnIntermediate["next_since"] = syncUntil
        try await assertSyncRejected(nextOnIntermediate, since: syncSince)
        var final = syncObject()
        final["last_cursor"] = syncCursorObject(change)
        try await assertSyncRejected(final)
        final = syncObject()
        final["next_since"] = NSNull()
        try await assertSyncRejected(final)
        final["next_since"] = syncSince
        try await assertSyncRejected(final)
        final = syncObject()
        final["changes"] = [syncChange(syncSince)]
        try await assertSyncRejected(final, since: syncSince, until: syncUntil)
        final["changes"] = [syncChange("2026-11-03T09:00:01Z")]
        try await assertSyncRejected(final, until: syncUntil)
        final = syncObject()
        try await assertSyncRejected(final, until: "2026-11-03T09:00:01Z")
        final["changes"] = [syncChange("2026-11-03T09:00:00.999998Z"), syncChange()]
        try await assertSyncRejected(final, limit: 1)
    }

    func testSyncNetworkAuthAndUnavailableErrorsPropagate() async throws {
        for (status, code) in [(401, "UNAUTHORIZED"), (403, "FORBIDDEN"), (503, "INTERNAL_ERROR")] {
            let error = """
            {"error":{"code":"\(code)","message":"Server message","retryable":\(status == 503)}}
            """
            let transport = CatalogueTransport([.http(status, error)])
            do {
                _ = try await client(transport).fetchSyncWirePage(session: syncSession)
                XCTFail("HTTP error became a sync success")
            } catch let failure as APIErrorResponse {
                XCTAssertEqual(failure.error.code, code)
                XCTAssertEqual(failure.error.retryable, status == 503)
            }
        }
        let transport = CatalogueTransport([.network, .http(503, "{}"), .http(200, "null"), .http(200, "[]")])
        let api = client(transport)
        do {
            _ = try await api.fetchSyncWirePage(session: syncSession)
            XCTFail("Network failure became success")
        } catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        do {
            _ = try await api.fetchSyncWirePage(session: syncSession)
            XCTFail("Malformed 503 became success")
        } catch let error as URLError { XCTAssertEqual(error.code, .badServerResponse) }
        for _ in 0..<2 {
            do {
                _ = try await api.fetchSyncWirePage(session: syncSession)
                XCTFail("Non-object envelope accepted")
            } catch is DecodingError {}
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 4)
    }
}

/// Deliberately ignores task cancellation until released; no sleeps or blocking waits.
private actor SuspendedCollectionTransport: PlantsAPITransport {
    private let json: String
    private var requests: [URLRequest] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    init(_ json: String) { self.json = json }
    func capturedRequests() -> [URLRequest] { requests }

    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func resume() {
        release?.resume()
        release = nil
    }

    func sendWithoutRedirect(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard requests.count == 1 else { throw URLError(.resourceUnavailable) }
        await withCheckedContinuation { continuation in
            release = continuation
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
        return (Data(json.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension CollectionWireTests {
    private var otherSyncOwner: UUID { UUID(uuidString: "44444444-4444-4444-8444-444444444444")! }

    private func diskURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sync.sqlite")
    }

    private func diskContainer(_ url: URL, allowsSave: Bool = true) throws -> ModelContainer {
        let schema = Schema([
            LocalOutboxRecord.self, GuestDraftCacheRecord.self,
            SyncedEntityRecord.self, SyncCheckpointRecord.self,
            CatalogueCreateConfirmationRecord.self, CatalogueInputCheckpointRecord.self
        ])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, allowsSave: allowsSave)
        ])
    }

    private func requestQuery(_ request: URLRequest) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func paidSyncEntitlement() -> [String: Any] {
        ["product_id": "app.narat.pro", "state": "active", "offer_kind": "paid",
         "valid_until": syncUntil, "grace_until": NSNull(), "trial_end_at": NSNull(),
         "auto_renew_enabled": true]
    }

    /// Seeds through the real bound API/engine, then closes the disk container.
    @MainActor
    private func seedSyncDisk(_ url: URL) async throws -> [OutboxEntrySnapshot] {
        let store = LocalStore(modelContainer: try diskContainer(url))
        var page = syncObject()
        page["until"] = syncSince
        page["next_since"] = syncSince
        page["entitlement"] = paidSyncEntitlement()
        let api = client(CatalogueTransport([.http(200, try syncJSON(page))]))
        await api.bindSyncSession(syncSession)
        _ = try await SyncEngine(store: store, apiClient: api).pullDelta(for: syncOwner)
        for owner in [syncOwner, otherSyncOwner] {
            try await store.applySyncedItems([
                SyncItemDTO(entityType: "plants", id: serverPlantId,
                            updatedAt: SQLTimestamp.date(from: syncSince)!, payloadJSON: #"{"name":"confirmed"}"#)
            ], ownerId: owner)
        }
        let a = try await store.enqueueCommand(
            operationId: operationId, ownerId: syncOwner, plantId: serverPlantId,
            commandName: "care.record", payloadJSON: #"{"action":"water"}"#
        )
        let b = try await store.enqueueCommand(
            ownerId: otherSyncOwner, plantId: serverPlantId, commandName: "care.record", payloadJSON: "{}"
        )
        return [a, b]
    }

    @MainActor
    private func assertSeedUnchanged(
        _ url: URL, outbox: [OutboxEntrySnapshot], extraA: [OutboxEntrySnapshot] = []
    ) async throws {
        // An independent container must see the old checkpoint, entities, rights and queue.
        let store = LocalStore(modelContainer: try diskContainer(url))
        let raw = try await store.currentWatermarkRaw(ownerId: syncOwner)
        let profile = try await store.syncedProfile(ownerId: syncOwner)
        let rights = try await store.syncedEntitlement(ownerId: syncOwner)
        XCTAssertEqual(raw, syncSince)
        XCTAssertEqual(profile?.preferredLocale, "pl")
        XCTAssertEqual(rights?.productId, "app.narat.pro")
        for (index, owner) in [syncOwner, otherSyncOwner].enumerated() {
            let items = try await store.activeSyncedEntities(ownerId: owner, entityType: "plants")
            let pending = try await store.pendingOutboxEntries(for: owner)
            XCTAssertEqual(items.map(\.payloadJSON), [#"{"name":"confirmed"}"#])
            XCTAssertEqual(pending, [outbox[index]] + (index == 0 ? extraA : []))
        }
    }

    @MainActor
    func testSyncWithoutReportSettingPreservesHistoricalClaimOnDisk() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let entity = "notification_claim_summaries"
        var historical = syncObject()
        var claim = syncChange(entity: entity)
        claim["data"] = ["kind": "trial_ending", "state": "cancelled"]
        historical["changes"] = [claim]
        let nextWatermark = "2026-11-03T10:00:00.000001Z"
        var current = syncObject()
        current["until"] = nextWatermark
        current["next_since"] = nextWatermark
        current["profile"] = ["preferred_locale": "en", "reminder_hour_local": 17, "trial_reminder_enabled": true]
        let transport = CatalogueTransport([.http(200, try syncJSON(historical)), .http(200, try syncJSON(current))])
        let api = client(transport)
        await api.bindSyncSession(syncSession)

        let previousClaim: SyncItemDTO
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let engine = SyncEngine(store: store, apiClient: api)
            _ = try await engine.pullDelta(for: syncOwner)
            let previous = try await store.syncedProfile(ownerId: syncOwner)
            XCTAssertEqual(previous?.reportNotificationsEnabled, true)
            let claims = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: entity)
            previousClaim = try XCTUnwrap(claims.first)
            _ = try await engine.pullDelta(for: syncOwner)
        }
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let profile = try await reopened.syncedProfile(ownerId: syncOwner)
        let claims = try await reopened.activeSyncedEntities(ownerId: syncOwner, entityType: entity)
        let watermark = try await reopened.currentWatermarkRaw(ownerId: syncOwner)
        XCTAssertNil(profile?.reportNotificationsEnabled)
        XCTAssertEqual(profile?.trialReminderEnabled, true)
        XCTAssertEqual(profile?.reminderHourLocal, 17)
        XCTAssertEqual(claims.map(\.id), [previousClaim.id])
        XCTAssertEqual(claims.first?.payloadJSON, previousClaim.payloadJSON)
        XCTAssertEqual(watermark, nextWatermark)
    }

    @MainActor
    func testCanonicalEngineTwoPagesExactDiskCheckpointAndNextRequest() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let nextSince = "2026-11-03T11:00:00.999999+02:00"
        let liveId = "33333333-3333-4333-8333-333333333333"
        var live = syncChange("2026-11-03T09:00:00.999998+00:00", id: liveId)
        live["data"] = ["nested": ["array": [true, NSNull(), ["decimal": 1.25, "name": "żółty"]]]]
        var first = syncObject()
        first["has_more"] = true
        first["next_since"] = NSNull()
        first["last_cursor"] = syncCursorObject(live)
        first["changes"] = [live]
        first["entitlement"] = paidSyncEntitlement()
        var tombstone = syncChange()
        tombstone["deleted_at"] = syncUntil
        tombstone["data"] = NSNull()
        var last = syncObject()
        last["changes"] = [tombstone]
        last["entitlement"] = paidSyncEntitlement()
        last["next_since"] = nextSince
        let transport = CatalogueTransport([.http(200, try syncJSON(first)), .http(200, try syncJSON(last))])
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let before = try await store.currentWatermarkRaw(ownerId: syncOwner)
            XCTAssertEqual(before, syncSince)
            let result = try await SyncEngine(store: store, apiClient: api).pullDelta(for: syncOwner, pageSize: 1)
            XCTAssertEqual(result, SQLTimestamp.date(from: syncUntil))
            let saved = try await store.currentWatermarkRaw(ownerId: syncOwner)
            let savedItems = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
            XCTAssertEqual(saved, nextSince)
            XCTAssertEqual(savedItems.map(\.id), [UUID(uuidString: liveId)!])
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try requestQuery(requests[0]), ["since": syncSince, "limit": "1"])
        XCTAssertEqual(try requestQuery(requests[1]), [
            "since": syncSince, "until": syncUntil, "limit": "1",
            "cursor_updated_at": "2026-11-03T09:00:00.999998+00:00",
            "cursor_entity_type": "plants", "cursor_id": liveId
        ])
        do {
            let container = try diskContainer(url)
            let store = LocalStore(modelContainer: container)
            let raw = try await store.currentWatermarkRaw(ownerId: syncOwner)
            let active = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
            let rights = try await store.syncedEntitlement(ownerId: syncOwner)
            XCTAssertEqual(raw, nextSince)
            XCTAssertEqual(active.map(\.id), [UUID(uuidString: liveId)!])
            XCTAssertEqual(rights?.validUntil, syncUntil)
            let records = try ModelContext(container).fetch(FetchDescriptor<SyncedEntityRecord>())
            let deleted = try XCTUnwrap(records.first { $0.ownerId == syncOwner && $0.entityId == serverPlantId })
            XCTAssertNotNil(deleted.deletedAt)
            XCTAssertEqual(deleted.payloadJSON, "null")
            XCTAssertEqual(deleted.updatedAtRaw, syncUntil)
            for (index, owner) in [syncOwner, otherSyncOwner].enumerated() {
                let pending = try await store.pendingOutboxEntries(for: owner)
                XCTAssertEqual(pending, [outbox[index]])
            }
        }
        // Cold-open delta must send the original SQL next_since, including its offset.
        var empty = syncObject()
        let end = "2026-11-03T10:01:00.000001Z"
        empty["until"] = end
        empty["next_since"] = end
        empty["profile"] = ["preferred_locale": "en", "reminder_hour_local": 17,
                            "report_notifications_enabled": false, "trial_reminder_enabled": true]
        let nextTransport = CatalogueTransport([.http(200, try syncJSON(empty))])
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let items = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
            let item = try XCTUnwrap(items.first)
            let data = try JSONDecoder().decode(SyncWireJSON.self, from: Data(item.payloadJSON.utf8))
            XCTAssertEqual(data, .object(["nested": .object([
                "array": .array([.bool(true), .null, .object(["decimal": .number(Decimal(string: "1.25")!), "name": .string("żółty")])])
            ])]))
            let api = client(nextTransport)
            await api.bindSyncSession(syncSession)
            let previousRights = try await store.syncedEntitlement(ownerId: syncOwner)
            let previousProfile = try await store.syncedProfile(ownerId: syncOwner)
            XCTAssertNotNil(previousRights)
            XCTAssertEqual(previousProfile?.preferredLocale, "pl")
            _ = try await SyncEngine(store: store, apiClient: api).pullDelta(for: syncOwner)
            let savedRights = try await store.syncedEntitlement(ownerId: syncOwner)
            let savedProfile = try await store.syncedProfile(ownerId: syncOwner)
            XCTAssertNil(savedRights)
            XCTAssertEqual(savedProfile?.preferredLocale, "en")
            XCTAssertEqual(savedProfile?.reminderHourLocal, 17)
        }
        let nextRequests = await nextTransport.capturedRequests()
        XCTAssertEqual(try requestQuery(XCTUnwrap(nextRequests.first)), ["since": nextSince, "limit": "200"])
        do {
            let container = try diskContainer(url)
            let store = LocalStore(modelContainer: container)
            let profile = try await store.syncedProfile(ownerId: syncOwner)
            let rights = try await store.syncedEntitlement(ownerId: syncOwner)
            XCTAssertEqual(profile?.preferredLocale, "en")
            XCTAssertEqual(profile?.reminderHourLocal, 17)
            XCTAssertEqual(profile?.trialReminderEnabled, true)
            XCTAssertNil(rights)
            let checkpoints = try ModelContext(container).fetch(FetchDescriptor<SyncCheckpointRecord>())
            let checkpoint = try XCTUnwrap(checkpoints.first { $0.ownerId == syncOwner })
            XCTAssertEqual(checkpoint.watermarkRaw, end)
            XCTAssertNil(checkpoint.entitlementState)
            XCTAssertNil(checkpoint.entitlementValidUntil)
            XCTAssertNil(checkpoint.entitlementOfferKind)
        }
        // Successful full refresh replaces only this owner's cache and preserves both queues.
        empty["until"] = "2026-11-03T10:02:00.000001Z"
        empty["next_since"] = "2026-11-03T10:02:00.000001Z"
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let refreshTransport = CatalogueTransport([.http(200, try syncJSON(empty))])
            let api = client(refreshTransport)
            await api.bindSyncSession(syncSession)
            _ = try await SyncEngine(store: store, apiClient: api).performFullRefresh(for: syncOwner)
            let own = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
            let foreign = try await store.activeSyncedEntities(ownerId: otherSyncOwner, entityType: "plants")
            let pending = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertTrue(own.isEmpty)
            XCTAssertEqual(foreign.count, 1)
            XCTAssertEqual(pending, [outbox[0]])
            let refreshRequests = await refreshTransport.capturedRequests()
            XCTAssertEqual(refreshRequests.count, 1)
            XCTAssertEqual(try requestQuery(XCTUnwrap(refreshRequests.first)), ["limit": "200"])
        }
    }

    @MainActor
    func testCanonicalFailedMalformedNonadvancingWindowsAreAtomicOnDisk() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        for mode in 0..<6 {
            let refresh = mode == 5
            let change = syncChange("2026-11-03T09:00:00.999998+00:00")
            var first = syncObject()
            var cursor = syncCursorObject(change)
            if refresh { cursor["since"] = NSNull() }
            first["changes"] = [change]
            first["has_more"] = true
            first["last_cursor"] = cursor
            first["next_since"] = NSNull()
            // If these projections were published early, existing rights would be cleared.
            var second = syncObject()
            let reply: CatalogueTransport.Reply
            switch mode {
            case 0, 5: reply = .network
            case 1:
                second.removeValue(forKey: "profile")
                reply = .http(200, try syncJSON(second))
            case 2: reply = .http(200, try syncJSON(first)) // Repeated tuple cannot progress.
            case 3:
                second["until"] = "2026-11-03T09:01:00Z"
                second["next_since"] = "2026-11-03T09:01:00Z"
                reply = .http(200, try syncJSON(second))
            default:
                second["has_more"] = true // Missing advancing cursor.
                second["next_since"] = NSNull()
                reply = .http(200, try syncJSON(second))
            }
            let transport = CatalogueTransport([.http(200, try syncJSON(first)), reply])
            do {
                let store = LocalStore(modelContainer: try diskContainer(url))
                let api = client(transport)
                await api.bindSyncSession(syncSession)
                let engine = SyncEngine(store: store, apiClient: api)
                do {
                    if refresh { _ = try await engine.performFullRefresh(for: syncOwner) }
                    else { _ = try await engine.pullDelta(for: syncOwner, pageSize: 1) }
                    XCTFail("Invalid/failed window must not commit, mode \(mode)")
                } catch is URLError {
                    XCTAssertTrue(mode == 0 || mode == 5)
                } catch is DecodingError {
                    XCTAssertEqual(mode, 1)
                } catch SyncWireValidationError.invalidPage {
                    XCTAssertTrue((2...4).contains(mode))
                }
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 2)
            try await assertSeedUnchanged(url, outbox: outbox)
        }
    }

    @MainActor
    func testCanonicalSaveFailureRollsBackWindowAndProjection() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        do {
            let store = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
            // Prime every view before publishing; neither a failed write nor a
            // cached read may replace the last committed snapshot.
            let oldDate = try await store.currentWatermark(ownerId: syncOwner)
            let oldProfile = try await store.syncedProfile(ownerId: syncOwner)
            let oldRights = try await store.syncedEntitlement(ownerId: syncOwner)
            var page = syncObject()
            page["changes"] = [syncChange()]
            page["profile"] = ["preferred_locale": "en", "reminder_hour_local": 17,
                               "report_notifications_enabled": false, "trial_reminder_enabled": true]
            let json = try syncJSON(page)
            let transport = CatalogueTransport([.http(200, json), .http(200, json), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let engine = SyncEngine(store: store, apiClient: api)
            for refresh in [true, false] {
                let before = try await store.currentWatermarkRaw(ownerId: syncOwner)
                let beforeItems = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
                XCTAssertEqual(before, syncSince)
                XCTAssertEqual(beforeItems.map(\.payloadJSON), [#"{"name":"confirmed"}"#])
                do {
                    if refresh { _ = try await engine.performFullRefresh(for: syncOwner) }
                    else { _ = try await engine.pullDelta(for: syncOwner) }
                    XCTFail("Read-only disk save must fail")
                } catch {
                    // Require the actual SQLite read-only save error.
                    let failure = error as NSError
                    XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                    XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
                }
                let raw = try await store.currentWatermarkRaw(ownerId: syncOwner)
                let date = try await store.currentWatermark(ownerId: syncOwner)
                let items = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
                let profile = try await store.syncedProfile(ownerId: syncOwner)
                let rights = try await store.syncedEntitlement(ownerId: syncOwner)
                XCTAssertEqual(raw, syncSince)
                XCTAssertEqual(date, oldDate)
                XCTAssertEqual(items, beforeItems)
                XCTAssertEqual(profile, oldProfile)
                XCTAssertEqual(rights, oldRights)
                XCTAssertEqual(rights?.state, "active")
                XCTAssertEqual(profile?.preferredLocale, "pl")
                for (index, owner) in [syncOwner, otherSyncOwner].enumerated() {
                    let pending = try await store.pendingOutboxEntries(for: owner)
                    let confirmed = try await store.activeSyncedEntities(ownerId: owner, entityType: "plants")
                    XCTAssertEqual(pending, [outbox[index]])
                    XCTAssertEqual(confirmed.map(\.payloadJSON), [#"{"name":"confirmed"}"#])
                }
                try await assertSeedUnchanged(url, outbox: outbox)
            }
            // A subsequent delta on this same store must request the old exact
            // since, even after both failed replacement and failed entity update.
            do {
                _ = try await engine.pullDelta(for: syncOwner)
                XCTFail("Network failure must propagate")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .networkConnectionLost)
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(try requestQuery(XCTUnwrap(requests.first)), ["limit": "200"])
            for request in requests.dropFirst() {
                XCTAssertEqual(try requestQuery(request), ["since": syncSince, "limit": "200"])
            }
        }
        try await assertSeedUnchanged(url, outbox: outbox)
    }

    @MainActor
    func testLegacyDiskDateAndPageRemainReadableAndCanonicalNeverDowngrades() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let oldDate = SQLTimestamp.date(from: "2026-11-03T08:00:00Z")!
        let oldItem = SyncItemDTO(entityType: "room", id: serverPlantId, updatedAt: oldDate,
                                  payloadJSON: #"{"name":"historical","unknown":{"kept":true}}"#)
        let legacy = SyncPageDTO(ownerId: syncOwner, items: [oldItem], hasMore: false,
                                 nextCursor: nil, serverWatermark: oldDate, limit: 200)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyJSON = String(decoding: try encoder.encode(legacy), as: UTF8.self)
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let api = client(CatalogueTransport([.http(200, legacyJSON)]))
            _ = try await SyncEngine(store: store, apiClient: api).pullDelta(for: syncOwner)
        }
        do {
            let container = try diskContainer(url)
            let store = LocalStore(modelContainer: container)
            let raw = try await store.currentWatermarkRaw(ownerId: syncOwner)
            XCTAssertEqual(raw, "2026-11-03T08:00:00.000Z")
            let checkpoint = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<SyncCheckpointRecord>()).first)
            XCTAssertNil(checkpoint.watermarkRaw) // Reading has not migrated/reformatted disk data.
            let items = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "room")
            XCTAssertEqual(items, [oldItem])
            let foreign = SyncPageDTO(ownerId: otherSyncOwner, items: [], hasMore: false,
                                      nextCursor: nil, serverWatermark: oldDate.addingTimeInterval(60), limit: 200)
            let transport = CatalogueTransport([
                .http(200, String(decoding: try encoder.encode(foreign), as: UTF8.self)),
                .http(200, legacyJSON)
            ])
            let api = client(transport)
            let engine = SyncEngine(store: store, apiClient: api)
            do {
                _ = try await engine.pullDelta(for: syncOwner)
                XCTFail("Legacy foreign owner must be rejected")
            } catch SyncWireValidationError.invalidSession {}
            await api.bindSyncSession(syncSession)
            do {
                _ = try await engine.pullDelta(for: syncOwner)
                XCTFail("Canonical client must not downgrade to legacy JSON")
            } catch is DecodingError {}
            let retained = try await store.currentWatermark(ownerId: syncOwner)
            XCTAssertEqual(retained, oldDate)
            await api.bindSyncSession(nil)
            do {
                _ = try await engine.pullDelta(for: syncOwner)
                XCTFail("Sign-out must not enable legacy mode")
            } catch SyncWireValidationError.invalidSession {}
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 2)
        }
        let transport = CatalogueTransport([.http(200, try syncJSON(syncObject()))])
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            _ = try await SyncEngine(store: store, apiClient: api).pullDelta(for: syncOwner)
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(try requestQuery(XCTUnwrap(requests.first)), [
            "since": "2026-11-03T08:00:00.000Z", "limit": "200"
        ])
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let history = try await reopened.activeSyncedEntities(ownerId: syncOwner, entityType: "room")
        XCTAssertEqual(history, [oldItem])
    }

    @MainActor
    func testOwnerSwitchABAAndCancellationDuringPullAndFlushRetainDiskState() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let extra: OutboxEntrySnapshot
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            extra = try await store.enqueueCommand(
                ownerId: syncOwner, plantId: UUID(), commandName: "care.record", payloadJSON: "{}"
            )
        }
        for flush in [false, true] {
            for mode in 0..<3 {
                let json = flush
                    ? #"{"status":"committed","operation_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","replayed":false}"#
                    : try syncJSON(syncObject())
                let transport = SuspendedCollectionTransport(json)
                let api = PlantsAPIClient(transport: transport)
                await api.bindSyncSession(syncSession)
                do {
                    let store = LocalStore(modelContainer: try diskContainer(url))
                    let engine = SyncEngine(store: store, apiClient: api)
                    let owner = syncOwner
                    let operation = Task {
                        if flush { _ = try await engine.flushOutbox(for: owner) }
                        else { _ = try await engine.pullDelta(for: owner) }
                    }
                    await transport.waitForRequest()
                    if mode == 2 {
                        operation.cancel()
                    } else {
                        await api.bindSyncSession(NativeAuthSession(
                            userId: otherSyncOwner, accessToken: "owner-b-token", expiresAt: .distantFuture
                        ))
                        do {
                            _ = try await engine.flushOutbox(for: syncOwner)
                            XCTFail("Owner A queue must never be sent with owner B token")
                        } catch SyncWireValidationError.invalidSession {}
                        if mode == 1 { await api.bindSyncSession(syncSession) }
                    }
                    await transport.resume()
                    do {
                        try await operation.value
                        XCTFail("Stale/cancelled operation must fail")
                    } catch is CancellationError {
                        XCTAssertEqual(mode, 2)
                    } catch SyncWireValidationError.invalidSession {
                        XCTAssertNotEqual(mode, 2)
                    }
                    let requests = await transport.capturedRequests()
                    XCTAssertEqual(requests.count, 1)
                    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sync-session-token")
                }
                try await assertSeedUnchanged(url, outbox: outbox, extraA: [extra])
            }
        }
    }

    @MainActor
    func testStorePublicationRevalidatesSessionGenerationAndCanonicalCreateDrainsExistingOutbox() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let api = client(CatalogueTransport([]))
            await api.bindSyncSession(syncSession)
            let stale = try await api.captureSyncContext(ownerId: syncOwner)
            await api.bindSyncSession(NativeAuthSession(
                userId: otherSyncOwner, accessToken: "b-token", expiresAt: .distantFuture
            ))
            await api.bindSyncSession(syncSession)
            do {
                try await store.publishSyncWindow(
                    items: [], ownerId: syncOwner, watermark: SQLTimestamp.date(from: syncUntil),
                    fullRefresh: true, context: stale, authority: api.syncAuthority
                )
                XCTFail("Store must reject a stale generation even when owner A is active again")
            } catch SyncWireValidationError.invalidSession {}
            do {
                try await store.finishOutboxEntry(
                    operationId: operationId, context: stale, authority: api.syncAuthority
                )
                XCTFail("Store must not acknowledge a stale operation")
            } catch SyncWireValidationError.invalidSession {}
        }
        try await assertSeedUnchanged(url, outbox: outbox)
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            // Existing legacy entry remains meaningful; canonical create consumes the
            // accepted SQL receipt on the same drain, without a second queue.
            let create = try await store.enqueueCommand(
                ownerId: syncOwner, plantId: nil, commandName: "plant.create", payloadJSON: envelope().payloadJSON
            )
            let transport = CatalogueTransport([
                .http(200, #"{"status":"committed","operation_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","replayed":false}"#),
                .http(200, receiptJSON())
            ])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let count = try await SyncEngine(store: store, apiClient: api).flushOutbox(for: syncOwner)
            XCTAssertEqual(count, 2)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Operation-Id"), create.operationId.uuidString.lowercased())
        }
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let pendingA = try await reopened.pendingOutboxEntries(for: syncOwner)
        let pendingB = try await reopened.pendingOutboxEntries(for: otherSyncOwner)
        XCTAssertTrue(pendingA.isEmpty)
        XCTAssertEqual(pendingB, [outbox[1]])
    }
}

extension CollectionWireTests {
    private func createCommand(operationId: UUID = UUID()) -> CommandEnvelopeDTO {
        CommandEnvelopeDTO(
            operationId: operationId, commandName: "plant.create",
            payloadJSON: #"{ "creation_source":"catalogue", "plant_id":"fixture_collection_cap", "display_name":"żółty", "photo_id":null }"#
        )
    }

    private func decodedCreateReceipt(_ changes: [String: Any] = [:]) throws -> PlantCreateReceiptDTO {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receiptJSON().utf8)) as? [String: Any])
        object.merge(changes) { _, replacement in replacement }
        return try JSONDecoder().decode(
            PlantCreateReceiptDTO.self, from: JSONSerialization.data(withJSONObject: object)
        )
    }

    @MainActor
    private func queueCreate(
        _ command: CommandEnvelopeDTO, ownerId: UUID, in store: LocalStore
    ) async throws -> OutboxEntrySnapshot {
        try await store.enqueueCommand(
            operationId: command.operationId, ownerId: ownerId, plantId: command.plantId,
            commandName: command.commandName, payloadJSON: command.payloadJSON
        )
    }

    @MainActor
    private func assertCreateStillPending(
        _ url: URL, store: LocalStore, outbox: [OutboxEntrySnapshot], create: OutboxEntrySnapshot
    ) async throws {
        for inspected in [store, LocalStore(modelContainer: try diskContainer(url))] {
            for (index, owner) in [syncOwner, otherSyncOwner].enumerated() {
                let pending = try await inspected.pendingOutboxEntries(for: owner)
                let confirmation = try await inspected.catalogueCreateConfirmation(
                    ownerId: owner, operationId: create.operationId
                )
                XCTAssertEqual(pending, [outbox[index]] + (index == 0 ? [create] : []))
                XCTAssertNil(confirmation)
            }
        }
        try await assertSeedUnchanged(url, outbox: outbox, extraA: [create])
    }

    @MainActor
    func testCreateAcknowledgementCommitsReceiptAndOnlyOriginalCommandAcrossReopen() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let command = createCommand()
        let receipt = try decodedCreateReceipt()
        let api = client(CatalogueTransport([]))
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let create = try await queueCreate(command, ownerId: syncOwner, in: store)
        let oldProfile = try await store.syncedProfile(ownerId: syncOwner)
        let oldRights = try await store.syncedEntitlement(ownerId: syncOwner)
        let oldItems = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
        try await assertCreateStillPending(url, store: store, outbox: outbox, create: create)

        try await store.acknowledgeCatalogueCreate(
            command, receipt: receipt, context: lease, authority: api.syncAuthority
        )
        for inspected in [store, LocalStore(modelContainer: try diskContainer(url))] {
            let value = try await inspected.catalogueCreateConfirmation(
                ownerId: syncOwner, operationId: command.operationId
            )
            let saved = try XCTUnwrap(value)
            XCTAssertEqual(saved.ownerId, syncOwner)
            XCTAssertEqual(saved.operationId, command.operationId)
            XCTAssertTrue(saved.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8))
            XCTAssertEqual(saved.receipt, receipt)
            XCTAssertEqual(saved.receipt.plantId, serverPlantId)
            XCTAssertEqual(saved.receipt.careRevision, 1)
            XCTAssertEqual(saved.receipt.contextState, "current")
            XCTAssertEqual(saved.receipt.nextAvailableStep, "enable_basic_care")
            XCTAssertEqual(saved.receipt.paidAction, "generate_full_routine_plan")
            XCTAssertEqual(saved.receipt.planAvailability, "available")
            XCTAssertEqual(saved.receipt.watermarkRaw, timestamp)
            // Exact replay succeeds even after the queued command has disappeared.
            try await inspected.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: lease, authority: api.syncAuthority
            )
            let afterReplay = try await inspected.catalogueCreateConfirmation(
                ownerId: syncOwner, operationId: command.operationId
            )
            let pending = try await inspected.pendingOutboxEntries(for: syncOwner)
            let raw = try await inspected.currentWatermarkRaw(ownerId: syncOwner)
            let date = try await inspected.currentWatermark(ownerId: syncOwner)
            let profile = try await inspected.syncedProfile(ownerId: syncOwner)
            let rights = try await inspected.syncedEntitlement(ownerId: syncOwner)
            let items = try await inspected.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
            XCTAssertEqual(afterReplay, saved)
            XCTAssertEqual(pending, [outbox[0]])
            XCTAssertEqual(raw, syncSince)
            XCTAssertEqual(date, SQLTimestamp.date(from: syncSince))
            XCTAssertEqual(profile, oldProfile)
            XCTAssertEqual(rights, oldRights)
            XCTAssertEqual(items, oldItems)
        }
        try await assertSeedUnchanged(url, outbox: outbox)
    }

    @MainActor
    func testCreateAcknowledgementRejectsQueueMismatchAndEveryReceiptConflict() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let command = createCommand()
        let create = try await queueCreate(command, ownerId: syncOwner, in: store)
        let wrongTarget = try await store.enqueueCommand(
            ownerId: syncOwner, plantId: serverPlantId, commandName: "plant.create",
            payloadJSON: command.payloadJSON
        )
        let receipt = try decodedCreateReceipt()
        let api = client(CatalogueTransport([]))
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let invalid: [(CommandEnvelopeDTO, CatalogueCreateAcknowledgementError)] = [
            (CommandEnvelopeDTO(operationId: command.operationId, commandName: "care.record",
                                payloadJSON: command.payloadJSON), .invalidCommand),
            (CommandEnvelopeDTO(operationId: command.operationId, commandName: "plant.create",
                                plantId: serverPlantId, payloadJSON: command.payloadJSON), .invalidCommand),
            (CommandEnvelopeDTO(operationId: command.operationId, commandName: "plant.create",
                                payloadJSON: command.payloadJSON + " "), .queuedCommandMismatch),
            (createCommand(operationId: operationId), .queuedCommandMismatch),
            (createCommand(operationId: wrongTarget.operationId), .queuedCommandMismatch),
            (createCommand(), .missingQueuedOperation)
        ]
        for (attempt, expected) in invalid {
            do {
                try await store.acknowledgeCatalogueCreate(
                    attempt, receipt: receipt, context: lease, authority: api.syncAuthority
                )
                XCTFail("A different or missing queued command must not be acknowledged")
            } catch let error as CatalogueCreateAcknowledgementError {
                XCTAssertEqual(error, expected)
            }
            let confirmation = try await store.catalogueCreateConfirmation(
                ownerId: syncOwner, operationId: attempt.operationId
            )
            XCTAssertNil(confirmation)
            let pending = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(pending, [outbox[0], create, wrongTarget])
        }
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receipt, context: lease, authority: api.syncAuthority
        )
        let original = try await store.catalogueCreateConfirmation(
            ownerId: syncOwner, operationId: command.operationId
        )
        XCTAssertNotNil(original)
        // Swift String equality normalizes Unicode; association metadata must compare bytes.
        let decomposed = command.payloadJSON.replacingOccurrences(of: "ż", with: "z\u{307}")
        XCTAssertEqual(decomposed, command.payloadJSON)
        XCTAssertFalse(decomposed.utf8.elementsEqual(command.payloadJSON.utf8))
        for payload in [command.payloadJSON + " ", decomposed] {
            do {
                try await store.acknowledgeCatalogueCreate(
                    CommandEnvelopeDTO(operationId: command.operationId, commandName: "plant.create",
                                       payloadJSON: payload),
                    receipt: receipt, context: lease, authority: api.syncAuthority
                )
                XCTFail("Changed original payload must conflict after removal")
            } catch CatalogueCreateAcknowledgementError.confirmationConflict {}
        }
        let changes: [[String: Any]] = [
            ["plant_id": otherSyncOwner.uuidString], ["care_revision": 2],
            ["context_state": "stale"], ["next_available_step": "review_conditions"],
            ["paid_action": NSNull()], ["plan_availability": "unavailable"],
            // Same instant, different exact SQL spelling is still a different receipt.
            ["watermark": "2026-11-03T11:00:00.999999+02:00"]
        ]
        for change in changes {
            do {
                try await store.acknowledgeCatalogueCreate(
                    command, receipt: decodedCreateReceipt(change), context: lease, authority: api.syncAuthority
                )
                XCTFail("A different server receipt must not overwrite confirmation")
            } catch CatalogueCreateAcknowledgementError.confirmationConflict {}
        }
        for inspected in [store, LocalStore(modelContainer: try diskContainer(url))] {
            let saved = try await inspected.catalogueCreateConfirmation(
                ownerId: syncOwner, operationId: command.operationId
            )
            let pending = try await inspected.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(saved, original)
            XCTAssertEqual(pending, [outbox[0], wrongTarget])
        }
        try await assertSeedUnchanged(url, outbox: outbox, extraA: [wrongTarget])
    }

    @MainActor
    func testCreateConfirmationOwnerNamespacesPermitSameOperationWithoutCrossAcknowledgement() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let command = createCommand()
        let create = try await queueCreate(command, ownerId: syncOwner, in: store)
        let receiptA = try decodedCreateReceipt()
        let api = client(CatalogueTransport([]))
        let sessionB = NativeAuthSession(
            userId: otherSyncOwner, accessToken: "owner-b-token", expiresAt: .distantFuture
        )
        await api.bindSyncSession(sessionB)
        let leaseB = try await api.captureSyncContext(ownerId: otherSyncOwner)
        do {
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receiptA, context: leaseB, authority: api.syncAuthority
            )
            XCTFail("B must not acknowledge A's queue")
        } catch CatalogueCreateAcknowledgementError.missingQueuedOperation {}
        try await assertCreateStillPending(url, store: store, outbox: outbox, create: create)

        await api.bindSyncSession(syncSession)
        let leaseA = try await api.captureSyncContext(ownerId: syncOwner)
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receiptA, context: leaseA, authority: api.syncAuthority
        )
        await api.bindSyncSession(sessionB)
        let currentB = try await api.captureSyncContext(ownerId: otherSyncOwner)
        let hidden = try await store.catalogueCreateConfirmation(
            ownerId: otherSyncOwner, operationId: command.operationId
        )
        XCTAssertNil(hidden)
        do {
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receiptA, context: currentB, authority: api.syncAuthority
            )
            XCTFail("A's receipt cannot prove a missing B operation")
        } catch CatalogueCreateAcknowledgementError.missingQueuedOperation {}
        // Keep the historical global outbox uniqueness, then reuse its freed UUID for B.
        let queuedB = try await queueCreate(command, ownerId: otherSyncOwner, in: store)
        XCTAssertEqual(queuedB.ownerId, otherSyncOwner)
        let replayAPI = client(CatalogueTransport([]))
        await replayAPI.bindSyncSession(syncSession)
        let replayLease = try await replayAPI.captureSyncContext(ownerId: syncOwner)
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receiptA, context: replayLease, authority: replayAPI.syncAuthority
        )
        let stillPendingB = try await store.pendingOutboxEntries(for: otherSyncOwner)
        let stillHiddenB = try await store.catalogueCreateConfirmation(
            ownerId: otherSyncOwner, operationId: command.operationId
        )
        XCTAssertEqual(stillPendingB, [outbox[1], queuedB])
        XCTAssertNil(stillHiddenB)
        let receiptB = try decodedCreateReceipt([
            "plant_id": otherSyncOwner.uuidString, "paid_action": NSNull(),
            "context_state": "needs_review", "plan_availability": "unavailable"
        ])
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receiptB, context: currentB, authority: api.syncAuthority
        )
        for inspected in [store, LocalStore(modelContainer: try diskContainer(url))] {
            for (owner, expected) in [(syncOwner, receiptA), (otherSyncOwner, receiptB)] {
                let value = try await inspected.catalogueCreateConfirmation(
                    ownerId: owner, operationId: command.operationId
                )
                let saved = try XCTUnwrap(value)
                XCTAssertEqual(saved.ownerId, owner)
                XCTAssertEqual(saved.operationId, command.operationId)
                XCTAssertEqual(saved.receipt, expected)
                XCTAssertTrue(saved.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8))
            }
        }
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receiptB, context: currentB, authority: api.syncAuthority
        )
        do {
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receiptA, context: currentB, authority: api.syncAuthority
            )
            XCTFail("B replay cannot replace its receipt with A's receipt")
        } catch CatalogueCreateAcknowledgementError.confirmationConflict {}
        await api.bindSyncSession(syncSession)
        let currentA = try await api.captureSyncContext(ownerId: syncOwner)
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receiptA, context: currentA, authority: api.syncAuthority
        )
        try await assertSeedUnchanged(url, outbox: outbox)
    }

    @MainActor
    func testCreateAcknowledgementRejectsStaleABALeaseAnonymousContextAndCancellation() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let command = createCommand()
        let create = try await queueCreate(command, ownerId: syncOwner, in: store)
        let receipt = try decodedCreateReceipt()
        let api = client(CatalogueTransport([]))
        await api.bindSyncSession(syncSession)
        let stale = try await api.captureSyncContext(ownerId: syncOwner)
        await api.bindSyncSession(NativeAuthSession(
            userId: otherSyncOwner, accessToken: "owner-b-token", expiresAt: .distantFuture
        ))
        await api.bindSyncSession(syncSession)
        do {
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: stale, authority: api.syncAuthority
            )
            XCTFail("Returning to A must not revive a captured lease")
        } catch SyncWireValidationError.invalidSession {}
        try await assertCreateStillPending(url, store: store, outbox: outbox, create: create)

        let anonymousAPI = client(CatalogueTransport([]))
        let anonymous = try await anonymousAPI.captureSyncContext(ownerId: syncOwner)
        do {
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: anonymous, authority: anonymousAPI.syncAuthority
            )
            XCTFail("Legacy anonymous sync context must not authorize create confirmation")
        } catch SyncWireValidationError.invalidSession {}
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        // Inherits MainActor: cancel before yielding so the store receives a cancelled task.
        let cancelled = Task {
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: lease, authority: api.syncAuthority
            )
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("A cancelled acknowledgement must not publish")
        } catch is CancellationError {}
        try await assertCreateStillPending(url, store: store, outbox: outbox, create: create)
        // The unchanged original operation remains retryable with a current lease.
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receipt, context: lease, authority: api.syncAuthority
        )
        try await assertSeedUnchanged(url, outbox: outbox)
    }

    @MainActor
    func testCreateAcknowledgementReadOnlySQLiteSaveRetainsQueueAndReceiptThenRetries() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let command = createCommand()
        let receipt = try decodedCreateReceipt(["paid_action": NSNull()])
        let create: OutboxEntrySnapshot
        do {
            let writable = LocalStore(modelContainer: try diskContainer(url))
            create = try await queueCreate(command, ownerId: syncOwner, in: writable)
        }
        let api = client(CatalogueTransport([]))
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        do {
            let store = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
            try await assertCreateStillPending(url, store: store, outbox: outbox, create: create)
            for _ in 0..<2 {
                do {
                    try await store.acknowledgeCatalogueCreate(
                        command, receipt: receipt, context: lease, authority: api.syncAuthority
                    )
                    XCTFail("Read-only SQLite must reject the atomic save")
                } catch {
                    let failure = error as NSError
                    XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                    XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
                }
                // Check this actor and a separate disk container after each actual failed save.
                try await assertCreateStillPending(url, store: store, outbox: outbox, create: create)
            }
        }
        do {
            let retry = LocalStore(modelContainer: try diskContainer(url))
            try await retry.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: lease, authority: api.syncAuthority
            )
            try await retry.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: lease, authority: api.syncAuthority
            )
            let saved = try await retry.catalogueCreateConfirmation(
                ownerId: syncOwner, operationId: command.operationId
            )
            XCTAssertEqual(saved?.receipt, receipt)
        }
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let saved = try await reopened.catalogueCreateConfirmation(
            ownerId: syncOwner, operationId: command.operationId
        )
        XCTAssertEqual(saved?.receipt, receipt)
        XCTAssertNil(saved?.receipt.paidAction)
        XCTAssertEqual(saved?.receipt.watermarkRaw, timestamp)
        XCTAssertTrue(saved?.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8) == true)
        try await assertSeedUnchanged(url, outbox: outbox)
    }

    @MainActor
    func testCreateConfirmationSchemaPreservesHistoricalDiskQueueAndCache() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let oldDate = SQLTimestamp.date(from: "2026-11-03T08:00:00Z")!
        let historical = SyncItemDTO(
            entityType: "room", id: serverPlantId, updatedAt: oldDate,
            payloadJSON: #"{"name":"historical","unknown":{"kept":true}}"#
        )
        let queued: OutboxEntrySnapshot
        do {
            // The pre-confirmation production schema, on a real SQLite file.
            let schema = Schema([
                LocalOutboxRecord.self, GuestDraftCacheRecord.self,
                SyncedEntityRecord.self, SyncCheckpointRecord.self
            ])
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url)
            ])
            let oldStore = LocalStore(modelContainer: container)
            queued = try await queueCreate(command, ownerId: syncOwner, in: oldStore)
            try await oldStore.applySyncedItems([historical], ownerId: syncOwner)
            try await oldStore.updateWatermark(ownerId: syncOwner, watermark: oldDate)
        }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let pending = try await store.pendingOutboxEntries(for: syncOwner)
        let before = try await store.catalogueCreateConfirmation(
            ownerId: syncOwner, operationId: command.operationId
        )
        XCTAssertEqual(pending, [queued])
        XCTAssertNil(before)
        let api = client(CatalogueTransport([]))
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let receipt = try decodedCreateReceipt()
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receipt, context: lease, authority: api.syncAuthority
        )
        let container = try diskContainer(url)
        let reopened = LocalStore(modelContainer: container)
        let retained = try await reopened.activeSyncedEntities(ownerId: syncOwner, entityType: "room")
        let date = try await reopened.currentWatermark(ownerId: syncOwner)
        let raw = try await reopened.currentWatermarkRaw(ownerId: syncOwner)
        let after = try await reopened.pendingOutboxEntries(for: syncOwner)
        let saved = try await reopened.catalogueCreateConfirmation(
            ownerId: syncOwner, operationId: command.operationId
        )
        let checkpoint = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<SyncCheckpointRecord>()).first)
        XCTAssertEqual(retained, [historical])
        XCTAssertEqual(date, oldDate)
        XCTAssertEqual(raw, "2026-11-03T08:00:00.000Z")
        XCTAssertNil(checkpoint.watermarkRaw)
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(saved?.receipt, receipt)
        XCTAssertTrue(saved?.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8) == true)
    }
}

/// A fixture ledger commits before optionally losing its response. No live SQL/server.
private actor CommittingCatalogueTransport: PlantsAPITransport {
    private let receiptJSON: String
    private var loseResponse: Bool
    private var bodies: [UUID: Data] = [:]
    private var requests: [URLRequest] = []

    init(_ receiptJSON: String, loseResponse: Bool = false) {
        self.receiptJSON = receiptJSON
        self.loseResponse = loseResponse
    }

    func capturedRequests() -> [URLRequest] { requests }
    func committedCount() -> Int { bodies.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let body = request.httpBody else { throw URLError(.badServerResponse) }
        let command = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: body)
        guard request.httpMethod == "POST", command.commandName == "plant.create",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer sync-session-token",
              request.value(forHTTPHeaderField: "X-Operation-Id") == command.operationId.uuidString.lowercased()
        else { throw URLError(.badServerResponse) }
        if let prior = bodies[command.operationId] {
            guard prior == body else { throw URLError(.badServerResponse) }
        } else {
            bodies[command.operationId] = body
        }
        if loseResponse {
            loseResponse = false
            throw URLError(.networkConnectionLost)
        }
        return (Data(receiptJSON.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension CollectionWireTests {
    /// Retain the seeded checkpoint/cache and B queue; A starts with only this create.
    @MainActor
    private func seedEngineCreate(
        _ url: URL, command: CommandEnvelopeDTO
    ) async throws -> (create: OutboxEntrySnapshot, other: OutboxEntrySnapshot) {
        let seeded = try await seedSyncDisk(url)
        let store = LocalStore(modelContainer: try diskContainer(url))
        try await store.markOutboxCommitted(operationId: seeded[0].operationId)
        let create = try await queueCreate(command, ownerId: syncOwner, in: store)
        return (create, seeded[1])
    }

    @MainActor
    private func assertEngineCreateState(
        _ url: URL, store: LocalStore, command: CommandEnvelopeDTO,
        pending: [OutboxEntrySnapshot], other: OutboxEntrySnapshot,
        receipt: PlantCreateReceiptDTO? = nil
    ) async throws {
        let container = try diskContainer(url)
        let expectedProfile = try JSONDecoder().decode(
            SyncWireProfileDTO.self,
            from: JSONSerialization.data(withJSONObject: syncObject()["profile"]!)
        )
        let expectedRights = try JSONDecoder().decode(
            SyncWireEntitlementDTO.self,
            from: JSONSerialization.data(withJSONObject: paidSyncEntitlement())
        )
        for inspected in [store, LocalStore(modelContainer: container)] {
            let pendingA = try await inspected.pendingOutboxEntries(for: syncOwner)
            let pendingB = try await inspected.pendingOutboxEntries(for: otherSyncOwner)
            let confirmation = try await inspected.catalogueCreateConfirmation(
                ownerId: syncOwner, operationId: command.operationId
            )
            let hidden = try await inspected.catalogueCreateConfirmation(
                ownerId: otherSyncOwner, operationId: command.operationId
            )
            XCTAssertEqual(pendingA, pending)
            XCTAssertEqual(pendingB, [other])
            XCTAssertNil(hidden)
            XCTAssertEqual(confirmation?.receipt, receipt)
            if receipt != nil {
                XCTAssertEqual(confirmation?.ownerId, syncOwner)
                XCTAssertEqual(confirmation?.operationId, command.operationId)
                XCTAssertTrue(confirmation?.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8) == true)
            } else {
                XCTAssertNil(confirmation)
            }
            let raw = try await inspected.currentWatermarkRaw(ownerId: syncOwner)
            let date = try await inspected.currentWatermark(ownerId: syncOwner)
            let profile = try await inspected.syncedProfile(ownerId: syncOwner)
            let rights = try await inspected.syncedEntitlement(ownerId: syncOwner)
            XCTAssertEqual(raw, syncSince)
            XCTAssertEqual(date, SQLTimestamp.date(from: syncSince))
            XCTAssertEqual(profile, expectedProfile)
            XCTAssertEqual(rights, expectedRights)
            for owner in [syncOwner, otherSyncOwner] {
                let cached = try await inspected.activeSyncedEntities(ownerId: owner, entityType: "plants")
                XCTAssertEqual(cached, [
                    SyncItemDTO(entityType: "plants", id: serverPlantId,
                                updatedAt: SQLTimestamp.date(from: syncSince)!,
                                payloadJSON: #"{"name":"confirmed"}"#)
                ])
            }
        }
        let confirmations = try ModelContext(container).fetch(FetchDescriptor<CatalogueCreateConfirmationRecord>())
        XCTAssertEqual(confirmations.count, receipt == nil ? 0 : 1)
    }

    private func assertCreateRequests(
        _ requests: [URLRequest], command: CommandEnvelopeDTO, count: Int
    ) throws {
        XCTAssertEqual(requests.count, count)
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sync-session-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), command.operationId.uuidString.lowercased())
            let body = try XCTUnwrap(request.httpBody)
            let sent = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: body)
            XCTAssertEqual(sent, command)
            XCTAssertTrue(sent.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8))
            XCTAssertEqual(body, requests.first?.httpBody)
        }
    }

    @MainActor
    func testEngineCreatePersistsAuthoritativeReceiptAndOriginalPayloadOnDisk() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let transport = CatalogueTransport([.http(200, receiptJSON())])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let store = LocalStore(modelContainer: try diskContainer(url))
        // Prime committed reads before the isolated ACK replaces the queue.
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [seeded.create], other: seeded.other
        )
        let engine = SyncEngine(store: store, apiClient: api)
        let committed = try await engine.flushOutbox(for: syncOwner)
        let next = try await engine.flushOutbox(for: syncOwner)
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(next, 0)
        let receipt = try decodedCreateReceipt()
        XCTAssertEqual(receipt.watermarkRaw, timestamp)
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [], other: seeded.other, receipt: receipt
        )
        let requests = await transport.capturedRequests()
        try assertCreateRequests(requests, command: command, count: 1)
    }

    @MainActor
    func testEngineCreateLostCommittedResponseReopensAndRetriesSameServerOperation() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let transport = CommittingCatalogueTransport(receiptJSON(), loseResponse: true)
        do {
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let count = try await SyncEngine(store: store, apiClient: api).flushOutbox(for: syncOwner)
            XCTAssertEqual(count, 0)
            let pending = try await store.pendingOutboxEntries(for: syncOwner)
            let failed = try XCTUnwrap(pending.first)
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(failed.operationId, command.operationId)
            XCTAssertTrue(failed.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8))
            XCTAssertEqual(failed.sequenceNumber, seeded.create.sequenceNumber)
            XCTAssertEqual(failed.createdAt, seeded.create.createdAt)
            XCTAssertEqual(failed.retryCount, 1)
            XCTAssertNotNil(failed.lastError)
            try await assertEngineCreateState(
                url, store: store, command: command, pending: [failed], other: seeded.other
            )
        }
        let serverCommitsBeforeRetry = await transport.committedCount()
        XCTAssertEqual(serverCommitsBeforeRetry, 1)
        // Recreate API, engine, actor and disk container after the lost response.
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let engine = SyncEngine(store: store, apiClient: api)
        let count = try await engine.flushOutbox(for: syncOwner)
        let next = try await engine.flushOutbox(for: syncOwner)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(next, 0)
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [], other: seeded.other,
            receipt: decodedCreateReceipt()
        )
        let requests = await transport.capturedRequests()
        let serverCommits = await transport.committedCount()
        try assertCreateRequests(requests, command: command, count: 2)
        XCTAssertEqual(serverCommits, 1)
    }

    @MainActor
    func testEngineCreateInvalid200CapAuthAndTransportErrorsNeverConfirmOrChangeCommand() async throws {
        func errorJSON(_ code: String, retryable: Bool = false) -> String {
            """
            {"error":{"code":"\(code)","message":"Fixture error","retryable":\(retryable)}}
            """
        }
        let failures: [(CatalogueTransport.Reply, String?)] = [
            (.http(200, "{}"), nil), (.http(200, "null"), nil),
            (.http(201, receiptJSON()), nil), (.http(202, receiptJSON()), nil),
            (.http(200, #"{"status":"committed","operation_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","replayed":false}"#), nil),
            (.http(409, errorJSON("COLLECTION_LIMIT_REACHED")), "COLLECTION_LIMIT_REACHED"),
            (.http(401, errorJSON("UNAUTHORIZED")), "UNAUTHORIZED"),
            (.http(403, errorJSON("FORBIDDEN")), "FORBIDDEN"),
            (.http(503, errorJSON("INTERNAL_ERROR", retryable: true)), "INTERNAL_ERROR"),
            (.network, nil)
        ]
        for (reply, code) in failures {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let command = createCommand()
            let seeded = try await seedEngineCreate(url, command: command)
            let laterCommand = createCommand()
            let transport = CatalogueTransport([reply, reply])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let original = LocalStore(modelContainer: try diskContainer(url))
            let later = try await queueCreate(laterCommand, ownerId: syncOwner, in: original)
            for attempt in 1...2 {
                let store = attempt == 1 ? original : LocalStore(modelContainer: try diskContainer(url))
                let count = try await SyncEngine(store: store, apiClient: api).flushOutbox(for: syncOwner)
                XCTAssertEqual(count, 0)
                let entries = try await store.pendingOutboxEntries(for: syncOwner)
                let failed = try XCTUnwrap(entries.first)
                XCTAssertEqual(failed.operationId, seeded.create.operationId)
                XCTAssertEqual(failed.ownerId, seeded.create.ownerId)
                XCTAssertEqual(failed.plantId, seeded.create.plantId)
                XCTAssertEqual(failed.commandName, seeded.create.commandName)
                XCTAssertTrue(failed.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8))
                XCTAssertEqual(failed.createdAt, seeded.create.createdAt)
                XCTAssertEqual(failed.sequenceNumber, seeded.create.sequenceNumber)
                XCTAssertEqual(failed.retryCount, attempt)
                let message = try XCTUnwrap(failed.lastError)
                if let code { XCTAssertTrue(message.contains(code)) }
                try await assertEngineCreateState(
                    url, store: original, command: command, pending: [failed, later], other: seeded.other
                )
            }
            let requests = await transport.capturedRequests()
            try assertCreateRequests(requests, command: command, count: 2)
        }
    }

    @MainActor
    func testEngineCreateOwnerSwitchABAAndCancellationCannotAcknowledgeOrSendNextCommand() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let later = try await queueCreate(createCommand(), ownerId: syncOwner, in: store)
        for mode in 0..<3 {
            let transport = SuspendedCollectionTransport(receiptJSON())
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let engine = SyncEngine(store: store, apiClient: api)
            let owner = syncOwner
            let operation = Task { try await engine.flushOutbox(for: owner) }
            await transport.waitForRequest()
            if mode == 2 {
                operation.cancel()
            } else {
                await api.bindSyncSession(NativeAuthSession(
                    userId: otherSyncOwner, accessToken: "owner-b-token", expiresAt: .distantFuture
                ))
                do {
                    _ = try await engine.flushOutbox(for: syncOwner)
                    XCTFail("A must not be dispatched with B's token")
                } catch SyncWireValidationError.invalidSession {}
                if mode == 1 { await api.bindSyncSession(syncSession) }
            }
            await transport.resume()
            do {
                _ = try await operation.value
                XCTFail("Stale/cancelled typed response must not acknowledge")
            } catch is CancellationError {
                XCTAssertEqual(mode, 2)
            } catch SyncWireValidationError.invalidSession {
                XCTAssertNotEqual(mode, 2)
            }
            try await assertEngineCreateState(
                url, store: store, command: command, pending: [seeded.create, later], other: seeded.other
            )
            let requests = await transport.capturedRequests()
            try assertCreateRequests(requests, command: command, count: 1)
        }
    }

    @MainActor
    func testEngineCreateReadOnlyAcknowledgementDoesNotRecordSendFailureAndWritableRetryCommits() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let transport = CommittingCatalogueTransport(receiptJSON())
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        do {
            let store = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
            let engine = SyncEngine(store: store, apiClient: api)
            try await assertEngineCreateState(
                url, store: store, command: command, pending: [seeded.create], other: seeded.other
            )
            for _ in 0..<2 {
                do {
                    _ = try await engine.flushOutbox(for: syncOwner)
                    XCTFail("Actual read-only SQLite ACK must fail")
                } catch {
                    let failure = error as NSError
                    XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                    XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
                }
                try await assertEngineCreateState(
                    url, store: store, command: command, pending: [seeded.create], other: seeded.other
                )
            }
        }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let engine = SyncEngine(store: store, apiClient: api)
        let count = try await engine.flushOutbox(for: syncOwner)
        let next = try await engine.flushOutbox(for: syncOwner)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(next, 0)
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [], other: seeded.other,
            receipt: decodedCreateReceipt()
        )
        let requests = await transport.capturedRequests()
        let serverCommits = await transport.committedCount()
        try assertCreateRequests(requests, command: command, count: 3)
        XCTAssertEqual(serverCommits, 1)
    }

    @MainActor
    func testEngineCreateReadOnlyFailureBookkeepingAndLegacyWritesLeaveNoCachedMutations() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let transport = CatalogueTransport([.network, .network])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let store = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
        let engine = SyncEngine(store: store, apiClient: api)
        for mode in 0..<5 {
            do {
                switch mode {
                case 0, 1:
                    _ = try await engine.flushOutbox(for: syncOwner)
                case 2:
                    try await store.recordOutboxFailure(operationId: command.operationId, errorMessage: "unsaved")
                case 3:
                    try await store.markOutboxCommitted(operationId: command.operationId)
                default:
                    _ = try await queueCreate(createCommand(), ownerId: syncOwner, in: store)
                }
                XCTFail("Read-only SQLite outbox mutation must fail")
            } catch {
                let failure = error as NSError
                XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
            }
            try await assertEngineCreateState(
                url, store: store, command: command, pending: [seeded.create], other: seeded.other
            )
        }
        let requests = await transport.capturedRequests()
        try assertCreateRequests(requests, command: command, count: 2)
        let retryAPI = client(CatalogueTransport([.http(200, receiptJSON())]))
        await retryAPI.bindSyncSession(syncSession)
        let writable = LocalStore(modelContainer: try diskContainer(url))
        let count = try await SyncEngine(store: writable, apiClient: retryAPI).flushOutbox(for: syncOwner)
        XCTAssertEqual(count, 1)
        try await assertEngineCreateState(
            url, store: writable, command: command, pending: [], other: seeded.other,
            receipt: decodedCreateReceipt()
        )
    }

    @MainActor
    func testEngineCreateConcurrentDuplicateFlushDispatchesOnceAndCountsOneDurableCommit() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let transport = SuspendedCollectionTransport(receiptJSON())
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let engine = SyncEngine(store: store, apiClient: api)
        let owner = syncOwner
        let first = Task { try await engine.flushOutbox(for: owner) }
        await transport.waitForRequest()
        let overlapping = try await engine.flushOutbox(for: owner)
        XCTAssertEqual(overlapping, 0)
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [seeded.create], other: seeded.other
        )
        await transport.resume()
        let committed = try await first.value
        let next = try await engine.flushOutbox(for: owner)
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(next, 0)
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [], other: seeded.other,
            receipt: decodedCreateReceipt()
        )
        let requests = await transport.capturedRequests()
        try assertCreateRequests(requests, command: command, count: 1)
    }

    @MainActor
    func testCanonicalCreateRejectsGenericSuccessButPersistsValidationFailureMetadata() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let transport = CatalogueTransport([.http(200, receiptJSON())])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        do {
            try await store.finishOutboxEntry(
                operationId: command.operationId, context: lease, authority: api.syncAuthority
            )
            XCTFail("Canonical plant.create requires durable receipt acknowledgement")
        } catch CatalogueCreateAcknowledgementError.invalidCommand {}
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [seeded.create], other: seeded.other
        )
        let engine = SyncEngine(store: store, apiClient: api)
        let committed = try await engine.flushOutbox(for: syncOwner)
        XCTAssertEqual(committed, 1)
        let invalid = createCommand()
        let invalidCommand = CommandEnvelopeDTO(
            operationId: invalid.operationId, commandName: "plant.create",
            payloadJSON: #"{"creation_source":"catalogue","plant_id":"fixture_collection_cap","owner_id":"injected"}"#
        )
        let queued = try await queueCreate(invalidCommand, ownerId: syncOwner, in: store)
        let failedCount = try await engine.flushOutbox(for: syncOwner)
        XCTAssertEqual(failedCount, 0)
        let pending = try await store.pendingOutboxEntries(for: syncOwner)
        let failed = try XCTUnwrap(pending.first)
        XCTAssertEqual(failed.operationId, queued.operationId)
        XCTAssertEqual(failed.sequenceNumber, queued.sequenceNumber)
        XCTAssertEqual(failed.createdAt, queued.createdAt)
        XCTAssertTrue(failed.payloadJSON.utf8.elementsEqual(invalidCommand.payloadJSON.utf8))
        XCTAssertEqual(failed.retryCount, 1)
        XCTAssertTrue(try XCTUnwrap(failed.lastError).contains("invalidPayload"))
        let invalidConfirmation = try await store.catalogueCreateConfirmation(
            ownerId: syncOwner, operationId: invalidCommand.operationId
        )
        XCTAssertNil(invalidConfirmation)
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [failed], other: seeded.other,
            receipt: decodedCreateReceipt()
        )
        let requests = await transport.capturedRequests()
        try assertCreateRequests(requests, command: command, count: 1)
    }

    @MainActor
    func testEngineCreateTransportCancellationNeverBecomesRetryMetadata() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let store = LocalStore(modelContainer: try diskContainer(url))
        for reply in [CatalogueTransport.Reply.cancelled, .urlCancelled] {
            let transport = CatalogueTransport([reply])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            do {
                _ = try await SyncEngine(store: store, apiClient: api).flushOutbox(for: syncOwner)
                XCTFail("Transport cancellation must propagate")
            } catch is CancellationError {
            } catch let error as URLError {
                XCTAssertEqual(error.code, .cancelled)
            }
            try await assertEngineCreateState(
                url, store: store, command: command, pending: [seeded.create], other: seeded.other
            )
            let requests = await transport.capturedRequests()
            try assertCreateRequests(requests, command: command, count: 1)
        }
    }
}

extension CollectionWireTests {
    @MainActor
    func testIdentifiedPlantSaveRestoresSameCommandAndReadsPrivatePhoto() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let flow = UUID(), photo = UUID(), taxon = UUID()
        let input = CatalogueInput(identification: .init(jobId: flow, taxonId: taxon), personalName: "My Monstera")
        let envelope = try input.makeEnvelope(operationId: operationId)
        let expected = ["creation_source": "catalogue", "add_method": "scan", "creation_intent": "care",
                        "identification_job_id": flow.uuidString.lowercased(), "taxon_id": taxon.uuidString.lowercased(),
                        "personal_name": "My Monstera"]
        let payload = try JSONDecoder().decode([String: String].self, from: Data(envelope.payloadJSON.utf8))
        XCTAssertEqual(payload, expected)
        let schema = Schema([
            LocalOutboxRecord.self, CatalogueCreateConfirmationRecord.self,
            CatalogueInputCheckpointRecord.self, GuestDraftCacheRecord.self,
            SyncedEntityRecord.self, SyncCheckpointRecord.self
        ])
        func openStore() throws -> LocalStore {
            LocalStore(modelContainer: try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url)
            ]))
        }
        func restore(_ store: LocalStore, _ api: PlantsAPIClient) async throws -> CatalogueSaveModel {
            let repository = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            let outcome = await CatalogueSaveModel.restore(store: store, apiClient: api, repository: repository,
                ownerId: syncOwner, flowId: flow, session: syncSession, isAnonymous: false)
            guard case let .restored(model) = outcome else { throw SyncWireValidationError.invalidPage }
            return model
        }
        let original: URLRequest
        do {
            let transport = CatalogueTransport([.http(200, try syncJSON(syncObject())), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = try openStore()
            _ = try await store.checkpointCatalogueInput(input, flowId: flow, operationId: operationId,
                context: lease, authority: api.syncAuthority)
            let model = try await restore(store, api)
            await model.save()
            guard case .pending = model.state else { return XCTFail("Lost receipt must leave the write pending") }
            let requests = await transport.capturedRequests()
            original = try XCTUnwrap(requests.last)
            model.cancel()
        }

        var page = syncObject()
        page["changes"] = [["entity_type": "plants", "id": serverPlantId.uuidString,
                            "updated_at": syncUntil, "deleted_at": NSNull(),
                            "data": ["id": serverPlantId.uuidString, "plant_id": "monstera_deliciosa",
                                     "taxon_id": taxon.uuidString, "main_photo_id": photo.uuidString,
                                     "personal_name": "My Monstera", "revision": 1, "care_revision": 1]]]
        let receipt = try decodedCreateReceipt(["photo_id": photo.uuidString])
        let receiptWire = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        let image = Data([0xff, 0xd8, 0xff])
        let transport = CatalogueTransport([.http(200, receiptWire), .http(200, try syncJSON(page)),
                                            .photo(image, mime: "image/jpeg"), .photo(image, mime: "text/html")])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let store = try openStore()
        let model = try await restore(store, api)
        XCTAssertEqual(model.input, input)
        XCTAssertEqual(model.envelope, envelope)
        await model.save()
        guard case let .saved(saved) = model.state else { return XCTFail("Typed receipt was not persisted") }
        XCTAssertEqual(saved.receipt.photoId, photo)
        await model.loadCard()
        XCTAssertEqual(model.cardSummary?.id, serverPlantId)
        XCTAssertEqual(model.cardSummary?.mainPhotoId, photo)

        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let bytes = try await api.fetchPlantPhoto(plantId: serverPlantId, context: lease)
        XCTAssertEqual(bytes, image)
        do {
            _ = try await api.fetchPlantPhoto(plantId: serverPlantId, context: lease)
            XCTFail("Non-image data reached the card")
        } catch AnalysisHTTPError.invalidResponse {}
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.first?.httpBody, original.httpBody)
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "GET", "GET"])
        XCTAssertEqual(requests.last?.url?.path, "/functions/v1/plants-api/plants/\(serverPlantId.uuidString.lowercased())/photo")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(syncSession.accessToken)")
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "X-Installation-Credential"))
        let nonRedirecting = await transport.nonRedirectingRequests
        XCTAssertEqual(nonRedirecting, 2)
        try XCTAssertThrowsError(CatalogueCreateWire.validate(decodedCreateReceipt(), for: envelope))
    }

    private func manualWateringReceipt(
        entryId: UUID, state: String, reversalId: UUID? = nil
    ) -> [String: Any] {
        ["plant_id": serverPlantId.uuidString, "entry_id": entryId.uuidString,
         "reversal_id": reversalId.map { $0.uuidString as Any } ?? NSNull(),
         "state": state, "watermark": syncUntil]
    }

    private func careProjection(anchor: String? = nil, due: String? = nil) -> [String: Any] {
        var result: [String: Any] = [
            "plant_id": serverPlantId.uuidString, "status": "available",
            "recommendation": [
                "action_id": "fixture-soil", "action_code": "check_soil", "text": "Check the substrate.",
                "next_check_interval_days": 7,
                "source": ["url": "https://example.invalid/soil", "locator": "Watering guidance"]
            ] as [String: Any],
            "next_check": NSNull()
        ]
        if let anchor, let due {
            result["next_check"] = [
                "anchor_on": anchor, "due_on": due, "interval_days": 7,
                "basis": "Based on the last recorded watering and the published 7-day interval.",
                "source": ["url": "https://example.invalid/interval", "locator": "Soil check interval"]
            ] as [String: Any]
        }
        return result
    }

    @MainActor
    func testManualWateringLostResponseRestoresFrozenWriteAndReadsUndo() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let flow = UUID()
        let input = CatalogueInput(speciesSlug: "fixture_collection_cap", personalName: "Saved plant")
        let create = try input.makeEnvelope(operationId: operationId)
        let receipt = try decodedCreateReceipt()
        let schema = Schema([
            LocalOutboxRecord.self, CatalogueCreateConfirmationRecord.self,
            CatalogueInputCheckpointRecord.self, GuestDraftCacheRecord.self,
            SyncedEntityRecord.self, SyncCheckpointRecord.self
        ])
        func openStore() throws -> LocalStore {
            LocalStore(modelContainer: try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url)
            ]))
        }
        func restore(_ store: LocalStore, _ api: PlantsAPIClient) async throws -> CatalogueSaveModel {
            let repository = CollectionRepository(
                store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api)
            )
            let outcome = await CatalogueSaveModel.restore(
                store: store, apiClient: api, repository: repository,
                ownerId: syncOwner, flowId: flow, session: syncSession, isAnonymous: false
            )
            guard case let .restored(model) = outcome else { throw SyncWireValidationError.invalidPage }
            return model
        }
        let entryId = UUID()
        func page(_ state: String? = nil, newEntry: UUID? = nil, recordOperation: UUID? = nil) throws -> String {
            let plant: [String: Any] = [
                "entity_type": "plants", "id": serverPlantId.uuidString,
                "updated_at": syncUntil, "deleted_at": NSNull(),
                "data": ["id": serverPlantId.uuidString, "plant_id": input.speciesIdentifier,
                         "personal_name": "Saved plant", "revision": 1, "care_revision": 1]
            ]
            func fact(_ id: UUID, state: String) -> [String: Any] {
                [
                    "entity_type": "care_entries", "id": id.uuidString,
                    "updated_at": syncUntil, "deleted_at": NSNull(),
                    "data": ["id": id.uuidString, "plant_id": serverPlantId.uuidString,
                             "task_id": NSNull(), "action_code": "water", "state": state,
                             "operation_id": id == newEntry ? "NEXT_RECORD_OPERATION"
                                 : (recordOperation?.uuidString ?? UUID().uuidString),
                             "occurred_at": "2026-11-03T07:00:00Z", "occurred_local_date": "2026-11-03"]
                ]
            }
            var rows = state.map { [fact(entryId, state: $0)] } ?? []
            if let newEntry { rows.append(fact(newEntry, state: "active")) }
            rows.sort { ($0["id"] as! String) < ($1["id"] as! String) }
            var result = syncObject()
            result["changes"] = rows + [plant]
            return try syncJSON(result)
        }
        let original: URLRequest
        let recordId: UUID
        do {
            let transport = CatalogueTransport([.http(200, try page()), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = try openStore()
            _ = try await store.checkpointCatalogueInput(
                input, flowId: flow, operationId: operationId, context: lease, authority: api.syncAuthority
            )
            _ = try await queueCreate(create, ownerId: syncOwner, in: store)
            try await store.acknowledgeCatalogueCreate(
                create, receipt: receipt, context: lease, authority: api.syncAuthority
            )
            let model = try await restore(store, api)
            await model.loadCard(includeManualWateringActions: true)
            XCTAssertEqual(model.manualWateringState, .ready)
            let beforeTap = Date()
            await model.recordWatering()
            let afterTap = Date()
            XCTAssertEqual(model.manualWateringState, .pending)
            XCTAssertEqual(model.wateringHistoryState, .loaded([]))
            let captured = await transport.capturedRequests()
            original = try XCTUnwrap(captured.last)
            XCTAssertEqual(original.httpMethod, "POST")
            XCTAssertEqual(original.url?.path, "/functions/v1/plants-api/commands")
            XCTAssertEqual(original.value(forHTTPHeaderField: "Authorization"), "Bearer \(syncSession.accessToken)")
            XCTAssertEqual(original.value(forHTTPHeaderField: "X-Client-Locale"), "en")
            XCTAssertNil(original.value(forHTTPHeaderField: "X-Installation-Credential"))
            let body = try XCTUnwrap(original.httpBody)
            let record = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: body)
            recordId = record.operationId
            XCTAssertEqual(record.plantId, serverPlantId)
            XCTAssertEqual(record.commandName, "care.record")
            XCTAssertNotEqual(recordId, create.operationId)
            XCTAssertEqual(original.value(forHTTPHeaderField: "X-Operation-Id"), recordId.uuidString.lowercased())
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(record.payloadJSON.utf8)) as? [String: String])
            XCTAssertEqual(Set(payload.keys), ["action_code", "occurred_at", "timezone"])
            XCTAssertEqual(payload["action_code"], "water")
            XCTAssertEqual(payload["timezone"], TimeZone.current.identifier)
            let timestamp = try XCTUnwrap(payload["occurred_at"])
            let occurredAt = try XCTUnwrap(SQLTimestamp.date(from: timestamp))
            XCTAssertGreaterThanOrEqual(occurredAt, beforeTap.addingTimeInterval(-1))
            XCTAssertLessThanOrEqual(occurredAt, afterTap)
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            XCTAssertEqual(timestamp, formatter.string(from: occurredAt))
            model.cancel()
        }

        let validRecord = try syncJSON(manualWateringReceipt(entryId: entryId, state: "active"))
        let reversalId = UUID()
        let voidedPage = try page("voided", recordOperation: recordId)
        let previousSync = syncUntil
        let reversalSync = "2026-11-03T09:05:00.000001+00:00"
        let postUndoPage = voidedPage.replacingOccurrences(of: previousSync, with: reversalSync)
        var undoReceipt = manualWateringReceipt(entryId: entryId, state: "voided", reversalId: reversalId)
        undoReceipt["watermark"] = reversalSync
        let canonicalUndo = try syncJSON(undoReceipt)
        var undoDelta = syncObject()
        undoDelta["changes"] = [[
            "entity_type": "care_reversals", "id": reversalId.uuidString,
            "updated_at": reversalSync, "deleted_at": NSNull(),
            "data": ["id": reversalId.uuidString, "entry_id": entryId.uuidString, "operation_id": "UNDO_OPERATION"]
        ]]
        let reversalTemplate = try syncJSON(undoDelta)
        let syncUndo = CatalogueTransport.Reply.inspect { requests in
            let post = try XCTUnwrap(requests.last { $0.httpMethod == "POST" })
            let command = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(post.httpBody))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(postUndoPage.utf8)) as? [String: Any])
            var rows = try XCTUnwrap(object["changes"] as? [[String: Any]])
            rows.removeAll { $0["entity_type"] as? String == "plants" }
            let reversal = reversalTemplate.replacingOccurrences(of: "UNDO_OPERATION", with: command.operationId.uuidString)
            let delta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reversal.utf8)) as? [String: Any])
            rows += try XCTUnwrap(delta["changes"] as? [[String: Any]])
            object["changes"] = rows
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let noDate = try syncJSON(careProjection())
        let dated = try syncJSON(careProjection(anchor: "2026-11-03", due: "2026-11-10"))
        let nextEntryId = UUID()
        let nextRecord = try syncJSON(manualWateringReceipt(entryId: nextEntryId, state: "active"))
        let activePage = try page("voided", newEntry: nextEntryId, recordOperation: recordId)
            .replacingOccurrences(of: previousSync, with: "2026-11-03T09:06:00.000001+00:00")
        let correctedAt = "2026-11-02T07:00:00Z"
        let correctedUntil = "2026-11-03T09:10:00.000001+00:00"
        var correctedPage = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(activePage.utf8)) as? [String: Any]
        )
        var rows = try XCTUnwrap(correctedPage["changes"] as? [[String: Any]])
        let correctedIndex = try XCTUnwrap(rows.firstIndex { ($0["id"] as? String) == nextEntryId.uuidString })
        var correctedRow = try XCTUnwrap(rows[correctedIndex]["data"] as? [String: Any])
        correctedRow["occurred_at"] = correctedAt
        correctedRow["occurred_local_date"] = "2026-11-02"
        rows[correctedIndex]["data"] = correctedRow
        rows[correctedIndex]["updated_at"] = correctedUntil
        correctedPage["until"] = correctedUntil
        correctedPage["next_since"] = correctedUntil
        let changed = rows.remove(at: correctedIndex)
        var correctedDelta = correctedPage
        correctedDelta["changes"] = [changed]
        correctedPage["changes"] = rows + [changed]
        var correctionReceipt = manualWateringReceipt(entryId: nextEntryId, state: "active")
        correctionReceipt["watermark"] = correctedUntil
        let correctedAdvice = try syncJSON(careProjection(anchor: "2026-11-02", due: "2026-11-09"))
        func withRecordOperation(_ page: String) -> CatalogueTransport.Reply {
            .inspect { requests in
                let records = try requests.filter { $0.httpMethod == "POST" }.map {
                    try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap($0.httpBody))
                }
                let command = try XCTUnwrap(records.last { $0.commandName == "care.record" })
                return page.replacingOccurrences(of: "NEXT_RECORD_OPERATION", with: command.operationId.uuidString)
            }
        }
        let transport = CatalogueTransport([
            .http(200, try page("active", recordOperation: recordId)), .http(200, noDate), .http(200, validRecord), .network,
            .http(200, try page("active", recordOperation: recordId)), .http(200, dated),
            .http(200, canonicalUndo), syncUndo, .http(200, postUndoPage), .http(200, noDate),
            .http(200, nextRecord), withRecordOperation(activePage), withRecordOperation(activePage), .http(200, dated),
            withRecordOperation(activePage), .http(200, try syncJSON(correctionReceipt)),
            withRecordOperation(try syncJSON(correctedDelta)), withRecordOperation(try syncJSON(correctedPage)),
            .http(200, correctedAdvice)
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let store = try openStore()
        let model = try await restore(store, api)
        await model.loadCard(includeManualWateringActions: true)
        XCTAssertEqual(model.manualWateringState, .pending)
        await model.loadCareRecommendation()
        await model.retryManualWatering()
        XCTAssertEqual(model.wateringHistoryState, .unavailable)
        XCTAssertEqual(model.manualWateringState, .unavailable)
        guard case .saved = model.state else { return XCTFail("Refresh failure lost the saved card confirmation") }
        let acknowledged = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertTrue(acknowledged.isEmpty)
        await model.retryManualWatering()
        let requestsAfterRefreshFailure = await transport.capturedRequests()
        XCTAssertEqual(requestsAfterRefreshFailure.map(\.httpMethod), ["GET", "GET", "POST", "GET"])
        XCTAssertEqual(model.careRecommendationState, .unavailable)
        await model.loadCard(includeManualWateringActions: true)
        XCTAssertEqual(model.manualWateringState, .ready)
        guard case let .loaded(active) = model.wateringHistoryState else {
            return XCTFail("Expected synchronized manual fact")
        }
        XCTAssertEqual(active.map(\.id), [entryId])
        XCTAssertEqual(active.map(\.state), ["active"])
        await model.loadCareRecommendation()
        guard case let .available(beforeUndo) = model.careRecommendationState else {
            return XCTFail("Expected a calendar check after reading the active fact")
        }
        XCTAssertEqual(beforeUndo.nextCheck?.dueOn, "2026-11-10")
        await model.undoWatering(entryId: entryId)
        XCTAssertEqual(model.manualWateringState, .ready)
        guard case let .loaded(voided) = model.wateringHistoryState else {
            return XCTFail("Expected synchronized reversal")
        }
        XCTAssertEqual(voided.map(\.id), [entryId])
        XCTAssertEqual(voided.map(\.state), ["voided"])
        guard case let .available(afterUndo) = model.careRecommendationState else {
            return XCTFail("Undo should reload the recommendation")
        }
        XCTAssertNil(afterUndo.nextCheck)
        let posts = await transport.capturedRequests().filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        let retry = try XCTUnwrap(posts.first)
        XCTAssertEqual(retry.httpBody, original.httpBody)
        XCTAssertEqual(retry.value(forHTTPHeaderField: "X-Operation-Id"), original.value(forHTTPHeaderField: "X-Operation-Id"))
        let undo = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(posts.last?.httpBody))
        XCTAssertEqual(undo.commandName, "care.undo")
        XCTAssertEqual(undo.plantId, serverPlantId)
        XCTAssertNotEqual(undo.operationId, recordId)
        XCTAssertNotEqual(undo.operationId, create.operationId)
        let undoPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(undo.payloadJSON.utf8)) as? [String: String])
        XCTAssertEqual(undoPayload, ["entry_id": entryId.uuidString.lowercased()])
        let pending = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertTrue(pending.isEmpty)
        await model.recordWatering()
        guard case let .available(afterRecord) = model.careRecommendationState else {
            return XCTFail("Recording a fact should reload the recommendation")
        }
        XCTAssertEqual(afterRecord.nextCheck?.dueOn, "2026-11-10")
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let repository = CollectionRepository(
            store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api)
        )
        try await repository.enqueueWateringDateCorrection(
            plantId: serverPlantId, entryId: nextEntryId,
            date: XCTUnwrap(SQLTimestamp.date(from: correctedAt)), timezone: TimeZone(secondsFromGMT: 0)!,
            context: lease
        )
        await model.loadCard(includeManualWateringActions: true)
        XCTAssertEqual(model.manualWateringState, .pending)
        XCTAssertEqual(model.careRecommendationState, .available(afterRecord))
        await model.retryManualWatering()
        guard case let .available(afterCorrection) = model.careRecommendationState else {
            return XCTFail("Confirming a date correction should reload the recommendation")
        }
        XCTAssertEqual(afterCorrection.nextCheck?.dueOn, "2026-11-09")
        let refreshedRequests = await transport.capturedRequests().suffix(4)
        XCTAssertEqual(refreshedRequests.map { $0.url?.lastPathComponent }, ["commands", "sync", "sync", "recommendation"])
    }

    @MainActor
    func testWateringDateCorrectionReopensExactOperationUntilCanonicalDateIsOnDisk() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let entry = UUID()
        let newer = "2026-11-03T09:10:00.000001+00:00"
        let corrected = "2026-11-02T08:30:00+03:00"
        var plant = syncChange(id: serverPlantId.uuidString)
        plant["data"] = ["id": serverPlantId.uuidString, "plant_id": "monstera_deliciosa",
                         "revision": 1, "care_revision": 1] as [String: Any]
        func fact(time: String, day: String, updatedAt: String) -> [String: Any] {
            var change = syncChange(updatedAt, id: entry.uuidString, entity: "care_entries")
            change["data"] = ["id": entry.uuidString, "plant_id": serverPlantId.uuidString,
                              "state": "active", "action_code": "water", "timezone": "Europe/Moscow",
                              "occurred_at": time, "occurred_local_date": day]
            return change
        }
        var baseline = syncObject()
        baseline["changes"] = [fact(time: "2026-11-03T08:30:00+03:00", day: "2026-11-03", updatedAt: syncUntil), plant]
        let original: URLRequest
        do {
            let transport = CatalogueTransport([.http(200, try syncJSON(baseline)), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            _ = try await repo.collectionCards(context: lease)
            let date = try XCTUnwrap(SQLTimestamp.date(from: corrected))
            let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
            do {
                try await repo.enqueueWateringDateCorrection(
                    plantId: serverPlantId, entryId: UUID(), date: date, timezone: zone, context: lease
                )
                XCTFail("Queued a correction for a different entry")
            } catch SyncWireValidationError.invalidPage {}
            try await repo.enqueueWateringDateCorrection(
                plantId: serverPlantId, entryId: entry, date: date, timezone: zone, context: lease
            )
            try await repo.retryWateringDateCorrection(plantId: serverPlantId, context: lease)
            let requests = await transport.capturedRequests()
            original = try XCTUnwrap(requests.last)
        }

        var receipt = manualWateringReceipt(entryId: entry, state: "active")
        receipt["watermark"] = newer
        let wrongReceipt = manualWateringReceipt(entryId: UUID(), state: "active")
        var delta = syncObject()
        delta["until"] = newer
        delta["next_since"] = newer
        delta["changes"] = [fact(time: corrected, day: "2026-11-02", updatedAt: newer)]
        let transport = CatalogueTransport([
            .http(200, try syncJSON(wrongReceipt)),
            .http(200, try syncJSON(receipt)), .network,
            .http(200, try syncJSON(receipt)), .http(200, try syncJSON(delta))
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        let envelope = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(original.httpBody))
        XCTAssertEqual(envelope.commandName, "care.correct_date")
        let payload = try JSONDecoder().decode([String: String].self, from: Data(envelope.payloadJSON.utf8))
        XCTAssertEqual(payload, ["entry_id": entry.uuidString.lowercased(), "occurred_at": corrected, "timezone": "Europe/Moscow"])

        for _ in 0..<2 {
            try await repo.retryWateringDateCorrection(plantId: serverPlantId, context: lease)
            let pending = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
            XCTAssertEqual(pending, envelope)
            let history = try await repo.collectionWateringHistory(plantId: serverPlantId, context: lease)
            XCTAssertEqual(history.map(\.occurredLocalDate), ["2026-11-03"])
        }
        try await repo.retryWateringDateCorrection(plantId: serverPlantId, context: lease)
        let pending = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
        XCTAssertNil(pending)
        let history = try await repo.collectionWateringHistory(plantId: serverPlantId, context: lease)
        XCTAssertEqual(history.map(\.id), [entry])
        XCTAssertEqual(history.map(\.occurredLocalDate), ["2026-11-02"])
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "GET", "POST", "GET"])
        for request in requests where request.httpMethod == "POST" {
            XCTAssertEqual(request.httpBody, original.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), envelope.operationId.uuidString.lowercased())
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Locale"), "en")
        }
    }

    @MainActor
    func testCollectionWateringUndoKeepsCorrectedDateUntilExactReversalSyncs() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let entry = UUID()
        let reversal = UUID()
        let correctedDate = "2026-11-02"
        let voidedAt = "2026-11-03T09:10:00.000001+00:00"
        var plant = syncChange(id: serverPlantId.uuidString)
        plant["data"] = ["id": serverPlantId.uuidString, "revision": 1, "care_revision": 1]
        func fact(_ state: String, updatedAt: String) -> [String: Any] {
            var row = syncChange(updatedAt, id: entry.uuidString, entity: "care_entries")
            row["data"] = [
                "id": entry.uuidString, "plant_id": serverPlantId.uuidString, "state": state,
                "action_code": "water", "occurred_at": "2026-11-02T08:30:00+03:00",
                "occurred_local_date": correctedDate, "timezone": "Europe/Moscow"
            ]
            return row
        }
        var baseline = syncObject()
        baseline["changes"] = [fact("active", updatedAt: syncUntil), plant]
        let command: CommandEnvelopeDTO
        let original: Data
        do {
            let transport = CatalogueTransport([.http(200, try syncJSON(baseline)), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            _ = try await repo.collectionCards(context: lease)
            try await repo.enqueueWateringUndo(plantId: serverPlantId, entryId: entry, context: lease)
            let pending = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
            command = try XCTUnwrap(pending)
            try await repo.retryWateringEdit(command, context: lease)
            let requests = await transport.capturedRequests()
            original = try XCTUnwrap(requests.last?.httpBody)
        }

        var receipt = manualWateringReceipt(entryId: entry, state: "voided", reversalId: reversal)
        receipt["watermark"] = voidedAt
        var delta = syncObject()
        delta["until"] = voidedAt
        delta["next_since"] = voidedAt
        let missingReversal = try syncJSON(delta)
        var reversalRow = syncChange(voidedAt, id: reversal.uuidString, entity: "care_reversals")
        reversalRow["data"] = ["id": reversal.uuidString, "entry_id": entry.uuidString,
                               "operation_id": command.operationId.uuidString]
        // A full refresh may supply the missing reversal before the next exact replay.
        delta["changes"] = [plant, fact("voided", updatedAt: voidedAt), reversalRow]
        let complete = try syncJSON(delta)
        let response = try syncJSON(receipt)
        let transport = CatalogueTransport([
            .http(200, response), .http(200, missingReversal),
            .http(200, complete), .http(200, response), .http(200, missingReversal)
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        try await repo.retryWateringEdit(command, context: lease)
        let pending = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
        let active = try await repo.collectionWateringHistory(plantId: serverPlantId, context: lease)
        XCTAssertEqual(pending, command)
        XCTAssertEqual(active.map(\.state), ["active"])
        _ = try await repo.collectionCards(context: lease)
        try await repo.retryWateringEdit(command, context: lease)
        let remaining = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
        let final = try await repo.collectionWateringHistory(plantId: serverPlantId, context: lease)
        XCTAssertNil(remaining)
        XCTAssertEqual(final.map(\.id), [entry])
        XCTAssertEqual(final.map(\.state), ["voided"])
        XCTAssertEqual(final.map(\.occurredLocalDate), [correctedDate])
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "GET", "POST", "GET"])
        XCTAssertTrue(requests.filter { $0.httpMethod == "POST" }.allSatisfy { $0.httpBody == original })
    }

    @MainActor
    func testWateringRecordReopensExactRetryAndRequiresCanonicalLinkBeforeAck() async throws {
        let variants = ["missing", "owner", "entry", "operation", "plant", "task", "action", "date", "day", "state", "sync-loss"]
        for (index, variant) in variants.enumerated() {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let command = try ManualWateringAction.record.envelope(plantId: serverPlantId)
            let entryId = UUID()
            let original: URLRequest
            do {
                let transport = CatalogueTransport([.network])
                let api = client(transport)
                await api.bindSyncSession(syncSession)
                let lease = try await api.captureSyncContext(ownerId: syncOwner)
                let store = LocalStore(modelContainer: try diskContainer(url))
                try await store.enqueueManualWatering(command, context: lease, authority: api.syncAuthority)
                let committed = try await SyncEngine(store: store, apiClient: api).flushOutbox(context: lease)
                XCTAssertEqual(committed, 0)
                let requests = await transport.capturedRequests()
                original = try XCTUnwrap(requests.first)
            }
            let receipt = try syncJSON(manualWateringReceipt(entryId: entryId, state: "active"))
            // Accepted creation can replay after a date correction and undo.
            let state = index.isMultiple(of: 2) ? "voided" : "active"
            let correctedAt = "2026-11-02T07:00:00Z"
            let data: [String: Any] = [
                "id": entryId.uuidString, "plant_id": serverPlantId.uuidString,
                "operation_id": command.operationId.uuidString, "task_id": NSNull(),
                "action_code": "water", "state": state, "timezone": "Europe/Moscow",
                "occurred_at": correctedAt, "occurred_local_date": "2026-11-02"
            ]
            var fact = syncChange(id: entryId.uuidString, entity: "care_entries")
            var badData = data
            switch variant {
            case "entry":
                let otherId = UUID().uuidString
                fact["id"] = otherId
                badData["id"] = otherId
            case "operation": badData["operation_id"] = UUID().uuidString
            case "plant": badData["plant_id"] = UUID().uuidString
            case "task": badData["task_id"] = UUID().uuidString
            case "action": badData["action_code"] = "check_soil"
            case "date": badData["occurred_at"] = "invalid"
            case "day": badData["occurred_local_date"] = "2026-02-30"
            case "state": badData["state"] = "unknown"
            default: break
            }
            fact["data"] = badData
            var badPage = syncObject()
            badPage["changes"] = ["missing", "owner"].contains(variant) ? [] : [fact]
            do {
                let transport = CatalogueTransport([
                    .http(200, receipt), variant == "sync-loss" ? .network : .http(200, try syncJSON(badPage))
                ])
                let api = client(transport)
                await api.bindSyncSession(syncSession)
                let lease = try await api.captureSyncContext(ownerId: syncOwner)
                let store = LocalStore(modelContainer: try diskContainer(url))
                if variant == "owner" {
                    try await store.applySyncedItems([
                        SyncItemDTO(entityType: "care_entries", id: entryId,
                                    updatedAt: SQLTimestamp.date(from: syncUntil)!, payloadJSON: try syncJSON(data))
                    ], ownerId: otherSyncOwner)
                }
                let restored = try await store.pendingOutboxEntries(for: syncOwner)
                XCTAssertEqual(restored.map(\.envelope), [command])
                let committed = try await SyncEngine(store: store, apiClient: api).flushOutbox(context: lease)
                XCTAssertEqual(committed, 0, variant)
                let requests = await transport.capturedRequests()
                XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET"])
                XCTAssertEqual(requests.first?.httpBody, original.httpBody)
            }
            let newer = "2026-11-03T09:10:00.000001+00:00"
            var canonical = syncObject()
            canonical["until"] = newer
            canonical["next_since"] = newer
            var linked = syncChange(newer, id: entryId.uuidString, entity: "care_entries")
            linked["data"] = data
            canonical["changes"] = [linked]
            do {
                let transport = CatalogueTransport([.http(200, receipt), .http(200, try syncJSON(canonical))])
                let api = client(transport)
                await api.bindSyncSession(syncSession)
                let lease = try await api.captureSyncContext(ownerId: syncOwner)
                let store = LocalStore(modelContainer: try diskContainer(url))
                let retained = try await store.pendingOutboxEntries(for: syncOwner)
                XCTAssertEqual(retained.map(\.envelope), [command], variant)
                XCTAssertEqual(retained.first?.retryCount, 2, variant)
                let committed = try await SyncEngine(store: store, apiClient: api).flushOutbox(context: lease)
                XCTAssertEqual(committed, 1, variant)
                let requests = await transport.capturedRequests()
                XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET"])
                XCTAssertEqual(requests.first?.httpBody, original.httpBody)
                XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Operation-Id"),
                               original.value(forHTTPHeaderField: "X-Operation-Id"))
            }
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let pending = try await reopened.pendingOutboxEntries(for: syncOwner)
            XCTAssertTrue(pending.isEmpty)
            let rows = try await reopened.activeSyncedEntities(ownerId: syncOwner, entityType: "care_entries")
            let saved = try XCTUnwrap(rows.first { $0.id == entryId })
            let factOnDisk = try JSONDecoder().decode(CatalogueCareJournalEntry.self, from: Data(saved.payloadJSON.utf8))
            XCTAssertEqual(factOnDisk.operationId, command.operationId)
            XCTAssertEqual(factOnDisk.occurredAt, correctedAt)
            XCTAssertEqual(factOnDisk.state, state)
        }
    }

    @MainActor
    func testManualWateringInvalidReceiptsKeepOriginalOperationOnDisk() async throws {
        let entryId = UUID()
        let cases: [(ManualWateringAction, String, Any)] = [
            (.record, "state", "voided"),
            (.record, "watermark", "invalid"),
            (.record, "reversal_id", UUID().uuidString),
            (.undo(entryId), "plant_id", UUID().uuidString),
            (.undo(entryId), "entry_id", UUID().uuidString),
            (.undo(entryId), "reversal_id", NSNull())
        ]
        for (action, key, value) in cases {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            var receipt: [String: Any]
            switch action {
            case .record, .correctDate: receipt = manualWateringReceipt(entryId: entryId, state: "active")
            case .undo: receipt = manualWateringReceipt(entryId: entryId, state: "voided", reversalId: UUID())
            }
            receipt[key] = value
            let transport = CatalogueTransport([.http(200, try syncJSON(receipt))])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let command = try action.envelope(plantId: serverPlantId)
            try await store.enqueueManualWatering(command, context: lease, authority: api.syncAuthority)
            let engine = SyncEngine(store: store, apiClient: api)
            let committed = try await engine.flushOutbox(context: lease)
            XCTAssertEqual(committed, 0, "Unexpected acknowledgement for \(key)")
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let pending = try await reopened.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(pending.count, 1)
            let failed = try XCTUnwrap(pending.first)
            XCTAssertEqual(failed.operationId, command.operationId)
            XCTAssertEqual(failed.plantId, command.plantId)
            XCTAssertEqual(failed.commandName, command.commandName)
            XCTAssertEqual(failed.payloadJSON, command.payloadJSON)
            XCTAssertEqual(failed.retryCount, 1)
            XCTAssertTrue(try XCTUnwrap(failed.lastError).contains("invalidPage"))
        }
    }

    @MainActor
    func testManualWateringOwnerSwitchAndABARejectInFlightAcknowledgement() async throws {
        let create = createCommand()
        for returnToOriginal in [false, true] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let seeded = try await seedEngineCreate(url, command: create)
            let receipt = try syncJSON(manualWateringReceipt(entryId: UUID(), state: "active"))
            let transport = SuspendedCollectionTransport(receipt)
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            try await store.acknowledgeCatalogueCreate(
                create, receipt: decodedCreateReceipt(), context: lease, authority: api.syncAuthority
            )
            let saved = try await store.catalogueCreateConfirmation(ownerId: syncOwner, operationId: create.operationId)
            let confirmation = try XCTUnwrap(saved)
            let engine = SyncEngine(store: store, apiClient: api)
            let repository = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
            let command = try ManualWateringAction.record.envelope(plantId: serverPlantId)
            let operation = Task {
                try await repository.submitManualWatering(command, confirmation: confirmation, context: lease)
            }
            await transport.waitForRequest()
            let original = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(original.map(\.operationId), [command.operationId])
            await api.bindSyncSession(NativeAuthSession(
                userId: otherSyncOwner, accessToken: "owner-b-token", expiresAt: .distantFuture
            ))
            if returnToOriginal { await api.bindSyncSession(syncSession) }
            await transport.resume()
            do {
                _ = try await operation.value
                XCTFail("The stale receipt acknowledged a manual write")
            } catch SyncWireValidationError.invalidSession {}
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let pendingA = try await reopened.pendingOutboxEntries(for: syncOwner)
            let pendingB = try await reopened.pendingOutboxEntries(for: otherSyncOwner)
            XCTAssertEqual(pendingA, original)
            XCTAssertEqual(pendingB, [seeded.other])
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(syncSession.accessToken)")
        }
    }

    func testCareRecommendationUsesBoundOwnerAndRejectsUnverifiedProjection() async throws {
        let plantId = serverPlantId
        let text = "Check the substrate before watering."
        let rule: [String: Any] = [
            "action_id": "checked-watering-rule", "action_code": "check_soil", "text": text,
            "next_check_interval_days": NSNull(),
            "source": ["url": "https://example.invalid/watering", "locator": "Growing"]
        ]
        func response(_ plant: UUID, _ status: String, _ recommendation: Any) throws -> CatalogueTransport.Reply {
            .http(200, try syncJSON([
                "plant_id": plant.uuidString, "status": status, "recommendation": recommendation
            ]))
        }
        var wrongAction = rule
        wrongAction["action_code"] = "water_now"
        var unsafeSource = rule
        unsafeSource["source"] = ["url": "https://account:password@example.invalid/watering", "locator": "Growing"]
        var invalidInterval = rule
        invalidInterval["next_check_interval_days"] = 0
        let transport = CatalogueTransport(try [
            response(plantId, "available", rule), response(plantId, "unavailable", NSNull()),
            response(UUID(), "available", rule), response(plantId, "available", wrongAction),
            response(plantId, "available", unsafeSource), response(plantId, "available", invalidInterval),
            response(plantId, "unavailable", rule)
        ])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let context = try await api.captureSyncContext(ownerId: accessOwner)
        let recommendation = try await api.fetchCareRecommendation(plantId: plantId, context: context)
        XCTAssertEqual(recommendation?.text, text)
        XCTAssertEqual(recommendation?.source.url, URL(string: "https://example.invalid/watering"))
        XCTAssertNil(recommendation?.nextCheck)
        let unavailable = try await api.fetchCareRecommendation(plantId: plantId, context: context)
        XCTAssertNil(unavailable)
        for _ in 0..<5 {
            do {
                _ = try await api.fetchCareRecommendation(plantId: plantId, context: context)
                XCTFail("An invalid care recommendation reached the card")
            } catch AnalysisHTTPError.invalidResponse {}
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 7)
        let path = "/functions/v1/plants-api/plants/\(plantId.uuidString.lowercased())/care/recommendation"
        XCTAssertTrue(requests.allSatisfy {
            $0.httpMethod == "GET" && $0.url?.path == path
                && $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(accessSession.accessToken)"
                && $0.value(forHTTPHeaderField: "X-Client-Locale") == "en"
                && $0.value(forHTTPHeaderField: "X-Installation-Credential") == nil
        })
        let nonRedirecting = await transport.nonRedirectingRequests
        XCTAssertEqual(nonRedirecting, requests.count)
    }

    func testCareNextCheckReadsCalendarDaysAndRejectsAnUnverifiedDate() async throws {
        let dated = careProjection(anchor: "2026-10-29", due: "2026-11-05")
        let corrected = careProjection(anchor: "2026-10-28", due: "2026-11-04")
        let olderAnchor = careProjection(anchor: "2026-10-20", due: "2026-10-27")
        let impossible = careProjection(anchor: "2026-11-31", due: "2026-12-07")
        var wrongSource = try XCTUnwrap(dated["next_check"] as? [String: Any])
        wrongSource["source"] = ["url": "http://example.invalid/interval", "locator": "Soil check interval"]
        var unsafe = dated
        unsafe["next_check"] = wrongSource
        var mismatched = dated
        var rule = try XCTUnwrap(dated["recommendation"] as? [String: Any])
        rule["next_check_interval_days"] = 8
        mismatched["recommendation"] = rule
        var older = careProjection()
        older.removeValue(forKey: "next_check")
        let replies = [dated, corrected, olderAnchor, careProjection(), older, impossible, unsafe, mismatched]
        let transport = CatalogueTransport(try replies.map { .http(200, try syncJSON($0)) })
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let context = try await api.captureSyncContext(ownerId: accessOwner)
        for (anchor, day) in [
            ("2026-10-29", "2026-11-05"), ("2026-10-28", "2026-11-04"), ("2026-10-20", "2026-10-27")
        ] {
            let recommendation = try await api.fetchCareRecommendation(plantId: serverPlantId, context: context)
            let check = try XCTUnwrap(recommendation?.nextCheck)
            XCTAssertEqual(check.anchorOn, anchor)
            XCTAssertEqual(check.dueOn, day)
            XCTAssertEqual(check.intervalDays, 7)
            XCTAssertEqual(check.source.url, URL(string: "https://example.invalid/interval"))
            XCTAssertEqual(check.basis, "Based on the last recorded watering and the published 7-day interval.")
        }
        for _ in 0..<2 {
            let recommendation = try await api.fetchCareRecommendation(plantId: serverPlantId, context: context)
            XCTAssertEqual(recommendation?.text, "Check the substrate.")
            XCTAssertNil(recommendation?.nextCheck)
        }
        for _ in 0..<3 {
            do {
                _ = try await api.fetchCareRecommendation(plantId: serverPlantId, context: context)
                XCTFail("An invalid calendar check reached the card")
            } catch AnalysisHTTPError.invalidResponse {}
        }
    }

    func testRoutineCheckValidatesAdditiveContext() async throws {
        let ruleId = UUID()
        let dated = careProjection(anchor: "2026-11-16", due: "2026-11-23")
        let routine: [String: Any] = [
            "rule_id": ruleId.uuidString, "care_revision": 2,
            "due_local_date": "2026-11-23", "anchor_local_date": "2026-11-16",
            "anchor_kind": "water"
        ]
        func projection(_ fields: [String: Any]) -> [String: Any] {
            var result = dated
            result["routine_check"] = fields
            return result
        }
        var soil = routine
        soil["anchor_kind"] = "check_soil"
        var maximum = routine
        maximum["care_revision"] = 9_007_199_254_740_991
        var nullRoutine = dated
        nullRoutine["routine_check"] = NSNull()
        var invalid: [[String: Any]] = []
        let badFields: [(String, Any)] = [
            ("rule_id", "not-a-uuid"), ("care_revision", 0), ("care_revision", -1),
            ("care_revision", 9_007_199_254_740_992), ("care_revision", 2.5),
            ("due_local_date", "2026-11-24"), ("anchor_local_date", "2026-11-15"),
            ("due_local_date", "2026-11-31"),
            ("anchor_local_date", "2026-11-16T00:00:00Z"), ("anchor_kind", "fertilize")
        ]
        for (key, value) in badFields {
            var fields = routine
            fields[key] = value
            invalid.append(projection(fields))
        }
        for key in routine.keys {
            var missing = routine
            missing.removeValue(forKey: key)
            invalid.append(projection(missing))
            var null = routine
            null[key] = NSNull()
            invalid.append(projection(null))
        }
        var noNext = projection(routine)
        noNext["next_check"] = NSNull()
        invalid.append(noNext)
        noNext.removeValue(forKey: "next_check")
        invalid.append(noNext)
        var unsafe = projection(routine)
        var next = try XCTUnwrap(unsafe["next_check"] as? [String: Any])
        next["source"] = ["url": "http://example.invalid/interval", "locator": "Interval"]
        unsafe["next_check"] = next
        invalid.append(unsafe)
        var unavailable = projection(routine)
        unavailable["status"] = "unavailable"
        unavailable["recommendation"] = NSNull()
        unavailable["next_check"] = NSNull()
        invalid.append(unavailable)
        var missingRecommendation = projection(routine)
        missingRecommendation["recommendation"] = NSNull()
        invalid.append(missingRecommendation)
        var wrongPlant = projection(routine)
        wrongPlant["plant_id"] = UUID().uuidString
        invalid.append(wrongPlant)
        let valid = [projection(routine), projection(soil), projection(maximum)]
        let transport = CatalogueTransport(try (valid + [dated, nullRoutine] + invalid).map {
            .http(200, try syncJSON($0))
        })
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let context = try await api.captureSyncContext(ownerId: accessOwner)
        let expected: [(PlantCareRecommendation.RoutineCheck.AnchorKind, Int)] = [
            (.water, 2), (.checkSoil, 2), (.water, 9_007_199_254_740_991)
        ]
        for (kind, revision) in expected {
            let recommendation = try await api.fetchCareRecommendation(plantId: serverPlantId, context: context)
            let result = try XCTUnwrap(recommendation?.routineContext)
            XCTAssertEqual(result.plantId, serverPlantId)
            XCTAssertEqual(result.check.ruleId, ruleId)
            XCTAssertEqual(result.check.careRevision, revision)
            XCTAssertEqual(result.check.anchorKind, kind)
            XCTAssertEqual(result.check.dueLocalDate, "2026-11-23")
            XCTAssertEqual(result.check.anchorLocalDate, "2026-11-16")
            XCTAssertEqual(recommendation?.nextCheck?.dueOn, "2026-11-23")
            XCTAssertEqual(recommendation?.text, "Check the substrate.")
        }
        for _ in 0..<2 {
            let recommendation = try await api.fetchCareRecommendation(plantId: serverPlantId, context: context)
            XCTAssertNotNil(recommendation?.nextCheck)
            XCTAssertNil(recommendation?.routineContext)
        }
        for (index, _) in invalid.enumerated() {
            do {
                _ = try await api.fetchCareRecommendation(plantId: serverPlantId, context: context)
                XCTFail("Invalid routine projection accepted at index \(index)")
            } catch AnalysisHTTPError.invalidResponse {
            } catch is DecodingError {}
        }
    }

    private func diagnosisTicket(url: String, photoId: UUID) -> String {
        #"{"photo_asset_id":"\#(photoId.uuidString)","storage_bucket":"photos","storage_path":"test.jpg","signed_upload_url":"\#(url)","expires_in_seconds":60,"max_byte_size":10485760}"#
    }

    private func diagnosisJob(
        id: UUID, status: String, result: String = "null", errorCode: String = "null",
        target: (plant: UUID, photo: UUID)? = nil
    ) -> String {
        let binding = target.map { #","target_plant_id":"\#($0.plant.uuidString)","photo_asset_id":"\#($0.photo.uuidString)""# } ?? ""
        return #"{"job_id":"\#(id.uuidString)","mode":"diagnosis","status":"\#(status)","quota_kind":"free_monthly","quota_state":"reserved","result":\#(result),"error_code":\#(errorCode),"error_message":null\#(binding)}"#
    }

    private func firstAidEligibility(jobId: UUID, plantId: UUID) throws -> RecordableFirstAidAction {
        let fields = [
            "job_id": jobId.uuidString, "plant_id": plantId.uuidString,
            "action_id": "check_monstera_moisture", "action_code": "check_soil",
            "source": ["url": "https://example.invalid/soil", "locator": "Soil moisture"]
        ] as [String: Any]
        return try JSONDecoder().decode(RecordableFirstAidAction.self, from: Data(syncJSON(fields).utf8))
    }

    func testFirstAidEligibilityRequiresBoundSuccessfulResultAndExactAdvisory() throws {
        let jobId = UUID(), photo = UUID()
        let result: [String: Any] = [
            "analysis_id": UUID().uuidString, "job_id": jobId.uuidString, "kb_release_id": UUID().uuidString,
            "mode": "diagnosis", "identification_status": "identified", "plant_id": "monstera_deliciosa",
            "genus_id": "monstera", "diagnosis_status": "problem_detected", "selected_condition_id": "overwatering",
            "candidates": [], "visual_markers": [], "evidence_basis": [], "limitations": [],
            "first_action_summary": "Check soil moisture.", "control_interval_days": NSNull(),
            "plan_availability": "available", "analysis_receipt": "test-receipt"
        ]
        func advisory(job: UUID, plant: UUID) -> [String: Any] {
            ["job_id": job.uuidString, "plant_id": plant.uuidString,
             "action_id": "check_monstera_moisture", "action_code": "check_soil",
             "source": ["url": "https://example.invalid/soil", "locator": "Soil moisture"]]
        }
        func decode(result: [String: Any], action: [String: Any]? = nil) throws -> AnalysisJobWire {
            let response = diagnosisJob(id: jobId, status: "succeeded", result: try syncJSON(result),
                                        target: (serverPlantId, photo))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            object["first_aid_action"] = action
            let wire = try JSONDecoder().decode(AnalysisJobWire.self, from: Data(syncJSON(object).utf8))
            try wire.validate(mode: .diagnosis, jobId: jobId, targetPlantId: serverPlantId, photoAssetId: photo)
            return wire
        }
        let eligible = advisory(job: jobId, plant: serverPlantId)
        XCTAssertEqual(try decode(result: result, action: eligible).recordableFirstAid,
                       try firstAidEligibility(jobId: jobId, plantId: serverPlantId))
        XCTAssertNil(try decode(result: result).recordableFirstAid)
        XCTAssertNil(try decode(result: result, action: advisory(job: jobId, plant: UUID())).recordableFirstAid)
        XCTAssertNil(try decode(result: result, action: advisory(job: UUID(), plant: serverPlantId)).recordableFirstAid)
        var unknown = result
        unknown["identification_status"] = "unknown"
        unknown["diagnosis_status"] = "insufficient_data"
        unknown["selected_condition_id"] = NSNull()
        unknown["plan_availability"] = "diagnosis_unresolved"
        XCTAssertNil(try decode(result: unknown, action: eligible).recordableFirstAid)
    }

    @MainActor
    func testFirstAidRecordReopensAndReplaysUntilExactFactIsInJournal() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let action = try firstAidEligibility(jobId: UUID(), plantId: serverPlantId)
        let target = RepeatDiagnosisTarget(plantId: serverPlantId, ownerId: syncOwner)
        let entry = UUID(), newer = "2026-11-03T09:10:00.000001+00:00"
        var plant = syncChange(id: serverPlantId.uuidString)
        plant["data"] = ["id": serverPlantId.uuidString, "plant_id": "monstera_deliciosa",
                         "revision": 1, "care_revision": 1] as [String: Any]
        var baseline = syncObject()
        baseline["changes"] = [plant]
        let original: URLRequest
        let command: FirstAidRecordCommand
        do {
            let transport = CatalogueTransport([.http(200, try syncJSON(baseline)), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            _ = try await repo.collectionCards(context: lease)
            command = try await repo.enqueueFirstAidRecord(action, target: target, context: lease)
            let same = try await repo.enqueueFirstAidRecord(action, target: target, context: lease)
            XCTAssertEqual(same.envelope, command.envelope)
            let outcome = try await repo.retryFirstAidRecord(command, context: lease)
            guard case .pending = outcome else { return XCTFail("Lost response must leave the command pending") }
            let requests = await transport.capturedRequests()
            original = try XCTUnwrap(requests.last)
        }

        var receipt = manualWateringReceipt(entryId: entry, state: "active")
        receipt["control_id"] = NSNull()
        receipt["watermark"] = newer
        var fact = syncChange(newer, id: entry.uuidString, entity: "care_entries")
        fact["data"] = ["id": entry.uuidString, "plant_id": serverPlantId.uuidString,
                        "state": "active", "action_code": "check_soil", "timezone": "Europe/Moscow",
                        "operation_id": command.envelope.operationId.uuidString,
                        "occurred_at": newer, "occurred_local_date": "2026-11-03"]
        var delta = syncObject()
        delta["until"] = newer
        delta["next_since"] = newer
        delta["changes"] = [fact]
        let transport = CatalogueTransport([
            .http(200, try syncJSON(receipt)), .http(200, try syncJSON(syncObject())),
            .http(200, try syncJSON(receipt)), .http(200, try syncJSON(delta)),
            .http(409, #"{"error":{"code":"CONFLICT","message":"Already recorded","retryable":false}}"#)
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        let queued = try await repo.pendingFirstAidRecord(plantId: serverPlantId, context: lease)
        let restored = try XCTUnwrap(queued)
        XCTAssertEqual(restored.envelope, command.envelope)
        guard case .pending = try await repo.retryFirstAidRecord(restored, context: lease) else {
            return XCTFail("Receipt alone cannot confirm a fact")
        }
        let missing = try await repo.collectionFirstAidHistory(plantId: serverPlantId, context: lease)
        XCTAssertTrue(missing.isEmpty)
        guard case .confirmed = try await repo.retryFirstAidRecord(restored, context: lease) else {
            return XCTFail("Expected the exact canonical fact")
        }
        let pending = try await repo.pendingFirstAidRecord(plantId: serverPlantId, context: lease)
        XCTAssertNil(pending)
        let conflict = try await repo.enqueueFirstAidRecord(action, target: target, context: lease)
        guard case .rejected = try await repo.retryFirstAidRecord(conflict, context: lease) else {
            return XCTFail("A definitive conflict must not remain in the queue")
        }
        let afterConflict = try await repo.pendingFirstAidRecord(plantId: serverPlantId, context: lease)
        XCTAssertNil(afterConflict)
        let history = try await repo.collectionFirstAidHistory(plantId: serverPlantId, context: lease)
        XCTAssertEqual(history.map(\.id), [entry])
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "POST", "GET", "POST"])
        for request in requests.prefix(4) where request.httpMethod == "POST" {
            XCTAssertEqual(request.httpBody, original.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"),
                           command.envelope.operationId.uuidString.lowercased())
        }
    }

    @MainActor
    func testFirstAidUndoReplaysUntilExactReversalAndControlUpdate() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let entry = UUID(), control = UUID(), reversal = UUID()
        let otherEntry = UUID(), otherControl = UUID()
        let voidedAt = "2026-11-03T09:10:00.000001+00:00"
        let controlUpdatedAt = "2026-11-03T09:10:00.000002+00:00"

        func fact(_ id: UUID, state: String, timestamp: String) -> [String: Any] {
            var row = syncChange(timestamp, id: id.uuidString, entity: "care_entries")
            row["data"] = ["id": id.uuidString, "plant_id": serverPlantId.uuidString, "action_code": "check_soil",
                           "state": state, "occurred_at": syncUntil, "occurred_local_date": "2026-11-03"]
            return row
        }
        func followup(_ id: UUID, entry: UUID, state: String, timestamp: String) -> [String: Any] {
            var row = syncChange(timestamp, id: id.uuidString, entity: "first_aid_followups")
            row["data"] = [
                "id": id.uuidString, "plant_id": serverPlantId.uuidString,
                "action_entry_id": entry.uuidString, "action_code": "check_soil", "state": state,
                "check_policy_snapshot": ["due_on": "2026-11-08", "interval_days": 5,
                                          "source": ["url": "https://example.invalid/interval", "locator": "Fixture"]]
            ] as [String: Any]
            return row
        }
        func page(_ until: String, _ changes: [[String: Any]]) -> [String: Any] {
            var result = syncObject()
            result["until"] = until
            result["next_since"] = until
            result["changes"] = changes.sorted {
                ($0["entity_type"] as! String, $0["id"] as! String) < ($1["entity_type"] as! String, $1["id"] as! String)
            }
            return result
        }
        var plant = syncChange(id: serverPlantId.uuidString)
        plant["data"] = ["id": serverPlantId.uuidString, "plant_id": "monstera_deliciosa",
                         "revision": 1, "care_revision": 1] as [String: Any]
        let baseline = page(syncUntil, [
            plant, fact(entry, state: "active", timestamp: syncUntil),
            fact(otherEntry, state: "active", timestamp: syncUntil),
            followup(control, entry: entry, state: "active", timestamp: syncUntil),
            followup(otherControl, entry: otherEntry, state: "active", timestamp: syncUntil)
        ])
        let command: CommandEnvelopeDTO
        let original: URLRequest
        do {
            let transport = CatalogueTransport([.http(200, try syncJSON(baseline)), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            _ = try await repo.collectionCards(context: lease)
            do {
                _ = try await repo.enqueueFirstAidUndo(plantId: UUID(), entryId: entry, context: lease)
                XCTFail("An undo must target the same plant as the entry")
            } catch SyncWireValidationError.invalidPage {}
            command = try await repo.enqueueFirstAidUndo(plantId: serverPlantId, entryId: entry, context: lease)
            let same = try await repo.enqueueFirstAidUndo(plantId: serverPlantId, entryId: entry, context: lease)
            XCTAssertEqual(same, command)
            let watering = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
            XCTAssertNil(watering)
            guard case .pending = try await repo.retryFirstAidUndo(command, context: lease) else {
                return XCTFail("An interrupted undo must stay pending")
            }
            let history = try await repo.collectionFirstAidHistory(plantId: serverPlantId, context: lease)
            XCTAssertEqual(history.first(where: { $0.id == entry })?.state, "active")
            let snapshot = try await repo.collectionFirstAidControls(plantId: serverPlantId, context: lease)
            XCTAssertEqual(Set(snapshot?.controls.map(\.id) ?? []), [control, otherControl])
            let requests = await transport.capturedRequests()
            original = try XCTUnwrap(requests.last)
        }
        var receipt = manualWateringReceipt(entryId: entry, state: "voided", reversalId: reversal)
        receipt["watermark"] = voidedAt
        let wrongReceipt = manualWateringReceipt(entryId: otherEntry, state: "voided", reversalId: reversal)
        var reversalChange = syncChange(voidedAt, id: reversal.uuidString, entity: "care_reversals")
        reversalChange["data"] = ["id": reversal.uuidString, "entry_id": entry.uuidString,
                                  "operation_id": command.operationId.uuidString, "recorded_at": voidedAt]
        let missingControlUpdate = page(voidedAt, [fact(entry, state: "voided", timestamp: voidedAt), reversalChange])
        let complete = page(controlUpdatedAt, [followup(control, entry: entry, state: "undone", timestamp: controlUpdatedAt)])
        let transport = CatalogueTransport([
            .http(200, try syncJSON(wrongReceipt)),
            .http(200, try syncJSON(receipt)), .http(200, try syncJSON(missingControlUpdate)),
            .http(200, try syncJSON(receipt)), .http(200, try syncJSON(complete))
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        let reopened = try await repo.pendingFirstAidUndo(plantId: serverPlantId, context: lease)
        XCTAssertEqual(reopened, command)
        for _ in 0..<2 {
            guard case .pending = try await repo.retryFirstAidUndo(command, context: lease) else {
                return XCTFail("Undo acknowledged against another entry or an active linked control")
            }
        }
        guard case .confirmed = try await repo.retryFirstAidUndo(command, context: lease) else {
            return XCTFail("Expected confirmation of the exact canonical undo")
        }
        let pending = try await repo.pendingFirstAidUndo(plantId: serverPlantId, context: lease)
        XCTAssertNil(pending)
        let history = try await repo.collectionFirstAidHistory(plantId: serverPlantId, context: lease)
        XCTAssertEqual(history.first(where: { $0.id == entry })?.state, "voided")
        XCTAssertEqual(history.first(where: { $0.id == otherEntry })?.state, "active")
        let snapshot = try await repo.collectionFirstAidControls(plantId: serverPlantId, context: lease)
        XCTAssertEqual(snapshot?.controls.map(\.id), [otherControl])
        let envelope = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(original.httpBody))
        XCTAssertEqual(envelope.commandName, "care.undo")
        XCTAssertEqual(envelope.plantId, serverPlantId)
        XCTAssertEqual(ManualWateringAction(envelope: envelope), .undo(entry))
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "GET", "POST", "GET"])
        for request in requests where request.httpMethod == "POST" {
            XCTAssertEqual(request.httpBody, original.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), command.operationId.uuidString.lowercased())
        }
    }

    @MainActor
    func testFirstAidObservationReplaysUntilControlAndLinkedObservationAreSynced() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let entry = UUID(), control = UUID(), observation = UUID(), stale = UUID()
        let completionTime = "2026-11-03T09:10:00.000001+00:00"
        let observationTime = "2026-11-03T09:10:00.000002+00:00"
        let entitlement: [String: Any] = [
            "product_id": "fixture-trial", "state": "active", "offer_kind": "trial",
            "valid_until": "2026-11-04T09:00:00Z", "grace_until": NSNull(),
            "trial_end_at": "2026-11-04T09:00:00Z", "auto_renew_enabled": true
        ]
        func row(_ type: String, _ id: UUID, time: String = "", data: [String: Any]) -> [String: Any] {
            var change = syncChange(time.isEmpty ? syncUntil : time, id: id.uuidString, entity: type)
            change["data"] = data.merging(["id": id.uuidString, "plant_id": serverPlantId.uuidString]) { old, _ in old }
            return change
        }
        func followup(_ id: UUID, state: String = "active", revision: Int = 1, time: String = "") -> [String: Any] {
            row("first_aid_followups", id, time: time, data: [
                "state": state, "action_code": "check_soil", "action_entry_id": entry.uuidString,
                "context_revision": revision, "control_task_id": NSNull(),
                "check_policy_snapshot": ["due_on": "2026-11-08", "interval_days": 5,
                                          "source": ["url": "https://example.invalid/interval", "locator": "Fixture"]]
            ])
        }
        func page(_ until: String, _ changes: [[String: Any]]) throws -> String {
            var result = syncObject()
            result["until"] = until
            result["next_since"] = until
            result["entitlement"] = entitlement
            result["changes"] = changes.sorted {
                ($0["entity_type"] as! String, $0["id"] as! String) < ($1["entity_type"] as! String, $1["id"] as! String)
            }
            return try syncJSON(result)
        }
        let baseline = try page(syncUntil, [
            row("plants", serverPlantId, data: ["plant_id": "monstera_deliciosa", "revision": 1, "care_revision": 1]),
            row("care_entries", entry, data: ["action_code": "check_soil", "state": "active",
                                              "occurred_at": syncUntil, "occurred_local_date": "2026-11-03"]),
            followup(control), followup(stale, revision: 2)
        ])
        let now = try XCTUnwrap(SQLTimestamp.date(from: syncUntil))
        let command: FirstAidObservationCommand
        let original: URLRequest
        do {
            let transport = CatalogueTransport([.http(200, baseline), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api),
                                            clock: { now })
            _ = try await repo.collectionCards(context: lease)
            for (plant, candidate) in [(UUID(), control), (serverPlantId, stale)] {
                do {
                    _ = try await repo.enqueueFirstAidObservation(plantId: plant, controlId: candidate, status: .improved, context: lease)
                    XCTFail("Accepted a foreign or stale control")
                } catch SyncWireValidationError.invalidPage {}
            }
            command = try await repo.enqueueFirstAidObservation(
                plantId: serverPlantId, controlId: control, status: .improved, context: lease
            )
            let duplicate = try await repo.enqueueFirstAidObservation(
                plantId: serverPlantId, controlId: control, status: .improved, context: lease
            )
            XCTAssertEqual(duplicate.envelope, command.envelope)
            guard case .pending = try await repo.retryFirstAidObservation(command, context: lease) else {
                return XCTFail("Lost response must retain the observation")
            }
            let history = try await repo.collectionFirstAidControls(plantId: serverPlantId, context: lease)
            XCTAssertEqual(history?.observations.count, 0)
            XCTAssertTrue(history?.controls.contains(where: { $0.id == control }) == true)
            let requests = await transport.capturedRequests()
            original = try XCTUnwrap(requests.last)
        }
        let receipt = ["plant_id": serverPlantId.uuidString, "control_id": control.uuidString,
                       "observation_id": observation.uuidString, "state": "completed", "watermark": completionTime]
        var mismatch = receipt
        mismatch["control_id"] = stale.uuidString
        let completed = try page(completionTime, [followup(control, state: "completed", time: completionTime)])
        let linked = try page(observationTime, [
            row("care_observations", observation, time: observationTime, data: [
                "first_aid_control_id": control.uuidString, "status_code": "improved",
                "operation_id": command.envelope.operationId.uuidString, "observed_at": observationTime
            ]),
            row("care_observations", UUID(), time: observationTime, data: [
                "status_code": "worse", "operation_id": UUID().uuidString, "observed_at": observationTime
            ])
        ])
        let transport = CatalogueTransport([
            .http(200, try syncJSON(mismatch)),
            .http(200, try syncJSON(receipt)), .http(200, completed),
            .http(200, try syncJSON(receipt)), .http(200, linked)
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api),
                                        clock: { .distantFuture })
        let restored = try await repo.pendingFirstAidObservation(plantId: serverPlantId, context: lease)
        XCTAssertEqual(restored?.envelope, command.envelope)
        for _ in 0..<2 {
            guard case .pending = try await repo.retryFirstAidObservation(command, context: lease) else {
                return XCTFail("Receipt mismatch or missing observation must retain the queued write")
            }
        }
        guard case .confirmed = try await repo.retryFirstAidObservation(command, context: lease) else {
            return XCTFail("Expired access must still allow exact replay and canonical history")
        }
        let pending = try await repo.pendingFirstAidObservation(plantId: serverPlantId, context: lease)
        XCTAssertNil(pending)
        let activeRepo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api),
                                              clock: { now })
        let activeHistory = try await activeRepo.collectionFirstAidControls(plantId: serverPlantId, context: lease)
        XCTAssertEqual(activeHistory?.controls.map(\.id), [stale])
        do {
            _ = try await activeRepo.enqueueFirstAidObservation(
                plantId: serverPlantId, controlId: control, status: .worse, context: lease
            )
            XCTFail("Completed control must reject a new observation")
        } catch SyncWireValidationError.invalidPage {}
        let history = try await repo.collectionFirstAidControls(plantId: serverPlantId, context: lease)
        XCTAssertEqual(history?.controls.count, 0)
        XCTAssertEqual(history?.observations.map(\.id), [observation])
        XCTAssertEqual(history?.observations.first?.controlId, control)
        XCTAssertEqual(history?.observations.first?.status, .improved)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "GET", "POST", "GET"])
        for request in requests where request.httpMethod == "POST" {
            XCTAssertEqual(request.httpBody, original.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), command.envelope.operationId.uuidString.lowercased())
        }
        let payload = try JSONDecoder().decode([String: String].self, from: Data(command.envelope.payloadJSON.utf8))
        XCTAssertEqual(payload, ["control_id": control.uuidString.lowercased(), "status_code": "improved"])
    }

    @MainActor
    func testFirstAidPhotoUploadAndAttachedObservationResumeAcrossRestarts() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let entry = UUID(), control = UUID(), asset = UUID(), observation = UUID()
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let completedAt = "2026-11-03T09:10:00.000001+00:00"
        let assetAt = "2026-11-03T09:10:00.000002+00:00"
        func row(_ type: String, _ id: UUID, at time: String, data: [String: Any]) -> [String: Any] {
            var change = syncChange(time, id: id.uuidString, entity: type)
            change["data"] = data.merging(["id": id.uuidString, "plant_id": serverPlantId.uuidString]) { old, _ in old }
            return change
        }
        func followup(state: String, at time: String) -> [String: Any] {
            row("first_aid_followups", control, at: time, data: [
                "state": state, "action_code": "check_soil", "action_entry_id": entry.uuidString, "context_revision": 1,
                "check_policy_snapshot": ["due_on": "2026-11-08", "interval_days": 5,
                                          "source": ["url": "https://example.invalid/interval", "locator": "Fixture"]]
            ])
        }
        func page(_ until: String, _ changes: [[String: Any]]) throws -> String {
            var result = syncObject()
            result["until"] = until
            result["next_since"] = until
            result["changes"] = changes.sorted { ($0["entity_type"] as! String) < ($1["entity_type"] as! String) }
            return try syncJSON(result)
        }
        let baseline = try page(syncUntil, [
            row("plants", serverPlantId, at: syncUntil, data: ["plant_id": "monstera_deliciosa", "revision": 1, "care_revision": 1]),
            row("care_entries", entry, at: syncUntil, data: ["action_code": "check_soil", "state": "active",
                                                            "occurred_at": syncUntil, "occurred_local_date": "2026-11-03"]),
            followup(state: "active", at: syncUntil)
        ])
        let media = "/functions/v1/plants-api/media/first-aid"
        let assetPath = media + "/uploads/" + asset.uuidString.lowercased()
        let uploadTicket: [String: Any] = [
            "photo_asset_id": asset.uuidString, "storage_bucket": "analysis-inputs", "storage_path": "private-test",
            "signed_upload_url": "https://example.invalid" + assetPath + "?sig=fixture",
            "expires_in_seconds": 60, "max_byte_size": 10 * 1024 * 1024
        ]
        var badTicket = uploadTicket
        badTicket["signed_upload_url"] = "https://wrong.invalid" + assetPath
        let draft: FirstAidObservationPhotoDraft
        do {
            let transport = CatalogueTransport([.http(200, baseline), .http(200, try syncJSON(badTicket)),
                                               .http(200, try syncJSON(uploadTicket)), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            _ = try await repo.collectionCards(context: lease)
            let discarded = try await repo.enqueueFirstAidPhotoDraft(
                plantId: serverPlantId, controlId: control, status: .improved, jpeg: jpeg, context: lease
            )
            try await repo.discardFirstAidPhotoDraft(discarded, context: lease)
            draft = try await repo.enqueueFirstAidPhotoDraft(
                plantId: serverPlantId, controlId: control, status: .improved, jpeg: jpeg, context: lease
            )
            XCTAssertNotEqual(draft.envelope.operationId, draft.uploadOperationId)
            for _ in 0..<2 {
                guard case .pending = try await repo.retryFirstAidPhotoDraft(draft, context: lease) else {
                    return XCTFail("Unsafe ticket or lost upload response must retain the original draft")
                }
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map { $0.url?.path }, ["/functions/v1/plants-api/sync",
                                                           media + "/upload-ticket", media + "/upload-ticket", assetPath])
            XCTAssertEqual(requests[1].httpBody, requests[2].httpBody)
            let ticketBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].httpBody)) as? [String: Any])
            XCTAssertEqual(ticketBody["operation_id"] as? String, draft.uploadOperationId.uuidString.lowercased())
            XCTAssertEqual(ticketBody["plant_id"] as? String, serverPlantId.uuidString.lowercased())
            XCTAssertEqual(ticketBody["control_id"] as? String, control.uuidString.lowercased())
            XCTAssertEqual(ticketBody["byte_size"] as? Int, jpeg.count)
            XCTAssertEqual(requests.last?.httpBody, jpeg)
            XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        }
        let firstPOST: URLRequest
        let ready = try syncJSON(["photo_asset_id": asset.uuidString, "state": "ready"])
        do {
            let transport = CatalogueTransport([.http(200, ready), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            let restored = try await repo.pendingFirstAidPhotoDraft(plantId: serverPlantId, context: lease)
            XCTAssertEqual(restored?.envelope, draft.envelope)
            guard case .pending = try await repo.retryFirstAidPhotoDraft(draft, context: lease) else {
                return XCTFail("Lost observation response must preserve the promoted command")
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map { $0.url?.path }, [media + "/complete", "/functions/v1/plants-api/commands"])
            let confirm = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests.first?.httpBody))
            XCTAssertEqual(confirm, ["photo_asset_id": asset.uuidString.lowercased()])
            firstPOST = try XCTUnwrap(requests.last)
        }
        let receipt = try syncJSON(["plant_id": serverPlantId.uuidString, "control_id": control.uuidString,
                                    "observation_id": observation.uuidString, "state": "completed", "watermark": completedAt])
        let noAsset = try page(completedAt, [
            followup(state: "completed", at: completedAt),
            row("care_observations", observation, at: completedAt, data: [
                "first_aid_control_id": control.uuidString, "status_code": "improved",
                "operation_id": draft.envelope.operationId.uuidString, "observed_at": completedAt, "photo_id": asset.uuidString
            ])
        ])
        let withAsset = try page(assetAt, [row("photo_assets", asset, at: assetAt, data: ["state": "ready", "purpose": "diary"])])
        let transport = CatalogueTransport([
            .http(200, receipt), .http(200, noAsset), .http(200, receipt), .http(200, withAsset), .photo(jpeg, mime: "image/jpeg")
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        let pending = try await repo.pendingFirstAidObservation(plantId: serverPlantId, context: lease)
        let command = try XCTUnwrap(pending)
        XCTAssertEqual(command.envelope.operationId, draft.envelope.operationId)
        XCTAssertEqual(command.photoId, asset)
        guard case .pending = try await repo.retryFirstAidObservation(command, context: lease),
              case .confirmed = try await repo.retryFirstAidObservation(command, context: lease) else {
            return XCTFail("Acknowledgement must wait for the linked ready asset")
        }
        let history = try await repo.collectionFirstAidControls(plantId: serverPlantId, context: lease)
        XCTAssertEqual(history?.observations.map(\.id), [observation])
        XCTAssertEqual(history?.observations.first?.photoId, asset)
        let bytes = try await api.fetchObservationPhoto(observationId: observation, context: lease)
        XCTAssertEqual(bytes, jpeg)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "POST", "GET", "GET"])
        for request in requests where request.httpMethod == "POST" {
            XCTAssertEqual(request.httpBody, firstPOST.httpBody)
        }
        XCTAssertEqual(requests.last?.url?.path, "/functions/v1/plants-api/care/observations/\(observation.uuidString.lowercased())/photo")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(syncSession.accessToken)")
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "X-Installation-Credential"))
        XCTAssertEqual(requests.last?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    @MainActor
    func testFirstAidPhotoReusesBytesAfterExpiryAndCleanupWithoutRewritingAcceptedObserve() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let entry = UUID(), control = UUID(), expiredAsset = UUID(), removedAsset = UUID(), readyAsset = UUID()
        let observation = UUID(), jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let later = "2026-11-03T09:10:00.000001+00:00"
        let completed = "2026-11-03T09:10:00.000002+00:00"
        let apiPath = "/functions/v1/plants-api"
        let media = apiPath + "/media/first-aid"
        let incomplete = #"{"error":{"code":"CONFLICT","message":"Photo upload is incomplete.","retryable":true}}"#
        let conflict = #"{"error":{"code":"CONFLICT","message":"The first-aid control is unavailable or the operation conflicts with an existing receipt.","retryable":false}}"#
        let missing = #"{"error":{"code":"NOT_FOUND","message":"Photo not found.","retryable":false}}"#

        func row(_ type: String, _ id: UUID, at time: String, data: [String: Any]) -> [String: Any] {
            var change = syncChange(time, id: id.uuidString, entity: type)
            change["data"] = data.merging(["id": id.uuidString, "plant_id": serverPlantId.uuidString]) { old, _ in old }
            return change
        }
        func followup(_ state: String, at time: String) -> [String: Any] {
            row("first_aid_followups", control, at: time, data: [
                "state": state, "action_code": "check_soil", "action_entry_id": entry.uuidString, "context_revision": 1,
                "check_policy_snapshot": ["due_on": "2026-11-08", "interval_days": 5,
                                          "source": ["url": "https://example.invalid/interval", "locator": "Fixture"]]
            ])
        }
        func page(_ until: String, _ changes: [[String: Any]]) throws -> String {
            var result = syncObject()
            result["until"] = until
            result["next_since"] = until
            result["changes"] = changes.sorted { ($0["entity_type"] as! String) < ($1["entity_type"] as! String) }
            return try syncJSON(result)
        }
        func ticket(_ asset: UUID) throws -> String {
            try syncJSON(["photo_asset_id": asset.uuidString, "storage_bucket": "analysis-inputs", "storage_path": "private-test",
                          "signed_upload_url": "https://example.invalid" + media + "/uploads/" + asset.uuidString.lowercased() + "?sig=fixture",
                          "expires_in_seconds": 60, "max_byte_size": 10 * 1024 * 1024])
        }
        func ready(_ asset: UUID) throws -> String {
            try syncJSON(["photo_asset_id": asset.uuidString, "state": "ready"])
        }
        func reopened(
            _ replies: [CatalogueTransport.Reply],
            run: (CollectionRepository, SyncSessionLease) async throws -> Void
        ) async throws -> [URLRequest] {
            let transport = CatalogueTransport(replies)
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            try await run(repo, lease)
            return await transport.capturedRequests()
        }
        let baseline = try page(syncUntil, [
            row("plants", serverPlantId, at: syncUntil, data: ["plant_id": "monstera_deliciosa", "revision": 1, "care_revision": 1]),
            row("care_entries", entry, at: syncUntil, data: ["action_code": "check_soil", "state": "active",
                                                            "occurred_at": syncUntil, "occurred_local_date": "2026-11-03"]),
            followup("active", at: syncUntil)
        ])
        var queued: FirstAidObservationPhotoDraft?
        let first = try await reopened([.http(200, baseline), .http(200, try ticket(expiredAsset)), .network]) { repo, lease in
            _ = try await repo.collectionCards(context: lease)
            let draft = try await repo.enqueueFirstAidPhotoDraft(
                plantId: serverPlantId, controlId: control, status: .improved, jpeg: jpeg, context: lease
            )
            queued = draft
            guard case .pending = try await repo.retryFirstAidPhotoDraft(draft, context: lease)
            else { return XCTFail("Ambiguous PUT must keep the same draft") }
        }
        let original = try XCTUnwrap(queued)
        let renewed = try await reopened([
            .http(409, incomplete), .http(409, incomplete), .http(200, try ticket(removedAsset)),
            .http(200, try ready(removedAsset)), .network
        ]) { repo, lease in
            let stored = try await repo.pendingFirstAidPhotoDraft(plantId: serverPlantId, context: lease)
            XCTAssertEqual(stored?.envelope, original.envelope)
            guard case .pending = try await repo.retryFirstAidPhotoDraft(original, context: lease)
            else { return XCTFail("Expired upload must progress to a replayable observe") }
        }
        XCTAssertEqual(renewed.map { $0.url?.path }, [
            media + "/complete", media + "/upload-ticket", media + "/upload-ticket",
            media + "/uploads/" + removedAsset.uuidString.lowercased(), apiPath + "/commands"
        ])
        XCTAssertEqual(first[1].httpBody, renewed[1].httpBody)
        XCTAssertEqual(renewed[3].httpBody, jpeg)
        let firstObserve = try XCTUnwrap(renewed.last?.httpBody)
        var replacement: FirstAidObservationPhotoDraft?
        let rejected = try await reopened([
            .http(409, conflict), .network, .http(404, missing), .http(200, try page(later, [])), .http(404, missing)
        ]) { repo, lease in
            let pending = try await repo.pendingFirstAidObservation(plantId: serverPlantId, context: lease)
            let command = try XCTUnwrap(pending)
            XCTAssertEqual(command.envelope.operationId, original.envelope.operationId)
            XCTAssertEqual(command.photoId, removedAsset)
            guard case .pending = try await repo.retryFirstAidObservation(command, context: lease)
            else { return XCTFail("An inconclusive sync must keep the exact observe") }
            let unchanged = try await repo.pendingFirstAidObservation(plantId: serverPlantId, context: lease)
            XCTAssertEqual(unchanged?.envelope, command.envelope)
            guard case .pending = try await repo.retryFirstAidObservation(command, context: lease)
            else { return XCTFail("A rejected observe with a missing photo must recover the draft") }
            replacement = try await repo.pendingFirstAidPhotoDraft(plantId: serverPlantId, context: lease)
        }
        XCTAssertEqual(rejected.map { $0.url?.path }, [
            apiPath + "/commands", apiPath + "/sync", apiPath + "/commands", apiPath + "/sync", media + "/complete"
        ])
        XCTAssertEqual(rejected[0].httpBody, firstObserve)
        XCTAssertEqual(rejected[2].httpBody, firstObserve)
        let draft = try XCTUnwrap(replacement)
        XCTAssertNotEqual(draft.envelope.operationId, original.envelope.operationId)
        let retried = try await reopened([.http(200, try ticket(readyAsset)), .http(200, try ready(readyAsset)), .network]) { repo, lease in
            guard case .pending = try await repo.retryFirstAidPhotoDraft(draft, context: lease)
            else { return XCTFail("Lost response must keep the new observe") }
        }
        XCTAssertEqual(retried[1].httpBody, jpeg)
        var ticketOperations = Set<String>()
        var contentHashes = Set<String>()
        for request in [first[1], renewed[2], retried[0]] {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            ticketOperations.insert(try XCTUnwrap(body["operation_id"] as? String))
            contentHashes.insert(try XCTUnwrap(body["content_sha256"] as? String))
            XCTAssertEqual(body["byte_size"] as? Int, jpeg.count)
            XCTAssertEqual(body["control_id"] as? String, control.uuidString.lowercased())
        }
        XCTAssertEqual(ticketOperations.count, 3)
        XCTAssertEqual(contentHashes.count, 1)
        let receipt = try syncJSON(["plant_id": serverPlantId.uuidString, "control_id": control.uuidString,
                                    "observation_id": observation.uuidString, "state": "completed", "watermark": completed])
        let sync = try page(completed, [
            followup("completed", at: completed),
            row("care_observations", observation, at: completed, data: [
                "first_aid_control_id": control.uuidString, "status_code": "improved",
                "operation_id": draft.envelope.operationId.uuidString, "observed_at": completed, "photo_id": readyAsset.uuidString
            ]),
            row("photo_assets", readyAsset, at: completed, data: ["state": "ready", "purpose": "diary"])
        ])
        let replay = try await reopened([.http(200, receipt), .http(200, sync)]) { repo, lease in
            let pending = try await repo.pendingFirstAidObservation(plantId: serverPlantId, context: lease)
            let command = try XCTUnwrap(pending)
            XCTAssertEqual(command.envelope.operationId, draft.envelope.operationId)
            XCTAssertEqual(command.photoId, readyAsset)
            guard case .confirmed = try await repo.retryFirstAidObservation(command, context: lease)
            else { return XCTFail("Accepted observe must replay without an upload") }
            let history = try await repo.collectionFirstAidControls(plantId: serverPlantId, context: lease)
            XCTAssertEqual(history?.observations.map(\.id), [observation])
        }
        XCTAssertEqual(replay.map { $0.url?.path }, [apiPath + "/commands", apiPath + "/sync"])
        XCTAssertEqual(replay.first?.httpBody, retried.last?.httpBody)
    }

    private func identificationJob(id: UUID, status: String, quota: String, result: String = "null") -> String {
        #"{"job_id":"\#(id.uuidString)","mode":"identification","status":"\#(status)","quota_kind":"starter_identification","quota_state":"\#(quota)","result":\#(result),"error_code":null,"error_message":null}"#
    }

    private func identificationResult(
        jobId: UUID, releaseId: UUID, plantId: UUID?, name: String? = nil
    ) throws -> String {
        try syncJSON([
            "schema_version": "1.0", "mode": "identification", "job_id": jobId.uuidString,
            "catalogue_release_id": releaseId.uuidString, "identification_status": plantId == nil ? "unknown" : "identified",
            "plant_id": plantId.map { $0.uuidString as Any } ?? NSNull(),
            "plant_display_name": name.map { $0 as Any } ?? NSNull()
        ])
    }

    func testIdentificationWireRejectsWrongIdentityShapeAndQuota() async throws {
        let release = UUID()
        let unknown = try identificationResult(jobId: operationId, releaseId: release, plantId: nil)
        let identified = try identificationResult(
            jobId: operationId, releaseId: release, plantId: serverPlantId, name: "Swiss cheese plant"
        )
        let mismatched = try identificationResult(jobId: UUID(), releaseId: release, plantId: nil)
        let falseUnknown = try identificationResult(jobId: operationId, releaseId: release, plantId: nil, name: "Wrong")
        let nameless = try identificationResult(jobId: operationId, releaseId: release, plantId: serverPlantId)
        let invalid: [(result: String, quota: String)] = [
            (mismatched, "released"), (falseUnknown, "released"), (nameless, "consumed"),
            (unknown, "consumed"), (identified, "released"),
            (unknown.replacingOccurrences(of: "1.0", with: "2.0"), "released"),
            (identified.replacingOccurrences(of: serverPlantId.uuidString, with: "monstera_deliciosa"), "consumed")
        ]
        let transport = CatalogueTransport([
            .http(200, identificationJob(id: operationId, status: "succeeded", quota: "released", result: unknown)),
            .http(200, identificationJob(id: operationId, status: "succeeded", quota: "consumed", result: identified))
        ] + invalid.map {
            .http(200, identificationJob(id: operationId, status: "succeeded", quota: $0.quota, result: $0.result))
        })
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let lease = try await api.captureSyncContext(ownerId: accessOwner)
        let unresolved = try await api.fetchAnalysisJob(id: operationId, mode: .identification, locale: .en, context: lease)
        XCTAssertEqual(unresolved.identificationResult?.catalogueReleaseId, release)
        XCTAssertNil(unresolved.identificationResult?.plant)
        XCTAssertNil(unresolved.result)
        let resolved = try await api.fetchAnalysisJob(id: operationId, mode: .identification, locale: .en, context: lease)
        XCTAssertEqual(resolved.identificationResult?.plant?.taxonId, serverPlantId)
        for _ in invalid {
            do {
                _ = try await api.fetchAnalysisJob(id: operationId, mode: .identification, locale: .en, context: lease)
                XCTFail("Invalid identification reached the caller")
            } catch AnalysisHTTPError.invalidResponse {
            } catch is DecodingError {}
        }
    }

    func testGuestDiagnosisDraftShapeAndInvalidSessionsFailBeforeHTTP() async throws {
        let guest = try profileSession(claims: ["sub": syncOwner.uuidString, "is_anonymous": true])
        let transport = CatalogueTransport([
            .http(201, try syncJSON(["draft_id": UUID().uuidString, "expires_at": syncUntil]))
        ])
        let api = client(transport)
        await api.bindSyncSession(guest)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        _ = try await api.createDiagnosisPhotoDraft(
            operationId: operationId, jobId: serverPlantId, credential: "fixture-installation", context: lease
        )
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body, ["operation_id": operationId.uuidString.lowercased(),
                              "diagnosis_job_id": serverPlantId.uuidString.lowercased()])
        XCTAssertEqual(request.url?.lastPathComponent, "drafts")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(guest.accessToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Installation-Credential"), "fixture-installation")
        let invalidSessions = [
            syncSession,
            try profileSession(),
            try profileSession(claims: ["sub": otherSyncOwner.uuidString, "is_anonymous": true]),
            try profileSession(claims: ["sub": syncOwner.uuidString]),
            try profileSession(claims: ["sub": syncOwner.uuidString, "is_anonymous": "true"])
        ]
        for invalid in invalidSessions {
            await api.bindSyncSession(invalid)
            let invalidLease = try await api.captureSyncContext(ownerId: invalid.userId)
            do {
                _ = try await api.createDiagnosisPhotoDraft(
                    operationId: operationId, jobId: serverPlantId,
                    credential: "fixture-installation", context: invalidLease
                )
                XCTFail("Invalid guest claims must not create a diagnosis draft")
            } catch SyncWireValidationError.invalidSession {}
        }
        do {
            _ = try await api.createDiagnosisPhotoDraft(
                operationId: operationId, jobId: serverPlantId, credential: "fixture-installation", context: lease
            )
            XCTFail("A replaced guest lease must not create a draft")
        } catch SyncWireValidationError.invalidSession {}
        let after = await transport.capturedRequests()
        XCTAssertEqual(after.count, 1)
    }

    func testGuestPhotoClaimUsesSameInstallationAndRetriesExactCommit() async throws {
        let credential = "fixture-guest-installation"
        let installation = UUID(), draft = UUID(), proof = UUID(), photo = UUID()
        let guest = NativeAuthSession(userId: UUID(), accessToken: "fixture-guest-bearer", expiresAt: .distantFuture)
        let draftOp = UUID(), prepareOp = UUID(), commitOp = UUID()
        let transport = CatalogueTransport([
            .http(200, try syncJSON(["installation_id": installation.uuidString])),
            .http(201, try syncJSON(["draft_id": draft.uuidString, "expires_at": syncUntil])),
            .http(200, try syncJSON(["bound": true, "installation_id": installation.uuidString, "owner_id": accessOwner.uuidString])),
            .http(200, try syncJSON(["claim_id": proof.uuidString, "draft_id": draft.uuidString, "proof_expires_at": syncUntil])),
            .network,
            .http(200, try syncJSON(["plant_id": serverPlantId.uuidString, "photo_id": photo.uuidString]))
        ])
        let api = client(transport)
        await api.bindSyncSession(guest)
        let guestLease = try await api.captureSyncContext(ownerId: guest.userId)
        let registered = try await api.registerPhotoInstallation(credential: credential, context: guestLease)
        XCTAssertEqual(registered, installation)
        let created = try await api.createPhotoDraft(operationId: draftOp, jobId: operationId, taxonId: serverPlantId,
                                                     credential: credential, context: guestLease)
        XCTAssertEqual(created.draftId, draft)
        await api.bindSyncSession(accessSession)
        let permanent = try await api.captureSyncContext(ownerId: accessOwner)
        do {
            _ = try await api.preparePhotoClaim(operationId: prepareOp, draftId: draft,
                                               credential: credential, context: guestLease)
            XCTFail("An old guest lease must not reach claim prepare")
        } catch SyncWireValidationError.invalidSession {}
        try await api.bindPhotoInstallation(id: installation, credential: credential, context: permanent)
        let prepared = try await api.preparePhotoClaim(operationId: prepareOp, draftId: draft,
                                                       credential: credential, context: permanent)
        XCTAssertEqual(prepared.claimId, proof)
        do {
            _ = try await api.commitPhotoClaim(operationId: commitOp, claimId: proof, credential: credential, context: permanent)
            XCTFail("Expected lost response")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        let committed = try await api.commitPhotoClaim(operationId: commitOp, claimId: proof,
                                                       credential: credential, context: permanent)
        XCTAssertEqual(committed.plantId, serverPlantId)
        XCTAssertEqual(committed.photoId, photo)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map { $0.url?.path.components(separatedBy: "/plants-api/").last },
                       ["installations/register", "drafts", "installations/bind", "claims/prepare", "claims/commit", "claims/commit"])
        guard requests.count == 6 else { return }
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Installation-Credential") == credential })
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer \(guest.accessToken)")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer \(accessSession.accessToken)")
        XCTAssertEqual(requests[4].httpBody, requests[5].httpBody)
        let committedBody = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[5].httpBody))
        XCTAssertEqual(committedBody, ["operation_id": commitOp.uuidString.lowercased(), "claim_id": proof.uuidString.lowercased()])
        let nonRedirecting = await transport.nonRedirectingRequests
        XCTAssertEqual(nonRedirecting, 6)
    }

    @MainActor
    func testGuestDiagnosisRetriesBoundUploadAndStatusWithExactInitialContext() async throws {
        let owner = accessOwner
        let guest = try profileSession(ownerId: owner, claims: ["sub": owner.uuidString, "is_anonymous": true])
        let credential = "fixture-installation-credential"
        let photo = serverPlantId
        let jobId = UUID()
        let url = "https://example.invalid/functions/v1/plants-api/media/uploads/\(photo.uuidString.lowercased())?sig=mock"
        let ready = #"{"photo_asset_id":"\#(photo.uuidString)","state":"ready"}"#
        let result = #"{"analysis_id":"\#(UUID().uuidString)","job_id":"\#(jobId.uuidString)","kb_release_id":"\#(UUID().uuidString)","mode":"diagnosis","identification_status":"unknown","plant_id":null,"genus_id":null,"diagnosis_status":"insufficient_data","selected_condition_id":null,"candidates":[],"visual_markers":[],"evidence_basis":[],"limitations":["Photo too unclear."],"first_action_summary":null,"control_interval_days":null,"plan_availability":"diagnosis_unresolved","analysis_receipt":"test-receipt"}"#
        let transport = CatalogueTransport([
            .http(200, diagnosisTicket(url: url, photoId: photo)), .network,
            .http(200, ready), .http(202, diagnosisJob(id: jobId, status: "queued")),
            .network, .http(200, diagnosisJob(id: jobId, status: "succeeded", result: result))
        ])
        let api = client(transport)
        await api.bindSyncSession(guest)
        var currentOwner = owner
        let service = PhotoAnalysisService(api: api, guestCredential: credential) {
            try await api.captureSyncContext(ownerId: currentOwner)
        }
        let input = AnalysisServiceRequest(
            operationId: operationId, flowId: UUID(), mode: .diagnosis, intent: .problem,
            photo: PreparedAnalysisPhoto(
                cloudNormalizedJPEG: Data("abc".utf8), aiVisionJPEG: Data("abc".utf8),
                aiWidthPx: 1, aiHeightPx: 1, originalByteCount: 3
            ),
            conditions: CareConditionsInput(
                lightLevel: .brightDirect, lightConfirmed: true, wateringHabit: .sparse, drainage: .no
            ), locale: .en
        )
        for _ in 0..<2 {
            do {
                _ = try await service.analyze(input)
                XCTFail("Expected a disconnected upload or status response")
            } catch is URLError {}
        }
        let changed = AnalysisServiceRequest(
            operationId: input.operationId, flowId: input.flowId, mode: .diagnosis, intent: .problem,
            photo: input.photo, conditions: CareConditionsInput(), locale: .en
        )
        do {
            _ = try await service.analyze(changed)
            XCTFail("Retry must keep the original context")
        } catch AnalysisServiceFailure.unavailable {}
        let finished = try await service.analyze(input)
        XCTAssertEqual(finished.analysis?.jobId, jobId)
        XCTAssertEqual(finished.analysis?.diagnosisStatus, .unknown)
        XCTAssertNil(finished.identification)
        XCTAssertEqual(finished.uploadedPhotoId, photo)
        XCTAssertEqual(finished.photoOwnerId, owner)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "POST", "POST", "GET", "GET"])
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(guest.accessToken)"
                && $0.value(forHTTPHeaderField: "X-Installation-Credential") == credential
        })
        guard requests.count == 6 else { return }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[3].httpBody)) as? NSDictionary)
        XCTAssertEqual(body, [
            "operation_id": operationId.uuidString.lowercased(), "mode": "diagnosis",
            "photo_asset_id": photo.uuidString.lowercased(),
            "initial_context": ["light": "direct_sun", "watering_frequency": "sparse", "drainage": "no"]
        ] as NSDictionary)
        XCTAssertEqual(requests[4].url?.lastPathComponent, jobId.uuidString.lowercased())
        XCTAssertEqual(requests[5].url, requests[4].url)
        let other = try profileSession(ownerId: otherSyncOwner, claims: ["sub": otherSyncOwner.uuidString, "is_anonymous": true])
        currentOwner = otherSyncOwner
        await api.bindSyncSession(other)
        do {
            _ = try await service.analyze(input)
            XCTFail("Another guest must not resume the original operation")
        } catch AnalysisServiceFailure.unavailable {}
        let after = await transport.capturedRequests()
        XCTAssertEqual(after.count, requests.count)
    }

    func testGuestDiagnosisDropsStatusAfterBoundLeaseLoss() async throws {
        let guest = try profileSession(ownerId: accessOwner, claims: ["sub": accessOwner.uuidString, "is_anonymous": true])
        let transport = SuspendedCollectionTransport(diagnosisJob(id: operationId, status: "running"))
        let api = client(transport)
        await api.bindSyncSession(guest)
        let lease = try await api.captureSyncContext(ownerId: accessOwner)
        let id = operationId
        let pending = Task {
            try await api.fetchAnalysisJob(
                id: id, mode: .diagnosis, locale: .en, context: lease,
                guestCredential: "fixture-installation-credential"
            )
        }
        await transport.waitForRequest()
        await api.bindSyncSession(nil)
        await api.bindSyncSession(guest)
        await transport.resume()
        do {
            _ = try await pending.value
            XCTFail("Guest status must not cross a lease generation")
        } catch SyncWireValidationError.invalidSession {}
    }

    func testInitialDiagnosisContextUsesClosedWireBodyAndRejectsConflictsBeforeHTTP() async throws {
        let transport = CatalogueTransport([.network, .network])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let lease = try await api.captureSyncContext(ownerId: accessOwner)
        let answers = InitialDiagnosisContext(conditions: CareConditionsInput(
            lightLevel: .brightDirect, lightConfirmed: true, wateringHabit: .sparse, drainage: .no
        ))
        for _ in 0..<2 {
            do {
                _ = try await api.createAnalysisJob(
                    operationId: operationId, mode: .diagnosis, photoAssetId: serverPlantId,
                    initialContext: answers, locale: .en, context: lease
                )
                XCTFail("Expected lost response")
            } catch is URLError {}
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        let body = try XCTUnwrap(requests.first?.httpBody)
        let expected: [String: Any] = [
            "operation_id": operationId.uuidString.lowercased(), "mode": "diagnosis",
            "photo_asset_id": serverPlantId.uuidString.lowercased(),
            "initial_context": ["light": "direct_sun", "watering_frequency": "sparse", "drainage": "no"]
        ]
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? NSDictionary), expected as NSDictionary)
        XCTAssertEqual(requests.last?.httpBody, body)
        let unknown = InitialDiagnosisContext(conditions: CareConditionsInput(lightLevel: .brightDirect))
        let unknownBody = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(unknown)) as? [String: String])
        XCTAssertEqual(unknownBody, ["light": "unknown", "watering_frequency": "unknown", "drainage": "unknown"])
        for (mode, target, guest) in [
            (AnalysisMode.identification, Optional<UUID>.none, Optional<String>.none),
            (.diagnosis, Optional(serverPlantId), nil),
            (.diagnosis, Optional(serverPlantId), Optional("fixture-guest")),
            (.legacyFollowUp, nil, nil)
        ] {
            do {
                _ = try await api.createAnalysisJob(
                    operationId: operationId, mode: mode, photoAssetId: serverPlantId,
                    targetPlantId: target, initialContext: answers, locale: .en, context: lease, guestCredential: guest
                )
                XCTFail("Conflicting context must fail before HTTP")
            } catch AnalysisHTTPError.invalidResponse {}
        }
        let after = await transport.capturedRequests()
        XCTAssertEqual(after.count, requests.count)
    }

    func testDiagnosisUploadAndReplaySendCanonicalWireWithBoundToken() async throws {
        let photo = serverPlantId
        let uploadOperationId = UUID()
        let upload = "https://example.invalid/functions/v1/plants-api/media/uploads/\(photo.uuidString.lowercased())?token=mock"
        let ready = #"{"photo_asset_id":"\#(photo.uuidString)","state":"ready"}"#
        let queued = diagnosisJob(id: operationId, status: "queued")
        let transport = CatalogueTransport([
            .http(200, diagnosisTicket(url: upload, photoId: photo)), .http(200, ready),
            .http(200, ready), .http(202, queued), .http(200, queued),
        ])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let context = try await api.captureSyncContext(ownerId: accessOwner)
        let bytes = Data("abc".utf8)
        let ticket = try await api.issueAnalysisUpload(jpeg: bytes, operationId: uploadOperationId, locale: .en, context: context)
        try await api.uploadAnalysisJPEG(bytes, ticket: ticket, locale: .en, context: context)
        try await api.confirmAnalysisPhoto(id: photo, locale: .en, context: context)
        let created = try await api.createAnalysisJob(operationId: operationId, mode: .diagnosis, photoAssetId: photo, locale: .en, context: context)
        let replay = try await api.createAnalysisJob(operationId: operationId, mode: .diagnosis, photoAssetId: photo, locale: .en, context: context)
        XCTAssertEqual(created.jobId, replay.jobId)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "POST", "POST", "POST"])
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(accessSession.accessToken)"
                && $0.value(forHTTPHeaderField: "X-Client-Locale") == "en"
                && $0.value(forHTTPHeaderField: "X-Installation-Credential") == nil
        })
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(body["content_sha256"] as? String, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(body["byte_size"] as? Int, bytes.count)
        XCTAssertEqual(body["operation_id"] as? String, uploadOperationId.uuidString.lowercased())
        XCTAssertEqual(body["mime_type"] as? String, "image/jpeg")
        XCTAssertEqual(requests[1].url?.absoluteString, upload)
        XCTAssertEqual(requests[1].httpBody, bytes)
        let nonRedirectingRequests = await transport.nonRedirectingRequests
        XCTAssertEqual(nonRedirectingRequests, 1)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(requests[2].url?.lastPathComponent, "complete")
        let jobBody = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[3].httpBody))
        XCTAssertEqual(jobBody, ["operation_id": operationId.uuidString.lowercased(), "mode": "diagnosis",
                                 "photo_asset_id": photo.uuidString.lowercased()])
        let replayBody = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[4].httpBody))
        XCTAssertEqual(jobBody, replayBody)
        XCTAssertEqual(requests[3].httpBody, requests[4].httpBody)
    }

    func testDiagnosisRejectsSignedUploadOutsideExactAssetPath() async throws {
        let suffix = "/functions/v1/plants-api/media/uploads/\(serverPlantId.uuidString.lowercased())"
        let urls = [
            "https://another.invalid\(suffix)", "http://example.invalid\(suffix)",
            "https://example.invalid:444\(suffix)", "https://user@example.invalid\(suffix)",
            "https://example.invalid/functions/v1/plants-api/%2e%2e/media/uploads/\(serverPlantId.uuidString)",
            "https://example.invalid\(suffix)/extra", "https://example.invalid\(suffix)#fragment",
        ]
        for url in urls {
            let transport = CatalogueTransport([.http(200, diagnosisTicket(url: url, photoId: serverPlantId))])
            let api = client(transport)
            await api.bindSyncSession(accessSession)
            let context = try await api.captureSyncContext(ownerId: accessOwner)
            do {
                _ = try await api.issueAnalysisUpload(jpeg: Data([1]), operationId: operationId, locale: .en, context: context)
                XCTFail("Unsafe ticket was accepted")
            } catch AnalysisHTTPError.invalidUpload {}
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["POST"])
        }
    }

    func testDiagnosisMalformedTicketCannotProceedToUpload() async throws {
        let path = "https://example.invalid/functions/v1/plants-api/media/uploads/\(serverPlantId.uuidString.lowercased())"
        let valid = Data(diagnosisTicket(url: path, photoId: serverPlantId).utf8)
        let original = try XCTUnwrap(try JSONSerialization.jsonObject(with: valid) as? [String: Any])
        for (key, wrongValue) in [("storage_bucket", nil), ("storage_path", 1)] as [(String, Int?)] {
            var malformed = original
            if let wrongValue {
                malformed[key] = wrongValue
            } else {
                malformed.removeValue(forKey: key)
            }
            let json = try syncJSON(malformed)
            let transport = CatalogueTransport([.http(200, json)])
            let api = client(transport)
            await api.bindSyncSession(accessSession)
            let context = try await api.captureSyncContext(ownerId: accessOwner)
            do {
                _ = try await api.issueAnalysisUpload(jpeg: Data([1]), operationId: operationId, locale: .en, context: context)
                XCTFail("Malformed storage metadata was accepted")
            } catch is DecodingError {}
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["POST"])
        }
    }

    func testDiagnosisStatusUnknownFailureAndWrongJobRemainDistinct() async throws {
        let id = operationId
        let result = #"{"analysis_id":"\#(serverPlantId.uuidString)","job_id":"\#(id.uuidString)","kb_release_id":"\#(serverPlantId.uuidString)","mode":"diagnosis","identification_status":"unknown","plant_id":null,"genus_id":null,"diagnosis_status":"insufficient_data","selected_condition_id":null,"candidates":[],"visual_markers":[],"evidence_basis":[],"limitations":["Photo too unclear."],"first_action_summary":null,"control_interval_days":null,"plan_availability":"diagnosis_unresolved","analysis_receipt":"test-receipt"}"#
        let malformedCandidateResult = result.replacingOccurrences(
            of: #""candidates":[]"#,
            with: #""candidates":[{"condition_id":"test","rank":3,"confidence":0.5}]"#
        )
        let outOfRangeConfidence = result.replacingOccurrences(
            of: #""candidates":[]"#,
            with: #""candidates":[{"condition_id":"test","rank":1,"confidence":2}]"#
        )
        let transport = CatalogueTransport([
            .http(200, diagnosisJob(id: id, status: "succeeded", result: result)),
            .http(200, diagnosisJob(id: id, status: "failed", errorCode: #""PROVIDER_UNAVAILABLE""#)),
            .http(200, diagnosisJob(id: serverPlantId, status: "running")),
            .http(200, diagnosisJob(id: id, status: "succeeded")),
            .http(200, diagnosisJob(id: id, status: "succeeded", result: malformedCandidateResult)),
            .http(200, diagnosisJob(id: id, status: "succeeded", result: outOfRangeConfidence)),
        ])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let context = try await api.captureSyncContext(ownerId: accessOwner)
        let succeeded = try await api.fetchAnalysisJob(id: id, mode: .diagnosis, locale: .en, context: context)
        XCTAssertEqual(succeeded.result?.domainValue.identificationStatus, .unknown)
        XCTAssertEqual(succeeded.result?.domainValue.diagnosisStatus, .unknown)
        XCTAssertEqual(succeeded.result?.limitations, ["Photo too unclear."])
        let failed = try await api.fetchAnalysisJob(id: id, mode: .diagnosis, locale: .en, context: context)
        XCTAssertNil(failed.result)
        XCTAssertEqual(failed.errorCode, "PROVIDER_UNAVAILABLE")
        for _ in 0..<4 {
            do {
                _ = try await api.fetchAnalysisJob(id: id, mode: .diagnosis, locale: .en, context: context)
                XCTFail("Invalid job response was accepted")
            } catch AnalysisHTTPError.invalidResponse {}
        }
        await api.bindSyncSession(nil)
        do {
            _ = try await api.fetchAnalysisJob(id: id, mode: .diagnosis, locale: .en, context: context)
            XCTFail("Stale request dispatched")
        } catch SyncWireValidationError.invalidSession {}
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.lastPathComponent == id.uuidString.lowercased() })
    }
}

extension CollectionWireTests {
    func testDiagnosisDropsStatusFromInvalidatedBoundSession() async throws {
        let id = operationId
        let transport = SuspendedCollectionTransport(diagnosisJob(id: id, status: "running"))
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let context = try await api.captureSyncContext(ownerId: accessOwner)
        let pending = Task { try await api.fetchAnalysisJob(id: id, mode: .diagnosis, locale: .en, context: context) }
        await transport.waitForRequest()
        await api.bindSyncSession(nil)
        await api.bindSyncSession(accessSession)
        await transport.resume()
        do {
            _ = try await pending.value
            XCTFail("Stale response crossed the session boundary")
        } catch SyncWireValidationError.invalidSession {}
    }
}

#if DEBUG && targetEnvironment(simulator)
extension CollectionWireTests {
    @MainActor
    func testStagingResumeLoadsExactCardWithoutCatalogueSelection() async throws {
        let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .free2)
        defer { try? h.cleanup() }
        let expected = try await h.connection.sessionSnapshot()
        let flow = UUID()
        let model = try await h.connection.makeModel(
            input: CatalogueInput(speciesSlug: "fixture_fern", personalName: "Diagnosis plant"),
            flowId: flow, operationId: UUID(), expected: expected
        )
        _ = try await h.connection.rememberModel(model, expected: expected)
        await model.save()
        guard case let .saved(saved) = model.state else {
            return XCTFail("Expected durable save")
        }
        let result = await h.connection.restoreModel(
            ownerId: expected.session.userId, flowId: flow, expected: expected
        )
        guard case let .restored(restored) = result else {
            return XCTFail("Expected exact restored flow")
        }
        let selection = try XCTUnwrap(CatalogueResumeSelection(restored))
        let firstCataloguePage: [String] = []
        XCTAssertFalse(firstCataloguePage.contains(selection.speciesSlug))
        XCTAssertEqual(selection.flowId, flow)
        XCTAssertEqual(selection.speciesSlug, "fixture_fern")
        await restored.loadCard()
        XCTAssertEqual(restored.cardSummary?.id, saved.receipt.plantId)
        XCTAssertEqual(restored.cardSummary?.personalName, "Diagnosis plant")
        XCTAssertEqual(h.server.snapshot.commits.count, 1)
        XCTAssertEqual(h.server.snapshot.attempts.count, 1)
    }

    @MainActor
    func testAnalysisLimitDisallowsNewCheckpointAndRetriesFrozenSave() async throws {
        let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .cap3)
        defer { try? h.cleanup() }
        let expected = try await h.connection.sessionSnapshot()
        let analysisFlow = UUID()
        let model = try await h.connection.makeModel(
            input: CatalogueInput(speciesSlug: "fixture_fern", personalName: "Original"),
            flowId: analysisFlow, operationId: UUID(), expected: expected
        )
        _ = try await h.connection.rememberModel(model, expected: expected)
        let envelope = try XCTUnwrap(model.envelope)
        let checkpoint = try XCTUnwrap(model.checkpoint)
        await model.save()
        guard case .collectionLimitNotEnqueued = model.state else {
            return XCTFail("Expected preflight limit")
        }
        XCTAssertFalse(CatalogueSaveIdentity.allowsEditingAsNewSave(analysisFlow: analysisFlow))
        XCTAssertTrue(CatalogueSaveIdentity.allowsEditingAsNewSave(analysisFlow: nil))
        await model.save()
        XCTAssertEqual(model.envelope, envelope)
        XCTAssertEqual(model.checkpoint, checkpoint)
        XCTAssertEqual(model.input?.personalName, "Original")
        XCTAssertTrue(h.server.snapshot.attempts.isEmpty)
    }

    @MainActor
    func testAnalysisSaveRestoresOnlyItsExactDiagnosisFlow() {
        let flow = UUID()
        XCTAssertTrue(CatalogueSaveIdentity.canRestore(
            selectedSpecies: "species", restoredSpecies: "species",
            analysisFlow: flow, restoredFlow: flow
        ))
        XCTAssertFalse(CatalogueSaveIdentity.canRestore(
            selectedSpecies: "species", restoredSpecies: "species",
            analysisFlow: flow, restoredFlow: UUID()
        ))
        XCTAssertFalse(CatalogueSaveIdentity.canRestore(
            selectedSpecies: "species", restoredSpecies: "other",
            analysisFlow: flow, restoredFlow: flow
        ))
        XCTAssertFalse(CatalogueSaveIdentity.canRestore(
            selectedSpecies: "species", restoredSpecies: "species",
            analysisFlow: flow, restoredFlow: nil
        ))
        XCTAssertTrue(CatalogueSaveIdentity.canRestore(
            selectedSpecies: "species", restoredSpecies: "species",
            analysisFlow: nil, restoredFlow: UUID()
        ))
    }

    @MainActor
    func testStagingAnalysisRequiresAnExplicitMatchingHTTPSHost() {
        let flag = ["--narat-staging-analysis"]
        let host = "staging.example.invalid"
        let https = URL(string: "https://\(host)")!
        XCTAssertTrue(PhotoAnalysisService.isEnabled(arguments: flag, expectedHost: host, apiOrigin: https))
        XCTAssertFalse(PhotoAnalysisService.isEnabled(arguments: [], expectedHost: host, apiOrigin: https))
        XCTAssertFalse(PhotoAnalysisService.isEnabled(arguments: flag, expectedHost: nil, apiOrigin: https))
        XCTAssertFalse(PhotoAnalysisService.isEnabled(arguments: flag, expectedHost: "other.invalid", apiOrigin: https))
        XCTAssertFalse(PhotoAnalysisService.isEnabled(
            arguments: flag, expectedHost: host, apiOrigin: URL(string: "http://\(host)")!
        ))
    }

    @MainActor
    func testStagingIdentificationRecoversUploadAndResolvesExactTaxon() async throws {
        let photo = UUID(), jobId = UUID(), releaseId = UUID()
        let upload = "https://example.invalid/functions/v1/plants-api/media/uploads/\(photo.uuidString.lowercased())?sig=mock"
        let ready = #"{"photo_asset_id":"\#(photo.uuidString)","state":"ready"}"#
        let result = try identificationResult(jobId: jobId, releaseId: releaseId, plantId: serverPlantId, name: "Pinned Monstera")
        let card = try syncJSON([
            "plant_id": "monstera_deliciosa", "taxon_id": serverPlantId.uuidString,
            "display_name": "Current Monstera", "scientific_name": "Monstera deliciosa", "care_profile_available": true
        ])
        let transport = CatalogueTransport([
            .http(200, diagnosisTicket(url: upload, photoId: photo)), .network, .http(200, ready),
            .http(202, identificationJob(id: jobId, status: "queued", quota: "reserved")),
            .http(200, identificationJob(id: jobId, status: "succeeded", quota: "consumed", result: result)),
            .http(200, card)
        ])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let owner = accessOwner
        let service = PhotoAnalysisService(api: api, identificationEnabled: true) {
            try await api.captureSyncContext(ownerId: owner)
        }
        let input = AnalysisServiceRequest(
            operationId: operationId, flowId: UUID(), mode: .identification, intent: .care,
            photo: PreparedAnalysisPhoto(cloudNormalizedJPEG: Data([1]), aiVisionJPEG: Data([1]),
                                         aiWidthPx: 1, aiHeightPx: 1, originalByteCount: 1),
            conditions: CareConditionsInput(), locale: .en
        )
        do {
            _ = try await service.analyze(input)
            XCTFail("Expected a lost PUT response")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        let finished = try await service.analyze(input)
        XCTAssertNil(finished.analysis)
        XCTAssertEqual(finished.uploadedPhotoId, photo)
        XCTAssertEqual(finished.identification?.jobId, jobId)
        XCTAssertEqual(finished.identification?.catalogueReleaseId, releaseId)
        XCTAssertEqual(finished.identification?.species, .init(
            taxonId: serverPlantId, slug: "monstera_deliciosa", displayName: "Pinned Monstera"
        ))
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "POST", "POST", "GET", "GET"])
        guard requests.count == 6 else { return }
        let complete = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[2].httpBody))
        XCTAssertEqual(complete, ["photo_asset_id": photo.uuidString.lowercased()])
        let create = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[3].httpBody))
        XCTAssertEqual(create, ["operation_id": operationId.uuidString.lowercased(), "mode": "identification",
                                "photo_asset_id": photo.uuidString.lowercased(), "flow_id": input.flowId.uuidString.lowercased()])
        XCTAssertEqual(requests[4].url?.lastPathComponent, jobId.uuidString.lowercased())
        XCTAssertEqual(requests[5].url?.lastPathComponent, serverPlantId.uuidString.lowercased())
        XCTAssertNil(requests[5].value(forHTTPHeaderField: "Authorization"))
    }

    @MainActor
    func testStagingAnalysisRecoversLostUploadAndJobRepliesWithDistinctStableOperations() async throws {
        let photo = serverPlantId
        let id = operationId
        let jobId = UUID()
        let url = "https://example.invalid/functions/v1/plants-api/media/uploads/\(photo.uuidString.lowercased())?sig=mock"
        let ready = #"{"photo_asset_id":"\#(photo.uuidString)","state":"ready"}"#
        let result = #"{"analysis_id":"\#(photo.uuidString)","job_id":"\#(jobId.uuidString)","kb_release_id":"\#(photo.uuidString)","mode":"diagnosis","identification_status":"identified","plant_id":"monstera_deliciosa","genus_id":"monstera","diagnosis_status":"problem_detected","selected_condition_id":"root_rot","candidates":[{"condition_id":"root_rot","rank":1,"confidence":0.7}],"visual_markers":[],"evidence_basis":[],"limitations":[],"first_action_summary":null,"control_interval_days":null,"plan_availability":"missing_condition_profile","analysis_receipt":"test-receipt","plant_display_name":"Monstera deliciosa","condition_display_name":"Root rot"}"#
        let transport = CatalogueTransport([
            .network, .http(200, diagnosisTicket(url: url, photoId: photo)),
            .network, .http(200, ready),
            .network, .http(200, diagnosisJob(id: jobId, status: "queued")),
            .http(200, diagnosisJob(id: jobId, status: "succeeded", result: result)
                .replacingOccurrences(of: #""quota_state":"reserved""#, with: #""quota_state":"consumed""#))
        ])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let owner = accessOwner
        let service = PhotoAnalysisService(api: api) {
            try await api.captureSyncContext(ownerId: owner)
        }
        let input = AnalysisServiceRequest(
            operationId: id, flowId: UUID(), mode: .diagnosis, intent: .problem,
            photo: PreparedAnalysisPhoto(
                cloudNormalizedJPEG: Data([1, 2]), aiVisionJPEG: Data([1, 2]),
                aiWidthPx: 1, aiHeightPx: 1, originalByteCount: 2
            ),
            conditions: CareConditionsInput(), locale: .en
        )
        for _ in 0..<3 {
            do {
                _ = try await service.analyze(input)
                XCTFail("Expected a lost response")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .networkConnectionLost)
            }
        }
        let finished = try await service.analyze(input)
        XCTAssertEqual(finished.speciesLabel, "Monstera deliciosa")
        XCTAssertEqual(finished.conditionLabel, "Root rot")
        XCTAssertEqual(finished.analysis?.jobId, jobId)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "PUT", "POST", "POST", "POST", "GET"])
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, [
            "upload-ticket", "upload-ticket", photo.uuidString.lowercased(), "complete",
            "jobs", "jobs", jobId.uuidString.lowercased()
        ])
        guard requests.count == 7 else { return }
        let uploadBody = try XCTUnwrap(requests[0].httpBody)
        let upload = try XCTUnwrap(JSONSerialization.jsonObject(with: uploadBody) as? [String: Any])
        let jobBody = try XCTUnwrap(requests[4].httpBody)
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: jobBody) as? [String: Any])
        XCTAssertEqual(job["initial_context"] as? [String: String],
                       ["light": "unknown", "watering_frequency": "unknown", "drainage": "unknown"])
        XCTAssertEqual(upload["operation_id"] as? String, input.uploadOperationId.uuidString.lowercased())
        XCTAssertEqual(job["operation_id"] as? String, id.uuidString.lowercased())
        XCTAssertNotEqual(upload["operation_id"] as? String, job["operation_id"] as? String)
        XCTAssertEqual(requests[1].httpBody, uploadBody)
        XCTAssertEqual(requests[5].httpBody, jobBody)
    }

    @MainActor
    func testStagingDiagnosisRetriesReleasedProviderFailureWithTheSamePreparedInput() async throws {
        let photo = UUID(), firstJob = UUID(), retryJob = UUID()
        let url = "https://example.invalid/functions/v1/plants-api/media/uploads/\(photo.uuidString.lowercased())?sig=mock"
        let ready = #"{"photo_asset_id":"\#(photo.uuidString)","state":"ready"}"#
        let failed = diagnosisJob(id: firstJob, status: "failed", errorCode: #""PROVIDER_TIMEOUT_OR_ERROR""#)
            .replacingOccurrences(of: #""quota_state":"reserved""#, with: #""quota_state":"released""#)
        let unavailable = #"{"error":{"code":"PROVIDER_UNAVAILABLE","message":"Fixture provider error","retryable":true}}"#
        let result = #"{"analysis_id":"\#(UUID().uuidString)","job_id":"\#(retryJob.uuidString)","kb_release_id":"\#(UUID().uuidString)","mode":"diagnosis","identification_status":"identified","plant_id":"monstera_deliciosa","genus_id":"monstera","diagnosis_status":"healthy","selected_condition_id":null,"candidates":[],"visual_markers":[],"evidence_basis":[],"limitations":[],"first_action_summary":null,"control_interval_days":null,"plan_availability":"diagnosis_unresolved","analysis_receipt":"test-receipt","plant_display_name":"Monstera deliciosa"}"#
        let transport = CatalogueTransport([
            .http(200, diagnosisTicket(url: url, photoId: photo)), .http(200, ready),
            .http(202, diagnosisJob(id: firstJob, status: "queued")), .http(200, failed),
            .http(503, unavailable), .http(202, diagnosisJob(id: retryJob, status: "queued")),
            .http(200, diagnosisJob(id: firstJob, status: "running")),
            .http(200, diagnosisJob(id: retryJob, status: "succeeded", result: result)
                .replacingOccurrences(of: #""quota_state":"reserved""#, with: #""quota_state":"consumed""#))
        ])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let owner = accessOwner
        let service = PhotoAnalysisService(api: api) { try await api.captureSyncContext(ownerId: owner) }
        let model = AnalysisFlowModel(service: service)
        model.router.selectIntent(.problem)
        model.router.attachPhoto(identifier: "fixture-gallery-photo")
        model.preparedPhoto = PreparedAnalysisPhoto(
            cloudNormalizedJPEG: Data([1, 2]), aiVisionJPEG: Data([1, 2]),
            aiWidthPx: 1, aiHeightPx: 1, originalByteCount: 2
        )
        model.selectLightLevel(.medium)
        model.selectWateringHabit(.moderate)
        let first = try XCTUnwrap(model.submitAnalysis(locale: .en))
        await first.value
        let frozen = try XCTUnwrap(model.frozenRequest)
        for error in ["analysis.error.provider", "analysis.error.provider", "analysis.error.failed"] {
            XCTAssertEqual(model.analysisError, error)
            XCTAssertEqual(model.router.flowState.currentStep, .analyzing)
            XCTAssertEqual(model.router.flowState.photoLocalIdentifier, "fixture-gallery-photo")
            XCTAssertEqual(model.router.flowState.conditions, frozen.conditions)
            XCTAssertEqual(model.preparedPhoto, frozen.photo)
            XCTAssertEqual(model.frozenRequest, frozen)
            XCTAssertNil(model.preliminaryResult)
            XCTAssertNil(model.speciesLabel)
            XCTAssertNil(model.conditionLabel)
            let retry = try XCTUnwrap(model.submitAnalysis(locale: .pl))
            await retry.value
        }
        XCTAssertEqual(model.currentOperationId, frozen.operationId)
        XCTAssertEqual(model.preliminaryResult?.jobId, retryJob)
        XCTAssertEqual(model.preliminaryResult?.diagnosisStatus, .healthy)
        XCTAssertEqual(model.router.flowState.currentStep, .preliminaryResult)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "POST", "GET", "POST", "POST", "GET", "GET"])
        guard requests.count == 8 else { return }
        let firstCreate = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        let secondCreate = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[4].httpBody)) as? [String: Any])
        XCTAssertEqual(firstCreate["operation_id"] as? String, frozen.operationId.uuidString.lowercased())
        XCTAssertNotEqual(firstCreate["operation_id"] as? String, secondCreate["operation_id"] as? String)
        XCTAssertEqual(firstCreate["photo_asset_id"] as? String, photo.uuidString.lowercased())
        XCTAssertEqual(secondCreate["photo_asset_id"] as? String, firstCreate["photo_asset_id"] as? String)
        XCTAssertEqual(firstCreate["initial_context"] as? [String: String],
                       ["light": "medium", "watering_frequency": "moderate", "drainage": "unknown"])
        XCTAssertEqual(secondCreate["initial_context"] as? [String: String], firstCreate["initial_context"] as? [String: String])
        XCTAssertEqual(requests[4].httpBody, requests[5].httpBody)
        XCTAssertEqual(requests[1].httpBody, frozen.photo.aiVisionJPEG)
        XCTAssertEqual(requests[6].url, requests[7].url)
        XCTAssertEqual(requests[7].url?.lastPathComponent, retryJob.uuidString.lowercased())
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Client-Locale") == "en" })
    }

    @MainActor
    func testReleasedTimeoutRetryPreservesFrozenInputThroughLostRepliesAndOwnerSwitch() async throws {
        for isGuest in [true, false] {
            let owner = accessOwner
            let credential = isGuest ? "fixture-installation-credential" : nil
            let boundSession = isGuest
                ? try profileSession(ownerId: owner, claims: ["sub": owner.uuidString, "is_anonymous": true])
                : accessSession
            let photo = UUID(), firstJob = UUID(), retryJob = UUID()
            let url = "https://example.invalid/functions/v1/plants-api/media/uploads/\(photo.uuidString.lowercased())?sig=mock"
            let ready = #"{"photo_asset_id":"\#(photo.uuidString)","state":"ready"}"#
            let expired = diagnosisJob(id: firstJob, status: "expired", errorCode: #""ANALYSIS_TIMEOUT""#)
                .replacingOccurrences(of: #""quota_state":"reserved""#, with: #""quota_state":"released""#)
                .replacingOccurrences(of: "free_monthly", with: isGuest ? "starter_diagnosis" : "paid_monthly")
            let result = #"{"analysis_id":"\#(UUID().uuidString)","job_id":"\#(retryJob.uuidString)","kb_release_id":"\#(UUID().uuidString)","mode":"diagnosis","identification_status":"unknown","plant_id":null,"genus_id":null,"diagnosis_status":"insufficient_data","selected_condition_id":null,"candidates":[],"visual_markers":[],"evidence_basis":[],"limitations":[],"first_action_summary":null,"control_interval_days":null,"plan_availability":"diagnosis_unresolved","analysis_receipt":"test-receipt"}"#
            let transport = CatalogueTransport([
                .http(200, diagnosisTicket(url: url, photoId: photo)), .http(200, ready),
                .http(202, diagnosisJob(id: firstJob, status: "queued")),
                .inspect { _ in throw URLError(.timedOut) },
                .http(200, expired), .network,
                .http(202, diagnosisJob(id: retryJob, status: "queued")), .network,
                .http(200, diagnosisJob(id: retryJob, status: "succeeded", result: result)
                    .replacingOccurrences(of: #""quota_state":"reserved""#, with: #""quota_state":"consumed""#))
            ])
            let api = client(transport)
            await api.bindSyncSession(boundSession)
            var currentOwner = owner
            let service = PhotoAnalysisService(api: api, guestCredential: credential) {
                try await api.captureSyncContext(ownerId: currentOwner)
            }
            let model = AnalysisFlowModel(service: service)
            model.router.selectIntent(.problem)
            model.router.attachPhoto(identifier: "timeout-fixture")
            model.preparedPhoto = PreparedAnalysisPhoto(
                cloudNormalizedJPEG: Data([1, 2]), aiVisionJPEG: Data([1, 2]),
                aiWidthPx: 1, aiHeightPx: 1, originalByteCount: 2
            )
            model.selectLightLevel(.brightDirect)
            model.selectWateringHabit(.sparse)
            model.selectDrainage(.no)
            let locale: SupportedLocale = isGuest ? .en : .pl
            let otherLocale: SupportedLocale = isGuest ? .pl : .en
            let first = try XCTUnwrap(model.submitAnalysis(locale: locale))
            await first.value
            XCTAssertEqual(model.analysisError, "analysis.error.failed")
            let frozen = try XCTUnwrap(model.frozenRequest)
            // A local transport timeout only resumes status; it cannot replace the job.
            let confirmation = try XCTUnwrap(model.submitAnalysis(locale: otherLocale))
            await confirmation.value
            XCTAssertEqual(model.analysisError, "analysis.error.timeout")
            let confirmedRequests = await transport.capturedRequests()
            XCTAssertEqual(confirmedRequests.count, 5)
            guard confirmedRequests.count == 5 else { return }
            XCTAssertEqual(confirmedRequests[3].url, confirmedRequests[4].url)
            XCTAssertEqual(confirmedRequests[4].httpMethod, "GET")

            currentOwner = otherSyncOwner
            let otherSession = try profileSession(ownerId: currentOwner, claims: [
                "sub": currentOwner.uuidString, "is_anonymous": isGuest
            ])
            await api.bindSyncSession(otherSession)
            let switched = try XCTUnwrap(model.submitAnalysis(locale: otherLocale))
            await switched.value
            XCTAssertEqual(model.analysisError, "analysis.error.failed")
            let afterSwitch = await transport.capturedRequests()
            XCTAssertEqual(afterSwitch.count, 5)
            currentOwner = owner
            await api.bindSyncSession(boundSession)

            // UI edits and a language change must not change the frozen retry.
            model.selectLightLevel(.low)
            model.selectWateringHabit(.frequent)
            model.selectDrainage(.yes)
            for _ in 0..<2 {
                let retry = try XCTUnwrap(model.submitAnalysis(locale: otherLocale))
                _ = model.submitAnalysis(locale: otherLocale)
                await retry.value
                XCTAssertEqual(model.analysisError, "analysis.error.failed")
                XCTAssertEqual(model.frozenRequest, frozen)
                XCTAssertEqual(model.preparedPhoto, frozen.photo)
                XCTAssertNil(model.preliminaryResult)
            }
            let finish = try XCTUnwrap(model.submitAnalysis(locale: otherLocale))
            await finish.value
            XCTAssertEqual(model.preliminaryResult?.jobId, retryJob)
            XCTAssertEqual(model.diagnosisPhoto?.id, photo)
            XCTAssertEqual(model.diagnosisPhoto?.owner, owner)
            XCTAssertEqual(model.frozenRequest, frozen)
            XCTAssertEqual(model.currentOperationId, frozen.operationId)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "POST", "GET", "GET", "POST", "POST", "GET", "GET"])
            guard requests.count == 9 else { return }
            let original = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: Any])
            let replacement = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[5].httpBody)) as? [String: Any])
            XCTAssertNotEqual(original["operation_id"] as? String, replacement["operation_id"] as? String)
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(replacement["operation_id"] as? String)))
            XCTAssertEqual(original["operation_id"] as? String, frozen.operationId.uuidString.lowercased())
            XCTAssertEqual(replacement["photo_asset_id"] as? String, photo.uuidString.lowercased())
            XCTAssertEqual(original["initial_context"] as? [String: String],
                           ["light": "direct_sun", "watering_frequency": "sparse", "drainage": "no"])
            XCTAssertEqual(replacement["initial_context"] as? [String: String], original["initial_context"] as? [String: String])
            XCTAssertEqual(requests[5].httpBody, requests[6].httpBody)
            XCTAssertEqual(requests[1].httpBody, frozen.photo.aiVisionJPEG)
            XCTAssertEqual(requests[7].url, requests[8].url)
            XCTAssertEqual(requests[8].url?.lastPathComponent, retryJob.uuidString.lowercased())
            XCTAssertTrue(requests.allSatisfy {
                $0.value(forHTTPHeaderField: "X-Client-Locale") == (isGuest ? "en" : "pl")
                    && $0.value(forHTTPHeaderField: "X-Installation-Credential") == credential
            })
        }
    }

    @MainActor
    func testExpiredUnsafeJobsNeverAllocateReplacementCreate() async throws {
        for scenario in ["reserved", "consumed", "not_required", "other_error", "unknown_quota", "wrong_photo", "repeat", "identification"] {
            let owner = accessOwner
            let photo = UUID(), jobId = UUID()
            let target = scenario == "repeat" ? RepeatDiagnosisTarget(plantId: serverPlantId, ownerId: owner) : nil
            let mode: AnalysisMode = scenario == "identification" ? .identification : .diagnosis
            var expired = diagnosisJob(id: jobId, status: "expired", errorCode: #""ANALYSIS_TIMEOUT""#,
                                       target: target.map { ($0.plantId, photo) })
                .replacingOccurrences(of: #""quota_state":"reserved""#, with: #""quota_state":"released""#)
            if ["reserved", "consumed", "not_required"].contains(scenario) {
                expired = expired.replacingOccurrences(of: #""quota_state":"released""#, with: "\"quota_state\":\"\(scenario)\"")
            } else if scenario == "other_error" {
                expired = expired.replacingOccurrences(of: "ANALYSIS_TIMEOUT", with: "OTHER_ERROR")
            } else if scenario == "unknown_quota" {
                expired = expired.replacingOccurrences(of: "free_monthly", with: "unknown")
            } else if scenario == "wrong_photo" {
                expired = expired.replacingOccurrences(of: #""result":null"#, with: #""photo_asset_id":"\#(UUID().uuidString)","result":null"#)
            } else if scenario == "identification" {
                expired = identificationJob(id: jobId, status: "expired", quota: "released")
                    .replacingOccurrences(of: #""error_code":null"#, with: #""error_code":"ANALYSIS_TIMEOUT""#)
            }
            let url = "https://example.invalid/functions/v1/plants-api/media/uploads/\(photo.uuidString.lowercased())?sig=mock"
            let ready = #"{"photo_asset_id":"\#(photo.uuidString)","state":"ready"}"#
            let transport = CatalogueTransport([
                .http(200, diagnosisTicket(url: url, photoId: photo)), .http(200, ready),
                .http(200, expired), .http(200, expired)
            ])
            let api = client(transport)
            await api.bindSyncSession(accessSession)
            let service = PhotoAnalysisService(api: api, identificationEnabled: true, repeatDiagnosisTarget: target) {
                try await api.captureSyncContext(ownerId: owner)
            }
            let input = AnalysisServiceRequest(
                operationId: operationId, flowId: UUID(), mode: mode,
                intent: mode == .diagnosis ? .problem : .care,
                photo: PreparedAnalysisPhoto(
                    cloudNormalizedJPEG: Data([1]), aiVisionJPEG: Data([1]),
                    aiWidthPx: 1, aiHeightPx: 1, originalByteCount: 1
                ), conditions: CareConditionsInput(), locale: .en, repeatDiagnosisTarget: target
            )
            for _ in 0..<2 {
                do {
                    _ = try await service.analyze(input)
                    XCTFail("Unsafe expiry must require reselect: \(scenario)")
                } catch AnalysisServiceFailure.expiredTerminal {}
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "POST", "GET"], scenario)
            XCTAssertEqual(requests.last?.url?.lastPathComponent, jobId.uuidString.lowercased())
        }
    }

    @MainActor
    func testCareRecommendationRefreshReplaysAfterRestartAndWaitsForCanonicalSync() async throws {
        let plant = serverPlantId
        let snapshot = UUID()
        let refreshedAt = "2026-11-03T09:10:00.000001+00:00"
        var row = syncChange(syncUntil, id: plant.uuidString)
        row["data"] = ["id": plant.uuidString, "revision": 2, "care_revision": 2,
                       "current_condition_snapshot_id": snapshot.uuidString] as [String: Any]
        var baseline = syncObject()
        baseline["changes"] = [row]
        var delta = syncObject()
        delta["changes"] = []
        delta["until"] = refreshedAt
        delta["next_since"] = refreshedAt
        let receipt: [String: Any] = [
            "plant_id": plant.uuidString, "care_revision": 2, "state": "refreshed",
            "reason": NSNull(), "watermark": refreshedAt
        ]
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command: CommandEnvelopeDTO
        let firstPost: Data
        do {
            let transport = CatalogueTransport([.http(200, try syncJSON(baseline)), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            _ = try await repo.collectionCards(context: lease)
            command = try await repo.enqueueCareRecommendationRefresh(plantId: plant, context: lease)
            XCTAssertEqual(command.payloadJSON, "{\"expected_care_revision\":2}")
            let outcome = try await repo.retryCareRecommendationRefresh(command, context: lease)
            XCTAssertEqual(outcome, .pending)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
            firstPost = try XCTUnwrap(requests.last?.httpBody)
        }
        var wrong = receipt
        wrong["care_revision"] = 3
        let projection = careProjection(anchor: "2026-10-29", due: "2026-11-05")
        let transport = CatalogueTransport([
            .http(200, try syncJSON(wrong)), .http(200, try syncJSON(receipt)),
            .http(200, try syncJSON(delta)), .http(200, try syncJSON(projection))
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        let replay = try await repo.enqueueCareRecommendationRefresh(plantId: plant, context: lease)
        XCTAssertEqual(replay, command)
        let invalidOutcome = try await repo.retryCareRecommendationRefresh(replay, context: lease)
        XCTAssertEqual(invalidOutcome, .pending)
        let pending = try await repo.pendingCareRecommendationRefresh(plantId: plant, context: lease)
        XCTAssertEqual(pending, command)
        let validOutcome = try await repo.retryCareRecommendationRefresh(replay, context: lease)
        XCTAssertEqual(validOutcome, .confirmed)
        let remaining = try await repo.pendingCareRecommendationRefresh(plantId: plant, context: lease)
        XCTAssertNil(remaining)
        let recommendation = try await api.fetchCareRecommendation(plantId: plant, context: lease)
        XCTAssertEqual(recommendation?.nextCheck?.dueOn, "2026-11-05")
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "GET", "GET"])
        XCTAssertEqual(requests.prefix(2).compactMap(\.httpBody), [firstPost, firstPost])
        XCTAssertTrue(requests.prefix(2).allSatisfy {
            $0.value(forHTTPHeaderField: "X-Operation-Id")?.lowercased() == command.operationId.uuidString.lowercased()
                && $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(syncSession.accessToken)"
                && $0.value(forHTTPHeaderField: "X-Client-Locale") == "en"
                && $0.value(forHTTPHeaderField: "X-Installation-Credential") == nil
        })
    }

    @MainActor
    func testCareRecommendationRefreshTerminalAndPausedOutcomes() async throws {
        for code in ["CONFLICT", "FORBIDDEN", "VALIDATION_ERROR", "NOT_FOUND"] {
            var row = syncChange(syncUntil, id: serverPlantId.uuidString)
            row["data"] = ["id": serverPlantId.uuidString, "revision": 2, "care_revision": 2] as [String: Any]
            var baseline = syncObject()
            baseline["changes"] = [row]
            let failure = try syncJSON(["error": ["code": code, "message": "Fixture rejection", "retryable": false] as [String: Any]])
            let retryable = try syncJSON(["error": ["code": code, "message": "Fixture retry", "retryable": true] as [String: Any]])
            let paused = try syncJSON([
                "plant_id": serverPlantId.uuidString, "care_revision": 2, "state": "paused",
                "reason": "missing_watering_anchor", "watermark": syncUntil
            ])
            let status = code == "FORBIDDEN" ? 403 : code == "NOT_FOUND" ? 404 : code == "CONFLICT" ? 409 : 400
            let transport = CatalogueTransport([
                .http(200, try syncJSON(baseline)), .http(status, failure),
                .http(status, failure), .http(status, retryable),
                .http(200, paused), .http(200, try syncJSON(syncObject()))
            ])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = LocalStore(modelContainer: try diskContainer(url))
            let engine = SyncEngine(store: store, apiClient: api)
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
            _ = try await repo.collectionCards(context: lease)
            let command = try await repo.enqueueCareRecommendationRefresh(plantId: serverPlantId, context: lease)
            let rejected = try await repo.retryCareRecommendationRefresh(command, context: lease)
            XCTAssertEqual(rejected, .rejected, code)
            let discarded = try await repo.pendingCareRecommendationRefresh(plantId: serverPlantId, context: lease)
            XCTAssertNil(discarded, code)
            let absent = try await repo.retryCareRecommendationRefresh(command, context: lease)
            XCTAssertEqual(absent, .unconfirmed, code)

            // Background rejection retains the existing nonthrowing drain behavior.
            let background = try await repo.enqueueCareRecommendationRefresh(plantId: serverPlantId, context: lease)
            let committed = try await engine.flushOutbox(context: lease)
            XCTAssertEqual(committed, 0, code)
            let backgroundOutcome = try await repo.retryCareRecommendationRefresh(background, context: lease)
            XCTAssertEqual(backgroundOutcome, .unconfirmed, code)

            let retry = try await repo.enqueueCareRecommendationRefresh(plantId: serverPlantId, context: lease)
            let pendingOutcome = try await repo.retryCareRecommendationRefresh(retry, context: lease)
            XCTAssertEqual(pendingOutcome, .pending, code)
            let pending = try await repo.pendingCareRecommendationRefresh(plantId: serverPlantId, context: lease)
            XCTAssertEqual(pending, retry, code)
            let confirmed = try await repo.retryCareRecommendationRefresh(retry, context: lease)
            XCTAssertEqual(confirmed, .confirmed, code)
            let remaining = try await repo.pendingCareRecommendationRefresh(plantId: serverPlantId, context: lease)
            XCTAssertNil(remaining, code)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "POST", "POST", "POST", "GET"], code)
            XCTAssertEqual(requests[3].httpBody, requests[4].httpBody, code)
            XCTAssertEqual(requests[3].value(forHTTPHeaderField: "X-Operation-Id"), retry.operationId.uuidString.lowercased(), code)
            XCTAssertEqual(requests[3].value(forHTTPHeaderField: "X-Operation-Id"), requests[4].value(forHTTPHeaderField: "X-Operation-Id"), code)
        }
    }

    @MainActor
    func testPlantLightEditReplaysAndRetainsPreviousAnalysis() async throws {
        try await verifyPlantConditionEdit(.light(.directSun), key: "light_code", code: "direct_sun")
    }

    @MainActor
    func testPlantDrainageEditReplaysAndRetainsPreviousAnalysis() async throws {
        try await verifyPlantConditionEdit(.drainage(.no), key: "drainage_code", code: "no")
    }

    @MainActor
    func testPlantWateringFrequencyEditReplaysAndRetainsPreviousAnalysis() async throws {
        try await verifyPlantConditionEdit(.watering(.weekly), key: "watering_code", code: "weekly")
    }

    @MainActor
    func testPlantPotTypeEditReplaysAndRetainsPreviousAnalysis() async throws {
        try await verifyPlantConditionEdit(.potType(.glazedCeramic), key: "pot_type", code: "glazed_ceramic")
    }

    @MainActor
    func testPlantTaxonEditReplaysExactCommandAndWaitsForCanonicalTaxon() async throws {
        let plant = serverPlantId
        let originalTaxon = UUID()
        let targetTaxon = UUID()
        let photo = UUID()
        let snapshot = UUID()
        let nextSnapshot = UUID()
        let editedAt = "2026-11-03T09:10:00.000001+00:00"
        let confirmedAt = "2026-11-03T09:10:00.000002+00:00"
        func page(_ at: String, taxon: UUID, slug: String, snapshot: UUID, revision: Int) throws -> String {
            var row = syncChange(at, id: plant.uuidString)
            row["data"] = ["id": plant.uuidString, "taxon_id": taxon.uuidString, "plant_id": slug,
                           "personal_name": "Fixture name", "main_photo_id": photo.uuidString,
                           "current_condition_snapshot_id": snapshot.uuidString,
                           "revision": revision, "care_revision": revision] as [String: Any]
            var page = syncObject()
            page["until"] = at
            page["next_since"] = at
            page["changes"] = [row]
            return try syncJSON(page)
        }
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command: CommandEnvelopeDTO
        let firstPost: Data
        do {
            let baseline = try page(syncUntil, taxon: originalTaxon, slug: "fixture_fern", snapshot: snapshot, revision: 1)
            let transport = CatalogueTransport([.http(200, baseline), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            _ = try await repo.collectionCards(context: lease)
            command = try await repo.enqueuePlantEdit(plantId: plant, change: .taxon(targetTaxon), context: lease)
            XCTAssertEqual(command.payloadJSON, "{\"taxon_id\":\"\(targetTaxon.uuidString.lowercased())\"}")
            let pending = try await repo.retryPlantEdit(command, context: lease)
            XCTAssertNil(pending)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
            firstPost = try XCTUnwrap(requests.last?.httpBody)
        }
        let receipt = try syncJSON(["plant_id": plant.uuidString, "revision": 2, "care_revision": 2,
                                    "condition_snapshot_id": nextSnapshot.uuidString, "watermark": editedAt])
        let wrong = try page(editedAt, taxon: originalTaxon, slug: "fixture_fern", snapshot: nextSnapshot, revision: 2)
        let canonical = try page(confirmedAt, taxon: targetTaxon, slug: "fixture_palm", snapshot: nextSnapshot, revision: 2)
        let transport = CatalogueTransport([.http(200, receipt), .http(200, wrong),
                                            .http(200, receipt), .http(200, canonical)])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        let stored = try await repo.pendingPlantEdit(plantId: plant, context: lease)
        let replay = try XCTUnwrap(stored)
        XCTAssertEqual(replay, command)
        let unconfirmed = try await repo.retryPlantEdit(replay, context: lease)
        XCTAssertNil(unconfirmed)
        let stillPending = try await repo.pendingPlantEdit(plantId: plant, context: lease)
        XCTAssertEqual(stillPending, replay)
        let confirmed = try await repo.retryPlantEdit(replay, context: lease)
        XCTAssertEqual(confirmed?.id, plant)
        XCTAssertEqual(confirmed?.taxonId, targetTaxon)
        XCTAssertEqual(confirmed?.speciesSlug, "fixture_palm")
        XCTAssertEqual(confirmed?.personalName, "Fixture name")
        XCTAssertEqual(confirmed?.mainPhotoId, photo)
        XCTAssertEqual(confirmed?.currentConditionSnapshotId, nextSnapshot)
        let remaining = try await repo.pendingPlantEdit(plantId: plant, context: lease)
        XCTAssertNil(remaining)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "POST", "GET"])
        for request in requests where request.httpMethod == "POST" {
            XCTAssertEqual(request.httpBody, firstPost)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), command.operationId.uuidString.lowercased())
        }
    }

    @MainActor
    private func verifyPlantConditionEdit(_ change: PlantEditCommand.Change, key: String, code: String) async throws {
        let plant = serverPlantId
        let originalSnapshot = UUID()
        let updatedSnapshot = UUID()
        let analysis = UUID()
        let photo = UUID()
        let updatedAt = "2026-11-03T09:10:00.000001+00:00"
        func row(_ kind: String, _ id: UUID, _ at: String, _ payload: [String: Any]) -> [String: Any] {
            var row = syncChange(at, id: id.uuidString, entity: kind)
            row["data"] = payload
            return row
        }
        func card(_ snapshot: UUID, _ at: String, _ revision: Int) -> [String: Any] {
            row("plants", plant, at, [
                "id": plant.uuidString, "revision": revision, "care_revision": revision,
                "current_condition_snapshot_id": snapshot.uuidString, "main_photo_id": photo.uuidString
            ])
        }
        func page(_ at: String, _ changes: [[String: Any]]) throws -> String {
            var page = syncObject()
            page["until"] = at
            page["next_since"] = at
            page["changes"] = changes
            return try syncJSON(page)
        }
        let originalAnalysis = row("analysis_summaries", analysis, syncUntil, [
            "id": analysis.uuidString, "plant_id": plant.uuidString, "mode": "diagnosis",
            "source_snapshot_id": originalSnapshot.uuidString, "source_care_revision": 1,
            "context_state": "current", "created_at": syncUntil
        ])
        let baseline = try page(syncUntil, [originalAnalysis, card(originalSnapshot, syncUntil, 1)])
        let receipt = try syncJSON(["plant_id": plant.uuidString, "revision": 2, "care_revision": 2,
                                    "condition_snapshot_id": updatedSnapshot.uuidString, "watermark": updatedAt])
        let light = row("condition_snapshots", updatedSnapshot, updatedAt, [
            "id": updatedSnapshot.uuidString, "plant_id": plant.uuidString, key: code
        ])
        let delta = try page(updatedAt, [light, card(updatedSnapshot, updatedAt, 2)])
        let transport = CatalogueTransport([.http(200, baseline), .network, .http(200, receipt), .http(200, delta)])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        _ = try await repo.collectionCards(context: lease)
        let before = try await repo.collectionAnalysisHistory(plantId: plant, context: lease)
        XCTAssertEqual(before.first?.previousConditions, false)
        let command = try await repo.enqueuePlantEdit(plantId: plant, change: change, context: lease)
        XCTAssertEqual(command.payloadJSON, "{\"conditions\":{\"\(key)\":\"\(code)\"}}")
        let pending = try await repo.retryPlantEdit(command, context: lease)
        XCTAssertNil(pending)
        let queued = try await repo.pendingPlantEdit(plantId: plant, context: lease)
        XCTAssertEqual(queued, command)
        let result = try await repo.retryPlantEdit(command, context: lease)
        let updated = try XCTUnwrap(result)
        XCTAssertEqual(updated.mainPhotoId, photo)
        XCTAssertEqual(updated.currentConditionSnapshotId, updatedSnapshot)
        let confirmed = try await repo.syncedPlantConditions(for: updated, context: lease)
        let confirmedCode = switch change {
        case .light: confirmed?.light?.rawValue
        case .drainage: confirmed?.drainage?.rawValue
        case .watering: confirmed?.watering?.rawValue
        case .potType: confirmed?.potType?.rawValue
        case .name, .taxon: nil as String?
        }
        XCTAssertEqual(confirmedCode, code)
        let after = try await repo.collectionAnalysisHistory(plantId: plant, context: lease)
        XCTAssertEqual(after.map(\.id), [analysis])
        XCTAssertEqual(after.first?.previousConditions, true)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "POST", "GET"])
        XCTAssertEqual(requests[1].httpBody, requests[2].httpBody)
    }

    @MainActor
    func testPlantEditAcceptanceRequiresExactEnvelopeAndCanonicalAck() async throws {
        for mode in 0..<4 {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let snapshot = UUID(), neighbour = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
            let later = "2026-11-03T09:10:00.000001+00:00"
            func page(_ at: String, revision: Int) throws -> String {
                var page = syncObject(), row = syncChange(at, id: serverPlantId.uuidString)
                page["until"] = at
                page["next_since"] = at
                row["data"] = ["id": serverPlantId.uuidString, "personal_name": "Requested",
                    "revision": revision, "care_revision": 1,
                    "current_condition_snapshot_id": snapshot.uuidString] as [String: Any]
                var other = syncChange(at, id: neighbour.uuidString)
                other["data"] = ["id": neighbour.uuidString, "personal_name": "Other",
                    "revision": 1, "care_revision": 1] as [String: Any]
                page["changes"] = [row, other]
                return try syncJSON(page)
            }
            let receipt = try syncJSON(["plant_id": serverPlantId.uuidString, "revision": 2,
                "care_revision": 1, "condition_snapshot_id": snapshot.uuidString,
                "watermark": later] as [String: Any])
            let rejected = try syncJSON(["error": ["code": "CONFLICT",
                "message": "Rejected", "retryable": false]])
            var replies: [CatalogueTransport.Reply] = [.http(200, try page(syncUntil, revision: 1))]
            switch mode {
            case 0: replies += [.http(200, receipt), .http(200, try page(later, revision: 2))]
            case 1: replies += [.network]
            case 2: replies += [.http(200, receipt), .network]
            default: replies += [.http(409, rejected)]
            }
            let transport = CatalogueTransport(replies), api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api,
                syncEngine: SyncEngine(store: store, apiClient: api))
            _ = try await repo.collectionCards(context: lease)
            let unrelated = try await repo.enqueuePlantRename(plantId: neighbour, personalName: "Other", context: lease)
            let target = try await repo.enqueuePlantRename(plantId: serverPlantId, personalName: "Requested", context: lease)
            let wrongBody = try PlantEditCommand.make(plantId: serverPlantId, change: .name("Wrong")).envelope
            let impostor = CommandEnvelopeDTO(operationId: target.operationId, commandName: target.commandName,
                plantId: target.plantId, payloadJSON: wrongBody.payloadJSON)
            let wrong = try await repo.retryPlantEditAcceptance(impostor, context: lease)
            XCTAssertEqual(wrong, .unconfirmed)
            let before = await transport.capturedRequests()
            XCTAssertEqual(before.count, 1, "Same UUID with another body must not dispatch")
            let outcome = try await repo.retryPlantEditAcceptance(target, context: lease)
            XCTAssertEqual(outcome, mode == 0 ? .confirmed : .unconfirmed)
            let pending = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertTrue(pending.contains { $0.envelope == unrelated })
            XCTAssertEqual(pending.contains { $0.envelope == target }, mode == 1 || mode == 2)
            let again = try await repo.retryPlantEditAcceptance(impostor, context: lease)
            XCTAssertEqual(again, .unconfirmed, "Queue absence and matching old card are not ACK")
            if mode == 0 {
                let card = try await repo.plantEditCard(target, context: lease)
                XCTAssertEqual(card?.personalName, "Requested")
                let replay = try await repo.retryPlantEditAcceptance(target, context: lease)
                XCTAssertEqual(replay, .unconfirmed)
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), mode == 0 || mode == 2
                ? ["GET", "POST", "GET"] : ["GET", "POST"])
            let posts = requests.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(posts.count, 1)
            let sent = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(posts.first?.httpBody))
            XCTAssertEqual(sent, target)
        }
    }

    @MainActor
    func testPlantEditAcceptanceRejectsReceiptAcrossOwnerABA() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var page = syncObject(), row = syncChange(id: serverPlantId.uuidString)
        row["data"] = ["id": serverPlantId.uuidString, "revision": 1, "care_revision": 1] as [String: Any]
        page["changes"] = [row]
        let store = LocalStore(modelContainer: try diskContainer(url))
        let seedAPI = client(CatalogueTransport([.http(200, try syncJSON(page))]))
        await seedAPI.bindSyncSession(syncSession)
        _ = try await SyncEngine(store: store, apiClient: seedAPI).pullDelta(for: syncOwner)
        let transport = SuspendedCollectionTransport(try syncJSON([
            "plant_id": serverPlantId.uuidString, "revision": 2, "care_revision": 1,
            "condition_snapshot_id": NSNull(), "watermark": syncUntil]))
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let repo = CollectionRepository(store: store, apiClient: api,
            syncEngine: SyncEngine(store: store, apiClient: api))
        let command = try await repo.enqueuePlantRename(plantId: serverPlantId, personalName: "New", context: lease)
        let attempt = Task { try await repo.retryPlantEditAcceptance(command, context: lease) }
        await transport.waitForRequest()
        await api.bindSyncSession(NativeAuthSession(userId: otherSyncOwner,
            accessToken: "owner-b-token", expiresAt: .distantFuture))
        await api.bindSyncSession(syncSession)
        await transport.resume()
        do {
            _ = try await attempt.value
            XCTFail("A receipt from the previous binding cannot confirm the edit")
        } catch SyncWireValidationError.invalidSession {}
        let pending = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertEqual(pending.map(\.envelope), [command])
    }

    @MainActor
    func testPlantRenameWaitsForCanonicalCardAndPreservesExactOperation() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = UUID()
        let photo = UUID()
        let renamedAt = "2026-11-03T09:10:00.000001+00:00"
        let plant = serverPlantId
        func page(_ at: String, name: String?, revision: Int) throws -> String {
            var page = syncObject()
            page["until"] = at
            page["next_since"] = at
            if let name {
                var row = syncChange(at, id: plant.uuidString)
                row["data"] = ["id": plant.uuidString, "personal_name": name, "revision": revision,
                               "care_revision": 1, "main_photo_id": photo.uuidString,
                               "current_condition_snapshot_id": snapshot.uuidString] as [String: Any]
                page["changes"] = [row]
            }
            return try syncJSON(page)
        }
        let command: CommandEnvelopeDTO
        let original: Data
        do {
            let transport = CatalogueTransport([.http(200, try page(syncUntil, name: "Original", revision: 1)), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            _ = try await repo.collectionCards(context: lease)
            command = try await repo.enqueuePlantRename(plantId: plant, personalName: "  New name  ", context: lease)
            let reused = try await repo.enqueuePlantRename(plantId: plant, personalName: "New name", context: lease)
            XCTAssertEqual(command, reused)
            let pending = try await repo.retryPlantEdit(command, context: lease)
            XCTAssertNil(pending)
            let requests = await transport.capturedRequests()
            original = try XCTUnwrap(requests.last?.httpBody)
        }
        let receipt: [String: Any] = ["plant_id": plant.uuidString, "revision": 2, "care_revision": 1,
                                     "condition_snapshot_id": snapshot.uuidString, "watermark": renamedAt]
        var foreign = receipt
        foreign["plant_id"] = UUID().uuidString
        var invalid = receipt
        invalid.removeValue(forKey: "condition_snapshot_id")
        let accepted = try syncJSON(receipt)
        let empty = try page(renamedAt, name: nil, revision: 2)
        let transport = CatalogueTransport([
            .http(200, try syncJSON(foreign)), .http(200, try syncJSON(invalid)),
            .http(200, accepted), .http(200, empty),
            .http(200, try page(renamedAt, name: "New name", revision: 2)),
            .http(200, accepted), .http(200, empty)
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        for _ in 0..<3 {
            let pending = try await repo.pendingPlantEdit(plantId: plant, context: lease)
            XCTAssertEqual(pending, command)
            let result = try await repo.retryPlantEdit(command, context: lease)
            XCTAssertNil(result)
        }
        _ = try await repo.collectionCards(context: lease)
        let renamed = try await repo.retryPlantEdit(command, context: lease)
        XCTAssertEqual(renamed?.personalName, "New name")
        XCTAssertEqual(renamed?.mainPhotoId, photo)
        XCTAssertEqual(renamed?.currentConditionSnapshotId, snapshot)
        XCTAssertEqual(renamed?.careRevision, 1)
        let remaining = try await repo.pendingPlantEdit(plantId: plant, context: lease)
        XCTAssertNil(remaining)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "POST", "GET", "GET", "POST", "GET"])
        for request in requests where request.httpMethod == "POST" {
            XCTAssertEqual(request.httpBody, original)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), command.operationId.uuidString.lowercased())
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Installation-Credential"))
        }
    }

    @MainActor
    func testPlantDeletionReplaysAfterRestartAndWaitsForTheSelectedTombstone() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let neighbour = UUID()
        let deletionJob = UUID()
        let deletionTime = "2026-11-03T09:10:00.000001+00:00"
        func active(_ id: UUID) -> [String: Any] {
            var row = syncChange(id: id.uuidString)
            row["data"] = ["id": id.uuidString, "plant_id": "monstera_deliciosa", "revision": 1, "care_revision": 1] as [String: Any]
            return row
        }
        func tombstone(_ id: UUID) -> [String: Any] {
            var row = syncChange(deletionTime, id: id.uuidString)
            row["data"] = NSNull()
            row["deleted_at"] = deletionTime
            return row
        }
        func page(_ until: String, changes: [[String: Any]]) throws -> String {
            var page = syncObject()
            page["until"] = until
            page["next_since"] = until
            page["changes"] = changes.sorted {
                ($0["updated_at"] as! String, $0["id"] as! String)
                    < ($1["updated_at"] as! String, $1["id"] as! String)
            }
            return try syncJSON(page)
        }
        let baseline = try page(syncUntil, changes: [active(serverPlantId), active(neighbour)])
        let initial = CatalogueTransport([.http(200, baseline), .network])
        let initialAPI = client(initial)
        await initialAPI.bindSyncSession(syncSession)
        let firstLease = try await initialAPI.captureSyncContext(ownerId: syncOwner)
        let initialStore = LocalStore(modelContainer: try diskContainer(url))
        let initialRepo = CollectionRepository(
            store: initialStore, apiClient: initialAPI, syncEngine: SyncEngine(store: initialStore, apiClient: initialAPI)
        )
        _ = try await initialRepo.collectionCards(context: firstLease)
        let targetFlow = UUID()
        let neighbourFlow = UUID()
        let unsentFlow = UUID()
        let input = CatalogueInput(speciesSlug: "fixture_collection_cap", personalName: "Saved plant")
        func saveCatalogueInput(flow: UUID, plantId: UUID?) async throws -> UUID {
            let checkpoint = try await initialStore.checkpointCatalogueInput(
                input, flowId: flow, operationId: UUID(), context: firstLease, authority: initialAPI.syncAuthority
            )
            if let plantId {
                _ = try await queueCreate(checkpoint.envelope, ownerId: syncOwner, in: initialStore)
                try await initialStore.acknowledgeCatalogueCreate(
                    checkpoint.envelope, receipt: decodedCreateReceipt(["plant_id": plantId.uuidString]),
                    context: firstLease, authority: initialAPI.syncAuthority
                )
            }
            return checkpoint.operationId
        }
        let targetCreate = try await saveCatalogueInput(flow: targetFlow, plantId: serverPlantId)
        let neighbourCreate = try await saveCatalogueInput(flow: neighbourFlow, plantId: neighbour)
        _ = try await saveCatalogueInput(flow: unsentFlow, plantId: nil)
        let localCare = try await initialStore.enqueueCommand(
            ownerId: syncOwner, plantId: serverPlantId, commandName: "care.record", payloadJSON: "{}"
        )
        let otherCare = try await initialStore.enqueueCommand(
            ownerId: syncOwner, plantId: neighbour, commandName: "care.record", payloadJSON: "{}"
        )
        let command = try await initialRepo.enqueuePlantDeletion(plantId: serverPlantId, context: firstLease)
        let reused = try await initialRepo.enqueuePlantDeletion(plantId: serverPlantId, context: firstLease)
        XCTAssertEqual(reused, command)
        guard case .pending = try await initialRepo.retryPlantDeletion(command, context: firstLease)
        else { return XCTFail("Lost response must retain the delete envelope") }
        let initialRequests = await initial.capturedRequests()
        XCTAssertEqual(initialRequests.map(\.httpMethod), ["GET", "POST"])
        XCTAssertEqual(try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(initialRequests.last?.httpBody)), command)

        let receipt = try syncJSON([
            "plant_id": serverPlantId.uuidString, "deletion_job_id": deletionJob.uuidString,
            "state": "deleting", "watermark": deletionTime
        ])
        let wrongReceipt = try syncJSON([
            "plant_id": neighbour.uuidString, "deletion_job_id": deletionJob.uuidString,
            "state": "deleting", "watermark": deletionTime
        ])
        let empty = try page(deletionTime, changes: [])
        let complete = try page(deletionTime, changes: [tombstone(serverPlantId), active(neighbour)])
        let transport = CatalogueTransport([
            .http(200, wrongReceipt),
            .http(200, receipt), .http(200, empty),
            .http(200, complete), .http(200, receipt), .http(200, empty)
        ])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
        let restored = try await repo.pendingPlantDeletion(plantId: serverPlantId, context: lease)
        XCTAssertEqual(restored, command)
        for _ in 0..<2 {
            guard case .pending = try await repo.retryPlantDeletion(command, context: lease)
            else { return XCTFail("A foreign receipt or sync without the tombstone cannot acknowledge deletion") }
        }
        let pendingConfirmation = try await store.catalogueCreateConfirmation(ownerId: syncOwner, operationId: targetCreate)
        XCTAssertNotNil(pendingConfirmation)
        let finalSnapshot = try await repo.collectionCards(context: lease)
        XCTAssertEqual(finalSnapshot.cards.map(\.id), [neighbour])
        let remaining = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertEqual(remaining.map(\.operationId), [otherCare.operationId])
        XCTAssertFalse(remaining.contains { $0.operationId == localCare.operationId })
        let deletedConfirmation = try await store.catalogueCreateConfirmation(
            ownerId: syncOwner, operationId: targetCreate
        )
        XCTAssertNil(deletedConfirmation)
        let neighbourConfirmation = try await store.catalogueCreateConfirmation(
            ownerId: syncOwner, operationId: neighbourCreate
        )
        XCTAssertEqual(neighbourConfirmation?.receipt.plantId, neighbour)
        let deletedFlow = await CatalogueSaveModel.restore(
            store: store, apiClient: api, repository: repo, ownerId: syncOwner,
            flowId: targetFlow, session: syncSession, isAnonymous: false
        )
        guard case .absent = deletedFlow else { return XCTFail("Deleted input must not resume after restart") }
        for flow in [neighbourFlow, unsentFlow] {
            let checkpoint = try await store.catalogueInputCheckpoint(
                flowId: flow, context: lease, authority: api.syncAuthority
            )
            XCTAssertNotNil(checkpoint)
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "GET", "GET", "POST", "GET"])
        for request in requests where request.httpMethod == "POST" {
            XCTAssertEqual(request.httpBody, initialRequests.last?.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), command.operationId.uuidString.lowercased())
        }
    }

    @MainActor
    func testBoundDiagnosisShowsQuotaExhaustionAndReturnsToPlantWithoutResult() async throws {
        let photo = UUID()
        let url = "https://example.invalid/functions/v1/plants-api/media/uploads/\(photo.uuidString.lowercased())?sig=mock"
        let ready = #"{"photo_asset_id":"\#(photo.uuidString)","state":"ready"}"#
        let exhausted = #"{"error":{"code":"QUOTA_EXHAUSTED","message":"Analysis quota is exhausted.","retryable":false}}"#
        let transport = CatalogueTransport([
            .http(200, diagnosisTicket(url: url, photoId: photo)), .http(200, ready), .http(429, exhausted)
        ])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let owner = accessOwner
        let target = RepeatDiagnosisTarget(plantId: serverPlantId, ownerId: owner)
        let service = PhotoAnalysisService(api: api, repeatDiagnosisTarget: target) {
            try await api.captureSyncContext(ownerId: owner)
        }
        let model = AnalysisFlowModel(repeatDiagnosisTarget: target, service: service)
        model.preparedPhoto = PreparedAnalysisPhoto(
            cloudNormalizedJPEG: Data([1, 2]), aiVisionJPEG: Data([1, 2]),
            aiWidthPx: 1, aiHeightPx: 1, originalByteCount: 2
        )
        let analysis = try XCTUnwrap(model.submitAnalysis(locale: .en))
        await analysis.value

        XCTAssertEqual(model.analysisError, "analysis.error.quota_exhausted")
        XCTAssertEqual(model.repeatDiagnosisTarget, target)
        XCTAssertNil(model.preliminaryResult)
        XCTAssertNil(model.recordableFirstAid)
        XCTAssertFalse(model.isAnalyzing)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "POST"])
        let create = try XCTUnwrap(requests.last?.httpBody)
        let body = try JSONDecoder().decode([String: String].self, from: create)
        XCTAssertEqual(body["target_plant_id"], target.plantId.uuidString.lowercased())
        XCTAssertEqual(body["photo_asset_id"], photo.uuidString.lowercased())
    }

    @MainActor
    func testStagingRepeatDiagnosisReplaysSameUploadAndRejectsOtherPhotoOrOwner() async throws {
        let target = RepeatDiagnosisTarget(plantId: serverPlantId, ownerId: accessOwner)
        let photo = UUID(), jobId = UUID()
        let url = "https://example.invalid/functions/v1/plants-api/media/uploads/\(photo.uuidString.lowercased())?sig=mock"
        let ready = #"{"photo_asset_id":"\#(photo.uuidString)","state":"ready"}"#
        let result = #"{"analysis_id":"\#(UUID().uuidString)","job_id":"\#(jobId.uuidString)","kb_release_id":"\#(UUID().uuidString)","mode":"diagnosis","identification_status":"identified","plant_id":"monstera_deliciosa","genus_id":"monstera","diagnosis_status":"healthy","selected_condition_id":null,"candidates":[],"visual_markers":[],"evidence_basis":[],"limitations":[],"first_action_summary":null,"control_interval_days":null,"plan_availability":"diagnosis_unresolved","analysis_receipt":"test-receipt","plant_display_name":"Monstera deliciosa"}"#
        let transport = CatalogueTransport([
            .http(200, diagnosisTicket(url: url, photoId: photo)), .http(200, ready), .network,
            .http(200, diagnosisJob(id: jobId, status: "queued", target: (target.plantId, photo))),
            .http(200, diagnosisJob(id: jobId, status: "running", target: (target.plantId, UUID()))),
            .http(200, diagnosisJob(id: jobId, status: "succeeded", result: result, target: (target.plantId, photo))
                .replacingOccurrences(of: #""quota_state":"reserved""#, with: #""quota_state":"consumed""#))
        ])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let owner = accessOwner
        let service = PhotoAnalysisService(api: api, repeatDiagnosisTarget: target) {
            try await api.captureSyncContext(ownerId: owner)
        }
        let prepared = PreparedAnalysisPhoto(
            cloudNormalizedJPEG: Data([1, 2]), aiVisionJPEG: Data([1, 2]),
            aiWidthPx: 1, aiHeightPx: 1, originalByteCount: 2
        )
        let other = RepeatDiagnosisTarget(plantId: target.plantId, ownerId: UUID())
        let wrongOwnerService = PhotoAnalysisService(api: api, repeatDiagnosisTarget: other) {
            try await api.captureSyncContext(ownerId: owner)
        }
        let wrongOwner = AnalysisServiceRequest(
            operationId: UUID(), flowId: UUID(), mode: .diagnosis, intent: .problem, photo: prepared,
            conditions: CareConditionsInput(), locale: .en, repeatDiagnosisTarget: other
        )
        do {
            _ = try await wrongOwnerService.analyze(wrongOwner)
            XCTFail("Sent a repeat request with another owner's lease")
        } catch AnalysisServiceFailure.unavailable {}
        let before = await transport.capturedRequests()
        XCTAssertTrue(before.isEmpty)

        let input = AnalysisServiceRequest(
            operationId: operationId, flowId: UUID(), mode: .diagnosis, intent: .problem, photo: prepared,
            conditions: CareConditionsInput(), locale: .en, repeatDiagnosisTarget: target
        )
        do {
            _ = try await service.analyze(input)
            XCTFail("Expected the create response to be lost")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        do {
            _ = try await service.analyze(input)
            XCTFail("Accepted a poll response for a different photo")
        } catch AnalysisHTTPError.invalidResponse {}
        let finished = try await service.analyze(input)
        XCTAssertEqual(finished.analysis?.jobId, jobId)
        XCTAssertEqual(finished.analysis?.plantId, "monstera_deliciosa")
        XCTAssertEqual(finished.uploadedPhotoId, photo)

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "POST", "POST", "GET", "GET"])
        guard requests.count == 6 else { return }
        XCTAssertEqual(requests[2].httpBody, requests[3].httpBody)
        let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[2].httpBody))
        XCTAssertEqual(body, [
            "operation_id": operationId.uuidString.lowercased(), "mode": "diagnosis",
            "photo_asset_id": photo.uuidString.lowercased(), "target_plant_id": target.plantId.uuidString.lowercased(),
            "flow_id": input.flowId.uuidString.lowercased()
        ])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Client-Locale") == "en" })
        XCTAssertTrue(requests.suffix(2).allSatisfy { $0.url?.lastPathComponent == jobId.uuidString.lowercased() })
    }
}
#endif

extension CollectionWireTests {
    private func careReconcilePage(
        _ at: String, changes: [[String: Any]] = [], hour: Int = 9
    ) throws -> String {
        var page = syncObject()
        page["until"] = at
        page["next_since"] = at
        page["profile"] = ["preferred_locale": "en", "reminder_hour_local": hour,
                           "trial_reminder_enabled": false] as [String: Any]
        page["changes"] = changes
        return try syncJSON(page)
    }

    @MainActor
    func testCareReconcileRestoresLostWateringWithoutActionSpecificRetry() async throws {
        for access in ["none", "expired"] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = SavedWateringReplayTransport(
                baseline: try savedWateringBaseline(access), plantId: serverPlantId
            )
            let frozen: CommandEnvelopeDTO
            do {
                let api = client(transport)
                await api.bindSyncSession(try profileSession())
                let lease = try await api.captureSyncContext(ownerId: syncOwner)
                let store = LocalStore(modelContainer: try diskContainer(url))
                let engine = SyncEngine(store: store, apiClient: api)
                _ = try await engine.pullDelta(for: syncOwner)
                let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
                try await repo.enqueueWateringEdit(.record, plantId: serverPlantId, context: lease)
                let queued = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
                frozen = try XCTUnwrap(queued)
                let outcome = try await repo.reconcilePendingCare(context: lease)
                XCTAssertEqual(outcome, .pending)
                let pending = try await store.pendingOutboxEntries(for: syncOwner)
                XCTAssertEqual(pending.map(\.envelope), [frozen])
            }
            // Reopen a new disk container and API/session; no model or create proof retained.
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api,
                                            syncEngine: SyncEngine(store: store, apiClient: api))
            let outcome = try await repo.reconcilePendingCare(context: lease)
            XCTAssertEqual(outcome, .completed)
            let posts = await transport.capturedRequests().filter { $0.httpMethod == "POST" }
            XCTAssertEqual(posts.count, 2)
            XCTAssertEqual(posts.first?.httpBody, posts.last?.httpBody)
            XCTAssertEqual(posts.first?.value(forHTTPHeaderField: "X-Operation-Id"),
                           posts.last?.value(forHTTPHeaderField: "X-Operation-Id"))
            let count = await transport.journalCount()
            XCTAssertEqual(count, 1)
            let remaining = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertTrue(remaining.isEmpty)
            let rows = try await repo.collectionWateringHistory(plantId: serverPlantId, context: lease)
            XCTAssertEqual(rows.map(\.operationId), [frozen.operationId])
        }
    }

    @MainActor
    func testCareReconcileRoutineAndProfileUseTypedCanonicalAcknowledgements() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = try routineCompletionCommand()
        let routinePage = try syncJSON(routineCompletionPage(operation: command.envelope.operationId))
        let transport = CatalogueTransport([
            .http(200, try syncJSON(routineCompletionBaseline())),
            .http(200, try syncJSON(routineCompletionReceipt())), .http(200, routinePage),
            .http(200, try profileResponse(hour: 17, receipt: true)),
            .http(200, try careReconcilePage("2026-11-03T09:11:00Z", hour: 17)),
            .http(200, try careReconcilePage("2026-11-03T09:12:00Z", hour: 17))
        ])
        let api = client(transport)
        await api.bindSyncSession(try profileSession())
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let engine = SyncEngine(store: store, apiClient: api)
        _ = try await engine.pullDelta(for: syncOwner)
        // Seed the exact accepted routine fixture through the existing typed store helper.
        _ = try await store.enqueueRoutineCompletion(command, context: lease, authority: api.syncAuthority)
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
        let hour = try await repo.enqueueProfileReminderHour(reminderHourLocal: 17, context: lease)
        let outcome = try await repo.reconcilePendingCare(context: lease)
        XCTAssertEqual(outcome, .completed)
        let rows = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertTrue(rows.isEmpty)
        let profile = try await store.syncedProfile(ownerId: syncOwner)
        XCTAssertEqual(profile?.reminderHourLocal, 17)
        let receipt = try JSONDecoder().decode(RoutineSoilCheckCompletionReceipt.self,
                                               from: Data(try syncJSON(routineCompletionReceipt()).utf8))
        try await store.validateRoutineCompletion(receipt, command: command,
                                                 context: lease, authority: api.syncAuthority)
        let requests = await transport.capturedRequests()
        let posts = requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.map { $0.value(forHTTPHeaderField: "X-Operation-Id") },
                       [command.envelope.operationId.uuidString.lowercased(),
                        hour.envelope.operationId.uuidString.lowercased()])
        XCTAssertEqual(requests.last?.httpMethod, "GET") // Final canonical pull, not send count alone.
    }

    @MainActor
    func testCareReconcileCannotBypassUnsupportedOrPendingDeletion() async throws {
        for blocker in ["fixture.unsupported", PlantDeleteReceipt.commandName] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = CatalogueTransport([.http(200, try savedWateringBaseline())])
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            _ = try await store.enqueueCommand(ownerId: syncOwner, plantId: serverPlantId,
                                                commandName: blocker, payloadJSON: "{}")
            let command = try ManualWateringAction.record.envelope(plantId: serverPlantId)
            _ = try await store.enqueueCommand(operationId: command.operationId, ownerId: syncOwner,
                plantId: serverPlantId, commandName: command.commandName, payloadJSON: command.payloadJSON)
            let foreign = try ManualWateringAction.record.envelope(plantId: UUID())
            _ = try await store.enqueueCommand(operationId: foreign.operationId, ownerId: otherSyncOwner,
                plantId: foreign.plantId, commandName: foreign.commandName, payloadJSON: foreign.payloadJSON)
            let before = try await store.pendingOutboxEntries(for: syncOwner)
            let repo = CollectionRepository(store: store, apiClient: api,
                                            syncEngine: SyncEngine(store: store, apiClient: api))
            let outcome = try await repo.reconcilePendingCare(context: lease)
            XCTAssertEqual(outcome, .pending)
            let after = try await store.pendingOutboxEntries(for: syncOwner)
            let other = try await store.pendingOutboxEntries(for: otherSyncOwner)
            XCTAssertEqual(after, before)
            XCTAssertEqual(other.map(\.envelope), [foreign])
            let requests = await transport.capturedRequests()
            XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        }
    }

    @MainActor
    func testCareReconcileTypedConditionEditUnblocksFollowingWateringInSequence() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = UUID(), fact = UUID()
        let editedAt = "2026-11-03T09:10:00Z", wateredAt = "2026-11-03T09:11:00Z"
        var condition = syncChange(editedAt, id: snapshot.uuidString, entity: "condition_snapshots")
        condition["data"] = ["id": snapshot.uuidString, "plant_id": serverPlantId.uuidString,
                             "watering_code": "weekly"]
        var card = syncChange(editedAt, id: serverPlantId.uuidString)
        card["data"] = ["id": serverPlantId.uuidString, "revision": 2, "care_revision": 2,
                        "current_condition_snapshot_id": snapshot.uuidString] as [String: Any]
        let editReceipt = try syncJSON(["plant_id": serverPlantId.uuidString, "revision": 2,
            "care_revision": 2, "condition_snapshot_id": snapshot.uuidString, "watermark": editedAt])
        let edit = try PlantEditCommand.make(plantId: serverPlantId, change: .watering(.weekly)).envelope
        let water = try ManualWateringAction.record.envelope(plantId: serverPlantId)
        var entry = syncChange(wateredAt, id: fact.uuidString, entity: "care_entries")
        entry["data"] = ["id": fact.uuidString, "plant_id": serverPlantId.uuidString,
            "operation_id": water.operationId.uuidString, "task_id": NSNull(), "action_code": "water",
            "state": "active", "timezone": "UTC", "occurred_at": "2026-11-02T07:00:00Z",
            "occurred_local_date": "2026-11-02"] as [String: Any]
        var waterReceipt = manualWateringReceipt(entryId: fact, state: "active")
        waterReceipt["watermark"] = wateredAt
        let transport = CatalogueTransport([
            .http(200, try savedWateringBaseline()),
            .http(200, editReceipt), .http(200, try careReconcilePage(editedAt, changes: [condition, card])),
            .http(200, try syncJSON(waterReceipt)),
            .http(200, try careReconcilePage(wateredAt, changes: [entry])),
            .http(200, try careReconcilePage("2026-11-03T09:12:00Z"))
        ])
        let api = client(transport)
        await api.bindSyncSession(try profileSession())
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let engine = SyncEngine(store: store, apiClient: api)
        _ = try await engine.pullDelta(for: syncOwner)
        // Fixture persistence preserves edit-before-care ordering across one drain snapshot.
        for command in [edit, water] {
            _ = try await store.enqueueCommand(operationId: command.operationId, ownerId: syncOwner,
                plantId: serverPlantId, commandName: command.commandName, payloadJSON: command.payloadJSON)
        }
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
        let outcome = try await repo.reconcilePendingCare(context: lease)
        XCTAssertEqual(outcome, .completed)
        let pending = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertTrue(pending.isEmpty)
        let posts = await transport.capturedRequests().filter { $0.httpMethod == "POST" }
        let commands = try posts.map { try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(commands, [edit, water])
        let updated = try await store.syncedCollectionCard(plantId: serverPlantId,
                                                         context: lease, authority: api.syncAuthority)
        let savedCard = try XCTUnwrap(updated)
        XCTAssertEqual(savedCard.careRevision, 2)
        let saved = try await repo.syncedPlantConditions(for: savedCard, context: lease)
        XCTAssertEqual(saved?.watering, .weekly)
        let history = try await repo.collectionWateringHistory(plantId: serverPlantId, context: lease)
        XCTAssertEqual(history.map(\.operationId), [water.operationId])
    }

    @MainActor
    func testCareReconcileBusyGuardIncludesFinalCanonicalPull() async throws {
        for cancel in [false, true] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = SuspendedCollectionTransport(try syncJSON(syncObject()))
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let repo = CollectionRepository(store: store, apiClient: api,
                                            syncEngine: SyncEngine(store: store, apiClient: api))
            let running = Task { try await repo.reconcilePendingCare(context: lease) }
            await transport.waitForRequest() // No queue: this is the final GET, not a send.
            let busy = try await repo.reconcilePendingCare(context: lease)
            XCTAssertEqual(busy, .busy)
            if cancel { running.cancel() }
            await transport.resume()
            do {
                let outcome = try await running.value
                XCTAssertFalse(cancel, "Cancelled final pull must not publish a successful pass")
                XCTAssertEqual(outcome, .completed)
            } catch is CancellationError {
                XCTAssertTrue(cancel)
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
        }
    }

    @MainActor
    func testCareReconcileBusyOwnerABAAndCancellationPreserveExactDiskQueue() async throws {
        for mode in ["owner", "aba", "cancel"] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = SuspendedCollectionTransport(try syncJSON(routineCompletionReceipt()))
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let command = try routineCompletionCommand().envelope
            _ = try await store.enqueueCommand(operationId: command.operationId, ownerId: syncOwner,
                plantId: serverPlantId, commandName: command.commandName, payloadJSON: command.payloadJSON)
            let before = try await store.pendingOutboxEntries(for: syncOwner)
            let repo = CollectionRepository(store: store, apiClient: api,
                                            syncEngine: SyncEngine(store: store, apiClient: api))
            let running = Task { try await repo.reconcilePendingCare(context: lease) }
            await transport.waitForRequest()
            let busy = try await repo.reconcilePendingCare(context: lease)
            XCTAssertEqual(busy, .busy)
            if mode == "cancel" { running.cancel() }
            else {
                await api.bindSyncSession(try profileSession(ownerId: otherSyncOwner))
                if mode == "aba" { await api.bindSyncSession(try profileSession()) }
            }
            await transport.resume()
            do {
                _ = try await running.value
                XCTFail("Stale or cancelled care reconciliation reported success: \(mode)")
            } catch is CancellationError {
                XCTAssertEqual(mode, "cancel")
            } catch SyncWireValidationError.invalidSession {
                XCTAssertNotEqual(mode, "cancel")
            }
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let after = try await reopened.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(after, before)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"),
                           "Bearer \(lease.session!.accessToken)")
        }
    }
}

extension CollectionWireTests {
    @MainActor
    func testCareLifecycleBusyIdleRaceCoalescesLatestRequestWithoutSelfRetries() async throws {
        let coordinator = CareLifecycleCoordinator()
        var calls = 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            coordinator.request {
                calls += 1
                if calls == 1 {
                    // Deliberately signal before .busy is returned. No timer/poll is used.
                    coordinator.didBecomeIdle()
                    return .busy
                }
                XCTAssertEqual(calls, 2)
                if calls == 2 { done.resume() }
                return .pending
            }
        }
        XCTAssertEqual(calls, 2)
        // A successful/pending pass must not convert its own idle event into more work.
        coordinator.didBecomeIdle()
        coordinator.didBecomeIdle()
        var release: CheckedContinuation<Void, Never>?
        var cancelledOld = false
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            coordinator.request {
                await withCheckedContinuation { continuation in
                    release = continuation
                    entered.resume()
                }
                cancelledOld = Task.isCancelled
                return .busy // A cancelled operation can still report busy late.
            }
        }
        var obsolete = 0, latest = 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            coordinator.request(replacingCurrent: true) { obsolete += 1; return .completed }
            coordinator.request(replacingCurrent: true) { latest += 1; done.resume(); return .completed }
            release?.resume()
        }
        XCTAssertTrue(cancelledOld)
        XCTAssertEqual(obsolete, 0)
        XCTAssertEqual(latest, 1)
        XCTAssertEqual(calls, 2)
        var staleCalls = 0
        var releaseStale: CheckedContinuation<Void, Never>?
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            coordinator.request {
                staleCalls += 1
                if staleCalls == 1 {
                    await withCheckedContinuation { continuation in
                        releaseStale = continuation
                        entered.resume()
                    }
                }
                return .busy
            }
        }
        let cancellation = coordinator.suspend()
        releaseStale?.resume()
        await cancellation?.value
        coordinator.didBecomeIdle()
        coordinator.didBecomeIdle()
        XCTAssertEqual(staleCalls, 1, "Late busy must not revive the suspended lifecycle request")
    }
}

extension CollectionWireTests {
    @MainActor
    func testCareTerminalWateringRejectionSurvivesRestartUntilExactExplicitRetry() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rejection = try syncJSON(["error": ["code": "CONFLICT", "message": "Fixture rejection", "retryable": false]])
        let empty = try careReconcilePage(syncUntil)
        let command: CommandEnvelopeDTO
        let rejectedSnapshot: OutboxEntrySnapshot
        let later = try PlantEditCommand.make(plantId: serverPlantId, change: .watering(.weekly)).envelope
        let foreign = try ManualWateringAction.record.envelope(plantId: UUID())
        let foreignBefore: [OutboxEntrySnapshot]
        let firstTransport = CatalogueTransport([
            .http(200, try savedWateringBaseline()), .http(409, rejection), .http(200, empty)
        ])
        do {
            let api = client(firstTransport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let engine = SyncEngine(store: store, apiClient: api)
            _ = try await engine.pullDelta(for: syncOwner)
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
            try await repo.enqueueWateringEdit(.record, plantId: serverPlantId, context: lease)
            let pending = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
            command = try XCTUnwrap(pending)
            for (owner, envelope) in [(syncOwner, later), (otherSyncOwner, foreign)] {
                _ = try await store.enqueueCommand(operationId: envelope.operationId, ownerId: owner,
                    plantId: envelope.plantId, commandName: envelope.commandName, payloadJSON: envelope.payloadJSON)
            }
            foreignBefore = try await store.pendingOutboxEntries(for: otherSyncOwner)
            let outcome = try await repo.reconcilePendingCare(context: lease)
            XCTAssertEqual(outcome, .pending)
            let retained = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(retained.map(\.envelope), [command, later])
            rejectedSnapshot = try XCTUnwrap(retained.first)
            XCTAssertEqual(rejectedSnapshot.envelope, command)
            XCTAssertEqual(rejectedSnapshot.retryCount, 1)
            XCTAssertEqual(rejectedSnapshot.lastAPIError?.error.code, "CONFLICT")
            let marker = try JSONDecoder().decode(PersistedWateringRejection.self,
                from: Data(try XCTUnwrap(rejectedSnapshot.lastError).utf8))
            XCTAssertTrue(marker.requiresExplicitWateringRetry)
            XCTAssertEqual(marker.wateringRejectionVersion, 1)
            XCTAssertTrue(PersistedWateringRejection.requiresReview(rejectedSnapshot))
        }
        // New container, API, engine and lease: no in-memory failed-action state survives.
        let transport = CatalogueTransport([.http(200, empty), .http(409, rejection)])
        let api = client(transport)
        await api.bindSyncSession(try profileSession())
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let engine = SyncEngine(store: store, apiClient: api)
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
        let restored = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertEqual(restored.first, rejectedSnapshot)
        let review = try await repo.pendingWateringRecordRequiresReview(command, context: lease)
        XCTAssertTrue(review)
        let automatic = try await repo.reconcilePendingCare(context: lease)
        let generic = try await engine.flushOutbox(context: lease)
        XCTAssertEqual(automatic, .pending)
        XCTAssertEqual(generic, 0)
        let afterAutomatic = try await store.pendingOutboxEntries(for: syncOwner)
        let foreignAfter = try await store.pendingOutboxEntries(for: otherSyncOwner)
        XCTAssertEqual(afterAutomatic, restored) // Exact body, retryCount, error and ordering unchanged.
        XCTAssertEqual(foreignAfter, foreignBefore)
        let automaticRequests = await transport.capturedRequests()
        XCTAssertEqual(automaticRequests.map(\.httpMethod), ["GET"])

        // An explicit retry sends the frozen intent once; terminal rejection removes only it.
        let retry = try await repo.retrySavedPlantWatering(command, context: lease)
        XCTAssertEqual(retry, .rejected)
        let afterRetry = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertEqual(afterRetry, Array(restored.dropFirst()))
        let firstRequests = await firstTransport.capturedRequests()
        let retryRequests = await transport.capturedRequests()
        let firstPOST = try XCTUnwrap(firstRequests.first { $0.httpMethod == "POST" })
        let retryPOSTs = retryRequests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(retryPOSTs.count, 1)
        XCTAssertEqual(retryPOSTs.first?.httpBody, firstPOST.httpBody)
        XCTAssertEqual(retryPOSTs.first?.value(forHTTPHeaderField: "X-Operation-Id"),
                       firstPOST.value(forHTTPHeaderField: "X-Operation-Id"))
        let noLongerReview = try await repo.pendingWateringRecordRequiresReview(command, context: lease)
        XCTAssertFalse(noLongerReview)
        try await repo.enqueueWateringEdit(.record, plantId: serverPlantId, context: lease)
        let newIntent = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
        XCTAssertNotEqual(try XCTUnwrap(newIntent).operationId, command.operationId)

        // A plain old API error, malformed/versioned data, or another command never acquires this meaning.
        func snapshot(_ raw: String, commandName: String? = nil) -> OutboxEntrySnapshot {
            OutboxEntrySnapshot(operationId: rejectedSnapshot.operationId, ownerId: rejectedSnapshot.ownerId,
                plantId: rejectedSnapshot.plantId, commandName: commandName ?? rejectedSnapshot.commandName,
                payloadJSON: rejectedSnapshot.payloadJSON, sequenceNumber: rejectedSnapshot.sequenceNumber,
                retryCount: rejectedSnapshot.retryCount, lastError: raw, createdAt: rejectedSnapshot.createdAt)
        }
        let stored = try XCTUnwrap(rejectedSnapshot.lastError)
        var markerObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
        var wrongVersion = markerObject
        wrongVersion["wateringRejectionVersion"] = 2
        var retryable = markerObject
        retryable["error"] = ["code": "CONFLICT", "message": "Try later", "retryable": true]
        markerObject["requiresExplicitWateringRetry"] = false
        var malformed = wrongVersion
        malformed["wateringRejectionVersion"] = "1"
        for raw in [rejection, "{malformed", try syncJSON(malformed), try syncJSON(wrongVersion),
                    try syncJSON(retryable), try syncJSON(markerObject)] {
            XCTAssertFalse(PersistedWateringRejection.requiresReview(snapshot(raw)), raw)
        }
        XCTAssertFalse(PersistedWateringRejection.requiresReview(
            snapshot(stored, commandName: ManualWateringAction.undoCommand)))
    }

    @MainActor
    func testAcceptedWateringReceiptThenForbiddenCanonicalReadRemainsReplayable() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fact = UUID(), watermark = "2026-11-03T09:10:00.000001+00:00"
        let command = try ManualWateringAction.record.envelope(plantId: serverPlantId)
        var receipt = manualWateringReceipt(entryId: fact, state: "active")
        receipt["watermark"] = watermark
        var row = syncChange(watermark, id: fact.uuidString, entity: "care_entries")
        row["data"] = ["id": fact.uuidString, "plant_id": serverPlantId.uuidString,
            "operation_id": command.operationId.uuidString, "task_id": NSNull(), "action_code": "water",
            "state": "active", "timezone": "UTC", "occurred_at": "2026-11-02T07:00:00Z",
            "occurred_local_date": "2026-11-02"] as [String: Any]
        let forbidden = try syncJSON(["error": ["code": "FORBIDDEN", "message": "Canonical read failed", "retryable": false]])
        let accepted = try syncJSON(receipt)
        let transport = CatalogueTransport([
            .http(200, try savedWateringBaseline()),
            .http(200, accepted), .http(403, forbidden), .http(403, forbidden),
            .http(200, accepted), .http(200, try careReconcilePage(watermark, changes: [row])),
            .http(200, try careReconcilePage(watermark))
        ])
        let api = client(transport)
        await api.bindSyncSession(try profileSession())
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let engine = SyncEngine(store: store, apiClient: api)
        _ = try await engine.pullDelta(for: syncOwner)
        _ = try await store.enqueueCommand(operationId: command.operationId, ownerId: syncOwner,
            plantId: serverPlantId, commandName: command.commandName, payloadJSON: command.payloadJSON)
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
        do {
            _ = try await repo.reconcilePendingCare(context: lease)
            XCTFail("The outer canonical read should fail too")
        } catch let error as APIErrorResponse {
            XCTAssertEqual(error.error.code, "FORBIDDEN")
        }
        let pending = try await store.pendingOutboxEntries(for: syncOwner)
        let retained = try XCTUnwrap(pending.first)
        XCTAssertEqual(pending.map(\.envelope), [command])
        XCTAssertEqual(retained.lastAPIError?.error.code, "FORBIDDEN")
        XCTAssertFalse(PersistedWateringRejection.requiresReview(retained))
        let review = try await repo.pendingWateringRecordRequiresReview(command, context: lease)
        XCTAssertFalse(review) // The receipt was accepted; a failed read must not become terminal rejection.
        let replayOutcome = try await repo.reconcilePendingCare(context: lease)
        XCTAssertEqual(replayOutcome, .completed)
        let remaining = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertTrue(remaining.isEmpty)
        let history = try await repo.collectionWateringHistory(plantId: serverPlantId, context: lease)
        XCTAssertEqual(history.map(\.operationId), [command.operationId])
        let requests = await transport.capturedRequests()
        let posts = requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.first?.httpBody, posts.last?.httpBody)
        XCTAssertEqual(posts.first?.value(forHTTPHeaderField: "X-Operation-Id"),
                       posts.last?.value(forHTTPHeaderField: "X-Operation-Id"))
    }

    @MainActor
    func testPostSaveExplicitWateringRetryReviewsMarkerWithoutFalseConfirmation() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let create = createCommand()
        _ = try await seedEngineCreate(url, command: create)
        let command = try ManualWateringAction.record.envelope(plantId: serverPlantId)
        let fact = UUID(), watermark = "2026-11-03T09:10:00.000001+00:00"
        let rejection = try syncJSON(["error": ["code": "CONFLICT", "message": "Fixture rejection", "retryable": false]])
        var receipt = manualWateringReceipt(entryId: fact, state: "active")
        receipt["watermark"] = watermark
        var row = syncChange(watermark, id: fact.uuidString, entity: "care_entries")
        row["data"] = ["id": fact.uuidString, "plant_id": serverPlantId.uuidString,
            "operation_id": command.operationId.uuidString, "task_id": NSNull(), "action_code": "water",
            "state": "active", "timezone": "UTC", "occurred_at": "2026-11-02T07:00:00Z",
            "occurred_local_date": "2026-11-02"] as [String: Any]
        let transport = CatalogueTransport([
            .http(200, try savedWateringBaseline()), .http(409, rejection),
            .http(200, try careReconcilePage(syncUntil)), .http(409, rejection),
            .http(200, try syncJSON(receipt)), .http(200, try careReconcilePage(watermark, changes: [row]))
        ])
        let api = client(transport)
        await api.bindSyncSession(try profileSession())
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        // Persist the real create receipt using the existing guarded ACK, not a hand-built confirmation.
        try await store.acknowledgeCatalogueCreate(
            create, receipt: decodedCreateReceipt(), context: lease, authority: api.syncAuthority
        )
        let saved = try await store.catalogueCreateConfirmation(ownerId: syncOwner, operationId: create.operationId)
        let confirmation = try XCTUnwrap(saved)
        let engine = SyncEngine(store: store, apiClient: api)
        _ = try await engine.pullDelta(for: syncOwner)
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
        try await store.enqueueManualWatering(command, context: lease, authority: api.syncAuthority)
        let background = try await repo.reconcilePendingCare(context: lease)
        XCTAssertEqual(background, .pending)
        let initiallyMarked = try await repo.pendingWateringRecordRequiresReview(command, context: lease)
        XCTAssertTrue(initiallyMarked)
        let rejected = try await repo.submitManualWatering(command, confirmation: confirmation, context: lease)
        XCTAssertFalse(rejected)
        let pending = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertEqual(pending.map(\.envelope), [command])
        let retained = try XCTUnwrap(pending.first)
        XCTAssertEqual(retained.retryCount, 2)
        XCTAssertTrue(PersistedWateringRejection.requiresReview(retained))
        XCTAssertEqual(retained.lastAPIError?.error.code, "CONFLICT")
        let confirmed = try await repo.submitManualWatering(command, confirmation: confirmation, context: lease)
        XCTAssertTrue(confirmed)
        let remaining = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertTrue(remaining.isEmpty)
        let history = try await repo.collectionWateringHistory(plantId: serverPlantId, context: lease)
        XCTAssertEqual(history.map(\.operationId), [command.operationId])
        let requests = await transport.capturedRequests()
        let posts = requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 3)
        let bodies = try posts.map { try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(bodies, [command, command, command])
        XCTAssertEqual(Set(posts.compactMap(\.httpBody)).count, 1)
    }
}

extension CollectionWireTests {
    @MainActor
    func testExplicitOrphanWateringRetryPersistsFrozenIdentityBeforeLostResponseAndReplays() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try ManualWateringAction.record.envelope(plantId: serverPlantId)
        let transport = SavedWateringReplayTransport(baseline: try savedWateringBaseline(), plantId: serverPlantId)
        do {
            let api = client(transport)
            await api.bindSyncSession(try profileSession())
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let engine = SyncEngine(store: store, apiClient: api)
            _ = try await engine.pullDelta(for: syncOwner)
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
            let initiallyEmpty = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertTrue(initiallyEmpty.isEmpty)
            // Explicit recovery starts with no queue row; the first POST commits but loses its response.
            let pending = try await repo.retryUncertainSavedPlantWatering(original, context: lease)
            XCTAssertEqual(pending, .pending)
            let durable = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(durable.map(\.envelope), [original])
        }
        let api = client(transport)
        await api.bindSyncSession(try profileSession())
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let repo = CollectionRepository(store: store, apiClient: api,
                                        syncEngine: SyncEngine(store: store, apiClient: api))
        let restored = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertEqual(restored.map(\.envelope), [original])
        let confirmed = try await repo.retryUncertainSavedPlantWatering(original, context: lease)
        XCTAssertEqual(confirmed, .confirmed)
        let remaining = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertTrue(remaining.isEmpty)
        let history = try await repo.collectionWateringHistory(plantId: serverPlantId, context: lease)
        XCTAssertEqual(history.map(\.operationId), [original.operationId])
        let requests = await transport.capturedRequests()
        let posts = requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        let commands = try posts.map { try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(commands, [original, original])
        XCTAssertEqual(posts.first?.httpBody, posts.last?.httpBody)
        XCTAssertEqual(posts.first?.value(forHTTPHeaderField: "X-Operation-Id"),
                       posts.last?.value(forHTTPHeaderField: "X-Operation-Id"))
        let factCount = await transport.journalCount()
        XCTAssertEqual(factCount, 1)
    }
}

private actor CareOverviewPagingTransport: PlantsAPITransport {
    private let first: CatalogueTransport
    private let rest: SuspendedCollectionTransport
    private var sentFirst = false

    init(first: String, rest: SuspendedCollectionTransport) {
        self.first = CatalogueTransport([.http(200, first)])
        self.rest = rest
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }

    func sendWithoutRedirect(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if !sentFirst {
            sentFirst = true
            return try await first.sendWithoutRedirect(request)
        }
        return try await rest.sendWithoutRedirect(request)
    }
}

extension CollectionWireTests {
    private func overviewRow(_ id: UUID, dated: Bool = false, controls: [[String: Any]] = []) -> [String: Any] {
        var card = dated ? careProjection(anchor: "2026-10-29", due: "2026-11-05") : careProjection()
        card["plant_id"] = id.uuidString
        if dated {
            card["routine_check"] = [
                "rule_id": operationId.uuidString, "care_revision": 2,
                "due_local_date": "2026-11-05", "anchor_local_date": "2026-10-29", "anchor_kind": "water"
            ]
        }
        return ["plant_id": id.uuidString, "care_revision": 2,
                "care_recommendation": card, "first_aid_controls": controls]
    }

    private func overviewControl() -> [String: Any] {
        [
            "control_id": operationId.uuidString, "action_entry_id": UUID().uuidString,
            "job_id": UUID().uuidString, "origin_analysis_id": UUID().uuidString,
            "kb_release_id": UUID().uuidString, "protocol_id": UUID().uuidString,
            "context_revision": 2, "action_id": "fixed_soil", "action_code": "check_soil",
            "policy": ["due_on": "2026-11-01", "interval_days": 7,
                       "source": ["url": "https://example.invalid/soil", "locator": "Published check"]] as [String: Any]
        ]
    }

    private func overviewPage(_ rows: [[String: Any]], next: UUID? = nil) -> [String: Any] {
        [
            "owner_id": syncOwner.uuidString, "server_now": "2026-11-19T10:00:00.000001Z",
            "owner_watermark": "2026-11-19T09:00:00.000001+00:00",
            "publication_fingerprint": String(repeating: "a", count: 64), "reminder_hour_local": 9,
            "automation_allowed": true, "verified_access_until": "2026-12-01T00:00:00.000001Z",
            "plants": rows, "next_after": next.map { $0.uuidString as Any } ?? NSNull()
        ]
    }

    private func readOverview(_ pages: [[String: Any]], limit: Int = 200) async throws -> CareOverviewSnapshot {
        let transport = CatalogueTransport(try pages.map { .http(200, try syncJSON($0)) })
        let api = client(transport)
        await api.bindSyncSession(try profileSession())
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        return try await api.fetchCareOverview(context: lease, limit: limit)
    }

    func testCareOverviewCompleteSiblingTransportAndFullWireFileRoundTrip() async throws {
        let ids = (1...201).map {
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0))!
        }
        let rows = ids.enumerated().map { index, id in
            overviewRow(id, dated: index == 0, controls: index == 0 ? [overviewControl()] : [])
        }
        let first = overviewPage(Array(rows.prefix(200)), next: ids[199])
        var second = overviewPage(Array(rows.suffix(1)))
        second["server_now"] = "2026-11-19T10:00:00.000002Z"
        let transport = CatalogueTransport([
            .http(200, try syncJSON(first)), .http(200, try syncJSON(second))
        ])
        let session = try profileSession()
        let api = client(transport)
        // Keep a stale configured bearer while the SDK authority holds the current session.
        await api.updateContext(installationCredential: "old-install", clientLocale: "pl", bearerToken: "old-token")
        api.syncAuthority.bind(session)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let snapshot = try await api.fetchCareOverview(context: lease)
        XCTAssertEqual(snapshot.plants.map(\.plantId), ids)
        XCTAssertEqual(snapshot.plants.count, 201)
        XCTAssertNil(try snapshot.plants[200].careRecommendation.validated(for: ids[200])?.nextCheck)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url?.absoluteString,
                       "https://example.invalid/functions/v1/care-overview?limit=200")
        XCTAssertEqual(requests.last?.url?.absoluteString,
                       "https://example.invalid/functions/v1/care-overview?limit=200&after=\(ids[199].uuidString.lowercased())")
        XCTAssertTrue(requests.allSatisfy {
            $0.httpMethod == "GET" && $0.httpBody == nil
                && $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(session.accessToken)"
                && $0.value(forHTTPHeaderField: "X-Client-Locale") == "pl"
                && $0.value(forHTTPHeaderField: "X-Installation-Credential") == nil
                && $0.value(forHTTPHeaderField: "Accept") == "application/json"
        })
        let nonRedirecting = await transport.nonRedirectingRequests
        XCTAssertEqual(nonRedirecting, 2)

        let originalZone = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        defer { NSTimeZone.default = originalZone }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        let restored = try JSONDecoder().decode(CareOverviewSnapshot.self, from: Data(contentsOf: file))
            .validated(for: syncOwner)
        XCTAssertEqual(restored.pages[0].ownerWatermark, first["owner_watermark"] as? String)
        XCTAssertEqual(restored.pages[0].verifiedAccessUntil, first["verified_access_until"] as? String)
        let card = try XCTUnwrap(restored.plants[0].careRecommendation.validated(for: ids[0]))
        XCTAssertEqual(card.nextCheck?.dueOn, "2026-11-05") // original overdue day, including west of UTC
        XCTAssertEqual(card.nextCheck?.anchorOn, "2026-10-29")
        XCTAssertEqual(card.nextCheck?.source.locator, "Soil check interval")
        XCTAssertEqual(card.source.url.absoluteString, "https://example.invalid/soil")
        XCTAssertEqual(card.routineContext?.plantId, ids[0])
        XCTAssertEqual(card.routineContext?.check.ruleId, operationId)
        XCTAssertEqual(card.routineContext?.check.careRevision, 2)
        XCTAssertEqual(card.routineContext?.check.dueLocalDate, "2026-11-05")
        XCTAssertEqual(restored.plants[0].firstAidControls[0].policy.dueOn, "2026-11-01")
    }

    func testCareOverviewRejectsMalformedWholePagesAndMixedPublications() async throws {
        let a = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let good = overviewPage([overviewRow(a, dated: true)])
        var invalid: [[String: Any]] = []
        for (key, value) in [
            ("owner_id", otherSyncOwner.uuidString as Any), ("server_now", "2026-02-30T00:00:00Z"),
            ("server_now", "2026-11-19T10:00:00+01:00"), ("owner_watermark", "infinity"),
            ("publication_fingerprint", String(repeating: "A", count: 64)), ("reminder_hour_local", 24),
            ("automation_allowed", 1), ("verified_access_until", "2026-11-19T10:00:00.000001Z"),
            ("verified_access_until", "infinity")
        ] {
            var page = good
            page[key] = value
            invalid.append(page)
        }
        var missing = good
        missing.removeValue(forKey: "verified_access_until")
        invalid.append(missing)
        for revision in [0, -1, 9_007_199_254_740_992, 1.5, true] as [Any] {
            var row = overviewRow(a)
            row["care_revision"] = revision
            invalid.append(overviewPage([row]))
        }
        var mismatch = overviewRow(a)
        mismatch["care_recommendation"] = careProjection()
        invalid.append(overviewPage([mismatch]))
        var routineMismatch = overviewRow(a, dated: true)
        routineMismatch["care_revision"] = 3
        invalid.append(overviewPage([routineMismatch]))
        var badCard = overviewRow(a)
        var card = careProjection()
        card["plant_id"] = a.uuidString
        card["recommendation"] = ["action_code": "water"]
        badCard["care_recommendation"] = card
        invalid.append(overviewPage([badCard]))
        invalid.append(overviewPage([overviewRow(a), overviewRow(a)]))
        invalid.append(overviewPage([overviewRow(b), overviewRow(a)]))
        invalid.append(overviewPage([overviewRow(a), overviewRow(b), overviewRow(serverPlantId)]))
        invalid.append(overviewPage([], next: a))
        invalid.append(overviewPage([overviewRow(a)], next: b))
        invalid.append(overviewPage([overviewRow(a)], next: a)) // short continuing page at limit=2
        let control = overviewControl()
        for (key, value) in [
            ("control_id", "bad" as Any), ("action_entry_id", "bad"), ("job_id", "bad"),
            ("origin_analysis_id", "bad"), ("kb_release_id", "bad"), ("protocol_id", "bad"),
            ("context_revision", 3), ("action_id", ""), ("action_id", "bad-id"),
            ("action_code", "water"), ("extra", true)
        ] {
            var broken = control
            broken[key] = value
            invalid.append(overviewPage([overviewRow(a, controls: [broken])]))
        }
        invalid.append(overviewPage([overviewRow(a, controls: [control, control])]))
        invalid.append(overviewPage([overviewRow(a, controls: [control]), overviewRow(b, controls: [control])]))
        for (key, value) in [
            ("due_on", "2026-02-30" as Any), ("interval_days", 0), ("interval_days", 91),
            ("interval_days", 1.5),
            ("source", ["url": "https://user:password@example.invalid", "locator": "x"]),
            ("source", ["url": "http://example.invalid", "locator": "x"]),
            ("source", ["url": "https://example.invalid", "locator": " "])
        ] {
            var broken = control
            var policy = try XCTUnwrap(control["policy"] as? [String: Any])
            policy[key] = value
            broken["policy"] = policy
            invalid.append(overviewPage([overviewRow(a, controls: [broken])]))
        }
        for page in invalid {
            do {
                _ = try await readOverview([page], limit: 2)
                XCTFail("Malformed overview must fail as a whole")
            } catch {}
        }
        let first = overviewPage([overviewRow(a)], next: a)
        let last = overviewPage([overviewRow(b)])
        for (key, value) in [
            ("owner_watermark", "2026-11-19T09:00:00.000002+00:00" as Any),
            ("publication_fingerprint", String(repeating: "b", count: 64)), ("reminder_hour_local", 10),
            ("verified_access_until", "2026-12-01T00:00:00.000002Z"), ("automation_allowed", false),
            ("owner_id", otherSyncOwner.uuidString), ("server_now", "2026-11-19T09:59:59Z")
        ] {
            var changed = last
            changed[key] = value
            do {
                _ = try await readOverview([first, changed], limit: 1)
                XCTFail("Mixed publication must not produce a snapshot")
            } catch {}
        }
        for badLast in [
            overviewPage([overviewRow(a)]),
            overviewPage([overviewRow(b)], next: a),
            overviewPage([], next: a)
        ] {
            do {
                _ = try await readOverview([first, badLast], limit: 1)
                XCTFail("Duplicate or nonadvancing page must fail")
            } catch {}
        }
        do {
            _ = try await readOverview([
                overviewPage([overviewRow(a, controls: [control])], next: a),
                overviewPage([overviewRow(b, controls: [control])])
            ], limit: 1)
            XCTFail("Control identity cannot be reused across pages")
        } catch {}
        // Prove the same coherent baseline succeeds.
        let valid = try await readOverview([first, last], limit: 1)
        XCTAssertEqual(valid.plants.map(\.plantId), [a, b])
    }

    func testCareOverviewExpiredAccessCannotReviveCalendarAndOldCardsRemainValid() async throws {
        let manual = overviewPage([overviewRow(serverPlantId)])
        var expired = manual
        expired["automation_allowed"] = false
        expired["verified_access_until"] = "2026-11-01T00:00:00Z"
        let snapshot = try await readOverview([expired])
        let advice = try XCTUnwrap(snapshot.plants[0].careRecommendation.validated(for: serverPlantId))
        XCTAssertNil(advice.nextCheck)
        XCTAssertNil(advice.routineContext)
        XCTAssertEqual(advice.text, "Check the substrate.")
        XCTAssertTrue(advice.source.isVerifiedLink)
        for row in [overviewRow(serverPlantId, dated: true),
                    overviewRow(serverPlantId, controls: [overviewControl()])] {
            var revived = expired
            revived["plants"] = [row]
            do {
                _ = try await readOverview([revived])
                XCTFail("Expired access must not revive a calendar")
            } catch {}
        }
        var unknownAccess = expired
        unknownAccess["verified_access_until"] = NSNull()
        let unknown = try await readOverview([unknownAccess])
        XCTAssertFalse(unknown.pages[0].automationAllowed)
        var free = manual
        free["verified_access_until"] = NSNull()
        _ = try await readOverview([free])
        var unavailable = overviewRow(serverPlantId)
        unavailable["care_recommendation"] = [
            "plant_id": serverPlantId.uuidString, "status": "unavailable", "recommendation": NSNull(),
            "next_check": NSNull()
        ]
        _ = try await readOverview([overviewPage([unavailable])])
        _ = try await readOverview([overviewPage([])])
    }

    func testCareOverviewRejectsUnsafeBaseRedirectErrorsAndUnboundSessions() async throws {
        let session = try profileSession()
        for base in [
            "http://example.invalid/functions/v1/plants-api",
            "https://user:pass@example.invalid/functions/v1/plants-api",
            "https://example.invalid/functions/v1/plants-api?x=1",
            "https://example.invalid/functions/v1/plants-api#fragment",
            "https://example.invalid/functions/v1/plants-api/child",
            "https://example.invalid/functions/v1/%70lants-api",
            "https://example.invalid/functions/v1/plants-api/%2e%2e",
            "https://example.invalid/plants-api"
        ] {
            let transport = CatalogueTransport([])
            let api = PlantsAPIClient(baseURL: try XCTUnwrap(URL(string: base)), transport: transport)
            await api.bindSyncSession(session)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            do {
                _ = try await api.fetchCareOverview(context: lease)
                XCTFail("Unsafe function root must fail before sending")
            } catch {}
            let requests = await transport.capturedRequests()
            XCTAssertTrue(requests.isEmpty)
        }
        for reply in [
            .redirect("https://foreign.invalid/care-overview"), .http(307, ""),
            .http(503, "{}"), .network, .cancelled
        ] as [CatalogueTransport.Reply] {
            let transport = CatalogueTransport([reply])
            let api = client(transport)
            await api.bindSyncSession(session)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            do {
                _ = try await api.fetchCareOverview(context: lease)
                XCTFail("Redirect/error must not yield an empty success")
            } catch {}
            let nonRedirecting = await transport.nonRedirectingRequests
            XCTAssertEqual(nonRedirecting, 1)
        }
        let transport = CatalogueTransport([])
        let api = client(transport)
        let explicit = try api.syncAuthority.capture(ownerId: syncOwner, explicitSession: session)
        do {
            _ = try await api.fetchCareOverview(context: explicit)
            XCTFail("Plain supplied session is not SDK binding")
        } catch SyncWireValidationError.invalidSession {}
        await api.bindSyncSession(try profileSession(claims: ["sub": syncOwner.uuidString, "is_anonymous": true]))
        let anonymous = try await api.captureSyncContext(ownerId: syncOwner)
        do {
            _ = try await api.fetchCareOverview(context: anonymous)
            XCTFail("Anonymous binding is not permanent")
        } catch SyncWireValidationError.invalidSession {}
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCareOverviewSuspendedSecondPageRejectsCancellationAndOwnerABA() async throws {
        let a = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        for cancel in [false, true] {
            let suspended = SuspendedCollectionTransport(try syncJSON(overviewPage([overviewRow(b)])))
            let transport = CareOverviewPagingTransport(
                first: try syncJSON(overviewPage([overviewRow(a)], next: a)), rest: suspended
            )
            let api = client(transport)
            let original = try profileSession()
            await api.bindSyncSession(original)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let task = Task { try await api.fetchCareOverview(context: lease, limit: 1) }
            await suspended.waitForRequest()
            if cancel {
                task.cancel()
            } else {
                await api.bindSyncSession(try profileSession(ownerId: otherSyncOwner))
                await api.bindSyncSession(original)
            }
            await suspended.resume()
            do {
                _ = try await task.value
                XCTFail("Suspended response must not escape cancellation or owner ABA")
            } catch is CancellationError {
                XCTAssertTrue(cancel)
            } catch SyncWireValidationError.invalidSession {
                XCTAssertFalse(cancel)
            }
            let requests = await suspended.capturedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(original.accessToken)")
            XCTAssertTrue(requests[0].url?.absoluteString.contains("after=\(a.uuidString.lowercased())") == true)
        }
    }
}

extension CollectionWireTests {
    private var overviewSyncTime: String { "2026-11-19T09:00:00.000002+00:00" }

    private func overviewBinding() throws -> (SyncSessionAuthority, SyncSessionLease) {
        let authority = SyncSessionAuthority()
        authority.bind(try profileSession())
        return (authority, try authority.capture(ownerId: syncOwner))
    }

    private func overviewSnapshot(_ pages: [[String: Any]], limit: Int = 200) throws -> CareOverviewSnapshot {
        try CareOverviewSnapshot(pages: pages.map {
            try JSONDecoder().decode(CareOverviewPage.self, from: Data(syncJSON($0).utf8))
        }, pageLimit: limit).validated(for: syncOwner)
    }

    @MainActor
    private func overviewCanonical(
        _ store: LocalStore, authority: SyncSessionAuthority, lease: SyncSessionLease,
        ids: [UUID], fullRefresh: Bool = false, personalName: String? = nil,
        revision: Int = 2, reminderHour: Int = 9
    ) async throws {
        var object = syncObject()
        var profile = try XCTUnwrap(object["profile"] as? [String: Any])
        profile["reminder_hour_local"] = reminderHour
        object["profile"] = profile
        object["until"] = overviewSyncTime
        object["next_since"] = overviewSyncTime
        object["changes"] = ids.sorted { $0.uuidString < $1.uuidString }.map { id in
            var row = syncChange(overviewSyncTime, id: id.uuidString)
            var data: [String: Any] = ["id": id.uuidString, "revision": revision, "care_revision": 2]
            if let personalName { data["personal_name"] = personalName }
            row["data"] = data
            return row
        }
        let page = try JSONDecoder().decode(SyncWirePageDTO.self, from: Data(syncJSON(object).utf8))
        let items = try page.changes.map {
            SyncItemDTO(entityType: $0.entityType, id: $0.id,
                        updatedAt: try XCTUnwrap(SQLTimestamp.date(from: $0.updatedAt)),
                        payloadJSON: String(decoding: try JSONEncoder().encode($0.data), as: UTF8.self))
        }
        try await store.publishSyncWindow(
            items: items, ownerId: syncOwner, watermark: SQLTimestamp.date(from: overviewSyncTime),
            wirePage: page, changes: page.changes, fullRefresh: fullRefresh,
            context: lease, authority: authority
        )
    }

    @MainActor
    private func overviewDiskState(_ url: URL) throws -> [String] {
        let disk = ModelContext(try diskContainer(url))
        let rows = try disk.fetch(FetchDescriptor<SyncedEntityRecord>()).map {
            "\($0.compositeKey)|\($0.ownerId)|\($0.entityId)|\($0.entityType)|\($0.payloadJSON)|\($0.updatedAt.timeIntervalSinceReferenceDate)|\($0.updatedAtRaw ?? "")|\(String(describing: $0.deletedAt))"
        }.sorted()
        let checkpoints = try disk.fetch(FetchDescriptor<SyncCheckpointRecord>()).map {
            "\($0.ownerId)|\($0.watermarkRaw ?? "")|\(String(describing: $0.watermark))|\($0.updatedAt.timeIntervalSinceReferenceDate)|\($0.syncProfileJSON ?? "")|\($0.syncEntitlementJSON ?? "")"
        }.sorted()
        return rows + checkpoints
    }

    @MainActor
    private func overviewWrapper(_ url: URL) throws -> [String: Any] {
        let disk = ModelContext(try diskContainer(url))
        let owner = syncOwner
        let rows = try disk.fetch(FetchDescriptor<SyncedEntityRecord>(predicate: #Predicate {
            $0.ownerId == owner && $0.entityType == "local_care_overview" && $0.entityId == owner
        }))
        XCTAssertEqual(rows.count, 1)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(rows.first).payloadJSON.utf8))
            as? [String: Any])
    }


    @MainActor
    func testOverviewLocalPresentationSharesCanonicalEpochAndPendingEvidence() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let container = try diskContainer(url)
        let store = LocalStore(modelContainer: container)
        let (authority, lease) = try overviewBinding()
        try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
        let snapshot = try overviewSnapshot([overviewPage([overviewRow(serverPlantId, dated: true)])])
        let token = try await store.beginCareOverviewRead(locale: "pl", context: lease, authority: authority)
        let committed = try await store.finishCareOverviewRead(token, snapshot: snapshot, authority: authority)
        XCTAssertEqual(committed.ownerId, syncOwner)
        XCTAssertEqual(committed.canonicalGeneration, committed.snapshotGeneration)
        XCTAssertNotNil(committed.canonicalGeneration)
        XCTAssertEqual(committed.cached?.state, .cached)
        XCTAssertTrue(committed.canonicalAccessKnown)
        XCTAssertNil(committed.entitlement) // Known canonical absence.
        let savedJSON = try XCTUnwrap(overviewWrapper(url)["snapshotJSON"] as? String)
        var expected: [OutboxEntrySnapshot] = []
        for (command, payload) in [
            ("plant.delete", "{}"), ("plant.edit", "{\"personal_name\":\"Pending\"}"),
            ("care.record", "{\"action_code\":\"water\"}"),
            ("profile.update", "{\"reminder_hour_local\":17}")
        ] {
            expected.append(try await store.enqueueCommand(
                ownerId: syncOwner, plantId: command == "profile.update" ? nil : serverPlantId,
                commandName: command, payloadJSON: payload
            ))
        }
        _ = try await store.enqueueCommand(
            ownerId: otherSyncOwner, plantId: serverPlantId, commandName: "plant.delete", payloadJSON: "{}"
        )
        let disk = ModelContext(container)
        for (index, type) in ["care_entries", "care_tasks", "care_observations", "first_aid_followups"].enumerated() {
            let row = SyncedEntityRecord(
                ownerId: syncOwner, entityType: type, entityId: UUID(),
                updatedAt: try XCTUnwrap(SQLTimestamp.date(from: overviewSyncTime)),
                deletedAt: index == 0 ? Date(timeIntervalSince1970: 1) : nil,
                payloadJSON: try syncJSON(["plant_id": serverPlantId.uuidString, "state": "completed"])
            )
            row.updatedAtRaw = overviewSyncTime
            disk.insert(row)
        }
        disk.insert(SyncedEntityRecord(
            ownerId: otherSyncOwner, entityType: "care_entries", entityId: UUID(),
            updatedAt: Date(), payloadJSON: "{}"
        ))
        disk.insert(SyncedEntityRecord(
            ownerId: otherSyncOwner, entityType: "plants", entityId: otherSyncOwner,
            updatedAt: Date(), payloadJSON: try syncJSON([
                "id": otherSyncOwner.uuidString, "revision": 9, "care_revision": 9
            ])
        ))
        try disk.save()
        // Same care_revision, different canonical name/revision/profile, same raw watermark.
        try await overviewCanonical(
            store, authority: authority, lease: lease, ids: [serverPlantId],
            personalName: "Canonical", revision: 3, reminderHour: 11
        )
        let before = try overviewDiskState(url)
        let presentation = try await store.readCareOverviewPresentation(context: lease, authority: authority)
        XCTAssertEqual(presentation.ownerId, syncOwner)
        XCTAssertNotEqual(presentation.canonicalGeneration, committed.canonicalGeneration)
        XCTAssertEqual(presentation.snapshotGeneration, committed.snapshotGeneration)
        XCTAssertEqual(presentation.canonicalGeneration?.uuidString.lowercased(),
                       (try overviewWrapper(url)["canonicalGeneration"] as? String)?.lowercased())
        XCTAssertEqual(presentation.cards.map(\.id), [serverPlantId])
        XCTAssertEqual(presentation.cards.first?.personalName, "Canonical")
        XCTAssertEqual(presentation.cards.first?.revision, 3)
        XCTAssertEqual(presentation.cards.first?.careRevision, 2)
        XCTAssertEqual(presentation.profile?.reminderHourLocal, 11)
        XCTAssertTrue(presentation.canonicalAccessKnown)
        XCTAssertEqual(presentation.pending, expected)
        XCTAssertEqual(presentation.pending.last?.payloadJSON, "{\"reminder_hour_local\":17}")
        XCTAssertEqual(presentation.cached?.state, .stale)
        XCTAssertEqual(presentation.cached?.fetchedAt, committed.cached?.fetchedAt)
        XCTAssertEqual(presentation.cached?.snapshotLocale, "pl")
        XCTAssertEqual(presentation.cached?.snapshot.plants.count, 1)
        let oldDue = try XCTUnwrap(committed.cached?.snapshot.plants.first?.careRecommendation.validated(for: serverPlantId))
        let newDue = try XCTUnwrap(presentation.cached?.snapshot.plants.first?.careRecommendation.validated(for: serverPlantId))
        XCTAssertEqual(newDue.nextCheck?.dueOn, oldDue.nextCheck?.dueOn)
        XCTAssertEqual(newDue.routineContext?.check.ruleId, oldDue.routineContext?.check.ruleId)
        let evidence = presentation.careRows.filter { $0.entityType != "plants" }
        XCTAssertEqual(evidence.count, 4)
        XCTAssertTrue(evidence.allSatisfy { $0.updatedAtRaw == overviewSyncTime && $0.payloadJSON.contains(serverPlantId.uuidString) })
        XCTAssertNotNil(evidence.first { $0.entityType == "care_entries" }?.deletedAt)
        XCTAssertEqual(try overviewWrapper(url)["snapshotJSON"] as? String, savedJSON)
        XCTAssertEqual(try overviewDiskState(url), before)
        let pendingAfter = try await store.pendingOutboxEntries(for: syncOwner)
        XCTAssertEqual(pendingAfter, expected)
    }

    @MainActor
    func testOverviewLocalPublicationRequiresWholeCanonicalSetIncludingEmptyOwner() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let (authority, lease) = try overviewBinding()
        let ids = [serverPlantId, otherSyncOwner].sorted { $0.uuidString < $1.uuidString }
        try await overviewCanonical(store, authority: authority, lease: lease, ids: ids)
        let full = try overviewSnapshot([overviewPage(ids.map { overviewRow($0) })])
        let token = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
        try await store.finishCareOverviewRead(token, snapshot: full, authority: authority)
        let extra = UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!
        for responseIDs in [[], [ids[0]], (ids + [extra]).sorted { $0.uuidString < $1.uuidString }] {
            let response = try overviewSnapshot([overviewPage(responseIDs.map { overviewRow($0) })])
            let request = try await store.beginCareOverviewRead(locale: "pl", context: lease, authority: authority)
            let before = try overviewDiskState(url)
            do {
                try await store.finishCareOverviewRead(request, snapshot: response, authority: authority)
                XCTFail("Incomplete or extra plant set must require canonical sync")
            } catch CareOverviewStoreError.needsCanonicalSync {}
            XCTAssertEqual(try overviewDiskState(url), before)
        }
        try await overviewCanonical(store, authority: authority, lease: lease, ids: [], fullRefresh: true)
        let empty = try overviewSnapshot([overviewPage([])])
        let request = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
        let result = try await store.finishCareOverviewRead(request, snapshot: empty, authority: authority)
        XCTAssertTrue(result.cards.isEmpty)
        XCTAssertEqual(result.cached?.snapshot.plants.count, 0)
        XCTAssertEqual(result.cached?.state, .cached)
        XCTAssertEqual(result.canonicalGeneration, result.snapshotGeneration)
    }

    @MainActor
    func testOverviewLocalUnknownAccessRetainsCacheWithoutAssumingFree() async throws {
        for mode in 0..<6 {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let container = try diskContainer(url)
            let store = LocalStore(modelContainer: container)
            let (authority, lease) = try overviewBinding()
            try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
            let snapshot = try overviewSnapshot([overviewPage([overviewRow(serverPlantId)])])
            let token = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
            try await store.finishCareOverviewRead(token, snapshot: snapshot, authority: authority)
            let saved = try XCTUnwrap(overviewWrapper(url)["snapshotJSON"] as? String)
            let disk = ModelContext(container)
            let checkpoint = try XCTUnwrap(disk.fetch(FetchDescriptor<SyncCheckpointRecord>()).first)
            switch mode {
            case 0: checkpoint.watermarkRaw = nil
            case 1: checkpoint.syncProfileJSON = nil
            case 2: checkpoint.syncProfileJSON = "{}"
            case 3: checkpoint.syncEntitlementJSON = "{}"
            case 4: checkpoint.syncEntitlementJSON = "null"
            default: disk.delete(checkpoint)
            }
            try disk.save()
            let before = try overviewDiskState(url)
            let result = try await store.readCareOverviewPresentation(context: lease, authority: authority)
            XCTAssertFalse(result.canonicalAccessKnown, "mode \(mode)")
            XCTAssertNotNil(result.cached)
            XCTAssertEqual(result.cards.map(\.id), [serverPlantId])
            if mode == 3 || mode == 4 {
                XCTAssertEqual(result.profile?.reminderHourLocal, 9)
                XCTAssertNil(result.entitlement)
            }
            XCTAssertEqual(try overviewWrapper(url)["snapshotJSON"] as? String, saved)
            XCTAssertEqual(try overviewDiskState(url), before)
        }
    }

    @MainActor
    func testOverviewLocalReadIsLazyAndRejectsOriginalLeaseABAAndCancellation() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let (authority, lease) = try overviewBinding()
        for canonical in [false, true] {
            if canonical {
                try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
            }
            let before = try overviewDiskState(url)
            let result = try await store.readCareOverviewPresentation(context: lease, authority: authority)
            XCTAssertNil(result.cached)
            XCTAssertNil(result.canonicalGeneration)
            XCTAssertNil(result.snapshotGeneration)
            XCTAssertEqual(result.canonicalAccessKnown, canonical)
            XCTAssertEqual(result.cards.count, canonical ? 1 : 0)
            XCTAssertTrue(result.pending.isEmpty)
            XCTAssertEqual(try overviewDiskState(url), before)
            let rows = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "local_care_overview")
            XCTAssertTrue(rows.isEmpty)
        }
        let before = try overviewDiskState(url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await store.readCareOverviewPresentation(context: lease, authority: authority)
        }
        do {
            try await task.value
            XCTFail("Cancelled local read must fail")
        } catch is CancellationError {}
        authority.bind(nil)
        authority.bind(try profileSession())
        do {
            _ = try await store.readCareOverviewPresentation(context: lease, authority: authority)
            XCTFail("Original lease must fail after owner ABA")
        } catch SyncWireValidationError.invalidSession {}
        XCTAssertEqual(try overviewDiskState(url), before)
    }

    @MainActor
    func testOverviewStoreDiskRestartPreservesFullPagesAndIndependentLocales() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (authority, lease) = try overviewBinding()
        let snapshot = try overviewSnapshot([
            overviewPage([overviewRow(serverPlantId, dated: true, controls: [overviewControl()])], next: serverPlantId),
            overviewPage([overviewRow(otherSyncOwner)])
        ], limit: 1)
        let oldPending: CareOverviewReadToken
        let savedAt: Date
        let savedJSON: String
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId, otherSyncOwner])
            let token = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
            try await store.finishCareOverviewRead(token, snapshot: snapshot, authority: authority)
            let read = try await store.readCareOverview(context: lease, authority: authority)
            savedAt = try XCTUnwrap(read).fetchedAt
            savedJSON = try XCTUnwrap(overviewWrapper(url)["snapshotJSON"] as? String)
            oldPending = try await store.beginCareOverviewRead(locale: "pl", context: lease, authority: authority)
        }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let beforeRead = try overviewDiskState(url)
        let read = try await store.readCareOverview(context: lease, authority: authority)
        let cached = try XCTUnwrap(read)
        XCTAssertEqual(cached.state, .cached)
        XCTAssertTrue(cached.canonicalGenerationMatches)
        XCTAssertEqual(cached.fetchedAt, savedAt)
        XCTAssertEqual(cached.snapshotLocale, "en")
        XCTAssertEqual(cached.snapshot.pages.count, 2)
        XCTAssertEqual(try overviewDiskState(url), beforeRead)
        let card = try XCTUnwrap(cached.snapshot.plants[0].careRecommendation.validated(for: serverPlantId))
        XCTAssertEqual(card.nextCheck?.dueOn, "2026-11-05")
        XCTAssertEqual(card.nextCheck?.anchorOn, "2026-10-29")
        XCTAssertEqual(card.nextCheck?.source.locator, "Soil check interval")
        XCTAssertEqual(card.routineContext?.plantId, serverPlantId)
        XCTAssertEqual(card.routineContext?.check.ruleId, operationId)
        XCTAssertEqual(card.routineContext?.check.careRevision, 2)
        XCTAssertEqual(cached.snapshot.plants[0].firstAidControls[0].policy.dueOn, "2026-11-01")
        XCTAssertEqual(try overviewWrapper(url)["snapshotJSON"] as? String, savedJSON)
        let latest = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
        let beforeOld = try overviewDiskState(url)
        do {
            try await store.finishCareOverviewRead(oldPending, snapshot: snapshot, authority: authority)
            XCTFail("Restart marker must not override a newer begin")
        } catch CareOverviewStoreError.superseded {}
        let abandoned = try await store.abandonCareOverviewRead(oldPending, authority: authority)
        XCTAssertFalse(abandoned)
        XCTAssertEqual(try overviewDiskState(url), beforeOld)
        try await store.finishCareOverviewRead(latest, snapshot: snapshot, authority: authority)
    }

    @MainActor
    func testOverviewStoreEmptySameWatermarkFullRefreshAndResetFenceLateResponses() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let (authority, lease) = try overviewBinding()
        try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
        let snapshot = try overviewSnapshot([overviewPage([overviewRow(serverPlantId, dated: true)])])
        let first = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
        try await store.finishCareOverviewRead(first, snapshot: snapshot, authority: authority)
        let complete = try overviewWrapper(url)
        var late = try await store.beginCareOverviewRead(locale: "pl", context: lease, authority: authority)
        for refresh in [false, true] {
            if refresh {
                // Same entity type with another ID is not the reserved owner row.
                let disk = ModelContext(try diskContainer(url))
                disk.insert(SyncedEntityRecord(ownerId: syncOwner, entityType: "local_care_overview",
                                              entityId: otherSyncOwner, updatedAt: Date(), payloadJSON: "{}"))
                try disk.save()
                late = try await store.beginCareOverviewRead(locale: "pl", context: lease, authority: authority)
            }
            let generation = try overviewWrapper(url)["canonicalGeneration"] as? String
            try await overviewCanonical(store, authority: authority, lease: lease,
                                        ids: refresh ? [otherSyncOwner] : [], fullRefresh: refresh)
            let wrapper = try overviewWrapper(url)
            XCTAssertNotEqual(wrapper["canonicalGeneration"] as? String, generation)
            for key in ["snapshotJSON", "snapshotLocale", "snapshotGeneration"] {
                XCTAssertEqual(wrapper[key] as? String, complete[key] as? String)
            }
            XCTAssertEqual(wrapper["fetchedAt"] as? Double, complete["fetchedAt"] as? Double)
            XCTAssertNil(wrapper["pendingRequestId"])
            let read = try await store.readCareOverview(context: lease, authority: authority)
            XCTAssertEqual(read?.state, .stale)
            XCTAssertFalse(try XCTUnwrap(read).canonicalGenerationMatches)
            let before = try overviewDiskState(url)
            do {
                try await store.finishCareOverviewRead(late, snapshot: snapshot, authority: authority)
                XCTFail("Canonical publication must fence even a same-watermark empty delta")
            } catch CareOverviewStoreError.superseded {}
            XCTAssertEqual(try overviewDiskState(url), before)
        }
        let plants = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
        XCTAssertEqual(plants.map(\.id), [otherSyncOwner])
        let localRows = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "local_care_overview")
        XCTAssertEqual(localRows.map(\.id), [syncOwner])
        late = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
        try await store.resetSyncCachePreservingOutbox(ownerId: syncOwner)
        let before = try overviewDiskState(url)
        let read = try await store.readCareOverview(context: lease, authority: authority)
        XCTAssertNil(read)
        do {
            try await store.finishCareOverviewRead(late, snapshot: snapshot, authority: authority)
            XCTFail("Reset cannot resurrect an overview")
        } catch CareOverviewStoreError.superseded {}
        XCTAssertEqual(try overviewDiskState(url), before)
        let rows = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "local_care_overview")
        XCTAssertTrue(rows.isEmpty)
    }

    @MainActor
    func testOverviewStoreLatestLocaleAndInvalidCompleteResponsesPreserveTrustedBytes() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let (authority, lease) = try overviewBinding()
        try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
        let snapshot = try overviewSnapshot([overviewPage([overviewRow(serverPlantId)])])
        let initial = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
        try await store.finishCareOverviewRead(initial, snapshot: snapshot, authority: authority)
        let en = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
        let pl = try await store.beginCareOverviewRead(locale: "pl", context: lease, authority: authority)
        let before = try overviewDiskState(url)
        do {
            try await store.finishCareOverviewRead(en, snapshot: snapshot, authority: authority)
            XCTFail("Only latest locale may publish")
        } catch CareOverviewStoreError.superseded {}
        let abandoned = try await store.abandonCareOverviewRead(en, authority: authority)
        XCTAssertFalse(abandoned)
        XCTAssertEqual(try overviewDiskState(url), before)
        var deniedPage = overviewPage([overviewRow(serverPlantId)])
        deniedPage["automation_allowed"] = false
        let denied = try overviewSnapshot([deniedPage])
        try await store.finishCareOverviewRead(pl, snapshot: denied, authority: authority)
        let read = try await store.readCareOverview(context: lease, authority: authority)
        XCTAssertEqual(read?.snapshotLocale, "pl")
        XCTAssertEqual(read?.snapshot.pages.first?.automationAllowed, false)
        let partialPage = try JSONDecoder().decode(
            CareOverviewPage.self, from: Data(syncJSON(overviewPage([overviewRow(serverPlantId)], next: serverPlantId)).utf8)
        )
        var mixedPage = overviewPage([overviewRow(otherSyncOwner)])
        mixedPage["publication_fingerprint"] = String(repeating: "b", count: 64)
        let mixed = try JSONDecoder().decode(CareOverviewPage.self, from: Data(syncJSON(mixedPage).utf8))
        for invalid in [
            CareOverviewSnapshot(pages: [], pageLimit: 200),
            CareOverviewSnapshot(pages: [partialPage], pageLimit: 1),
            CareOverviewSnapshot(pages: [partialPage, mixed], pageLimit: 1)
        ] {
            let token = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
            let bytes = try overviewDiskState(url)
            do {
                try await store.finishCareOverviewRead(token, snapshot: invalid, authority: authority)
                XCTFail("Partial/mixed/invalid cannot erase the last complete snapshot")
            } catch SyncWireValidationError.invalidPage {}
            XCTAssertEqual(try overviewDiskState(url), bytes)
        }
    }

    @MainActor
    func testOverviewStoreOriginalLeaseABAOtherAuthorityForeignOwnerAndCancellation() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let (authority, lease) = try overviewBinding()
        try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
        let snapshot = try overviewSnapshot([overviewPage([overviewRow(serverPlantId)])])
        let initial = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
        try await store.finishCareOverviewRead(initial, snapshot: snapshot, authority: authority)
        let old = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
        let beforeABA = try overviewDiskState(url)
        authority.bind(try profileSession(ownerId: otherSyncOwner))
        authority.bind(try profileSession())
        do {
            try await store.finishCareOverviewRead(old, snapshot: snapshot, authority: authority)
            XCTFail("Owner A-B-A must reject original lease")
        } catch SyncWireValidationError.invalidSession {}
        do {
            _ = try await store.abandonCareOverviewRead(old, authority: authority)
            XCTFail("Old failure cannot clear marker")
        } catch SyncWireValidationError.invalidSession {}
        do {
            _ = try await store.beginCareOverviewRead(locale: "pl", context: lease, authority: authority)
            XCTFail("Old begin must fail")
        } catch SyncWireValidationError.invalidSession {}
        do {
            _ = try await store.readCareOverview(context: lease, authority: authority)
            XCTFail("Old read must fail")
        } catch SyncWireValidationError.invalidSession {}
        XCTAssertEqual(try overviewDiskState(url), beforeABA)
        let current = try authority.capture(ownerId: syncOwner)
        let token = try await store.beginCareOverviewRead(locale: "en", context: current, authority: authority)
        let before = try overviewDiskState(url)
        let (foreignAuthority, _) = try overviewBinding()
        do {
            try await store.finishCareOverviewRead(token, snapshot: snapshot, authority: foreignAuthority)
            XCTFail("Replacement authority cannot authorize original token")
        } catch SyncWireValidationError.invalidSession {}
        var foreignPage = overviewPage([overviewRow(serverPlantId)])
        foreignPage["owner_id"] = otherSyncOwner.uuidString
        let foreignSnapshot = CareOverviewSnapshot(pages: [
            try JSONDecoder().decode(CareOverviewPage.self, from: Data(syncJSON(foreignPage).utf8))
        ], pageLimit: 200)
        do {
            try await store.finishCareOverviewRead(token, snapshot: foreignSnapshot, authority: authority)
            XCTFail("Foreign snapshot cannot publish")
        } catch SyncWireValidationError.invalidPage {}
        for operation in 0..<4 {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                switch operation {
                case 0: try await store.finishCareOverviewRead(token, snapshot: snapshot, authority: authority)
                case 1: _ = try await store.beginCareOverviewRead(locale: "pl", context: current, authority: authority)
                case 2: _ = try await store.abandonCareOverviewRead(token, authority: authority)
                default: _ = try await store.readCareOverview(context: current, authority: authority)
                }
            }
            do {
                try await task.value
                XCTFail("Cancelled disk operation must fail")
            } catch is CancellationError {}
        }
        XCTAssertEqual(try overviewDiskState(url), before)
        try await store.finishCareOverviewRead(token, snapshot: snapshot, authority: authority)
    }

    @MainActor
    func testOverviewStoreAlignmentFailuresDoNotMutateSnapshotOrCheckpoint() async throws {
        for mode in 0..<7 {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let container = try diskContainer(url)
            let store = LocalStore(modelContainer: container)
            let (authority, lease) = try overviewBinding()
            try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
            let snapshot = try overviewSnapshot([overviewPage([overviewRow(serverPlantId)])])
            let initial = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
            try await store.finishCareOverviewRead(initial, snapshot: snapshot, authority: authority)
            let disk = ModelContext(container)
            let checkpoint = try XCTUnwrap(disk.fetch(FetchDescriptor<SyncCheckpointRecord>()).first)
            let plant = try XCTUnwrap(disk.fetch(FetchDescriptor<SyncedEntityRecord>()).first { $0.entityType == "plants" })
            switch mode {
            case 0: checkpoint.watermarkRaw = "2026-11-19T08:59:59.999999+00:00"
            case 1: checkpoint.watermarkRaw = nil // legacy Date cannot prove microsecond alignment
            case 2: disk.delete(checkpoint)
            case 3: disk.delete(plant)
            case 4: plant.deletedAt = Date()
            case 5: plant.ownerId = otherSyncOwner
            default: plant.payloadJSON = try syncJSON(["id": serverPlantId.uuidString, "revision": 3, "care_revision": 3])
            }
            try disk.save()
            let token = try await store.beginCareOverviewRead(locale: "pl", context: lease, authority: authority)
            let before = try overviewDiskState(url)
            do {
                try await store.finishCareOverviewRead(token, snapshot: snapshot, authority: authority)
                XCTFail("Alignment failure must be typed, mode \(mode)")
            } catch CareOverviewStoreError.needsCanonicalSync {}
            XCTAssertEqual(try overviewDiskState(url), before)
        }
    }

    @MainActor
    func testOverviewStoreCorruptWrapperDoesNotBlockCanonicalSyncOrInventEmptySnapshot() async throws {
        for mode in 0..<5 {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let container = try diskContainer(url)
            let store = LocalStore(modelContainer: container)
            let (authority, lease) = try overviewBinding()
            try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
            let snapshot = try overviewSnapshot([overviewPage([overviewRow(serverPlantId)])])
            let token = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
            try await store.finishCareOverviewRead(token, snapshot: snapshot, authority: authority)
            var object = try overviewWrapper(url)
            switch mode {
            case 0: object["version"] = 999
            case 1: object["snapshotJSON"] = "{}"
            case 2: object["snapshotJSON"] = try syncJSON(["pages": [], "pageLimit": 200])
            default: object["snapshotLocale"] = "xx"
            }
            let disk = ModelContext(container)
            let row = try XCTUnwrap(disk.fetch(FetchDescriptor<SyncedEntityRecord>()).first {
                $0.entityType == "local_care_overview"
            })
            row.payloadJSON = mode == 4 ? "not-json" : (try syncJSON(object))
            try disk.save()
            let before = try overviewDiskState(url)
            let read = try await store.readCareOverview(context: lease, authority: authority)
            XCTAssertNil(read)
            XCTAssertEqual(try overviewDiskState(url), before)
            try await overviewCanonical(store, authority: authority, lease: lease, ids: [], fullRefresh: mode == 2)
            let wrapper = try overviewWrapper(url)
            XCTAssertEqual(wrapper["version"] as? Int, 1)
            XCTAssertNil(wrapper["snapshotJSON"])
            XCTAssertNotNil(wrapper["canonicalGeneration"])
            let after = try await store.readCareOverview(context: lease, authority: authority)
            XCTAssertNil(after)
        }
    }

    @MainActor
    func testOverviewStoreFailedSavesRetainCanonicalGenerationAndOldSnapshot() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let (authority, lease) = try overviewBinding()
        try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
        let snapshot = try overviewSnapshot([overviewPage([overviewRow(serverPlantId)])])
        let initial = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
        try await store.finishCareOverviewRead(initial, snapshot: snapshot, authority: authority)
        let token = try await store.beginCareOverviewRead(locale: "pl", context: lease, authority: authority)
        let before = try overviewDiskState(url)
        let readOnly = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
        for operation in 0..<4 {
            do {
                switch operation {
                case 0:
                    try await overviewCanonical(readOnly, authority: authority, lease: lease, ids: [otherSyncOwner], fullRefresh: true)
                case 1: _ = try await readOnly.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
                case 2: try await readOnly.finishCareOverviewRead(token, snapshot: snapshot, authority: authority)
                default: _ = try await readOnly.abandonCareOverviewRead(token, authority: authority)
                }
                XCTFail("Read-only save must fail")
            } catch {}
            XCTAssertEqual(try overviewDiskState(url), before)
        }
        try await store.finishCareOverviewRead(token, snapshot: snapshot, authority: authority)
    }
}


extension CollectionWireTests {
    @MainActor
    private func overviewRepositoryFixture(
        _ transport: any PlantsAPITransport, seed: Bool = true
    ) async throws -> (URL, LocalStore, PlantsAPIClient, SyncSessionLease, CollectionRepository) {
        let url = try diskURL()
        let store = LocalStore(modelContainer: try diskContainer(url))
        let api = client(transport)
        await api.bindSyncSession(try profileSession())
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        try await overviewCanonical(store, authority: api.syncAuthority, lease: lease, ids: [serverPlantId])
        if seed {
            var page = overviewPage([overviewRow(serverPlantId, dated: true, controls: [overviewControl()])])
            page["verified_access_until"] = NSNull()
            let token = try await store.beginCareOverviewRead(
                locale: "pl", context: lease, authority: api.syncAuthority
            )
            try await store.finishCareOverviewRead(
                token, snapshot: overviewSnapshot([page]), authority: api.syncAuthority
            )
        }
        let now = try XCTUnwrap(SQLTimestamp.date(from: "2026-11-20T00:00:00Z"))
        let repo = CollectionRepository(
            store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api),
            clock: { now }
        )
        return (url, store, api, lease, repo)
    }

    private func overviewAlignmentPage() -> [String: Any] {
        var page = syncObject()
        let time = "2026-11-19T09:00:00.000004+00:00"
        page["until"] = time
        page["next_since"] = time
        var plant = syncChange(time, id: serverPlantId.uuidString)
        plant["data"] = ["id": serverPlantId.uuidString, "revision": 2, "care_revision": 2]
        page["changes"] = [plant]
        return page
    }

    @MainActor
    func testOverviewRepositoryFreshThenOfflineUsesDurableSnapshotLocaleAndNoCommands() async throws {
        var page = overviewPage([overviewRow(serverPlantId, dated: true, controls: [overviewControl()])])
        page["verified_access_until"] = NSNull()
        let transport = CatalogueTransport([.http(200, try syncJSON(page)), .network])
        let (url, _, api, lease, repo) = try await overviewRepositoryFixture(transport, seed: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await api.updateClientLocale("en")
        let fresh = try await repo.refreshCareOverview(locale: .pl, context: lease)
        XCTAssertEqual(fresh.origin, .network)
        XCTAssertEqual(fresh.snapshotLocale, "pl")
        XCTAssertEqual(fresh.availability, .available)
        XCTAssertEqual(fresh.plants.first?.routine?.dueLocalDate, "2026-11-05")
        XCTAssertEqual(fresh.plants.first?.controls.first?.dueOn, "2026-11-01")
        let bytes = try XCTUnwrap(overviewWrapper(url)["snapshotJSON"] as? String)
        let offline = try await repo.refreshCareOverview(locale: .en, context: lease)
        XCTAssertEqual(offline.origin, .cache)
        XCTAssertEqual(offline.failure, .transport)
        XCTAssertNil(offline.knownInvalidation)
        XCTAssertEqual(offline.snapshotLocale, "pl")
        XCTAssertEqual(offline.plants.first?.routine?.dueLocalDate, "2026-11-05")
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let local = try await reopened.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        XCTAssertEqual(local.cached?.state, .cached)
        XCTAssertNil(local.knownInvalidation)
        XCTAssertEqual(try overviewWrapper(url)["snapshotJSON"] as? String, bytes)
        let wrapper = try syncJSON(overviewWrapper(url))
        XCTAssertFalse(wrapper.contains("fixture-installation"))
        XCTAssertFalse(wrapper.contains("fixture-user-token"))
        XCTAssertFalse(wrapper.contains("eyJhbGci"))
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "X-Client-Locale") }, ["pl", "en"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path.hasSuffix("care-overview") == true })
    }

    @MainActor
    func testOverviewRepositoryAheadAlignsOnceAndReadsANewPublication() async throws {
        var ahead = overviewPage([overviewRow(serverPlantId)])
        ahead["owner_watermark"] = "2026-11-19T09:00:00.000003+00:00"
        var aligned = ahead
        aligned["publication_fingerprint"] = String(repeating: "b", count: 64)
        let transport = CatalogueTransport([
            .http(200, try syncJSON(ahead)), .http(200, try syncJSON(overviewAlignmentPage())),
            .http(200, try syncJSON(aligned))
        ])
        let (url, store, api, lease, repo) = try await overviewRepositoryFixture(transport)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pending = try await store.enqueueCommand(
            ownerId: syncOwner, plantId: serverPlantId, commandName: "care.record", payloadJSON: "{}"
        )
        let old = try overviewWrapper(url)["canonicalGeneration"] as? String
        let result = try await repo.refreshCareOverview(locale: .en, context: lease)
        XCTAssertEqual(result.origin, .network)
        XCTAssertNil(result.knownInvalidation)
        XCTAssertEqual(result.snapshotLocale, "en")
        XCTAssertNotEqual(try overviewWrapper(url)["canonicalGeneration"] as? String, old)
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        XCTAssertEqual(local.cached?.snapshot.pages.first?.publicationFingerprint, String(repeating: "b", count: 64))
        XCTAssertEqual(local.canonicalGeneration, local.snapshotGeneration)
        XCTAssertEqual(local.pending.map(\.operationId), [pending.operationId])
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["care-overview", "sync", "care-overview"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "care-overview" }
            .map { $0.value(forHTTPHeaderField: "X-Client-Locale") }, ["en", "en"])
    }

    @MainActor
    func testOverviewRepositoryRejectedReadSurvivesFailedAlignmentAndDiskReopen() async throws {
        var ahead = overviewPage([overviewRow(serverPlantId)])
        ahead["owner_watermark"] = "2026-11-19T09:00:00.000003+00:00"
        let transport = CatalogueTransport([.http(200, try syncJSON(ahead)), .network])
        let (url, _, api, lease, repo) = try await overviewRepositoryFixture(transport)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try overviewWrapper(url)
        let result = try await repo.refreshCareOverview(locale: .en, context: lease)
        XCTAssertEqual(result.availability, .readOnly)
        XCTAssertEqual(result.failure, .revalidationRequired)
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let local = try await reopened.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        XCTAssertEqual(local.knownInvalidation, .canonicalRevalidation)
        XCTAssertEqual(local.cached?.state, .stale)
        XCTAssertFalse(local.cached?.canonicalGenerationMatches ?? true)
        let after = try overviewWrapper(url)
        for key in ["snapshotJSON", "snapshotLocale"] {
            XCTAssertEqual(after[key] as? String, before[key] as? String)
        }
        XCTAssertEqual(after["fetchedAt"] as? Double, before["fetchedAt"] as? Double)
        XCTAssertNotEqual(after["canonicalGeneration"] as? String, before["canonicalGeneration"] as? String)
        let projected = CareOverviewViewState(local: local, now: Date(), origin: .cache)
        XCTAssertNil(projected.plants.first?.routine)
        XCTAssertTrue(projected.plants.first?.controls.isEmpty == true)
        XCTAssertTrue(projected.plants.first?.manualJournalAvailable == true)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    @MainActor
    func testOverviewRepositoryRepeatedSetMismatchIsBoundedAndPreservesSnapshot() async throws {
        let mismatch = try syncJSON(overviewPage([]))
        let transport = CatalogueTransport([
            .http(200, mismatch), .http(200, try syncJSON(overviewAlignmentPage())), .http(200, mismatch)
        ])
        let (url, _, api, lease, repo) = try await overviewRepositoryFixture(transport)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bytes = try overviewWrapper(url)["snapshotJSON"] as? String
        let result = try await repo.refreshCareOverview(locale: .en, context: lease)
        XCTAssertEqual(result.failure, .revalidationRequired)
        XCTAssertEqual(result.availability, .readOnly)
        XCTAssertEqual(result.plants.count, 1)
        XCTAssertNil(result.plants.first?.routine)
        XCTAssertEqual(try overviewWrapper(url)["snapshotJSON"] as? String, bytes)
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let local = try await reopened.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        XCTAssertEqual(local.knownInvalidation, .canonicalRevalidation)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["care-overview", "sync", "care-overview"])
    }

    @MainActor
    func testOverviewRepositoryAuthorizationDenialPersistsButOrdinaryFailuresDoNotInventDenial() async throws {
        for status in [401, 403, 503, 200] {
            let transport = CatalogueTransport([.http(status, "{}"), .network])
            let (url, _, api, lease, repo) = try await overviewRepositoryFixture(transport)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let bytes = try overviewWrapper(url)["snapshotJSON"] as? String
            let denied = status == 401 || status == 403
            let result = try await repo.refreshCareOverview(locale: .en, context: lease)
            XCTAssertEqual(result.failure, denied ? .authorizationDenied : .transport)
            let offline = try await repo.refreshCareOverview(locale: .pl, context: lease)
            XCTAssertEqual(offline.failure, denied ? .authorizationDenied : .transport)
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let local = try await reopened.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
            XCTAssertEqual(local.knownInvalidation, denied ? .authorizationDenied : nil)
            XCTAssertEqual(local.cached?.state, denied ? .stale : .cached)
            XCTAssertEqual(try overviewWrapper(url)["snapshotJSON"] as? String, bytes)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 2)
        }
    }

    @MainActor
    func testOverviewRepositoryPartialAndMixedHTTPNeverReplaceCacheOrTriggerAlignment() async throws {
        let ids = (1...200).map {
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0))!
        }
        let first = overviewPage(ids.map { overviewRow($0) }, next: ids.last)
        var mixed = overviewPage([overviewRow(serverPlantId)])
        mixed["publication_fingerprint"] = String(repeating: "b", count: 64)
        for last in [CatalogueTransport.Reply.network, .http(200, try syncJSON(mixed))] {
            let transport = CatalogueTransport([.http(200, try syncJSON(first)), last])
            let (url, _, _, lease, repo) = try await overviewRepositoryFixture(transport)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let bytes = try overviewWrapper(url)["snapshotJSON"] as? String
            let result = try await repo.refreshCareOverview(locale: .en, context: lease)
            XCTAssertEqual(result.failure, .transport)
            XCTAssertEqual(result.snapshotLocale, "pl")
            XCTAssertNil(result.knownInvalidation)
            XCTAssertEqual(try overviewWrapper(url)["snapshotJSON"] as? String, bytes)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(requests.allSatisfy { $0.url?.lastPathComponent == "care-overview" })
        }
    }

    @MainActor
    func testOverviewRepositorySuspendedExplicitLocaleLatestABAAndCancellation() async throws {
        for mode in 0..<4 {
            let suspended = SuspendedCollectionTransport(try syncJSON(overviewPage([overviewRow(serverPlantId)])))
            let (url, store, api, lease, repo) = try await overviewRepositoryFixture(suspended)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try await api.updateClientLocale("en")
            let task = Task { try await repo.refreshCareOverview(locale: .pl, context: lease) }
            await suspended.waitForRequest()
            try await api.updateClientLocale("pl")
            var newer: CareOverviewReadToken?
            if mode == 1 {
                newer = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: api.syncAuthority)
            } else if mode == 2 {
                await api.bindSyncSession(try profileSession(ownerId: otherSyncOwner))
                await api.bindSyncSession(try profileSession())
            } else if mode == 3 {
                task.cancel()
            }
            let before = try overviewWrapper(url)
            await suspended.resume()
            if mode == 0 {
                let result = try await task.value
                XCTAssertEqual(result.snapshotLocale, "pl")
            } else {
                do {
                    _ = try await task.value
                    XCTFail("Superseded, ABA and cancelled reads must throw")
                } catch {}
                XCTAssertEqual(try overviewWrapper(url)["snapshotJSON"] as? String, before["snapshotJSON"] as? String)
                XCTAssertEqual(try overviewWrapper(url)["pendingRequestId"] as? String, before["pendingRequestId"] as? String)
            }
            if let newer {
                let snapshot = try overviewSnapshot([overviewPage([overviewRow(serverPlantId)])])
                try await store.finishCareOverviewRead(newer, snapshot: snapshot, authority: api.syncAuthority)
            }
            let requests = await suspended.capturedRequests()
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Client-Locale"), "pl")
            XCTAssertEqual(requests.count, 1)
        }
    }

    @MainActor
    func testOverviewRevalidationContinuationCannotReplaceNewerReadAndUsesNewToken() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let authority = api.syncAuthority
        let old = try await store.beginCareOverviewRead(locale: "pl", context: lease, authority: authority)
        let oldID = try overviewWrapper(url)["pendingRequestId"] as? String
        try await store.invalidateCareOverviewRead(old, reason: .canonicalRevalidation, authority: authority)
        try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId], fullRefresh: true)
        let next = try await store.beginCareOverviewRead(
            locale: "pl", context: lease, authority: authority, revalidating: old
        )
        XCTAssertNotEqual(try overviewWrapper(url)["pendingRequestId"] as? String, oldID)
        let before = try overviewDiskState(url)
        do {
            try await store.invalidateCareOverviewRead(old, reason: .authorizationDenied, authority: authority)
            XCTFail("Old failure must not mark newer request denied")
        } catch CareOverviewStoreError.superseded {}
        do {
            _ = try await store.beginCareOverviewRead(
                locale: "pl", context: lease, authority: authority, revalidating: old
            )
            XCTFail("Consumed continuation must not replace the new token")
        } catch CareOverviewStoreError.superseded {}
        let abandoned = try await store.abandonCareOverviewRead(old, authority: authority)
        XCTAssertFalse(abandoned)
        XCTAssertEqual(try overviewDiskState(url), before)
        try await store.finishCareOverviewRead(
            next, snapshot: overviewSnapshot([overviewPage([overviewRow(serverPlantId)])]), authority: authority
        )
        let local = try await store.readCareOverviewPresentation(context: lease, authority: authority)
        XCTAssertNil(local.knownInvalidation)
    }

    @MainActor
    func testOverviewSafeProjectionPendingAndCanonicalMutationGates() async throws {
        let (url, store, api, lease, repo) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        let now = try XCTUnwrap(SQLTimestamp.date(from: "2026-11-20T00:00:00Z"))
        let baseline = CareOverviewViewState(local: local, now: now, origin: .cache)
        XCTAssertTrue(baseline.plants.first?.automatedActionsAllowed == true)
        XCTAssertEqual(baseline.plants.first?.routine?.dueLocalDate, "2026-11-05")
        for command in ["plant.edit", "plant.delete", "care.record", "care.routine.undo", "plant.photo", "profile.update"] {
            let pending = OutboxEntrySnapshot(
                operationId: UUID(), ownerId: syncOwner, plantId: command == "profile.update" ? nil : serverPlantId,
                commandName: command, payloadJSON: "{\"claim_proof\":\"SECRET\",\"jpeg\":\"SECRET\"}", sequenceNumber: 1
            )
            let modified = LocalCareOverviewPresentation(
                ownerId: local.ownerId, canonicalGeneration: local.canonicalGeneration,
                snapshotGeneration: local.snapshotGeneration, cached: local.cached, cards: local.cards,
                pending: [pending], profile: local.profile, entitlement: local.entitlement,
                canonicalAccessKnown: true, careRows: local.careRows
            )
            let view = CareOverviewViewState(local: modified, now: now, origin: .cache)
            XCTAssertFalse(view.plants.first?.automatedActionsAllowed ?? true, command)
            XCTAssertNil(view.plants.first?.routine)
            XCTAssertTrue(view.plants.first?.controls.isEmpty == true)
            XCTAssertTrue(view.plants.first?.manualJournalAvailable == true)
            XCTAssertTrue(view.plants.first?.cardLinkAvailable == true)
            XCTAssertEqual(view.profileHourPending, command == "profile.update")
            XCTAssertEqual(view.pending.map(\.operationId), [pending.operationId])
            let rendered = String(reflecting: view)
            for secret in ["SECRET", "payloadJSON", "claim_proof", "jpeg", "careRows", "lastError"] {
                XCTAssertFalse(rendered.contains(secret))
            }
        }
        for type in ["care_entries", "care_reversals", "care_tasks", "first_aid_followups", "analysis_summaries"] {
            for mapped in [false, true] {
                let evidence = LocalCareOverviewRow(
                    entityType: type, entityId: UUID(),
                    payloadJSON: mapped ? "{\"plant_id\":\"\(serverPlantId)\",\"state\":\"completed\"}" : "{}",
                    updatedAtRaw: "2026-11-19T09:00:00.000002+00:00", deletedAt: now
                )
                let modified = LocalCareOverviewPresentation(
                    ownerId: local.ownerId, canonicalGeneration: local.canonicalGeneration,
                    snapshotGeneration: local.snapshotGeneration, cached: local.cached, cards: local.cards,
                    pending: [], profile: local.profile, entitlement: local.entitlement,
                    canonicalAccessKnown: true, careRows: [evidence]
                )
                let view = CareOverviewViewState(local: modified, now: now, origin: .cache)
                XCTAssertEqual(view.plants.first?.automatedActionsAllowed, type == "analysis_summaries")
                XCTAssertEqual(view.plants.first?.routine?.dueLocalDate,
                               type == "analysis_summaries" ? "2026-11-05" : nil)
                if !mapped && type != "analysis_summaries" { XCTAssertEqual(view.availability, .readOnly) }
            }
        }
        let diskRead = try await repo.cachedCareOverview(context: lease)
        XCTAssertEqual(diskRead.origin, .cache)
    }

    @MainActor
    func testOverviewProjectionAccessRevisionDeletionAndLegacyDatesFailClosed() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        let now = try XCTUnwrap(SQLTimestamp.date(from: "2026-11-20T00:00:00Z"))
        var entitlement: [String: Any] = [
            "product_id": "paid", "state": "grace", "offer_kind": "trial",
            "valid_until": "2026-12-01T00:00:00Z", "grace_until": "2027-01-01T00:00:00Z",
            "trial_end_at": "2026-11-20T00:00:00Z", "auto_renew_enabled": true
        ]
        for mode in 0..<7 {
            var cards = local.cards
            var snapshot = local.cached
            var accessKnown = true
            var retained: SyncWireEntitlementDTO?
            if mode == 0 { accessKnown = false }
            if mode == 1 { cards = [] }
            if mode == 2 {
                cards = [CatalogueCardSummary(
                    id: serverPlantId, speciesSlug: nil, taxonId: nil, mainPhotoId: nil,
                    personalName: nil, currentConditionSnapshotId: nil, revision: 3, careRevision: 3
                )]
            }
            if mode == 3 || mode == 4 {
                if mode == 4 {
                    entitlement["offer_kind"] = "paid"
                    entitlement["valid_until"] = "2026-11-20T00:00:00Z"
                }
                retained = try JSONDecoder().decode(SyncWireEntitlementDTO.self, from: Data(syncJSON(entitlement).utf8))
            }
            if mode == 5 {
                var row = overviewRow(serverPlantId, dated: true)
                var recommendation = try XCTUnwrap(row["care_recommendation"] as? [String: Any])
                recommendation.removeValue(forKey: "routine_check")
                row["care_recommendation"] = recommendation
                var page = overviewPage([row])
                page["verified_access_until"] = NSNull()
                snapshot = CachedCareOverview(
                    snapshot: try overviewSnapshot([page]), fetchedAt: now, snapshotLocale: "pl",
                    state: .cached, canonicalGenerationMatches: true
                )
            }
            if mode == 6 {
                var page = overviewPage([overviewRow(serverPlantId, dated: true)])
                page["verified_access_until"] = "2026-11-20T00:00:00Z"
                snapshot = CachedCareOverview(
                    snapshot: try overviewSnapshot([page]), fetchedAt: now, snapshotLocale: "pl",
                    state: .cached, canonicalGenerationMatches: true
                )
            }
            let modified = LocalCareOverviewPresentation(
                ownerId: local.ownerId, canonicalGeneration: local.canonicalGeneration,
                snapshotGeneration: local.snapshotGeneration, cached: snapshot, cards: cards,
                pending: [], profile: local.profile, entitlement: retained,
                canonicalAccessKnown: accessKnown, careRows: []
            )
            let view = CareOverviewViewState(local: modified, now: now, origin: .cache)
            XCTAssertNil(view.plants.first?.routine, "mode \(mode)")
            XCTAssertFalse(view.plants.first?.automatedActionsAllowed ?? false)
            if mode == 0 { XCTAssertEqual(view.access, .unknown) }
            if mode == 3 || mode == 4 { XCTAssertEqual(view.access, .expired) }
            if mode == 1 { XCTAssertTrue(view.plants.isEmpty) }
            if mode == 5 { XCTAssertNotNil(view.plants.first?.advice) }
        }
    }

    func testOverviewExplicitLocaleAppliesToEveryPageDespiteDifferentClientDefault() async throws {
        let a = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let transport = CatalogueTransport([
            .http(200, try syncJSON(overviewPage([overviewRow(a)], next: a))),
            .http(200, try syncJSON(overviewPage([overviewRow(b)])))
        ])
        let api = client(transport)
        let session = try profileSession()
        await api.bindSyncSession(session)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let snapshot = try await api.fetchCareOverview(context: lease, limit: 1, locale: .pl)
        XCTAssertEqual(snapshot.plants.map(\.plantId), [a, b])
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Client-Locale") == "pl"
                && $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(session.accessToken)"
        })
    }

    @MainActor
    func testOverviewProjectionVerifiedPaidAuthorityAndServerDeadlineUseCurrentClock() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        let page = overviewPage([overviewRow(serverPlantId, dated: true)])
        let now = try XCTUnwrap(SQLTimestamp.date(from: "2026-11-20T00:00:00Z"))
        let later = try XCTUnwrap(SQLTimestamp.date(from: "2026-12-02T00:00:00Z"))
        for state in ["active", "grace"] {
            let entitlement = try JSONDecoder().decode(SyncWireEntitlementDTO.self, from: Data(syncJSON([
                "product_id": "paid", "state": state, "offer_kind": "paid",
                "valid_until": "2026-12-10T00:00:00Z", "grace_until": "2027-01-01T00:00:00Z",
                "trial_end_at": NSNull(), "auto_renew_enabled": true
            ]).utf8))
            let modified = LocalCareOverviewPresentation(
                ownerId: local.ownerId, canonicalGeneration: local.canonicalGeneration,
                snapshotGeneration: local.snapshotGeneration,
                cached: CachedCareOverview(
                    snapshot: try overviewSnapshot([page]), fetchedAt: now, snapshotLocale: "pl",
                    state: .cached, canonicalGenerationMatches: true
                ),
                cards: local.cards, pending: [], profile: local.profile, entitlement: entitlement,
                canonicalAccessKnown: true, careRows: []
            )
            let valid = CareOverviewViewState(local: modified, now: now, origin: .cache)
            XCTAssertEqual(valid.access, .verified)
            XCTAssertTrue(valid.plants.first?.automatedActionsAllowed == true)
            let expiredServer = CareOverviewViewState(local: modified, now: later, origin: .cache)
            XCTAssertEqual(expiredServer.access, .verified)
            XCTAssertEqual(expiredServer.availability, .readOnly)
            XCTAssertNil(expiredServer.plants.first?.routine)
            XCTAssertTrue(expiredServer.plants.first?.manualJournalAvailable == true)
        }
    }
}

extension CollectionWireTests {
    @MainActor
    private func assertLocalOutboxSignals(
        _ stream: AsyncStream<Void>, count: Int = 1,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let event = XCTestExpectation(description: "owner local outbox change")
        event.isInverted = count == 0
        event.expectedFulfillmentCount = max(1, count)
        event.assertForOverFulfill = true
        let excess = XCTestExpectation(description: "no extra buffered change")
        excess.isInverted = true
        var received = 0
        let reader = Task { @MainActor in
            for await _ in stream {
                received += 1
                if count > 0 && received > count {
                    excess.fulfill()
                } else {
                    event.fulfill()
                }
            }
        }
        let result = await XCTWaiter.fulfillment(of: [event], timeout: count == 0 ? 0.05 : 1)
        if count > 0 && result == .completed {
            let bounded = await XCTWaiter.fulfillment(of: [excess], timeout: 0.05)
            XCTAssertEqual(bounded, .completed, file: file, line: line)
        }
        reader.cancel()
        await reader.value
        XCTAssertEqual(result, .completed, file: file, line: line)
        XCTAssertEqual(received, count, file: file, line: line)
    }

    @MainActor
    func testLocalOutboxSignalsCoalesceWithoutReplayAndIsolateOwnersAndSubscribers() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try diskContainer(url))
        _ = try await store.enqueueCommand(ownerId: syncOwner, plantId: nil, commandName: "fixture", payloadJSON: "{}")
        await assertLocalOutboxSignals(await store.localOutboxUpdates(ownerId: syncOwner), count: 0)
        let first = await store.localOutboxUpdates(ownerId: syncOwner)
        let second = await store.localOutboxUpdates(ownerId: syncOwner)
        let foreign = await store.localOutboxUpdates(ownerId: otherSyncOwner)
        for _ in 0..<4 {
            let row = try await store.enqueueCommand(
                ownerId: syncOwner, plantId: nil, commandName: "fixture", payloadJSON: "{}"
            )
            try await store.recordOutboxFailure(operationId: row.operationId, errorMessage: "offline")
        }
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let rows = try await reopened.pendingOutboxEntries(for: syncOwner)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.filter { $0.retryCount == 1 }.count, 4)
        await assertLocalOutboxSignals(first)
        await assertLocalOutboxSignals(second)
        await assertLocalOutboxSignals(foreign, count: 0)
        let own = await store.localOutboxUpdates(ownerId: syncOwner)
        let other = await store.localOutboxUpdates(ownerId: otherSyncOwner)
        _ = try await store.enqueueCommand(ownerId: otherSyncOwner, plantId: nil, commandName: "fixture", payloadJSON: "{}")
        await assertLocalOutboxSignals(other)
        await assertLocalOutboxSignals(own, count: 0)
    }

    @MainActor
    func testLocalOutboxSignalsExposeDurableCoherentCareProfileDeleteAndFailureReads() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let (authority, lease) = try overviewBinding()
        try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
        let before = try await store.readCareOverviewPresentation(context: lease, authority: authority)
        let care = try ManualWateringAction.record.envelope(plantId: serverPlantId)
        let hour = try ProfileReminderHourCommand.make(reminderHourLocal: 10)
        var events = await store.localOutboxUpdates(ownerId: syncOwner)
        try await store.enqueueSavedPlantWatering(care, context: lease, authority: authority)
        _ = try await store.enqueueProfileReminderHour(hour, context: lease, authority: authority)
        let deletion = try await store.enqueuePlantDeletion(plantId: serverPlantId, context: lease, authority: authority)
        await assertLocalOutboxSignals(events)
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        var read = try await reopened.readCareOverviewPresentation(context: lease, authority: authority)
        XCTAssertEqual(read.pending.map(\.operationId), [care.operationId, hour.envelope.operationId, deletion.operationId])
        XCTAssertEqual(read.canonicalGeneration, before.canonicalGeneration)

        events = await store.localOutboxUpdates(ownerId: syncOwner)
        try await store.finishOutboxEntry(operationId: care.operationId, context: lease, authority: authority, failure: "offline")
        await assertLocalOutboxSignals(events)
        read = try await reopened.readCareOverviewPresentation(context: lease, authority: authority)
        XCTAssertEqual(read.pending.first?.retryCount, 1)
        XCTAssertEqual(read.pending.first?.lastError, "offline")

        events = await store.localOutboxUpdates(ownerId: syncOwner)
        try await store.recordOutboxFailure(operationId: deletion.operationId, errorMessage: "retry")
        await assertLocalOutboxSignals(events)
        read = try await reopened.readCareOverviewPresentation(context: lease, authority: authority)
        XCTAssertEqual(read.pending.last?.lastError, "retry")

        events = await store.localOutboxUpdates(ownerId: syncOwner)
        _ = try await store.finishProfileReminderHour(hour, receipt: nil, context: lease, authority: authority)
        await assertLocalOutboxSignals(events)
        read = try await reopened.readCareOverviewPresentation(context: lease, authority: authority)
        XCTAssertEqual(read.pending.map(\.operationId), [care.operationId, deletion.operationId])
        events = await store.localOutboxUpdates(ownerId: syncOwner)
        try await store.finishOutboxEntry(operationId: care.operationId, context: lease, authority: authority)
        await assertLocalOutboxSignals(events)
        read = try await reopened.readCareOverviewPresentation(context: lease, authority: authority)
        XCTAssertEqual(read.pending.map(\.operationId), [deletion.operationId])
        events = await store.localOutboxUpdates(ownerId: syncOwner)
        try await store.markOutboxCommitted(operationId: deletion.operationId)
        await assertLocalOutboxSignals(events)
        read = try await reopened.readCareOverviewPresentation(context: lease, authority: authority)
        XCTAssertTrue(read.pending.isEmpty)
        XCTAssertEqual(read.canonicalGeneration, before.canonicalGeneration)

        let creation = createCommand()
        events = await store.localOutboxUpdates(ownerId: syncOwner)
        let journal = try await store.catalogueCreateJournal(
            creation, mode: .enqueue(canCreate: true), context: lease, authority: authority
        )
        read = try await reopened.readCareOverviewPresentation(context: lease, authority: authority)
        guard case let .pending(created) = journal else {
            return XCTFail("Catalogue create was not enqueued")
        }
        XCTAssertEqual(created.envelope, creation)
        XCTAssertEqual(read.pending, [created])
        XCTAssertEqual(read.canonicalGeneration, before.canonicalGeneration)
        await assertLocalOutboxSignals(events)
        events = await store.localOutboxUpdates(ownerId: syncOwner)
        for mode in [CatalogueCreateJournalMode.checkOnly, .enqueue(canCreate: true)] {
            let replay = try await store.catalogueCreateJournal(
                creation, mode: mode, context: lease, authority: authority
            )
            XCTAssertEqual(replay, journal)
        }
        await assertLocalOutboxSignals(events, count: 0)
    }

    @MainActor
    func testLocalOutboxSignalsIgnoreDuplicateRejectedLeaseIdentityAndFailedSave() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let row = try await store.enqueueCommand(
            ownerId: syncOwner, plantId: nil, commandName: "fixture", payloadJSON: "{}"
        )
        let events = await store.localOutboxUpdates(ownerId: syncOwner)
        _ = try await store.enqueueCommand(
            operationId: row.operationId, ownerId: syncOwner, plantId: nil, commandName: "fixture", payloadJSON: "{}"
        )
        do {
            _ = try await store.enqueueCommand(
                operationId: row.operationId, ownerId: otherSyncOwner, plantId: nil, commandName: "fixture", payloadJSON: "{}"
            )
            XCTFail("Mismatched identity accepted")
        } catch OutboxEnqueueError.operationIdentityMismatch {}
        let (authority, lease) = try overviewBinding()
        authority.bind(try profileSession(ownerId: otherSyncOwner))
        do {
            _ = try await store.enqueueProfileReminderHour(
                ProfileReminderHourCommand.make(reminderHourLocal: 10), context: lease, authority: authority
            )
            XCTFail("Invalid lease accepted")
        } catch is SyncWireValidationError {}
        try await store.markOutboxCommitted(operationId: UUID())
        try await store.recordOutboxFailure(operationId: UUID(), errorMessage: "missing")
        await assertLocalOutboxSignals(events, count: 0)

        let readOnly = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
        let failed = await readOnly.localOutboxUpdates(ownerId: syncOwner)
        do {
            try await readOnly.recordOutboxFailure(operationId: row.operationId, errorMessage: "not saved")
            XCTFail("Read-only save accepted")
        } catch {}
        await assertLocalOutboxSignals(failed, count: 0)
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let rows = try await reopened.pendingOutboxEntries(for: syncOwner)
        XCTAssertEqual(rows, [row])
    }

    @MainActor
    func testLocalOutboxSignalsIncludeRoutineUndoAndCancellationDoesNotReplay() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let container = try diskContainer(url)
        let fixture = try await routineHistoryFixture(routineUndoBaseline(), container: container)
        let store = LocalStore(modelContainer: container)
        let identity = routineCompletionReceipt()
        let command = try RoutineSoilCheckUndoCommand.make(
            plantId: serverPlantId,
            taskId: XCTUnwrap(UUID(uuidString: identity["task_id"] as! String)),
            entryId: XCTUnwrap(UUID(uuidString: identity["entry_id"] as! String))
        )
        let cancelledStream = await store.localOutboxUpdates(ownerId: syncOwner)
        let reader = Task {
            var iterator = cancelledStream.makeAsyncIterator()
            return await iterator.next() != nil
        }
        reader.cancel()
        let received = await reader.value
        XCTAssertFalse(received)
        let events = await store.localOutboxUpdates(ownerId: syncOwner)
        _ = try await store.enqueueRoutineUndo(command, context: fixture.lease, authority: fixture.api.syncAuthority)
        await assertLocalOutboxSignals(events)
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let saved = try await reopened.pendingRoutineUndo(
            plantId: serverPlantId, context: fixture.lease, authority: fixture.api.syncAuthority
        )
        XCTAssertEqual(saved?.envelope, command.envelope)
        let duplicate = await store.localOutboxUpdates(ownerId: syncOwner)
        _ = try await store.enqueueRoutineUndo(command, context: fixture.lease, authority: fixture.api.syncAuthority)
        await assertLocalOutboxSignals(duplicate, count: 0)
        await assertLocalOutboxSignals(await store.localOutboxUpdates(ownerId: syncOwner), count: 0)
    }
}

extension CollectionWireTests {
    private func todayCalendarState(
        _ local: LocalCareOverviewPresentation, rows: [[String: Any]],
        known: Bool = true, aligned: Bool = true, pending: [OutboxEntrySnapshot] = [],
        cards: [CatalogueCardSummary]? = nil, deadline: String? = nil
    ) throws -> CareOverviewViewState {
        let now = try XCTUnwrap(SQLTimestamp.date(from: "2026-11-20T00:00:00Z"))
        var page = overviewPage(rows)
        page["verified_access_until"] = deadline.map { $0 as Any } ?? NSNull()
        let entitlement = try deadline.map { until in
            try JSONDecoder().decode(SyncWireEntitlementDTO.self, from: Data(syncJSON([
                "product_id": "paid", "state": "active", "offer_kind": "paid",
                "valid_until": until, "grace_until": NSNull(), "trial_end_at": NSNull(),
                "auto_renew_enabled": true
            ]).utf8))
        }
        return CareOverviewViewState(local: LocalCareOverviewPresentation(
            ownerId: local.ownerId, canonicalGeneration: local.canonicalGeneration,
            snapshotGeneration: local.snapshotGeneration,
            cached: CachedCareOverview(snapshot: try overviewSnapshot([page]), fetchedAt: now,
                                       snapshotLocale: "pl", state: .cached, canonicalGenerationMatches: aligned),
            cards: cards ?? local.cards, pending: pending, profile: local.profile,
            entitlement: entitlement, canonicalAccessKnown: known, careRows: []
        ), now: now, origin: .cache)
    }

    @MainActor
    func testTodayKnownStaleSurvivesFailedAlignmentWithoutInventingFirstFailureSchedule() async throws {
        for seed in [true, false] {
            var ahead = overviewPage([overviewRow(serverPlantId)])
            ahead["owner_watermark"] = "2026-11-19T09:00:00.000003+00:00"
            let transport = CatalogueTransport(seed ? [.http(200, try syncJSON(ahead)), .network] : [.network])
            let (url, _, _, lease, repo) = try await overviewRepositoryFixture(transport, seed: seed)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let model = TodayModel()
            let scope = model.activate(ownerId: syncOwner, generation: 1, locale: .pl)
            await model.rereadLocal(scope: scope) {
                try await repo.cachedCareOverview(context: lease)
            }
            let now = try XCTUnwrap(SQLTimestamp.date(from: "2026-11-20T00:00:00Z"))
            XCTAssertEqual(TodayCalendar(state: model.state, now: now).sections.isEmpty, !seed)
            await model.refresh(scope: scope) {
                try await repo.refreshCareOverview(locale: .pl, context: lease)
            }
            let state = try XCTUnwrap(model.state)
            XCTAssertEqual(state.ownerId, syncOwner)
            XCTAssertEqual(state.access, .free)
            XCTAssertTrue(state.pending.isEmpty)
            XCTAssertTrue(model.hasError)
            XCTAssertEqual(state.origin, .cache)
            XCTAssertEqual(state.lastCheckedAt == nil, !seed)
            XCTAssertEqual(state.availability, seed ? .readOnly : .unavailable)
            XCTAssertEqual(state.failure, seed ? .revalidationRequired : .transport)
            XCTAssertEqual(state.knownInvalidation, seed ? .canonicalRevalidation : nil)
            let calendar = TodayCalendar(state: state, now: now)
            XCTAssertEqual(calendar.status, .unavailable)
            XCTAssertTrue(calendar.sections.isEmpty)
            XCTAssertEqual(calendar.needsRevalidation, seed)
            XCTAssertTrue(state.plants.allSatisfy { $0.routine == nil && $0.controls.isEmpty })
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map { $0.url?.lastPathComponent },
                           seed ? ["care-overview", "sync"] : ["care-overview"])
        }
    }

    @MainActor
    func testTodayRotatedGenerationTransportFailureKeepsStaleDistinctFromAlignedOfflineAndFirstFailure() async throws {
        for (seed, rotate) in [(true, true), (true, false), (false, false)] {
            let transport = CatalogueTransport([.network])
            let (url, store, api, lease, repo) = try await overviewRepositoryFixture(transport, seed: seed)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let saved = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
            let savedAt = saved.cached?.fetchedAt
            XCTAssertEqual(savedAt == nil, !seed)
            if seed {
                XCTAssertEqual(saved.snapshotGeneration, saved.canonicalGeneration)
                XCTAssertEqual(saved.cached?.canonicalGenerationMatches, true)
            }
            if rotate {
                // Real ordinary empty publish at the fixture's existing watermark; no invalidation marker.
                try await overviewCanonical(store, authority: api.syncAuthority, lease: lease, ids: [])
            }
            let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
            XCTAssertNil(local.knownInvalidation)
            XCTAssertEqual(local.snapshotGeneration, saved.snapshotGeneration)
            if rotate {
                XCTAssertNotNil(local.canonicalGeneration)
                XCTAssertNotEqual(local.canonicalGeneration, saved.canonicalGeneration)
                XCTAssertNotEqual(local.snapshotGeneration, local.canonicalGeneration)
                XCTAssertEqual(local.cached?.canonicalGenerationMatches, false)
            }
            let model = TodayModel()
            let scope = model.activate(ownerId: syncOwner, generation: 1, locale: .pl)
            await model.rereadLocal(scope: scope) {
                try await repo.cachedCareOverview(context: lease)
            }
            let now = try XCTUnwrap(SQLTimestamp.date(from: "2026-11-20T00:00:00Z"))
            let baseline = TodayCalendar(state: model.state, now: now)
            await model.refresh(scope: scope) {
                try await repo.refreshCareOverview(locale: .pl, context: lease)
            }
            let state = try XCTUnwrap(model.state)
            XCTAssertTrue(model.hasError)
            XCTAssertEqual(state.failure, .transport)
            XCTAssertNil(state.knownInvalidation)
            XCTAssertEqual(state.origin, .cache)
            XCTAssertEqual(state.lastCheckedAt, savedAt)
            if seed {
                XCTAssertEqual(state.canonicalGeneration, local.canonicalGeneration)
            } else {
                // The first beginCareOverviewRead reserves a wrapper even if transport fails.
                XCTAssertNil(local.canonicalGeneration)
                XCTAssertNotNil(state.canonicalGeneration)
            }
            XCTAssertEqual(state.snapshotGeneration, local.snapshotGeneration)
            XCTAssertEqual(state.availability, seed ? (rotate ? .readOnly : .available) : .unavailable)
            let calendar = TodayCalendar(state: state, now: now)
            XCTAssertEqual(calendar.needsRevalidation, rotate)
            XCTAssertNotEqual(calendar.status, .empty)
            XCTAssertNotEqual(calendar.status, .noSchedule)
            if seed && !rotate {
                XCTAssertEqual(calendar.status, .scheduled)
                XCTAssertFalse(calendar.sections.isEmpty)
                XCTAssertEqual(calendar.sections.flatMap(\.checks).map(\.due),
                               baseline.sections.flatMap(\.checks).map(\.due))
                XCTAssertTrue(calendar.sections.flatMap(\.checks).allSatisfy {
                    SQLCalendarDay.date(from: $0.due) != nil
                })
            } else {
                XCTAssertEqual(calendar.status, .unavailable)
                XCTAssertTrue(calendar.sections.isEmpty)
                XCTAssertTrue(state.plants.allSatisfy { $0.routine == nil && $0.controls.isEmpty })
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["care-overview"])
        }
    }

    @MainActor
    func testTodayLastCheckedUsesPersistedFetchThroughLocalAndFailedReads() async throws {
        for seed in [false, true] {
            let transport = CatalogueTransport([.network])
            let (url, store, api, lease, repo) = try await overviewRepositoryFixture(transport, seed: seed)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
            let savedAt = local.cached?.fetchedAt
            XCTAssertEqual(savedAt == nil, !seed)
            let baseline = try await repo.cachedCareOverview(context: lease)
            XCTAssertEqual(baseline.lastCheckedAt, savedAt)
            let pending = OutboxEntrySnapshot(
                operationId: UUID(), ownerId: syncOwner, plantId: serverPlantId,
                commandName: "care.record", payloadJSON: "{}", sequenceNumber: 1
            )
            let overlay = LocalCareOverviewPresentation(
                ownerId: local.ownerId, canonicalGeneration: local.canonicalGeneration,
                snapshotGeneration: local.snapshotGeneration, cached: local.cached, cards: local.cards,
                pending: [pending], profile: local.profile, entitlement: local.entitlement,
                canonicalAccessKnown: local.canonicalAccessKnown, careRows: local.careRows
            )
            for offset in [0.0, 3600.0, 86400.0] {
                let view = CareOverviewViewState(
                    local: overlay, now: Date(timeIntervalSince1970: 2_000_000_000 + offset), origin: .cache
                )
                XCTAssertEqual(view.lastCheckedAt, savedAt)
                XCTAssertNil(view.plants.first?.routine)
            }
            let failed = try await repo.refreshCareOverview(locale: .pl, context: lease)
            XCTAssertEqual(failed.failure, .transport)
            XCTAssertEqual(failed.lastCheckedAt, savedAt)
            let reopened = LocalStore(modelContainer: try diskContainer(url))
            let canonicalRead = try await reopened.readCareOverviewPresentation(
                context: lease, authority: api.syncAuthority
            )
            XCTAssertEqual(CareOverviewViewState(
                local: canonicalRead, now: Date(timeIntervalSince1970: 2_100_000_000), origin: .cache
            ).lastCheckedAt, savedAt)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["care-overview"])
        }
    }

    func testTodayCoreFailureAllowsOnlyConnectivityFallback() {
        for code: URLError.Code in [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                    .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            XCTAssertTrue(CareReconciliationOutcome.permitsOverviewRead(after: URLError(code)))
        }
        for error: Error in [CancellationError(), URLError(.cancelled), URLError(.badServerResponse),
                             URLError(.cannotParseResponse), SyncWireValidationError.invalidSession,
                             SyncWireValidationError.invalidPage, CareOverviewAuthorizationError.denied,
                             CareOverviewStoreError.superseded] {
            XCTAssertFalse(CareReconciliationOutcome.permitsOverviewRead(after: error))
        }
    }

    @MainActor
    func testTodayCalendarKeepsTodayAndOverdueSourceDates() async throws {
        let (url, _, _, lease, repo) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let state = try await repo.cachedCareOverview(context: lease)
        let now = try XCTUnwrap(SQLTimestamp.date(from: "2026-11-05T12:00:00Z"))
        let projection = TodayCalendar(state: state, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(projection.status, .scheduled)
        XCTAssertEqual(projection.sections.map(\.day), ["2026-11-01", "2026-11-05"])
        XCTAssertEqual(projection.sections.flatMap(\.checks).map(\.due), ["2026-11-01", "2026-11-05"])
        XCTAssertTrue(projection.sections[0].checks[0].followUp)
        XCTAssertEqual(projection.sections[0].checks[0].source.locator, "Published check")
        XCTAssertFalse(projection.sections[1].checks[0].followUp)
    }

    @MainActor
    func testTodayCalendarNearestTiesAndHonestEmptyStates() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        var control = overviewControl()
        var policy = try XCTUnwrap(control["policy"] as? [String: Any])
        policy["due_on"] = "2026-11-05"; control["policy"] = policy
        var later = control
        later["control_id"] = UUID().uuidString
        policy["due_on"] = "2026-11-06"; later["policy"] = policy
        let rows = [overviewRow(serverPlantId, dated: true, controls: [control, later])]
        let now = try XCTUnwrap(SQLTimestamp.date(from: "2026-11-04T12:00:00Z"))
        let tied = TodayCalendar(state: try todayCalendarState(local, rows: rows), now: now)
        XCTAssertEqual(tied.sections.map(\.day), ["2026-11-05"])
        XCTAssertEqual(tied.sections.first?.checks.count, 2)
        XCTAssertEqual(Set(tied.sections.flatMap(\.checks).map(\.id)).count, 2)
        let undated = [overviewRow(serverPlantId)]
        func status(known: Bool = true, aligned: Bool = true, pending: [OutboxEntrySnapshot] = []) throws -> TodayCalendar.Status {
            TodayCalendar(state: try todayCalendarState(local, rows: undated, known: known,
                                                       aligned: aligned, pending: pending), now: now).status
        }
        XCTAssertEqual(try status(), .noSchedule)
        XCTAssertEqual(try status(known: false), .unknown)
        XCTAssertEqual(try status(aligned: false), .unavailable)
        let pending = OutboxEntrySnapshot(operationId: UUID(), ownerId: lease.ownerId, plantId: serverPlantId,
                                         commandName: "care.record", payloadJSON: "{}", sequenceNumber: 1)
        XCTAssertEqual(try status(pending: [pending]), .pending)
        XCTAssertEqual(TodayCalendar(state: try todayCalendarState(local, rows: [], cards: []), now: now).status, .empty)
        XCTAssertEqual(TodayCalendar(state: nil, now: now).status, .unavailable)
    }

    func testTodayCalendarUsesLocalGregorianDayAndDSTMidnight() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let before = try XCTUnwrap(SQLTimestamp.date(from: "2026-03-08T07:30:00Z"))
        XCTAssertEqual(TodayCalendar.day(before, timeZone: zone), "2026-03-07")
        let start = try XCTUnwrap(SQLTimestamp.date(from: "2026-03-08T08:00:00Z"))
        let next = TodayCalendar.boundary(now: start, deadline: nil, timeZone: zone)
        XCTAssertEqual(TodayCalendar.day(start, timeZone: zone), "2026-03-08")
        XCTAssertEqual(TodayCalendar.day(next, timeZone: zone), "2026-03-09")
        XCTAssertEqual(next.timeIntervalSince(start), 23 * 3600)
        XCTAssertEqual(TodayCalendar.calendar(timeZone: zone).identifier, .gregorian)
    }

    @MainActor
    func testTodayCalendarSuppressesExactExpiryWithoutWaitingForStore() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        let raw = "2026-11-21T00:00:00.123456Z"
        let deadline = try XCTUnwrap(SQLTimestamp.date(from: raw))
        let state = try todayCalendarState(local, rows: [overviewRow(serverPlantId, dated: true)], deadline: raw)
        let before = deadline.addingTimeInterval(-0.001)
        let zone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(TodayCalendar.boundary(now: before, deadline: state.verifiedAccessUntil, timeZone: zone), deadline)
        XCTAssertFalse(TodayCalendar(state: state, now: before).sections.isEmpty)
        let expired = TodayCalendar(state: state, now: deadline)
        XCTAssertEqual(expired.status, .paused)
        XCTAssertTrue(expired.sections.isEmpty)
        XCTAssertNotNil(state.plants.first?.routine)
        XCTAssertTrue(state.plants.first?.manualJournalAvailable == true)
    }
}

#if DEBUG && targetEnvironment(simulator)
extension CollectionWireTests {
    @MainActor
    func testTodayFixtureLocalBoundarySeedSurvivesReadsAndReopen() async throws {
        let cases = [
            ("2026-12-31T21:30:00Z", 3 * 3600, "2027-01-01", "2026-12-31"),
            ("2027-01-01T00:30:00Z", -3 * 3600, "2026-12-31", "2026-12-30"),
            ("2026-12-31T21:30:00Z", 0, "2026-12-31", "2026-12-30")
        ]
        for (timestamp, offset, day, overdue) in cases {
            let now = try XCTUnwrap(SQLTimestamp.date(from: timestamp))
            let zone = try XCTUnwrap(TimeZone(secondsFromGMT: offset))
            let namespace = UUID().uuidString
            var h = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .todayMixed,
                initialDate: now, initialTimeZone: zone)
            defer { try? h.cleanup() }
            let seed = h.server.snapshot
            let first = try XCTUnwrap(seed.plants.first?.id)
            for cold in [false, true] {
                if cold {
                    h.shutdown()
                    h = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .todayMixed,
                        initialDate: now.addingTimeInterval(3 * 86400),
                        initialTimeZone: TimeZone(secondsFromGMT: -offset)!)
                }
                XCTAssertEqual(h.server.snapshot.todayAnchorDay, day)
                XCTAssertEqual(h.server.snapshot.todayClockSeed, timestamp)
                XCTAssertEqual(h.server.snapshot.permanent, seed.permanent)
                XCTAssertEqual(h.server.snapshot.guest, seed.guest)
                XCTAssertEqual(h.server.snapshot.plants.map(\.id), seed.plants.map(\.id))
                let session = try await h.connection.sessionSnapshot()
                let sync = try XCTUnwrap(h.connection.syncEngine)
                _ = try await sync.pullDelta(for: session.session.userId)
                let lease = try await h.connection.collectionLease(expected: session)
                let repo = try XCTUnwrap(h.connection.repository)
                let state = try await repo.refreshCareOverview(locale: .en, context: lease)
                XCTAssertNil(state.failure)
                let calendar = TodayCalendar(state: state, now: now, timeZone: zone)
                XCTAssertEqual(calendar.today, day)
                XCTAssertEqual(calendar.status, .scheduled)
                XCTAssertEqual(calendar.sections.map(\.day), [overdue, day])
                XCTAssertEqual(calendar.sections.last?.checks.map(\.plantId), [first])
                let api = try XCTUnwrap(h.connection.apiClient)
                let overview = try await api.fetchCareOverview(context: lease, limit: 2, locale: .en)
                XCTAssertTrue(overview.pages.allSatisfy { $0.serverNow == timestamp })
                for row in overview.plants {
                    let card = try await api.fetchCareRecommendation(plantId: row.plantId, context: lease)
                    XCTAssertEqual(card, try row.careRecommendation.validated(for: row.plantId))
                    if row.plantId == first { XCTAssertEqual(card?.nextCheck?.dueOn, day) }
                }
                XCTAssertEqual(h.server.snapshot.todayAnchorDay, seed.todayAnchorDay)
                XCTAssertEqual(h.server.snapshot.todayClockSeed, seed.todayClockSeed)
                XCTAssertTrue(h.server.snapshot.attempts.isEmpty)
                XCTAssertTrue(h.server.snapshot.commits.isEmpty)
            }
        }
    }

    @MainActor
    func testTodayConsentSeedKeepsUTCAtLocalYearBoundary() async throws {
        let timestamp = "2026-12-31T21:30:00Z"
        let now = try XCTUnwrap(SQLTimestamp.date(from: timestamp))
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 3 * 3600))
        let ordinary = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .todayFuture,
            initialDate: now, initialTimeZone: zone)
        defer { try? ordinary.cleanup() }
        let namespace = UUID().uuidString.lowercased()
        guard case let .fixture(configuration) = ReminderConsentLaunch.parse([
            "app", "--care-reminder-fixture", "eligible", "--care-reminder-namespace", namespace
        ]) else { return XCTFail("Valid dedicated consent configuration rejected") }
        var consent = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .todayFuture,
            reminderConfiguration: configuration, reminderPreparation: { _, _ in },
            initialDate: now, initialTimeZone: zone)
        defer { try? consent.cleanup() }
        let owner = consent.server.snapshot.permanent
        XCTAssertEqual(consent.server.snapshot.todayAnchorDay, "2026-12-31")
        XCTAssertEqual(consent.server.snapshot.todayClockSeed, timestamp)
        consent.shutdown()
        consent = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .todayFuture,
            reminderConfiguration: configuration, reminderPreparation: { _, _ in },
            initialDate: now.addingTimeInterval(86400), initialTimeZone: zone)
        XCTAssertEqual(ordinary.server.snapshot.todayAnchorDay, "2027-01-01")
        XCTAssertEqual(consent.server.snapshot.todayAnchorDay, "2026-12-31")
        XCTAssertEqual(consent.server.snapshot.todayClockSeed, timestamp)
        XCTAssertEqual(ordinary.server.snapshot.todayClockSeed, timestamp)
        XCTAssertEqual(consent.server.snapshot.permanent, owner)
        XCTAssertEqual(consent.server.snapshot.reminderMode, "eligible")
    }

    @MainActor
    func testTodayFixtureCompletePagesMatchCardsWithoutCareWrites() async throws {
        for scenario in [CatalogueUIFixtureScenario.todayMixed, .todayFuture] {
            let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: scenario)
            defer { try? h.cleanup() }
            let expected = try await h.connection.sessionSnapshot()
            let api = try XCTUnwrap(h.connection.apiClient)
            let sync = try XCTUnwrap(h.connection.syncEngine)
            let store = try XCTUnwrap(h.connection.store)
            let repo = try XCTUnwrap(h.connection.repository)
            _ = try await sync.pullDelta(for: expected.session.userId)
            let lease = try await h.connection.collectionLease(expected: expected)
            let token = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: api.syncAuthority)
            let before = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
            let requestStart = h.server.requests.count
            let snapshot = try await api.fetchCareOverview(context: lease, limit: 2, locale: .en)
            XCTAssertEqual(snapshot.pages.count, 2)
            XCTAssertEqual(snapshot.pages.map { $0.plants.count }, [2, 1])
            XCTAssertEqual(snapshot.pages.first?.nextAfter, snapshot.pages.first?.plants.last?.plantId)
            XCTAssertNil(snapshot.pages.last?.nextAfter)
            XCTAssertEqual(snapshot.plants.map(\.plantId),
                           h.server.snapshot.plants.map(\.id).sorted { $0.uuidString < $1.uuidString })
            for page in snapshot.pages {
                XCTAssertEqual(page.ownerId, expected.session.userId)
                XCTAssertEqual(page.serverNow, h.server.snapshot.todayClockSeed)
                XCTAssertEqual(page.ownerWatermark, snapshot.pages[0].ownerWatermark)
                XCTAssertEqual(page.publicationFingerprint, String(repeating: "a", count: 64))
                XCTAssertEqual(page.reminderHourLocal, 9)
                XCTAssertTrue(page.automationAllowed)
                XCTAssertNil(page.verifiedAccessUntil)
            }
            for row in snapshot.plants {
                XCTAssertEqual(row.careRevision, 1)
                XCTAssertTrue(row.firstAidControls.isEmpty)
                let card = try await api.fetchCareRecommendation(plantId: row.plantId, context: lease)
                XCTAssertEqual(card, try row.careRecommendation.validated(for: row.plantId))
                if let routine = row.careRecommendation.routineCheck {
                    XCTAssertEqual(routine.ruleId, row.plantId)
                    XCTAssertEqual(routine.careRevision, row.careRevision)
                    XCTAssertEqual(row.careRecommendation.nextCheck?.source.locator, "Fixture interval")
                }
                let membership = try await store.syncedBasicCareEnabledAt(
                    plantId: row.plantId, context: lease, authority: api.syncAuthority
                )
                XCTAssertNotNil(membership)
            }
            try await store.finishCareOverviewRead(token, snapshot: snapshot, authority: api.syncAuthority)
            let count = h.server.requests.count
            let state = try await repo.cachedCareOverview(context: lease)
            let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
            XCTAssertEqual(h.server.requests.count, count, "Local readers must not send HTTP")
            XCTAssertEqual(local.canonicalGeneration, before.canonicalGeneration)
            XCTAssertEqual(local.careRows.map(\.payloadJSON), before.careRows.map(\.payloadJSON))
            XCTAssertTrue(local.pending.isEmpty)
            XCTAssertEqual(state.access, .free)
            XCTAssertEqual(state.plants.filter { $0.routine == nil }.count, 1)
            let now = try XCTUnwrap(h.server.snapshot.todayClockSeed.flatMap(SQLTimestamp.date(from:)))
            let calendar = TodayCalendar(state: state, now: now, timeZone: .current)
            XCTAssertEqual(calendar.status, .scheduled)
            XCTAssertEqual(calendar.sections.flatMap(\.checks).count, 2)
            XCTAssertEqual(calendar.sections.count, scenario == .todayFuture ? 1 : 2)
            XCTAssertEqual(h.server.snapshot.overviewRequests, 2)
            XCTAssertTrue(h.server.snapshot.attempts.isEmpty)
            XCTAssertTrue(h.server.snapshot.commits.isEmpty)
            XCTAssertTrue(h.server.requests.dropFirst(requestStart).allSatisfy { $0.httpMethod == "GET" })

            // Invalid queries/authority are transport errors, never successful empty pages.
            let valid = try XCTUnwrap(h.server.requests.first { $0.url?.lastPathComponent == "care-overview" })
            for query in ["limit=0", "limit=2&limit=2", "limit=2&owner_id=\(expected.session.userId)",
                          "limit=2&after=invalid"] {
                var request = valid
                var url = try XCTUnwrap(URLComponents(url: try XCTUnwrap(valid.url), resolvingAgainstBaseURL: false))
                url.percentEncodedQuery = query
                request.url = url.url
                do { _ = try await h.http.data(for: request); XCTFail("Invalid query accepted") } catch {}
            }
            for header in ["Authorization", "X-Client-Locale", "X-Installation-Credential"] {
                var request = valid
                request.setValue("invalid", forHTTPHeaderField: header)
                do { _ = try await h.http.data(for: request); XCTFail("Invalid header accepted") } catch {}
            }
            XCTAssertEqual(h.server.snapshot.overviewRequests, 2)
        }
    }

    @MainActor
    func testTodayFixtureEmptyUnscheduledAndInitialFailureRemainDistinct() async throws {
        for scenario in [CatalogueUIFixtureScenario.todayEmpty, .todayNoSchedule, .todayFirstFailure] {
            let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: scenario)
            defer { try? h.cleanup() }
            let expected = try await h.connection.sessionSnapshot()
            let sync = try XCTUnwrap(h.connection.syncEngine)
            let api = try XCTUnwrap(h.connection.apiClient)
            let repo = try XCTUnwrap(h.connection.repository)
            let store = try XCTUnwrap(h.connection.store)
            _ = try await sync.pullDelta(for: expected.session.userId)
            let lease = try await h.connection.collectionLease(expected: expected)
            let state = try await repo.refreshCareOverview(locale: .en, context: lease)
            let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
            let calendar = TodayCalendar(state: state, now: Date())
            XCTAssertEqual(calendar.status, scenario == .todayEmpty ? .empty :
                            scenario == .todayNoSchedule ? .noSchedule : .unavailable)
            XCTAssertEqual(state.plants.count, scenario.initialCount)
            XCTAssertTrue(state.plants.allSatisfy { $0.routine == nil && $0.controls.isEmpty })
            XCTAssertEqual(state.failure, scenario == .todayFirstFailure ? .transport : nil)
            XCTAssertEqual(local.cached == nil, scenario == .todayFirstFailure)
            XCTAssertTrue(local.pending.isEmpty)
            XCTAssertEqual(h.server.snapshot.overviewRequests, 1)
            XCTAssertTrue(h.server.snapshot.attempts.isEmpty)
            XCTAssertTrue(h.server.snapshot.commits.isEmpty)
        }
    }

    @MainActor
    func testTodayFixtureSavedFailureAndOfflineSurviveColdContextWithoutFreshness() async throws {
        let namespace = UUID().uuidString
        var h = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .todaySaved)
        defer { try? h.cleanup() }
        let expected = try await h.connection.sessionSnapshot()
        let sync = try XCTUnwrap(h.connection.syncEngine)
        _ = try await sync.pullDelta(for: expected.session.userId)
        var lease = try await h.connection.collectionLease(expected: expected)
        var repo = try XCTUnwrap(h.connection.repository)
        let accepted = try await repo.refreshCareOverview(locale: .en, context: lease)
        XCTAssertNil(accepted.failure)
        let api = try XCTUnwrap(h.connection.apiClient)
        let store = try XCTUnwrap(h.connection.store)
        let saved = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        let cache = try XCTUnwrap(saved.cached)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(cache.snapshot)
        let dates = accepted.plants.compactMap { $0.routine?.dueLocalDate }
        let seed = h.server.snapshot.todayClockSeed
        let day = h.server.snapshot.todayAnchorDay
        var reads = 1
        for phase in [CatalogueFixtureServer.TodayPhase.failOverview, .offline] {
            try h.changeTodayPhase(phase)
            let failed = try await repo.refreshCareOverview(locale: .en, context: lease)
            reads += 1
            XCTAssertEqual(failed.failure, .transport)
            XCTAssertEqual(failed.origin, .cache)
            XCTAssertEqual(failed.plants.compactMap { $0.routine?.dueLocalDate }, dates)
            h.shutdown()
            h = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .todaySaved)
            XCTAssertEqual(h.server.snapshot.todayTransport, phase)
            XCTAssertEqual(h.server.snapshot.todayClockSeed, seed)
            XCTAssertEqual(h.server.snapshot.todayAnchorDay, day)
            let reopened = try await h.connection.sessionSnapshot()
            lease = try await h.connection.collectionLease(expected: reopened)
            repo = try XCTUnwrap(h.connection.repository)
            let coldAPI = try XCTUnwrap(h.connection.apiClient)
            let coldStore = try XCTUnwrap(h.connection.store)
            let count = h.server.requests.count
            let cold = try await repo.cachedCareOverview(context: lease)
            let local = try await coldStore.readCareOverviewPresentation(context: lease, authority: coldAPI.syncAuthority)
            XCTAssertEqual(h.server.requests.count, count)
            XCTAssertEqual(cold.origin, .cache)
            XCTAssertEqual(cold.plants.compactMap { $0.routine?.dueLocalDate }, dates)
            let retained = try XCTUnwrap(local.cached)
            XCTAssertEqual(retained.fetchedAt, cache.fetchedAt)
            XCTAssertEqual(try encoder.encode(retained.snapshot), bytes)
            XCTAssertEqual(local.canonicalGeneration, saved.canonicalGeneration)
            XCTAssertTrue(local.pending.isEmpty)
            let retry = try await repo.refreshCareOverview(locale: .en, context: lease)
            reads += 1
            XCTAssertEqual(retry.failure, .transport)
            XCTAssertEqual(h.server.snapshot.overviewRequests, reads)
            XCTAssertTrue(h.server.snapshot.attempts.isEmpty)
            XCTAssertTrue(h.server.snapshot.commits.isEmpty)
        }
        // Resume only emits Root's event. Withdrawal itself must not perform HTTP.
        let count = h.server.requests.count
        var reconnects = 0
        h.connection.reconcileFixtureReconnect = { reconnects += 1 }
        try h.resumeToday()
        XCTAssertEqual(reconnects, 1)
        XCTAssertEqual(h.server.requests.count, count)
        try h.changeTodayPhase(.withdrawn)
        XCTAssertEqual(h.server.requests.count, count)
        let withdrawn = try await repo.refreshCareOverview(locale: .en, context: lease)
        XCTAssertNil(withdrawn.failure)
        XCTAssertTrue(withdrawn.plants.allSatisfy { $0.routine == nil && $0.advice == nil })
        XCTAssertEqual(withdrawn.canonicalGeneration, saved.canonicalGeneration)
        let withdrawalReadCount = h.server.requests.count
        try h.resumeToday()
        XCTAssertEqual(reconnects, 2)
        XCTAssertEqual(h.server.requests.count, withdrawalReadCount)
        XCTAssertEqual(h.server.snapshot.todayTransport, .normal)
        let resumed = try await repo.refreshCareOverview(locale: .en, context: lease)
        XCTAssertNil(resumed.failure)
        XCTAssertEqual(resumed.plants.compactMap { $0.routine?.dueLocalDate }, dates)
        XCTAssertEqual(h.server.snapshot.overviewRequests, reads + 2)
    }
}
#endif

extension CollectionWireTests {
    @MainActor
    private func receiptReject(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Receipt operation must fail closed") } catch {}
    }

    @MainActor
    private func receiptEdit(_ url: URL, _ action: (ModelContext) throws -> Void) throws {
        let disk = ModelContext(try diskContainer(url))
        disk.autosaveEnabled = false
        try action(disk)
        try disk.save()
    }

    private func forgedReceipt(
        _ ledger: CareReminderReceipts, _ edit: (inout [String: Any]) -> Void
    ) throws -> CareReminderReceipts {
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        var records = try XCTUnwrap(wire["entries"] as? [[String: Any]])
        var entry = try XCTUnwrap(records[0]["entry"] as? [String: Any])
        edit(&entry)
        records[0]["entry"] = entry
        wire["entries"] = records
        return try JSONDecoder().decode(CareReminderReceipts.self, from: JSONSerialization.data(withJSONObject: wire))
    }

    @MainActor
    func testReminderStoreDiskPhasesOwnerIsolationAndConsumedOpportunity() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (authority, lease) = try overviewBinding()
        let store = LocalStore(modelContainer: try diskContainer(url))
        try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
        _ = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
        let unrelated = try overviewDiskState(url)
        let missing = try await store.readCareReminderReceipts(context: lease, authority: authority)
        XCTAssertNil(missing)
        var token = try await store.beginCareReminderReceipts(context: lease, authority: authority)
        let emptyState = try overviewDiskState(url)
        let same = try await store.beginCareReminderReceipts(context: lease, authority: authority)
        XCTAssertEqual(same.revision, token.revision)
        let noop = try await store.commitCareReminderReceipts(token.receipts, replacing: token, authority: authority)
        XCTAssertEqual(noop.revision, token.revision)
        XCTAssertEqual(try overviewDiskState(url), emptyState)
        let candidate = try receiptCandidate()
        let changed = try receiptCandidate(due: "2026-11-28", hour: 11,
            zone: TimeZone(identifier: "America/New_York"))
        let phases: [CareReminderReceipts.Phase] = [.prepared, .armed, .cancelledBeforeFire, .prepared, .uncertain, .spent]
        for (index, phase) in phases.enumerated() {
            var ledger = token.receipts
            switch index {
            case 0: _ = try ledger.prepare(candidate, now: receiptNow)
            case 1:
                _ = try ledger.acknowledge(id: candidate.id, attemptId: XCTUnwrap(ledger.entries[candidate.id]).attemptId, now: receiptNow)
            case 2:
                _ = try ledger.cancel(id: candidate.id, attemptId: XCTUnwrap(ledger.entries[candidate.id]).attemptId,
                    proof: .removedAndReadBackAbsent(confirmedAt: receiptNow), now: receiptNow)
            case 3: _ = try ledger.prepare(changed, now: receiptNow)
            case 4: try ledger.observe(id: candidate.id, now: receiptNow, unknown: true)
            default: try ledger.observe(id: candidate.id, now: changed.absoluteFireDate, delivered: true)
            }
            let saved = try await store.commitCareReminderReceipts(ledger, replacing: token, authority: authority)
            XCTAssertNotEqual(saved.revision, token.revision)
            let cold = LocalStore(modelContainer: try diskContainer(url))
            let read = try await cold.readCareReminderReceipts(context: lease, authority: authority)
            token = try XCTUnwrap(read)
            XCTAssertEqual(token.revision, saved.revision)
            XCTAssertEqual(token.receipts, ledger)
            XCTAssertEqual(token.receipts.entries[candidate.id]?.phase, phase)
            XCTAssertEqual(token.receipts.entries[candidate.id]?.originalFireDate, candidate.absoluteFireDate)
            XCTAssertEqual(token.receipts.entries[candidate.id]?.currentFireDate,
                           index < 3 ? candidate.absoluteFireDate : changed.absoluteFireDate)
        }
        var spent = token.receipts
        XCTAssertEqual(try spent.prepare(receiptCandidate(due: "2026-11-29", hour: 16),
            now: changed.absoluteFireDate.addingTimeInterval(3600)), .blocked)
        let blocked = try await store.commitCareReminderReceipts(spent, replacing: token, authority: authority)
        XCTAssertEqual(blocked.revision, token.revision)
        let b = SyncSessionAuthority()
        b.bind(try profileSession(ownerId: otherSyncOwner))
        let leaseB = try b.capture(ownerId: otherSyncOwner)
        let emptyB = try await store.beginCareReminderReceipts(context: leaseB, authority: b)
        XCTAssertTrue(emptyB.receipts.entries.isEmpty)
        await receiptReject {
            _ = try await store.commitCareReminderReceipts(token.receipts, replacing: emptyB, authority: b)
        }
        XCTAssertEqual(try overviewDiskState(url).filter { !$0.contains("local_care_reminder_receipts") }, unrelated)
    }

    @MainActor
    func testReminderStoreTwoWritersLeaseFencesAndPurgeABA() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (authority, lease) = try overviewBinding()
        let store = LocalStore(modelContainer: try diskContainer(url))
        let second = LocalStore(modelContainer: try diskContainer(url))
        let first = try await store.beginCareReminderReceipts(context: lease, authority: authority)
        let other = try await second.beginCareReminderReceipts(context: lease, authority: authority)
        var ledger = first.receipts
        _ = try ledger.prepare(receiptCandidate(), now: receiptNow)
        let replacement = ledger
        let a = Task { try await store.commitCareReminderReceipts(replacement, replacing: first, authority: authority) }
        let b = Task { try await second.commitCareReminderReceipts(replacement, replacing: other, authority: authority) }
        var winners = 0
        for task in [a, b] {
            do { _ = try await task.value; winners += 1 }
            catch CareReminderReceiptStoreError.superseded {}
        }
        XCTAssertEqual(winners, 1)
        let currentRead = try await store.readCareReminderReceipts(context: lease, authority: authority)
        let current = try XCTUnwrap(currentRead)
        let before = try overviewDiskState(url)
        let (foreign, _) = try overviewBinding()
        await receiptReject { _ = try await store.commitCareReminderReceipts(replacement, replacing: current, authority: foreign) }
        for session in [nil, try profileSession(ownerId: otherSyncOwner), try profileSession()] {
            authority.bind(session)
            await receiptReject { _ = try await store.beginCareReminderReceipts(context: lease, authority: authority) }
            await receiptReject { _ = try await store.readCareReminderReceipts(context: lease, authority: authority) }
            await receiptReject { _ = try await store.commitCareReminderReceipts(replacement, replacing: current, authority: authority) }
        }
        authority.bind(try profileSession(claims: ["sub": syncOwner.uuidString, "is_anonymous": true]))
        let anonymous = try authority.capture(ownerId: syncOwner)
        await receiptReject { _ = try await store.beginCareReminderReceipts(context: anonymous, authority: authority) }
        await receiptReject { _ = try await store.readCareReminderReceipts(context: anonymous, authority: authority) }
        XCTAssertEqual(try overviewDiskState(url), before)
        authority.bind(try profileSession())
        let fresh = try authority.capture(ownerId: syncOwner)
        let old = try await store.beginCareReminderReceipts(context: fresh, authority: authority)
        try await store.purgeCareReminderReceiptMetadata(ownerId: syncOwner)
        await receiptReject { _ = try await store.commitCareReminderReceipts(replacement, replacing: old, authority: authority) }
        let next = try await store.beginCareReminderReceipts(context: fresh, authority: authority)
        XCTAssertNotEqual(next.revision, old.revision)
        await receiptReject { _ = try await store.commitCareReminderReceipts(replacement, replacing: old, authority: authority) }
        let after = try await store.readCareReminderReceipts(context: fresh, authority: authority)
        XCTAssertEqual(after?.revision, next.revision)
        XCTAssertTrue(try XCTUnwrap(after).receipts.entries.isEmpty)
    }

    @MainActor
    func testReminderStoreRefreshResetAndForgedSyncAreAtomic() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let (authority, lease) = try overviewBinding()
        var token = try await store.beginCareReminderReceipts(context: lease, authority: authority)
        var ledger = token.receipts
        _ = try ledger.prepare(receiptCandidate(), now: receiptNow)
        token = try await store.commitCareReminderReceipts(ledger, replacing: token, authority: authority)
        _ = try await store.beginCareOverviewRead(locale: "en", context: lease, authority: authority)
        let generation = try overviewWrapper(url)["canonicalGeneration"] as? String
        for full in [false, true] {
            try receiptEdit(url) { disk in
                for kind in 0..<3 {
                    let row = SyncedEntityRecord(ownerId: syncOwner,
                        entityType: kind == 2 ? "local_other" : "local_care_reminder_receipts",
                        entityId: kind == 0 ? otherSyncOwner : syncOwner, updatedAt: Date(), payloadJSON: "{}")
                    if kind == 1 { row.compositeKey += ":wrong" }
                    disk.insert(row)
                }
            }
            try await overviewCanonical(store, authority: authority, lease: lease, ids: [], fullRefresh: full)
            let read = try await store.readCareReminderReceipts(context: lease, authority: authority)
            XCTAssertEqual(read?.revision, token.revision)
            XCTAssertEqual(read?.receipts, ledger)
        }
        XCTAssertNotEqual(try overviewWrapper(url)["canonicalGeneration"] as? String, generation)
        let rows = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "local_care_reminder_receipts")
        XCTAssertEqual(rows.map(\.id), [syncOwner])
        let before = try overviewDiskState(url)
        let forged = SyncItemDTO(entityType: "local_care_reminder_receipts", id: syncOwner,
            updatedAt: Date(), payloadJSON: "{}")
        let ordinary = SyncItemDTO(entityType: "plants", id: otherSyncOwner, updatedAt: Date(), payloadJSON: "{}")
        await receiptReject { try await store.applySyncedItems([ordinary, forged], ownerId: syncOwner) }
        await receiptReject {
            try await store.publishSyncWindow(items: [ordinary, forged], ownerId: syncOwner, watermark: Date(),
                fullRefresh: true, context: lease, authority: authority)
        }
        XCTAssertEqual(try overviewDiskState(url), before)
        try await store.resetSyncCachePreservingOutbox(ownerId: syncOwner)
        let read = try await store.readCareReminderReceipts(context: lease, authority: authority)
        XCTAssertEqual(read?.revision, token.revision)
        XCTAssertEqual(read?.receipts, ledger)
        let overview = try await store.readCareOverviewPresentation(context: lease, authority: authority)
        XCTAssertNil(overview.canonicalGeneration)
        let plants = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
        let cursor = try await store.currentWatermarkRaw(ownerId: syncOwner)
        XCTAssertTrue(plants.isEmpty)
        XCTAssertNil(cursor)
        for (index, owner) in [syncOwner, otherSyncOwner].enumerated() {
            let queue = try await store.pendingOutboxEntries(for: owner)
            XCTAssertEqual(queue, [outbox[index]])
        }
    }
}

extension CollectionWireTests {
    @MainActor
    func testReminderStoreCorruptionCollisionRetentionAndOwnerOnlyPurge() async throws {
        for mutation in 0..<9 {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let (authority, lease) = try overviewBinding()
            let store = LocalStore(modelContainer: try diskContainer(url))
            let token = try await store.beginCareReminderReceipts(context: lease, authority: authority)
            try receiptEdit(url) { disk in
                let row = try XCTUnwrap(disk.fetch(FetchDescriptor<SyncedEntityRecord>()).first)
                var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(row.payloadJSON.utf8)) as? [String: Any])
                switch mutation {
                case 0: row.payloadJSON = "corrupt"; return
                case 1: wire["version"] = 2
                case 2: wire.removeValue(forKey: "revision")
                case 3:
                    var receipts = wire["receipts"] as! [String: Any]
                    receipts["ownerId"] = otherSyncOwner.uuidString
                    wire["receipts"] = receipts
                case 4:
                    var receipts = wire["receipts"] as! [String: Any]
                    receipts["version"] = 2
                    wire["receipts"] = receipts
                case 5: row.deletedAt = receiptNow
                case 6: row.ownerId = otherSyncOwner
                case 7: row.entityId = otherSyncOwner
                default: row.entityType = "plants"
                }
                row.payloadJSON = String(decoding: try JSONSerialization.data(withJSONObject: wire), as: UTF8.self)
            }
            let before = try overviewDiskState(url)
            await receiptReject { _ = try await store.beginCareReminderReceipts(context: lease, authority: authority) }
            await receiptReject { _ = try await store.readCareReminderReceipts(context: lease, authority: authority) }
            await receiptReject { _ = try await store.commitCareReminderReceipts(token.receipts, replacing: token, authority: authority) }
            XCTAssertEqual(try overviewDiskState(url), before)
            if mutation < 6 {
                try await overviewCanonical(store, authority: authority, lease: lease, ids: [], fullRefresh: true)
                try await store.resetSyncCachePreservingOutbox(ownerId: syncOwner)
                await receiptReject { _ = try await store.beginCareReminderReceipts(context: lease, authority: authority) }
                let retained = try overviewDiskState(url).filter { $0.contains("local_care_reminder_receipts") }
                XCTAssertEqual(retained, before)
            }
        }
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let (authority, lease) = try overviewBinding()
        _ = try await store.beginCareReminderReceipts(context: lease, authority: authority)
        let b = SyncSessionAuthority()
        b.bind(try profileSession(ownerId: otherSyncOwner))
        let leaseB = try b.capture(ownerId: otherSyncOwner)
        let tokenB = try await store.beginCareReminderReceipts(context: leaseB, authority: b)
        try receiptEdit(url) { disk in
            let own = try XCTUnwrap(disk.fetch(FetchDescriptor<SyncedEntityRecord>()).first {
                $0.ownerId == syncOwner && $0.entityType == "local_care_reminder_receipts"
            })
            own.entityType = "broken" // Own reserved key still belongs to erase-only cleanup.
            own.payloadJSON = "corrupt"
            disk.insert(SyncedEntityRecord(ownerId: syncOwner, entityType: "local_care_reminder_receipts",
                entityId: serverPlantId, updatedAt: Date(), payloadJSON: "malformed"))
        }
        let before = try overviewDiskState(url).filter {
            !$0.hasPrefix(syncOwner.uuidString.lowercased() + ":local_care_reminder_receipts:")
        }
        try await store.purgeCareReminderReceiptMetadata(ownerId: syncOwner)
        XCTAssertEqual(try overviewDiskState(url), before)
        let a = try await store.readCareReminderReceipts(context: lease, authority: authority)
        let readB = try await store.readCareReminderReceipts(context: leaseB, authority: b)
        XCTAssertNil(a)
        XCTAssertEqual(readB?.revision, tokenB.revision)
        for (index, owner) in [syncOwner, otherSyncOwner].enumerated() {
            let queue = try await store.pendingOutboxEntries(for: owner)
            XCTAssertEqual(queue, [outbox[index]])
        }
    }

    @MainActor
    func testReminderStoreFailedSavesDiscardEntryAndNonce() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (authority, lease) = try overviewBinding()
        let store = LocalStore(modelContainer: try diskContainer(url))
        try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
        let readOnly = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
        let beforeBegin = try overviewDiskState(url)
        await receiptReject { _ = try await readOnly.beginCareReminderReceipts(context: lease, authority: authority) }
        let absent = try await readOnly.readCareReminderReceipts(context: lease, authority: authority)
        XCTAssertNil(absent)
        XCTAssertEqual(try overviewDiskState(url), beforeBegin)
        let token = try await store.beginCareReminderReceipts(context: lease, authority: authority)
        var ledger = token.receipts
        _ = try ledger.prepare(receiptCandidate(), now: receiptNow)
        let before = try overviewDiskState(url)
        await receiptReject { _ = try await readOnly.commitCareReminderReceipts(ledger, replacing: token, authority: authority) }
        let unchanged = try await readOnly.readCareReminderReceipts(context: lease, authority: authority)
        XCTAssertEqual(unchanged?.revision, token.revision)
        XCTAssertTrue(try XCTUnwrap(unchanged).receipts.entries.isEmpty)
        await receiptReject { try await readOnly.purgeCareReminderReceiptMetadata(ownerId: syncOwner) }
        XCTAssertEqual(try overviewDiskState(url), before)
        let saved = try await store.commitCareReminderReceipts(ledger, replacing: token, authority: authority)
        XCTAssertEqual(saved.receipts, ledger)
        XCTAssertNotEqual(saved.revision, token.revision)
    }

    @MainActor
    func testReminderStoreForgedCodecCannotBypassDurableTransitions() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (authority, lease) = try overviewBinding()
        let store = LocalStore(modelContainer: try diskContainer(url))
        var token = try await store.beginCareReminderReceipts(context: lease, authority: authority)
        let candidate = try receiptCandidate()
        var ledger = token.receipts
        _ = try ledger.prepare(candidate, now: receiptNow)
        let prepared = ledger
        let newArmed = try forgedReceipt(prepared) { $0["phase"] = "armed" }
        await receiptReject { _ = try await store.commitCareReminderReceipts(newArmed, replacing: token, authority: authority) }
        token = try await store.commitCareReminderReceipts(prepared, replacing: token, authority: authority)
        // A caller-modified expected copy must not become the baseline for validation.
        let fabricated = CareReminderReceiptSnapshot(lease: lease, revision: token.revision,
            receipts: CareReminderReceipts(ownerId: syncOwner))
        await receiptReject {
            _ = try await store.commitCareReminderReceipts(fabricated.receipts, replacing: fabricated, authority: authority)
        }
        let attempt = try XCTUnwrap(prepared.entries[candidate.id]).attemptId
        _ = try ledger.acknowledge(id: candidate.id, attemptId: attempt, now: receiptNow)
        token = try await store.commitCareReminderReceipts(ledger, replacing: token, authority: authority)
        let armed = ledger
        for mutation in 0..<4 {
            let forged = try forgedReceipt(armed) { entry in
                switch mutation {
                case 0: entry["phase"] = "prepared"
                case 1: entry["attemptId"] = UUID().uuidString
                case 2: entry["sourceDueYMD"] = "2026-11-28" // First-aid identity stays the same.
                default:
                    entry["phase"] = "prepared"
                    entry["attemptId"] = UUID().uuidString
                    entry["currentFireDate"] = candidate.absoluteFireDate.addingTimeInterval(3600).timeIntervalSinceReferenceDate
                    entry["cancellation"] = ["attemptId": attempt.uuidString,
                        "fireDate": candidate.absoluteFireDate.timeIntervalSinceReferenceDate,
                        "confirmedAt": receiptNow.timeIntervalSinceReferenceDate]
                }
            }
            await receiptReject { _ = try await store.commitCareReminderReceipts(forged, replacing: token, authority: authority) }
        }
        _ = try ledger.cancel(id: candidate.id, attemptId: attempt,
            proof: .removedAndReadBackAbsent(confirmedAt: receiptNow), now: receiptNow)
        token = try await store.commitCareReminderReceipts(ledger, replacing: token, authority: authority)
        _ = try ledger.prepare(receiptCandidate(due: "2026-11-28", hour: 10), now: receiptNow)
        let wrongProof = try forgedReceipt(ledger) { entry in
            var proof = entry["cancellation"] as! [String: Any]
            proof["confirmedAt"] = receiptNow.addingTimeInterval(1).timeIntervalSinceReferenceDate
            entry["cancellation"] = proof
        }
        await receiptReject { _ = try await store.commitCareReminderReceipts(wrongProof, replacing: token, authority: authority) }
        token = try await store.commitCareReminderReceipts(ledger, replacing: token, authority: authority)
        try ledger.observe(id: candidate.id, now: receiptNow, unknown: true)
        token = try await store.commitCareReminderReceipts(ledger, replacing: token, authority: authority)
        let uncertainRearm = try forgedReceipt(ledger) { $0["phase"] = "prepared" }
        await receiptReject { _ = try await store.commitCareReminderReceipts(uncertainRearm, replacing: token, authority: authority) }
        try ledger.observe(id: candidate.id, now: receiptNow, delivered: true)
        token = try await store.commitCareReminderReceipts(ledger, replacing: token, authority: authority)
        let before = try overviewDiskState(url)
        for mutation in 0..<7 {
            let forged = try forgedReceipt(ledger) { entry in
                switch mutation {
                case 0: entry["phase"] = "prepared"
                case 1: entry["phase"] = "armed"
                case 2: entry["phase"] = "uncertain"
                case 3: entry["attemptId"] = UUID().uuidString
                case 4: entry["sourceDueYMD"] = "2026-11-29"
                case 5: entry["originalFireDate"] = receiptNow.timeIntervalSinceReferenceDate
                default: entry["currentFireDate"] = receiptNow.timeIntervalSinceReferenceDate
                }
            }
            await receiptReject { _ = try await store.commitCareReminderReceipts(forged, replacing: token, authority: authority) }
        }
        XCTAssertEqual(try overviewDiskState(url), before)
    }
}

@MainActor
private final class FakeCareReminderNotifications: CareReminderNotifications {
    enum Fault: Error { case injected }
    var now = SQLTimestamp.date(from: "2026-11-20T00:00:00Z")!
    var authorizationValue = CareReminderPlan.Authorization.authorized
    var pending: [CareReminderNotificationInventory.Item] = []
    var delivered: [CareReminderNotificationInventory.Item] = []
    var otherPendingCount = 1 // Trial/other namespace is never passed to care removals.
    var adds: [CareReminderNotificationProposal] = []
    var removed: [String] = []
    var permissionRequests = 0
    var inventoryReads = 0
    var onPermission: (() async -> Void)?
    var failInventory = false
    var afterRemove: (() -> Void)?
    var onAuthorization: (() -> Void)?
    var onAdd: ((CareReminderNotificationProposal) async throws -> Void)?

    func authorization() async throws -> CareReminderPlan.Authorization {
        onAuthorization?()
        return authorizationValue
    }
    func requestAuthorization() async throws {
        permissionRequests += 1
        await onPermission?()
    }
    func inventory() async throws -> CareReminderNotificationInventory {
        inventoryReads += 1
        if failInventory { throw Fault.injected }
        return .init(pending: pending, delivered: delivered, otherPendingCount: otherPendingCount)
    }
    func add(_ proposal: CareReminderNotificationProposal, now: Date) async throws {
        adds.append(proposal)
        pending.append(.init(rawIdentifier: CareReminderNotificationFactory.prefix + proposal.candidate.id,
            route: .init(candidate: proposal.candidate, attemptId: proposal.attemptId), deliveredAt: nil))
        try await onAdd?(proposal)
    }
    func removePending(_ identifiers: [String]) async throws {
        removed += identifiers
        pending.removeAll { identifiers.contains($0.rawIdentifier) }
        afterRemove?()
    }
    func removeDelivered(_ identifiers: [String]) async throws {
        removed += identifiers
        delivered.removeAll { identifiers.contains($0.rawIdentifier) }
    }
}

extension CollectionWireTests {
    @MainActor
    private func reminderFixture() async throws
        -> (URL, LocalStore, SyncSessionAuthority, SyncSessionLease, LocalCareOverviewPresentation) {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        return (url, store, api.syncAuthority, lease, local)
    }

    private func passState(_ local: LocalCareOverviewPresentation, count: Int = 1,
                           hour: Int = 9, due: String = "2026-11-25") throws -> CareOverviewViewState {
        try reminderState(local, rows: [overviewRow(serverPlantId, dated: true,
            controls: (1...count).map { reminderControl($0, due: due) })], hour: hour)
    }

    @MainActor
    private func reminderPass(_ store: LocalStore, _ authority: SyncSessionAuthority,
                              _ lease: SyncSessionLease, _ state: CareOverviewViewState?,
                              _ fake: FakeCareReminderNotifications, optedIn: Bool = true,
                              allowNew: Bool = true, current: @escaping () -> Bool = { true })
        async -> CareReminderScheduler.Result {
        await CareReminderScheduler.reconcile(.init(lease: lease, store: store, authority: authority,
            isCurrent: current, state: state, optedIn: optedIn, allowNewRequests: allowNew,
            locale: "pl", timeZone: TimeZone(secondsFromGMT: 0)!, clock: { fake.now }),
            notifications: fake)
    }

    @MainActor
    func testReminderPassPersistsPrepareBeforeAddAndNoopPreservesOtherNamespace() async throws {
        let (url, store, authority, lease, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let state = try passState(local)
        let fake = FakeCareReminderNotifications()
        let foreign = try receiptCandidate(owner: otherSyncOwner)
        fake.pending = [.init(rawIdentifier: CareReminderNotificationFactory.prefix + foreign.id,
            route: .init(candidate: foreign, attemptId: UUID()), deliveredAt: nil)]
        fake.onAdd = { proposal in
            let disk = LocalStore(modelContainer: try self.diskContainer(url))
            let read = try await disk.readCareReminderReceipts(context: lease, authority: authority)
            let entry = try XCTUnwrap(read?.receipts.entries[proposal.candidate.id])
            XCTAssertEqual(entry.phase, .prepared)
            XCTAssertEqual(entry.attemptId, proposal.attemptId)
            XCTAssertFalse(fake.pending.contains { $0.route?.candidate.ownerId == self.otherSyncOwner })
        }
        let first = await reminderPass(store, authority, lease, state, fake)
        XCTAssertFalse(first.failed)
        XCTAssertEqual(first.confirmedPendingCount, 1)
        let read = try await store.readCareReminderReceipts(context: lease, authority: authority)
        XCTAssertEqual(read?.receipts.entries.values.first?.phase, .armed)
        let second = await reminderPass(store, authority, lease, state, fake)
        XCTAssertEqual(second, first)
        XCTAssertEqual(fake.adds.count, 1)
        XCTAssertEqual(fake.otherPendingCount, 1)
        XCTAssertTrue(fake.removed.allSatisfy { $0.hasPrefix(CareReminderNotificationFactory.prefix) })
        XCTAssertEqual(fake.permissionRequests, 0)
    }

    @MainActor
    func testReminderPassColdRecoveryAndConsumedOrUnknownEvidenceNeverReplay() async throws {
        // Exact accepted-add/lost-ACK recovery; elapsed, delivered, missing and unknown OS history.
        for mode in 0...4 {
            let (url, store, authority, lease, local) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let state = try passState(local)
            let candidate = try XCTUnwrap(reminderPlan(state).candidates.first)
            let fake = FakeCareReminderNotifications()
            if mode == 4 {
                fake.pending = [.init(rawIdentifier: CareReminderNotificationFactory.prefix + candidate.id,
                    route: .init(candidate: candidate, attemptId: UUID()), deliveredAt: nil)]
            } else {
                fake.onAdd = { _ in throw FakeCareReminderNotifications.Fault.injected }
                let lost = await reminderPass(store, authority, lease, state, fake)
                XCTAssertTrue(lost.failed)
                let prepared = try await store.readCareReminderReceipts(context: lease, authority: authority)
                XCTAssertEqual(prepared?.receipts.entries[candidate.id]?.phase, .prepared)
            }
            let attempt = fake.pending.first?.route?.attemptId
            fake.onAdd = nil
            if mode == 1 { fake.now = candidate.absoluteFireDate }
            if mode == 2 {
                let item = try XCTUnwrap(fake.pending.first)
                fake.delivered = [.init(rawIdentifier: item.rawIdentifier, route: item.route, deliveredAt: fake.now)]
                fake.pending = []
            }
            if mode == 3 { fake.pending = [] } // Dismissal/absence is not fresh-add authority.
            let cold = LocalStore(modelContainer: try diskContainer(url))
            let desired = try (mode == 0 ? state : passState(local, hour: 11, due: "2026-11-26"))
            let recovered = await reminderPass(cold, authority, lease, desired, fake)
            XCTAssertFalse(recovered.failed)
            XCTAssertEqual(fake.adds.count, mode == 4 ? 0 : 1)
            let read = try await cold.readCareReminderReceipts(context: lease, authority: authority)
            let entry = try XCTUnwrap(read?.receipts.entries[candidate.id])
            XCTAssertEqual(entry.attemptId, attempt)
            XCTAssertEqual(entry.phase, mode == 0 ? .armed : mode <= 2 ? .spent : .uncertain)
            XCTAssertEqual(recovered.confirmedPendingCount, mode == 0 ? 1 : 0)
        }
    }

    @MainActor
    func testReminderPassPrefireReadbackProofAndFailureBarriers() async throws {
        for mode in 0...3 {
            let (url, store, authority, lease, local) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let fake = FakeCareReminderNotifications()
            let initial = await reminderPass(store, authority, lease, try passState(local), fake)
            XCTAssertFalse(initial.failed)
            let before = try await store.readCareReminderReceipts(context: lease, authority: authority)
            let old = try XCTUnwrap(before?.receipts.entries.values.first)
            if mode == 1 { fake.pending = [] }
            if mode == 2 { fake.afterRemove = { fake.failInventory = true } }
            if mode == 3 { fake.afterRemove = { fake.now = old.currentFireDate } }
            let replacement = await reminderPass(store, authority, lease, try passState(local, hour: 11), fake)
            XCTAssertEqual(replacement.failed, mode == 2)
            let after = try await store.readCareReminderReceipts(context: lease, authority: authority)
            let entry = try XCTUnwrap(after?.receipts.entries[old.id])
            XCTAssertEqual(entry.originalFireDate, old.originalFireDate)
            XCTAssertEqual(fake.adds.count, mode == 0 ? 2 : 1)
            if mode == 0 {
                XCTAssertEqual(entry.phase, .armed)
                XCTAssertNotEqual(entry.attemptId, old.attemptId)
                XCTAssertEqual(entry.currentFireDate, try receiptCandidate(hour: 11).absoluteFireDate)
                XCTAssertEqual(entry.cancellation?.fireDate, old.currentFireDate)
                var ledger = try XCTUnwrap(after).receipts
                XCTAssertFalse(try ledger.acknowledge(id: old.id, attemptId: old.attemptId, now: fake.now))
                XCTAssertFalse(try ledger.cancel(id: old.id, attemptId: old.attemptId,
                    proof: .removedAndReadBackAbsent(confirmedAt: fake.now), now: fake.now))
                XCTAssertEqual(ledger, after?.receipts)
            } else {
                XCTAssertEqual(entry.phase, mode == 3 ? .spent : .uncertain)
            }
        }
    }

    @MainActor
    func testReminderPassFiltersSpentBeforeCapacityAndAccountsOtherRequests() async throws {
        for other in [0, 1, 31, 32, 40] {
            let (url, store, authority, lease, local) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let state = try passState(local, count: 74)
            let candidates = reminderPlan(state).candidates
            XCTAssertEqual(candidates.count, 74)
            let token = try await store.beginCareReminderReceipts(context: lease, authority: authority)
            var ledger = token.receipts
            for c in candidates.prefix(40) {
                _ = try ledger.prepare(c, now: receiptNow)
                try ledger.observe(id: c.id, now: receiptNow, delivered: true)
            }
            _ = try await store.commitCareReminderReceipts(ledger, replacing: token, authority: authority)
            let fake = FakeCareReminderNotifications()
            fake.otherPendingCount = other
            let result = await reminderPass(store, authority, lease, state, fake)
            let count = max(0, 32 - other)
            XCTAssertFalse(result.failed)
            XCTAssertEqual(result.confirmedPendingCount, count)
            XCTAssertEqual(result.omittedCount, 34 - count)
            XCTAssertEqual(fake.adds.map { $0.candidate.id }, Array(candidates.dropFirst(40).prefix(count)).map { $0.id })
            XCTAssertEqual(fake.otherPendingCount, other)
        }
    }

    @MainActor
    func testReminderPassPermissionOptoutHoldAndUnknownPresentation() async throws {
        for mode in 0...3 {
            let (url, store, authority, lease, local) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let fake = FakeCareReminderNotifications()
            let state = try passState(local)
            let initial = await reminderPass(store, authority, lease, state, fake)
            XCTAssertFalse(initial.failed)
            let unknown = await reminderPass(store, authority, lease, nil, fake)
            XCTAssertTrue(unknown.deferred)
            XCTAssertEqual(fake.pending.count, 1)
            if mode == 1 { fake.authorizationValue = .denied }
            if mode == 2 { fake.authorizationValue = .notDetermined }
            let result = await reminderPass(store, authority, lease, try passState(local, count: 2), fake,
                optedIn: mode != 0, allowNew: false)
            XCTAssertFalse(result.failed)
            XCTAssertEqual(fake.adds.count, 1)
            XCTAssertEqual(result.confirmedPendingCount, mode == 3 ? 1 : 0)
            XCTAssertEqual(fake.permissionRequests, 0)
            XCTAssertEqual(fake.otherPendingCount, 1)
        }
    }

    @MainActor
    func testReminderPassScopeStorageAndConflictingInventoryFailClosed() async throws {
        for mode in 0...8 {
            let (url, store, authority, lease, local) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let fake = FakeCareReminderNotifications()
            let state = try passState(local)
            var target = store
            if mode == 1 {
                _ = try await store.beginCareReminderReceipts(context: lease, authority: authority)
                target = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
            }
            if mode == 2 { fake.onAuthorization = { authority.bind(nil) } }
            if mode == 3 {
                let token = try await store.beginCareReminderReceipts(context: lease, authority: authority)
                let c = try XCTUnwrap(reminderPlan(state).candidates.first)
                var ledger = token.receipts
                _ = try ledger.prepare(c, now: receiptNow)
                let entry = try XCTUnwrap(ledger.entries[c.id])
                _ = try await store.commitCareReminderReceipts(ledger, replacing: token, authority: authority)
                let item = CareReminderNotificationInventory.Item(
                    rawIdentifier: CareReminderNotificationFactory.prefix + c.id,
                    route: .init(candidate: c, attemptId: entry.attemptId), deliveredAt: nil)
                fake.pending = [item, item] // No Dictionary(uniqueKeysWithValues:) trap or replay.
            }
            if mode == 4 {
                fake.pending = [.init(rawIdentifier: CareReminderNotificationFactory.prefix + "unknown",
                    route: nil, deliveredAt: nil)]
            }
            if mode >= 5 {
                var token = try await store.beginCareReminderReceipts(context: lease, authority: authority)
                let c = try XCTUnwrap(reminderPlan(state).candidates.first)
                var ledger = token.receipts
                _ = try ledger.prepare(c, now: fake.now)
                token = try await store.commitCareReminderReceipts(ledger, replacing: token, authority: authority)
                let entry = try XCTUnwrap(ledger.entries[c.id])
                XCTAssertTrue(try ledger.cancel(id: c.id, attemptId: entry.attemptId,
                    proof: .removedAndReadBackAbsent(confirmedAt: fake.now), now: fake.now))
                _ = try await store.commitCareReminderReceipts(ledger, replacing: token, authority: authority)
                target = LocalStore(modelContainer: try diskContainer(url))
                let cancelled = try await target.readCareReminderReceipts(context: lease, authority: authority)
                XCTAssertEqual(cancelled?.receipts.entries[c.id]?.phase, .cancelledBeforeFire)
                let raw = CareReminderNotificationFactory.prefix + c.id
                let route = CareReminderNotificationRoute(candidate: c,
                    attemptId: mode == 5 ? UUID() : entry.attemptId)
                if mode == 5 || mode == 7 {
                    // Both a different attempt and a reappearing cancelled attempt contradict absence.
                    fake.pending = [.init(rawIdentifier: raw, route: route, deliveredAt: nil)]
                } else {
                    // Unverifiable delivered evidence blocks; verified delivery consumes the occurrence.
                    fake.delivered = [.init(rawIdentifier: raw, route: mode == 6 ? nil : route,
                        deliveredAt: fake.now)]
                }
            }
            let result = await reminderPass(target, authority, lease, state, fake, current: { mode != 0 })
            XCTAssertEqual(result.failed, mode != 3 && mode < 5)
            XCTAssertTrue(fake.adds.isEmpty)
            XCTAssertEqual(fake.permissionRequests, 0)
            if mode == 3 || mode >= 5 {
                let read = try await store.readCareReminderReceipts(context: lease, authority: authority)
                let expected: CareReminderReceipts.Phase = mode == 8 ? .spent : .uncertain
                XCTAssertEqual(read?.receipts.entries.values.first?.phase, expected)
                XCTAssertEqual(result.unconfirmedBlockers, mode == 8 ? 0 : 1)
                if mode >= 5 {
                    XCTAssertTrue(fake.pending.isEmpty)
                    XCTAssertTrue(fake.delivered.isEmpty)
                    let cold = LocalStore(modelContainer: try diskContainer(url))
                    let again = await reminderPass(cold, authority, lease, state, fake)
                    XCTAssertFalse(again.failed)
                    XCTAssertTrue(fake.adds.isEmpty)
                    let persisted = try await cold.readCareReminderReceipts(context: lease, authority: authority)
                    XCTAssertEqual(persisted?.receipts.entries.values.first?.phase, expected)
                    XCTAssertEqual(again.unconfirmedBlockers, mode == 8 ? 0 : 1)
                }
            }
        }
    }
}


extension CollectionWireTests {
    @MainActor
    private func workerInput(
        _ store: LocalStore, _ authority: SyncSessionAuthority, _ lease: SyncSessionLease,
        _ state: CareOverviewViewState?, _ fake: FakeCareReminderNotifications,
        optedIn: Bool = true, allowNew: Bool = true, current: @escaping () -> Bool = { true }
    ) -> CareReminderScheduler.Input {
        .init(lease: lease, store: store, authority: authority, isCurrent: current, state: state,
            optedIn: optedIn, allowNewRequests: allowNew, locale: "pl",
            timeZone: TimeZone(secondsFromGMT: 0)!, clock: { fake.now })
    }

    @MainActor
    func testReminderWorkerHeldAddThenOptoutOrLogoutAwaitsCleanup() async throws {
        for logout in [false, true] {
            let (url, store, authority, lease, local) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let fake = FakeCareReminderNotifications()
            let gate = TodayReadBarrier()
            fake.onAdd = { _ in await gate.wait() }
            let worker = CareReminderScheduler(notifications: fake)
            worker.hold()
            await worker.waitUntilIdle()
            XCTAssertEqual(fake.inventoryReads, 0) // Unknown startup is not logout.
            let state = try passState(local)
            worker.update(workerInput(store, authority, lease, state, fake))
            await gate.waitUntilEntered()
            if logout {
                authority.bind(nil)
                worker.cancelAll()
            } else {
                worker.update(workerInput(store, authority, lease, state, fake, optedIn: false))
            }
            XCTAssertTrue(fake.removed.isEmpty) // Old add has not completed.
            XCTAssertNil(worker.result)
            gate.open()
            await worker.waitUntilIdle()
            XCTAssertTrue(fake.pending.isEmpty)
            XCTAssertTrue(fake.delivered.isEmpty)
            XCTAssertEqual(fake.adds.count, 1)
            XCTAssertEqual(fake.otherPendingCount, 1)
            XCTAssertFalse(worker.requestingPermission)
            if logout { XCTAssertNil(worker.result) }
            else { XCTAssertEqual(worker.result?.failed, false) }
        }
    }

    @MainActor
    func testReminderWorkerABACleanupLatchAndSameOwnerRefreshLostACK() async throws {
        for aba in [false, true] {
            let (url, store, authority, lease, local) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let fake = FakeCareReminderNotifications()
            let gate = TodayReadBarrier()
            fake.onAdd = { _ in
                await gate.wait()
                throw FakeCareReminderNotifications.Fault.injected
            }
            let state = try passState(local)
            let worker = CareReminderScheduler(notifications: fake)
            worker.update(workerInput(store, authority, lease, state, fake))
            await gate.waitUntilEntered()
            if aba {
                worker.cancelAll()
                authority.bind(try profileSession(ownerId: otherSyncOwner))
                let b = try authority.capture(ownerId: otherSyncOwner)
                worker.update(workerInput(store, authority, b, nil, fake))
            }
            authority.bind(try profileSession())
            let fresh = try authority.capture(ownerId: syncOwner)
            worker.update(workerInput(store, authority, fresh, aba ? nil : state, fake))
            gate.open()
            await worker.waitUntilIdle()
            XCTAssertEqual(fake.adds.count, 1)
            XCTAssertEqual(fake.pending.count, aba ? 0 : 1)
            XCTAssertEqual(worker.result?.failed, false)
            XCTAssertEqual(worker.result?.deferred, aba)
            XCTAssertFalse(worker.requestingPermission)
            let read = try await store.readCareReminderReceipts(context: fresh, authority: authority)
            XCTAssertEqual(read?.receipts.entries.values.first?.phase, aba ? .prepared : .armed)
            if aba {
                authority.bind(try profileSession(ownerId: otherSyncOwner))
                let b = try authority.capture(ownerId: otherSyncOwner)
                let foreign = try await store.readCareReminderReceipts(context: b, authority: authority)
                XCTAssertNil(foreign) // Coalesced B was never allowed to open a receipt ledger.
            }
        }
    }

    @MainActor
    func testReminderWorkerHoldRecoversPreparedAndLocalCancellationKeepsOthers() async throws {
        let (url, store, authority, lease, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fake = FakeCareReminderNotifications()
        let gate = TodayReadBarrier()
        fake.onAdd = { _ in await gate.wait() }
        let worker = CareReminderScheduler(notifications: fake)
        let two = try passState(local, count: 2)
        worker.update(workerInput(store, authority, lease, two, fake))
        await gate.waitUntilEntered()
        worker.hold()
        gate.open()
        await worker.waitUntilIdle()
        XCTAssertEqual(fake.pending.count, 1)
        XCTAssertEqual(fake.adds.count, 1)
        XCTAssertEqual(worker.result?.confirmedPendingCount, 1)
        fake.onAdd = nil
        worker.update(workerInput(store, authority, lease, two, fake))
        await worker.waitUntilIdle()
        XCTAssertEqual(fake.pending.count, 2)
        worker.hold()
        await worker.waitUntilIdle()
        XCTAssertEqual(fake.adds.count, 2)
        let one = try passState(local)
        worker.update(workerInput(store, authority, lease, one, fake, allowNew: false))
        await worker.waitUntilIdle()
        XCTAssertEqual(fake.pending.map { $0.route?.candidate.id }, reminderPlan(one).candidates.map { Optional($0.id) })
        XCTAssertEqual(fake.adds.count, 2)
        XCTAssertEqual(worker.result?.confirmedPendingCount, 1)

        // Unknown readback remains visible; only an explicit retry resumes cleanup.
        fake.afterRemove = { fake.failInventory = true }
        worker.cancelAll()
        await worker.waitUntilIdle()
        XCTAssertEqual(worker.result?.failed, true)
        fake.failInventory = false
        fake.afterRemove = nil
        worker.retry()
        await worker.waitUntilIdle()
        XCTAssertTrue(fake.pending.isEmpty)
        XCTAssertNil(worker.result)
        XCTAssertEqual(fake.adds.count, 2)
        XCTAssertEqual(fake.otherPendingCount, 1)
    }

    @MainActor
    func testReminderWorkerNoScheduleDoesNotAuthorizeLaterAutomaticPrompt() async throws {
        let (url, store, authority, lease, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fake = FakeCareReminderNotifications()
        fake.authorizationValue = .notDetermined
        let worker = CareReminderScheduler(notifications: fake)
        worker.update(workerInput(store, authority, lease, nil, fake))
        worker.requestPermission()
        await worker.waitUntilIdle()
        let state = try passState(local)
        worker.update(workerInput(store, authority, lease, state, fake))
        await worker.waitUntilIdle()
        XCTAssertEqual(fake.permissionRequests, 0)
        XCTAssertTrue(fake.adds.isEmpty)
        fake.onPermission = { fake.authorizationValue = .authorized }
        worker.requestPermission()
        await worker.waitUntilIdle()
        XCTAssertEqual(fake.permissionRequests, 1)
        XCTAssertEqual(fake.adds.count, 1)
        XCTAssertEqual(worker.authorization, .authorized)
        XCTAssertFalse(worker.requestingPermission)
        worker.requestPermission()
        await worker.waitUntilIdle()
        XCTAssertEqual(fake.permissionRequests, 1)
        XCTAssertEqual(fake.adds.count, 1)
    }

    @MainActor
    func testReminderWorkerPermissionLateCallbacksCannotRearmOrRestoreFlags() async throws {
        for mode in 0...3 {
            let (url, store, authority, lease, local) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let fake = FakeCareReminderNotifications()
            fake.authorizationValue = .notDetermined
            let gate = TodayReadBarrier()
            fake.onPermission = {
                await gate.wait()
                fake.authorizationValue = .authorized
            }
            var current = true
            let worker = CareReminderScheduler(notifications: fake)
            worker.update(workerInput(store, authority, lease, try passState(local), fake, current: { current }))
            await worker.waitUntilIdle()
            worker.requestPermission()
            await gate.waitUntilEntered()
            XCTAssertTrue(worker.requestingPermission)
            switch mode {
            case 0:
                authority.bind(nil)
                worker.cancelAll()
            case 1:
                authority.bind(try profileSession(ownerId: otherSyncOwner))
                let b = try authority.capture(ownerId: otherSyncOwner)
                worker.update(workerInput(store, authority, b, nil, fake))
            case 2:
                let suppressed = try reminderState(local, rows: [])
                worker.update(workerInput(store, authority, lease, suppressed, fake, allowNew: false))
            default:
                current = false // Caller activation changes even without another worker request.
            }
            gate.open()
            await worker.waitUntilIdle()
            XCTAssertEqual(fake.permissionRequests, 1)
            XCTAssertTrue(fake.adds.isEmpty)
            XCTAssertTrue(fake.pending.isEmpty)
            XCTAssertFalse(worker.requestingPermission)
            if mode == 0 || mode == 3 {
                XCTAssertNil(worker.result)
                XCTAssertNil(worker.authorization)
            } else {
                XCTAssertEqual(worker.result?.failed, false)
            }
        }
    }

    @MainActor
    func testReminderWorkerMalformedCleanupCurrentIdentityAndHistoricalBlockers() async throws {
        let (url, store, authority, lease, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let state = try passState(local)
        let candidate = try XCTUnwrap(reminderPlan(state).candidates.first)
        let fake = FakeCareReminderNotifications()
        fake.pending = [
            .init(rawIdentifier: CareReminderNotificationFactory.prefix + candidate.id, route: nil, deliveredAt: nil),
            .init(rawIdentifier: CareReminderNotificationFactory.prefix + "malformed", route: nil, deliveredAt: nil)
        ]
        let worker = CareReminderScheduler(notifications: fake)
        worker.update(workerInput(store, authority, lease, state, fake, optedIn: false))
        await worker.waitUntilIdle()
        XCTAssertEqual(worker.result?.failed, true)
        XCTAssertTrue(fake.pending.isEmpty)
        XCTAssertTrue(fake.adds.isEmpty)
        let cold = LocalStore(modelContainer: try diskContainer(url))
        let again = await reminderPass(cold, authority, lease, state, fake)
        XCTAssertFalse(again.failed)
        XCTAssertEqual(again.unconfirmedBlockers, 1)
        XCTAssertTrue(fake.adds.isEmpty)
        fake.now = candidate.absoluteFireDate
        let afterFire = CareReminderPlan(expectedOwnerId: syncOwner, state: state, optedIn: true,
            authorization: .authorized, now: fake.now, timeZone: TimeZone(secondsFromGMT: 0)!, locale: "pl")
        XCTAssertTrue(afterFire.currentOccurrenceIDs.contains(candidate.id))
        XCTAssertTrue(afterFire.candidates.isEmpty)
        let past = await reminderPass(cold, authority, lease, state, fake)
        XCTAssertEqual(past.unconfirmedBlockers, 1)
        let removed = try reminderState(local, rows: [])
        let noTask = await reminderPass(cold, authority, lease, removed, fake)
        XCTAssertFalse(noTask.failed)
        XCTAssertEqual(noTask.unconfirmedBlockers, 0)
        let read = try await cold.readCareReminderReceipts(context: lease, authority: authority)
        XCTAssertEqual(read?.receipts.entries[candidate.id]?.phase, .uncertain)
        let skipped = reminderPlan(try passState(local, due: "2011-12-30"),
            now: "2011-12-01T00:00:00Z", zone: TimeZone(identifier: "Pacific/Apia")!)
        let skippedOccurrence = try XCTUnwrap(skipped.currentOccurrences.first {
            $0.id == candidate.id
        })
        XCTAssertEqual(skippedOccurrence.sourceDueYMD, "2011-12-30")
        XCTAssertTrue(skipped.currentOccurrenceIDs.contains(candidate.id))
        XCTAssertFalse(skipped.candidates.contains { $0.id == candidate.id })
    }
}

extension CollectionWireTests {
    func testReminderRawIdentityBlocksAreStrictMonotonicAndV1Compatible() throws {
        let firstAid = try receiptCandidate()
        let routine = try receiptCandidate(occurrence: .routine(ruleId: operationId))
        var ledger = CareReminderReceipts(ownerId: syncOwner)
        for candidate in [routine, firstAid] {
            try ledger.blockIdentifier(candidate.id)
            try ledger.blockIdentifier(candidate.id)
        }
        XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertEqual(try coldReceipts(ledger), ledger)
        for candidate in [firstAid, routine] {
            XCTAssertEqual(try ledger.prepare(candidate, now: receiptNow), .blocked)
        }
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        XCTAssertEqual(wire["blockedIdentifiers"] as? [String], [firstAid.id, routine.id].sorted())
        let foreign = try receiptCandidate(owner: otherSyncOwner).id
        let upperUUID = "care/\(syncOwner.uuidString.lowercased())/ABCDEFAB-1234-4000-8000-000000000001/first-aid/\(operationId.uuidString.lowercased())"
        for ids in [[firstAid.id, firstAid.id], [foreign], ["care/malformed"], [upperUUID],
                    [routine.id + "/extra"], [firstAid.id + "/2026-11-25"],
                    [routine.id.replacingOccurrences(of: "2026-11-25", with: "2026-02-30")]] {
            var corrupt = wire
            corrupt["blockedIdentifiers"] = ids
            XCTAssertThrowsError(try JSONDecoder().decode(CareReminderReceipts.self,
                from: JSONSerialization.data(withJSONObject: corrupt)))
        }
        XCTAssertThrowsError(try ledger.blockIdentifier(foreign))
        var dropped = wire
        dropped.removeValue(forKey: "blockedIdentifiers")
        let oldEmpty = try JSONDecoder().decode(CareReminderReceipts.self,
            from: JSONSerialization.data(withJSONObject: dropped))
        XCTAssertTrue(oldEmpty.blockedIdentifiers.isEmpty)
        XCTAssertThrowsError(try oldEmpty.validateReplacement(of: ledger))
        var oldLedger = CareReminderReceipts(ownerId: syncOwner)
        _ = try oldLedger.prepare(firstAid, now: receiptNow)
        var oldWire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldLedger)) as? [String: Any])
        oldWire.removeValue(forKey: "blockedIdentifiers")
        XCTAssertEqual(try JSONDecoder().decode(CareReminderReceipts.self,
            from: JSONSerialization.data(withJSONObject: oldWire)), oldLedger)
    }

    @MainActor
    func testReminderColdKnownOwnerCleansOnlyForeignRawBeforeUnknownDefer() async throws {
        let (url, store, authority, lease, _) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let own = try receiptCandidate()
        let foreign = try receiptCandidate(owner: otherSyncOwner)
        func item(_ candidate: CareReminderPlan.Candidate) -> CareReminderNotificationInventory.Item {
            .init(rawIdentifier: CareReminderNotificationFactory.prefix + candidate.id,
                route: .init(candidate: candidate, attemptId: UUID()), deliveredAt: nil)
        }
        let ownItem = item(own)
        let foreignItem = item(foreign)
        let trial = CareReminderNotificationInventory.Item(rawIdentifier: "narat.trial-reminder.v1.test",
            route: nil, deliveredAt: nil)
        let other = CareReminderNotificationInventory.Item(rawIdentifier: "other.request", route: nil, deliveredAt: nil)
        let opaque = CareReminderNotificationInventory.Item(
            rawIdentifier: CareReminderNotificationFactory.prefix + "opaque",
            route: foreignItem.route, deliveredAt: nil)
        let fake = FakeCareReminderNotifications()
        fake.pending = [foreignItem, ownItem, trial, other, opaque]
        fake.delivered = fake.pending
        let worker = CareReminderScheduler(notifications: fake)
        await worker.waitUntilIdle()
        XCTAssertEqual(fake.inventoryReads, 0)
        XCTAssertTrue(fake.removed.isEmpty)
        worker.update(workerInput(store, authority, lease, nil, fake))
        await worker.waitUntilIdle()
        XCTAssertEqual(worker.result?.failed, false)
        XCTAssertEqual(worker.result?.deferred, true)
        XCTAssertEqual(fake.pending, [ownItem, trial, other, opaque])
        XCTAssertEqual(fake.delivered, [ownItem, trial, other, opaque])
        XCTAssertEqual(fake.removed, [foreignItem.rawIdentifier, foreignItem.rawIdentifier])
        XCTAssertTrue(fake.adds.isEmpty)
        XCTAssertEqual(fake.permissionRequests, 0)
        authority.bind(try profileSession(ownerId: otherSyncOwner))
        let foreignLease = try authority.capture(ownerId: otherSyncOwner)
        let foreignLedger = try await store.readCareReminderReceipts(context: foreignLease, authority: authority)
        XCTAssertNil(foreignLedger)
    }

    @MainActor
    func testReminderSuppressedRawIdentitiesSurviveDiskRestartWithoutRearming() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (authority, lease) = try overviewBinding()
        let state: CareOverviewViewState
        let suppressed: CareOverviewViewState
        let removed: CareOverviewViewState
        let ids: Set<String>
        let fake = FakeCareReminderNotifications()
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            try await overviewCanonical(store, authority: authority, lease: lease, ids: [serverPlantId])
            var page = overviewPage([overviewRow(serverPlantId, dated: true, controls: [overviewControl()])])
            page["verified_access_until"] = NSNull()
            let overviewToken = try await store.beginCareOverviewRead(locale: "pl", context: lease, authority: authority)
            try await store.finishCareOverviewRead(overviewToken, snapshot: overviewSnapshot([page]), authority: authority)
            let local = try await store.readCareOverviewPresentation(context: lease, authority: authority)
            let rows = [reminderRow(serverPlantId, controls: [reminderControl(1)])]
            state = try reminderState(local, rows: rows)
            suppressed = try reminderState(local, rows: rows, mode: "profile.update")
            removed = try reminderState(local, rows: [])
            ids = reminderPlan(state).currentOccurrenceIDs
            XCTAssertEqual(ids.count, 2) // Routine and first-aid raw grammars.
            XCTAssertTrue(suppressed.profileHourPending)
            XCTAssertTrue(reminderPlan(suppressed).currentOccurrences.isEmpty)
            fake.pending = ids.sorted().map {
                .init(rawIdentifier: CareReminderNotificationFactory.prefix + $0, route: nil, deliveredAt: nil)
            }
            fake.delivered = fake.pending
            _ = try await store.beginCareReminderReceipts(context: lease, authority: authority)
            let readOnly = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
            let failed = await reminderPass(readOnly, authority, lease, suppressed, fake)
            XCTAssertTrue(failed.failed)
            XCTAssertEqual(fake.pending.count, 2)
            XCTAssertEqual(fake.delivered.count, 2)
            XCTAssertTrue(fake.removed.isEmpty)
            XCTAssertTrue(fake.adds.isEmpty)
            let unchanged = try await store.readCareReminderReceipts(context: lease, authority: authority)
            XCTAssertTrue(try XCTUnwrap(unchanged).receipts.blockedIdentifiers.isEmpty)
            let cleaned = await reminderPass(store, authority, lease, suppressed, fake)
            XCTAssertTrue(cleaned.failed) // Untrusted inventory was cleaned conservatively.
            XCTAssertTrue(fake.pending.isEmpty)
            XCTAssertTrue(fake.delivered.isEmpty)
            XCTAssertTrue(fake.adds.isEmpty)
        }
        // Reopen the actual disk after releasing the original writable Store.
        let cold = LocalStore(modelContainer: try diskContainer(url))
        let read = try await cold.readCareReminderReceipts(context: lease, authority: authority)
        let token = try XCTUnwrap(read)
        let decoded = try coldReceipts(token.receipts)
        XCTAssertEqual(decoded.blockedIdentifiers, ids)
        XCTAssertTrue(decoded.entries.isEmpty) // No invented sourceDueYMD/fireDate.
        await receiptReject {
            _ = try await cold.commitCareReminderReceipts(CareReminderReceipts(ownerId: lease.ownerId),
                replacing: token, authority: authority)
        }
        let recovered = await reminderPass(cold, authority, lease, state, fake)
        XCTAssertFalse(recovered.failed)
        XCTAssertEqual(recovered.unconfirmedBlockers, 2)
        XCTAssertEqual(recovered.omittedCount, 0)
        let optedOut = await reminderPass(cold, authority, lease, state, fake, optedIn: false)
        XCTAssertFalse(optedOut.failed)
        let noTask = await reminderPass(cold, authority, lease, removed, fake)
        XCTAssertFalse(noTask.failed)
        XCTAssertEqual(noTask.unconfirmedBlockers, 0)
        try await overviewCanonical(cold, authority: authority, lease: lease, ids: [serverPlantId], fullRefresh: true)
        let retained = try await cold.readCareReminderReceipts(context: lease, authority: authority)
        XCTAssertEqual(retained?.receipts.blockedIdentifiers, ids)
        XCTAssertTrue(fake.adds.isEmpty)
        XCTAssertEqual(fake.permissionRequests, 0)
    }
}

extension CollectionWireTests {
    @MainActor
    func testReminderForeignCleanupPrecedesReceiptReadAndBeginFailures() async throws {
        for corrupt in [false, true] {
            let (url, store, authority, lease, _) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            if corrupt {
                _ = try await store.beginCareReminderReceipts(context: lease, authority: authority)
                try receiptEdit(url) { disk in
                    let rows = try disk.fetch(FetchDescriptor<SyncedEntityRecord>())
                    let row = try XCTUnwrap(rows.first { $0.entityType == "local_care_reminder_receipts" })
                    row.payloadJSON = "corrupt"
                }
            }
            let before = try overviewDiskState(url)
            let target = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
            let own = try receiptCandidate()
            let foreign = try receiptCandidate(owner: otherSyncOwner)
            func item(_ c: CareReminderPlan.Candidate) -> CareReminderNotificationInventory.Item {
                .init(rawIdentifier: CareReminderNotificationFactory.prefix + c.id,
                    route: .init(candidate: c, attemptId: UUID()), deliveredAt: nil)
            }
            let ownItem = item(own)
            let foreignItem = item(foreign)
            let trial = CareReminderNotificationInventory.Item(
                rawIdentifier: "narat.trial-reminder.v1.test", route: nil, deliveredAt: nil)
            let fake = FakeCareReminderNotifications()
            fake.pending = [foreignItem, ownItem, trial]
            fake.delivered = fake.pending
            let worker = CareReminderScheduler(notifications: fake)
            worker.update(workerInput(target, authority, lease, nil, fake))
            await worker.waitUntilIdle()
            XCTAssertEqual(worker.result?.failed, true)
            XCTAssertEqual(fake.pending, [ownItem, trial])
            XCTAssertEqual(fake.delivered, [ownItem, trial])
            XCTAssertEqual(fake.removed, [foreignItem.rawIdentifier, foreignItem.rawIdentifier])
            XCTAssertGreaterThanOrEqual(fake.inventoryReads, 3) // Includes removal readback.
            XCTAssertTrue(fake.adds.isEmpty)
            XCTAssertEqual(fake.permissionRequests, 0)
            XCTAssertEqual(try overviewDiskState(url), before) // Includes corrupt bytes.
            authority.bind(try profileSession(ownerId: otherSyncOwner))
            let foreignLease = try authority.capture(ownerId: otherSyncOwner)
            let foreignLedger = try await target.readCareReminderReceipts(context: foreignLease, authority: authority)
            XCTAssertNil(foreignLedger)
        }
    }

    @MainActor
    func testReminderNilProjectionOptoutProtectsBothUnknownOwnVariantsOnDisk() async throws {
        for validRoute in [false, true] {
            let (url, store, authority, lease, local) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let state = try passState(local)
            let candidates = reminderPlan(state).candidates
            XCTAssertFalse(candidates.isEmpty)
            let fake = FakeCareReminderNotifications()
            fake.pending = candidates.map {
                .init(rawIdentifier: CareReminderNotificationFactory.prefix + $0.id,
                    route: validRoute ? .init(candidate: $0, attemptId: UUID()) : nil, deliveredAt: nil)
            }
            fake.delivered = fake.pending
            let seeded = fake.pending
            _ = try await store.beginCareReminderReceipts(context: lease, authority: authority)
            let before = try overviewDiskState(url)
            let readOnly = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
            let worker = CareReminderScheduler(notifications: fake)
            worker.update(workerInput(readOnly, authority, lease, nil, fake, optedIn: false))
            await worker.waitUntilIdle()
            XCTAssertEqual(worker.result?.failed, true)
            XCTAssertEqual(fake.pending, seeded)
            XCTAssertEqual(fake.delivered, seeded)
            XCTAssertTrue(fake.removed.isEmpty)
            XCTAssertEqual(try overviewDiskState(url), before)
            worker.update(workerInput(store, authority, lease, nil, fake, optedIn: false))
            await worker.waitUntilIdle()
            XCTAssertTrue(fake.pending.isEmpty)
            XCTAssertTrue(fake.delivered.isEmpty)
            let cold = LocalStore(modelContainer: try diskContainer(url))
            let read = try await cold.readCareReminderReceipts(context: lease, authority: authority)
            let ledger = try XCTUnwrap(read).receipts
            for c in candidates {
                if validRoute {
                    XCTAssertEqual(ledger.entries[c.id]?.phase, .spent)
                } else {
                    XCTAssertTrue(ledger.blockedIdentifiers.contains(c.id))
                    XCTAssertNil(ledger.entries[c.id]) // No invented dates.
                }
            }
            let restored = await reminderPass(cold, authority, lease, state, fake)
            XCTAssertFalse(restored.failed)
            XCTAssertTrue(fake.adds.isEmpty)
            XCTAssertEqual(fake.permissionRequests, 0)
        }
    }

    @MainActor
    func testReminderPrivacyCleanupSurvivesKnownReceiptSaveFailureAfterAdd() async throws {
        for heldAdd in [false, true] {
            let (url, store, authority, lease, local) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let state = try passState(local)
            let fake = FakeCareReminderNotifications()
            let gate = TodayReadBarrier()
            let worker = CareReminderScheduler(notifications: fake)
            if heldAdd {
                fake.onAdd = { _ in await gate.wait() }
                worker.update(workerInput(store, authority, lease, state, fake))
                await gate.waitUntilEntered()
            } else {
                let initial = await reminderPass(store, authority, lease, state, fake)
                XCTAssertFalse(initial.failed)
            }
            let before = try await store.readCareReminderReceipts(context: lease, authority: authority)
            let original = try XCTUnwrap(before).receipts
            XCTAssertEqual(original.entries.values.first?.phase, heldAdd ? .prepared : .armed)
            fake.delivered = fake.pending
            let trial = CareReminderNotificationInventory.Item(
                rawIdentifier: "narat.trial-reminder.v1.test", route: nil, deliveredAt: nil)
            fake.pending.append(trial)
            fake.delivered.append(trial)
            let readOnly = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
            worker.update(workerInput(readOnly, authority, lease, state, fake, optedIn: false))
            if heldAdd { gate.open() }
            await worker.waitUntilIdle()
            XCTAssertEqual(worker.result?.failed, true)
            XCTAssertEqual(fake.pending, [trial])
            XCTAssertEqual(fake.delivered, [trial])
            XCTAssertEqual(fake.adds.count, 1)
            XCTAssertEqual(fake.permissionRequests, 0)
            let cold = LocalStore(modelContainer: try diskContainer(url))
            let unchanged = try await cold.readCareReminderReceipts(context: lease, authority: authority)
            XCTAssertEqual(unchanged?.receipts, original)
            XCTAssertEqual(unchanged?.revision, before?.revision)
            fake.onAdd = nil
            let retry = await reminderPass(cold, authority, lease, state, fake)
            XCTAssertFalse(retry.failed)
            let recovered = try await cold.readCareReminderReceipts(context: lease, authority: authority)
            XCTAssertEqual(recovered?.receipts.entries.values.first?.phase, .uncertain)
            XCTAssertEqual(fake.adds.count, 1)
        }
    }
}

extension CollectionWireTests {
    @MainActor
    func testReminderKnownOwnerDeferJournalsUnknownBeforeLogoutAndColdRestore() async throws {
        for validRoute in [false, true] {
            let (url, store, authority, lease, local) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let state = try passState(local, count: 2)
            let candidates = reminderPlan(state).candidates
            let unknown = try XCTUnwrap(candidates.first)
            let known = try XCTUnwrap(candidates.dropFirst().first)
            let fake = FakeCareReminderNotifications()
            let token = try await store.beginCareReminderReceipts(context: lease, authority: authority)
            var seeded = token.receipts
            _ = try seeded.prepare(known, now: fake.now)
            let knownEntry = try XCTUnwrap(seeded.entries[known.id])
            _ = try await store.commitCareReminderReceipts(seeded, replacing: token, authority: authority)
            let unknownItem = CareReminderNotificationInventory.Item(
                rawIdentifier: CareReminderNotificationFactory.prefix + unknown.id,
                route: validRoute ? .init(candidate: unknown, attemptId: UUID()) : nil,
                deliveredAt: nil)
            let knownItem = CareReminderNotificationInventory.Item(
                rawIdentifier: CareReminderNotificationFactory.prefix + known.id,
                route: .init(candidate: known, attemptId: knownEntry.attemptId), deliveredAt: nil)
            let trial = CareReminderNotificationInventory.Item(
                rawIdentifier: "narat.trial-reminder.v1.test", route: nil, deliveredAt: nil)
            fake.pending = [unknownItem, knownItem, trial]
            let worker = CareReminderScheduler(notifications: fake)
            worker.update(workerInput(store, authority, lease, nil, fake))
            await worker.waitUntilIdle()
            XCTAssertEqual(worker.result?.deferred, true)
            XCTAssertEqual(fake.pending, [unknownItem, knownItem, trial])
            XCTAssertTrue(fake.removed.isEmpty)
            XCTAssertTrue(fake.adds.isEmpty)
            let journal = try await store.readCareReminderReceipts(context: lease, authority: authority)
            let persisted = try XCTUnwrap(journal).receipts
            XCTAssertEqual(persisted.entries[known.id], knownEntry) // No ACK/phase observation without projection.
            if validRoute {
                XCTAssertEqual(persisted.entries[unknown.id]?.phase, .uncertain)
            } else {
                XCTAssertTrue(persisted.blockedIdentifiers.contains(unknown.id))
                XCTAssertNil(persisted.entries[unknown.id]) // No invented scheduling dates.
            }
            authority.bind(nil)
            worker.cancelAll()
            await worker.waitUntilIdle()
            XCTAssertEqual(fake.pending, [trial])
            authority.bind(try profileSession(ownerId: syncOwner))
            let freshLease = try authority.capture(ownerId: syncOwner)
            let cold = LocalStore(modelContainer: try diskContainer(url))
            let restored = CareReminderScheduler(notifications: fake)
            restored.update(workerInput(cold, authority, freshLease, state, fake))
            await restored.waitUntilIdle()
            XCTAssertEqual(restored.result?.failed, false)
            XCTAssertTrue(fake.adds.isEmpty)
            XCTAssertEqual(fake.pending, [trial])
            XCTAssertEqual(fake.permissionRequests, 0)
            let final = try await cold.readCareReminderReceipts(context: freshLease, authority: authority)
            XCTAssertEqual(final?.receipts.entries[known.id]?.phase, .uncertain)
        }
    }
}

extension CollectionWireTests {
    @MainActor
    func testReminderCancelledConflictNeedsDurableBarrierBeforeNilOrFailedCleanup() async throws {
        for saveFails in [false, true] {
            for delivered in [false, true] {
                let (url, store, authority, lease, local) = try await reminderFixture()
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let state = try passState(local)
                let candidate = try XCTUnwrap(reminderPlan(state).candidates.first)
                let fake = FakeCareReminderNotifications()
                let token = try await store.beginCareReminderReceipts(context: lease, authority: authority)
                var prepared = token.receipts
                _ = try prepared.prepare(candidate, now: fake.now)
                let preparing = try await store.commitCareReminderReceipts(prepared, replacing: token, authority: authority)
                var cancelled = preparing.receipts
                let entry = try XCTUnwrap(cancelled.entries[candidate.id])
                XCTAssertTrue(try cancelled.cancel(id: candidate.id, attemptId: entry.attemptId,
                    proof: .removedAndReadBackAbsent(confirmedAt: fake.now), now: fake.now))
                _ = try await store.commitCareReminderReceipts(cancelled, replacing: preparing, authority: authority)
                let before = try overviewDiskState(url)
                let item = CareReminderNotificationInventory.Item(
                    rawIdentifier: CareReminderNotificationFactory.prefix + candidate.id,
                    route: .init(candidate: candidate, attemptId: entry.attemptId),
                    deliveredAt: delivered ? fake.now : nil)
                let trial = CareReminderNotificationInventory.Item(
                    rawIdentifier: "narat.trial-reminder.v1.test", route: nil, deliveredAt: nil)
                fake.pending = delivered ? [trial] : [item, trial]
                fake.delivered = delivered ? [item] : []
                let target = saveFails
                    ? LocalStore(modelContainer: try diskContainer(url, allowsSave: false)) : store
                let worker = CareReminderScheduler(notifications: fake)
                worker.update(workerInput(target, authority, lease, saveFails ? state : nil, fake, optedIn: false))
                await worker.waitUntilIdle()
                XCTAssertEqual(worker.result?.failed, saveFails)
                XCTAssertTrue(fake.adds.isEmpty)
                if saveFails {
                    XCTAssertEqual(try overviewDiskState(url), before)
                    XCTAssertEqual(fake.pending, delivered ? [trial] : [item, trial])
                    XCTAssertEqual(fake.delivered, delivered ? [item] : [])
                    XCTAssertTrue(fake.removed.isEmpty) // Keep conflicting evidence until terminal save succeeds.
                } else {
                    XCTAssertEqual(fake.pending, [trial])
                    XCTAssertTrue(fake.delivered.isEmpty)
                    let read = try await store.readCareReminderReceipts(context: lease, authority: authority)
                    XCTAssertEqual(read?.receipts.entries[candidate.id]?.phase, delivered ? .spent : .uncertain)
                }
                // Cold eligibility recovery still sees the contradiction when the terminal save failed.
                let cold = LocalStore(modelContainer: try diskContainer(url))
                let recovered = await reminderPass(cold, authority, lease, state, fake)
                XCTAssertFalse(recovered.failed)
                XCTAssertTrue(fake.adds.isEmpty)
                XCTAssertEqual(fake.pending, [trial])
                XCTAssertTrue(fake.delivered.isEmpty)
                let final = try await cold.readCareReminderReceipts(context: lease, authority: authority)
                XCTAssertEqual(final?.receipts.entries[candidate.id]?.phase, delivered ? .spent : .uncertain)
                XCTAssertEqual(final?.receipts.entries[candidate.id]?.attemptId, entry.attemptId)
                XCTAssertEqual(fake.permissionRequests, 0)
            }
        }
    }
}

extension CollectionWireTests {
    @MainActor
    private func lifecycleContext(_ store: LocalStore, _ api: PlantsAPIClient,
                                  _ lease: SyncSessionLease, locale: String = "pl",
                                  reader: (() async throws -> CareOverviewViewState)? = nil)
        -> CareReminderLifecycle.Context {
        .init(lease: lease, store: store, authority: api.syncAuthority,
              engine: SyncEngine(store: store, apiClient: api), locale: locale,
              isCurrent: { true }, readCache: reader)
    }

    @MainActor
    private func lifecycleCache(_ store: LocalStore, _ api: PlantsAPIClient,
                                _ lease: SyncSessionLease, rows: [[String: Any]]) async throws {
        let ordered = rows.sorted { ($0["plant_id"] as! String).lowercased() < ($1["plant_id"] as! String).lowercased() }
        var page = overviewPage(ordered)
        page["verified_access_until"] = NSNull()
        let token = try await store.beginCareOverviewRead(
            locale: "pl", context: lease, authority: api.syncAuthority)
        try await store.finishCareOverviewRead(
            token, snapshot: overviewSnapshot([page]), authority: api.syncAuthority)
    }

    @MainActor
    func testReminderLifecycleBackgroundDurableCancellationAndReadFailure() async throws {
        let transport = CatalogueTransport([])
        let (url, store, api, lease, repo) = try await overviewRepositoryFixture(transport)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await overviewCanonical(store, authority: api.syncAuthority, lease: lease,
                                    ids: [serverPlantId, otherSyncOwner])
        try await lifecycleCache(store, api, lease,
                                 rows: [reminderRow(serverPlantId), reminderRow(otherSyncOwner)])
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CareReminderLifecycle.preferenceKey(ownerId: syncOwner))
        let fake = FakeCareReminderNotifications()
        let core = CareReminderLifecycle(notifications: fake, defaults: defaults,
            clock: { fake.now }, timeZone: { TimeZone(secondsFromGMT: 0)! })
        var failRead = false
        var arrival: XCTestExpectation?
        let context = lifecycleContext(store, api, lease, reader: {
            arrival?.fulfill()
            arrival = nil
            if failRead { throw FakeCareReminderNotifications.Fault.injected }
            return try await repo.cachedCareOverview(context: lease)
        })
        core.setSceneActive(true)
        core.accept(context)
        await core.waitUntilIdle()
        XCTAssertEqual(fake.pending.count, 2)
        let added = fake.adds.count
        core.setSceneActive(false)
        await core.waitUntilIdle()
        XCTAssertEqual(fake.pending.count, 2)
        XCTAssertEqual(fake.adds.count, added)
        let wateringRead = expectation(description: "real durable watering signal")
        arrival = wateringRead
        let watering = try ManualWateringAction.record.envelope(plantId: serverPlantId)
        try await store.enqueueSavedPlantWatering(watering, context: lease, authority: api.syncAuthority)
        await fulfillment(of: [wateringRead], timeout: 3)
        await core.waitUntilIdle()
        XCTAssertEqual(fake.pending.compactMap { $0.route?.candidate.plantId }, [otherSyncOwner])
        XCTAssertEqual(fake.adds.count, added)
        failRead = true
        let failedRead = expectation(description: "real durable profile signal")
        arrival = failedRead
        let hour = try ProfileReminderHourCommand.make(reminderHourLocal: 10)
        _ = try await store.enqueueProfileReminderHour(hour, context: lease, authority: api.syncAuthority)
        await fulfillment(of: [failedRead], timeout: 3)
        await core.waitUntilIdle()
        XCTAssertTrue(core.readFailed)
        XCTAssertTrue(core.optedIn)
        XCTAssertTrue(fake.pending.isEmpty)
        core.setSceneActive(true)
        await core.waitUntilIdle()
        XCTAssertEqual(fake.adds.count, added)
        failRead = false
        core.retry()
        await core.waitUntilIdle()
        XCTAssertFalse(core.readFailed)
        XCTAssertEqual(fake.adds.count, added)
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        XCTAssertEqual(local.pending.count, 2)
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
        core.logout()
        await core.waitUntilIdle()
    }

    @MainActor
    func testReminderLifecycleDurableRevisionDisplacesHeldOldCache() async throws {
        let transport = CatalogueTransport([])
        let (url, store, api, lease, repo) = try await overviewRepositoryFixture(transport)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await lifecycleCache(store, api, lease, rows: [reminderRow(serverPlantId)])
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CareReminderLifecycle.preferenceKey(ownerId: syncOwner))
        let fake = FakeCareReminderNotifications()
        let core = CareReminderLifecycle(notifications: fake, defaults: defaults,
            clock: { fake.now }, timeZone: { TimeZone(secondsFromGMT: 0)! })
        let gate = TodayReadBarrier()
        var block = false
        core.accept(lifecycleContext(store, api, lease, reader: {
            let captured = try await repo.cachedCareOverview(context: lease)
            if block { block = false; await gate.wait() }
            return captured
        }))
        await core.waitUntilIdle()
        XCTAssertTrue(fake.adds.isEmpty)
        block = true
        core.setSceneActive(true)
        await gate.waitUntilEntered()
        let displaced = expectation(description: "local stream fences suspended read")
        let expected = core.revision + 1
        let observation = core.$revision.sink { if $0 == expected { displaced.fulfill() } }
        let hour = try ProfileReminderHourCommand.make(reminderHourLocal: 10)
        _ = try await store.enqueueProfileReminderHour(hour, context: lease, authority: api.syncAuthority)
        await fulfillment(of: [displaced], timeout: 3)
        gate.open()
        await core.waitUntilIdle()
        observation.cancel()
        XCTAssertTrue(core.state?.profileHourPending == true)
        XCTAssertTrue(fake.adds.isEmpty)
        XCTAssertTrue(fake.pending.isEmpty)
        XCTAssertEqual(fake.permissionRequests, 0)
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
        core.logout()
        await core.waitUntilIdle()
    }

    @MainActor
    func testReminderLifecycleUnresolvedStartupLogoutABAAndLateLocaleRead() async throws {
        let (url, store, api, lease, repo) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CareReminderLifecycle.preferenceKey(ownerId: syncOwner))
        let fake = FakeCareReminderNotifications()
        let own = try receiptCandidate()
        let foreign = try receiptCandidate(owner: otherSyncOwner)
        fake.pending = [own, foreign].map {
            .init(rawIdentifier: CareReminderNotificationFactory.prefix + $0.id,
                  route: .init(candidate: $0, attemptId: UUID()), deliveredAt: nil)
        }
        let core = CareReminderLifecycle(notifications: fake, defaults: defaults,
            clock: { fake.now }, timeZone: { TimeZone(secondsFromGMT: 0)! })
        core.suspendAuth()
        await core.waitUntilIdle()
        XCTAssertEqual(fake.inventoryReads, 0)
        let gate = TodayReadBarrier()
        let oldDone = expectation(description: "late original lease callback")
        core.accept(lifecycleContext(store, api, lease, reader: {
            _ = try await repo.cachedCareOverview(context: lease)
            await gate.wait()
            oldDone.fulfill()
            throw FakeCareReminderNotifications.Fault.injected
        }))
        await gate.waitUntilEntered()
        XCTAssertEqual(fake.pending.map { $0.rawIdentifier }, [CareReminderNotificationFactory.prefix + own.id])
        let journal = try await store.readCareReminderReceipts(context: lease, authority: api.syncAuthority)
        XCTAssertEqual(journal?.receipts.entries[own.id]?.phase, .uncertain)
        core.suspendAuth()
        await core.worker.waitUntilIdle()
        XCTAssertEqual(fake.pending.count, 1)
        core.logout()
        api.syncAuthority.bind(try profileSession(ownerId: otherSyncOwner))
        let b = try api.syncAuthority.capture(ownerId: otherSyncOwner)
        core.accept(lifecycleContext(store, api, b))
        XCTAssertFalse(core.optedIn)
        api.syncAuthority.bind(try profileSession())
        let a = try api.syncAuthority.capture(ownerId: syncOwner)
        core.accept(lifecycleContext(store, api, a, locale: "en"))
        core.setSceneActive(true)
        await core.waitUntilIdle()
        XCTAssertTrue(core.optedIn)
        XCTAssertTrue(fake.pending.isEmpty)
        let revision = core.revision
        gate.open()
        await fulfillment(of: [oldDone], timeout: 3)
        await core.waitUntilIdle()
        XCTAssertEqual(core.revision, revision)
        XCTAssertFalse(core.readFailed)
        XCTAssertTrue(fake.adds.isEmpty)
        XCTAssertEqual(fake.permissionRequests, 0)
        core.logout()
        await core.waitUntilIdle()
    }

    @MainActor
    func testReminderLifecycleOwnerConsentColdRetentionAndExplicitEligiblePermission() async throws {
        let transport = CatalogueTransport([])
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(transport)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeCareReminderNotifications()
        fake.authorizationValue = .notDetermined
        let core = CareReminderLifecycle(notifications: fake, defaults: defaults,
            clock: { fake.now }, timeZone: { TimeZone(secondsFromGMT: 0)! })
        core.setSceneActive(true)
        core.accept(lifecycleContext(store, api, lease))
        await core.waitUntilIdle()
        XCTAssertFalse(core.optedIn)
        core.setOptedIn(true, requestPermission: true) // Only overdue rows: NoSchedule.
        await core.waitUntilIdle()
        XCTAssertEqual(fake.permissionRequests, 0)
        try await lifecycleCache(store, api, lease, rows: [reminderRow(serverPlantId)])
        core.cachePublicationOrTimeChanged()
        await core.waitUntilIdle()
        XCTAssertEqual(fake.permissionRequests, 0)
        core.requestEligiblePermission()
        await core.waitUntilIdle()
        XCTAssertEqual(fake.permissionRequests, 1)
        core.logout()
        await core.waitUntilIdle()
        let cold = CareReminderLifecycle(notifications: fake, defaults: defaults,
            clock: { fake.now }, timeZone: { TimeZone(secondsFromGMT: 0)! })
        cold.setSceneActive(true)
        cold.accept(lifecycleContext(store, api, lease))
        await cold.waitUntilIdle()
        XCTAssertTrue(cold.optedIn)
        XCTAssertEqual(fake.permissionRequests, 1)
        api.syncAuthority.bind(try profileSession(ownerId: otherSyncOwner))
        let b = try api.syncAuthority.capture(ownerId: otherSyncOwner)
        cold.accept(lifecycleContext(store, api, b))
        await cold.waitUntilIdle()
        XCTAssertFalse(cold.optedIn)
        XCTAssertTrue(defaults.bool(forKey: CareReminderLifecycle.preferenceKey(ownerId: syncOwner)))
        XCTAssertFalse(defaults.bool(forKey: CareReminderLifecycle.preferenceKey(ownerId: otherSyncOwner)))
        XCTAssertEqual(fake.permissionRequests, 1)
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
        cold.logout()
        await cold.waitUntilIdle()
    }

    @MainActor
    func testReminderLifecycleUnknownCacheHoldVersusKnownPolicySuppression() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        for (index, mode) in ["absent", "offline", "profile.update", "denied", "revalidate", "generation", "expired", "withdrawn"].enumerated() {
            let suite = UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: CareReminderLifecycle.preferenceKey(ownerId: syncOwner))
            let fake = FakeCareReminderNotifications()
            let core = CareReminderLifecycle(notifications: fake, defaults: defaults,
                clock: { fake.now }, timeZone: { TimeZone(secondsFromGMT: 0)! })
            let row = overviewRow(serverPlantId, dated: true, controls: [reminderControl(index + 1)])
            var current = try reminderState(local, rows: [row])
            core.setSceneActive(true)
            core.accept(lifecycleContext(store, api, lease, reader: { current }))
            await core.waitUntilIdle()
            // Each iteration uses a fresh opportunity, not a previously spent occurrence.
            let armed = fake.pending.count
            XCTAssertEqual(armed, 1, mode)
            current = try reminderState(local,
                rows: mode == "withdrawn" ? [overviewRow(serverPlantId)] : [row],
                mode: mode, deadline: mode == "expired" ? "2026-11-19T12:00:00Z" : nil)
            if mode == "expired" { XCTAssertEqual(current.access, .expired) }
            core.cachePublicationOrTimeChanged()
            await core.waitUntilIdle()
            XCTAssertEqual(fake.pending.count, ["absent", "offline"].contains(mode) ? armed : 0, mode)
            XCTAssertTrue(core.optedIn, mode)
            XCTAssertEqual(fake.permissionRequests, 0, mode)
            core.logout()
            await core.waitUntilIdle()
        }
    }
}

extension CollectionWireTests {
    @MainActor
    func testReminderWorkerPermissionReadbackLagArmsBeforePublishedAuthorizationCatchesUp() async throws {
        let (url, store, authority, lease, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fake = FakeCareReminderNotifications()
        fake.authorizationValue = .notDetermined
        var prompted = false
        var postPromptReads = 0
        fake.onPermission = { prompted = true }
        fake.onAuthorization = {
            if prompted {
                postPromptReads += 1
                fake.authorizationValue = postPromptReads == 1 ? .notDetermined : .authorized
            }
        }
        let worker = CareReminderScheduler(notifications: fake)
        let input = workerInput(store, authority, lease, try passState(local), fake)
        let occurrence = try XCTUnwrap(reminderPlan(input.state).candidates.first?.id)
        worker.update(input)
        await worker.waitUntilIdle()
        XCTAssertTrue(fake.adds.isEmpty)
        worker.requestPermission()
        await worker.waitUntilIdle()
        XCTAssertGreaterThanOrEqual(postPromptReads, 2)
        XCTAssertEqual(fake.permissionRequests, 1)
        XCTAssertEqual(fake.adds.map { $0.candidate.id }, [occurrence])
        XCTAssertEqual(worker.result?.confirmedPendingCount, 1)
        XCTAssertEqual(worker.authorization, .notDetermined) // Drain published its earlier OS read.
        XCTAssertFalse(worker.requestingPermission)
        XCTAssertEqual(worker.result?.failed, false)
        XCTAssertEqual(worker.result?.deferred, false)
        worker.retry()
        await worker.waitUntilIdle()
        XCTAssertEqual(worker.authorization, .authorized)
        XCTAssertEqual(fake.permissionRequests, 1)
        XCTAssertEqual(fake.adds.map { $0.candidate.id }, [occurrence])
        XCTAssertEqual(fake.pending.count, 1)
    }

    @MainActor
    func testReminderWorkerPermissionReadbackLagNeedsExplicitTriggerWhenBothReadsRemainUndetermined() async throws {
        let (url, store, authority, lease, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fake = FakeCareReminderNotifications()
        fake.authorizationValue = .notDetermined
        var authorizationReads = 0
        var prompted = false
        var postPromptReads = 0
        fake.onPermission = { prompted = true }
        fake.onAuthorization = {
            authorizationReads += 1
            if prompted { postPromptReads += 1 }
        }
        let worker = CareReminderScheduler(notifications: fake)
        let input = workerInput(store, authority, lease, try passState(local), fake)
        let occurrence = try XCTUnwrap(reminderPlan(input.state).candidates.first?.id)
        worker.update(input)
        await worker.waitUntilIdle()
        worker.requestPermission()
        await worker.waitUntilIdle()
        XCTAssertGreaterThanOrEqual(postPromptReads, 2)
        XCTAssertEqual(fake.permissionRequests, 1)
        XCTAssertEqual(worker.authorization, .notDetermined)
        XCTAssertFalse(worker.requestingPermission)
        XCTAssertEqual(worker.result?.failed, false)
        XCTAssertEqual(worker.result?.deferred, false)
        XCTAssertEqual(worker.result?.confirmedPendingCount, 0)
        XCTAssertTrue(fake.adds.isEmpty)
        let readsBeforeUntriggeredChange = authorizationReads
        fake.authorizationValue = .authorized // OS changes independently; this is not a worker trigger.
        await Task.yield()
        await worker.waitUntilIdle()
        XCTAssertEqual(authorizationReads, readsBeforeUntriggeredChange)
        XCTAssertTrue(fake.adds.isEmpty)
        XCTAssertEqual(worker.authorization, .notDetermined)
        worker.retry()
        await worker.waitUntilIdle()
        XCTAssertEqual(worker.authorization, .authorized)
        XCTAssertEqual(worker.result?.confirmedPendingCount, 1)
        XCTAssertEqual(fake.adds.map { $0.candidate.id }, [occurrence])
        worker.retry()
        await worker.waitUntilIdle()
        XCTAssertEqual(fake.permissionRequests, 1)
        XCTAssertEqual(fake.adds.map { $0.candidate.id }, [occurrence])
        XCTAssertEqual(fake.pending.count, 1)
    }
}

extension CollectionWireTests {
    private func consentProjection(
        _ state: CareOverviewViewState?, result: CareReminderScheduler.Result? = nil,
        authorization: CareReminderPlan.Authorization? = .authorized,
        current: Bool = true, reading: Bool = false, active: Bool = true,
        optedIn: Bool = true, readFailed: Bool = false, eligible: Int = 1
    ) -> ReminderConsentStatus {
        ReminderConsentStatus(current: current, reading: reading, active: active,
            optedIn: optedIn, readFailed: readFailed, state: state, eligibleCount: eligible,
            authorization: authorization, requestingPermission: false, result: result,
            now: SQLTimestamp.date(from: "2026-11-20T00:00:00Z")!)
    }

    @MainActor
    func testConsentProjectionRejectsStaleAndUnreadyConfirmation() async throws {
        let (url, _, _, _, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let state = try passState(local)
        let confirmed = CareReminderScheduler.Result(confirmedPendingCount: 1,
            omittedCount: 0, unconfirmedBlockers: 0, failed: false, deferred: false)
        let stale = consentProjection(state, result: confirmed, current: false)
        XCTAssertEqual(stale.phase, .unavailable)
        XCTAssertEqual(stale.confirmedPendingCount, 0)
        XCTAssertEqual(consentProjection(state, result: confirmed, optedIn: false).phase, .stopping)
        XCTAssertEqual(consentProjection(state, result: confirmed, reading: true).phase, .loading)
        XCTAssertEqual(consentProjection(nil, result: confirmed).phase, .unknown)
        XCTAssertEqual(consentProjection(state, result: confirmed, readFailed: true).phase, .readFailed)
        XCTAssertEqual(consentProjection(state, result: confirmed, active: false).phase, .paused)
        let expired = try reminderState(local, rows: [reminderRow(serverPlantId)],
                                        deadline: "2026-11-19T12:00:00Z")
        XCTAssertEqual(consentProjection(expired, result: confirmed).phase, .expired)
        let pending = try reminderState(local, rows: [reminderRow(serverPlantId)], mode: "profile.update")
        XCTAssertEqual(consentProjection(pending, result: confirmed).phase, .pending)
        let paused = try reminderState(local, rows: [reminderRow(serverPlantId)], mode: "invalidated")
        XCTAssertEqual(consentProjection(paused, result: confirmed).phase, .paused)
    }

    @MainActor
    func testConsentProjectionZeroPartialAndFailureNeverPromiseScheduling() async throws {
        let (url, _, _, _, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let state = try passState(local)
        let zero = CareReminderScheduler.Result(confirmedPendingCount: 0,
            omittedCount: 0, unconfirmedBlockers: 0, failed: false, deferred: false)
        let status = consentProjection(state, result: zero, authorization: .notDetermined)
        XCTAssertEqual(status.phase, .unconfirmed)
        XCTAssertEqual(status.confirmedPendingCount, 0)
        XCTAssertTrue(status.canAllow)
        XCTAssertEqual(consentProjection(state).phase, .pending)
        XCTAssertEqual(consentProjection(state, result: zero, eligible: 0).phase, .noEligible)
        XCTAssertFalse(consentProjection(state, result: zero, authorization: .notDetermined, eligible: 0).canAllow)
        XCTAssertEqual(consentProjection(state, result: zero, authorization: .denied).phase, .denied)
        let failure = CareReminderScheduler.Result(confirmedPendingCount: 0,
            omittedCount: 0, unconfirmedBlockers: 1, failed: true, deferred: false)
        XCTAssertEqual(consentProjection(state, result: failure).phase, .failed)
        let partial = CareReminderScheduler.Result(confirmedPendingCount: 1,
            omittedCount: 2, unconfirmedBlockers: 1, failed: true, deferred: false)
        let confirmed = consentProjection(state, result: partial, authorization: .notDetermined)
        XCTAssertEqual(confirmed.phase, .confirmed)
        XCTAssertEqual(confirmed.confirmedPendingCount, 1)
        XCTAssertTrue(confirmed.partial)
        XCTAssertTrue(confirmed.readbackWarning)
    }

    @MainActor
    func testConsentProjectionUsesActualDelayedPermissionReadback() async throws {
        for catchesUp in [false, true] {
            let (url, store, authority, lease, local) = try await reminderFixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let fake = FakeCareReminderNotifications()
            fake.authorizationValue = .notDetermined
            var prompted = false
            var reads = 0
            fake.onPermission = { prompted = true }
            fake.onAuthorization = {
                if prompted {
                    reads += 1
                    fake.authorizationValue = catchesUp && reads > 1 ? .authorized : .notDetermined
                }
            }
            let state = try passState(local)
            let worker = CareReminderScheduler(notifications: fake)
            worker.update(workerInput(store, authority, lease, state, fake))
            await worker.waitUntilIdle()
            worker.requestPermission()
            await worker.waitUntilIdle()
            let status = consentProjection(state, result: worker.result, authorization: worker.authorization)
            XCTAssertEqual(status.phase, catchesUp ? .confirmed : .unconfirmed)
            XCTAssertEqual(status.confirmedPendingCount, catchesUp ? 1 : 0)
            XCTAssertEqual(status.readbackWarning, catchesUp)
            XCTAssertEqual(fake.permissionRequests, 1)
            // End the simulated readback lag before the independent OS permission change.
            fake.onAuthorization = nil
            fake.authorizationValue = .authorized
            worker.retry()
            await worker.waitUntilIdle()
            let checked = consentProjection(state, result: worker.result, authorization: worker.authorization)
            XCTAssertEqual(checked.phase, .confirmed)
            XCTAssertFalse(checked.readbackWarning)
            XCTAssertEqual(fake.permissionRequests, 1)
        }
    }

    @MainActor
    func testConsentActionsRejectOriginalOwnerAfterSDKChanges() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeCareReminderNotifications()
        let core = CareReminderLifecycle(notifications: fake, defaults: defaults,
            clock: { fake.now }, timeZone: { TimeZone(secondsFromGMT: 0)! })
        core.setSceneActive(true)
        core.accept(lifecycleContext(store, api, lease))
        await core.waitUntilIdle()
        let binding = try XCTUnwrap(core.consentBinding(expectedOwnerId: syncOwner, locale: "pl"))
        XCTAssertEqual(core.consentStatus(binding: binding).phase, .off)
        core.performConsentAction(.setOptedIn(true), binding: binding)
        await core.waitUntilIdle()
        api.syncAuthority.bind(try profileSession(ownerId: otherSyncOwner))
        let revision = core.revision
        let actions: [CareReminderLifecycle.ConsentAction] = [.setOptedIn(false), .allow, .checkStatus]
        for action in actions {
            core.performConsentAction(action, binding: binding)
        }
        XCTAssertEqual(core.revision, revision)
        XCTAssertTrue(defaults.bool(forKey: CareReminderLifecycle.preferenceKey(ownerId: syncOwner)))
        XCTAssertEqual(core.consentStatus(binding: binding).phase, .unavailable)
        let b = try api.syncAuthority.capture(ownerId: otherSyncOwner)
        core.accept(lifecycleContext(store, api, b))
        await core.waitUntilIdle()
        core.performConsentAction(.setOptedIn(true), binding: binding)
        XCTAssertFalse(core.optedIn)
        XCTAssertFalse(defaults.bool(forKey: CareReminderLifecycle.preferenceKey(ownerId: otherSyncOwner)))
        XCTAssertEqual(fake.permissionRequests, 0)
        core.logout()
        await core.waitUntilIdle()
    }

    @MainActor
    func testConsentNoSchedulePreferenceAndRetryNeverQueuePermission() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeCareReminderNotifications()
        fake.authorizationValue = .notDetermined
        let core = CareReminderLifecycle(notifications: fake, defaults: defaults,
            clock: { fake.now }, timeZone: { TimeZone(secondsFromGMT: 0)! })
        core.setSceneActive(true)
        core.accept(lifecycleContext(store, api, lease))
        await core.waitUntilIdle()
        let binding = try XCTUnwrap(core.consentBinding(expectedOwnerId: syncOwner, locale: "pl"))
        core.performConsentAction(.setOptedIn(true), binding: binding)
        core.performConsentAction(.allow, binding: binding)
        await core.waitUntilIdle()
        XCTAssertFalse(core.offersConsent(expectedOwnerId: syncOwner))
        XCTAssertEqual(fake.permissionRequests, 0)
        try await lifecycleCache(store, api, lease, rows: [reminderRow(serverPlantId)])
        core.cachePublicationOrTimeChanged()
        await core.waitUntilIdle()
        XCTAssertTrue(core.offersConsent(expectedOwnerId: syncOwner))
        XCTAssertTrue(core.consentStatus(binding: binding).canAllow)
        core.setSceneActive(false)
        core.setSceneActive(true)
        core.performConsentAction(.checkStatus, binding: binding)
        await core.waitUntilIdle()
        XCTAssertEqual(fake.permissionRequests, 0)
        core.performConsentAction(.allow, binding: binding)
        await core.waitUntilIdle()
        XCTAssertEqual(fake.permissionRequests, 1)
        XCTAssertEqual(core.consentStatus(binding: binding).phase, .unconfirmed)
        core.logout()
        await core.waitUntilIdle()
    }

    @MainActor
    func testConsentFrozenBindingRejectsReplacementSDKLocaleAndABA() async throws {
        for transition in ["context", "sdk", "locale", "aba"] {
            let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try await lifecycleCache(store, api, lease, rows: [reminderRow(serverPlantId)])
            let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
            let fake = FakeCareReminderNotifications()
            fake.authorizationValue = .notDetermined
            let state = CareOverviewViewState(local: local, now: fake.now, origin: .cache)
            let suite = UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let core = CareReminderLifecycle(notifications: fake, defaults: defaults,
                clock: { fake.now }, timeZone: { TimeZone(secondsFromGMT: 0)! })
            core.setSceneActive(true)
            core.accept(lifecycleContext(store, api, lease, reader: { state }))
            await core.waitUntilIdle()
            let original = try XCTUnwrap(core.consentBinding(expectedOwnerId: syncOwner, locale: "pl"))
            // These closures model actions retained by the original presentation.
            let oldToggle: (Bool) -> Void = { core.performConsentAction(.setOptedIn($0), binding: original) }
            let oldAllow = { core.performConsentAction(.allow, binding: original) }
            let oldRetry = { core.performConsentAction(.checkStatus, binding: original) }
            var nextLease = lease
            if transition == "sdk" || transition == "aba" {
                if transition == "aba" {
                    core.logout()
                    api.syncAuthority.bind(try profileSession(ownerId: otherSyncOwner))
                    let b = try api.syncAuthority.capture(ownerId: otherSyncOwner)
                    core.accept(lifecycleContext(store, api, b))
                    await core.waitUntilIdle()
                }
                api.syncAuthority.bind(try profileSession())
                nextLease = try api.syncAuthority.capture(ownerId: syncOwner)
            }
            let locale = transition == "locale" ? "en" : "pl"
            let nextState: CareOverviewViewState
            if locale != original.locale {
                var page = overviewPage([reminderRow(serverPlantId)])
                page["verified_access_until"] = NSNull()
                let token = try await store.beginCareOverviewRead(
                    locale: locale, context: nextLease, authority: api.syncAuthority)
                let localized = try await store.finishCareOverviewRead(
                    token, snapshot: overviewSnapshot([page]), authority: api.syncAuthority)
                nextState = CareOverviewViewState(local: localized, now: fake.now, origin: .cache)
            } else {
                nextState = state
            }
            core.accept(lifecycleContext(store, api, nextLease, locale: locale, reader: { nextState }))
            await core.waitUntilIdle()
            let fresh = try XCTUnwrap(core.consentBinding(expectedOwnerId: syncOwner, locale: locale))
            XCTAssertNotEqual(original, fresh, transition)
            XCTAssertFalse(core.isCurrent(binding: original), transition)
            XCTAssertEqual(core.consentStatus(binding: original).phase, .unavailable, transition)
            XCTAssertNil(core.consentBinding(expectedOwnerId: syncOwner, locale: locale == "pl" ? "en" : "pl"))
            for enabled in [false, true] {
                core.performConsentAction(.setOptedIn(enabled), binding: fresh)
                await core.waitUntilIdle()
                XCTAssertEqual(core.optedIn, enabled, transition)
                let revision = core.revision
                let preferences = NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:])
                let permissions = fake.permissionRequests
                let adds = fake.adds.count
                let reads = fake.inventoryReads
                let removals = fake.removed
                oldToggle(!enabled)
                oldAllow()
                oldRetry()
                await core.waitUntilIdle()
                XCTAssertEqual(core.revision, revision, transition)
                XCTAssertEqual(core.optedIn, enabled, transition)
                XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:]),
                               preferences, transition)
                XCTAssertEqual(fake.permissionRequests, permissions, transition)
                XCTAssertEqual(fake.adds.count, adds, transition)
                XCTAssertEqual(fake.inventoryReads, reads, transition)
                XCTAssertEqual(fake.removed, removals, transition)
            }
            XCTAssertTrue(core.consentStatus(binding: fresh).canAllow, transition)
            let revision = core.revision
            core.performConsentAction(.checkStatus, binding: fresh)
            await core.waitUntilIdle()
            XCTAssertGreaterThan(core.revision, revision, transition)
            core.performConsentAction(.allow, binding: fresh)
            await core.waitUntilIdle()
            XCTAssertEqual(fake.permissionRequests, 1, transition)
            XCTAssertEqual(core.consentStatus(binding: fresh).phase, .unconfirmed, transition)
            core.logout()
            await core.waitUntilIdle()
        }
    }
}

#if DEBUG
extension CollectionWireTests {
    func testReminderFixtureStrictLaunchNeverFallsBackForNewFlags() throws {
        let namespace = UUID().uuidString
        let valid = ["--care-reminder-fixture", "eligible", "--care-reminder-namespace", namespace]
        guard case .fixture(let configuration) = ReminderConsentLaunch.parse(valid) else {
            return XCTFail("Valid dedicated configuration")
        }
        XCTAssertEqual(configuration.namespace, UUID(uuidString: namespace))
        XCTAssertEqual(ReminderConsentLaunch.parse(["app", "--today-fixture", "todayFuture"]), .ordinary)
        for arguments in [
            ["--care-reminder-typo"], Array(valid.dropLast()), valid + ["--care-reminder-typo"],
            valid + ["--care-reminder-fixture", "eligible"], valid + ["--care-reminder-namespace", namespace],
            valid + ["--today-fixture", "todayFuture"], valid + ["--catalogue-namespace", namespace],
            valid + ["--narat-staging-analysis"],
            ["--care-reminder-fixture", "unknown", "--care-reminder-namespace", namespace],
            ["--care-reminder-fixture", "eligible", "--care-reminder-namespace", "invalid"]
        ] { XCTAssertEqual(ReminderConsentLaunch.parse(arguments), .invalid, arguments.description) }
        for mode in ReminderConsentFixtureMode.allCases {
            guard case .fixture = ReminderConsentLaunch.parse([
                "--care-reminder-namespace", namespace, "--care-reminder-fixture", mode.rawValue])
            else { return XCTFail(mode.rawValue) }
        }
    }

    @MainActor
    func testReminderRuntimeOwnsOneInertCoreAndWeaklyForwardsRealChanges() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeCareReminderNotifications()
        let core = CareReminderLifecycle(notifications: fake, defaults: defaults,
            clock: { fake.now }, timeZone: { TimeZone(secondsFromGMT: 0)! })
        var runtime: CareReminderRuntime? = .init(core: core)
        weak var weakRuntime = runtime
        XCTAssertTrue(runtime?.core === core)
        XCTAssertNil(core.state)
        XCTAssertEqual(fake.inventoryReads, 0)
        XCTAssertTrue(fake.adds.isEmpty)
        XCTAssertEqual(fake.permissionRequests, 0)
        var publications = 0
        let subscription = runtime!.objectWillChange.sink { publications += 1 }
        core.setSceneActive(true)
        core.accept(lifecycleContext(store, api, lease))
        await core.waitUntilIdle()
        XCTAssertGreaterThan(publications, 0)
        XCTAssertTrue(runtime?.core === core)
        core.logout()
        await core.waitUntilIdle()
        runtime = nil
        XCTAssertNil(weakRuntime)
        XCTAssertEqual(fake.permissionRequests, 0)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testReminderFixtureColdLedgerIdentityIsolationAndCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("os.json"), namespace = UUID()
        let candidate = try receiptCandidate()
        let proposal = CareReminderNotificationProposal(candidate: candidate, attemptId: operationId)
        let fake = try ReminderConsentNotifications(file: file, namespace: namespace,
            mode: .eligible, owner: syncOwner, seed: receiptNow)
        try await fake.add(proposal, now: receiptNow)
        let other = try ReminderConsentNotifications(file: directory.appendingPathComponent("other.json"),
            namespace: UUID(), mode: .eligible, owner: syncOwner, seed: receiptNow)
        try await other.add(proposal, now: receiptNow)
        let cold = try ReminderConsentNotifications(file: file, namespace: namespace,
            mode: .eligible, owner: syncOwner, seed: receiptNow)
        let inventory = try await cold.inventory()
        XCTAssertEqual(inventory.pending.first?.route,
            CareReminderNotificationRoute(candidate: candidate, attemptId: operationId))
        XCTAssertEqual(cold.ledger.adds, fake.ledger.adds)
        XCTAssertEqual(cold.ledger.adds.count, 1)
        XCTAssertEqual(inventory.otherPendingCount, 1)
        XCTAssertThrowsError(try ReminderConsentNotifications(file: file, namespace: UUID(),
            mode: .eligible, owner: syncOwner, seed: receiptNow))
        XCTAssertThrowsError(try ReminderConsentNotifications(file: file, namespace: namespace,
            mode: .denied, owner: syncOwner, seed: receiptNow))
        XCTAssertThrowsError(try ReminderConsentNotifications(file: file, namespace: namespace,
            mode: .eligible, owner: otherSyncOwner, seed: receiptNow))
        try cold.advance(to: candidate.absoluteFireDate)
        let delivered = try await cold.inventory()
        XCTAssertEqual(delivered.delivered.first?.deliveredAt, candidate.absoluteFireDate)
        let identifier = try XCTUnwrap(delivered.delivered.first?.rawIdentifier)
        try await cold.removeDelivered([identifier, "narat.trial.fixture"])
        try await cold.removePending([identifier, "narat.trial.fixture"])
        let cleaned = try await cold.inventory()
        XCTAssertTrue(cleaned.delivered.isEmpty)
        XCTAssertEqual(cleaned.otherPendingCount, 1)
        XCTAssertEqual(other.ledger.pending.count, 1)
        XCTAssertFalse(cold.ledger.removedPending.contains("narat.trial.fixture"))
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try ReminderConsentNotifications(file: file, namespace: namespace,
            mode: .eligible, owner: syncOwner, seed: receiptNow))
    }

    @MainActor
    func testReminderFixtureLagStatusAndUncertainFailureEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in [ReminderConsentFixtureMode.oneReadLag, .twoReadLag, .denied, .failure] {
            let fake = try ReminderConsentNotifications(file: directory.appendingPathComponent(mode.rawValue),
                namespace: UUID(), mode: mode, owner: syncOwner, seed: receiptNow)
            try await fake.requestAuthorization()
            let first = try await fake.authorization(), second = try await fake.authorization()
            XCTAssertEqual(first, mode == .failure ? .authorized : (mode == .denied ? .denied : .notDetermined))
            XCTAssertEqual(second, mode == .oneReadLag || mode == .failure ? .authorized :
                (mode == .denied ? .denied : .notDetermined))
            let reads = fake.ledger.authReads
            try fake.setAuthorization(.authorized)
            XCTAssertEqual(fake.ledger.authReads, reads)
            let retry = try await fake.authorization()
            XCTAssertEqual(retry, .authorized)
            XCTAssertEqual(fake.ledger.promptCount, 1)
            if mode == .failure {
                do {
                    try await fake.add(.init(candidate: receiptCandidate(), attemptId: operationId), now: receiptNow)
                    XCTFail("Expected uncertain add failure")
                } catch ReminderConsentNotifications.Fault.injected {}
                let inventory = try await fake.inventory()
                XCTAssertEqual(inventory.pending.count, 1)
                XCTAssertEqual(fake.ledger.adds.count, 1)
                try fake.setFailures(add: false, inventory: true)
                do { _ = try await fake.inventory(); XCTFail("Expected inventory failure") }
                catch ReminderConsentNotifications.Fault.injected {}
            }
        }
    }

    @MainActor
    func testReminderFixtureReadinessAndExplicitReadOnlyContextColdRestore() async throws {
        try await CareReminderReadiness().wait()
        let barrier = CareReminderReadiness(held: true)
        let release = Task { @MainActor in
            XCTAssertEqual(barrier.waitingCount, 1)
            barrier.release()
        }
        try await barrier.wait()
        await release.value
        let cancelledBarrier = CareReminderReadiness(held: true)
        let waiter = Task { @MainActor in try await cancelledBarrier.wait() }
        waiter.cancel()
        do { try await waiter.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(cancelledBarrier.waitingCount, 0)
        let namespace = UUID().uuidString
        guard case .fixture(let configuration) = ReminderConsentLaunch.parse([
            "--care-reminder-fixture", "noSchedule", "--care-reminder-namespace", namespace])
        else { return XCTFail("Configuration") }
        let fixture = try await ReminderConsentFixture.makeContext(configuration)
        defer { try? fixture.cleanup() }
        XCTAssertNil(fixture.runtime.core.state)
        XCTAssertEqual(fixture.notifications.ledger.promptCount, 0)
        XCTAssertTrue(fixture.matches(context: fixture.context, connection: fixture.context.connection))
        XCTAssertEqual(fixture.context.server.snapshot.reminderCommandRequests, 0)
        XCTAssertTrue(fixture.context.server.snapshot.todayWithdrawn == true)
        XCTAssertEqual(fixture.notifications.now,
            fixture.context.server.snapshot.todayClockSeed.flatMap(SQLTimestamp.date(from:)))
        fixture.context.connection.reconcileFixtureReconnect = {}
        try fixture.restoreSchedule()
        fixture.context.shutdown()
        let cold = try await ReminderConsentFixture.makeContext(configuration)
        defer { try? cold.cleanup() }
        XCTAssertEqual(cold.context.server.snapshot.reminderScheduleRestored, true)
        XCTAssertEqual(cold.context.server.snapshot.todayWithdrawn, false)
        XCTAssertEqual(cold.notifications.now, fixture.notifications.now)
        var request = URLRequest(url: URL(string: "https://" + namespace.lowercased() + ".invalid/functions/v1/plants-api/commands")!)
        request.httpMethod = "POST"
        let (_, response) = try await cold.context.http.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertEqual(cold.context.server.snapshot.reminderCommandRequests, 1) // Deliberate rejected probe.
        XCTAssertTrue(cold.context.server.snapshot.attempts.isEmpty)
        XCTAssertGreaterThan(cold.context.server.snapshot.reminderAuthRequests ?? 0, 0)
        let authCount = cold.context.server.snapshot.reminderAuthRequests
        cold.context.shutdown()
        try Data("corrupt".utf8).write(to: cold.context.directory.appendingPathComponent("reminder-os.json"))
        do {
            let unexpected = try await ReminderConsentFixture.makeContext(configuration)
            unexpected.context.shutdown()
            XCTFail("Corrupt OS ledger must fail before SDK bootstrap")
        } catch {}
        let persisted = try JSONDecoder().decode(CatalogueFixtureServer.Ledger.self,
            from: Data(contentsOf: cold.context.directory.appendingPathComponent("server-ledger.json")))
        XCTAssertEqual(persisted.reminderAuthRequests, authCount)
    }
}
#endif

#if DEBUG
extension CollectionWireTests {
    @MainActor
    func testReminderBootstrapStrictSelectionConstructsOnlyOrdinaryRuntime() async throws {
        let suite = "BootstrapSelection." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let inert = CareReminderRuntime(core: .init(
            notifications: FakeCareReminderNotifications(), defaults: defaults,
            clock: { Date() }, timeZone: { TimeZone(secondsFromGMT: 0)! }))
        var productionCalls = 0
        var fixtureCalls = 0
        let namespace = UUID().uuidString
        let valid = ["--care-reminder-fixture", "eligible", "--care-reminder-namespace", namespace]
        let production: @MainActor () -> CareReminderRuntime = {
            productionCalls += 1
            return inert
        }
        let fixture: @MainActor (ReminderConsentLaunch.Configuration) async throws -> ReminderConsentFixture = { _ in
            fixtureCalls += 1
            throw CancellationError()
        }
        for arguments in [
            ["app"], ["app", "--today-fixture", "todayFuture"],
            ["app", "--catalogue-fixture", "collection"],
            ["app", "--narat-staging-analysis"]
        ] {
            let bootstrap = CareReminderBootstrap(arguments: arguments,
                productionFactory: production, fixtureFactory: fixture)
            guard case .ordinary(let runtime) = bootstrap.startup else {
                return XCTFail("Ordinary and legacy launches retain the ordinary runtime")
            }
            XCTAssertTrue(runtime === inert)
            await bootstrap.prepare()
        }
        XCTAssertEqual(productionCalls, 4)
        productionCalls = 0
        for arguments in [
            ["--care-reminder-unknown"], Array(valid.dropLast()),
            valid + ["--care-reminder-unknown"], valid + ["--today-fixture", "todayFuture"],
            valid + ["--catalogue-namespace", namespace], valid + ["--narat-staging-analysis"],
            valid + ["--care-reminder-fixture", "eligible"],
            ["--care-reminder-fixture", "unknown", "--care-reminder-namespace", namespace],
            ["--care-reminder-fixture", "eligible", "--care-reminder-namespace", "invalid"]
        ] {
            let bootstrap = CareReminderBootstrap(arguments: arguments,
                productionFactory: production, fixtureFactory: fixture)
            guard case .failed = bootstrap.startup else { return XCTFail(arguments.description) }
            await bootstrap.prepare()
        }
        for mode in ReminderConsentFixtureMode.allCases {
            let bootstrap = CareReminderBootstrap(arguments: [
                "--care-reminder-fixture", mode.rawValue, "--care-reminder-namespace", namespace],
                productionFactory: production, fixtureFactory: fixture)
            guard case .loading = bootstrap.startup else { return XCTFail(mode.rawValue) }
        }
        XCTAssertEqual(productionCalls, 0)
        XCTAssertEqual(fixtureCalls, 0)
        XCTAssertNil(inert.core.state)
    }

    @MainActor
    func testReminderBootstrapPublishesOneExactSDKRuntimePairAndReleasesOnlyNormalModes() async throws {
        for mode in [ReminderConsentFixtureMode.eligible, .readiness, .noSchedule] {
            var calls = 0
            var made: ReminderConsentFixture?
            let arguments = [
                "--care-reminder-fixture", mode.rawValue,
                "--care-reminder-namespace", UUID().uuidString]
            let bootstrap = CareReminderBootstrap(arguments: arguments,
                productionFactory: { fatalError("Dedicated launch must never construct System") },
                fixtureFactory: { configuration in
                    calls += 1
                    let fixture = try await ReminderConsentFixture.makeContext(configuration)
                    made = fixture
                    return fixture
                })
            guard case .loading = bootstrap.startup else { return XCTFail("Must await SDK bootstrap") }
            XCTAssertEqual(calls, 0)
            await bootstrap.prepare()
            let fixture = try XCTUnwrap(made)
            defer { try? fixture.cleanup() }
            guard case .fixture(let published) = bootstrap.startup else { return XCTFail("Pair missing") }
            XCTAssertTrue(published === fixture)
            XCTAssertTrue(published.runtime === fixture.runtime)
            XCTAssertTrue(published.runtime.core === fixture.runtime.core)
            XCTAssertTrue(published.matches(context: fixture.context, connection: fixture.context.connection))
            let registration = NativeRegistrationProbe()
            let appDelegate = CareReminderAppDelegate(arguments: arguments) { registration.install($0) }
            XCTAssertTrue(appDelegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
            XCTAssertEqual(registration.installs, 0)
            let root = RootContainerView(languageStore: LanguageStore(), analysisModel: AnalysisFlowModel(),
                careReminderRuntime: published.runtime, careReminderInbox: appDelegate.inbox,
                preloadedReminderFixture: published)
            XCTAssertTrue(root.careReminderInbox === appDelegate.inbox)
            XCTAssertTrue(root.careReminderRuntime === fixture.runtime)
            XCTAssertTrue(root.preloadedReminderFixture === fixture)
            XCTAssertNil(fixture.runtime.core.state)
            XCTAssertEqual(fixture.notifications.ledger.promptCount, 0)
            XCTAssertTrue(fixture.notifications.ledger.adds.isEmpty)
            XCTAssertEqual(fixture.context.server.snapshot.reminderCommandRequests, 0)
            if mode == .readiness {
                let release = Task { @MainActor in
                    XCTAssertEqual(fixture.runtime.readiness.waitingCount, 1)
                    fixture.runtime.readiness.release()
                }
                try await fixture.runtime.readiness.wait()
                await release.value
            } else {
                try await fixture.runtime.readiness.wait()
                XCTAssertEqual(fixture.runtime.readiness.waitingCount, 0)
            }
            await bootstrap.prepare()
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(fixture.context.server.snapshot.reminderCommandRequests, 0)
        }
    }

    @MainActor
    func testReminderBootstrapCancelledLateFactoryShutsDownWithoutPublishingOrErasingColdState() async throws {
        let arguments = ["--care-reminder-fixture", "eligible",
                         "--care-reminder-namespace", UUID().uuidString]
        guard case .fixture(let configuration) = ReminderConsentLaunch.parse(arguments)
        else { return XCTFail("Configuration") }
        let fixture = try await ReminderConsentFixture.makeContext(configuration)
        defer { try? fixture.cleanup() }
        let entered = CareReminderReadiness(held: true)
        var continuation: CheckedContinuation<ReminderConsentFixture, Never>?
        var calls = 0
        let bootstrap = CareReminderBootstrap(arguments: arguments,
            productionFactory: { fatalError("Cancelled fixture must never construct System") },
            fixtureFactory: { _ in
                calls += 1
                return await withCheckedContinuation {
                    continuation = $0
                    entered.release()
                }
            })
        let task = Task { @MainActor in await bootstrap.prepare() }
        try await entered.wait()
        guard case .loading = bootstrap.startup else { return XCTFail("No premature publication") }
        task.cancel()
        let pending = try XCTUnwrap(continuation)
        pending.resume(returning: fixture)
        await task.value
        guard case .failed = bootstrap.startup else { return XCTFail("Late pair was published") }
        XCTAssertNil(fixture.context.connection)
        XCTAssertNil(fixture.runtime.core.state)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.context.directory.appendingPathComponent("server-ledger.json").path))
        await bootstrap.prepare()
        XCTAssertEqual(calls, 1)
        let cold = try await ReminderConsentFixture.makeContext(configuration)
        defer { try? cold.cleanup() }
        XCTAssertTrue(cold.matches(context: cold.context, connection: cold.context.connection))
        XCTAssertEqual(cold.notifications.now, fixture.notifications.now)
        XCTAssertEqual(cold.context.server.snapshot.reminderCommandRequests, 0)

        let failure = CareReminderBootstrap(arguments: arguments,
            productionFactory: { fatalError("Failure must never construct System") },
            fixtureFactory: { _ in throw CancellationError() })
        await failure.prepare()
        guard case .failed = failure.startup else { return XCTFail("Failed factory must fail closed") }
    }
}
#endif


extension CollectionWireTests {
    func testConsentOffRequiresVerifiedCleanupMatrix() {
        let results: [CareReminderScheduler.Result?] = [nil,
            .init(confirmedPendingCount: 0, omittedCount: 0, unconfirmedBlockers: 0, failed: true, deferred: false),
            .init(confirmedPendingCount: 0, omittedCount: 0, unconfirmedBlockers: 0, failed: false, deferred: true),
            .init(confirmedPendingCount: 0, omittedCount: 0, unconfirmedBlockers: 1, failed: false, deferred: false),
            .init(confirmedPendingCount: 1, omittedCount: 0, unconfirmedBlockers: 0, failed: false, deferred: false),
            .init(confirmedPendingCount: 0, omittedCount: 0, unconfirmedBlockers: 0, failed: false, deferred: false),
            .init(confirmedPendingCount: 0, omittedCount: 3, unconfirmedBlockers: 0, failed: false, deferred: false)]
        for (index, result) in results.enumerated() {
            let status = consentProjection(nil, result: result, optedIn: false)
            XCTAssertEqual(status.phase, index >= 5 ? .off : .stopping)
            XCTAssertEqual(status.readbackWarning, index < 5)
            XCTAssertFalse(status.canAllow)
            XCTAssertEqual(status.confirmedPendingCount, 0)
            let stale = consentProjection(nil, result: result, current: false, optedIn: false)
            XCTAssertEqual(stale.phase, .unavailable)
            XCTAssertFalse(stale.readbackWarning)
            XCTAssertEqual(stale.confirmedPendingCount, 0)
        }
        let zero = results[5]
        XCTAssertEqual(consentProjection(nil, result: zero, reading: true, optedIn: false).phase, .stopping)
        XCTAssertEqual(consentProjection(nil, result: zero, optedIn: false, readFailed: true).phase, .stopping)
    }

    @MainActor
    func testConsentOffCleanupFailurePersistsPreferenceUntilExplicitRetry() async throws {
        let (url, store, api, lease, _) = try await overviewRepositoryFixture(CatalogueTransport([]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
        let state = try passState(local)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = CareReminderLifecycle.preferenceKey(ownerId: syncOwner)
        defaults.set(true, forKey: key)
        let fake = FakeCareReminderNotifications()
        let core = CareReminderLifecycle(notifications: fake, defaults: defaults,
            clock: { fake.now }, timeZone: { TimeZone(secondsFromGMT: 0)! })
        core.setSceneActive(true)
        core.accept(lifecycleContext(store, api, lease, reader: { state }))
        await core.waitUntilIdle()
        let binding = try XCTUnwrap(core.consentBinding(expectedOwnerId: syncOwner, locale: "pl"))
        XCTAssertEqual(fake.pending.count, 1)
        XCTAssertEqual(core.consentStatus(binding: binding).phase, .confirmed)
        fake.failInventory = true
        core.performConsentAction(.setOptedIn(false), binding: binding)
        XCTAssertFalse(defaults.bool(forKey: key))
        XCTAssertEqual(core.consentStatus(binding: binding).phase, .stopping)
        await core.waitUntilIdle()
        XCTAssertFalse(core.optedIn)
        XCTAssertEqual(fake.pending.count, 1)
        XCTAssertEqual(core.result?.failed, true)
        XCTAssertEqual(core.consentStatus(binding: binding).phase, .stopping)
        XCTAssertTrue(core.consentStatus(binding: binding).readbackWarning)
        let reads = fake.inventoryReads
        let adds = fake.adds.count
        fake.failInventory = false // An external OS change is not a Core trigger.
        await core.waitUntilIdle()
        XCTAssertEqual(fake.inventoryReads, reads)
        XCTAssertEqual(fake.pending.count, 1)
        XCTAssertEqual(core.consentStatus(binding: binding).phase, .stopping)
        core.performConsentAction(.checkStatus, binding: binding)
        await core.waitUntilIdle()
        XCTAssertGreaterThan(fake.inventoryReads, reads)
        XCTAssertTrue(fake.pending.isEmpty)
        XCTAssertEqual(fake.adds.count, adds)
        XCTAssertFalse(defaults.bool(forKey: key))
        XCTAssertEqual(core.consentStatus(binding: binding).phase, .off)
        XCTAssertFalse(core.consentStatus(binding: binding).readbackWarning)
        XCTAssertEqual(fake.otherPendingCount, 1)
        XCTAssertEqual(fake.permissionRequests, 0)
        core.logout()
        await core.waitUntilIdle()
    }
}

#if DEBUG
extension CollectionWireTests {

    @MainActor
    func testConsentFixtureLegacyColdEvidenceAndExplicitRetryMarkers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("os.json"), namespace = UUID()
        let fake = try ReminderConsentNotifications(file: file, namespace: namespace,
            mode: .eligible, owner: syncOwner, seed: receiptNow)
        let proposal = CareReminderNotificationProposal(candidate: try receiptCandidate(), attemptId: UUID())
        try await fake.add(proposal, now: receiptNow)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fake.ledger)) as? [String: Any])
        for key in ["initialPending", "initialDelivered", "events", "markers"] { old.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: old).write(to: file)
        let cold = try ReminderConsentNotifications(file: file, namespace: namespace,
            mode: .eligible, owner: syncOwner, seed: receiptNow)
        XCTAssertEqual(cold.ledger.initialPending, fake.ledger.pending)
        XCTAssertEqual(cold.ledger.events?.count, 0)
        try cold.setFailures(add: false, inventory: true)
        try cold.setFailures(add: false, inventory: false)
        try cold.setAuthorization(.authorized)
        try cold.markRetry()
        XCTAssertEqual(cold.ledger.markers?.map(\.kind), [.failures, .failures, .authorization, .retry])
        XCTAssertTrue(cold.ledger.markers!.allSatisfy { $0.authReads == 0 && $0.inventoryReads == 0 })
        do {
            try await cold.add(.init(candidate: proposal.candidate, attemptId: UUID()), now: receiptNow)
            XCTFail("Duplicate pending identifier must be rejected")
        } catch ReminderConsentNotifications.Fault.corrupt {}
        try await cold.removePending(cold.ledger.pending.map(\.identifier))
        let latest = CareReminderNotificationProposal(candidate: proposal.candidate, attemptId: UUID())
        try await cold.add(latest, now: receiptNow)
        let reopened = try ReminderConsentNotifications(file: file, namespace: namespace,
            mode: .eligible, owner: syncOwner, seed: receiptNow)
        XCTAssertEqual(reopened.ledger.events?.map(\.kind), [.removePending, .add])
        XCTAssertEqual(reopened.ledger.pending.first?.route?.attemptId, latest.attemptId)
        XCTAssertEqual(reopened.ledger.otherPending, ["narat.trial.fixture"])
        var corrupt = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reopened.ledger)) as? [String: Any])
        corrupt["events"] = [["kind": "removePending", "wires": [], "identifiers": ["narat.trial.fixture"]]]
        try JSONSerialization.data(withJSONObject: corrupt).write(to: file)
        XCTAssertThrowsError(try ReminderConsentNotifications(file: file, namespace: namespace,
            mode: .eligible, owner: syncOwner, seed: receiptNow))
    }
}
#endif

extension CollectionWireTests {
    /// A real manual fact plus already enabled care: neither proves a subsequent command.
    private func careAckPage(entry: UUID, state: String = "active",
                             reversal: UUID? = nil, operation: UUID? = nil, corrected: Bool = false, at: String? = nil) throws -> String {
        var page = syncObject()
        page["until"] = at ?? syncUntil
        page["next_since"] = at ?? syncUntil
        var plant = syncChange(at, id: serverPlantId.uuidString)
        plant["data"] = ["id": serverPlantId.uuidString, "revision": 1, "care_revision": 1]
        var fact = syncChange(at, id: entry.uuidString, entity: "care_entries")
        fact["data"] = ["id": entry.uuidString, "plant_id": serverPlantId.uuidString,
            "state": state, "action_code": "water", "timezone": "Europe/Moscow",
            "occurred_at": corrected ? "2026-11-02T08:30:00+03:00" : "2026-11-03T08:30:00+03:00",
            "occurred_local_date": corrected ? "2026-11-02" : "2026-11-03"]
        var membership = syncChange(at, id: serverPlantId.uuidString, entity: "basic_care_memberships")
        membership["data"] = ["plant_id": serverPlantId.uuidString, "enabled": true, "enabled_at": syncUntil]
        var changes = [plant, fact, membership]
        if let reversal, let operation {
            var row = syncChange(at, id: reversal.uuidString, entity: "care_reversals")
            row["data"] = ["id": reversal.uuidString, "entry_id": entry.uuidString,
                           "operation_id": operation.uuidString]
            changes.append(row)
        }
        page["changes"] = changes.sorted { ($0["entity_type"] as! String) < ($1["entity_type"] as! String) }
        return try syncJSON(page)
    }

    @MainActor
    func testCareEditExactProofSurvivesLostAckAndCanonicalFailure() async throws {
        for undo in [false, true] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let entry = UUID(), reversal = UUID()
            let action: ManualWateringAction = undo ? .undo(entry) : .correctDate(
                entryId: entry, occurredAt: "2026-11-02T08:30:00+03:00", timezone: "Europe/Moscow")
            let command = try action.envelope(plantId: serverPlantId)
            let later = "2026-11-03T09:10:00Z"
            var acceptedReceipt = manualWateringReceipt(
                entryId: entry, state: undo ? "voided" : "active", reversalId: undo ? reversal : nil)
            acceptedReceipt["watermark"] = later
            let receipt = try syncJSON(acceptedReceipt)
            let transport = CatalogueTransport([
                .http(200, try careAckPage(entry: entry)), .network,
                .http(200, receipt), .network,
                .http(200, receipt), .http(200, try careAckPage(entry: entry,
                    state: undo ? "voided" : "active", reversal: undo ? reversal : nil,
                    operation: command.operationId, corrected: true, at: later))
            ])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            var store = LocalStore(modelContainer: try diskContainer(url))
            _ = try await SyncEngine(store: store, apiClient: api).pullDelta(for: syncOwner)
            try await store.enqueueManualWatering(command, context: lease, authority: api.syncAuthority)
            for _ in 0..<2 {
                // New engine/container on each attempt: proof cannot be an actor-global cache.
                store = LocalStore(modelContainer: try diskContainer(url))
                let repo = CollectionRepository(store: store, apiClient: api,
                    syncEngine: SyncEngine(store: store, apiClient: api))
                let outcome = try await repo.retryWateringEdit(command, context: lease)
                XCTAssertEqual(outcome, .unconfirmed)
                let pending = try await repo.pendingManualWatering(plantId: serverPlantId, context: lease)
                XCTAssertEqual(pending, command)
            }
            let repo = CollectionRepository(store: store, apiClient: api,
                syncEngine: SyncEngine(store: store, apiClient: api))
            let confirmed = try await repo.retryWateringEdit(command, context: lease)
            XCTAssertEqual(confirmed, .confirmed)
            let history = try await repo.collectionWateringHistory(plantId: serverPlantId, context: lease)
            XCTAssertEqual(history.map(\.occurredLocalDate), ["2026-11-02"])
            let again = try await repo.retryWateringEdit(command, context: lease)
            XCTAssertEqual(again, .unconfirmed, "An absent operation is not a fresh ACK")
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "POST", "GET", "POST", "GET"])
            let posts = requests.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(posts.count, 3)
            XCTAssertTrue(posts.allSatisfy { $0.httpBody == posts.first?.httpBody })
            XCTAssertTrue(posts.allSatisfy {
                $0.value(forHTTPHeaderField: "X-Operation-Id") == command.operationId.uuidString.lowercased()
            })
        }
    }

    @MainActor
    func testCareEditTracksTargetInsteadOfPredecessorCountOrRejectedDequeue() async throws {
        for predecessorAccepted in [false, true] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let entry = UUID()
            let rejected = try syncJSON(["error": [
                "code": "CONFLICT", "message": "Fixture rejection", "retryable": false]])
            let enabled = try syncJSON(["plant_id": serverPlantId.uuidString,
                                        "enabled": true, "enabled_at": syncUntil] as [String: Any])
            let page = try careAckPage(entry: entry)
            let replies: [CatalogueTransport.Reply] = predecessorAccepted
                ? [.http(200, page), .http(200, enabled), .http(200, try careReconcilePage(syncUntil)),
                   .http(409, rejected), .http(200, try careReconcilePage(syncUntil))]
                : [.http(200, page), .network]
            let transport = CatalogueTransport(replies)
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let engine = SyncEngine(store: store, apiClient: api)
            _ = try await engine.pullDelta(for: syncOwner)
            let predecessor = try await store.enqueueBasicCareEnable(
                plantId: serverPlantId, context: lease, authority: api.syncAuthority)
            let command = try ManualWateringAction.undo(entry).envelope(plantId: serverPlantId)
            try await store.enqueueCollectionWateringUndo(command, context: lease, authority: api.syncAuthority)
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
            let outcome = try await repo.retryWateringEdit(command, context: lease)
            XCTAssertEqual(outcome, .unconfirmed)
            let pending = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(pending.map(\.operationId),
                           predecessorAccepted ? [] : [predecessor.operationId, command.operationId])
            let posts = await transport.capturedRequests().filter { $0.httpMethod == "POST" }
            let sent = try posts.map { try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap($0.httpBody)) }
            XCTAssertEqual(sent, predecessorAccepted ? [predecessor, command] : [predecessor])
        }
    }

    @MainActor
    func testCareBasicEnableDoesNotConfirmPreexistingMembershipAfterRejection() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rejection = try syncJSON(["error": [
            "code": "FORBIDDEN", "message": "Fixture rejection", "retryable": false]])
        let transport = CatalogueTransport([.http(200, try careAckPage(entry: UUID())), .http(403, rejection)])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let engine = SyncEngine(store: store, apiClient: api)
        _ = try await engine.pullDelta(for: syncOwner)
        let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
        let outcome = try await repo.enableBasicCare(plantId: serverPlantId, context: lease)
        XCTAssertEqual(outcome, .unconfirmed)
        let state = try await repo.basicCareEnableState(plantId: serverPlantId, context: lease)
        XCTAssertTrue(state.enabled)
        XCTAssertFalse(state.pending)
    }

    @MainActor
    func testCareEditReceiptCannotConfirmAcrossOwnerSwitchOrABA() async throws {
        for returnToOriginal in [false, true] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let entry = UUID()
            let seedAPI = client(CatalogueTransport([.http(200, try careAckPage(entry: entry))]))
            await seedAPI.bindSyncSession(syncSession)
            let store = LocalStore(modelContainer: try diskContainer(url))
            _ = try await SyncEngine(store: store, apiClient: seedAPI).pullDelta(for: syncOwner)
            let command = try ManualWateringAction.correctDate(entryId: entry,
                occurredAt: "2026-11-02T08:30:00+03:00", timezone: "Europe/Moscow").envelope(plantId: serverPlantId)
            let transport = SuspendedCollectionTransport(try syncJSON(manualWateringReceipt(entryId: entry, state: "active")))
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            try await store.enqueueManualWatering(command, context: lease, authority: api.syncAuthority)
            let before = try await store.pendingOutboxEntries(for: syncOwner)
            let repo = CollectionRepository(store: store, apiClient: api,
                syncEngine: SyncEngine(store: store, apiClient: api))
            let attempt = Task { try await repo.retryWateringEdit(command, context: lease) }
            await transport.waitForRequest()
            await api.bindSyncSession(NativeAuthSession(userId: otherSyncOwner,
                accessToken: "owner-b-token", expiresAt: .distantFuture))
            if returnToOriginal { await api.bindSyncSession(syncSession) }
            await transport.resume()
            do {
                _ = try await attempt.value
                XCTFail("Stale receipt must not produce positive care proof")
            } catch SyncWireValidationError.invalidSession {}
            let after = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(after, before)
        }
    }
}

#if DEBUG
extension CollectionWireTests {
    @MainActor
    func testConsentRetryReadPolicyUsesActualAlignmentAndCareDataFailures() async throws {
        let (url, store, authority, lease, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for mode in ["", "offline", "readOnly", "unknown", "invalidated", "denied", "revalidate", "profile.update"] {
            let state = try reminderState(local, rows: [overviewRow(serverPlantId, dated: true)], mode: mode)
            XCTAssertEqual(ReminderConsentReadPolicy.needsExternalRead(state: state, readFailed: false),
                           !["", "offline"].contains(mode), mode)
        }
        let aligned = try passState(local)
        for authorization in [CareReminderPlan.Authorization.notDetermined, .denied, .authorized] {
            let status = consentProjection(aligned,
                result: .init(confirmedPendingCount: 0, omittedCount: 0, unconfirmedBlockers: 1,
                              failed: true, deferred: false), authorization: authorization)
            XCTAssertTrue([.failed, .denied, .paused].contains(status.phase))
            XCTAssertFalse(ReminderConsentReadPolicy.needsExternalRead(state: aligned, readFailed: false))
        }
        XCTAssertTrue(ReminderConsentReadPolicy.needsExternalRead(state: nil, readFailed: false))
        XCTAssertTrue(ReminderConsentReadPolicy.needsExternalRead(state: aligned, readFailed: true))
        try await overviewCanonical(store, authority: authority, lease: lease, ids: [])
        let rotated = try await store.readCareOverviewPresentation(context: lease, authority: authority)
        let stale = CareOverviewViewState(local: rotated, now: receiptNow, origin: .cache)
        XCTAssertEqual(stale.availability, .readOnly)
        XCTAssertTrue(ReminderConsentReadPolicy.needsExternalRead(state: stale, readFailed: false))
    }

    @MainActor
    func testConsentHourFixtureExactProfileReplayAndCanonicalWireCoherence() async throws {
        guard case .fixture(let configuration) = ReminderConsentLaunch.parse([
            "--care-reminder-fixture", "hour", "--care-reminder-namespace", UUID().uuidString])
        else { return XCTFail("hour configuration") }
        let fixture = try await ReminderConsentFixture.makeContext(configuration)
        defer { try? fixture.cleanup() }
        let connection = fixture.context.connection!
        let api = try XCTUnwrap(connection.apiClient)
        let store = try XCTUnwrap(connection.store)
        let repo = try XCTUnwrap(connection.repository)
        let owner = fixture.context.server.snapshot.permanent
        let lease = try await api.captureSyncContext(ownerId: owner)
        let initial = try await api.fetchProfileSettings(context: lease)
        XCTAssertEqual(initial.reminderHourLocal, 9)
        let overview = try await api.fetchCareOverview(context: lease)
        XCTAssertEqual(overview.pages.first?.reminderHourLocal, 9)
        let initialSync = try await api.fetchSyncPage(context: lease, since: nil, until: nil, cursor: nil, limit: 200)
        XCTAssertEqual(initialSync.page.profile.reminderHourLocal, 9)
        let before = fixture.context.server.snapshot
        let command = try await repo.enqueueProfileReminderHour(reminderHourLocal: 23, context: lease)
        let lost = try await repo.retryProfileReminderHour(command, context: lease)
        XCTAssertEqual(lost, .pending)
        let pending = try await repo.pendingProfileReminderHour(context: lease)
        XCTAssertEqual(pending?.envelope, command.envelope)
        let confirmed = try await repo.retryProfileReminderHour(command, context: lease)
        XCTAssertEqual(confirmed, .confirmed(hour: 23))
        let saved = try await store.syncedProfile(ownerId: owner)
        XCTAssertEqual(saved?.reminderHourLocal, 23)
        let absent = try await repo.pendingProfileReminderHour(context: lease)
        XCTAssertNil(absent)
        let me = try await api.fetchProfileSettings(context: lease)
        let afterOverview = try await api.fetchCareOverview(context: lease)
        XCTAssertEqual(me.reminderHourLocal, 23)
        XCTAssertEqual(afterOverview.pages.first?.reminderHourLocal, 23)
        let finalSync = try await api.fetchSyncPage(context: lease, since: nil, until: nil, cursor: nil, limit: 200)
        XCTAssertEqual(finalSync.page.profile.reminderHourLocal, 23)
        XCTAssertEqual(finalSync.page.changes, initialSync.page.changes)
        let after = fixture.context.server.snapshot
        XCTAssertEqual(after.tick, before.tick + 1)
        XCTAssertEqual(after.commits.count, 1)
        XCTAssertEqual(after.attempts.count, 2)
        XCTAssertEqual(after.attempts[0].body, after.attempts[1].body)
        XCTAssertEqual(after.plants.map(\.id), before.plants.map(\.id))
        let commands = fixture.context.server.requests.filter { $0.url?.lastPathComponent == "commands" }
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].value(forHTTPHeaderField: "X-Operation-Id"),
                       command.envelope.operationId.uuidString.lowercased())
        // Same-operation replay remains idempotent in hour mode, including after ACK.
        let replay = try await api.updateProfileReminderHour(command, context: lease)
        XCTAssertEqual(replay.profile.reminderHourLocal, 23)
        var probe = try XCTUnwrap(commands.first)
        for body in [
            Data("{}".utf8),
            try JSONEncoder().encode(CommandEnvelopeDTO(operationId: UUID(), commandName: "care.record", payloadJSON: "{}")),
            try JSONEncoder().encode(CommandEnvelopeDTO(operationId: UUID(), commandName: "plant.create", payloadJSON: "{}"))
        ] {
            probe.httpBody = body
            if let envelope = try? JSONDecoder().decode(CommandEnvelopeDTO.self, from: body) {
                probe.setValue(envelope.operationId.uuidString.lowercased(), forHTTPHeaderField: "X-Operation-Id")
            }
            let (_, response) = try await fixture.context.http.data(for: probe)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        }
        probe = commands[0]
        for mutation in 0..<3 {
            var invalid = probe
            if mutation == 0 { invalid.setValue(UUID().uuidString, forHTTPHeaderField: "X-Operation-Id") }
            if mutation == 1 { invalid.url = URL(string: probe.url!.absoluteString + "?limit=1") }
            if mutation == 2 { invalid.setValue("Bearer foreign", forHTTPHeaderField: "Authorization") }
            let (_, response) = try await fixture.context.http.data(for: invalid)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        }
        XCTAssertEqual(fixture.context.server.snapshot.commits.count, 1)
        XCTAssertEqual(fixture.context.server.snapshot.attempts.count, 3)
        for mode in ReminderConsentFixtureMode.allCases where mode != .hour {
            guard case .fixture(let config) = ReminderConsentLaunch.parse([
                "--care-reminder-fixture", mode.rawValue, "--care-reminder-namespace", UUID().uuidString])
            else { return XCTFail(mode.rawValue) }
            let other = try await ReminderConsentFixture.makeContext(config)
            defer { try? other.cleanup() }
            probe.url = URL(string: "https://" + other.context.namespace + ".invalid/functions/v1/plants-api/commands")
            probe.setValue(other.context.namespace, forHTTPHeaderField: "X-Catalogue-Fixture-Namespace")
            probe.httpBody = try JSONEncoder().encode(command.envelope)
            let (_, response) = try await other.context.http.data(for: probe)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
            XCTAssertTrue(other.context.server.snapshot.commits.isEmpty)
        }
    }

    @MainActor
    func testConsentPassiveSnapshotBeforeBindingAndColdValidation() async throws {
        guard case .fixture(let configuration) = ReminderConsentLaunch.parse([
            "--care-reminder-fixture", "readiness", "--care-reminder-namespace", UUID().uuidString])
        else { return XCTFail("readiness configuration") }
        let fixture = try await ReminderConsentFixture.makeContext(configuration)
        defer { try? fixture.cleanup() }
        let api = try XCTUnwrap(fixture.context.connection.apiClient)
        let lease = try await api.captureSyncContext(ownerId: fixture.notifications.ledger.owner)
        _ = try await api.fetchCareOverview(context: lease)
        _ = try await fixture.notifications.authorization()
        _ = try await fixture.notifications.inventory()
        try await fixture.notifications.requestAuthorization()
        let before = try JSONEncoder().encode(fixture.notifications.ledger)
        let requests = fixture.context.server.requests.count
        try fixture.snapshotEvidence()
        let marker = try XCTUnwrap(fixture.notifications.ledger.markers?.last)
        XCTAssertEqual(marker.kind, .snapshot)
        XCTAssertEqual(marker.overviewReads, fixture.context.server.snapshot.overviewRequests)
        XCTAssertEqual(marker.addsCount, 0)
        XCTAssertEqual(marker.pendingCount, 0)
        XCTAssertEqual(marker.promptCount, 1)
        XCTAssertEqual(marker.authReads, 1)
        XCTAssertEqual(marker.inventoryReads, 1)
        XCTAssertNil(fixture.runtime.core.state)
        XCTAssertEqual(fixture.context.server.requests.count, requests)
        var original = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        var observed = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(fixture.notifications.ledger)) as? [String: Any])
        original.removeValue(forKey: "markers"); observed.removeValue(forKey: "markers")
        XCTAssertEqual(NSDictionary(dictionary: observed), NSDictionary(dictionary: original))
        fixture.context.shutdown()
        let cold = try await ReminderConsentFixture.makeContext(configuration)
        defer { try? cold.cleanup() }
        XCTAssertEqual(cold.notifications.ledger.markers?.last?.kind, .snapshot)
        let file = cold.context.directory.appendingPathComponent("reminder-os.json")
        var corrupt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        corrupt["markers"] = [["kind": "snapshot", "authReads": 0, "inventoryReads": 0,
                               "overviewReads": -1, "addsCount": 0, "promptCount": 0, "pendingCount": 0]]
        try JSONSerialization.data(withJSONObject: corrupt).write(to: file)
        XCTAssertThrowsError(try ReminderConsentNotifications(file: file, namespace: configuration.namespace,
            mode: .readiness, owner: cold.notifications.ledger.owner, seed: cold.notifications.ledger.seed))
    }
}
#endif

extension CollectionWireTests {
    @MainActor
    func testPostSaveTypedAcceptanceRequiresTargetReceiptAndReplaysDurableIntent() async throws {
        for undo in [false, true] {
            for mode in ["accepted", "rejected", "lost", "canonical", "blocked"] {
                let url = try diskURL()
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let create = createCommand(), entry = UUID(), reversal = UUID()
                _ = try await seedEngineCreate(url, command: create)
                let command = try (undo ? ManualWateringAction.undo(entry) : .record).envelope(plantId: serverPlantId)
                let later = "2026-11-03T09:10:00Z"
                var receipt = manualWateringReceipt(entryId: entry, state: undo ? "voided" : "active",
                                                   reversalId: undo ? reversal : nil)
                receipt["watermark"] = later
                let page = try careAckPage(entry: entry, state: undo ? "voided" : "active",
                    reversal: undo ? reversal : nil, operation: command.operationId, at: later)
                var canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.utf8)) as? [String: Any])
                var rows = try XCTUnwrap(canonical["changes"] as? [[String: Any]])
                if !undo {
                    let index = try XCTUnwrap(rows.firstIndex { $0["entity_type"] as? String == "care_entries" })
                    var fact = try XCTUnwrap(rows[index]["data"] as? [String: Any])
                    fact["operation_id"] = command.operationId.uuidString
                    rows[index]["data"] = fact
                }
                canonical["changes"] = rows
                let success: [CatalogueTransport.Reply] = [
                    .http(200, try syncJSON(receipt)), .http(200, try syncJSON(canonical))]
                let rejected = try syncJSON(["error": ["code": "CONFLICT",
                    "message": "Fixture rejection", "retryable": false]])
                var replies: [CatalogueTransport.Reply] = [.http(200, try careAckPage(entry: entry))]
                if mode == "rejected" {
                    // An accepted predecessor cannot prove the rejected target.
                    replies += [.http(200, try syncJSON(["plant_id": serverPlantId.uuidString,
                        "enabled": true, "enabled_at": syncUntil] as [String: Any])),
                        .http(200, try careReconcilePage(syncUntil)), .http(409, rejected)]
                    if undo { replies += [.http(200, try careReconcilePage(syncUntil))] }
                } else if mode == "canonical" { replies += [.http(200, try syncJSON(receipt)), .network] }
                else if mode == "accepted" { replies += success }
                else { replies += [.network] }
                if mode != "accepted" && mode != "blocked" && !(mode == "rejected" && undo) {
                    replies += success
                }
                let transport = CatalogueTransport(replies), api = client(transport)
                await api.bindSyncSession(syncSession)
                let lease = try await api.captureSyncContext(ownerId: syncOwner)
                var store = LocalStore(modelContainer: try diskContainer(url))
                try await store.acknowledgeCatalogueCreate(
                    create, receipt: decodedCreateReceipt(), context: lease, authority: api.syncAuthority)
                let saved = try await store.catalogueCreateConfirmation(ownerId: syncOwner, operationId: create.operationId)
                let confirmation = try XCTUnwrap(saved)
                var engine = SyncEngine(store: store, apiClient: api)
                _ = try await engine.pullDelta(for: syncOwner)
                var predecessor: CommandEnvelopeDTO?
                if mode == "rejected" || mode == "blocked" {
                    predecessor = try await store.enqueueBasicCareEnable(
                        plantId: serverPlantId, context: lease, authority: api.syncAuthority)
                }
                let repo = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
                let outcome = try await repo.submitManualWateringAcceptance(command, confirmation: confirmation, context: lease)
                XCTAssertEqual(outcome, mode == "accepted" ? .confirmed : .unconfirmed, mode)
                let pending = try await store.pendingOutboxEntries(for: syncOwner)
                let dequeued = mode == "accepted" || (mode == "rejected" && undo)
                XCTAssertEqual(pending.map(\.envelope), dequeued ? [] :
                    (mode == "blocked" ? [try XCTUnwrap(predecessor), command] : [command]), mode)
                if mode == "rejected" && !undo {
                    XCTAssertTrue(PersistedWateringRejection.requiresReview(try XCTUnwrap(pending.first)))
                }
                if !dequeued && mode != "blocked" {
                    store = LocalStore(modelContainer: try diskContainer(url))
                    engine = SyncEngine(store: store, apiClient: api)
                    let reopened = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
                    let replay = try await reopened.submitManualWateringAcceptance(
                        command, confirmation: confirmation, context: lease)
                    XCTAssertEqual(replay, .confirmed, mode)
                    let remaining = try await store.pendingOutboxEntries(for: syncOwner)
                    XCTAssertTrue(remaining.isEmpty)
                }
                let posts = await transport.capturedRequests().filter { $0.httpMethod == "POST" }
                let sent = try posts.map { try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap($0.httpBody)) }
                let targetAttempts = dequeued ? 1 : (mode == "blocked" ? 0 : 2)
                XCTAssertEqual(sent, (predecessor.map { [$0] } ?? []) + Array(repeating: command, count: targetAttempts))
            }
        }
    }

    @MainActor
    func testCareDrainFullEnvelopeProofRejectsWrongBodyUnrelatedAckAndQueueAbsence() async throws {
        for wrongBody in [false, true] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let entry = UUID(), reversal = UUID()
            let command = try ManualWateringAction.undo(entry).envelope(plantId: serverPlantId)
            let other = try ManualWateringAction.undo(UUID()).envelope(plantId: serverPlantId)
            let tracked = CommandEnvelopeDTO(operationId: wrongBody ? command.operationId : UUID(),
                commandName: command.commandName, plantId: command.plantId,
                payloadJSON: wrongBody ? other.payloadJSON : command.payloadJSON)
            let later = "2026-11-03T09:10:00Z"
            var receipt = manualWateringReceipt(entryId: entry, state: "voided", reversalId: reversal)
            receipt["watermark"] = later
            let transport = CatalogueTransport([.http(200, try careAckPage(entry: entry)),
                .http(200, try syncJSON(receipt)),
                .http(200, try careAckPage(entry: entry, state: "voided", reversal: reversal,
                    operation: command.operationId, at: later))])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let engine = SyncEngine(store: store, apiClient: api)
            _ = try await engine.pullDelta(for: syncOwner)
            try await store.enqueueManualWatering(command, context: lease, authority: api.syncAuthority)
            let mismatch = try await engine.flushCareOperation(tracked, context: lease)
            XCTAssertFalse(mismatch)
            let pending = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertTrue(pending.isEmpty, "The actual envelope was accepted")
            let absent = try await engine.flushCareOperation(command, context: lease)
            XCTAssertFalse(absent, "An old canonical reversal is not a new target receipt")
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET"])
        }
    }
}

extension CollectionWireTests {
    @MainActor
    func testPostSaveTypedAcceptanceRejectsForgedConfirmationBodyAndStaleLease() async throws {
        for aba in [false, true] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let create = createCommand()
            _ = try await seedEngineCreate(url, command: create)
            let transport = CatalogueTransport([]), api = client(transport)
            await api.bindSyncSession(syncSession)
            let lease = try await api.captureSyncContext(ownerId: syncOwner)
            let store = LocalStore(modelContainer: try diskContainer(url))
            try await store.acknowledgeCatalogueCreate(
                create, receipt: decodedCreateReceipt(), context: lease, authority: api.syncAuthority)
            let saved = try await store.catalogueCreateConfirmation(ownerId: syncOwner, operationId: create.operationId)
            let confirmation = try XCTUnwrap(saved)
            let repo = CollectionRepository(store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api))
            let command = try ManualWateringAction.record.envelope(plantId: serverPlantId)
            let forged = CatalogueCreateConfirmationSnapshot(ownerId: confirmation.ownerId,
                operationId: confirmation.operationId, payloadJSON: confirmation.payloadJSON + " ", receipt: confirmation.receipt)
            do {
                _ = try await repo.submitManualWateringAcceptance(command, confirmation: forged, context: lease)
                XCTFail("Only the exact durable create confirmation authorizes enqueue")
            } catch SyncWireValidationError.invalidSession {}
            try await store.enqueueManualWatering(command, context: lease, authority: api.syncAuthority)
            let wrong = CommandEnvelopeDTO(operationId: command.operationId, commandName: command.commandName,
                plantId: command.plantId, payloadJSON: command.payloadJSON + " ")
            do {
                _ = try await repo.submitManualWateringAcceptance(wrong, confirmation: confirmation, context: lease)
                XCTFail("The same UUID cannot replace the frozen full body")
            } catch OutboxEnqueueError.operationIdentityMismatch {}
            await api.bindSyncSession(NativeAuthSession(userId: otherSyncOwner, accessToken: "other", expiresAt: .distantFuture))
            if aba { await api.bindSyncSession(syncSession) }
            do {
                _ = try await repo.submitManualWateringAcceptance(command, confirmation: confirmation, context: lease)
                XCTFail("A stale original lease cannot confirm")
            } catch SyncWireValidationError.invalidSession {}
            let pending = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(pending.map(\.envelope), [command])
            let requests = await transport.capturedRequests()
            XCTAssertTrue(requests.isEmpty)
        }
    }
}


extension CollectionWireTests {
    @MainActor
    func testProductionSaveCompletionRepairsEarlyOverviewAfterLateCanonicalSettlement() async throws {
        for failDetails in [false, true] {
            var sync = overviewAlignmentPage()
            var rows = try XCTUnwrap(sync["changes"] as? [[String: Any]])
            var data = try XCTUnwrap(rows[0]["data"] as? [String: Any])
            data["plant_id"] = "fixture-fern"
            rows[0]["data"] = data
            sync["changes"] = rows
            var overview = overviewPage([reminderRow(serverPlantId)])
            overview["verified_access_until"] = NSNull()
            let body = try syncJSON(overview)
            let transport = CatalogueTransport([
                .http(200, try syncJSON(sync)), .http(200, receiptJSON()),
                .held(failDetails ? 503 : 200, try syncJSON(sync)),
                .http(200, body), .http(200, body)
            ])
            let (url, store, api, lease, repo) = try await overviewRepositoryFixture(transport, seed: false)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let target = try await CatalogueSaveModel(
                store: store, apiClient: api, repository: repo, flowId: UUID(), operationId: UUID(),
                input: CatalogueInput(speciesSlug: "fixture-fern", personalName: nil),
                session: try profileSession(), isAnonymous: false)
            var finalRead: Task<CareOverviewViewState, Error>?
            let done = CatalogueSaveCompletion(isCurrent: { true }, publish: {
                finalRead = Task { try await repo.refreshCareOverview(locale: .pl, context: lease) }
            })
            let saving = Task { await target.save(completion: done) }
            await transport.waitForHeld()
            guard case .saved = target.state else { return XCTFail("Actual create ACK required") }
            XCTAssertNil(finalRead)
            let early = try await repo.refreshCareOverview(locale: .pl, context: lease)
            XCTAssertEqual(early.availability, .available)
            XCTAssertFalse(reminderPlan(early).candidates.isEmpty)
            let before = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
            await transport.releaseHeld()
            await saving.value
            let finalTask = try XCTUnwrap(finalRead)
            let fresh = try await finalTask.value
            XCTAssertEqual(fresh.origin, .network)
            XCTAssertNil(fresh.failure)
            XCTAssertEqual(fresh.availability, .available)
            let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
            XCTAssertEqual(local.canonicalGeneration, local.snapshotGeneration)
            XCTAssertTrue(local.cached?.canonicalGenerationMatches == true)
            XCTAssertNil(local.knownInvalidation)
            if !failDetails {
                XCTAssertNotEqual(before.canonicalGeneration, local.canonicalGeneration)
                guard case .loaded = target.cardState else { return XCTFail("Canonical details must load") }
            } else { XCTAssertEqual(target.cardState, .unavailable) }
            let cached = try await repo.cachedCareOverview(context: lease)
            XCTAssertEqual(cached.availability, .available)
            XCTAssertEqual(reminderPlan(cached).candidates, reminderPlan(fresh).candidates)
            XCTAssertFalse(reminderPlan(cached).candidates.isEmpty)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map { $0.url?.lastPathComponent },
                           ["sync", "commands", "sync", "care-overview", "care-overview"])
            XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        }
    }
}


extension CollectionWireTests {
    @MainActor
    func testManualCompletionUsesTypedRecordUndoACKAfterOptionalReadFailure() async throws {
        for undo in [false, true] {
            for mode in ["pending", "accepted", "retry"] {
                let accepted = mode != "pending"
                let url = try diskURL()
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let entry = UUID(), reversal = UUID(), placeholder = UUID()
                let later = "2026-11-03T09:10:00Z"
                var initial = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: Data(careAckPage(entry: entry).utf8)) as? [String: Any])
                var rows = try XCTUnwrap(initial["changes"] as? [[String: Any]])
                let plantIndex = try XCTUnwrap(rows.firstIndex { $0["entity_type"] as? String == "plants" })
                var plant = try XCTUnwrap(rows[plantIndex]["data"] as? [String: Any])
                plant["plant_id"] = "fixture-fern"
                rows[plantIndex]["data"] = plant
                initial["changes"] = rows
                var canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(careAckPage(
                    entry: entry, state: undo ? "voided" : "active", reversal: undo ? reversal : nil,
                    operation: placeholder, at: later).utf8)) as? [String: Any])
                var facts = try XCTUnwrap(canonical["changes"] as? [[String: Any]])
                if !undo {
                    let index = try XCTUnwrap(facts.firstIndex { $0["entity_type"] as? String == "care_entries" })
                    var fact = try XCTUnwrap(facts[index]["data"] as? [String: Any])
                    fact["operation_id"] = placeholder.uuidString
                    facts[index]["data"] = fact
                }
                canonical["changes"] = facts
                let canonicalBody = try syncJSON(canonical), baseline = try syncJSON(initial)
                var receipt = manualWateringReceipt(entryId: entry, state: undo ? "voided" : "active",
                                                    reversalId: undo ? reversal : nil)
                receipt["watermark"] = later
                let transport = CatalogueTransport([
                    .http(200, baseline), .http(200, receiptJSON()), .http(200, baseline)
                ] + (mode == "retry" ? [.network] : []) + [
                    accepted ? .http(200, try syncJSON(receipt)) : .network,
                    .inspect { requests in
                        let command = try JSONDecoder().decode(CommandEnvelopeDTO.self,
                            from: XCTUnwrap(requests.last(where: { $0.httpMethod == "POST" })?.httpBody))
                        return canonicalBody.replacingOccurrences(of: placeholder.uuidString,
                                                                   with: command.operationId.uuidString)
                    }, .network
                ])
                let api = client(transport), sdk = try profileSession()
                await api.bindSyncSession(sdk)
                let store = LocalStore(modelContainer: try diskContainer(url))
                let repo = CollectionRepository(store: store, apiClient: api,
                                                syncEngine: SyncEngine(store: store, apiClient: api))
                let target = try await CatalogueSaveModel(store: store, apiClient: api, repository: repo,
                    flowId: UUID(), operationId: UUID(), input: CatalogueInput(speciesSlug: "fixture-fern",
                    personalName: nil), session: sdk, isAnonymous: false)
                await target.save()
                await target.loadCard(includeManualWateringActions: true)
                XCTAssertEqual(target.manualWateringState, .ready)
                var completions = 0
                let done = CatalogueSaveCompletion(isCurrent: { true }, publish: { completions += 1 })
                if undo { await target.undoWatering(entryId: entry, completion: done) }
                else { await target.recordWatering(completion: done) }
                if mode == "retry" {
                    XCTAssertEqual(completions, 0)
                    XCTAssertEqual(target.manualWateringState, .pending)
                    await target.retryManualWatering(completion: done)
                }
                XCTAssertEqual(completions, accepted ? 1 : 0)
                XCTAssertEqual(target.manualWateringState, accepted ? .unavailable : .pending)
                if accepted { XCTAssertEqual(target.cardState, .unavailable) }
            }
        }
    }
}

extension CollectionWireTests {
    @MainActor
    func testRestoredCardReadJoinsLateCanonicalTaskWithoutAnotherCommand() async throws {
        for joinExisting in [false, true] {
            for mode in ["success", "partialFailure", "httpFailure", "cancel", "modelCancel",
                         "locale", "ticket", "disappear", "sdk", "aba"] {
                let signals = ["success", "partialFailure", "httpFailure"].contains(mode)
                let sdk = try profileSession(claims: ["sub": syncOwner.uuidString, "is_anonymous": false])
                let flow = UUID(), operation = UUID()
                var initial = overviewAlignmentPage()
                let baselineWatermark = "2026-11-19T09:00:00.000005+00:00"
                initial["until"] = baselineWatermark
                initial["next_since"] = baselineWatermark
                var rows = try XCTUnwrap(initial["changes"] as? [[String: Any]])
                var plant = try XCTUnwrap(rows[0]["data"] as? [String: Any])
                plant["plant_id"] = "fixture-fern"
                rows[0]["data"] = plant
                rows[0]["updated_at"] = baselineWatermark
                initial["changes"] = rows
                var late = initial
                let watermark = "2026-11-19T09:00:00.000006+00:00"
                late["until"] = watermark
                late["next_since"] = watermark
                rows[0]["updated_at"] = watermark
                if mode == "partialFailure" {
                    // Canonical publish succeeds, then catalogueCard rejects the missing species.
                    plant.removeValue(forKey: "plant_id")
                    rows[0]["data"] = plant
                }
                late["changes"] = rows
                var receipt = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: Data(receiptJSON().utf8)) as? [String: Any])
                receipt["watermark"] = baselineWatermark
                var earlyPage = overviewPage([reminderRow(serverPlantId)])
                earlyPage["verified_access_until"] = NSNull()
                earlyPage["owner_watermark"] = receipt["watermark"]
                var finalPage = earlyPage
                // A rejected details GET publishes no newer canonical window.
                finalPage["owner_watermark"] = mode == "httpFailure" ? baselineWatermark : watermark
                let transport = CatalogueTransport([
                    .http(200, try syncJSON(initial)), .http(200, try syncJSON(receipt)),
                    .held(mode == "httpFailure" ? 503 : 200, try syncJSON(late)),
                    .http(200, try syncJSON(earlyPage))
                ] + (signals ? [.http(200, try syncJSON(finalPage))] : []))
                let (url, store, api, lease, repo) = try await overviewRepositoryFixture(transport, seed: false)
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let original = try await CatalogueSaveModel(store: store, apiClient: api, repository: repo,
                    flowId: flow, operationId: operation,
                    input: CatalogueInput(speciesSlug: "fixture-fern", personalName: nil),
                    session: sdk, isAnonymous: false)
                await original.save()
                guard case let .saved(confirmation) = original.state else { return XCTFail("Create fixture ACK") }
                let restored = await CatalogueSaveModel.restore(store: store, apiClient: api, repository: repo,
                    ownerId: syncOwner, flowId: flow, session: sdk, isAnonymous: false)
                guard case let .restored(target) = restored else { return XCTFail("Durable restore") }
                XCTAssertEqual(target.state, .saved(confirmation))
                XCTAssertEqual(target.envelope, original.envelope)
                XCTAssertEqual(target.cardState, .idle)
                var active = true, locale = "en", ticket = 1, completions = 0, joined = false
                let originalTicket = ticket, originalLocale = locale
                var finalRead: Task<CareOverviewViewState, Error>?
                let done = CatalogueCardReadCompletion(
                    isCurrent: { active && ticket == originalTicket && locale == originalLocale },
                    publish: {
                        completions += 1
                        finalRead = Task { try await repo.refreshCareOverview(locale: .pl, context: lease) }
                    })
                let loading: Task<Void, Never>?
                if joinExisting {
                    loading = Task { await target.loadCard(includeManualWateringActions: true) }
                    await transport.waitForHeld()
                } else { loading = nil }
                let reading = Task {
                    joined = true
                    await target.readCard(includeManualWateringActions: true, completion: done)
                }
                while !joined { await Task.yield() }
                if !joinExisting { await transport.waitForHeld() }
                // Independent early overview is eligible, but cannot finish the held card read.
                let early = try await repo.refreshCareOverview(locale: .pl, context: lease)
                XCTAssertEqual(early.origin, .network)
                XCTAssertNil(early.failure)
                XCTAssertEqual(early.availability, .available)
                XCTAssertFalse(reminderPlan(early).candidates.isEmpty)
                XCTAssertEqual(completions, 0)
                XCTAssertNil(finalRead)
                let before = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
                switch mode {
                case "cancel": reading.cancel()
                case "modelCancel": target.cancel()
                case "locale": locale = "pl"
                case "ticket": ticket += 1
                case "disappear": active = false
                case "sdk": await api.bindSyncSession(sdk)
                case "aba":
                    await api.bindSyncSession(try profileSession(ownerId: otherSyncOwner))
                    await api.bindSyncSession(sdk)
                default: break
                }
                await transport.releaseHeld()
                if let loading { await loading.value }
                await reading.value
                XCTAssertEqual(completions, signals ? 1 : 0, mode)
                if signals {
                    let finalTask = try XCTUnwrap(finalRead)
                    let fresh = try await finalTask.value
                    XCTAssertEqual(fresh.origin, .network)
                    XCTAssertNil(fresh.failure)
                    XCTAssertEqual(fresh.availability, .available)
                    let local = try await store.readCareOverviewPresentation(context: lease, authority: api.syncAuthority)
                    XCTAssertEqual(local.canonicalGeneration, local.snapshotGeneration)
                    XCTAssertTrue(local.cached?.canonicalGenerationMatches == true)
                    XCTAssertNil(local.knownInvalidation)
                    if mode != "httpFailure" {
                        XCTAssertNotEqual(before.canonicalGeneration, local.canonicalGeneration)
                    }
                    let cached = try await repo.cachedCareOverview(context: lease)
                    XCTAssertEqual(cached.availability, .available)
                    XCTAssertEqual(reminderPlan(cached).candidates, reminderPlan(fresh).candidates)
                    XCTAssertFalse(reminderPlan(cached).candidates.isEmpty)
                    XCTAssertEqual(target.state, .saved(confirmation))
                    if mode == "success" {
                        guard case .loaded = target.cardState else { return XCTFail("Settled card") }
                        XCTAssertEqual(target.manualWateringState, .ready)
                    } else { XCTAssertEqual(target.cardState, .unavailable) }
                } else { XCTAssertNil(finalRead) }
                let requests = await transport.capturedRequests()
                XCTAssertEqual(requests.map { $0.url?.lastPathComponent },
                    ["sync", "commands", "sync", "care-overview"] + (signals ? ["care-overview"] : []))
                XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
                let persisted = try await store.catalogueCreateConfirmation(ownerId: syncOwner, operationId: operation)
                XCTAssertEqual(persisted, confirmation)
            }
        }
    }
}


extension CollectionWireTests {
    private func routingPayload(_ candidate: CareReminderPlan.Candidate) throws -> CareReminderNotificationRoute {
        let request = try CareReminderNotificationFactory.request(
            .init(candidate: candidate, attemptId: UUID()),
            now: SQLTimestamp.date(from: "2026-11-20T00:00:00Z")!)
        return try XCTUnwrap(CareReminderNotificationFactory.parse(
            identifier: request.identifier, userInfo: request.content.userInfo))
    }

    private func routingDecision(
        _ route: CareReminderNotificationRoute, _ state: CareOverviewViewState?,
        owner: UUID? = nil, locale: String = "pl"
    ) -> CareReminderRouting.Decision {
        CareReminderRouting.decide(route, expectedOwnerId: owner ?? syncOwner,
            locale: locale, state: state, now: SQLTimestamp.date(from: "2026-11-27T12:00:00Z")!,
            timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    @MainActor
    func testRoutingPostFireUsesCurrentOccurrenceDespiteOptoutAndOSDenial() async throws {
        let (url, _, _, _, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rows = [reminderRow(serverPlantId)]
        let state = try reminderState(local, rows: rows)
        let candidate = try XCTUnwrap(reminderPlan(state).candidates.first)
        let route = try routingPayload(candidate)
        let postFire = reminderPlan(state, optedIn: false, authorization: .denied,
                                    now: "2026-11-27T12:00:00Z")
        XCTAssertTrue(postFire.candidates.isEmpty)
        XCTAssertTrue(postFire.requests.isEmpty)
        XCTAssertEqual(postFire.currentOccurrences.map(\.id), [candidate.id])
        XCTAssertEqual(routingDecision(route, state), .open(plantId: serverPlantId))
        let changedHour = try reminderState(local, rows: rows, hour: 23)
        XCTAssertNotEqual(reminderPlan(changedHour).currentOccurrences.first, candidate)
        XCTAssertEqual(routingDecision(route, changedHour), .open(plantId: serverPlantId))
        let english = try reminderState(local, rows: rows, mode: "english")
        XCTAssertEqual(routingDecision(route, english, locale: "en"), .open(plantId: serverPlantId))
        XCTAssertEqual(routingDecision(route, english), .hold)
        let offline = try reminderState(local, rows: rows, mode: "offline")
        XCTAssertEqual(offline.failure, .transport)
        XCTAssertEqual(routingDecision(route, offline), .open(plantId: serverPlantId))
    }

    @MainActor
    func testRoutingFirstAidMovedDayDropsEvenWithStableID() async throws {
        let (url, _, _, _, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try reminderState(local, rows: [
            reminderRow(serverPlantId, controls: [reminderControl(1)])])
        let candidate = try XCTUnwrap(reminderPlan(original).candidates.first {
            if case .firstAid = $0.occurrence { return true }; return false
        })
        let route = try routingPayload(candidate)
        XCTAssertEqual(routingDecision(route, original), .open(plantId: serverPlantId))
        let moved = try reminderState(local, rows: [
            reminderRow(serverPlantId, controls: [reminderControl(1, due: "2026-11-26")])])
        let current = try XCTUnwrap(reminderPlan(moved).currentOccurrences.first { $0.id == candidate.id })
        XCTAssertEqual(current.sourceDueYMD, "2026-11-26")
        XCTAssertEqual(routingDecision(route, moved), .drop)
        XCTAssertEqual(routingDecision(try routingPayload(current), moved), .open(plantId: serverPlantId))
    }

    @MainActor
    func testRoutingRequiresEveryIdentityFieldAndIndependentOwner() async throws {
        let (url, _, _, _, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let state = try reminderState(local, rows: [reminderRow(serverPlantId)])
        let c = try XCTUnwrap(reminderPlan(state).candidates.first)
        let route = try routingPayload(c)
        XCTAssertEqual(routingDecision(route, nil, owner: otherSyncOwner), .drop)
        XCTAssertEqual(routingDecision(route, state, owner: otherSyncOwner), .drop)
        // Typed corruption also protects callers constructing routes directly.
        let wrong: [CareReminderPlan.Candidate] = [
            .init(id: c.id + "/extra", ownerId: c.ownerId, plantId: c.plantId,
                  occurrence: c.occurrence, sourceDueYMD: c.sourceDueYMD,
                  absoluteFireDate: c.absoluteFireDate, locale: c.locale),
            .init(id: c.id, ownerId: otherSyncOwner, plantId: c.plantId,
                  occurrence: c.occurrence, sourceDueYMD: c.sourceDueYMD,
                  absoluteFireDate: c.absoluteFireDate, locale: c.locale),
            .init(id: c.id, ownerId: c.ownerId, plantId: otherSyncOwner,
                  occurrence: c.occurrence, sourceDueYMD: c.sourceDueYMD,
                  absoluteFireDate: c.absoluteFireDate, locale: c.locale),
            .init(id: c.id, ownerId: c.ownerId, plantId: c.plantId,
                  occurrence: .routine(ruleId: otherSyncOwner), sourceDueYMD: c.sourceDueYMD,
                  absoluteFireDate: c.absoluteFireDate, locale: c.locale),
            .init(id: c.id, ownerId: c.ownerId, plantId: c.plantId,
                  occurrence: .firstAid(controlId: operationId), sourceDueYMD: c.sourceDueYMD,
                  absoluteFireDate: c.absoluteFireDate, locale: c.locale),
            .init(id: c.id, ownerId: c.ownerId, plantId: c.plantId,
                  occurrence: c.occurrence, sourceDueYMD: "2026-11-25",
                  absoluteFireDate: c.absoluteFireDate, locale: c.locale)
        ]
        for candidate in wrong {
            XCTAssertEqual(routingDecision(.init(candidate: candidate, attemptId: UUID()), state), .drop)
        }
        let foreign = try routingPayload(.init(
            id: CareReminderPlan.identity(ownerId: otherSyncOwner, plantId: c.plantId,
                occurrence: c.occurrence, sourceDueYMD: c.sourceDueYMD),
            ownerId: otherSyncOwner, plantId: c.plantId, occurrence: c.occurrence,
            sourceDueYMD: c.sourceDueYMD, absoluteFireDate: c.absoluteFireDate, locale: c.locale))
        XCTAssertEqual(routingDecision(foreign, state, owner: otherSyncOwner), .hold)
    }

    @MainActor
    func testRoutingUnavailableHoldsAndKnownDenialsOrAbsentTasksDrop() async throws {
        let (url, _, _, _, local) = try await reminderFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rows = [reminderRow(serverPlantId)]
        let state = try reminderState(local, rows: rows)
        let route = try routingPayload(try XCTUnwrap(reminderPlan(state).candidates.first))
        XCTAssertEqual(routingDecision(route, nil), .hold)
        for mode in ["absent", "unknown", "readOnly", "generation", "nilGeneration",
                     "invalidated", "revalidate", "english", "profile.update", "nilHour", "deleted"] {
            XCTAssertEqual(routingDecision(route, try reminderState(local, rows: rows, mode: mode)), .hold, mode)
        }
        XCTAssertEqual(routingDecision(route, state, locale: "de"), .hold)
        XCTAssertEqual(routingDecision(route, try reminderState(local, rows: rows, mode: "denied")), .drop)
        for deadline in ["2026-11-20T00:00:00Z", "2026-11-27T12:00:00Z"] {
            XCTAssertEqual(routingDecision(route, try reminderState(local, rows: rows, deadline: deadline)), .drop)
        }
        // Accepted projection removed/suppressed the task or its source (paused/withdrawn care).
        let replacements: [[[String: Any]]] = [
            [], [overviewRow(serverPlantId)], [reminderRow(serverPlantId, due: "2026-11-27")]
        ]
        for replacement in replacements {
            XCTAssertEqual(routingDecision(route, try reminderState(local, rows: replacement)), .drop)
        }
        for mode in ["plant.edit", "plant.delete", "care.record", "care.routine.undo", "plant.photo", "global"] {
            XCTAssertEqual(routingDecision(route, try reminderState(local, rows: rows, mode: mode)), .drop, mode)
        }
    }
}

// Test-only synchronized completion recorder; native objects never escape into Tasks.
private final class NativeBridgeCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var nonemptyOptions = 0
    func record(_ options: UNNotificationPresentationOptions = []) {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if !options.isEmpty { nonemptyOptions += 1 }
    }
    var snapshot: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return [calls, nonemptyOptions]
    }
}

extension CollectionWireTests {
    func testNativeBridgeEarlyPolicyFixedMatrix() {
        for arguments in [[], ["Plants"], ["-AppleLanguages", "(en)", "-AppleLocale", "pl_PL"],
                          ["--ordinary", "value"]] {
            XCTAssertTrue(CareReminderSystemLaunchPolicy.allowsSystem(arguments: arguments))
        }
        let blocked = ["--catalogue", "--catalogue-fixture", "--catalogue-namespace",
            "--catalogue-malformed=x", "--today", "--today-fixture", "--today-namespace",
            "--today-broken", "--narat-staging", "--narat-staging-invalid",
            "--care-reminder", "--care-reminder-fixture", "--care-reminder-namespace",
            "--care-reminder-unknown=x", "--result-save-presentation",
            "--result-save-presentation-invalid"]
        for flag in blocked {
            XCTAssertFalse(CareReminderSystemLaunchPolicy.allowsSystem(arguments: ["Plants", flag]), flag)
            XCTAssertFalse(CareReminderSystemLaunchPolicy.allowsSystem(
                arguments: ["-AppleLocale", "en_US", flag, "--care-reminder-fixture", "eligible"]), flag)
        }
    }

    @MainActor
    func testNativeInboxColdRetentionDuplicatesAndStaleConsume() throws {
        let inbox = CareReminderNotificationInbox()
        let route = try routingPayload(receiptCandidate())
        inbox.receive(.tap(route))
        let first = try XCTUnwrap(inbox.pendingTap)
        XCTAssertEqual(first.route, route)
        // A duplicate must not rebind payload or remint the intent.
        let altered = CareReminderNotificationRoute(candidate: try receiptCandidate(locale: "en"),
                                                     attemptId: route.attemptId)
        inbox.receive(.tap(altered))
        XCTAssertEqual(inbox.pendingTap, first)
        inbox.receive(.foreground(altered))
        XCTAssertEqual(inbox.pendingTap, first)
        XCTAssertEqual(inbox.latestForeground, altered)
        inbox.consume(intentID: first.id)
        inbox.receive(.tap(route))
        XCTAssertNil(inbox.pendingTap)
        let newer = CareReminderNotificationRoute(candidate: route.candidate, attemptId: otherSyncOwner)
        inbox.receive(.tap(newer))
        let second = try XCTUnwrap(inbox.pendingTap)
        XCTAssertNotEqual(second.id, first.id)
        inbox.consume(intentID: first.id)
        inbox.receive(.tap(route))
        XCTAssertEqual(inbox.pendingTap, second)
        inbox.consume(intentID: second.id)
        inbox.receive(.tap(newer))
        XCTAssertNil(inbox.pendingTap)
    }

    @MainActor
    func testNativeInboxLatestAndFixedMemoryBound() throws {
        let inbox = CareReminderNotificationInbox()
        let route = try routingPayload(receiptCandidate())
        var last = route
        for index in 1...128 {
            let attempt = try XCTUnwrap(UUID(uuidString:
                String(format: "00000000-0000-0000-0000-%012d", index)))
            last = .init(candidate: route.candidate, attemptId: attempt)
            inbox.receive(.tap(last))
            inbox.receive(.foreground(last))
            XCTAssertLessThanOrEqual(inbox.recentCount, 64)
        }
        XCTAssertEqual(inbox.recentCount, 64)
        XCTAssertEqual(inbox.pendingTap?.route, last)
        XCTAssertEqual(inbox.latestForeground, last)
        let pending = try XCTUnwrap(inbox.pendingTap)
        inbox.receive(.tap(last))
        XCTAssertEqual(inbox.pendingTap, pending)
        inbox.consume(intentID: pending.id)
        inbox.receive(.foreground(route))
        inbox.receive(.tap(last))
        XCTAssertNil(inbox.pendingTap)
        XCTAssertEqual(inbox.latestForeground, route)
    }

    func testNativeBridgeImplementsBothOptionalSDKSelectors() {
        let adapter = CareReminderNotificationBridge(arguments: []) { _ in }
        let witness: any UNUserNotificationCenterDelegate = adapter
        XCTAssertTrue(witness.responds(to: #selector(UNUserNotificationCenterDelegate
            .userNotificationCenter(_:didReceive:withCompletionHandler:))))
        XCTAssertTrue(witness.responds(to: #selector(UNUserNotificationCenterDelegate
            .userNotificationCenter(_:willPresent:withCompletionHandler:))))
    }

    @MainActor
    func testNativeBridgeRejectedCallbacksCompleteOnceSynchronously() async throws {
        let request = try notificationRequest(receiptCandidate())
        let unexpected = XCTestExpectation(description: "No rejected transport")
        unexpected.isInverted = true
        let adapter = CareReminderNotificationBridge(arguments: []) { _ in unexpected.fulfill() }
        for action in [UNNotificationDismissActionIdentifier, "custom"] {
            let probe = NativeBridgeCompletionProbe()
            adapter.receive(identifier: request.identifier, actionIdentifier: action,
                userInfo: request.content.userInfo) { probe.record() }
            XCTAssertEqual(probe.snapshot, [1, 0])
        }
        let invalid: [(String, [AnyHashable: Any])] = [
            ("narat.trial.fixture", request.content.userInfo), ("unrelated", [:]),
            (request.identifier, [:]), (request.identifier, ["narat.care.version": 1])]
        for (identifier, metadata) in invalid {
            let tap = NativeBridgeCompletionProbe(), foreground = NativeBridgeCompletionProbe()
            adapter.receive(identifier: identifier, actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: metadata) { tap.record() }
            adapter.present(identifier: identifier, userInfo: metadata) { foreground.record($0) }
            XCTAssertEqual(tap.snapshot, [1, 0])
            XCTAssertEqual(foreground.snapshot, [1, 0])
        }
        for flag in ["--catalogue", "--today-broken", "--narat-staging", "--care-reminder",
                     "--result-save-presentation"] {
            let isolated = CareReminderNotificationBridge(arguments: [flag]) { _ in unexpected.fulfill() }
            let tap = NativeBridgeCompletionProbe(), foreground = NativeBridgeCompletionProbe()
            isolated.receive(identifier: request.identifier,
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: request.content.userInfo) { tap.record() }
            isolated.present(identifier: request.identifier,
                userInfo: request.content.userInfo) { foreground.record($0) }
            XCTAssertEqual(tap.snapshot, [1, 0])
            XCTAssertEqual(foreground.snapshot, [1, 0])
        }
        let result = await XCTWaiter.fulfillment(of: [unexpected], timeout: 0.05)
        XCTAssertEqual(result, .completed)
    }

    @MainActor
    func testNativeBridgeHeldSinkDoesNotDelayCompletionAndRetainsTypedEvents() async throws {
        // Fixed historical fire: transport has no expiry/owner authority.
        let request = try CareReminderNotificationFactory.request(
            .init(candidate: receiptCandidate(due: "2026-11-19", owner: otherSyncOwner),
                  attemptId: operationId),
            now: SQLTimestamp.date(from: "2026-11-18T00:00:00Z")!)
        let route = try XCTUnwrap(CareReminderNotificationFactory.parse(
            identifier: request.identifier, userInfo: request.content.userInfo))
        let inbox = CareReminderNotificationInbox()
        let barrier = CareReminderReadiness(held: true)
        let entered = XCTestExpectation(description: "Both typed sinks held")
        let delivered = XCTestExpectation(description: "Both typed sinks delivered")
        entered.expectedFulfillmentCount = 2
        delivered.expectedFulfillmentCount = 2
        entered.assertForOverFulfill = true
        delivered.assertForOverFulfill = true
        let adapter = CareReminderNotificationBridge(arguments: []) { event in
            entered.fulfill()
            try? await barrier.wait()
            await inbox.receive(event)
            delivered.fulfill()
        }
        let tap = NativeBridgeCompletionProbe(), foreground = NativeBridgeCompletionProbe()
        adapter.receive(identifier: request.identifier, actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: request.content.userInfo) { tap.record() }
        adapter.present(identifier: request.identifier, userInfo: request.content.userInfo) { foreground.record($0) }
        XCTAssertEqual(tap.snapshot, [1, 0])
        XCTAssertEqual(foreground.snapshot, [1, 0])
        XCTAssertNil(inbox.pendingTap)
        let started = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(started, .completed)
        XCTAssertNil(inbox.pendingTap)
        barrier.release()
        let finished = await XCTWaiter.fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(finished, .completed)
        XCTAssertEqual(inbox.pendingTap?.route, route)
        XCTAssertEqual(inbox.latestForeground, route)
        XCTAssertEqual(tap.snapshot, [1, 0])
        XCTAssertEqual(foreground.snapshot, [1, 0])
    }

    @MainActor
    func testNativeBridgeForegroundAloneNeverCreatesNavigationIntent() async throws {
        let request = try notificationRequest(receiptCandidate())
        let route = try XCTUnwrap(CareReminderNotificationFactory.parse(
            identifier: request.identifier, userInfo: request.content.userInfo))
        let inbox = CareReminderNotificationInbox()
        let delivered = XCTestExpectation(description: "Foreground transport only")
        let adapter = CareReminderNotificationBridge(arguments: []) { event in
            await inbox.receive(event)
            delivered.fulfill()
        }
        let probe = NativeBridgeCompletionProbe()
        adapter.present(identifier: request.identifier, userInfo: request.content.userInfo) { probe.record($0) }
        XCTAssertEqual(probe.snapshot, [1, 0])
        let result = await XCTWaiter.fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(result, .completed)
        XCTAssertNil(inbox.pendingTap)
        XCTAssertEqual(inbox.latestForeground, route)
        XCTAssertEqual(inbox.recentCount, 0)
    }
}

@MainActor
private final class NativeRegistrationProbe {
    // Models UNUserNotificationCenter's weak delegate without acquiring the center.
    weak var delegate: CareReminderNotificationBridge?
    var installs = 0
    func install(_ bridge: CareReminderNotificationBridge) {
        installs += 1
        delegate = bridge
    }
}

extension CollectionWireTests {
    @MainActor
    func testNativeLaunchConstructorIsInertAndOptionalSelectorInstallsSynchronouslyOnce() throws {
        let probe = NativeRegistrationProbe()
        var owner: CareReminderAppDelegate? = .init(arguments: ["Plants"]) { probe.install($0) }
        weak var weakInbox = owner?.inbox
        XCTAssertNotNil(weakInbox)
        XCTAssertNil(owner?.bridge)
        XCTAssertNil(probe.delegate)
        XCTAssertEqual(probe.installs, 0)
        let selector = #selector(UIApplicationDelegate.application(_:didFinishLaunchingWithOptions:))
        XCTAssertTrue(try XCTUnwrap(owner).responds(to: selector))
        // Calls the real witness, with a lazy fake installer; no real UN center is used.
        XCTAssertTrue(try XCTUnwrap(owner).application(UIApplication.shared,
            didFinishLaunchingWithOptions: nil))
        XCTAssertEqual(probe.installs, 1)
        XCTAssertTrue(probe.delegate === owner?.bridge)
        weak var installed = probe.delegate
        XCTAssertNotNil(installed)
        XCTAssertTrue(try XCTUnwrap(owner).application(UIApplication.shared,
            didFinishLaunchingWithOptions: [:]))
        XCTAssertEqual(probe.installs, 1)
        XCTAssertTrue(installed === probe.delegate)
        XCTAssertTrue(weakInbox === owner?.inbox)
        owner = nil
        XCTAssertNil(installed)
        XCTAssertNil(probe.delegate)
        XCTAssertNil(weakInbox)
    }

    @MainActor
    func testNativeLaunchBlockedMatrixNeverInvokesLazyAcquisition() {
        let flags = ["--catalogue", "--catalogue-fixture", "--catalogue-namespace",
            "--catalogue-malformed=x", "--today", "--today-fixture", "--today-namespace",
            "--today-broken", "--narat-staging", "--narat-staging-invalid",
            "--care-reminder", "--care-reminder-fixture", "--care-reminder-namespace",
            "--care-reminder-unknown=x", "--result-save-presentation",
            "--result-save-presentation-invalid"]
        for flag in flags {
            for arguments in [["Plants", flag],
                ["Plants", "--care-reminder-fixture", "eligible", flag, "--today-broken"]] {
                let probe = NativeRegistrationProbe()
                let owner = CareReminderAppDelegate(arguments: arguments) { probe.install($0) }
                let inbox = owner.inbox
                for _ in 0..<2 {
                    XCTAssertTrue(owner.application(UIApplication.shared,
                        didFinishLaunchingWithOptions: nil), arguments.description)
                }
                // All System acquisition is inside the uncalled installer.
                XCTAssertEqual(probe.installs, 0, arguments.description)
                XCTAssertNil(probe.delegate)
                XCTAssertNil(owner.bridge)
                XCTAssertTrue(owner.inbox === inbox)
                XCTAssertNil(inbox.pendingTap)
                XCTAssertNil(inbox.latestForeground)
            }
        }
    }

    @MainActor
    func testNativeLaunchColdTapReachesPrecreatedInboxThenSameRootAndRuntime() async throws {
        let probe = NativeRegistrationProbe()
        let owner = CareReminderAppDelegate(arguments: []) { probe.install($0) }
        let inbox = owner.inbox
        let request = try notificationRequest(receiptCandidate())
        let route = try XCTUnwrap(CareReminderNotificationFactory.parse(
            identifier: request.identifier, userInfo: request.content.userInfo))
        XCTAssertTrue(owner.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        let delivered = XCTestExpectation(description: "Cold tap retained before Root or SDK")
        let observation = inbox.$pendingTap.compactMap { $0 }.first().sink { _ in delivered.fulfill() }
        defer { observation.cancel() }
        let completion = NativeBridgeCompletionProbe()
        try XCTUnwrap(probe.delegate).receive(identifier: request.identifier,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: request.content.userInfo) { completion.record() }
        XCTAssertEqual(completion.snapshot, [1, 0])
        let result = await XCTWaiter.fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(result, .completed)
        let intent = try XCTUnwrap(inbox.pendingTap)
        XCTAssertEqual(intent.route, route)
        XCTAssertNil(inbox.latestForeground)

        let notifications = FakeCareReminderNotifications()
        let runtime = CareReminderRuntime(core: .init(
            notifications: notifications, defaults: .standard,
            clock: { Date() }, timeZone: { TimeZone.current }))
        let root = RootContainerView(languageStore: LanguageStore(), analysisModel: AnalysisFlowModel(),
            careReminderRuntime: runtime, careReminderInbox: owner.inbox)
        XCTAssertTrue(root.careReminderRuntime === runtime)
        XCTAssertTrue(root.careReminderInbox === inbox)
        XCTAssertEqual(root.careReminderInbox.pendingTap, intent)
        XCTAssertNil(runtime.core.state)
        XCTAssertEqual(notifications.permissionRequests, 0)
        XCTAssertEqual(notifications.inventoryReads, 0)
        XCTAssertTrue(notifications.adds.isEmpty)
        XCTAssertTrue(notifications.removed.isEmpty)
        XCTAssertEqual(completion.snapshot, [1, 0])
    }

    @MainActor
    func testNativeLaunchForegroundRemainsTransportWithoutTapOrRuntimeEffects() async throws {
        let probe = NativeRegistrationProbe()
        let owner = CareReminderAppDelegate(arguments: []) { probe.install($0) }
        let request = try notificationRequest(receiptCandidate())
        let route = try XCTUnwrap(CareReminderNotificationFactory.parse(
            identifier: request.identifier, userInfo: request.content.userInfo))
        XCTAssertTrue(owner.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        let delivered = XCTestExpectation(description: "Foreground is transport only")
        let observation = owner.inbox.$latestForeground.compactMap { $0 }.first()
            .sink { _ in delivered.fulfill() }
        defer { observation.cancel() }
        let completion = NativeBridgeCompletionProbe()
        try XCTUnwrap(probe.delegate).present(identifier: request.identifier,
            userInfo: request.content.userInfo) { completion.record($0) }
        XCTAssertEqual(completion.snapshot, [1, 0])
        let result = await XCTWaiter.fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(owner.inbox.latestForeground, route)
        XCTAssertNil(owner.inbox.pendingTap)
        XCTAssertEqual(owner.inbox.recentCount, 0)
        XCTAssertEqual(probe.installs, 1)
    }
}
