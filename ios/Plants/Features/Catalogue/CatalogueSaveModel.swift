import Foundation
import Observation

enum CatalogueSaveUnavailable: Error, Sendable, Equatable {
    case sessionChanged
    case cancelled
    case storageOrServiceUnavailable
}

enum CatalogueSaveState: Sendable, Equatable {
    case ready
    case busy
    case signInRequired
    case pending(OutboxEntrySnapshot)
    case saved(CatalogueCreateConfirmationSnapshot)
    case collectionLimitNotEnqueued(CollectionCapacity)
    case unavailable(CatalogueSaveUnavailable)
}

@MainActor
enum CatalogueSaveRestoration {
    case absent
    case restored(CatalogueSaveModel)
    case unavailable(CatalogueSaveUnavailable)
}

/// One immutable SDK snapshot, flow, operation and original bound lease.
/// A replacement SDK session requires a new model, even for the same owner/token.
@MainActor
@Observable
final class CatalogueSaveModel {
    private let store: LocalStore
    private let apiClient: PlantsAPIClient
    private let repository: CollectionRepository
    private let context: SyncSessionLease
    private let isAnonymous: Bool
    private let flowId: UUID
    private let frozenInput: CatalogueInput
    private let frozenEnvelope: CommandEnvelopeDTO
    private var frozenCheckpoint: CatalogueInputCheckpointSnapshot?
    private var phase: CatalogueSaveState = .ready
    private var cancelled = false
    @ObservationIgnored private var work: Task<Void, Never>?

    // Access is checked as well as publication: an idle old model also redacts after ABA.
    var state: CatalogueSaveState {
        let value = phase
        if cancelled { return .unavailable(.cancelled) }
        guard (try? apiClient.syncAuthority.withBoundValid(context, {})) != nil else {
            return .unavailable(.sessionChanged)
        }
        return value
    }

    var input: CatalogueInput? { isAccessible ? frozenInput : nil }
    var envelope: CommandEnvelopeDTO? { isAccessible ? frozenEnvelope : nil }
    var checkpoint: CatalogueInputCheckpointSnapshot? {
        let value = frozenCheckpoint
        return isAccessible ? value : nil
    }
    var pendingAPIError: APIErrorResponse? {
        guard case let .pending(entry) = state else { return nil }
        return entry.lastAPIError
    }

    private var isAccessible: Bool {
        guard !cancelled else { return false }
        return (try? apiClient.syncAuthority.withBoundValid(context, {})) != nil
    }

    init(
        store: LocalStore, apiClient: PlantsAPIClient, repository: CollectionRepository,
        flowId: UUID, operationId: UUID, input: CatalogueInput,
        session: NativeAuthSession, isAnonymous: Bool
    ) async throws {
        let captured: SyncSessionLease
        do {
            captured = try await apiClient.captureSyncContext(ownerId: session.userId)
            guard captured.session == session else { throw CatalogueSaveUnavailable.sessionChanged }
            try apiClient.syncAuthority.withBoundValid(captured) {}
        } catch is CancellationError {
            throw CatalogueSaveUnavailable.cancelled
        } catch {
            throw CatalogueSaveUnavailable.sessionChanged
        }
        let envelope: CommandEnvelopeDTO
        do { envelope = try input.makeEnvelope(operationId: operationId) }
        catch { throw CatalogueSaveUnavailable.storageOrServiceUnavailable }
        self.store = store
        self.apiClient = apiClient
        self.repository = repository
        self.context = captured
        self.isAnonymous = isAnonymous
        self.flowId = flowId
        self.frozenInput = input
        self.frozenEnvelope = envelope
    }

    private init(
        store: LocalStore, apiClient: PlantsAPIClient, repository: CollectionRepository,
        context: SyncSessionLease, isAnonymous: Bool,
        checkpoint: CatalogueInputCheckpointSnapshot, input: CatalogueInput,
        state: CatalogueSaveState
    ) {
        self.store = store
        self.apiClient = apiClient
        self.repository = repository
        self.context = context
        self.isAnonymous = isAnonymous
        self.flowId = checkpoint.flowId
        self.frozenInput = input
        // Keep the accepted checkpoint envelope; decoding input never rebuilds the send body.
        self.frozenEnvelope = checkpoint.envelope
        self.frozenCheckpoint = checkpoint
        self.phase = state
    }

