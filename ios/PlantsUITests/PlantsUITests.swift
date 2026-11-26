import XCTest

final class PlantsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOrdinaryLaunchShowsPhotoAndCollectionRoutes() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["welcome.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["welcome.check"].exists)
        XCTAssertTrue(app.buttons["welcome.identify"].exists)
        XCTAssertTrue(app.buttons["welcome.catalogue"].exists)
        XCTAssertTrue(app.buttons["collection.open"].exists)
        XCTAssertFalse(app.segmentedControls["welcome.language.picker"].exists)
    }

    @MainActor
    func testOrdinaryPolishHomeShowsOfflinePhotoAvailabilityAndBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(pl)", "-AppleLocale", "pl_PL"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Jak się ma Twoja roślina?"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["welcome.title"].label, "Narat")
        XCTAssertTrue(app.staticTexts["Dodaj zdjęcie, aby sprawdzić, czego może potrzebować Twoja roślina."].exists)
        XCTAssertEqual(app.buttons["welcome.check"].label, "Sprawdź zdrowie rośliny")
        XCTAssertEqual(app.buttons["welcome.identify"].label, "Rozpoznaj gatunek")
        XCTAssertEqual(app.buttons["welcome.catalogue"].label, "Przeglądaj katalog")
        XCTAssertEqual(app.buttons["collection.open"].label, "Moje rośliny")
        XCTAssertFalse(app.segmentedControls["welcome.language.picker"].exists)

        // The local QA build has no backend configuration. Its ordinary photo
        // routes are unavailable; do not substitute fixtures or start a session.
        let unavailable = app.staticTexts["welcome.unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
        XCTAssertEqual(unavailable.label, "Narat nie może się teraz połączyć. Sprawdź ustawienia połączenia aplikacji.")
        XCTAssertFalse(app.buttons["welcome.check"].isEnabled)
        XCTAssertFalse(app.buttons["welcome.identify"].isEnabled)
        XCTAssertFalse(app.buttons["collection.open"].isEnabled)
        XCTAssertFalse(app.buttons["photo.select.gallery"].exists)

        app.buttons["welcome.catalogue"].tap()
        let error = app.staticTexts["catalogue.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Nie udało się pobrać katalogu.")
        XCTAssertEqual(app.buttons["catalogue.retry"].label, "Spróbuj ponownie")
        let back = app.buttons["catalogue.back"]
        XCTAssertEqual(back.label, "Wstecz")
        back.tap()
        XCTAssertTrue(app.buttons["welcome.check"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["welcome.check"].label, "Sprawdź zdrowie rośliny")
        XCTAssertTrue(unavailable.exists)
    }

    @MainActor
    func testOrdinaryAccessibilityTextSizeKeepsShortcutsReachable() throws {
        for language in ["en", "pl"] {
            let app = XCUIApplication()
            let locale = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "pl" ? "pl_PL" : "en_US"]
            app.launchArguments = locale + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            app.launch()
            let title = app.staticTexts["welcome.title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            let standardTitleHeight = title.frame.height
            app.terminate()

            // UIKit's OS preference only; the application has no test-size override.
            app.launchArguments = locale + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            app.launch()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            // Fail if the platform ignores the preference: ordinary-size navigation
            // must never be reported as accessibility-size coverage.
            XCTAssertGreaterThan(title.frame.height, standardTitleHeight * 1.5)
            let collection = app.buttons["collection.open"]
            XCTAssertEqual(collection.label, language == "pl" ? "Moje rośliny" : "My plants")
            XCTAssertGreaterThanOrEqual(collection.frame.minY, title.frame.maxY)
            XCTAssertGreaterThanOrEqual(collection.frame.height, 44)
            XCTAssertFalse(collection.isEnabled)
            XCTAssertEqual(app.buttons["welcome.check"].label, language == "pl" ? "Sprawdź zdrowie rośliny" : "Check plant health")
            XCTAssertEqual(app.buttons["welcome.identify"].label, language == "pl" ? "Rozpoznaj gatunek" : "Identify species")
            XCTAssertFalse(app.buttons["welcome.check"].isEnabled)
            XCTAssertFalse(app.buttons["welcome.identify"].isEnabled)

            let scroll = app.scrollViews.firstMatch
            let catalogue = app.buttons["welcome.catalogue"]
            let initialY = catalogue.frame.minY
            XCTAssertGreaterThan(catalogue.frame.maxY, scroll.frame.maxY)
            for _ in 0..<8 {
                if scroll.frame.contains(catalogue.frame) && catalogue.isHittable { break }
                scroll.swipeUp()
            }
            XCTAssertLessThan(catalogue.frame.minY, initialY)
            XCTAssertTrue(scroll.frame.contains(catalogue.frame))
            XCTAssertTrue(catalogue.isHittable)
            XCTAssertGreaterThanOrEqual(catalogue.frame.height, 44)
            XCTAssertEqual(catalogue.label, language == "pl" ? "Przeglądaj katalog" : "Browse catalogue")
            catalogue.tap()
            XCTAssertTrue(app.staticTexts["catalogue.error"].waitForExistence(timeout: 5))
            app.buttons["catalogue.back"].tap()
            XCTAssertTrue(app.buttons["welcome.check"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testDiagnosisSavePresentationEnglish() { verifyResultSavePresentation(mode: "diagnosis", polish: false) }

    @MainActor
    func testDiagnosisSavePresentationPolish() { verifyResultSavePresentation(mode: "diagnosis", polish: true) }

    @MainActor
    func testIdentificationSavePresentationEnglish() { verifyResultSavePresentation(mode: "identification", polish: false) }

    @MainActor
    func testIdentificationSavePresentationPolish() { verifyResultSavePresentation(mode: "identification", polish: true) }

    @MainActor
    func testStandaloneCatalogueKeepsSpeciesAndScientificName() {
        for polish in [false, true] {
            let app = openSavePresentationFixture(polish: polish)
            defer { app.terminate() }
            let scientific = app.staticTexts["catalogue.selected.scientific"]
            XCTAssertTrue(scientific.waitForExistence(timeout: 15))
            XCTAssertEqual(scientific.label, "Nephrolepis exaltata")
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", polish ? "Paproć" : "Fern")).count, 1)
            XCTAssertFalse(app.staticTexts["analysis.result.species"].exists)
        }
    }

    @MainActor
    func testConfirmedCatalogueCardOpensCollectionAndRestoresReceipt() {
        for polish in [false, true] {
            let app = openSavePresentationFixture(polish: polish)
            defer { app.terminate() }
            let open = app.buttons["catalogue.saved.collection"]
            XCTAssertTrue(app.buttons["catalogue.save.submit"].waitForExistence(timeout: 15))
            XCTAssertFalse(open.exists)
            app.buttons["catalogue.save.submit"].tap()
            let card = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.card.")
            ).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 20))
            let cardID = card.identifier
            let plantID = String(cardID.dropFirst("catalogue.saved.card.".count))
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            XCTAssertEqual(open.label, polish ? "Moje rośliny" : "My plants")
            open.tap()
            let plant = app.buttons["collection.plant." + plantID]
            XCTAssertTrue(plant.waitForExistence(timeout: 15))
            app.buttons["collection.back"].tap()
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            XCTAssertEqual(card.identifier, cardID)

            app.terminate()
            app.launch()
            XCTAssertTrue(card.waitForExistence(timeout: 20))
            XCTAssertEqual(card.identifier, cardID)
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            open.tap()
            XCTAssertTrue(plant.waitForExistence(timeout: 15))
        }
    }

    @MainActor
    func testPendingCatalogueSaveHidesCollectionAction() {
        let app = openSavePresentationFixture(polish: false, scenario: "server503")
        defer { app.terminate() }
        let submit = app.buttons["catalogue.save.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["catalogue.saved.collection"].exists)
        submit.tap()
        XCTAssertTrue(app.staticTexts["catalogue.save.pending"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["catalogue.saved.collection"].exists)
    }

    @MainActor
    private func verifyResultSavePresentation(mode: String, polish: Bool) {
        let app = openSavePresentationFixture(polish: polish, mode: mode)
        defer { app.terminate() }
        let heading = app.staticTexts["analysis.result.species"]
        XCTAssertTrue(heading.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["catalogue.saved.collection"].exists)
        if mode == "identification" {
            let confirm = app.buttons["analysis.identification.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
            XCTAssertTrue(app.staticTexts["analysis.identification.confirmed"].waitForExistence(timeout: 5))
        }
        let submit = app.buttons["catalogue.save.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 15))
        XCTAssertEqual(submit.label, polish ? "Zapisz roślinę" : "Save plant")
        XCTAssertTrue(app.staticTexts[polish ? "Zapisz w kolekcji" : "Save to collection"].exists)
        XCTAssertEqual(app.textFields["catalogue.save.name"].placeholderValue,
                       polish ? "Nazwa rośliny (opcjonalnie)" : "Plant name (optional)")
        let label = polish ? "Paproć" : "Fern"
        XCTAssertEqual(heading.label, label)
        XCTAssertEqual(app.staticTexts.matching(identifier: "analysis.result.species").count, 1)
        // Count the label too: a second header has no analysis accessibility ID.
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", label)).count, 1)
        XCTAssertFalse(app.staticTexts["catalogue.selected.scientific"].exists)
        XCTAssertFalse(app.buttons["catalogue.saved.collection"].exists)
        let locale = polish ? "pl" : "en"
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "result-save-\(mode)-\(locale)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Fixture-only presentation; no live analysis, authentication or save is performed.
    @MainActor
    private func openSavePresentationFixture(
        polish: Bool, mode: String? = nil, scenario: String = "free2"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--catalogue-fixture", scenario, "--catalogue-namespace", UUID().uuidString,
            "-AppleLanguages", polish ? "(pl)" : "(en)", "-AppleLocale", polish ? "pl_PL" : "en_US"
        ]
        if let mode { app.launchArguments += ["--result-save-presentation", mode] }
        app.launch()
        let language = app.segmentedControls["welcome.language.picker"].buttons[polish ? "Polski" : "English"]
        XCTAssertTrue(language.waitForExistence(timeout: 15))
        language.tap()
        app.buttons["welcome.intent.care"].tap()
        let catalogue = app.buttons["care.method.catalogue"]
        XCTAssertTrue(catalogue.waitForExistence(timeout: 5))
        catalogue.tap()
        let species = app.buttons["catalogue.species.fixture_fern"]
        XCTAssertTrue(species.waitForExistence(timeout: 15))
        species.tap()
        return app
    }

    @MainActor
    func testStagingCatalogueSelectionSurvivesRelaunch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NARAT_LIVE_STAGING"] == "1")
        let app = XCUIApplication()
        func openCatalogue() {
            app.launch()
            app.buttons["welcome.catalogue"].tap()
        }

        openCatalogue()
        let species = app.buttons["catalogue.species.monstera_deliciosa"]
        let change = app.buttons["catalogue.change"]
        if change.waitForExistence(timeout: 3) { change.tap() }
        XCTAssertTrue(species.waitForExistence(timeout: 25))
        species.tap()
        let name = app.staticTexts["catalogue.selected.scientific"]
        XCTAssertEqual(name.label, "Monstera deliciosa")
        app.terminate()
        openCatalogue()
        XCTAssertTrue(name.waitForExistence(timeout: 25))
        XCTAssertEqual(name.label, "Monstera deliciosa")
    }

    @MainActor
    func testQuietGardenOrdinaryHomeAndCatalogueVisuals() {
        quietGardenOrdinaryVisuals(accessibilitySize: false)
    }

    @MainActor
    func testQuietGardenAccessibilityHomeAndCatalogueVisuals() {
        quietGardenOrdinaryVisuals(accessibilitySize: true)
    }

    @MainActor
    private func quietGardenOrdinaryVisuals(accessibilitySize: Bool) {
        for language in ["en", "pl"] {
            let app = XCUIApplication()
            defer { app.terminate() }
            let locale = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "pl" ? "pl_PL" : "en_US"]
            app.launchArguments = locale + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            app.launch()
            let title = app.staticTexts["welcome.title"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            let ordinaryHeight = title.frame.height
            if accessibilitySize {
                app.terminate()
                app.launchArguments = locale + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                app.launch()
                XCTAssertTrue(title.waitForExistence(timeout: 10))
                XCTAssertGreaterThan(title.frame.height, ordinaryHeight * 1.5)
            }
            let size = accessibilitySize ? "accessibility" : "standard"
            quietGardenImage(app, "qg-home-\(language)-\(size)")
            let catalogue = app.buttons["welcome.catalogue"]
            XCTAssertTrue(catalogue.waitForExistence(timeout: 10))
            let scroll = app.scrollViews.firstMatch
            for _ in 0..<10 {
                if catalogue.isEnabled && catalogue.isHittable && scroll.frame.contains(catalogue.frame) { break }
                scroll.swipeUp()
            }
            XCTAssertGreaterThanOrEqual(catalogue.frame.height, 44)
            XCTAssertTrue(catalogue.isEnabled && catalogue.isHittable)
            XCTAssertTrue(scroll.frame.contains(catalogue.frame))
            if accessibilitySize { quietGardenImage(app, "qg-actions-\(language)-\(size)") }
            catalogue.tap()
            let error = app.staticTexts["catalogue.error"]
            XCTAssertTrue(error.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["catalogue.retry"].isEnabled)
            quietGardenImage(app, "qg-catalogue-error-\(language)-\(size)")
            app.buttons["catalogue.back"].tap()
            XCTAssertTrue(app.buttons["welcome.check"].waitForExistence(timeout: 10))
        }
    }

    @MainActor
    private func quietGardenImage(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}

extension PlantsUITests {
    @MainActor
    func testOrdinaryAccountNativeFeedbackEnglish() throws {
        try verifyOrdinaryAccountNativeFeedback(polish: false)
        let flag = "--catalogue-account-native-feedback-fixture"
        let companions = ["--catalogue-fixture", "guestProviderCancel",
                          "--catalogue-namespace", UUID().uuidString.lowercased()]
        for invalid in [[flag], companions + [flag, flag],
                        companions + [flag, "--today-fixture", "todayMixed"]] {
            let app = XCUIApplication()
            app.launchArguments = invalid + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["welcome.unavailable"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["collection.open"].isEnabled)
            XCTAssertFalse(app.textFields["account.email"].exists)
            XCTAssertFalse(app.buttons["account.signin.google"].exists)
            XCTAssertFalse(app.segmentedControls["welcome.language.picker"].exists)
            XCTAssertFalse(app.buttons["catalogue.save.google"].exists)
        }
    }

    @MainActor
    func testOrdinaryAccountNativeFeedbackPolish() throws {
        try verifyOrdinaryAccountNativeFeedback(polish: true)
    }

    @MainActor
    private func verifyOrdinaryAccountNativeFeedback(polish: Bool) throws {
        let language = polish ? "pl" : "en"
        for scenario in ["guestProviderCancel", "guestProviderFailureRetry"] {
            let namespace = UUID().uuidString.lowercased()
            let app = XCUIApplication()
            app.launchArguments = [
                "--catalogue-fixture", scenario, "--catalogue-namespace", namespace,
                "--catalogue-account-native-feedback-fixture",
                "-AppleLanguages", "(\(language))", "-AppleLocale", polish ? "pl_PL" : "en_US"
            ]
            app.launch()
            defer { app.terminate() }
            let collection = app.buttons["collection.open"]
            nativeFeedbackEnabled(collection)
            XCTAssertEqual(collection.label, polish ? "Moje rośliny" : "My plants")
            collection.tap()
            let email = app.textFields["account.email"]
            nativeFeedbackEnabled(email)
            let google = app.buttons["account.signin.google"]
            nativeFeedbackEnabled(google)
            let creation = app.staticTexts["account.signin.accountCreation"]
            XCTAssertTrue(creation.waitForExistence(timeout: 10))
            XCTAssertEqual(creation.label, polish
                ? "Pierwsze logowanie przez Google tworzy konto Narat."
                : "First sign-in with Google creates your Narat account.")
            XCTAssertFalse(app.staticTexts[
                "First sign-in creates your Narat account. After sign-in, we continue saving this plant with your chosen details."
            ].exists)
            XCTAssertFalse(app.staticTexts[
                "Pierwsze logowanie tworzy konto Narat. Po zalogowaniu kontynuujemy zapisywanie tej rośliny z wybranymi danymi."
            ].exists)
            nativeFeedbackReveal(creation, app: app)
            XCTAssertTrue(nativeFeedbackViewport(app).contains(creation.frame))
            let marker = "fixture@" + namespace + ".invalid"
            email.tap()
            email.typeText(marker)
            XCTAssertEqual(email.value as? String, marker)
            let keyboard = app.keyboards.firstMatch
            let returnKey = keyboard.buttons.matching(NSPredicate(
                format: "label IN %@", ["Return", "return", "Done", "Gotowe", "Wróć", "Dalej", "Next"]
            )).firstMatch
            if returnKey.exists && returnKey.isHittable { returnKey.tap() }
            nativeFeedbackReveal(google, app: app)
            XCTAssertGreaterThanOrEqual(google.frame.height, 44)
            google.tap()
            let cancelled = scenario == "guestProviderCancel"
            let notice = app.staticTexts[cancelled ? "account.signin.cancelled" : "account.signin.error"]
            XCTAssertTrue(notice.waitForExistence(timeout: 15))
            XCTAssertEqual(notice.label, cancelled
                ? (polish ? "Logowanie przez Google anulowane. Możesz spróbować ponownie."
                    : "Google sign-in was cancelled. You can try again.")
                : (polish ? "Nie udało się zalogować przez Google. Spróbuj ponownie."
                    : "Couldn’t sign in with Google. Try again."))
            nativeFeedbackEnabled(google)
            nativeFeedbackReveal(notice, app: app)
            XCTAssertTrue(nativeFeedbackViewport(app).contains(notice.frame))
            XCTAssertTrue(nativeFeedbackViewport(app).contains(google.frame))
            XCTAssertGreaterThanOrEqual(google.frame.height, 44)
            XCTAssertTrue(google.isEnabled)
            XCTAssertTrue(email.exists)
            XCTAssertEqual(email.value as? String, marker)
            XCTAssertTrue(app.secureTextFields["account.password"].exists)
            XCTAssertFalse(app.buttons["account.signin"].isEnabled)
            XCTAssertFalse(app.staticTexts["catalogue.saved.name"].exists)
            XCTAssertFalse(app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "collection.plant."
            )).firstMatch.exists)
            XCTAssertFalse(app.staticTexts[cancelled ? "account.signin.error" : "account.signin.cancelled"].exists)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "account-native-feedback-\(scenario)-\(language)"
            image.lifetime = .keepAlways
            add(image)
            let proof = try JSONSerialization.data(withJSONObject: [
                "namespace": namespace, "scenario": scenario, "language": language, "emailRetained": true
            ], options: [.sortedKeys])
            let attachment = XCTAttachment(data: proof, uniformTypeIdentifier: "public.json")
            attachment.name = "account-native-feedback-proof-\(scenario)-\(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func nativeFeedbackEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }

    @MainActor
    private func nativeFeedbackViewport(_ app: XCUIApplication) -> CGRect {
        var viewport = app.windows.firstMatch.frame
        let navigation = app.navigationBars.firstMatch
        if navigation.exists {
            let top = max(viewport.minY, navigation.frame.maxY)
            viewport = CGRect(x: viewport.minX, y: top, width: viewport.width,
                              height: max(0, viewport.maxY - top))
        }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists && viewport.intersects(keyboard.frame) {
            viewport.size.height = max(0, keyboard.frame.minY - viewport.minY)
        }
        return viewport
    }

    @MainActor
    private func nativeFeedbackReveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<4 {
            let viewport = nativeFeedbackViewport(app)
            if viewport.contains(element.frame) && element.isHittable { return }
            guard element.frame.maxY > viewport.maxY, viewport.height > 80 else { break }
            // Scroll upward inside the visible form, never drag the sheet down.
            let window = app.windows.firstMatch
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX - window.frame.minX,
                                                   dy: viewport.minY + viewport.height * 0.8 - window.frame.minY))
            let end = origin.withOffset(CGVector(dx: viewport.midX - window.frame.minX,
                                                 dy: viewport.minY + viewport.height * 0.3 - window.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(nativeFeedbackViewport(app).contains(element.frame))
        XCTAssertTrue(element.isHittable)
    }
}

@MainActor
extension PlantsUITests {
    func testPhotoIdentificationChoicesAndLifetimeEnglish() throws { try b2UIChoices(false) }
    func testPhotoIdentificationChoicesAndLifetimePolish() throws { try b2UIChoices(true) }
    func testGuestPhotoManualSelectionClaimEnglish() throws { try b2UIClaim(false) }
    func testGuestPhotoManualSelectionClaimPolish() throws { try b2UIClaim(true) }

    @MainActor
    private struct B2UIRun {
        let app = XCUIApplication()
        let polish: Bool
        let unknown: Bool
        let namespace = UUID().uuidString.lowercased()
        var language: String { polish ? "pl" : "en" }
        var scenario: String { unknown ? "photoIdentificationUnknown" : "photoIdentificationWrong" }
        func text(_ en: String, _ pl: String) -> String { polish ? pl : en }
    }
    private var b2UIPalm: String { "a2000000-0000-4000-8000-000000000003" }

    private func b2UIReady(_ element: XCUIElement) {
        nativeFeedbackEnabled(element)
        XCTAssertGreaterThan(element.frame.width, 0); XCTAssertGreaterThan(element.frame.height, 0)
    }
    private func b2UITap(_ element: XCUIElement, production: Bool = false) {
        b2UIReady(element)
        XCTAssertTrue(XCUIApplication().windows.firstMatch.frame.contains(element.frame))
        if production { XCTAssertGreaterThanOrEqual(element.frame.height, 44) }
        element.tap()
    }
    private func b2UIAbsent(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 15), .completed)
    }
    private func b2UIObject(_ value: Any?) throws -> [String: Any] { try XCTUnwrap(value as? [String: Any]) }
    private func b2UIID(_ value: Any?) throws -> UUID { try XCTUnwrap((value as? String).flatMap(UUID.init(uuidString:))) }
    private func b2UIEqual(_ a: Any?, _ b: Any?) throws {
        let left = try JSONSerialization.data(withJSONObject: [try XCTUnwrap(a)], options: [.sortedKeys])
        let right = try JSONSerialization.data(withJSONObject: [try XCTUnwrap(b)], options: [.sortedKeys])
        XCTAssertEqual(left, right)
    }
    private func b2UIRecord(_ run: B2UIRun, _ phase: String, _ element: XCUIElement,
                            viewport: CGRect? = nil, proof: [String: Any]? = nil) throws {
        let bounds = viewport ?? run.app.windows.firstMatch.frame
        XCTAssertTrue(element.exists); XCTAssertTrue(element.isHittable)
        XCTAssertTrue(bounds.contains(element.frame))
        func rect(_ r: CGRect) -> [String: Double] {
            ["x": Double(r.minX), "y": Double(r.minY), "width": Double(r.width), "height": Double(r.height)]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": "rendered-photo-identification", "phase": phase, "language": run.language,
            "scenario": run.scenario, "namespace": run.namespace, "element": element.identifier,
            "label": element.label, "elementFrame": rect(element.frame), "viewport": rect(bounds),
            "proof": proof as Any? ?? NSNull()
        ], options: [.sortedKeys])
        let name = "b2UI-\(run.language)-\(run.scenario)-\(run.namespace)-\(phase)"
        let json = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        json.name = name; json.lifetime = .keepAlways; add(json)
        let png = XCTAttachment(screenshot: run.app.screenshot())
        png.name = name; png.lifetime = .keepAlways; add(png)
    }
    private func b2UIProbe(_ run: B2UIRun, _ phase: String) throws -> [String: Any] {
        let value = run.app.staticTexts["photo.fixture.proof"]
        func read() -> [String: Any]? {
            guard let string = value.value as? String, let data = string.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let previous = read()?["probeRevision"] as? Int ?? 0
        b2UITap(run.app.buttons["photo.fixture.probe"])
        let fresh = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (read()?["probeRevision"] as? Int ?? 0) > previous
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fresh], timeout: 20), .completed); XCTAssertFalse(run.app.staticTexts["photo.fixture.error"].exists)
        let result = try XCTUnwrap(read())
        XCTAssertGreaterThan(try XCTUnwrap(result["probeRevision"] as? Int), previous); XCTAssertEqual(result["namespace"] as? String, run.namespace)
        XCTAssertEqual(result["scenario"] as? String, run.scenario)
        try b2UIRecord(run, phase, run.app.buttons["photo.fixture.probe"], proof: result)
        return result
    }
    private func b2UIReach(_ run: B2UIRun, _ element: XCUIElement, anchor: String) throws -> CGRect {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        let matches = run.app.scrollViews.containing(.any, identifier: anchor)
        XCTAssertEqual(matches.count, 1)
        let scroll = try XCTUnwrap(matches.allElementsBoundByIndex.first)
        let window = run.app.windows.firstMatch
        let viewport = window.frame.intersection(scroll.frame)
        XCTAssertGreaterThan(viewport.height, 80)
        for _ in 0..<16 {
            if viewport.contains(element.frame) && element.isHittable { break }
            let before = element.frame
            let down = before.midY < viewport.midY
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX - window.frame.minX,
                dy: viewport.minY + viewport.height * (down ? 0.3 : 0.8) - window.frame.minY))
            let end = origin.withOffset(CGVector(dx: viewport.midX - window.frame.minX,
                dy: viewport.minY + viewport.height * (down ? 0.8 : 0.3) - window.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertNotEqual(element.frame.minY, before.minY, "Own scroll must move toward the element")
        }
        b2UIReady(element)
        XCTAssertTrue(viewport.contains(element.frame))
        return viewport
    }
    private func b2UILaunch(_ run: B2UIRun) throws -> [String: Any] {
        let app = run.app
        app.launchArguments = ["--today-fixture", run.scenario, "--catalogue-namespace", run.namespace,
                               "-AppleLanguages", "(\(run.language))", "-AppleLocale", run.polish ? "pl_PL" : "en_US"]
        app.launch()
        let identify = app.buttons["welcome.identify"]
        b2UIReady(identify)
        XCTAssertEqual(identify.label, run.text("Identify species", "Rozpoznaj gatunek"))
        b2UITap(identify, production: true)
        b2UIReady(app.buttons["photo.select.gallery"])
        let access = app.staticTexts["analysis.access.starter"]
        XCTAssertTrue(access.waitForExistence(timeout: 15)); XCTAssertEqual(access.label, run.text("Starter species identification: 1/1", "Startowe rozpoznanie gatunku: 1/1"))
        for id in ["analysis.access.error", "analysis.access.loading", "analysis.access.denied"] {
            let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.descendants(matching: .any)[id])
            XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 10), .completed)
        }
        try b2UIRecord(run, "starter-ready", app.buttons["photo.select.gallery"])
        b2UITap(app.buttons["photo.fixture.submit"])
        let heading = app.staticTexts["analysis.result.species"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20))
        b2UIAbsent(app.descendants(matching: .any)["analysis.progress"])
        XCTAssertEqual(heading.label, run.unknown
            ? run.text("Species could not be determined.", "Nie udało się ustalić gatunku.")
            : run.text("Boston fern", "Nefrolepis"))
        let back = app.buttons["analysis.navigation.back"]
        XCTAssertEqual(app.buttons.matching(identifier: "analysis.navigation.back").count, 1)
        b2UIReady(back)
        XCTAssertFalse(app.buttons["analysis.back.button"].exists)
        let uncertainty = app.staticTexts["analysis.identification.uncertainty"]
        let viewport = try b2UIReach(run, uncertainty, anchor: "analysis.result.species")
        XCTAssertEqual(uncertainty.label, run.unknown
            ? run.text("Choose a species from the catalogue to continue.", "Wybierz gatunek z katalogu, aby kontynuować.")
            : run.text("This identification is preliminary. Confirm the species or choose it manually.",
                       "To wstępne rozpoznanie. Potwierdź gatunek lub wybierz go ręcznie."))
        try b2UIRecord(run, "uncertainty", uncertainty, viewport: viewport)
        if !run.unknown { try b2UIHero(run, palm: false, picker: false) }
        else {
            XCTAssertFalse(app.buttons["analysis.identification.confirm"].exists); XCTAssertFalse(app.images[run.text("Boston fern", "Nefrolepis")].exists)
            XCTAssertFalse(app.images[run.text("Parlour palm", "Chamedora")].exists)
        }
        let manual = app.buttons["analysis.identification.manual"]
        _ = try b2UIReach(run, manual, anchor: "analysis.result.species")
        XCTAssertEqual(manual.label, run.unknown ? run.text("Choose a species", "Wybierz gatunek")
                                               : run.text("Choose another species", "Wybierz inny gatunek"))
        if !run.unknown {
            XCTAssertEqual(app.buttons["analysis.identification.confirm"].label, run.text("Confirm this species", "Potwierdź gatunek"))
        }
        let proof = try b2UIProbe(run, "original-result")
        try b2UISource(proof, original: proof, manual: nil, confirmed: nil)
        let source = try b2UIObject(proof["original"])
        XCTAssertEqual(source["locale"] as? String, run.language)
        if run.unknown { XCTAssertTrue(source["taxon"] is NSNull) }
        else { XCTAssertEqual(try b2UIID(source["taxon"]), UUID(uuidString: "32e72c49-4e06-434a-86dd-bbf8a5cb209e")) }
        return proof
    }
    private func b2UIHero(_ run: B2UIRun, palm: Bool, picker: Bool) throws {
        let name = palm ? run.text("Parlour palm", "Chamedora") : run.text("Boston fern", "Nefrolepis")
        let anchor = picker ? "collection.species.confirm" : "analysis.result.species"
        if !picker {
            b2UIAbsent(run.app.buttons["collection.species.confirm"])
            b2UIAbsent(run.app.buttons["catalogue.back"])
        }
        let matches = run.app.scrollViews.containing(.any, identifier: anchor)
        XCTAssertEqual(matches.count, 1)
        guard matches.count == 1 else { return }
        let scroll = try XCTUnwrap(matches.allElementsBoundByIndex.first)
        let scientific = scroll.staticTexts[palm ? "Chamaedorea elegans" : "Nephrolepis exaltata"]
        _ = try b2UIReach(run, scientific, anchor: anchor)
        let label = (picker ? run.text("Example species photo: ", "Przykładowe zdjęcie gatunku: ") : "") + name
        let image = scroll.images[label]
        let viewport = try b2UIReach(run, image, anchor: anchor)
        XCTAssertEqual(image.frame.height, 240, accuracy: 1)
        try b2UIRecord(run, picker ? "picker-hero" : "result-hero", image, viewport: viewport)
        let credit = scroll.staticTexts["Narat Fixture Studio · CC0-1.0 · Deterministic fern colour study"]
        let creditViewport = try b2UIReach(run, credit, anchor: anchor)
        let source = scroll.buttons[run.text("Image source", "Źródło zdjęcia")]
        _ = try b2UIReach(run, source, anchor: anchor)
        b2UIReady(source)
        XCTAssertTrue(creditViewport.contains(credit.frame))
        try b2UIRecord(run, "published-credit", credit, viewport: creditViewport)
    }
    private func b2UISource(_ proof: [String: Any], original: [String: Any], manual: String?, confirmed: String?) throws {
        try b2UIEqual(proof["original"], original["original"])
        XCTAssertEqual(proof["currentSourceEqualsOriginal"] as? Bool, true)
        if let manual { XCTAssertEqual(try b2UIID(proof["currentManualTaxon"]), UUID(uuidString: manual)) }
        else { XCTAssertTrue(proof["currentManualTaxon"] is NSNull) }
        if let confirmed { XCTAssertEqual(try b2UIID(proof["currentConfirmed"]), UUID(uuidString: confirmed)) }
        else { XCTAssertTrue(proof["currentConfirmed"] is NSNull) }
        XCTAssertTrue(try b2UIObject(proof["state"])["draft"] is NSNull)
        try b2UICounters(proof, drafts: 0, claims: 0)
    }
    private func b2UICounters(_ proof: [String: Any], drafts: Int, claims: Int) throws {
        let state = try b2UIObject(proof["state"]), source = try b2UIObject(proof["original"])
        let requests = try b2UIObject(state["requests"])
        let photo = try b2UIID(source["photo"]), job = try b2UIID(source["job"])
        for route in ["media/upload-ticket", "media/uploads/" + photo.uuidString.lowercased(),
                      "analysis/jobs", "analysis/jobs/" + job.uuidString.lowercased()] {
            XCTAssertEqual(requests[route] as? Int, 1, route)
        }
        for (route, count) in [("drafts", drafts), ("claims/prepare", claims), ("claims/commit", claims)] { XCTAssertEqual(requests[route] as? Int ?? 0, count, route) }
        for (key, originalKey) in [("photo", "photo"), ("job", "job"), ("flow", "flow"),
                                  ("uploadOperation", "uploadOperation"), ("jobOperation", "requestOperation"),
                                  ("sourceOwner", "owner")] {
            XCTAssertEqual(try b2UIID(state[key]), try b2UIID(source[originalKey]))
        }
        XCTAssertEqual(state["ready"] as? Bool, true); XCTAssertEqual(state["succeeded"] as? Bool, true)
        try b2UIEqual(state["jpegHash"], source["aiVisionJPEGHash"])
        try b2UIEqual(state["byteCount"], source["aiVisionJPEGByteCount"])
    }
    private func b2UIPicker(_ run: B2UIRun, missing: Bool) throws {
        let manual = run.app.buttons["analysis.identification.manual"]
        _ = try b2UIReach(run, manual, anchor: "analysis.result.species")
        b2UITap(manual, production: true)
        let row = run.app.buttons["catalogue.species." + (missing ? "fixture_missing" : "fixture_palm")]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        if missing { XCTAssertTrue(row.label.contains("Published fixture species 000000000001")) }
        let lists = run.app.tables.containing(.button, identifier: row.identifier)
        let collections = run.app.collectionViews.containing(.button, identifier: row.identifier)
        XCTAssertEqual(lists.count + collections.count, 1)
        let list = lists.count == 1 ? lists.firstMatch : collections.firstMatch
        for _ in 0..<8 {
            if row.isHittable && list.frame.intersection(run.app.windows.firstMatch.frame).contains(row.frame) { break }
            list.swipeUp()
        }
        b2UITap(row, production: true)
        XCTAssertTrue(run.app.buttons["collection.species.confirm"].waitForExistence(timeout: 15))
        if missing {
            let label = run.text("Example species photo: ", "Przykładowe zdjęcie gatunku: ")
                + "Published fixture species 000000000001. " + run.text("No image", "Brak zdjęcia")
            let placeholder = run.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            let viewport = try b2UIReach(run, placeholder, anchor: "collection.species.confirm")
            XCTAssertFalse(run.app.images[run.text("Example species photo: ", "Przykładowe zdjęcie gatunku: ") + "Published fixture species 000000000001"].exists)
            try b2UIRecord(run, "nil-image", placeholder, viewport: viewport)
        } else { try b2UIHero(run, palm: true, picker: true) }
    }
    private func b2UISelect(_ run: B2UIRun) throws {
        try b2UIPicker(run, missing: false)
        let choose = run.app.buttons["collection.species.confirm"]
        let viewport = try b2UIReach(run, choose, anchor: "collection.species.confirm")
        XCTAssertEqual(choose.label, run.text("Choose this species", "Wybierz ten gatunek"))
        try b2UIRecord(run, "long-description-confirm", choose, viewport: viewport)
        b2UITap(choose, production: true)
        b2UIAbsent(run.app.buttons["collection.species.confirm"])
        XCTAssertTrue(run.app.staticTexts["analysis.result.species"].waitForExistence(timeout: 15)); XCTAssertEqual(run.app.staticTexts["analysis.result.species"].label, run.text("Parlour palm", "Chamedora"))
        try b2UIHero(run, palm: true, picker: false)
        _ = try b2UIReach(run, run.app.staticTexts["analysis.identification.uncertainty"], anchor: "analysis.result.species")
    }
    private func b2UIConfirm(_ run: B2UIRun) throws {
        let confirm = run.app.buttons["analysis.identification.confirm"]
        _ = try b2UIReach(run, confirm, anchor: "analysis.result.species")
        b2UITap(confirm, production: true)
        let message = run.app.staticTexts["analysis.identification.confirmed"]
        let viewport = try b2UIReach(run, message, anchor: "analysis.result.species")
        XCTAssertEqual(message.label, run.text("Species confirmed.", "Gatunek potwierdzony."))
        let save = run.app.buttons["staging.guest.draft.save"]
        _ = try b2UIReach(run, save, anchor: "analysis.result.species")
        XCTAssertEqual(save.label, run.text("Sign in to save", "Zaloguj się, aby zapisać"))
        try b2UIRecord(run, "confirmed-before-draft", message, viewport: viewport)
    }
    private func b2UIChoices(_ polish: Bool) throws {
        for unknown in [false, true] {
            let run = B2UIRun(polish: polish, unknown: unknown)
            defer { run.app.terminate() }
            let original = try b2UILaunch(run)
            try b2UIPicker(run, missing: true)
            let cancel = run.app.buttons["catalogue.back"]
            XCTAssertEqual(cancel.label, run.text("Cancel", "Anuluj"))
            b2UITap(cancel)
            XCTAssertTrue(run.app.staticTexts["analysis.result.species"].waitForExistence(timeout: 10))
            b2UIAbsent(run.app.buttons["catalogue.back"])
            try b2UISource(b2UIProbe(run, "nil-cancelled"), original: original, manual: nil, confirmed: nil)
            try b2UISelect(run)
            try b2UISource(b2UIProbe(run, "manual-selected"), original: original, manual: b2UIPalm, confirmed: nil)
            try b2UIConfirm(run)
            try b2UISource(b2UIProbe(run, "confirmed-no-draft"), original: original, manual: b2UIPalm, confirmed: b2UIPalm)
        }
        let run = B2UIRun(polish: polish, unknown: polish)
        defer { run.app.terminate() }
        let original = try b2UILaunch(run)
        try b2UIPicker(run, missing: false)
        b2UITap(run.app.buttons["photo.fixture.validation.arm"])
        let choose = run.app.buttons["collection.species.confirm"]
        _ = try b2UIReach(run, choose, anchor: "collection.species.confirm")
        b2UITap(choose, production: true)
        b2UITap(run.app.buttons["photo.fixture.host.remove"])
        XCTAssertTrue(run.app.staticTexts["photo.fixture.host.removed"].waitForExistence(timeout: 15)); XCTAssertFalse(run.app.staticTexts["analysis.result.species"].exists)
        XCTAssertFalse(run.app.buttons["collection.species.confirm"].exists)
        var removed = try b2UIProbe(run, "host-removed")
        for index in 0..<8 {
            if try b2UIObject(removed["heldRequestProof"])["cancellations"] as? Int == 1 { break }
            removed = try b2UIProbe(run, "cancellation-settling-\(index)")
        }
        try b2UIHeld(removed, original: original)
        b2UITap(run.app.buttons["photo.fixture.release"])
        let released = try b2UIProbe(run, "cancelled-release-no-op")
        try b2UIHeld(released, original: original)
        try b2UIEqual(released["heldRequestProof"], removed["heldRequestProof"])
    }
    private func b2UIHeld(_ proof: [String: Any], original: [String: Any]) throws {
        try b2UISource(proof, original: original, manual: nil, confirmed: nil)
        XCTAssertEqual(proof["heldSDKIsCurrent"] as? Bool, true); XCTAssertEqual(proof["hostRemoved"] as? Bool, true)
        let held = try b2UIObject(proof["heldRequestProof"]), source = try b2UIObject(proof["original"])
        _ = try b2UIID(held["request"])
        XCTAssertEqual(try b2UIID(held["owner"]), try b2UIID(source["owner"])); XCTAssertEqual(try b2UIID(held["taxon"]), UUID(uuidString: b2UIPalm))
        try b2UIEqual(held["locale"], source["locale"])
        for (key, count) in [("arrivals", 1), ("cancellations", 1), ("releases", 0)] { XCTAssertEqual(held[key] as? Int, count) }
    }
    private func b2UIClaim(_ polish: Bool) throws {
        let run = B2UIRun(polish: polish, unknown: polish)
        defer { run.app.terminate() }
        let original = try b2UILaunch(run)
        XCTAssertEqual(original["plantCount"] as? Int, 2)
        let signup = try b2UIObject(original["auth"])["signupCount"]
        try b2UISelect(run)
        try b2UIConfirm(run)
        try b2UISource(b2UIProbe(run, "claim-confirmed"), original: original, manual: b2UIPalm, confirmed: b2UIPalm)
        var draft: [String: Any]?
        for attempt in 1...3 {
            let save = run.app.buttons["staging.guest.draft.save"]
            _ = try b2UIReach(run, save, anchor: "analysis.result.species")
            b2UITap(save, production: true)
            let email = run.app.textFields["account.email"], google = run.app.buttons["account.signin.google"]
            b2UIReady(email); b2UIReady(google)
            let creation = run.app.staticTexts["account.signin.accountCreation"]
            nativeFeedbackReveal(creation, app: run.app)
            XCTAssertEqual(creation.label, run.text("First sign-in with Google creates your Narat account.",
                                                   "Pierwsze logowanie przez Google tworzy konto Narat."))
            XCTAssertTrue(run.app.secureTextFields["account.password"].exists)
            try b2UIRecord(run, "account-creation-\(attempt)", creation, viewport: nativeFeedbackViewport(run.app))
            let marker = "fixture@" + run.namespace + ".invalid"
            nativeFeedbackReveal(email, app: run.app)
            email.tap(); email.typeText(marker)
            let key = run.app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", ["Return", "return", "Done", "Gotowe", "Wróć", "Dalej", "Next"])).firstMatch
            if key.exists && key.isHittable { key.tap() }
            nativeFeedbackReveal(google, app: run.app)
            b2UITap(google, production: true)
            if attempt == 3 { break }
            let notice = run.app.staticTexts[attempt == 1 ? "account.signin.cancelled" : "account.signin.error"]
            XCTAssertTrue(notice.waitForExistence(timeout: 15))
            XCTAssertEqual(notice.label, attempt == 1
                ? run.text("Google sign-in was cancelled. You can try again.", "Logowanie przez Google anulowane. Możesz spróbować ponownie.")
                : run.text("Couldn’t sign in with Google. Try again.", "Nie udało się zalogować przez Google. Spróbuj ponownie."))
            nativeFeedbackReveal(notice, app: run.app)
            b2UIReady(google)
            XCTAssertTrue(nativeFeedbackViewport(run.app).contains(google.frame)); XCTAssertEqual(email.value as? String, marker)
            XCTAssertFalse(run.app.buttons["account.signin"].isEnabled)
            try b2UIRecord(run, "provider-notice-\(attempt)", notice, viewport: nativeFeedbackViewport(run.app))
            let cancel = run.app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", run.text("Cancel", "Anuluj")))
            XCTAssertEqual(cancel.count, 1)
            b2UITap(cancel.firstMatch)
            let proof = try b2UIProbe(run, "provider-return-\(attempt)")
            try b2UIEqual(proof["original"], original["original"])
            try b2UIAuth(proof, attempts: attempt, failures: attempt - 1, tokens: 0, signup: signup)
            XCTAssertEqual(proof["plantCount"] as? Int, 2)
            try b2UICounters(proof, drafts: 1, claims: 0)
            try b2UIJournal(proof, baseline: draft)
            if draft == nil { draft = proof }
        }
        let status = run.app.staticTexts["staging.guest.claim.status"]
        let saved = run.text("Plant and photo saved.", "Roślina i zdjęcie zapisane")
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", saved), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed)
        try b2UIRecord(run, "claim-saved", status)
        b2UITap(run.app.buttons["staging.guest.claim.collection"])
        let rows = run.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "collection.plant.", "Parlour palm"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20)); XCTAssertEqual(rows.count, 1)
        let plant = try XCTUnwrap(UUID(uuidString: String(rows.firstMatch.identifier.dropFirst("collection.plant.".count))))
        try b2UICard(run, plant: plant)
        try b2UICloseCollection(run)
        let committed = try b2UIProbe(run, "claim-canonical")
        try b2UICanonical(committed, original: original, draft: try XCTUnwrap(draft), plant: plant, signup: signup)
        run.app.terminate(); run.app.launch()
        b2UIReady(run.app.buttons["collection.open"])
        b2UIReady(run.app.buttons["photo.fixture.probe"])
        let cold = try b2UIProbe(run, "cold-restored")
        try b2UICanonical(cold, original: original, draft: try XCTUnwrap(draft), plant: plant, signup: signup)
        for key in ["original", "journal", "canonical", "state", "auth", "plantCount", "owner"] { try b2UIEqual(cold[key], committed[key]) }
        b2UITap(run.app.buttons["collection.open"], production: true)
        try b2UICard(run, plant: plant)
    }
    private func b2UIAuth(_ proof: [String: Any], attempts: Int, failures: Int, tokens: Int, signup: Any?) throws {
        let auth = try b2UIObject(proof["auth"])
        for (key, count) in [("providerAttempts", attempts), ("providerFailures", failures),
                             ("idTokenRequests", tokens), ("passwordRequests", 0), ("emailRegistrationRequests", 0)] {
            XCTAssertEqual(auth[key] as? Int, count)
        }
        try b2UIEqual(auth["signupCount"], signup)
    }
    private func b2UIJournal(_ proof: [String: Any], baseline: [String: Any]?) throws {
        let journal = try b2UIObject(proof["journal"]), source = try b2UIObject(proof["original"])
        for (key, sourceKey) in [("guestOwner", "owner"), ("jobId", "job"), ("photoId", "photo")] { XCTAssertEqual(try b2UIID(journal[key]), try b2UIID(source[sourceKey])) }
        XCTAssertEqual(try b2UIID(journal["taxonId"]), UUID(uuidString: b2UIPalm))
        for key in ["installationId", "draftOperationId", "prepareOperationId", "commitOperationId"] { _ = try b2UIID(journal[key]) }
        let operations = try ["draftOperationId", "prepareOperationId", "commitOperationId"].map { try b2UIID(journal[$0]) }
        XCTAssertEqual(Set(operations).count, 3)
        let draft = try b2UIObject(journal["draft"])
        _ = try b2UIID(draft["draft_id"])
        XCTAssertEqual(try b2UIID(draft["draft_id"]), try b2UIID(b2UIObject(proof["state"])["draft"]))
        if let baseline {
            let old = try b2UIObject(baseline["journal"])
            for key in ["guestOwner", "installationId", "jobId", "photoId", "taxonId", "draftOperationId",
                        "prepareOperationId", "commitOperationId", "draft"] { try b2UIEqual(journal[key], old[key]) }
        }
    }
    private func b2UICanonical(_ proof: [String: Any], original: [String: Any], draft: [String: Any],
                               plant: UUID, signup: Any?) throws {
        try b2UIEqual(proof["original"], original["original"])
        try b2UICounters(proof, drafts: 1, claims: 1)
        try b2UIJournal(proof, baseline: draft)
        try b2UIAuth(proof, attempts: 3, failures: 1, tokens: 1, signup: signup)
        XCTAssertEqual(proof["anonymous"] as? Bool, false); XCTAssertEqual(proof["plantCount"] as? Int, 3)
        let canonical = try b2UIObject(proof["canonical"]), source = try b2UIObject(proof["original"])
        XCTAssertEqual(try b2UIID(canonical["plant"]), plant); XCTAssertEqual(try b2UIID(canonical["taxon"]), UUID(uuidString: b2UIPalm))
        XCTAssertEqual(try b2UIID(canonical["mainPhoto"]), try b2UIID(source["photo"])); XCTAssertEqual(canonical["name"] as? String, "Parlour palm")
        XCTAssertEqual(canonical["collectionCount"] as? Int, 3)
        try b2UIEqual(canonical["privateJPEGHash"], source["aiVisionJPEGHash"])
        try b2UIEqual(canonical["byteCount"], source["aiVisionJPEGByteCount"])
        let journal = try b2UIObject(proof["journal"]), state = try b2UIObject(proof["state"])
        let receipt = try b2UIObject(journal["receipt"]), prepared = try b2UIObject(journal["proof"])
        XCTAssertEqual(try b2UIID(receipt["plant_id"]), plant); XCTAssertEqual(try b2UIID(receipt["photo_id"]), try b2UIID(source["photo"]))
        XCTAssertEqual(try b2UIID(journal["destinationOwner"]), try b2UIID(proof["owner"])); XCTAssertEqual(try b2UIID(prepared["draft_id"]), try b2UIID(b2UIObject(journal["draft"])["draft_id"]))
        XCTAssertEqual(try b2UIID(prepared["claim_id"]), try b2UIID(state["claim"])); XCTAssertEqual(try b2UIID(state["plant"]), plant)
        XCTAssertEqual(try b2UIID(state["selectedTaxon"]), UUID(uuidString: b2UIPalm)); XCTAssertEqual(try b2UIID(state["destination"]), try b2UIID(proof["owner"]))
    }
    private func b2UICard(_ run: B2UIRun, plant: UUID) throws {
        let id = plant.uuidString.lowercased()
        b2UITap(run.app.buttons["collection.plant." + id])
        XCTAssertTrue(run.app.descendants(matching: .any)["catalogue.saved.card." + id].waitForExistence(timeout: 20)); XCTAssertEqual(run.app.staticTexts["catalogue.saved.name"].label, "Parlour palm")
        let species = run.app.staticTexts["catalogue.saved.species"]
        XCTAssertTrue(species.waitForExistence(timeout: 15)); XCTAssertEqual(species.label, run.text("Parlour palm", "Chamedora"))
        let image = run.app.images["catalogue.saved.photo"]
        let viewport = try b2UIReach(run, image, anchor: "catalogue.saved.name")
        try b2UIRecord(run, "canonical-private-image-" + id, image, viewport: viewport)
    }
    private func b2UICloseCollection(_ run: B2UIRun) throws {
        let back = run.app.buttons["collection.back"]
        XCTAssertEqual(back.label, run.text("Back", "Wstecz"))
        b2UITap(back)
        b2UIReady(back)
        XCTAssertEqual(back.label, run.text("Close", "Zamknij"))
        b2UITap(back)
    }
}
