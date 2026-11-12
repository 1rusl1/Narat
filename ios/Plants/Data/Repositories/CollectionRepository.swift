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

/// Canonical care fact. Dates remain server calendar dates.
struct CatalogueCareJournalEntry: Decodable, Sendable, Equatable, Identifiable {
    let id: UUID
    let operationId: UUID?
    let plantId: UUID
    let taskId: UUID?
    let actionCode: String
    let occurredAt: String
    let occurredLocalDate: String
    let timezone: String?
    let state: String

    enum CodingKeys: String, CodingKey {
        case id, state, timezone
        case operationId = "operation_id"
        case plantId = "plant_id"
        case taskId = "task_id"
        case actionCode = "action_code"
        case occurredAt = "occurred_at"
        case occurredLocalDate = "occurred_local_date"
    }

    var hasCanonicalDatesAndState: Bool {
        (state == "active" || state == "voided") && SQLTimestamp.microseconds(from: occurredAt) != nil
            && SQLCalendarDay.date(from: occurredLocalDate) != nil
    }
}

enum FirstAidWriteOutcome {
    case pending, confirmed, rejected
}

struct CatalogueFirstAidControl: Decodable, Sendable, Identifiable {
    struct Policy: Decodable, Sendable {
        let dueOn: String
        let intervalDays: Int
        let source: PlantCareRecommendation.Source

        enum CodingKeys: String, CodingKey {
            case dueOn = "due_on"
            case intervalDays = "interval_days"
            case source
        }
    }

    let id: UUID
    let plantId: UUID
    let actionEntryId: UUID
    let actionCode: String
    let state: String
    let policy: Policy
    let contextRevision: Int?
    let controlTaskId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, state
        case plantId = "plant_id"
        case actionEntryId = "action_entry_id"
        case actionCode = "action_code"
        case policy = "check_policy_snapshot"
        case contextRevision = "context_revision"
        case controlTaskId = "control_task_id"
    }

    var hasSupportedPolicy: Bool {
        (1...90).contains(policy.intervalDays) && SQLCalendarDay.date(from: policy.dueOn) != nil
            && policy.source.isVerifiedLink
    }

    func canObserve(careRevision: Int) -> Bool {
        state == "active" && actionCode == "check_soil" && controlTaskId == nil
            && contextRevision == careRevision && hasSupportedPolicy
    }
}

struct CatalogueFirstAidControlLink: Decodable, Sendable {
    let id: UUID
    let plantId: UUID
    let actionEntryId: UUID
    let actionCode: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case id, state
        case plantId = "plant_id"
        case actionEntryId = "action_entry_id"
        case actionCode = "action_code"
    }
}

struct CatalogueFirstAidObservation: Decodable, Sendable, Identifiable {
    let id: UUID
    let plantId: UUID
    let controlId: UUID
    let taskId: UUID?
    let operationId: UUID
    let status: FirstAidObservationStatus
    let observedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case plantId = "plant_id"
        case controlId = "first_aid_control_id"
        case taskId = "task_id"
        case operationId = "operation_id"
        case status = "status_code"
        case observedAt = "observed_at"
    }

    var isStandalone: Bool { taskId == nil && SQLTimestamp.microseconds(from: observedAt) != nil }
}

