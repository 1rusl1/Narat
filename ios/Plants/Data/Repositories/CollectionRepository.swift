import Foundation

/// Minimal catalogue selection. The caller owns the stable operation ID and flow.
public struct CatalogueInput: Sendable, Equatable {
    struct Identification: Sendable, Equatable {
        let jobId: UUID
        let taxonId: UUID
    }

    public let speciesSlug: String?
    public let personalName: String?
    let identification: Identification?

    var speciesIdentifier: String {
        identification?.taxonId.uuidString.lowercased() ?? speciesSlug ?? ""
    }

    public init(speciesSlug: String, personalName: String? = nil) {
        self.speciesSlug = speciesSlug
        self.personalName = personalName
        identification = nil
    }

    init(identification: Identification, personalName: String? = nil) {
        speciesSlug = nil
        self.personalName = personalName
        self.identification = identification
    }

    public func makeEnvelope(operationId: UUID) throws -> CommandEnvelopeDTO {
        var payload = ["creation_source": "catalogue"]
        if let identification {
            payload["add_method"] = "scan"
            payload["creation_intent"] = "care"
            payload["identification_job_id"] = identification.jobId.uuidString.lowercased()
            payload["taxon_id"] = identification.taxonId.uuidString.lowercased()
        } else if let speciesSlug {
            payload["plant_id"] = speciesSlug
        }
        if let personalName { payload["personal_name"] = personalName }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let envelope = CommandEnvelopeDTO(
            operationId: operationId, commandName: "plant.create",
            payloadJSON: String(decoding: data, as: UTF8.self)
        )
        try CatalogueCreateWire.validate(envelope)
        return envelope
    }

    static func fromCheckpoint(_ envelope: CommandEnvelopeDTO) throws -> Self {
        guard let payload = try? JSONDecoder().decode([String: String].self, from: Data(envelope.payloadJSON.utf8)) else {
            throw CatalogueInputCheckpointError.invalidStoredInput
        }
        let input: Self
        if let jobId = payload["identification_job_id"].flatMap(UUID.init(uuidString:)),
           let taxonId = payload["taxon_id"].flatMap(UUID.init(uuidString:)) {
            input = Self(identification: Identification(jobId: jobId, taxonId: taxonId), personalName: payload["personal_name"])
        } else if let slug = payload["plant_id"] {
            input = Self(speciesSlug: slug, personalName: payload["personal_name"])
        } else {
            throw CatalogueInputCheckpointError.invalidStoredInput
        }
        let rebuilt = try input.makeEnvelope(operationId: envelope.operationId)
        guard rebuilt.commandName == envelope.commandName, rebuilt.plantId == envelope.plantId,
              rebuilt.payloadJSON.utf8.elementsEqual(envelope.payloadJSON.utf8) else {
            throw CatalogueInputCheckpointError.invalidStoredInput
        }
        return input
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

/// The minimal canonical SQL plants projection, never reconstructed from create input.
struct CatalogueCardSummary: Decodable, Sendable, Equatable, Identifiable {
    let id: UUID
    let speciesSlug: String?
    let taxonId: UUID?
    let mainPhotoId: UUID?
    let personalName: String?
    let revision: Int
    let careRevision: Int

    enum CodingKeys: String, CodingKey {
        case id, revision
        case speciesSlug = "plant_id"
        case taxonId = "taxon_id"
        case mainPhotoId = "main_photo_id"
        case personalName = "personal_name"
        case careRevision = "care_revision"
    }
}

struct CatalogueCollectionSnapshot: Sendable {
    let cards: [CatalogueCardSummary]
    let isCached: Bool
}

/// Canonical standalone watering fact. Dates remain server calendar dates.
struct CatalogueWateringEntry: Decodable, Sendable, Equatable, Identifiable {
    let id: UUID
    let plantId: UUID
    let taskId: UUID?
    let actionCode: String
    let occurredAt: String
    let occurredLocalDate: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case id, state
        case plantId = "plant_id"
        case taskId = "task_id"
        case actionCode = "action_code"
        case occurredAt = "occurred_at"
        case occurredLocalDate = "occurred_local_date"
    }
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
        return try await saveCatalogueCreate(envelope: envelope, context: context)
    }