    /// Explicit same-owner lookup only. No requests, enqueue, IDs or auth rebinding.
    static func restore(
        store: LocalStore, apiClient: PlantsAPIClient, repository: CollectionRepository,
        ownerId: UUID, flowId: UUID, session: NativeAuthSession, isAnonymous: Bool
    ) async -> CatalogueSaveRestoration {
        var captured: SyncSessionLease?
        do {
            guard ownerId == session.userId else { throw CatalogueSaveUnavailable.sessionChanged }
            let context = try await apiClient.captureSyncContext(ownerId: ownerId)
            captured = context
            guard context.session == session else { throw CatalogueSaveUnavailable.sessionChanged }
            try apiClient.syncAuthority.withBoundValid(context) {}
            guard let checkpoint = try await store.catalogueInputCheckpoint(
                flowId: flowId, context: context, authority: apiClient.syncAuthority
            ) else {
                return try apiClient.syncAuthority.withBoundValid(context) { .absent }
            }
            try apiClient.syncAuthority.withBoundValid(context) {}
            let input = try JSONDecoder().decode(
                CheckpointInput.self, from: Data(checkpoint.envelope.payloadJSON.utf8)
            )
            let journal = try await store.catalogueCreateJournal(
                checkpoint.envelope, mode: .checkOnly,
                context: context, authority: apiClient.syncAuthority
            )
            return try apiClient.syncAuthority.withBoundValid(context) {
                let state: CatalogueSaveState
                if isAnonymous {
                    state = .signInRequired
                } else {
                    switch journal {
                    case let .confirmed(confirmation): state = .saved(confirmation)
                    case let .pending(entry): state = .pending(entry)
                    case .absent: state = .ready
                    case .collectionLimitNotEnqueued:
                        throw CatalogueSaveUnavailable.storageOrServiceUnavailable
                    }
                }
                return .restored(CatalogueSaveModel(
                    store: store, apiClient: apiClient, repository: repository,
                    context: context, isAnonymous: isAnonymous, checkpoint: checkpoint,
                    input: CatalogueInput(speciesSlug: input.plant_id, personalName: input.personal_name),
                    state: state
                ))
            }
        } catch is CancellationError {
            return .unavailable(.cancelled)
        } catch SyncWireValidationError.invalidSession {
            return .unavailable(.sessionChanged)
        } catch {
            if let captured,
               (try? apiClient.syncAuthority.withBoundValid(captured, {})) == nil {
                return .unavailable(.sessionChanged)
            }
            if error as? CatalogueSaveUnavailable == .sessionChanged {
                return .unavailable(.sessionChanged)
            }
            return .unavailable(.storageOrServiceUnavailable)
        }
    }

    // LocalStore has already validated the minimal input and its exact identity.
    private struct CheckpointInput: Decodable {
        let plant_id: String
        let personal_name: String?
    }

    /// Duplicate taps join no new operation and cannot turn busy into success.
    func save() async {
        guard work == nil, !cancelled else { return }
        if Task.isCancelled { cancel(); return }
        if case .saved = state { return }
        let task = Task { await self.performSave() }
        work = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        work = nil
    }

    /// Invalidate this facade permanently, preserving its durable input and any queue entry.
    func cancel() {
        cancelled = true
        work?.cancel()
        phase = .unavailable(.cancelled)
    }

    private func validateAuthority() throws {
        guard !cancelled else { throw CancellationError() }
        try apiClient.syncAuthority.withBoundValid(context) {}
    }

    /// Observation calls observers synchronously. Release the authority lock before
    /// mutation so callbacks can reread this model, invalidate its session or cancel.
    /// Recheck afterwards: a callback may have revoked authority before returning.
    private func publish(_ mutation: () -> Void) throws {
        try validateAuthority()
        mutation()
        try validateAuthority()
    }

    private func performSave() async {
        do {
            try publish { phase = .busy }
            if frozenCheckpoint == nil {
                let checkpoint = try await store.checkpointCatalogueInput(
                    frozenInput, flowId: flowId, operationId: frozenEnvelope.operationId,
                    context: context, authority: apiClient.syncAuthority
                )
                try publish { frozenCheckpoint = checkpoint }
            }
            // The SDK's explicit anonymous snapshot guards the registered path.
            if isAnonymous {
                try publish { phase = .signInRequired }
                return
            }
            try validateAuthority()
            let result = try await repository.saveCatalogueCreate(
                envelope: frozenEnvelope, context: context
            )
            try publish {
                switch result {
                case .signInRequired: phase = .signInRequired
                case let .saved(confirmation): phase = .saved(confirmation)
                case let .pending(entry): phase = .pending(entry)
                case let .collectionLimitNotEnqueued(capacity):
                    phase = .collectionLimitNotEnqueued(capacity)
                }
            }
        } catch {
            if Task.isCancelled || error is CancellationError ||
                (error as? URLError)?.code == .cancelled {
                cancel()
            } else {
                // No raw SQL/network/token/user data becomes a UI diagnostic.
                phase = .unavailable(isAccessible ? .storageOrServiceUnavailable : .sessionChanged)
            }
        }
    }
}