struct CatalogueFirstAidSnapshot: Sendable {
    var controls: [CatalogueFirstAidControl]
    let observations: [CatalogueFirstAidObservation]
    let accessUntil: Date?
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
        try await store.pendingManualCare(
            plantId: plantId, firstAidUndo: false, context: context, authority: apiClient.syncAuthority
        )
    }

    func enqueueWateringDateCorrection(
        plantId: UUID, entryId: UUID, date: Date, timezone: TimeZone, context: SyncSessionLease
    ) async throws {
        guard date <= Date() else { throw SyncWireValidationError.invalidRequest }
        let action = ManualWateringAction.correction(entryId: entryId, date: date, timezone: timezone)
        let command = try action.envelope(plantId: plantId)
        try await store.enqueueManualWatering(command, context: context, authority: apiClient.syncAuthority)
    }

    func retryWateringDateCorrection(plantId: UUID, context: SyncSessionLease) async throws {
        guard let pending = try await pendingManualWatering(plantId: plantId, context: context),
              pending.commandName == ManualWateringAction.correctionCommand else { return }
        _ = try await syncEngine.flushOutbox(context: context)
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
    ) async throws -> [CatalogueCareJournalEntry] {
        try Task.checkCancellation()
        try apiClient.syncAuthority.withBoundValid(context) {}
        guard confirmation.ownerId == context.ownerId,
              card.id == confirmation.receipt.plantId else {
            throw SyncWireValidationError.invalidSession
        }
        return try await manualCareHistory(plantId: card.id, actionCode: "water", context: context)
    }

    func collectionWateringHistory(
        plantId: UUID, context: SyncSessionLease
    ) async throws -> [CatalogueCareJournalEntry] {
        try await collectionCareHistory(plantId: plantId, actionCode: "water", context: context)
    }

    func collectionFirstAidHistory(plantId: UUID, context: SyncSessionLease) async throws -> [CatalogueCareJournalEntry] {
        try await collectionCareHistory(plantId: plantId, actionCode: "check_soil", context: context)
    }

    private func collectionCareHistory(
        plantId: UUID, actionCode: String, context: SyncSessionLease
    ) async throws -> [CatalogueCareJournalEntry] {
        try apiClient.syncAuthority.withBoundValid(context) {}
        let plants = try await store.activeSyncedEntities(ownerId: context.ownerId, entityType: "plants")
        guard plants.contains(where: { $0.id == plantId }) else { throw SyncWireValidationError.invalidPage }
        return try await manualCareHistory(plantId: plantId, actionCode: actionCode, context: context)
    }

    func pendingFirstAidRecord(plantId: UUID, context: SyncSessionLease) async throws -> FirstAidRecordCommand? {
        try await store.pendingFirstAidRecord(plantId: plantId, context: context, authority: apiClient.syncAuthority)
    }

    func enqueueFirstAidRecord(
        _ action: RecordableFirstAidAction, target: RepeatDiagnosisTarget, context: SyncSessionLease
    ) async throws -> FirstAidRecordCommand {
        guard target.ownerId == context.ownerId, target.plantId == action.plantId, action.isSoilCheck else {
            throw SyncWireValidationError.invalidRequest
        }
        let command = try FirstAidRecordCommand.make(for: action, date: clock(), timezone: .current)
        return try await store.enqueueFirstAidRecord(command, context: context, authority: apiClient.syncAuthority)
    }

    func retryFirstAidRecord(
        _ command: FirstAidRecordCommand, context: SyncSessionLease
    ) async throws -> FirstAidWriteOutcome {
        _ = try await syncEngine.flushOutbox(context: context)
        if try await pendingFirstAidRecord(plantId: command.plantId, context: context)?.envelope == command.envelope {
            return .pending
        }
        let entry = try await store.confirmedFirstAidEntry(command, context: context, authority: apiClient.syncAuthority)
        return entry == nil ? .rejected : .confirmed
    }

    func pendingFirstAidUndo(plantId: UUID, context: SyncSessionLease) async throws -> CommandEnvelopeDTO? {
        try await store.pendingManualCare(
            plantId: plantId, firstAidUndo: true, context: context, authority: apiClient.syncAuthority
        )
    }

    func enqueueFirstAidUndo(plantId: UUID, entryId: UUID, context: SyncSessionLease) async throws -> CommandEnvelopeDTO {
        let command = try ManualWateringAction.undo(entryId).envelope(plantId: plantId)
        return try await store.enqueueFirstAidUndo(command, context: context, authority: apiClient.syncAuthority)
    }

    func retryFirstAidUndo(_ command: CommandEnvelopeDTO, context: SyncSessionLease) async throws -> FirstAidWriteOutcome {
        guard let plantId = command.plantId, case .undo = ManualWateringAction(envelope: command) else {
            throw SyncWireValidationError.invalidRequest
        }
        _ = try await syncEngine.flushOutbox(context: context)
        if try await pendingFirstAidUndo(plantId: plantId, context: context) == command {
            return .pending
        }
        let reversal = try await store.confirmedFirstAidUndo(command, context: context, authority: apiClient.syncAuthority)
        return reversal == nil ? .rejected : .confirmed
    }

    func pendingFirstAidObservation(plantId: UUID, context: SyncSessionLease) async throws -> FirstAidObservationCommand? {
        try await store.pendingFirstAidObservation(plantId: plantId, context: context, authority: apiClient.syncAuthority)
    }

    func enqueueFirstAidObservation(
        plantId: UUID, controlId: UUID, status: FirstAidObservationStatus, context: SyncSessionLease
    ) async throws -> FirstAidObservationCommand {
        let command = try FirstAidObservationCommand.make(plantId: plantId, controlId: controlId, status: status)
        return try await store.enqueueFirstAidObservation(
            command, now: clock(), context: context, authority: apiClient.syncAuthority
        )
    }

    func retryFirstAidObservation(
        _ command: FirstAidObservationCommand, context: SyncSessionLease
    ) async throws -> FirstAidWriteOutcome {
        _ = try await syncEngine.flushOutbox(context: context)
        if try await pendingFirstAidObservation(plantId: command.plantId, context: context)?.envelope == command.envelope {
            return .pending
        }
        let observation = try await store.confirmedFirstAidObservation(
            command, context: context, authority: apiClient.syncAuthority
        )
        return observation == nil ? .rejected : .confirmed
    }

    func collectionFirstAidControls(plantId: UUID, context: SyncSessionLease) async throws -> CatalogueFirstAidSnapshot? {
        guard let snapshot = try await store.firstAidControlSnapshot(
            plantId: plantId, context: context, authority: apiClient.syncAuthority
        ) else { return nil }
        return try apiClient.syncAuthority.withBoundValid(context) {
            let accessUntil = snapshot.entitlement?.verifiedAccessUntil
            let hasAccess = snapshot.entitlement == nil || accessUntil.map { $0 > clock() } == true
            let decoder = JSONDecoder()
            let controls = hasAccess ? snapshot.controls.compactMap { row -> CatalogueFirstAidControl? in
                guard let control = try? decoder.decode(CatalogueFirstAidControl.self, from: Data(row.payloadJSON.utf8)),
                      control.id == row.id, control.plantId == plantId, control.state == "active",
                      control.actionCode == "check_soil", control.hasSupportedPolicy else { return nil }
                return control
            }.sorted { ($0.policy.dueOn, $0.id.uuidString) < ($1.policy.dueOn, $1.id.uuidString) } : []
            let completed = Set(snapshot.controls.compactMap { row -> UUID? in
                guard let control = try? decoder.decode(CatalogueFirstAidControlLink.self, from: Data(row.payloadJSON.utf8)),
                      control.id == row.id, control.plantId == plantId, control.state == "completed",
                      control.actionCode == "check_soil" else { return nil }
                return control.id
            })
            let observations = snapshot.observations.compactMap { row -> CatalogueFirstAidObservation? in
                guard let observation = try? decoder.decode(CatalogueFirstAidObservation.self, from: Data(row.payloadJSON.utf8)),
                      observation.id == row.id, observation.plantId == plantId, observation.isStandalone,
                      completed.contains(observation.controlId) else { return nil }
                return observation
            }.sorted {
                let lhs = SQLTimestamp.microseconds(from: $0.observedAt)!
                let rhs = SQLTimestamp.microseconds(from: $1.observedAt)!
                return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
            }
            guard !controls.isEmpty || !observations.isEmpty else { return nil }
            return CatalogueFirstAidSnapshot(controls: controls, observations: observations, accessUntil: accessUntil)
        }
    }

    private func manualCareHistory(
        plantId: UUID, actionCode: String, context: SyncSessionLease
    ) async throws -> [CatalogueCareJournalEntry] {
        try apiClient.syncAuthority.withBoundValid(context) {}
        let entities = try await store.activeSyncedEntities(
            ownerId: context.ownerId, entityType: "care_entries"
        )
        return try apiClient.syncAuthority.withBoundValid(context) {
            try Task.checkCancellation()
            var entries: [CatalogueCareJournalEntry] = []
            for entity in entities {
                let entry = try JSONDecoder().decode(
                    CatalogueCareJournalEntry.self, from: Data(entity.payloadJSON.utf8)
                )
                guard entry.plantId == plantId, entry.taskId == nil,
                      entry.actionCode == actionCode else { continue }
                guard entry.id == entity.id, entry.hasCanonicalDatesAndState else {
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
            let paid = snapshot.entitlement?.verifiedAccessUntil.map { $0 > clock() } ?? false
            return CollectionCapacity(
                ownerId: context.ownerId, plantCount: snapshot.plantCount, hasVerifiedPaidAccess: paid
            )
        }
    }
}
