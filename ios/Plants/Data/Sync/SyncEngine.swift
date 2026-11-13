import Foundation

public struct CachedPlanHistoryEntry: Codable, Sendable, Equatable {
    public let planId: UUID
    public let ownerId: UUID
    public let plantId: UUID
    public let version: Int
    public let accessTier: PlanAccessTier
    public let planKind: PlanKind
    public let contextRevision: Int
    public let applicabilityStatus: String
    public let chemicalMustRevalidateAfter: String?
    public let summaryBodyJSON: String
    public let fullBodyJSON: String?
    public let updatedAt: Date

    public init(
        planId: UUID,
        ownerId: UUID,
        plantId: UUID,
        version: Int,
        accessTier: PlanAccessTier,
        planKind: PlanKind,
        contextRevision: Int,
        applicabilityStatus: String,
        chemicalMustRevalidateAfter: String?,
        summaryBodyJSON: String,
        fullBodyJSON: String?,
        updatedAt: Date
    ) {
        self.planId = planId
        self.ownerId = ownerId
        self.plantId = plantId
        self.version = version
        self.accessTier = accessTier
        self.planKind = planKind
        self.contextRevision = contextRevision
        self.applicabilityStatus = applicabilityStatus
        self.chemicalMustRevalidateAfter = chemicalMustRevalidateAfter
        self.summaryBodyJSON = summaryBodyJSON
        self.fullBodyJSON = fullBodyJSON
        self.updatedAt = updatedAt
    }

    public func isActionable(at referenceDateUTC: String) -> Bool {
        guard applicabilityStatus == "applicable" else {
            return false
        }
        if let revalidateAfter = chemicalMustRevalidateAfter, revalidateAfter < referenceDateUTC {
            return false
        }
        return true
    }
}

public struct EffectiveCareTaskView: Codable, Sendable, Equatable {
    public let taskId: UUID
    public let plantId: UUID
    public let actionType: String
    public let status: String
    public let reminderEligible: Bool
    public let pendingOperationId: UUID?

    public init(
        taskId: UUID,
        plantId: UUID,
        actionType: String,
        status: String,
        reminderEligible: Bool,
        pendingOperationId: UUID? = nil
    ) {
        self.taskId = taskId
        self.plantId = plantId
        self.actionType = actionType
        self.status = status
        self.reminderEligible = reminderEligible
        self.pendingOperationId = pendingOperationId
    }
}

