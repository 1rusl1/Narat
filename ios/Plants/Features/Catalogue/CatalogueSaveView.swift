import SwiftUI
import UIKit

private struct CatalogueViewIntent {
    let input: CatalogueInput
    let flowId: UUID
    let operationId: UUID
}

private enum CatalogueViewNotice {
    case invalidInput, unavailable, sessionChanged, nativeCancelled, authenticationFailed
    case configurationMissing, presentationUnavailable
}

/// Read-only recorded values shared by the saved result and collection card.
struct CatalogueSavedConditionsView: View {
    let conditions: PlantConditionCodes
    let polish: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let light = conditions.light {
                Text((polish ? "Światło: " : "Light: ") + lightLabel(light))
                    .accessibilityIdentifier("catalogue.saved.conditions.light")
            }
            if let watering = conditions.watering {
                Text((polish ? "Częstotliwość podlewania: " : "Watering frequency: ") + wateringLabel(watering))
                    .accessibilityIdentifier("catalogue.saved.conditions.watering")
            }
            if let drainage = conditions.drainage {
                Text((polish ? "Drenaż: " : "Drainage: ") + drainageLabel(drainage))
                    .accessibilityIdentifier("catalogue.saved.conditions.drainage")
            }
        }
        .qgCard(padding: 16)
        .font(.subheadline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("catalogue.saved.conditions")
    }

    private func lightLabel(_ light: PlantLightCode) -> String {
        guard polish else { return light.label }
        return switch light {
        case .low: "Słabe światło"
        case .medium: "Umiarkowane światło"
        case .brightIndirect: "Jasne, rozproszone światło"
        case .directSun: "Bezpośrednie słońce"
        case .unknown: "Nieznane"
        }
    }

    private func wateringLabel(_ watering: PlantWateringCode) -> String {
        guard polish else { return watering.label }
        return switch watering {
        case .severalWeekly: "Kilka razy w tygodniu"
        case .weekly: "Raz w tygodniu"
        case .lessOften: "Rzadziej"
        case .frequent: "Częste podlewanie"
        case .moderate: "Umiarkowane podlewanie"
        case .sparse: "Rzadkie podlewanie"
        case .unknown: "Nieznana"
        }
    }

    private func drainageLabel(_ drainage: PlantDrainageCode) -> String {
        guard polish else { return drainage.label }
        return switch drainage {
        case .yes: "Otwory odpływowe"
        case .no: "Brak otworów odpływowych"
        case .unknown: "Nieznany"
        }
    }

}

/// Only the current account may load or render the private image for a canonical card.
@MainActor
struct CataloguePrivatePhotoView: View {
    enum Subject {
        case plant(UUID)
        case observation(UUID)

        var accessibilityId: String {
            switch self {
            case .plant: "catalogue.saved.photo"
            case let .observation(id): "catalogue.saved.firstAid.photo." + id.uuidString.lowercased()
            }
        }
    }
    private struct Read: Equatable {
        let scope: CatalogueSDKSnapshot
        let attempt: Int
    }

    let connection: CatalogueConnection
    let expected: CatalogueSDKSnapshot
    let subject: Subject
    let polish: Bool

    @State private var image: UIImage?
    @State private var loadedScope: CatalogueSDKSnapshot?
    @State private var failed = false
    @State private var attempt = 0

    private var read: Read { Read(scope: expected, attempt: attempt) }

    var body: some View {
        if connection.snapshot == expected {
            Group {
                if let image, loadedScope == expected {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .accessibilityLabel(photoLabel)
                        .accessibilityIdentifier(subject.accessibilityId)
                } else if failed, loadedScope == expected {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "photo").font(.largeTitle)
                            .foregroundStyle(QuietGarden.secondaryText).accessibilityHidden(true)
                        Button(polish ? "Wczytaj zdjęcie ponownie" : "Retry photo") { attempt += 1 }
                            .buttonStyle(QuietGardenSecondaryButtonStyle())
                            .accessibilityIdentifier(subject.accessibilityId + ".retry")
                    }
                    .qgCard()
                } else {
                    ProgressView(polish ? "Wczytywanie zdjęcia…" : "Loading photo…")
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .background(QuietGarden.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
            .task(id: read) { await load(read) }
        }
    }

    private var photoLabel: String {
        switch subject {
        case .plant: polish ? "Twoje zdjęcie rośliny" : "Your plant photo"
        case .observation: "Your observation photo"
        }
    }

    private func load(_ requested: Read) async {
        guard !Task.isCancelled, read == requested else { return }
        loadedScope = nil
        image = nil
        failed = false
        do {
            guard let api = connection.apiClient else { throw CatalogueConnectionUnavailable.configurationMissing }
            let lease = try await connection.collectionLease(expected: requested.scope)
            let bytes: Data
            switch subject {
            case let .plant(id): bytes = try await api.fetchPlantPhoto(plantId: id, context: lease)
            case let .observation(id): bytes = try await api.fetchObservationPhoto(observationId: id, context: lease)
            }
            guard !Task.isCancelled, read == requested, connection.snapshot == requested.scope else { return }
            guard let decoded = UIImage(data: bytes) else { throw URLError(.cannotDecodeContentData) }
            image = decoded
        } catch {
            guard !Task.isCancelled, read == requested, connection.snapshot == requested.scope else { return }
            failed = true
        }
        loadedScope = requested.scope
    }
}

@MainActor
struct CatalogueResumeSelection {
    let speciesSlug: String
    let flowId: UUID
    let identification: CatalogueInput.Identification?
    let diagnosisJobId: UUID?

    init?(_ model: CatalogueSaveModel) {
        guard let input = model.input, let checkpoint = model.checkpoint else { return nil }
        speciesSlug = input.speciesIdentifier
        flowId = checkpoint.flowId
        identification = input.identification
        diagnosisJobId = input.diagnosisJobId
    }
}

enum CatalogueSaveIdentity {
    static func allowsEditingAsNewSave(analysisFlow: UUID?) -> Bool {
        analysisFlow == nil
    }

