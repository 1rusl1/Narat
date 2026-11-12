import SwiftUI

public struct PreliminaryResultView: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore
    private var catalogueConnection: CatalogueConnection? = nil
    @State private var saveLocked = false

    public init(model: AnalysisFlowModel, languageStore: LanguageStore) {
        self.model = model
        self.languageStore = languageStore
    }

    init(model: AnalysisFlowModel, languageStore: LanguageStore, catalogueConnection: CatalogueConnection?) {
        self.model = model
        self.languageStore = languageStore
        self.catalogueConnection = catalogueConnection
    }

    private var isPolish: Bool { languageStore.currentLocale == .pl }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.isAnalyzing {
                    ProgressView(isPolish ? "Analizowanie zdjęcia" : "Analyzing photo")
                        .accessibilityIdentifier("analysis.progress")
                    exitButtons
                } else if let result = model.preliminaryResult {
                    Text(model.speciesLabel ?? (isPolish
                         ? "Nie udało się ustalić gatunku."
                         : "Species could not be determined."))
                        .font(.headline)
                        .accessibilityIdentifier("analysis.result.species")
                    if result.mode == .diagnosis {
                        if let condition = model.conditionLabel {
                            Text(isPolish ? "Możliwa przyczyna — \(condition)" : "Possible condition — \(condition)")
                                .accessibilityIdentifier("analysis.result.condition")
                        } else if result.diagnosisStatus == .healthy {
                            Text(isPolish ? "Nie wykryto problemu." : "No problem detected.")
                                .accessibilityIdentifier("analysis.result.healthy")
                        } else {
                            Text(isPolish
                                 ? "Nie ustalono jednoznacznej diagnozy."
                                 : "No conclusive diagnosis is available.")
                                .accessibilityIdentifier("analysis.result.uncertainty")
                        }
                    }
                    ForEach(Array(result.limitations.enumerated()), id: \.offset) { _, limitation in
                        Text(limitation)
                    }
                    if result.mode == .identification {
                        if model.confirmedPhotoIdentification != nil {
                            Text(isPolish ? "Gatunek potwierdzony." : "Species confirmed.")
                                .accessibilityIdentifier("analysis.identification.confirmed")
                        } else if model.canConfirmPhotoIdentification {
                            Button(isPolish ? "Potwierdź gatunek" : "Confirm this species") {
                                model.confirmPhotoIdentification()
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("analysis.identification.confirm")
                        }
                    }
                    if let connection = catalogueConnection,
                       connection.snapshot?.isAnonymous == false,
                       result.mode == .diagnosis,
                       result.identificationStatus == .resolved,
                       let species = result.plantId,
                       !species.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let label = model.speciesLabel,
                       !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        CatalogueSaveView(
                            connection: connection, speciesSlug: species,
                            displayName: label, scientificName: "", polish: false,
                            analysisSaveIdentity: result.jobId,
                            selectionLocked: $saveLocked
                        ) { EmptyView() }
                        .id(result.jobId)
                    }
                    exitButtons
                } else {
                    AnalysisUnavailableSection(model: model, languageStore: languageStore)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(isPolish ? "Analiza" : "Analysis")
    }

    private var exitButtons: some View {
        Group {
            Button(isPolish ? "Wstecz" : "Back") {
                model.returnFromAnalysis()
            }
            .accessibilityIdentifier("analysis.back.button")
            Button(isPolish ? "Przejdź do katalogu" : "Open catalogue") {
                model.showCatalogue()
            }
            .accessibilityIdentifier("analysis.catalogue.button")
        }
        .disabled(catalogueConnection != nil && saveLocked)
        .buttonStyle(.bordered)
    }
}

/// Shared failure UI also preserves the fail-closed entry without a service.
struct AnalysisUnavailableSection: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore

    private var isPolish: Bool { languageStore.currentLocale == .pl }

    private var failureText: String {
        switch model.analysisError {
        case "analysis.error.provider":
            return isPolish
                ? "Usługa analizy jest chwilowo niedostępna. Spróbuj ponownie."
                : "The analysis provider is temporarily unavailable. Please retry."
        case "analysis.error.provider_terminal":
            return isPolish
                ? "Usługa analizy nie ukończyła zadania. Wróć do wyboru zdjęcia."
                : "The provider could not complete the analysis. Go back to choose a photo."
        case "analysis.error.failed":
            return isPolish
                ? "Nie udało się przeanalizować zdjęcia. Spróbuj ponownie."
                : "Unable to analyze the photo. Please retry."
        default:
            return isPolish
                ? "Analiza jest tymczasowo niedostępna."
                : "Analysis is temporarily unavailable."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(failureText)
                .font(.headline)
                .accessibilityIdentifier("analysis.unavailable.title")

            if model.analysisError != "analysis.error.provider_terminal" {
                Button(isPolish ? "Spróbuj ponownie" : "Retry") {
                    model.submitAnalysis(locale: languageStore.currentLocale)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("analysis.retry.button")
            }

            Button(isPolish ? "Wstecz" : "Back") {
                model.returnFromAnalysis()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("analysis.back.button")

            Button(isPolish ? "Przejdź do katalogu" : "Open catalogue") {
                model.showCatalogue()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("analysis.catalogue.button")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
