import Foundation

// MARK: - Profile & Overrides DTOs (FR-035, FR-046..048)

public struct ProfileDTO: Codable, Sendable, Equatable {
    public let id: UUID
    public let accountState: String
    public let anonymous: Bool
    public let preferredLocale: String
    public let reminderHourLocal: Int
    public let freeSelectionExplicit: Bool
    public let trialReminderOptIn: Bool
    public let monthlyReportOptIn: Bool
    public let updatedAt: Date

    public init(
        id: UUID,
        accountState: String = "active",
        anonymous: Bool = false,
        preferredLocale: String = "pl",
        reminderHourLocal: Int = 9,
        freeSelectionExplicit: Bool = false,
        trialReminderOptIn: Bool = false,
        monthlyReportOptIn: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountState = accountState
        self.anonymous = anonymous
        self.preferredLocale = preferredLocale
        self.reminderHourLocal = reminderHourLocal
        self.freeSelectionExplicit = freeSelectionExplicit
        self.trialReminderOptIn = trialReminderOptIn
        self.monthlyReportOptIn = monthlyReportOptIn
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case accountState = "account_state"
        case anonymous
        case preferredLocale = "preferred_locale"
        case reminderHourLocal = "reminder_hour_local"
        case freeSelectionExplicit = "free_selection_explicit"
        case trialReminderOptIn = "trial_reminder_opt_in"
        case monthlyReportOptIn = "monthly_report_opt_in"
        case updatedAt = "updated_at"
    }
}

public struct ClaimOverridesDTO: Codable, Sendable, Equatable {
    public var plantId: String?
    public var taxonId: UUID?
    public var displayName: String?
    public var roomId: UUID?
    public var newRoomName: String?
    public var lightLevel: LightLevel?
    public var lightSource: LightSource?
    public var lightConfirmed: Bool?
    public var wateringHabit: WateringHabit?
    public var lastWatered: LastWateredBucket?
    public var potType: PotType?
    public var seasonOverride: SeasonOverride?

    public init(
        plantId: String? = nil,
        taxonId: UUID? = nil,
        displayName: String? = nil,
        roomId: UUID? = nil,
        newRoomName: String? = nil,
        lightLevel: LightLevel? = nil,
        lightSource: LightSource? = nil,
        lightConfirmed: Bool? = nil,
        wateringHabit: WateringHabit? = nil,
        lastWatered: LastWateredBucket? = nil,
        potType: PotType? = nil,
        seasonOverride: SeasonOverride? = nil
    ) {
        self.plantId = plantId
        self.taxonId = taxonId
        self.displayName = displayName
        self.roomId = roomId
        self.newRoomName = newRoomName
        self.lightLevel = lightLevel
        self.lightSource = lightSource
        self.lightConfirmed = lightConfirmed
        self.wateringHabit = wateringHabit
        self.lastWatered = lastWatered
        self.potType = potType
        self.seasonOverride = seasonOverride
    }

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case taxonId = "taxon_id"
        case displayName = "display_name"
        case roomId = "room_id"
        case newRoomName = "new_room_name"
        case lightLevel = "light_level"
        case lightSource = "light_source"
        case lightConfirmed = "light_confirmed"
        case wateringHabit = "watering_habit"
        case lastWatered = "last_watered"
        case potType = "pot_type"
        case seasonOverride = "season_override"
    }
}

public struct RecoveryCheckDTO: Codable, Sendable, Equatable {
    public let intervalDays: Int
    public let nextCheckDate: String?
    public let comparisonTraits: [String]
    public let photoAngleHint: String?

    public init(
        intervalDays: Int,
        nextCheckDate: String? = nil,
        comparisonTraits: [String],
        photoAngleHint: String? = nil
    ) {
        self.intervalDays = intervalDays
        self.nextCheckDate = nextCheckDate
        self.comparisonTraits = comparisonTraits
        self.photoAngleHint = photoAngleHint
    }

    enum CodingKeys: String, CodingKey {
        case intervalDays = "interval_days"
        case nextCheckDate = "next_check_date"
        case comparisonTraits = "comparison_traits"
        case photoAngleHint = "photo_angle_hint"
    }
}

