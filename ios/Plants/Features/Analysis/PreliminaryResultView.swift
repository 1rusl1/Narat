import SwiftUI
import UIKit

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

/// Owned by the mounted result, including while its picker sheet is presented.
@MainActor
final class IdentificationResultLifetime {
    private(set) var presentation: UUID?
    var task: Task<Void, Never>?
    private var invalidateTicket: (() -> Void)?
    private var visibleAnchors: Set<UUID> = []

    func enter() -> UUID {
        cancelRead()
        visibleAnchors.removeAll()
        let id = UUID()
        presentation = id
        return id
    }

    func isCurrent(_ id: UUID) -> Bool { presentation == id }

    func setVisible(_ visible: Bool, anchor: UUID, presentation id: UUID) {
        guard isCurrent(id) else { return }
        if visible { visibleAnchors.insert(anchor) }
        else {
            visibleAnchors.remove(anchor)
            if visibleAnchors.isEmpty { leave(id) }
        }
    }

    @discardableResult
    func own(_ ticket: IdentificationCorrectionTicket, model: AnalysisFlowModel,
             presentation id: UUID) -> Bool {
        guard isCurrent(id) else { return false }
        cancelRead()
        invalidateTicket = { model.cancelManualCorrection(ticket) }
        return true
    }

    func cancelRead() {
        task?.cancel()
        task = nil
        invalidateTicket?()
        invalidateTicket = nil
    }

    func leave(_ id: UUID) {
        guard isCurrent(id) else { return }
        presentation = nil
        cancelRead()
    }
}

/// Covers both structural removal and a retained host leaving its window.
/// The picker shares presence so covering the result keeps its read alive.
@MainActor
struct IdentificationResultLifetimeAnchor: UIViewRepresentable {
    let lifetime: IdentificationResultLifetime
    var presentation: UUID? = nil

    @MainActor
    final class Coordinator {
        let lifetime: IdentificationResultLifetime
        var presentation: UUID
        let anchor = UUID()
        let isResult: Bool
        init(_ lifetime: IdentificationResultLifetime, presentation: UUID?) {
            self.lifetime = lifetime
            isResult = presentation == nil
            self.presentation = presentation ?? lifetime.enter()
        }
        func setVisible(_ visible: Bool) {
            if visible && isResult && lifetime.presentation == nil {
                presentation = lifetime.enter()
            }
            lifetime.setVisible(visible, anchor: anchor, presentation: presentation)
        }
    }

    @MainActor
    final class PresenceView: UIView {
        var presenceChanged: ((Bool) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            presenceChanged?(window != nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(lifetime, presentation: presentation) }
    func makeUIView(context: Context) -> UIView {
        let view = PresenceView(frame: .zero)
        view.presenceChanged = { [coordinator = context.coordinator] in coordinator.setVisible($0) }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        if coordinator.isResult { coordinator.lifetime.leave(coordinator.presentation) }
        else { coordinator.setVisible(false) }
    }
}

// B2_PHOTO_FIXTURE_BEGIN action_type
#if DEBUG
struct PhotoFixtureActions {
    let arm: (CatalogueSDKSnapshot, SupportedLocale) -> Void
    let removeHost: () -> Void
}
#endif
// B2_PHOTO_FIXTURE_END action_type
public struct PreliminaryResultView: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore
    private var catalogueConnection: CatalogueConnection? = nil
    private var guestActions: GuestIdentificationActions? = nil
    private var openCollection: ((CatalogueSDKSnapshot) -> Void)? = nil
    private var returnToPlant: (() -> Void)? = nil
    private var firstAidContext: FirstAidResultContext? = nil
    // B2_PHOTO_FIXTURE_BEGIN action_value
#if DEBUG
    private var photoFixtureActions: PhotoFixtureActions? = nil

