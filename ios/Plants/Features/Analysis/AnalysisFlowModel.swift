import Foundation
import Observation

struct RepeatDiagnosisTarget: Sendable, Equatable {
    let plantId: UUID
    let ownerId: UUID
}

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
    let repeatDiagnosisTarget: RepeatDiagnosisTarget?

    init(
        operationId: UUID, flowId: UUID, mode: AnalysisMode, intent: AddIntent,
        photo: PreparedAnalysisPhoto, conditions: CareConditionsInput, locale: SupportedLocale,
        repeatDiagnosisTarget: RepeatDiagnosisTarget? = nil
    ) {
        self.operationId = operationId
        self.flowId = flowId
        self.mode = mode
        self.intent = intent
        self.photo = photo
        self.conditions = conditions
        self.locale = locale
        self.repeatDiagnosisTarget = repeatDiagnosisTarget
    }
}

public struct PhotoIdentificationResult: Equatable, Sendable {
    public struct Species: Equatable, Sendable {
        let taxonId: UUID
        let slug: String
        let displayName: String
    }

    let jobId: UUID
    let catalogueReleaseId: UUID
    let species: Species?
}

public struct AnalysisServiceResult: Sendable {
    public let analysis: PreliminaryAnalysis?
    public let identification: PhotoIdentificationResult?
    public let speciesLabel: String?
    public let conditionLabel: String?
    public let uploadedPhotoId: UUID?
    let photoOwnerId: UUID?
    let firstAidAction: RecordableFirstAidAction?

    public init(
        analysis: PreliminaryAnalysis,
        speciesLabel: String? = nil,
        conditionLabel: String? = nil,
        uploadedPhotoId: UUID? = nil
    ) {
        self.init(analysis: analysis, speciesLabel: speciesLabel, conditionLabel: conditionLabel,
                  uploadedPhotoId: uploadedPhotoId, firstAidAction: nil)
    }

    init(analysis: PreliminaryAnalysis, speciesLabel: String?, conditionLabel: String?,
         uploadedPhotoId: UUID?, firstAidAction: RecordableFirstAidAction?, photoOwnerId: UUID? = nil) {
        self.analysis = analysis
        identification = nil
        self.speciesLabel = speciesLabel
        self.conditionLabel = conditionLabel
        self.uploadedPhotoId = uploadedPhotoId
        self.photoOwnerId = photoOwnerId
        self.firstAidAction = firstAidAction
    }

    init(identification: PhotoIdentificationResult, uploadedPhotoId: UUID?, photoOwnerId: UUID? = nil) {
        analysis = nil
        self.identification = identification
        speciesLabel = identification.species?.displayName
        conditionLabel = nil
        self.uploadedPhotoId = uploadedPhotoId
        self.photoOwnerId = photoOwnerId
        firstAidAction = nil
    }
}

struct PhotoIdentificationSelection: Equatable, Sendable {
    let jobId: UUID
    let photoAssetId: UUID
    let speciesSlug: String
    let taxonId: UUID
    let ownerId: UUID?
}

public enum AnalysisServiceFailure: Error, Sendable, Equatable {
    case retryableProvider
    case providerFailed
    case releasedTimeout
    case expiredTerminal
    case quotaRegistrationRequired
    case quotaExhausted
    case unavailable
}

@MainActor
public protocol AnalysisService {
    func analyze(_ request: AnalysisServiceRequest) async throws -> AnalysisServiceResult
}

/// Presentation of canonical initial-diagnosis content, independent of authentication.
struct InitialDiagnosisExplanation {
    let result: PreliminaryAnalysis
    let polish: Bool

    var firstAction: String? {
        guard result.mode == .diagnosis,
              result.identificationStatus == .resolved,
              result.diagnosisStatus == .conditionDetected,
              result.planAvailability == .available,
              result.contextState == .current,
              let condition = result.selectedConditionId,
              !condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let summary = result.firstActionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        return summary
    }

