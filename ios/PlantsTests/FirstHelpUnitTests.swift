import XCTest
import UIKit
import ImageIO
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

    private func assertCompleteJPEG(
        _ data: Data, expectedSize: CGSize? = nil, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            XCTFail("JPEG source could not be opened", file: file, line: line)
            return
        }
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg", file: file, line: line)
        XCTAssertEqual(CGImageSourceGetStatus(source), .statusComplete, file: file, line: line)
        XCTAssertEqual(CGImageSourceGetStatusAtIndex(source, 0), .statusComplete, file: file, line: line)
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            XCTFail("JPEG pixels could not be decoded (\(data.count) bytes)", file: file, line: line)
            return
        }
        if let expectedSize {
            XCTAssertEqual(CGSize(width: decoded.width, height: decoded.height), expectedSize, file: file, line: line)
        }
        XCTAssertFalse(AnalysisPhotoInput.containsGpsOrExifMetadata(data), file: file, line: line)
    }

    func testLargeOver10MBPhotoCompressesStripsMetadataAndResizesTo1568Px() throws {
        let largeRawData = photoFixture(largeOver10MB: true)
        XCTAssertGreaterThan(largeRawData.count, 10 * 1024 * 1024)
        let input = AnalysisPhotoInput()
        let prepared = try input.preparePhoto(from: largeRawData)
        XCTAssertLessThanOrEqual(prepared.cloudNormalizedJPEG.count, AnalysisPhotoInput.maxCloudBytes)
        XCTAssertLessThanOrEqual(max(prepared.aiWidthPx, prepared.aiHeightPx), 1568)
        XCTAssertTrue(prepared.strippedExifAndGps)
        assertCompleteJPEG(prepared.cloudNormalizedJPEG)
        assertCompleteJPEG(prepared.aiVisionJPEG, expectedSize: CGSize(width: prepared.aiWidthPx, height: prepared.aiHeightPx))
        XCTAssertThrowsError(try input.preparePhoto(from: Data([0x00, 0x01, 0x02, 0x03]))) { error in
            XCTAssertEqual(error as? PhotoInputError, .unreadableOrCorruptImage)
        }
    }

    func testCatalogueMonsteraPhotoProducesCompleteJPEGsWithRealDimensions() throws {
        let bundle = Bundle(for: Self.self)
        let photo = try XCTUnwrap(bundle.url(forResource: "48854fc7b2b6d711a508c396", withExtension: "jpg"))
        let prepared = try AnalysisPhotoInput().preparePhoto(from: Data(contentsOf: photo))
        let expectedSize = CGSize(width: 960, height: 1091)
        XCTAssertEqual(prepared.aiWidthPx, 960)
        XCTAssertEqual(prepared.aiHeightPx, 1091)
        assertCompleteJPEG(prepared.aiVisionJPEG, expectedSize: expectedSize)
        assertCompleteJPEG(prepared.cloudNormalizedJPEG, expectedSize: expectedSize)
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

    func testLegacyLightingStaysHistoricalUntilExplicitManualSelection() throws {
        let legacyJSON = #"""
        {
          "light_level":"low", "light_source":"camera_estimate", "light_confirmed":false,
          "watering_habit":"sparse", "last_watered":"within_3_days",
          "pot_type":"terracotta", "season_override":"autumn_winter"
        }
        """#
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let legacy = try decoder.decode(CareConditionsInput.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.lightLevel, .low)
        XCTAssertEqual(legacy.lightSource, .cameraEstimate)
        XCTAssertFalse(legacy.lightConfirmed)

        for intent in [AddIntent.problem, .care] {
            let initial = AddFlowState(
                intent: intent, addMethod: .scan, currentStep: .careQuestions,
                questionIndex: 2, photoLocalIdentifier: "legacy-photo",
                confirmedPlantId: "monstera_deliciosa", confirmedTaxonId: UUID(),
                confirmedDisplayName: "My Monstera", conditions: legacy,
                resultMode: intent == .care ? .identification : .diagnosis, draftId: UUID()
            )
            let router = AddPlantRouter(initialState: initial, hasCompletedWelcome: true)
            let model = AnalysisFlowModel(router: router)
            XCTAssertTrue(model.router === router)
            XCTAssertEqual(router.flowState, initial)
            let historicalData = try encoder.encode(router.flowState.conditions)
            let historicalJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: historicalData) as? [String: Any])
            XCTAssertEqual(historicalJSON["light_source"] as? String, "camera_estimate")
            XCTAssertEqual(historicalJSON["light_confirmed"] as? Bool, false)
            XCTAssertEqual(try decoder.decode(CareConditionsInput.self, from: historicalData), legacy)

            model.selectPhotoData(photoFixture(), identifier: "test-photo")
            let photo = try XCTUnwrap(model.preparedPhoto)
            model.submitAnalysis(locale: .en)
            let operation = try XCTUnwrap(model.currentOperationId)
            let before = router.flowState
            XCTAssertEqual(before.conditions, legacy)

            // Cover direct sun as well as every other known choice, then clear it explicitly.
            for level in [LightLevel.brightDirect, .brightIndirect, .medium, .low, .unknown] {
                model.selectLightLevel(level)
                let known = level != .unknown
                var expected = before
                expected.conditions.lightLevel = level
                expected.conditions.lightSource = known ? .manual : .unknown
                expected.conditions.lightConfirmed = known
                XCTAssertEqual(router.flowState, expected)
                XCTAssertTrue(router.hasCompletedWelcome)
                XCTAssertEqual(model.preparedPhoto, photo)
                XCTAssertEqual(model.currentOperationId, operation)
                XCTAssertEqual(model.analysisError, "analysis.error.unavailable")
                XCTAssertFalse(model.isAnalyzing)
                XCTAssertFalse(model.isPreparingPhoto)
                XCTAssertNil(model.photoError)
                XCTAssertNil(model.preliminaryResult)
                XCTAssertNil(model.accessState)

                let data = try encoder.encode(router.flowState.conditions)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(object["light_level"] as? String, level.rawValue)
                XCTAssertEqual(object["light_source"] as? String, known ? "manual" : "unknown")
                XCTAssertEqual(object["light_confirmed"] as? Bool, known)
                XCTAssertEqual(try decoder.decode(CareConditionsInput.self, from: data), expected.conditions)
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

    private func serviceResult(
        mode: AnalysisMode = .diagnosis,
        status: IdentificationStatus = .resolved,
        labels: Bool = true,
        uploadedPhotoId: UUID? = nil
    ) -> AnalysisServiceResult {
        let resolved = status == .resolved
        if mode == .identification {
            let species: PhotoIdentificationResult.Species? = resolved ? .init(
                taxonId: UUID(), slug: "fixture-species", displayName: labels ? "Fixture species" : ""
            ) : nil
            return AnalysisServiceResult(identification: .init(
                jobId: UUID(), catalogueReleaseId: UUID(), species: species
            ), uploadedPhotoId: uploadedPhotoId)
        }
        return AnalysisServiceResult(
            analysis: PreliminaryAnalysis(
                id: UUID(), jobId: UUID(), kbReleaseId: UUID(), mode: mode,
                identificationStatus: status,
                plantId: resolved ? "fixture-species" : nil, genusId: nil,
                diagnosisStatus: resolved ? .conditionDetected : .unknown,
                candidates: [], selectedConditionId: resolved ? "fixture-condition" : nil,
                visualMarkers: [], evidenceBasis: [], limitations: ["Fixture limitation"],
                firstActionSummary: nil, controlIntervalDays: nil,
                analysisReceipt: ""
            ),
            speciesLabel: labels ? "Fixture species" : nil,
            conditionLabel: labels ? "Fixture condition" : nil,
            uploadedPhotoId: uploadedPhotoId
        )
    }

    func testInjectedServiceUsesPreparedGalleryPhotoForBothModes() async throws {
        for intent in [AddIntent.problem, .care] {
            let mode: AnalysisMode = intent == .problem ? .diagnosis : .identification
            let response = serviceResult(mode: mode)
            let service = GalleryAnalysisFixture(response: response)
            let model = AnalysisFlowModel(service: service)
            model.router.selectIntent(intent)
            if intent == .care { model.router.selectCareMethod(.scan) }
            let raw = photoFixture()
            model.selectPhotoData(raw, locale: .pl)
            XCTAssertEqual(model.router.flowState.currentStep, .analyzing)
            let task = try XCTUnwrap(model.submitAnalysis(locale: .en))
            await task.value

            let request = try XCTUnwrap(service.requests.first)
            XCTAssertEqual(service.requests.count, 1)
            XCTAssertEqual(request.photo, try AnalysisPhotoInput().preparePhoto(from: raw))
            XCTAssertEqual(request.flowId, model.router.flowState.flowId)
            XCTAssertEqual(request.intent, intent)
            XCTAssertEqual(request.mode, mode)
            XCTAssertEqual(request.locale, .pl)
            XCTAssertEqual(model.preliminaryResult, response.analysis)
            XCTAssertEqual(model.identificationResult, response.identification)
            XCTAssertEqual(model.speciesLabel, "Fixture species")
            XCTAssertEqual(model.conditionLabel, mode == .diagnosis ? "Fixture condition" : nil)
            XCTAssertEqual(model.router.flowState.currentStep, .preliminaryResult)
            XCTAssertFalse(model.isAnalyzing)
            XCTAssertNil(model.analysisError)
            XCTAssertNil(model.accessState)
            XCTAssertNil(model.submitAnalysis(locale: .en))
            XCTAssertEqual(service.requests.count, 1)
        }
    }

    func testIdentificationConfirmationRequiresResolvedResultAndItsUploadedPhoto() async throws {
        let photoId = UUID()
        let candidates = [
            serviceResult(mode: .identification, status: .unknown, uploadedPhotoId: photoId),
            serviceResult(mode: .identification),
            serviceResult(mode: .identification, uploadedPhotoId: photoId)
        ]
        for (index, result) in candidates.enumerated() {
            let service = GalleryAnalysisFixture(response: result)
            let model = AnalysisFlowModel(service: service)
            model.router.selectIntent(.care)
            model.router.selectCareMethod(.scan)
            model.selectPhotoData(photoFixture())
            let task = try XCTUnwrap(model.submitAnalysis(locale: .en))
            await task.value
            XCTAssertEqual(model.canConfirmPhotoIdentification, index == 2)
            XCTAssertNil(model.confirmedPhotoIdentification)
            XCTAssertNil(model.router.flowState.confirmedPlantId)
            model.confirmPhotoIdentification()
            if index == 2 {
                let identification = try XCTUnwrap(result.identification)
                let taxon = try XCTUnwrap(identification.species?.taxonId)
                XCTAssertEqual(model.confirmedPhotoIdentification, PhotoIdentificationSelection(
                    jobId: identification.jobId, photoAssetId: photoId, speciesSlug: "fixture-species", taxonId: taxon, ownerId: nil
                ))
                XCTAssertEqual(model.router.flowState.confirmedPlantId, "fixture-species")
                XCTAssertEqual(service.requests.count, 1)
                XCTAssertFalse(model.canConfirmPhotoIdentification)
            } else {
                XCTAssertNil(model.confirmedPhotoIdentification)
            }
            _ = model.beginPhotoSelection()
            XCTAssertNil(model.confirmedPhotoIdentification)
            XCTAssertNil(model.router.flowState.confirmedPlantId)
            XCTAssertFalse(model.canConfirmPhotoIdentification)
        }
    }

    func testInjectedUnknownOutOfScopeAndMissingLabelsRemainUncertain() async throws {
        for status in [IdentificationStatus.unknown, .outOfScope, .genusOnly, .resolved] {
            let response = serviceResult(status: status, labels: status != .resolved)
            let model = AnalysisFlowModel(service: GalleryAnalysisFixture(response: response))
            model.selectPhotoData(photoFixture())
            let task = try XCTUnwrap(model.submitAnalysis(locale: .en))
            await task.value
            XCTAssertEqual(model.preliminaryResult, response.analysis)
            XCTAssertNil(model.speciesLabel)
            XCTAssertNil(model.conditionLabel)
            XCTAssertEqual(model.preliminaryResult?.limitations, ["Fixture limitation"])
            XCTAssertEqual(model.router.flowState.currentStep, .preliminaryResult)
        }
    }

    func testExplicitRetryKeepsFrozenRequestAndOperationAfterProviderFailure() async throws {
        let service = GalleryAnalysisFixture(response: serviceResult())
        service.failure = AnalysisServiceFailure.retryableProvider
        let model = AnalysisFlowModel(service: service)
        model.selectLightLevel(.medium)
        model.selectPhotoData(photoFixture(), locale: .pl)
        let firstTask = try XCTUnwrap(model.submitAnalysis(locale: .en))
        await firstTask.value
        let original = try XCTUnwrap(model.frozenRequest)
        XCTAssertEqual(model.analysisError, "analysis.error.provider")
        XCTAssertNil(model.preliminaryResult)
        XCTAssertFalse(model.isAnalyzing)
        XCTAssertEqual(service.requests.count, 1)

        model.selectLightLevel(.low)
        model.selectWateringHabit(.frequent)
        service.failure = nil
        let retry = try XCTUnwrap(model.submitAnalysis(locale: .en))
        _ = model.submitAnalysis(locale: .en)
        await retry.value
        XCTAssertEqual(service.requests, [original, original])
        XCTAssertEqual(model.currentOperationId, original.operationId)
        XCTAssertEqual(original.locale, .pl)
        XCTAssertEqual(original.conditions.lightLevel, .medium)
        XCTAssertEqual(model.router.flowState.conditions.lightLevel, .low)
        XCTAssertNotNil(model.preliminaryResult)
    }

    func testExplicitInstallationUsesExistingPreparedPhotoAndHidesUnexpectedErrors() async throws {
        let model = AnalysisFlowModel()
        model.router.selectIntent(.problem)
        model.selectPhotoData(photoFixture())
        let prepared = try XCTUnwrap(model.preparedPhoto)
        XCTAssertEqual(model.router.flowState.currentStep, .careQuestions)
        model.submitAnalysis(locale: .en)
        XCTAssertEqual(model.analysisError, "analysis.error.unavailable")

        let service = GalleryAnalysisFixture(response: serviceResult())
        service.failure = NSError(
            domain: "private-provider-token", code: 401,
            userInfo: [NSLocalizedDescriptionKey: "secret raw failure"]
        )
        model.installAnalysisService(service)
        XCTAssertEqual(model.preparedPhoto, prepared)
        let task = try XCTUnwrap(model.submitAnalysis(locale: .pl))
        await task.value
        XCTAssertEqual(service.requests.first?.photo, prepared)
        XCTAssertEqual(model.analysisError, "analysis.error.failed")
        XCTAssertNil(model.preliminaryResult)
        XCTAssertNil(model.speciesLabel)
        XCTAssertNil(model.conditionLabel)
    }

    func testCancelledAndReplacedOperationsIgnoreLateServiceCompletion() async throws {
        let response = serviceResult()
        let service = GalleryAnalysisFixture(response: response)
        service.suspend = true
        let model = AnalysisFlowModel(service: service)
        model.selectPhotoData(photoFixture())
        let cancelled = try XCTUnwrap(model.submitAnalysis(locale: .en))
        await service.waitForRequestCount(1)
        let oldOperation = try XCTUnwrap(model.currentOperationId)
        model.returnFromAnalysis()
        service.completeNext(response)
        await cancelled.value
        XCTAssertNil(model.preliminaryResult)
        XCTAssertNil(model.currentOperationId)
        XCTAssertEqual(model.router.flowState.currentStep, .selectIntent)

        model.selectPhotoData(photoFixture())
        let replaced = try XCTUnwrap(model.submitAnalysis(locale: .en))
        await service.waitForRequestCount(2)
        let replacedOperation = try XCTUnwrap(model.currentOperationId)
        XCTAssertNotEqual(replacedOperation, oldOperation)
        model.selectPhotoData(photoFixture(), locale: .pl)
        let current = try XCTUnwrap(model.submitAnalysis(locale: .en))
        await service.waitForRequestCount(3)
        let currentOperation = try XCTUnwrap(model.currentOperationId)
        XCTAssertNotEqual(currentOperation, replacedOperation)
        service.completeNext(response)
        await replaced.value
        XCTAssertTrue(model.isAnalyzing)
        XCTAssertNil(model.preliminaryResult)
        XCTAssertEqual(model.currentOperationId, currentOperation)
        service.completeNext(response)
        await current.value
        XCTAssertEqual(model.preliminaryResult, response.analysis)
        XCTAssertEqual(model.router.flowState.currentStep, .preliminaryResult)
    }

    func testFailedOrObsoletePhotoLoadCannotSubmitPreviousBytes() async throws {
        let service = GalleryAnalysisFixture(response: serviceResult())
        let model = AnalysisFlowModel(service: service)
        model.selectPhotoData(photoFixture())
        let first = try XCTUnwrap(model.submitAnalysis(locale: .en))
        await first.value
        model.selectPhotoData(Data([0, 1, 2]))
        XCTAssertNil(model.preparedPhoto)
        XCTAssertNil(model.frozenRequest)
        XCTAssertNil(model.preliminaryResult)
        XCTAssertNotNil(model.photoError)
        XCTAssertEqual(model.router.flowState.currentStep, .selectPhoto)
        XCTAssertNil(model.submitAnalysis(locale: .en))
        XCTAssertEqual(service.requests.count, 1)

        let obsolete = model.beginPhotoSelection()
        let newest = model.beginPhotoSelection()
        model.completePhotoSelection(photoFixture(), selectionId: obsolete, locale: .en)
        XCTAssertNil(model.preparedPhoto)
        model.failPhotoSelection(newest)
        XCTAssertFalse(model.isPreparingPhoto)
        XCTAssertNotNil(model.photoError)
        let cancelled = model.beginPhotoSelection()
        model.showCatalogue()
        model.completePhotoSelection(photoFixture(), selectionId: cancelled, locale: .en)
        XCTAssertNil(model.preparedPhoto)
        XCTAssertEqual(model.router.flowState.currentStep, .selectCatalogueSpecies)
        let back = model.beginPhotoSelection()
        model.returnFromAnalysis()
        model.completePhotoSelection(photoFixture(), selectionId: back, locale: .en)
        XCTAssertNil(model.preparedPhoto)
        XCTAssertEqual(model.router.flowState.currentStep, .selectIntent)
        XCTAssertEqual(service.requests.count, 1)
    }
}

@MainActor
private final class GalleryAnalysisFixture: AnalysisService {
    let response: AnalysisServiceResult
    var failure: (any Error)?
    var suspend = false
    private(set) var requests: [AnalysisServiceRequest] = []
    private var pending: [CheckedContinuation<AnalysisServiceResult, any Error>] = []
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var awaitedCount = 0

    init(response: AnalysisServiceResult) {
        self.response = response
    }

    func analyze(_ request: AnalysisServiceRequest) async throws -> AnalysisServiceResult {
        requests.append(request)
        if requests.count >= awaitedCount {
            requestWaiter?.resume()
            requestWaiter = nil
        }
        if suspend {
            // Deliberately ignores Task cancellation to exercise the model's generation guard.
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        if let failure { throw failure }
        return response
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        awaitedCount = count
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func completeNext(_ response: AnalysisServiceResult) {
        pending.removeFirst().resume(returning: response)
    }
}
