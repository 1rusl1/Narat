import Foundation
import XCTest
import SwiftData
@testable import Plants

private actor CapacityTransport: PlantsAPITransport {
    private let pages: [Data]
    private let statuses: [Int]
    private let suspended: Bool
    private var requests: [URLRequest] = []
    private var release: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    init(_ pages: [Data], statuses: [Int] = [], suspended: Bool = false) {
        self.pages = pages
        self.statuses = statuses
        self.suspended = suspended
    }

    func captured() -> [URLRequest] { requests }
    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resume() { release?.resume(); release = nil }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        guard request.httpMethod == "GET", request.url?.lastPathComponent == "sync",
              index < pages.count else { throw URLError(.badServerResponse) }
        if suspended && index == 0 {
            await withCheckedContinuation { continuation in
                release = continuation
                for observer in observers { observer.resume() }
                observers.removeAll()
            }
        }
        return (pages[index], HTTPURLResponse(
            url: request.url!, statusCode: statuses.isEmpty ? 200 : statuses[index],
            httpVersion: nil, headerFields: nil
        )!)
    }
}

private actor OutboxFailureTransport: PlantsAPITransport {
    private let status: Int?
    private let body: Data
    private var requests: [URLRequest] = []

    init(status: Int? = nil, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    func captured() -> [URLRequest] { requests }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let status else { throw URLError(.notConnectedToInternet) }
        return (body, HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!)
    }
}