    static func canRestore(
        selectedSpecies: String, restoredSpecies: String?,
        analysisFlow: UUID?, restoredFlow: UUID?
    ) -> Bool {
        selectedSpecies == restoredSpecies &&
            (analysisFlow == nil || analysisFlow == restoredFlow)
    }
}

/// A nil flow pins the absence of a pointer while an explicit new input is edited.
struct CatalogueSaveBinding: Equatable {
    let scope: CatalogueSDKSnapshot
    let flowId: UUID?

    func matches(scope: CatalogueSDKSnapshot, flowId: UUID?) -> Bool {
        self.scope == scope && self.flowId == flowId
    }
}

/// Private form state belongs to one actual SDK snapshot, including its event epoch.
@MainActor
struct CatalogueSaveView<SpeciesDetails: View>: View {
    let connection: CatalogueConnection
    let speciesSlug: String
    let displayName: String
    let scientificName: String
    let polish: Bool
    var careReminderLocaleIsCurrent: () -> Bool = { false }
    var restoresResumableSave: Bool = true
    var resumeFlowId: UUID? = nil
    var resumeScope: CatalogueSDKSnapshot? = nil
    var feedbackAnchor: String? = nil
    var onExplicitFeedback: ((CatalogueSDKSnapshot) -> Void)? = nil
    var showsSpeciesHeading: Bool = true
    var analysisSaveIdentity: UUID? = nil
    var identification: CatalogueInput.Identification? = nil
    var diagnosisJobId: UUID? = nil
    var expectedPhotoId: UUID? = nil
    var openCollection: ((CatalogueSDKSnapshot) -> Void)? = nil
    @Binding var selectionLocked: Bool
    @ViewBuilder let speciesDetails: () -> SpeciesDetails

    @State private var scope: CatalogueSDKSnapshot?
    @State private var model: CatalogueSaveModel?
    @State private var intent: CatalogueViewIntent?
    @State private var name = ""
    @State private var previousFlow: UUID?
    @State private var notice: CatalogueViewNotice?
    @State private var restoreFailed = false
    @State private var preparedNewIntent = false
    @State private var saveBinding: CatalogueSaveBinding?
    @State private var journalAllowsNewIntent = false
    @State private var working = false
    @State private var nativeInFlight = false
    @State private var active = false
    @State private var revision = 0
    @State private var work: Task<Void, Never>?
    @State private var presenter: UIViewController?
    @FocusState private var nameFocused: Bool

    private func showsManualWateringActions(_ saved: CatalogueSaveModel) -> Bool {
        !polish && (analysisSaveIdentity != nil || saved.input?.diagnosisJobId != nil || saved.input?.identification != nil)
    }

    private var scopeIsCurrent: Bool {
        guard let scope else { return false }
        return (try? validateSaveBinding(expected: scope)) != nil
    }

    private var speciesIdentifier: String { identification?.taxonId.uuidString.lowercased() ?? speciesSlug }

