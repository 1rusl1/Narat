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
    private var legacySlotProfileJSON: String {
        #"{"id":"11111111-1111-4111-8111-111111111111","account_state":"active","anonymous":true,"preferred_locale":"en","reminder_hour_local":17,"free_selection_explicit":true,"trial_reminder_opt_in":true,"monthly_report_opt_in":false,"updated_at":"2026-11-01T00:00:00Z"}"#
    }

    private var legacySlotMembershipJSON: String {
        #"{"id":"22222222-2222-4222-8222-222222222222","owner_id":"11111111-1111-4111-8111-111111111111","plant_id":"33333333-3333-4333-8333-333333333333","enabled":true,"enabled_at":"2026-10-01T00:00:00Z","free_slot":2,"selection_revision":19,"updated_at":"2026-11-01T00:00:00Z","deleted_at":"2026-11-02T00:00:00Z"}"#
    }

    private func slotJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func slotJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func slotJSONObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testProfileReadsLegacyAndCurrentValuesButOnlyWritesCurrentFields() throws {
        for retiredValue in [true, false, nil] as [Bool?] {
            var input = try slotJSONObject(Data(legacySlotProfileJSON.utf8))
            if let retiredValue {
                input["free_selection_explicit"] = retiredValue
            } else {
                input.removeValue(forKey: "free_selection_explicit")
            }
            let profile = try slotJSONDecoder().decode(ProfileDTO.self,
                from: JSONSerialization.data(withJSONObject: input))
            XCTAssertEqual(profile.freeSelectionExplicit, retiredValue ?? false)
            let output = try slotJSONObject(slotJSONEncoder().encode(profile))
            input.removeValue(forKey: "free_selection_explicit")
            XCTAssertEqual(output as NSDictionary, input as NSDictionary)
            XCTAssertFalse(try slotJSONDecoder().decode(ProfileDTO.self,
                from: slotJSONEncoder().encode(profile)).freeSelectionExplicit)
        }
        let nullJSON = legacySlotProfileJSON.replacingOccurrences(
            of: #""free_selection_explicit":true"#, with: #""free_selection_explicit":null"#)
        XCTAssertFalse(try slotJSONDecoder().decode(ProfileDTO.self,
            from: Data(nullJSON.utf8)).freeSelectionExplicit)
    }

    func testMembershipReadsLegacyAndCurrentValuesButOnlyWritesCurrentFields() throws {
        for legacy in [true, false] {
            for deletedValue in ["present", "absent", "null"] {
                var input = try slotJSONObject(Data(legacySlotMembershipJSON.utf8))
                if !legacy {
                    input.removeValue(forKey: "free_slot")
                    input.removeValue(forKey: "selection_revision")
                }
                if deletedValue == "absent" { input.removeValue(forKey: "deleted_at") }
                if deletedValue == "null" { input["deleted_at"] = NSNull() }
                let membership = try slotJSONDecoder().decode(BasicCareMembership.self,
                    from: JSONSerialization.data(withJSONObject: input))
                XCTAssertEqual(membership.freeSlot, legacy ? 2 : nil)
                XCTAssertEqual(membership.selectionRevision, legacy ? 19 : 0)
                XCTAssertEqual(membership.deletedAt != nil, deletedValue == "present")
                let output = try slotJSONObject(slotJSONEncoder().encode(membership))
                input.removeValue(forKey: "free_slot")
                input.removeValue(forKey: "selection_revision")
                if deletedValue == "null" { input.removeValue(forKey: "deleted_at") }
                XCTAssertEqual(output as NSDictionary, input as NSDictionary)
                let current = try slotJSONDecoder().decode(BasicCareMembership.self,
                    from: slotJSONEncoder().encode(membership))
                XCTAssertNil(current.freeSlot)
                XCTAssertEqual(current.selectionRevision, 0)
                XCTAssertEqual(current.deletedAt, membership.deletedAt)
            }
        }
        var nullInput = try slotJSONObject(Data(legacySlotMembershipJSON.utf8))
        nullInput["free_slot"] = NSNull()
        nullInput["selection_revision"] = NSNull()
        let nullMembership = try slotJSONDecoder().decode(BasicCareMembership.self,
            from: JSONSerialization.data(withJSONObject: nullInput))
        XCTAssertNil(nullMembership.freeSlot)
        XCTAssertEqual(nullMembership.selectionRevision, 0)
    }

    func testLegacySelectionAndStepDecodeWithoutAllowingNewRetiredStepWrites() throws {
        let selectionJSON = #"{"selected_plant_ids":["33333333-3333-4333-8333-333333333333"],"selection_revision":19,"explicit_selection":true,"max_slots":3}"#
        let selection = try slotJSONDecoder().decode(FreeSelection.self, from: Data(selectionJSON.utf8))
        XCTAssertEqual(selection.selectedPlantIds, [UUID(uuidString: "33333333-3333-4333-8333-333333333333")!])
        XCTAssertEqual(selection.selectionRevision, 19)
        XCTAssertTrue(selection.explicitSelection)
        XCTAssertEqual(selection.maxSlots, 3)
        let retired = try slotJSONDecoder().decode(NextAvailableStep.self,
            from: Data(#""select_free_plants""#.utf8))
        XCTAssertEqual(retired, .selectFreePlants)
        XCTAssertThrowsError(try slotJSONEncoder().encode(retired)) { error in
            guard case EncodingError.invalidValue = error else {
                return XCTFail("Expected retired selector encoding rejection, got \(error)")
            }
        }
        for step in NextAvailableStep.allCases where step != .selectFreePlants {
            let data = try slotJSONEncoder().encode(step)
            XCTAssertEqual(try slotJSONDecoder().decode(String.self, from: data), step.rawValue)
            XCTAssertEqual(try slotJSONDecoder().decode(NextAvailableStep.self, from: data), step)
        }
    }

    @MainActor
    func testLegacySlotDiskRowsAndGenericReplayRemainExactAfterDTOEncoding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy-slots.sqlite")
        func container() throws -> ModelContainer {
            let schema = Schema([
                LocalOutboxRecord.self, CatalogueCreateConfirmationRecord.self,
                CatalogueInputCheckpointRecord.self, GuestDraftCacheRecord.self,
                SyncedEntityRecord.self, SyncCheckpointRecord.self
            ])
            return try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url)
            ])
        }
        let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let plant = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let operation = UUID()
        let receiptOperation = UUID()
        let payload = #" { "selected_plant_ids" : ["33333333-3333-4333-8333-333333333333"], "selection_revision" : 19 } "#
        let receiptJSON = #"{"plant_id":"33333333-3333-4333-8333-333333333333","care_revision":7,"context_state":"current","next_available_step":"select_free_plants","paid_action":null,"plan_availability":"available","watermark":"2026-11-01T00:00:00.123456Z"}"#
        let historyJSON = #" { "selected_plant_ids" : ["33333333-3333-4333-8333-333333333333"], "selection_revision" : 19, "explicit_selection" : true, "max_slots" : 3 } "#
        let rows = [
            ("profile", legacySlotProfileJSON),
            ("basic_care_membership", legacySlotMembershipJSON),
            ("history", historyJSON)
        ]
        do {
            let disk = try container()
            let context = ModelContext(disk)
            context.insert(LocalOutboxRecord(operationId: operation, ownerId: owner,
                commandName: "free_care.select", payloadJSON: payload, sequenceNumber: 1))
            context.insert(CatalogueCreateConfirmationRecord(ownerId: owner,
                operationId: receiptOperation, payloadJSON: payload, receiptJSON: receiptJSON))
            let checkpoint = SyncCheckpointRecord(ownerId: owner, freeSelectionRevision: 19)
            checkpoint.syncProfileJSON = legacySlotProfileJSON
            context.insert(checkpoint)
            for (type, raw) in rows {
                context.insert(SyncedEntityRecord(ownerId: owner, entityType: type,
                    entityId: plant, updatedAt: Date(timeIntervalSince1970: 1_762_000_000),
                    payloadJSON: raw))
            }
            try context.save()
        }
        for pass in 0..<2 {
            let disk = try container()
            let store = LocalStore(modelContainer: disk)
            let pending = try await store.pendingOutboxEntries(for: owner)
            XCTAssertEqual(pending.count, 1)
            let entry = try XCTUnwrap(pending.first)
            XCTAssertEqual(entry.operationId, operation)
            XCTAssertEqual(entry.commandName, "free_care.select")
            XCTAssertEqual(Data(entry.payloadJSON.utf8), Data(payload.utf8))
            for (type, raw) in rows {
                let entities = try await store.activeSyncedEntities(ownerId: owner, entityType: type)
                XCTAssertEqual(entities.count, 1)
                XCTAssertEqual(Data(try XCTUnwrap(entities.first).payloadJSON.utf8), Data(raw.utf8))
            }
            _ = try slotJSONEncoder().encode(slotJSONDecoder().decode(
                ProfileDTO.self, from: Data(legacySlotProfileJSON.utf8)))
            _ = try slotJSONEncoder().encode(slotJSONDecoder().decode(
                BasicCareMembership.self, from: Data(legacySlotMembershipJSON.utf8)))
            let selection = try slotJSONDecoder().decode(FreeSelection.self, from: Data(historyJSON.utf8))
            XCTAssertEqual(selection.selectionRevision, 19)
            let receipt = try await store.catalogueCreateConfirmation(
                ownerId: owner, operationId: receiptOperation)
            let decodedReceipt = try XCTUnwrap(receipt)
            let encodedReceipt = try slotJSONObject(slotJSONEncoder().encode(decodedReceipt.receipt))
            XCTAssertEqual(encodedReceipt["next_available_step"] as? String, "select_free_plants")
            XCTAssertEqual(encodedReceipt["watermark"] as? String, "2026-11-01T00:00:00.123456Z")
            if pass == 0 {
                let transport = UnavailableSyncTransport()
                let client = PlantsAPIClient(transport: transport, installationCredential: "fixture",
                    clientLocale: "pl", bearerToken: "fixture")
                let engine = SyncEngine(store: store, apiClient: client)
                let committed = try await engine.flushOutbox(for: owner)
                XCTAssertEqual(committed, 0)
                let bodies = await transport.commandBodies
                XCTAssertEqual(bodies.count, 1)
                let envelope = try slotJSONDecoder().decode(CommandEnvelopeDTO.self,
                    from: XCTUnwrap(bodies.first))
                XCTAssertEqual(envelope.operationId, operation)
                XCTAssertEqual(envelope.commandName, "free_care.select")
                XCTAssertEqual(Data(envelope.payloadJSON.utf8), Data(payload.utf8))
            }
            let context = ModelContext(disk)
            let checkpoint = try XCTUnwrap(context.fetch(FetchDescriptor<SyncCheckpointRecord>()).first)
            XCTAssertEqual(checkpoint.freeSelectionRevision, 19)
            XCTAssertEqual(Data(try XCTUnwrap(checkpoint.syncProfileJSON).utf8),
                Data(legacySlotProfileJSON.utf8))
            let storedReceipt = try XCTUnwrap(context.fetch(
                FetchDescriptor<CatalogueCreateConfirmationRecord>()).first)
            XCTAssertEqual(Data(storedReceipt.receiptJSON.utf8), Data(receiptJSON.utf8))
            XCTAssertEqual(Data(storedReceipt.payloadJSON.utf8), Data(payload.utf8))
            for row in try context.fetch(FetchDescriptor<SyncedEntityRecord>()) {
                let expected = try XCTUnwrap(rows.first { $0.0 == row.entityType }?.1)
                XCTAssertEqual(Data(row.payloadJSON.utf8), Data(expected.utf8))
            }
        }
    }

    func testPersistedLegacyClaimOverridesReadConditionsAndEncodeWithoutRoomKeys() async throws {
        let container = try LocalStore.makeContainer(accountScope: "t158_\(UUID())", inMemory: true)
        let draftId = UUID()
        let taxonId = UUID(uuidString: "11111111-1111-4111-8111-111111111101")!
        let legacyJSON = #"""
        {
          "plant_id":"monstera_deliciosa", "taxon_id":"11111111-1111-4111-8111-111111111101",
          "display_name":"Salon Monstera", "room_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          "new_room_name":"Salon", "light_level":"low", "light_source":"camera_estimate",
          "light_confirmed":false, "watering_habit":"sparse", "last_watered":"within_3_days",
          "pot_type":"terracotta", "season_override":"autumn_winter"
        }
        """#
        let expected = ClaimOverridesDTO(
            plantId: "monstera_deliciosa", taxonId: taxonId, displayName: "Salon Monstera",
            lightLevel: .low, lightSource: .cameraEstimate, lightConfirmed: false,
            wateringHabit: .sparse, lastWatered: .within3Days,
            potType: .terracotta, seasonOverride: .autumnWinter
        )
        let encoder = JSONEncoder()
        let conditionsJSON = String(decoding: try encoder.encode(CareConditionsInput()), as: UTF8.self)
        // Seed historical raw JSON in SwiftData, then read it through the production store.
        do {
            let context = ModelContext(container)
            context.insert(GuestDraftCacheRecord(
                draftId: draftId, flowId: UUID(), intentRaw: "problem", addMethodRaw: "scan",
                currentStepRaw: "preliminary_result", photoLocalPath: nil,
                confirmedPlantId: "monstera_deliciosa", confirmedTaxonId: taxonId,
                confirmedDisplayName: "Salon Monstera", conditionsJSON: conditionsJSON,
                resultModeRaw: "diagnosis", preliminaryAnalysisJSON: nil,
                analysisReceiptJSON: nil, overridesJSON: legacyJSON,
                serverExpiresAt: Date().addingTimeInterval(3600), isCompleteForFallback: true
            ))
            try context.save()
        }
        let store = LocalStore(modelContainer: container)
        let loadedValue = try await store.loadGuestDraft(draftId: draftId)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.overrides, expected)
        let encoded = try encoder.encode(try XCTUnwrap(loaded.overrides))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["room_id", "new_room_name", "create_room_name"] {
            XCTAssertNil(object[key])
        }
        XCTAssertEqual(object.count, 10)
        XCTAssertEqual(try JSONDecoder().decode(ClaimOverridesDTO.self, from: encoded), expected)
        try await store.saveGuestDraft(loaded)
        let recreated = LocalStore(modelContainer: container)
        let savedValue = try await recreated.loadGuestDraft(draftId: draftId)
        XCTAssertEqual(try XCTUnwrap(savedValue).overrides, expected)
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<GuestDraftCacheRecord>())
        let savedJSON = try XCTUnwrap(records.first(where: { $0.draftId == draftId })?.overridesJSON)
        let savedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(savedJSON.utf8)) as? [String: Any])
        for key in ["room_id", "new_room_name", "create_room_name"] {
            XCTAssertNil(savedObject[key])
        }
        XCTAssertEqual(try JSONDecoder().decode(ClaimOverridesDTO.self, from: Data(savedJSON.utf8)), expected)
    }

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
