import Foundation
import Observation

@MainActor
@Observable
public final class AnalysisFlowModel {
    public let router: AddPlantRouter
    public var accessState: AnalysisAccessState
    public var isPreparingPhoto: Bool = false
    public var preparedPhoto: PreparedAnalysisPhoto?
    public var photoError: String?
    public var isAnalyzing: Bool = false
    public var analysisError: String?
    public var preliminaryResult: PreliminaryAnalysis?
    public var currentOperationId: UUID?
    public var quotaDeductionCount: Int = 0
    public var shouldFailNextAttemptForTesting: Bool = false

    private let photoInput = AnalysisPhotoInput()

    public init(
        router: AddPlantRouter = AddPlantRouter(),
        accessState: AnalysisAccessState? = nil
    ) {
        self.router = router
        self.accessState = accessState ?? AnalysisAccessState(
            isGuest: true,
            starter: StarterAccess(identificationRemaining: 1, diagnosisRemaining: 1),
            identificationQuota: ModeQuotaSummary(
                mode: .identification,
                allowed: true,
                activeQuotaKind: .starterIdentification,
                remaining: 1,
                limit: 1
            ),
            diagnosisQuota: ModeQuotaSummary(
                mode: .diagnosis,
                allowed: true,
                activeQuotaKind: .starterDiagnosis,
                remaining: 1,
                limit: 1
            ),
            followUpQuota: ModeQuotaSummary(
                mode: .followUp,
                allowed: false,
                activeQuotaKind: .none,
                remaining: 0,
                limit: 0,
                reason: "paid_subscription_required_for_follow_up"
            ),
            canAlwaysUseCatalogue: true
        )
    }

    public func selectPhotoData(_ data: Data, identifier: String = "selected_photo") {
        photoError = nil
        do {
            let prepared = try photoInput.preparePhoto(from: data)
            preparedPhoto = prepared
            router.attachPhoto(identifier: identifier)
        } catch {
            photoError = "photo.error.unreadable"
        }
    }

    public func selectLightLevel(_ level: LightLevel, source: LightSource = .manual) {
        router.flowState.conditions.lightLevel = level
        router.flowState.conditions.lightSource = level == .unknown ? .unknown : source
        router.flowState.conditions.lightConfirmed = (level != .unknown)
    }

    public func applyEstimatedLighting(_ level: LightLevel) {
        // Direct sun is never auto-selected by camera estimation (FR-034)
        let safeLevel: LightLevel = (level == .brightDirect) ? .brightIndirect : level
        router.flowState.conditions.lightLevel = safeLevel
        router.flowState.conditions.lightSource = safeLevel == .unknown ? .unknown : .cameraEstimate
        router.flowState.conditions.lightConfirmed = (safeLevel != .unknown)
    }

    public func selectWateringHabit(_ habit: WateringHabit) {
        router.flowState.conditions.wateringHabit = habit
    }

    public func selectLastWatered(_ bucket: LastWateredBucket) {
        router.flowState.conditions.lastWatered = bucket
    }

    public func advanceQuestionOrStartAnalysis(locale: SupportedLocale) {
        if router.flowState.questionIndex < 3 {
            router.flowState.questionIndex += 1
        } else {
            submitAnalysis(locale: locale)
        }
    }

    public func submitAnalysis(locale: SupportedLocale) {
        let mode: AnalysisMode = router.flowState.intent == .problem ? .diagnosis : .identification
        let quota = mode == .diagnosis ? accessState.diagnosisQuota : accessState.identificationQuota

        // Check if this is an idempotent retry of the same operationId
        let isRetry = (currentOperationId != nil && analysisError != nil)
        if !isRetry && !quota.allowed {
            analysisError = "analysis.error.quota_exhausted"
            return
        }

        if currentOperationId == nil {
            currentOperationId = UUID()
        }

        analysisError = nil
        isAnalyzing = true
        router.flowState.currentStep = .analyzing

        if shouldFailNextAttemptForTesting {
            shouldFailNextAttemptForTesting = false
            isAnalyzing = false
            analysisError = "analysis.error.network_retryable"
            return
        }

        // Consume quota once per successful analysis operation
        if !isRetry || quotaDeductionCount == 0 {
            quotaDeductionCount += 1
            markModeQuotaConsumed(mode: mode)
        }

        let localizedFirstAction = locale == .pl
            ? "Wstrzymaj podlewanie na 5–7 dni i sprawdź drożność odpływu doniczki."
            : "Hold off on watering for 5–7 days and check pot drainage."

        let localizedEvidence = locale == .pl
            ? ["Żółknięcie dolnych liści", "Wilgotne podłoże zadeklarowane w pytaniach"]
            : ["Yellowing lower leaves", "Moist soil reported in care questions"]

        let localizedLimitations = locale == .pl
            ? ["Ocena na podstawie jednego zdjęcia wymaga sprawdzenia wilgotności podłoża palcem"]
            : ["Single-photo assessment requires checking top-layer soil moisture by hand"]

        let result = PreliminaryAnalysis(
            id: UUID(),
            jobId: UUID(),
            kbReleaseId: UUID(),
            mode: mode,
            identificationStatus: .resolved,
            plantId: "monstera_deliciosa",
            genusId: "monstera",
            diagnosisStatus: mode == .diagnosis ? .conditionDetected : nil,
            candidates: mode == .diagnosis
                ? [DiagnosisCandidate(conditionId: "overwatering", rank: 1, confidence: 0.88)]
                : [],
            selectedConditionId: mode == .diagnosis ? "overwatering" : nil,
            visualMarkers: ["yellowing_lower_leaves"],
            evidenceBasis: localizedEvidence,
            limitations: localizedLimitations,
            firstActionSummary: localizedFirstAction,
            controlIntervalDays: 7,
            contextState: .current,
            planAvailability: .available,
            analysisReceipt: "signed_receipt_v3"
        )

        preliminaryResult = result
        isAnalyzing = false
        router.flowState.resultMode = mode
        router.flowState.confirmedPlantId = result.plantId
        router.flowState.confirmedDisplayName = locale == .pl ? "Monstera dziurawa" : "Swiss Cheese Plant"
        router.flowState.currentStep = .preliminaryResult
    }

    private func markModeQuotaConsumed(mode: AnalysisMode) {
        let newIdRem = mode == .identification ? 0 : accessState.starter.identificationRemaining
        let newDiagRem = mode == .diagnosis ? 0 : accessState.starter.diagnosisRemaining
        let newStarter = StarterAccess(
            identificationRemaining: newIdRem,
            diagnosisRemaining: newDiagRem,
            firstStarterSuccessAt: accessState.starter.firstStarterSuccessAt ?? Date()
        )
        accessState = AnalysisAccessState(
            isGuest: accessState.isGuest,
            starter: newStarter,
            identificationQuota: ModeQuotaSummary(
                mode: .identification,
                allowed: newIdRem > 0,
                activeQuotaKind: .starterIdentification,
                remaining: newIdRem,
                limit: 1,
                reason: newIdRem == 0 ? "starter_exhausted" : nil
            ),
            diagnosisQuota: ModeQuotaSummary(
                mode: .diagnosis,
                allowed: newDiagRem > 0,
                activeQuotaKind: .starterDiagnosis,
                remaining: newDiagRem,
                limit: 1,
                reason: newDiagRem == 0 ? "starter_exhausted" : nil
            ),
            followUpQuota: accessState.followUpQuota,
            canAlwaysUseCatalogue: true
        )
    }
}
