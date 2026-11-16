import SwiftUI

struct GuestIdentificationActions {
    let busy: Bool
    let failed: Bool
    let save: (PhotoIdentificationSelection) -> Void
    var saveDiagnosis: ((GuestDiagnosisSelection) -> Void)? = nil
}

/// A resolved initial diagnosis with the verified upload owned by the active guest.
struct GuestDiagnosisSelection: Equatable, Sendable {
    let jobId: UUID
    let photoId: UUID
    let ownerId: UUID

    init?(result: PreliminaryAnalysis, photo: (id: UUID, owner: UUID)?,
          isInitial: Bool, expected: CatalogueSDKSnapshot) {
        guard isInitial, result.mode == .diagnosis, result.identificationStatus == .resolved,
              let plant = result.plantId,
              !plant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expected.isAnonymous, PlantsAPIClient.isGuestPhotoSession(expected.session),
              let photo, photo.owner == expected.session.userId else { return nil }
        jobId = result.jobId
        photoId = photo.id
        ownerId = photo.owner
    }
}

struct FirstAidResultContext {
    let connection: CatalogueConnection
    let expected: CatalogueSDKSnapshot
    let openJournal: () -> Void
}

public struct PreliminaryResultView: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore
    private var catalogueConnection: CatalogueConnection? = nil
    private var guestActions: GuestIdentificationActions? = nil
    private var returnToPlant: (() -> Void)? = nil
    private var firstAidContext: FirstAidResultContext? = nil
    @State private var saveLocked = false

    public init(model: AnalysisFlowModel, languageStore: LanguageStore) {
        self.model = model
        self.languageStore = languageStore
    }

    init(model: AnalysisFlowModel, languageStore: LanguageStore, catalogueConnection: CatalogueConnection?,
         guestActions: GuestIdentificationActions? = nil, returnToPlant: (() -> Void)? = nil,
         firstAidContext: FirstAidResultContext? = nil) {
        self.model = model
        self.languageStore = languageStore
        self.catalogueConnection = catalogueConnection
        self.guestActions = guestActions
        self.returnToPlant = returnToPlant
        self.firstAidContext = firstAidContext
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
                    let explanation = InitialDiagnosisExplanation(result: result, polish: isPolish)
                    speciesHeading
                    if result.mode == .diagnosis {
                        if let condition = model.conditionLabel {
                            Text(isPolish ? "Możliwa przyczyna — \(condition)" : "Possible condition — \(condition)")
                                .accessibilityIdentifier("analysis.result.condition")
                        } else if result.diagnosisStatus == .healthy {
                            Text(isPolish ? "Nie wykryto problemu." : "No problem detected.")
                                .accessibilityIdentifier("analysis.result.healthy")
                        } else {
                            Text(model.repeatDiagnosisTarget == nil
                                 ? explanation.uncertaintyStatus
                                 : (isPolish
                                    ? "Nie ustalono jednoznacznej diagnozy."
                                    : "No conclusive diagnosis is available."))
                                .accessibilityIdentifier("analysis.result.uncertainty")
                        }
                    }
                    if model.repeatDiagnosisTarget == nil, result.mode == .diagnosis {
                        if !explanation.evidence.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(isPolish ? "Co widać na zdjęciu" : "What the photo shows")
                                    .font(.headline)
                                ForEach(explanation.evidence, id: \.self) { evidence in
                                    Text(verbatim: evidence)
                                }
                            }
                            .accessibilityIdentifier("analysis.result.evidence")
                        }
                        if let summary = explanation.firstAction {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(isPolish ? "Pierwsze działanie" : "First action")
                                    .font(.headline)
                                Text(verbatim: summary)
                            }
                            .accessibilityIdentifier("analysis.result.firstAction")
                        }
                    }
                    ForEach(Array((model.repeatDiagnosisTarget == nil
                                   ? explanation.limitations
                                   : result.limitations).enumerated()), id: \.offset) { _, limitation in
                        Text(limitation)
                    }
                    if let context = firstAidContext, let action = model.recordableFirstAid,
                       let target = model.repeatDiagnosisTarget, let summary = result.firstActionSummary,
                       target.ownerId == context.expected.session.userId,
                       context.connection.snapshot == context.expected {
                        FirstAidRecordControls(context: context, target: target, action: action, summary: summary)
                            .id(action.jobId)
                    }
                    if let guestActions, let save = guestActions.saveDiagnosis,
                       let session = catalogueConnection?.snapshot,
                       let selection = GuestDiagnosisSelection(
                           result: result, photo: model.diagnosisPhoto,
                           isInitial: model.repeatDiagnosisTarget == nil, expected: session
                       ) {
                        Button(isPolish ? "Zaloguj się, aby zapisać" : "Sign in to save") { save(selection) }
                            .buttonStyle(.borderedProminent)
                            .disabled(guestActions.busy)
                            .accessibilityIdentifier("staging.guest.draft.save")
                        if guestActions.busy {
                            ProgressView(isPolish ? "Przygotowywanie rośliny…" : "Preparing your plant…")
                        }
                        if guestActions.failed {
                            Text(isPolish ? "Nie udało się przygotować rośliny. Spróbuj ponownie."
                                 : "Couldn’t prepare your plant. Try again.")
                        }
                    }
                    if model.repeatDiagnosisTarget == nil, let connection = catalogueConnection,
                       let session = connection.snapshot, !session.isAnonymous,
                       let photo = model.diagnosisPhoto, photo.owner == session.session.userId,
                       result.mode == .diagnosis,
                       result.identificationStatus == .resolved,
                       let species = result.plantId,
                       !species.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let label = model.speciesLabel,
                       !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        CatalogueSaveView(
                            connection: connection, speciesSlug: species,
                            displayName: label, scientificName: "", polish: false,
                            analysisSaveIdentity: result.jobId, diagnosisJobId: result.jobId,
                            expectedPhotoId: photo.id, selectionLocked: $saveLocked
                        ) { EmptyView() }
                        .id(result.jobId)
                    }
                    exitButtons
                } else {
                    AnalysisUnavailableSection(model: model, languageStore: languageStore, returnToPlant: returnToPlant)
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
        AnalysisExitButtons(model: model, polish: isPolish, returnToPlant: returnToPlant)
            .disabled((catalogueConnection != nil && saveLocked) || guestActions?.busy == true)
            .buttonStyle(.bordered)
    }
}

