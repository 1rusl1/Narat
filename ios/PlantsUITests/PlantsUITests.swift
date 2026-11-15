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
