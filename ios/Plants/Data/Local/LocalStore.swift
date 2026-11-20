import Foundation
import SwiftData

// MARK: - SwiftData Models (T023)

@Model
public final class LocalOutboxRecord {
    @Attribute(.unique) public var operationId: UUID
    public var ownerId: UUID
    public var plantId: UUID?
    public var commandName: String
    public var payloadJSON: String
    public var sequenceNumber: Int64
    public var retryCount: Int
    public var lastError: String?
    public var createdAt: Date
    @Attribute(.externalStorage) var observationJPEG: Data?
    var observationPhotoAssetId: UUID?
    // Immutable enqueue-time identity; never included in the transport payload.
    var routineUndoIdentityJSON: String?

    public init(
        operationId: UUID = UUID(),
        ownerId: UUID,
        plantId: UUID? = nil,
        commandName: String,
        payloadJSON: String,
        sequenceNumber: Int64,
        retryCount: Int = 0,
        lastError: String? = nil,
        createdAt: Date = Date()
    ) {
        self.operationId = operationId
        self.ownerId = ownerId
        self.plantId = plantId
        self.commandName = commandName
        self.payloadJSON = payloadJSON
        self.sequenceNumber = sequenceNumber
        self.retryCount = retryCount
        self.lastError = lastError
        self.createdAt = createdAt
    }
}

/// Local association only: the receipt remains the server's authoritative DTO.
@Model
public final class CatalogueCreateConfirmationRecord {
    @Attribute(.unique) public var compositeKey: String
    public var ownerId: UUID
    public var operationId: UUID
    public var payloadJSON: String
    public var receiptJSON: String

    public init(ownerId: UUID, operationId: UUID, payloadJSON: String, receiptJSON: String) {
        self.compositeKey = "\(ownerId.uuidString.lowercased()):\(operationId.uuidString.lowercased())"
        self.ownerId = ownerId
        self.operationId = operationId
        self.payloadJSON = payloadJSON
        self.receiptJSON = receiptJSON
    }
}

/// Local input only: no server draft, receipt, credentials, or retention policy.
@Model
public final class CatalogueInputCheckpointRecord {
    @Attribute(.unique) public var compositeKey: String
    public var ownerId: UUID
    public var flowId: UUID
    public var operationId: UUID
    public var payloadJSON: String
    public var createdAt: Date