public struct AnalysisReceiptDTO: Codable, Sendable, Equatable {
    public let analysisId: UUID
    public let kbReleaseId: UUID
    public let mode: AnalysisMode
    public let plantId: String?
    public let selectedConditionId: String?
    public let decisionRevision: Int
    public let issuedAt: Date
    public let signature: String

    public init(
        analysisId: UUID,
        kbReleaseId: UUID,
        mode: AnalysisMode,
        plantId: String?,
        selectedConditionId: String?,
        decisionRevision: Int = 1,
        issuedAt: Date,
        signature: String
    ) {
        self.analysisId = analysisId
        self.kbReleaseId = kbReleaseId
        self.mode = mode
        self.plantId = plantId
        self.selectedConditionId = selectedConditionId
        self.decisionRevision = decisionRevision
        self.issuedAt = issuedAt
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case analysisId = "analysis_id"
        case kbReleaseId = "kb_release_id"
        case mode
        case plantId = "plant_id"
        case selectedConditionId = "selected_condition_id"
        case decisionRevision = "decision_revision"
        case issuedAt = "issued_at"
        case signature
    }
}

// MARK: - ConditionProfile, Diagnostic Refinement & Treatment Steps (FR-061..064)

public struct TreatmentStepDTO: Codable, Sendable, Equatable {
    public let stepCode: String
    public let phase: String
    public let title: String
    public let instructions: String
    public let intervalDays: Int
    public let maxRepeats: Int

    public init(
        stepCode: String,
        phase: String,
        title: String,
        instructions: String,
        intervalDays: Int,
        maxRepeats: Int
    ) {
        self.stepCode = stepCode
        self.phase = phase
        self.title = title
        self.instructions = instructions
        self.intervalDays = intervalDays
        self.maxRepeats = maxRepeats
    }

    enum CodingKeys: String, CodingKey {
        case stepCode = "step_code"
        case phase
        case title
        case instructions
        case intervalDays = "interval_days"
        case maxRepeats = "max_repeats"
    }
}

public struct ConditionProfileDTO: Codable, Sendable, Equatable {
    public let conditionId: String
    public let kbReleaseId: UUID
    public let category: String
    public let localizedName: String
    public let visualMarkers: [String]
    public let firstAidSteps: [String]
    public let controlIntervalDays: Int?
    public let treatmentSteps: [TreatmentStepDTO]

    public init(
        conditionId: String,
        kbReleaseId: UUID,
        category: String,
        localizedName: String,
        visualMarkers: [String],
        firstAidSteps: [String],
        controlIntervalDays: Int?,
        treatmentSteps: [TreatmentStepDTO]
    ) {
        self.conditionId = conditionId
        self.kbReleaseId = kbReleaseId
        self.category = category
        self.localizedName = localizedName
        self.visualMarkers = visualMarkers
        self.firstAidSteps = firstAidSteps
        self.controlIntervalDays = controlIntervalDays
        self.treatmentSteps = treatmentSteps
    }

    enum CodingKeys: String, CodingKey {
        case conditionId = "condition_id"
        case kbReleaseId = "kb_release_id"
        case category
        case localizedName = "localized_name"
        case visualMarkers = "visual_markers"
        case firstAidSteps = "first_aid_steps"
        case controlIntervalDays = "control_interval_days"
        case treatmentSteps = "treatment_steps"
    }
}

// MARK: - Monthly Progress Report DTO (FR-068)

public struct PlantProgressHighlightDTO: Codable, Sendable, Equatable {
    public let plantId: UUID
    public let displayName: String
    public let careActionsCount: Int
    public let latestOutcome: ObservationOutcome?
    public let beforePhotoAssetId: UUID?
    public let afterPhotoAssetId: UUID?

    public init(
        plantId: UUID,
        displayName: String,
        careActionsCount: Int,
        latestOutcome: ObservationOutcome? = nil,
        beforePhotoAssetId: UUID? = nil,
        afterPhotoAssetId: UUID? = nil
    ) {
        self.plantId = plantId
        self.displayName = displayName
        self.careActionsCount = careActionsCount
        self.latestOutcome = latestOutcome
        self.beforePhotoAssetId = beforePhotoAssetId
        self.afterPhotoAssetId = afterPhotoAssetId
    }

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case displayName = "display_name"
        case careActionsCount = "care_actions_count"
        case latestOutcome = "latest_outcome"
        case beforePhotoAssetId = "before_photo_asset_id"
        case afterPhotoAssetId = "after_photo_asset_id"
    }
}

