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

enum CatalogueWateringHistoryState: Sendable, Equatable {
    case idle
    case loading
    case loaded([CatalogueCareJournalEntry])
    case unavailable
}

enum CatalogueCareRecommendationState: Sendable, Equatable {
    case idle
    case loading
    case available(PlantCareRecommendation)
    case unavailable
    case failed
}

enum CatalogueManualWateringState: Sendable, Equatable {
    case unavailable
    case ready
    case saving
    case pending
}

enum CatalogueCardState: Sendable, Equatable {
    case idle
    case loading
    case loaded(CatalogueCardSummary)
    case unavailable
}

@MainActor
enum CatalogueSaveRestoration {
    case absent
    case restored(CatalogueSaveModel)
    case unavailable(CatalogueSaveUnavailable)
}

/// Transient operation-entry UI authority. Inactive callers keep the legacy read behavior.
@MainActor
struct CatalogueSaveCompletion {
    let isCurrent: () -> Bool
    let publish: () -> Void
}

/// Completion of an explicit card read, independent of command acceptance.
@MainActor
struct CatalogueCardReadCompletion {
    let isCurrent: () -> Bool
    let publish: () -> Void
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
    private var detailsPhase: CatalogueCardState = .idle
    private var confirmedConditions: PlantConditionCodes?
    private var historyPhase: CatalogueWateringHistoryState = .idle
    private var recommendationPhase: CatalogueCareRecommendationState = .idle
    @ObservationIgnored private var recommendationRead = 0
    private var manualWateringPhase: CatalogueManualWateringState = .unavailable
    private var frozenWateringCommand: CommandEnvelopeDTO?

    var wateringHistoryState: CatalogueWateringHistoryState {
        let value = historyPhase
        guard isAccessible else { return .unavailable }
        guard case .saved = state else { return .idle }
        return value
    }
    @ObservationIgnored private var detailsTask: Task<Void, Never>?

    /// Idle retained models redact details immediately after logout, switch or ABA.
    var cardState: CatalogueCardState {
        let value = detailsPhase
        guard isAccessible else { return .unavailable }
        guard case .saved = state else { return .idle }
        return value
    }

    var cardSummary: CatalogueCardSummary? {
        guard case let .loaded(summary) = cardState else { return nil }
        return summary
    }

    /// Only synchronized conditions for this confirmed diagnosis and current lease.
    var diagnosisConditions: PlantConditionCodes? {
        guard frozenInput.diagnosisJobId != nil,
              case let .saved(confirmation) = state,
              let card = cardSummary, card.id == confirmation.receipt.plantId,
              card.mainPhotoId == confirmation.receipt.photoId,
              card.speciesSlug == frozenInput.speciesSlug,
              let conditions = confirmedConditions,
              conditions.plantId == card.id,
              conditions.id == card.currentConditionSnapshotId else { return nil }
        return conditions
    }

    var careRecommendationState: CatalogueCareRecommendationState {
        guard isAccessible, !isAnonymous, cardSummary != nil else { return .unavailable }
        return recommendationPhase
    }

    func loadCareRecommendation(retry: Bool = false) async {
        guard !isAnonymous, case let .saved(confirmation) = state,
              let card = cardSummary, card.id == confirmation.receipt.plantId else { return }
        switch recommendationPhase {
        case .idle: break
        case .failed where retry: break
        default: return
        }
        recommendationRead += 1
        let requested = recommendationRead
        do {
            try publish { recommendationPhase = .loading }
            let recommendation = try await apiClient.fetchCareRecommendation(plantId: card.id, context: context)
            try validateAuthority()
            guard recommendationRead == requested else { return }
            guard case let .saved(current) = state, current == confirmation,
                  cardSummary == card else { throw CatalogueSaveUnavailable.sessionChanged }
            try publish {
                recommendationPhase = recommendation.map(CatalogueCareRecommendationState.available) ?? .unavailable
            }
        } catch {
            guard recommendationRead == requested else { return }
            if Task.isCancelled {
                recommendationPhase = .idle
            } else {
                try? publish { recommendationPhase = .failed }
            }
        }
    }

    var manualWateringState: CatalogueManualWateringState {
        guard isAccessible, !isAnonymous, cardSummary != nil else { return .unavailable }
        return manualWateringPhase
    }

    func recordWatering(completion: CatalogueSaveCompletion? = nil) async {
        await beginManualWatering(.record, completion: completion)
    }

    func undoWatering(entryId: UUID, completion: CatalogueSaveCompletion? = nil) async {
        guard case let .loaded(entries) = wateringHistoryState,
              entries.contains(where: { $0.id == entryId && $0.state == "active" }) else { return }
        await beginManualWatering(.undo(entryId), completion: completion)
    }

    private func beginManualWatering(_ action: ManualWateringAction, completion: CatalogueSaveCompletion?) async {
        guard manualWateringState == .ready, let card = cardSummary,
              let command = try? action.envelope(plantId: card.id) else { return }
        await sendManualWatering(command, completion: completion)
    }

