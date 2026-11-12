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

    // MARK: Outbox Operations

    public func enqueueCommand(
        operationId: UUID = UUID(),
        ownerId: UUID,
        plantId: UUID?,
        commandName: String,
        payloadJSON: String
    ) throws -> OutboxEntrySnapshot {
        let modelContext = makeSyncContext()
        let existingDescriptor = FetchDescriptor<LocalOutboxRecord>(
            predicate: #Predicate { $0.operationId == operationId }
        )
        if let existing = try modelContext.fetch(existingDescriptor).first {
            guard existing.ownerId == ownerId,
                  existing.plantId == plantId,
                  existing.commandName.utf8.elementsEqual(commandName.utf8),
                  existing.payloadJSON.utf8.elementsEqual(payloadJSON.utf8) else {
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
        modelContext.insert(record)
        try modelContext.save()

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
        guard let command = FirstAidRecordCommand(envelope: .init(
            operationId: entry.operationId, commandName: entry.commandName,
            plantId: entry.plantId, payloadJSON: entry.payloadJSON
        )) else { throw OutboxEnqueueError.operationIdentityMismatch }
        return command
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
        let modelContext = makeSyncContext()
        let descriptor = FetchDescriptor<LocalOutboxRecord>(
            predicate: #Predicate { $0.ownerId == ownerId },
            sortBy: [SortDescriptor(\.sequenceNumber, order: .forward)]
        )
        let records = try modelContext.fetch(descriptor)
        return records.map {
            OutboxEntrySnapshot(
                operationId: $0.operationId,
                ownerId: $0.ownerId,
                plantId: $0.plantId,
                commandName: $0.commandName,
                payloadJSON: $0.payloadJSON,
                sequenceNumber: $0.sequenceNumber,
                retryCount: $0.retryCount,
                lastError: $0.lastError,
                createdAt: $0.createdAt
            )
        }
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
        for record in try modelContext.fetch(descriptor) {
            modelContext.delete(record)
        }
        try modelContext.save()
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
                    for entity in try modelContext.fetch(entities) { modelContext.delete(entity) }
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
                if let failure {
                    record.retryCount += 1
                    record.lastError = failure
                } else {
                    guard context.session == nil || record.commandName != "plant.create" else {
                        throw CatalogueCreateAcknowledgementError.invalidCommand
                    }
                    modelContext.delete(record)
                }
                try Task.checkCancellation()
                try modelContext.save()
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

    func firstAidControlSnapshot(
        plantId: UUID, context: SyncSessionLease, authority: SyncSessionAuthority
    ) throws -> (entitlement: SyncWireEntitlementDTO?, rows: [SyncItemDTO])? {
        try authority.withBoundValid(context) {
            let ownerId = context.ownerId
            let disk = makeSyncContext()
            let plant = FetchDescriptor<SyncedEntityRecord>(predicate: #Predicate {
                $0.ownerId == ownerId && $0.entityType == "plants" && $0.entityId == plantId && $0.deletedAt == nil
            })
            guard try disk.fetchCount(plant) == 1 else { return nil }
            let entitlement = try canonicalEntitlement(ownerId: ownerId, in: disk)
            let controls = try activeSyncedEntities(ownerId: ownerId, entityType: "first_aid_followups", in: disk)
            return (entitlement, controls)
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

    /// Resets cached synced entities and cursor while strictly preserving LocalOutbox and GuestDraftCache.
    public func resetSyncCachePreservingOutbox(ownerId: UUID) throws {
        let modelContext = makeSyncContext()
        let entityDescriptor = FetchDescriptor<SyncedEntityRecord>(
            predicate: #Predicate { $0.ownerId == ownerId }
        )
        for entity in try modelContext.fetch(entityDescriptor) {
            modelContext.delete(entity)
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
    }
}
