import XCTest

/// Rendered UI against the isolated DEBUG HTTP/SDK/SQLite fixture, never live auth.
final class CatalogueSaveUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testFreeSaveEnglish() { verifySave(.en, paid: false) }
    @MainActor func testFreeSavePolish() { verifySave(.pl, paid: false) }
    @MainActor func testPaidSaveEnglish() { verifySave(.en, paid: true) }
    @MainActor func testPaidSavePolish() { verifySave(.pl, paid: true) }
    @MainActor func testPreflightLimitEnglish() { verifyPreflightLimit(.en) }
    @MainActor func testPreflightLimitPolish() { verifyPreflightLimit(.pl) }
    @MainActor func testServerLimitEnglish() { verifyServerFailure(.en, limit: true) }
    @MainActor func testServerLimitPolish() { verifyServerFailure(.pl, limit: true) }
    @MainActor func testServerUnavailableEnglish() { verifyServerFailure(.en, limit: false) }
    @MainActor func testServerUnavailablePolish() { verifyServerFailure(.pl, limit: false) }
    @MainActor func testLostResponseRestartEnglish() { verifyLostResponse(.en) }
    @MainActor func testLostResponseRestartPolish() { verifyLostResponse(.pl) }
    @MainActor func testNativeCancellationRestartEnglish() { verifyNativeCancellation(.en) }
    @MainActor func testNativeCancellationRestartPolish() { verifyNativeCancellation(.pl) }
    @MainActor func testNativeSuccessEnglish() { verifyNativeSuccess(.en) }
    @MainActor func testNativeSuccessPolish() { verifyNativeSuccess(.pl) }
    @MainActor func testACKFailureRestartEnglish() { verifyACKFailureRestart(.en) }
    @MainActor func testACKFailureRestartPolish() { verifyACKFailureRestart(.pl) }

    @MainActor func testCollectionOpensSameServerCardAfterRestart() {
        let run = Run("free2", .en)
        defer { run.app.terminate() }
        openCatalogue(run)
        enterName(run, run.language.input)
        submit(run)
        let saved = assertCard(run, name: run.language.canonicalName)
        restart(run)
        tap(run, "collection.open", "My plants")
        let plantId = saved.dropFirst("catalogue.saved.card.".count)
        tap(run, "collection.plant." + plantId, run.language.canonicalName)
        XCTAssertEqual(identity(run, "catalogue.saved.card."), saved)
        localizedText(run, "catalogue.saved.name", run.language.canonicalName, run.language.canonicalName)
    }

    @MainActor func testPlantDeletionLostReplyKeepsNeighbourAfterRestart() {
        let run = Run("plantDeletion", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        let first = run.app.buttons["Fixture 1"]
        let second = run.app.buttons["Fixture 2"]
        enabled(first)
        first.tap()
        let delete = run.app.buttons["collection.delete"]
        require(delete)
        if !delete.isHittable { run.app.swipeUp() }
        enabled(delete)
        delete.tap()
        let alert = run.app.alerts["Delete this plant?"]
        require(alert)
        alert.buttons["Cancel"].tap()
        enabled(delete)
        delete.tap()
        require(alert)
        alert.buttons["collection.delete.confirm"].firstMatch.tap()
        require(run.app.staticTexts["collection.delete.pending"])
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
        restart(run)
        tap(run, "collection.open", "My plants")
        enabled(second)
        XCTAssertFalse(first.exists)
        second.tap()
        require(run.app.staticTexts["catalogue.saved.name"])
        XCTAssertEqual(run.app.staticTexts["catalogue.saved.name"].label, "Fixture 2")
    }

    @MainActor func testCollectionShowsOnlyThePendingFirstAidControl() {
        let run = Run("firstAidControl", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        let activePlant = run.app.buttons.matching(NSPredicate(format: "label == %@", "Fixture 1")).firstMatch
        enabled(activePlant)
        activePlant.tap()
        let date = run.app.staticTexts["catalogue.saved.firstAid.date"]
        require(date)
        XCTAssertEqual(date.label, "First-aid soil check · 2026-11-08")
        require(run.app.descendants(matching: .any)["catalogue.saved.firstAid.source"].firstMatch)
        tap(run, "collection.back", "Back")
        let undonePlant = run.app.buttons.matching(NSPredicate(format: "label == %@", "Fixture 2")).firstMatch
        enabled(undonePlant)
        undonePlant.tap()
        require(run.app.staticTexts["catalogue.saved.name"])
        XCTAssertFalse(date.exists)
        XCTAssertFalse(run.app.descendants(matching: .any)["catalogue.saved.firstAid.source"].firstMatch.exists)
    }

    @MainActor func testCollectionShowsVerifiedTrialDateWithOptInOffByDefault() {
        let run = Run("trialReminder", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        let end = run.app.staticTexts["trial.reminder.end"]
        require(end)
        XCTAssertTrue(end.label.contains("2099"))
        let optIn = run.app.switches["trial.reminder.optIn"]
        require(optIn)
        XCTAssertEqual(optIn.value as? String, "0")
    }

    private enum Language: String {
        case en, pl
        func text(_ english: String, _ polish: String) -> String { self == .pl ? polish : english }
        var other: Language { self == .pl ? .en : .pl }
        var input: String { text("  My fern  ", "  Moja paproć  ") }
        var canonicalName: String { text("My fern", "Moja paproć") }
        var secondName: String { text("Another fern", "Druga paproć") }
        var placeholder: String { text("Plant name (optional)", "Nazwa rośliny (opcjonalnie)") }
    }

    @MainActor
    private struct Run {
        let app = XCUIApplication()
        let scenario: String
        let language: Language
        // One namespace for this test, including every subsequent process launch.
        let namespace = UUID().uuidString

        init(_ scenario: String, _ language: Language) {
            self.scenario = scenario
            self.language = language
            app.launchArguments = [
                "--catalogue-fixture", scenario, "--catalogue-namespace", namespace,
                "-AppleLanguages", "(" + language.rawValue + ")",
                "-AppleLocale", language == .pl ? "pl_PL" : "en_US"
            ]
        }
    }

    @MainActor
    private func require(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), element.identifier, file: file, line: line)
    }

    @MainActor
    private func enabled(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed,
                       element.identifier, file: file, line: line)
    }

    @MainActor
    private func tap(_ run: Run, _ identifier: String, _ label: String? = nil) {
        let button = run.app.buttons[identifier]
        enabled(button)
        if let label { XCTAssertEqual(button.label, label) }
        button.tap()
    }

    @MainActor
    private func selectLanguage(_ run: Run, _ language: Language) {
        let choice = run.app.segmentedControls["welcome.language.picker"]
            .buttons[language.text("English", "Polski")]
        enabled(choice)
        choice.tap()
    }

    @MainActor
    private func launch(_ run: Run) {
        run.app.launch()
        selectLanguage(run, run.language)
    }

    @MainActor
    private func openCatalogue(_ run: Run) {
        launch(run)
        tap(run, "welcome.intent.care",
            run.language.text("Set up care and schedule", "Dobierz pielęgnację i harmonogram"))
        tap(run, "care.method.catalogue",
            run.language.text("Choose species from catalogue (no photo)", "Wybierz gatunek z katalogu (bez zdjęcia)"))
        chooseSpecies(run)
    }

    @MainActor
    private func chooseSpecies(_ run: Run) {
        tap(run, "catalogue.species.fixture_fern")
        localizedText(run, "catalogue.selected.scientific", "Nephrolepis exaltata", "Nephrolepis exaltata")
        let field = run.app.textFields["catalogue.save.name"]
        enabled(field)
        XCTAssertEqual(field.placeholderValue, run.language.placeholder)
        let value = field.value as? String
        XCTAssertTrue(value == "" || value == run.language.placeholder, "A new plant intent must have an empty form")
        XCTAssertFalse(run.app.staticTexts["catalogue.save.saved"].exists)
        XCTAssertFalse(run.app.buttons["catalogue.save.retry"].exists)
    }

    @MainActor
    private func enterName(_ run: Run, _ name: String) {
        let field = run.app.textFields["catalogue.save.name"]
        enabled(field)
        field.tap()
        field.typeText(name + "\n")
        XCTAssertEqual(field.value as? String, name)
    }

    @MainActor
    private func submit(_ run: Run) {
        tap(run, "catalogue.save.submit", run.language.text("Save plant", "Zapisz roślinę"))
    }

    @MainActor
    private func retry(_ run: Run) {
        tap(run, "catalogue.save.retry", run.language.text("Retry this save", "Ponów ten sam zapis"))
    }

    @MainActor
    private func localizedText(
        _ run: Run, _ identifier: String, _ english: String, _ polish: String,
        language: Language? = nil
    ) {
        let expected = (language ?? run.language).text(english, polish)
        let element = run.app.staticTexts.matching(identifier: identifier)
            .matching(NSPredicate(format: "label == %@", expected)).firstMatch
        require(element)
        XCTAssertEqual(element.label, expected)
    }

    @MainActor
    private func identity(_ run: Run, _ prefix: String) -> String {
        let element = run.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        require(element)
        let identifier = element.identifier
        let uuid = String(identifier.dropFirst(prefix.count))
        XCTAssertNotNil(UUID(uuidString: uuid), "Identity must come from the real operation/server row")
        XCTAssertFalse(run.app.staticTexts[uuid].exists, "Technical identity must not be product copy")
        return identifier
    }

    @MainActor
    private func operation(_ run: Run) -> String { identity(run, "catalogue.save.operation.") }

    @MainActor
    private func assertFrozen(_ run: Run, name: String) {
        let field = run.app.textFields["catalogue.save.name"]
        require(field)
        XCTAssertEqual(field.value as? String, name)
        XCTAssertFalse(field.isEnabled)
        XCTAssertFalse(run.app.buttons["catalogue.save.submit"].exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.save.saved"].exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
    }

    @MainActor
    private func assertPending(_ run: Run, serverLimit: Bool = false, serviceUnavailable: Bool = false,
                               language: Language? = nil) {
        if serverLimit {
            localizedText(run, "catalogue.save.serverLimit",
                          "The server rejected this save: collection limit reached. The plant is not saved.",
                          "Serwer odrzucił zapis: limit kolekcji został osiągnięty. Roślina nie jest zapisana.",
                          language: language)
        } else if serviceUnavailable {
            localizedText(run, "catalogue.save.pending",
                          "The service couldn’t confirm the save. It is pending a retry.",
                          "Usługa nie potwierdziła zapisu. Zapis oczekuje na ponowienie.", language: language)
        } else {
            localizedText(run, "catalogue.save.pending",
                          "Save pending. The plant has not been confirmed saved yet.",
                          "Oczekuje na zapis. Nie potwierdzono jeszcze zapisania rośliny.", language: language)
        }
        assertFrozen(run, name: run.language.input)
        enabled(run.app.buttons["catalogue.save.retry"])
        require(run.app.buttons["catalogue.change"])
        XCTAssertFalse(run.app.buttons["catalogue.change"].isEnabled)
        XCTAssertFalse(run.app.buttons["catalogue.save.edit"].exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.save.limit"].exists)
    }

    @MainActor
    private func assertLimit(_ run: Run, name: String) {
        localizedText(run, "catalogue.save.limit",
                      "The free collection holds 3 plants. This plant was not submitted.",
                      "Bezpłatna kolekcja mieści 3 rośliny. Nie wysłano nowej rośliny.")
        assertFrozen(run, name: name)
        enabled(run.app.buttons["catalogue.save.retry"])
        enabled(run.app.buttons["catalogue.save.edit"])
        XCTAssertEqual(run.app.buttons["catalogue.save.edit"].label,
                       run.language.text("Edit as a new save", "Edytuj jako nowy zapis"))
        enabled(run.app.buttons["catalogue.change"])
        XCTAssertFalse(run.app.staticTexts["catalogue.save.serverLimit"].exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.save.pending"].exists)
    }

    @MainActor
    private func assertCard(_ run: Run, name: String) -> String {
        localizedText(run, "catalogue.save.saved", "Plant saved", "Roślina zapisana")
        let card = identity(run, "catalogue.saved.card.")
        localizedText(run, "catalogue.saved.name", name, name)
        localizedText(run, "catalogue.saved.species", "Fern", "Paproć")
        localizedText(run, "catalogue.selected.scientific", "Nephrolepis exaltata", "Nephrolepis exaltata")
        XCTAssertFalse(run.app.textFields["catalogue.save.name"].exists)
        XCTAssertFalse(run.app.buttons["catalogue.save.submit"].exists)
        XCTAssertFalse(run.app.buttons["catalogue.save.retry"].exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.save.pending"].exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.detailsUnavailable"].exists)
        enabled(run.app.buttons["catalogue.change"])
        return card
    }

    @MainActor
    private func screenshot(_ run: Run, _ phase: String) {
        let attachment = XCTAttachment(screenshot: run.app.screenshot())
        attachment.name = run.scenario + "-" + run.language.rawValue + "-" + phase
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func restart(_ run: Run) {
        run.app.terminate()
        launch(run) // Identical fixture arguments, scenario, namespace and persisted SDK session.
    }

    @MainActor
    private func verifySave(_ language: Language, paid: Bool) {
        let run = Run(paid ? "paid4" : "free2", language)
        defer { screenshot(run, "final"); run.app.terminate() }
        openCatalogue(run)
        enterName(run, language.input)
        submit(run)
        let firstCard = assertCard(run, name: language.canonicalName)
        let firstOperation = operation(run)
        screenshot(run, "original-saved")
        restart(run)
        XCTAssertEqual(assertCard(run, name: language.canonicalName), firstCard)
        XCTAssertEqual(operation(run), firstOperation)

        // Choosing the same species again is an explicit second instance, never receipt replay.
        tap(run, "catalogue.change", language.text("Choose another species", "Wybierz inny gatunek"))
        chooseSpecies(run)
        enterName(run, language.secondName)
        submit(run)
        if paid {
            let secondCard = assertCard(run, name: language.secondName)
            XCTAssertNotEqual(secondCard, firstCard)
            let secondOperation = operation(run)
            XCTAssertNotEqual(secondOperation, firstOperation)
            restart(run)
            XCTAssertEqual(assertCard(run, name: language.secondName), secondCard)
            XCTAssertEqual(operation(run), secondOperation)
        } else {
            assertLimit(run, name: language.secondName)
            let secondOperation = operation(run)
            XCTAssertNotEqual(secondOperation, firstOperation)
            retry(run)
            assertLimit(run, name: language.secondName)
            XCTAssertEqual(operation(run), secondOperation)
        }
    }

    @MainActor
    private func verifyPreflightLimit(_ language: Language) {
        let run = Run("cap3", language)
        defer { screenshot(run, "final"); run.app.terminate() }
        openCatalogue(run)
        enterName(run, language.input)
        submit(run)
        assertLimit(run, name: language.input)
        let originalOperation = operation(run)
        retry(run)
        assertLimit(run, name: language.input)
        XCTAssertEqual(operation(run), originalOperation)
    }

    @MainActor
    private func verifyServerFailure(_ language: Language, limit: Bool) {
        let run = Run(limit ? "server409" : "server503", language)
        defer { screenshot(run, "final"); run.app.terminate() }
        openCatalogue(run)
        enterName(run, language.input)
        submit(run)
        assertPending(run, serverLimit: limit, serviceUnavailable: !limit)
        let originalOperation = operation(run)
        screenshot(run, "pending")
        // Metadata refresh must preserve this pending operation and its frozen input.
        selectLanguage(run, language.other)
        assertPending(run, serverLimit: limit, serviceUnavailable: !limit, language: language.other)
        XCTAssertEqual(operation(run), originalOperation)
        selectLanguage(run, language)
        assertPending(run, serverLimit: limit, serviceUnavailable: !limit)
        retry(run)
        assertPending(run, serverLimit: limit, serviceUnavailable: !limit)
        XCTAssertEqual(operation(run), originalOperation)
    }

    @MainActor
    private func verifyLostResponse(_ language: Language) {
        let run = Run("lostresponse", language)
        defer { screenshot(run, "final"); run.app.terminate() }
        openCatalogue(run)
        enterName(run, language.input)
        submit(run)
        assertPending(run)
        let originalOperation = operation(run)
        screenshot(run, "committed-response-lost")
        restart(run)
        assertPending(run)
        XCTAssertEqual(operation(run), originalOperation)
        // The ledger has already committed at cap=3. Only replay of this exact send can succeed.
        retry(run)
        let card = assertCard(run, name: language.canonicalName)
        XCTAssertEqual(operation(run), originalOperation)
        screenshot(run, "retry-server-card")
        restart(run)
        XCTAssertEqual(assertCard(run, name: language.canonicalName), card)
        XCTAssertEqual(operation(run), originalOperation)
    }

    @MainActor
    private func assertACKFlow(_ run: Run, unavailable: Bool) {
        if unavailable {
            localizedText(run, "catalogue.save.unavailable",
                          "Save unavailable. The plant has not been confirmed saved.",
                          "Zapis jest niedostępny. Nie potwierdzono zapisania rośliny.")
            XCTAssertFalse(run.app.staticTexts["catalogue.save.pending"].exists)
        } else {
            localizedText(run, "catalogue.save.pending",
                          "Save pending. The plant has not been confirmed saved yet.",
                          "Oczekuje na zapis. Nie potwierdzono jeszcze zapisania rośliny.")
            XCTAssertFalse(run.app.staticTexts["catalogue.save.unavailable"].exists)
        }
        localizedText(run, "catalogue.selected.scientific", "Nephrolepis exaltata", "Nephrolepis exaltata")
        assertFrozen(run, name: "Luna")
        XCTAssertEqual(run.app.textFields["catalogue.save.name"].placeholderValue, run.language.placeholder)
        enabled(run.app.buttons["catalogue.save.retry"])
        require(run.app.buttons["catalogue.change"])
        XCTAssertFalse(run.app.buttons["catalogue.change"].isEnabled)
        XCTAssertFalse(run.app.buttons["catalogue.save.edit"].exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.save.limit"].exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.save.serverLimit"].exists)
        XCTAssertFalse(run.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.card.")).firstMatch.exists)
    }

    @MainActor
    private func verifyACKFailureRestart(_ language: Language) {
        let run = Run("ackFailure", language)
        defer { screenshot(run, "final"); run.app.terminate() }
        // Setup has only checkpointed/enqueued an intent; Root restores it without a send.
        launch(run)
        assertACKFlow(run, unavailable: false)
        let originalOperation = operation(run)
        retry(run)
        assertACKFlow(run, unavailable: true)
        XCTAssertEqual(operation(run), originalOperation)
        screenshot(run, "first-sqlite-ack-failure")

        // Ordinary back navigation must preserve both the journal and the resume metadata.
        tap(run, "catalogue.back", language.text("Back", "Wstecz"))
        tap(run, "care.method.catalogue",
            language.text("Choose species from catalogue (no photo)", "Wybierz gatunek z katalogu (bez zdjęcia)"))
        assertACKFlow(run, unavailable: false)
        XCTAssertEqual(operation(run), originalOperation)
        restart(run)
        assertACKFlow(run, unavailable: false)
        XCTAssertEqual(operation(run), originalOperation)
        retry(run)
        assertACKFlow(run, unavailable: true)
        XCTAssertEqual(operation(run), originalOperation)
        screenshot(run, "second-sqlite-ack-failure")

        // Only the two real persisted POSTs allow the next store to reopen writable.
        restart(run)
        assertACKFlow(run, unavailable: false)
        XCTAssertEqual(operation(run), originalOperation)
        retry(run)
        let serverCard = assertCard(run, name: "Luna")
        XCTAssertEqual(operation(run), originalOperation)
        screenshot(run, "durable-ack-recovery")
        restart(run)
        XCTAssertEqual(assertCard(run, name: "Luna"), serverCard)
        XCTAssertEqual(operation(run), originalOperation)
        screenshot(run, "durable-card-after-restart")
    }

    @MainActor
    private func assertSignIn(_ run: Run) {
        localizedText(run, "catalogue.save.signInRequired",
                      "Sign in to save your chosen plant.", "Zaloguj się, aby zapisać wybraną roślinę.")
        assertFrozen(run, name: run.language.input)
        enabled(run.app.buttons["catalogue.save.apple"])
        enabled(run.app.buttons["catalogue.save.google"])
        XCTAssertEqual(run.app.buttons["catalogue.save.apple"].label,
                       run.language.text("Continue with Apple", "Kontynuuj z Apple"))
        XCTAssertEqual(run.app.buttons["catalogue.save.google"].label,
                       run.language.text("Continue with Google", "Kontynuuj z Google"))
    }

    @MainActor
    private func assertCancellation(_ run: Run) {
        localizedText(run, "catalogue.save.notice",
                      "Sign-in cancelled. Your chosen input has been retained.",
                      "Logowanie anulowane. Wybrane dane zostały zachowane.")
        assertSignIn(run)
    }

    @MainActor
    private func verifyNativeCancellation(_ language: Language) {
        let run = Run("guestProviderCancel", language)
        defer { screenshot(run, "final"); run.app.terminate() }
        openCatalogue(run)
        enterName(run, language.input)
        submit(run)
        assertSignIn(run)
        let originalOperation = operation(run)
        tap(run, language == .en ? "catalogue.save.apple" : "catalogue.save.google")
        assertCancellation(run)
        XCTAssertEqual(operation(run), originalOperation)
        screenshot(run, "native-cancelled")
        restart(run)
        assertSignIn(run)
        XCTAssertEqual(operation(run), originalOperation)
        // A second explicit native attempt after process restart still retains the guest input.
        tap(run, language == .en ? "catalogue.save.google" : "catalogue.save.apple")
        assertCancellation(run)
        XCTAssertEqual(operation(run), originalOperation)
    }

    @MainActor
    private func verifyNativeSuccess(_ language: Language) {
        let run = Run("guestProviderSuccess", language)
        defer { screenshot(run, "final"); run.app.terminate() }
        openCatalogue(run)
        enterName(run, language.input)
        submit(run)
        assertSignIn(run)
        let originalOperation = operation(run)
        tap(run, language == .en ? "catalogue.save.google" : "catalogue.save.apple")
        let card = assertCard(run, name: language.canonicalName)
        XCTAssertEqual(operation(run), originalOperation)
        screenshot(run, "native-server-card")
        // Only the guest had a public species preference. The permanent owner's SQLite flow
        // and SDK session must bootstrap the matching card without manual species selection.
        restart(run)
        XCTAssertEqual(assertCard(run, name: language.canonicalName), card)
        XCTAssertEqual(operation(run), originalOperation)
        XCTAssertFalse(run.app.buttons["catalogue.save.apple"].exists)
        XCTAssertFalse(run.app.buttons["catalogue.save.google"].exists)
    }
}