    func retryManualWatering(completion: CatalogueSaveCompletion? = nil) async {
        guard manualWateringState == .pending, let command = frozenWateringCommand else { return }
        await sendManualWatering(command, completion: completion)
    }

    private func sendManualWatering(_ command: CommandEnvelopeDTO, completion: CatalogueSaveCompletion?) async {
        guard !isAnonymous, case let .saved(confirmation) = state,
              let card = cardSummary, command.plantId == card.id,
              manualWateringPhase != .saving else { return }
        var accepted = false
        defer { finishCompletion(completion, accepted: accepted) }
        do {
            try publish {
                frozenWateringCommand = command
                manualWateringPhase = .saving
            }
            let outcome = try await repository.submitManualWateringAcceptance(
                command, confirmation: confirmation, context: context
            )
            accepted = outcome == .confirmed
            if !accepted {
                try publish { manualWateringPhase = .pending }
                return
            }
            let reloadRecommendation = recommendationPhase != .idle
            try publish {
                frozenWateringCommand = nil
                if reloadRecommendation {
                    recommendationRead += 1
                    recommendationPhase = .idle
                }
            }
            if completion != nil { await settleCard(includeManualWateringActions: true) }
            else { await loadCard(includeManualWateringActions: true) }
            if case .loaded = wateringHistoryState {
                try publish { manualWateringPhase = .ready }
                if reloadRecommendation { await loadCareRecommendation() }
            } else {
                try publish { manualWateringPhase = .unavailable }
            }
        } catch {
            try? publish { manualWateringPhase = frozenWateringCommand == nil ? .unavailable : .pending }
        }
    }

    // Access is checked as well as publication: an idle old model also redacts after ABA.
    var state: CatalogueSaveState {
        let value = phase
        if cancelled { return .unavailable(.cancelled) }
        guard (try? apiClient.syncAuthority.withBoundValid(context, {})) != nil else {
            return .unavailable(.sessionChanged)
        }
        return value
    }

    var isCancelled: Bool { cancelled }
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
            let input = try CatalogueInput.fromCheckpoint(checkpoint.envelope)
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
                    input: input,
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

    /// Exact connection scope plus the ORIGINAL bound lease, not merely an equal owner.
    /// Validation never runs caller code under the authority lock.
    func validateScope(
        of store: LocalStore, apiClient: PlantsAPIClient, session: NativeAuthSession,
        isAnonymous: Bool
    ) throws {
        guard self.store === store, self.apiClient === apiClient,
              context.session == session, self.isAnonymous == isAnonymous else {
            throw CatalogueSaveUnavailable.sessionChanged
        }
        try validateAuthority()
    }

    /// A native continuation must originate from this connection's current guest lease.
    func isGuest(of store: LocalStore, apiClient: PlantsAPIClient, session: NativeAuthSession) -> Bool {
        (try? validateScope(of: store, apiClient: apiClient, session: session, isAnonymous: true)) != nil
    }

    /// Always replay the durable checkpoint under the ORIGINAL lease, including when cached.
    /// No Observation callbacks run under LocalStore's authority lock.
    @discardableResult
    func checkpointInput() async throws -> CatalogueInputCheckpointSnapshot {
        try validateAuthority()
        let checkpoint = try await store.checkpointCatalogueInput(
            frozenInput, flowId: flowId, operationId: frozenEnvelope.operationId,
            context: context, authority: apiClient.syncAuthority
        )
        guard checkpoint.envelope.operationId == frozenEnvelope.operationId,
              checkpoint.envelope.payloadJSON.utf8.elementsEqual(frozenEnvelope.payloadJSON.utf8) else {
            throw CatalogueSaveUnavailable.storageOrServiceUnavailable
        }
        try publish { frozenCheckpoint = checkpoint }
        return checkpoint
    }

    /// Duplicate taps join no new operation and cannot turn busy into success.
    func save(completion: CatalogueSaveCompletion? = nil, includeManualWateringActions: Bool = false) async {
        guard work == nil, !cancelled else { return }
        if Task.isCancelled { cancel(); return }
        if case .saved = state { return }
        let task = Task {
            let accepted = await self.performSave()
            if accepted, completion != nil {
                await self.settleCard(includeManualWateringActions: includeManualWateringActions)
            }
            self.finishCompletion(completion, accepted: accepted)
        }
        work = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        work = nil
    }

    private func settleCard(includeManualWateringActions: Bool) async {
        if let detailsTask { await detailsTask.value }
        else { await loadCard(includeManualWateringActions: includeManualWateringActions) }
    }

