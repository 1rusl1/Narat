import Foundation
import Testing
@testable import Plants

struct PlantsBootstrapTests {
    @Test("Resolves Polish when pl is first preferred language")
    func resolvesPolishPreferredLanguage() {
        let resolved = SupportedLocale.resolveInitial(preferredLanguages: ["pl-PL", "en-US"])
        #expect(resolved == .pl)
    }

    @Test("Falls back to English when preferred language is unsupported (FR-045)")
    func fallsBackToEnglishForUnsupportedLanguage() {
        let resolved = SupportedLocale.resolveInitial(preferredLanguages: ["de-DE", "fr-FR"])
        #expect(resolved == .en)
    }

    @Test("Persists language selection in UserDefaults")
    @MainActor
    func persistsLanguageSelection() throws {
        let suiteName = "app.narat.plants.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = LanguageStore(userDefaults: defaults, preferredLanguages: ["pl-PL"])
        #expect(store.currentLocale == .pl)

        store.currentLocale = .en
        let reloaded = LanguageStore(userDefaults: defaults, preferredLanguages: ["pl-PL"])
        #expect(reloaded.currentLocale == .en)
    }
}
