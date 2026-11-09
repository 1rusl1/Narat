import Foundation
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
