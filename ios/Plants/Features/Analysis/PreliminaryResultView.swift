import SwiftUI

public struct PreliminaryResultView: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore

    public init(model: AnalysisFlowModel, languageStore: LanguageStore) {
        self.model = model
        self.languageStore = languageStore
    }

    public var body: some View {
        ScrollView {
            AnalysisUnavailableSection(model: model, languageStore: languageStore)
                .padding()
        }
        .navigationTitle(languageStore.currentLocale == .pl ? "Analiza" : "Analysis")
    }
}

/// Also used at scan entry: there is no real photo input or analysis service yet.
struct AnalysisUnavailableSection: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore

    private var isPolish: Bool { languageStore.currentLocale == .pl }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isPolish
                 ? "Analiza jest tymczasowo niedostępna."
                 : "Analysis is temporarily unavailable.")
                .font(.headline)
                .accessibilityIdentifier("analysis.unavailable.title")

            Button(isPolish ? "Spróbuj ponownie" : "Retry") {
                model.submitAnalysis(locale: languageStore.currentLocale)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("analysis.retry.button")

            Button(isPolish ? "Wstecz" : "Back") {
                model.router.returnFromUnavailableAnalysis()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("analysis.back.button")

            Button(isPolish ? "Przejdź do katalogu" : "Open catalogue") {
                model.router.showCatalogue()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("analysis.catalogue.button")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