    var evidence: [String] {
        guard result.mode == .diagnosis else { return [] }
        var seen = Set<String>()
        return result.evidenceBasis.compactMap { code in
            guard seen.insert(code).inserted else { return nil }
            // Closed, user-safe vocabulary from the published diagnosis profile
            // and ProtocolResolver's healthy response. Unknown codes stay hidden.
            switch code {
            case "yellowing_lower_leaves":
                return polish ? "Dolne liście wydają się żółte." : "Lower leaves appear yellow."
            case "standing_water_in_saucer":
                return polish ? "Na podstawce widać stojącą wodę." : "Standing water is visible in the saucer."
            case "no_pathological_markers_detected":
                return polish
                    ? "Na tym zdjęciu nie wykryto widocznych oznak problemu."
                    : "No visible signs of a problem were detected in this photo."
            default:
                return nil
            }
        }
    }
}

@MainActor
@Observable
public final class AnalysisFlowModel {
    public let router: AddPlantRouter
    let repeatDiagnosisTarget: RepeatDiagnosisTarget?
    public var accessState: AnalysisAccessState?
    public var isPreparingPhoto: Bool = false
    public var preparedPhoto: PreparedAnalysisPhoto?
    public var photoError: String?
    public var isAnalyzing: Bool = false
    public var analysisError: String?
    public var preliminaryResult: PreliminaryAnalysis?
    private(set) var identificationResult: PhotoIdentificationResult?
    public var currentOperationId: UUID?
    public private(set) var frozenRequest: AnalysisServiceRequest?
    public private(set) var speciesLabel: String?
    public private(set) var conditionLabel: String?
    private var identifiedPhoto: PhotoIdentificationSelection?
    private var confirmedPhoto: PhotoIdentificationSelection?
    private var firstAidAction: RecordableFirstAidAction?
    private(set) var diagnosisPhoto: (id: UUID, owner: UUID)?
    private let photoInput = AnalysisPhotoInput()
    private var service: (any AnalysisService)?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    private var generation = UUID()
    private var photoSelectionId: UUID?
    private(set) var isReplacingQuestionPhoto = false

    public var hasAnalysisService: Bool { service != nil }

    public convenience init(
        router: AddPlantRouter = AddPlantRouter(),
        accessState: AnalysisAccessState? = nil,
        service: (any AnalysisService)? = nil
    ) {
        self.init(router: router, accessState: accessState, service: service, repeatDiagnosisTarget: nil)
    }

    convenience init(repeatDiagnosisTarget: RepeatDiagnosisTarget, service: any AnalysisService) {
        let router = AddPlantRouter()
        router.selectIntent(.problem)
        self.init(router: router, accessState: nil, service: service, repeatDiagnosisTarget: repeatDiagnosisTarget)
    }

    private init(
        router: AddPlantRouter, accessState: AnalysisAccessState?, service: (any AnalysisService)?,
        repeatDiagnosisTarget: RepeatDiagnosisTarget?
    ) {
        self.router = router
        self.accessState = accessState
        self.service = service
        self.repeatDiagnosisTarget = repeatDiagnosisTarget
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
        identificationResult = nil
        speciesLabel = nil
        conditionLabel = nil
        identifiedPhoto = nil
        if confirmedPhoto != nil { router.flowState.confirmedPlantId = nil }
        confirmedPhoto = nil
        firstAidAction = nil
        diagnosisPhoto = nil
        analysisError = nil
    }

    var recordableFirstAid: RecordableFirstAidAction? {
        guard router.flowState.currentStep == .preliminaryResult, let result = preliminaryResult,
              result.mode == .diagnosis, result.diagnosisStatus == .conditionDetected,
              result.identificationStatus == .resolved, result.planAvailability == .available,
              Self.nonempty(result.firstActionSummary) != nil,
              let target = repeatDiagnosisTarget, let firstAidAction,
              firstAidAction.jobId == result.jobId, firstAidAction.plantId == target.plantId,
              firstAidAction.isSoilCheck else { return nil }
        return firstAidAction
    }

    private var photoIdentificationCandidate: PhotoIdentificationSelection? {
        guard router.flowState.currentStep == .preliminaryResult,
              let frozenRequest, frozenRequest.mode == .identification,
              frozenRequest.flowId == router.flowState.flowId,
              frozenRequest.operationId == currentOperationId,
              frozenRequest.photo == preparedPhoto,
              let result = identificationResult, let species = result.species, speciesLabel != nil,
              let identifiedPhoto, identifiedPhoto.jobId == result.jobId,
              identifiedPhoto.taxonId == species.taxonId,
              identifiedPhoto.speciesSlug == species.slug else { return nil }
        return identifiedPhoto
    }