public struct ProgressReportDTO: Codable, Sendable, Equatable {
    public let monthKey: String
    public let isPartialPeriod: Bool
    public let totalCareActions: Int
    public let activePlantsCount: Int
    public let resolvedIssuesCount: Int
    public let highlights: [PlantProgressHighlightDTO]
    public let watermark: Date

    public init(
        monthKey: String,
        isPartialPeriod: Bool,
        totalCareActions: Int,
        activePlantsCount: Int,
        resolvedIssuesCount: Int,
        highlights: [PlantProgressHighlightDTO],
        watermark: Date
    ) {
        self.monthKey = monthKey
        self.isPartialPeriod = isPartialPeriod
        self.totalCareActions = totalCareActions
        self.activePlantsCount = activePlantsCount
        self.resolvedIssuesCount = resolvedIssuesCount
        self.highlights = highlights
        self.watermark = watermark
    }

    enum CodingKeys: String, CodingKey {
        case monthKey = "month_key"
        case isPartialPeriod = "is_partial_period"
        case totalCareActions = "total_care_actions"
        case activePlantsCount = "active_plants_count"
        case resolvedIssuesCount = "resolved_issues_count"
        case highlights
        case watermark
    }
}

// MARK: - Sync & Command Envelopes (contracts/sync.md, contracts/api.md)

public struct SyncCursorDTO: Codable, Sendable, Equatable {
    public let updatedAt: Date
    public let entityType: String
    public let id: UUID

    public init(updatedAt: Date, entityType: String, id: UUID) {
        self.updatedAt = updatedAt
        self.entityType = entityType
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case entityType = "entity_type"
        case id
    }
}

public struct SyncItemDTO: Codable, Sendable, Equatable {
    public let entityType: String
    public let id: UUID
    public let updatedAt: Date
    public let deletedAt: Date?
    public let payloadJSON: String

    public init(
        entityType: String,
        id: UUID,
        updatedAt: Date,
        deletedAt: Date? = nil,
        payloadJSON: String
    ) {
        self.entityType = entityType
        self.id = id
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.payloadJSON = payloadJSON
    }

    enum CodingKeys: String, CodingKey {
        case entityType = "entity_type"
        case id
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case payloadJSON = "payload_json"
    }
}

public struct SyncPageDTO: Codable, Sendable, Equatable {
    public let ownerId: UUID
    public let items: [SyncItemDTO]
    public let hasMore: Bool
    public let nextCursor: SyncCursorDTO?
    public let serverWatermark: Date
    public let limit: Int

    public init(
        ownerId: UUID,
        items: [SyncItemDTO],
        hasMore: Bool,
        nextCursor: SyncCursorDTO?,
        serverWatermark: Date,
        limit: Int
    ) {
        self.ownerId = ownerId
        self.items = items
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.serverWatermark = serverWatermark
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case ownerId = "owner_id"
        case items
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
        case serverWatermark = "server_watermark"
        case limit
    }
}

public struct CommandEnvelopeDTO: Codable, Sendable, Equatable {
    public let operationId: UUID
    public let commandName: String
    public let plantId: UUID?
    public let payloadJSON: String

    public init(
        operationId: UUID,
        commandName: String,
        plantId: UUID? = nil,
        payloadJSON: String
    ) {
        self.operationId = operationId
        self.commandName = commandName
        self.plantId = plantId
        self.payloadJSON = payloadJSON
    }

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
        case commandName = "command_name"
        case plantId = "plant_id"
        case payloadJSON = "payload_json"
    }
}

public struct CommandResponseDTO: Codable, Sendable, Equatable {
    public let status: String
    public let operationId: UUID
    public let replayed: Bool
    public let watermark: Date?

    public init(
        status: String,
        operationId: UUID,
        replayed: Bool = false,
        watermark: Date? = nil
    ) {
        self.status = status
        self.operationId = operationId
        self.replayed = replayed
        self.watermark = watermark
    }

    enum CodingKeys: String, CodingKey {
        case status
        case operationId = "operation_id"
        case replayed
        case watermark
    }
}