    public init(ownerId: UUID, flowId: UUID, operationId: UUID, payloadJSON: String, createdAt: Date) {
        self.compositeKey = "\(ownerId.uuidString.lowercased()):\(flowId.uuidString.lowercased())"
        self.ownerId = ownerId
        self.flowId = flowId
        self.operationId = operationId
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

@Model
public final class GuestDraftCacheRecord {
    @Attribute(.unique) public var draftId: UUID
    public var flowId: UUID
    public var intentRaw: String
    public var addMethodRaw: String?
    public var currentStepRaw: String
    public var photoLocalPath: String?
    public var confirmedPlantId: String?
    public var confirmedTaxonId: UUID?
    public var confirmedDisplayName: String?
    public var conditionsJSON: String
    public var resultModeRaw: String?
    public var preliminaryAnalysisJSON: String?
    public var analysisReceiptJSON: String?
    public var overridesJSON: String?
    public var serverExpiresAt: Date
    public var isCompleteForFallback: Bool
    public var updatedAt: Date

    public init(
        draftId: UUID,
        flowId: UUID,
        intentRaw: String,
        addMethodRaw: String?,
        currentStepRaw: String,
        photoLocalPath: String?,
        confirmedPlantId: String?,
        confirmedTaxonId: UUID?,
        confirmedDisplayName: String?,
        conditionsJSON: String,
        resultModeRaw: String?,
        preliminaryAnalysisJSON: String?,
        analysisReceiptJSON: String?,
        overridesJSON: String?,
        serverExpiresAt: Date,
        isCompleteForFallback: Bool,
        updatedAt: Date = Date()
    ) {
        self.draftId = draftId
        self.flowId = flowId
        self.intentRaw = intentRaw
        self.addMethodRaw = addMethodRaw
        self.currentStepRaw = currentStepRaw
        self.photoLocalPath = photoLocalPath
        self.confirmedPlantId = confirmedPlantId
        self.confirmedTaxonId = confirmedTaxonId
        self.confirmedDisplayName = confirmedDisplayName
        self.conditionsJSON = conditionsJSON
        self.resultModeRaw = resultModeRaw
        self.preliminaryAnalysisJSON = preliminaryAnalysisJSON
        self.analysisReceiptJSON = analysisReceiptJSON
        self.overridesJSON = overridesJSON
        self.serverExpiresAt = serverExpiresAt
        self.isCompleteForFallback = isCompleteForFallback
        self.updatedAt = updatedAt
    }
}

@Model
public final class SyncedEntityRecord {
    @Attribute(.unique) public var compositeKey: String
    public var ownerId: UUID
    public var entityType: String
    public var entityId: UUID
    public var updatedAt: Date
    public var deletedAt: Date?
    public var payloadJSON: String
    public var updatedAtRaw: String?

    public init(
        ownerId: UUID,
        entityType: String,
        entityId: UUID,
        updatedAt: Date,
        deletedAt: Date? = nil,
        payloadJSON: String
    ) {
        self.compositeKey = "\(ownerId.uuidString.lowercased()):\(entityType):\(entityId.uuidString.lowercased())"
        self.ownerId = ownerId
        self.entityType = entityType
        self.entityId = entityId
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.payloadJSON = payloadJSON
    }
}

@Model
public final class SyncCheckpointRecord {
    @Attribute(.unique) public var ownerId: UUID
    public var watermark: Date?
    public var watermarkRaw: String?
    public var syncProfileJSON: String?
    public var syncEntitlementJSON: String?
    public var freeSelectionRevision: Int
    public var entitlementValidUntil: Date?
    public var entitlementTrialEndAt: Date?
    public var entitlementOfferKind: String?
    public var entitlementState: String?
    public var updatedAt: Date

    public init(
        ownerId: UUID,
        watermark: Date? = nil,
        freeSelectionRevision: Int = 0,
        entitlementValidUntil: Date? = nil,
        entitlementTrialEndAt: Date? = nil,
        entitlementOfferKind: String? = nil,
        entitlementState: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.ownerId = ownerId
        self.watermark = watermark
        self.freeSelectionRevision = freeSelectionRevision
        self.entitlementValidUntil = entitlementValidUntil
        self.entitlementTrialEndAt = entitlementTrialEndAt
        self.entitlementOfferKind = entitlementOfferKind
        self.entitlementState = entitlementState
        self.updatedAt = updatedAt
    }
}

// MARK: - Sendable Snapshots

public struct OutboxEntrySnapshot: Codable, Sendable, Equatable {
    public let operationId: UUID
    public let ownerId: UUID
    public let plantId: UUID?
    public let commandName: String
    public let payloadJSON: String
    public let sequenceNumber: Int64
    public let retryCount: Int
    public let lastError: String?
    public let createdAt: Date

    var envelope: CommandEnvelopeDTO {
        CommandEnvelopeDTO(operationId: operationId, commandName: commandName, plantId: plantId, payloadJSON: payloadJSON)
    }

    /// Legacy diagnostic text is deliberately not classified as an API error.
    public var lastAPIError: APIErrorResponse? {
        guard let lastError else { return nil }
        return try? JSONDecoder().decode(APIErrorResponse.self, from: Data(lastError.utf8))
    }

    public init(
        operationId: UUID,
        ownerId: UUID,
        plantId: UUID?,
        commandName: String,
        payloadJSON: String,
        sequenceNumber: Int64,
        retryCount: Int = 0,
        lastError: String? = nil,
        createdAt: Date = Date()
    ) {
        self.operationId = operationId
        self.ownerId = ownerId
        self.plantId = plantId
        self.commandName = commandName
        self.payloadJSON = payloadJSON
        self.sequenceNumber = sequenceNumber
        self.retryCount = retryCount
        self.lastError = lastError
        self.createdAt = createdAt
    }
}

public enum OutboxEnqueueError: Error, Sendable, Equatable {
    case operationIdentityMismatch
}

public struct CatalogueCreateConfirmationSnapshot: Sendable, Equatable {
    public let ownerId: UUID
    public let operationId: UUID
    public let payloadJSON: String
    public let receipt: PlantCreateReceiptDTO
}

public struct CatalogueInputCheckpointSnapshot: Sendable, Equatable {
    public let ownerId: UUID
    public let flowId: UUID
    public let envelope: CommandEnvelopeDTO
    public let createdAt: Date

    public var operationId: UUID { envelope.operationId }
}

enum CatalogueInputCheckpointError: Error, Sendable, Equatable {
    case flowIdentityMismatch
    case invalidStoredInput
}

enum CatalogueCreateJournalMode: Sendable {
    case checkOnly
    case enqueue(canCreate: Bool)
}

enum CatalogueCreateJournalState: Sendable, Equatable {
    case absent
    case pending(OutboxEntrySnapshot)
    case confirmed(CatalogueCreateConfirmationSnapshot)
    case collectionLimitNotEnqueued
}

enum CatalogueCreateAcknowledgementError: Error, Sendable, Equatable {
    case invalidCommand
    case missingQueuedOperation
    case queuedCommandMismatch
    case confirmationConflict
}

public struct GuestDraftCacheSnapshot: Codable, Sendable, Equatable {
    public var draftId: UUID
    public var flowState: AddFlowState
    public var preliminaryAnalysis: PreliminaryAnalysis?
    public var analysisReceipt: AnalysisReceiptDTO?
    public var overrides: ClaimOverridesDTO?
    public var serverExpiresAt: Date
    public var isCompleteForFallback: Bool

    public init(
        draftId: UUID,
        flowState: AddFlowState,
        preliminaryAnalysis: PreliminaryAnalysis? = nil,
        analysisReceipt: AnalysisReceiptDTO? = nil,
        overrides: ClaimOverridesDTO? = nil,
        serverExpiresAt: Date = Date().addingTimeInterval(24 * 3600),
        isCompleteForFallback: Bool = true
    ) {
        self.draftId = draftId
        self.flowState = flowState
        self.preliminaryAnalysis = preliminaryAnalysis
        self.analysisReceipt = analysisReceipt
        self.overrides = overrides
        self.serverExpiresAt = serverExpiresAt
        self.isCompleteForFallback = isCompleteForFallback
    }
}

// Metadata only; this token grants no OS scheduling or delivery authority.
struct CareReminderReceiptSnapshot: Sendable {
    let lease: SyncSessionLease
    let revision: UUID
    let receipts: CareReminderReceipts
}

enum CareReminderReceiptStoreError: Error, Equatable { case invalidMetadata, superseded }

private struct CareReminderReceiptPayload: Codable {
    let version: Int
    let revision: UUID
    let receipts: CareReminderReceipts
}

// MARK: - Local care overview (no sync schema or credential persistence)

enum CareOverviewAuthorizationError: Error { case denied }

enum CareOverviewInvalidation: String, Codable, Sendable {
    case canonicalRevalidation, authorizationDenied
}

enum CareOverviewStoreError: Error, Equatable {
    case invalidLocale
    case superseded
    case needsCanonicalSync
}

/// The original lease stays in memory; persisted pending IDs confer no authority.
struct CareOverviewReadToken: Sendable {
    fileprivate let lease: SyncSessionLease
    fileprivate let requestId: UUID
    fileprivate let canonicalGeneration: UUID
    let locale: String
}

struct CachedCareOverview: Sendable {
    enum State: Sendable, Equatable { case cached, stale }
    let snapshot: CareOverviewSnapshot
    let fetchedAt: Date
    let snapshotLocale: String
    let state: State
    // Alignment is local evidence only, never network freshness or OS permission.
    let canonicalGenerationMatches: Bool
}

/// One local epoch; nil generation means no valid reserved wrapper exists yet.
struct LocalCareOverviewPresentation: Sendable {
    let ownerId: UUID
    let canonicalGeneration: UUID?
    let snapshotGeneration: UUID?
    let cached: CachedCareOverview?
    let cards: [CatalogueCardSummary]
    let pending: [OutboxEntrySnapshot]
    let profile: SyncWireProfileDTO?
    let entitlement: SyncWireEntitlementDTO?
    let canonicalAccessKnown: Bool
    let careRows: [LocalCareOverviewRow]
    var knownInvalidation: CareOverviewInvalidation? = nil
}

/// Raw canonical evidence, including tombstones; never interpreted as future tasks.
struct LocalCareOverviewRow: Sendable {
    let entityType: String
    let entityId: UUID
    let payloadJSON: String
    let updatedAtRaw: String?
    let deletedAt: Date?
}

private struct CareOverviewCachePayload: Codable {
    var version = 1
    var canonicalGeneration = UUID()
    // Preserve the full encoded wire snapshot byte-for-byte on invalidation.
    var snapshotJSON: String?
    var snapshotGeneration: UUID?
    var fetchedAt: Date?
    var snapshotLocale: String?
    var pendingRequestId: UUID?
    var pendingRequestLocale: String?
    // Optional fields preserve version-1 decoding; no session material is persisted.
    var knownInvalidation: CareOverviewInvalidation?
    var revalidationRequestId: UUID?

    func validatedSnapshot(ownerId: UUID) throws -> CareOverviewSnapshot? {
        guard version == 1,
              (pendingRequestId == nil) == (pendingRequestLocale == nil),
              pendingRequestLocale.map({ ["en", "pl"].contains($0) }) ?? true else {
            throw SyncWireValidationError.invalidPage
        }
        guard let snapshotJSON else {
            guard snapshotGeneration == nil, fetchedAt == nil, snapshotLocale == nil else {
                throw SyncWireValidationError.invalidPage
            }
            return nil
        }
        guard snapshotGeneration != nil, let fetchedAt,
              fetchedAt.timeIntervalSince1970.isFinite,
              snapshotLocale.map({ ["en", "pl"].contains($0) }) == true else {
            throw SyncWireValidationError.invalidPage
        }
        return try JSONDecoder().decode(CareOverviewSnapshot.self, from: Data(snapshotJSON.utf8))
            .validated(for: ownerId)
    }
}

// MARK: - LocalStore ModelActor (T023)

@ModelActor
public actor LocalStore {
    public static func makeContainer(
        accountScope: String = "default",
        inMemory: Bool = false
    ) throws -> ModelContainer {
        let schema = Schema([
            LocalOutboxRecord.self,
            CatalogueCreateConfirmationRecord.self,
            CatalogueInputCheckpointRecord.self,
            GuestDraftCacheRecord.self,
            SyncedEntityRecord.self,
            SyncCheckpointRecord.self
        ])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(
                "PlantsStore_\(accountScope)",
                schema: schema,
                isStoredInMemoryOnly: true
            )
        } else {
            let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let storeDir = baseURL.appendingPathComponent("NaratStores", isDirectory: true)
            try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            let storeURL = storeDir.appendingPathComponent("store_\(accountScope).sqlite")
            configuration = ModelConfiguration(schema: schema, url: storeURL)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    // Presentation invalidation only: reread current owner state with the original lease.
    private var localOutboxObservers: [UUID: (owner: UUID, continuation: AsyncStream<Void>.Continuation)] = [:]

    func localOutboxUpdates(ownerId: UUID) -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        localOutboxObservers[id] = (ownerId, continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLocalOutboxObserver(id) }
        }
        return stream
    }

    private func removeLocalOutboxObserver(_ id: UUID) {
        localOutboxObservers[id] = nil
    }

    private func publishLocalOutboxChange(ownerId: UUID) {
        for observer in localOutboxObservers.values where observer.owner == ownerId {
            observer.continuation.yield(())
        }
    }

    // MARK: Outbox Operations

    func pendingProfileReminderHour(
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> ProfileReminderHourCommand? {
        try authority.withPermanentBoundValid(context) {
            let rows = try pendingOutboxEntries(for: context.ownerId).filter { $0.commandName == "profile.update" }
            guard !rows.isEmpty else { return nil }
            guard rows.count == 1, let command = ProfileReminderHourCommand(rows[0].envelope)
            else { throw SyncWireValidationError.invalidRequest }
            return command
        }
    }

    func enqueueProfileReminderHour(
        _ command: ProfileReminderHourCommand, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> ProfileReminderHourCommand {
        try authority.withPermanentBoundValid(context) {
            let rows = try pendingOutboxEntries(for: context.ownerId).filter { $0.commandName == "profile.update" }
            if !rows.isEmpty {
                guard rows.count == 1, let saved = ProfileReminderHourCommand(rows[0].envelope)
                else { throw SyncWireValidationError.invalidRequest }
                guard saved.reminderHourLocal == command.reminderHourLocal
                else { throw OutboxEnqueueError.operationIdentityMismatch }
                return saved
            }
            let envelope = command.envelope
            _ = try enqueueCommand(
                operationId: envelope.operationId, ownerId: context.ownerId, plantId: nil,
                commandName: envelope.commandName, payloadJSON: envelope.payloadJSON
            )
            return command
        }
    }

    /// Receipt proof and canonical profile read share the transaction that removes the exact command.
    /// A newer synchronized profile supersedes the hour in an older, correctly replayed receipt.
    func finishProfileReminderHour(
        _ command: ProfileReminderHourCommand, receipt: ProfileReminderHourReceipt?,
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> Int? {
        try authority.withPermanentBoundValid(context) {
            let disk = makeSyncContext()
            let ownerId = context.ownerId
            let operationId = command.envelope.operationId
            let rows = try disk.fetch(FetchDescriptor<LocalOutboxRecord>(predicate: #Predicate {
                $0.ownerId == ownerId && $0.commandName == "profile.update"
            }))
            guard rows.count == 1, let row = rows.first, row.operationId == operationId,
                  row.plantId == nil, row.payloadJSON == command.envelope.payloadJSON
            else { throw OutboxEnqueueError.operationIdentityMismatch }
            let hour: Int?
            if let receipt {
                let checkpoints = FetchDescriptor<SyncCheckpointRecord>(predicate: #Predicate { $0.ownerId == ownerId })
                guard receipt.profile.reminderHourLocal == command.reminderHourLocal,
                      let checkpoint = try disk.fetch(checkpoints).first,
                      let raw = checkpoint.watermarkRaw, let watermark = SQLTimestamp.microseconds(from: raw),
                      watermark >= receipt.watermark, let json = checkpoint.syncProfileJSON
                else { throw SyncWireValidationError.invalidPage }
                hour = try JSONDecoder().decode(SyncWireProfileDTO.self, from: Data(json.utf8)).reminderHourLocal
            } else {
                // Only an explicit permanent server rejection may discard without canonical proof.
                hour = nil
            }
            disk.delete(row)
            try Task.checkCancellation()
            try disk.save()
            publishLocalOutboxChange(ownerId: ownerId)
            return hour
        }
    }

    public func enqueueCommand(
        operationId: UUID = UUID(),
        ownerId: UUID,
        plantId: UUID?,
        commandName: String,
        payloadJSON: String
    ) throws -> OutboxEntrySnapshot {
        try enqueueCommand(operationId: operationId, ownerId: ownerId, plantId: plantId,
                           commandName: commandName, payloadJSON: payloadJSON, observationJPEG: nil)
    }

    private func enqueueCommand(
        operationId: UUID, ownerId: UUID, plantId: UUID?, commandName: String, payloadJSON: String,
        observationJPEG: Data?
    ) throws -> OutboxEntrySnapshot {
        let modelContext = makeSyncContext()
        let existingDescriptor = FetchDescriptor<LocalOutboxRecord>(
            predicate: #Predicate { $0.operationId == operationId }
        )
        if let existing = try modelContext.fetch(existingDescriptor).first {
            guard existing.ownerId == ownerId,
                  existing.plantId == plantId,
                  existing.commandName.utf8.elementsEqual(commandName.utf8),
                  existing.payloadJSON.utf8.elementsEqual(payloadJSON.utf8),
                  existing.observationJPEG == observationJPEG else {
                throw OutboxEnqueueError.operationIdentityMismatch
            }
            return OutboxEntrySnapshot(
                operationId: existing.operationId,
                ownerId: existing.ownerId,
                plantId: existing.plantId,
                commandName: existing.commandName,
                payloadJSON: existing.payloadJSON,
                sequenceNumber: existing.sequenceNumber,
                retryCount: existing.retryCount,
                lastError: existing.lastError,
                createdAt: existing.createdAt
            )
        }

        let allDescriptor = FetchDescriptor<LocalOutboxRecord>(
            sortBy: [SortDescriptor(\.sequenceNumber, order: .reverse)]
        )
        let nextSeq = (try modelContext.fetch(allDescriptor).first?.sequenceNumber ?? 0) + 1

        let record = LocalOutboxRecord(
            operationId: operationId,
            ownerId: ownerId,
            plantId: plantId,
            commandName: commandName,
            payloadJSON: payloadJSON,
            sequenceNumber: nextSeq
        )
        record.observationJPEG = observationJPEG
        modelContext.insert(record)
        try modelContext.save()
        publishLocalOutboxChange(ownerId: record.ownerId)

        return OutboxEntrySnapshot(
            operationId: record.operationId,
            ownerId: record.ownerId,
            plantId: record.plantId,
            commandName: record.commandName,
            payloadJSON: record.payloadJSON,
            sequenceNumber: record.sequenceNumber,
            retryCount: record.retryCount,
            lastError: record.lastError,
            createdAt: record.createdAt
        )
    }

    func enqueueSavedPlantWatering(
        _ command: CommandEnvelopeDTO, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws {
        try authority.withPermanentBoundValid(context) {
            let disk = makeSyncContext()
            guard let plantId = command.plantId, ManualWateringAction(envelope: command) == .record,
                  let payload = try? JSONDecoder().decode([String: String].self, from: Data(command.payloadJSON.utf8)),
                  let raw = payload["occurred_at"], let date = SQLTimestamp.date(from: raw), date <= Date(),
                  let row = try activeSyncRow("plants", id: plantId, ownerId: context.ownerId, in: disk),
                  let card = try? JSONDecoder().decode(CatalogueCardSummary.self, from: Data(row.payloadJSON.utf8)),
                  card.id == plantId, card.revision > 0, card.careRevision > 0 else {
                throw SyncWireValidationError.invalidRequest
            }
            let pending = try pendingOutboxEntries(for: context.ownerId)
            guard !pending.contains(where: {
                $0.plantId == plantId && ($0.commandName == PlantDeleteReceipt.commandName
                    || ($0.operationId != command.operationId && ManualWateringAction.accepts(command: $0.commandName)))
            }) else { throw OutboxEnqueueError.operationIdentityMismatch }
            _ = try enqueueCommand(
                operationId: command.operationId, ownerId: context.ownerId, plantId: plantId,
                commandName: command.commandName, payloadJSON: command.payloadJSON
            )
        }
    }

    func enqueueManualWatering(
        _ command: CommandEnvelopeDTO, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws {
        try authority.withBoundValid(context) {
            guard let plantId = command.plantId, let action = ManualWateringAction(envelope: command) else {
                throw OutboxEnqueueError.operationIdentityMismatch
            }
            if case let .correctDate(entryId, _, _) = action {
                guard try activeSyncedEntities(ownerId: context.ownerId, entityType: "plants").contains(where: { $0.id == plantId }),
                      let item = try activeSyncedEntities(ownerId: context.ownerId, entityType: "care_entries")
                        .first(where: { $0.id == entryId }),
                      let entry = try? JSONDecoder().decode(CatalogueCareJournalEntry.self, from: Data(item.payloadJSON.utf8)),
                      entry.id == entryId, entry.plantId == plantId, entry.taskId == nil,
                      entry.actionCode == "water", entry.state == "active" else {
                    throw SyncWireValidationError.invalidPage
                }
            }
            let pending = try pendingOutboxEntries(for: context.ownerId)
            guard !pending.contains(where: {
                $0.plantId == plantId && $0.operationId != command.operationId
                    && ManualWateringAction.accepts(command: $0.commandName)
            }) else { throw OutboxEnqueueError.operationIdentityMismatch }
            _ = try enqueueCommand(operationId: command.operationId, ownerId: context.ownerId,
                                   plantId: plantId, commandName: command.commandName, payloadJSON: command.payloadJSON)
        }
    }

    func enqueueCollectionWateringUndo(
        _ command: CommandEnvelopeDTO, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws {
        try authority.withBoundValid(context) {
            let disk = makeSyncContext()
            guard let plantId = command.plantId,
                  try activeSyncRow("plants", id: plantId, ownerId: context.ownerId, in: disk) != nil,
                  try manualUndoEntry(command, actionCode: "water", ownerId: context.ownerId, in: disk)?.state == "active"
            else { throw SyncWireValidationError.invalidPage }
        }
        try enqueueManualWatering(command, context: context, authority: authority)
    }

    func pendingFirstAidRecord(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> FirstAidRecordCommand? {
        try authority.withBoundValid(context) {
            try firstAidRecordInOutbox(plantId: plantId, ownerId: context.ownerId)
        }
    }

    func enqueueFirstAidRecord(
        _ command: FirstAidRecordCommand, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> FirstAidRecordCommand {
        try authority.withBoundValid(context) {
            let ownerId = context.ownerId
            guard try activeSyncedEntities(ownerId: ownerId, entityType: "plants")
                .contains(where: { $0.id == command.plantId }) else { throw SyncWireValidationError.invalidPage }
            if let pending = try firstAidRecordInOutbox(plantId: command.plantId, ownerId: ownerId) {
                guard pending.jobId == command.jobId else { throw OutboxEnqueueError.operationIdentityMismatch }
                return pending
            }
            let envelope = command.envelope
            _ = try enqueueCommand(operationId: envelope.operationId, ownerId: ownerId, plantId: command.plantId,
                                   commandName: envelope.commandName, payloadJSON: envelope.payloadJSON)
            return command
        }
    }

    private func firstAidRecordInOutbox(plantId: UUID, ownerId: UUID) throws -> FirstAidRecordCommand? {
        guard let entry = try pendingOutboxEntries(for: ownerId).first(where: {
            $0.plantId == plantId && $0.commandName == FirstAidRecordCommand.name
        }) else { return nil }
        guard let command = FirstAidRecordCommand(envelope: entry.envelope)
        else { throw OutboxEnqueueError.operationIdentityMismatch }
        return command
    }

    /// A replay proves creation even after a later correction or undo.
    /// The original payload must never overwrite the current canonical fact.
    func confirmedWateringRecord(
        _ command: CommandEnvelopeDTO, entryId: UUID, watermark: Int64,
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> Bool {
        try authority.withBoundValid(context) {
            guard let raw = try currentWatermarkRaw(ownerId: context.ownerId),
                  let current = SQLTimestamp.microseconds(from: raw), current >= watermark else { return false }
            return try canonicalWateringRecord(command, ownerId: context.ownerId, entryId: entryId) == entryId
        }
    }

    /// Operation identity survives subsequent canonical date corrections and undo.
    func confirmedWateringRecord(
        _ command: CommandEnvelopeDTO, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> UUID? {
        try authority.withBoundValid(context) {
            try canonicalWateringRecord(command, ownerId: context.ownerId)
        }
    }

    private func canonicalWateringRecord(
        _ command: CommandEnvelopeDTO, ownerId: UUID, entryId: UUID? = nil
    ) throws -> UUID? {
        guard let plantId = command.plantId, ManualWateringAction(envelope: command) == .record
        else { return nil }
        for row in try activeSyncedEntities(ownerId: ownerId, entityType: "care_entries") {
            if let entryId, row.id != entryId { continue }
            guard let entry = try? JSONDecoder().decode(
                CatalogueCareJournalEntry.self, from: Data(row.payloadJSON.utf8)
            ), entry.id == row.id, entry.operationId == command.operationId,
               entry.plantId == plantId, entry.taskId == nil, entry.actionCode == "water",
               entry.hasCanonicalDatesAndState else { continue }
            return entry.id
        }
        return nil
    }

    func confirmedFirstAidEntry(
        _ command: FirstAidRecordCommand, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> UUID? {
        try authority.withBoundValid(context) {
            let rows = try activeSyncedEntities(ownerId: context.ownerId, entityType: "care_entries")
            let decoder = JSONDecoder()
            return rows.first(where: { row in
                guard let entry = try? decoder.decode(CatalogueCareJournalEntry.self, from: Data(row.payloadJSON.utf8))
                else { return false }
                return entry.operationId == command.envelope.operationId && entry.id == row.id
                    && entry.plantId == command.plantId && entry.taskId == nil && entry.actionCode == "check_soil"
                    && entry.hasCanonicalDatesAndState
            })?.id
        }
    }

    func pendingManualCare(
        plantId: UUID, firstAidUndo: Bool, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CommandEnvelopeDTO? {
        try authority.withBoundValid(context) {
            try pendingManualCare(plantId: plantId, firstAidUndo: firstAidUndo, ownerId: context.ownerId)
        }
    }

    private func pendingManualCare(plantId: UUID, firstAidUndo: Bool, ownerId: UUID) throws -> CommandEnvelopeDTO? {
        let disk = makeSyncContext()
        for row in try pendingOutboxEntries(for: ownerId) where row.plantId == plantId {
            guard ManualWateringAction.accepts(command: row.commandName),
                  !firstAidUndo || row.commandName == ManualWateringAction.undoCommand else { continue }
            let envelope = row.envelope
            guard ManualWateringAction(envelope: envelope) != nil else { throw OutboxEnqueueError.operationIdentityMismatch }
            let isFirstAidUndo = try firstAidUndoEntry(envelope, ownerId: ownerId, in: disk) != nil
            if isFirstAidUndo == firstAidUndo { return envelope }
        }
        return nil
    }

    func enqueueFirstAidUndo(
        _ command: CommandEnvelopeDTO, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CommandEnvelopeDTO {
        try authority.withBoundValid(context) {
            let ownerId = context.ownerId
            guard let plantId = command.plantId, case let .undo(entryId) = ManualWateringAction(envelope: command),
                  let entry = try firstAidUndoEntry(command, ownerId: ownerId, in: makeSyncContext()),
                  try activeSyncedEntities(ownerId: ownerId, entityType: "plants").contains(where: { $0.id == plantId })
            else { throw SyncWireValidationError.invalidPage }
            if let pending = try pendingManualCare(plantId: plantId, firstAidUndo: true, ownerId: ownerId) {
                guard ManualWateringAction(envelope: pending) == .undo(entryId)
                else { throw OutboxEnqueueError.operationIdentityMismatch }
                return pending
            }
            guard entry.state == "active", try firstAidRecordInOutbox(plantId: plantId, ownerId: ownerId) == nil,
                  try firstAidPhotoDraftInOutbox(plantId: plantId, ownerId: ownerId) == nil
            else { throw OutboxEnqueueError.operationIdentityMismatch }
            _ = try enqueueCommand(operationId: command.operationId, ownerId: ownerId, plantId: plantId,
                                   commandName: command.commandName, payloadJSON: command.payloadJSON)
            return command
        }
    }

    func isFirstAidUndo(
        _ command: CommandEnvelopeDTO, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> Bool {
        try authority.withBoundValid(context) {
            try firstAidUndoEntry(command, ownerId: context.ownerId, in: makeSyncContext()) != nil
        }
    }

    private func firstAidUndoEntry(
        _ command: CommandEnvelopeDTO, ownerId: UUID, in disk: ModelContext
    ) throws -> CatalogueCareJournalEntry? {
        try manualUndoEntry(command, actionCode: "check_soil", ownerId: ownerId, in: disk)
    }

    private func manualUndoEntry(
        _ command: CommandEnvelopeDTO, actionCode: String, ownerId: UUID, in disk: ModelContext
    ) throws -> CatalogueCareJournalEntry? {
        guard let plantId = command.plantId, case let .undo(entryId) = ManualWateringAction(envelope: command)
        else { return nil }
        guard let row = try activeSyncRow("care_entries", id: entryId, ownerId: ownerId, in: disk),
              let entry = try? JSONDecoder().decode(CatalogueCareJournalEntry.self, from: Data(row.payloadJSON.utf8)),
              entry.id == entryId, entry.plantId == plantId, entry.taskId == nil,
              entry.actionCode == actionCode, entry.hasCanonicalDatesAndState else { return nil }
        return entry
    }

    private func activeSyncRow(
        _ entityType: String, id: UUID, ownerId: UUID, in disk: ModelContext
    ) throws -> SyncedEntityRecord? {
        let descriptor = FetchDescriptor<SyncedEntityRecord>(predicate: #Predicate {
            $0.ownerId == ownerId && $0.entityType == entityType && $0.entityId == id && $0.deletedAt == nil
        })
        return try disk.fetch(descriptor).first
    }

    func enqueuePlantEdit(
        _ edit: PlantEditCommand, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CommandEnvelopeDTO {
        try authority.withBoundValid(context) {
            let ownerId = context.ownerId
            let command = edit.envelope
            guard let plantId = command.plantId,
                  try activeSyncRow("plants", id: plantId, ownerId: ownerId, in: makeSyncContext()) != nil
            else { throw SyncWireValidationError.invalidRequest }
            let pending = try pendingOutboxEntries(for: ownerId).filter { $0.plantId == plantId }
            guard !pending.contains(where: { $0.commandName == PlantDeleteReceipt.commandName })
            else { throw OutboxEnqueueError.operationIdentityMismatch }
            if let existing = pending.first(where: { $0.commandName == PlantEditCommand.name }) {
                guard existing.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8)
                else { throw OutboxEnqueueError.operationIdentityMismatch }
                return existing.envelope
            }
            return try enqueueCommand(
                operationId: command.operationId, ownerId: ownerId, plantId: plantId,
                commandName: command.commandName, payloadJSON: command.payloadJSON
            ).envelope
        }
    }

    private struct SyncedBasicCareMembership: Decodable {
        let plantId: UUID
        let enabled: Bool
        let enabledAt: String

        enum CodingKeys: String, CodingKey {
            case plantId = "plant_id"
            case enabled
            case enabledAt = "enabled_at"
        }
    }

    func syncedBasicCareEnabledAt(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> Int64? {
        try authority.withBoundValid(context) {
            let rows = try activeSyncedEntities(ownerId: context.ownerId, entityType: "basic_care_memberships")
            let decoder = JSONDecoder()
            let memberships = try rows.map { try decoder.decode(SyncedBasicCareMembership.self, from: Data($0.payloadJSON.utf8)) }
            guard let membership = memberships.first(where: { $0.plantId == plantId && $0.enabled })
            else { return nil }
            guard let timestamp = SQLTimestamp.microseconds(from: membership.enabledAt)
            else { throw SyncWireValidationError.invalidPage }
            return timestamp
        }
    }

    func enqueueBasicCareEnable(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CommandEnvelopeDTO {
        try authority.withBoundValid(context) {
            let owner = context.ownerId
            guard try activeSyncRow("plants", id: plantId, ownerId: owner, in: makeSyncContext()) != nil
            else { throw SyncWireValidationError.invalidRequest }

            let pending = try pendingOutboxEntries(for: owner).filter { $0.plantId == plantId }
            guard !pending.contains(where: { $0.commandName == PlantDeleteReceipt.commandName })
            else { throw OutboxEnqueueError.operationIdentityMismatch }
            let name = BasicCareEnableReceipt.commandName
            if let existing = pending.first(where: { $0.commandName == name }) { return existing.envelope }
            return try enqueueCommand(
                operationId: UUID(), ownerId: owner, plantId: plantId, commandName: name, payloadJSON: "{}"
            ).envelope
        }
    }

    func enqueueCareRecommendationRefresh(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CommandEnvelopeDTO {
        guard let card = try syncedCollectionCard(plantId: plantId, context: context, authority: authority)
        else { throw SyncWireValidationError.invalidRequest }
        return try authority.withBoundValid(context) {
            let pending = try pendingOutboxEntries(for: context.ownerId).filter { $0.plantId == plantId }
            guard !pending.contains(where: {
                $0.commandName == PlantDeleteReceipt.commandName || $0.commandName == PlantEditCommand.name
            }) else { throw OutboxEnqueueError.operationIdentityMismatch }
            if let existing = pending.first(where: { $0.commandName == CareRecommendationRefreshCommand.name }) {
                return existing.envelope
            }
            let command = try CareRecommendationRefreshCommand.make(plantId: plantId, careRevision: card.careRevision)
            return try enqueueCommand(
                operationId: command.envelope.operationId, ownerId: context.ownerId, plantId: plantId,
                commandName: command.envelope.commandName, payloadJSON: command.envelope.payloadJSON
            ).envelope
        }
    }

    func pendingRoutineCompletion(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> RoutineSoilCheckCompletionCommand? {
        try authority.withBoundValid(context) {
            guard let row = try pendingOutboxEntries(for: context.ownerId).first(where: {
                $0.plantId == plantId && $0.commandName == RoutineSoilCheckCompletionCommand.name
            }) else { return nil }
            guard let command = RoutineSoilCheckCompletionCommand(row.envelope)
            else { throw OutboxEnqueueError.operationIdentityMismatch }
            return command
        }
    }

    func enqueueRoutineCompletion(
        _ command: RoutineSoilCheckCompletionCommand,
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> RoutineSoilCheckCompletionCommand {
        try authority.withBoundValid(context) {
            guard let plantId = command.envelope.plantId,
                  let row = try activeSyncRow("plants", id: plantId, ownerId: context.ownerId, in: makeSyncContext())
            else { throw SyncWireValidationError.invalidRequest }
            let card = try JSONDecoder().decode(CatalogueCardSummary.self, from: Data(row.payloadJSON.utf8))
            guard card.id == plantId, card.revision > 0, card.careRevision == command.careRevision
            else { throw SyncWireValidationError.invalidRequest }
            let pending = try pendingOutboxEntries(for: context.ownerId).filter { $0.plantId == plantId }
            guard !pending.contains(where: {
                $0.commandName == PlantDeleteReceipt.commandName || $0.commandName == RoutineSoilCheckUndoCommand.name
            }) else { throw OutboxEnqueueError.operationIdentityMismatch }
            if let row = pending.first(where: { $0.commandName == RoutineSoilCheckCompletionCommand.name }) {
                guard let existing = RoutineSoilCheckCompletionCommand(row.envelope)
                else { throw OutboxEnqueueError.operationIdentityMismatch }
                guard existing.ruleId == command.ruleId, existing.careRevision == command.careRevision,
                      existing.dueLocalDate == command.dueLocalDate
                else { throw OutboxEnqueueError.operationIdentityMismatch }
                return existing
            }
            _ = try enqueueCommand(
                operationId: command.envelope.operationId, ownerId: context.ownerId, plantId: plantId,
                commandName: command.envelope.commandName, payloadJSON: command.envelope.payloadJSON
            )
            return command
        }
    }

    /// One actor-isolated, session-bound read of the canonical owner cache.
    func routineSoilCheckHistory(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> [CatalogueCareJournalEntry] {
        try authority.withBoundValid(context) {
            try Task.checkCancellation()
            let disk = makeSyncContext()
            let ownerId = context.ownerId
            guard try activeSyncRow("plants", id: plantId, ownerId: ownerId, in: disk) != nil
            else { throw SyncWireValidationError.invalidPage }
            let rows = try disk.fetch(FetchDescriptor<SyncedEntityRecord>(predicate: #Predicate {
                $0.ownerId == ownerId && $0.deletedAt == nil
                    && ($0.entityType == "care_entries" || $0.entityType == "care_tasks")
            }))
            let decoder = JSONDecoder()
            var tasks: [UUID: RoutineUndoTask] = [:]
            var entries: [UUID: CatalogueCareJournalEntry] = [:]
            for row in rows {
                try Task.checkCancellation()
                let data = Data(row.payloadJSON.utf8)
                if row.entityType == "care_tasks" {
                    if let task = try? decoder.decode(RoutineUndoTask.self, from: data),
                       task.id == row.entityId, task.plantId == plantId, task.isRoutineCheck {
                        tasks[task.id] = task
                    }
                } else if let entry = try? decoder.decode(CatalogueCareJournalEntry.self, from: data),
                          entry.id == row.entityId, entry.plantId == plantId,
                          entry.actionCode == "check_soil", entry.operationId != nil,
                          entry.hasCanonicalDatesAndState {
                    entries[entry.id] = entry
                }
            }
            let history = entries.values.filter { entry in
                guard let taskId = entry.taskId, let task = tasks[taskId] else { return false }
                if entry.state == "active" {
                    return task.state == "completed" && task.completedEntryId == entry.id
                }
                // A voided fact survives a later completion of the same occurrence.
                guard let latest = entries[task.completedEntryId], latest.taskId == task.id
                else { return false }
                return (task.state == "superseded" && latest.state == "voided")
                    || (task.state == "completed" && latest.state == "active" && latest.id != entry.id)
            }.sorted {
                let left = SQLTimestamp.microseconds(from: $0.occurredAt)!
                let right = SQLTimestamp.microseconds(from: $1.occurredAt)!
                return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
            }
            try Task.checkCancellation()
            return history
        }
    }

    private struct RoutineUndoTask: Decodable {
        let id: UUID
        let plantId: UUID
        let ruleId: UUID
        let occurrenceKey: String
        let dueLocalDate: String
        let actionCode: String
        let conditionCode: String
        let state: String
        let completedEntryId: UUID

        enum CodingKeys: String, CodingKey {
            case id, state
            case plantId = "plant_id", ruleId = "rule_id", occurrenceKey = "occurrence_key"
            case dueLocalDate = "due_local_date", actionCode = "action_code", conditionCode = "condition_code"
            case completedEntryId = "completed_entry_id"
        }

        var isRoutineCheck: Bool {
            actionCode == "check_soil" && conditionCode == "check_soil_first"
                && occurrenceKey == ruleId.uuidString.lowercased() + ":" + dueLocalDate
                && SQLCalendarDay.date(from: dueLocalDate) != nil
        }
    }

    private struct RoutineUndoIdentity: Codable {
        let taskJSON: String
        let entryJSON: String
    }

    private func savedRoutineUndo(
        _ row: LocalOutboxRecord
    ) throws -> (command: RoutineSoilCheckUndoCommand, task: RoutineUndoTask, entry: CatalogueCareJournalEntry) {
        guard let json = row.routineUndoIdentityJSON else { throw SyncWireValidationError.invalidRequest }
        let decoder = JSONDecoder()
        let saved = try decoder.decode(RoutineUndoIdentity.self, from: Data(json.utf8))
        let task = try decoder.decode(RoutineUndoTask.self, from: Data(saved.taskJSON.utf8))
        let entry = try decoder.decode(CatalogueCareJournalEntry.self, from: Data(saved.entryJSON.utf8))
        let envelope = CommandEnvelopeDTO(
            operationId: row.operationId, commandName: row.commandName,
            plantId: row.plantId, payloadJSON: row.payloadJSON
        )
        guard let command = RoutineSoilCheckUndoCommand(envelope, taskId: task.id),
              task.isRoutineCheck, task.state == "completed", task.completedEntryId == entry.id,
              task.plantId == row.plantId, entry.plantId == task.plantId, entry.taskId == task.id,
              command.entryId == entry.id, entry.state == "active", entry.actionCode == "check_soil",
              entry.operationId != nil, entry.operationId != row.operationId, entry.hasCanonicalDatesAndState
        else { throw SyncWireValidationError.invalidRequest }
        return (command, task, entry)
    }

    func pendingRoutineUndo(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> RoutineSoilCheckUndoCommand? {
        try authority.withBoundValid(context) {
            try pendingRoutineUndo(plantId: plantId, ownerId: context.ownerId)
        }
    }

    private func pendingRoutineUndo(plantId: UUID, ownerId: UUID) throws -> RoutineSoilCheckUndoCommand? {
        let name = RoutineSoilCheckUndoCommand.name
        let rows = try makeSyncContext().fetch(FetchDescriptor<LocalOutboxRecord>(predicate: #Predicate {
            $0.ownerId == ownerId && $0.plantId == plantId && $0.commandName == name
        }))
        guard let row = rows.first else { return nil }
        return try savedRoutineUndo(row).command
    }

    func enqueueRoutineUndo(
        _ command: RoutineSoilCheckUndoCommand,
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> RoutineSoilCheckUndoCommand {
        try authority.withBoundValid(context) {
            guard let plantId = command.envelope.plantId else { throw SyncWireValidationError.invalidRequest }
            // Replay the saved identity even when sync has already voided the entry.
            if let saved = try pendingRoutineUndo(plantId: plantId, ownerId: context.ownerId) {
                guard saved.entryId == command.entryId, saved.taskId == command.taskId
                else { throw OutboxEnqueueError.operationIdentityMismatch }
                return saved
            }
            let pending = try pendingOutboxEntries(for: context.ownerId)
            guard !pending.contains(where: {
                $0.plantId == plantId && ($0.commandName == RoutineSoilCheckCompletionCommand.name
                    || $0.commandName == PlantDeleteReceipt.commandName)
            }) else { throw OutboxEnqueueError.operationIdentityMismatch }
            let disk = makeSyncContext()
            guard try activeSyncRow("plants", id: plantId, ownerId: context.ownerId, in: disk) != nil,
                  let taskRow = try activeSyncRow("care_tasks", id: command.taskId, ownerId: context.ownerId, in: disk),
                  let entryRow = try activeSyncRow("care_entries", id: command.entryId, ownerId: context.ownerId, in: disk)
            else { throw SyncWireValidationError.invalidRequest }
            let row = LocalOutboxRecord(
                operationId: command.envelope.operationId, ownerId: context.ownerId, plantId: plantId,
                commandName: command.envelope.commandName, payloadJSON: command.envelope.payloadJSON,
                sequenceNumber: (try disk.fetch(FetchDescriptor<LocalOutboxRecord>(
                    sortBy: [SortDescriptor(\.sequenceNumber, order: .reverse)]
                )).first?.sequenceNumber ?? 0) + 1
            )
            row.routineUndoIdentityJSON = String(decoding: try JSONEncoder().encode(RoutineUndoIdentity(
                taskJSON: taskRow.payloadJSON, entryJSON: entryRow.payloadJSON
            )), as: UTF8.self)
            guard try savedRoutineUndo(row).command.taskId == command.taskId
            else { throw SyncWireValidationError.invalidRequest }
            let operationId = command.envelope.operationId
            guard try disk.fetch(FetchDescriptor<LocalOutboxRecord>(predicate: #Predicate {
                $0.operationId == operationId
            })).isEmpty else { throw OutboxEnqueueError.operationIdentityMismatch }
            disk.insert(row)
            try Task.checkCancellation()
            try disk.save()
            publishLocalOutboxChange(ownerId: row.ownerId)
            return command
        }
    }

    func validateRoutineUndo(
        _ receipt: RoutineSoilCheckUndoReceipt, command: RoutineSoilCheckUndoCommand,
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws {
        try authority.withBoundValid(context) {
            try receipt.validate(for: command)
            let disk = makeSyncContext()
            let operationId = command.envelope.operationId
            let ownerId = context.ownerId
            guard let pending = try disk.fetch(FetchDescriptor<LocalOutboxRecord>(predicate: #Predicate {
                $0.operationId == operationId && $0.ownerId == ownerId
            })).first else { throw SyncWireValidationError.invalidPage }
            let saved = try savedRoutineUndo(pending)
            guard saved.command.envelope == command.envelope, saved.command.taskId == command.taskId,
                  let raw = try currentWatermarkRaw(ownerId: ownerId),
                  let watermark = SQLTimestamp.microseconds(from: raw), watermark >= receipt.watermark,
                  try activeSyncRow("plants", id: receipt.plantId, ownerId: ownerId, in: disk) != nil,
                  let taskRow = try activeSyncRow("care_tasks", id: receipt.taskId, ownerId: ownerId, in: disk),
                  let entryRow = try activeSyncRow("care_entries", id: receipt.entryId, ownerId: ownerId, in: disk)
            else { throw SyncWireValidationError.invalidPage }
            let decoder = JSONDecoder()
            let task = try decoder.decode(RoutineUndoTask.self, from: Data(taskRow.payloadJSON.utf8))
            let entry = try decoder.decode(CatalogueCareJournalEntry.self, from: Data(entryRow.payloadJSON.utf8))
            guard task.id == saved.task.id, task.plantId == saved.task.plantId, task.isRoutineCheck,
                  task.ruleId == saved.task.ruleId, task.occurrenceKey == saved.task.occurrenceKey,
                  task.dueLocalDate == saved.task.dueLocalDate, task.conditionCode == saved.task.conditionCode,
                  entry.id == saved.entry.id, entry.plantId == saved.entry.plantId,
                  entry.taskId == saved.entry.taskId, entry.operationId == saved.entry.operationId,
                  entry.actionCode == saved.entry.actionCode, entry.occurredAt == saved.entry.occurredAt,
                  entry.occurredLocalDate == saved.entry.occurredLocalDate, entry.timezone == saved.entry.timezone,
                  entry.state == "voided", entry.hasCanonicalDatesAndState,
                  try confirmedCareReversal(command.envelope, entryId: entry.id, ownerId: ownerId, in: disk)
                    == receipt.reversalId
            else { throw SyncWireValidationError.invalidPage }
            if task.state == "superseded", task.completedEntryId == entry.id { return }
            // A different device may have re-completed this same occurrence after the undo.
            guard task.state == "completed", task.completedEntryId != entry.id,
                  let replacementRow = try activeSyncRow(
                    "care_entries", id: task.completedEntryId, ownerId: ownerId, in: disk
                  ) else { throw SyncWireValidationError.invalidPage }
            let replacement = try decoder.decode(
                CatalogueCareJournalEntry.self, from: Data(replacementRow.payloadJSON.utf8)
            )
            guard replacement.id == task.completedEntryId, replacement.plantId == task.plantId,
                  replacement.taskId == task.id, replacement.actionCode == "check_soil",
                  replacement.state == "active", replacement.hasCanonicalDatesAndState,
                  let replacementOperation = replacement.operationId,
                  replacementOperation != saved.entry.operationId, replacementOperation != operationId
            else { throw SyncWireValidationError.invalidPage }
        }
    }

    private struct CompletedRoutineTask: Decodable {
        let id: UUID
        let plantId: UUID
        let ruleId: UUID
        let occurrenceKey: String
        let dueLocalDate: String
        let actionCode: String
        let state: String
        let completedEntryId: UUID

        enum CodingKeys: String, CodingKey {
            case id, state
            case plantId = "plant_id", ruleId = "rule_id", occurrenceKey = "occurrence_key"
            case dueLocalDate = "due_local_date", actionCode = "action_code"
            case completedEntryId = "completed_entry_id"
        }
    }

    func validateRoutineCompletion(
        _ receipt: RoutineSoilCheckCompletionReceipt, command: RoutineSoilCheckCompletionCommand,
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws {
        try authority.withBoundValid(context) {
            try receipt.validate(for: command)
            let disk = makeSyncContext()
            guard let raw = try currentWatermarkRaw(ownerId: context.ownerId),
                  let watermark = SQLTimestamp.microseconds(from: raw), watermark >= receipt.watermark,
                  let taskRow = try activeSyncRow("care_tasks", id: receipt.taskId, ownerId: context.ownerId, in: disk),
                  let entryRow = try activeSyncRow("care_entries", id: receipt.entryId, ownerId: context.ownerId, in: disk)
            else { throw SyncWireValidationError.invalidPage }
            let task = try JSONDecoder().decode(CompletedRoutineTask.self, from: Data(taskRow.payloadJSON.utf8))
            let entry = try JSONDecoder().decode(CatalogueCareJournalEntry.self, from: Data(entryRow.payloadJSON.utf8))
            guard task.id == receipt.taskId, task.plantId == receipt.plantId, task.ruleId == receipt.ruleId,
                  task.occurrenceKey == receipt.occurrenceKey, task.dueLocalDate == receipt.dueLocalDate,
                  task.actionCode == "check_soil", task.state == "completed",
                  task.completedEntryId == receipt.entryId,
                  entry.id == receipt.entryId, entry.plantId == receipt.plantId, entry.taskId == receipt.taskId,
                  entry.actionCode == "check_soil", entry.state == "active", entry.hasCanonicalDatesAndState,
                  entry.operationId == command.envelope.operationId
            else { throw SyncWireValidationError.invalidPage }
        }
    }

    func syncedCollectionCard(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CatalogueCardSummary? {
        try authority.withBoundValid(context) {
            guard let row = try activeSyncRow("plants", id: plantId, ownerId: context.ownerId, in: makeSyncContext())
            else { return nil }
            let card = try JSONDecoder().decode(CatalogueCardSummary.self, from: Data(row.payloadJSON.utf8))
            guard card.id == plantId, card.revision > 0, card.careRevision > 0
            else { throw SyncWireValidationError.invalidPage }
            return card
        }
    }

    func syncedPlantConditions(
        for card: CatalogueCardSummary, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> PlantConditionCodes? {
        try authority.withBoundValid(context) {
            guard let snapshot = card.currentConditionSnapshotId,
                  let row = try activeSyncRow("condition_snapshots", id: snapshot, ownerId: context.ownerId, in: makeSyncContext()),
                  let conditions = try? JSONDecoder().decode(PlantConditionCodes.self, from: Data(row.payloadJSON.utf8)),
                  conditions.id == snapshot, conditions.plantId == card.id else { return nil }
            return conditions
        }
    }

    func enqueuePlantDeletion(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CommandEnvelopeDTO {
        try authority.withBoundValid(context) {
            let ownerId = context.ownerId
            if let queued = try pendingOutboxEntries(for: ownerId).first(where: {
                $0.plantId == plantId && $0.commandName == PlantDeleteReceipt.commandName
            }) {
                return queued.envelope
            }
            guard try activeSyncRow("plants", id: plantId, ownerId: ownerId, in: makeSyncContext()) != nil
            else { throw SyncWireValidationError.invalidRequest }
            return try enqueueCommand(
                ownerId: ownerId, plantId: plantId, commandName: PlantDeleteReceipt.commandName, payloadJSON: "{}"
            ).envelope
        }
    }

    func plantDeletionWatermark(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> Int64? {
        try authority.withBoundValid(context) {
            try plantDeletionWatermark(plantId: plantId, ownerId: context.ownerId, in: makeSyncContext())
        }
    }

    private func plantDeletionWatermark(plantId: UUID, ownerId: UUID, in disk: ModelContext) throws -> Int64? {
        let descriptor = FetchDescriptor<SyncedEntityRecord>(predicate: #Predicate {
            $0.ownerId == ownerId && $0.entityType == "plants" && $0.entityId == plantId && $0.deletedAt != nil
        })
        guard let row = try disk.fetch(descriptor).first, row.payloadJSON == "null",
              let stamp = row.updatedAtRaw, let deletedAt = row.deletedAt,
              SQLTimestamp.date(from: stamp) == deletedAt else { return nil }
        return SQLTimestamp.microseconds(from: stamp)
    }

    func acknowledgePlantDeletion(
        _ command: CommandEnvelopeDTO, receipt: PlantDeleteReceipt,
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws {
        try authority.withBoundValid(context) {
            Self.catalogueInputLock.lock()
            defer { Self.catalogueInputLock.unlock() }
            let disk = makeSyncContext()
            let ownerId = context.ownerId
            let plantId = receipt.plantId
            guard command.plantId == plantId,
                  let deleted = try plantDeletionWatermark(plantId: plantId, ownerId: ownerId, in: disk),
                  deleted >= receipt.watermark else { throw SyncWireValidationError.invalidPage }
            let descriptor = FetchDescriptor<LocalOutboxRecord>(
                predicate: #Predicate { $0.ownerId == ownerId && $0.plantId == plantId }
            )
            let entries = try disk.fetch(descriptor)
            guard entries.contains(where: {
                $0.operationId == command.operationId && $0.commandName == PlantDeleteReceipt.commandName
                    && $0.payloadJSON == command.payloadJSON
            }) else { throw OutboxEnqueueError.operationIdentityMismatch }
            for entry in entries { disk.delete(entry) }
            let confirmations = FetchDescriptor<CatalogueCreateConfirmationRecord>(
                predicate: #Predicate { $0.ownerId == ownerId }
            )
            let decoder = JSONDecoder()
            for confirmation in try disk.fetch(confirmations) {
                guard let creation = try? decoder.decode(
                    PlantCreateReceiptDTO.self, from: Data(confirmation.receiptJSON.utf8)
                ), creation.plantId == plantId else { continue }
                let operationId = confirmation.operationId
                let inputs = FetchDescriptor<CatalogueInputCheckpointRecord>(
                    predicate: #Predicate { $0.ownerId == ownerId && $0.operationId == operationId }
                )
                for input in try disk.fetch(inputs) { disk.delete(input) }
                disk.delete(confirmation)
            }
            try Task.checkCancellation()
            try disk.save()
            publishLocalOutboxChange(ownerId: ownerId)
        }
    }

    func confirmedFirstAidUndo(
        _ command: CommandEnvelopeDTO, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> UUID? {
        try authority.withBoundValid(context) {
            let disk = makeSyncContext()
            let ownerId = context.ownerId
            guard let entry = try firstAidUndoEntry(command, ownerId: ownerId, in: disk), entry.state == "voided"
            else { return nil }
            let decoder = JSONDecoder()
            let controls = try activeSyncedEntities(ownerId: ownerId, entityType: "first_aid_followups", in: disk)
            guard !controls.contains(where: { row in
                guard let link = try? decoder.decode(CatalogueFirstAidControlLink.self, from: Data(row.payloadJSON.utf8))
                else { return false }
                return link.plantId == entry.plantId && link.actionEntryId == entry.id && link.state == "active"
            }) else { return nil }
            return try confirmedCareReversal(command, entryId: entry.id, ownerId: ownerId, in: disk)
        }
    }

    func confirmedWateringUndo(
        _ command: CommandEnvelopeDTO, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> UUID? {
        try authority.withBoundValid(context) {
            let disk = makeSyncContext()
            let ownerId = context.ownerId
            guard let entry = try manualUndoEntry(command, actionCode: "water", ownerId: ownerId, in: disk),
                  entry.state == "voided" else { return nil }
            return try confirmedCareReversal(command, entryId: entry.id, ownerId: ownerId, in: disk)
        }
    }

    private func confirmedCareReversal(
        _ command: CommandEnvelopeDTO, entryId: UUID, ownerId: UUID, in disk: ModelContext
    ) throws -> UUID? {
        let decoder = JSONDecoder()
        let reversals = try activeSyncedEntities(ownerId: ownerId, entityType: "care_reversals", in: disk)
        return reversals.first(where: { row in
            guard let reversal = try? decoder.decode(CareJournalReversal.self, from: Data(row.payloadJSON.utf8))
            else { return false }
            return reversal.id == row.id && reversal.entryId == entryId && reversal.operationId == command.operationId
        })?.id
    }

    func pendingFirstAidObservation(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> FirstAidObservationCommand? {
        try authority.withBoundValid(context) {
            try firstAidObservationInOutbox(plantId: plantId, ownerId: context.ownerId)
        }
    }

    private func firstAidObservationInOutbox(plantId: UUID, ownerId: UUID) throws -> FirstAidObservationCommand? {
        guard let entry = try pendingOutboxEntries(for: ownerId).first(where: {
            $0.plantId == plantId && $0.commandName == FirstAidObservationCommand.name
        }) else { return nil }
        guard let command = FirstAidObservationCommand(envelope: entry.envelope)
        else { throw OutboxEnqueueError.operationIdentityMismatch }
        return command
    }

    func enqueueFirstAidObservation(
        _ command: FirstAidObservationCommand, now: Date, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> FirstAidObservationCommand {
        try authority.withBoundValid(context) {
            let ownerId = context.ownerId
            let plantId = command.plantId
            if let pending = try firstAidObservationInOutbox(plantId: plantId, ownerId: ownerId) {
                guard pending.controlId == command.controlId, pending.status == command.status, pending.photoId == command.photoId
                else { throw OutboxEnqueueError.operationIdentityMismatch }
                return pending
            }
            guard command.photoId == nil, try firstAidPhotoDraftInOutbox(plantId: plantId, ownerId: ownerId) == nil
            else { throw OutboxEnqueueError.operationIdentityMismatch }
            try requireActiveFirstAidTarget(plantId: plantId, controlId: command.controlId, ownerId: ownerId, now: now)
            let envelope = command.envelope
            _ = try enqueueCommand(operationId: envelope.operationId, ownerId: ownerId, plantId: plantId,
                                   commandName: envelope.commandName, payloadJSON: envelope.payloadJSON)
            return command
        }
    }

    private func requireActiveFirstAidTarget(plantId: UUID, controlId: UUID, ownerId: UUID, now: Date) throws {
        let disk = makeSyncContext()
        let decoder = JSONDecoder()
        guard let plantRow = try activeSyncRow("plants", id: plantId, ownerId: ownerId, in: disk),
                  let plant = try? decoder.decode(CatalogueCardSummary.self, from: Data(plantRow.payloadJSON.utf8)),
                  plant.id == plantId,
                  let row = try activeSyncRow("first_aid_followups", id: controlId, ownerId: ownerId, in: disk),
                  let control = try? decoder.decode(CatalogueFirstAidControl.self, from: Data(row.payloadJSON.utf8)),
                  control.id == controlId, control.plantId == plantId,
                  control.canObserve(careRevision: plant.careRevision),
                  let factRow = try activeSyncRow("care_entries", id: control.actionEntryId, ownerId: ownerId, in: disk),
                  let fact = try? decoder.decode(CatalogueCareJournalEntry.self, from: Data(factRow.payloadJSON.utf8)),
                  fact.id == control.actionEntryId, fact.plantId == plantId, fact.state == "active",
                  fact.actionCode == control.actionCode, fact.taskId == nil, fact.hasCanonicalDatesAndState
        else { throw SyncWireValidationError.invalidPage }
        if let entitlement = try canonicalEntitlement(ownerId: ownerId, in: disk) {
            guard let expiry = entitlement.verifiedAccessUntil, expiry > now
            else { throw SyncWireValidationError.invalidRequest }
        }
        guard try pendingManualCare(plantId: plantId, firstAidUndo: true, ownerId: ownerId) == nil,
              try firstAidRecordInOutbox(plantId: plantId, ownerId: ownerId) == nil
        else { throw OutboxEnqueueError.operationIdentityMismatch }
    }

    func pendingFirstAidPhotoDraft(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> FirstAidObservationPhotoDraft? {
        try authority.withBoundValid(context) {
            try firstAidPhotoDraftInOutbox(plantId: plantId, ownerId: context.ownerId)
        }
    }

    private func firstAidPhotoDraftInOutbox(plantId: UUID, ownerId: UUID) throws -> FirstAidObservationPhotoDraft? {
        guard let row = try pendingOutboxEntries(for: ownerId).first(where: {
            $0.plantId == plantId && $0.commandName == FirstAidObservationPhotoDraft.name
        }) else { return nil }
        guard let draft = FirstAidObservationPhotoDraft(envelope: row.envelope)
        else { throw OutboxEnqueueError.operationIdentityMismatch }
        return draft
    }

    func enqueueFirstAidPhotoDraft(
        _ draft: FirstAidObservationPhotoDraft, jpeg: Data, now: Date,
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> FirstAidObservationPhotoDraft {
        try authority.withBoundValid(context) {
            let ownerId = context.ownerId
            guard !jpeg.isEmpty, jpeg.count <= AnalysisPhotoInput.maxCloudBytes,
                  try firstAidObservationInOutbox(plantId: draft.plantId, ownerId: ownerId) == nil
            else { throw OutboxEnqueueError.operationIdentityMismatch }
            if let existing = try firstAidPhotoDraftInOutbox(plantId: draft.plantId, ownerId: ownerId) {
                let record = try firstAidPhotoOutboxRecord(existing.envelope, ownerId: ownerId, in: makeSyncContext())
                guard existing.controlId == draft.controlId, existing.status == draft.status, record.observationJPEG == jpeg
                else { throw OutboxEnqueueError.operationIdentityMismatch }
                return existing
            }
            try requireActiveFirstAidTarget(plantId: draft.plantId, controlId: draft.controlId, ownerId: ownerId, now: now)
            let envelope = draft.envelope
            _ = try enqueueCommand(operationId: envelope.operationId, ownerId: ownerId, plantId: draft.plantId,
                                   commandName: envelope.commandName, payloadJSON: envelope.payloadJSON, observationJPEG: jpeg)
            return draft
        }
    }

    private func firstAidPhotoOutboxRecord(
        _ envelope: CommandEnvelopeDTO, ownerId: UUID, in disk: ModelContext
    ) throws -> LocalOutboxRecord {
        let operationId = envelope.operationId
        let descriptor = FetchDescriptor<LocalOutboxRecord>(predicate: #Predicate { $0.operationId == operationId })
        guard let row = try disk.fetch(descriptor).first, row.ownerId == ownerId, row.plantId == envelope.plantId,
              row.commandName == envelope.commandName, row.payloadJSON == envelope.payloadJSON
        else { throw OutboxEnqueueError.operationIdentityMismatch }
        return row
    }

    func firstAidPhotoUpload(
        _ draft: FirstAidObservationPhotoDraft, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> (jpeg: Data, assetId: UUID?) {
        try authority.withBoundValid(context) {
            let record = try firstAidPhotoOutboxRecord(draft.envelope, ownerId: context.ownerId, in: makeSyncContext())
            guard let jpeg = record.observationJPEG else { throw SyncWireValidationError.invalidRequest }
            return (jpeg, record.observationPhotoAssetId)
        }
    }

    func checkpointFirstAidPhoto(
        _ assetId: UUID, for draft: FirstAidObservationPhotoDraft, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws {
        try authority.withBoundValid(context) {
            let disk = makeSyncContext()
            let record = try firstAidPhotoOutboxRecord(draft.envelope, ownerId: context.ownerId, in: disk)
            guard record.observationPhotoAssetId == nil || record.observationPhotoAssetId == assetId
            else { throw OutboxEnqueueError.operationIdentityMismatch }
            record.observationPhotoAssetId = assetId
            try disk.save()
        }
    }

    func finalizeFirstAidPhoto(
        _ assetId: UUID, for draft: FirstAidObservationPhotoDraft, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> FirstAidObservationCommand {
        try authority.withBoundValid(context) {
            let disk = makeSyncContext()
            let record = try firstAidPhotoOutboxRecord(draft.envelope, ownerId: context.ownerId, in: disk)
            guard record.observationPhotoAssetId == assetId else { throw OutboxEnqueueError.operationIdentityMismatch }
            let command = try FirstAidObservationCommand.make(
                plantId: draft.plantId, controlId: draft.controlId, status: draft.status,
                photoId: assetId, operationId: draft.envelope.operationId
            )
            record.commandName = command.envelope.commandName
            record.payloadJSON = command.envelope.payloadJSON
            // Keep the bytes until the observe receipt is acknowledged. Cleanup can win before attach.
            record.observationPhotoAssetId = nil
            record.lastError = nil
            try disk.save()
            publishLocalOutboxChange(ownerId: record.ownerId)
            return command
        }
    }

    func discardFirstAidPhotoDraft(
        _ draft: FirstAidObservationPhotoDraft, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws {
        try authority.withBoundValid(context) {
            let disk = makeSyncContext()
            let record = try firstAidPhotoOutboxRecord(draft.envelope, ownerId: context.ownerId, in: disk)
            let ownerId = record.ownerId
            disk.delete(record)
            try disk.save()
            publishLocalOutboxChange(ownerId: ownerId)
        }
    }

    func renewFirstAidPhotoDraft(
        _ draft: FirstAidObservationPhotoDraft, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> FirstAidObservationPhotoDraft {
        let replacement = try FirstAidObservationPhotoDraft.make(
            plantId: draft.plantId, controlId: draft.controlId, status: draft.status,
            operationId: draft.envelope.operationId
        )
        try replaceUnavailableFirstAidPhoto(draft.envelope, with: replacement, context: context, authority: authority)
        return replacement
    }

    func canReplaceRejectedFirstAidPhoto(
        _ command: FirstAidObservationCommand, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> Bool {
        try authority.withBoundValid(context) {
            let record = try firstAidPhotoOutboxRecord(command.envelope, ownerId: context.ownerId, in: makeSyncContext())
            guard record.observationJPEG != nil else { return false }
            do {
                try requireActiveFirstAidTarget(
                    plantId: command.plantId, controlId: command.controlId, ownerId: context.ownerId, now: Date()
                )
                return true
            } catch SyncWireValidationError.invalidPage {
                return false
            } catch SyncWireValidationError.invalidRequest {
                return false
            } catch OutboxEnqueueError.operationIdentityMismatch {
                return false
            }
        }
    }

    func replaceRejectedFirstAidPhoto(
        _ command: FirstAidObservationCommand, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws {
        let replacement = try FirstAidObservationPhotoDraft.make(
            plantId: command.plantId, controlId: command.controlId, status: command.status
        )
        try replaceUnavailableFirstAidPhoto(command.envelope, with: replacement, context: context, authority: authority)
    }

    private func replaceUnavailableFirstAidPhoto(
        _ envelope: CommandEnvelopeDTO, with draft: FirstAidObservationPhotoDraft,
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws {
        try authority.withBoundValid(context) {
            let disk = makeSyncContext()
            let record = try firstAidPhotoOutboxRecord(envelope, ownerId: context.ownerId, in: disk)
            guard record.observationJPEG != nil else { throw SyncWireValidationError.invalidRequest }
            try requireActiveFirstAidTarget(
                plantId: draft.plantId, controlId: draft.controlId, ownerId: context.ownerId, now: Date()
            )
            let pendingChanged = record.operationId != draft.envelope.operationId
                || record.commandName != draft.envelope.commandName
                || record.payloadJSON != draft.envelope.payloadJSON
                || record.retryCount != 0 || record.lastError != nil
            record.operationId = draft.envelope.operationId
            record.commandName = draft.envelope.commandName
            record.payloadJSON = draft.envelope.payloadJSON
            record.observationPhotoAssetId = nil
            record.retryCount = 0
            record.lastError = nil
            try Task.checkCancellation()
            try disk.save()
            if pendingChanged { publishLocalOutboxChange(ownerId: record.ownerId) }
        }
    }

    func confirmedFirstAidObservation(
        _ command: FirstAidObservationCommand, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> UUID? {
        try authority.withBoundValid(context) {
            let disk = makeSyncContext()
            let decoder = JSONDecoder()
            guard let row = try activeSyncRow("first_aid_followups", id: command.controlId, ownerId: context.ownerId, in: disk),
                  let link = try? decoder.decode(CatalogueFirstAidControlLink.self, from: Data(row.payloadJSON.utf8)),
                  link.id == command.controlId, link.plantId == command.plantId,
                  link.actionCode == "check_soil", link.state == "completed" else { return nil }
            if let photoId = command.photoId {
                guard let photoRow = try activeSyncRow("photo_assets", id: photoId, ownerId: context.ownerId, in: disk),
                      let photo = try? decoder.decode(ObservationPhotoAsset.self, from: Data(photoRow.payloadJSON.utf8)),
                      photo.id == photoId, photo.plantId == command.plantId, photo.state == "ready", photo.purpose == "diary"
                else { return nil }
            }
            let rows = try activeSyncedEntities(ownerId: context.ownerId, entityType: "care_observations", in: disk)
            return rows.first(where: { row in
                guard let observation = try? decoder.decode(CatalogueFirstAidObservation.self, from: Data(row.payloadJSON.utf8))
                else { return false }
                return observation.id == row.id && observation.plantId == command.plantId
                    && observation.controlId == command.controlId && observation.operationId == command.envelope.operationId
                    && observation.status == command.status && observation.photoId == command.photoId && observation.isStandalone
            })?.id
        }
    }

    private struct ObservationPhotoAsset: Decodable {
        let id: UUID
        let plantId: UUID
        let state: String
        let purpose: String

        enum CodingKeys: String, CodingKey {
            case id, state, purpose
            case plantId = "plant_id"
        }
    }

    private struct CareJournalReversal: Decodable {
        let id: UUID
        let entryId: UUID
        let operationId: UUID

        enum CodingKeys: String, CodingKey {
            case id
            case entryId = "entry_id"
            case operationId = "operation_id"
        }
    }

    /// One session-ordered disk operation. Capacity is advisory; durable replay wins.
    /// No transport, recapture, watermark publication, or managed models escape here.
    func catalogueCreateJournal(
        _ envelope: CommandEnvelopeDTO, mode: CatalogueCreateJournalMode,
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CatalogueCreateJournalState {
        try authority.withBoundValid(context) {
            try CatalogueCreateWire.validate(envelope)
            let ownerId = context.ownerId
            let operationId = envelope.operationId
            let disk = makeSyncContext()
            do {
                let confirmations = FetchDescriptor<CatalogueCreateConfirmationRecord>(
                    predicate: #Predicate { $0.ownerId == ownerId && $0.operationId == operationId }
                )
                let prior = try disk.fetch(confirmations).first
                if let prior {
                    guard prior.payloadJSON.utf8.elementsEqual(envelope.payloadJSON.utf8) else {
                        throw OutboxEnqueueError.operationIdentityMismatch
                    }
                }
                // Global operation identity must also hold when a receipt already exists.
                let commands = FetchDescriptor<LocalOutboxRecord>(
                    predicate: #Predicate { $0.operationId == operationId }
                )
                let queued = try disk.fetch(commands).first
                if let queued {
                    guard queued.ownerId == ownerId, queued.plantId == envelope.plantId,
                          queued.commandName.utf8.elementsEqual(envelope.commandName.utf8),
                          queued.payloadJSON.utf8.elementsEqual(envelope.payloadJSON.utf8) else {
                        throw OutboxEnqueueError.operationIdentityMismatch
                    }
                }

                let result: CatalogueCreateJournalState
                if let prior {
                    result = .confirmed(CatalogueCreateConfirmationSnapshot(
                        ownerId: prior.ownerId, operationId: prior.operationId,
                        payloadJSON: prior.payloadJSON,
                        receipt: try JSONDecoder().decode(
                            PlantCreateReceiptDTO.self, from: Data(prior.receiptJSON.utf8)
                        )
                    ))
                } else if let queued {
                    result = .pending(journalSnapshot(queued))
                } else {
                    switch mode {
                    case .checkOnly:
                        result = .absent
                    case .enqueue(canCreate: false):
                        result = .collectionLimitNotEnqueued
                    case .enqueue(canCreate: true):
                        var sequence = FetchDescriptor<LocalOutboxRecord>(
                            sortBy: [SortDescriptor(\.sequenceNumber, order: .reverse)]
                        )
                        sequence.fetchLimit = 1
                        let next = (try disk.fetch(sequence).first?.sequenceNumber ?? 0) + 1
                        let record = LocalOutboxRecord(
                            operationId: operationId, ownerId: ownerId, plantId: envelope.plantId,
                            commandName: envelope.commandName, payloadJSON: envelope.payloadJSON,
                            sequenceNumber: next
                        )
                        disk.insert(record)
                        try Task.checkCancellation()
                        try disk.save()
                        publishLocalOutboxChange(ownerId: record.ownerId)
                        return .pending(journalSnapshot(record))
                    }
                }
                try Task.checkCancellation()
                return result
            } catch {
                disk.rollback()
                throw error
            }
        }
    }

    // All catalogue input contexts share this ordering, including distinct API authorities.
    private static let catalogueInputLock = NSLock()

    /// The original bound lease is required even for anonymous local input caching.
    /// New unsent edits require an explicitly new flow and operation.
    func checkpointCatalogueInput(
        _ input: CatalogueInput, flowId: UUID, operationId: UUID,
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CatalogueInputCheckpointSnapshot {
        try authority.withBoundValid(context) {
            Self.catalogueInputLock.lock()
            defer { Self.catalogueInputLock.unlock() }
            let disk = makeSyncContext()
            do {
                let envelope = try input.makeEnvelope(operationId: operationId)
                let ownerId = context.ownerId
                let descriptor = FetchDescriptor<CatalogueInputCheckpointRecord>(
                    predicate: #Predicate { $0.ownerId == ownerId && $0.flowId == flowId }
                )
                if let prior = try disk.fetch(descriptor).first {
                    let original = try catalogueInputSnapshot(prior)
                    guard original.operationId == operationId,
                          original.envelope.payloadJSON.utf8.elementsEqual(envelope.payloadJSON.utf8) else {
                        throw CatalogueInputCheckpointError.flowIdentityMismatch
                    }
                    try validateCatalogueInputIdentity(envelope, ownerId: ownerId, disk: disk)
                    try Task.checkCancellation()
                    return original
                }
                try validateCatalogueInputIdentity(envelope, ownerId: ownerId, disk: disk)
                let record = CatalogueInputCheckpointRecord(
                    ownerId: ownerId, flowId: flowId, operationId: operationId,
                    payloadJSON: envelope.payloadJSON, createdAt: Date()
                )
                disk.insert(record)
                let snapshot = try catalogueInputSnapshot(record)
                try Task.checkCancellation()
                try disk.save()
                return snapshot
            } catch {
                disk.rollback()
                throw error
            }
        }
    }

    func catalogueInputCheckpoint(
        flowId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CatalogueInputCheckpointSnapshot? {
        try authority.withBoundValid(context) {
            Self.catalogueInputLock.lock()
            defer { Self.catalogueInputLock.unlock() }
            let disk = makeSyncContext()
            do {
                let ownerId = context.ownerId
                let descriptor = FetchDescriptor<CatalogueInputCheckpointRecord>(
                    predicate: #Predicate { $0.ownerId == ownerId && $0.flowId == flowId }
                )
                guard let record = try disk.fetch(descriptor).first else {
                    try Task.checkCancellation()
                    return nil
                }
                let snapshot = try catalogueInputSnapshot(record)
                try validateCatalogueInputIdentity(snapshot.envelope, ownerId: ownerId, disk: disk)
                try Task.checkCancellation()
                return snapshot
            } catch {
                disk.rollback()
                throw error
            }
        }
    }

    private func catalogueInputSnapshot(
        _ record: CatalogueInputCheckpointRecord
    ) throws -> CatalogueInputCheckpointSnapshot {
        guard record.compositeKey ==
                "\(record.ownerId.uuidString.lowercased()):\(record.flowId.uuidString.lowercased())" else {
            throw CatalogueInputCheckpointError.invalidStoredInput
        }
        let envelope = CommandEnvelopeDTO(operationId: record.operationId, commandName: "plant.create",
                                          payloadJSON: record.payloadJSON)
        _ = try CatalogueInput.fromCheckpoint(envelope)
        return CatalogueInputCheckpointSnapshot(
            ownerId: record.ownerId, flowId: record.flowId, envelope: envelope, createdAt: record.createdAt
        )
    }

    /// Match the accepted journal's global queue identity and own confirmation bytes.
    /// No foreign record or server receipt escapes this check.
    private func validateCatalogueInputIdentity(
        _ envelope: CommandEnvelopeDTO, ownerId: UUID, disk: ModelContext
    ) throws {
        let operationId = envelope.operationId
        let commands = FetchDescriptor<LocalOutboxRecord>(
            predicate: #Predicate { $0.operationId == operationId }
        )
        if let queued = try disk.fetch(commands).first {
            guard queued.ownerId == ownerId, queued.plantId == envelope.plantId,
                  queued.commandName.utf8.elementsEqual(envelope.commandName.utf8),
                  queued.payloadJSON.utf8.elementsEqual(envelope.payloadJSON.utf8) else {
                throw OutboxEnqueueError.operationIdentityMismatch
            }
        }
        let confirmations = FetchDescriptor<CatalogueCreateConfirmationRecord>(
            predicate: #Predicate { $0.ownerId == ownerId && $0.operationId == operationId }
        )
        if let prior = try disk.fetch(confirmations).first {
            guard prior.payloadJSON.utf8.elementsEqual(envelope.payloadJSON.utf8) else {
                throw OutboxEnqueueError.operationIdentityMismatch
            }
        }
    }

    private func journalSnapshot(_ record: LocalOutboxRecord) -> OutboxEntrySnapshot {
        OutboxEntrySnapshot(
            operationId: record.operationId, ownerId: record.ownerId, plantId: record.plantId,
            commandName: record.commandName, payloadJSON: record.payloadJSON,
            sequenceNumber: record.sequenceNumber, retryCount: record.retryCount,
            lastError: record.lastError, createdAt: record.createdAt
        )
    }

    public func pendingOutboxEntries(for ownerId: UUID) throws -> [OutboxEntrySnapshot] {
        try pendingOutboxEntries(for: ownerId, in: makeSyncContext())
    }

    private func pendingOutboxEntries(for ownerId: UUID, in disk: ModelContext) throws -> [OutboxEntrySnapshot] {
        let descriptor = FetchDescriptor<LocalOutboxRecord>(
            predicate: #Predicate { $0.ownerId == ownerId },
            sortBy: [SortDescriptor(\.sequenceNumber, order: .forward)]
        )
        return try disk.fetch(descriptor).map { journalSnapshot($0) }
    }

    /// Reads committed storage, including immediately after an isolated acknowledgement.
    public func catalogueCreateConfirmation(
        ownerId: UUID, operationId: UUID
    ) throws -> CatalogueCreateConfirmationSnapshot? {
        let context = makeSyncContext()
        let descriptor = FetchDescriptor<CatalogueCreateConfirmationRecord>(
            predicate: #Predicate { $0.ownerId == ownerId && $0.operationId == operationId }
        )
        guard let record = try context.fetch(descriptor).first else { return nil }
        return CatalogueCreateConfirmationSnapshot(
            ownerId: record.ownerId, operationId: record.operationId, payloadJSON: record.payloadJSON,
            receipt: try JSONDecoder().decode(PlantCreateReceiptDTO.self, from: Data(record.receiptJSON.utf8))
        )
    }

    /// Receipt insertion and deletion of the original command share one disk save.
    /// A receipt watermark is deliberately never published as a sync checkpoint.
    func acknowledgeCatalogueCreate(
        _ envelope: CommandEnvelopeDTO, receipt: PlantCreateReceiptDTO,
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws {
        try authority.withValid(context) {
            guard context.session != nil else { throw SyncWireValidationError.invalidSession }
            guard envelope.commandName == "plant.create", envelope.plantId == nil else {
                throw CatalogueCreateAcknowledgementError.invalidCommand
            }
            let ownerId = context.ownerId
            let operationId = envelope.operationId
            let modelContext = makeSyncContext()
            do {
                let confirmations = FetchDescriptor<CatalogueCreateConfirmationRecord>(
                    predicate: #Predicate { $0.ownerId == ownerId && $0.operationId == operationId }
                )
                let prior = try modelContext.fetch(confirmations).first
                if let prior {
                    let originalReceipt = try JSONDecoder().decode(
                        PlantCreateReceiptDTO.self, from: Data(prior.receiptJSON.utf8)
                    )
                    guard prior.payloadJSON.utf8.elementsEqual(envelope.payloadJSON.utf8),
                          originalReceipt == receipt,
                          originalReceipt.contextState.utf8.elementsEqual(receipt.contextState.utf8),
                          originalReceipt.nextAvailableStep.utf8.elementsEqual(receipt.nextAvailableStep.utf8),
                          originalReceipt.planAvailability.utf8.elementsEqual(receipt.planAvailability.utf8),
                          originalReceipt.paidAction.map({ Data($0.utf8) }) ==
                            receipt.paidAction.map({ Data($0.utf8) }) else {
                        throw CatalogueCreateAcknowledgementError.confirmationConflict
                    }
                }

                let commands = FetchDescriptor<LocalOutboxRecord>(
                    predicate: #Predicate { $0.ownerId == ownerId && $0.operationId == operationId }
                )
                guard let queued = try modelContext.fetch(commands).first else {
                    // A missing command is safe only when durable evidence proves exact replay.
                    guard prior != nil else {
                        throw CatalogueCreateAcknowledgementError.missingQueuedOperation
                    }
                    return
                }
                guard queued.ownerId == ownerId else { throw SyncWireValidationError.invalidSession }
                guard queued.commandName == envelope.commandName,
                      queued.plantId == envelope.plantId,
                      queued.payloadJSON.utf8.elementsEqual(envelope.payloadJSON.utf8) else {
                    throw CatalogueCreateAcknowledgementError.queuedCommandMismatch
                }
                if prior == nil {
                    let receiptJSON = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
                    modelContext.insert(CatalogueCreateConfirmationRecord(
                        ownerId: ownerId, operationId: operationId,
                        payloadJSON: envelope.payloadJSON, receiptJSON: receiptJSON
                    ))
                }
                modelContext.delete(queued)
                try Task.checkCancellation()
                try modelContext.save()
                publishLocalOutboxChange(ownerId: ownerId)
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    public func markOutboxCommitted(operationId: UUID) throws {
        let modelContext = makeSyncContext()
        let descriptor = FetchDescriptor<LocalOutboxRecord>(
            predicate: #Predicate { $0.operationId == operationId }
        )
        let records = try modelContext.fetch(descriptor)
        guard !records.isEmpty else { return }
        let owners = Set(records.map(\.ownerId))
        for record in records {
            modelContext.delete(record)
        }
        try modelContext.save()
        for ownerId in owners { publishLocalOutboxChange(ownerId: ownerId) }
    }

    public func recordOutboxFailure(operationId: UUID, errorMessage: String) throws {
        let modelContext = makeSyncContext()
        let descriptor = FetchDescriptor<LocalOutboxRecord>(
            predicate: #Predicate { $0.operationId == operationId }
        )
        if let record = try modelContext.fetch(descriptor).first {
            record.retryCount += 1
            record.lastError = errorMessage
            try modelContext.save()
            publishLocalOutboxChange(ownerId: record.ownerId)
        }
    }

    // MARK: GuestDraftCache & AddFlowState Persistence (survives > 24h server TTL)

    public func saveGuestDraft(_ snapshot: GuestDraftCacheSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let conditionsData = try encoder.encode(snapshot.flowState.conditions)
        let conditionsJSON = String(decoding: conditionsData, as: UTF8.self)

        let analysisJSON = try snapshot.preliminaryAnalysis.map {
            String(decoding: try encoder.encode($0), as: UTF8.self)
        }
        let receiptJSON = try snapshot.analysisReceipt.map {
            String(decoding: try encoder.encode($0), as: UTF8.self)
        }
        let overridesJSON = try snapshot.overrides.map {
            String(decoding: try encoder.encode($0), as: UTF8.self)
        }

        let targetId = snapshot.draftId
        let descriptor = FetchDescriptor<GuestDraftCacheRecord>(
            predicate: #Predicate { $0.draftId == targetId }
        )

        if let existing = try modelContext.fetch(descriptor).first {
            existing.flowId = snapshot.flowState.flowId
            existing.intentRaw = snapshot.flowState.intent.rawValue
            existing.addMethodRaw = snapshot.flowState.addMethod?.rawValue
            existing.currentStepRaw = snapshot.flowState.currentStep.rawValue
            existing.photoLocalPath = snapshot.flowState.photoLocalIdentifier
            existing.confirmedPlantId = snapshot.flowState.confirmedPlantId
            existing.confirmedTaxonId = snapshot.flowState.confirmedTaxonId
            existing.confirmedDisplayName = snapshot.flowState.confirmedDisplayName
            existing.conditionsJSON = conditionsJSON
            existing.resultModeRaw = snapshot.flowState.resultMode?.rawValue
            existing.preliminaryAnalysisJSON = analysisJSON
            existing.analysisReceiptJSON = receiptJSON
            existing.overridesJSON = overridesJSON
            existing.serverExpiresAt = snapshot.serverExpiresAt
            existing.isCompleteForFallback = snapshot.isCompleteForFallback
            existing.updatedAt = Date()
        } else {
            let record = GuestDraftCacheRecord(
                draftId: snapshot.draftId,
                flowId: snapshot.flowState.flowId,
                intentRaw: snapshot.flowState.intent.rawValue,
                addMethodRaw: snapshot.flowState.addMethod?.rawValue,
                currentStepRaw: snapshot.flowState.currentStep.rawValue,
                photoLocalPath: snapshot.flowState.photoLocalIdentifier,
                confirmedPlantId: snapshot.flowState.confirmedPlantId,
                confirmedTaxonId: snapshot.flowState.confirmedTaxonId,
                confirmedDisplayName: snapshot.flowState.confirmedDisplayName,
                conditionsJSON: conditionsJSON,
                resultModeRaw: snapshot.flowState.resultMode?.rawValue,
                preliminaryAnalysisJSON: analysisJSON,
                analysisReceiptJSON: receiptJSON,
                overridesJSON: overridesJSON,
                serverExpiresAt: snapshot.serverExpiresAt,
                isCompleteForFallback: snapshot.isCompleteForFallback
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func loadGuestDraft(draftId: UUID) throws -> GuestDraftCacheSnapshot? {
        let descriptor = FetchDescriptor<GuestDraftCacheRecord>(
            predicate: #Predicate { $0.draftId == draftId }
        )
        guard let record = try modelContext.fetch(descriptor).first else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let conditions = (try? decoder.decode(
            CareConditionsInput.self,
            from: Data(record.conditionsJSON.utf8)
        )) ?? CareConditionsInput()

        let analysis = record.preliminaryAnalysisJSON.flatMap {
            try? decoder.decode(PreliminaryAnalysis.self, from: Data($0.utf8))
        }
        let receipt = record.analysisReceiptJSON.flatMap {
            try? decoder.decode(AnalysisReceiptDTO.self, from: Data($0.utf8))
        }
        let overrides = record.overridesJSON.flatMap {
            try? decoder.decode(ClaimOverridesDTO.self, from: Data($0.utf8))
        }

        let flowState = AddFlowState(
            flowId: record.flowId,
            intent: AddIntent(rawValue: record.intentRaw) ?? .problem,
            addMethod: record.addMethodRaw.flatMap(AddMethod.init(rawValue:)),
            currentStep: AddFlowStep(rawValue: record.currentStepRaw) ?? .selectIntent,
            photoLocalIdentifier: record.photoLocalPath,
            confirmedPlantId: record.confirmedPlantId,
            confirmedTaxonId: record.confirmedTaxonId,
            confirmedDisplayName: record.confirmedDisplayName,
            conditions: conditions,
            resultMode: record.resultModeRaw.flatMap(AnalysisMode.init(rawValue:)),
            draftId: record.draftId,
            updatedAt: record.updatedAt
        )

        return GuestDraftCacheSnapshot(
            draftId: record.draftId,
            flowState: flowState,
            preliminaryAnalysis: analysis,
            analysisReceipt: receipt,
            overrides: overrides,
            serverExpiresAt: record.serverExpiresAt,
            isCompleteForFallback: record.isCompleteForFallback
        )
    }

    public func removeGuestDraft(draftId: UUID) throws {
        let descriptor = FetchDescriptor<GuestDraftCacheRecord>(
            predicate: #Predicate { $0.draftId == draftId }
        )
        for record in try modelContext.fetch(descriptor) {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    // MARK: Synced Entity & Checkpoint Operations

    /// Sync and outbox models never escape an operation's context. A failed save can leave
    /// registered SwiftData models changed even after rollback, so both writers
    /// and readers start from committed storage rather than those cached models.
    private func makeSyncContext() -> ModelContext {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        return context
    }

    public func applySyncedItems(_ items: [SyncItemDTO], ownerId: UUID) throws {
        let modelContext = makeSyncContext()
        do {
            try stageSyncedItems(items, ownerId: ownerId, in: modelContext)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func stageSyncedItems(
        _ items: [SyncItemDTO], ownerId: UUID, rawTimes: [String: String] = [:],
        in modelContext: ModelContext
    ) throws {
        for item in items {
            guard item.entityType != Self.careOverviewEntityType,
                  item.entityType != Self.careReminderReceiptEntityType
            else { throw SyncWireValidationError.invalidPage }
            let key = "\(ownerId.uuidString.lowercased()):\(item.entityType):\(item.id.uuidString.lowercased())"
            let descriptor = FetchDescriptor<SyncedEntityRecord>(
                predicate: #Predicate { $0.compositeKey == key }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                let raw = rawTimes[key]
                let isNewer: Bool
                if let raw, let old = existing.updatedAtRaw,
                   let incoming = SQLTimestamp.microseconds(from: raw),
                   let previous = SQLTimestamp.microseconds(from: old) {
                    isNewer = incoming >= previous
                } else {
                    isNewer = item.updatedAt >= existing.updatedAt
                }
                if isNewer {
                    existing.updatedAtRaw = raw
                    existing.updatedAt = item.updatedAt
                    existing.deletedAt = item.deletedAt
                    existing.payloadJSON = item.payloadJSON
                }
            } else {
                let record = SyncedEntityRecord(
                    ownerId: ownerId,
                    entityType: item.entityType,
                    entityId: item.id,
                    updatedAt: item.updatedAt,
                    deletedAt: item.deletedAt,
                    payloadJSON: item.payloadJSON
                )
                record.updatedAtRaw = rawTimes[key]
                modelContext.insert(record)
            }
        }
    }

    // Exact local-only identity. Corrupt bytes at this identity survive cache eviction.
    private static let careReminderReceiptEntityType = "local_care_reminder_receipts"

    private func careReminderReceiptKey(_ ownerId: UUID) -> String {
        "\(ownerId.uuidString.lowercased()):\(Self.careReminderReceiptEntityType):\(ownerId.uuidString.lowercased())"
    }

    private func isCareReminderReceiptRow(_ row: SyncedEntityRecord, ownerId: UUID) -> Bool {
        row.ownerId == ownerId && row.entityId == ownerId
            && row.entityType == Self.careReminderReceiptEntityType
            && row.compositeKey == careReminderReceiptKey(ownerId)
    }

    private func careReminderReceiptRow(ownerId: UUID, in disk: ModelContext) throws -> SyncedEntityRecord? {
        let key = careReminderReceiptKey(ownerId)
        let rows = try disk.fetch(FetchDescriptor<SyncedEntityRecord>(predicate: #Predicate {
            $0.compositeKey == key
        }))
        guard rows.count <= 1 else { throw CareReminderReceiptStoreError.invalidMetadata }
        return rows.first
    }

    private func careReminderReceiptPayload(
        _ row: SyncedEntityRecord, ownerId: UUID
    ) throws -> CareReminderReceiptPayload {
        guard isCareReminderReceiptRow(row, ownerId: ownerId), row.deletedAt == nil else {
            throw CareReminderReceiptStoreError.invalidMetadata
        }
        do {
            let payload = try JSONDecoder().decode(CareReminderReceiptPayload.self, from: Data(row.payloadJSON.utf8))
            guard payload.version == 1 else { throw CareReminderReceiptStoreError.invalidMetadata }
            try payload.receipts.validate(expectedOwner: ownerId)
            return payload
        } catch {
            throw CareReminderReceiptStoreError.invalidMetadata
        }
    }

    private func encodeCareReminderReceipts(
        _ receipts: CareReminderReceipts, revision: UUID, ownerId: UUID
    ) throws -> String {
        try receipts.validate(expectedOwner: ownerId)
        return String(decoding: try JSONEncoder().encode(CareReminderReceiptPayload(
            version: 1, revision: revision, receipts: receipts)), as: UTF8.self)
    }

    func readCareReminderReceipts(
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CareReminderReceiptSnapshot? {
        try authority.withPermanentBoundValid(context) {
            let disk = makeSyncContext()
            guard let row = try careReminderReceiptRow(ownerId: context.ownerId, in: disk) else { return nil }
            let payload = try careReminderReceiptPayload(row, ownerId: context.ownerId)
            return CareReminderReceiptSnapshot(lease: context, revision: payload.revision, receipts: payload.receipts)
        }
    }

    /// Reserve the empty ledger before any future awaited adapter work. Never infer empty from corruption.
    func beginCareReminderReceipts(
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CareReminderReceiptSnapshot {
        try authority.withPermanentBoundValid(context) {
            let disk = makeSyncContext()
            do {
                if let row = try careReminderReceiptRow(ownerId: context.ownerId, in: disk) {
                    let payload = try careReminderReceiptPayload(row, ownerId: context.ownerId)
                    return CareReminderReceiptSnapshot(lease: context, revision: payload.revision, receipts: payload.receipts)
                }
                let receipts = CareReminderReceipts(ownerId: context.ownerId)
                let revision = UUID()
                disk.insert(SyncedEntityRecord(
                    ownerId: context.ownerId, entityType: Self.careReminderReceiptEntityType,
                    entityId: context.ownerId, updatedAt: Date(),
                    payloadJSON: try encodeCareReminderReceipts(receipts, revision: revision, ownerId: context.ownerId)))
                try Task.checkCancellation()
                try disk.save()
                return CareReminderReceiptSnapshot(lease: context, revision: revision, receipts: receipts)
            } catch {
                disk.rollback()
                throw error
            }
        }
    }

    /// CAS and replacement validation share one fresh disk context and the original permanent lease.
    /// A save acknowledges metadata only; PREPARED must precede a future adapter add, ACK follows it.
    func commitCareReminderReceipts(
        _ receipts: CareReminderReceipts, replacing original: CareReminderReceiptSnapshot,
        authority: SyncSessionAuthority
    ) throws -> CareReminderReceiptSnapshot {
        try authority.withPermanentBoundValid(original.lease) {
            let ownerId = original.lease.ownerId
            let disk = makeSyncContext()
            do {
                guard let row = try careReminderReceiptRow(ownerId: ownerId, in: disk) else {
                    throw CareReminderReceiptStoreError.superseded
                }
                let current = try careReminderReceiptPayload(row, ownerId: ownerId)
                guard current.revision == original.revision else { throw CareReminderReceiptStoreError.superseded }
                try receipts.validate(expectedOwner: ownerId)
                try receipts.validateReplacement(of: current.receipts)
                guard receipts != current.receipts else {
                    return CareReminderReceiptSnapshot(lease: original.lease, revision: current.revision,
                                                       receipts: current.receipts)
                }
                let revision = UUID()
                row.payloadJSON = try encodeCareReminderReceipts(receipts, revision: revision, ownerId: ownerId)
                row.updatedAt = Date()
                try Task.checkCancellation()
                try disk.save()
                return CareReminderReceiptSnapshot(lease: original.lease, revision: revision, receipts: receipts)
            } catch {
                disk.rollback()
                throw error
            }
        }
    }

    /// Trusted erase-only account-removal primitive; no read/write/arm authority is granted.
    /// R3 owns cleanup integration. Logout, opt-out and cache reset must retain these receipts.
    func purgeCareReminderReceiptMetadata(ownerId: UUID) throws {
        let disk = makeSyncContext()
        do {
            let key = careReminderReceiptKey(ownerId)
            let type = Self.careReminderReceiptEntityType
            let rows = try disk.fetch(FetchDescriptor<SyncedEntityRecord>(predicate: #Predicate {
                $0.ownerId == ownerId && ($0.entityType == type || $0.compositeKey == key)
            }))
            for row in rows { disk.delete(row) }
            try Task.checkCancellation()
            try disk.save()
        } catch {
            disk.rollback()
            throw error
        }
    }

    // This reserved row is local only and never belongs to the server sync vocabulary.
    private static let careOverviewEntityType = "local_care_overview"

    private func careOverviewKey(_ ownerId: UUID) -> String {
        "\(ownerId.uuidString.lowercased()):\(Self.careOverviewEntityType):\(ownerId.uuidString.lowercased())"
    }

    private func careOverviewRow(ownerId: UUID, in disk: ModelContext) throws -> SyncedEntityRecord? {
        let key = careOverviewKey(ownerId)
        return try disk.fetch(FetchDescriptor<SyncedEntityRecord>(predicate: #Predicate {
            $0.compositeKey == key
        })).first
    }

    private func careOverviewPayload(_ row: SyncedEntityRecord?, ownerId: UUID) -> CareOverviewCachePayload? {
        guard let row, row.ownerId == ownerId, row.entityId == ownerId,
              row.entityType == Self.careOverviewEntityType, row.deletedAt == nil,
              let payload = try? JSONDecoder().decode(CareOverviewCachePayload.self, from: Data(row.payloadJSON.utf8))
        else { return nil }
        do {
            _ = try payload.validatedSnapshot(ownerId: ownerId)
            return payload
        } catch { return nil }
    }

    private func stageCareOverview(
        _ payload: CareOverviewCachePayload, row: SyncedEntityRecord?,
        ownerId: UUID, in disk: ModelContext
    ) throws {
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        if let row {
            row.ownerId = ownerId
            row.entityId = ownerId
            row.entityType = Self.careOverviewEntityType
            row.deletedAt = nil
            row.updatedAtRaw = nil
            row.payloadJSON = json
        } else {
            disk.insert(SyncedEntityRecord(
                ownerId: ownerId, entityType: Self.careOverviewEntityType, entityId: ownerId,
                updatedAt: Date(), payloadJSON: json
            ))
        }
    }

    /// Called within the canonical rows/checkpoint transaction, including empty windows.
    private func rotateCareOverviewGeneration(ownerId: UUID, in disk: ModelContext) throws {
        guard let row = try careOverviewRow(ownerId: ownerId, in: disk) else { return }
        var payload = careOverviewPayload(row, ownerId: ownerId) ?? CareOverviewCachePayload()
        payload.canonicalGeneration = UUID()
        payload.pendingRequestId = nil
        payload.pendingRequestLocale = nil
        try stageCareOverview(payload, row: row, ownerId: ownerId, in: disk)
    }

    func beginCareOverviewRead(
        locale: String, context: SyncSessionLease, authority: SyncSessionAuthority,
        revalidating original: CareOverviewReadToken? = nil
    ) throws -> CareOverviewReadToken {
        try authority.withPermanentBoundValid(context) {
            guard ["en", "pl"].contains(locale) else { throw CareOverviewStoreError.invalidLocale }
            let disk = makeSyncContext()
            do {
                let row = try careOverviewRow(ownerId: context.ownerId, in: disk)
                var payload = careOverviewPayload(row, ownerId: context.ownerId) ?? CareOverviewCachePayload()
                if let original {
                    guard payload.revalidationRequestId == original.requestId,
                          original.lease.ownerId == context.ownerId,
                          original.lease.generation == context.generation else {
                        throw CareOverviewStoreError.superseded
                    }
                }
                payload.revalidationRequestId = nil
                let requestId = UUID()
                payload.pendingRequestId = requestId
                payload.pendingRequestLocale = locale
                try stageCareOverview(payload, row: row, ownerId: context.ownerId, in: disk)
                try Task.checkCancellation()
                try disk.save()
                return CareOverviewReadToken(
                    lease: context, requestId: requestId,
                    canonicalGeneration: payload.canonicalGeneration, locale: locale
                )
            } catch {
                disk.rollback()
                throw error
            }
        }
    }

    /// A disk read is always cached/stale, even when canonical generations match.
    func readCareOverview(
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CachedCareOverview? {
        try authority.withPermanentBoundValid(context) {
            try cachedCareOverview(ownerId: context.ownerId, in: makeSyncContext())
        }
    }

    private func cachedCareOverview(ownerId: UUID, in disk: ModelContext) throws -> CachedCareOverview? {
        let row = try careOverviewRow(ownerId: ownerId, in: disk)
        guard let payload = careOverviewPayload(row, ownerId: ownerId),
              let snapshot = try payload.validatedSnapshot(ownerId: ownerId),
              let fetchedAt = payload.fetchedAt, let locale = payload.snapshotLocale else { return nil }
        let aligned = payload.knownInvalidation == nil
            && payload.snapshotGeneration == payload.canonicalGeneration
        return CachedCareOverview(
            snapshot: snapshot, fetchedAt: fetchedAt, snapshotLocale: locale,
            state: aligned ? .cached : .stale, canonicalGenerationMatches: aligned
        )
    }

    private func careOverviewCards(ownerId: UUID, in disk: ModelContext) throws -> [CatalogueCardSummary] {
        let rows = try disk.fetch(FetchDescriptor<SyncedEntityRecord>(predicate: #Predicate {
            $0.ownerId == ownerId && $0.entityType == "plants" && $0.deletedAt == nil
        }))
        return try rows.map { row in
            let card = try JSONDecoder().decode(CatalogueCardSummary.self, from: Data(row.payloadJSON.utf8))
            guard card.id == row.entityId, card.revision > 0, card.careRevision > 0 else {
                throw SyncWireValidationError.invalidPage
            }
            return card
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func careOverviewPresentation(
        ownerId: UUID, in disk: ModelContext
    ) throws -> LocalCareOverviewPresentation {
        let row = try careOverviewRow(ownerId: ownerId, in: disk)
        let payload = careOverviewPayload(row, ownerId: ownerId)
        let checkpoints = FetchDescriptor<SyncCheckpointRecord>(predicate: #Predicate { $0.ownerId == ownerId })
        let checkpoint = try disk.fetch(checkpoints).first
        let profile = checkpoint?.syncProfileJSON.flatMap {
            try? JSONDecoder().decode(SyncWireProfileDTO.self, from: Data($0.utf8))
        }
        let entitlement = checkpoint?.syncEntitlementJSON.flatMap {
            try? JSONDecoder().decode(SyncWireEntitlementDTO.self, from: Data($0.utf8))
        }
        let accessKnown = checkpoint?.watermarkRaw.flatMap(SQLTimestamp.microseconds(from:)) != nil
            && profile != nil && (checkpoint?.syncEntitlementJSON == nil || entitlement != nil)
        // Include current care evidence and tombstones without deriving or scheduling dates.
        let types: Set<String> = [
            "plants", "condition_snapshots", "analysis_summaries", "care_plan_summaries",
            "care_tasks", "care_entries", "care_reversals", "schedule_changes",
            "basic_care_memberships", "first_aid_followups", "care_observations", "recovery_transitions"
        ]
        let rows = try disk.fetch(FetchDescriptor<SyncedEntityRecord>(predicate: #Predicate {
            $0.ownerId == ownerId
        })).filter { types.contains($0.entityType) }.sorted {
            ($0.entityType, $0.entityId.uuidString) < ($1.entityType, $1.entityId.uuidString)
        }
        return LocalCareOverviewPresentation(
            ownerId: ownerId, canonicalGeneration: payload?.canonicalGeneration,
            snapshotGeneration: payload?.snapshotGeneration,
            cached: try cachedCareOverview(ownerId: ownerId, in: disk),
            cards: try careOverviewCards(ownerId: ownerId, in: disk),
            pending: try pendingOutboxEntries(for: ownerId, in: disk),
            profile: profile, entitlement: entitlement, canonicalAccessKnown: accessKnown,
            careRows: rows.map {
                LocalCareOverviewRow(
                    entityType: $0.entityType, entityId: $0.entityId, payloadJSON: $0.payloadJSON,
                    updatedAtRaw: $0.updatedAtRaw, deletedAt: $0.deletedAt
                )
            },
            knownInvalidation: payload?.knownInvalidation
        )
    }

    /// No save, wrapper materialization, network freshness or authorization claim.
    func readCareOverviewPresentation(
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> LocalCareOverviewPresentation {
        try authority.withPermanentBoundValid(context) {
            try careOverviewPresentation(ownerId: context.ownerId, in: makeSyncContext())
        }
    }

    private func matchesCareOverviewRequest(
        _ payload: CareOverviewCachePayload, token: CareOverviewReadToken
    ) -> Bool {
        payload.pendingRequestId == token.requestId && payload.pendingRequestLocale == token.locale
            && payload.canonicalGeneration == token.canonicalGeneration
    }

    private func requireCareOverviewAlignment(
        _ snapshot: CareOverviewSnapshot, ownerId: UUID, in disk: ModelContext
    ) throws {
        let checkpoints = FetchDescriptor<SyncCheckpointRecord>(predicate: #Predicate { $0.ownerId == ownerId })
        guard let checkpoint = try disk.fetch(checkpoints).first,
              let raw = checkpoint.watermarkRaw, let end = SQLTimestamp.microseconds(from: raw),
              let first = snapshot.pages.first,
              let overview = SQLTimestamp.microseconds(from: first.ownerWatermark), overview <= end
        else { throw CareOverviewStoreError.needsCanonicalSync }
        let cards: [CatalogueCardSummary]
        do {
            cards = try careOverviewCards(ownerId: ownerId, in: disk)
        } catch {
            throw CareOverviewStoreError.needsCanonicalSync
        }
        guard Set(cards.map(\.id)).count == cards.count,
              Set(cards.map(\.id)) == Set(snapshot.plants.map(\.plantId)) else {
            throw CareOverviewStoreError.needsCanonicalSync
        }
        let revisions = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.careRevision) })
        guard snapshot.plants.allSatisfy({ revisions[$0.plantId] == $0.careRevision }) else {
            throw CareOverviewStoreError.needsCanonicalSync
        }
    }

    @discardableResult
    func finishCareOverviewRead(
        _ token: CareOverviewReadToken, snapshot: CareOverviewSnapshot,
        authority: SyncSessionAuthority
    ) throws -> LocalCareOverviewPresentation {
        try authority.withPermanentBoundValid(token.lease) {
            let ownerId = token.lease.ownerId
            let disk = makeSyncContext()
            do {
                let row = try careOverviewRow(ownerId: ownerId, in: disk)
                guard var payload = careOverviewPayload(row, ownerId: ownerId),
                      matchesCareOverviewRequest(payload, token: token)
                else { throw CareOverviewStoreError.superseded }
                let validated = try snapshot.validated(for: ownerId)
                try requireCareOverviewAlignment(validated, ownerId: ownerId, in: disk)
                payload.snapshotJSON = String(decoding: try JSONEncoder().encode(validated), as: UTF8.self)
                payload.snapshotGeneration = payload.canonicalGeneration
                payload.knownInvalidation = nil
                payload.revalidationRequestId = nil
                payload.snapshotLocale = token.locale
                payload.fetchedAt = Date()
                payload.pendingRequestId = nil
                payload.pendingRequestLocale = nil
                try stageCareOverview(payload, row: row, ownerId: ownerId, in: disk)
                let presentation = try careOverviewPresentation(ownerId: ownerId, in: disk)
                try Task.checkCancellation()
                try disk.save()
                return presentation
            } catch {
                disk.rollback()
                throw error
            }
        }
    }

    /// Persist rejection before sync, retaining the last snapshot bytes and metadata.
    /// The continuation marker fences the alignment await against newer requests.
    func invalidateCareOverviewRead(
        _ token: CareOverviewReadToken, reason: CareOverviewInvalidation,
        authority: SyncSessionAuthority
    ) throws {
        try authority.withPermanentBoundValid(token.lease) {
            let disk = makeSyncContext()
            do {
                let row = try careOverviewRow(ownerId: token.lease.ownerId, in: disk)
                guard var payload = careOverviewPayload(row, ownerId: token.lease.ownerId),
                      matchesCareOverviewRequest(payload, token: token) else {
                    throw CareOverviewStoreError.superseded
                }
                if payload.knownInvalidation != .authorizationDenied {
                    payload.knownInvalidation = reason
                }
                payload.canonicalGeneration = UUID()
                payload.pendingRequestId = nil
                payload.pendingRequestLocale = nil
                payload.revalidationRequestId = token.requestId
                try stageCareOverview(payload, row: row, ownerId: token.lease.ownerId, in: disk)
                try Task.checkCancellation()
                try disk.save()
            } catch {
                disk.rollback()
                throw error
            }
        }
    }

    @discardableResult
    func abandonCareOverviewRead(
        _ token: CareOverviewReadToken, authority: SyncSessionAuthority
    ) throws -> Bool {
        try authority.withPermanentBoundValid(token.lease) {
            let disk = makeSyncContext()
            do {
                let row = try careOverviewRow(ownerId: token.lease.ownerId, in: disk)
                guard var payload = careOverviewPayload(row, ownerId: token.lease.ownerId),
                      matchesCareOverviewRequest(payload, token: token)
                        || payload.revalidationRequestId == token.requestId else { return false }
                payload.revalidationRequestId = nil
                payload.pendingRequestId = nil
                payload.pendingRequestLocale = nil
                try stageCareOverview(payload, row: row, ownerId: token.lease.ownerId, in: disk)
                try Task.checkCancellation()
                try disk.save()
                return true
            } catch {
                disk.rollback()
                throw error
            }
        }
    }

    /// One disk transaction for the entire validated window. The same session
    /// authority used at request time is checked *inside* publication.
    func publishSyncWindow(
        items: [SyncItemDTO], ownerId: UUID, watermark: Date?,
        wirePage: SyncWirePageDTO? = nil, changes: [SyncWireChangeDTO] = [],
        fullRefresh: Bool, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws {
        guard ownerId == context.ownerId else { throw SyncWireValidationError.invalidSession }
        try authority.withValid(context) {
            // Discard the staging context on either outcome; it never shares
            // registered checkpoint/entity instances with subsequent reads.
            let modelContext = makeSyncContext()
            do {
                let descriptor = FetchDescriptor<SyncCheckpointRecord>(
                    predicate: #Predicate { $0.ownerId == ownerId }
                )
                let checkpoint: SyncCheckpointRecord
                if let existing = try modelContext.fetch(descriptor).first {
                    checkpoint = existing
                } else {
                    checkpoint = SyncCheckpointRecord(ownerId: ownerId)
                    modelContext.insert(checkpoint)
                }
                if let next = wirePage?.nextSince, let previous = checkpoint.watermarkRaw,
                   let end = SQLTimestamp.microseconds(from: next),
                   let old = SQLTimestamp.microseconds(from: previous), end < old {
                    throw SyncWireValidationError.invalidPage
                }
                if fullRefresh {
                    let entities = FetchDescriptor<SyncedEntityRecord>(
                        predicate: #Predicate { $0.ownerId == ownerId }
                    )
                    for entity in try modelContext.fetch(entities) {
                        let isOverview = entity.compositeKey == careOverviewKey(ownerId)
                            && entity.entityType == Self.careOverviewEntityType && entity.entityId == ownerId
                        if !isOverview && !isCareReminderReceiptRow(entity, ownerId: ownerId) {
                            modelContext.delete(entity)
                        }
                    }
                }
                var rawTimes: [String: String] = [:]
                for change in changes {
                    let key = "\(ownerId.uuidString.lowercased()):\(change.entityType):\(change.id.uuidString.lowercased())"
                    rawTimes[key] = change.updatedAt
                }
                try stageSyncedItems(items, ownerId: ownerId, rawTimes: rawTimes, in: modelContext)
                checkpoint.watermark = watermark
                checkpoint.watermarkRaw = wirePage?.nextSince
                if let wirePage {
                    let encoder = JSONEncoder()
                    checkpoint.syncProfileJSON = String(decoding: try encoder.encode(wirePage.profile), as: UTF8.self)
                    checkpoint.syncEntitlementJSON = try wirePage.entitlement.map {
                        String(decoding: try encoder.encode($0), as: UTF8.self)
                    }
                    // Null entitlement clears previous rights, including legacy projections.
                    checkpoint.entitlementValidUntil = wirePage.entitlement?.validUntil.flatMap { SQLTimestamp.date(from: $0) }
                    checkpoint.entitlementTrialEndAt = wirePage.entitlement?.trialEndAt.flatMap { SQLTimestamp.date(from: $0) }
                    checkpoint.entitlementOfferKind = wirePage.entitlement?.offerKind
                    checkpoint.entitlementState = wirePage.entitlement?.state
                }
                try rotateCareOverviewGeneration(ownerId: ownerId, in: modelContext)
                checkpoint.updatedAt = Date()
                try Task.checkCancellation()
                try modelContext.save()
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    func finishOutboxEntry(
        operationId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority,
        failure: String? = nil
    ) throws {
        try authority.withValid(context) {
            let modelContext = makeSyncContext()
            do {
                let descriptor = FetchDescriptor<LocalOutboxRecord>(
                    predicate: #Predicate { $0.operationId == operationId }
                )
                guard let record = try modelContext.fetch(descriptor).first,
                      record.ownerId == context.ownerId else {
                    throw SyncWireValidationError.invalidSession
                }
                let ownerId = record.ownerId
                if let failure {
                    record.retryCount += 1
                    record.lastError = failure
                } else {
                    guard record.commandName != "profile.update",
                          context.session == nil || record.commandName != "plant.create" else {
                        throw CatalogueCreateAcknowledgementError.invalidCommand
                    }
                    modelContext.delete(record)
                }
                try Task.checkCancellation()
                try modelContext.save()
                publishLocalOutboxChange(ownerId: ownerId)
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    /// Original SQL spelling wins. Only historical Date-only caches use this fallback.
    /// Reading never rewrites a historical checkpoint.
    public func currentWatermarkRaw(ownerId: UUID) throws -> String? {
        let modelContext = makeSyncContext()
        let descriptor = FetchDescriptor<SyncCheckpointRecord>(
            predicate: #Predicate { $0.ownerId == ownerId }
        )
        guard let checkpoint = try modelContext.fetch(descriptor).first else { return nil }
        if let raw = checkpoint.watermarkRaw { return raw }
        guard let date = checkpoint.watermark else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// One coherent committed read, ordered against auth changes by the same authority as publication.
    func collectionCapacitySnapshot(
        context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> CollectionCapacitySnapshot {
        try authority.withValid(context) {
            guard context.session != nil else { throw SyncWireValidationError.invalidSession }
            let ownerId = context.ownerId
            let modelContext = makeSyncContext()
            let entitlement = try canonicalEntitlement(ownerId: ownerId, in: modelContext)
            let plants = FetchDescriptor<SyncedEntityRecord>(
                predicate: #Predicate {
                    $0.ownerId == ownerId && $0.entityType == "plants" && $0.deletedAt == nil
                }
            )
            return CollectionCapacitySnapshot(
                plantCount: try modelContext.fetchCount(plants), entitlement: entitlement
            )
        }
    }

    func analysisHistorySnapshot(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> (plant: SyncItemDTO, analyses: [SyncItemDTO]) {
        try authority.withBoundValid(context) {
            let disk = makeSyncContext()
            let ownerId = context.ownerId
            let plants = try activeSyncedEntities(ownerId: ownerId, entityType: "plants", in: disk)
            guard let plant = plants.first(where: { $0.id == plantId })
            else { throw SyncWireValidationError.invalidPage }
            let analyses = try activeSyncedEntities(ownerId: ownerId, entityType: "analysis_summaries", in: disk)
            return (plant, analyses)
        }
    }

    func firstAidControlSnapshot(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> (entitlement: SyncWireEntitlementDTO?, controls: [SyncItemDTO], observations: [SyncItemDTO])? {
        try authority.withBoundValid(context) {
            let ownerId = context.ownerId
            let disk = makeSyncContext()
            let plant = FetchDescriptor<SyncedEntityRecord>(predicate: #Predicate {
                $0.ownerId == ownerId && $0.entityType == "plants" && $0.entityId == plantId && $0.deletedAt == nil
            })
            guard try disk.fetchCount(plant) == 1 else { return nil }
            let entitlement = try canonicalEntitlement(ownerId: ownerId, in: disk)
            let controls = try activeSyncedEntities(ownerId: ownerId, entityType: "first_aid_followups", in: disk)
            let observations = try activeSyncedEntities(ownerId: ownerId, entityType: "care_observations", in: disk)
            return (entitlement, controls, observations)
        }
    }

    private func canonicalEntitlement(ownerId: UUID, in disk: ModelContext) throws -> SyncWireEntitlementDTO? {
        let checkpoints = FetchDescriptor<SyncCheckpointRecord>(predicate: #Predicate { $0.ownerId == ownerId })
        guard let checkpoint = try disk.fetch(checkpoints).first,
              let raw = checkpoint.syncProfileJSON,
              let watermark = checkpoint.watermarkRaw, SQLTimestamp.microseconds(from: watermark) != nil else {
            throw SyncWireValidationError.invalidPage
        }
        // An absent entitlement means Free only after a canonical owner sync.
        _ = try JSONDecoder().decode(SyncWireProfileDTO.self, from: Data(raw.utf8))
        return try checkpoint.syncEntitlementJSON.map {
            try JSONDecoder().decode(SyncWireEntitlementDTO.self, from: Data($0.utf8))
        }
    }

    func syncedCanonicalEntitlement(context: SyncSessionLease, authority: SyncSessionAuthority) throws -> SyncWireEntitlementDTO? {
        try authority.withBoundValid(context) {
            try canonicalEntitlement(ownerId: context.ownerId, in: makeSyncContext())
        }
    }

    public func syncedProfile(ownerId: UUID) throws -> SyncWireProfileDTO? {
        let modelContext = makeSyncContext()
        let descriptor = FetchDescriptor<SyncCheckpointRecord>(
            predicate: #Predicate { $0.ownerId == ownerId }
        )
        guard let raw = try modelContext.fetch(descriptor).first?.syncProfileJSON else { return nil }
        return try JSONDecoder().decode(SyncWireProfileDTO.self, from: Data(raw.utf8))
    }

    public func syncedEntitlement(ownerId: UUID) throws -> SyncWireEntitlementDTO? {
        let modelContext = makeSyncContext()
        let descriptor = FetchDescriptor<SyncCheckpointRecord>(
            predicate: #Predicate { $0.ownerId == ownerId }
        )
        guard let raw = try modelContext.fetch(descriptor).first?.syncEntitlementJSON else { return nil }
        return try JSONDecoder().decode(SyncWireEntitlementDTO.self, from: Data(raw.utf8))
    }

    public func activeSyncedEntities(ownerId: UUID, entityType: String) throws -> [SyncItemDTO] {
        try activeSyncedEntities(ownerId: ownerId, entityType: entityType, in: makeSyncContext())
    }

    private func activeSyncedEntities(ownerId: UUID, entityType: String, in modelContext: ModelContext) throws -> [SyncItemDTO] {
        let descriptor = FetchDescriptor<SyncedEntityRecord>(
            predicate: #Predicate {
                $0.ownerId == ownerId && $0.entityType == entityType && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map {
            SyncItemDTO(
                entityType: $0.entityType,
                id: $0.entityId,
                updatedAt: $0.updatedAt,
                deletedAt: $0.deletedAt,
                payloadJSON: $0.payloadJSON
            )
        }
    }

    public func updateWatermark(ownerId: UUID, watermark: Date?) throws {
        let modelContext = makeSyncContext()
        let descriptor = FetchDescriptor<SyncCheckpointRecord>(
            predicate: #Predicate { $0.ownerId == ownerId }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            existing.watermark = watermark
            existing.watermarkRaw = nil
            existing.updatedAt = Date()
        } else {
            let record = SyncCheckpointRecord(ownerId: ownerId, watermark: watermark)
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func currentWatermark(ownerId: UUID) throws -> Date? {
        let modelContext = makeSyncContext()
        let descriptor = FetchDescriptor<SyncCheckpointRecord>(
            predicate: #Predicate { $0.ownerId == ownerId }
        )
        return try modelContext.fetch(descriptor).first?.watermark
    }

    /// Resets canonical/overview cache and cursor, retaining receipts, outbox and guest drafts.
    public func resetSyncCachePreservingOutbox(ownerId: UUID) throws {
        let modelContext = makeSyncContext()
        do {
            let entityDescriptor = FetchDescriptor<SyncedEntityRecord>(
                predicate: #Predicate { $0.ownerId == ownerId }
            )
            for entity in try modelContext.fetch(entityDescriptor) {
                if !isCareReminderReceiptRow(entity, ownerId: ownerId) { modelContext.delete(entity) }
            }

            let checkpointDescriptor = FetchDescriptor<SyncCheckpointRecord>(
                predicate: #Predicate { $0.ownerId == ownerId }
            )
            for cp in try modelContext.fetch(checkpointDescriptor) {
                cp.watermark = nil
                cp.watermarkRaw = nil
                cp.updatedAt = Date()
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