    /// Join the actual details task through all optional reads, including same-scope failure.
    /// A busy raw loadCard return or a published .loaded value is not completion.
    func readCard(includeManualWateringActions: Bool = false, completion: CatalogueCardReadCompletion) async {
        guard !Task.isCancelled, !cancelled, case .saved = state else { return }
        await settleCard(includeManualWateringActions: includeManualWateringActions)
        guard !Task.isCancelled, !cancelled, completion.isCurrent(),
              (try? apiClient.syncAuthority.withPermanentBoundValid(context, {})) != nil else { return }
        completion.publish()
    }

    /// Explicit initial read or retry. Details failure never rewrites durable save truth.
    func loadCard(includeManualWateringActions: Bool = false) async {
        guard detailsTask == nil, case let .saved(confirmation) = state else { return }
        if Task.isCancelled { cancel(); return }
        let task = Task {
            await self.performCardLoad(confirmation, includeManualWateringActions: includeManualWateringActions)
        }
        detailsTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if Task.isCancelled { cancel() }
        detailsTask = nil
    }

    private func performCardLoad(
        _ confirmation: CatalogueCreateConfirmationSnapshot, includeManualWateringActions: Bool
    ) async {
        do {
            try publish {
                confirmedConditions = nil
                detailsPhase = .loading
                historyPhase = .loading
                if manualWateringPhase != .saving { manualWateringPhase = .unavailable }
            }
            let summary = try await repository.catalogueCard(
                confirmation: confirmation, envelope: frozenEnvelope, context: context
            )
            try validateAuthority()
            guard case let .saved(current) = state, current == confirmation else {
                throw CatalogueSaveUnavailable.sessionChanged
            }
            try publish { detailsPhase = .loaded(summary) }
            if frozenInput.diagnosisJobId != nil {
                // Optional local read: absent/old snapshots or storage errors cannot fail the card.
                let conditions = try? await repository.syncedPlantConditions(for: summary, context: context)
                try validateAuthority()
                guard case let .saved(current) = state, current == confirmation,
                      cardSummary == summary else { throw CatalogueSaveUnavailable.sessionChanged }
                try publish { confirmedConditions = conditions }
            }
            let history = try await repository.manualWateringHistory(
                card: summary, confirmation: confirmation, context: context
            )
            try validateAuthority()
            guard case let .saved(current) = state, current == confirmation else {
                throw CatalogueSaveUnavailable.sessionChanged
            }
            try publish { historyPhase = .loaded(history) }
            if includeManualWateringActions, !isAnonymous, manualWateringPhase != .saving {
                let queued = try await repository.pendingManualWatering(plantId: summary.id, context: context)
                try publish {
                    if let queued { frozenWateringCommand = queued }
                    manualWateringPhase = frozenWateringCommand == nil ? .ready : .pending
                }
            }
        } catch {
            if Task.isCancelled {
                cancel()
            } else {
                // Includes service cancellation, absent/deleted/malformed data and disk failure.
                // The guarded getters redact invalid authority; .saved remains durable truth.
                if case .loaded = detailsPhase {} else { detailsPhase = .unavailable }
                historyPhase = .unavailable
            }
        }
    }

    /// Invalidate this facade permanently, preserving its durable input and any queue entry.
    func cancel() {
        cancelled = true
        work?.cancel()
        detailsTask?.cancel()
        confirmedConditions = nil
        detailsPhase = .unavailable
        historyPhase = .unavailable
        manualWateringPhase = .unavailable
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

    /// The original model lease is rechecked after every optional read settles.
    private func finishCompletion(_ completion: CatalogueSaveCompletion?, accepted: Bool) {
        guard accepted, let completion, !Task.isCancelled, !cancelled,
              completion.isCurrent(),
              (try? apiClient.syncAuthority.withPermanentBoundValid(context, {})) != nil else { return }
        completion.publish()
    }

    private func performSave() async -> Bool {
        do {
            try publish { phase = .busy }
            if frozenCheckpoint == nil {
                try await checkpointInput()
            }
            // The SDK's explicit anonymous snapshot guards the registered path.
            if isAnonymous {
                try publish { phase = .signInRequired }
                return false
            }
            try validateAuthority()
            let result = try await repository.saveCatalogueCreate(
                envelope: frozenEnvelope, context: context
            )
            let accepted: Bool
            if case .saved = result { accepted = true } else { accepted = false }
            try publish {
                switch result {
                case .signInRequired: phase = .signInRequired
                case let .saved(confirmation): phase = .saved(confirmation)
                case let .pending(entry): phase = .pending(entry)
                case let .collectionLimitNotEnqueued(capacity):
                    phase = .collectionLimitNotEnqueued(capacity)
                }
            }
            return accepted
        } catch {
            if Task.isCancelled || error is CancellationError ||
                (error as? URLError)?.code == .cancelled {
                cancel()
            } else {
                // No raw SQL/network/token/user data becomes a UI diagnostic.
                phase = .unavailable(isAccessible ? .storageOrServiceUnavailable : .sessionChanged)
            }
        }
        return false
    }
}
