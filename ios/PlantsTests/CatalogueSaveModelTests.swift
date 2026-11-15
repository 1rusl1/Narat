import Foundation
import Observation
import XCTest
import SwiftData
@testable import Plants

/// Only transport is scripted. All model/repository/engine/disk behavior is production code.
private actor SaveModelTransport: PlantsAPITransport {
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
    private var committed: [UUID: (Data, Data)] = [:]

    init(_ replies: [Reply], suspendAt: Int? = nil) {
        self.replies = replies
        self.suspendAt = suspendAt
    }

    func captured() -> [URLRequest] { requests }
    func commitCount() -> Int { committed.count }
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
            guard let original = committed[command.operationId], original.0 == body else {
                throw URLError(.badServerResponse)
            }
            status = 200
            data = original.1
        }
        return (data, HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!)
    }
}

@MainActor
final class CatalogueSaveModelTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let other = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let input = CatalogueInput(speciesSlug: "fixture-fern", personalName: " e\u{0301} ")
    private var session: NativeAuthSession {
        NativeAuthSession(userId: owner, accessToken: "model-a", expiresAt: .distantFuture)
    }
    private var otherSession: NativeAuthSession {
        NativeAuthSession(userId: other, accessToken: "model-b", expiresAt: .distantFuture)
    }
    private var refreshedSession: NativeAuthSession {
        NativeAuthSession(userId: owner, accessToken: "model-refreshed", expiresAt: .distantFuture)
    }

    @MainActor
    private final class ObserverReadings {
        var states: [CatalogueSaveState] = []
        var inputs: [CatalogueInput?] = []
        var checkpoints: [CatalogueInputCheckpointSnapshot?] = []

        func read(_ model: CatalogueSaveModel) {
            states.append(model.state)
            inputs.append(model.input)
            checkpoints.append(model.checkpoint)
        }
    }

    private struct Stack {
        let store: LocalStore
        let api: PlantsAPIClient
        let repository: CollectionRepository
    }

    private func diskURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("model.sqlite")
    }

    private func container(_ url: URL, allowsSave: Bool = true) throws -> ModelContainer {
        let schema = Schema([
            LocalOutboxRecord.self, CatalogueCreateConfirmationRecord.self,
            CatalogueInputCheckpointRecord.self, GuestDraftCacheRecord.self,
            SyncedEntityRecord.self, SyncCheckpointRecord.self
        ])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, allowsSave: allowsSave)
        ])
    }

    private func stack(
        _ url: URL, _ transport: SaveModelTransport,
        session snapshot: NativeAuthSession? = nil, allowsSave: Bool = true
    ) async throws -> Stack {
        let store = LocalStore(modelContainer: try container(url, allowsSave: allowsSave))
        let api = PlantsAPIClient(transport: transport)
        await api.bindSyncSession(snapshot ?? session)
        let engine = SyncEngine(store: store, apiClient: api)
        return Stack(store: store, api: api, repository: CollectionRepository(
            store: store, apiClient: api, syncEngine: engine
        ))
    }

    private func model(
        _ stack: Stack, flow: UUID, operation: UUID, guest: Bool = false
    ) async throws -> CatalogueSaveModel {
        try await CatalogueSaveModel(
            store: stack.store, apiClient: stack.api, repository: stack.repository,
            flowId: flow, operationId: operation, input: input,
            session: session, isAnonymous: guest
        )
    }

    private func restoration(
        _ stack: Stack, flow: UUID, snapshot: NativeAuthSession? = nil, guest: Bool = false
    ) async -> CatalogueSaveRestoration {
        let sdk = snapshot ?? session
        return await CatalogueSaveModel.restore(
            store: stack.store, apiClient: stack.api, repository: stack.repository,
            ownerId: sdk.userId, flowId: flow, session: sdk, isAnonymous: guest
        )
    }

    private func restored(_ result: CatalogueSaveRestoration) throws -> CatalogueSaveModel {
        guard case let .restored(model) = result else {
            XCTFail("Expected actual disk checkpoint restoration")
            throw CatalogueSaveUnavailable.storageOrServiceUnavailable
        }
        return model
    }

    private func pending(_ model: CatalogueSaveModel) throws -> OutboxEntrySnapshot {
        guard case let .pending(entry) = model.state else {
            XCTFail("Expected durable exact pending command")
            throw CatalogueSaveUnavailable.storageOrServiceUnavailable
        }
        return entry
    }

    private func saved(_ model: CatalogueSaveModel) throws -> CatalogueCreateConfirmationSnapshot {
        guard case let .saved(confirmation) = model.state else {
            XCTFail("Only a durable exact receipt proves saved")
            throw CatalogueSaveUnavailable.storageOrServiceUnavailable
        }
        return confirmation
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func page(_ count: Int = 0) throws -> Data {
        let timestamp = "2026-11-03T09:00:00.123456+00:00"
        let changes: [[String: Any]] = (0..<count).map {
            ["entity_type": "plants", "id": String(format: "22222222-2222-4222-8222-%012d", $0),
             "updated_at": timestamp, "deleted_at": NSNull(),
             "data": ["care_enabled": false]]
        }
        return try json([
            "until": timestamp, "has_more": false, "last_cursor": NSNull(), "next_since": timestamp,
            "profile": ["preferred_locale": "pl", "reminder_hour_local": 9,
                        "report_notifications_enabled": true, "trial_reminder_enabled": false],
            "entitlement": NSNull(), "changes": changes
        ])
    }

    private func receipt() throws -> Data {
        try json([
            "plant_id": "33333333-3333-4333-8333-333333333333", "care_revision": 1,
            "context_state": "current", "next_available_step": "enable_basic_care",
            "paid_action": NSNull(), "plan_availability": "available",
            "watermark": "2026-11-03T09:00:01.123456+00:00"
        ])
    }

    private func diskCheckpoint(_ stack: Stack, flow: UUID) async throws -> CatalogueInputCheckpointSnapshot? {
        let context = try await stack.api.captureSyncContext(ownerId: owner)
        return try await stack.store.catalogueInputCheckpoint(
            flowId: flow, context: context, authority: stack.api.syncAuthority
        )
    }

    private func assertRedacted(_ model: CatalogueSaveModel, reason: CatalogueSaveUnavailable) {
        XCTAssertEqual(model.state, .unavailable(reason))
        XCTAssertNil(model.input)
        XCTAssertNil(model.envelope)
        XCTAssertNil(model.checkpoint)
        XCTAssertNil(model.pendingAPIError)
    }

    private var cardID: UUID {
        UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    }

    private var canonicalCardData: [String: Any] {
        ["id": cardID.uuidString, "plant_id": "server-reclassified-fern",
         "personal_name": " Canonical fern ", "revision": 7, "care_revision": 4]
    }

    /// Minimal actual 202611090004 plants projection, without unrelated nullable fields.
    private func cardPage(
        data: [String: Any]? = nil, entityId: UUID? = nil,
        missing: Bool = false, deleted: Bool = false,
        timestamp: String = "2026-11-03T09:00:02.123456+00:00"
    ) throws -> Data {
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: page()) as? [String: Any])
        body["until"] = timestamp
        body["next_since"] = timestamp
        let change: [String: Any] = [
            "entity_type": "plants", "id": (entityId ?? cardID).uuidString,
            "updated_at": timestamp, "deleted_at": deleted ? timestamp as Any : NSNull(),
            "data": deleted ? NSNull() : (data ?? canonicalCardData) as Any
        ]
        body["changes"] = missing ? [] : [change]
        return try json(body)
    }

    private func assertCanonicalCard(_ model: CatalogueSaveModel, name: String? = " Canonical fern ") {
        let expected = CatalogueCardSummary(
            id: cardID, speciesSlug: "server-reclassified-fern", taxonId: nil, mainPhotoId: nil,
            personalName: name, currentConditionSnapshotId: nil, revision: 7, careRevision: 4
        )
        XCTAssertEqual(model.cardState, .loaded(expected))
        XCTAssertEqual(model.cardSummary, expected)
    }

    @MainActor
    private final class CardObserverReadings {
        var states: [CatalogueCardState] = []
        var summaries: [CatalogueCardSummary?] = []
        var saves: [CatalogueSaveState] = []

        func read(_ model: CatalogueSaveModel) {
            states.append(model.cardState)
            summaries.append(model.cardSummary)
            saves.append(model.state)
        }
    }

    func testCardRequiresDurableSaveAndReadsExactCanonicalUUIDNameSpeciesAndRevisions() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = SaveModelTransport([
            .http("GET", 200, try page()), .http("POST", 200, try receipt()),
            .http("GET", 200, try cardPage())
        ])
        let stack = try await stack(url, transport)
        let flow = UUID(), operation = UUID()
        let model = try await model(stack, flow: flow, operation: operation)
        await model.loadCard()
        XCTAssertEqual(model.cardState, .idle)
        XCTAssertNil(model.cardSummary)
        let before = await transport.captured()
        XCTAssertTrue(before.isEmpty)
        await model.save()
        let confirmation = try saved(model)
        XCTAssertEqual(model.cardState, .idle)
        XCTAssertNil(model.cardSummary)
        let beforeRead = try await stack.store.currentWatermarkRaw(ownerId: owner)
        XCTAssertEqual(beforeRead, "2026-11-03T09:00:00.123456+00:00")
        XCTAssertNotEqual(beforeRead, confirmation.receipt.watermarkRaw)
        await model.loadCard()
        assertCanonicalCard(model)
        XCTAssertEqual(try saved(model), confirmation)
        await model.save()
        let reopened = try await self.stack(url, SaveModelTransport([]))
        let entities = try await reopened.store.activeSyncedEntities(ownerId: owner, entityType: "plants")
        let watermark = try await reopened.store.currentWatermarkRaw(ownerId: owner)
        let diskReceipt = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
        XCTAssertEqual(entities.map(\.id), [confirmation.receipt.plantId])
        let data = try JSONDecoder().decode(CatalogueCardSummary.self, from: Data(XCTUnwrap(entities.first).payloadJSON.utf8))
        XCTAssertEqual(data, model.cardSummary)
        XCTAssertEqual(watermark, "2026-11-03T09:00:02.123456+00:00")
        XCTAssertEqual(diskReceipt, confirmation)
        let requests = await transport.captured()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET"])
        let query = URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertFalse(query.contains { ["since", "owner_id", "user_id"].contains($0.name) })
    }

    func testCardGETFailureClearsOldSummaryKeepsSavedAndExplicitRetryDoesNotCreateAgain() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var renamed = canonicalCardData
        renamed["personal_name"] = " Server renamed "
        let transport = SaveModelTransport([
            .http("GET", 200, try page()), .http("POST", 200, try receipt()),
            .http("GET", 200, try cardPage()), .http("GET", 503, Data()),
            .http("GET", 200, try cardPage(data: renamed))
        ])
        let stack = try await stack(url, transport)
        let model = try await model(stack, flow: UUID(), operation: UUID())
        await model.save()
        let confirmation = try saved(model)
        await model.loadCard()
        assertCanonicalCard(model)
        let watermark = try await stack.store.currentWatermarkRaw(ownerId: owner)
        await model.loadCard()
        XCTAssertEqual(model.cardState, .unavailable)
        XCTAssertNil(model.cardSummary)
        XCTAssertEqual(try saved(model), confirmation)
        let afterFailure = try await stack.store.currentWatermarkRaw(ownerId: owner)
        XCTAssertEqual(afterFailure, watermark)
        await model.save()
        await model.loadCard()
        assertCanonicalCard(model, name: " Server renamed ")
        XCTAssertEqual(try saved(model), confirmation)
        let requests = await transport.captured()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "GET", "GET"])
    }

    func testCardMissingDeletedAndMalformedCanonicalMatchesRemainSavedAndRetryWithoutPOST() async throws {
        for mode in 0..<10 {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            var malformed = canonicalCardData
            switch mode {
            case 2: malformed["id"] = other.uuidString
            case 3: malformed["id"] = "not-a-uuid"
            case 4: malformed["plant_id"] = NSNull()
            case 5: malformed["revision"] = "7"
            case 7: malformed.removeValue(forKey: "id")
            case 8: malformed["personal_name"] = 42
            case 9: malformed.removeValue(forKey: "care_revision")
            default: break
            }
            let invalidPage = try cardPage(
                data: malformed, entityId: mode == 1 ? other : nil,
                missing: mode == 0, deleted: mode == 6
            )
            var nullable = canonicalCardData
            nullable["personal_name"] = NSNull()
            let transport = SaveModelTransport([
                .http("GET", 200, try page()), .http("POST", 200, try receipt()),
                .http("GET", 200, invalidPage), .http("GET", 200, try cardPage(data: nullable))
            ])
            let stack = try await stack(url, transport)
            let operation = UUID()
            let model = try await model(stack, flow: UUID(), operation: operation)
            await model.save()
            let confirmation = try saved(model)
            await model.loadCard()
            XCTAssertEqual(model.cardState, .unavailable, "mode \(mode)")
            XCTAssertNil(model.cardSummary)
            XCTAssertEqual(try saved(model), confirmation)
            let reopened = try await self.stack(url, SaveModelTransport([]))
            let diskReceipt = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
            XCTAssertEqual(diskReceipt, confirmation)
            await model.save()
            await model.loadCard()
            assertCanonicalCard(model, name: nil)
            XCTAssertEqual(try saved(model), confirmation)
            let requests = await transport.captured()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "GET"])
        }
    }

    func testCardRestoresSameDurableReceiptAfterDiskRestartThenReadsThroughNewBoundStack() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let flow = UUID(), operation = UUID()
        let confirmation: CatalogueCreateConfirmationSnapshot
        let checkpoint: CatalogueInputCheckpointSnapshot
        do {
            let transport = SaveModelTransport([
                .http("GET", 200, try page()), .http("POST", 200, try receipt())
            ])
            let stack = try await stack(url, transport)
            let model = try await model(stack, flow: flow, operation: operation)
            await model.save()
            confirmation = try saved(model)
            checkpoint = try XCTUnwrap(model.checkpoint)
        }
        let transport = SaveModelTransport([.http("GET", 200, try cardPage())])
        let reopened = try await stack(url, transport, session: refreshedSession)
        let model = try restored(await restoration(reopened, flow: flow, snapshot: refreshedSession))
        XCTAssertEqual(try saved(model), confirmation)
        XCTAssertEqual(model.checkpoint, checkpoint)
        XCTAssertEqual(model.cardState, .idle)
        let before = await transport.captured()
        XCTAssertTrue(before.isEmpty)
        await model.loadCard()
        assertCanonicalCard(model)
        XCTAssertEqual(try saved(model), confirmation)
        let requests = await transport.captured()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer model-refreshed")
        let queue = try await reopened.store.pendingOutboxEntries(for: owner)
        XCTAssertTrue(queue.isEmpty)
    }

    func testCardReadOnlyCanonicalPublicationFailurePreservesRestoredSavedAndDiskCheckpoint() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let flow = UUID(), operation = UUID()
        let confirmation: CatalogueCreateConfirmationSnapshot
        do {
            let stack = try await stack(url, SaveModelTransport([
                .http("GET", 200, try page()), .http("POST", 200, try receipt())
            ]))
            let model = try await model(stack, flow: flow, operation: operation)
            await model.save()
            confirmation = try saved(model)
        }
        let transport = SaveModelTransport([.http("GET", 200, try cardPage())])
        do {
            let readOnly = try await stack(url, transport, allowsSave: false)
            let model = try restored(await restoration(readOnly, flow: flow))
            await model.loadCard()
            XCTAssertEqual(try saved(model), confirmation)
            XCTAssertEqual(model.cardState, .unavailable)
            XCTAssertNil(model.cardSummary)
        }
        let reopened = try await stack(url, SaveModelTransport([]))
        let watermark = try await reopened.store.currentWatermarkRaw(ownerId: owner)
        let entities = try await reopened.store.activeSyncedEntities(ownerId: owner, entityType: "plants")
        let diskReceipt = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
        XCTAssertEqual(watermark, "2026-11-03T09:00:00.123456+00:00")
        XCTAssertTrue(entities.isEmpty)
        XCTAssertEqual(diskReceipt, confirmation)
        let requests = await transport.captured()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    }

    func testCardSuspendedGETSwitchABALogoutAndCancellationRedactWithoutDiskOrPOSTMutation() async throws {
        for mode in 0..<5 {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            var changed = canonicalCardData
            changed["personal_name"] = " Must never publish "
            let transport = SaveModelTransport([
                .http("GET", 200, try page()), .http("POST", 200, try receipt()),
                .http("GET", 200, try cardPage()),
                .http("GET", 200, try cardPage(data: changed, timestamp: "2026-11-03T09:00:03.123456+00:00"))
            ], suspendAt: 3)
            let stack = try await stack(url, transport)
            let flow = UUID(), operation = UUID()
            let model = try await model(stack, flow: flow, operation: operation)
            await model.save()
            let confirmation = try saved(model)
            await model.loadCard()
            assertCanonicalCard(model)
            let original = try await diskCheckpoint(stack, flow: flow)
            let entities = try await stack.store.activeSyncedEntities(ownerId: owner, entityType: "plants")
            let watermark = try await stack.store.currentWatermarkRaw(ownerId: owner)
            let loading = Task { await model.loadCard() }
            await transport.waitForSuspension()
            XCTAssertEqual(model.cardState, .loading)
            XCTAssertNil(model.cardSummary)
            XCTAssertEqual(try saved(model), confirmation)
            if mode < 2 {
                await stack.api.bindSyncSession(otherSession)
                if mode == 1 { await stack.api.bindSyncSession(session) }
            } else if mode == 2 {
                await stack.api.bindSyncSession(nil)
            } else if mode == 3 {
                model.cancel()
            } else {
                loading.cancel()
            }
            if mode < 4 {
                assertRedacted(model, reason: mode == 3 ? .cancelled : .sessionChanged)
                XCTAssertEqual(model.cardState, .unavailable)
                XCTAssertNil(model.cardSummary)
            }
            await transport.resume()
            await loading.value
            assertRedacted(model, reason: mode >= 3 ? .cancelled : .sessionChanged)
            XCTAssertEqual(model.cardState, .unavailable)
            XCTAssertNil(model.cardSummary)
            await model.loadCard()
            await model.save()
            let reopened = try await self.stack(url, SaveModelTransport([]))
            let after = try await diskCheckpoint(reopened, flow: flow)
            let afterEntities = try await reopened.store.activeSyncedEntities(ownerId: owner, entityType: "plants")
            let afterWatermark = try await reopened.store.currentWatermarkRaw(ownerId: owner)
            let diskReceipt = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
            let queue = try await reopened.store.pendingOutboxEntries(for: owner)
            XCTAssertEqual(after, original)
            XCTAssertEqual(afterEntities.map(\.payloadJSON), entities.map(\.payloadJSON))
            XCTAssertEqual(afterEntities.map(\.id), entities.map(\.id))
            XCTAssertEqual(afterWatermark, watermark)
            XCTAssertEqual(diskReceipt, confirmation)
            XCTAssertTrue(queue.isEmpty)
            let requests = await transport.captured()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "GET"])
            XCTAssertTrue(requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer model-a"
            })
        }
    }

    func testCardDuplicateLoadWhileGETSuspendedSendsOneRefreshAndKeepsDurableSaved() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = SaveModelTransport([
            .http("GET", 200, try page()), .http("POST", 200, try receipt()),
            .http("GET", 200, try cardPage())
        ], suspendAt: 2)
        let stack = try await stack(url, transport)
        let model = try await model(stack, flow: UUID(), operation: UUID())
        await model.save()
        let confirmation = try saved(model)
        let loading = Task { await model.loadCard() }
        await transport.waitForSuspension()
        await model.loadCard()
        await model.save()
        XCTAssertEqual(model.cardState, .loading)
        XCTAssertNil(model.cardSummary)
        XCTAssertEqual(try saved(model), confirmation)
        await transport.resume()
        await loading.value
        assertCanonicalCard(model)
        XCTAssertEqual(try saved(model), confirmation)
        let requests = await transport.captured()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET"])
        await stack.api.bindSyncSession(otherSession)
        await stack.api.bindSyncSession(session)
        assertRedacted(model, reason: .sessionChanged)
        XCTAssertEqual(model.cardState, .unavailable)
        XCTAssertNil(model.cardSummary)
    }

    func testCardLoadingObservationRereadsAndInvalidatesBeforeAnyDetailsGETWithoutDeadlock() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = SaveModelTransport([
            .http("GET", 200, try page()), .http("POST", 200, try receipt())
        ])
        let stack = try await stack(url, transport)
        let operation = UUID()
        let model = try await model(stack, flow: UUID(), operation: operation)
        await model.save()
        let confirmation = try saved(model)
        let readings = CardObserverReadings()
        let authority = stack.api.syncAuthority
        withObservationTracking {
            _ = model.cardState
            _ = model.cardSummary
        } onChange: {
            MainActor.assumeIsolated {
                readings.read(model)
                authority.invalidate()
                readings.read(model)
            }
        }
        await model.loadCard()
        XCTAssertEqual(readings.states, [.idle, .unavailable])
        XCTAssertEqual(readings.summaries, [nil, nil])
        XCTAssertEqual(readings.saves, [.saved(confirmation), .unavailable(.sessionChanged)])
        assertRedacted(model, reason: .sessionChanged)
        XCTAssertNil(model.cardSummary)
        let reopened = try await self.stack(url, SaveModelTransport([]))
        let diskReceipt = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
        let watermark = try await reopened.store.currentWatermarkRaw(ownerId: owner)
        XCTAssertEqual(diskReceipt, confirmation)
        XCTAssertEqual(watermark, "2026-11-03T09:00:00.123456+00:00")
        let requests = await transport.captured()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    }

    func testCardLoadedObservationRereadsAndInvalidatesWithoutPublishingOldOwnerSummary() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = SaveModelTransport([
            .http("GET", 200, try page()), .http("POST", 200, try receipt()),
            .http("GET", 200, try cardPage())
        ], suspendAt: 2)
        let stack = try await stack(url, transport)
        let flow = UUID(), operation = UUID()
        let model = try await model(stack, flow: flow, operation: operation)
        await model.save()
        let confirmation = try saved(model)
        let checkpoint = model.checkpoint
        let loading = Task { await model.loadCard() }
        await transport.waitForSuspension()
        let readings = CardObserverReadings()
        let authority = stack.api.syncAuthority
        withObservationTracking {
            _ = model.cardState
            _ = model.cardSummary
        } onChange: {
            MainActor.assumeIsolated {
                readings.read(model)
                authority.invalidate()
                readings.read(model)
            }
        }
        await transport.resume()
        await loading.value
        XCTAssertEqual(readings.states, [.loading, .unavailable])
        XCTAssertEqual(readings.summaries, [nil, nil])
        XCTAssertEqual(readings.saves, [.saved(confirmation), .unavailable(.sessionChanged)])
        assertRedacted(model, reason: .sessionChanged)
        XCTAssertEqual(model.cardState, .unavailable)
        XCTAssertNil(model.cardSummary)
        await model.loadCard()
        let reopened = try await self.stack(url, SaveModelTransport([]))
        let diskReceipt = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
        let diskInput = try await diskCheckpoint(reopened, flow: flow)
        let watermark = try await reopened.store.currentWatermarkRaw(ownerId: owner)
        XCTAssertEqual(diskReceipt, confirmation)
        XCTAssertEqual(diskInput, checkpoint)
        // The GET committed before this synchronous publication callback revoked its lease.
        XCTAssertEqual(watermark, "2026-11-03T09:00:02.123456+00:00")
        let requests = await transport.captured()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET"])
    }

    func testGuestCheckpointsBeforeSignInWithoutRequestsOrQueueAndRestoresOnlyOwnFlow() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = SaveModelTransport([])
        let stack = try await stack(url, transport)
        let flow = UUID(), operation = UUID()
        let model = try await model(stack, flow: flow, operation: operation, guest: true)
        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.checkpoint)
        await model.save()
        XCTAssertEqual(model.state, .signInRequired)
        let checkpoint = try XCTUnwrap(model.checkpoint)
        XCTAssertEqual(checkpoint.operationId, operation)
        XCTAssertEqual(model.input, input)
        let reopened = try await self.stack(url, transport)
        let restored = try restored(await restoration(reopened, flow: flow, guest: true))
        XCTAssertEqual(restored.checkpoint, checkpoint)
        XCTAssertEqual(restored.input, input)
        XCTAssertEqual(restored.envelope, checkpoint.envelope)
        XCTAssertEqual(restored.state, .signInRequired)
        if case .absent = await restoration(reopened, flow: UUID()) {} else { XCTFail("Missing flow") }
        let foreign = try await self.stack(url, transport, session: otherSession)
        if case .absent = await restoration(foreign, flow: flow, snapshot: otherSession) {} else {
            XCTFail("Must not discover another owner's input")
        }
        let ownQueue = try await reopened.store.pendingOutboxEntries(for: owner)
        let foreignQueue = try await reopened.store.pendingOutboxEntries(for: other)
        let requests = await transport.captured()
        XCTAssertTrue(ownQueue.isEmpty)
        XCTAssertTrue(foreignQueue.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }

    func testRegisteredSaveRequiresExactDurableReceiptAndRestoresSavedWithoutSending() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let body = try receipt()
        let transport = SaveModelTransport([.http("GET", 200, try page(2)), .http("POST", 200, body)])
        let stack = try await stack(url, transport)
        let flow = UUID(), operation = UUID()
        let model = try await model(stack, flow: flow, operation: operation)
        await model.save()
        let confirmation = try saved(model)
        XCTAssertEqual(confirmation.ownerId, owner)
        XCTAssertEqual(confirmation.operationId, operation)
        XCTAssertEqual(confirmation.receipt, try JSONDecoder().decode(PlantCreateReceiptDTO.self, from: body))
        XCTAssertEqual(confirmation.payloadJSON, model.checkpoint?.envelope.payloadJSON)
        await model.save()
        let silent = SaveModelTransport([])
        let reopened = try await self.stack(url, silent)
        let diskReceipt = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
        XCTAssertEqual(diskReceipt, confirmation)
        let restored = try restored(await restoration(reopened, flow: flow))
        XCTAssertEqual(restored.state, .saved(confirmation))
        await restored.save()
        let requests = await transport.captured()
        let noRequests = await silent.captured()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        let command = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(requests[1].httpBody))
        XCTAssertEqual(command, model.envelope)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Operation-Id"), operation.uuidString.lowercased())
        XCTAssertTrue(noRequests.isEmpty)
    }

    func testCommittedLostResponseRestartsUnderRefreshedSessionWithSameOperationBodyAndReceipt() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = SaveModelTransport([
            .http("GET", 200, try page(2)), .commitAndLose(try receipt()), .replayCommitted
        ])
        let flow = UUID(), operation = UUID()
        let original: CatalogueInputCheckpointSnapshot
        let queued: OutboxEntrySnapshot
        do {
            let stack = try await stack(url, transport)
            let model = try await model(stack, flow: flow, operation: operation)
            await model.save()
            queued = try pending(model)
            original = try XCTUnwrap(model.checkpoint)
            XCTAssertEqual(queued.operationId, operation)
            XCTAssertEqual(queued.retryCount, 1)
            XCTAssertNil(model.pendingAPIError)
        }
        let reopened = try await stack(url, transport, session: refreshedSession)
        let model = try restored(await restoration(reopened, flow: flow, snapshot: refreshedSession))
        XCTAssertEqual(model.checkpoint, original)
        XCTAssertEqual(try pending(model), queued)
        XCTAssertEqual(model.input, input)
        let before = await transport.captured()
        XCTAssertEqual(before.count, 2) // Restore never sends, even for pending.
        await model.save()
        let confirmation = try saved(model)
        XCTAssertEqual(confirmation.operationId, operation)
        XCTAssertEqual(Data(confirmation.payloadJSON.utf8), Data(original.envelope.payloadJSON.utf8))
        let requests = await transport.captured()
        let commits = await transport.commitCount()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "POST"])
        XCTAssertEqual(requests[1].httpBody, requests[2].httpBody)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer model-refreshed")
        XCTAssertEqual(commits, 1)
        let queue = try await reopened.store.pendingOutboxEntries(for: owner)
        XCTAssertTrue(queue.isEmpty)
    }

    func testCapPrecheckDoesNotQueueWhileServer409RemainsExactTypedPendingAcrossRestart() async throws {
        for full in [true, false] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            var replies: [SaveModelTransport.Reply] = [.http("GET", 200, try page(full ? 3 : 2))]
            let error = try json([
                "error": ["code": "COLLECTION_LIMIT_REACHED", "message": "Limit", "retryable": false]
            ])
            if !full { replies.append(.http("POST", 409, error)) }
            let transport = SaveModelTransport(replies)
            let stack = try await stack(url, transport)
            let flow = UUID(), operation = UUID()
            let model = try await model(stack, flow: flow, operation: operation)
            await model.save()
            let queue = try await stack.store.pendingOutboxEntries(for: owner)
            if full {
                guard case let .collectionLimitNotEnqueued(capacity) = model.state else {
                    return XCTFail("Full new create must not queue")
                }
                XCTAssertEqual(capacity.plantCount, 3)
                XCTAssertFalse(capacity.canCreate)
                XCTAssertTrue(queue.isEmpty)
            } else {
                XCTAssertEqual(queue, [try pending(model)])
                XCTAssertEqual(model.pendingAPIError, try JSONDecoder().decode(APIErrorResponse.self, from: error))
            }
            let reopened = try await self.stack(url, transport)
            let restored = try restored(await restoration(reopened, flow: flow))
            XCTAssertEqual(restored.input, input)
            XCTAssertEqual(restored.envelope, model.envelope)
            if !full { XCTAssertEqual(restored.state, model.state) }
            let diskReceipt = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
            let requests = await transport.captured()
            XCTAssertNil(diskReceipt)
            XCTAssertEqual(requests.count, full ? 1 : 2)
        }
    }

    func testFailedPreflightRetainsCheckpointWithoutQueueOrFakeSuccess() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = SaveModelTransport([.http("GET", 503, Data())])
        let stack = try await stack(url, transport)
        let flow = UUID(), operation = UUID()
        let model = try await model(stack, flow: flow, operation: operation)
        await model.save()
        XCTAssertEqual(model.state, .unavailable(.storageOrServiceUnavailable))
        XCTAssertNotNil(model.checkpoint)
        let reopened = try await self.stack(url, transport)
        let restored = try restored(await restoration(reopened, flow: flow))
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.checkpoint, model.checkpoint)
        let queue = try await reopened.store.pendingOutboxEntries(for: owner)
        let diskReceipt = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
        let requests = await transport.captured()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(diskReceipt)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    }

    func testReadOnlyCheckpointAndACKFailuresNeverPublishSavedAndPreserveDisk() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do { _ = try container(url) }
        let silent = SaveModelTransport([])
        let flow = UUID(), operation = UUID()
        do {
            let readOnly = try await stack(url, silent, allowsSave: false)
            let model = try await model(readOnly, flow: flow, operation: operation, guest: true)
            await model.save()
            XCTAssertEqual(model.state, .unavailable(.storageOrServiceUnavailable))
            XCTAssertNil(model.checkpoint)
        }
        let writable = try await stack(url, silent)
        if case .absent = await restoration(writable, flow: flow) {} else { XCTFail("No phantom input") }
        let model = try await model(writable, flow: flow, operation: operation, guest: true)
        await model.save()
        let checkpoint = try XCTUnwrap(model.checkpoint)
        let context = try await writable.api.captureSyncContext(ownerId: owner)
        _ = try await writable.store.catalogueCreateJournal(
            checkpoint.envelope, mode: .enqueue(canCreate: true),
            context: context, authority: writable.api.syncAuthority
        )
        let originalQueue = try await writable.store.pendingOutboxEntries(for: owner)
        let transport = SaveModelTransport([.http("POST", 200, try receipt())])
        do {
            let readOnly = try await stack(url, transport, allowsSave: false)
            let restored = try restored(await restoration(readOnly, flow: flow))
            XCTAssertEqual(try pending(restored), try XCTUnwrap(originalQueue.first))
            await restored.save()
            XCTAssertEqual(restored.state, .unavailable(.storageOrServiceUnavailable))
        }
        let reopened = try await stack(url, silent)
        let diskInput = try await diskCheckpoint(reopened, flow: flow)
        let diskQueue = try await reopened.store.pendingOutboxEntries(for: owner)
        let diskReceipt = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
        let noRequests = await silent.captured()
        let requests = await transport.captured()
        XCTAssertEqual(diskInput, checkpoint)
        XCTAssertEqual(diskQueue, originalQueue)
        XCTAssertNil(diskReceipt)
        XCTAssertTrue(noRequests.isEmpty)
        XCTAssertEqual(requests.map(\.httpMethod), ["POST"])
    }

    func testUnboundAndMismatchedSDKContextsCannotConstructModelOrRestore() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = SaveModelTransport([])
        let store = LocalStore(modelContainer: try container(url))
        for mode in 0..<3 {
            let api = PlantsAPIClient(transport: transport, bearerToken: session.accessToken)
            if mode == 1 { await api.bindSyncSession(otherSession) }
            if mode == 2 { await api.bindSyncSession(refreshedSession) }
            let repository = CollectionRepository(
                store: store, apiClient: api, syncEngine: SyncEngine(store: store, apiClient: api)
            )
            do {
                _ = try await CatalogueSaveModel(
                    store: store, apiClient: api, repository: repository,
                    flowId: UUID(), operationId: UUID(), input: input, session: session, isAnonymous: false
                )
                XCTFail("Bound exact SDK snapshot required")
            } catch { XCTAssertEqual(error as? CatalogueSaveUnavailable, .sessionChanged) }
            let result = await CatalogueSaveModel.restore(
                store: store, apiClient: api, repository: repository,
                ownerId: owner, flowId: UUID(), session: session, isAnonymous: false
            )
            if case .unavailable(.sessionChanged) = result {} else { XCTFail("Invalid restore context") }
        }
        let requests = await transport.captured()
        XCTAssertTrue(requests.isEmpty)
    }

    func testOldIdleModelRedactsAfterSwitchABASignoutAndRefreshBeforeAction() async throws {
        for checkpointed in [false, true] {
            for mode in 0..<4 {
                let url = try diskURL()
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let transport = SaveModelTransport([])
                let stack = try await stack(url, transport)
                let flow = UUID(), operation = UUID()
                let model = try await model(stack, flow: flow, operation: operation, guest: checkpointed)
                if checkpointed { await model.save() }
                let original = model.checkpoint
                if mode < 2 {
                    await stack.api.bindSyncSession(otherSession)
                    if mode == 1 { await stack.api.bindSyncSession(session) }
                } else {
                    await stack.api.bindSyncSession(mode == 2 ? nil : refreshedSession)
                }
                assertRedacted(model, reason: .sessionChanged)
                await model.save()
                assertRedacted(model, reason: .sessionChanged)
                let reopened = try await self.stack(url, transport)
                let disk = try await diskCheckpoint(reopened, flow: flow)
                XCTAssertEqual(disk, original)
                let queue = try await reopened.store.pendingOutboxEntries(for: owner)
                let requests = await transport.captured()
                XCTAssertTrue(queue.isEmpty)
                XCTAssertTrue(requests.isEmpty)
            }
        }
    }

    func testIdleSavedAndPendingStatesRedactImmediatelyAfterSwitchAndABA() async throws {
        for success in [false, true] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let failure = try json([
                "error": ["code": "COLLECTION_LIMIT_REACHED", "message": "Limit", "retryable": false]
            ])
            let successfulReceipt = try receipt()
            let transport = SaveModelTransport([
                .http("GET", 200, try page(2)),
                .http("POST", success ? 200 : 409, success ? successfulReceipt : failure)
            ])
            let stack = try await stack(url, transport)
            let flow = UUID(), operation = UUID()
            let model = try await model(stack, flow: flow, operation: operation)
            await model.save()
            let originalState = model.state
            let originalInput = model.checkpoint
            if success { _ = try saved(model) } else { _ = try pending(model) }
            await stack.api.bindSyncSession(otherSession)
            assertRedacted(model, reason: .sessionChanged)
            await model.save()
            await stack.api.bindSyncSession(session)
            assertRedacted(model, reason: .sessionChanged)
            await model.save()
            let reopened = try await self.stack(url, transport)
            let restored = try restored(await restoration(reopened, flow: flow))
            XCTAssertEqual(restored.state, originalState)
            XCTAssertEqual(restored.checkpoint, originalInput)
            let requests = await transport.captured()
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testSuspendedGETAndPOSTSwitchABASignoutAndCancellationRedactAndPreserveDisk() async throws {
        for boundary in [0, 1] {
            for mode in 0..<5 {
                let url = try diskURL()
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let transport = SaveModelTransport([
                    .http("GET", 200, try page(2)), .http("POST", 200, try receipt())
                ], suspendAt: boundary)
                let stack = try await stack(url, transport)
                let flow = UUID(), operation = UUID()
                let model = try await model(stack, flow: flow, operation: operation)
                let saving = Task { await model.save() }
                await transport.waitForSuspension()
                XCTAssertEqual(model.state, .busy)
                let original = try await diskCheckpoint(stack, flow: flow)
                let queue = try await stack.store.pendingOutboxEntries(for: owner)
                XCTAssertEqual(queue.count, boundary)
                if mode < 2 {
                    await stack.api.bindSyncSession(otherSession)
                    if mode == 1 { await stack.api.bindSyncSession(session) }
                } else if mode == 2 {
                    await stack.api.bindSyncSession(nil)
                } else if mode == 3 {
                    model.cancel()
                } else {
                    saving.cancel()
                }
                if mode < 4 {
                    assertRedacted(model, reason: mode == 3 ? .cancelled : .sessionChanged)
                }
                await transport.resume()
                await saving.value
                assertRedacted(model, reason: mode >= 3 ? .cancelled : .sessionChanged)
                let reopened = try await self.stack(url, transport)
                let disk = try await diskCheckpoint(reopened, flow: flow)
                let afterQueue = try await reopened.store.pendingOutboxEntries(for: owner)
                let receipt = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
                XCTAssertEqual(disk, original)
                XCTAssertEqual(afterQueue, queue)
                XCTAssertNil(receipt)
                let requests = await transport.captured()
                XCTAssertEqual(requests.count, boundary + 1)
                XCTAssertTrue(requests.allSatisfy {
                    $0.value(forHTTPHeaderField: "Authorization") == "Bearer model-a"
                })
            }
        }
    }

    func testDuplicateBusyTapDoesNotSendOrManufactureSuccessAndCancelledModelCannotResume() async throws {
        for cancel in [false, true] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let transport = SaveModelTransport([
                .http("GET", 200, try page(2)), .http("POST", 200, try receipt())
            ], suspendAt: 1)
            let stack = try await stack(url, transport)
            let flow = UUID(), operation = UUID()
            let model = try await model(stack, flow: flow, operation: operation)
            let saving = Task { await model.save() }
            await transport.waitForSuspension()
            await model.save()
            XCTAssertEqual(model.state, .busy)
            let diskReceipt = try await stack.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
            XCTAssertNil(diskReceipt)
            if cancel { model.cancel() }
            await transport.resume()
            await saving.value
            if cancel {
                assertRedacted(model, reason: .cancelled)
                await model.save()
                let reopened = try await self.stack(url, transport)
                let restored = try restored(await restoration(reopened, flow: flow))
                XCTAssertEqual(try pending(restored).operationId, operation)
            } else {
                XCTAssertEqual(try saved(model).operationId, operation)
                await model.save()
            }
            let requests = await transport.captured()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        }
    }

    func testSynchronousObserverInvalidatesBeforeSaveWritesAndPreservesExistingDiskInput() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = SaveModelTransport([])
        let stack = try await stack(url, transport)
        let retainedFlow = UUID()
        let context = try await stack.api.captureSyncContext(ownerId: owner)
        let retained = try await stack.store.checkpointCatalogueInput(
            input, flowId: retainedFlow, operationId: UUID(),
            context: context, authority: stack.api.syncAuthority
        )
        let flow = UUID(), operation = UUID()
        let model = try await model(stack, flow: flow, operation: operation)
        let readings = ObserverReadings()
        let authority = stack.api.syncAuthority
        withObservationTracking {
            _ = model.state
            _ = model.input
            _ = model.checkpoint
        } onChange: {
            MainActor.assumeIsolated {
                readings.read(model)
                authority.invalidate()
                readings.read(model)
            }
        }

        await model.save()
        XCTAssertEqual(readings.states, [.ready, .unavailable(.sessionChanged)])
        XCTAssertEqual(readings.inputs, [input, nil])
        XCTAssertEqual(readings.checkpoints, [nil, nil])
        assertRedacted(model, reason: .sessionChanged)
        await model.save()

        let reopened = try await self.stack(url, transport)
        let retainedAfter = try await diskCheckpoint(reopened, flow: retainedFlow)
        let attempted = try await diskCheckpoint(reopened, flow: flow)
        let queue = try await reopened.store.pendingOutboxEntries(for: owner)
        let confirmation = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
        let disk = ModelContext(try container(url))
        let records = try disk.fetch(FetchDescriptor<CatalogueInputCheckpointRecord>())
        let requests = await transport.captured()
        XCTAssertEqual(retainedAfter, retained)
        XCTAssertNil(attempted)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(confirmation)
        XCTAssertTrue(requests.isEmpty)
    }

    func testSynchronousCheckpointObserverInvalidatesBeforeRegisteredPathWithoutLosingCommittedInput() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = SaveModelTransport([])
        let stack = try await stack(url, transport)
        let flow = UUID(), operation = UUID()
        let model = try await model(stack, flow: flow, operation: operation)
        let envelope = try XCTUnwrap(model.envelope)
        let readings = ObserverReadings()
        let authority = stack.api.syncAuthority
        // Track only checkpoint: busy must complete before this callback runs.
        withObservationTracking {
            _ = model.checkpoint
        } onChange: {
            MainActor.assumeIsolated {
                readings.read(model)
                authority.invalidate()
                readings.read(model)
            }
        }

        await model.save()
        XCTAssertEqual(readings.states, [.busy, .unavailable(.sessionChanged)])
        XCTAssertEqual(readings.inputs, [input, nil])
        XCTAssertEqual(readings.checkpoints, [nil, nil])
        assertRedacted(model, reason: .sessionChanged)

        let reopened = try await self.stack(url, transport)
        let diskInput = try await diskCheckpoint(reopened, flow: flow)
        let committed = try XCTUnwrap(diskInput)
        XCTAssertEqual(committed.envelope, envelope)
        await model.save()
        let afterRetry = try await diskCheckpoint(reopened, flow: flow)
        let queue = try await reopened.store.pendingOutboxEntries(for: owner)
        let confirmation = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
        let requests = await transport.captured()
        XCTAssertEqual(afterRetry, committed)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(confirmation)
        XCTAssertTrue(requests.isEmpty)
    }

    func testSynchronousResultObserverInvalidatesWithoutExposingSavedOrPendingAndPreservesJournal() async throws {
        for success in [false, true] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let successfulReceipt = try receipt()
            let failure = try json([
                "error": ["code": "COLLECTION_LIMIT_REACHED", "message": "Limit", "retryable": false]
            ])
            let response = success ? successfulReceipt : failure
            let transport = SaveModelTransport([
                .http("GET", 200, try page(2)), .http("POST", success ? 200 : 409, response)
            ], suspendAt: 1)
            let stack = try await stack(url, transport)
            let flow = UUID(), operation = UUID()
            let model = try await model(stack, flow: flow, operation: operation)
            let saving = Task { await model.save() }
            await transport.waitForSuspension()
            let original = try XCTUnwrap(model.checkpoint)
            let readings = ObserverReadings()
            let authority = stack.api.syncAuthority
            withObservationTracking {
                _ = model.state
                _ = model.input
                _ = model.checkpoint
            } onChange: {
                MainActor.assumeIsolated {
                    readings.read(model)
                    authority.invalidate()
                    readings.read(model)
                }
            }

            await transport.resume()
            await saving.value
            XCTAssertEqual(readings.states, [.busy, .unavailable(.sessionChanged)])
            XCTAssertEqual(readings.inputs, [input, nil])
            XCTAssertEqual(readings.checkpoints, [original, nil])
            assertRedacted(model, reason: .sessionChanged)
            await model.save()

            let reopened = try await self.stack(url, transport)
            let checkpoint = try await diskCheckpoint(reopened, flow: flow)
            let queue = try await reopened.store.pendingOutboxEntries(for: owner)
            let confirmation = try await reopened.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
            let requests = await transport.captured()
            XCTAssertEqual(checkpoint, original)
            if success {
                XCTAssertTrue(queue.isEmpty)
                XCTAssertEqual(confirmation?.operationId, operation)
                XCTAssertEqual(confirmation?.payloadJSON, original.envelope.payloadJSON)
                XCTAssertEqual(confirmation?.receipt, try JSONDecoder().decode(PlantCreateReceiptDTO.self, from: response))
            } else {
                let entry = try XCTUnwrap(queue.first)
                XCTAssertEqual(queue.count, 1)
                XCTAssertEqual(entry.operationId, operation)
                XCTAssertEqual(entry.payloadJSON, original.envelope.payloadJSON)
                XCTAssertEqual(entry.lastAPIError, try JSONDecoder().decode(APIErrorResponse.self, from: response))
                XCTAssertNil(confirmation)
            }
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        }
    }

    func testCorruptOrConflictingCheckpointIsUnavailableWithoutRequestsOrRepair() async throws {
        for corrupt in [true, false] {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let flow = UUID(), operation = UUID()
            let envelope = try input.makeEnvelope(operationId: operation)
            do {
                let disk = ModelContext(try container(url))
                disk.insert(CatalogueInputCheckpointRecord(
                    ownerId: owner, flowId: flow, operationId: operation,
                    payloadJSON: corrupt ? "{}" : envelope.payloadJSON, createdAt: Date()
                ))
                if !corrupt {
                    disk.insert(LocalOutboxRecord(
                        operationId: operation, ownerId: other, plantId: nil, commandName: "plant.create",
                        payloadJSON: envelope.payloadJSON, sequenceNumber: 1
                    ))
                }
                try disk.save()
            }
            let transport = SaveModelTransport([])
            let stack = try await stack(url, transport)
            if case .unavailable(.storageOrServiceUnavailable) = await restoration(stack, flow: flow) {} else {
                XCTFail("Corrupt/mismatched checkpoint must be unavailable")
            }
            let disk = ModelContext(try container(url))
            let records = try disk.fetch(FetchDescriptor<CatalogueInputCheckpointRecord>())
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0].payloadJSON, corrupt ? "{}" : envelope.payloadJSON)
            let queue = try await stack.store.pendingOutboxEntries(for: other)
            let requests = await transport.captured()
            XCTAssertEqual(queue.count, corrupt ? 0 : 1)
            XCTAssertTrue(requests.isEmpty)
        }
    }
}