@MainActor
final class CollectionRepositoryTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let other = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let until = "2026-11-03T09:00:00.999999+00:00"
    private let boundary = "2026-11-03T09:00:00+00:00"
    private var session: NativeAuthSession {
        NativeAuthSession(userId: owner, accessToken: "capacity-a", expiresAt: .distantFuture)
    }

    private func diskURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("capacity.sqlite")
    }

    private func container(
        _ url: URL, allowsSave: Bool = true, historicalFiveTables: Bool = false
    ) throws -> ModelContainer {
        var models: [any PersistentModel.Type] = [
            LocalOutboxRecord.self, CatalogueCreateConfirmationRecord.self,
            GuestDraftCacheRecord.self, SyncedEntityRecord.self, SyncCheckpointRecord.self
        ]
        if !historicalFiveTables { models.append(CatalogueInputCheckpointRecord.self) }
        let schema = Schema(models)
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, allowsSave: allowsSave)
        ])
    }

    private func change(_ index: Int, deleted: Bool = false) -> [String: Any] {
        ["entity_type": "plants", "id": String(format: "22222222-2222-4222-8222-%012d", index),
         "updated_at": until, "deleted_at": deleted ? (until as Any) : NSNull(),
         "data": deleted ? NSNull() : (["care_enabled": false, "legacy_over_cap": true] as Any)]
    }

    private func page(_ changes: [[String: Any]] = [], entitlement: Any = NSNull()) -> [String: Any] {
        ["until": until, "has_more": false, "last_cursor": NSNull(), "next_since": until,
         "profile": ["preferred_locale": "pl", "reminder_hour_local": 9,
                     "report_notifications_enabled": true, "trial_reminder_enabled": false],
         "entitlement": entitlement, "changes": changes]
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func rights(
        state: String = "active", offer: String = "paid",
        valid: String? = "2026-12-01T00:00:00Z", trial: String? = nil
    ) -> [String: Any] {
        ["product_id": "app.narat.pro", "state": state, "offer_kind": offer,
         "valid_until": valid.map { $0 as Any } ?? NSNull(), "trial_end_at": trial.map { $0 as Any } ?? NSNull(),
         "grace_until": "2027-01-01T00:00:00Z", "auto_renew_enabled": false]
    }

    private func repository(_ store: LocalStore, _ api: PlantsAPIClient) -> CollectionRepository {
        let now = SQLTimestamp.date(from: boundary)!
        return CollectionRepository(
            store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api),
            clock: { now }
        )
    }

    private func confirmed(_ result: CollectionCapacityResult) throws -> CollectionCapacity {
        guard case let .confirmed(capacity) = result else {
            XCTFail("Authenticated canonical refresh must confirm capacity")
            throw SyncWireValidationError.invalidPage
        }
        return capacity
    }

    private struct DiskState: Equatable {
        let raw: String?
        let profile: SyncWireProfileDTO?
        let entitlement: SyncWireEntitlementDTO?
        let plants: [String]
        let queue: [OutboxEntrySnapshot]
    }

    private func state(_ store: LocalStore, ownerId: UUID) async throws -> DiskState {
        let raw = try await store.currentWatermarkRaw(ownerId: ownerId)
        let profile = try await store.syncedProfile(ownerId: ownerId)
        let entitlement = try await store.syncedEntitlement(ownerId: ownerId)
        let plants = try await store.activeSyncedEntities(ownerId: ownerId, entityType: "plants")
        let queue = try await store.pendingOutboxEntries(for: ownerId)
        return DiskState(raw: raw, profile: profile, entitlement: entitlement,
                         plants: plants.map { $0.id.uuidString + $0.payloadJSON }, queue: queue)
    }

    private func seed(_ store: LocalStore) async throws {
        let api = PlantsAPIClient(transport: CapacityTransport([try json(page([change(1)], entitlement: rights()))]))
        await api.bindSyncSession(session)
        _ = try await repository(store, api).preflightCapacity(session: session, isAnonymous: false)
        for id in [owner, other] {
            _ = try await store.enqueueCommand(ownerId: id, plantId: nil, commandName: "plant.create", payloadJSON: "{}")
        }
    }

    func testFreeTwoThreeAndOverCapCountAllPlantsButNotTombstones() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try container(url))
        for count in [2, 3, 5] {
            let changes = (1...count).map { change($0) } + [change(9, deleted: true)]
            let transport = CapacityTransport([try json(page(changes))])
            let api = PlantsAPIClient(transport: transport)
            await api.bindSyncSession(session)
            let result = try confirmed(await repository(store, api).preflightCapacity(session: session, isAnonymous: false))
            XCTAssertEqual(result.ownerId, owner)
            XCTAssertEqual(result.plantCount, count)
            XCTAssertEqual(result.collectionLimit, 3)
            XCTAssertFalse(result.hasVerifiedPaidAccess)
            XCTAssertEqual(result.canCreate, count < 3)
            let requests = await transport.captured()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer capacity-a")
            let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertFalse(query.contains { $0.name == "since" })
        }
    }

    func testVerifiedPaidGraceAndTrialUseStrictSQLExpiryPredicate() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try container(url))
        let cases: [([String: Any], Bool)] = [
            (rights(), true), (rights(state: "grace"), true),
            (rights(offer: "trial", trial: until), true),
            (rights(offer: "trial", trial: boundary), false),
            (rights(offer: "trial"), false),
            (rights(state: "grace", valid: boundary), false),
            (rights(state: "grace", valid: "2026-10-01T00:00:00Z"), false),
            (rights(valid: nil), false), (rights(state: "revoked"), false),
            (rights(valid: "2026-11-03T09:00:00.000001+00:00"), true)
        ]
        for (entitlement, expected) in cases {
            let api = PlantsAPIClient(transport: CapacityTransport([
                try json(page((1...4).map { change($0) }, entitlement: entitlement))
            ]))
            await api.bindSyncSession(session)
            let result = try confirmed(await repository(store, api).preflightCapacity(session: session, isAnonymous: false))
            XCTAssertEqual(result.hasVerifiedPaidAccess, expected)
            XCTAssertEqual(result.canCreate, expected)
            XCTAssertEqual(result.collectionLimit, expected ? nil : 3)
            XCTAssertEqual(result.plantCount, 4)
        }
    }

    func testFractionalExpiryBeforeAtAndAfterExactBoundary() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try container(url))
        let exact = "2026-11-03T09:00:00.000003Z"
        let now = SQLTimestamp.date(from: exact)!
        let cases: [(String, Bool)] = [
            ("2026-11-03T09:00:00.000002Z", false),
            (exact, false),
            ("2026-11-03T10:00:00.000003+01:00", false),
            ("2026-11-03T09:00:00.000004Z", true)
        ]
        for (expiry, expected) in cases {
            for entitlement in [rights(valid: expiry), rights(offer: "trial", trial: expiry)] {
                let api = PlantsAPIClient(transport: CapacityTransport([
                    try json(page((1...4).map { change($0) }, entitlement: entitlement))
                ]))
                await api.bindSyncSession(session)
                let repository = CollectionRepository(
                    store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api),
                    clock: { now }
                )
                let result = try confirmed(await repository.preflightCapacity(session: session, isAnonymous: false))
                XCTAssertEqual(result.hasVerifiedPaidAccess, expected, "expiry=\(expiry), rights=\(entitlement)")
                XCTAssertEqual(result.canCreate, expected)
            }
        }
    }

    func testEmptyCanonicalRefreshClearsOldPlantsAndNullableRightsWithoutDrainingQueue() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try container(url))
        try await seed(store)
        let before = try await state(store, ownerId: owner)
        for entitlement in [rights() as Any, NSNull()] {
            let api = PlantsAPIClient(transport: CapacityTransport([try json(page(entitlement: entitlement))]))
            await api.bindSyncSession(session)
            let result = try confirmed(await repository(store, api).preflightCapacity(session: session, isAnonymous: false))
            XCTAssertEqual(result.plantCount, 0)
            XCTAssertTrue(result.canCreate)
            XCTAssertEqual(result.hasVerifiedPaidAccess, entitlement is [String: Any])
            let reopened = LocalStore(modelContainer: try container(url))
            let after = try await state(reopened, ownerId: owner)
            XCTAssertEqual(after.queue, before.queue)
            XCTAssertEqual(after.raw, until)
            XCTAssertEqual(after.profile?.preferredLocale, "pl")
            XCTAssertEqual(after.entitlement != nil, entitlement is [String: Any])
        }
    }

    func testFailedMalformedAndSecondPageFailurePreserveConfirmedDiskAndQueue() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try container(url))
        try await seed(store)
        let before = try await state(store, ownerId: owner)
        let foreign = try await state(store, ownerId: other)
        var malformed = page()
        malformed.removeValue(forKey: "profile")
        var first = page([change(2)])
        first["has_more"] = true
        first["next_since"] = NSNull()
        first["last_cursor"] = [
            "since": NSNull(), "until": until, "updated_at": until,
            "entity_type": "plants", "id": change(2)["id"]!
        ]
        let attempts: [([Data], [Int])] = [
            ([try json(page())], [503]), ([try json(malformed)], [200]),
            ([try json(first), try json(page())], [200, 503])
        ]
        for (pages, statuses) in attempts {
            let transport = CapacityTransport(pages, statuses: statuses)
            let api = PlantsAPIClient(transport: transport)
            await api.bindSyncSession(session)
            do {
                _ = try await repository(store, api).preflightCapacity(session: session, isAnonymous: false)
                XCTFail("Unavailable canonical refresh must not manufacture capacity")
            } catch {}
            let reopened = LocalStore(modelContainer: try container(url))
            let after = try await state(reopened, ownerId: owner)
            let otherAfter = try await state(reopened, ownerId: other)
            XCTAssertEqual(after, before)
            XCTAssertEqual(otherAfter, foreign)
            let requests = await transport.captured()
            XCTAssertEqual(requests.count, pages.count)
        }
    }

    func testGuestUnboundWrongOwnerAndChangedTokenNeverRequestOrMutate() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try container(url))
        try await seed(store)
        let before = try await state(store, ownerId: owner)
        for mode in 0..<4 {
            let transport = CapacityTransport([])
            let api = PlantsAPIClient(transport: transport)
            if mode == 0 { await api.bindSyncSession(session) }
            if mode == 2 {
                await api.bindSyncSession(NativeAuthSession(userId: other, accessToken: "b", expiresAt: .distantFuture))
            }
            if mode == 3 {
                await api.bindSyncSession(NativeAuthSession(userId: owner, accessToken: "new", expiresAt: .distantFuture))
            }
            do {
                let result = try await repository(store, api).preflightCapacity(session: session, isAnonymous: mode == 0)
                XCTAssertEqual(mode, 0)
                XCTAssertEqual(result, .signInRequired)
            } catch SyncWireValidationError.invalidSession {
                XCTAssertNotEqual(mode, 0)
            } catch {
                XCTFail("Unexpected preflight error: \(error)")
            }
            let requests = await transport.captured()
            XCTAssertTrue(requests.isEmpty)
            let after = try await state(store, ownerId: owner)
            XCTAssertEqual(after, before)
        }
    }

    func testOwnerSwitchABAAndCancellationMidPreflightCannotPublishOrReturnCapacity() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try container(url))
        try await seed(store)
        let before = try await state(store, ownerId: owner)
        let foreign = try await state(store, ownerId: other)
        for mode in 0..<3 {
            let transport = CapacityTransport([try json(page())], suspended: true)
            let api = PlantsAPIClient(transport: transport)
            await api.bindSyncSession(session)
            let repository = repository(store, api)
            let caller = session
            let operation = Task { try await repository.preflightCapacity(session: caller, isAnonymous: false) }
            await transport.waitForRequest()
            if mode == 2 {
                operation.cancel()
            } else {
                await api.bindSyncSession(NativeAuthSession(userId: other, accessToken: "b", expiresAt: .distantFuture))
                if mode == 1 { await api.bindSyncSession(session) }
            }
            await transport.resume()
            do {
                _ = try await operation.value
                XCTFail("Original cancelled/stale lease must fail")
            } catch is CancellationError {
                XCTAssertEqual(mode, 2)
            } catch SyncWireValidationError.invalidSession {
                XCTAssertNotEqual(mode, 2)
            } catch {
                XCTFail("Unexpected preflight error: \(error)")
            }
            let reopened = LocalStore(modelContainer: try container(url))
            let after = try await state(reopened, ownerId: owner)
            let otherAfter = try await state(reopened, ownerId: other)
            XCTAssertEqual(after, before)
            XCTAssertEqual(otherAfter, foreign)
            let requests = await transport.captured()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testLegacyDateRequiresCanonicalFullRefreshAndExactCheckpointSurvivesReopen() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = LocalStore(modelContainer: try container(url))
            try await store.updateWatermark(ownerId: owner, watermark: SQLTimestamp.date(from: boundary))
            try await store.applySyncedItems([
                SyncItemDTO(entityType: "plant", id: UUID(), updatedAt: Date(), payloadJSON: "{}")
            ], ownerId: owner)
        }
        do {
            let store = LocalStore(modelContainer: try container(url))
            let transport = CapacityTransport([try json(page([change(1), change(2)]))])
            let api = PlantsAPIClient(transport: transport)
            await api.bindSyncSession(session)
            let result = try confirmed(await repository(store, api).preflightCapacity(session: session, isAnonymous: false))
            XCTAssertEqual(result.plantCount, 2)
            XCTAssertTrue(result.canCreate)
            let requests = await transport.captured()
            let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertFalse(query.contains { $0.name == "since" })
        }
        let reopened = LocalStore(modelContainer: try container(url))
        let after = try await state(reopened, ownerId: owner)
        XCTAssertEqual(after.raw, until)
        XCTAssertEqual(after.plants.count, 2)
        XCTAssertNotNil(after.profile)
        XCTAssertNil(after.entitlement)
        let legacy = try await reopened.activeSyncedEntities(ownerId: owner, entityType: "plant")
        XCTAssertTrue(legacy.isEmpty)
    }

    func testCollectionAndJournalReopenOfflineOnlyForPreviouslySyncedOwner() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plant = UUID(uuidString: "22222222-2222-4222-8222-000000000001")!
        let entry = UUID(uuidString: "55555555-5555-4555-8555-000000000001")!
        var card = change(1)
        card["data"] = ["id": plant.uuidString.lowercased(), "plant_id": "monstera_deliciosa",
                        "personal_name": "Saved Monstera", "revision": 1, "care_revision": 1] as [String: Any]
        let fact: [String: Any] = [
            "entity_type": "care_entries", "id": entry.uuidString.lowercased(), "updated_at": until, "deleted_at": NSNull(),
            "data": ["id": entry.uuidString.lowercased(), "plant_id": plant.uuidString.lowercased(),
                     "action_code": "water", "occurred_at": boundary, "occurred_local_date": "2026-11-03", "state": "active"]
        ]
        do {
            let store = LocalStore(modelContainer: try container(url))
            let api = PlantsAPIClient(transport: CapacityTransport([try json(page([fact, card]))]))
            await api.bindSyncSession(session)
            let lease = try await api.captureSyncContext(ownerId: owner)
            let collection = try await repository(store, api).collectionCards(context: lease)
            XCTAssertFalse(collection.isCached)
            XCTAssertEqual(collection.cards.map(\.id), [plant])
        }

        let store = LocalStore(modelContainer: try container(url))
        let transport = OutboxFailureTransport()
        let api = PlantsAPIClient(transport: transport)
        await api.bindSyncSession(session)
        let lease = try await api.captureSyncContext(ownerId: owner)
        let repo = repository(store, api)
        let before = try await state(store, ownerId: owner)
        let cached = try await repo.collectionCards(context: lease)
        XCTAssertTrue(cached.isCached)
        XCTAssertEqual(cached.cards.map(\.id), [plant])
        XCTAssertEqual(cached.cards.first?.personalName, "Saved Monstera")
        let history = try await repo.collectionWateringHistory(plantId: plant, context: lease)
        XCTAssertEqual(history.map(\.id), [entry])
        XCTAssertEqual(history.first?.state, "active")
        XCTAssertEqual(history.first?.occurredLocalDate, "2026-11-03")
        let after = try await state(store, ownerId: owner)
        XCTAssertEqual(after, before)

        await api.bindSyncSession(NativeAuthSession(userId: other, accessToken: "capacity-b", expiresAt: .distantFuture))
        do {
            _ = try await repo.collectionCards(context: lease)
            XCTFail("A revoked lease read the previous owner's cache")
        } catch SyncWireValidationError.invalidSession {}
        let otherLease = try await api.captureSyncContext(ownerId: other)
        do {
            _ = try await repo.collectionCards(context: otherLease)
            XCTFail("Reported an empty offline collection without a synced snapshot")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        let requests = await transport.captured()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
    }

    func testFirstAidControlReadsOwnerSyncAndHidesHistoryAtExpiryOrUndo() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plant = UUID(uuidString: "22222222-2222-4222-8222-000000000001")!
        let otherPlant = UUID(uuidString: "22222222-2222-4222-8222-000000000002")!
        let control = UUID(), actionEntry = UUID()
        let expiry = "2026-11-04T12:00:00+00:00"
        var card = change(1)
        card["data"] = ["id": plant.uuidString, "plant_id": "monstera_deliciosa",
                        "personal_name": "Saved Monstera", "revision": 1, "care_revision": 1] as [String: Any]

        func followup(
            _ id: UUID, plantId: UUID? = nil, state: String = "active",
            due: String = "2026-11-08", source: String = "https://example.invalid/control"
        ) -> [String: Any] {
            [
                "entity_type": "first_aid_followups", "id": id.uuidString, "updated_at": until, "deleted_at": NSNull(),
                "data": [
                    "id": id.uuidString, "plant_id": (plantId ?? plant).uuidString, "action_entry_id": actionEntry.uuidString,
                    "state": state, "action_code": "check_soil",
                    "check_policy_snapshot": [
                        "due_on": due, "interval_days": 5, "source": ["url": source, "locator": "Follow-up interval"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }
        var historical = followup(UUID())
        var historicalData = try XCTUnwrap(historical["data"] as? [String: Any])
        historicalData["check_policy_snapshot"] = [:] as [String: Any]
        historical["data"] = historicalData
        let activeRows = [
            followup(control), followup(UUID(), plantId: otherPlant), followup(UUID(), state: "undone"),
            followup(UUID(), due: "2026-11-31"), followup(UUID(), source: "http://example.invalid/control"), historical
        ].sorted { ($0["id"] as! String) < ($1["id"] as! String) }
        let trial = rights(offer: "trial", trial: expiry)
        let transport = CapacityTransport([
            try json(page(activeRows + [card], entitlement: trial)),
            try json(page(activeRows + [card])),
            try json(page([followup(control, state: "undone"), card]))
        ])
        let api = PlantsAPIClient(transport: transport)
        await api.bindSyncSession(session)
        let lease = try await api.captureSyncContext(ownerId: owner)
        let store = LocalStore(modelContainer: try container(url))
        let repo = repository(store, api)
        _ = try await repo.collectionCards(context: lease)

        let reopened = LocalStore(modelContainer: try container(url))
        let result = try await repository(reopened, api).collectionFirstAidControls(plantId: plant, context: lease)
        let snapshot = try XCTUnwrap(result)
        XCTAssertEqual(snapshot.controls.map(\.id), [control])
        XCTAssertEqual(snapshot.controls.first?.actionEntryId, actionEntry)
        XCTAssertEqual(snapshot.controls.first?.policy.dueOn, "2026-11-08")
        XCTAssertEqual(snapshot.controls.first?.policy.source.url.absoluteString, "https://example.invalid/control")
        let exactExpiry = try XCTUnwrap(SQLTimestamp.date(from: expiry))
        XCTAssertEqual(snapshot.accessUntil, exactExpiry)
        let expiredRepo = CollectionRepository(
            store: reopened, apiClient: api, syncEngine: SyncEngine(store: reopened, apiClient: api),
            clock: { exactExpiry }
        )
        let expired = try await expiredRepo.collectionFirstAidControls(plantId: plant, context: lease)
        XCTAssertNil(expired)
        let retained = try await reopened.activeSyncedEntities(ownerId: owner, entityType: "first_aid_followups")
        XCTAssertEqual(retained.count, activeRows.count)

        _ = try await repo.collectionCards(context: lease)
        let free = try await repo.collectionFirstAidControls(plantId: plant, context: lease)
        XCTAssertEqual(free?.controls.map(\.id), [control])
        XCTAssertNil(free?.accessUntil)
        _ = try await repo.collectionCards(context: lease)
        let undone = try await repo.collectionFirstAidControls(plantId: plant, context: lease)
        XCTAssertNil(undone)
        let history = try await store.activeSyncedEntities(ownerId: owner, entityType: "first_aid_followups")
        XCTAssertEqual(history.map(\.id), [control])

        await api.bindSyncSession(NativeAuthSession(userId: other, accessToken: "capacity-b", expiresAt: .distantFuture))
        do {
            _ = try await repo.collectionFirstAidControls(plantId: plant, context: lease)
            XCTFail("A revoked owner lease read the first-aid control")
        } catch SyncWireValidationError.invalidSession {}
        let otherLease = try await api.captureSyncContext(ownerId: other)
        let inaccessible = try await repo.collectionFirstAidControls(plantId: plant, context: otherLease)
        XCTAssertNil(inaccessible)
        let requests = await transport.captured()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET"])
    }

    private func assertFrozenCommand(_ actual: OutboxEntrySnapshot, _ original: OutboxEntrySnapshot) {
        XCTAssertEqual(actual.operationId, original.operationId)
        XCTAssertEqual(actual.ownerId, original.ownerId)
        XCTAssertEqual(actual.plantId, original.plantId)
        XCTAssertTrue(actual.commandName.utf8.elementsEqual(original.commandName.utf8))
        XCTAssertTrue(actual.payloadJSON.utf8.elementsEqual(original.payloadJSON.utf8))
        XCTAssertEqual(actual.sequenceNumber, original.sequenceNumber)
        XCTAssertEqual(actual.createdAt, original.createdAt)
    }

    func testEnqueueExactReplayAfterDiskRestartPreservesCommittedRetrySnapshot() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original: OutboxEntrySnapshot
        let foreign: OutboxEntrySnapshot
        do {
            let store = LocalStore(modelContainer: try container(url))
            let queued = try await store.enqueueCommand(
                ownerId: owner, plantId: UUID(), commandName: "care.complete", payloadJSON: #" { "amount": 1 } "#
            )
            try await store.recordOutboxFailure(operationId: queued.operationId, errorMessage: "legacy failure")
            try await store.recordOutboxFailure(operationId: queued.operationId, errorMessage: "second failure")
            let pending = try await store.pendingOutboxEntries(for: owner)
            original = try XCTUnwrap(pending.first)
            foreign = try await store.enqueueCommand(
                ownerId: other, plantId: nil, commandName: "care.complete", payloadJSON: "{}"
            )
        }
        for _ in 0..<2 {
            let store = LocalStore(modelContainer: try container(url))
            let replay = try await store.enqueueCommand(
                operationId: original.operationId, ownerId: owner, plantId: original.plantId,
                commandName: original.commandName, payloadJSON: original.payloadJSON
            )
            XCTAssertEqual(replay, original)
            assertFrozenCommand(replay, original)
            XCTAssertEqual(replay.retryCount, 2)
            XCTAssertEqual(replay.lastError, "second failure")
            let own = try await store.pendingOutboxEntries(for: owner)
            let others = try await store.pendingOutboxEntries(for: other)
            XCTAssertEqual(own, [original])
            XCTAssertEqual(others, [foreign])
        }
        let reopened = LocalStore(modelContainer: try container(url))
        let next = try await reopened.enqueueCommand(
            ownerId: owner, plantId: nil, commandName: "care.complete", payloadJSON: "{}"
        )
        XCTAssertEqual(next.sequenceNumber, foreign.sequenceNumber + 1)
    }

    private func assertRejectedReplays(
        foreignOwner: Bool, changes: [(UUID?, String, String)]
    ) async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original: OutboxEntrySnapshot
        let foreign: OutboxEntrySnapshot
        do {
            let store = LocalStore(modelContainer: try container(url))
            let queued = try await store.enqueueCommand(
                ownerId: owner, plantId: other, commandName: "care.complete",
                payloadJSON: "{ \"name\": \"\u{00E9}\", \"amount\": 1 }"
            )
            try await store.recordOutboxFailure(operationId: queued.operationId, errorMessage: "retained")
            let pending = try await store.pendingOutboxEntries(for: owner)
            original = try XCTUnwrap(pending.first)
            foreign = try await store.enqueueCommand(
                ownerId: other, plantId: nil, commandName: "care.complete", payloadJSON: "{}"
            )
        }
        for (plantId, commandName, payload) in changes {
            let store = LocalStore(modelContainer: try container(url))
            do {
                _ = try await store.enqueueCommand(
                    operationId: original.operationId, ownerId: foreignOwner ? other : owner,
                    plantId: plantId, commandName: commandName, payloadJSON: payload
                )
                XCTFail("Conflicting enqueue must fail without returning a queued snapshot")
            } catch {
                XCTAssertEqual(error as? OutboxEnqueueError, .operationIdentityMismatch)
            }
            let reopened = LocalStore(modelContainer: try container(url))
            let own = try await reopened.pendingOutboxEntries(for: owner)
            let others = try await reopened.pendingOutboxEntries(for: other)
            XCTAssertEqual(own, [original])
            assertFrozenCommand(try XCTUnwrap(own.first), original)
            XCTAssertEqual(others, [foreign])
        }
        let reopened = LocalStore(modelContainer: try container(url))
        let next = try await reopened.enqueueCommand(
            ownerId: foreignOwner ? other : owner, plantId: nil,
            commandName: "care.complete", payloadJSON: "{}"
        )
        XCTAssertEqual(next.sequenceNumber, foreign.sequenceNumber + 1)
    }

    func testEnqueueForeignOwnerCollisionCannotExposeOrMutateCommittedQueue() async throws {
        let exact = (Optional(other), "care.complete", "{ \"name\": \"\u{00E9}\", \"amount\": 1 }")
        try await assertRejectedReplays(foreignOwner: true, changes: [exact, exact])
    }

    func testEnqueueChangedPlantCommandOrPayloadCannotMutateDiskOrAllocateSequence() async throws {
        let payload = "{ \"name\": \"\u{00E9}\", \"amount\": 1 }"
        try await assertRejectedReplays(foreignOwner: false, changes: [
            (nil, "care.complete", payload),
            (UUID(), "care.complete", payload),
            (other, "care.undo", payload),
            (other, "care.complete", payload + " "),
            (other, "care.complete", #"{"amount":1,"name":"é"}"#),
            (other, "care.complete", "{ \"name\": \"e\u{0301}\", \"amount\": 1 }"),
            (other, "care.complete", #"{"name":"é","amount":2}"#)
        ])
    }

    private func assertTypedOutboxFailure(
        status: Int, code: String, message: String, retryable: Bool
    ) async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let body = try json(["error": ["code": code, "message": message, "retryable": retryable]])
        let expected = APIErrorResponse(error: .init(code: code, message: message, retryable: retryable))
        let original: OutboxEntrySnapshot
        let foreign: OutboxEntrySnapshot
        do {
            let store = LocalStore(modelContainer: try container(url))
            original = try await store.enqueueCommand(
                ownerId: owner, plantId: nil, commandName: "plant.create",
                payloadJSON: #" { "plant_id":"fixture-fern", "creation_source":"catalogue", "personal_name":"Paproć" } "#
            )
            foreign = try await store.enqueueCommand(
                ownerId: other, plantId: nil, commandName: "care.complete", payloadJSON: "{}"
            )
        }
        var firstBody: Data?
        for attempt in 1...2 {
            do {
                // Recreate the API, engine, actor and disk container for each delivery.
                let store = LocalStore(modelContainer: try container(url))
                let transport = OutboxFailureTransport(status: status, body: body)
                let api = PlantsAPIClient(transport: transport)
                await api.bindSyncSession(session)
                let committed = try await SyncEngine(store: store, apiClient: api).flushOutbox(for: owner)
                XCTAssertEqual(committed, 0)
                let requests = await transport.captured()
                XCTAssertEqual(requests.count, 1)
                let request = try XCTUnwrap(requests.first)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.lastPathComponent, "commands")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), original.operationId.uuidString.lowercased())
                let sentBody = try XCTUnwrap(request.httpBody)
                if let firstBody { XCTAssertEqual(sentBody, firstBody) }
                else { firstBody = sentBody }
                let sent = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: sentBody)
                XCTAssertEqual(sent.operationId, original.operationId)
                XCTAssertEqual(sent.plantId, original.plantId)
                XCTAssertEqual(sent.commandName, original.commandName)
                XCTAssertTrue(sent.payloadJSON.utf8.elementsEqual(original.payloadJSON.utf8))
            }
            let reopened = LocalStore(modelContainer: try container(url))
            let pending = try await reopened.pendingOutboxEntries(for: owner)
            XCTAssertEqual(pending.count, 1)
            let failed = try XCTUnwrap(pending.first)
            assertFrozenCommand(failed, original)
            XCTAssertEqual(failed.retryCount, attempt)
            XCTAssertEqual(failed.lastAPIError, expected)
            let stored = try XCTUnwrap(failed.lastError)
            XCTAssertEqual(try JSONDecoder().decode(APIErrorResponse.self, from: Data(stored.utf8)), expected)
            let replay = try await reopened.enqueueCommand(
                operationId: original.operationId, ownerId: owner, plantId: original.plantId,
                commandName: original.commandName, payloadJSON: original.payloadJSON
            )
            XCTAssertEqual(replay, failed)
            let others = try await reopened.pendingOutboxEntries(for: other)
            XCTAssertEqual(others, [foreign])
            let confirmation = try await reopened.catalogueCreateConfirmation(ownerId: owner, operationId: original.operationId)
            XCTAssertNil(confirmation)
        }
    }

    func testAPI409CollectionLimitPersistsTypedNonretryableFailureThroughEngineAndRestart() async throws {
        try await assertTypedOutboxFailure(
            status: 409, code: "COLLECTION_LIMIT_REACHED",
            message: "Limit kolekcji osiągnięty — spróbuj później.", retryable: false
        )
    }

    func testAPI503InternalErrorPersistsTypedRetryableFailureThroughEngineAndRestart() async throws {
        try await assertTypedOutboxFailure(
            status: 503, code: "INTERNAL_ERROR",
            message: "Temporarily unavailable: \"try again\".\nSpróbuj ponownie.", retryable: true
        )
    }

    func testLegacyAndMalformedErrorTextNeverBecomesTypedAfterDiskRestart() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original: OutboxEntrySnapshot
        do {
            let store = LocalStore(modelContainer: try container(url))
            original = try await store.enqueueCommand(
                ownerId: owner, plantId: nil, commandName: "care.complete", payloadJSON: "{}"
            )
        }
        XCTAssertNil(original.lastAPIError)
        let messages = [
            "COLLECTION_LIMIT_REACHED / QUOTA_EXHAUSTED / UNAUTHORIZED",
            "APIErrorResponse(error: COLLECTION_LIMIT_REACHED)",
            #"{"error":{"code":"COLLECTION_LIMIT_REACHED","message":"Legacy","retryable":"false"}}"#,
            #"{"error":{"code":"INTERNAL_ERROR","message":"Legacy"}}"#,
            #"{"error":{"code":"INTERNAL_ERROR","message":"Legacy","retryable":true}} trailing"#,
            #"{"code":"UNAUTHORIZED","message":"Legacy","retryable":false}"#,
            "{}"
        ]
        for (index, message) in messages.enumerated() {
            do {
                let store = LocalStore(modelContainer: try container(url))
                try await store.recordOutboxFailure(operationId: original.operationId, errorMessage: message)
            }
            let reopened = LocalStore(modelContainer: try container(url))
            let pending = try await reopened.pendingOutboxEntries(for: owner)
            let failed = try XCTUnwrap(pending.first)
            assertFrozenCommand(failed, original)
            XCTAssertEqual(failed.lastError, message)
            XCTAssertEqual(failed.retryCount, index + 1)
            XCTAssertNil(failed.lastAPIError)
        }
    }

    func testNonAPITransportFailureKeepsLegacyDiagnosticAndNilTypedProjectionOnDisk() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original: OutboxEntrySnapshot
        do {
            let store = LocalStore(modelContainer: try container(url))
            original = try await store.enqueueCommand(
                ownerId: owner, plantId: nil, commandName: "plant.create",
                payloadJSON: #"{"plant_id":"fixture-fern","creation_source":"catalogue"}"#
            )
            let transport = OutboxFailureTransport()
            let api = PlantsAPIClient(transport: transport)
            await api.bindSyncSession(session)
            let committed = try await SyncEngine(store: store, apiClient: api).flushOutbox(for: owner)
            XCTAssertEqual(committed, 0)
            let requests = await transport.captured()
            XCTAssertEqual(requests.count, 1)
        }
        let reopened = LocalStore(modelContainer: try container(url))
        let pending = try await reopened.pendingOutboxEntries(for: owner)
        let failed = try XCTUnwrap(pending.first)
        assertFrozenCommand(failed, original)
        XCTAssertEqual(failed.retryCount, 1)
        XCTAssertEqual(failed.lastError, String(describing: URLError(.notConnectedToInternet) as any Error))
        XCTAssertNil(failed.lastAPIError)
    }
}

