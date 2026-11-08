import XCTest
import UIKit
@testable import Plants

@MainActor
final class FirstHelpUnitTests: XCTestCase {
    // Image data is a test fixture only; production must never offer generated photos.
    private func photoFixture(largeOver10MB: Bool = false) -> Data {
        let size = CGSize(width: 600, height: 800)
        let renderer = UIGraphicsImageRenderer(size: size)
        var data = renderer.pngData { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        if largeOver10MB {
            data.append(Data(repeating: 0, count: max(0, 11 * 1024 * 1024 - data.count)))
        }
        return data
    }

    func testLargeOver10MBPhotoCompressesStripsMetadataAndResizesTo1568Px() throws {
        let largeRawData = photoFixture(largeOver10MB: true)
        XCTAssertGreaterThan(largeRawData.count, 10 * 1024 * 1024)
        let input = AnalysisPhotoInput()
        let prepared = try input.preparePhoto(from: largeRawData)
        XCTAssertLessThanOrEqual(prepared.cloudNormalizedJPEG.count, AnalysisPhotoInput.maxCloudBytes)
        XCTAssertLessThanOrEqual(max(prepared.aiWidthPx, prepared.aiHeightPx), 1568)
        XCTAssertTrue(prepared.strippedExifAndGps)
        XCTAssertThrowsError(try input.preparePhoto(from: Data([0x00, 0x01, 0x02, 0x03]))) { error in
            XCTAssertEqual(error as? PhotoInputError, .unreadableOrCorruptImage)
        }
    }

    func testDefaultHasNoConfirmedAccessOrFabricatedResult() {
        let model = AnalysisFlowModel()
        XCTAssertNil(model.accessState)
        XCTAssertNil(model.preliminaryResult)
        XCTAssertNil(model.router.flowState.confirmedPlantId)
        XCTAssertNil(model.router.flowState.confirmedDisplayName)
        XCTAssertNil(model.router.flowState.resultMode)
        XCTAssertNil(model.currentOperationId)
    }

    func testUnavailableRetryPreservesInputsIdentityAndAccessForBothIntents() throws {
        let access = AnalysisAccessState(
            isGuest: true,
            starter: StarterAccess(identificationRemaining: 1, diagnosisRemaining: 1),
            identificationQuota: ModeQuotaSummary(mode: .identification, allowed: true,
                activeQuotaKind: .starterIdentification, remaining: 1, limit: 1),
            diagnosisQuota: ModeQuotaSummary(mode: .diagnosis, allowed: true,
                activeQuotaKind: .starterDiagnosis, remaining: 1, limit: 1),
            followUpQuota: ModeQuotaSummary(mode: .followUp, allowed: false,
                activeQuotaKind: .none, remaining: 0, limit: 0)
        )
        for intent in [AddIntent.problem, .care] {
            for locale in [SupportedLocale.en, .pl] {
                for initialAccess in [nil, access] as [AnalysisAccessState?] {
                    let model = AnalysisFlowModel(accessState: initialAccess)
                    model.router.selectIntent(intent)
                    if intent == .care { model.router.selectCareMethod(.scan) }
                    model.selectPhotoData(photoFixture(), identifier: "test-photo")
                    model.selectLightLevel(.medium)
                    model.selectWateringHabit(.moderate)
                    model.selectLastWatered(.within3Days)
                    // A previous user-confirmed species must not be overwritten.
                    model.router.flowState.confirmedPlantId = "existing-species"
                    model.router.flowState.confirmedDisplayName = "My plant"
                    let before = model.router.flowState
                    let photo = try XCTUnwrap(model.preparedPhoto).cloudNormalizedJPEG

                    model.submitAnalysis(locale: locale)
                    let operation = try XCTUnwrap(model.currentOperationId)
                    for _ in 0..<3 {
                        model.submitAnalysis(locale: locale)
                        XCTAssertEqual(model.currentOperationId, operation)
                        XCTAssertEqual(model.analysisError, "analysis.error.unavailable")
                        XCTAssertFalse(model.isAnalyzing)
                        XCTAssertNil(model.preliminaryResult)
                        XCTAssertEqual(model.accessState, initialAccess)
                        XCTAssertEqual(model.router.flowState.confirmedPlantId, before.confirmedPlantId)
                        XCTAssertEqual(model.router.flowState.confirmedDisplayName, before.confirmedDisplayName)
                        XCTAssertEqual(model.router.flowState.resultMode, before.resultMode)
                        XCTAssertEqual(model.router.flowState.intent, intent)
                        XCTAssertEqual(model.router.flowState.photoLocalIdentifier, before.photoLocalIdentifier)
                        XCTAssertEqual(model.router.flowState.conditions, before.conditions)
                        XCTAssertEqual(model.preparedPhoto?.cloudNormalizedJPEG, photo)
                    }

                    model.router.returnFromUnavailableAnalysis()
                    XCTAssertEqual(model.router.flowState.currentStep,
                                   intent == .care ? .selectCareMethod : .selectIntent)
                    model.router.selectIntent(intent)
                    if intent == .care { model.router.selectCareMethod(.scan) }
                    model.router.showCatalogue()
                    XCTAssertEqual(model.router.flowState.currentStep, .selectCatalogueSpecies)
                    model.router.navigateBack()
                    XCTAssertEqual(model.router.flowState.currentStep,
                                   intent == .care ? .selectCareMethod : .selectPhoto)
                    XCTAssertEqual(model.router.flowState.conditions, before.conditions)
                    XCTAssertEqual(model.router.flowState.photoLocalIdentifier, before.photoLocalIdentifier)
                    XCTAssertEqual(model.preparedPhoto?.cloudNormalizedJPEG, photo)
                    XCTAssertEqual(model.currentOperationId, operation)
                    XCTAssertEqual(model.accessState, initialAccess)
                }
            }
        }
    }
}
