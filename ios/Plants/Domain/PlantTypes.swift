import Foundation

// MARK: - Intents, Methods, and Flow State (FR-049, FR-050)

public enum AddIntent: String, Codable, Sendable, CaseIterable, Equatable {
    case problem
    case care
}

public enum AddMethod: String, Codable, Sendable, CaseIterable, Equatable {
    case scan
    case catalogue
}

public enum AnalysisMode: String, Codable, Sendable, CaseIterable, Equatable {
    case identification
    case diagnosis
    /// Read-only compatibility for cached analyses and signed receipts.
    case legacyFollowUp = "follow_up"

    public static let allCases: [AnalysisMode] = [.identification, .diagnosis]

    public var isSelectable: Bool { Self.allCases.contains(self) }
}

public enum LightLevel: String, Codable, Sendable, CaseIterable, Equatable {
    case brightDirect = "bright_direct"
    case brightIndirect = "bright_indirect"
    case medium
    case low
    case unknown
}

public enum LightSource: String, Codable, Sendable, CaseIterable, Equatable {
    case manual
    case cameraEstimate = "camera_estimate"
    case unknown
}

public enum WateringHabit: String, Codable, Sendable, CaseIterable, Equatable {
    case frequent
    case moderate
    case sparse
    case unknown
}

public enum LastWateredBucket: String, Codable, Sendable, CaseIterable, Equatable {
    case today
    case within3Days = "within_3_days"
    case within7Days = "within_7_days"
    case over7Days = "over_7_days"
    case unknown
}

public enum PotType: String, Codable, Sendable, CaseIterable, Equatable {
    case standardDrainage = "standard_drainage"
    case cachepotNoDrainage = "cachepot_no_drainage"
    case terracotta
    case selfWatering = "self_watering"
    case unknown
}

public enum SeasonOverride: String, Codable, Sendable, CaseIterable, Equatable {
    case auto
    case springSummer = "spring_summer"
    case autumnWinter = "autumn_winter"
}

public struct CareConditionsInput: Codable, Sendable, Equatable {
    public var lightLevel: LightLevel
    public var lightSource: LightSource
    public var lightConfirmed: Bool
    public var wateringHabit: WateringHabit
    public var lastWatered: LastWateredBucket
    public var potType: PotType
    public var seasonOverride: SeasonOverride

    public init(
        lightLevel: LightLevel = .unknown,
        lightSource: LightSource = .unknown,
        lightConfirmed: Bool = false,
        wateringHabit: WateringHabit = .unknown,
        lastWatered: LastWateredBucket = .unknown,
        potType: PotType = .unknown,
        seasonOverride: SeasonOverride = .auto
    ) {
        self.lightLevel = lightLevel
        self.lightSource = lightSource
        self.lightConfirmed = lightConfirmed
        self.wateringHabit = wateringHabit
        self.lastWatered = lastWatered
        self.potType = potType
        self.seasonOverride = seasonOverride
    }

    enum CodingKeys: String, CodingKey {
        case lightLevel = "light_level"
        case lightSource = "light_source"
        case lightConfirmed = "light_confirmed"
        case wateringHabit = "watering_habit"
        case lastWatered = "last_watered"
        case potType = "pot_type"
        case seasonOverride = "season_override"
    }
}

public enum AddFlowStep: String, Codable, Sendable, Equatable {
    case selectIntent = "select_intent"
    case selectCareMethod = "select_care_method"
    case selectPhoto = "select_photo"
    case selectCatalogueSpecies = "select_catalogue_species"
    case confirmSpecies = "confirm_species"
    case careQuestions = "care_questions"
    case analyzing = "analyzing"
    case diagnosticRefinement = "diagnostic_refinement"
    case preliminaryResult = "preliminary_result"
    case preSaveReview = "pre_save_review"
    case postSaveNextStep = "post_save_next_step"
}

public struct AddFlowState: Codable, Sendable, Equatable {
    public var flowId: UUID
    public var intent: AddIntent
    public var addMethod: AddMethod?
    public var currentStep: AddFlowStep
    public var questionIndex: Int
    public var photoLocalIdentifier: String?
    public var confirmedPlantId: String?
    public var confirmedTaxonId: UUID?
    public var confirmedDisplayName: String?
    public var conditions: CareConditionsInput
    public var resultMode: AnalysisMode?
    public var draftId: UUID?
    public var updatedAt: Date

