import XCTest
import UIKit
import ImageIO
@testable import Plants

@MainActor
final class FirstHelpUnitTests: XCTestCase {
    private func quotaDenialFixture(
        mode: AnalysisAccessWireDTO.AnalysisMode,
        guest: Bool = true,
        reason: String? = "starter_exhausted",
        remaining: Int = 0,
        job: UUID? = nil
    ) throws -> AnalysisAccessWireDTO {
        let null = NSNull()
        let modes = Dictionary(uniqueKeysWithValues: ["identification", "diagnosis"].map { key in
            let targeted = key == mode.rawValue
            let value: [String: Any] = [
                "mode": key, "allowed": !targeted,
                "activeQuotaKind": "starter_\(key)",
                "remaining": targeted ? remaining : 1, "limit": 1,
                "inProgressJobId": targeted ? (job.map { $0.uuidString as Any } ?? null) : null,
                "nextResetAt": null,
                "reason": targeted ? (reason.map { $0 as Any } ?? null) : null
            ]
            return (key, value)
        })
        let payload: [String: Any] = [
            "owner_id": UUID().uuidString, "is_guest": guest,
            "starter": [
                "identification_remaining": mode == .identification ? remaining : 1,
                "diagnosis_remaining": mode == .diagnosis ? remaining : 1,
                "identification_in_progress_job_id": null,
                "diagnosis_in_progress_job_id": null,
                "first_starter_success_at": null
            ],
            "monthly": [
                "quota_kind": guest ? null : "free_monthly" as Any,
                "registered_at": null, "period_start": null, "period_end": null,
                "limit": null, "consumed": null, "reserved": null, "remaining": null,
                "status": guest ? "not_applicable" : "history_unresolved"
            ],
            "modes": modes
        ]
        return try JSONDecoder().decode(
            AnalysisAccessWireDTO.self, from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    func testConfirmedGuestExhaustionExplainsOnlyTheUsedModeInBothLocales() throws {
        for mode in [AnalysisAccessWireDTO.AnalysisMode.diagnosis, .identification] {
            let access = try quotaDenialFixture(mode: mode)
            let presentation = AnalysisQuotaDenialPresentation(access: access, mode: mode)
            XCTAssertEqual(presentation, .guestExhausted(mode))
            XCTAssertFalse(presentation.showsRetry)
            XCTAssertEqual(presentation.message(locale: .en), mode == .diagnosis
                ? "Your free guest diagnosis has already been used. You can still browse the catalogue."
                : "Your free guest identification has already been used. You can still browse the catalogue.")
            XCTAssertEqual(presentation.message(locale: .pl), mode == .diagnosis
                ? "Bezpłatna diagnoza dla gościa została już wykorzystana. Nadal możesz przeglądać katalog."
                : "Bezpłatne rozpoznanie gatunku dla gościa zostało już wykorzystane. Nadal możesz przeglądać katalog.")
            let other: AnalysisAccessWireDTO.AnalysisMode = mode == .diagnosis ? .identification : .diagnosis
            XCTAssertEqual(access.modes[other.rawValue]?.allowed, true)
            XCTAssertNotEqual(AnalysisQuotaDenialPresentation(access: access, mode: other), .guestExhausted(other))
        }
    }

    func testUnconfirmedGuestDenialsAndPermanentUsersRetainRetry() throws {
        for mode in [AnalysisAccessWireDTO.AnalysisMode.diagnosis, .identification] {
            let snapshots = try [
                quotaDenialFixture(mode: mode, reason: nil),
                quotaDenialFixture(mode: mode, reason: "quota_history_unresolved"),
                quotaDenialFixture(mode: mode, reason: "starter_in_progress", remaining: 1, job: UUID()),
                quotaDenialFixture(mode: mode, job: UUID()),
                quotaDenialFixture(mode: mode, remaining: 1),
                quotaDenialFixture(mode: mode, guest: false)
            ]
            for access in snapshots {
                let presentation = AnalysisQuotaDenialPresentation(access: access, mode: mode)
                XCTAssertEqual(presentation, .temporary)
                XCTAssertTrue(presentation.showsRetry)
                XCTAssertEqual(presentation.message(locale: .en), "Photo analysis is currently unavailable.")
                XCTAssertEqual(presentation.message(locale: .pl), "Analiza zdjęcia jest teraz niedostępna.")
            }
            // A failed network read has no validated snapshot, so it must remain retryable.
            let network = AnalysisQuotaDenialPresentation(access: nil, mode: mode)
            XCTAssertEqual(network, .unavailable)
            XCTAssertTrue(network.showsRetry)
            XCTAssertEqual(network.message(locale: .en), "Couldn’t check analysis quota.")
            XCTAssertEqual(network.message(locale: .pl), "Nie udało się sprawdzić limitu analiz.")
        }
    }

    private func explanationFixture(
        mode: AnalysisMode = .diagnosis,
        status: DiagnosisStatus = .conditionDetected,
        identification: IdentificationStatus = .resolved,
        availability: PlanAvailability = .available,
        context: AnalysisContextState = .current,
        condition: String? = "overwatering",
        summary: String? = "  Check the potting mix. \n",
        evidence: [String] = [],
        limitations: [String] = [],
        polish: Bool = false
    ) -> InitialDiagnosisExplanation {
        InitialDiagnosisExplanation(result: PreliminaryAnalysis(
            id: UUID(), jobId: UUID(), kbReleaseId: UUID(), mode: mode,
            identificationStatus: identification, plantId: "monstera_deliciosa", genusId: nil,
            diagnosisStatus: status, candidates: [], selectedConditionId: condition,
            visualMarkers: ["standing_water_in_saucer"], evidenceBasis: evidence, limitations: limitations,
            firstActionSummary: summary, controlIntervalDays: nil, contextState: context,
            planAvailability: availability, analysisReceipt: ""
        ), polish: polish)
    }

    func testInitialDiagnosisShowsOnlyApplicableCanonicalAction() {
        XCTAssertEqual(explanationFixture().firstAction, "Check the potting mix.")
        XCTAssertEqual(explanationFixture(summary: "Sprawdź podłoże.", polish: true).firstAction,
                       "Sprawdź podłoże.")
        XCTAssertNil(explanationFixture(summary: nil).firstAction)
        XCTAssertNil(explanationFixture(summary: " \n\t").firstAction)
        XCTAssertNil(explanationFixture(condition: nil).firstAction)
        XCTAssertNil(explanationFixture(condition: " \n").firstAction)
        XCTAssertNil(explanationFixture(context: .stale).firstAction)
        XCTAssertNil(explanationFixture(mode: .identification).firstAction)
        for availability in PlanAvailability.allCases where availability != .available {
            XCTAssertNil(explanationFixture(availability: availability).firstAction)
        }
        for identification in [IdentificationStatus.unknown, .genusOnly, .outOfScope] {
            XCTAssertNil(explanationFixture(identification: identification).firstAction)
        }
    }

    func testHealthyAndUncertainResultsDoNotOfferAction() {
        for status in [DiagnosisStatus.healthy, .unknown, .outOfScope] {
            XCTAssertNil(explanationFixture(status: status).firstAction)
        }
        let codes = ["no_pathological_markers_detected"]
        XCTAssertTrue(explanationFixture(status: .healthy, evidence: codes).evidence.isEmpty)
        XCTAssertTrue(explanationFixture(status: .healthy, evidence: codes, polish: true).evidence.isEmpty)
        XCTAssertTrue(explanationFixture(status: .unknown).evidence.isEmpty)
    }

    func testInitialStockCopyPreservesWarningsAndAction() {
        let stocks = [
            [
                "No problem detected. No published basic-care action is provided in this result.",
                "Insufficient data to select an applicable action.",
                "The result is ambiguous; no treatment has been selected.",
                "No published, applicable first aid or check interval is available."
            ],
            [
                "Nie wykryto problemu. Brak opublikowanego działania podstawowej pielęgnacji w tym wyniku.",
                "Za mało danych do wyboru odpowiedniego działania.",
                "Niejednoznaczny wynik; nie wybrano leczenia.",
                "Brak opublikowanej, mającej zastosowanie pierwszej pomocy i terminu kontroli."
            ]
        ]
        for (index, stock) in stocks.enumerated() {
            let polish = index == 1
            let warning = polish ? "Korzenie nie są widoczne." : "Roots are not visible."
            let context = polish ? "Warunki są nieaktualne." : "Care conditions are stale."
            let warnings = [warning, context, stock[0] + " " + warning]
            let healthy = explanationFixture(
                status: .healthy, evidence: ["no_pathological_markers_detected", "yellowing_lower_leaves"],
                limitations: [stock[0]] + warnings, polish: polish
            )
            XCTAssertEqual(healthy.limitations, warnings)
            XCTAssertEqual(healthy.evidence, [polish
                ? "Dolne liście wydają się żółte." : "Lower leaves appear yellow."])
            for reason in [stock[1], stock[2]] {
                let uncertain = explanationFixture(
                    status: .unknown, evidence: ["standing_water_in_saucer"],
                    limitations: [reason, stock[3]] + warnings, polish: polish
                )
                XCTAssertEqual(uncertain.uncertaintyStatus, reason)
                XCTAssertEqual(uncertain.limitations, warnings)
                XCTAssertEqual(uncertain.evidence.count, 1)
                XCTAssertNil(uncertain.firstAction)
            }
            let action = polish ? "Sprawdź podłoże." : "Check the potting mix."
            let problem = explanationFixture(
                summary: action, limitations: stock + warnings, polish: polish
            )
            XCTAssertEqual(problem.firstAction, action)
            XCTAssertEqual(problem.limitations, stock + warnings)
            XCTAssertEqual(explanationFixture(
                status: .unknown, limitations: [stock[1], stock[2]], polish: polish
            ).limitations, [stock[1], stock[2]])
            XCTAssertEqual(explanationFixture(
                mode: .identification, limitations: stock, polish: polish
            ).limitations, stock)
        }
    }

    func testCanonicalEvidenceIsLocalizedOrderedAndDeduplicated() {
        let codes = ["standing_water_in_saucer", "protocol_internal",
                     "yellowing_lower_leaves", "standing_water_in_saucer"]
        XCTAssertEqual(explanationFixture(evidence: codes).evidence, [
            "Standing water is visible in the saucer.", "Lower leaves appear yellow."
        ])
        XCTAssertEqual(explanationFixture(evidence: codes, polish: true).evidence, [
            "Na podstawce widać stojącą wodę.", "Dolne liście wydają się żółte."
        ])
        XCTAssertTrue(explanationFixture(evidence: ["unknown_code"]).evidence.isEmpty)
        XCTAssertTrue(explanationFixture().evidence.isEmpty)
        XCTAssertTrue(explanationFixture(mode: .identification, evidence: codes).evidence.isEmpty)
    }

    func testPhotoCameraAccessRequiresBothHardwareAndPermission() {
        XCTAssertEqual(PhotoCameraAccess(available: true, authorization: .authorized), .ready)
        XCTAssertEqual(PhotoCameraAccess(available: true, authorization: .notDetermined), .request)
        XCTAssertEqual(PhotoCameraAccess(available: true, authorization: .denied), .denied)
        XCTAssertEqual(PhotoCameraAccess(available: true, authorization: .restricted), .denied)
        XCTAssertEqual(PhotoCameraAccess(available: false, authorization: .authorized), .unavailable)
        XCTAssertEqual(PhotoCameraAccess(available: false, authorization: .notDetermined), .unavailable)
        XCTAssertEqual(PhotoCameraAccess(available: false, authorization: .denied), .denied)
        XCTAssertEqual(PhotoCameraAccess(available: false, authorization: .restricted), .denied)
    }

    func testCameraNoticesAreLocalizedAndKeepGalleryFallback() {
        XCTAssertEqual(PhotoCameraAccess.denied.noticeText(polish: true),
                       "Dostęp do aparatu jest wyłączony. Nadal możesz wybrać zdjęcie z galerii.")
        XCTAssertEqual(PhotoCameraAccess.unavailable.noticeText(polish: true),
                       "Aparat jest niedostępny. Nadal możesz wybrać zdjęcie z galerii.")
        XCTAssertEqual(PhotoCameraAccess.denied.noticeText(polish: false),
                       "Camera access is off. You can still choose a photo.")
        XCTAssertEqual(PhotoCameraAccess.unavailable.noticeText(polish: false),
                       "Camera is unavailable. You can still choose a photo.")
    }

    // Image data is a test fixture only; production must never offer generated photos.
    private func photoFixture(largeOver10MB: Bool = false, color: UIColor = .systemGreen) -> Data {
        let size = CGSize(width: 600, height: 800)
        let renderer = UIGraphicsImageRenderer(size: size)
        var data = renderer.pngData { context in
            color.setFill()
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

    func testInitialContextMapsEveryLightAndPersistsDrainageWithoutChangingLastWatered() throws {
        for (level, wire) in [
            (LightLevel.low, "low"), (.medium, "medium"),
            (.brightIndirect, "bright_indirect"), (.brightDirect, "direct_sun"), (.unknown, "unknown")
        ] {
            for confirmed in [false, true] {
                let conditions = CareConditionsInput(
                    lightLevel: level, lightConfirmed: confirmed, wateringHabit: .frequent,
                    lastWatered: .within7Days, drainage: .yes
                )
                let data = try JSONEncoder().encode(InitialDiagnosisContext(conditions: conditions))
                let body = try JSONDecoder().decode([String: String].self, from: data)
                XCTAssertEqual(body, [
                    "light": confirmed ? wire : "unknown", "watering_frequency": "frequent", "drainage": "yes"
                ])
                let stored = try JSONEncoder().encode(conditions)
                XCTAssertEqual(try JSONDecoder().decode(CareConditionsInput.self, from: stored), conditions)
            }
        }
        for answer in DrainageAnswer.allCases {
            let conditions = CareConditionsInput(drainage: answer)
            let data = try JSONEncoder().encode(conditions)
            XCTAssertEqual(try JSONDecoder().decode(CareConditionsInput.self, from: data).drainage, answer)
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
        XCTAssertEqual(legacy.drainage, .unknown)
        XCTAssertEqual(legacy.lastWatered, .within3Days)

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
            XCTAssertEqual(model.router.flowState.currentStep, intent == .problem ? .careQuestions : .analyzing)
            let task = try XCTUnwrap(model.submitAnalysis(locale: .pl))
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

    func testRepeatDiagnosisStartsWithPhotoAndRetriesTheSameTargetAndInput() async throws {
        let target = RepeatDiagnosisTarget(plantId: UUID(), ownerId: UUID())
        let response = serviceResult()
        let service = GalleryAnalysisFixture(response: response)
        service.failure = URLError(.networkConnectionLost)
        let model = AnalysisFlowModel(repeatDiagnosisTarget: target, service: service)

        XCTAssertEqual(model.router.flowState.currentStep, .selectPhoto)
        let raw = photoFixture()
        model.selectPhotoData(raw, locale: .en)
        XCTAssertEqual(model.router.flowState.currentStep, .analyzing)
        let first = try XCTUnwrap(model.submitAnalysis(locale: .en))
        await first.value
        XCTAssertEqual(model.analysisError, "analysis.error.failed")
        XCTAssertNil(model.preliminaryResult)

        let request = try XCTUnwrap(service.requests.first)
        XCTAssertEqual(request.repeatDiagnosisTarget, target)
        XCTAssertEqual(request.photo, try AnalysisPhotoInput().preparePhoto(from: raw))
        XCTAssertEqual(request.mode, .diagnosis)
        XCTAssertEqual(request.locale, .en)
        service.failure = nil
        let retry = try XCTUnwrap(model.submitAnalysis(locale: .pl))
        await retry.value

        XCTAssertEqual(service.requests, [request, request])
        XCTAssertEqual(model.preliminaryResult, response.analysis)
        XCTAssertEqual(model.router.flowState.currentStep, .preliminaryResult)
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
        model.selectPhotoData(photoFixture(), locale: .pl)
        XCTAssertEqual(model.router.flowState.currentStep, .careQuestions)
        XCTAssertNil(model.frozenRequest)
        XCTAssertTrue(service.requests.isEmpty)
        model.selectLightLevel(.medium)
        model.advanceQuestionOrStartAnalysis(locale: .pl)
        model.selectWateringHabit(.sparse)
        model.advanceQuestionOrStartAnalysis(locale: .pl)
        model.selectDrainage(.no)
        model.advanceQuestionOrStartAnalysis(locale: .pl)
        let firstTask = try XCTUnwrap(model.submitAnalysis(locale: .en))
        await firstTask.value
        let original = try XCTUnwrap(model.frozenRequest)
        XCTAssertEqual(model.analysisError, "analysis.error.provider")
        XCTAssertNil(model.preliminaryResult)
        XCTAssertFalse(model.isAnalyzing)
        XCTAssertEqual(service.requests.count, 1)

        model.selectLightLevel(.low)
        model.selectWateringHabit(.frequent)
        model.selectDrainage(.yes)
        service.failure = nil
        let retry = try XCTUnwrap(model.submitAnalysis(locale: .en))
        _ = model.submitAnalysis(locale: .en)
        await retry.value
        XCTAssertEqual(service.requests, [original, original])
        XCTAssertEqual(model.currentOperationId, original.operationId)
        XCTAssertEqual(original.locale, .pl)
        XCTAssertEqual(original.conditions.lightLevel, .medium)
        XCTAssertEqual(original.conditions.wateringHabit, .sparse)
        XCTAssertEqual(original.conditions.drainage, .no)
        XCTAssertEqual(model.router.flowState.conditions.drainage, .yes)
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

    func testQuestionReplacementChoicesAndPickerCancellationKeepAnswersAndPosition() throws {
        for locale in [SupportedLocale.en, .pl] {
            for step in 1...3 {
                let service = GalleryAnalysisFixture(response: serviceResult())
                let model = AnalysisFlowModel(service: service)
                model.router.selectIntent(.problem)
                model.selectPhotoData(photoFixture(), locale: locale)
                model.selectLightLevel(.medium)
                model.selectWateringHabit(.sparse)
                model.selectDrainage(.no)
                model.router.flowState.questionIndex = step
                let before = model.router.flowState
                let photo = try XCTUnwrap(model.preparedPhoto)
                model.replaceQuestionPhoto()
                XCTAssertTrue(model.isReplacingQuestionPhoto)
                XCTAssertEqual(model.router.flowState.currentStep, .selectPhoto)
                XCTAssertFalse(model.isPreparingPhoto)
                XCTAssertEqual(model.preparedPhoto, photo)
                XCTAssertEqual(model.router.flowState.conditions, before.conditions)
                XCTAssertEqual(model.router.flowState.questionIndex, step)
                XCTAssertTrue(service.requests.isEmpty)
                // Cancelling a system picker produces no selection callback.
                model.navigateBack()
                XCTAssertEqual(model.router.flowState, before)
                XCTAssertFalse(model.isReplacingQuestionPhoto)
                XCTAssertEqual(model.preparedPhoto, photo)
                XCTAssertTrue(service.requests.isEmpty)
            }
        }
    }

    func testInvalidThenValidQuestionReplacementUsesNewBytesAndIgnoresOldOperation() async throws {
        let response = serviceResult()
        let service = GalleryAnalysisFixture(response: response)
        service.suspend = true
        let model = AnalysisFlowModel(service: service)
        model.router.selectIntent(.problem)
        model.selectPhotoData(photoFixture())
        model.selectLightLevel(.low)
        model.selectWateringHabit(.sparse)
        model.selectDrainage(.yes)
        model.router.flowState.questionIndex = 2
        let conditions = model.router.flowState.conditions
        let originalPhoto = try XCTUnwrap(model.preparedPhoto)
        let oldTask = try XCTUnwrap(model.submitAnalysis(locale: .en))
        await service.waitForRequestCount(1)
        let oldOperation = try XCTUnwrap(model.currentOperationId)
        model.navigateBack()
        model.replaceQuestionPhoto()
        model.selectPhotoData(Data([0, 1, 2]))
        XCTAssertNotNil(model.photoError)
        XCTAssertNil(model.preparedPhoto)
        XCTAssertNil(model.frozenRequest)
        XCTAssertEqual(model.router.flowState.conditions, conditions)
        XCTAssertEqual(model.router.flowState.questionIndex, 2)
        XCTAssertEqual(service.requests.count, 1)
        let obsolete = model.beginPhotoSelection()
        let selection = model.beginPhotoSelection()
        model.completePhotoSelection(photoFixture(), selectionId: obsolete, locale: .pl)
        XCTAssertNil(model.preparedPhoto)
        let replacement = photoFixture(color: .systemBlue)
        model.completePhotoSelection(replacement, selectionId: selection, locale: .pl)
        let prepared = try XCTUnwrap(model.preparedPhoto)
        XCTAssertEqual(prepared, try AnalysisPhotoInput().preparePhoto(from: replacement))
        XCTAssertNotEqual(prepared.cloudNormalizedJPEG, originalPhoto.cloudNormalizedJPEG)
        XCTAssertEqual(model.router.flowState.currentStep, .careQuestions)
        XCTAssertEqual(model.router.flowState.questionIndex, 2)
        XCTAssertEqual(model.router.flowState.conditions, conditions)
        XCTAssertFalse(model.isReplacingQuestionPhoto)
        XCTAssertNil(model.currentOperationId)
        XCTAssertEqual(service.requests.count, 1)
        model.advanceQuestionOrStartAnalysis(locale: .pl)
        XCTAssertEqual(model.router.flowState.questionIndex, 3)
        XCTAssertEqual(service.requests.count, 1)
        model.advanceQuestionOrStartAnalysis(locale: .pl)
        let newTask = try XCTUnwrap(model.submitAnalysis(locale: .pl))
        await service.waitForRequestCount(2)
        let newOperation = try XCTUnwrap(model.currentOperationId)
        XCTAssertNotEqual(newOperation, oldOperation)
        XCTAssertEqual(service.requests.last?.photo, prepared)
        XCTAssertEqual(service.requests.last?.conditions, conditions)
        XCTAssertEqual(service.requests.last?.locale, .pl)
        service.completeNext(response)
        await oldTask.value
        XCTAssertNil(model.preliminaryResult)
        XCTAssertTrue(model.isAnalyzing)
        XCTAssertEqual(model.currentOperationId, newOperation)
        service.completeNext(response)
        await newTask.value
        XCTAssertEqual(model.preliminaryResult, response.analysis)
        XCTAssertEqual(service.requests.count, 2)
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