    private var shouldLockSelection: Bool {
        if working || nativeInFlight || restoreFailed || !scopeIsCurrent { return true }
        guard let model else { return !journalAllowsNewIntent }
        switch model.state {
        case .pending, .busy, .unavailable: return true
        case .saved: return false
        case .ready, .signInRequired, .collectionLimitNotEnqueued: return !journalAllowsNewIntent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if nativeInFlight {
                publicHeading
                ProgressView(polish ? "Logowanie i zapisywanie…" : "Signing in and saving…")
                    .accessibilityIdentifier("catalogue.save.native.busy")
            } else if !scopeIsCurrent {
                publicHeading
                if saveBinding != nil {
                    Text(polish ? "Sesja lub zapis uległy zmianie. Wróć i ponownie otwórz katalog." : "Session or save changed. Go back and reopen the catalogue.")
                        .accessibilityIdentifier("catalogue.save.unavailable")
                } else {
                    Text(polish ? "Sesja uległa zmianie. Wczytaj bieżące konto." : "Session changed. Load the current account.")
                        .accessibilityIdentifier("catalogue.save.unavailable")
                    Button(polish ? "Wczytaj konto" : "Load account") { synchronize(explicit: true) }
                        .accessibilityIdentifier("catalogue.save.restore")
                }
            } else if let model, case .saved = model.state {
                VStack(alignment: .leading, spacing: 12) { savedCard(model) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(operationIdentifier)
                    .id(feedbackAnchor ?? "catalogue.save.feedback")
            } else {
                publicHeading
                speciesDetails()
                VStack(alignment: .leading, spacing: 12) {
                    if let notice { noticeText(notice) }
                    if restoreFailed {
                        Text(polish ? "Nie udało się przywrócić zapisu." : "Couldn’t restore your save.")
                            .accessibilityIdentifier("catalogue.save.unavailable")
                        Button(polish ? "Spróbuj ponownie" : "Try again") { synchronize(explicit: true) }
                            .accessibilityIdentifier("catalogue.save.restore")
                    } else {
                        saveForm
                    }
                }
                .id(feedbackAnchor ?? "catalogue.save.feedback")
            }
        }
        .qgScreen()
        .buttonStyle(QuietGardenSecondaryButtonStyle())
        .background {
            CatalogueWindowPresenter(controller: $presenter)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
#if DEBUG
        .modifier(ResultSavePresentationFixtureModifier(
            connection: connection, polish: polish, enabled: analysisSaveIdentity == nil,
            openCollection: openCollection
        ))
#endif
        .onAppear {
            active = true
            synchronize()
        }
        .onChange(of: connection.snapshot) { _, current in
            // The native helper alone reconciles its intentional SDK transition.
            guard !nativeInFlight, current != scope else { return }
            synchronize()
        }
        .onChange(of: connection.lastDeletedPlant) { _, deleted in
            guard let deleted, scopeIsCurrent, case let .saved(confirmation) = model?.state,
                  confirmation.receipt.plantId == deleted else { return }
            synchronize()
        }
        .onChange(of: shouldLockSelection, initial: true) { _, locked in
            selectionLocked = locked
        }
        .onDisappear {
            active = false
            revision += 1
            work?.cancel()
            model?.cancel()
            work = nil
            model = nil
            intent = nil
            name = ""
            previousFlow = nil
            notice = nil
            scope = nil
            working = false
            nativeInFlight = false
            selectionLocked = false
        }
    }

    @ViewBuilder
    private var publicHeading: some View {
        if showsSpeciesHeading {
            VStack(alignment: .leading) {
                Text(displayName).font(.largeTitle.weight(.semibold))
                Text(scientificName).italic()
                    .accessibilityIdentifier("catalogue.selected.scientific")
            }
        }
    }

    private var formName: String {
        if let model { return model.input?.personalName ?? "" }
        return intent?.input.personalName ?? name
    }

    private var operationIdentifier: String {
        guard let envelope = model?.envelope else { return "catalogue.save.form" }
        return "catalogue.save.operation." + envelope.operationId.uuidString.lowercased()
    }

    private var saveForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(polish ? "Zapisz w kolekcji" : "Save to collection").qgSectionTitle()
            Text(polish ? "Nazwa rośliny (opcjonalnie)" : "Plant name (optional)")
            if model == nil || model?.input != nil {
                TextField(
                    polish ? "Nazwa rośliny (opcjonalnie)" : "Plant name (optional)",
                    text: Binding(
                        get: { formName },
                        set: { if !working, model == nil, intent == nil, scopeIsCurrent { name = $0 } }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { nameFocused = false }
                .disabled(working || model != nil || intent != nil)
                .accessibilityIdentifier("catalogue.save.name")
            }
            if let model {
                saveControls(model)
            } else {
                Button(polish ? "Zapisz roślinę" : "Save plant") { save() }
                    .buttonStyle(QuietGardenPrimaryButtonStyle())
                    .disabled(working)
                    .accessibilityIdentifier("catalogue.save.submit")
                if intent != nil {
                    editButton
                }
            }
            if working && !nativeInFlight { ProgressView() }
        }
        .qgCard(padding: 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(operationIdentifier)
    }

    @ViewBuilder
    private func saveControls(_ model: CatalogueSaveModel) -> some View {
        switch model.state {
        case .ready:
            retrySaveButton
            editButton
        case .busy:
            Text(polish ? "Zapisywanie…" : "Saving…")
                .accessibilityIdentifier("catalogue.save.busy")
        case .signInRequired:
            Text(polish ? "Zaloguj się, aby zapisać wybraną roślinę." : "Sign in to save your chosen plant.")
                .accessibilityIdentifier("catalogue.save.signInRequired")
            Text(polish
                 ? "Pierwsze logowanie tworzy konto Narat. Po zalogowaniu kontynuujemy zapisywanie tej rośliny z wybranymi danymi."
                 : "First sign-in creates your Narat account. After sign-in, we continue saving this plant with your chosen details.")
            if connection.accountProviders.isEmpty {
                Text(polish
                     ? "Logowanie jest teraz niedostępne. Spróbuj później, wróć lub zmień wybrane dane."
                     : "Sign-in is unavailable right now. Try again later, go back or edit your choices.")
            } else if presenter?.viewIfLoaded?.window == nil {
                Text(polish
                     ? "Przygotowywanie logowania… Poczekaj chwilę lub wróć i spróbuj ponownie."
                     : "Preparing sign-in… Wait a moment or go back and try again.")
            }
            if connection.accountProviders.contains(.apple) {
                Button(polish ? "Kontynuuj z Apple" : "Continue with Apple") { signIn(.apple) }
                    .accessibilityIdentifier("catalogue.save.apple")
                    .disabled(working || presenter?.viewIfLoaded?.window == nil)
            }
            if connection.accountProviders.contains(.google) {
                Button(polish ? "Kontynuuj z Google" : "Continue with Google") { signIn(.google) }
                    .accessibilityIdentifier("catalogue.save.google")
                    .disabled(working || presenter?.viewIfLoaded?.window == nil)
            }
            editButton
        case .pending:
            if model.pendingAPIError?.error.code == "COLLECTION_LIMIT_REACHED" {
                Text(polish
                     ? "Serwer odrzucił zapis: limit kolekcji został osiągnięty. Roślina nie jest zapisana."
                     : "The server rejected this save: collection limit reached. The plant is not saved.")
                    .accessibilityIdentifier("catalogue.save.serverLimit")
            } else {
                Text(model.pendingAPIError?.error.code == "INTERNAL_ERROR"
                     ? (polish ? "Usługa nie potwierdziła zapisu. Zapis oczekuje na ponowienie." : "The service couldn’t confirm the save. It is pending a retry.")
                     : (polish ? "Oczekuje na zapis. Nie potwierdzono jeszcze zapisania rośliny." : "Save pending. The plant has not been confirmed saved yet."))
                    .accessibilityIdentifier("catalogue.save.pending")
            }
            retrySaveButton
        case .collectionLimitNotEnqueued:
            Text(polish
                 ? "Bezpłatna kolekcja mieści 3 rośliny. Nie wysłano nowej rośliny."
                 : "The free collection holds 3 plants. This plant was not submitted.")
                .accessibilityIdentifier("catalogue.save.limit")
            retrySaveButton
            editButton
        case let .unavailable(reason):
            Text(reason == .sessionChanged
                 ? (polish ? "Sesja uległa zmianie." : "Session changed.")
                 : (polish ? "Zapis jest niedostępny. Nie potwierdzono zapisania rośliny." : "Save unavailable. The plant has not been confirmed saved."))
                .accessibilityIdentifier("catalogue.save.unavailable")
            if reason == .storageOrServiceUnavailable {
                // Queue truth may be unknown after a storage failure: keep this operation.
                retrySaveButton
            } else {
                Button(polish ? "Przywróć zapis" : "Restore save") { synchronize(explicit: true) }
                    .accessibilityIdentifier("catalogue.save.restore")
            }
        case .saved:
            EmptyView()
        }
    }

    private var retrySaveButton: some View {
        Button(polish ? "Ponów ten sam zapis" : "Retry this save") { save() }
            .disabled(working)
            .accessibilityIdentifier("catalogue.save.retry")
    }

    @ViewBuilder
    private var editButton: some View {
        if CatalogueSaveIdentity.allowsEditingAsNewSave(analysisFlow: analysisSaveIdentity) {
        Button(polish ? "Zmień dane rośliny" : "Edit plant details") { editAsNewIntent() }
            .disabled(working || !journalAllowsNewIntent)
            .accessibilityIdentifier("catalogue.save.edit")
        }
    }

    @ViewBuilder
    private func savedCard(_ model: CatalogueSaveModel) -> some View {
        // No receipt or captured private summary is passed to a destination.
        Text(polish ? "Roślina zapisana" : "Plant saved").font(.headline)
            .accessibilityIdentifier("catalogue.save.saved")
        if let summary = model.cardSummary, expectedPhotoId == nil || expectedPhotoId == summary.mainPhotoId {
            let selected = identification.map { $0.taxonId == summary.taxonId } ?? (summary.speciesSlug == speciesSlug)
            VStack(alignment: .leading, spacing: 12) {
                Text(summary.personalName ?? (polish ? "Roślina" : "Plant")).font(.title)
                    .accessibilityIdentifier("catalogue.saved.name")
                Text(selected ? displayName : (summary.speciesSlug ?? ""))
                    .accessibilityIdentifier("catalogue.saved.species")
                if selected, !scientificName.isEmpty {
                    Text(scientificName).italic()
                        .accessibilityIdentifier("catalogue.selected.scientific")
                }
                if let conditions = model.diagnosisConditions {
                    CatalogueSavedConditionsView(conditions: conditions, polish: polish)
                }
                if let photo = summary.mainPhotoId, let scope {
                    CataloguePrivatePhotoView(connection: connection, expected: scope, subject: .plant(summary.id), polish: polish)
                        .id(photo)
                }
                if showsManualWateringActions(model) {
                    careRecommendation(model)
                        .task(id: summary.id) { await model.loadCareRecommendation() }
                    wateringHistory(model)
                }
                if let openCollection, let scope, canOpenCollection(model, scope: scope) {
                    Button(polish ? "Moje rośliny" : "My plants") {
                        guard canOpenCollection(model, scope: scope) else { return }
                        openCollection(scope)
                    }
                    .accessibilityIdentifier("catalogue.saved.collection")
                }
                if selected { speciesDetails() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("catalogue.saved.card." + summary.id.uuidString.lowercased())
        } else {
            switch model.cardState {
            case .idle, .loading:
                ProgressView(polish ? "Wczytywanie szczegółów…" : "Loading details…")
            case .unavailable:
                Text(polish ? "Roślina jest zapisana. Szczegóły są niedostępne." : "Your plant is saved. Details are unavailable.")
                    .accessibilityIdentifier("catalogue.saved.detailsUnavailable")
                Button(polish ? "Wczytaj szczegóły ponownie" : "Retry details") { loadDetails(model) }
                    .disabled(working)
                    .accessibilityIdentifier("catalogue.saved.retry")
            case .loaded:
                Text(polish ? "Nie udało się potwierdzić zdjęcia." : "Couldn’t verify the saved photo.")
                    .accessibilityIdentifier("catalogue.saved.photo.error")
            }
        }
    }

    private func canOpenCollection(_ model: CatalogueSaveModel, scope: CatalogueSDKSnapshot) -> Bool {
        guard connection.snapshot == scope, !scope.isAnonymous,
              case let .saved(confirmation) = model.state,
              confirmation.ownerId == scope.session.userId,
              let summary = model.cardSummary,
              summary.id == confirmation.receipt.plantId,
              summary.mainPhotoId == confirmation.receipt.photoId,
              expectedPhotoId == nil || expectedPhotoId == summary.mainPhotoId else { return false }
        return true
    }

    @ViewBuilder
    private func careRecommendation(_ model: CatalogueSaveModel) -> some View {
        switch model.careRecommendationState {
        case .idle, .loading:
            ProgressView("Loading care recommendation…")
        case let .available(recommendation):
            PlantCareRecommendationContent(recommendation: recommendation)
        case .unavailable:
            Text("No verified care recommendation is available.")
                .qgNotice(.warning)
                .accessibilityIdentifier("catalogue.saved.care.unavailable")
        case .failed:
            Button("Retry care recommendation") {
                Task { await model.loadCareRecommendation(retry: true) }
            }
            .accessibilityIdentifier("catalogue.saved.care.retry")
        }
    }

    @ViewBuilder
    private func wateringHistory(_ model: CatalogueSaveModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manual watering history").font(.headline)
            switch model.wateringHistoryState {
            case .idle, .loading:
                ProgressView("Loading watering history…")
                    .accessibilityIdentifier("catalogue.saved.history.loading")
            case let .loaded(entries):
                if showsManualWateringActions(model) { wateringControls(model) }
                if entries.isEmpty {
                    Text("No manual watering recorded.")
                        .accessibilityIdentifier("catalogue.saved.history.empty")
                } else {
                    ForEach(entries) { entry in
                        HStack {
                            Text(entry.occurredLocalDate)
                            Text(entry.state == "voided" ? "Undone" : "Active")
                            if showsManualWateringActions(model), entry.state == "active",
                               model.manualWateringState == .ready {
                                Button("Undo") { watering(model, entryId: entry.id) }
                                    .accessibilityIdentifier("catalogue.care.undo." + entry.id.uuidString.lowercased())
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("catalogue.saved.history." + entry.id.uuidString.lowercased())
                    }
                }
            case .unavailable:
                Text("Watering history is unavailable.")
                    .accessibilityIdentifier("catalogue.saved.history.unavailable")
                Button("Retry watering history") { loadDetails(model) }
                    .disabled(working)
                    .accessibilityIdentifier("catalogue.saved.history.retry")
            }
        }
        .qgCard(padding: 16)
    }

    @ViewBuilder
    private func wateringControls(_ model: CatalogueSaveModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.manualWateringState {
            case .ready:
                Button("Record watering") { watering(model) }
                    .accessibilityIdentifier("catalogue.care.record")
            case .saving:
                ProgressView("Saving watering history…")
                    .accessibilityIdentifier("catalogue.care.saving")
            case .pending:
                Text("Watering history change pending.")
                    .accessibilityIdentifier("catalogue.care.pending")
                Button("Retry watering change") { watering(model, retry: true) }
                    .accessibilityIdentifier("catalogue.care.retry")
            case .unavailable:
                Button("Reload watering history") { loadDetails(model) }
                    .accessibilityIdentifier("catalogue.care.refresh")
            }
            }
            .qgCard()
    }

    private func noticeText(_ notice: CatalogueViewNotice) -> some View {
        let text: String
        switch notice {
        case .invalidInput:
            text = polish ? "Sprawdź nazwę rośliny i spróbuj ponownie." : "Check the plant name and try again."
        case .unavailable:
            text = polish ? "Nie udało się zapisać. Spróbuj ponownie." : "Couldn’t save. Try again."
        case .sessionChanged:
            text = polish ? "Sesja uległa zmianie. Wczytaj bieżące konto." : "Session changed. Load the current account."
        case .nativeCancelled:
            text = polish ? "Logowanie anulowane. Wybrane dane zostały zachowane." : "Sign-in cancelled. Your chosen input has been retained."
        case .authenticationFailed:
            text = polish ? "Logowanie nie powiodło się. Spróbuj ponownie lub wróć." : "Sign-in failed. Try again or go back."
        case .configurationMissing:
            text = polish ? "Ta metoda logowania jest niedostępna. Wybierz inną, spróbuj później lub wróć. Wybrane dane pozostają zachowane." : "This sign-in method is unavailable. Choose another, try later or go back. Your choices are kept."
        case .presentationUnavailable:
            text = polish ? "Nie udało się otworzyć logowania. Spróbuj ponownie lub wróć. Wybrane dane pozostają zachowane." : "Couldn’t open sign-in. Try again or go back. Your choices are kept."
        }
        return Text(text).qgNotice(.warning).accessibilityIdentifier("catalogue.save.notice")
    }

    private func validateSaveBinding(expected: CatalogueSDKSnapshot) throws {
        guard let saveBinding, saveBinding.scope == expected, connection.snapshot == expected,
              saveBinding.matches(scope: expected, flowId: try connection.resumableFlow(expected: expected)) else {
            throw CatalogueSaveUnavailable.sessionChanged
        }
    }

    private func requestIsCurrent(_ ticket: Int, _ expected: CatalogueSDKSnapshot) -> Bool {
        active && revision == ticket && !Task.isCancelled && scope == expected && connection.snapshot == expected
    }

    private func isCurrent(_ ticket: Int, _ expected: CatalogueSDKSnapshot) -> Bool {
        requestIsCurrent(ticket, expected) && (try? validateSaveBinding(expected: expected)) != nil
    }

    private func revealFeedback(ticket: Int, locale: Bool) {
        guard active, revision == ticket, !Task.isCancelled, polish == locale,
              let expected = scope, connection.snapshot == expected else { return }
        onExplicitFeedback?(expected)
    }

    private func synchronize(explicit: Bool = false) {
        guard active, !nativeInFlight else { return }
        revision += 1
        let ticket = revision
        work?.cancel()
        model?.cancel()
        model = nil
        intent = nil
        name = ""
        previousFlow = nil
        notice = nil
        restoreFailed = false
        journalAllowsNewIntent = false
        scope = connection.snapshot
        guard let expected = scope else { working = false; return }
        let requestedPolish = polish
        let locale = polish ? "pl" : "en"
        let localeIsCurrent = careReminderLocaleIsCurrent
        working = true
        work = Task { @MainActor in
            defer {
                if revision == ticket { working = false; work = nil }
                if explicit { revealFeedback(ticket: ticket, locale: requestedPolish) }
            }
            do {
                // Seed once. Passive SDK events and retries never replace this binding.
                if saveBinding == nil {
                    if let resumeScope, resumeScope != expected {
                        throw CatalogueSaveUnavailable.sessionChanged
                    }
                    let flow = try connection.resumableFlow(expected: expected)
                    if let resumeFlowId, flow != resumeFlowId {
                        throw CatalogueSaveUnavailable.sessionChanged
                    }
                    saveBinding = CatalogueSaveBinding(scope: expected, flowId: flow)
                }
                try validateSaveBinding(expected: expected)
                previousFlow = saveBinding?.flowId
                if let flow = previousFlow {
                    let result = await connection.restoreModel(
                        ownerId: expected.session.userId, flowId: flow, expected: expected
                    )
                    guard isCurrent(ticket, expected) else { return }
                    guard try connection.resumableFlow(expected: expected) == flow else {
                        throw CatalogueSaveUnavailable.sessionChanged
                    }
                    switch result {
                    case let .restored(restored):
                        if (restoresResumableSave || preparedNewIntent), CatalogueSaveIdentity.canRestore(
                            selectedSpecies: speciesIdentifier, restoredSpecies: restored.input?.speciesIdentifier,
                            analysisFlow: analysisSaveIdentity, restoredFlow: restored.checkpoint?.flowId
                        ), restored.input?.identification == identification {
                            model = restored
                            switch restored.state {
                            case .ready, .collectionLimitNotEnqueued:
                                journalAllowsNewIntent = true
                            case .signInRequired:
                                // Anonymous restoration does not expose its journal phase.
                                do {
                                    _ = try await replaceableFlow(expected: expected)
                                    guard isCurrent(ticket, expected) else { return }
                                    journalAllowsNewIntent = true
                                } catch {
                                    guard isCurrent(ticket, expected) else { return }
                                    journalAllowsNewIntent = false
                                }
                            default: break
                            }
                            await loadIfSaved(restored, completion: readCompletion(restored,
                                expected: expected, ticket: ticket, locale: locale, localeIsCurrent: localeIsCurrent))
                        } else {
                            // An undisplayed flow still owns its pointer until its journal
                            // proves that a different species can start safely.
                            let replaceable = try await replaceableFlow(expected: expected)
                            guard isCurrent(ticket, expected) else { return }
                            if !restoresResumableSave, !preparedNewIntent, let replaceable {
                                guard replaceable == flow else { throw CatalogueSaveUnavailable.sessionChanged }
                                guard try connection.forgetResumableFlow(
                                    ownerId: expected.session.userId, expectedFlowId: replaceable, expected: expected
                                ) else { throw CatalogueSaveUnavailable.sessionChanged }
                                saveBinding = CatalogueSaveBinding(scope: expected, flowId: nil)
                                previousFlow = nil
                            }
                            preparedNewIntent = true
                            journalAllowsNewIntent = true
                        }
                    case .absent:
                        if !restoresResumableSave, !preparedNewIntent {
                            guard try connection.forgetResumableFlow(
                                ownerId: expected.session.userId, expectedFlowId: flow, expected: expected
                            ) else { throw CatalogueSaveUnavailable.sessionChanged }
                            saveBinding = CatalogueSaveBinding(scope: expected, flowId: nil)
                            previousFlow = nil
                        }
                        preparedNewIntent = true
                        journalAllowsNewIntent = true
                    case .unavailable: restoreFailed = true
                    }
                } else {
                    preparedNewIntent = true
                    journalAllowsNewIntent = true
                }
            } catch {
                if isCurrent(ticket, expected) { restoreFailed = true }
            }
        }
    }

    /// Restoration alone can hide queue truth (for example for anonymous owners).
    /// Only an actual journal read may authorize replacing the current-owner pointer.
    private func replaceableFlow(expected: CatalogueSDKSnapshot) async throws -> UUID? {
        try validateSaveBinding(expected: expected)
        guard let flow = saveBinding?.flowId else { return nil }
        let result = await connection.restoreModel(
            ownerId: expected.session.userId, flowId: flow, expected: expected
        )
        try validateSaveBinding(expected: expected)
        switch result {
        case .absent:
            return flow
        case let .restored(restored):
            guard let envelope = restored.envelope,
                  let store = connection.store, let api = connection.apiClient else {
                throw CatalogueSaveUnavailable.storageOrServiceUnavailable
            }
            let context = try await api.captureSyncContext(ownerId: expected.session.userId)
            try validateSaveBinding(expected: expected)
            guard context.session == expected.session else {
                throw CatalogueSaveUnavailable.sessionChanged
            }
            let journal = try await store.catalogueCreateJournal(
                envelope, mode: .checkOnly, context: context, authority: api.syncAuthority
            )
            try validateSaveBinding(expected: expected)
            switch journal {
            case .absent, .confirmed: return flow
            case .pending, .collectionLimitNotEnqueued:
                throw CatalogueSaveUnavailable.storageOrServiceUnavailable
            }
        case let .unavailable(reason):
            throw reason
        }
    }

    private func completion(
        expected: CatalogueSDKSnapshot, ticket: Int, locale: String,
        localeIsCurrent: @escaping () -> Bool
    ) -> CatalogueSaveCompletion {
        CatalogueSaveCompletion(
            isCurrent: { active && revision == ticket && connection.snapshot == expected && localeIsCurrent() },
            publish: {
                connection.publishExplicitCareRead(expected: expected, locale: locale,
                    isLocaleCurrent: { active && revision == ticket && localeIsCurrent() })
            })
    }

    private func readCompletion(
        _ target: CatalogueSaveModel, expected: CatalogueSDKSnapshot, ticket: Int,
        locale: String, localeIsCurrent: @escaping () -> Bool
    ) -> CatalogueCardReadCompletion {
        CatalogueCardReadCompletion(
            isCurrent: { isCurrent(ticket, expected) && model === target && localeIsCurrent() },
            publish: {
                connection.publishExplicitCareRead(expected: expected, locale: locale,
                    isLocaleCurrent: { isCurrent(ticket, expected) && model === target && localeIsCurrent() })
            })
    }

    private func watering(_ target: CatalogueSaveModel, entryId: UUID? = nil, retry: Bool = false) {
        guard !working, scopeIsCurrent, let expected = scope else { return }
        let done = completion(expected: expected, ticket: revision, locale: polish ? "pl" : "en",
                              localeIsCurrent: careReminderLocaleIsCurrent)
        Task {
            if retry { await target.retryManualWatering(completion: done) }
            else if let entryId { await target.undoWatering(entryId: entryId, completion: done) }
            else { await target.recordWatering(completion: done) }
        }
    }

    private func save() {
        guard !working, !restoreFailed, scopeIsCurrent, let expected = scope else { return }
        let requestedPolish = polish
        let locale = polish ? "pl" : "en"
        let localeIsCurrent = careReminderLocaleIsCurrent
        nameFocused = false
        if model == nil && intent == nil {
            let personalName = name.isEmpty ? nil : name
            let input: CatalogueInput
            if let identification {
                input = CatalogueInput(identification: identification, personalName: personalName)
            } else if let diagnosisJobId {
                input = CatalogueInput(diagnosisJobId: diagnosisJobId, speciesSlug: speciesSlug, personalName: personalName)
            } else {
                input = CatalogueInput(speciesSlug: speciesSlug, personalName: personalName)
            }
            let chosen = CatalogueViewIntent(input: input, flowId: analysisSaveIdentity ?? UUID(), operationId: UUID())
            do { _ = try input.makeEnvelope(operationId: chosen.operationId) }
            catch {
                notice = .invalidInput
                revealFeedback(ticket: revision, locale: requestedPolish)
                return
            }
            intent = chosen
        }
        let ticket = revision
        working = true
        notice = nil
        work = Task { @MainActor in
            defer {
                if revision == ticket { working = false; work = nil }
                revealFeedback(ticket: ticket, locale: requestedPolish)
            }
            do {
                let target: CatalogueSaveModel
                if let model {
                    target = model
                } else if let intent {
                    do { _ = try await replaceableFlow(expected: expected) }
                    catch {
                        if isCurrent(ticket, expected) { restoreFailed = true }
                        throw error
                    }
                    guard isCurrent(ticket, expected) else { return }
                    target = try await connection.makeModel(
                        input: intent.input, flowId: intent.flowId,
                        operationId: intent.operationId, expected: expected
                    )
                } else { return }
                guard isCurrent(ticket, expected) else { return }
                model = target
                if let pointed = try connection.resumableFlow(expected: expected),
                   pointed != target.checkpoint?.flowId {
                    do { _ = try await replaceableFlow(expected: expected) }
                    catch {
                        if isCurrent(ticket, expected) { restoreFailed = true }
                        throw error
                    }
                    guard isCurrent(ticket, expected) else { return }
                }
                try validateSaveBinding(expected: expected)
                if let checkpoint = target.checkpoint, checkpoint.flowId == saveBinding?.flowId {
                    // A retry already owns its durable pointer; never republish it over a newer flow.
                    previousFlow = checkpoint.flowId
                } else {
                    // Only this explicit input may publish and bind a newly prepared checkpoint.
                    guard let intent else { throw CatalogueSaveUnavailable.sessionChanged }
                    let replacingFlow = saveBinding?.flowId
                    let checkpoint = try await connection.rememberModel(
                        target, expected: expected, replacingFlow: replacingFlow
                    )
                    guard requestIsCurrent(ticket, expected),
                          checkpoint.flowId == intent.flowId, checkpoint.operationId == intent.operationId,
                          try connection.resumableFlow(expected: expected) == checkpoint.flowId else {
                        throw CatalogueSaveUnavailable.sessionChanged
                    }
                    saveBinding = CatalogueSaveBinding(scope: expected, flowId: checkpoint.flowId)
                    previousFlow = checkpoint.flowId
                }
                guard isCurrent(ticket, expected) else { return }
                let done = localeIsCurrent() ? completion(expected: expected, ticket: ticket,
                    locale: locale, localeIsCurrent: localeIsCurrent) : nil
                await target.save(completion: done, includeManualWateringActions: showsManualWateringActions(target))
                guard isCurrent(ticket, expected) else { return }
                if done == nil { await loadIfSaved(target) }
            } catch {
                if isCurrent(ticket, expected) { notice = .unavailable }
            }
        }
    }

    private func editAsNewIntent() {
        // A diagnosis owns one immutable checkpoint and retries that exact save.
        guard CatalogueSaveIdentity.allowsEditingAsNewSave(analysisFlow: analysisSaveIdentity) else { return }
        guard !working, !restoreFailed, scopeIsCurrent, let expected = scope else { return }
        if let model {
            switch model.state {
            case .ready, .signInRequired, .collectionLimitNotEnqueued: break
            default: return
            }
        }
        let editableName = model?.input?.personalName ?? intent?.input.personalName ?? name
        let ticket = revision
        working = true
        work = Task { @MainActor in
            defer { if revision == ticket { working = false; work = nil } }
            do {
                let flow = try await replaceableFlow(expected: expected)
                guard isCurrent(ticket, expected) else { return }
                if let flow {
                    guard try connection.forgetResumableFlow(
                        ownerId: expected.session.userId, expectedFlowId: flow, expected: expected
                    ) else { throw CatalogueSaveUnavailable.sessionChanged }
                }
                // Retire the old selection only after the exact pointer was forgotten.
                saveBinding = CatalogueSaveBinding(scope: expected, flowId: nil)
                preparedNewIntent = true
                guard isCurrent(ticket, expected) else { return }
                model?.cancel()
                model = nil
                intent = nil
                previousFlow = nil
                name = editableName
                notice = nil
            } catch {
                if isCurrent(ticket, expected) { restoreFailed = true; notice = .unavailable }
            }
        }
    }

    private func authenticationNotice(_ failure: NativeAuthFailure) -> CatalogueViewNotice {
        switch failure {
        case .configurationMissing: .configurationMissing
        case .presentationUnavailable: .presentationUnavailable
        default: .authenticationFailed
        }
    }

    private func signIn(_ provider: NativeAuthProvider) {
        guard !working, scopeIsCurrent, let expected = scope, let original = model,
              case .signInRequired = original.state,
              let presenter, presenter.viewIfLoaded?.window != nil else { return }
        let requestedPolish = polish
        let ticket = revision
        let locale = polish ? "pl" : "en"
        let localeIsCurrent = careReminderLocaleIsCurrent
        working = true
        nativeInFlight = true
        let includeManual = showsManualWateringActions(original)
        notice = nil
        work = Task { @MainActor in
            defer {
                if revision == ticket {
                    if connection.snapshot != scope { clearPrivateState() }
                    working = false
                    nativeInFlight = false
                    work = nil
                }
                revealFeedback(ticket: ticket, locale: requestedPolish)
            }
            do {
                let prepared = try await original.checkpointInput()
                guard isCurrent(ticket, expected), model === original,
                      prepared.ownerId == expected.session.userId,
                      prepared.flowId == saveBinding?.flowId, original.checkpoint == prepared else {
                    throw CatalogueSaveUnavailable.sessionChanged
                }
                let outcome = await connection.signInAndSave(original, with: provider, presenting: presenter,
                    includeManualWateringActions: includeManual,
                    completion: { expected in
                        guard localeIsCurrent() else { return nil }
                        return completion(expected: expected, ticket: ticket, locale: locale,
                                          localeIsCurrent: localeIsCurrent)
                    })
                guard active, revision == ticket, !Task.isCancelled else { return }
                switch outcome {
                case let .continued(verified):
                    try await adopt(verified, original: original, prepared: prepared, originalScope: expected,
                                    ticket: ticket, locale: locale, localeIsCurrent: localeIsCurrent)
                case let .inputRetained(verified, reason):
                    try await adopt(verified, original: original, prepared: prepared, originalScope: expected,
                                    ticket: ticket, locale: locale, localeIsCurrent: localeIsCurrent)
                    switch reason {
                    case .cancelled: notice = .nativeCancelled
                    case let .authenticationFailed(failure): notice = authenticationNotice(failure)
                    }
                case .busy:
                    notice = .authenticationFailed
                case let .unavailable(reason):
                    if connection.snapshot == expected, original.input != nil {
                        if !connection.accountProviders.contains(provider) {
                            notice = .configurationMissing
                        } else {
                            notice = reason == .cancelled ? .nativeCancelled : .authenticationFailed
                        }
                    } else {
                        clearPrivateState()
                    }
                }
            } catch {
                guard active, revision == ticket, !Task.isCancelled else { return }
                if connection.snapshot == expected, original.input != nil {
                    notice = (error as? NativeAuthFailure).map { authenticationNotice($0) } ?? .authenticationFailed
                } else {
                    clearPrivateState()
                }
            }
        }
    }

    private func adopt(
        _ verified: CatalogueSaveModel, original: CatalogueSaveModel,
        prepared: CatalogueInputCheckpointSnapshot, originalScope: CatalogueSDKSnapshot,
        ticket: Int, locale: String, localeIsCurrent: @escaping () -> Bool
    ) async throws {
        // Only a typed native outcome may advance the scope of the captured logical save.
        guard nativeInFlight, scope == originalScope, model === original,
              saveBinding?.matches(scope: originalScope, flowId: prepared.flowId) == true,
              prepared.ownerId == originalScope.session.userId else {
            throw CatalogueSaveUnavailable.sessionChanged
        }
        let expected = try await connection.sessionSnapshot()
        guard active, revision == ticket, !Task.isCancelled, nativeInFlight,
              scope == originalScope, model === original,
              saveBinding?.matches(scope: originalScope, flowId: prepared.flowId) == true,
              let store = connection.store, let api = connection.apiClient else {
            throw CatalogueSaveUnavailable.sessionChanged
        }
        try verified.validateScope(
            of: store, apiClient: api, session: expected.session, isAnonymous: expected.isAnonymous
        )
        guard connection.snapshot == expected, verified.input?.speciesIdentifier == speciesIdentifier,
              verified.input?.identification == identification,
              let checkpoint = verified.checkpoint, checkpoint.ownerId == expected.session.userId,
              checkpoint.flowId == prepared.flowId, checkpoint.operationId == prepared.operationId,
              checkpoint.envelope.payloadJSON.utf8.elementsEqual(prepared.envelope.payloadJSON.utf8),
              try connection.resumableFlow(expected: expected) == checkpoint.flowId else {
            throw CatalogueSaveUnavailable.sessionChanged
        }
        if let old = model, old !== verified { old.cancel() }
        saveBinding = CatalogueSaveBinding(scope: expected, flowId: checkpoint.flowId)
        scope = expected
        model = verified
        intent = nil
        name = ""
        previousFlow = verified.checkpoint?.flowId
        if verified.cardState == .idle {
            await loadIfSaved(verified, completion: readCompletion(verified,
                expected: expected, ticket: ticket, locale: locale, localeIsCurrent: localeIsCurrent))
        }
    }

    private func clearPrivateState() {
        model?.cancel()
        model = nil
        intent = nil
        name = ""
        previousFlow = nil
        scope = nil
        notice = .sessionChanged
    }

    private func loadIfSaved(_ target: CatalogueSaveModel, completion: CatalogueCardReadCompletion? = nil) async {
        guard case .saved = target.state else { return }
        if let completion {
            await target.readCard(includeManualWateringActions: showsManualWateringActions(target), completion: completion)
        } else {
            await target.loadCard(includeManualWateringActions: showsManualWateringActions(target))
        }
    }

    private func loadDetails(_ target: CatalogueSaveModel) {
        guard !working, scopeIsCurrent, let expected = scope, model === target else { return }
        let requestedPolish = polish
        let ticket = revision
        let done = readCompletion(target, expected: expected, ticket: ticket,
            locale: polish ? "pl" : "en", localeIsCurrent: careReminderLocaleIsCurrent)
        working = true
        work = Task { @MainActor in
            defer {
                if revision == ticket { working = false; work = nil }
                revealFeedback(ticket: ticket, locale: requestedPolish)
            }
            await target.readCard(includeManualWateringActions: showsManualWateringActions(target), completion: done)
        }
    }
}

struct PlantCareRecommendationContent: View {
    let recommendation: PlantCareRecommendation
    var showNextCheck = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: recommendation.text)
                .accessibilityIdentifier("catalogue.saved.care.text")
            Link("Verified care source", destination: recommendation.source.url)
                .font(.subheadline).frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("catalogue.saved.care.source")
            if showNextCheck, let check = recommendation.nextCheck {
                Text("Next soil check · \(check.dueOn)")
                    .font(.headline)
                    .accessibilityIdentifier("catalogue.saved.care.next.date")
                Text(verbatim: check.basis)
                    .accessibilityIdentifier("catalogue.saved.care.next.basis")
                Link("Soil check interval source", destination: check.source.url)
                    .font(.subheadline).frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("catalogue.saved.care.next.source")
            }
        }
        .qgCard(padding: 20)
    }
}

/// A mounted controller in the app's real window supplies the native presentation anchor.
@MainActor
struct CatalogueWindowPresenter: UIViewControllerRepresentable {
    @Binding var controller: UIViewController?

    func makeUIViewController(context: Context) -> WindowController {
        let result = WindowController()
        result.didAppear = { controller = $0 }
        return result
    }

    func updateUIViewController(_ uiViewController: WindowController, context: Context) {}

    final class WindowController: UIViewController {
        var didAppear: ((UIViewController) -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if view.window != nil { didAppear?(self) }
        }
    }
}