    public init(
        flowId: UUID = UUID(),
        intent: AddIntent = .problem,
        addMethod: AddMethod? = .scan,
        currentStep: AddFlowStep = .selectIntent,
        questionIndex: Int = 1,
        photoLocalIdentifier: String? = nil,
        confirmedPlantId: String? = nil,
        confirmedTaxonId: UUID? = nil,
        confirmedDisplayName: String? = nil,
        conditions: CareConditionsInput = CareConditionsInput(),
        resultMode: AnalysisMode? = nil,
        draftId: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.flowId = flowId
        self.intent = intent
        self.addMethod = addMethod
        self.currentStep = currentStep
        self.questionIndex = questionIndex
        self.photoLocalIdentifier = photoLocalIdentifier
        self.confirmedPlantId = confirmedPlantId
        self.confirmedTaxonId = confirmedTaxonId
        self.confirmedDisplayName = confirmedDisplayName
        self.conditions = conditions
        self.resultMode = resultMode
        self.draftId = draftId
        self.updatedAt = updatedAt
    }

    /// Switching between .problem and .care preserves compatible photo, species, and condition inputs.
    public mutating func switchIntent(to newIntent: AddIntent) {
        self.intent = newIntent
        if newIntent == .problem {
            self.addMethod = .scan
        }
        self.updatedAt = Date()
    }
}

// MARK: - Next Step & Plan Availability (FR-048, FR-050)

public enum NextAvailableStep: String, Codable, Sendable, CaseIterable, Equatable {
    case enableBasicCare = "enable_basic_care"
    case selectFreePlants = "select_free_plants"
    case recordFirstAid = "record_first_aid"
    case openFirstAidControl = "open_first_aid_control"
    case generatePlan = "generate_plan"
    case openPlan = "open_plan"
    case viewPlant = "view_plant"
}

public enum PaidActionKind: String, Codable, Sendable, CaseIterable, Equatable {
    case generateFullRoutinePlan = "generate_full_routine_plan"
    case generateFullRecoveryPlan = "generate_full_recovery_plan"
    case unlockUnlimitedBasicCare = "unlock_unlimited_basic_care"
}

public enum PlanKind: String, Codable, Sendable, CaseIterable, Equatable {
    case routine
    case recovery
}

public enum PlanAccessTier: String, Codable, Sendable, CaseIterable, Equatable {
    case basic
    case full
}

public enum PlanAvailability: String, Codable, Sendable, CaseIterable, Equatable {
    case available
    case missingPlantProfile = "missing_plant_profile"
    case missingConditionProfile = "missing_condition_profile"
    case diagnosisUnresolved = "diagnosis_unresolved"
    case contextStale = "context_stale"
}

// MARK: - Identification & Diagnosis Domain Models (FR-005..007, FR-050, FR-061..064)

public enum IdentificationStatus: String, Codable, Sendable, Equatable {
    case resolved
    case genusOnly = "genus_only"
    case unknown
    case outOfScope = "out_of_scope"
}

public struct IdentificationResult: Codable, Sendable, Equatable {
    public let flowId: UUID
    public let analysisId: UUID
    public let kbReleaseId: UUID
    public let status: IdentificationStatus
    public let plantId: String?
    public let taxonId: UUID?
    public let genusId: String?
    public let displayName: String?
    public let scientificName: String?
    public let planAvailability: PlanAvailability

    public init(
        flowId: UUID,
        analysisId: UUID,
        kbReleaseId: UUID,
        status: IdentificationStatus,
        plantId: String?,
        taxonId: UUID?,
        genusId: String?,
        displayName: String?,
        scientificName: String?,
        planAvailability: PlanAvailability
    ) {
        self.flowId = flowId
        self.analysisId = analysisId
        self.kbReleaseId = kbReleaseId
        self.status = status
        self.plantId = plantId
        self.taxonId = taxonId
        self.genusId = genusId
        self.displayName = displayName
        self.scientificName = scientificName
        self.planAvailability = planAvailability
    }
}

public enum DiagnosisStatus: String, Codable, Sendable, Equatable {
    case healthy
    case conditionDetected = "condition_detected"
    case unknown
    case outOfScope = "out_of_scope"
}

public struct DiagnosisCandidate: Codable, Sendable, Equatable {
    public let conditionId: String
    public let rank: Int
    public let confidence: Double

    public init(conditionId: String, rank: Int, confidence: Double) {
        self.conditionId = conditionId
        self.rank = rank
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case conditionId = "condition_id"
        case rank
        case confidence
    }
}

public enum AnalysisContextState: String, Codable, Sendable, Equatable {
    case current
    case stale
}