extension CollectionRepositoryTests {
    private func journalCommand(
        operationId: UUID = UUID(),
        payload: String = #" { "creation_source":"catalogue", "plant_id":"fixture-fern", "personal_name":"é" } "#
    ) -> CommandEnvelopeDTO {
        CommandEnvelopeDTO(operationId: operationId, commandName: "plant.create", payloadJSON: payload)
    }

    private func journalSession() async throws -> (PlantsAPIClient, SyncSessionLease) {
        let api = PlantsAPIClient(transport: CapacityTransport([]))
        await api.bindSyncSession(session)
        return (api, try await api.captureSyncContext(ownerId: owner))
    }

    private func journalPending(_ state: CatalogueCreateJournalState) throws -> OutboxEntrySnapshot {
        guard case let .pending(entry) = state else {
            XCTFail("Expected durable pending command")
            throw SyncWireValidationError.invalidPage
        }
        return entry
    }

    private func journalConfirmed(
        _ state: CatalogueCreateJournalState
    ) throws -> CatalogueCreateConfirmationSnapshot {
        guard case let .confirmed(receipt) = state else {
            XCTFail("Expected durable confirmation")
            throw SyncWireValidationError.invalidPage
        }
        return receipt
    }

    private func journalReceipt() throws -> PlantCreateReceiptDTO {
        try JSONDecoder().decode(PlantCreateReceiptDTO.self, from: json([
            "plant_id": "22222222-2222-4222-8222-222222222222", "care_revision": 1,
            "context_state": "current", "next_available_step": "enable_basic_care",
            "paid_action": NSNull(), "plan_availability": "available", "watermark": "2026-11-04T09:00:00.123456Z"
        ]))
    }

    private struct JournalDisk: Equatable {
        let own: DiskState
        let foreign: DiskState
        let receipts: [Data]
    }

    private func journalDisk(_ url: URL, historicalFiveTables: Bool = false) async throws -> JournalDisk {
        let reopened = try container(url, historicalFiveTables: historicalFiveTables)
        let store = LocalStore(modelContainer: reopened)
        let own = try await state(store, ownerId: owner)
        let foreign = try await state(store, ownerId: other)
        let context = ModelContext(reopened)
        context.autosaveEnabled = false
        let receipts = try context.fetch(FetchDescriptor<CatalogueCreateConfirmationRecord>(
            sortBy: [SortDescriptor(\.compositeKey)]
        )).map {
            Data(($0.compositeKey + "|" + $0.ownerId.uuidString + "|" + $0.operationId.uuidString
                  + "|" + $0.payloadJSON + "|" + $0.receiptJSON).utf8)
        }
        return JournalDisk(own: own, foreign: foreign, receipts: receipts)
    }

    private func assertJournalConflict(
        _ command: CommandEnvelopeDTO, store: LocalStore,
        lease: SyncSessionLease, authority: SyncSessionAuthority
    ) async {
        for mode in [CatalogueCreateJournalMode.checkOnly, .enqueue(canCreate: false), .enqueue(canCreate: true)] {
            do {
                _ = try await store.catalogueCreateJournal(command, mode: mode, context: lease, authority: authority)
                XCTFail("Conflicting identity must not return a snapshot or enqueue")
            } catch OutboxEnqueueError.operationIdentityMismatch {
            } catch CatalogueCreateValidationError.invalidCommand {
            } catch CatalogueCreateValidationError.invalidPayload {
            } catch {
                XCTFail("Unexpected journal conflict error: \(error)")
            }
        }
    }

