import XCTest
import SwiftData
@testable import Plants

private actor MockSyncTransport: PlantsAPITransport {
    struct QueuedSyncPage {
        let page: SyncPageDTO
    }

    var shouldFailNextCommand: Bool = false
    var committedOperations = Set<UUID>()
    var commandCallCount: Int = 0
    var syncPages: [SyncPageDTO] = []
    var syncCallIndex: Int = 0
    var lastHeaders: [String: String] = [:]

    func setFailNextCommand(_ fail: Bool) {
        shouldFailNextCommand = fail
    }

    func setSyncPages(_ pages: [SyncPageDTO]) {
        syncPages = pages
        syncCallIndex = 0
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastHeaders = request.allHTTPHeaderFields ?? [:]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let url = request.url!
        if url.path.hasSuffix("/commands") {
            commandCallCount += 1
            let body = try decoder.decode(CommandEnvelopeDTO.self, from: request.httpBody ?? Data())
            let alreadyCommitted = committedOperations.contains(body.operationId)
            committedOperations.insert(body.operationId)

            if shouldFailNextCommand {
                shouldFailNextCommand = false
                throw URLError(.networkConnectionLost)
            }

            let responseDTO = CommandResponseDTO(
                status: "committed",
                operationId: body.operationId,
                replayed: alreadyCommitted,
                watermark: Date(timeIntervalSince1970: 1_762_000_000)
            )
            let data = try encoder.encode(responseDTO)
            let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, http)
        }

        if url.path.hasSuffix("/sync") {
            let page: SyncPageDTO
            if syncCallIndex < syncPages.count {
                page = syncPages[syncCallIndex]
                syncCallIndex += 1
            } else {
                page = SyncPageDTO(
                    ownerId: UUID(),
                    items: [],
                    hasMore: false,
                    nextCursor: nil,
                    serverWatermark: Date(timeIntervalSince1970: 1_762_000_100),
                    limit: 200
                )
            }
            let data = try encoder.encode(page)
            let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, http)
        }

        throw URLError(.unsupportedURL)
    }
}

final class SyncPersistenceTests: XCTestCase {
    func testOutboxSurvivesRestartAndNetworkDropAfterServerCommit() async throws {
        let container = try LocalStore.makeContainer(accountScope: "test_restart_\(UUID().uuidString)", inMemory: true)
        let ownerId = UUID()
        let plantId = UUID()
        let operationId = UUID()

        // First session: enqueue care.record before network call
        do {
            let store1 = LocalStore(modelContainer: container)
            _ = try await store1.enqueueCommand(
                operationId: operationId,
                ownerId: ownerId,
                plantId: plantId,
                commandName: "care.record",
                payloadJSON: #"{"action_type":"water","performed_date":"2026-11-01"}"#
            )
        }

        // Second session (simulating app restart): outbox still holds the operation
        let store2 = LocalStore(modelContainer: container)
        let pendingBefore = try await store2.pendingOutboxEntries(for: ownerId)
        XCTAssertEqual(pendingBefore.count, 1)
        XCTAssertEqual(pendingBefore.first?.operationId, operationId)

        let transport = MockSyncTransport()
        // Simulate server committing the operation and connection dropping before client gets response
        await transport.setFailNextCommand(true)
        let apiClient = PlantsAPIClient(
            transport: transport,
            installationCredential: "install-cred-123",
            clientLocale: "pl",
            bearerToken: "token-abc"
        )
        let syncEngine = SyncEngine(store: store2, apiClient: apiClient)

        let committedFirstTry = try await syncEngine.flushOutbox(for: ownerId)
        XCTAssertEqual(committedFirstTry, 0)

        // Entry remains in LocalOutbox with incremented retryCount
        let pendingAfterDrop = try await store2.pendingOutboxEntries(for: ownerId)
        XCTAssertEqual(pendingAfterDrop.count, 1)
        XCTAssertEqual(pendingAfterDrop.first?.retryCount, 1)

        // Next flush replays the exact same operation_id, gets idempotent receipt, and clears outbox
        let committedSecondTry = try await syncEngine.flushOutbox(for: ownerId)
        XCTAssertEqual(committedSecondTry, 1)
        let remaining = try await store2.pendingOutboxEntries(for: ownerId)
        XCTAssertTrue(remaining.isEmpty)

        let headers = await transport.lastHeaders
        XCTAssertEqual(headers["X-Installation-Credential"], "install-cred-123")
        XCTAssertEqual(headers["X-Client-Locale"], "pl")
        XCTAssertEqual(headers["X-Operation-Id"], operationId.uuidString.lowercased())
    }