    func withPhotoFixtureActions(_ actions: PhotoFixtureActions?) -> Self {
        var copy = self
        copy.photoFixtureActions = actions
        return copy
    }
#endif
    // B2_PHOTO_FIXTURE_END action_value
    @State private var saveLocked = false
    private struct Correction {
        let id = UUID()
        let connection: CatalogueConnection
        let snapshot: CatalogueSDKSnapshot
        let locale: SupportedLocale
        let ticket: IdentificationCorrectionTicket
        let presentation: UUID
    }
    @State private var correction: Correction?
    @State private var showingCorrection = false
    @State private var correctionRequest: UUID?
    @State private var correctionLifetime = IdentificationResultLifetime()
    @State private var correctionFailed = false

    public init(model: AnalysisFlowModel, languageStore: LanguageStore) {
        self.model = model
        self.languageStore = languageStore
    }

    init(model: AnalysisFlowModel, languageStore: LanguageStore, catalogueConnection: CatalogueConnection?,
         guestActions: GuestIdentificationActions? = nil, returnToPlant: (() -> Void)? = nil,
         firstAidContext: FirstAidResultContext? = nil,
         openCollection: ((CatalogueSDKSnapshot) -> Void)? = nil) {
        self.model = model
        self.languageStore = languageStore
        self.catalogueConnection = catalogueConnection
        self.guestActions = guestActions
        self.returnToPlant = returnToPlant
        self.firstAidContext = firstAidContext
        self.openCollection = openCollection
    }

    private var isPolish: Bool { languageStore.currentLocale == .pl }

