import Foundation
import Observation

/// Immutable input retained in memory for an explicit retry of the same operation.
public struct AnalysisServiceRequest: Sendable, Equatable {
    public let operationId: UUID
    // Upload and job creation share the backend operation receipt namespace.
    public let uploadOperationId = UUID()
    public let flowId: UUID
    public let mode: AnalysisMode
    public let intent: AddIntent
    public let photo: PreparedAnalysisPhoto
    public let conditions: CareConditionsInput
    public let locale: SupportedLocale
}

public struct AnalysisServiceResult: Sendable {
    public let analysis: PreliminaryAnalysis
    public let speciesLabel: String?
    public let conditionLabel: String?

    public init(
        analysis: PreliminaryAnalysis,
        speciesLabel: String? = nil,
        conditionLabel: String? = nil
    ) {
        self.analysis = analysis
        self.speciesLabel = speciesLabel
        self.conditionLabel = conditionLabel
    }
}

public enum AnalysisServiceFailure: Error, Sendable, Equatable {
    case retryableProvider
    case providerFailed
    case unavailable
}

@MainActor
public protocol AnalysisService {
    func analyze(_ request: AnalysisServiceRequest) async throws -> AnalysisServiceResult
}

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
    public private(set) var frozenRequest: AnalysisServiceRequest?
    public private(set) var speciesLabel: String?
    public private(set) var conditionLabel: String?

    private let photoInput = AnalysisPhotoInput()
    private var service: (any AnalysisService)?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    private var generation = UUID()
    private var photoSelectionId: UUID?

    public var hasAnalysisService: Bool { service != nil }

    /// Only the current, completed diagnosis may supply a create slug.
    public var diagnosisSaveSpeciesSlug: String? {
        guard !isAnalyzing, analysisError == nil,
              router.flowState.currentStep == .preliminaryResult,
              let request = frozenRequest, request.mode == .diagnosis,
              request.intent == .problem,
              request.operationId == currentOperationId,
              request.flowId == router.flowState.flowId,
              request.intent == router.flowState.intent,
              let result = preliminaryResult, result.mode == .diagnosis,
              result.identificationStatus == .resolved, result.contextState == .current,
              let slug = result.plantId,
              (try? CatalogueInput(speciesSlug: slug).makeEnvelope(operationId: request.operationId)) != nil
        else { return nil }
        return slug
    }

    public init(
        router: AddPlantRouter = AddPlantRouter(),
        accessState: AnalysisAccessState? = nil,
        service: (any AnalysisService)? = nil
    ) {
        self.router = router
        self.accessState = accessState
        self.service = service
    }

    /// RootContainerView can explicitly install its endpoint adapter here.
    public func installAnalysisService(_ service: (any AnalysisService)?) {
        cancelAnalysis()
        self.service = service
    }

    public func cancelAnalysis() {
        generation = UUID()
        analysisTask?.cancel()
        analysisTask = nil
        photoSelectionId = nil
        isPreparingPhoto = false
        isAnalyzing = false
        currentOperationId = nil
        frozenRequest = nil
        preliminaryResult = nil
        speciesLabel = nil
        conditionLabel = nil
        analysisError = nil
    }

    public func returnFromAnalysis() {
        if hasAnalysisService { cancelAnalysis() }
        router.returnFromUnavailableAnalysis()
    }

    public func showCatalogue() {
        if hasAnalysisService { cancelAnalysis() }
        router.showCatalogue()
    }

    public func navigateBack() {
        if hasAnalysisService { cancelAnalysis() }
        router.navigateBack()
    }

    @discardableResult
    public func beginPhotoSelection() -> UUID {
        cancelAnalysis()
        preparedPhoto = nil
        router.flowState.photoLocalIdentifier = nil
        photoError = nil
        isPreparingPhoto = true
        let selectionId = UUID()
        photoSelectionId = selectionId
        router.flowState.currentStep = .selectPhoto
        return selectionId
    }

    public func failPhotoSelection(_ selectionId: UUID) {
        guard photoSelectionId == selectionId,
              router.flowState.currentStep == .selectPhoto else { return }
        photoSelectionId = nil
        isPreparingPhoto = false
        photoError = "photo.error.unreadable"
    }

    public func completePhotoSelection(
        _ data: Data, selectionId: UUID, identifier: String = "selected_photo",
        locale: SupportedLocale
    ) {
        guard photoSelectionId == selectionId,
              router.flowState.currentStep == .selectPhoto else { return }
        do {
            let prepared = try photoInput.preparePhoto(from: data)
            photoSelectionId = nil
            isPreparingPhoto = false
            preparedPhoto = prepared
            router.attachPhoto(identifier: identifier)
            if hasAnalysisService {
                submitAnalysis(locale: locale)
            }
        } catch {
            failPhotoSelection(selectionId)
        }
    }

    public func selectPhotoData(
        _ data: Data, identifier: String = "selected_photo", locale: SupportedLocale = .en
    ) {
        let selectionId = beginPhotoSelection()
        completePhotoSelection(data, selectionId: selectionId, identifier: identifier, locale: locale)
    }

    public func selectLightLevel(_ level: LightLevel) {
        router.flowState.conditions.lightLevel = level
        router.flowState.conditions.lightSource = level == .unknown ? .unknown : .manual
        router.flowState.conditions.lightConfirmed = (level != .unknown)
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

    /// Returns the active task so tests and callers can await completion deterministically.
    @discardableResult
    public func submitAnalysis(locale: SupportedLocale) -> Task<Void, Never>? {
        guard !isPreparingPhoto, !isAnalyzing, preliminaryResult == nil else {
            return analysisTask
        }
        guard let service else {
            if currentOperationId == nil { currentOperationId = UUID() }
            isAnalyzing = false
            preliminaryResult = nil
            analysisError = "analysis.error.unavailable"
            router.flowState.currentStep = .analyzing
            return nil
        }
        guard let photo = preparedPhoto else {
            photoError = "photo.error.unreadable"
            router.flowState.currentStep = .selectPhoto
            return nil
        }
        let request: AnalysisServiceRequest
        if let frozenRequest {
            request = frozenRequest
        } else {
            request = AnalysisServiceRequest(
                operationId: UUID(), flowId: router.flowState.flowId,
                mode: router.flowState.intent == .problem ? .diagnosis : .identification,
                intent: router.flowState.intent, photo: photo,
                conditions: router.flowState.conditions, locale: locale
            )
            frozenRequest = request
        }
        currentOperationId = request.operationId
        analysisError = nil
        isAnalyzing = true
        router.flowState.currentStep = .analyzing
        let submittedGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let result = try await service.analyze(request)
                guard let self, self.accepts(request, generation: submittedGeneration) else { return }
                guard result.analysis.mode == request.mode else {
                    self.finishFailure("analysis.error.failed")
                    return
                }
                self.preliminaryResult = result.analysis
                if result.analysis.identificationStatus == .resolved,
                   result.analysis.plantId != nil {
                    self.speciesLabel = Self.nonempty(result.speciesLabel)
                }
                if request.mode == .diagnosis,
                   result.analysis.diagnosisStatus == .conditionDetected,
                   result.analysis.selectedConditionId != nil {
                    self.conditionLabel = Self.nonempty(result.conditionLabel)
                }
                self.isAnalyzing = false
                self.analysisTask = nil
                self.router.flowState.currentStep = .preliminaryResult
            } catch {
                guard let self, self.accepts(request, generation: submittedGeneration) else { return }
                let key: String
                switch error as? AnalysisServiceFailure {
                case .retryableProvider?: key = "analysis.error.provider"
                case .providerFailed?: key = "analysis.error.provider_terminal"
                default: key = "analysis.error.failed"
                }
                self.finishFailure(key)
            }
        }
        analysisTask = task
        return task
    }

    private func accepts(_ request: AnalysisServiceRequest, generation: UUID) -> Bool {
        self.generation == generation
            && frozenRequest == request
            && router.flowState.flowId == request.flowId
            && router.flowState.intent == request.intent
            && router.flowState.currentStep == .analyzing
    }

    private func finishFailure(_ key: String) {
        isAnalyzing = false
        analysisTask = nil
        analysisError = key
    }

    private static func nonempty(_ label: String?) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return nil }
        return label
    }
}
