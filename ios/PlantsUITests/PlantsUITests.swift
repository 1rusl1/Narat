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
        XCTAssertEqual(app.buttons["welcome.check"].label, "Sprawdź roślinę")
        XCTAssertEqual(app.buttons["welcome.identify"].label, "Rozpoznaj roślinę")
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
        XCTAssertEqual(app.buttons["welcome.check"].label, "Sprawdź roślinę")
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
            XCTAssertEqual(app.buttons["welcome.check"].label, language == "pl" ? "Sprawdź roślinę" : "Check a plant")
            XCTAssertEqual(app.buttons["welcome.identify"].label, language == "pl" ? "Rozpoznaj roślinę" : "Identify a plant")
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
}