    private func journalConflicts(_ command: CommandEnvelopeDTO) -> [CommandEnvelopeDTO] {
        [
            CommandEnvelopeDTO(operationId: command.operationId, commandName: "plant.create",
                               plantId: UUID(), payloadJSON: command.payloadJSON),
            CommandEnvelopeDTO(operationId: command.operationId, commandName: "care.complete",
                               payloadJSON: command.payloadJSON),
            journalCommand(operationId: command.operationId, payload: command.payloadJSON + " "),
            journalCommand(operationId: command.operationId,
                           payload: #"{"plant_id":"fixture-fern","creation_source":"catalogue","personal_name":"é"}"#),
            journalCommand(operationId: command.operationId,
                           payload: command.payloadJSON.replacingOccurrences(of: "é", with: "e\u{0301}")),
            journalCommand(operationId: command.operationId,
                           payload: command.payloadJSON.replacingOccurrences(of: "fixture-fern", with: "different"))
        ]
    }

    /// Receipt setup goes through the accepted ACK; it is a fixture, not a live save.
    private func journalSeedStates(
        _ store: LocalStore, lease: SyncSessionLease, authority: SyncSessionAuthority
    ) async throws -> [CommandEnvelopeDTO] {
        let absent = journalCommand()
        let pending = journalCommand()
        let confirmed = journalCommand()
        for command in [pending, confirmed] {
            _ = try await store.catalogueCreateJournal(
                command, mode: .enqueue(canCreate: true), context: lease, authority: authority
            )
        }
        try await store.acknowledgeCatalogueCreate(
            confirmed, receipt: journalReceipt(), context: lease, authority: authority
        )
        return [absent, pending, confirmed]
    }

    private func assertJournalInvalidLease(
        _ commands: [CommandEnvelopeDTO], store: LocalStore,
        lease: SyncSessionLease, authority: SyncSessionAuthority
    ) async {
        for command in commands {
            for mode in [CatalogueCreateJournalMode.checkOnly, .enqueue(canCreate: false), .enqueue(canCreate: true)] {
                do {
                    _ = try await store.catalogueCreateJournal(command, mode: mode, context: lease, authority: authority)
                    XCTFail("Invalid original lease must not read, replay, or insert")
                } catch SyncWireValidationError.invalidSession {
                } catch {
                    XCTFail("Unexpected session error: \(error)")
                }
            }
        }
    }

    func testJournalCheckOnlyAbsentAndBlockedAllocateNothingAcrossReopen() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (api, lease) = try await journalSession()
        let command = journalCommand()
        for seeded in [false, true] {
            if seeded { try await seed(LocalStore(modelContainer: try container(url))) }
            let before = try await journalDisk(url)
            for _ in 0..<2 {
                let store = LocalStore(modelContainer: try container(url))
                let absent = try await store.catalogueCreateJournal(
                    command, mode: .checkOnly, context: lease, authority: api.syncAuthority
                )
                XCTAssertEqual(absent, .absent)
                let blocked = try await store.catalogueCreateJournal(
                    command, mode: .enqueue(canCreate: false), context: lease, authority: api.syncAuthority
                )
                XCTAssertEqual(blocked, .collectionLimitNotEnqueued)
                let after = try await journalDisk(url)
                XCTAssertEqual(after, before)
            }
        }
        let store = LocalStore(modelContainer: try container(url))
        let beforeInvalid = try await journalDisk(url)
        await assertJournalConflict(
            journalCommand(payload: "{}"), store: store, lease: lease, authority: api.syncAuthority
        )
        let afterInvalid = try await journalDisk(url)
        XCTAssertEqual(afterInvalid, beforeInvalid)
        let inserted = try journalPending(await store.catalogueCreateJournal(
            command, mode: .enqueue(canCreate: true), context: lease, authority: api.syncAuthority
        ))
        XCTAssertEqual(inserted.sequenceNumber, 3)
    }

    func testJournalInsertAndPendingReplayBypassFalseCapacityWithFrozenTypedRetry() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (api, lease) = try await journalSession()
        let command = journalCommand()
        let original: OutboxEntrySnapshot
        do {
            let store = LocalStore(modelContainer: try container(url))
            try await seed(store)
            original = try journalPending(await store.catalogueCreateJournal(
                command, mode: .enqueue(canCreate: true), context: lease, authority: api.syncAuthority
            ))
            XCTAssertEqual(original.operationId, command.operationId)
            XCTAssertEqual(original.ownerId, owner)
            XCTAssertNil(original.plantId)
            XCTAssertTrue(original.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8))
            XCTAssertEqual(original.sequenceNumber, 3)
            let typed = String(decoding: try json([
                "error": ["code": "COLLECTION_LIMIT_REACHED", "message": "Limit", "retryable": false]
            ]), as: UTF8.self)
            try await store.recordOutboxFailure(operationId: command.operationId, errorMessage: typed)
        }
        let before = try await journalDisk(url)
        let frozen = try XCTUnwrap(before.own.queue.last)
        XCTAssertEqual(frozen.retryCount, 1)
        XCTAssertEqual(frozen.lastAPIError?.error.code, "COLLECTION_LIMIT_REACHED")
        for _ in 0..<2 {
            let store = LocalStore(modelContainer: try container(url))
            for mode in [CatalogueCreateJournalMode.checkOnly, .enqueue(canCreate: false), .enqueue(canCreate: true)] {
                let replay = try journalPending(await store.catalogueCreateJournal(
                    command, mode: mode, context: lease, authority: api.syncAuthority
                ))
                XCTAssertEqual(replay, frozen)
                assertFrozenCommand(replay, original)
            }
            let after = try await journalDisk(url)
            XCTAssertEqual(after, before)
        }
        let next = try await LocalStore(modelContainer: container(url)).enqueueCommand(
            ownerId: other, plantId: nil, commandName: "care.complete", payloadJSON: "{}"
        )
        XCTAssertEqual(next.sequenceNumber, original.sequenceNumber + 1)
    }

    func testJournalConfirmedReplayBypassesFalseCapacityUsingOriginalACKReceipt() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (api, lease) = try await journalSession()
        let command = journalCommand()
        let receipt = try journalReceipt()
        do {
            let store = LocalStore(modelContainer: try container(url))
            try await seed(store)
            _ = try await store.catalogueCreateJournal(
                command, mode: .enqueue(canCreate: true), context: lease, authority: api.syncAuthority
            )
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: lease, authority: api.syncAuthority
            )
        }
        let before = try await journalDisk(url)
        XCTAssertEqual(before.own.queue.count, 1)
        XCTAssertEqual(before.receipts.count, 1)
        XCTAssertNotEqual(before.own.raw, receipt.watermarkRaw)
        for _ in 0..<2 {
            let store = LocalStore(modelContainer: try container(url))
            for mode in [CatalogueCreateJournalMode.checkOnly, .enqueue(canCreate: false), .enqueue(canCreate: true)] {
                let replay = try journalConfirmed(await store.catalogueCreateJournal(
                    command, mode: mode, context: lease, authority: api.syncAuthority
                ))
                XCTAssertEqual(replay.ownerId, owner)
                XCTAssertEqual(replay.operationId, command.operationId)
                XCTAssertTrue(replay.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8))
                XCTAssertEqual(replay.receipt, receipt)
                XCTAssertEqual(replay.receipt.watermarkRaw, receipt.watermarkRaw)
                XCTAssertNotEqual(replay.receipt.plantId, command.operationId)
            }
            let after = try await journalDisk(url)
            XCTAssertEqual(after, before)
        }
    }

    func testJournalPendingConflictsRejectForeignOwnerAndAllChangedIdentityFields() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (api, lease) = try await journalSession()
        let command = journalCommand()
        let store = LocalStore(modelContainer: try container(url))
        try await seed(store)
        _ = try await store.catalogueCreateJournal(
            command, mode: .enqueue(canCreate: true), context: lease, authority: api.syncAuthority
        )
        let before = try await journalDisk(url)
        for conflict in journalConflicts(command) {
            try await assertJournalConflict(
                conflict, store: LocalStore(modelContainer: container(url)),
                lease: lease, authority: api.syncAuthority
            )
            let after = try await journalDisk(url)
            XCTAssertEqual(after, before)
        }
        let foreignAPI = PlantsAPIClient(transport: CapacityTransport([]))
        await foreignAPI.bindSyncSession(NativeAuthSession(
            userId: other, accessToken: "foreign", expiresAt: .distantFuture
        ))
        let foreignLease = try await foreignAPI.captureSyncContext(ownerId: other)
        await assertJournalConflict(command, store: store, lease: foreignLease, authority: foreignAPI.syncAuthority)
        let after = try await journalDisk(url)
        XCTAssertEqual(after, before)
        // Legacy writers may have stored a different target or command for a new UUID.
        for (plant, name) in [(Optional(UUID()), "plant.create"), (nil, "care.complete")] {
            let expected = journalCommand()
            _ = try await store.enqueueCommand(
                operationId: expected.operationId, ownerId: owner, plantId: plant,
                commandName: name, payloadJSON: expected.payloadJSON
            )
            let collision = try await journalDisk(url)
            await assertJournalConflict(expected, store: store, lease: lease, authority: api.syncAuthority)
            let unchanged = try await journalDisk(url)
            XCTAssertEqual(unchanged, collision)
        }
    }

    func testJournalConfirmedConflictsAndGlobalPendingCollisionPreserveAllReceipts() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (api, lease) = try await journalSession()
        let store = LocalStore(modelContainer: try container(url))
        try await seed(store)
        let commands = try await journalSeedStates(store, lease: lease, authority: api.syncAuthority)
        let command = commands[2]
        let foreignAPI = PlantsAPIClient(transport: CapacityTransport([]))
        await foreignAPI.bindSyncSession(NativeAuthSession(
            userId: other, accessToken: "foreign", expiresAt: .distantFuture
        ))
        let foreignLease = try await foreignAPI.captureSyncContext(ownerId: other)
        let foreignCommand = journalCommand()
        _ = try await store.catalogueCreateJournal(
            foreignCommand, mode: .enqueue(canCreate: true),
            context: foreignLease, authority: foreignAPI.syncAuthority
        )
        try await store.acknowledgeCatalogueCreate(
            foreignCommand, receipt: journalReceipt(),
            context: foreignLease, authority: foreignAPI.syncAuthority
        )
        let before = try await journalDisk(url)
        XCTAssertEqual(before.receipts.count, 2)
        for conflict in journalConflicts(command) {
            try await assertJournalConflict(
                conflict, store: LocalStore(modelContainer: container(url)),
                lease: lease, authority: api.syncAuthority
            )
            let after = try await journalDisk(url)
            XCTAssertEqual(after, before)
        }
        // A legacy global outbox collision must not be hidden by the owner's receipt.
        _ = try await store.enqueueCommand(
            operationId: command.operationId, ownerId: other, plantId: nil,
            commandName: command.commandName, payloadJSON: command.payloadJSON
        )
        let collision = try await journalDisk(url)
        await assertJournalConflict(command, store: store, lease: lease, authority: api.syncAuthority)
        let after = try await journalDisk(url)
        XCTAssertEqual(after, collision)
    }

    func testJournalOriginalLeaseRejectsOwnerSwitchABAAndSignOutForEveryState() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (setupAPI, setupLease) = try await journalSession()
        let store = LocalStore(modelContainer: try container(url))
        try await seed(store)
        let commands = try await journalSeedStates(store, lease: setupLease, authority: setupAPI.syncAuthority)
        let before = try await journalDisk(url)
        for mode in 0..<3 {
            let (api, original) = try await journalSession()
            if mode == 2 {
                await api.bindSyncSession(nil)
            } else {
                await api.bindSyncSession(NativeAuthSession(
                    userId: other, accessToken: "foreign", expiresAt: .distantFuture
                ))
                if mode == 1 { await api.bindSyncSession(session) }
            }
            await assertJournalInvalidLease(commands, store: store, lease: original, authority: api.syncAuthority)
            let after = try await journalDisk(url)
            XCTAssertEqual(after, before)
        }
    }

    func testJournalRejectsUnboundExplicitSessionAndDifferentAuthorityWithoutDiskEffects() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (api, lease) = try await journalSession()
        let store = LocalStore(modelContainer: try container(url))
        let commands = try await journalSeedStates(store, lease: lease, authority: api.syncAuthority)
        let before = try await journalDisk(url)
        let unbound = PlantsAPIClient(transport: CapacityTransport([]))
        let compatibility = try unbound.syncAuthority.capture(ownerId: owner, explicitSession: session)
        XCTAssertEqual(compatibility.session, session)
        await assertJournalInvalidLease(
            commands, store: store, lease: compatibility, authority: unbound.syncAuthority
        )
        let anonymous = try await unbound.captureSyncContext(ownerId: owner)
        await assertJournalInvalidLease(
            commands, store: store, lease: anonymous, authority: unbound.syncAuthority
        )
        // Same owner, token and generation on another authority are not this lease.
        let (otherAPI, _) = try await journalSession()
        await assertJournalInvalidLease(commands, store: store, lease: lease, authority: otherAPI.syncAuthority)
        let after = try await journalDisk(url)
        XCTAssertEqual(after, before)
    }

    func testJournalCancellationCannotInsertReadOrReplayAnyState() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (api, lease) = try await journalSession()
        let store = LocalStore(modelContainer: try container(url))
        try await seed(store)
        let commands = try await journalSeedStates(store, lease: lease, authority: api.syncAuthority)
        let before = try await journalDisk(url)
        for command in commands {
            for mode in [CatalogueCreateJournalMode.checkOnly, .enqueue(canCreate: false), .enqueue(canCreate: true)] {
                let operation = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await store.catalogueCreateJournal(
                        command, mode: mode, context: lease, authority: api.syncAuthority
                    )
                }
                do {
                    _ = try await operation.value
                    XCTFail("Cancelled journal must not return a snapshot or enqueue")
                } catch is CancellationError {
                } catch {
                    XCTFail("Unexpected cancellation error: \(error)")
                }
            }
        }
        let after = try await journalDisk(url)
        XCTAssertEqual(after, before)
    }

    func testJournalFailedSQLiteSaveHasNoPhantomAndWritableRetryInsertsOnce() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (api, lease) = try await journalSession()
        let command = journalCommand()
        do {
            let store = LocalStore(modelContainer: try container(url))
            try await seed(store)
        }
        let before = try await journalDisk(url)
        do {
            let store = LocalStore(modelContainer: try container(url, allowsSave: false))
            for _ in 0..<2 {
                do {
                    _ = try await store.catalogueCreateJournal(
                        command, mode: .enqueue(canCreate: true), context: lease, authority: api.syncAuthority
                    )
                    XCTFail("Real read-only SQLite save must fail")
                } catch {
                    let failure = error as NSError
                    XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                    XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
                }
                let absent = try await store.catalogueCreateJournal(
                    command, mode: .checkOnly, context: lease, authority: api.syncAuthority
                )
                XCTAssertEqual(absent, .absent)
                let blocked = try await store.catalogueCreateJournal(
                    command, mode: .enqueue(canCreate: false), context: lease, authority: api.syncAuthority
                )
                XCTAssertEqual(blocked, .collectionLimitNotEnqueued)
                let local = try await state(store, ownerId: owner)
                XCTAssertEqual(local, before.own)
                let after = try await journalDisk(url)
                XCTAssertEqual(after, before)
            }
        }
        let inserted: OutboxEntrySnapshot
        do {
            let writable = LocalStore(modelContainer: try container(url))
            inserted = try journalPending(await writable.catalogueCreateJournal(
                command, mode: .enqueue(canCreate: true), context: lease, authority: api.syncAuthority
            ))
            XCTAssertEqual(inserted.sequenceNumber, 3)
        }
        let reopened = LocalStore(modelContainer: try container(url))
        let replay = try journalPending(await reopened.catalogueCreateJournal(
            command, mode: .enqueue(canCreate: false), context: lease, authority: api.syncAuthority
        ))
        XCTAssertEqual(replay, inserted)
        let after = try await journalDisk(url)
        XCTAssertEqual(after.own.queue, before.own.queue + [inserted])
        XCTAssertEqual(after.own.raw, before.own.raw)
        XCTAssertEqual(after.foreign, before.foreign)
        XCTAssertEqual(after.receipts, before.receipts)
    }

    func testJournalConcurrentConditionalEnqueueAcrossStoresInsertsOnlyOnce() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (api, lease) = try await journalSession()
        let first = LocalStore(modelContainer: try container(url))
        try await seed(first)
        let before = try await journalDisk(url)
        let second = LocalStore(modelContainer: try container(url))
        let command = journalCommand()
        async let left = first.catalogueCreateJournal(
            command, mode: .enqueue(canCreate: true), context: lease, authority: api.syncAuthority
        )
        async let right = second.catalogueCreateJournal(
            command, mode: .enqueue(canCreate: true), context: lease, authority: api.syncAuthority
        )
        let (leftState, rightState) = try await (left, right)
        let inserted = try journalPending(leftState)
        XCTAssertEqual(rightState, .pending(inserted))
        XCTAssertEqual(inserted.sequenceNumber, 3)
        let after = try await journalDisk(url)
        XCTAssertEqual(after.own.queue, before.own.queue + [inserted])
        XCTAssertEqual(after.foreign, before.foreign)
        XCTAssertEqual(after.own.raw, before.own.raw)
        XCTAssertEqual(after.receipts, before.receipts)
    }
}