    /// Internal composition must retain the model's original bound authority, including ABA.
    /// The caller must explicitly guard its SDK anonymous snapshot before this registered path.
    func saveCatalogueCreate(
        envelope: CommandEnvelopeDTO, context: SyncSessionLease
    ) async throws -> CatalogueSaveResult {
        try apiClient.syncAuthority.withBoundValid(context) {}
        try CatalogueCreateWire.validate(envelope)

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

    /// Details are independent of create success. Only the original durable journal
    /// identity permits a canonical refresh, with no outbox drain or lease recapture.
    func catalogueCard(
        confirmation: CatalogueCreateConfirmationSnapshot,
        envelope: CommandEnvelopeDTO, context: SyncSessionLease
    ) async throws -> CatalogueCardSummary {
        try apiClient.syncAuthority.withBoundValid(context) {}
        guard confirmation.ownerId == context.ownerId,
              confirmation.operationId == envelope.operationId,
              confirmation.payloadJSON.utf8.elementsEqual(envelope.payloadJSON.utf8) else {
            throw SyncWireValidationError.invalidSession
        }
        let journal = try await store.catalogueCreateJournal(
            envelope, mode: .checkOnly, context: context, authority: apiClient.syncAuthority
        )
        try apiClient.syncAuthority.withBoundValid(context) {}
        guard case let .confirmed(durable) = journal, durable == confirmation else {
            throw CatalogueCreateAcknowledgementError.missingQueuedOperation
        }

        try apiClient.syncAuthority.withBoundValid(context) {}
        _ = try await syncEngine.performFullRefresh(context: context)
        try apiClient.syncAuthority.withBoundValid(context) {}
        let plants = try await store.activeSyncedEntities(ownerId: context.ownerId, entityType: "plants")
        return try apiClient.syncAuthority.withBoundValid(context) {
            guard let entity = plants.first(where: { $0.id == confirmation.receipt.plantId }) else {
                throw SyncWireValidationError.invalidPage
            }
            let summary = try Self.decodeCard(entity)
            guard summary.speciesSlug?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw SyncWireValidationError.invalidPage
            }
            if let taxon = CatalogueCreateWire.identificationTaxon(envelope) {
                guard let photo = confirmation.receipt.photoId, photo == summary.mainPhotoId,
                      taxon == summary.taxonId else { throw SyncWireValidationError.invalidPage }
            }
            return summary
        }
    }

    func collectionCards(context: SyncSessionLease) async throws -> CatalogueCollectionSnapshot {
        try apiClient.syncAuthority.withBoundValid(context) {}
        let isCached: Bool
        do {
            _ = try await syncEngine.performFullRefresh(context: context)
            isCached = false
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code) {
            try Task.checkCancellation()
            try apiClient.syncAuthority.withBoundValid(context) {}
            guard try await store.syncedProfile(ownerId: context.ownerId) != nil else { throw error }
            isCached = true
        }
        let entities = try await store.activeSyncedEntities(ownerId: context.ownerId, entityType: "plants")
        return try apiClient.syncAuthority.withBoundValid(context) {
            try Task.checkCancellation()
            let cards = try entities.reversed().map(Self.decodeCard)
            return CatalogueCollectionSnapshot(cards: cards, isCached: isCached)
        }
    }

    private static func decodeCard(_ entity: SyncItemDTO) throws -> CatalogueCardSummary {
        let card = try JSONDecoder().decode(CatalogueCardSummary.self, from: Data(entity.payloadJSON.utf8))
        guard card.id == entity.id, card.revision > 0, card.careRevision > 0 else {
            throw SyncWireValidationError.invalidPage
        }
        return card
    }

    func pendingManualWatering(plantId: UUID, context: SyncSessionLease) async throws -> CommandEnvelopeDTO? {
        try apiClient.syncAuthority.withBoundValid(context) {}
        let pending = try await store.pendingOutboxEntries(for: context.ownerId)
        return try apiClient.syncAuthority.withBoundValid(context) {
            guard let entry = pending.first(where: {
                $0.plantId == plantId && ($0.commandName == "care.record" || $0.commandName == "care.undo")
            }) else { return nil }
            let command = CommandEnvelopeDTO(operationId: entry.operationId, commandName: entry.commandName,
                                             plantId: entry.plantId, payloadJSON: entry.payloadJSON)
            guard ManualWateringAction(envelope: command) != nil else {
                throw OutboxEnqueueError.operationIdentityMismatch
            }
            return command
        }
    }

