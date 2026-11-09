#if DEBUG
import XCTest
import Foundation
import SwiftData
import Supabase
import UIKit
@testable import Plants

@MainActor
final class CatalogueUIFixtureTests: XCTestCase {
    private let input = CatalogueInput(speciesSlug: "fixture-fern", personalName: " e\u{0301} ")

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
        let rows = try await h.connection.store!.activeSyncedEntities(ownerId: initial.ownerId, entityType: "plants")
        let row = try XCTUnwrap(rows.first { $0.id == confirmation.receipt.plantId })
        let data = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(row.payloadJSON.utf8)) as? [String: Any])
        XCTAssertEqual(data["id"] as? String, confirmation.receipt.plantId.uuidString)
        XCTAssertEqual(data["plant_id"] as? String, input.speciesSlug)
        XCTAssertEqual(data["personal_name"] as? String, input.personalName)
        XCTAssertEqual(data["revision"] as? Int, 1)
        XCTAssertEqual(data["care_revision"] as? Int, 1)
        XCTAssertNotNil(data["created_at"])
        XCTAssertNil(data["owner_id"])
        let pending = try await h.connection.store!.pendingOutboxEntries(for: initial.ownerId)
        XCTAssertTrue(pending.isEmpty)
        let changed = try CatalogueInput(speciesSlug: "fixture-fern", personalName: "changed").makeEnvelope(operationId: envelope.operationId)
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
        _ = try saved(model)
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

    func testNamespaceIsolationPersistentAnonymousSDKRPCAndFailClosedURLs() async throws {
        struct Page: Decodable {
            struct Card: Decodable { let plant_id: String; let display_name: String; let hero_image: String? }
            let items: [Card]
        }
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
        for locale in ["en", "pl"] {
            let page: Page = try await reopened.connection.client!.rpc("search_catalogue_species", params: ["p_locale": locale]).execute().value
            XCTAssertEqual(page.items.first?.plant_id, "fixture-fern")
            XCTAssertEqual(page.items.first?.display_name, locale == "pl" ? "Paproć" : "Fern")
            XCTAssertNil(page.items.first?.hero_image)
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
}
#endif
