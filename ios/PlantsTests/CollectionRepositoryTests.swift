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

    private func container(_ url: URL) throws -> ModelContainer {
        let schema = Schema([
            LocalOutboxRecord.self, CatalogueCreateConfirmationRecord.self,
            GuestDraftCacheRecord.self, SyncedEntityRecord.self, SyncCheckpointRecord.self
        ])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
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