/// Scripted HTTP server, including a durable server commit whose first response is lost.
private actor CatalogueSaveTransport: PlantsAPITransport {
    enum Reply: Sendable {
        case http(String, Int, Data)
        case commitAndLose(Data)
        case replayCommitted
    }

    private let replies: [Reply]
    private let suspendAt: Int?
    private var requests: [URLRequest] = []
    private var release: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var committed: [UUID: (body: Data, receipt: Data)] = [:]

    init(_ replies: [Reply], suspendAt: Int? = nil) {
        self.replies = replies
        self.suspendAt = suspendAt
    }

    func captured() -> [URLRequest] { requests }
    func serverCommitCount() -> Int { committed.count }
    func waitForSuspension() async {
        if release != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resume() { release?.resume(); release = nil }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        guard index < replies.count else { throw URLError(.badServerResponse) }
        if index == suspendAt {
            await withCheckedContinuation { continuation in
                release = continuation
                for observer in observers { observer.resume() }
                observers.removeAll()
            }
        }
        let status: Int
        let data: Data
        switch replies[index] {
        case let .http(method, code, body):
            guard request.httpMethod == method,
                  request.url?.lastPathComponent == (method == "GET" ? "sync" : "commands") else {
                throw URLError(.badServerResponse)
            }
            status = code
            data = body
        case let .commitAndLose(receipt):
            guard request.httpMethod == "POST", let body = request.httpBody else {
                throw URLError(.badServerResponse)
            }
            let command = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: body)
            committed[command.operationId] = (body, receipt)
            throw URLError(.networkConnectionLost)
        case .replayCommitted:
            guard request.httpMethod == "POST", let body = request.httpBody else {
                throw URLError(.badServerResponse)
            }
            let command = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: body)
            guard let original = committed[command.operationId], original.body == body else {
                throw URLError(.badServerResponse)
            }
            status = 200
            data = original.receipt
        }
        return (data, HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!)
    }
}

extension CollectionRepositoryTests {
    private func saveStack(
        _ url: URL, _ transport: CatalogueSaveTransport, allowsSave: Bool = true
    ) async throws -> (
        store: LocalStore, api: PlantsAPIClient, engine: SyncEngine, repository: CollectionRepository
    ) {
        let store = LocalStore(modelContainer: try container(url, allowsSave: allowsSave))
        let api = PlantsAPIClient(transport: transport)
        await api.bindSyncSession(session)
        let engine = SyncEngine(store: store, apiClient: api)
        let now = SQLTimestamp.date(from: boundary)!
        let repository = CollectionRepository(store: store, apiClient: api, syncEngine: engine, clock: { now })
        return (store, api, engine, repository)
    }

    private func saved(_ result: CatalogueSaveResult) throws -> CatalogueCreateConfirmationSnapshot {
        guard case let .saved(confirmation) = result else {
            XCTFail("Only a durable typed receipt proves save")
            throw SyncWireValidationError.invalidPage
        }
        return confirmation
    }

    private func savePending(_ result: CatalogueSaveResult) throws -> OutboxEntrySnapshot {
        guard case let .pending(entry) = result else {
            XCTFail("Expected original durable pending command")
            throw SyncWireValidationError.invalidPage
        }
        return entry
    }

    private func enqueueSave(_ command: CommandEnvelopeDTO, _ store: LocalStore) async throws -> OutboxEntrySnapshot {
        try await store.enqueueCommand(
            operationId: command.operationId, ownerId: owner, plantId: command.plantId,
            commandName: command.commandName, payloadJSON: command.payloadJSON
        )
    }

