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
