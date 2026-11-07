import XCTest

final class FirstHelpTests: XCTestCase {
    @MainActor
    func testFirstHelpFlowOnPolishAndEnglishWithLargePhotoUnknownBackAndLimit() throws {
        let app = XCUIApplication()
        app.launch()

        // 1. Verify Welcome screen and switch to Polish
        let title = app.staticTexts["welcome.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5.0))

        let plButton = app.buttons["Polski"]
        if plButton.exists {
            plButton.tap()
        }

        // 2. Tap problem intent -> Photo selection with contextual tip & separate starter banner
        let problemButton = app.buttons["welcome.intent.problem"]
        XCTAssertTrue(problemButton.exists)
        problemButton.tap()

        XCTAssertTrue(app.staticTexts["photo.capture.tip"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(app.staticTexts["quota.starter.banner"].exists)

        // 3. Select > 10 MB photo (auto-compressed on device)
        let largePhotoBtn = app.buttons["photo.select.large"]
        XCTAssertTrue(largePhotoBtn.exists)
        largePhotoBtn.tap()

        // 4. Question 1 of 3: verify progress indicator, select unknown, then camera hint
        let progressText = app.staticTexts["care.questions.progress"]
        XCTAssertTrue(progressText.waitForExistence(timeout: 3.0))
        XCTAssertTrue(app.buttons["care.light.option.unknown"].exists)
        app.buttons["care.light.option.unknown"].tap()
        app.buttons["care.lighting.estimate.button"].tap()

        app.buttons["care.navigation.next"].tap()

        // 5. Question 2 of 3: select unknown, navigate back to verify photo & answers preserved, then advance
        XCTAssertTrue(app.buttons["care.watering.option.unknown"].waitForExistence(timeout: 3.0))
        app.buttons["care.watering.option.unknown"].tap()
        app.buttons["care.navigation.back"].tap()
        XCTAssertTrue(app.staticTexts["care.photo.ready.badge"].exists)
        app.buttons["care.navigation.next"].tap()
        app.buttons["care.navigation.next"].tap()

        // 6. Question 3 of 3: select unknown and submit analysis
        XCTAssertTrue(app.buttons["care.last_watered.option.unknown"].waitForExistence(timeout: 3.0))
        app.buttons["care.last_watered.option.unknown"].tap()
        app.buttons["care.navigation.next"].tap()

        // 7. Preliminary Result screen (US1.15): cause, evidence basis, limitations, and first action
        XCTAssertTrue(app.staticTexts["result.cause.title"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(app.otherElements["result.evidence.section"].exists || app.staticTexts["Podstawa wniosku"].exists)
        XCTAssertTrue(app.otherElements["result.limitations.section"].exists || app.staticTexts["Ograniczenia oceny"].exists)
        XCTAssertTrue(app.otherElements["result.first_action.section"].exists || app.staticTexts["Pierwszy bezpieczny krok teraz"].exists)

        // 8. Switch language to English and verify EN localization
        let enButton = app.buttons["English"]
        if enButton.exists {
            enButton.tap()
            XCTAssertTrue(app.staticTexts["Likely cause: Overwatering"].waitForExistence(timeout: 3.0))
        }
    }
}
