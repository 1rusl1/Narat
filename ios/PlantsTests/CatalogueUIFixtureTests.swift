#if DEBUG
import XCTest
import Foundation
import SwiftData
import Supabase
import UIKit
@testable import Plants

@MainActor
final class CatalogueUIFixtureTests: XCTestCase {
    private let input = CatalogueInput(speciesSlug: "fixture_fern", personalName: " e\u{0301} ")

    private func model(
        _ h: CatalogueUIFixtureContext, flow: UUID = UUID(), operation: UUID = UUID()
    ) async throws -> CatalogueSaveModel {
        let snapshot = try await h.connection.sessionSnapshot()
        return try await h.connection.makeModel(input: input, flowId: flow, operationId: operation, expected: snapshot)
    }
    private func saved(_ model: CatalogueSaveModel) throws -> CatalogueCreateConfirmationSnapshot {
        guard case let .saved(value) = model.state else {
            XCTFail("Expected durable production acknowledgement")
            throw CatalogueUIFixtureError.invalidRequest
        }
        return value
    }
    private func capacity(_ h: CatalogueUIFixtureContext) async throws -> CollectionCapacity {
        let snapshot = try await h.connection.sessionSnapshot()
        let result = try await h.connection.repository!.preflightCapacity(
            session: snapshot.session, isAnonymous: snapshot.isAnonymous
        )
        guard case let .confirmed(value) = result else { throw CatalogueUIFixtureError.invalidRequest }
        return value
    }

    func testRoutineKnownEntitlementDeadlinePolicy() throws {
        let expiry = SQLTimestamp.date(from: "2099-01-01T00:00:01Z")!
        func entitlement(state: String = "active", date: String? = "2099-01-01T00:00:01Z") throws -> SyncWireEntitlementDTO {
            let json: [String: Any] = [
                "product_id": "fixture-only-paid", "state": state, "offer_kind": "paid",
                "valid_until": date.map { $0 as Any } ?? NSNull(), "grace_until": NSNull(), "trial_end_at": NSNull(),
                "auto_renew_enabled": false
            ]
            return try JSONDecoder().decode(SyncWireEntitlementDTO.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let active = try entitlement()
        XCTAssertTrue(CatalogueRoutineAccessPolicy.allows(active, at: expiry.addingTimeInterval(-1)))
        XCTAssertFalse(CatalogueRoutineAccessPolicy.allows(active, at: expiry))
        XCTAssertFalse(CatalogueRoutineAccessPolicy.allows(active, at: expiry.addingTimeInterval(1)))
        XCTAssertFalse(CatalogueRoutineAccessPolicy.allows(try entitlement(state: "expired"), at: expiry.addingTimeInterval(-1)))
        XCTAssertFalse(CatalogueRoutineAccessPolicy.allows(try entitlement(date: nil), at: expiry.addingTimeInterval(-1)))
        XCTAssertTrue(CatalogueRoutineAccessPolicy.allows(nil, at: expiry.addingTimeInterval(1)))
    }

    func testRoutineLateEntitlementIsDeliveredAfterInitialNilAndUpdatesCanonically() async throws {
        let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .routineLateEntitlement)
        defer { try? h.cleanup() }
        let expected = try await h.connection.sessionSnapshot()
        let lease = try await h.connection.collectionLease(expected: expected)
        let sync = try XCTUnwrap(h.connection.syncEngine)
        let repository = try XCTUnwrap(h.connection.repository)
        _ = try await sync.syncNow(for: expected.session.userId)
        let initial = try await h.connection.syncedTrialEntitlement(expected: expected)
        XCTAssertNil(initial)
        XCTAssertNil(h.server.snapshot.routineEntitlementDeadline)
        XCTAssertNil(h.connection.routineFixtureNow, "This fixture must use real Date deadlines")

        let plant = try XCTUnwrap(h.server.snapshot.plants.first)
        let api = try XCTUnwrap(h.connection.apiClient)
        let initialAdvice = try await api.fetchCareRecommendation(plantId: plant.id, context: lease)
        XCTAssertNotNil(initialAdvice)
        XCTAssertNil(initialAdvice?.nextCheck)
        XCTAssertNil(initialAdvice?.routineContext)
        let command = try await repository.enqueueCareRecommendationRefresh(plantId: plant.id, context: lease)
        let started = Date()
        let outcome = try await repository.retryCareRecommendationRefresh(command, context: lease)
        guard case .confirmed = outcome else { return XCTFail("Refresh must publish a canonical sync window") }
        let delivered = try await h.connection.syncedTrialEntitlement(expected: expected)
        let deadline = try XCTUnwrap(delivered?.verifiedAccessUntil)
        XCTAssertGreaterThan(deadline, started)
        XCTAssertLessThanOrEqual(deadline, Date().addingTimeInterval(6))
        XCTAssertTrue(CatalogueRoutineAccessPolicy.allows(delivered, at: deadline.addingTimeInterval(-1)))
        XCTAssertFalse(CatalogueRoutineAccessPolicy.allows(delivered, at: deadline))
        XCTAssertNotNil(h.server.snapshot.routineEntitlementDeadline)
        let refreshedAdvice = try await api.fetchCareRecommendation(plantId: plant.id, context: lease)
        XCTAssertEqual(refreshedAdvice?.nextCheck?.dueOn, "2000-01-01")
        XCTAssertNotNil(refreshedAdvice?.routineContext)

        // Canonical renewal replaces the old deadline; revocation denies immediately.
        let renewedDeadline = deadline.addingTimeInterval(30)
        try h.server.setRoutineEntitlement(deadline: renewedDeadline)
        let beforeSync = try await h.connection.syncedTrialEntitlement(expected: expected)
        XCTAssertEqual(beforeSync, delivered, "Server changes must not bypass canonical delivery")
        _ = try await sync.syncNow(for: expected.session.userId)
        let renewed = try await h.connection.syncedTrialEntitlement(expected: expected)
        XCTAssertEqual(try XCTUnwrap(renewed?.verifiedAccessUntil).timeIntervalSince1970,
                       renewedDeadline.timeIntervalSince1970, accuracy: 0.002)
        XCTAssertTrue(CatalogueRoutineAccessPolicy.allows(renewed, at: deadline))
        XCTAssertFalse(CatalogueRoutineAccessPolicy.allows(renewed, at: renewedDeadline))
        try h.server.setRoutineEntitlement(deadline: renewedDeadline, state: "expired")
        _ = try await sync.syncNow(for: expected.session.userId)
        let revoked = try await h.connection.syncedTrialEntitlement(expected: expected)
        XCTAssertEqual(revoked?.state, "expired")
        XCTAssertFalse(CatalogueRoutineAccessPolicy.allows(revoked, at: Date()))

        let other = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .free2)
        defer { try? other.cleanup() }
        let foreign = try await other.connection.sessionSnapshot()
        do {
            _ = try await h.connection.syncedTrialEntitlement(expected: foreign)
            XCTFail("A foreign owner read must throw, never return nil Free access")
        } catch CatalogueSaveUnavailable.sessionChanged {
        }
        let afterFailedRead = try await h.connection.syncedTrialEntitlement(expected: expected)
        XCTAssertEqual(afterFailedRead, revoked)
        XCTAssertFalse(CatalogueRoutineAccessPolicy.allows(afterFailedRead, at: Date()))
    }

