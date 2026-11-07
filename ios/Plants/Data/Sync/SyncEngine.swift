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
    private var planHistoryByOwner: [UUID: [UUID: CachedPlanHistoryEntry]] = [:]
    private var reportCacheByOwner: [UUID: [String: ProgressReportDTO]] = [:]

    public init(store: LocalStore, apiClient: PlantsAPIClient) {
        self.store = store
        self.apiClient = apiClient
    }

    // MARK: - Outbox Drain (Sequential per plantId)

    @discardableResult
    public func flushOutbox(for ownerId: UUID) async throws -> Int {
        let pending = try await store.pendingOutboxEntries(for: ownerId)
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

            do {
                _ = try await apiClient.sendCommand(envelope)
                try await store.markOutboxCommitted(operationId: entry.operationId)
                committedCount += 1
            } catch {
                try await store.recordOutboxFailure(
                    operationId: entry.operationId,
                    errorMessage: String(describing: error)
                )
                if let plantId = entry.plantId {
                    blockedPlantIds.insert(plantId)
                } else {
                    GlobalChainBlocked = true
                }
            }
        }

        return committedCount
    }

    // MARK: - Delta Sync with since/until Window & Stable Cursor

    @discardableResult
    public func pullDelta(for ownerId: UUID, pageSize: Int = 200) async throws -> Date? {
        let since = try await store.currentWatermark(ownerId: ownerId)
        var windowUntil: Date? = nil
        var cursor: SyncCursorDTO? = nil
        var previousWatermark = since

        repeat {
            let page = try await apiClient.fetchSyncPage(
                since: since,
                until: windowUntil,
                cursor: cursor,
                limit: pageSize
            )

            if windowUntil == nil {
                windowUntil = page.serverWatermark
            }

            if !page.items.isEmpty {
                try await store.applySyncedItems(page.items, ownerId: ownerId)
                ingestSpecialEntities(page.items, ownerId: ownerId)
            }

            if page.hasMore, let nextCursor = page.nextCursor {
                cursor = nextCursor
            } else {
                cursor = nil
                break
            }
        } while cursor != nil

        if let finalWatermark = windowUntil {
            if previousWatermark != finalWatermark {
                invalidateReportCache(for: ownerId, newWatermark: finalWatermark)
                previousWatermark = finalWatermark
            }
            try await store.updateWatermark(ownerId: ownerId, watermark: finalWatermark)
        }

        return windowUntil
    }

    public func syncNow(for ownerId: UUID) async throws -> Date? {
        _ = try await flushOutbox(for: ownerId)
        return try await pullDelta(for: ownerId)
    }

    /// Resets the sync cursor and cached server entities while preserving LocalOutbox,
    /// then pulls a fresh snapshot from the beginning.
    public func performFullRefresh(for ownerId: UUID) async throws -> Date? {
        try await store.resetSyncCachePreservingOutbox(ownerId: ownerId)
        _ = try await flushOutbox(for: ownerId)
        return try await pullDelta(for: ownerId)
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
