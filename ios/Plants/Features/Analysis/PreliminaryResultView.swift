import SwiftUI

struct GuestIdentificationActions {
    let busy: Bool
    let failed: Bool
    let save: (PhotoIdentificationSelection) -> Void
}

public struct PreliminaryResultView: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore
    private var catalogueConnection: CatalogueConnection? = nil
    private var guestActions: GuestIdentificationActions? = nil
    @State private var saveLocked = false

    public init(model: AnalysisFlowModel, languageStore: LanguageStore) {
        self.model = model
        self.languageStore = languageStore
    }

    init(model: AnalysisFlowModel, languageStore: LanguageStore, catalogueConnection: CatalogueConnection?,
         guestActions: GuestIdentificationActions? = nil) {
        self.model = model
        self.languageStore = languageStore
        self.catalogueConnection = catalogueConnection
        self.guestActions = guestActions
    }

    private var isPolish: Bool { languageStore.currentLocale == .pl }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.isAnalyzing {
                    ProgressView(isPolish ? "Analizowanie zdjęcia" : "Analyzing photo")
                        .accessibilityIdentifier("analysis.progress")
                    exitButtons
                } else if model.identificationResult != nil {
                    speciesHeading
                    if let confirmed = model.confirmedPhotoIdentification {
                        Text(isPolish ? "Gatunek potwierdzony." : "Species confirmed.")
                            .accessibilityIdentifier("analysis.identification.confirmed")
                        if let connection = catalogueConnection, let owner = confirmed.ownerId,
                           let session = connection.snapshot, !session.isAnonymous, session.session.userId == owner,
                           let label = model.speciesLabel {
                            CatalogueSaveView(
                                connection: connection, speciesSlug: confirmed.speciesSlug,
                                displayName: label, scientificName: "", polish: isPolish,
                                analysisSaveIdentity: confirmed.jobId,
                                identification: .init(jobId: confirmed.jobId, taxonId: confirmed.taxonId),
                                expectedPhotoId: confirmed.photoAssetId, selectionLocked: $saveLocked
                            ) { EmptyView() }
                            .id(confirmed.jobId)
                        } else if let guestActions, let session = catalogueConnection?.snapshot,
                                  session.isAnonymous, session.session.userId == confirmed.ownerId {
                            Button("Sign in to save") { guestActions.save(confirmed) }
                                .buttonStyle(.borderedProminent)
                                .disabled(guestActions.busy)
                                .accessibilityIdentifier("staging.guest.draft.save")
                            if guestActions.busy { ProgressView("Preparing your plant…") }
                            if guestActions.failed { Text("Couldn’t prepare your plant. Try again.") }
                        }
                    } else if model.canConfirmPhotoIdentification {
                        Button(isPolish ? "Potwierdź gatunek" : "Confirm this species") {
                            model.confirmPhotoIdentification()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("analysis.identification.confirm")
                    }
                    exitButtons
                } else if let result = model.preliminaryResult {
                    speciesHeading
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

    private var speciesHeading: some View {
        Text(model.speciesLabel ?? (isPolish ? "Nie udało się ustalić gatunku." : "Species could not be determined."))
            .font(.headline)
            .accessibilityIdentifier("analysis.result.species")
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
        .disabled((catalogueConnection != nil && saveLocked) || guestActions?.busy == true)
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
        case "analysis.error.quota_registration":
            return isPolish
                ? "Nie można potwierdzić daty rejestracji konta, aby rozpocząć kolejną analizę."
                : "We couldn’t verify your account registration date to start another analysis."
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

            if model.analysisError != "analysis.error.provider_terminal",
               model.analysisError != "analysis.error.quota_registration" {
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