public actor SyncEngine {
    private let store: LocalStore
    private let apiClient: PlantsAPIClient
    private var drainingOwners = Set<UUID>()
    private var planHistoryByOwner: [UUID: [UUID: CachedPlanHistoryEntry]] = [:]
    private var reportCacheByOwner: [UUID: [String: ProgressReportDTO]] = [:]
    private var canonicalSyncObservers: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(store: LocalStore, apiClient: PlantsAPIClient) {
        self.store = store
        self.apiClient = apiClient
    }

    func canonicalSyncUpdates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        canonicalSyncObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeCanonicalSyncObserver(id) }
        }
        return stream
    }

    private func removeCanonicalSyncObserver(_ id: UUID) {
        canonicalSyncObservers[id] = nil
    }

    // MARK: - Outbox Drain (Sequential per plantId)

    @discardableResult
    public func flushOutbox(for ownerId: UUID) async throws -> Int {
        let context = try await apiClient.captureSyncContext(ownerId: ownerId)
        return try await flushOutbox(for: ownerId, context: context)
    }

    /// Repository composition keeps one bound lease through refresh, drain and disk read.
    func flushOutbox(context: SyncSessionLease) async throws -> Int {
        try apiClient.syncAuthority.withBoundValid(context) {}
        return try await flushOutbox(for: context.ownerId, context: context)
    }

    func flushPlantDeletions(context: SyncSessionLease) async throws {
        try apiClient.syncAuthority.withBoundValid(context) {}
        _ = try await flushOutbox(for: context.ownerId, context: context, commandName: PlantDeleteReceipt.commandName)
    }

    func flushPlantEdit(_ command: CommandEnvelopeDTO, context: SyncSessionLease) async throws {
        try apiClient.syncAuthority.withBoundValid(context) {}
        _ = try await flushOutbox(for: context.ownerId, context: context, onlyOperation: command.operationId)
    }

    private func flushOutbox(
        for ownerId: UUID, context: SyncSessionLease, commandName: String? = nil, onlyOperation: UUID? = nil
    ) async throws -> Int {
        guard ownerId == context.ownerId else { throw SyncWireValidationError.invalidSession }
        try await apiClient.validateSyncContext(context)
        // Actor reentrancy must not dispatch a second copy of this owner's snapshot.
        guard drainingOwners.insert(ownerId).inserted else { return 0 }
        defer { drainingOwners.remove(ownerId) }
        let pending = try await store.pendingOutboxEntries(for: ownerId)
        try await apiClient.validateSyncContext(context)
        guard !pending.isEmpty else { return 0 }

        var blockedPlantIds = Set<UUID>()
        var GlobalChainBlocked = false
        var committedCount = 0
        let deletingPlants = Set(pending.compactMap { entry in
            entry.commandName == PlantDeleteReceipt.commandName ? entry.plantId : nil
        })

        for entry in pending {
            if let commandName, entry.commandName != commandName { continue }
            if let onlyOperation, entry.operationId != onlyOperation { continue }
            if let plantId = entry.plantId {
                if blockedPlantIds.contains(plantId)
                    || (deletingPlants.contains(plantId) && entry.commandName != PlantDeleteReceipt.commandName) {
                    continue
                }
            } else if GlobalChainBlocked {
                continue
            }

            var envelope = entry.envelope
            var firstAidUndo = false
            if context.session != nil, entry.commandName == ManualWateringAction.undoCommand {
                firstAidUndo = try await store.isFirstAidUndo(envelope, context: context, authority: apiClient.syncAuthority)
            }

            let result: OutboxCommandResult
            var receivedReceipt = false
            do {
                if entry.commandName == FirstAidObservationPhotoDraft.name {
                    guard let draft = FirstAidObservationPhotoDraft(envelope: envelope)
                    else { throw SyncWireValidationError.invalidRequest }
                    envelope = try await prepareFirstAidObservationPhoto(draft, context: context).envelope
                }
                result = try await apiClient.sendOutboxCommand(envelope, context: context)
                receivedReceipt = true
                switch result {
                case let .wateringDateCorrection(watermark):
                    try await refreshCanonicalJournal(ownerId: ownerId, watermark: watermark, context: context)
                case let .firstAidRecorded(receipt):
                    try await refreshCanonicalJournal(ownerId: ownerId, watermark: receipt.watermark, context: context)
                    guard let command = FirstAidRecordCommand(envelope: envelope),
                          try await store.confirmedFirstAidEntry(
                              command, context: context, authority: apiClient.syncAuthority
                          ) == receipt.entryId else {
                        throw SyncWireValidationError.invalidPage
                    }
                case let .careUndone(reversalId, watermark):
                    try await refreshCanonicalJournal(ownerId: ownerId, watermark: watermark, context: context)
                    let confirmed: UUID?
                    if firstAidUndo {
                        confirmed = try await store.confirmedFirstAidUndo(
                            envelope, context: context, authority: apiClient.syncAuthority
                        )
                    } else {
                        confirmed = try await store.confirmedWateringUndo(
                            envelope, context: context, authority: apiClient.syncAuthority
                        )
                    }
                    guard confirmed == reversalId else { throw SyncWireValidationError.invalidPage }
                case let .firstAidObserved(receipt):
                    try await refreshCanonicalJournal(ownerId: ownerId, watermark: receipt.watermark, context: context)
                    guard let command = FirstAidObservationCommand(envelope: envelope),
                          try await store.confirmedFirstAidObservation(
                              command, context: context, authority: apiClient.syncAuthority
                          ) == receipt.observationId else { throw SyncWireValidationError.invalidPage }
                case let .plantDeleting(receipt):
                    try await refreshCanonicalJournal(ownerId: ownerId, watermark: receipt.watermark, context: context)
                    guard let deleted = try await store.plantDeletionWatermark(
                        plantId: receipt.plantId, context: context, authority: apiClient.syncAuthority
                    ), deleted >= receipt.watermark else { throw SyncWireValidationError.invalidPage }
                case let .plantEdited(receipt):
                    guard let edit = PlantEditCommand(envelope) else { throw SyncWireValidationError.invalidRequest }
                    try await refreshCanonicalJournal(ownerId: ownerId, watermark: receipt.watermark, context: context)
                    if let card = try await store.syncedCollectionCard(
                        plantId: receipt.plantId, context: context, authority: apiClient.syncAuthority
                    ) {
                        if card.revision > receipt.revision, card.careRevision >= receipt.careRevision { break }
                        guard card.revision == receipt.revision, card.careRevision == receipt.careRevision,
                              card.currentConditionSnapshotId == receipt.conditionSnapshotId
                        else { throw SyncWireValidationError.invalidPage }
                        switch edit.change {
                        case let .name(name):
                            guard card.personalName?.utf8.elementsEqual(name.utf8) == true
                            else { throw SyncWireValidationError.invalidPage }
                        case let .light(light):
                            let saved = try await store.syncedPlantConditions(
                                for: card, context: context, authority: apiClient.syncAuthority
                            )
                            guard saved?.light == light || (card.currentConditionSnapshotId == nil && light == .unknown)
                            else { throw SyncWireValidationError.invalidPage }
                        case let .drainage(drainage):
                            let saved = try await store.syncedPlantConditions(
                                for: card, context: context, authority: apiClient.syncAuthority
                            )
                            guard saved?.drainage == drainage || (card.currentConditionSnapshotId == nil && drainage == .unknown)
                            else { throw SyncWireValidationError.invalidPage }
                        case let .watering(watering):
                            let saved = try await store.syncedPlantConditions(
                                for: card, context: context, authority: apiClient.syncAuthority
                            )
                            guard saved?.watering == watering || (card.currentConditionSnapshotId == nil && watering == .unknown)
                            else { throw SyncWireValidationError.invalidPage }
                        }
                    } else {
                        guard let deleted = try await store.plantDeletionWatermark(
                            plantId: receipt.plantId, context: context, authority: apiClient.syncAuthority
                        ), deleted >= receipt.watermark else { throw SyncWireValidationError.invalidPage }
                    }
                default:
                    break
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                // Cancellation/auth changes abort the drain without touching the captured queue.
                try await apiClient.validateSyncContext(context)
                let failure: String
                if let apiError = error as? APIErrorResponse {
                    let observation = envelope.commandName == FirstAidObservationCommand.name
                    let deletion = envelope.commandName == PlantDeleteReceipt.commandName
                    if !receivedReceipt, (entry.commandName == ManualWateringAction.undoCommand
                                          || entry.commandName == FirstAidRecordCommand.name || observation || deletion
                                          || entry.commandName == PlantEditCommand.name),
                       !apiError.error.retryable,
                       ["NOT_FOUND", "CONFLICT", "FORBIDDEN", "VALIDATION_ERROR"].contains(apiError.error.code) {
                        if observation, ["NOT_FOUND", "CONFLICT"].contains(apiError.error.code) {
                            if let command = FirstAidObservationCommand(envelope: envelope), let photoId = command.photoId {
                                if try await recoverRejectedFirstAidPhoto(command, photoId: photoId, context: context) {
                                    blockedPlantIds.insert(command.plantId)
                                    continue
                                }
                            } else {
                                _ = try? await pullDelta(for: ownerId, pageSize: 200, fullRefresh: false, context: context)
                            }
                        }
                        if entry.commandName == ManualWateringAction.undoCommand, !firstAidUndo {
                            // Keep the existing journal until the current owner window is available.
                            _ = try await pullDelta(for: ownerId, pageSize: 200, fullRefresh: false, context: context)
                        }
                        try await store.finishOutboxEntry(
                            operationId: entry.operationId, context: context, authority: apiClient.syncAuthority
                        )
                        continue
                    }
                    failure = String(decoding: try JSONEncoder().encode(apiError), as: UTF8.self)
                } else if envelope.commandName == FirstAidObservationPhotoDraft.name {
                    failure = "Observation photo upload failed"
                } else {
                    failure = String(describing: error)
                }
                try await store.finishOutboxEntry(
                    operationId: entry.operationId, context: context, authority: apiClient.syncAuthority,
                    failure: failure
                )
                if let plantId = entry.plantId {
                    blockedPlantIds.insert(plantId)
                } else {
                    GlobalChainBlocked = true
                }
                continue
            }

            // Disk acknowledgement failures propagate separately from send failures:
            // do not change retry metadata or count a commit after a failed save.
            switch result {
            case let .catalogueCreate(receipt):
                try await store.acknowledgeCatalogueCreate(
                    envelope, receipt: receipt, context: context, authority: apiClient.syncAuthority
                )
            case let .plantDeleting(receipt):
                try await store.acknowledgePlantDeletion(
                    envelope, receipt: receipt, context: context, authority: apiClient.syncAuthority
                )
            case .generic, .wateringDateCorrection, .firstAidRecorded, .careUndone, .firstAidObserved, .plantEdited:
                try await store.finishOutboxEntry(
                    operationId: entry.operationId, context: context, authority: apiClient.syncAuthority
                )
            }
            committedCount += 1
        }

        return committedCount
    }

    private func prepareFirstAidObservationPhoto(
        _ draft: FirstAidObservationPhotoDraft, context: SyncSessionLease
    ) async throws -> FirstAidObservationCommand {
        do {
            return try await uploadFirstAidObservationPhoto(draft, context: context)
        } catch let error as APIErrorResponse where error.isMissingPhoto || error.isIncompletePhoto {
            // At this stage no observe has been sent. An expired ticket cannot be refreshed by replay.
            let renewed = try await store.renewFirstAidPhotoDraft(
                draft, context: context, authority: apiClient.syncAuthority
            )
            return try await uploadFirstAidObservationPhoto(renewed, context: context)
        }
    }

    private func uploadFirstAidObservationPhoto(
        _ draft: FirstAidObservationPhotoDraft, context: SyncSessionLease
    ) async throws -> FirstAidObservationCommand {
        let authority = apiClient.syncAuthority
        let upload = try await store.firstAidPhotoUpload(draft, context: context, authority: authority)
        if let assetId = upload.assetId {
            do {
                try await apiClient.confirmFirstAidPhoto(id: assetId, context: context)
                return try await store.finalizeFirstAidPhoto(assetId, for: draft, context: context, authority: authority)
            } catch let error as APIErrorResponse where error.isIncompletePhoto {
                // A lost PUT may have left the upload incomplete. Keep the original ticket identity.
            }
        }
        let ticket = try await apiClient.issueFirstAidPhotoUpload(jpeg: upload.jpeg, draft: draft, context: context)
        try await store.checkpointFirstAidPhoto(ticket.photoAssetId, for: draft, context: context, authority: authority)
        if ticket.expiresInSeconds == 0 {
            try await apiClient.confirmFirstAidPhoto(id: ticket.photoAssetId, context: context)
        } else {
            try await apiClient.uploadFirstAidJPEG(upload.jpeg, ticket: ticket, context: context)
        }
        return try await store.finalizeFirstAidPhoto(ticket.photoAssetId, for: draft, context: context, authority: authority)
    }

    private func recoverRejectedFirstAidPhoto(
        _ command: FirstAidObservationCommand, photoId: UUID, context: SyncSessionLease
    ) async throws -> Bool {
        let authority = apiClient.syncAuthority
        do {
            _ = try await pullDelta(for: context.ownerId, pageSize: 200, fullRefresh: false, context: context)
            if try await store.confirmedFirstAidObservation(command, context: context, authority: authority) != nil {
                return true
            }
            guard try await store.canReplaceRejectedFirstAidPhoto(command, context: context, authority: authority)
            else { return false }
            do {
                try await apiClient.confirmFirstAidPhoto(id: photoId, context: context)
                return false
            } catch let error as APIErrorResponse where error.isMissingPhoto {
                try await store.replaceRejectedFirstAidPhoto(command, context: context, authority: authority)
                return true
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            // Inconclusive readback keeps the exact observe, which checks the server receipt first.
            try await apiClient.validateSyncContext(context)
            return true
        }
    }

    private func refreshCanonicalJournal(ownerId: UUID, watermark: Int64, context: SyncSessionLease) async throws {
        _ = try await pullDelta(for: ownerId, pageSize: 200, fullRefresh: false, context: context)
        guard let raw = try await store.currentWatermarkRaw(ownerId: ownerId),
              let confirmed = SQLTimestamp.microseconds(from: raw), confirmed >= watermark else {
            throw SyncWireValidationError.invalidPage
        }
    }

    // MARK: - Delta Sync with since/until Window & Stable Cursor

    @discardableResult
    public func pullDelta(for ownerId: UUID, pageSize: Int = 200) async throws -> Date? {
        let context = try await apiClient.captureSyncContext(ownerId: ownerId)
        return try await pullDelta(for: ownerId, pageSize: pageSize, fullRefresh: false, context: context)
    }

    private func pullDelta(
        for ownerId: UUID, pageSize: Int, fullRefresh: Bool, context: SyncSessionLease
    ) async throws -> Date? {
        if context.session != nil {
            return try await pullCanonicalDelta(
                for: ownerId, pageSize: pageSize, fullRefresh: fullRefresh, context: context
            )
        }
        // Explicit legacy compatibility for existing Date DTO clients. No error from
        // the bound canonical path can enter here.
        try await apiClient.validateSyncContext(context)
        let since: Date?
        if fullRefresh { since = nil }
        else { since = try await store.currentWatermark(ownerId: ownerId) }
        var stagedItems: [SyncItemDTO] = []
        var windowUntil: Date?
        var cursor: SyncCursorDTO?

        repeat {
            try await apiClient.validateSyncContext(context)
            let page = try await apiClient.fetchSyncPage(
                since: since, until: windowUntil, cursor: cursor, limit: pageSize
            )
            try await apiClient.validateSyncContext(context)
            guard page.ownerId == ownerId else { throw SyncWireValidationError.invalidSession }
            if windowUntil == nil { windowUntil = page.serverWatermark }
            stagedItems.append(contentsOf: page.items)
            if page.hasMore {
                guard let next = page.nextCursor, !page.items.isEmpty else {
                    throw SyncWireValidationError.invalidPage
                }
                if let cursor {
                    let previous: (Date, String, String) = (cursor.updatedAt, cursor.entityType, cursor.id.uuidString)
                    let following: (Date, String, String) = (next.updatedAt, next.entityType, next.id.uuidString)
                    guard previous < following else { throw SyncWireValidationError.invalidPage }
                }
                cursor = next
            } else {
                guard page.nextCursor == nil else { throw SyncWireValidationError.invalidPage }
                break
            }
        } while true

        try await store.publishSyncWindow(
            items: stagedItems, ownerId: ownerId, watermark: windowUntil,
            fullRefresh: fullRefresh, context: context, authority: apiClient.syncAuthority
        )
        if fullRefresh { planHistoryByOwner[ownerId] = nil }
        ingestSpecialEntities(stagedItems, ownerId: ownerId)
        if let windowUntil { invalidateReportCache(for: ownerId, newWatermark: windowUntil) }
        return windowUntil
    }

    private func pullCanonicalDelta(
        for ownerId: UUID, pageSize: Int, fullRefresh: Bool, context: SyncSessionLease
    ) async throws -> Date? {
        let since: String?
        if fullRefresh { since = nil }
        else { since = try await store.currentWatermarkRaw(ownerId: ownerId) }
        var windowUntil: String?
        var cursor: SyncWireCursorDTO?
        var changes: [SyncWireChangeDTO] = []
        var firstPage: SyncWirePageDTO?
        var finalPage: SyncWirePageDTO

        repeat {
            let result = try await apiClient.fetchSyncPage(
                context: context, since: since, until: windowUntil, cursor: cursor, limit: pageSize
            )
            guard result.ownerId == ownerId else { throw SyncWireValidationError.invalidSession }
            let page = result.page
            if let firstPage {
                guard page.profile == firstPage.profile, page.entitlement == firstPage.entitlement else {
                    throw SyncWireValidationError.invalidPage
                }
            } else {
                firstPage = page
                windowUntil = page.until
            }
            changes.append(contentsOf: page.changes)
            if page.hasMore {
                // A1 validates complete, strictly advancing tuples against this request.
                guard let next = page.lastCursor else { throw SyncWireValidationError.invalidPage }
                cursor = next
            } else {
                finalPage = page
                break
            }
        } while true

        let encoder = JSONEncoder()
        let items = try changes.map { change in
            SyncItemDTO(
                entityType: change.entityType, id: change.id,
                updatedAt: SQLTimestamp.date(from: change.updatedAt)!,
                deletedAt: change.deletedAt.flatMap { SQLTimestamp.date(from: $0) },
                payloadJSON: String(decoding: try encoder.encode(change.data), as: UTF8.self)
            )
        }
        let watermark = finalPage.nextSince.flatMap { SQLTimestamp.date(from: $0) }
        try await apiClient.validateSyncContext(context)
        try await store.publishSyncWindow(
            items: items, ownerId: ownerId, watermark: watermark, wirePage: finalPage, changes: changes,
            fullRefresh: fullRefresh, context: context, authority: apiClient.syncAuthority
        )
        for observer in canonicalSyncObservers.values { observer.yield(()) }
        if fullRefresh { planHistoryByOwner[ownerId] = nil }
        ingestSpecialEntities(items, ownerId: ownerId)
        if let watermark { invalidateReportCache(for: ownerId, newWatermark: watermark) }
        return watermark
    }

    public func syncNow(for ownerId: UUID) async throws -> Date? {
        let context = try await apiClient.captureSyncContext(ownerId: ownerId)
        _ = try await flushOutbox(for: ownerId, context: context)
        return try await pullDelta(for: ownerId, pageSize: 200, fullRefresh: false, context: context)
    }

    /// Canonical refresh never drains the outbox: failed refresh retains the whole old snapshot/queue.
    public func performFullRefresh(for ownerId: UUID) async throws -> Date? {
        let context = try await apiClient.captureSyncContext(ownerId: ownerId)
        if context.session == nil { _ = try await flushOutbox(for: ownerId, context: context) }
        return try await pullDelta(for: ownerId, pageSize: 200, fullRefresh: true, context: context)
    }

    /// Repository preflight keeps its original lease across the entire refresh and read.
    /// This overload never drains commands or permits legacy compatibility.
    func performFullRefresh(context: SyncSessionLease) async throws -> Date? {
        try await apiClient.validateSyncContext(context)
        guard context.session != nil else { throw SyncWireValidationError.invalidSession }
        let result = try await pullDelta(
            for: context.ownerId, pageSize: 200, fullRefresh: true, context: context
        )
        try await apiClient.validateSyncContext(context)
        return result
    }

    // MARK: - Pending Overlay over Synced Cache

    public func pendingOutboxOverlayCount(for ownerId: UUID) async throws -> Int {
        let entries = try await store.pendingOutboxEntries(for: ownerId)
        return entries.count
    }

    // MARK: - PlanHistoryCache & ReportCache Management

    private func ingestSpecialEntities(_ items: [SyncItemDTO], ownerId: UUID) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for item in items {
            guard item.deletedAt == nil else {
                if item.entityType == "care_plan" {
                    planHistoryByOwner[ownerId]?[item.id] = nil
                }
                continue
            }
            if item.entityType == "care_plan",
               let entry = try? decoder.decode(CachedPlanHistoryEntry.self, from: Data(item.payloadJSON.utf8)) {
                var ownerPlans = planHistoryByOwner[ownerId] ?? [:]
                ownerPlans[entry.planId] = entry
                planHistoryByOwner[ownerId] = ownerPlans
            }
        }
    }

    public func cachePlanHistoryEntry(_ entry: CachedPlanHistoryEntry) {
        var ownerPlans = planHistoryByOwner[entry.ownerId] ?? [:]
        ownerPlans[entry.planId] = entry
        planHistoryByOwner[entry.ownerId] = ownerPlans
    }

    public func readablePlanHistory(
        ownerId: UUID,
        plantId: UUID,
        referenceDateUTC: String
    ) -> [CachedPlanHistoryEntry] {
        guard let ownerPlans = planHistoryByOwner[ownerId] else { return [] }
        return ownerPlans.values
            .filter { $0.plantId == plantId }
            .sorted { $0.version > $1.version }
    }

    public func cacheProgressReport(_ report: ProgressReportDTO, for ownerId: UUID) {
        var ownerReports = reportCacheByOwner[ownerId] ?? [:]
        ownerReports[report.monthKey] = report
        reportCacheByOwner[ownerId] = ownerReports
    }

    public func cachedProgressReport(
        monthKey: String,
        for ownerId: UUID,
        expectedWatermark: Date
    ) -> ProgressReportDTO? {
        guard let report = reportCacheByOwner[ownerId]?[monthKey] else { return nil }
        guard report.watermark == expectedWatermark else {
            reportCacheByOwner[ownerId]?[monthKey] = nil
            return nil
        }
        return report
    }

    public func invalidateReportCache(for ownerId: UUID, newWatermark: Date) {
        guard let reports = reportCacheByOwner[ownerId] else { return }
        reportCacheByOwner[ownerId] = reports.filter { $0.value.watermark == newWatermark }
    }

    public func clearAccountMemoryCaches(for ownerId: UUID) {
        planHistoryByOwner[ownerId] = nil
        reportCacheByOwner[ownerId] = nil
    }
}

private extension APIErrorResponse {
    var isMissingPhoto: Bool { error.code == "NOT_FOUND" && !error.retryable }
    var isIncompletePhoto: Bool { error.code == "CONFLICT" && error.retryable }
}
