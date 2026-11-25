import XCTest

/// Rendered UI against the isolated DEBUG HTTP/SDK/SQLite fixture, never live auth.
final class CatalogueSaveUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testCatalogueListFirstExplicitResumeEnglishAndPolish() throws {
        for language in [Language.en, .pl] {
            let run = Run("guestProviderSuccess", language)
            defer { run.app.terminate() }
            openCatalogue(run)
            enterName(run, language.input)
            submit(run)
            assertSignIn(run)
            let originalOperation = operation(run)
            tap(run, "catalogue.back")
            tap(run, "care.method.catalogue")
            c1AssertList(run)
            tap(run, "catalogue.resume")
            assertSignIn(run)
            XCTAssertEqual(operation(run), originalOperation)

            // Raw cold launches deliberately bypass the legacy resume convenience.
            run.app.terminate()
            launch(run)
            c1AssertList(run)
            tap(run, "catalogue.resume", language.text("Continue save", "Kontynuuj zapisywanie"))
            assertSignIn(run)
            XCTAssertEqual(operation(run), originalOperation)
            tap(run, "catalogue.save.google")
            let originalCard = assertCard(run, name: language.canonicalName)
            XCTAssertEqual(operation(run), originalOperation)
            tap(run, "catalogue.change")
            c1AssertList(run)
            tap(run, "catalogue.resume", language.text("Open saved plant", "Otwórz zapisaną roślinę"))
            XCTAssertEqual(assertCard(run, name: language.canonicalName), originalCard)
            XCTAssertEqual(operation(run), originalOperation)

            run.app.terminate()
            launch(run)
            c1AssertList(run)
            tap(run, "catalogue.resume", language.text("Open saved plant", "Otwórz zapisaną roślinę"))
            let resumedCard = assertCard(run, name: language.canonicalName)
            XCTAssertEqual(resumedCard, originalCard)
            XCTAssertEqual(operation(run), originalOperation)
            try c1Proof(run, kind: "resume", fields: [
                "originalCardId": authBUUID(originalCard, "catalogue.saved.card.").lowercased(),
                "resumedCardId": authBUUID(resumedCard, "catalogue.saved.card.").lowercased(),
                "originalOperation": authBUUID(originalOperation, "catalogue.save.operation.").lowercased(),
                "finalOperation": authBUUID(operation(run), "catalogue.save.operation.").lowercased()
            ])
        }
    }

    @MainActor func testCatalogueFreshIntentEnglishAndPolish() throws {
        for language in [Language.en, .pl] {
            let run = Run("guestProvidersUnavailable", language)
            defer { run.app.terminate() }
            openCatalogue(run)
            enterName(run, language.input)
            submit(run)
            require(run.app.staticTexts["catalogue.save.signInRequired"])
            assertFrozen(run, name: language.input)
            let originalOperation = operation(run)
            tap(run, "catalogue.change")
            c1AssertList(run)
            chooseSpecies(run) // The same slug must create a fresh instance.
            let field = run.app.textFields["catalogue.save.name"]
            let value = try XCTUnwrap(field.value as? String)
            let freshNameEmpty = value.isEmpty || value == field.placeholderValue
            XCTAssertTrue(freshNameEmpty)
            XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
            enterName(run, language.secondName)
            submit(run)
            require(run.app.staticTexts["catalogue.save.signInRequired"])
            assertFrozen(run, name: language.secondName)
            let newOperation = operation(run)
            XCTAssertNotEqual(newOperation, originalOperation)
            XCTAssertFalse(run.app.buttons["catalogue.save.apple"].exists)
            XCTAssertFalse(run.app.buttons["catalogue.save.google"].exists)
            try c1Proof(run, kind: "new", fields: [
                "originalOperation": authBUUID(originalOperation, "catalogue.save.operation.").lowercased(),
                "newOperation": authBUUID(newOperation, "catalogue.save.operation.").lowercased(),
                "freshNameEmpty": freshNameEmpty
            ])
        }
    }

    @MainActor func testCatalogueOutcomeVisibilityEnglishAndPolish() throws {
        for language in [Language.en, .pl] {
            for longDetails in [false, true] {
                for cancelled in [true, false] {
                    let kind = (longDetails ? "long-" : "short-") + (cancelled ? "cancel" : "error")
                    let run = Run(cancelled ? "guestProviderCancel" : "guestProviderFailureRetry",
                                  language, longDetails: longDetails)
                    defer { run.app.terminate() }
                    launch(run)
                    tap(run, "welcome.intent.care")
                    tap(run, "care.method.catalogue")
                    tap(run, "catalogue.species.fixture_fern")
                    if longDetails {
                        let paragraph = language.text(
                            "Nephrolepis exaltata is a fern with long, arching fronds. Each frond carries many small leaflets along its central stem.",
                            "Nephrolepis exaltata to paproć o długich, łukowato wygiętych liściach. Wzdłuż osi każdego liścia wyrastają liczne drobne listki.")
                        let fullText = Array(repeating: paragraph, count: 16).joined(separator: "\n\n")
                        let description = run.app.staticTexts.matching(NSPredicate(format: "label == %@", fullText)).firstMatch
                        require(description)
                        XCTAssertEqual(description.label, fullText, "Long details must render the complete response")
                    }
                    require(run.app.textFields["catalogue.save.name"])
                    let scroll = try c1DetailScroll(run, containing: "catalogue.save.name")
                    c1Reach(run.app.textFields["catalogue.save.name"], in: scroll)
                    enterName(run, language.input)
                    c1Reach(run.app.buttons["catalogue.save.submit"], in: scroll)
                    submit(run)
                    require(run.app.staticTexts["catalogue.save.signInRequired"])
                    c1Reach(run.app.buttons["catalogue.save.google"], in: scroll)
                    tap(run, "catalogue.save.google")
                    localizedText(run, "catalogue.save.notice",
                                  cancelled ? "Sign-in cancelled. Your chosen input has been retained."
                                      : "Sign-in failed. Try again or go back.",
                                  cancelled ? "Logowanie anulowane. Wybrane dane zostały zachowane."
                                      : "Logowanie nie powiodło się. Spróbuj ponownie lub wróć.")
                    // No scrolling after the outcome: this verifies the production feedback anchor.
                    let notice = run.app.staticTexts["catalogue.save.notice"]
                    let provider = run.app.buttons["catalogue.save.google"]
                    enabled(notice)
                    enabled(provider)
                    let detailScroll = try c1DetailScroll(run, containing: "catalogue.save.notice")
                    var viewport = detailScroll.frame.intersection(run.app.windows.firstMatch.frame)
                    for bar in run.app.navigationBars.allElementsBoundByIndex where bar.exists {
                        let frame = bar.frame
                        if frame.intersects(viewport) {
                            let bottom = viewport.maxY
                            viewport.origin.y = max(viewport.minY, frame.maxY)
                            viewport.size.height = bottom - viewport.minY
                        }
                    }
                    for id in ["catalogue.change", "catalogue.back"] {
                        let footer = run.app.buttons[id]
                        require(footer)
                        let frame = footer.frame
                        if frame.intersects(viewport) {
                            viewport.size.height = min(viewport.maxY, frame.minY) - viewport.minY
                        }
                    }
                    let noticeFrame = notice.frame
                    let providerFrame = provider.frame
                    XCTAssertTrue(viewport.contains(noticeFrame), "The complete notice must be visible")
                    XCTAssertTrue(viewport.contains(providerFrame), "The complete Google CTA must be visible")
                    try c1Proof(run, kind: kind, fields: [
                        "noticeFrame": c1Rect(noticeFrame),
                        "providerFrame": c1Rect(providerFrame),
                        "viewportFrame": c1Rect(viewport),
                        "nativeNoticeHittable": notice.exists && notice.isEnabled && notice.isHittable,
                        "providerHittable": provider.exists && provider.isEnabled && provider.isHittable
                    ])
                }
            }
        }
    }

    @MainActor
    private func c1AssertList(_ run: Run) {
        enabled(run.app.textFields["catalogue.search"])
        enabled(run.app.buttons["catalogue.species.fixture_fern"])
        XCTAssertFalse(run.app.textFields["catalogue.save.name"].exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.save.saved"].exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
        XCTAssertFalse(run.app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.card.")).firstMatch.exists)
    }

    @MainActor
    private func c1DetailScroll(_ run: Run, containing identifier: String) throws -> XCUIElement {
        let matches = run.app.scrollViews.allElementsBoundByIndex.filter {
            $0.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists
        }
        XCTAssertEqual(matches.count, 1, "Use the current detail scroll containing the actual control")
        return try XCTUnwrap(matches.first)
    }

    @MainActor
    private func c1Reach(_ element: XCUIElement, in scroll: XCUIElement) {
        require(element)
        for _ in 0..<24 {
            if element.isHittable { break }
            scroll.swipeUp()
        }
        enabled(element)
    }

    private func c1Rect(_ rect: CGRect) -> [Double] {
        let values = [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) }
        XCTAssertTrue(values.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        return values
    }

    @MainActor
    private func c1Proof(_ run: Run, kind: String, fields: [String: Any]) throws {
        var proof = fields
        proof["namespace"] = try XCTUnwrap(UUID(uuidString: run.namespace)).uuidString.lowercased()
        proof["scenario"] = run.scenario
        proof["language"] = run.language.rawValue
        proof["kind"] = kind
        let screenshot = XCTAttachment(screenshot: run.app.screenshot())
        screenshot.name = "c1-" + kind + "-" + run.language.rawValue
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "c1-proof-" + kind + "-" + run.language.rawValue
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testDirectAnalysisEntryNavigationEnglish() { verifyDirectEntry(.en) }
    @MainActor func testDirectAnalysisEntryNavigationPolish() { verifyDirectEntry(.pl) }

    @MainActor
    private func verifyDirectEntry(_ language: Language) {
        for scenario in ["directEntryDiagnosisExhausted", "directEntryIdentificationExhausted"] {
            let run = Run(scenario, language, today: true)
            launch(run)
            require(run.app.staticTexts["today.title"])
            for diagnosis in [true, false] {
                tap(run, diagnosis ? "welcome.check" : "welcome.identify",
                    diagnosis ? language.text("Check plant health", "Sprawdź zdrowie rośliny")
                        : language.text("Identify species", "Rozpoznaj gatunek"))
                let header = run.app.staticTexts["analysis.photo.header"]
                require(header)
                XCTAssertEqual(header.label, diagnosis
                    ? language.text("Check plant health", "Sprawdź zdrowie rośliny")
                    : language.text("Identify species", "Rozpoznaj gatunek"))
                XCTAssertFalse(run.app.buttons["care.method.scan"].exists)
                XCTAssertFalse(run.app.buttons["care.method.catalogue"].exists)
                XCTAssertFalse(run.app.staticTexts["care.questions.progress"].exists)
                let exhausted = diagnosis == (scenario == "directEntryDiagnosisExhausted")
                let starter = run.app.staticTexts["analysis.access.starter"]
                require(starter)
                let heading = diagnosis
                    ? language.text("Starter health check", "Startowa diagnoza")
                    : language.text("Starter species identification", "Startowe rozpoznanie gatunku")
                XCTAssertEqual(starter.label, heading + (exhausted ? ": 0/1" : ": 1/1"))
                if exhausted {
                    require(run.app.staticTexts["analysis.access.denied"])
                    XCTAssertFalse(run.app.buttons["photo.select.gallery"].exists)
                    XCTAssertFalse(run.app.buttons["photo.select.camera"].exists)
                } else {
                    enabled(run.app.buttons["photo.select.gallery"])
                    enabled(run.app.buttons["photo.select.camera"])
                    XCTAssertFalse(run.app.staticTexts["analysis.access.denied"].exists)
                }
                let back = run.app.buttons["analysis.navigation.back"]
                enabled(back)
                XCTAssertEqual(run.app.buttons.matching(identifier: "analysis.navigation.back").count, 1)
                XCTAssertFalse(run.app.buttons["analysis.back.button"].exists)
                enabled(run.app.buttons["analysis.catalogue.button"])
                XCTAssertLessThan(back.frame.maxY, header.frame.minY)
                back.tap()
                require(run.app.staticTexts["today.title"])
                XCTAssertFalse(run.app.buttons["care.method.scan"].exists)
            }
            tap(run, "direct-entry.verify")
            require(run.app.staticTexts["direct-entry.proof"])
            XCTAssertEqual(run.app.staticTexts["direct-entry.proof"].label, "No actions")
            if scenario == "directEntryIdentificationExhausted" {
                tap(run, "welcome.identify")
                require(run.app.staticTexts["analysis.access.denied"])
                let attachment = XCTAttachment(screenshot: run.app.screenshot())
                attachment.name = "direct-entry-" + language.rawValue
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            run.app.terminate()
        }
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
    @MainActor func testAuthUnavailableProvidersEnglishAndPolish() throws {
        for language in [Language.en, .pl] {
            let run = Run("guestProvidersUnavailable", language)
            defer { screenshot(run, "failure-or-final"); run.app.terminate() }
            openCatalogue(run)
            enterName(run, language.input)
            submit(run)
            require(run.app.staticTexts["catalogue.save.signInRequired"])
            let original = operation(run)
            assertFrozen(run, name: language.input)
            XCTAssertFalse(run.app.buttons["catalogue.save.apple"].exists)
            XCTAssertFalse(run.app.buttons["catalogue.save.google"].exists)
            require(run.app.staticTexts[language.text(
                "Sign-in is unavailable right now. Try again later, go back or edit your choices.",
                "Logowanie jest teraz niedostępne. Spróbuj później, wróć lub zmień wybrane dane.")])
            authBCopy(run)
            screenshot(run, "unavailable")
            restart(run)
            require(run.app.staticTexts["catalogue.save.signInRequired"])
            assertFrozen(run, name: language.input)
            XCTAssertEqual(operation(run), original)
            localizedText(run, "catalogue.selected.scientific", "Nephrolepis exaltata", "Nephrolepis exaltata")
            XCTAssertFalse(run.app.buttons["catalogue.save.apple"].exists)
            XCTAssertFalse(run.app.buttons["catalogue.save.google"].exists)
            try authBProof(run, ["originalOperation": authBUUID(original, "catalogue.save.operation."),
                                 "finalOperation": authBUUID(operation(run), "catalogue.save.operation.")])
            screenshot(run, "final")
        }
    }

    @MainActor func testAuthProviderFailureRetryEnglishAndPolish() throws {
        for language in [Language.en, .pl] {
            let run = Run("guestProviderFailureRetry", language)
            defer { screenshot(run, "failure-or-final"); run.app.terminate() }
            openCatalogue(run)
            enterName(run, language.input)
            submit(run)
            assertSignIn(run)
            authBCopy(run)
            let original = operation(run)
            tap(run, "catalogue.save.google")
            localizedText(run, "catalogue.save.notice", "Sign-in failed. Try again or go back.",
                          "Logowanie nie powiodło się. Spróbuj ponownie lub wróć.")
            assertSignIn(run)
            XCTAssertEqual(operation(run), original)
            localizedText(run, "catalogue.selected.scientific", "Nephrolepis exaltata", "Nephrolepis exaltata")
            screenshot(run, "provider-failed")
            tap(run, "catalogue.save.google")
            let card = assertCard(run, name: language.canonicalName)
            XCTAssertEqual(operation(run), original)
            screenshot(run, "saved")
            restart(run)
            let cold = assertCard(run, name: language.canonicalName)
            XCTAssertEqual(cold, card)
            XCTAssertEqual(operation(run), original)
            try authBProof(run, ["originalOperation": authBUUID(original, "catalogue.save.operation."),
                                 "finalOperation": authBUUID(operation(run), "catalogue.save.operation."),
                                 "savedCardId": authBUUID(card, "catalogue.saved.card."),
                                 "coldCardId": authBUUID(cold, "catalogue.saved.card."),
                                 "expectedName": language.canonicalName, "expectedSpeciesSlug": "fixture_fern"])
            screenshot(run, "final")
        }
    }

    @MainActor func testExistingAccountLoginEnglishAndPolish() throws {
        for language in [Language.en, .pl] {
            let run = Run("todaySDKOpening", language, today: true)
            defer { screenshot(run, "failure-or-final"); run.app.terminate() }
            launch(run)
            require(todayElement(run, "sdk-opening.ready"))
            todayTap(run, "collection.open")
            todayTap(run, "Fixture 1")
            let before = identity(run, "catalogue.saved.card.")
            XCTAssertEqual(run.app.staticTexts["catalogue.saved.name"].label, "Fixture 1")
            screenshot(run, "before-login")
            todayTap(run, "collection.back")
            todayTap(run, "collection.settings.open")
            todayTap(run, "account.signOut.open")
            let confirm = run.app.alerts.buttons["account.signOut.confirm"].firstMatch
            enabled(confirm)
            confirm.tap()
            require(todayElement(run, "account.signedOut"))
            todayAbsent(run, "today.root")
            todayTap(run, "collection.open")
            let email = run.app.textFields["account.email"]
            enabled(email)
            XCTAssertFalse(run.app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "collection.plant.")).firstMatch.exists)
            XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
            screenshot(run, "ordinary-login")
            email.tap()
            let fixtureEmail = "fixture@" + run.namespace.lowercased() + ".invalid"
            email.typeText(fixtureEmail)
            XCTAssertEqual(email.value as? String, fixtureEmail)
            let password = run.app.secureTextFields["account.password"]
            enabled(password)
            password.tap()
            password.typeText("fixture-only-password")
            todayTap(run, "account.signin")
            let plant = run.app.buttons["collection.plant." + authBUUID(before, "catalogue.saved.card.")]
            enabled(plant)
            require(run.app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@", "collection.plant.", "Fixture 2")).firstMatch)
            XCTAssertFalse(run.app.textFields["account.email"].exists)
            plant.tap()
            let after = identity(run, "catalogue.saved.card.")
            XCTAssertEqual(after, before)
            XCTAssertEqual(run.app.staticTexts["catalogue.saved.name"].label, "Fixture 1")
            try authBProof(run, ["beforeCardId": authBUUID(before, "catalogue.saved.card."),
                                 "afterCardId": authBUUID(after, "catalogue.saved.card.")])
            screenshot(run, "final")
        }
    }

    @MainActor
    private func authBCopy(_ run: Run) {
        require(run.app.staticTexts[run.language.text(
            "First sign-in creates your Narat account. After sign-in, we continue saving this plant with your chosen details.",
            "Pierwsze logowanie tworzy konto Narat. Po zalogowaniu kontynuujemy zapisywanie tej rośliny z wybranymi danymi.")])
    }

    private func authBUUID(_ identifier: String, _ prefix: String) -> String {
        XCTAssertTrue(identifier.hasPrefix(prefix))
        let value = String(identifier.dropFirst(prefix.count))
        XCTAssertNotNil(UUID(uuidString: value))
        return value
    }

    @MainActor
    private func authBProof(_ run: Run, _ fields: [String: String]) throws {
        var proof = fields
        proof["namespace"] = run.namespace.lowercased()
        proof["scenario"] = run.scenario
        proof["language"] = run.language.rawValue
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "auth-b-proof-" + run.scenario + "-" + run.language.rawValue
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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

    @MainActor func testPolishCollectionShowsRecordedConditionsAfterRestart() {
        let run = Run("plantLightEdit", .pl)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "Moje rośliny")
        tap(run, "Fixture 1")
        let card = identity(run, "catalogue.saved.card.")
        assertPolishConditions(run)
        require(run.app.images["catalogue.saved.photo"])

        restart(run)
        tap(run, "collection.open", "Moje rośliny")
        tap(run, "Fixture 1")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), card)
        assertPolishConditions(run)
        require(run.app.images["catalogue.saved.photo"])
    }

    @MainActor
    private func assertPolishConditions(_ run: Run, light: String = "Umiarkowane światło") {
        let values = [
            ("light", "Światło: " + light),
            ("watering", "Częstotliwość podlewania: Umiarkowane podlewanie"),
            ("drainage", "Drenaż: Otwory odpływowe")
        ]
        for (field, label) in values {
            let value = run.app.staticTexts["catalogue.saved.conditions." + field]
            require(value)
            XCTAssertEqual(value.label, label)
        }
        for edit in ["rename", "light", "watering.frequency", "drainage", "pot.type", "species"] {
            XCTAssertFalse(run.app.buttons["collection." + edit + ".open"].exists)
        }
    }

    @MainActor func testPolishCatalogueWithoutConditionsDoesNotInventValues() {
        let run = Run("free2", .pl)
        defer { run.app.terminate() }
        openCatalogue(run)
        enterName(run, run.language.input)
        submit(run)
        let saved = assertCard(run, name: run.language.canonicalName)
        assertNoRecordedConditions(run)
        restart(run)
        tap(run, "collection.open", "Moje rośliny")
        let plantId = saved.dropFirst("catalogue.saved.card.".count)
        tap(run, "collection.plant." + plantId, run.language.canonicalName)
        XCTAssertEqual(identity(run, "catalogue.saved.card."), saved)
        assertNoRecordedConditions(run)
    }

    @MainActor
    private func assertNoRecordedConditions(_ run: Run) {
        let values = run.app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.conditions.")
        )
        let invented = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"), object: values
        )
        invented.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [invented], timeout: 1), .completed)
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

    @MainActor func testDeletedCatalogueSaveDoesNotResumeAfterRestart() {
        let run = Run("plantDeletion", .en)
        defer { run.app.terminate() }
        openCatalogue(run)
        enterName(run, run.language.input)
        submit(run)
        let saved = assertCard(run, name: run.language.canonicalName)
        tap(run, "collection.open", "My plants")
        let plantId = saved.dropFirst("catalogue.saved.card.".count)
        tap(run, "collection.plant." + plantId, run.language.canonicalName)
        let delete = run.app.buttons["collection.delete"]
        require(delete)
        if !delete.isHittable { run.app.swipeUp() }
        delete.tap()
        let alert = run.app.alerts["Delete this plant?"]
        require(alert)
        alert.buttons["collection.delete.confirm"].firstMatch.tap()
        require(run.app.staticTexts["collection.delete.pending"])
        tap(run, "collection.delete.retry")
        enabled(run.app.buttons["Fixture 2"])
        tap(run, "collection.back", "Close")
        enabled(run.app.textFields["catalogue.save.name"])
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
        restart(run)
        tap(run, "welcome.intent.care", "Set up care and schedule")
        tap(run, "care.method.catalogue", "Choose species from catalogue (no photo)")
        chooseSpecies(run)
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

    @MainActor func testCollectionShowsPlantsBeforeAccountSettingsEnglish() {
        verifyCollectionSettings(.en)
    }

    @MainActor func testCollectionShowsPlantsBeforeAccountSettingsPolish() {
        verifyCollectionSettings(.pl)
    }

    @MainActor
    private func verifyCollectionSettings(_ language: Language) {
        let run = Run("plantDeletion", language)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", language.text("My plants", "Moje rośliny"))
        let plant = run.app.buttons["Fixture 1"]
        enabled(plant)
        XCTAssertFalse(run.app.pickers["profile.hour.picker"].exists)
        XCTAssertFalse(run.app.staticTexts["profile.hour.synced"].exists)
        tap(run, "collection.settings.open", language.text("Account settings", "Ustawienia konta"))
        // The saved-plant fixture has no profile endpoint. The separate profile
        // fixture covers a successful load, edit and relaunch.
        require(run.app.staticTexts["profile.hour.failed"])
        tap(run, "collection.settings.close", language.text("Close", "Zamknij"))
        enabled(plant)
        XCTAssertFalse(run.app.pickers["profile.hour.picker"].exists)
        plant.tap()
        require(run.app.staticTexts["catalogue.saved.name"])
        XCTAssertFalse(run.app.buttons["collection.settings.open"].exists)
        tap(run, "collection.back", language.text("Back", "Wstecz"))
        enabled(plant)
        enabled(run.app.buttons["collection.settings.open"])
    }

    @MainActor func testAccountSignOutCancelConfirmAndRestart() {
        for language in [Language.en, .pl] {
            let run = Run("accountSignOut", language)
            defer { run.app.terminate() }
            launch(run)
            tap(run, "collection.open", language.text("My plants", "Moje rośliny"))
            enabled(run.app.buttons["Fixture 1"])
            tap(run, "collection.settings.open", language.text("Account settings", "Ustawienia konta"))
            tap(run, "account.signOut.open", language.text("Sign out", "Wyloguj się"))
            let confirmation = run.app.alerts[language.text("Sign out?", "Wylogować się?")]
            require(confirmation)
            // SwiftUI exposes the alert action as nested buttons with the same ID.
            let cancel = confirmation.buttons["account.signOut.cancel"].firstMatch
            enabled(cancel)
            XCTAssertEqual(cancel.label, language.text("Cancel", "Anuluj"))
            cancel.tap()
            enabled(run.app.buttons["account.signOut.open"])
            XCTAssertFalse(run.app.staticTexts["account.signedOut"].exists)
            tap(run, "collection.settings.close", language.text("Close", "Zamknij"))
            tap(run, "Fixture 1")
            require(run.app.staticTexts["catalogue.saved.name"])
            tap(run, "collection.back", language.text("Back", "Wstecz"))
            tap(run, "collection.settings.open", language.text("Account settings", "Ustawienia konta"))
            tap(run, "account.signOut.open", language.text("Sign out", "Wyloguj się"))
            require(confirmation)
            let confirm = confirmation.buttons["account.signOut.confirm"].firstMatch
            enabled(confirm)
            XCTAssertEqual(confirm.label, language.text("Sign out", "Wyloguj się"))
            confirm.tap()
            for restartNeeded in [false, true] {
                if restartNeeded { restart(run) }
                let loggedOut = run.app.staticTexts["account.signedOut"]
                require(loggedOut)
                XCTAssertEqual(loggedOut.label, language.text("You’re signed out on this device.", "Wylogowano na tym urządzeniu."))
                XCTAssertFalse(run.app.buttons["account.signOut.open"].exists)
                XCTAssertFalse(run.app.buttons["collection.settings.close"].exists)
                XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
                enabled(run.app.buttons["welcome.intent.care"])
                // Fixture uses legacy welcome with ordinary collection/settings.
                tap(run, "collection.open", language.text("My plants", "Moje rośliny"))
                require(run.app.staticTexts["collection.signInRequired"])
                XCTAssertFalse(run.app.buttons["Fixture 1"].exists)
                XCTAssertFalse(run.app.buttons["collection.settings.open"].exists)
                tap(run, "collection.back", language.text("Close", "Zamknij"))
            }
        }
    }

    @MainActor func testProfileReminderHourSurvivesRestart() {
        let run = Run("profileReminderHour", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "collection.settings.open", "Account settings")
        let synced = run.app.staticTexts["profile.hour.synced"]
        require(synced)
        XCTAssertEqual(synced.label, "09:00")
        let picker = run.app.pickerWheels.firstMatch
        enabled(picker)
        picker.adjust(toPickerWheelValue: "23:00")
        tap(run, "profile.hour.save", "Save")
        let pending = run.app.staticTexts["profile.hour.pending"]
        require(pending)
        XCTAssertEqual(pending.label, "Pending: 23:00")
        enabled(run.app.buttons["profile.hour.retry"])
        XCTAssertFalse(synced.exists)
        XCTAssertFalse(run.app.buttons["profile.hour.save"].exists)

        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "collection.settings.open", "Account settings")
        require(pending)
        XCTAssertEqual(pending.label, "Pending: 23:00")
        XCTAssertFalse(synced.exists)
        XCTAssertFalse(run.app.buttons["profile.hour.save"].exists)
        // The fixture confirms only attempt two of the identical persisted envelope/body.
        tap(run, "profile.hour.retry", "Try again")
        require(synced)
        XCTAssertEqual(synced.label, "23:00")
        XCTAssertFalse(pending.exists)
        XCTAssertFalse(run.app.buttons["profile.hour.retry"].exists)
        XCTAssertFalse(run.app.buttons["profile.hour.save"].isEnabled)

        tap(run, "collection.settings.close", "Close")
        tap(run, "collection.back", "Close")
        tap(run, "collection.open", "My plants")
        tap(run, "collection.settings.open", "Account settings")
        require(synced)
        XCTAssertEqual(synced.label, "23:00")
        XCTAssertFalse(pending.exists)
        // Reopening reads /me, whose fixture rejects duplicate or nonidentical attempts.
        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "collection.settings.open", "Account settings")
        require(synced)
        XCTAssertEqual(synced.label, "23:00")
        XCTAssertFalse(pending.exists)
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

    @MainActor func testPrivatePhotoHistoryReopensWithDatesAfterAccessExpiry() {
        let run = Run("photoHistory", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(run.app.images["catalogue.saved.photo"])

        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let observations = [
            ("12340000-0000-4000-8000-000000000002", "Improved", "Oct 30, 2026"),
            ("12340000-0000-4000-8000-000000000001", "Unchanged", "Oct 29, 2026")
        ]
        for (id, status, day) in observations {
            let row = run.app.staticTexts["catalogue.saved.firstAid.observation." + id]
            let date = run.app.staticTexts["catalogue.saved.firstAid.observation.date." + id]
            let photo = run.app.images["catalogue.saved.firstAid.photo." + id]
            require(row)
            require(date)
            require(photo)
            XCTAssertEqual(row.label, "Observation · " + status)
            XCTAssertEqual(date.label, day)
        }
        let latest = run.app.staticTexts["catalogue.saved.firstAid.observation.date." + observations[0].0]
        let previous = run.app.staticTexts["catalogue.saved.firstAid.observation.date." + observations[1].0]
        XCTAssertLessThan(latest.frame.minY, previous.frame.minY)
        require(run.app.images["catalogue.saved.photo"])

        tap(run, "collection.back", "Back")
        tap(run, "Fixture 2")
        require(run.app.staticTexts["catalogue.saved.name"])
        XCTAssertFalse(run.app.images["catalogue.saved.photo"].exists)
        for (id, _, _) in observations {
            XCTAssertFalse(run.app.images["catalogue.saved.firstAid.photo." + id].exists)
        }
    }

    @MainActor func testAnalysisHistoryMarksOnlyPreviousConditionsAfterRestart() {
        let run = Run("analysisHistory", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(run.app.staticTexts["Analysis history"])

        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let olderId = "12340000-0000-4000-8000-000000000001"
        let currentId = "12340000-0000-4000-8000-000000000002"
        let older = run.app.otherElements["collection.analysis.history." + olderId]
        let current = run.app.otherElements["collection.analysis.history." + currentId]
        require(older.staticTexts["Species identification"])
        require(older.staticTexts["Oct 29, 2026"])
        require(older.staticTexts["collection.analysis.previous." + olderId])
        require(current.staticTexts["Diagnosis"])
        require(current.staticTexts["Oct 30, 2026"])
        XCTAssertFalse(current.staticTexts["collection.analysis.previous." + currentId].exists)
        XCTAssertLessThan(current.frame.minY, older.frame.minY)

        tap(run, "collection.back", "Back")
        tap(run, "Fixture 2")
        require(run.app.staticTexts["catalogue.saved.name"])
        XCTAssertFalse(older.exists)
        XCTAssertFalse(current.exists)
    }

    @MainActor func testPlantRenameReplaysAfterRestartAndKeepsPhotoAndAnalysis() {
        let run = Run("plantRename", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        require(run.app.images["catalogue.saved.photo"])
        tap(run, "collection.rename.open", "Edit name")
        let alert = run.app.alerts["Edit plant name"].firstMatch
        require(alert)
        let input = alert.textFields.firstMatch
        enabled(input)
        XCTAssertEqual(input.value as? String, "Fixture 1")
        input.tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Fixture 1".count))
        let save = run.app.buttons.matching(identifier: "collection.rename.save").firstMatch
        XCTAssertFalse(save.isEnabled)
        input.typeText("  North window fern  ")
        save.tap()
        require(run.app.staticTexts["collection.rename.pending"])
        XCTAssertEqual(run.app.staticTexts["catalogue.saved.name"].label, "Fixture 1")

        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "North window fern")
        require(run.app.staticTexts["collection.rename.pending"])
        tap(run, "collection.rename.retry", "Retry name change")
        enabled(run.app.buttons["collection.rename.open"])
        XCTAssertFalse(run.app.staticTexts["collection.rename.pending"].exists)
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        require(run.app.images["catalogue.saved.photo"])
        require(run.app.staticTexts["collection.analysis.previous.12340000-0000-4000-8000-000000000001"])
        require(run.app.staticTexts["Diagnosis"])

        tap(run, "collection.back", "Back")
        enabled(run.app.buttons["North window fern"])
        enabled(run.app.buttons["Fixture 2"])
    }

    @MainActor func testPlantRenameReopensRejectedInputAndSendsCorrectedName() {
        let run = Run("plantRenameRejected", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        tap(run, "collection.rename.open", "Edit name")
        let alert = run.app.alerts["Edit plant name"].firstMatch
        let input = alert.textFields.firstMatch
        let save = run.app.buttons.matching(identifier: "collection.rename.save").firstMatch
        enabled(input)
        input.tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Fixture 1".count))
        let rejected = "  North window fern  "
        input.typeText(rejected)
        save.tap()
        require(run.app.staticTexts["collection.rename.failed"])
        XCTAssertEqual(run.app.staticTexts["catalogue.saved.name"].label, "Fixture 1")
        XCTAssertFalse(run.app.staticTexts["collection.rename.pending"].exists)

        tap(run, "collection.rename.open", "Edit name")
        enabled(input)
        XCTAssertEqual(input.value as? String, rejected)
        input.tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: rejected.count))
        input.typeText("Window fern")
        save.tap()
        let name = run.app.staticTexts["catalogue.saved.name"]
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Window fern"), object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 15), .completed)
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        XCTAssertFalse(run.app.staticTexts["collection.rename.failed"].exists)
        XCTAssertFalse(run.app.staticTexts["collection.rename.pending"].exists)
    }

    @MainActor func testBasicCareEnableReplaysWithoutRecordingWatering() {
        let run = Run("basicCareEnable", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        tap(run, "collection.care.enable", "Enable basic care")
        let pending = run.app.staticTexts["collection.care.enable.pending"]
        require(pending)
        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        // Foreground Root reconciliation completes the exact persisted enable, without card Retry.
        enabled(run.app.buttons["collection.care.refresh"])
        XCTAssertFalse(pending.exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.care.next.date"].exists)
        XCTAssertEqual(run.app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.history.")
        ).count, 0)
    }

    @MainActor func testCareRecommendationRefreshReplaysAfterRestart() {
        let run = Run("careRecommendationRefresh", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        let nextCheck = run.app.staticTexts["catalogue.saved.care.next.date"]
        XCTAssertFalse(nextCheck.exists)
        tap(run, "collection.care.refresh", "Update care recommendation")
        require(run.app.staticTexts["collection.care.refresh.pending"])
        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        // The fixture accepts only the original frozen command; Root replays it while closed.
        require(nextCheck)
        XCTAssertEqual(nextCheck.label, "Next soil check · 2026-10-28")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        XCTAssertFalse(run.app.staticTexts["collection.care.refresh.pending"].exists)
        // Remain on this card: the source changes remotely with an empty owner delta
        // and identical watermark, as asserted by the fixture server before returning nil advice.
        wateringTap(run, "collection.care.fixture.withdraw")
        // Background cancels the card's active read tasks. Foreground must still
        // revalidate the withdrawn source without a careRevision change.
        XCUIDevice.shared.press(.home)
        run.app.activate()
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        let source = run.app.links["catalogue.saved.care.source"]
        let text = run.app.staticTexts["catalogue.saved.care.text"]
        let gone = [nextCheck, source, text].map {
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: $0)
        }
        XCTAssertEqual(XCTWaiter.wait(for: gone, timeout: 15), .completed)
        XCTAssertFalse(run.app.buttons["collection.routine.complete"].exists)
        XCTAssertFalse(run.app.buttons["Retry care details"].exists)
    }

    @MainActor func testRoutineSoilCheckUndoAfterRestart() {
        let run = Run("routineSoilCheckUndo", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        tap(run, "collection.routine.complete", "Mark soil checked")
        require(run.app.staticTexts["collection.routine.confirmed"])
        let entry = "19190000-0000-4000-8000-000000000003"
        let row = run.app.staticTexts["collection.routine.history." + entry]
        require(row)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let localDate = formatter.string(from: Date())
        XCTAssertEqual(row.label, localDate + " · Active")
        let next = run.app.staticTexts["catalogue.saved.care.next.date"]
        require(next)
        XCTAssertNotEqual(next.label, "Next soil check · 2000-01-01")
        let undo = "collection.routine.undo." + entry
        tap(run, undo, "Undo soil check")
        let undoDialog = run.app.alerts["Undo this soil check?"]
        require(undoDialog)
        let cancelUndo = undoDialog.buttons.matching(identifier: "Cancel").firstMatch
        enabled(cancelUndo)
        cancelUndo.tap()
        XCTAssertEqual(row.label, localDate + " · Active")
        XCTAssertFalse(run.app.staticTexts["collection.routine.undo.pending"].exists)
        tap(run, undo, "Undo soil check")
        require(undoDialog)
        let confirmUndo = undoDialog.buttons.matching(identifier: "Undo soil check").firstMatch
        enabled(confirmUndo)
        confirmUndo.tap()
        let pending = run.app.staticTexts["collection.routine.undo.pending"]
        require(pending)
        XCTAssertFalse(run.app.staticTexts["collection.routine.undo.confirmed"].exists)
        XCTAssertFalse(next.exists)
        XCTAssertEqual(row.label, localDate + " · Active")
        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        require(row)
        // Root foreground replay must satisfy the exact body guard and publish canonical voided state.
        let voided = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", localDate + " · Undone"), object: row
        )
        XCTAssertEqual(XCTWaiter.wait(for: [voided], timeout: 15), .completed)
        require(next)
        XCTAssertEqual(next.label, "Next soil check · 2000-01-01")
        XCTAssertFalse(pending.exists)
        XCTAssertFalse(run.app.buttons[undo].exists)
        XCTAssertFalse(run.app.buttons["collection.routine.undo.retry"].exists)
        XCTAssertEqual(run.app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "collection.routine.history.")
        ).count, 1)
        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(row)
        XCTAssertEqual(row.label, localDate + " · Undone")
        require(next)
        XCTAssertEqual(next.label, "Next soil check · 2000-01-01")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        XCTAssertFalse(pending.exists)
        XCTAssertFalse(run.app.buttons[undo].exists)
    }

    @MainActor func testRoutineLateEntitlementUsesRealDeadline() {
        let run = Run("routineLateEntitlement", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        let date = run.app.staticTexts["catalogue.saved.care.next.date"]
        let action = run.app.buttons["collection.routine.complete"]
        // The initial card has nil entitlement and no scheduled check, so refresh is offered.
        let refresh = run.app.buttons["collection.care.refresh"]
        enabled(refresh)
        XCTAssertFalse(date.exists)
        XCTAssertFalse(action.exists)
        let entry = "19190000-0000-4000-8000-000000000005"
        let journal = run.app.staticTexts["catalogue.saved.history." + entry]
        require(journal)
        let started = Date()
        // This real command delivers the first paid entitlement through canonical sync.
        XCTAssertEqual(refresh.label, "Update care recommendation")
        refresh.tap()
        enabled(action)
        require(date)
        XCTAssertEqual(date.label, "Next soil check · 2000-01-01")
        XCTAssertFalse(run.app.staticTexts["collection.care.refresh.pending"].exists)

        // No refresh, artificial clock, backgrounding or navigation until both disappear.
        let dateGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: date)
        let actionGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: action)
        XCTAssertEqual(XCTWaiter.wait(for: [dateGone, actionGone], timeout: 10), .completed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        require(journal)
        require(run.app.buttons["collection.watering.correct." + entry])
        require(run.app.buttons["collection.watering.undo." + entry])
        XCTAssertFalse(run.app.staticTexts["collection.routine.pending"].exists)

        tap(run, "collection.back", "Back")
        tap(run, "Fixture 1")
        require(journal)
        XCTAssertFalse(date.exists)
        XCTAssertFalse(action.exists)
        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(journal)
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        XCTAssertFalse(date.exists)
        XCTAssertFalse(action.exists)
        require(run.app.buttons["collection.watering.correct." + entry])
        require(run.app.buttons["collection.watering.undo." + entry])
    }

    @MainActor func testRoutineKnownExpiryHidesDateAndNewCompletionAfterRestart() {
        let run = Run("routineKnownExpiry", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        let date = run.app.staticTexts["catalogue.saved.care.next.date"]
        let action = run.app.buttons["collection.routine.complete"]
        require(date)
        XCTAssertEqual(date.label, "Next soil check · 2000-01-01")
        enabled(action)
        let entry = "19190000-0000-4000-8000-000000000005"
        let journal = run.app.staticTexts["catalogue.saved.history." + entry]
        require(journal)

        // Cross the canonical deadline on the open card without sleeping.
        tap(run, "collection.routine.fixture.expire", "Advance entitlement clock")
        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: date
        )
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 5), .completed)
        XCTAssertFalse(action.exists)
        XCTAssertFalse(run.app.staticTexts["collection.routine.pending"].exists)
        require(journal)
        require(run.app.buttons["collection.watering.correct." + entry])
        require(run.app.buttons["collection.watering.undo." + entry])

        XCUIDevice.shared.press(.home)
        run.app.activate()
        require(journal)
        XCTAssertFalse(date.exists)
        XCTAssertFalse(action.exists)
        tap(run, "collection.back", "Back")
        tap(run, "Fixture 1")
        require(journal)
        XCTAssertFalse(date.exists)
        XCTAssertFalse(action.exists)

        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(journal)
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        XCTAssertFalse(date.exists)
        XCTAssertFalse(action.exists)
        XCTAssertFalse(run.app.staticTexts["collection.routine.pending"].exists)
        require(run.app.buttons["collection.watering.correct." + entry])
        require(run.app.buttons["collection.watering.undo." + entry])
    }

    @MainActor func testPolishRecommendationHidesExistingPendingSoilCheck() {
        let run = Run("routinePendingPolish", .en)
        defer { screenshot(run, "polish-existing-pending"); run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        let date = run.app.staticTexts["catalogue.saved.care.next.date"]
        let text = run.app.staticTexts["catalogue.saved.care.text"]
        let source = run.app.descendants(matching: .any).matching(identifier: "catalogue.saved.care.source").firstMatch
        require(text)
        require(source)
        require(date)
        XCTAssertEqual(date.label, "Next soil check · 2000-01-01")
        XCTAssertEqual(text.label, "Check the soil before watering.")

        tap(run, "collection.routine.complete", "Mark soil checked")
        require(run.app.staticTexts["collection.routine.pending"])
        XCTAssertFalse(run.app.staticTexts["collection.routine.confirmed"].exists)
        XCTAssertFalse(date.exists)
        tap(run, "collection.back", "Back")
        tap(run, "collection.back", "Close")

        // Keep the real Root locale lifecycle: only its bounded pass may replay.
        // The fixture gates the PL recommendation on 2...4 identical attempts,
        // one operation and one completed canonical commit, without a receipt.
        selectLanguage(run, .pl)
        tap(run, "collection.open", "Moje rośliny")
        tap(run, "Fixture 1")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        require(text)
        require(source)
        XCTAssertEqual(text.label, "Check the soil before watering.")
        XCTAssertFalse(date.exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.care.next.basis"].exists)
        XCTAssertFalse(run.app.descendants(matching: .any).matching(identifier: "catalogue.saved.care.next.source").firstMatch.exists)
        for prefix in ["collection.routine.", "collection.watering.", "collection.firstAid.",
                       "collection.care.enable", "collection.care.refresh"] {
            XCTAssertEqual(run.app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", prefix)
            ).count, 0, prefix)
        }
    }

    @MainActor func testRoutineSoilCheckCompletesAfterRestart() {
        let run = Run("routineSoilCheck", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        let action = run.app.buttons["collection.routine.complete"]
        enabled(action)
        XCTAssertEqual(run.app.buttons.matching(identifier: "collection.routine.complete").count, 1)
        tap(run, "collection.routine.complete", "Mark soil checked")
        let pending = run.app.staticTexts["collection.routine.pending"]
        require(pending)
        XCTAssertFalse(action.exists)
        XCTAssertFalse(run.app.staticTexts["collection.routine.confirmed"].exists)
        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        // No card Retry: exact persisted completion is replayed by the foreground Root pass.
        let row = run.app.staticTexts["collection.routine.history.19190000-0000-4000-8000-000000000003"]
        require(row)
        XCTAssertTrue(row.label.hasSuffix(" · Active"))
        XCTAssertEqual(run.app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "collection.routine.history.")
        ).count, 1)
        let next = run.app.staticTexts["catalogue.saved.care.next.date"]
        require(next)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let expectedDate = formatter.string(from: calendar.date(byAdding: .day, value: 7, to: Date())!)
        XCTAssertEqual(next.label, "Next soil check · " + expectedDate)
        XCTAssertFalse(pending.exists)
        XCTAssertFalse(action.exists)
        XCTAssertFalse(run.app.buttons["collection.routine.retry"].exists)
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        XCTAssertEqual(run.app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.history.")).count, 0)
        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(next)
        XCTAssertEqual(next.label, "Next soil check · " + expectedDate)
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        XCTAssertFalse(action.exists)
        XCTAssertFalse(pending.exists)
    }

    @MainActor func testCollectionRecordsWateringAfterRestart() {
        let run = Run("collectionWateringRecord", .en)
        defer { screenshot(run, "final"); run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        require(run.app.staticTexts["collection.cached"])
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        require(run.app.buttons["Retry care details"]) // Advice GET fails; this must not gate the local write.
        XCTAssertFalse(run.app.staticTexts["catalogue.save.saved"].exists)
        XCTAssertFalse(run.app.buttons["collection.routine.complete"].exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.care.next.date"].exists)
        wateringTap(run, "collection.watering.record")
        wateringAlertTap(run, title: "Record watering now?", identifier: "collection.watering.record.confirm",
                         label: "Confirm watering", doubleTap: true)
        let pending = run.app.staticTexts["collection.watering.record.pending"]
        require(pending)
        let operation = pending.value as? String ?? ""
        XCTAssertNotNil(UUID(uuidString: operation))
        XCTAssertFalse(run.app.buttons["collection.watering.record"].isEnabled)
        XCTAssertFalse(run.app.staticTexts["collection.watering.record.confirmed"].exists)
        XCTAssertEqual(run.app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.history.")
        ).count, 0)

        restart(run)
        tap(run, "collection.open", "My plants")
        require(run.app.staticTexts["collection.cached"])
        tap(run, "Fixture 1")
        require(pending)
        XCTAssertEqual(pending.value as? String, operation)
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        XCTAssertFalse(run.app.buttons["collection.watering.record"].isEnabled)
        XCTAssertFalse(run.app.staticTexts["collection.watering.record.confirmed"].exists)
        // Keep the actual Root lifecycle active with the card/collection closed.
        // The fixture stays offline until this explicit reconnect, never a launch count.
        tap(run, "collection.back", "Back")
        tap(run, "collection.back", "Close")
        wateringTap(run, "care.fixture.reconnect")
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let journal = run.app.staticTexts["catalogue.saved.history." + operation]
        require(journal) // Canonical linkage, not pass.completed or queue disappearance.
        let acknowledged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: pending
        )
        XCTAssertEqual(XCTWaiter.wait(for: [acknowledged], timeout: 15), .completed)
        XCTAssertTrue(journal.label.hasSuffix(" · Active"))
        XCTAssertEqual(run.app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.history.")
        ).count, 1)
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        // No profile or published rule: recording a fact must not invent a next check.
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.care.next.date"].exists)
        require(run.app.buttons["Retry care details"])
        wateringTap(run, "collection.watering.correct." + operation)
        require(run.app.descendants(matching: .any).matching(identifier: "collection.watering.date").firstMatch)
        tap(run, "Cancel")
        wateringTap(run, "collection.watering.undo." + operation)
        wateringAlertTap(run, title: "Undo this watering?", identifier: "collection.watering.undo.confirm",
                         label: "Undo watering")
        let undone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label ENDSWITH %@", " · Undone"), object: journal
        )
        XCTAssertEqual(XCTWaiter.wait(for: [undone], timeout: 15), .completed)
        XCTAssertEqual(run.app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.history.")
        ).count, 1)
        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(journal)
        XCTAssertTrue(journal.label.hasSuffix(" · Undone"))
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
    }

    @MainActor func testManualWateringWithMissingCachedConditionStillRecords() {
        let run = Run("collectionWateringMissingConditions", .en)
        defer { screenshot(run, "final"); run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        require(run.app.staticTexts["collection.cached"])
        tap(run, "Fixture 1")
        require(run.app.buttons["Retry care details"])
        require(run.app.staticTexts["collection.details.unavailable"])
        XCTAssertFalse(run.app.staticTexts["Couldn’t save the plant edit."].exists)
        wateringTap(run, "collection.watering.record")
        wateringAlertTap(run, title: "Record watering now?", identifier: "collection.watering.record.confirm",
                         label: "Confirm watering")
        let pending = run.app.staticTexts["collection.watering.record.pending"]
        require(pending)
        let operation = pending.value as? String ?? ""
        XCTAssertNotNil(UUID(uuidString: operation))
        XCTAssertFalse(run.app.staticTexts["collection.watering.record.confirmed"].exists)
        tap(run, "collection.back", "Back")
        tap(run, "collection.back", "Close")
        wateringTap(run, "care.fixture.reconnect")
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(run.app.staticTexts["catalogue.saved.history." + operation])
        let acknowledged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: pending
        )
        XCTAssertEqual(XCTWaiter.wait(for: [acknowledged], timeout: 15), .completed)
        XCTAssertEqual(run.app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.history.")
        ).count, 1)
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.care.next.date"].exists)
    }

    @MainActor func testBackgroundWateringFailureSurvivesColdLaunchUntilExplicitRetry() {
        let run = Run("collectionWateringBackgroundFailure", .en)
        defer { screenshot(run, "final"); run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        require(run.app.staticTexts["collection.cached"])
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        wateringTap(run, "collection.watering.record")
        wateringAlertTap(run, title: "Record watering now?", identifier: "collection.watering.record.confirm",
                         label: "Confirm watering")
        let pending = run.app.staticTexts["collection.watering.record.pending"]
        require(pending)
        let original = pending.value as? String ?? ""
        XCTAssertNotNil(UUID(uuidString: original))
        // Keep this card alive while Root handles a real foreground lifecycle request.
        XCUIDevice.shared.press(.home)
        run.app.activate()
        let failed = run.app.staticTexts["collection.watering.record.failed"]
        require(failed)
        XCTAssertEqual(failed.value as? String, original)
        XCTAssertFalse(pending.exists)
        XCTAssertFalse(run.app.buttons["collection.watering.record"].isEnabled)
        XCTAssertFalse(run.app.staticTexts["collection.watering.record.confirmed"].exists)
        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(failed)
        XCTAssertEqual(failed.value as? String, original)
        XCTAssertFalse(pending.exists)
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        XCUIDevice.shared.press(.home)
        run.app.activate()
        require(failed)
        XCTAssertEqual(failed.value as? String, original)
        wateringTap(run, "collection.watering.record.retry")
        let rejected = run.app.staticTexts["collection.watering.record.rejected"]
        require(rejected)
        XCTAssertEqual(rejected.value as? String, original)
        XCTAssertFalse(pending.exists)
        XCTAssertFalse(run.app.staticTexts["collection.watering.record.confirmed"].exists)
        XCTAssertEqual(run.app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.history.")
        ).count, 0)
        wateringTap(run, "collection.watering.record")
        wateringAlertTap(run, title: "Record watering now?", identifier: "collection.watering.record.confirm",
                         label: "Confirm watering")
        require(run.app.staticTexts["collection.watering.record.confirmed"])
        let journalId = identity(run, "catalogue.saved.history.")
        let newOperation = String(journalId.dropFirst("catalogue.saved.history.".count))
        XCTAssertNotEqual(newOperation, original)
        XCTAssertNotNil(UUID(uuidString: newOperation))
        XCTAssertEqual(run.app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.history.")
        ).count, 1)
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.history." + original].exists)
        XCTAssertFalse(pending.exists)
    }

    @MainActor func testCollectionWateringRejectionDoesNotShowSuccess() {
        let run = Run("collectionWateringRecordRejected", .en)
        defer { screenshot(run, "final"); run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        require(run.app.staticTexts["collection.cached"])
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        wateringTap(run, "collection.watering.record")
        wateringAlertTap(run, title: "Record watering now?", identifier: "collection.watering.record.confirm",
                         label: "Confirm watering")
        let rejected = run.app.staticTexts["collection.watering.record.rejected"]
        require(rejected)
        let firstOperation = rejected.value as? String ?? ""
        XCTAssertNotNil(UUID(uuidString: firstOperation))
        XCTAssertFalse(run.app.staticTexts["collection.watering.record.pending"].exists)
        XCTAssertFalse(run.app.staticTexts["collection.watering.record.confirmed"].exists)
        XCTAssertFalse(run.app.buttons["collection.watering.record.retry"].exists)
        wateringTap(run, "collection.watering.record")
        wateringAlertTap(run, title: "Record watering now?", identifier: "collection.watering.record.confirm",
                         label: "Confirm watering")
        let fresh = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value != %@", firstOperation), object: rejected
        )
        XCTAssertEqual(XCTWaiter.wait(for: [fresh], timeout: 15), .completed)
        XCTAssertNotNil(UUID(uuidString: rejected.value as? String ?? ""))
        XCTAssertFalse(run.app.staticTexts["collection.watering.record.pending"].exists)
        XCTAssertFalse(run.app.staticTexts["collection.watering.record.confirmed"].exists)
        XCTAssertEqual(run.app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.history.")
        ).count, 0)
        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(run.app.staticTexts["No manual watering recorded."])
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        XCTAssertFalse(run.app.staticTexts["collection.watering.record.pending"].exists)
        XCTAssertFalse(run.app.staticTexts["collection.watering.record.confirmed"].exists)
        XCTAssertEqual(run.app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.history.")
        ).count, 0)
    }

    @MainActor
    private func wateringAlertTap(
        _ run: Run, title: String, identifier: String, label: String, doubleTap: Bool = false
    ) {
        // SwiftUI alerts expose nested button wrappers with the same identifier on iOS 26.
        let button = run.app.alerts[title].buttons.matching(identifier: identifier).firstMatch
        enabled(button)
        XCTAssertEqual(button.label, label)
        if doubleTap { button.doubleTap() } else { button.tap() }
    }

    @MainActor
    private func wateringTap(_ run: Run, _ identifier: String) {
        let button = run.app.buttons[identifier]
        require(button)
        for _ in 0..<6 {
            if button.isHittable { break }
            run.app.swipeUp()
        }
        enabled(button)
        button.tap()
    }

    @MainActor func testCareRecommendationRefreshRejectionShowsFailure() {
        let run = Run("careRecommendationRefreshRejected", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        let nextCheck = run.app.staticTexts["catalogue.saved.care.next.date"]
        XCTAssertFalse(nextCheck.exists)
        tap(run, "collection.care.refresh", "Update care recommendation")
        require(run.app.staticTexts["Couldn’t update the care recommendation."])
        enabled(run.app.buttons["collection.care.refresh"])
        XCTAssertFalse(run.app.staticTexts["collection.care.refresh.pending"].exists)
        XCTAssertFalse(run.app.buttons["collection.care.refresh.retry"].exists)
        XCTAssertFalse(run.app.staticTexts["No next soil check is available yet."].exists)
        XCTAssertFalse(nextCheck.exists)
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
    }

    @MainActor func testPlantLightEditReplaysAndMarksEarlierDiagnosis() {
        let run = Run("plantLightEdit", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        let light = run.app.staticTexts["collection.light.current"]
        let previous = run.app.staticTexts["collection.analysis.previous.12340000-0000-4000-8000-000000000002"]
        require(run.app.staticTexts["Diagnosis"])
        XCTAssertFalse(previous.exists)
        require(light)
        XCTAssertEqual(light.label, "Medium light")
        tap(run, "collection.light.open", "Edit light")
        let direct = run.app.buttons.matching(identifier: "collection.light.direct_sun").firstMatch
        enabled(direct)
        direct.tap()
        require(run.app.staticTexts["collection.rename.pending"])
        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(run.app.staticTexts["collection.rename.pending"])
        tap(run, "collection.rename.retry", "Retry light change")
        require(light)
        XCTAssertEqual(light.label, "Direct sunlight")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        require(run.app.images["catalogue.saved.photo"])
        require(previous)

        // Reopen the same persisted owner-bound snapshot in Polish after the EN edit.
        run.app.terminate()
        run.app.launch()
        selectLanguage(run, .pl)
        tap(run, "collection.open", "Moje rośliny")
        tap(run, "Fixture 1")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        assertPolishConditions(run, light: "Bezpośrednie słońce")
        require(run.app.images["catalogue.saved.photo"])
    }

    @MainActor func testPlantDrainageEditReplaysAndKeepsLightAndHistory() {
        let run = Run("plantDrainageEdit", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        let drainage = run.app.staticTexts["collection.drainage.current"]
        let light = run.app.staticTexts["collection.light.current"]
        let previous = run.app.staticTexts["collection.analysis.previous.12340000-0000-4000-8000-000000000002"]
        require(drainage)
        XCTAssertEqual(drainage.label, "Drainage holes")
        require(run.app.staticTexts["Diagnosis"])
        XCTAssertFalse(previous.exists)
        tap(run, "collection.drainage.open", "Edit drainage")
        let noDrainage = run.app.buttons.matching(identifier: "No drainage holes").firstMatch
        enabled(noDrainage)
        noDrainage.tap()
        require(run.app.staticTexts["collection.rename.pending"])

        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(run.app.staticTexts["collection.rename.pending"])
        tap(run, "collection.rename.retry", "Retry drainage change")
        require(drainage)
        XCTAssertEqual(drainage.label, "No drainage holes")
        require(light)
        XCTAssertEqual(light.label, "Medium light")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        require(run.app.images["catalogue.saved.photo"])
        require(previous)
    }

    @MainActor func testPlantWateringFrequencyEditReplaysAndKeepsOtherConditions() {
        let run = Run("plantWateringEdit", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        let frequency = run.app.staticTexts["collection.watering.frequency.current"]
        require(frequency)
        XCTAssertEqual(frequency.label, "Moderate watering")
        tap(run, "collection.watering.frequency.open", "Edit watering frequency")
        let weekly = run.app.buttons.matching(identifier: "Once a week").firstMatch
        enabled(weekly)
        weekly.tap()
        require(run.app.staticTexts["collection.rename.pending"])

        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        // The typed edit precedes any later care command in Root's ordered retry pass.
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Once a week"), object: frequency
        )
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 15), .completed)
        XCTAssertFalse(run.app.staticTexts["collection.rename.pending"].exists)
        XCTAssertEqual(frequency.label, "Once a week")
        XCTAssertEqual(run.app.staticTexts["collection.light.current"].label, "Medium light")
        XCTAssertEqual(run.app.staticTexts["collection.drainage.current"].label, "Drainage holes")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        require(run.app.images["catalogue.saved.photo"])
        require(run.app.staticTexts["collection.analysis.previous.12340000-0000-4000-8000-000000000002"])
    }

    @MainActor func testPlantPotTypeEditReplaysAndKeepsPhotoAndHistory() {
        let run = Run("plantPotTypeEdit", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        let potType = run.app.staticTexts["collection.pot.type.current"]
        let previous = run.app.staticTexts["collection.analysis.previous.12340000-0000-4000-8000-000000000002"]
        require(potType)
        XCTAssertEqual(potType.label, "Plastic")
        require(run.app.images["catalogue.saved.photo"])
        require(run.app.staticTexts["Diagnosis"])
        XCTAssertFalse(previous.exists)
        tap(run, "collection.pot.type.open", "Edit pot type")
        let ceramic = run.app.buttons.matching(identifier: "Glazed ceramic").firstMatch
        enabled(ceramic)
        ceramic.tap()
        require(run.app.staticTexts["collection.rename.pending"])

        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(run.app.staticTexts["collection.rename.pending"])
        tap(run, "collection.rename.retry", "Retry pot type change")
        require(potType)
        XCTAssertEqual(potType.label, "Glazed ceramic")
        XCTAssertEqual(run.app.staticTexts["collection.light.current"].label, "Medium light")
        XCTAssertEqual(run.app.staticTexts["collection.drainage.current"].label, "Drainage holes")
        XCTAssertEqual(run.app.staticTexts["collection.watering.frequency.current"].label, "Moderate watering")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        require(run.app.images["catalogue.saved.photo"])
        require(previous)
    }

    @MainActor func testPlantTaxonEditUsesPublishedCatalogueAndReplays() {
        let run = Run("plantTaxonEdit", .en)
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        let cardId = identity(run, "catalogue.saved.card.")
        let species = run.app.staticTexts["catalogue.saved.species"]
        let photo = run.app.images["catalogue.saved.photo"]
        let previous = run.app.staticTexts["collection.analysis.previous.12340000-0000-4000-8000-000000000002"]
        require(run.app.staticTexts["Fern"])
        require(photo)
        require(run.app.staticTexts["Diagnosis"])
        XCTAssertFalse(previous.exists)
        let change = run.app.buttons["collection.species.open"]
        require(change)
        if !change.isHittable { run.app.swipeUp() }
        tap(run, "collection.species.open", "Change species")
        let current = run.app.buttons["catalogue.species.fixture_fern"]
        require(current)
        XCTAssertFalse(current.isEnabled)
        let search = run.app.textFields["catalogue.search"]
        require(search)
        search.tap()
        search.typeText("Chamaedorea")
        tap(run, "catalogue.species.fixture_palm")
        require(run.app.staticTexts["Chamaedorea elegans"])
        tap(run, "collection.species.confirm", "Confirm species change")
        require(run.app.staticTexts["collection.rename.pending"])

        restart(run)
        tap(run, "collection.open", "My plants")
        tap(run, "Fixture 1")
        require(run.app.staticTexts["collection.rename.pending"])
        tap(run, "collection.rename.retry", "Retry species change")
        require(run.app.staticTexts["Palm"])
        XCTAssertEqual(species.label, "Palm")
        XCTAssertEqual(run.app.staticTexts["catalogue.saved.name"].label, "Fixture 1")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), cardId)
        XCTAssertEqual(run.app.staticTexts["collection.light.current"].label, "Medium light")
        XCTAssertEqual(run.app.staticTexts["collection.pot.type.current"].label, "Plastic")
        require(photo)
        require(previous)
    }

    @MainActor func testTodayMixedChecksOpenRequestedCardOnce() {
        let run = Run("todayMixed", .en, today: true)
        defer { run.app.terminate() }
        launch(run)
        let tasks = todayTasks(run)
        XCTAssertEqual(tasks.count, 2)
        let target = tasks.first { todayElement(run, $0).label.contains("Fixture 2") }
        guard let target else { return XCTFail("Missing the nonfirst plant task") }
        let parts = target.dropFirst("today.task.".count).split(separator: "/").map(String.init)
        XCTAssertEqual(parts.count, 4)
        guard parts.count == 4 else { return }
        require(todayElement(run, "today.section.overdue." + parts[3]))
        XCTAssertTrue(todayElement(run, target).label.contains(parts[3]))
        guard let other = tasks.first(where: { $0 != target }) else { return XCTFail("Missing today task") }
        let currentDay = String(other.split(separator: "/").last!)
        require(todayElement(run, "today.section.today." + currentDay))
        assertTodayEntrypoints(run)
        todayTap(run, target)
        XCTAssertEqual(identity(run, "catalogue.saved.card."),
                       "catalogue.saved.card." + parts[1].lowercased())
        XCTAssertEqual(todayElement(run, "catalogue.saved.name").label, "Fixture 2")
        todayTap(run, "collection.back")
        require(todayElement(run, "collection.settings.open"))
        XCTAssertFalse(todayElement(run, "catalogue.saved.card." + parts[1].lowercased()).exists)
        todayTap(run, "collection.back")
        require(todayElement(run, "today.root"))
        XCTAssertEqual(Set(todayTasks(run)), Set(tasks))
        XCTAssertFalse(todayElement(run, "collection.back").exists)
    }

    @MainActor func testTodayFutureNoScheduleAndEmptyAreDistinct() {
        for scenario in ["todayFuture", "todayNoSchedule", "todayEmpty"] {
            let run = Run(scenario, .en, today: true)
            defer { run.app.terminate() }
            launch(run)
            require(todayElement(run, "today.lastChecked"))
            if scenario == "todayFuture" {
                let tasks = todayTasks(run)
                XCTAssertEqual(tasks.count, 2)
                let days = Set(tasks.map { String($0.split(separator: "/").last!) })
                XCTAssertEqual(days.count, 1)
                guard let day = days.first else { return XCTFail("Missing future source date") }
                require(todayElement(run, "today.section.future." + day))
                XCTAssertFalse(todayElement(run, "today.noSchedule").exists)
                XCTAssertFalse(todayElement(run, "today.empty").exists)
            } else {
                let expected = scenario == "todayEmpty" ? "today.empty" : "today.noSchedule"
                require(todayElement(run, expected))
                XCTAssertEqual(todayTaskQuery(run).count, 0)
                XCTAssertFalse(todayElement(run, scenario == "todayEmpty" ? "today.noSchedule" : "today.empty").exists)
                let shortcuts = run.app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.plant."))
                XCTAssertEqual(shortcuts.count, scenario == "todayEmpty" ? 0 : 2)
            }
            XCTAssertFalse(todayElement(run, "today.failed").exists)
            XCTAssertFalse(todayElement(run, "today.stale").exists)
            assertTodayEntrypoints(run)
        }
    }

    @MainActor func testTodayFirstFailureIsNotEmptySchedule() {
        let run = Run("todayFirstFailure", .en, today: true)
        defer { run.app.terminate() }
        launch(run)
        require(todayElement(run, "today.failed"))
        XCTAssertFalse(todayElement(run, "today.empty").exists)
        XCTAssertFalse(todayElement(run, "today.noSchedule").exists)
        XCTAssertFalse(todayElement(run, "today.lastChecked").exists)
        XCTAssertEqual(todayTaskQuery(run).count, 0)
        assertTodayEntrypoints(run)
        todayTap(run, "today.fixture.resume")
        XCTAssertEqual(todayTasks(run).count, 2)
        require(todayElement(run, "today.lastChecked"))
        todayAbsent(run, "today.failed")
    }

    @MainActor func testTodaySavedChecksSurviveOfflineColdLaunch() {
        let run = Run("todaySaved", .en, today: true)
        defer { run.app.terminate() }
        launch(run)
        let tasks = todayTasks(run)
        let checked = todayElement(run, "today.lastChecked")
        require(checked)
        let timestamp = checked.value as? String
        XCTAssertNotNil(timestamp)
        XCTAssertNotNil(timestamp.flatMap { value in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value)
        })
        todayTap(run, "today.fixture.offline")
        todayTap(run, "today.retry")
        require(todayElement(run, "today.failed"))
        require(todayElement(run, "today.cached"))
        XCTAssertEqual(checked.value as? String, timestamp)
        XCTAssertEqual(Set(todayTasks(run)), Set(tasks))

        // Same ledger, owner, persisted clock anchor and SQLite; offline is not reset on launch.
        run.app.terminate()
        run.app.launch()
        require(todayElement(run, "today.failed"))
        require(todayElement(run, "today.cached"))
        require(checked)
        XCTAssertEqual(checked.value as? String, timestamp)
        XCTAssertEqual(Set(todayTasks(run)), Set(tasks))
        XCTAssertFalse(todayElement(run, "today.empty").exists)
        XCTAssertFalse(todayElement(run, "today.noSchedule").exists)
        todayTap(run, "today.fixture.resume")
        let fetchedAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value != %@", timestamp ?? ""), object: checked
        )
        XCTAssertEqual(XCTWaiter.wait(for: [fetchedAgain], timeout: 15), .completed)
        todayAbsent(run, "today.failed")
        todayAbsent(run, "today.cached")
        XCTAssertEqual(Set(todayTasks(run)), Set(tasks))
        require(checked)
    }

    @MainActor func testTodayHomeReturnRevalidatesChangedSource() {
        let run = Run("todayMixed", .en, today: true)
        defer { run.app.terminate() }
        launch(run)
        XCTAssertEqual(todayTasks(run).count, 2)
        todayTap(run, "welcome.catalogue")
        require(todayElement(run, "catalogue.species.fixture_fern"))
        todayTap(run, "today.fixture.withdraw")
        // Withdrawal alone does no read. The production return-home event owns this refresh.
        todayTap(run, "catalogue.back")
        require(todayElement(run, "today.noSchedule"))
        XCTAssertEqual(todayTaskQuery(run).count, 0)
        XCTAssertFalse(todayElement(run, "today.failed").exists)
        XCTAssertFalse(todayElement(run, "today.empty").exists)
        XCTAssertFalse(run.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Fixture interval")).firstMatch.exists)
        assertTodayEntrypoints(run)
    }

    @MainActor func testMyPlantsRefreshInsideReadOpensCurrentCollectionWithoutLogin() {
        let run = Run("todaySDKOpening", .en, today: true)
        defer { run.app.terminate() }
        launch(run)
        require(todayElement(run, "sdk-opening.ready"))
        require(todayElement(run, "today.title"))
        todayTap(run, "sdk-opening.arm")
        todayTap(run, "collection.open")

        let plant = run.app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "collection.plant.", "Fixture 1")).firstMatch
        enabled(plant)
        require(run.app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "collection.plant.", "Fixture 2")).firstMatch)
        XCTAssertFalse(run.app.textFields["account.email"].exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
        let plantId = String(plant.identifier.dropFirst("collection.plant.".count))
        XCTAssertNotNil(UUID(uuidString: plantId))
        notificationImage(run, "sdk-opening-list_")

        plant.tap()
        require(run.app.staticTexts["catalogue.saved.name"])
        XCTAssertEqual(run.app.staticTexts["catalogue.saved.name"].label, "Fixture 1")
        XCTAssertEqual(identity(run, "catalogue.saved.card."), "catalogue.saved.card." + plantId)
        XCTAssertFalse(run.app.textFields["account.email"].exists)
        notificationImage(run, "sdk-opening-card_")
    }

    @MainActor func testMyPlantsExplicitSignOutRequiresLoginWithoutReseeding() {
        let run = Run("todaySDKOpening", .en, today: true)
        defer { run.app.terminate() }
        launch(run)
        require(todayElement(run, "sdk-opening.ready"))
        require(todayElement(run, "today.title"))
        todayTap(run, "collection.open")
        todayTap(run, "collection.settings.open")
        todayTap(run, "account.signOut.open")
        let confirm = run.app.alerts.buttons["account.signOut.confirm"].firstMatch
        enabled(confirm)
        confirm.tap()
        require(todayElement(run, "account.signedOut"))
        todayAbsent(run, "today.root")

        // Same process, ordinary Home action: no launch, seed or fixture sign-in.
        todayTap(run, "collection.open")
        enabled(run.app.textFields["account.email"])
        XCTAssertFalse(run.app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "collection.plant.")).firstMatch.exists)
        XCTAssertFalse(run.app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "catalogue.saved.card.")).firstMatch.exists)
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
        notificationImage(run, "sdk-opening-login_")
    }

    @MainActor func testTodayLocaleAndSignOutClearOldProjection() {
        let run = Run("todayMixed", .en, today: true)
        defer { run.app.terminate() }
        launch(run)
        let tasks = todayTasks(run)
        guard let first = tasks.first else { return XCTFail("Missing Today tasks") }
        XCTAssertTrue(todayElement(run, first).label.contains("Check soil"))
        selectLanguage(run, .pl)
        let title = todayElement(run, "today.title")
        let translated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", "Dzisiaj"), object: title
        )
        XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: 15), .completed)
        XCTAssertEqual(Set(todayTasks(run)), Set(tasks))
        let checked = todayElement(run, "today.lastChecked")
        require(checked)
        XCTAssertTrue(checked.label.hasPrefix("Ostatnio sprawdzono:"))
        for task in tasks {
            XCTAssertTrue(todayElement(run, task).label.contains("Sprawdź podłoże"))
        }
        todayAbsent(run, "today.failed")
        todayTap(run, "collection.open")
        todayTap(run, "collection.settings.open")
        todayTap(run, "account.signOut.open")
        let confirm = run.app.alerts.buttons["account.signOut.confirm"].firstMatch
        enabled(confirm)
        confirm.tap()
        require(todayElement(run, "account.signedOut"))
        todayAbsent(run, "today.root")
        XCTAssertEqual(todayTaskQuery(run).count, 0)
        XCTAssertFalse(checked.exists)
        XCTAssertFalse(run.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalogue.saved.card.")).firstMatch.exists)
        XCUIDevice.shared.press(.home)
        run.app.activate()
        require(todayElement(run, "account.signedOut"))
        todayAbsent(run, "today.root")
        XCTAssertEqual(todayTaskQuery(run).count, 0)
    }

    @MainActor
    private func todayElement(_ run: Run, _ identifier: String) -> XCUIElement {
        run.app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func todayTaskQuery(_ run: Run) -> XCUIElementQuery {
        run.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.task."))
    }

    @MainActor
    private func todayTasks(_ run: Run) -> [String] {
        let query = todayTaskQuery(run)
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: query)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 15), .completed)
        let tasks = query.allElementsBoundByIndex.map(\.identifier).sorted()
        XCTAssertEqual(Set(tasks).count, 2)
        for task in tasks {
            let day = String(task.split(separator: "/").last!)
            XCTAssertNotNil(day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression))
            XCTAssertTrue(todayElement(run, task).label.contains(day))
        }
        require(run.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Fixture interval")).firstMatch)
        return tasks
    }

    @MainActor
    private func assertTodayEntrypoints(_ run: Run) {
        for identifier in ["collection.open", "welcome.catalogue", "welcome.check", "welcome.identify"] {
            require(todayElement(run, identifier))
        }
    }

    @MainActor
    private func todayAbsent(_ run: Run, _ identifier: String) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: todayElement(run, identifier)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 15), .completed, identifier)
    }

    @MainActor
    private func todayTap(_ run: Run, _ identifier: String) {
        let element = todayElement(run, identifier)
        require(element)
        // Scroll only inside Today; DEBUG controls and sheet toolbars remain outside it.
        if !element.isHittable, todayElement(run, "today.root").exists {
            for _ in 0..<5 {
                run.app.swipeDown()
                if element.isHittable { break }
            }
            if !element.isHittable {
                for _ in 0..<8 {
                    run.app.swipeUp()
                    if element.isHittable { break }
                }
            }
        }
        enabled(element)
        element.tap()
    }


    // Dedicated consent fixtures exercise the rendered production controls and injected Core.
    @MainActor func testReminderEligibleConsentFromTodaySurvivesColdAndOptOut() {
        let run = reminderRun("eligible")
        defer { run.app.terminate() }
        launch(run)
        reminderExpandCompact(run)
        reminderPreference(run, false)
        reminderText(run, "care.reminders.status", "Reminders are off for this account.")
        reminderSetPreference(run, true)
        reminderOpenSettings(run)
        reminderSnapshot(run, "before-allow")
        reminderTap(run, "collection.settings.close")
        reminderTap(run, "collection.back")
        reminderExpandCompact(run)
        reminderPreference(run, true)
        reminderAllow(run)
        reminderConfirmed(run)
        screenshot(run, "compact-confirmed")
        // Snapshot controls live in settings; opening it may legitimately reconcile the plan.
        reminderOpenSettings(run)
        reminderConfirmed(run)
        reminderSnapshot(run, "confirmed")
        reminderTap(run, "collection.settings.close")
        reminderTap(run, "collection.back")
        let previous = todayElement(run, "today.lastChecked").value as? String ?? ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(formatter.date(from: previous))
        restart(run)
        reminderWait("Fresh cold-launch source") {
            let checked = self.todayElement(run, "today.lastChecked")
            guard checked.exists, let value = checked.value as? String else { return false }
            return formatter.date(from: value) != nil && value != previous
        }
        reminderOpenSettings(run)
        reminderPreference(run, true)
        reminderConfirmed(run)
        screenshot(run, "cold-opted-in")
        reminderSetPreference(run, false)
        reminderOff(run)
        reminderSnapshot(run, "verified-off")
        restart(run)
        reminderOpenSettings(run)
        reminderPreference(run, false)
        reminderOff(run)
        screenshot(run, "cold-opted-out")
    }

    @MainActor func testReminderOneReadLagRetryDoesNotAddOrPromptAgain() {
        let run = reminderRun("one-readlag")
        defer { run.app.terminate() }
        reminderBeginAllow(run)
        reminderConfirmed(run)
        reminderPresent(run, "care.reminders.readback")
        reminderSnapshot(run, "lag-confirmed-with-warning")
        reminderTap(run, "care.reminders.retry")
        reminderConfirmed(run)
        reminderAbsent(run, "care.reminders.readback")
        reminderSnapshot(run, "retry-confirmed")
    }

    @MainActor func testReminderTwoReadLagNeedsExplicitStatusRetry() {
        let run = reminderRun("two-readlag")
        defer { run.app.terminate() }
        reminderBeginAllow(run)
        reminderText(run, "care.reminders.status", "No pending reminders confirmed.")
        reminderAbsent(run, "care.reminders.confirmed")
        reminderSnapshot(run, "unconfirmed")
        reminderMarkedAction(run, "care.fixture.authorized")
        reminderText(run, "care.reminders.status", "No pending reminders confirmed.")
        reminderAbsent(run, "care.reminders.confirmed")
        reminderSnapshot(run, "authorized-without-retry")
        reminderTap(run, "care.reminders.retry")
        reminderConfirmed(run)
        reminderSnapshot(run, "first-status-retry")
        reminderTap(run, "care.reminders.retry")
        reminderConfirmed(run)
        reminderSnapshot(run, "second-status-retry")
    }

    @MainActor func testReminderDeniedKeepsManualJournalAvailable() {
        let run = reminderRun("denied")
        defer { run.app.terminate() }
        launch(run)
        reminderOpenSettings(run)
        reminderPreference(run, false)
        reminderSetPreference(run, true)
        reminderText(run, "care.reminders.status", "Notifications are denied in iOS.")
        reminderPresent(run, "care.reminders.settings")
        reminderAbsent(run, "care.reminders.allow")
        reminderAbsent(run, "care.reminders.confirmed")
        reminderSnapshot(run, "denied")
        reminderTap(run, "collection.settings.close")
        reminderTap(run, "collection.back")
        let journals = run.app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "today.plant."))
        reminderWait("Manual journal entry point") { journals.count > 0 }
        let journal = journals.firstMatch
        XCTAssertTrue(journal.label.contains("card and journal"))
        reminderTap(run, journal.identifier)
        let watering = reminderReach(run, "collection.watering.record")
        XCTAssertEqual(watering.label, "Record watering")
        enabled(watering)
        screenshot(run, "manual-journal-available")
    }

    @MainActor func testReminderNoScheduleNeverDefersPermissionPrompt() {
        let run = reminderRun("noSchedule")
        defer { run.app.terminate() }
        launch(run)
        reminderOpenSettings(run)
        reminderPreference(run, false)
        reminderSetPreference(run, true)
        reminderText(run, "care.reminders.status",
            "No eligible future tasks. This preference will not automatically prompt for iOS permission.")
        reminderAbsent(run, "care.reminders.allow")
        reminderSnapshot(run, "no-schedule")
        reminderTap(run, "care.fixture.restore")
        reminderPresent(run, "care.reminders.allow")
        reminderPreference(run, true)
        reminderAbsent(run, "care.reminders.confirmed")
        reminderSnapshot(run, "restored-before-explicit-allow")
        reminderAllow(run)
        reminderConfirmed(run)
        reminderSnapshot(run, "explicit-allow-confirmed")
    }

    @MainActor func testReminderFailedOptOutWaitsForVerifiedCleanup() {
        let run = reminderRun("failure")
        defer { run.app.terminate() }
        reminderBeginAllow(run)
        reminderText(run, "care.reminders.status", "Couldn’t confirm reminders. Retry the check.")
        reminderAbsent(run, "care.reminders.confirmed")
        reminderSnapshot(run, "add-failed")
        reminderMarkedAction(run, "care.fixture.failInventory")
        reminderSetPreference(run, false)
        reminderStopping(run)
        reminderSnapshot(run, "cleanup-unverified")
        reminderMarkedAction(run, "care.fixture.clearFailure")
        reminderStopping(run)
        reminderSnapshot(run, "cleared-without-retry")
        reminderTap(run, "care.reminders.retry")
        reminderOff(run)
        reminderSnapshot(run, "cleanup-verified")
    }

    @MainActor func testReminderReadinessPublishesInOpenSettings() {
        let run = reminderRun("readiness")
        defer { run.app.terminate() }
        launch(run)
        reminderOpenSettings(run)
        reminderText(run, "care.reminders.loading", "Reading reminder state…")
        reminderAbsent(run, "care.reminders.optIn")
        reminderSnapshot(run, "before-core-binding")
        reminderTap(run, "care.fixture.ready")
        reminderPreference(run, false)
        reminderOff(run)
        reminderSnapshot(run, "ready-without-prompt")
        reminderSetPreference(run, true)
        reminderAllow(run)
        reminderConfirmed(run)
        reminderSnapshot(run, "ready-confirmed")
    }

    @MainActor func testReminderConfirmedHourReplansInsideSettings() {
        let run = reminderRun("hour")
        defer { run.app.terminate() }
        reminderBeginAllow(run)
        reminderText(run, "profile.hour.synced", "09:00")
        reminderConfirmed(run)
        reminderSnapshot(run, "hour-nine-confirmed")
        _ = reminderReach(run, "profile.hour.picker")
        let picker = run.app.pickerWheels.firstMatch
        enabled(picker)
        picker.adjust(toPickerWheelValue: "23:00")
        reminderWait("Selected hour 23") { picker.value as? String == "23:00" }
        reminderTap(run, "profile.hour.save")
        reminderText(run, "profile.hour.pending", "Pending: 23:00")
        reminderAbsent(run, "profile.hour.synced")
        reminderAbsent(run, "profile.hour.save")
        screenshot(run, "hour-lost-reply")
        reminderTap(run, "profile.hour.retry")
        reminderText(run, "profile.hour.synced", "23:00")
        reminderAbsent(run, "profile.hour.pending")
        reminderAbsent(run, "profile.hour.retry")
        reminderConfirmed(run)
        XCTAssertTrue(run.app.buttons["collection.settings.close"].isHittable)
        reminderSnapshot(run, "hour-twenty-three-confirmed-same-sheet")
    }

    @MainActor func testNotificationTapFromAccountSettingsOpensCurrentNonFirstPlantOnce() {
        let run = reminderRun("routing")
        defer { run.app.terminate() }
        reminderBeginAllow(run)
        reminderConfirmed(run)
        let button = reminderReach(run, "care.fixture.notificationTap")
        let name = button.value as? String ?? ""
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(run.app.buttons["collection.settings.close"].exists)
        button.tap()
        reminderWait("Exact notification card") {
            run.app.staticTexts["catalogue.saved.name"].exists
                && run.app.staticTexts["catalogue.saved.name"].label == name
        }
        XCTAssertEqual(run.app.staticTexts["catalogue.saved.name"].label, name)
        XCTAssertFalse(run.app.buttons["collection.settings.close"].exists)
        reminderPresent(run, "collection.rename.open")
        reminderPresent(run, "collection.light.open")
        notificationImage(run, "notification-route-card_")
        reminderTap(run, "collection.back")
        reminderPresent(run, "collection.settings.open")
        reminderTap(run, "collection.back")
        reminderOpenSettings(run)
        reminderSnapshot(run, "before-duplicate-tap")
        reminderMarkedAction(run, "care.fixture.notificationTap")
        reminderPresent(run, "collection.settings.close")
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
        reminderSnapshot(run, "after-duplicate-tap")
    }

    @MainActor func testNotificationForegroundDeliveryRefreshesInventoryWithoutNavigation() {
        let run = reminderRun("routing")
        defer { run.app.terminate() }
        reminderBeginAllow(run)
        reminderConfirmed(run)
        reminderSnapshot(run, "before-foreground")
        reminderMarkedAction(run, "care.fixture.notificationForeground")
        reminderAbsent(run, "care.reminders.confirmed")
        reminderPresent(run, "collection.settings.close")
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
        reminderAbsent(run, "care.reminders.allow")
        reminderText(run, "care.reminders.status",
            "No eligible future tasks. This preference will not automatically prompt for iOS permission.")
        reminderSnapshot(run, "after-foreground")
        // The same actual wire is delivered only after the first zero-pending result.
        reminderMarkedAction(run, "care.fixture.notificationForeground")
        reminderText(run, "care.reminders.status",
            "No eligible future tasks. This preference will not automatically prompt for iOS permission.")
        reminderAbsent(run, "care.reminders.confirmed")
        reminderPresent(run, "collection.settings.close")
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
        reminderAbsent(run, "care.reminders.allow")
        reminderSnapshot(run, "after-second-foreground")
        notificationImage(run, "notification-foreground-settings_")
    }

    @MainActor func testNotificationTapUsesObservedNonFirstCollectionPlant() throws {
        let run = reminderRun("routing")
        defer { run.app.terminate() }
        launch(run)
        tap(run, "collection.open", "My plants")
        reminderWait("Collection toolbar ready before observing rows") {
            let settings = run.app.buttons["collection.settings.open"]
            return settings.exists && settings.isHittable
        }
        let collectionRows = run.app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "collection.plant."))
        reminderWait("Three visible collection rows") {
            collectionRows.allElementsBoundByIndex.filter { $0.isHittable }.count == 3
        }
        let rows = collectionRows.allElementsBoundByIndex.filter { $0.isHittable }.map {
            (identifier: $0.identifier, label: $0.label, minY: Double($0.frame.minY))
        }.sorted { $0.minY < $1.minY }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.map { $0.identifier }).count, 3)
        XCTAssertEqual(Set(rows.map { $0.label }).count, 3)
        for row in rows {
            XCTAssertNotNil(UUID(uuidString: String(row.identifier.dropFirst("collection.plant.".count))))
            XCTAssertFalse(row.label.isEmpty)
            XCTAssertTrue(row.minY.isFinite)
        }
        for index in 1..<rows.count {
            XCTAssertLessThan(rows[index - 1].minY, rows[index].minY)
        }
        let firstRow = try XCTUnwrap(rows.first)
        let firstIdentifier = firstRow.identifier
        let firstLabel = firstRow.label
        notificationImage(run, "notification-observed-initial-list_")

        tap(run, "collection.settings.open")
        enabled(run.app.buttons["collection.settings.close"])
        reminderPreference(run, false)
        reminderSetPreference(run, true)
        reminderAllow(run)
        reminderConfirmed(run)
        let button = reminderReach(run, "care.fixture.notificationTap")
        let selectedName = try XCTUnwrap(button.value as? String)
        XCTAssertFalse(selectedName.isEmpty)
        let selectedRows = rows.filter { $0.label == selectedName }
        XCTAssertEqual(selectedRows.count, 1)
        let selectedRow = try XCTUnwrap(selectedRows.first)
        let selectedIdentifier = selectedRow.identifier
        XCTAssertNotEqual(selectedIdentifier, firstIdentifier)
        XCTAssertNotEqual(selectedName, firstLabel)
        let mapping: [String: Any] = [
            "version": 1, "namespace": run.namespace,
            "rows": rows.map { row -> [String: Any] in
                ["identifier": row.identifier, "label": row.label, "minY": row.minY]
            },
            "firstIdentifier": firstIdentifier, "selectedIdentifier": selectedIdentifier,
            "selectedPlantName": selectedName
        ]
        let attachment = XCTAttachment(
            data: try JSONSerialization.data(withJSONObject: mapping, options: [.sortedKeys]),
            uniformTypeIdentifier: "public.json")
        attachment.name = "notification-observed-list-mapping_" + run.namespace
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(run.app.buttons["collection.settings.close"].exists)
        button.tap()
        reminderWait("Exact observed notification card") {
            run.app.staticTexts["catalogue.saved.name"].exists
                && run.app.staticTexts["catalogue.saved.name"].label == selectedName
        }
        XCTAssertEqual(run.app.staticTexts["catalogue.saved.name"].label, selectedName)
        XCTAssertFalse(run.app.buttons["collection.settings.close"].exists)
        reminderPresent(run, "collection.rename.open")
        reminderPresent(run, "collection.light.open")
        notificationImage(run, "notification-observed-route-card_")
        reminderTap(run, "collection.back")
        reminderPresent(run, "collection.settings.open")
        reminderTap(run, "collection.back")
        reminderOpenSettings(run)
        reminderSnapshot(run, "before-duplicate-tap")
        reminderMarkedAction(run, "care.fixture.notificationTap")
        reminderPresent(run, "collection.settings.close")
        XCTAssertFalse(run.app.staticTexts["catalogue.saved.name"].exists)
        reminderSnapshot(run, "after-duplicate-tap")
    }

    @MainActor
    private func notificationImage(_ run: Run, _ prefix: String) {
        let attachment = XCTAttachment(screenshot: run.app.screenshot())
        attachment.name = prefix + run.namespace
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func reminderRun(_ mode: String) -> Run {
        let run = Run(mode, .en)
        run.app.launchArguments = [
            "--care-reminder-fixture", mode, "--care-reminder-namespace", run.namespace,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        return run
    }

    @MainActor
    private func reminderWait(_ message: String, _ condition: @escaping () -> Bool,
                              file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed,
                       message, file: file, line: line)
    }

    @MainActor
    private func reminderScope(_ run: Run, _ identifier: String) -> XCUIElement {
        // The compact consent remains behind the account sheet. Never select that copy.
        if run.app.buttons["collection.settings.close"].exists,
           identifier != "collection.settings.close" {
            let fixtureScroll = run.app.scrollViews
                .containing(.button, identifier: "care.fixture.snapshot").firstMatch
            if fixtureScroll.exists { return fixtureScroll }
            // Offscreen children may not yet be in the accessibility tree.
            // Use only the visible sheet's scroll view while discovering them.
            return run.app.scrollViews.allElementsBoundByIndex.first(where: { $0.isHittable })
                ?? run.app.scrollViews.firstMatch
        }
        return run.app
    }

    @MainActor
    private func reminderElement(_ run: Run, _ identifier: String) -> XCUIElement {
        let query = reminderScope(run, identifier).descendants(matching: .any)
            .matching(identifier: identifier)
        return query.firstMatch
    }

    @MainActor
    @discardableResult
    private func reminderReach(_ run: Run, _ identifier: String) -> XCUIElement {
        let scope = reminderScope(run, identifier)
        let scopeType = scope.elementType
        let scopeIdentifier = scope.identifier
        let settingsWasOpen = run.app.buttons["collection.settings.close"].exists
        let navigationBar = run.app.navigationBars.firstMatch
        let hadNavigationBar = navigationBar.exists
        let navigationIdentifier = hadNavigationBar ? navigationBar.identifier : nil

        func sameScope() -> Bool {
            guard run.app.buttons["collection.settings.close"].exists == settingsWasOpen,
                  scope.exists else { return false }
            let current = reminderScope(run, identifier)
            guard current.exists, current.elementType == scopeType,
                  current.identifier == scopeIdentifier else { return false }
            let bar = run.app.navigationBars.firstMatch
            return bar.exists == hadNavigationBar &&
                (!hadNavigationBar || bar.identifier == navigationIdentifier)
        }

        func validFrame(_ frame: CGRect) -> Bool {
            !frame.isNull && !frame.isInfinite && !frame.isEmpty &&
                frame.origin.x.isFinite && frame.origin.y.isFinite &&
                frame.width.isFinite && frame.height.isFinite &&
                frame.maxX.isFinite && frame.maxY.isFinite
        }

        var gestures = 0
        var readinessDeadline: TimeInterval?
        var nativeReady = false

        func describe(_ elements: [XCUIElement]) -> String {
            "count=\(elements.count) " + elements.map {
                "type=\($0.elementType.rawValue) id=\($0.identifier) frame=\($0.frame)"
            }.joined(separator: "; ")
        }

        func diagnose(_ reason: String) {
            let chosen = reminderScope(run, identifier)
            let scopedMatches = chosen.descendants(matching: .any)
                .matching(identifier: identifier).allElementsBoundByIndex
            let appMatches = run.app.descendants(matching: .any)
                .matching(identifier: identifier).allElementsBoundByIndex
            let bars = run.app.navigationBars.allElementsBoundByIndex
            let frontBars = bars.filter {
                $0.descendants(matching: .button).matching(identifier: "collection.settings.close").count > 0 ||
                $0.descendants(matching: .button).matching(identifier: "collection.back").count > 0
            }
            let details = XCTAttachment(string: """
                reason=\(reason) target=\(identifier) gestures=\(gestures)/12
                readinessDeadline=\(String(describing: readinessDeadline))
                originalScope type=\(scopeType.rawValue) id=\(scopeIdentifier) exists=\(scope.exists) frame=\(scope.frame)
                chosenScope type=\(chosen.elementType.rawValue) id=\(chosen.identifier) exists=\(chosen.exists) frame=\(chosen.frame)
                settingsWasOpen=\(settingsWasOpen) settingsOpen=\(run.app.buttons["collection.settings.close"].exists)
                originalNavigation=\(String(describing: navigationIdentifier)) hadNavigationBar=\(hadNavigationBar)
                windows: \(describe(run.app.windows.allElementsBoundByIndex)) appFrame=\(run.app.frame)
                navigationBars: \(describe(bars))
                frontNavigationBars: \(describe(frontBars))
                chosenScopeMatches: \(describe(scopedMatches))
                wholeAppMatches: \(describe(appMatches))
                """)
            details.name = "consent-geometry-" + reason + "-" + identifier
            details.lifetime = .keepAlways
            add(details)
            screenshot(run, reason + "-" + identifier)
            let tree = XCTAttachment(string: run.app.debugDescription)
            tree.name = "consent-current-view-" + reason + "-" + identifier
            tree.lifetime = .keepAlways
            add(tree)
        }

        // Discovery and repositioning share twelve gestures. Waits always refresh geometry.
        while true {
            guard sameScope() else {
                diagnose("scope-changed")
                XCTFail("Discovery left the original view: " + identifier)
                break
            }
            let element = reminderElement(run, identifier)
            let window = run.app.windows.firstMatch
            let windowFrame = window.exists ? window.frame : run.app.frame
            let scopeFrame = scope.frame
            guard validFrame(windowFrame), validFrame(scopeFrame) else {
                diagnose("invalid-viewport")
                XCTFail("No finite current viewport: " + identifier)
                break
            }
            let viewport = windowFrame.intersection(scopeFrame)
            guard validFrame(viewport) else {
                diagnose("invalid-viewport")
                XCTFail("Current scope is outside the window: " + identifier)
                break
            }
            let frame = element.exists ? element.frame : CGRect.null
            let inside = validFrame(frame) && viewport.contains(frame)
            guard sameScope() else {
                diagnose("scope-changed")
                XCTFail("Readiness left the original view: " + identifier)
                break
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let deadline = readinessDeadline, now >= deadline, !nativeReady {
                diagnose("native-readiness-timeout")
                XCTFail("Native readiness timed out in current view: " + identifier)
                break
            }
            if element.exists && !element.isEnabled {
                // A disabled control is never scrolled and only gets exists/enabled probes.
                nativeReady = false
                if readinessDeadline == nil { readinessDeadline = now + 15 }
                let deadline = readinessDeadline ?? now
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else {
                    diagnose("disabled")
                    XCTFail("Enabled readiness timed out in current view: " + identifier)
                    break
                }
                let condition = NSPredicate(format: "exists == true AND enabled == true")
                if condition.evaluate(with: element) { continue }
                let ready = XCTNSPredicateExpectation(predicate: condition, object: element)
                let result = XCTWaiter.wait(for: [ready], timeout: min(1, remaining))
                guard result == .completed || result == .timedOut else {
                    diagnose("enabled-waiter-failed")
                    XCTAssertEqual(result, .completed, "Enabled in current view: " + identifier)
                    break
                }
                continue
            }
            if inside {
                if nativeReady {
                    // The successful native probe is followed by fresh scope and viewport reads.
                    enabled(element)
                    return element
                }
                if readinessDeadline == nil {
                    readinessDeadline = ProcessInfo.processInfo.systemUptime + 15
                }
                let remaining = (readinessDeadline ?? now) - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else {
                    diagnose("native-readiness-timeout")
                    XCTFail("Native readiness timed out in current view: " + identifier)
                    break
                }
                let condition = NSPredicate(format: "exists == true AND enabled == true AND hittable == true")
                if condition.evaluate(with: element) {
                    nativeReady = true
                    continue
                }
                let ready = XCTNSPredicateExpectation(predicate: condition, object: element)
                let result = XCTWaiter.wait(for: [ready], timeout: min(1, remaining))
                guard result == .completed || result == .timedOut else {
                    diagnose("native-waiter-failed")
                    XCTAssertEqual(result, .completed, "Native readiness in current view: " + identifier)
                    break
                }
                nativeReady = result == .completed
                continue
            }
            nativeReady = false
            if let deadline = readinessDeadline, ProcessInfo.processInfo.systemUptime >= deadline {
                diagnose("native-readiness-timeout")
                XCTFail("Native readiness timed out while repositioning: " + identifier)
                break
            }
            guard gestures < 12 else {
                diagnose("unreachable")
                XCTFail("Not fully inside the current viewport: " + identifier)
                break
            }
            if validFrame(frame), frame.maxY > viewport.maxY {
                scope.swipeUp()
            } else if validFrame(frame), frame.minY < viewport.minY {
                scope.swipeDown()
            } else if !validFrame(frame) {
                if gestures < 8 { scope.swipeUp() } else { scope.swipeDown() }
            } else {
                diagnose("outside-horizontal-viewport")
                XCTFail("Cannot reach with vertical scrolling: " + identifier)
                break
            }
            gestures += 1
        }
        let element = reminderElement(run, identifier)
        enabled(element)
        return element
    }

    @MainActor
    private func reminderTap(_ run: Run, _ identifier: String) {
        let element = reminderReach(run, identifier)
        enabled(element)
        element.tap()
    }

    @MainActor
    private func reminderPresent(_ run: Run, _ identifier: String) {
        _ = reminderReach(run, identifier)
    }

    @MainActor
    private func reminderAbsent(_ run: Run, _ identifier: String) {
        reminderWait("Absent in current view: " + identifier) {
            !self.reminderElement(run, identifier).exists
        }
    }

    @MainActor
    private func reminderText(_ run: Run, _ identifier: String, _ text: String) {
        _ = reminderReach(run, identifier)
        reminderWait(identifier + " = " + text) {
            self.reminderElement(run, identifier).label == text
        }
    }

    @MainActor
    private func reminderPreference(_ run: Run, _ on: Bool) {
        _ = reminderReach(run, "care.reminders.optIn")
        reminderWait("Consent preference " + String(on)) {
            self.reminderElement(run, "care.reminders.optIn").value as? String == (on ? "1" : "0")
        }
    }

    @MainActor
    private func reminderSetPreference(_ run: Run, _ on: Bool) {
        reminderPreference(run, !on)
        reminderTap(run, "care.reminders.optIn")
        reminderPreference(run, on)
    }

    @MainActor
    private func reminderOpenSettings(_ run: Run) {
        reminderTap(run, "collection.open")
        reminderWait("Collection toolbar ready before settings search") {
            let settings = run.app.buttons["collection.settings.open"]
            return settings.exists && settings.isHittable
        }
        reminderTap(run, "collection.settings.open")
        enabled(run.app.buttons["collection.settings.close"])
    }

    @MainActor
    private func reminderExpandCompact(_ run: Run) {
        reminderWait("Today source settled") { self.todayElement(run, "today.lastChecked").exists }
        if !reminderElement(run, "care.reminders.optIn").exists {
            let disclosure = run.app.buttons.matching(NSPredicate(format: "label == %@", "Care reminders")).firstMatch
            enabled(disclosure)
            disclosure.tap()
        }
        reminderPresent(run, "care.reminders.optIn")
    }

    @MainActor
    private func reminderBeginAllow(_ run: Run) {
        launch(run)
        reminderOpenSettings(run)
        reminderPreference(run, false)
        reminderSetPreference(run, true)
        reminderAllow(run)
    }

    @MainActor
    private func reminderAllow(_ run: Run) {
        let allow = reminderReach(run, "care.reminders.allow")
        XCTAssertEqual(allow.label, "Allow notifications")
        enabled(allow)
        allow.tap()
    }

    @MainActor
    private func reminderConfirmed(_ run: Run) {
        reminderText(run, "care.reminders.status", "Pending iOS notifications confirmed.")
        reminderText(run, "care.reminders.confirmed", "Confirmed pending: 2")
    }

    @MainActor
    private func reminderOff(_ run: Run) {
        reminderPreference(run, false)
        reminderText(run, "care.reminders.status", "Reminders are off for this account.")
        reminderAbsent(run, "care.reminders.readback")
        reminderAbsent(run, "care.reminders.confirmed")
    }

    @MainActor
    private func reminderStopping(_ run: Run) {
        reminderPreference(run, false)
        reminderText(run, "care.reminders.status",
            "Preference is off. iOS notification cleanup is not confirmed. Retry the check.")
        reminderPresent(run, "care.reminders.readback")
        reminderPresent(run, "care.reminders.retry")
        reminderAbsent(run, "care.reminders.confirmed")
    }

    @MainActor
    private func reminderMarker(_ run: Run) -> Int {
        let changed = reminderElement(run, "care.fixture.changed")
        guard changed.exists else { return 0 }
        let label = changed.label
        return Int(label.replacingOccurrences(of: "Changed: ", with: "")) ?? 0
    }

    @MainActor
    private func reminderMarkedAction(_ run: Run, _ identifier: String) {
        let previous = reminderMarker(run)
        reminderTap(run, identifier)
        _ = reminderReach(run, "care.fixture.changed")
        reminderWait("Persisted fixture ACK advances") { self.reminderMarker(run) > previous }
    }

    @MainActor
    private func reminderSnapshot(_ run: Run, _ phase: String) {
        reminderMarkedAction(run, "care.fixture.snapshot")
        let status = reminderElement(run, "care.reminders.status")
        if status.exists { reminderPresent(run, "care.reminders.status") }
        else { reminderPresent(run, "care.reminders.loading") }
        screenshot(run, phase)
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

        init(_ scenario: String, _ language: Language, today: Bool = false, longDetails: Bool = false) {
            self.scenario = scenario
            self.language = language
            app.launchArguments = [
                today ? "--today-fixture" : "--catalogue-fixture", scenario, "--catalogue-namespace", namespace,
                "-AppleLanguages", "(" + language.rawValue + ")",
                "-AppleLocale", language == .pl ? "pl_PL" : "en_US"
            ]
            if longDetails { app.launchArguments.append("--catalogue-long-details") }
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
        if ["collection.rename.open", "collection.light.open", "collection.drainage.open", "collection.watering.frequency.open", "collection.pot.type.open", "collection.species.open"].contains(identifier) {
            _ = reminderReach(run, identifier)
        }
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
                       run.language.text("Edit plant details", "Zmień dane rośliny"))
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
        let resume = run.app.buttons["catalogue.resume"]
        if resume.waitForExistence(timeout: 15) {
            enabled(resume)
            resume.tap()
        }
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
        // Setup has only checkpointed/enqueued an intent; explicitly reopen it without a send.
        launch(run)
        tap(run, "catalogue.resume")
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
        tap(run, "catalogue.resume")
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

    @MainActor
    func testQuietGardenTodayCollectionCardAndSettingsVisuals() {
        for language in [Language.en, .pl] {
            let run = Run("todayMixed", language, today: true)
            defer { run.app.terminate() }
            launch(run)
            require(todayElement(run, "today.lastChecked"))
            XCTAssertEqual(todayTasks(run).count, 2)
            screenshot(run, "qg-today")
            todayTap(run, "collection.open")
            require(todayElement(run, "collection.settings.open"))
            let first = run.app.buttons.matching(NSPredicate(format: "label == %@", "Fixture 1")).firstMatch
            enabled(first)
            screenshot(run, "qg-collection")
            first.tap()
            let name = run.app.staticTexts["catalogue.saved.name"]
            require(name)
            XCTAssertEqual(name.label, "Fixture 1")
            screenshot(run, "qg-card")
            todayTap(run, "collection.back")
            todayTap(run, "collection.settings.open")
            require(todayElement(run, "profile.hour.synced"))
            enabled(run.app.buttons["collection.settings.close"])
            screenshot(run, "qg-settings")
            todayTap(run, "collection.settings.close")
            enabled(first)
            XCTAssertFalse(name.exists)
        }
    }

}