    private func assertCreateRequest(_ request: URLRequest, _ command: CommandEnvelopeDTO) throws {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.lastPathComponent, "commands")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer capacity-a")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), command.operationId.uuidString.lowercased())
        let body = try XCTUnwrap(request.httpBody)
        let sent = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: body)
        XCTAssertEqual(sent, command)
        XCTAssertEqual(Data(sent.payloadJSON.utf8), Data(command.payloadJSON.utf8))
    }

    func testSaveNewFreeTwoThreeAndPaidFourRefreshBeforeExactCreate() async throws {
        for (count, paid) in [(2, false), (3, false), (4, true)] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let command = journalCommand()
            let receipt = try journalReceipt()
            let allowed = count < 3 || paid
            var replies: [CatalogueSaveTransport.Reply] = [
                .http("GET", 200, try json(page(
                    (1...count).map { change($0) }, entitlement: paid ? rights() as Any : NSNull()
                )))
            ]
            if allowed { replies.append(.http("POST", 200, try JSONEncoder().encode(receipt))) }
            let transport = CatalogueSaveTransport(replies)
            let stack = try await saveStack(url, transport)
            let result = try await stack.repository.saveCatalogueCreate(command, session: session, isAnonymous: false)
            let requests = await transport.captured()
            XCTAssertEqual(requests.map(\.httpMethod), allowed ? ["GET", "POST"] : ["GET"])
            XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer capacity-a")
            let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertFalse(query.contains { $0.name == "since" })
            if allowed {
                let confirmation = try saved(result)
                XCTAssertEqual(confirmation.receipt, receipt)
                XCTAssertEqual(confirmation.ownerId, owner)
                XCTAssertEqual(confirmation.operationId, command.operationId)
                XCTAssertEqual(Data(confirmation.payloadJSON.utf8), Data(command.payloadJSON.utf8))
                try assertCreateRequest(requests[1], command)
            } else {
                guard case let .collectionLimitNotEnqueued(capacity) = result else {
                    return XCTFail("Free full collection must not enqueue")
                }
                XCTAssertEqual(capacity.plantCount, 3)
                XCTAssertFalse(capacity.canCreate)
            }
            let disk = try await journalDisk(url)
            XCTAssertTrue(disk.own.queue.isEmpty)
            XCTAssertEqual(disk.receipts.count, allowed ? 1 : 0)
            XCTAssertEqual(disk.own.plants.count, count)
            XCTAssertEqual(disk.own.raw, until) // ACK does not publish its newer watermark/cache.
        }
    }

    func testSaveGuestMalformedUnboundAndDifferentSessionHaveNoEffects() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await seed(LocalStore(modelContainer: container(url)))
        let before = try await journalDisk(url)
        for mode in 0..<6 {
            let transport = CatalogueSaveTransport([])
            let store = LocalStore(modelContainer: try container(url))
            let api = PlantsAPIClient(transport: transport)
            if mode != 2 { await api.bindSyncSession(session) }
            if mode == 3 {
                await api.bindSyncSession(NativeAuthSession(userId: other, accessToken: "b", expiresAt: .distantFuture))
            }
            if mode == 4 {
                await api.bindSyncSession(NativeAuthSession(userId: owner, accessToken: "new", expiresAt: .distantFuture))
            }
            let valid = journalCommand()
            let command = mode == 5
                ? CommandEnvelopeDTO(operationId: valid.operationId, commandName: "care.complete", payloadJSON: valid.payloadJSON)
                : journalCommand(operationId: valid.operationId, payload: mode == 1 ? "{}" : valid.payloadJSON)
            do {
                let result = try await repository(store, api).saveCatalogueCreate(
                    command, session: session, isAnonymous: mode == 0
                )
                XCTAssertEqual(mode, 0)
                XCTAssertEqual(result, .signInRequired)
            } catch CatalogueCreateValidationError.invalidPayload {
                XCTAssertEqual(mode, 1)
            } catch CatalogueCreateValidationError.invalidCommand {
                XCTAssertEqual(mode, 5)
            } catch SyncWireValidationError.invalidSession {
                XCTAssertTrue((2...4).contains(mode))
            }
            let requests = await transport.captured()
            XCTAssertTrue(requests.isEmpty)
            let after = try await journalDisk(url)
            XCTAssertEqual(after, before)
        }
    }

    func testSaveLostCommittedResponseResumesSameBodyAfterRestartAtFullCapacityAndReplaysReceipt() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = journalCommand()
        let receipt = try journalReceipt()
        var committedPlant = change(3)
        committedPlant["id"] = receipt.plantId.uuidString
        let transport = CatalogueSaveTransport([
            .http("GET", 200, try json(page([change(1), change(2)]))),
            .commitAndLose(try JSONEncoder().encode(receipt)),
            .http("GET", 200, try json(page([change(1), change(2), committedPlant]))),
            .replayCommitted
        ])
        let pending: OutboxEntrySnapshot
        do {
            let stack = try await saveStack(url, transport)
            pending = try savePending(await stack.repository.saveCatalogueCreate(
                command, session: session, isAnonymous: false
            ))
            XCTAssertEqual(pending.retryCount, 1)
            XCTAssertNotNil(pending.lastError)
            XCTAssertNil(pending.lastAPIError)
            let full = try confirmed(await stack.repository.preflightCapacity(session: session, isAnonymous: false))
            XCTAssertFalse(full.canCreate)
        }
        let before = try await journalDisk(url)
        XCTAssertEqual(before.own.queue, [pending])
        XCTAssertTrue(before.receipts.isEmpty)
        do {
            let stack = try await saveStack(url, transport)
            for _ in 0..<2 {
                let confirmation = try saved(await stack.repository.saveCatalogueCreate(
                    command, session: session, isAnonymous: false
                ))
                XCTAssertEqual(confirmation.receipt, receipt)
                XCTAssertEqual(confirmation.operationId, command.operationId)
                XCTAssertEqual(Data(confirmation.payloadJSON.utf8), Data(command.payloadJSON.utf8))
            }
        }
        let requests = await transport.captured()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "POST"])
        try assertCreateRequest(requests[1], command)
        try assertCreateRequest(requests[3], command)
        XCTAssertEqual(requests[1].httpBody, requests[3].httpBody)
        let commits = await transport.serverCommitCount()
        XCTAssertEqual(commits, 1)
        let after = try await journalDisk(url)
        XCTAssertTrue(after.own.queue.isEmpty)
        XCTAssertEqual(after.receipts.count, 1)
        XCTAssertEqual(after.own.raw, until)
        XCTAssertNotEqual(after.own.raw, receipt.watermarkRaw)
        XCTAssertEqual(after.own.plants.count, 3)
        XCTAssertTrue(after.own.plants.contains { $0.hasPrefix(receipt.plantId.uuidString) })
        // A fresh repository/client must also replay disk confirmation with zero HTTP.
        let silent = CatalogueSaveTransport([])
        let reopened = try await saveStack(url, silent)
        let replay = try saved(await reopened.repository.saveCatalogueCreate(
            command, session: session, isAnonymous: false
        ))
        XCTAssertEqual(replay.receipt, receipt)
        let noRequests = await silent.captured()
        XCTAssertTrue(noRequests.isEmpty)
    }

    func testSaveServerCapAuthUnavailableAndMalformedReceiptRemainPendingAcrossReopen() async throws {
        for (status, code) in [(409, "COLLECTION_LIMIT_REACHED"), (401, "UNAUTHORIZED"),
                               (503, "INTERNAL_ERROR"), (200, "")] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let command = journalCommand()
            let body = try json(code.isEmpty ? [:] : [
                "error": ["code": code, "message": "Try later", "retryable": status == 503]
            ])
            let transport = CatalogueSaveTransport([
                .http("GET", 200, try json(page([change(1), change(2)]))),
                .http("POST", status, body), .http("POST", status, body)
            ])
            let original: OutboxEntrySnapshot
            do {
                let stack = try await saveStack(url, transport)
                original = try savePending(await stack.repository.saveCatalogueCreate(
                    command, session: session, isAnonymous: false
                ))
                XCTAssertEqual(original.retryCount, 1)
                XCTAssertNotNil(original.lastError)
                XCTAssertEqual(original.lastAPIError?.error.code, code.isEmpty ? nil : code)
                if !code.isEmpty {
                    XCTAssertEqual(original.lastAPIError?.error.retryable, status == 503)
                    XCTAssertEqual(original.lastAPIError?.error.message, "Try later")
                }
            }
            let persisted = try await journalDisk(url)
            XCTAssertEqual(persisted.own.queue, [original])
            XCTAssertTrue(persisted.receipts.isEmpty)
            do {
                let stack = try await saveStack(url, transport)
                let retried = try savePending(await stack.repository.saveCatalogueCreate(
                    command, session: session, isAnonymous: false
                ))
                assertFrozenCommand(retried, original)
                XCTAssertEqual(retried.retryCount, 2)
                XCTAssertEqual(retried.lastAPIError, original.lastAPIError)
                let disk = try await journalDisk(url)
                XCTAssertEqual(disk.own.queue, [retried])
                XCTAssertTrue(disk.receipts.isEmpty)
            }
            let requests = await transport.captured()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "POST"])
            try assertCreateRequest(requests[1], command)
            XCTAssertEqual(requests[1].httpBody, requests[2].httpBody)
        }
    }

    func testSaveUnavailableOrMalformedPreflightPreservesOldDiskWithoutEnqueue() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await seed(LocalStore(modelContainer: container(url)))
        let before = try await journalDisk(url)
        for reply in [
            CatalogueSaveTransport.Reply.http("GET", 503, try json([
                "error": ["code": "INTERNAL_ERROR", "message": "Unavailable", "retryable": true]
            ])),
            .http("GET", 200, try json([:]))
        ] {
            let transport = CatalogueSaveTransport([reply])
            let stack = try await saveStack(url, transport)
            do {
                _ = try await stack.repository.saveCatalogueCreate(journalCommand(), session: session, isAnonymous: false)
                XCTFail("Failed refresh cannot create or manufacture a result")
            } catch {}
            let after = try await journalDisk(url)
            XCTAssertEqual(after, before)
            let requests = await transport.captured()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
        }
    }

    func testSaveOriginalLeaseRejectsOwnerSwitchABAAndCancellationDuringRefreshAndPOST() async throws {
        for suspendedIndex in [0, 1] {
            for mode in 0..<3 {
                let url = try diskURL()
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let command = journalCommand()
                let transport = CatalogueSaveTransport([
                    .http("GET", 200, try json(page([change(1), change(2)]))),
                    .http("POST", 200, try JSONEncoder().encode(journalReceipt()))
                ], suspendAt: suspendedIndex)
                let stack = try await saveStack(url, transport)
                _ = try await stack.store.enqueueCommand(
                    ownerId: other, plantId: nil, commandName: "care.complete", payloadJSON: "{}"
                )
                let caller = session
                let operation = Task {
                    try await stack.repository.saveCatalogueCreate(command, session: caller, isAnonymous: false)
                }
                await transport.waitForSuspension()
                let atBoundary = try await journalDisk(url)
                if mode == 2 {
                    operation.cancel()
                } else {
                    await stack.api.bindSyncSession(NativeAuthSession(
                        userId: other, accessToken: "b", expiresAt: .distantFuture
                    ))
                    if mode == 1 { await stack.api.bindSyncSession(session) }
                }
                await transport.resume()
                do {
                    _ = try await operation.value
                    XCTFail("Original stale/cancelled save cannot return success or pending")
                } catch is CancellationError {
                    XCTAssertEqual(mode, 2)
                } catch SyncWireValidationError.invalidSession {
                    XCTAssertNotEqual(mode, 2)
                }
                let after = try await journalDisk(url)
                XCTAssertEqual(after, atBoundary)
                XCTAssertTrue(after.receipts.isEmpty)
                XCTAssertEqual(after.own.queue.count, suspendedIndex)
                let requests = await transport.captured()
                XCTAssertEqual(requests.count, suspendedIndex + 1)
                XCTAssertTrue(requests.allSatisfy {
                    $0.value(forHTTPHeaderField: "Authorization") == "Bearer capacity-a"
                })
            }
        }
    }

    func testSaveConcurrentActiveDrainReturnsPendingUntilExactDiskACK() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = journalCommand()
        let receipt = try journalReceipt()
        let transport = CatalogueSaveTransport([
            .http("POST", 200, try JSONEncoder().encode(receipt))
        ], suspendAt: 0)
        let stack = try await saveStack(url, transport)
        let original = try await enqueueSave(command, stack.store)
        let foreign = try await stack.store.enqueueCommand(
            ownerId: other, plantId: nil, commandName: "care.complete", payloadJSON: "{}"
        )
        let ownerId = owner
        let drain = Task { try await stack.engine.flushOutbox(for: ownerId) }
        await transport.waitForSuspension()
        let waiting = try savePending(await stack.repository.saveCatalogueCreate(
            command, session: session, isAnonymous: false
        ))
        XCTAssertEqual(waiting, original) // The active drain's zero count is not a receipt.
        let during = try await journalDisk(url)
        XCTAssertEqual(during.own.queue, [original])
        XCTAssertTrue(during.receipts.isEmpty)
        await transport.resume()
        let count = try await drain.value
        XCTAssertEqual(count, 1)
        let confirmation = try saved(await stack.repository.saveCatalogueCreate(
            command, session: session, isAnonymous: false
        ))
        XCTAssertEqual(confirmation.receipt, receipt)
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 1)
        try assertCreateRequest(requests[0], command)
        let after = try await journalDisk(url)
        XCTAssertEqual(after.foreign.queue, [foreign])
        XCTAssertEqual(after.receipts.count, 1)
    }

    func testSaveUnrelatedCommitCountCannotProveTargetSuccess() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let unrelated = journalCommand()
        let target = journalCommand()
        let transport = CatalogueSaveTransport([
            .http("POST", 200, try JSONEncoder().encode(journalReceipt())),
            .http("POST", 409, try json([
                "error": ["code": "COLLECTION_LIMIT_REACHED", "message": "Limit", "retryable": false]
            ]))
        ])
        let stack = try await saveStack(url, transport)
        _ = try await enqueueSave(unrelated, stack.store)
        let original = try await enqueueSave(target, stack.store)
        let pending = try savePending(await stack.repository.saveCatalogueCreate(
            target, session: session, isAnonymous: false
        ))
        assertFrozenCommand(pending, original)
        XCTAssertEqual(pending.lastAPIError?.error.code, "COLLECTION_LIMIT_REACHED")
        let reopened = LocalStore(modelContainer: try container(url))
        let missing = try await reopened.catalogueCreateConfirmation(ownerId: owner, operationId: target.operationId)
        XCTAssertNil(missing)
        let committed = try await reopened.catalogueCreateConfirmation(ownerId: owner, operationId: unrelated.operationId)
        XCTAssertNotNil(committed)
        let disk = try await journalDisk(url)
        XCTAssertEqual(disk.own.queue, [pending])
        XCTAssertEqual(disk.receipts.count, 1)
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 2)
        try assertCreateRequest(requests[0], unrelated)
        try assertCreateRequest(requests[1], target)
    }

    func testSaveOverlappingSameOperationPendingOrACKWinsOverFalseCapacityAfterAwait() async throws {
        for confirmBeforeResume in [false, true] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let command = journalCommand()
            let receipt = try journalReceipt()
            let transport = CatalogueSaveTransport([
                .http("GET", 200, try json(page([change(1), change(2), change(3)]))),
                .http("POST", 200, try JSONEncoder().encode(receipt))
            ], suspendAt: 0)
            let stack = try await saveStack(url, transport)
            let caller = session
            let first = Task {
                try await stack.repository.saveCatalogueCreate(command, session: caller, isAnonymous: false)
            }
            await transport.waitForSuspension()
            _ = try await enqueueSave(command, stack.store)
            if confirmBeforeResume {
                let overlapping = try saved(await stack.repository.saveCatalogueCreate(
                    command, session: session, isAnonymous: false
                ))
                XCTAssertEqual(overlapping.receipt, receipt)
            }
            await transport.resume()
            let confirmation = try saved(await first.value)
            XCTAssertEqual(confirmation.receipt, receipt)
            XCTAssertEqual(confirmation.operationId, command.operationId)
            let requests = await transport.captured()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
            try assertCreateRequest(requests[1], command)
            let disk = try await journalDisk(url)
            XCTAssertEqual(disk.receipts.count, 1)
            XCTAssertTrue(disk.own.queue.isEmpty)
            XCTAssertEqual(disk.own.plants.count, 3)
        }
    }

    func testSaveReadOnlyDiskACKFailurePropagatesAndRetainsOriginalQueue() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = journalCommand()
        do {
            let writable = LocalStore(modelContainer: try container(url))
            _ = try await enqueueSave(command, writable)
        }
        let before = try await journalDisk(url)
        let transport = CatalogueSaveTransport([
            .http("POST", 200, try JSONEncoder().encode(journalReceipt()))
        ])
        do {
            let stack = try await saveStack(url, transport, allowsSave: false)
            do {
                _ = try await stack.repository.saveCatalogueCreate(command, session: session, isAnonymous: false)
                XCTFail("A network receipt is not durable after a failed disk ACK")
            } catch {
                let failure = error as NSError
                XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
            }
        }
        let after = try await journalDisk(url)
        XCTAssertEqual(after, before)
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 1)
        try assertCreateRequest(requests[0], command)
    }
}

extension CollectionRepositoryTests {
    private func inputRows(_ url: URL) throws -> [Data] {
        let disk = ModelContext(try container(url))
        disk.autosaveEnabled = false
        return try disk.fetch(FetchDescriptor<CatalogueInputCheckpointRecord>(
            sortBy: [SortDescriptor(\.compositeKey)]
        )).map {
            Data([$0.compositeKey, $0.ownerId.uuidString, $0.flowId.uuidString, $0.operationId.uuidString,
                  $0.payloadJSON, $0.createdAt.timeIntervalSince1970.description].joined(separator: "|").utf8)
        }
    }

