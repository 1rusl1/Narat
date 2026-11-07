import SwiftUI

public struct PreliminaryResultView: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore

    public init(model: AnalysisFlowModel, languageStore: LanguageStore) {
        self.model = model
        self.languageStore = languageStore
    }

    private var isPolish: Bool {
        languageStore.currentLocale == .pl
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.isAnalyzing {
                    neutralWaitingSection
                } else if let err = model.analysisError {
                    errorOrLimitSection(errorCode: err)
                } else if let result = model.preliminaryResult {
                    resultContentSection(result: result)
                }
            }
            .padding()
        }
        .navigationTitle(isPolish ? "Wynik wstępny" : "Preliminary Result")
    }

    /// US1.14: Neutral waiting screen that never promises a detected disease.
    private var neutralWaitingSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(
                isPolish
                    ? "Sprawdzamy zdjęcie oraz podane warunki pielęgnacji…"
                    : "Checking the photo and reported care conditions…"
            )
            .font(.headline)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("analysis.waiting.neutral_title")

            Text(
                isPolish
                    ? "Porównujemy widoczne cechy z bazą zweryfikowanych protokołów Narat."
                    : "Comparing visible traits against Narat's verified protocol database."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("analysis.waiting.neutral_subtitle")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorOrLimitSection(errorCode: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if errorCode == "analysis.error.quota_exhausted" {
                Text(
                    isPolish
                        ? "Bezpłatny skan startowy dla tego trybu został już wykorzystany."
                        : "The free starter scan for this mode has already been used."
                )
                .font(.headline)
                .accessibilityIdentifier("analysis.quota_exhausted.title")

                Text(
                    isPolish
                        ? "Możesz nadal bezpłatnie dodać roślinę z katalogu i korzystać z podstawowej pielęgnacji do 3 roślin."
                        : "You can still add your plant from the catalogue for free and use basic care for up to 3 plants."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("analysis.quota_exhausted.subtitle")
            } else {
                Text(
                    isPolish
                        ? "Nie udało się dokończyć analizy. Ponowienie próby nie zużyje dodatkowego limitu."
                        : "Could not complete the analysis. Retrying will not consume an additional scan."
                )
                .font(.headline)
                .accessibilityIdentifier("analysis.retryable_error.title")

                Button {
                    model.submitAnalysis(locale: languageStore.currentLocale)
                } label: {
                    Text(isPolish ? "Spróbuj ponownie (bez utraty limitu)" : "Retry (without losing quota)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("analysis.retry.button")
            }

            Button {
                model.router.navigateBack()
            } label: {
                Text(isPolish ? "Wróć do pytań" : "Back to questions")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("analysis.back.button")
        }
    }

    /// US1.15: First result screen with likely cause/health, evidence basis, limitations, and first action.
    private func resultContentSection(result: PreliminaryAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    model.router.flowState.confirmedDisplayName ??
                        (isPolish ? "Monstera dziurawa" : "Swiss Cheese Plant")
                )
                .font(.title2.bold())
                .accessibilityIdentifier("result.plant.name")

                Text(
                    isPolish
                        ? "Prawdopodobna przyczyna: Przelanie (nadmiar wody)"
                        : "Likely cause: Overwatering"
                )
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("result.cause.title")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(isPolish ? "Podstawa wniosku" : "Evidence Basis")
                    .font(.subheadline.bold())
                ForEach(result.evidenceBasis, id: \.self) { item in
                    Text("• \(item)")
                        .font(.subheadline)
                }
            }
            .accessibilityIdentifier("result.evidence.section")

            VStack(alignment: .leading, spacing: 6) {
                Text(isPolish ? "Ograniczenia oceny" : "Assessment Limitations")
                    .font(.subheadline.bold())
                ForEach(result.limitations, id: \.self) { lim in
                    Text("• \(lim)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("result.limitations.section")

            if let action = result.firstActionSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isPolish ? "Pierwszy bezpieczny krok teraz" : "First Safe Action Now")
                        .font(.subheadline.bold())
                    Text(action)
                        .font(.body)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("result.first_action.section")
            }

            Button {
                model.router.navigateBack()
            } label: {
                Text(isPolish ? "Wróć i edytuj odpowiedzi" : "Back to edit answers")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("result.back_to_questions.button")
        }
    }
}
