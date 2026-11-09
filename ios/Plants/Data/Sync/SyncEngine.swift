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

    public init(store: LocalStore, apiClient: PlantsAPIClient) {
        self.store = store
        self.apiClient = apiClient
    }

    // MARK: - Outbox Drain (Sequential per plantId)

    @discardableResult
    public func flushOutbox(for ownerId: UUID) async throws -> Int {
        let context = try await apiClient.captureSyncContext(ownerId: ownerId)
        return try await flushOutbox(for: ownerId, context: context)
    }

    private func flushOutbox(for ownerId: UUID, context: SyncSessionLease) async throws -> Int {
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

        for entry in pending {
            if let plantId = entry.plantId {
                if blockedPlantIds.contains(plantId) {
                    continue
                }
            } else if GlobalChainBlocked {
                continue
            }

            let envelope = CommandEnvelopeDTO(
                operationId: entry.operationId,
                commandName: entry.commandName,
                plantId: entry.plantId,
                payloadJSON: entry.payloadJSON
            )

            let result: OutboxCommandResult
            do {
                result = try await apiClient.sendOutboxCommand(envelope, context: context)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                // Cancellation/auth changes abort the drain without touching the captured queue.
                try await apiClient.validateSyncContext(context)
                try await store.finishOutboxEntry(
                    operationId: entry.operationId, context: context, authority: apiClient.syncAuthority,
                    failure: String(describing: error)
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
            case .generic:
                try await store.finishOutboxEntry(
                    operationId: entry.operationId, context: context, authority: apiClient.syncAuthority
                )
            }
            committedCount += 1
        }

        return committedCount
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
