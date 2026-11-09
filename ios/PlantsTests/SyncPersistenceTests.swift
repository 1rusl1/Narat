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

// Test transport returns an actual HTTP response and API error envelope, never a thrown network stub.
private actor UnavailableSyncTransport: PlantsAPITransport {
    private var firstPage: SyncPageDTO?
    private(set) var commandBodies: [Data] = []
    private(set) var operationHeaders: [String] = []

    func setFirstPage(_ page: SyncPageDTO?) {
        firstPage = page
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.path.hasSuffix("/commands") {
            commandBodies.append(request.httpBody ?? Data())
            operationHeaders.append(request.value(forHTTPHeaderField: "X-Operation-Id") ?? "")
        }
        if url.path.hasSuffix("/sync"), let page = firstPage {
            firstPage = nil
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return (try encoder.encode(page),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let data = Data(#"{"error":{"code":"INTERNAL_ERROR","message":"Temporarily unavailable","retryable":true}}"#.utf8)
        return (data, HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil,
                                     headerFields: ["Content-Type": "application/json"])!)
    }
}

final class SyncPersistenceTests: XCTestCase {
    func testHTTP503KeepsOutboxIdentityPayloadAndErrorAcrossStoreRecreation() async throws {
        // Recreate LocalStore over the same in-memory container, not a cold process restart.
        let container = try LocalStore.makeContainer(accountScope: "t152_\(UUID())", inMemory: true)
        let owner = UUID()
        let operation = UUID()
        let plant = UUID()
        let payload = #"{"action_type":"water","performed_date":"2026-11-01"}"#
        let transport = UnavailableSyncTransport()
        let client = PlantsAPIClient(transport: transport)
        let original = LocalStore(modelContainer: container)
        let queued = try await original.enqueueCommand(operationId: operation, ownerId: owner,
            plantId: plant, commandName: "care.record", payloadJSON: payload)

        for attempt in 1...3 {
            let store = LocalStore(modelContainer: container)
            let engine = SyncEngine(store: store, apiClient: client)
            let committed = try await engine.flushOutbox(for: owner)
            XCTAssertEqual(committed, 0)
            let pending = try await store.pendingOutboxEntries(for: owner)
            let entry = try XCTUnwrap(pending.first)
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(entry.operationId, operation)
            XCTAssertEqual(entry.ownerId, owner)
            XCTAssertEqual(entry.plantId, plant)
            XCTAssertEqual(entry.commandName, queued.commandName)
            XCTAssertEqual(entry.payloadJSON, payload)
            XCTAssertEqual(entry.sequenceNumber, queued.sequenceNumber)
            XCTAssertEqual(entry.createdAt, queued.createdAt)
            XCTAssertEqual(entry.retryCount, attempt)
            XCTAssertTrue(try XCTUnwrap(entry.lastError).contains("INTERNAL_ERROR"))
        }
        let recreated = LocalStore(modelContainer: container)
        let persisted = try await recreated.pendingOutboxEntries(for: owner)
        XCTAssertEqual(persisted.first?.retryCount, 3)
        XCTAssertNotNil(persisted.first?.lastError)
        let bodies = await transport.commandBodies
        let headers = await transport.operationHeaders
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(headers, Array(repeating: operation.uuidString.lowercased(), count: 3))
        let decoder = JSONDecoder()
        for body in bodies {
            let envelope = try decoder.decode(CommandEnvelopeDTO.self, from: body)
            XCTAssertEqual(envelope.operationId, operation)
            XCTAssertEqual(envelope.plantId, plant)
            XCTAssertEqual(envelope.commandName, queued.commandName)
            XCTAssertEqual(envelope.payloadJSON, payload)
        }
    }

    func testHTTP503FailedSyncPreservesConfirmedCacheWatermarkAndOtherOwner() async throws {
        let container = try LocalStore.makeContainer(accountScope: "t152_isolation_\(UUID())", inMemory: true)
        let store = LocalStore(modelContainer: container)
        let owner = UUID()
        let other = UUID()
        let watermark = Date(timeIntervalSince1970: 1_762_000_000)
        let item = SyncItemDTO(entityType: "plant", id: UUID(), updatedAt: watermark,
                              payloadJSON: #"{"name":"confirmed"}"#)
        let otherItem = SyncItemDTO(entityType: "plant", id: UUID(), updatedAt: watermark,
                                   payloadJSON: #"{"name":"other owner"}"#)
        try await store.applySyncedItems([item], ownerId: owner)
        try await store.applySyncedItems([otherItem], ownerId: other)
        try await store.updateWatermark(ownerId: owner, watermark: watermark)
        try await store.updateWatermark(ownerId: other, watermark: watermark)
        let queued = try await store.enqueueCommand(ownerId: owner, plantId: item.id,
            commandName: "care.record", payloadJSON: "{}")
        let foreign = try await store.enqueueCommand(ownerId: other, plantId: otherItem.id,
            commandName: "care.record", payloadJSON: #"{"owner":"other"}"#)
        let transport = UnavailableSyncTransport()
        let engine = SyncEngine(store: store, apiClient: PlantsAPIClient(transport: transport))

        // Failure on page one, then after a successful page, then during full refresh.
        // None may publish partial entities, remove the cache, or advance the watermark.
        for mode in 0..<3 {
            if mode > 0 {
                let nextTime = watermark.addingTimeInterval(60)
                let changed = SyncItemDTO(entityType: "plant", id: item.id, updatedAt: nextTime,
                                          payloadJSON: #"{"name":"unconfirmed page"}"#)
                await transport.setFirstPage(SyncPageDTO(ownerId: owner, items: [changed],
                    hasMore: true, nextCursor: SyncCursorDTO(updatedAt: nextTime,
                        entityType: "plant", id: item.id),
                    serverWatermark: nextTime, limit: 1))
            }
            do {
                if mode == 2 {
                    _ = try await engine.performFullRefresh(for: owner)
                } else {
                    _ = try await engine.syncNow(for: owner)
                }
                XCTFail("HTTP503 must fail sync")
            } catch let error as APIErrorResponse {
                XCTAssertEqual(error.error.code, "INTERNAL_ERROR")
                XCTAssertTrue(error.error.retryable)
            } catch {
                XCTFail("Expected decoded HTTP503 envelope, got \(error)")
            }
            let current = try await store.currentWatermark(ownerId: owner)
            let confirmed = try await store.activeSyncedEntities(ownerId: owner, entityType: "plant")
            let foreignWatermark = try await store.currentWatermark(ownerId: other)
            let foreignEntities = try await store.activeSyncedEntities(ownerId: other, entityType: "plant")
            let foreignQueue = try await store.pendingOutboxEntries(for: other)
            let ownQueue = try await store.pendingOutboxEntries(for: owner)
            XCTAssertEqual(current, watermark)
            XCTAssertEqual(confirmed, [item])
            XCTAssertEqual(foreignWatermark, watermark)
            XCTAssertEqual(foreignEntities, [otherItem])
            XCTAssertEqual(foreignQueue, [foreign])
            XCTAssertEqual(ownQueue.first?.operationId, queued.operationId)
            XCTAssertEqual(ownQueue.first?.ownerId, owner)
            XCTAssertEqual(ownQueue.first?.payloadJSON, queued.payloadJSON)
            XCTAssertEqual(ownQueue.first?.retryCount, mode + 1)
        }
        let headers = await transport.operationHeaders
        XCTAssertEqual(headers, Array(repeating: queued.operationId.uuidString.lowercased(), count: 3))
    }

    func testDiskBackedStoreSurvivesHTTP503AcrossIndependentContainersAndReplaysIdempotently() async throws {
        let scope = "t152_disk_\(UUID().uuidString)"
        defer {
            let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let storeDir = baseURL.appendingPathComponent("NaratStores", isDirectory: true)
            for suffix in ["", "-wal", "-shm"] {
                let fileURL = storeDir.appendingPathComponent("store_\(scope).sqlite\(suffix)")
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        let owner = UUID()
        let otherOwner = UUID()
        let operationId = UUID()
        let otherOperationId = UUID()
        let watermark = Date(timeIntervalSince1970: 1_762_000_000)
        let payload = #"{"action_type":"water","performed_date":"2026-11-01"}"#
        let otherPayload = #"{"owner":"other"}"#
        let confirmedItem = SyncItemDTO(
            entityType: "plant",
            id: UUID(),
            updatedAt: watermark,
            payloadJSON: #"{"name":"confirmed_disk"}"#
        )
        let otherConfirmedItem = SyncItemDTO(
            entityType: "plant",
            id: UUID(),
            updatedAt: watermark,
            payloadJSON: #"{"name":"other_disk"}"#
        )

        let queued: OutboxEntrySnapshot
        let foreignQueued: OutboxEntrySnapshot
        do {
            let container1 = try LocalStore.makeContainer(accountScope: scope, inMemory: false)
            let store1 = LocalStore(modelContainer: container1)
            try await store1.applySyncedItems([confirmedItem], ownerId: owner)
            try await store1.applySyncedItems([otherConfirmedItem], ownerId: otherOwner)
            try await store1.updateWatermark(ownerId: owner, watermark: watermark)
            try await store1.updateWatermark(ownerId: otherOwner, watermark: watermark)
            queued = try await store1.enqueueCommand(
                operationId: operationId,
                ownerId: owner,
                plantId: confirmedItem.id,
                commandName: "care.record",
                payloadJSON: payload
            )
            foreignQueued = try await store1.enqueueCommand(
                operationId: otherOperationId,
                ownerId: otherOwner,
                plantId: otherConfirmedItem.id,
                commandName: "care.record",
                payloadJSON: otherPayload
            )
        }

        let unavailableTransport = UnavailableSyncTransport()
        do {
            let container2 = try LocalStore.makeContainer(accountScope: scope, inMemory: false)
            let store2 = LocalStore(modelContainer: container2)
            let engine2 = SyncEngine(store: store2, apiClient: PlantsAPIClient(transport: unavailableTransport))

            let committed = try await engine2.flushOutbox(for: owner)
            XCTAssertEqual(committed, 0)

            let nextTime = watermark.addingTimeInterval(60)
            let unconfirmedItem = SyncItemDTO(
                entityType: "plant",
                id: confirmedItem.id,
                updatedAt: nextTime,
                payloadJSON: #"{"name":"unconfirmed_page"}"#
            )
            await unavailableTransport.setFirstPage(SyncPageDTO(
                ownerId: owner,
                items: [unconfirmedItem],
                hasMore: true,
                nextCursor: SyncCursorDTO(updatedAt: nextTime, entityType: "plant", id: confirmedItem.id),
                serverWatermark: nextTime,
                limit: 1
            ))
            do {
                _ = try await engine2.syncNow(for: owner)
                XCTFail("HTTP503 on second page must fail syncNow")
            } catch let error as APIErrorResponse {
                XCTAssertEqual(error.error.code, "INTERNAL_ERROR")
                XCTAssertTrue(error.error.retryable)
            }

            do {
                _ = try await engine2.performFullRefresh(for: owner)
                XCTFail("HTTP503 must fail performFullRefresh")
            } catch let error as APIErrorResponse {
                XCTAssertEqual(error.error.code, "INTERNAL_ERROR")
                XCTAssertTrue(error.error.retryable)
            }
        }

        let mockTransport = MockSyncTransport()
        do {
            let container3 = try LocalStore.makeContainer(accountScope: scope, inMemory: false)
            let store3 = LocalStore(modelContainer: container3)
            let pending = try await store3.pendingOutboxEntries(for: owner)
            let entry = try XCTUnwrap(pending.first)
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(entry.operationId, operationId)
            XCTAssertEqual(entry.payloadJSON, payload)
            XCTAssertEqual(entry.sequenceNumber, queued.sequenceNumber)
            XCTAssertEqual(entry.createdAt, queued.createdAt)
            XCTAssertEqual(entry.retryCount, 3)
            XCTAssertTrue(try XCTUnwrap(entry.lastError).contains("INTERNAL_ERROR"))
            let ownerWatermark3 = try await store3.currentWatermark(ownerId: owner)
            let ownerPlants3 = try await store3.activeSyncedEntities(ownerId: owner, entityType: "plant")
            let otherWatermark3 = try await store3.currentWatermark(ownerId: otherOwner)
            let otherPlants3 = try await store3.activeSyncedEntities(ownerId: otherOwner, entityType: "plant")
            let otherOutbox3 = try await store3.pendingOutboxEntries(for: otherOwner)
            XCTAssertEqual(ownerWatermark3, watermark)
            XCTAssertEqual(ownerPlants3, [confirmedItem])
            XCTAssertEqual(otherWatermark3, watermark)
            XCTAssertEqual(otherPlants3, [otherConfirmedItem])
            XCTAssertEqual(otherOutbox3, [foreignQueued])

            let engine3 = SyncEngine(store: store3, apiClient: PlantsAPIClient(transport: mockTransport))
            let replayedCommitted = try await engine3.flushOutbox(for: owner)
            XCTAssertEqual(replayedCommitted, 1)
        }

        let container4 = try LocalStore.makeContainer(accountScope: scope, inMemory: false)
        let store4 = LocalStore(modelContainer: container4)
        let ownerOutbox4 = try await store4.pendingOutboxEntries(for: owner)
        let otherOutbox4 = try await store4.pendingOutboxEntries(for: otherOwner)
        XCTAssertTrue(ownerOutbox4.isEmpty)
        XCTAssertEqual(otherOutbox4, [foreignQueued])
    }

    func testOutboxSurvivesStoreRecreationAndNetworkDropAfterServerCommit() async throws {
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

        // Second LocalStore on the same in-memory container: not a cold process restart.
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

    @MainActor
    func testHistoricalAnalysisWithObsoleteQuestionsSurvivesDiskReopen() async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func makeContainer(at url: URL) throws -> ModelContainer {
            let schema = Schema([
                LocalOutboxRecord.self, GuestDraftCacheRecord.self,
                SyncedEntityRecord.self, SyncCheckpointRecord.self
            ])
            return try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url)
            ])
        }

        for (mode, summary) in [
            ("follow_up", "Historical first aid"), ("follow_up", "Historyczna pierwsza pomoc"),
            ("diagnosis", "Historical first aid"), ("diagnosis", "Historyczna pierwsza pomoc")
        ] {
            let analysisJSON = #"""
            {
              "id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
              "jobId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
              "kbReleaseId":"88888888-8888-4888-8888-888888888888",
              "mode":"MODE", "identificationStatus":"resolved",
              "plantId":"monstera_deliciosa", "genusId":"monstera",
              "diagnosisStatus":"condition_detected",
              "candidates":[{"condition_id":"overwatering","rank":1,"confidence":0.9}],
              "selectedConditionId":"overwatering",
              "visualMarkers":["yellowing_lower_leaves"], "evidenceBasis":["photo"],
              "limitations":["single_angle"], "firstActionSummary":"SUMMARY",
              "controlIntervalDays":7, "contextState":"current", "planAvailability":"available",
              "analysisReceipt":"original.base64-and-signature",
              "decision_state":"pending", "decisionState":"pending",
              "diagnosticQuestion":{"question_code":"old_check","prompt":"OBSOLETE?",
                                    "options":[{"value":"yes","label":"Yes"}]},
              "diagnosticAnswers":[{"question_code":"old_check","answer_value":"yes"}],
              "diagnosticDecision":{"revision":7,"resolution_state":"needs_disambiguation",
                                    "disambiguation_question":{"prompt":"OBSOLETE?"}}
            }
            """#.replacingOccurrences(of: "SUMMARY", with: summary)
                .replacingOccurrences(of: "MODE", with: mode)
            let receiptJSON = #"""
            {
              "analysis_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
              "kb_release_id":"88888888-8888-4888-8888-888888888888",
              "mode":"MODE", "plant_id":"monstera_deliciosa",
              "selected_condition_id":"overwatering", "decision_revision":7,
              "issued_at":"2026-11-01T00:00:00Z", "signature":"original-signature"
            }
            """#.replacingOccurrences(of: "MODE", with: mode)
            let analysis = try decoder.decode(PreliminaryAnalysis.self, from: Data(analysisJSON.utf8))
            let receipt = try decoder.decode(AnalysisReceiptDTO.self, from: Data(receiptJSON.utf8))
            let expectedMode = try XCTUnwrap(AnalysisMode(rawValue: mode))
            XCTAssertEqual(analysis.mode, expectedMode)
            XCTAssertEqual(receipt.mode, expectedMode)
            XCTAssertEqual(analysis.mode.isSelectable, mode == "diagnosis")
            let draftId = UUID()
            let flowId = UUID()
            let storeURL = directory.appendingPathComponent("\(draftId).sqlite")
            let conditions = CareConditionsInput(
                lightLevel: .brightIndirect, lightSource: .manual, lightConfirmed: true,
                wateringHabit: .moderate, lastWatered: .within7Days, potType: .standardDrainage
            )
            let conditionsJSON = String(decoding: try encoder.encode(conditions), as: UTF8.self)
            // Seed the actual stored JSON, including historical unknown fields, before decoding it.
            do {
                let container = try makeContainer(at: storeURL)
                let context = ModelContext(container)
                context.insert(GuestDraftCacheRecord(
                    draftId: draftId, flowId: flowId, intentRaw: "problem", addMethodRaw: "scan",
                    currentStepRaw: "preliminary_result", photoLocalPath: "historical/photo.jpg",
                    confirmedPlantId: "monstera_deliciosa", confirmedTaxonId: nil,
                    confirmedDisplayName: "My Monstera", conditionsJSON: conditionsJSON,
                    resultModeRaw: mode, preliminaryAnalysisJSON: analysisJSON,
                    analysisReceiptJSON: receiptJSON, overridesJSON: nil,
                    serverExpiresAt: Date().addingTimeInterval(3600), isCompleteForFallback: true
                ))
                try context.save()
            }
            // Separate containers reopen the on-disk store; no in-memory container is reused.
            for _ in 0..<2 {
                let container = try makeContainer(at: storeURL)
                let restored = LocalStore(modelContainer: container)
                let loadedValue = try await restored.loadGuestDraft(draftId: draftId)
                let loaded = try XCTUnwrap(loadedValue)
                XCTAssertEqual(loaded.flowState.flowId, flowId)
                XCTAssertEqual(loaded.flowState.resultMode, expectedMode)
                XCTAssertEqual(loaded.flowState.conditions, conditions)
                XCTAssertEqual(loaded.flowState.photoLocalIdentifier, "historical/photo.jpg")
                XCTAssertEqual(loaded.flowState.confirmedDisplayName, "My Monstera")
                XCTAssertEqual(loaded.preliminaryAnalysis, analysis)
                XCTAssertEqual(loaded.analysisReceipt, receipt)
                XCTAssertEqual(loaded.analysisReceipt?.decisionRevision, 7)
                XCTAssertEqual(loaded.preliminaryAnalysis?.analysisReceipt, "original.base64-and-signature")
                XCTAssertEqual(loaded.preliminaryAnalysis?.firstActionSummary, summary)
                let router = AddPlantRouter(initialState: loaded.flowState)
                XCTAssertEqual(router.flowState.currentStep, .preliminaryResult)
                XCTAssertNotEqual(router.flowState.currentStep, .diagnosticRefinement)
                let encoded = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: encoder.encode(try XCTUnwrap(loaded.preliminaryAnalysis))) as? [String: Any])
                for key in ["decision_state", "decisionState", "diagnosticQuestion",
                            "diagnosticAnswers", "diagnosticDecision"] {
                    XCTAssertNil(encoded[key])
                }
                // Re-saving a readable historical result preserves its signed receipt and context.
                try await restored.saveGuestDraft(loaded)
            }
            let encodedReceipt = try XCTUnwrap(JSONSerialization.jsonObject(
                with: encoder.encode(receipt)) as? [String: Any])
            XCTAssertEqual(encodedReceipt["mode"] as? String, mode)
            XCTAssertEqual(encodedReceipt["decision_revision"] as? Int, 7)
            XCTAssertEqual(encodedReceipt["signature"] as? String, "original-signature")
            XCTAssertThrowsError(try decoder.decode(PreliminaryAnalysis.self,
                from: Data(analysisJSON.replacingOccurrences(of: mode, with: "unknown_mode").utf8)))
            XCTAssertThrowsError(try decoder.decode(AnalysisReceiptDTO.self,
                from: Data(receiptJSON.replacingOccurrences(of: mode, with: "unknown_mode").utf8)))
        }
    }

    func testAnalysisWithoutRecommendationRemainsSaveable() async throws {
        let container = try LocalStore.makeContainer(accountScope: "no_advice_\(UUID())", inMemory: true)
        let store = LocalStore(modelContainer: container)
        let draftId = UUID()
        let analysis = PreliminaryAnalysis(
            id: UUID(), jobId: UUID(), kbReleaseId: UUID(), mode: .diagnosis,
            identificationStatus: .unknown, plantId: nil, genusId: nil,
            diagnosisStatus: .unknown, candidates: [], selectedConditionId: nil,
            visualMarkers: [], evidenceBasis: [], limitations: ["Insufficient data"],
            firstActionSummary: nil, controlIntervalDays: nil,
            planAvailability: .diagnosisUnresolved, analysisReceipt: "unchanged.signed-result"
        )
        try await store.saveGuestDraft(GuestDraftCacheSnapshot(
            draftId: draftId,
            flowState: AddFlowState(currentStep: .preliminaryResult, resultMode: .diagnosis, draftId: draftId),
            preliminaryAnalysis: analysis
        ))
        let reopened = LocalStore(modelContainer: container)
        let loadedValue = try await reopened.loadGuestDraft(draftId: draftId)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.preliminaryAnalysis, analysis)
        XCTAssertNil(loaded.preliminaryAnalysis?.firstActionSummary)
        XCTAssertNil(loaded.preliminaryAnalysis?.controlIntervalDays)
        XCTAssertEqual(loaded.flowState.currentStep, .preliminaryResult)
    }
}
