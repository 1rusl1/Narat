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
                activeQuotaKind: .starterDiagnosis, remaining: 1, limit: 1)
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

    func testAnalysisModesOfferOnlyIdentificationAndDiagnosis() throws {
        XCTAssertEqual(AnalysisMode.allCases, [.identification, .diagnosis])
        XCTAssertTrue(AnalysisMode.allCases.allSatisfy(\.isSelectable))
        let legacy = try JSONDecoder().decode(AnalysisMode.self, from: Data(#""follow_up""#.utf8))
        XCTAssertEqual(legacy, .legacyFollowUp)
        XCTAssertFalse(legacy.isSelectable)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self), #""follow_up""#)
        XCTAssertThrowsError(try JSONDecoder().decode(AnalysisMode.self, from: Data(#""unknown_mode""#.utf8)))
        XCTAssertFalse(PaidActionKind.allCases.map(\.rawValue).contains("start_follow_up_scan"))
    }

    func testTwoModeAccessRoundTripIgnoresOldQuotaAndLegacyDoesNotConsumeStarter() async throws {
        let repository = AnalysisAccessRepository()
        let initial = await repository.currentAccessState()
        let encoded = try JSONEncoder().encode(initial)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["followUpQuota"])
        XCTAssertEqual(try JSONDecoder().decode(AnalysisAccessState.self, from: encoded), initial)
        // Cached access from an older build may still contain the retired summary.
        object["followUpQuota"] = [
            "mode": "follow_up", "allowed": false, "activeQuotaKind": "none",
            "remaining": 0, "limit": 0
        ]
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(AnalysisAccessState.self, from: oldData)
        XCTAssertEqual(restored, initial)
        let cleanObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertNil(cleanObject["followUpQuota"])

        await repository.markStarterConsumed(for: .legacyFollowUp)
        let afterLegacy = await repository.currentAccessState()
        XCTAssertEqual(afterLegacy, initial)
        await repository.markStarterConsumed(for: .diagnosis)
        let afterDiagnosis = await repository.currentAccessState()
        XCTAssertEqual(afterDiagnosis.starter.identificationRemaining, 1)
        XCTAssertEqual(afterDiagnosis.starter.diagnosisRemaining, 0)
        XCTAssertEqual(afterDiagnosis.diagnosisQuota.reason, "starter_exhausted")
        XCTAssertEqual(afterDiagnosis.diagnosisQuota.mode, .diagnosis)
    }
}