    var confirmedPhotoIdentification: PhotoIdentificationSelection? {
        guard let confirmedPhoto, confirmedPhoto == photoIdentificationCandidate else { return nil }
        return confirmedPhoto
    }

    var canConfirmPhotoIdentification: Bool {
        confirmedPhoto == nil && photoIdentificationCandidate != nil
    }

    func confirmPhotoIdentification() {
        guard confirmedPhoto == nil, let candidate = photoIdentificationCandidate else { return }
        confirmedPhoto = candidate
        router.flowState.confirmedPlantId = candidate.speciesSlug
    }

    public func returnFromAnalysis() {
        isReplacingQuestionPhoto = false
        if hasAnalysisService { cancelAnalysis() }
        router.returnFromUnavailableAnalysis()
    }

    public func showCatalogue() {
        isReplacingQuestionPhoto = false
        if hasAnalysisService { cancelAnalysis() }
        router.showCatalogue()
    }

    public func navigateBack() {
        if isReplacingQuestionPhoto && router.flowState.currentStep == .selectPhoto {
            cancelAnalysis()
            isReplacingQuestionPhoto = false
            router.flowState.currentStep = .careQuestions
            return
        }
        if hasAnalysisService { cancelAnalysis() }
        router.navigateBack()
    }

    /// Reveal source choices without opening a picker or changing answered conditions.
    func replaceQuestionPhoto() {
        guard repeatDiagnosisTarget == nil, router.flowState.intent == .problem,
              router.flowState.currentStep == .careQuestions else { return }
        cancelAnalysis()
        isReplacingQuestionPhoto = true
        photoError = nil
        router.flowState.currentStep = .selectPhoto
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
            router.attachPhoto(identifier: identifier, skipQuestions: repeatDiagnosisTarget != nil)
            isReplacingQuestionPhoto = false
            if hasAnalysisService && router.flowState.currentStep == .analyzing {
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

    public func selectDrainage(_ answer: DrainageAnswer) {
        router.flowState.conditions.drainage = answer
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
        guard !isPreparingPhoto, !isAnalyzing, preliminaryResult == nil, identificationResult == nil else {
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
                conditions: router.flowState.conditions, locale: locale, repeatDiagnosisTarget: repeatDiagnosisTarget
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
                if request.mode == .identification, let identification = result.identification {
                    self.identificationResult = identification
                    if let species = identification.species {
                        self.speciesLabel = Self.nonempty(species.displayName)
                        if let photoId = result.uploadedPhotoId {
                            self.identifiedPhoto = PhotoIdentificationSelection(
                                jobId: identification.jobId, photoAssetId: photoId, speciesSlug: species.slug,
                                taxonId: species.taxonId, ownerId: result.photoOwnerId
                            )
                        }
                    }
                } else if request.mode == .diagnosis, let diagnosis = result.analysis, diagnosis.mode == .diagnosis {
                    self.preliminaryResult = diagnosis
                    self.firstAidAction = result.firstAidAction
                    if let id = result.uploadedPhotoId, let owner = result.photoOwnerId {
                        self.diagnosisPhoto = (id, owner)
                    }
                    if diagnosis.identificationStatus == .resolved, diagnosis.plantId != nil {
                        self.speciesLabel = Self.nonempty(result.speciesLabel)
                    }
                    if diagnosis.diagnosisStatus == .conditionDetected, diagnosis.selectedConditionId != nil {
                        self.conditionLabel = Self.nonempty(result.conditionLabel)
                    }
                } else {
                    self.finishFailure("analysis.error.failed")
                    return
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
                case .releasedTimeout?: key = "analysis.error.timeout"
                case .expiredTerminal?: key = "analysis.error.expired_terminal"
                case .quotaRegistrationRequired?: key = "analysis.error.quota_registration"
                case .quotaExhausted?: key = "analysis.error.quota_exhausted"
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
