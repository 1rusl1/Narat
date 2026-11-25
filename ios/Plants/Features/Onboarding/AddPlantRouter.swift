import Foundation
import Observation

@MainActor
@Observable
public final class AddPlantRouter {
    public var flowState: AddFlowState
    public var hasCompletedWelcome: Bool
    public private(set) var isDirectAnalysisEntry = false

    public init(
        initialState: AddFlowState = AddFlowState(),
        hasCompletedWelcome: Bool = false
    ) {
        self.flowState = initialState
        self.hasCompletedWelcome = hasCompletedWelcome
    }

    public func startDirectAnalysis(_ intent: AddIntent) {
        flowState = AddFlowState()
        selectIntent(intent)
        isDirectAnalysisEntry = true
        flowState.addMethod = .scan
        flowState.currentStep = .selectPhoto
    }

    public func selectIntent(_ intent: AddIntent) {
        isDirectAnalysisEntry = false
        flowState.switchIntent(to: intent)
        if intent == .problem {
            flowState.addMethod = .scan
            flowState.currentStep = .selectPhoto
        } else {
            flowState.currentStep = .selectCareMethod
        }
    }

    public func selectCareMethod(_ method: AddMethod) {
        isDirectAnalysisEntry = false
        flowState.intent = .care
        flowState.addMethod = method
        switch method {
        case .scan:
            flowState.currentStep = .selectPhoto
        case .catalogue:
            flowState.currentStep = .selectCatalogueSpecies
        }
        flowState.updatedAt = Date()
    }

    public func attachPhoto(identifier: String) {
        attachPhoto(identifier: identifier, skipQuestions: false)
    }

    func attachPhoto(identifier: String, skipQuestions: Bool) {
        flowState.photoLocalIdentifier = identifier
        if flowState.intent == .problem && !skipQuestions {
            flowState.currentStep = .careQuestions
        } else {
            flowState.currentStep = .analyzing
        }
        flowState.updatedAt = Date()
    }

    public func returnFromUnavailableAnalysis() {
        flowState.currentStep = isDirectAnalysisEntry ? .selectIntent
            : (flowState.intent == .care ? .selectCareMethod : .selectIntent)
        isDirectAnalysisEntry = false
        flowState.updatedAt = Date()
    }

    public func showCatalogue() {
        isDirectAnalysisEntry = false
        flowState.currentStep = .selectCatalogueSpecies
        flowState.updatedAt = Date()
    }

    public func navigateBack() {
        switch flowState.currentStep {
        case .selectIntent:
            break
        case .selectCareMethod:
            flowState.currentStep = .selectIntent
        case .selectPhoto:
            if isDirectAnalysisEntry {
                returnFromUnavailableAnalysis()
            } else {
                flowState.currentStep = flowState.intent == .care ? .selectCareMethod : .selectIntent
            }
        case .selectCatalogueSpecies:
            flowState.currentStep = flowState.intent == .care ? .selectCareMethod : .selectPhoto
        case .confirmSpecies:
            flowState.currentStep = .selectPhoto
        case .careQuestions:
            if flowState.questionIndex > 1 {
                flowState.questionIndex -= 1
            } else if flowState.intent == .problem {
                flowState.currentStep = .selectPhoto
            } else {
                flowState.currentStep = flowState.addMethod == .catalogue ? .selectCatalogueSpecies : .confirmSpecies
            }
        case .analyzing:
            flowState.currentStep = .careQuestions
        case .diagnosticRefinement, .preliminaryResult:
            flowState.currentStep = .careQuestions
        case .preSaveReview:
            flowState.currentStep = .preliminaryResult
        case .postSaveNextStep:
            flowState.currentStep = .preSaveReview
        }
        flowState.updatedAt = Date()
    }
}
