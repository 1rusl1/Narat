import XCTest

final class FirstHelpTests: XCTestCase {
    @MainActor
    func testProblemScanEnglish() {
        verifyUnavailableFlow(care: false, polish: false)
    }

    @MainActor
    func testProblemScanPolish() {
        verifyUnavailableFlow(care: false, polish: true)
    }

    @MainActor
    func testCareScanEnglish() {
        verifyUnavailableFlow(care: true, polish: false)
    }

    @MainActor
    func testCareScanPolish() {
        verifyUnavailableFlow(care: true, polish: true)
    }

    @MainActor
    private func verifyUnavailableFlow(care: Bool, polish: Bool) {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["welcome.title"].waitForExistence(timeout: 5))
        let language = app.segmentedControls["welcome.language.picker"]
        let choice = language.buttons[polish ? "Polski" : "English"]
        XCTAssertTrue(choice.exists)
        choice.tap()
        let expectedSubtitle = polish
            ? "Wybierz, w czym możemy dziś pomóc Twojej roślinie."
            : "Choose how we can help your plant today."
        let localizedSubtitle = app.staticTexts.matching(identifier: "welcome.subtitle")
            .matching(NSPredicate(format: "label == %@", expectedSubtitle)).firstMatch
        XCTAssertTrue(localizedSubtitle.waitForExistence(timeout: 3),
                      "The selected language must update the welcome text")

        enterScan(app, care: care)
        assertUnavailable(app, polish: polish)
        app.buttons["analysis.retry.button"].tap()
        assertUnavailable(app, polish: polish)
        app.buttons["analysis.retry.button"].tap()
        assertUnavailable(app, polish: polish)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "unavailable-\(care ? "care" : "problem")-\(polish ? "pl" : "en")"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["analysis.back.button"].tap()
        XCTAssertTrue(app.staticTexts[care ? "care.method.title" : "welcome.title"]
            .waitForExistence(timeout: 3))
        if care {
            app.buttons["care.method.scan"].tap()
        } else {
            enterScan(app, care: false)
        }
        assertUnavailable(app, polish: polish)
        app.buttons["analysis.catalogue.button"].tap()
        let catalogueError = app.staticTexts["catalogue.error"]
        XCTAssertTrue(catalogueError.waitForExistence(timeout: 5))
        XCTAssertEqual(catalogueError.label, polish
                       ? "Nie udało się pobrać katalogu." : "Couldn’t load the catalogue.")
        XCTAssertTrue(app.buttons["catalogue.back"].isHittable)
        app.buttons["catalogue.back"].tap()
        if care {
            XCTAssertTrue(app.staticTexts["care.method.title"].waitForExistence(timeout: 3))
        } else {
            assertUnavailable(app, polish: polish)
            app.buttons["analysis.back.button"].tap()
            XCTAssertTrue(app.staticTexts["welcome.title"].waitForExistence(timeout: 3))
        }
        app.terminate()
    }

    @MainActor
    private func enterScan(_ app: XCUIApplication, care: Bool) {
        app.buttons[care ? "welcome.intent.care" : "welcome.intent.problem"].tap()
        if care {
            XCTAssertTrue(app.staticTexts["care.method.title"].waitForExistence(timeout: 3))
            app.buttons["care.method.scan"].tap()
        }
    }

    @MainActor
    private func assertUnavailable(_ app: XCUIApplication, polish: Bool) {
        let title = app.staticTexts["analysis.unavailable.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.label, polish
                       ? "Analiza jest tymczasowo niedostępna."
                       : "Analysis is temporarily unavailable.")
        XCTAssertTrue(app.buttons["analysis.retry.button"].isHittable)
        XCTAssertTrue(app.buttons["analysis.back.button"].isHittable)
        XCTAssertTrue(app.buttons["analysis.catalogue.button"].isHittable)
        for identifier in [
            "quota.starter.banner", "analysis.quota_exhausted.title",
            "photo.select.standard", "photo.select.large", "care.photo.ready.badge",
            "care.lighting.estimate.button", "result.plant.name", "result.cause.title",
            "result.evidence.section", "result.first_action.section", "analysis.waiting.neutral_title"
        ] {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].exists, identifier)
        }
        XCTAssertFalse(app.staticTexts["Swiss Cheese Plant"].exists)
        XCTAssertFalse(app.staticTexts["Monstera dziurawa"].exists)
        XCTAssertFalse(app.staticTexts["signed_receipt_v3"].exists)
    }
}