    /// Supplement JournalDisk with every persisted field of the other three old tables.
    private func legacyCacheBytes(_ url: URL, historicalFiveTables: Bool = false) throws -> [Data] {
        let disk = ModelContext(try container(url, historicalFiveTables: historicalFiveTables))
        disk.autosaveEnabled = false
        func bytes(_ fields: [String?]) throws -> Data {
            try JSONEncoder().encode(fields)
        }
        let entities = try disk.fetch(FetchDescriptor<SyncedEntityRecord>(
            sortBy: [SortDescriptor(\.compositeKey)]
        )).map {
            try bytes([$0.compositeKey, $0.ownerId.uuidString, $0.entityType, $0.entityId.uuidString,
                       $0.updatedAt.timeIntervalSince1970.description,
                       $0.deletedAt?.timeIntervalSince1970.description, $0.payloadJSON, $0.updatedAtRaw])
        }
        let checkpoints = try disk.fetch(FetchDescriptor<SyncCheckpointRecord>())
            .sorted { $0.ownerId.uuidString < $1.ownerId.uuidString }.map {
            try bytes([$0.ownerId.uuidString, $0.watermark?.timeIntervalSince1970.description,
                       $0.watermarkRaw, $0.syncProfileJSON, $0.syncEntitlementJSON,
                       $0.freeSelectionRevision.description, $0.entitlementValidUntil?.timeIntervalSince1970.description,
                       $0.entitlementTrialEndAt?.timeIntervalSince1970.description, $0.entitlementOfferKind,
                       $0.entitlementState, $0.updatedAt.timeIntervalSince1970.description])
        }
        let guests = try disk.fetch(FetchDescriptor<GuestDraftCacheRecord>())
            .sorted { $0.draftId.uuidString < $1.draftId.uuidString }.map {
            try bytes([$0.draftId.uuidString, $0.flowId.uuidString, $0.intentRaw, $0.addMethodRaw,
                       $0.currentStepRaw, $0.photoLocalPath, $0.confirmedPlantId,
                       $0.confirmedTaxonId?.uuidString, $0.confirmedDisplayName, $0.conditionsJSON,
                       $0.resultModeRaw, $0.preliminaryAnalysisJSON, $0.analysisReceiptJSON, $0.overridesJSON,
                       $0.serverExpiresAt.timeIntervalSince1970.description,
                       $0.isCompleteForFallback.description, $0.updatedAt.timeIntervalSince1970.description])
        }
        return entities + checkpoints + guests
    }

    private func assertInputLeaseRejected(
        _ store: LocalStore, flowId: UUID, operationId: UUID, input: CatalogueInput,
        lease: SyncSessionLease, authority: SyncSessionAuthority, cancelled: Bool = false
    ) async {
        let absentFlow = UUID()
        for mode in 0..<4 {
            let attempt = Task<CatalogueInputCheckpointSnapshot?, Error> {
                if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                let flow = mode % 2 == 0 ? flowId : absentFlow
                if mode < 2 {
                    return try await store.catalogueInputCheckpoint(flowId: flow, context: lease, authority: authority)
                }
                return try await store.checkpointCatalogueInput(
                    input, flowId: flow, operationId: operationId, context: lease, authority: authority
                )
            }
            do {
                _ = try await attempt.value
                XCTFail("Invalid original lease must not read, replay, or insert input")
            } catch is CancellationError {
                XCTAssertTrue(cancelled)
            } catch SyncWireValidationError.invalidSession {
                XCTAssertFalse(cancelled)
            } catch {
                XCTFail("Unexpected checkpoint lease error: \(error)")
            }
        }
    }

