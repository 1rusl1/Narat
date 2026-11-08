import Foundation
import Observation

@MainActor
@Observable
public final class AnalysisFlowModel {
    public let router: AddPlantRouter
    public var accessState: AnalysisAccessState?
    public var isPreparingPhoto: Bool = false
    public var preparedPhoto: PreparedAnalysisPhoto?
    public var photoError: String?
    public var isAnalyzing: Bool = false
    public var analysisError: String?
    public var preliminaryResult: PreliminaryAnalysis?
    public var currentOperationId: UUID?

    private let photoInput = AnalysisPhotoInput()

    public init(
        router: AddPlantRouter = AddPlantRouter(),
        accessState: AnalysisAccessState? = nil
    ) {
        self.router = router
        self.accessState = accessState
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
        // No analysis service is connected yet. Keep the input and retry identity,
        // and never infer server access rights or manufacture a result locally.
        if currentOperationId == nil {
            currentOperationId = UUID()
        }
        isAnalyzing = false
        preliminaryResult = nil
        analysisError = "analysis.error.unavailable"
        router.flowState.currentStep = .analyzing
    }
}