public struct PreliminaryAnalysis: Codable, Sendable, Equatable {
    public let id: UUID
    public let jobId: UUID
    public let kbReleaseId: UUID
    public let mode: AnalysisMode
    public let identificationStatus: IdentificationStatus
    public let plantId: String?
    public let genusId: String?
    public let diagnosisStatus: DiagnosisStatus?
    public let candidates: [DiagnosisCandidate]
    public let selectedConditionId: String?
    public let visualMarkers: [String]
    public let evidenceBasis: [String]
    public let limitations: [String]
    public let firstActionSummary: String?
    public let controlIntervalDays: Int?
    public let contextState: AnalysisContextState
    public let planAvailability: PlanAvailability
    public let analysisReceipt: String

    public init(
        id: UUID,
        jobId: UUID,
        kbReleaseId: UUID,
        mode: AnalysisMode,
        identificationStatus: IdentificationStatus,
        plantId: String?,
        genusId: String?,
        diagnosisStatus: DiagnosisStatus?,
        candidates: [DiagnosisCandidate],
        selectedConditionId: String?,
        visualMarkers: [String],
        evidenceBasis: [String],
        limitations: [String],
        firstActionSummary: String?,
        controlIntervalDays: Int?,
        contextState: AnalysisContextState = .current,
        planAvailability: PlanAvailability = .available,
        analysisReceipt: String
    ) {
        self.id = id
        self.jobId = jobId
        self.kbReleaseId = kbReleaseId
        self.mode = mode
        self.identificationStatus = identificationStatus
        self.plantId = plantId
        self.genusId = genusId
        self.diagnosisStatus = diagnosisStatus
        self.candidates = candidates
        self.selectedConditionId = selectedConditionId
        self.visualMarkers = visualMarkers
        self.evidenceBasis = evidenceBasis
        self.limitations = limitations
        self.firstActionSummary = firstActionSummary
        self.controlIntervalDays = controlIntervalDays
        self.contextState = contextState
        self.planAvailability = planAvailability
        self.analysisReceipt = analysisReceipt
    }
}

// MARK: - Quotas, Entitlements, and Requested Actions (FR-005, FR-015..021, FR-065)

public enum QuotaKind: String, Codable, Sendable, CaseIterable, Equatable {
    case starterIdentification = "starter_identification"
    case starterDiagnosis = "starter_diagnosis"
    case freeMonthly = "free_monthly"
    case paidMonthly = "paid_monthly"
    case none
}

public struct StarterAccess: Codable, Sendable, Equatable {
    public let identificationRemaining: Int
    public let diagnosisRemaining: Int
    public let identificationInProgressJobId: UUID?
    public let diagnosisInProgressJobId: UUID?
    public let firstStarterSuccessAt: Date?

    public init(
        identificationRemaining: Int,
        diagnosisRemaining: Int,
        identificationInProgressJobId: UUID? = nil,
        diagnosisInProgressJobId: UUID? = nil,
        firstStarterSuccessAt: Date? = nil
    ) {
        self.identificationRemaining = identificationRemaining
        self.diagnosisRemaining = diagnosisRemaining
        self.identificationInProgressJobId = identificationInProgressJobId
        self.diagnosisInProgressJobId = diagnosisInProgressJobId
        self.firstStarterSuccessAt = firstStarterSuccessAt
    }

    enum CodingKeys: String, CodingKey {
        case identificationRemaining = "identification_remaining"
        case diagnosisRemaining = "diagnosis_remaining"
        case identificationInProgressJobId = "identification_in_progress_job_id"
        case diagnosisInProgressJobId = "diagnosis_in_progress_job_id"
        case firstStarterSuccessAt = "first_starter_success_at"
    }
}

public struct RequestedAction: Codable, Sendable, Equatable {
    public let kind: PaidActionKind
    public let plantId: UUID?
    public let analysisId: UUID?
    public let decisionRevision: Int?
    public let returnRoute: String

    public init(
        kind: PaidActionKind,
        plantId: UUID? = nil,
        analysisId: UUID? = nil,
        decisionRevision: Int? = nil,
        returnRoute: String
    ) {
        self.kind = kind
        self.plantId = plantId
        self.analysisId = analysisId
        self.decisionRevision = decisionRevision
        self.returnRoute = returnRoute
    }
}

// MARK: - Basic Care Membership, First Aid Followup, and Observations (FR-023, FR-066, FR-067)

public struct FreeSelection: Codable, Sendable, Equatable {
    public let selectedPlantIds: [UUID]
    public let selectionRevision: Int
    public let explicitSelection: Bool
    public let maxSlots: Int