    func testFreeSaveCanonicalReadbackAndExactReplay() async throws {
        let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .free2)
        defer { try? h.cleanup() }
        let initial = try await capacity(h)
        XCTAssertEqual(initial.plantCount, 2)
        XCTAssertFalse(initial.hasVerifiedPaidAccess)
        let model = try await model(h)
        let envelope = try XCTUnwrap(model.envelope)
        let before = try await h.connection.store!.currentWatermarkRaw(ownerId: initial.ownerId)
        await model.save()
        let confirmation = try saved(model)
        XCTAssertEqual(confirmation.receipt.contextState, "current")
        XCTAssertEqual(confirmation.receipt.nextAvailableStep, "view_plant")
        XCTAssertEqual(confirmation.receipt.planAvailability, "care_profile_unavailable")
        XCTAssertNil(confirmation.receipt.paidAction)
        XCTAssertEqual(model.input, input)
        let afterReceipt = try await h.connection.store!.currentWatermarkRaw(ownerId: initial.ownerId)
        XCTAssertEqual(before, afterReceipt, "Receipt alone cannot advance the sync checkpoint")
        XCTAssertEqual(h.server.snapshot.commits.count, 1)
        XCTAssertEqual(h.server.snapshot.plants.count, 3)
        XCTAssertNotEqual(confirmation.receipt.plantId, envelope.operationId)
        let replay = try await h.connection.apiClient!.sendCatalogueCreate(envelope)
        XCTAssertEqual(replay, confirmation.receipt)
        XCTAssertEqual(h.server.snapshot.commits.count, 1)
        XCTAssertEqual(h.server.snapshot.plants.count, 3)
        let refreshed = try await capacity(h)
        XCTAssertEqual(refreshed.plantCount, 3)
        let scope = try await h.connection.sessionSnapshot()
        let lease = try await h.connection.collectionLease(expected: scope)
        let collection = try await h.connection.repository!.collectionCards(context: lease)
        XCTAssertFalse(collection.isCached)
        let cards = collection.cards
        XCTAssertEqual(cards.count, 3)
        let savedCard = try XCTUnwrap(cards.first { $0.id == confirmation.receipt.plantId })
        XCTAssertEqual(savedCard.speciesSlug, input.speciesSlug)
        let rows = try await h.connection.store!.activeSyncedEntities(ownerId: initial.ownerId, entityType: "plants")
        let row = try XCTUnwrap(rows.first { $0.id == confirmation.receipt.plantId })
        let data = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(row.payloadJSON.utf8)) as? [String: Any])
        XCTAssertEqual(data["id"] as? String, confirmation.receipt.plantId.uuidString)
        XCTAssertEqual(data["plant_id"] as? String, input.speciesSlug)
        let canonicalName = input.personalName?.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        XCTAssertEqual(data["personal_name"] as? String, canonicalName)
        XCTAssertEqual(data["display_name"] as? String, canonicalName)
        XCTAssertNil(data["care_enabled"])
        XCTAssertEqual(data["revision"] as? Int, 1)
        XCTAssertEqual(data["care_revision"] as? Int, 1)
        XCTAssertNotNil(data["created_at"])
        XCTAssertNil(data["owner_id"])
        let pending = try await h.connection.store!.pendingOutboxEntries(for: initial.ownerId)
        XCTAssertTrue(pending.isEmpty)
        let changed = try CatalogueInput(speciesSlug: "fixture_fern", personalName: "changed").makeEnvelope(operationId: envelope.operationId)
        do {
            _ = try await h.connection.apiClient!.sendCatalogueCreate(changed)
            XCTFail("Changed replay must be rejected")
        } catch {}
        XCTAssertEqual(h.server.snapshot.commits.count, 1)
    }

    func testPaidFourUsesCanonicalEntitlementAndSavesFifth() async throws {
        let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .paid4)
        defer { try? h.cleanup() }
        let before = try await capacity(h)
        XCTAssertEqual(before.plantCount, 4)
        XCTAssertTrue(before.hasVerifiedPaidAccess)
        let model = try await model(h)
        await model.save()
        let receipt = try saved(model).receipt
        XCTAssertEqual(receipt.contextState, "current")
        XCTAssertEqual(receipt.nextAvailableStep, "view_plant")
        XCTAssertEqual(receipt.planAvailability, "care_profile_unavailable")
        XCTAssertNil(receipt.paidAction)
        let after = try await capacity(h)
        XCTAssertEqual(after.plantCount, 5)
        XCTAssertEqual(h.server.snapshot.commits.count, 1)
        let rights = try await h.connection.store!.syncedEntitlement(ownerId: before.ownerId)
        XCTAssertEqual(rights?.state, "active")
        XCTAssertEqual(rights?.offerKind, "paid")
    }

    func testCapThreePreservesInputWithoutCommandPOST() async throws {
        let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .cap3)
        defer { try? h.cleanup() }
        let model = try await model(h)
        await model.save()
        guard case let .collectionLimitNotEnqueued(value) = model.state else {
            return XCTFail("Expected production preflight cap")
        }
        XCTAssertEqual(value.plantCount, 3)
        XCTAssertEqual(model.input, input)
        XCTAssertTrue(h.server.snapshot.attempts.isEmpty)
        let pending = try await h.connection.store!.pendingOutboxEntries(for: value.ownerId)
        XCTAssertTrue(pending.isEmpty)
    }

    private func serverError(_ scenario: CatalogueUIFixtureScenario, code: String, retryable: Bool) async throws {
        let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: scenario)
        defer { try? h.cleanup() }
        let before = try await capacity(h)
        XCTAssertEqual(before.plantCount, 2)
        let model = try await model(h)
        let envelope = model.envelope
        await model.save()
        guard case let .pending(entry) = model.state else { return XCTFail("Expected real engine pending state") }
        XCTAssertEqual(entry.operationId, envelope?.operationId)
        XCTAssertEqual(model.pendingAPIError?.error.code, code)
        XCTAssertEqual(model.pendingAPIError?.error.retryable, retryable)
        XCTAssertEqual(model.input, input)
        XCTAssertEqual(h.server.snapshot.attempts.count, 1)
        XCTAssertTrue(h.server.snapshot.commits.isEmpty)
        let persisted = try await h.connection.store!.pendingOutboxEntries(for: before.ownerId)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.payloadJSON, envelope?.payloadJSON)
    }
    func testAuthoritative409AfterSuccessfulTwoPlantPreflight() async throws {
        try await serverError(.server409, code: "COLLECTION_LIMIT_REACHED", retryable: false)
    }
    func test503RetainsExactInputAndDurablePending() async throws {
        try await serverError(.server503, code: "INTERNAL_ERROR", retryable: true)
    }

    func testCommittedLostResponseRestartAtCapExplicitRetryAndDurableACK() async throws {
        let namespace = UUID().uuidString, flow = UUID(), operation = UUID()
        let first = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .lostresponse)
        let original = try await model(first, flow: flow, operation: operation)
        await original.save()
        guard case .pending = original.state else { return XCTFail("Lost response must remain pending") }
        let committed = first.server.snapshot
        XCTAssertEqual(committed.plants.count, 3)
        XCTAssertEqual(committed.commits.count, 1)
        XCTAssertTrue(committed.lostResponseCommitted)
        let originalBody = try XCTUnwrap(committed.attempts.first?.body)
        let plantID = try XCTUnwrap(committed.commits.values.first?.plantID)
        first.shutdown()
        let second = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .lostresponse)
        defer { try? second.cleanup() }
        let cap = try await capacity(second)
        XCTAssertEqual(cap.plantCount, 3)
        XCTAssertFalse(cap.canCreate)
        XCTAssertEqual(second.server.snapshot.signupCount, 0)
        let snapshot = try await second.connection.sessionSnapshot()
        let restored = await second.connection.restoreModel(ownerId: cap.ownerId, flowId: flow, expected: snapshot)
        guard case let .restored(model) = restored, case .pending = model.state else {
            return XCTFail("Expected durable pending restoration")
        }
        XCTAssertEqual(second.server.snapshot.attempts.count, 1, "Restoring must not send")
        await model.save()
        let confirmation = try saved(model)
        XCTAssertEqual(confirmation.receipt.plantId, plantID)
        XCTAssertEqual(confirmation.operationId, operation)
        XCTAssertEqual(second.server.snapshot.attempts.map(\.body), [originalBody, originalBody])
        XCTAssertEqual(second.server.snapshot.commits.count, 1)
        XCTAssertEqual(second.server.snapshot.plants.count, 3)
        second.shutdown()
        let third = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .lostresponse)
        defer { try? third.cleanup() }
        let thirdSnapshot = try await third.connection.sessionSnapshot()
        let durable = await third.connection.restoreModel(ownerId: cap.ownerId, flowId: flow, expected: thirdSnapshot)
        guard case let .restored(acked) = durable else { return XCTFail("Expected persisted ACK") }
        XCTAssertEqual(try saved(acked), confirmation)
        let queue = try await third.connection.store!.pendingOutboxEntries(for: cap.ownerId)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(third.server.snapshot.attempts.count, 2)
    }

    /// Read actual SDK/SQLite restoration, including the only current-owner resume pointer.
    private func ackPending(
        _ h: CatalogueUIFixtureContext,
        checkpoint expectedCheckpoint: CatalogueInputCheckpointSnapshot? = nil,
        queue expectedQueue: [OutboxEntrySnapshot]? = nil
    ) async throws -> CatalogueSaveModel {
        let snapshot = try await h.connection.sessionSnapshot()
        XCTAssertFalse(snapshot.isAnonymous)
        let flow = try XCTUnwrap(try h.connection.resumableFlow(expected: snapshot))
        let result = await h.connection.restoreModel(
            ownerId: snapshot.session.userId, flowId: flow, expected: snapshot
        )
        guard case let .restored(model) = result, case let .pending(entry) = model.state else {
            XCTFail("Expected the original SQLite pending flow")
            throw CatalogueUIFixtureError.invalidStorage
        }
        let checkpoint = try XCTUnwrap(model.checkpoint)
        XCTAssertEqual(checkpoint.flowId, flow)
        XCTAssertEqual(checkpoint.ownerId, snapshot.session.userId)
        XCTAssertEqual(model.input, CatalogueInput(speciesSlug: "fixture_fern", personalName: "Luna"))
        XCTAssertEqual(model.envelope, checkpoint.envelope)
        XCTAssertEqual(entry.operationId, checkpoint.operationId)
        XCTAssertEqual(Data(entry.payloadJSON.utf8), Data(checkpoint.envelope.payloadJSON.utf8))
        let queue = try await h.connection.store!.pendingOutboxEntries(for: snapshot.session.userId)
        XCTAssertEqual(queue, [entry])
        if let expectedCheckpoint { XCTAssertEqual(checkpoint, expectedCheckpoint) }
        if let expectedQueue { XCTAssertEqual(queue, expectedQueue) }
        let disk = ModelContext(h.connection.store!.modelContainer)
        XCTAssertEqual(try disk.fetch(FetchDescriptor<CatalogueInputCheckpointRecord>()).count, 1)
        XCTAssertEqual(try disk.fetch(FetchDescriptor<LocalOutboxRecord>()).count, 1)
        XCTAssertTrue(try disk.fetch(FetchDescriptor<CatalogueCreateConfirmationRecord>()).isEmpty)
        let confirmation = try await h.connection.store!.catalogueCreateConfirmation(
            ownerId: snapshot.session.userId, operationId: checkpoint.operationId
        )
        XCTAssertNil(confirmation)
        return model
    }

    func testRealSQLiteACKFailureRestartExactReplayAndWritableRecovery() async throws {
        let namespace = UUID().uuidString
        let first = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .ackFailure)
        let original = try await ackPending(first)
        let checkpoint = try XCTUnwrap(original.checkpoint)
        let queue = try await first.connection.store!.pendingOutboxEntries(for: checkpoint.ownerId)
        XCTAssertTrue(first.server.snapshot.attempts.isEmpty, "Setup must not POST a create")
        XCTAssertTrue(first.server.snapshot.commits.isEmpty)
        XCTAssertEqual(first.server.snapshot.plants.count, 2)
        first.shutdown()

        // Recreating an untouched namespace cannot seed another flow or clear the fault.
        let untouched = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .ackFailure)
        _ = try await ackPending(untouched, checkpoint: checkpoint, queue: queue)
        XCTAssertTrue(untouched.server.snapshot.attempts.isEmpty)
        untouched.shutdown()
        let failing = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .ackFailure)
        let attempt = try await ackPending(failing, checkpoint: checkpoint, queue: queue)
        let expected = try await failing.connection.sessionSnapshot()
        let remembered = try await failing.connection.rememberModel(attempt, expected: expected)
        XCTAssertEqual(remembered, checkpoint)
        await attempt.save()
        XCTAssertEqual(attempt.state, .unavailable(.storageOrServiceUnavailable))
        XCTAssertNil(attempt.cardSummary)
        let committed = failing.server.snapshot
        XCTAssertEqual(committed.attempts.count, 1)
        XCTAssertEqual(committed.commits.count, 1)
        XCTAssertEqual(committed.plants.count, 3)
        let commit = try XCTUnwrap(committed.commits.values.first)
        let body = try XCTUnwrap(committed.attempts.first?.body)
        XCTAssertEqual(commit.envelope, checkpoint.envelope)
        XCTAssertEqual(commit.owner, checkpoint.ownerId)
        XCTAssertEqual(commit.body, body)
        let receipt = try JSONDecoder().decode(PlantCreateReceiptDTO.self, from: commit.receipt)
        XCTAssertEqual(receipt.plantId, commit.plantID)
        _ = try await ackPending(failing, checkpoint: checkpoint, queue: queue)
        failing.shutdown()

        // Even another recreation after one real POST remains read-only.
        let stillFaulted = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .ackFailure)
        _ = try await ackPending(stillFaulted, checkpoint: checkpoint, queue: queue)
        XCTAssertEqual(stillFaulted.server.snapshot.attempts.count, 1)
        XCTAssertEqual(stillFaulted.server.snapshot.commits.count, 1)
        stillFaulted.shutdown()
        let replay = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .ackFailure)
        let retry = try await ackPending(replay, checkpoint: checkpoint, queue: queue)
        let replaySnapshot = try await replay.connection.sessionSnapshot()
        let replayCheckpoint = try await replay.connection.rememberModel(retry, expected: replaySnapshot)
        XCTAssertEqual(replayCheckpoint, checkpoint)
        await retry.save()
        XCTAssertEqual(retry.state, .unavailable(.storageOrServiceUnavailable))
        XCTAssertNil(retry.cardSummary)
        _ = try await ackPending(replay, checkpoint: checkpoint, queue: queue)
        XCTAssertEqual(replay.server.snapshot.attempts.map(\.body), [body, body])
        XCTAssertEqual(replay.server.snapshot.commits.count, 1)
        XCTAssertEqual(replay.server.snapshot.plants.count, 3)
        replay.shutdown()

        // Two persisted HTTP attempts permit writable reopening; no automatic send occurs.
        let recovery = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .ackFailure)
        let pending = try await ackPending(recovery, checkpoint: checkpoint, queue: queue)
        XCTAssertEqual(recovery.server.snapshot.attempts.count, 2)
        let recoverySnapshot = try await recovery.connection.sessionSnapshot()
        let recoveryCheckpoint = try await recovery.connection.rememberModel(pending, expected: recoverySnapshot)
        XCTAssertEqual(recoveryCheckpoint, checkpoint)
        await pending.save()
        let confirmation = try saved(pending)
        XCTAssertEqual(confirmation.operationId, checkpoint.operationId)
        XCTAssertEqual(confirmation.payloadJSON, checkpoint.envelope.payloadJSON)
        XCTAssertEqual(confirmation.receipt, receipt, "Durable ACK must retain the first server receipt")
        XCTAssertEqual(confirmation.receipt.plantId, commit.plantID)
        await pending.loadCard()
        XCTAssertEqual(pending.cardSummary?.id, commit.plantID)
        XCTAssertEqual(pending.cardSummary?.personalName, "Luna")
        XCTAssertEqual(recovery.server.snapshot.attempts.map(\.body), [body, body, body])
        XCTAssertEqual(recovery.server.snapshot.commits.count, 1)
        XCTAssertEqual(recovery.server.snapshot.plants.count, 3)
        let empty = try await recovery.connection.store!.pendingOutboxEntries(for: checkpoint.ownerId)
        XCTAssertTrue(empty.isEmpty)
        let disk = ModelContext(recovery.connection.store!.modelContainer)
        XCTAssertEqual(try disk.fetch(FetchDescriptor<CatalogueCreateConfirmationRecord>()).count, 1)
        recovery.shutdown()

        let durable = try await CatalogueUIFixtures.make(namespace: namespace, scenario: .ackFailure)
        defer { try? durable.cleanup() }
        let durableSnapshot = try await durable.connection.sessionSnapshot()
        XCTAssertEqual(try durable.connection.resumableFlow(expected: durableSnapshot), checkpoint.flowId)
        let restored = await durable.connection.restoreModel(
            ownerId: checkpoint.ownerId, flowId: checkpoint.flowId, expected: durableSnapshot
        )
        guard case let .restored(savedModel) = restored else {
            XCTFail("Expected the original durably acknowledged flow")
            throw CatalogueUIFixtureError.invalidStorage
        }
        XCTAssertEqual(savedModel.checkpoint, checkpoint)
        XCTAssertEqual(try saved(savedModel), confirmation)
        await savedModel.loadCard()
        XCTAssertEqual(savedModel.cardSummary?.id, commit.plantID)
        XCTAssertEqual(durable.server.snapshot.attempts.map(\.body), [body, body, body])
        XCTAssertEqual(durable.server.snapshot.commits.count, 1)
        let durableDisk = ModelContext(durable.connection.store!.modelContainer)
        XCTAssertEqual(try durableDisk.fetch(FetchDescriptor<CatalogueInputCheckpointRecord>()).count, 1)
        XCTAssertEqual(try durableDisk.fetch(FetchDescriptor<CatalogueCreateConfirmationRecord>()).count, 1)
        XCTAssertTrue(try durableDisk.fetch(FetchDescriptor<LocalOutboxRecord>()).isEmpty)
    }

    func testNativeFixtureSuppliedBundleAvailabilityAndAbsentMetadata() async throws {
        for scenario in [CatalogueUIFixtureScenario.guestProviderCancel, .guestProviderSuccess,
                         .guestProviderFailureRetry, .guestProvidersUnavailable] {
            let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: scenario)
            defer { try? h.cleanup() }
            XCTAssertEqual(h.connection.accountProviders.contains(.google), scenario != .guestProvidersUnavailable)
            XCTAssertEqual(h.connection.accountProviders.contains(.apple), scenario != .guestProvidersUnavailable)
            if scenario == .guestProvidersUnavailable {
                let original = try await model(h)
                _ = try await original.checkpointInput()
                let outcome = await h.connection.signInAndSave(original, with: .google, presenting: UIViewController())
                guard case .unavailable = outcome else { return XCTFail("Missing metadata must fail closed") }
                XCTAssertEqual(h.identity.calls, 0)
                XCTAssertEqual(h.server.snapshot.authProof?.providerAttempts, 0)
                XCTAssertEqual(h.server.snapshot.authProof?.authIdTokenRequests, 0)
                XCTAssertTrue(h.server.snapshot.commits.isEmpty)
            }
        }
    }

    func testNativeFirstFailureRetainsDiskCheckpointAndExplicitRetryCommitsOnce() async throws {
        let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .guestProviderFailureRetry)
        defer { try? h.cleanup() }
        let original = try await model(h)
        let checkpoint = try await original.checkpointInput()
        let first = await h.connection.signInAndSave(original, with: .google, presenting: UIViewController())
        guard case let .inputRetained(retained, .authenticationFailed(.providerFailed)) = first else {
            return XCTFail("Expected the first actual provider action to fail")
        }
        XCTAssertTrue(retained === original)
        XCTAssertEqual(retained.input, input)
        XCTAssertEqual(retained.checkpoint, checkpoint)
        let disk = ModelContext(h.connection.store!.modelContainer)
        let row = try XCTUnwrap(try disk.fetch(FetchDescriptor<CatalogueInputCheckpointRecord>()).first {
            $0.flowId == checkpoint.flowId
        })
        XCTAssertEqual(row.operationId, checkpoint.operationId)
        XCTAssertEqual(row.payloadJSON, checkpoint.envelope.payloadJSON)
        XCTAssertTrue(h.server.snapshot.attempts.isEmpty)
        XCTAssertTrue(h.server.snapshot.commits.isEmpty)
        XCTAssertEqual(h.server.snapshot.authProof?.providerAttempts, 1)
        XCTAssertEqual(h.server.snapshot.authProof?.providerFailures, 1)
        XCTAssertEqual(h.server.snapshot.authProof?.authIdTokenRequests, 0)
        let retry = await h.connection.signInAndSave(retained, with: .google, presenting: UIViewController())
        guard case let .continued(permanent) = retry else { return XCTFail("Explicit retry must continue saving") }
        let receipt = try saved(permanent)
        XCTAssertEqual(receipt.operationId, checkpoint.operationId)
        XCTAssertEqual(receipt.payloadJSON, checkpoint.envelope.payloadJSON)
        XCTAssertEqual(h.server.snapshot.authProof?.providerAttempts, 2)
        XCTAssertEqual(h.server.snapshot.authProof?.providerFailures, 1)
        XCTAssertEqual(h.server.snapshot.authProof?.authIdTokenRequests, 1)
        XCTAssertEqual(h.server.snapshot.attempts.count, 1)
        XCTAssertEqual(h.server.snapshot.commits.count, 1)
        XCTAssertEqual(try disk.fetch(FetchDescriptor<CatalogueCreateConfirmationRecord>()).count, 1)
    }

    func testGuestCancelAndNativeSuccessUseSameSDKCheckpointBeforeProviderWithoutTransfer() async throws {
        for scenario in [CatalogueUIFixtureScenario.guestProviderCancel, .guestProviderSuccess] {
            let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: scenario)
            defer { try? h.cleanup() }
            let sdk = try XCTUnwrap(h.connection.client)
            let guest = try await h.connection.sessionSnapshot()
            XCTAssertTrue(guest.isAnonymous)
            let flow = UUID(), operation = UUID()
            let model = try await model(h, flow: flow, operation: operation)
            let envelope = try XCTUnwrap(model.envelope)
            let foreignOperation = try await h.connection.store!.enqueueCommand(
                ownerId: guest.session.userId, plantId: UUID(), commandName: "care.complete", payloadJSON: "{}"
            )
            h.identity.beforeCredentials = {
                let disk = ModelContext(h.connection.store!.modelContainer)
                let checkpoint = try XCTUnwrap(try disk.fetch(FetchDescriptor<CatalogueInputCheckpointRecord>()).first {
                    $0.ownerId == guest.session.userId && $0.flowId == flow
                })
                XCTAssertEqual(checkpoint.operationId, operation)
                XCTAssertEqual(Data(checkpoint.payloadJSON.utf8), Data(envelope.payloadJSON.utf8))
                XCTAssertEqual(sdk.auth.currentSession?.user.isAnonymous, true)
            }
            let outcome = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
            XCTAssertTrue(h.connection.client === sdk)
            XCTAssertEqual(h.identity.calls, 1)
            if scenario == .guestProviderCancel {
                guard case let .inputRetained(retained, .cancelled) = outcome else {
                    return XCTFail("Expected actual native cancellation")
                }
                XCTAssertTrue(retained === model)
                XCTAssertEqual(retained.input, input)
                XCTAssertEqual(sdk.auth.currentSession?.user.id, guest.session.userId)
                XCTAssertTrue(h.server.snapshot.commits.isEmpty)
            } else {
                guard case let .continued(permanent) = outcome else { return XCTFail("Expected native SDK exchange") }
                let confirmation = try saved(permanent)
                XCTAssertEqual(confirmation.operationId, operation)
                XCTAssertEqual(confirmation.payloadJSON, envelope.payloadJSON)
                XCTAssertEqual(sdk.auth.currentSession?.user.isAnonymous, false)
                XCTAssertNotEqual(sdk.auth.currentSession?.user.id, guest.session.userId)
                let current = try await h.connection.sessionSnapshot()
                XCTAssertEqual(try h.connection.resumableFlow(expected: current), flow)
                XCTAssertEqual(h.server.snapshot.attempts.map(\.owner), [current.session.userId])
            }
            let guestQueue = try await h.connection.store!.pendingOutboxEntries(for: guest.session.userId)
            XCTAssertEqual(guestQueue.map(\.operationId), [foreignOperation.operationId])
        }
    }

    func testNamespaceIsolationPersistentAnonymousSDKCatalogueAndFailClosedURLs() async throws {
        let name = UUID().uuidString
        let first = try await CatalogueUIFixtures.make(namespace: name, scenario: .guestProviderSuccess)
        let other = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .cap3)
        defer { try? other.cleanup() }
        let guest = try await first.connection.sessionSnapshot()
        let model = try await model(first)
        let checkpoint = try await model.checkpointInput()
        first.shutdown()
        let reopened = try await CatalogueUIFixtures.make(namespace: name, scenario: .guestProviderSuccess)
        defer { try? reopened.cleanup() }
        let current = try await reopened.connection.sessionSnapshot()
        XCTAssertEqual(current.session.userId, guest.session.userId)
        XCTAssertTrue(current.isAnonymous)
        XCTAssertEqual(reopened.server.snapshot.signupCount, 1)
        let otherSnapshot = try await other.connection.sessionSnapshot()
        XCTAssertNotEqual(otherSnapshot.session.userId, current.session.userId)
        let otherRows = try await other.connection.store!.activeSyncedEntities(ownerId: current.session.userId, entityType: "plants")
        XCTAssertTrue(otherRows.isEmpty)
        let foreign = await other.connection.restoreModel(ownerId: current.session.userId, flowId: checkpoint.flowId, expected: otherSnapshot)
        guard case .unavailable(.sessionChanged) = foreign else { return XCTFail("Foreign owner must fail closed") }
        let api = try XCTUnwrap(reopened.connection.apiClient)
        for locale in [SupportedLocale.en, .pl] {
            let page = try await api.searchPublishedCatalogue(query: "Nephrolepis", locale: locale, limit: 1, offset: 0)
            XCTAssertEqual(page.items.first?.id, "fixture_fern")
            XCTAssertEqual(page.items.first?.displayName, locale == .pl ? "Paproć" : "Fern")
            XCTAssertNil(page.items.first?.heroImage)
            let card = try await api.fetchPublishedSpecies(slug: "fixture_fern", locale: locale)
            XCTAssertEqual(card.taxonId, page.items.first?.taxonId)
            let byTaxon = try await api.fetchPublishedSpecies(taxonId: card.taxonId, locale: locale)
            XCTAssertEqual(byTaxon.id, card.id)
            XCTAssertEqual(byTaxon.displayName, card.displayName)
            let end = try await api.searchPublishedCatalogue(query: "Nephrolepis", locale: locale, limit: 1, offset: 1)
            XCTAssertEqual(end.releaseVersion, page.releaseVersion)
            XCTAssertEqual(end.total, 1)
            XCTAssertTrue(end.items.isEmpty)
        }
        _ = try await reopened.connection.client!.auth.refreshSession()
        let user = try await reopened.connection.client!.auth.user()
        XCTAssertEqual(user.id, current.session.userId)
        for url in ["https://unknown.invalid/", "https://" + reopened.namespace + ".invalid/unknown"] {
            do { _ = try await reopened.http.data(from: URL(string: url)!); XCTFail("Unknown URL reached transport") }
            catch {}
        }
        do { _ = try await CatalogueUIFixtures.make(namespace: "../outside", scenario: .free2); XCTFail("Invalid namespace accepted") }
        catch {}
        try await reopened.connection.client!.auth.signOut()
        XCTAssertNil(reopened.connection.client!.auth.currentSession)
    }

    private func c2Source(_ card: PublishedSpeciesCard) -> PublishedPlantImageSource {
        PublishedPlantImageSource(
            url: card.heroImage?.downloadURL, author: card.heroImage?.author,
            license: card.heroImage?.license, attribution: card.heroImage?.attribution,
            sourcePage: card.heroImage?.sourcePage
        )
    }

    private func c2Reject(_ session: URLSession, _ url: URL) async {
        do {
            _ = try await session.data(from: url)
            XCTFail("Scoped public fixture accepted a foreign or malformed URL")
        } catch {}
    }

    func testPublishedFixtureDecodedPixelsCacheMetadataAndPublicTransport() async throws {
        let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .publishedMedia)
        defer { try? h.cleanup() }
        let api = try XCTUnwrap(h.connection.apiClient)
        let page = try await api.searchPublishedCatalogue(query: "", locale: .en, limit: 50, offset: 0)
        XCTAssertEqual(page.items.count, 50)
        XCTAssertEqual(page.total, 50)
        XCTAssertEqual(try h.server.publishedMediaLedger.listGETs, 1)
        XCTAssertEqual(try h.server.publishedMediaLedger.detailGETs, 0)
        XCTAssertTrue(try h.server.publishedMediaLedger.requests.isEmpty)
        let source = c2Source(try XCTUnwrap(page.items.first))
        XCTAssertEqual(source.author, CataloguePublishedFixture.author)
        XCTAssertEqual(source.license, CataloguePublishedFixture.license)
        XCTAssertEqual(source.attribution, CataloguePublishedFixture.attribution)
        XCTAssertEqual(source.sourcePage?.absoluteString, CataloguePublishedFixture.sourcePage)
        XCTAssertEqual(source.credit, "Narat Fixture Studio · CC0-1.0 · Deterministic fern colour study")
        let beforeAPI = h.server.requests.count
        let loader = h.connection.publicMediaLoader
        let image = try await loader.load(source)
        let cached = try await loader.load(source)
        XCTAssertTrue(image === cached)
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, 8)
        XCTAssertEqual(cg.height, 8)
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        var green = 0, orange = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let rgba = Array(pixels[index..<(index + 4)])
            if rgba == [32, 160, 64, 255] { green += 1 }
            if rgba == [240, 128, 16, 255] { orange += 1 }
        }
        XCTAssertEqual(green, 32)
        XCTAssertEqual(orange, 32)
        let media = try h.server.publishedMediaLedger
        XCTAssertEqual(media.requests.count, 1, "The second load must use the actual image cache")
        XCTAssertTrue(media.requests.allSatisfy {
            $0.accepted && !$0.authorizationPresent && !$0.installationPresent
                && !$0.namespaceHeaderPresent && !$0.cookiePresent
        })
        XCTAssertEqual(media.pngSHA256, CataloguePublishedFixture.pngSHA256)
        XCTAssertEqual(h.server.requests.count, beforeAPI, "Image loads must never use the API session")
        let session = try XCTUnwrap(h.mediaHTTP)
        XCTAssertTrue(session.configuration.httpAdditionalHeaders?.isEmpty != false)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
        XCTAssertNil(session.configuration.urlCache)
        let (data, _) = try await session.data(from: try XCTUnwrap(source.url))
        XCTAssertEqual(data, CataloguePublishedFixture.png)
        XCTAssertNotNil(UIImage(data: data))
        let nilState = PublishedPlantImageState()
        let beforeNil = try h.server.publishedMediaLedger.requests.count
        await nilState.load(c2Source(page.items[1]), using: loader)
        guard case .missing = nilState.phase else { return XCTFail("Nil metadata must render the missing phase") }
        XCTAssertEqual(try h.server.publishedMediaLedger.requests.count, beforeNil)
        let failed = PublishedPlantImageState()
        await failed.load(c2Source(page.items[2]), using: loader)
        guard case .failed = failed.phase else { return XCTFail("HTTP 503 must render the failure phase") }
        let failureCount = try h.server.publishedMediaLedger.requests.count
        await failed.load(c2Source(page.items[2]), using: loader)
        XCTAssertEqual(try h.server.publishedMediaLedger.requests.count, failureCount + 1, "Failures are not cached")
        for value in [
            "https://unknown.invalid/image.png",
            "https://catalogue-media.fixture.invalid/media/" + h.namespace + "/unknown.png",
            "https://catalogue-media.fixture.invalid/media/" + h.namespace + "/fern.png?unexpected=1",
            "http://catalogue-media.fixture.invalid/media/" + h.namespace + "/fern.png"
        ] {
            await c2Reject(session, try XCTUnwrap(URL(string: value)))
        }
        XCTAssertEqual(h.server.requests.count, beforeAPI)
    }

    func testPublishedFixtureConcurrentNamespaceIsolationAndShutdown() async throws {
        let first = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .publishedMedia)
        let second = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .publishedMedia)
        defer { try? first.cleanup(); try? second.cleanup() }
        let firstSession = try XCTUnwrap(first.mediaHTTP)
        let secondSession = try XCTUnwrap(second.mediaHTTP)
        let firstURL = CataloguePublishedFixture.imageURL(namespace: first.namespace)
        let secondURL = CataloguePublishedFixture.imageURL(namespace: second.namespace)
        let firstAPI = first.server.requests.count, secondAPI = second.server.requests.count
        let a = try await first.connection.publicMediaLoader.load(.init(url: firstURL))
        let b = try await second.connection.publicMediaLoader.load(.init(url: secondURL))
        XCTAssertFalse(a === b, "Each context owns its decoded cache")
        await c2Reject(firstSession, secondURL)
        await c2Reject(secondSession, firstURL)
        XCTAssertEqual(try first.server.publishedMediaLedger.requests.filter(\.accepted).count, 1)
        XCTAssertEqual(try second.server.publishedMediaLedger.requests.filter(\.accepted).count, 1)
        XCTAssertEqual(first.server.requests.count, firstAPI)
        XCTAssertEqual(second.server.requests.count, secondAPI)
        let name = first.namespace
        first.shutdown()
        XCTAssertNil(first.mediaHTTP)
        XCTAssertNil(first.connection)
        let reopened = try await CatalogueUIFixtures.make(namespace: name, scenario: .publishedMedia)
        defer { reopened.shutdown() }
        let count = try reopened.server.publishedMediaLedger.requests.count
        _ = try await reopened.connection.publicMediaLoader.load(.init(url: firstURL))
        XCTAssertEqual(try reopened.server.publishedMediaLedger.requests.count, count + 1, "Cold context cannot reuse the old cache")
        _ = try await second.connection.publicMediaLoader.load(.init(url: secondURL))
        XCTAssertEqual(try second.server.publishedMediaLedger.requests.filter(\.accepted).count, 1)
    }

    func testPublishedIdentificationCheckpointUUIDMappingAndColdRestoreWithoutCreate() async throws {
        let name = UUID().uuidString
        let h = try await CatalogueUIFixtures.make(namespace: name, scenario: .publishedIdentificationResume)
        defer { h.shutdown() }
        let proofURL = h.directory.appendingPathComponent("c2-resume-proof.json")
        let proofData = try Data(contentsOf: proofURL)
        let proof = try JSONDecoder().decode(CataloguePublishedResumeProof.self, from: proofData)
        let expected = try await h.connection.sessionSnapshot()
        XCTAssertEqual(proof.namespace, h.namespace)
        XCTAssertEqual(proof.original, proof.current)
        XCTAssertEqual(proof.original.job, CataloguePublishedFixture.job)
        XCTAssertEqual(proof.original.taxon, CataloguePublishedFixture.taxon)
        XCTAssertEqual(proof.original.name, "Luna")
        XCTAssertEqual(proof.original.owner, expected.session.userId)
        XCTAssertEqual(proof.checkpointCount, 1)
        XCTAssertEqual(proof.commandAttempts, 0)
        XCTAssertEqual(proof.newCommits, 0)
        XCTAssertEqual(proof.plantCount, 2)
        let initialResult = await h.connection.restoreModel(
            ownerId: expected.session.userId, flowId: proof.original.flow, expected: expected
        )
        guard case let .restored(initial) = initialResult else { return XCTFail("Expected real durable checkpoint") }
        let originalInput = try XCTUnwrap(initial.input)
        let originalEnvelope = try XCTUnwrap(initial.envelope)
        let originalCheckpoint = try XCTUnwrap(initial.checkpoint)
        XCTAssertNil(initial.input?.speciesSlug)
        XCTAssertEqual(initial.input?.speciesIdentifier, CataloguePublishedFixture.taxon.uuidString.lowercased())
        XCTAssertEqual(initial.input?.identification?.jobId, proof.original.job)
        XCTAssertEqual(initial.input?.personalName, "Luna")
        XCTAssertEqual(try CataloguePublishedFixture.envelopeHash(originalEnvelope), proof.original.envelopeSHA256)
        let selection = try XCTUnwrap(CatalogueResumeSelection(initial))
        XCTAssertEqual(selection.flowId, proof.original.flow)
        XCTAssertEqual(selection.speciesSlug, CataloguePublishedFixture.taxon.uuidString.lowercased())
        XCTAssertEqual(selection.identification, initial.input?.identification)
        XCTAssertNil(selection.diagnosisJobId)
        XCTAssertFalse(CatalogueSaveIdentity.allowsEditingAsNewSave(analysisFlow: selection.flowId))
        do {
            _ = try await h.connection.apiClient!.fetchPublishedSpecies(taxonId: proof.original.taxon, locale: .en)
            XCTFail("The first public detail GET must fail with the fixture 503")
        } catch let failure as APIErrorResponse {
            XCTAssertEqual(failure.error.code, "INTERNAL_ERROR")
            XCTAssertTrue(failure.error.retryable)
        }
        XCTAssertEqual(try h.server.publishedMediaLedger.detailGETs, 1)
        for locale in [SupportedLocale.en, .pl] {
            let card = try await h.connection.apiClient!.fetchPublishedSpecies(taxonId: proof.original.taxon, locale: locale)
            XCTAssertEqual(card.id, "fixture_fern")
            XCTAssertNotEqual(card.id, selection.speciesSlug)
            XCTAssertEqual(card.taxonId, selection.identification?.taxonId)
            XCTAssertEqual(card.displayName, locale == .pl ? "Paproć" : "Fern")
            let slugCard = try await h.connection.apiClient!.fetchPublishedSpecies(slug: card.id, locale: locale)
            XCTAssertEqual(slugCard.taxonId, card.taxonId)
        }
        h.shutdown()
        let cold = try await CatalogueUIFixtures.make(namespace: name, scenario: .publishedIdentificationResume)
        defer { try? cold.cleanup() }
        let current = try await cold.connection.sessionSnapshot()
        XCTAssertEqual(current.session.userId, expected.session.userId)
        XCTAssertEqual(try cold.connection.resumableFlow(expected: current), proof.original.flow)
        let result = await cold.connection.restoreModel(
            ownerId: current.session.userId, flowId: proof.original.flow, expected: current
        )
        guard case let .restored(restored) = result else { return XCTFail("Expected SQLite restore after cold context") }
        XCTAssertEqual(restored.checkpoint, originalCheckpoint)
        XCTAssertEqual(restored.envelope, originalEnvelope)
        XCTAssertEqual(restored.input, originalInput)
        XCTAssertEqual(try Data(contentsOf: proofURL), proofData)
        let disk = ModelContext(cold.connection.store!.modelContainer)
        XCTAssertEqual(try disk.fetchCount(FetchDescriptor<CatalogueInputCheckpointRecord>()), 1)
        XCTAssertTrue(cold.server.snapshot.attempts.isEmpty)
        XCTAssertTrue(cold.server.snapshot.commits.isEmpty)
        XCTAssertEqual(cold.server.snapshot.plants.count, 2)
        XCTAssertFalse(cold.server.requests.contains {
            $0.httpMethod == "POST" && $0.url?.path.hasPrefix("/functions/") == true
        })

        // The same production selection helper preserves diagnosis identity too.
        let diagnosis = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .free2)
        defer { try? diagnosis.cleanup() }
        let diagnosisScope = try await diagnosis.connection.sessionSnapshot()
        let job = UUID(), flow = UUID(), operation = UUID()
        let model = try await diagnosis.connection.makeModel(
            input: CatalogueInput(diagnosisJobId: job, speciesSlug: "fixture_fern", personalName: "Luna"),
            flowId: flow, operationId: operation, expected: diagnosisScope
        )
        let checkpoint = try await diagnosis.connection.rememberModel(model, expected: diagnosisScope)
        let diagnosisResult = await diagnosis.connection.restoreModel(
            ownerId: diagnosisScope.session.userId, flowId: flow, expected: diagnosisScope
        )
        guard case let .restored(diagnosisModel) = diagnosisResult else { return XCTFail("Expected diagnosis checkpoint") }
        let diagnosisSelection = try XCTUnwrap(CatalogueResumeSelection(diagnosisModel))
        XCTAssertEqual(diagnosisSelection.flowId, flow)
        XCTAssertEqual(diagnosisSelection.diagnosisJobId, job)
        XCTAssertEqual(diagnosisSelection.speciesSlug, "fixture_fern")
        XCTAssertNil(diagnosisSelection.identification)
        XCTAssertEqual(diagnosisModel.checkpoint, checkpoint)
        XCTAssertEqual(diagnosisModel.envelope?.operationId, operation)
        XCTAssertTrue(diagnosis.server.snapshot.attempts.isEmpty)
        XCTAssertTrue(diagnosis.server.snapshot.commits.isEmpty)
    }
}
#endif