    public var body: some View {
        let locale = languageStore.currentLocale
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.isAnalyzing {
                    ProgressView(isPolish ? "Analizowanie zdjęcia" : "Analyzing photo")
                        .frame(maxWidth: .infinity, minHeight: 100)
                        .qgCard()
                        .accessibilityIdentifier("analysis.progress")
                    exitButtons
                } else if model.identificationResult != nil {
                    speciesHeading
                    publishedIdentification
                    if let confirmed = model.confirmedPhotoIdentification {
                        Text(isPolish ? "Gatunek potwierdzony." : "Species confirmed.")
                            .accessibilityIdentifier("analysis.identification.confirmed")
                        if let connection = catalogueConnection, let owner = confirmed.ownerId,
                           let session = connection.snapshot, !session.isAnonymous, session.session.userId == owner,
                           let label = model.selectedIdentificationSpecies?.displayName {
                            CatalogueSaveView(
                                connection: connection, speciesSlug: confirmed.speciesSlug,
                                displayName: label,
                                scientificName: model.selectedIdentificationSpecies?.publishedFacts?.scientificName ?? "",
                                polish: isPolish,
                                careReminderLocaleIsCurrent: { [languageStore, locale] in languageStore.currentLocale == locale },
                                showsSpeciesHeading: false,
                                analysisSaveIdentity: confirmed.jobId,
                                identification: .init(jobId: confirmed.jobId, taxonId: confirmed.taxonId),
                                expectedPhotoId: confirmed.photoAssetId, openCollection: openCollection,
                                selectionLocked: $saveLocked
                            ) { EmptyView() }
                            .id(confirmed.jobId)
                        } else if let guestActions, let session = catalogueConnection?.snapshot,
                                  session.isAnonymous, session.session.userId == confirmed.ownerId {
                            Button(isPolish ? "Zaloguj się, aby zapisać" : "Sign in to save") { guestActions.save(confirmed) }
                                .buttonStyle(QuietGardenPrimaryButtonStyle())
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
                    } else {
                        if canConfirmIdentification {
                            Button(isPolish ? "Potwierdź gatunek" : "Confirm this species") {
                                if let owner = catalogueConnection?.snapshot?.session.userId {
                                    model.confirmPhotoIdentification(expectedOwnerId: owner)
                                } else {
                                    model.confirmPhotoIdentification()
                                }
                            }
                            .buttonStyle(QuietGardenPrimaryButtonStyle())
                            .disabled(identificationBusy)
                            .accessibilityIdentifier("analysis.identification.confirm")
                        }
                        if let connection = catalogueConnection, let expected = connection.snapshot,
                           model.correctionSource?.ownerId == expected.session.userId {
                            Button(model.selectedIdentificationSpecies == nil
                                   ? (isPolish ? "Wybierz gatunek" : "Choose a species")
                                   : (isPolish ? "Wybierz inny gatunek" : "Choose another species")) {
                                openCorrection(connection: connection, expected: expected)
                            }
                            .disabled(identificationBusy)
                            .accessibilityIdentifier("analysis.identification.manual")
                        }
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
                                .qgNotice(.warning)
                                .accessibilityIdentifier("analysis.result.uncertainty")
                        }
                    }
                    if let guidance = explanation.photoGuidance(
                        isInitial: model.repeatDiagnosisTarget == nil
                    ) {
                        Text(verbatim: guidance)
                            .qgNotice(.neutral)
                            .accessibilityIdentifier("analysis.result.photoGuidance")
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
                            .qgCard()
                            .accessibilityIdentifier("analysis.result.evidence")
                        }
                        if let summary = explanation.firstAction {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(isPolish ? "Pierwsze działanie" : "First action")
                                    .font(.headline)
                                Text(verbatim: summary)
                            }
                            .qgCard()
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
                            .buttonStyle(QuietGardenPrimaryButtonStyle())
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
                            displayName: label, scientificName: "", polish: isPolish,
                            careReminderLocaleIsCurrent: { [languageStore, locale] in languageStore.currentLocale == locale },
                            showsSpeciesHeading: false,
                            analysisSaveIdentity: result.jobId, diagnosisJobId: result.jobId,
                            expectedPhotoId: photo.id, openCollection: openCollection,
                            selectionLocked: $saveLocked
                        ) { EmptyView() }
                        .id(result.jobId)
                    }
                    exitButtons
                } else {
                    AnalysisUnavailableSection(
                        model: model, languageStore: languageStore, returnToPlant: returnToPlant,
                        hostOwnsNativeBack: ownsNativeBack
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .qgScreen()
        .buttonStyle(QuietGardenSecondaryButtonStyle())
        .navigationTitle(isPolish ? "Analiza" : "Analysis")
        .toolbar {
            if ownsNativeBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.returnFromAnalysis) {
                        Label(isPolish ? "Wstecz" : "Back", systemImage: "chevron.left")
                    }
                    .disabled(identificationBusy)
                    .accessibilityIdentifier("analysis.navigation.back")
                }
            }
        }
        .background {
            IdentificationResultLifetimeAnchor(lifetime: correctionLifetime)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $showingCorrection, onDismiss: closeCorrection) {
            if let correction {
                VStack {
                    if correctionFailed {
                        Text(isPolish ? "Nie udało się wczytać gatunku. Wybierz ponownie lub anuluj."
                             : "Couldn’t load the species. Choose again or cancel.")
                    }
                    if correctionRequest != nil {
                        ProgressView()
                        Button(isPolish ? "Anuluj" : "Cancel", action: closeCorrection)
                    }
                    GuestCatalogueView(
                        connection: correction.connection, polish: correction.locale == .pl,
                        careReminderLocaleIsCurrent: { correctionIsCurrent(correction) },
                        speciesPicker: .init(
                            taxonId: model.selectedIdentificationSpecies?.taxonId,
                            slug: model.selectedIdentificationSpecies?.slug,
                            select: { selectCorrection($0, correction: correction) },
                            confirmationTitle: isPolish ? "Wybierz ten gatunek" : "Choose this species",
                            cancelTitle: isPolish ? "Anuluj" : "Cancel",
                            contextTitle: model.selectedIdentificationSpecies == nil
                                ? (isPolish ? "Wybierz gatunek" : "Choose a species")
                                : (isPolish ? "Wybierz inny gatunek" : "Choose another species")
                        ),
                        openCollection: nil, back: closeCorrection
                    )
                    .disabled(correctionRequest != nil)
                    // B2_PHOTO_FIXTURE_BEGIN sheet_controls
#if DEBUG
                    if let photoFixtureActions {
                        Button("Arm validation") {
                            photoFixtureActions.arm(correction.snapshot, correction.locale)
                        }
                        .disabled(correctionRequest != nil)
                        .accessibilityIdentifier("photo.fixture.validation.arm")
                        Button("Remove result host", action: photoFixtureActions.removeHost)
                            .disabled(correctionRequest == nil)
                            .accessibilityIdentifier("photo.fixture.host.remove")
                    }
#endif
                    // B2_PHOTO_FIXTURE_END sheet_controls
                }
                .background {
                    IdentificationResultLifetimeAnchor(
                        lifetime: correctionLifetime, presentation: correction.presentation
                    )
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: languageStore.currentLocale) { _, _ in closeCorrection() }
        .onChange(of: catalogueConnection?.snapshot) { _, _ in closeCorrection() }
        .onChange(of: model.correctionSource) { _, _ in closeCorrection() }
    }

    private var identificationBusy: Bool {
        saveLocked || guestActions?.busy == true || showingCorrection
    }

    private var ownsNativeBack: Bool {
        model.router.isDirectAnalysisEntry && returnToPlant == nil
    }

    private var canConfirmIdentification: Bool {
        if let connection = catalogueConnection {
            guard let expected = connection.snapshot else { return false }
            return model.selectedPhotoIdentification(expectedOwnerId: expected.session.userId) != nil
        }
        return model.canConfirmPhotoIdentification
    }

    @ViewBuilder
    private var publishedIdentification: some View {
        if model.confirmedPhotoIdentification == nil {
            Text(model.selectedIdentificationSpecies == nil
                 ? (isPolish ? "Wybierz gatunek z katalogu, aby kontynuować."
                    : "Choose a species from the catalogue to continue.")
                 : (isPolish ? "To wstępne rozpoznanie. Potwierdź gatunek lub wybierz go ręcznie."
                    : "This identification is preliminary. Confirm the species or choose it manually."))
                .accessibilityIdentifier("analysis.identification.uncertainty")
        }
        if let facts = model.selectedIdentificationSpecies?.publishedFacts {
            VStack(alignment: .leading, spacing: 12) {
                Text(facts.scientificName).italic()
                PublishedPlantImageView(
                    source: .init(url: facts.imageURL, author: facts.imageAuthor, license: facts.imageLicense,
                                  attribution: facts.imageAttribution, sourcePage: facts.imageSourcePage),
                    presentation: .hero, label: facts.commonName, locale: languageStore.currentLocale.locale,
                    loader: catalogueConnection?.publicMediaLoader ?? .shared
                )
                Text(isPolish ? "Przykładowe zdjęcie gatunku — nie Twoje zdjęcie."
                     : "Example species photo — separate from your original photo.")
                    .font(.caption)
                if let text = facts.descriptionText { Text(text) }
                if let attribution = facts.descriptionAttribution { Text(attribution).font(.caption) }
                if let url = PublishedPlantImageSource.safeURL(facts.descriptionSourceURL) {
                    Link(isPolish ? "Źródło opisu" : "Description source", destination: url).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .qgCard()
        }
    }

    private func openCorrection(connection: CatalogueConnection, expected: CatalogueSDKSnapshot) {
        guard !identificationBusy, connection.snapshot == expected,
              let presentation = correctionLifetime.presentation,
              let ticket = model.beginManualCorrection(expectedOwnerId: expected.session.userId),
              correctionLifetime.own(ticket, model: model, presentation: presentation) else { return }
        correction = Correction(connection: connection, snapshot: expected,
                                locale: languageStore.currentLocale, ticket: ticket, presentation: presentation)
        correctionFailed = false
        showingCorrection = true
    }

    private func correctionIsCurrent(_ value: Correction) -> Bool {
        !Task.isCancelled && correctionLifetime.isCurrent(value.presentation)
            && showingCorrection && correction?.id == value.id
            && catalogueConnection === value.connection && value.connection.snapshot == value.snapshot
            && languageStore.currentLocale == value.locale && model.correctionSource == value.ticket.source
            && model.confirmedPhotoIdentification == nil && !saveLocked && guestActions?.busy != true
    }

    private func selectCorrection(_ taxonId: UUID, correction value: Correction) {
        guard correctionRequest == nil, correctionIsCurrent(value),
              let api = value.connection.apiClient else { return }
        let request = UUID()
        correctionRequest = request
        correctionFailed = false
        correctionLifetime.task = Task { @MainActor in
            do {
                guard correctionIsCurrent(value), correctionRequest == request else { return }
                let lease = try await value.connection.analysisLease(expected: value.snapshot)
                guard correctionIsCurrent(value), correctionRequest == request else { return }
                let selected = try await model.selectManualSpecies(
                    taxonId: taxonId, locale: value.locale, api: api, context: lease,
                    ticket: value.ticket, expectedOwnerId: value.snapshot.session.userId,
                    isCurrent: { correctionIsCurrent(value) && correctionRequest == request }
                )
                guard correctionIsCurrent(value), correctionRequest == request else { return }
                if selected { closeCorrection() }
                else { correctionRequest = nil; correctionFailed = true }
            } catch {
                guard correctionIsCurrent(value), correctionRequest == request else { return }
                correctionRequest = nil
                correctionFailed = true
            }
        }
    }

    private func closeCorrection() {
        correctionLifetime.cancelRead()
        correctionRequest = nil
        correction = nil
        showingCorrection = false
        correctionFailed = false
    }

    private var speciesHeading: some View {
        Text(model.selectedIdentificationSpecies?.displayName
             ?? (model.identificationResult == nil ? model.speciesLabel : nil)
             ?? (isPolish ? "Nie udało się ustalić gatunku." : "Species could not be determined."))
            .font(.headline)
            .accessibilityIdentifier("analysis.result.species")
    }

    private var exitButtons: some View {
        AnalysisExitButtons(
            model: model, polish: isPolish, returnToPlant: returnToPlant,
            hostOwnsNativeBack: ownsNativeBack
        )
            .disabled((catalogueConnection != nil && saveLocked) || guestActions?.busy == true)
            .buttonStyle(QuietGardenSecondaryButtonStyle())
    }
}

#if DEBUG
/// Reuses the isolated catalogue fixture and renders the ordinary result view.
struct ResultSavePresentationFixtureModifier: ViewModifier {
    let connection: CatalogueConnection
    let polish: Bool
    let enabled: Bool
    var openCollection: ((CatalogueSDKSnapshot) -> Void)? = nil
    private var mode: AnalysisMode? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--catalogue-fixture"),
              let index = arguments.firstIndex(of: "--result-save-presentation"),
              index + 1 < arguments.count,
              let mode = AnalysisMode(rawValue: arguments[index + 1]), mode.isSelectable else { return nil }
        return mode
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled, let mode {
            ResultSavePresentationFixture(
                connection: connection, polish: polish, mode: mode, openCollection: openCollection
            )
        } else {
            content
        }
    }
}

private struct ResultSavePresentationFixture: View {
    let connection: CatalogueConnection
    let polish: Bool
    let mode: AnalysisMode
    var openCollection: ((CatalogueSDKSnapshot) -> Void)? = nil
    @State private var model = AnalysisFlowModel()
    @State private var languageStore = LanguageStore()

    var body: some View {
        NavigationStack {
            PreliminaryResultView(
                model: model, languageStore: languageStore, catalogueConnection: connection,
                openCollection: openCollection
            )
        }
        .task {
            guard let snapshot = connection.snapshot, !snapshot.isAnonymous else { return }
            languageStore.currentLocale = polish ? .pl : .en
            model.installAnalysisService(ResultSavePresentationService(owner: snapshot.session.userId))
            model.router.selectIntent(mode == .diagnosis ? .problem : .care)
            if mode == .identification { model.router.selectCareMethod(.scan) }
            let size = CGSize(width: 600, height: 800)
            let photo = UIGraphicsImageRenderer(size: size).pngData { context in
                UIColor.systemGreen.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            model.selectPhotoData(photo, locale: languageStore.currentLocale)
            await model.submitAnalysis(locale: languageStore.currentLocale)?.value
        }
    }
}

private struct ResultSavePresentationService: AnalysisService {
    let owner: UUID

    func analyze(_ request: AnalysisServiceRequest) async throws -> AnalysisServiceResult {
        let label = request.locale == .pl ? "Paproć" : "Fern"
        let job = UUID()
        let photo = UUID()
        if request.mode == .identification {
            return AnalysisServiceResult(
                identification: .init(jobId: job, catalogueReleaseId: UUID(), species: .init(
                    taxonId: UUID(uuidString: "32e72c49-4e06-434a-86dd-bbf8a5cb209e")!,
                    slug: "fixture_fern", displayName: label
                )),
                uploadedPhotoId: photo, photoOwnerId: owner
            )
        }
        return AnalysisServiceResult(
            analysis: PreliminaryAnalysis(
                id: UUID(), jobId: job, kbReleaseId: UUID(), mode: .diagnosis,
                identificationStatus: .resolved, plantId: "fixture_fern", genusId: nil,
                diagnosisStatus: .healthy, candidates: [], selectedConditionId: nil,
                visualMarkers: [], evidenceBasis: [], limitations: [],
                firstActionSummary: nil, controlIntervalDays: nil, analysisReceipt: "fixture"
            ),
            speciesLabel: label, conditionLabel: nil, uploadedPhotoId: photo,
            firstAidAction: nil, photoOwnerId: owner
        )
    }
}
#endif

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
                    .buttonStyle(QuietGardenPrimaryButtonStyle())
                    .accessibilityIdentifier("analysis.firstAid.record")
            }
        }
        .qgCard(padding: 20)
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
    var hostOwnsNativeBack: Bool = false

    var body: some View {
        if let returnToPlant {
            Button("Back to plant", action: returnToPlant)
                .buttonStyle(QuietGardenSecondaryButtonStyle())
                .accessibilityIdentifier("analysis.back.button")
        } else {
            if !hostOwnsNativeBack {
                Button(polish ? "Wstecz" : "Back") { model.returnFromAnalysis() }
                    .buttonStyle(QuietGardenSecondaryButtonStyle())
                    .accessibilityIdentifier("analysis.back.button")
            }
            Button(polish ? "Przejdź do katalogu" : "Open catalogue") { model.showCatalogue() }
                .buttonStyle(QuietGardenSecondaryButtonStyle())
                .accessibilityIdentifier("analysis.catalogue.button")
        }
    }
}

/// Shared failure UI also preserves the fail-closed entry without a service.
struct AnalysisUnavailableSection: View {
    @Bindable var model: AnalysisFlowModel
    @Bindable var languageStore: LanguageStore
    var returnToPlant: (() -> Void)? = nil
    var hostOwnsNativeBack: Bool = false

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
                .qgNotice(.error)
                .accessibilityIdentifier("analysis.unavailable.title")

            if model.analysisError != "analysis.error.provider_terminal",
               model.analysisError != "analysis.error.expired_terminal",
               model.analysisError != "analysis.error.quota_registration",
               model.analysisError != "analysis.error.quota_exhausted" {
                Button(isPolish ? "Spróbuj ponownie" : "Retry") {
                    model.submitAnalysis(locale: languageStore.currentLocale)
                }
                .buttonStyle(QuietGardenPrimaryButtonStyle())
                .accessibilityIdentifier("analysis.retry.button")
            }

            AnalysisExitButtons(
                model: model, polish: isPolish, returnToPlant: returnToPlant,
                hostOwnsNativeBack: hostOwnsNativeBack
            )
                .buttonStyle(QuietGardenSecondaryButtonStyle())
        }
        .qgCard(padding: 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