    public init(
        selectedPlantIds: [UUID],
        selectionRevision: Int,
        explicitSelection: Bool,
        maxSlots: Int = 3
    ) {
        self.selectedPlantIds = selectedPlantIds
        self.selectionRevision = selectionRevision
        self.explicitSelection = explicitSelection
        self.maxSlots = maxSlots
    }

    enum CodingKeys: String, CodingKey {
        case selectedPlantIds = "selected_plant_ids"
        case selectionRevision = "selection_revision"
        case explicitSelection = "explicit_selection"
        case maxSlots = "max_slots"
    }
}

public struct BasicCareMembership: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let ownerId: UUID
    public let plantId: UUID
    public let enabled: Bool
    public let enabledAt: Date
    public let freeSlot: Int?
    public let selectionRevision: Int
    public let updatedAt: Date
    public let deletedAt: Date?

    public init(
        id: UUID,
        ownerId: UUID,
        plantId: UUID,
        enabled: Bool,
        enabledAt: Date,
        freeSlot: Int?,
        selectionRevision: Int,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerId = ownerId
        self.plantId = plantId
        self.enabled = enabled
        self.enabledAt = enabledAt
        self.freeSlot = freeSlot
        self.selectionRevision = selectionRevision
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerId = "owner_id"
        case plantId = "plant_id"
        case enabled
        case enabledAt = "enabled_at"
        case freeSlot = "free_slot"
        case selectionRevision = "selection_revision"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

public enum FirstAidFollowupState: String, Codable, Sendable, Equatable {
    case active
    case completed
    case cancelled
    case superseded
}

public struct FirstAidFollowup: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let ownerId: UUID
    public let plantId: UUID
    public let originAnalysisId: UUID
    public let decisionRevision: Int
    public let firstActionEntryId: UUID?
    public let controlTaskId: UUID?
    public let controlIntervalDays: Int?
    public let controlDueDate: String?
    public let noScheduleReason: String?
    public let state: FirstAidFollowupState
    public let updatedAt: Date
    public let deletedAt: Date?

    public init(
        id: UUID,
        ownerId: UUID,
        plantId: UUID,
        originAnalysisId: UUID,
        decisionRevision: Int = 1,
        firstActionEntryId: UUID? = nil,
        controlTaskId: UUID? = nil,
        controlIntervalDays: Int? = nil,
        controlDueDate: String? = nil,
        noScheduleReason: String? = nil,
        state: FirstAidFollowupState = .active,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerId = ownerId
        self.plantId = plantId
        self.originAnalysisId = originAnalysisId
        self.decisionRevision = decisionRevision
        self.firstActionEntryId = firstActionEntryId
        self.controlTaskId = controlTaskId
        self.controlIntervalDays = controlIntervalDays
        self.controlDueDate = controlDueDate
        self.noScheduleReason = noScheduleReason
        self.state = state
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerId = "owner_id"
        case plantId = "plant_id"
        case originAnalysisId = "origin_analysis_id"
        case decisionRevision = "decision_revision"
        case firstActionEntryId = "first_action_entry_id"
        case controlTaskId = "control_task_id"
        case controlIntervalDays = "control_interval_days"
        case controlDueDate = "control_due_date"
        case noScheduleReason = "no_schedule_reason"
        case state
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

public enum ObservationOutcome: String, Codable, Sendable, CaseIterable, Equatable {
    case improved
    case unchanged
    case worsened
    case unsure
}

public struct CareObservation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let ownerId: UUID
    public let plantId: UUID
    public let taskId: UUID?
    public let firstAidId: UUID?
    public let outcome: ObservationOutcome
    public let note: String?
    public let photoAssetId: UUID?
    public let observedDate: String
    public let updatedAt: Date
    public let deletedAt: Date?

    public init(
        id: UUID,
        ownerId: UUID,
        plantId: UUID,
        taskId: UUID? = nil,
        firstAidId: UUID? = nil,
        outcome: ObservationOutcome,
        note: String? = nil,
        photoAssetId: UUID? = nil,
        observedDate: String,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerId = ownerId
        self.plantId = plantId
        self.taskId = taskId
        self.firstAidId = firstAidId
        self.outcome = outcome
        self.note = note
        self.photoAssetId = photoAssetId
        self.observedDate = observedDate
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerId = "owner_id"
        case plantId = "plant_id"
        case taskId = "task_id"
        case firstAidId = "first_aid_id"
        case outcome
        case note
        case photoAssetId = "photo_asset_id"
        case observedDate = "observed_date"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}
