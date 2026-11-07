import XCTest
@testable import Plants

@MainActor
final class FirstHelpUnitTests: XCTestCase {
    func testLargeOver10MBPhotoCompressesStripsMetadataAndResizesTo1568Px() throws {
        let largeRawData = CareQuestionsView.makeSampleImageData(largeOver10MB: true)
        XCTAssertGreaterThan(largeRawData.count, 10 * 1024 * 1024)

        let input = AnalysisPhotoInput()
        let prepared = try input.preparePhoto(from: largeRawData)

        XCTAssertLessThanOrEqual(prepared.cloudNormalizedJPEG.count, AnalysisPhotoInput.maxCloudBytes)
        XCTAssertLessThanOrEqual(max(prepared.aiWidthPx, prepared.aiHeightPx), 1568)
        XCTAssertTrue(prepared.strippedExifAndGps)

        // Corrupt / unreadable data is rejected
        XCTAssertThrowsError(try input.preparePhoto(from: Data([0x00, 0x01, 0x02, 0x03]))) { error in
            XCTAssertEqual(error as? PhotoInputError, .unreadableOrCorruptImage)
        }
    }

    func testBackNavigationPreservesPhotoAndAnswersAndRetryDoesNotDoubleDeductQuota() {
        let model = AnalysisFlowModel()
        model.router.selectIntent(.problem)
        let photoData = CareQuestionsView.makeSampleImageData(largeOver10MB: false)
        model.selectPhotoData(photoData, identifier: "photo_1")

        // Step 1: select unknown light, then camera estimate
        model.selectLightLevel(.unknown)
        XCTAssertEqual(model.router.flowState.conditions.lightLevel, .unknown)
        model.applyEstimatedLighting(.brightDirect)
        // Direct sun is never auto-selected by camera estimation (FR-034)
        XCTAssertEqual(model.router.flowState.conditions.lightLevel, .brightIndirect)
        XCTAssertEqual(model.router.flowState.conditions.lightSource, .cameraEstimate)

        model.advanceQuestionOrStartAnalysis(locale: .pl)
        XCTAssertEqual(model.router.flowState.questionIndex, 2)

        // Step 2: select watering habit and navigate back -> Step 1 answer and photo are preserved!
        model.selectWateringHabit(.moderate)
        model.router.navigateBack()
        XCTAssertEqual(model.router.flowState.questionIndex, 1)
        XCTAssertEqual(model.router.flowState.conditions.lightLevel, .brightIndirect)
        XCTAssertNotNil(model.preparedPhoto)

        // Advance to Step 3 and select unknown
        model.advanceQuestionOrStartAnalysis(locale: .pl)
        model.advanceQuestionOrStartAnalysis(locale: .pl)
        XCTAssertEqual(model.router.flowState.questionIndex, 3)
        model.selectLastWatered(.unknown)

        // Simulate transient network failure on first submit -> retry succeeds and deducts starter_diagnosis only ONCE
        model.shouldFailNextAttemptForTesting = true
        model.advanceQuestionOrStartAnalysis(locale: .pl)
        XCTAssertEqual(model.analysisError, "analysis.error.network_retryable")
        XCTAssertEqual(model.quotaDeductionCount, 0)
        let firstOpId = model.currentOperationId
        XCTAssertNotNil(firstOpId)

        // Retry with same operationId
        model.submitAnalysis(locale: .pl)
        XCTAssertNil(model.analysisError)
        XCTAssertEqual(model.currentOperationId, firstOpId)
        XCTAssertEqual(model.quotaDeductionCount, 1)
        XCTAssertEqual(model.accessState.diagnosisQuota.remaining, 0)
        // Starter identification remains untouched (1/1)!
        XCTAssertEqual(model.accessState.identificationQuota.remaining, 1)
        XCTAssertNotNil(model.preliminaryResult?.firstActionSummary)

        // Starting a new operation after starter_diagnosis is exhausted returns quota_exhausted while keeping catalogue open
        model.currentOperationId = nil
        model.submitAnalysis(locale: .pl)
        XCTAssertEqual(model.analysisError, "analysis.error.quota_exhausted")
        XCTAssertTrue(model.accessState.canAlwaysUseCatalogue)
    }
}
