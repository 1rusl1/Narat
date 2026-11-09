import Foundation

/// Minimal catalogue selection. The caller owns the stable operation ID and flow.
public struct CatalogueInput: Sendable, Equatable {
    public let speciesSlug: String
    public let personalName: String?

    public init(speciesSlug: String, personalName: String? = nil) {
        self.speciesSlug = speciesSlug
        self.personalName = personalName
    }

    public func makeEnvelope(operationId: UUID) throws -> CommandEnvelopeDTO {
        var payload = ["creation_source": "catalogue", "plant_id": speciesSlug]
        if let personalName { payload["personal_name"] = personalName }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let envelope = CommandEnvelopeDTO(
            operationId: operationId, commandName: "plant.create",
            payloadJSON: String(decoding: data, as: UTF8.self)
        )
        try CatalogueCreateWire.validate(envelope)
        return envelope
    }
}

public struct CollectionCapacity: Sendable, Equatable {
    public let ownerId: UUID
    public let plantCount: Int
    public let hasVerifiedPaidAccess: Bool

    public var collectionLimit: Int? { hasVerifiedPaidAccess ? nil : 3 }
    public var canCreate: Bool { hasVerifiedPaidAccess || plantCount < 3 }
}

public enum CollectionCapacityResult: Sendable, Equatable {
    case signInRequired
    case confirmed(CollectionCapacity)
}

/// Only a durable, exact typed confirmation is a saved catalogue create.
public enum CatalogueSaveResult: Sendable, Equatable {
    case signInRequired
    case saved(CatalogueCreateConfirmationSnapshot)
    case pending(OutboxEntrySnapshot)
    case collectionLimitNotEnqueued(CollectionCapacity)
}

struct CollectionCapacitySnapshot: Sendable {
    let plantCount: Int
    let entitlement: SyncWireEntitlementDTO?
}

/// Advisory only: the server's create guard remains authoritative.
public struct CollectionRepository: Sendable {
    private let store: LocalStore
    private let apiClient: PlantsAPIClient
    private let syncEngine: SyncEngine
    private let clock: @Sendable () -> Date

    public init(
        store: LocalStore, apiClient: PlantsAPIClient, syncEngine: SyncEngine,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.apiClient = apiClient
        self.syncEngine = syncEngine
        self.clock = clock
    }

    /// Errors mean unavailable; neither old cache nor pending commands imply capacity.
    public func preflightCapacity(
        session: NativeAuthSession, isAnonymous: Bool
    ) async throws -> CollectionCapacityResult {
        try Task.checkCancellation()
        guard !isAnonymous else { return .signInRequired }
        // Do not pass an explicit-session fallback: only an actually bound client qualifies.
        let context = try await apiClient.captureSyncContext(ownerId: session.userId)
        guard context.session == session else { throw SyncWireValidationError.invalidSession }
        return .confirmed(try await preflightCapacity(context: context))
    }

    /// The caller retains the original operation and frozen payload for every retry.
    /// Pending commands resume without requiring capacity for a second new create.
    public func saveCatalogueCreate(
        _ envelope: CommandEnvelopeDTO, session: NativeAuthSession, isAnonymous: Bool
    ) async throws -> CatalogueSaveResult {
        try Task.checkCancellation()
        try CatalogueCreateWire.validate(envelope)
        guard !isAnonymous else { return .signInRequired }
        let context = try await apiClient.captureSyncContext(ownerId: session.userId)
        guard context.session == session else { throw SyncWireValidationError.invalidSession }

        var journal = try await store.catalogueCreateJournal(
            envelope, mode: .checkOnly, context: context, authority: apiClient.syncAuthority
        )
        if journal == .absent {
            let capacity = try await preflightCapacity(context: context)
            // Recheck exact pending/confirmed identity atomically, even when capacity is false.
            journal = try await store.catalogueCreateJournal(
                envelope, mode: .enqueue(canCreate: capacity.canCreate),
                context: context, authority: apiClient.syncAuthority
            )
            if journal == .collectionLimitNotEnqueued {
                return try apiClient.syncAuthority.withBoundValid(context) {
                    .collectionLimitNotEnqueued(capacity)
                }
            }
        }

        if case .pending = journal {
            // Commit count can belong to other commands, or be zero during another drain.
            _ = try await syncEngine.flushOutbox(context: context)
            journal = try await store.catalogueCreateJournal(
                envelope, mode: .checkOnly, context: context, authority: apiClient.syncAuthority
            )
        }
        return try apiClient.syncAuthority.withBoundValid(context) {
            switch journal {
            case let .confirmed(confirmation): return .saved(confirmation)
            case let .pending(entry): return .pending(entry)
            case .absent, .collectionLimitNotEnqueued:
                throw CatalogueCreateAcknowledgementError.missingQueuedOperation
            }
        }
    }

    /// Reuse the original bound lease; never recapture after an auth ABA.
    func preflightCapacity(context: SyncSessionLease) async throws -> CollectionCapacity {
        try apiClient.syncAuthority.withBoundValid(context) {}
        _ = try await syncEngine.performFullRefresh(context: context)
        let snapshot = try await store.collectionCapacitySnapshot(
            context: context, authority: apiClient.syncAuthority
        )
        return try apiClient.syncAuthority.withBoundValid(context) {
            let now = clock()
            func future(_ raw: String?) -> Bool {
                guard let raw, let expiry = SQLTimestamp.date(from: raw) else { return false }
                return expiry > now
            }
            let paid = snapshot.entitlement.map {
                ["active", "grace"].contains($0.state) && future($0.validUntil)
                    && ($0.offerKind == "paid" || ($0.offerKind == "trial" && future($0.trialEndAt)))
            } ?? false
            return CollectionCapacity(
                ownerId: context.ownerId, plantCount: snapshot.plantCount, hasVerifiedPaidAccess: paid
            )
        }
    }
}