    /// The typed receipt must be validated by the existing outbox drain before the queue item disappears.
    func submitManualWatering(
        _ command: CommandEnvelopeDTO, confirmation: CatalogueCreateConfirmationSnapshot,
        context: SyncSessionLease
    ) async throws -> Bool {
        try apiClient.syncAuthority.withBoundValid(context) {}
        guard confirmation.ownerId == context.ownerId,
              command.plantId == confirmation.receipt.plantId,
              ManualWateringAction(envelope: command) != nil,
              try await store.catalogueCreateConfirmation(
                  ownerId: context.ownerId, operationId: confirmation.operationId
              ) == confirmation else {
            throw SyncWireValidationError.invalidSession
        }
        try await store.enqueueManualWatering(command, context: context, authority: apiClient.syncAuthority)
        _ = try await syncEngine.flushOutbox(context: context)
        let pending = try await store.pendingOutboxEntries(for: context.ownerId)
        return try apiClient.syncAuthority.withBoundValid(context) {
            !pending.contains { $0.operationId == command.operationId }
        }
    }

    /// Read only after catalogueCard has refreshed the exact confirmed card.
    /// The full owner refresh already includes care_entries; no second HTTP request.
    func manualWateringHistory(
        card: CatalogueCardSummary, confirmation: CatalogueCreateConfirmationSnapshot,
        context: SyncSessionLease
    ) async throws -> [CatalogueWateringEntry] {
        try Task.checkCancellation()
        try apiClient.syncAuthority.withBoundValid(context) {}
        guard confirmation.ownerId == context.ownerId,
              card.id == confirmation.receipt.plantId else {
            throw SyncWireValidationError.invalidSession
        }
        return try await wateringHistory(plantId: card.id, context: context)
    }

    func collectionWateringHistory(
        plantId: UUID, context: SyncSessionLease
    ) async throws -> [CatalogueWateringEntry] {
        try apiClient.syncAuthority.withBoundValid(context) {}
        let plants = try await store.activeSyncedEntities(ownerId: context.ownerId, entityType: "plants")
        guard plants.contains(where: { $0.id == plantId }) else { throw SyncWireValidationError.invalidPage }
        return try await wateringHistory(plantId: plantId, context: context)
    }

    private func wateringHistory(plantId: UUID, context: SyncSessionLease) async throws -> [CatalogueWateringEntry] {
        try apiClient.syncAuthority.withBoundValid(context) {}
        let entities = try await store.activeSyncedEntities(
            ownerId: context.ownerId, entityType: "care_entries"
        )
        return try apiClient.syncAuthority.withBoundValid(context) {
            try Task.checkCancellation()
            let dateFormat = DateFormatter()
            dateFormat.locale = Locale(identifier: "en_US_POSIX")
            dateFormat.calendar = Calendar(identifier: .gregorian)
            dateFormat.timeZone = TimeZone(secondsFromGMT: 0)
            dateFormat.dateFormat = "yyyy-MM-dd"
            dateFormat.isLenient = false
            var entries: [CatalogueWateringEntry] = []
            for entity in entities {
                let entry = try JSONDecoder().decode(
                    CatalogueWateringEntry.self, from: Data(entity.payloadJSON.utf8)
                )
                guard entry.plantId == plantId, entry.taskId == nil,
                      entry.actionCode == "water" else { continue }
                guard entry.id == entity.id,
                      ["active", "voided"].contains(entry.state),
                      SQLTimestamp.microseconds(from: entry.occurredAt) != nil,
                      let day = dateFormat.date(from: entry.occurredLocalDate),
                      dateFormat.string(from: day) == entry.occurredLocalDate else {
                    throw SyncWireValidationError.invalidPage
                }
                entries.append(entry)
            }
            return entries.sorted {
                let lhs = SQLTimestamp.microseconds(from: $0.occurredAt)!
                let rhs = SQLTimestamp.microseconds(from: $1.occurredAt)!
                return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
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