private struct FirstAidRecordControls: View {
    let context: FirstAidResultContext
    let target: RepeatDiagnosisTarget
    let action: RecordableFirstAidAction
    let summary: String

    @State private var pending: FirstAidRecordCommand?
    @State private var busy = true
    @State private var failed = false
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: summary)
            Link("First-aid source", destination: action.source.url)
                .accessibilityIdentifier("analysis.firstAid.source")
            if busy {
                ProgressView()
            } else if let pending {
                Text("Soil check pending sync.").accessibilityIdentifier("analysis.firstAid.pending")
                if pending.jobId == action.jobId {
                    Button("Retry soil check") { Task { await submit(pending) } }
                        .accessibilityIdentifier("analysis.firstAid.retry")
                }
            } else if failed {
                Text("Couldn’t record the soil check.")
            } else {
                Button("Record soil check") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("analysis.firstAid.record")
            }
        }
        .task {
            do {
                let lease = try await context.connection.collectionLease(expected: context.expected)
                guard let repository = context.connection.repository else { throw SyncWireValidationError.invalidSession }
                pending = try await repository.pendingFirstAidRecord(plantId: action.plantId, context: lease)
            } catch {
                failed = true
            }
            busy = false
        }
        .confirmationDialog("Did you check the soil?", isPresented: $confirming, titleVisibility: .visible) {
            Button("I checked the soil") { Task { await submit(nil) } }
                .accessibilityIdentifier("analysis.firstAid.confirm")
            Button("Cancel", role: .cancel) {}
        }
    }

    private func submit(_ retry: FirstAidRecordCommand?) async {
        guard !busy, !failed, let repository = context.connection.repository else { return }
        busy = true
        defer { busy = false }
        do {
            let lease = try await context.connection.collectionLease(expected: context.expected)
            let command: FirstAidRecordCommand
            if let retry {
                command = retry
            } else {
                command = try await repository.enqueueFirstAidRecord(action, target: target, context: lease)
            }
            pending = command
            let outcome = try await repository.retryFirstAidRecord(command, context: lease)
            guard context.connection.snapshot == context.expected else { return }
            switch outcome {
            case .confirmed:
                context.openJournal()
            case .rejected:
                pending = nil
                failed = true
            case .pending:
                break
            }
        } catch {
            failed = pending == nil
        }
    }
}

struct AnalysisExitButtons: View {
    let model: AnalysisFlowModel
    let polish: Bool
    let returnToPlant: (() -> Void)?

    var body: some View {
        if let returnToPlant {
            Button("Back to plant", action: returnToPlant)
                .accessibilityIdentifier("analysis.back.button")
        } else {
            Button(polish ? "Wstecz" : "Back") { model.returnFromAnalysis() }
                .accessibilityIdentifier("analysis.back.button")
            Button(polish ? "Przejdź do katalogu" : "Open catalogue") { model.showCatalogue() }
                .accessibilityIdentifier("analysis.catalogue.button")
        }
    }
}

/// Shared failure UI also preserves the fail-closed entry without a service.
struct AnalysisUnavailableSection: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore
    var returnToPlant: (() -> Void)? = nil

    private var isPolish: Bool { languageStore.currentLocale == .pl }

    private var failureText: String {
        switch model.analysisError {
        case "analysis.error.provider":
            return isPolish
                ? "Usługa analizy jest chwilowo niedostępna. Spróbuj ponownie."
                : "The analysis provider is temporarily unavailable. Please retry."
        case "analysis.error.timeout":
            return isPolish
                ? "Analiza przekroczyła limit czasu. Spróbuj ponownie z tym samym zdjęciem i odpowiedziami."
                : "The analysis timed out. Retry with the same photo and answers."
        case "analysis.error.expired_terminal":
            return isPolish
                ? "Analiza wygasła. Wróć i wybierz zdjęcie ponownie."
                : "The analysis expired. Go back and choose a photo again."
        case "analysis.error.provider_terminal":
            if returnToPlant != nil { return "The provider could not complete the analysis. Choose a new photo from your plant card." }
            return isPolish
                ? "Usługa analizy nie ukończyła zadania. Wróć do wyboru zdjęcia."
                : "The provider could not complete the analysis. Go back to choose a photo."
        case "analysis.error.quota_registration":
            return isPolish
                ? "Nie można potwierdzić daty rejestracji konta, aby rozpocząć kolejną analizę."
                : "We couldn’t verify your account registration date to start another analysis."
        case "analysis.error.quota_exhausted":
            return isPolish
                ? "Limit analiz zdjęć został wyczerpany."
                : "You’ve reached your photo analysis limit."
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
               model.analysisError != "analysis.error.expired_terminal",
               model.analysisError != "analysis.error.quota_registration",
               model.analysisError != "analysis.error.quota_exhausted" {
                Button(isPolish ? "Spróbuj ponownie" : "Retry") {
                    model.submitAnalysis(locale: languageStore.currentLocale)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("analysis.retry.button")
            }

            AnalysisExitButtons(model: model, polish: isPolish, returnToPlant: returnToPlant)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