    func testCatalogueInputBuilderSavesBareSpeciesAndExactOptionalUnicodeThroughAcceptedPath() async throws {
        for name in [nil, "", "  e\u{0301} 🌿 \"\n"] as [String?] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = CatalogueSaveTransport([
                .http("GET", 200, try json(page())),
                .http("POST", 200, try JSONEncoder().encode(journalReceipt()))
            ])
            let stack = try await saveStack(url, transport)
            let lease = try await stack.api.captureSyncContext(ownerId: owner)
            let input = CatalogueInput(speciesSlug: "fixture-fern", personalName: name)
            let operationId = UUID()
            let command = try input.makeEnvelope(operationId: operationId)
            let repeated = try input.makeEnvelope(operationId: operationId)
            XCTAssertEqual(Data(command.payloadJSON.utf8), Data(repeated.payloadJSON.utf8))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.payloadJSON.utf8)) as? [String: String])
            let expectedKeys: Set<String> = name == nil
                ? ["creation_source", "plant_id"] : ["creation_source", "plant_id", "personal_name"]
            XCTAssertEqual(Set(payload.keys), expectedKeys)
            XCTAssertEqual(payload["plant_id"], input.speciesSlug)
            XCTAssertEqual(payload["creation_source"], "catalogue")
            XCTAssertEqual(payload["personal_name"].map { Data($0.utf8) }, name.map { Data($0.utf8) })
            let frozen = try await stack.store.checkpointCatalogueInput(
                input, flowId: UUID(), operationId: operationId, context: lease, authority: stack.api.syncAuthority
            )
            let confirmation = try saved(await stack.repository.saveCatalogueCreate(
                frozen.envelope, session: session, isAnonymous: false
            ))
            XCTAssertEqual(confirmation.operationId, operationId)
            XCTAssertEqual(Data(confirmation.payloadJSON.utf8), Data(command.payloadJSON.utf8))
            let requests = await transport.captured()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
            try assertCreateRequest(requests[1], command)
            let replay = try await stack.store.catalogueInputCheckpoint(
                flowId: frozen.flowId, context: lease, authority: stack.api.syncAuthority
            )
            XCTAssertEqual(replay, frozen)
        }
    }

    func testCatalogueInputInvalidSpeciesFailsBeforeCacheOrRequestsWithoutTrimmingValidBytes() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = CatalogueSaveTransport([])
        let stack = try await saveStack(url, transport)
        let lease = try await stack.api.captureSyncContext(ownerId: owner)
        let before = try await journalDisk(url)
        for slug in ["", " ", "\n\t"] {
            let input = CatalogueInput(speciesSlug: slug)
            XCTAssertThrowsError(try input.makeEnvelope(operationId: UUID()))
            do {
                _ = try await stack.store.checkpointCatalogueInput(
                    input, flowId: UUID(), operationId: UUID(), context: lease, authority: stack.api.syncAuthority
                )
                XCTFail("Invalid species must fail before local persistence")
            } catch CatalogueCreateValidationError.invalidPayload {}
        }
        XCTAssertTrue(try inputRows(url).isEmpty)
        let requests = await transport.captured()
        XCTAssertTrue(requests.isEmpty)
        let after = try await journalDisk(url)
        XCTAssertEqual(after, before)
        let exact = CatalogueInput(speciesSlug: "  fixture-fern  ", personalName: " e\u{0301} ")
        let command = try exact.makeEnvelope(operationId: UUID())
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.payloadJSON.utf8)) as? [String: String])
        XCTAssertEqual(Data(try XCTUnwrap(payload["plant_id"]).utf8), Data(try XCTUnwrap(exact.speciesSlug).utf8))
        XCTAssertEqual(Data(try XCTUnwrap(payload["personal_name"]).utf8), Data(try XCTUnwrap(exact.personalName).utf8))
        XCTAssertTrue(command.payloadJSON.hasPrefix(#"{"creation_source":"catalogue","personal_name":"#))
    }

    func testCatalogueInputDiskRestartFreezesFlowOperationPayloadAndCreationTime() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (api, lease) = try await journalSession()
        let input = CatalogueInput(speciesSlug: "fixture-fern", personalName: "e\u{0301}")
        let flow = UUID(), operation = UUID()
        let original: CatalogueInputCheckpointSnapshot
        do {
            let store = LocalStore(modelContainer: try container(url))
            try await seed(store)
            original = try await store.checkpointCatalogueInput(
                input, flowId: flow, operationId: operation, context: lease, authority: api.syncAuthority
            )
        }
        let before = try await journalDisk(url)
        let rows = try inputRows(url)
        let reopened = LocalStore(modelContainer: try container(url))
        let read = try await reopened.catalogueInputCheckpoint(flowId: flow, context: lease, authority: api.syncAuthority)
        XCTAssertEqual(read, original)
        let retry = try await reopened.checkpointCatalogueInput(
            input, flowId: flow, operationId: operation, context: lease, authority: api.syncAuthority
        )
        XCTAssertEqual(retry, original)
        XCTAssertEqual(retry.flowId, flow)
        XCTAssertEqual(retry.operationId, operation)
        for (edited, op) in [
            (input, UUID()),
            (CatalogueInput(speciesSlug: "other"), operation),
            (CatalogueInput(speciesSlug: "fixture-fern", personalName: "é"), operation),
            (CatalogueInput(speciesSlug: "fixture-fern"), operation)
        ] {
            do {
                _ = try await reopened.checkpointCatalogueInput(
                    edited, flowId: flow, operationId: op, context: lease, authority: api.syncAuthority
                )
                XCTFail("A frozen flow cannot be rewritten")
            } catch CatalogueInputCheckpointError.flowIdentityMismatch {}
        }
        XCTAssertEqual(try inputRows(url), rows)
        let after = try await journalDisk(url)
        XCTAssertEqual(after, before)
        let newFlow = try await reopened.checkpointCatalogueInput(
            CatalogueInput(speciesSlug: "other"), flowId: UUID(), operationId: UUID(),
            context: lease, authority: api.syncAuthority
        )
        XCTAssertNotEqual(newFlow.flowId, flow)
        XCTAssertNotEqual(newFlow.operationId, operation)
        XCTAssertEqual(try inputRows(url).count, 2)
    }

    func testCatalogueInputAnonymousCacheIsOwnerScopedAndNeverGrantsCreatePermission() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = CatalogueSaveTransport([])
        let stack = try await saveStack(url, transport)
        let lease = try await stack.api.captureSyncContext(ownerId: owner)
        let before = try await journalDisk(url)
        let flow = UUID()
        let cached = try await stack.store.checkpointCatalogueInput(
            CatalogueInput(speciesSlug: "fixture-fern"), flowId: flow, operationId: UUID(),
            context: lease, authority: stack.api.syncAuthority
        )
        let result = try await stack.repository.saveCatalogueCreate(cached.envelope, session: session, isAnonymous: true)
        XCTAssertEqual(result, .signInRequired)
        await stack.api.bindSyncSession(NativeAuthSession(userId: other, accessToken: "b", expiresAt: .distantFuture))
        let otherLease = try await stack.api.captureSyncContext(ownerId: other)
        let absent = try await stack.store.catalogueInputCheckpoint(
            flowId: flow, context: otherLease, authority: stack.api.syncAuthority
        )
        XCTAssertNil(absent)
        let otherCache = try await stack.store.checkpointCatalogueInput(
            CatalogueInput(speciesSlug: "other"), flowId: flow, operationId: UUID(),
            context: otherLease, authority: stack.api.syncAuthority
        )
        XCTAssertEqual(otherCache.ownerId, other)
        XCTAssertEqual(cached.ownerId, owner)
        XCTAssertNotEqual(otherCache.operationId, cached.operationId)
        XCTAssertEqual(try inputRows(url).count, 2)
        let requests = await transport.captured()
        XCTAssertTrue(requests.isEmpty)
        let after = try await journalDisk(url)
        XCTAssertEqual(after, before)
    }

    func testCatalogueInputOriginalLeaseRejectsSwitchABASignoutUnboundForeignAuthorityAndCancellation() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LocalStore(modelContainer: try container(url))
        let input = CatalogueInput(speciesSlug: "fixture-fern")
        let flow = UUID(), operation = UUID()
        let (initial, originalLease) = try await journalSession()
        _ = try await store.checkpointCatalogueInput(
            input, flowId: flow, operationId: operation, context: originalLease, authority: initial.syncAuthority
        )
        let before = try await journalDisk(url)
        let rows = try inputRows(url)
        for mode in 0..<7 {
            let (api, lease) = try await journalSession()
            var checkedLease = lease
            var authority = api.syncAuthority
            switch mode {
            case 0, 1:
                await api.bindSyncSession(NativeAuthSession(userId: other, accessToken: "b", expiresAt: .distantFuture))
                if mode == 1 { await api.bindSyncSession(session) }
            case 2:
                await api.bindSyncSession(nil)
            case 3, 4:
                let unbound = PlantsAPIClient(transport: CapacityTransport([]))
                authority = unbound.syncAuthority
                checkedLease = mode == 3
                    ? try authority.capture(ownerId: owner, explicitSession: session)
                    : try await unbound.captureSyncContext(ownerId: owner)
            case 5:
                let (different, _) = try await journalSession()
                authority = different.syncAuthority
            default: break
            }
            await assertInputLeaseRejected(
                store, flowId: flow, operationId: operation, input: input,
                lease: checkedLease, authority: authority, cancelled: mode == 6
            )
        }
        XCTAssertEqual(try inputRows(url), rows)
        let after = try await journalDisk(url)
        XCTAssertEqual(after, before)
    }

    func testCatalogueInputChecksGlobalQueueIdentityAndOwnConfirmationWithoutChangingJournal() async throws {
        for mode in 0..<8 {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let (api, lease) = try await journalSession()
            let store = LocalStore(modelContainer: try container(url))
            let input = CatalogueInput(speciesSlug: "fixture-fern", personalName: "é")
            let op = UUID(), flow = UUID()
            let command = try input.makeEnvelope(operationId: op)
            let changed = try CatalogueInput(speciesSlug: "fixture-fern", personalName: "different").makeEnvelope(operationId: op)
            let queuedPayload: String
            switch mode {
            case 3: queuedPayload = command.payloadJSON + " "
            case 4: queuedPayload = command.payloadJSON.replacingOccurrences(of: "é", with: "e\u{0301}")
            case 5: queuedPayload = changed.payloadJSON
            default: queuedPayload = command.payloadJSON
            }
            let queued = CommandEnvelopeDTO(
                operationId: op, commandName: mode == 2 ? "care.complete" : "plant.create",
                plantId: mode == 1 ? UUID() : nil, payloadJSON: queuedPayload
            )
            _ = try await store.enqueueCommand(
                operationId: op, ownerId: mode == 0 ? other : owner,
                plantId: queued.plantId, commandName: queued.commandName, payloadJSON: queued.payloadJSON
            )
            if mode == 5 || mode == 7 {
                try await store.acknowledgeCatalogueCreate(
                    queued, receipt: journalReceipt(), context: lease, authority: api.syncAuthority
                )
            }
            let before = try await journalDisk(url)
            do {
                let cached = try await store.checkpointCatalogueInput(
                    input, flowId: flow, operationId: op, context: lease, authority: api.syncAuthority
                )
                XCTAssertTrue(mode >= 6)
                let read = try await store.catalogueInputCheckpoint(flowId: flow, context: lease, authority: api.syncAuthority)
                XCTAssertEqual(read, cached)
            } catch OutboxEnqueueError.operationIdentityMismatch {
                XCTAssertTrue(mode < 6)
            }
            XCTAssertEqual(try inputRows(url).count, mode >= 6 ? 1 : 0)
            let after = try await journalDisk(url)
            XCTAssertEqual(after, before)
        }
    }

    func testCatalogueInputReadOnlySQLiteFailureHasNoPhantomAndWritableRetryPersistsOnce() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (api, lease) = try await journalSession()
        let input = CatalogueInput(speciesSlug: "fixture-fern")
        let flow = UUID(), op = UUID()
        try await seed(LocalStore(modelContainer: container(url)))
        let before = try await journalDisk(url)
        do {
            let store = LocalStore(modelContainer: try container(url, allowsSave: false))
            for _ in 0..<2 {
                do {
                    _ = try await store.checkpointCatalogueInput(
                        input, flowId: flow, operationId: op, context: lease, authority: api.syncAuthority
                    )
                    XCTFail("Real read-only SQLite save must fail")
                } catch {
                    let failure = error as NSError
                    XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                    XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
                }
                let absent = try await store.catalogueInputCheckpoint(flowId: flow, context: lease, authority: api.syncAuthority)
                XCTAssertNil(absent)
                let reopened = LocalStore(modelContainer: try container(url))
                let diskAbsent = try await reopened.catalogueInputCheckpoint(
                    flowId: flow, context: lease, authority: api.syncAuthority
                )
                XCTAssertNil(diskAbsent)
                XCTAssertTrue(try inputRows(url).isEmpty)
            }
        }
        let writable = LocalStore(modelContainer: try container(url))
        let saved = try await writable.checkpointCatalogueInput(
            input, flowId: flow, operationId: op, context: lease, authority: api.syncAuthority
        )
        let retry = try await writable.checkpointCatalogueInput(
            input, flowId: flow, operationId: op, context: lease, authority: api.syncAuthority
        )
        XCTAssertEqual(retry, saved)
        let reopened = LocalStore(modelContainer: try container(url))
        let read = try await reopened.catalogueInputCheckpoint(flowId: flow, context: lease, authority: api.syncAuthority)
        XCTAssertEqual(read, saved)
        XCTAssertEqual(try inputRows(url).count, 1)
        let after = try await journalDisk(url)
        XCTAssertEqual(after, before)
    }

    func testCatalogueInputHistoricalFiveTableSQLiteUpgradePreservesEverySeededTable() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (api, lease) = try await journalSession()
        let draftId = UUID()
        let guest = GuestDraftCacheSnapshot(
            draftId: draftId, flowState: AddFlowState(
                intent: .problem, addMethod: .scan, currentStep: .preliminaryResult,
                photoLocalIdentifier: "old/photo.jpg", confirmedPlantId: "fixture-fern",
                conditions: CareConditionsInput(
                    lightLevel: .brightIndirect, lightSource: .cameraEstimate, lightConfirmed: true,
                    wateringHabit: .moderate, lastWatered: .within7Days,
                    potType: .standardDrainage, seasonOverride: .auto
                ), resultMode: .diagnosis, draftId: draftId
            ),
            serverExpiresAt: Date(timeIntervalSince1970: 1), isCompleteForFallback: true
        )
        let confirmedCommand: CommandEnvelopeDTO
        do {
            let historical = try container(url, historicalFiveTables: true)
            XCTAssertEqual(historical.schema.entities.count, 5)
            let store = LocalStore(modelContainer: historical)
            try await seed(store)
            confirmedCommand = try CatalogueInput(speciesSlug: "fixture-fern").makeEnvelope(operationId: UUID())
            _ = try await store.catalogueCreateJournal(
                confirmedCommand, mode: .enqueue(canCreate: true), context: lease, authority: api.syncAuthority
            )
            try await store.acknowledgeCatalogueCreate(
                confirmedCommand, receipt: journalReceipt(), context: lease, authority: api.syncAuthority
            )
            try await store.saveGuestDraft(guest)
            let disk = ModelContext(historical)
            disk.autosaveEnabled = false
            let checkpoint = try XCTUnwrap(disk.fetch(FetchDescriptor<SyncCheckpointRecord>()).first)
            checkpoint.freeSelectionRevision = 17
            checkpoint.entitlementValidUntil = Date(timeIntervalSince1970: 123)
            checkpoint.entitlementTrialEndAt = Date(timeIntervalSince1970: 456)
            checkpoint.entitlementOfferKind = "legacy-offer"
            checkpoint.entitlementState = "legacy-state"
            try disk.save()
        }
        let before = try await journalDisk(url, historicalFiveTables: true)
        let oldCache = try legacyCacheBytes(url, historicalFiveTables: true)
        XCTAssertEqual(before.own.queue.count, 1)
        XCTAssertEqual(before.foreign.queue.count, 1)
        XCTAssertEqual(before.receipts.count, 1)
        XCTAssertEqual(oldCache.count, 3) // entity, sync checkpoint, guest cache
        let upgraded = try container(url)
        XCTAssertEqual(upgraded.schema.entities.count, 6)
        let store = LocalStore(modelContainer: upgraded)
        let loaded = try await store.loadGuestDraft(draftId: draftId)
        XCTAssertEqual(loaded?.flowState.flowId, guest.flowState.flowId)
        XCTAssertEqual(loaded?.flowState.conditions, guest.flowState.conditions)
        XCTAssertEqual(loaded?.flowState.photoLocalIdentifier, guest.flowState.photoLocalIdentifier)
        XCTAssertEqual(loaded?.serverExpiresAt, guest.serverExpiresAt)
        XCTAssertEqual(loaded?.isCompleteForFallback, guest.isCompleteForFallback)
        let confirmation = try journalConfirmed(await store.catalogueCreateJournal(
            confirmedCommand, mode: .checkOnly, context: lease, authority: api.syncAuthority
        ))
        XCTAssertEqual(confirmation.receipt, try journalReceipt())
        let cached = try await store.checkpointCatalogueInput(
            CatalogueInput(speciesSlug: "fixture-fern"), flowId: UUID(), operationId: UUID(),
            context: lease, authority: api.syncAuthority
        )
        let reopened = LocalStore(modelContainer: try container(url))
        let read = try await reopened.catalogueInputCheckpoint(
            flowId: cached.flowId, context: lease, authority: api.syncAuthority
        )
        XCTAssertEqual(read, cached)
        let after = try await journalDisk(url)
        XCTAssertEqual(after, before)
        XCTAssertEqual(try legacyCacheBytes(url), oldCache)
        XCTAssertEqual(try inputRows(url).count, 1)
    }

    func testCatalogueInputMalformedStoredPayloadAndLaterQueueConflictFailClosedWithoutRepair() async throws {
        let input = CatalogueInput(speciesSlug: "fixture-fern")
        let canonical = try input.makeEnvelope(operationId: UUID()).payloadJSON
        for payload in ["{}", canonical + " ",
                        #"{"creation_source":"catalogue","personal_name":null,"plant_id":"fixture-fern"}"#,
                        #"{"creation_source":"catalogue","plant_id":"fixture-fern","rooms":[]}"#,
                        #"{"creation_source":"catalogue","plant_id":""}"#, canonical] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let (api, lease) = try await journalSession()
            let model = try container(url)
            let store = LocalStore(modelContainer: model)
            let flow = UUID(), op = UUID()
            let disk = ModelContext(model)
            disk.autosaveEnabled = false
            disk.insert(CatalogueInputCheckpointRecord(
                ownerId: owner, flowId: flow, operationId: op, payloadJSON: payload,
                createdAt: Date(timeIntervalSince1970: 10)
            ))
            try disk.save()
            if payload == canonical {
                _ = try await store.enqueueCommand(
                    operationId: op, ownerId: other, plantId: nil, commandName: "plant.create", payloadJSON: canonical
                )
            }
            let rows = try inputRows(url)
            let before = try await journalDisk(url)
            for writing in [false, true] {
                do {
                    if writing {
                        _ = try await store.checkpointCatalogueInput(
                            input, flowId: flow, operationId: op, context: lease, authority: api.syncAuthority
                        )
                    } else {
                        _ = try await store.catalogueInputCheckpoint(flowId: flow, context: lease, authority: api.syncAuthority)
                    }
                    XCTFail("Malformed input or a conflicting queue must fail closed")
                } catch CatalogueInputCheckpointError.invalidStoredInput {
                    XCTAssertNotEqual(payload, canonical)
                } catch CatalogueCreateValidationError.invalidPayload {
                    XCTAssertNotEqual(payload, canonical)
                } catch OutboxEnqueueError.operationIdentityMismatch {
                    XCTAssertEqual(payload, canonical)
                }
            }
            XCTAssertEqual(try inputRows(url), rows)
            let after = try await journalDisk(url)
            XCTAssertEqual(after, before)
        }
    }

    func testCatalogueInputConcurrentDifferentAuthoritiesCannotRewriteFirstSuccessfulCheckpoint() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (firstAPI, firstLease) = try await journalSession()
        let (secondAPI, secondLease) = try await journalSession()
        let firstStore = LocalStore(modelContainer: try container(url))
        let secondStore = LocalStore(modelContainer: try container(url))
        let before = try await journalDisk(url)
        let flow = UUID()
        let first = Task {
            try await firstStore.checkpointCatalogueInput(
                CatalogueInput(speciesSlug: "first"), flowId: flow, operationId: UUID(),
                context: firstLease, authority: firstAPI.syncAuthority
            )
        }
        let second = Task {
            try await secondStore.checkpointCatalogueInput(
                CatalogueInput(speciesSlug: "second"), flowId: flow, operationId: UUID(),
                context: secondLease, authority: secondAPI.syncAuthority
            )
        }
        var successes: [CatalogueInputCheckpointSnapshot] = []
        for result in [await first.result, await second.result] {
            switch result {
            case let .success(snapshot): successes.append(snapshot)
            case let .failure(error):
                XCTAssertEqual(error as? CatalogueInputCheckpointError, .flowIdentityMismatch)
            }
        }
        XCTAssertEqual(successes.count, 1)
        let winner = try XCTUnwrap(successes.first)
        let reopened = LocalStore(modelContainer: try container(url))
        let read = try await reopened.catalogueInputCheckpoint(
            flowId: flow, context: firstLease, authority: firstAPI.syncAuthority
        )
        XCTAssertEqual(read, winner)
        XCTAssertEqual(try inputRows(url).count, 1)
        let after = try await journalDisk(url)
        XCTAssertEqual(after, before)
    }
}