    func testAccountSwitchIsolationAndFullRefreshPreservesOutbox() async throws {
        let container = try LocalStore.makeContainer(accountScope: "test_isolation_\(UUID().uuidString)", inMemory: true)
        let store = LocalStore(modelContainer: container)
        let ownerA = UUID()
        let ownerB = UUID()

        _ = try await store.enqueueCommand(
            ownerId: ownerA,
            plantId: UUID(),
            commandName: "care.record",
            payloadJSON: "{}"
        )
        _ = try await store.enqueueCommand(
            ownerId: ownerB,
            plantId: UUID(),
            commandName: "room.create",
            payloadJSON: #"{"name":"Salon"}"#
        )

        let listA = try await store.pendingOutboxEntries(for: ownerA)
        let listB = try await store.pendingOutboxEntries(for: ownerB)
        XCTAssertEqual(listA.count, 1)
        XCTAssertEqual(listB.count, 1)
        XCTAssertEqual(listA.first?.commandName, "care.record")
        XCTAssertEqual(listB.first?.commandName, "room.create")

        // Populate synced entity for Owner A and run resetSyncCachePreservingOutbox
        let itemId = UUID()
        try await store.applySyncedItems([
            SyncItemDTO(
                entityType: "plant",
                id: itemId,
                updatedAt: Date(),
                deletedAt: nil,
                payloadJSON: #"{"display_name":"Monstera"}"#
            )
        ], ownerId: ownerA)

        let plantsBeforeReset = try await store.activeSyncedEntities(ownerId: ownerA, entityType: "plant")
        XCTAssertEqual(plantsBeforeReset.count, 1)

        try await store.resetSyncCachePreservingOutbox(ownerId: ownerA)
        let plantsAfterReset = try await store.activeSyncedEntities(ownerId: ownerA, entityType: "plant")
        XCTAssertEqual(plantsAfterReset.count, 0)
        // Outbox for Owner A is strictly preserved across full cursor reset!
        let outboxAfterReset = try await store.pendingOutboxEntries(for: ownerA)
        XCTAssertEqual(outboxAfterReset.count, 1)
    }

    func testIdenticalUpdatedAtPaginationRoomDeletionAndLateCommitWindow() async throws {
        let container = try LocalStore.makeContainer(accountScope: "test_paging_\(UUID().uuidString)", inMemory: true)
        let store = LocalStore(modelContainer: container)
        let transport = MockSyncTransport()
        let apiClient = PlantsAPIClient(transport: transport)
        let syncEngine = SyncEngine(store: store, apiClient: apiClient)

        let ownerId = UUID()
        let sameTimestamp = Date(timeIntervalSince1970: 1_762_000_500)
        let windowWatermark = Date(timeIntervalSince1970: 1_762_000_600)
        let plant1 = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let plant2 = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let room1 = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!

        // Page 1 and Page 2 share the exact same updated_at timestamp
        let page1 = SyncPageDTO(
            ownerId: ownerId,
            items: [
                SyncItemDTO(entityType: "plant", id: plant1, updatedAt: sameTimestamp, payloadJSON: #"{"name":"P1"}"#),
                SyncItemDTO(entityType: "room", id: room1, updatedAt: sameTimestamp, payloadJSON: #"{"name":"Living"}"#)
            ],
            hasMore: true,
            nextCursor: SyncCursorDTO(updatedAt: sameTimestamp, entityType: "room", id: room1),
            serverWatermark: windowWatermark,
            limit: 2
        )

        // Page 2 includes plant2 with the same timestamp AND a tombstone deleting room1
        let roomDeletedAt = Date(timeIntervalSince1970: 1_762_000_550)
        let page2 = SyncPageDTO(
            ownerId: ownerId,
            items: [
                SyncItemDTO(entityType: "plant", id: plant2, updatedAt: sameTimestamp, payloadJSON: #"{"name":"P2"}"#),
                SyncItemDTO(entityType: "room", id: room1, updatedAt: roomDeletedAt, deletedAt: roomDeletedAt, payloadJSON: #"{"name":"Living"}"#)
            ],
            hasMore: false,
            nextCursor: nil,
            serverWatermark: Date(timeIntervalSince1970: 1_762_000_999), // Late commit advanced server watermark during paging
            limit: 2
        )

        await transport.setSyncPages([page1, page2])

        let finalWatermark = try await syncEngine.pullDelta(for: ownerId, pageSize: 2)
        // Watermark pins to the initial windowUntil so any commit after windowUntil is fetched on the next delta
        XCTAssertEqual(finalWatermark, windowWatermark)

        let activePlants = try await store.activeSyncedEntities(ownerId: ownerId, entityType: "plant")
        XCTAssertEqual(activePlants.count, 2)

        let activeRooms = try await store.activeSyncedEntities(ownerId: ownerId, entityType: "room")
        XCTAssertEqual(activeRooms.count, 0)
    }

    func testGuestDraftCachePersistsAfterServerExpiryAndIntentSwitchPreservesInputs() async throws {
        let container = try LocalStore.makeContainer(accountScope: "test_draft_\(UUID().uuidString)", inMemory: true)
        let store = LocalStore(modelContainer: container)
        let draftId = UUID()

        var flowState = AddFlowState(
            intent: .problem,
            addMethod: .scan,
            currentStep: .preliminaryResult,
            photoLocalIdentifier: "local/photo1.jpg",
            confirmedPlantId: "monstera_deliciosa",
            conditions: CareConditionsInput(
                lightLevel: .brightIndirect,
                lightSource: .cameraEstimate,
                lightConfirmed: true,
                wateringHabit: .moderate,
                lastWatered: .within7Days,
                potType: .standardDrainage,
                seasonOverride: .auto
            ),
            resultMode: .diagnosis,
            draftId: draftId
        )

        // Switching intent preserves compatible inputs
        flowState.switchIntent(to: .care)
        XCTAssertEqual(flowState.intent, .care)
        XCTAssertEqual(flowState.confirmedPlantId, "monstera_deliciosa")
        XCTAssertEqual(flowState.conditions.lightSource, .cameraEstimate)

        // Save draft whose server TTL expired 2 hours ago
        let expiredServerDate = Date().addingTimeInterval(-7200)
        let snapshot = GuestDraftCacheSnapshot(
            draftId: draftId,
            flowState: flowState,
            serverExpiresAt: expiredServerDate,
            isCompleteForFallback: true
        )
        try await store.saveGuestDraft(snapshot)

        let loaded = try await store.loadGuestDraft(draftId: draftId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.flowState.confirmedPlantId, "monstera_deliciosa")
        XCTAssertEqual(loaded?.isCompleteForFallback, true)
    }
}
