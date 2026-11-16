import SwiftUI
import Supabase
import Observation
import UIKit

@main
struct PlantsApp: App {
    @State private var languageStore = LanguageStore()
    @State private var analysisModel = AnalysisFlowModel()

    var body: some Scene {
        WindowGroup {
            RootContainerView(
                languageStore: languageStore,
                analysisModel: analysisModel
            )
            .environment(\.locale, languageStore.currentLocale.locale)
            .onOpenURL { url in
                _ = NativeIdentityProvider.handleCallbackURL(url)
            }
        }
    }
}

struct RootContainerView: View {
    private struct TrialReminderRead: Equatable {
        let snapshot: CatalogueSDKSnapshot?
        let authResolved: Bool
        let active: Bool
        let locale: SupportedLocale
    }

    @Bindable var languageStore: LanguageStore
    @Bindable var analysisModel: AnalysisFlowModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var catalogue: CatalogueConnection?
    @State private var trialReminder = TrialReminderScheduler()
    private enum AccountDestination: String, Identifiable {
        case diagnosis, identification, collection, guestTransfer
        var id: Self { self }
    }

    @State private var showingCollection = false
    @State private var accountDestination: AccountDestination?
    @State private var collectionAfterSignIn = false
    @State private var opening: AccountDestination?
    @State private var analysisOwner: UUID?
    @State private var analysisCredential: String?
    @State private var guestPhotoClaim: GuestPhotoClaim?
    @State private var guestAccessFailed = false
    @State private var showingGuestTransfer = false
    @State private var openClaimCollection = false
    @State private var analysisAccessRepository = AnalysisAccessRepository()
    @State private var starting = false
    @State private var startupFailed = false
#if DEBUG && (targetEnvironment(simulator) || NARAT_DEVICE_STAGING_ANALYSIS)
    @State private var stagingAccount: StagingAccountPresentation?
    @State private var stagingResume: CatalogueResumeSelection?
    @State private var stagingResumeLocked = false
    @State private var stagingSpecies: PublishedSpeciesCard?
#endif
#if DEBUG
    @State private var fixtureContext: CatalogueUIFixtureContext?
#endif

    private var isPolish: Bool {
        languageStore.currentLocale == .pl
    }

    private var isStagingAnalysis: Bool {
#if DEBUG && (targetEnvironment(simulator) || NARAT_DEVICE_STAGING_ANALYSIS)
        ProcessInfo.processInfo.arguments.contains("--narat-staging-analysis")
#else
        false
#endif
    }

    private var usesLegacyWelcome: Bool {
#if DEBUG
        isStagingAnalysis || fixtureContext != nil
#else
        false
#endif
    }

    var body: some View {
        let reminderRead = TrialReminderRead(
            snapshot: catalogue?.snapshot, authResolved: catalogue?.hasResolvedAuth == true || catalogue?.unavailable != nil,
            active: scenePhase == .active, locale: languageStore.currentLocale
        )
        NavigationStack {
            VStack(spacing: 16) {
#if DEBUG
                if fixtureContext != nil {
                    Picker("profile.language.picker", selection: $languageStore.currentLocale) {
                        Text("Polski").tag(SupportedLocale.pl)
                        Text("English").tag(SupportedLocale.en)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .accessibilityIdentifier("welcome.language.picker")
                }
#endif
                if startupFailed && usesLegacyWelcome {
                    Text(isPolish ? "Katalog jest niedostępny." : "Catalogue unavailable.")
                        .accessibilityIdentifier("catalogue.error")
                }
                switch analysisModel.router.flowState.currentStep {
                case .selectIntent:
                    if usesLegacyWelcome {
                        welcomeIntentSection
                    } else {
                        PlantHomeView(
                            polish: isPolish,
                            busy: opening != nil,
                            unavailable: catalogue?.unavailable != nil || startupFailed,
                            guestAccessFailed: guestAccessFailed,
                            check: { open(.diagnosis) },
                            identify: { open(.identification) },
                            browse: {
                                analysisModel.router.selectIntent(.care)
                                analysisModel.router.selectCareMethod(.catalogue)
                            },
                            collection: { open(.collection) }
                        ) { guestSaveButtons }
                    }
                case .selectCareMethod:
                    careMethodPickerSection
                case .selectCatalogueSpecies:
                    if let catalogue {
#if DEBUG && (targetEnvironment(simulator) || NARAT_DEVICE_STAGING_ANALYSIS)
                        if isStagingAnalysis, let resumed = stagingResume {
                            ScrollView {
                                CatalogueSaveView(
                                    connection: catalogue, speciesSlug: resumed.speciesSlug,
                                    displayName: stagingSpecies?.displayName ?? (resumed.identification == nil ? resumed.speciesSlug : "Plant"),
                                    scientificName: stagingSpecies?.scientificName ?? "", polish: false,
                                    analysisSaveIdentity: resumed.flowId,
                                    identification: resumed.identification,
                                    diagnosisJobId: resumed.diagnosisJobId,
                                    selectionLocked: $stagingResumeLocked
                                ) { EmptyView() }
                                .id(resumed.flowId)
                                .padding()
                            }
                            .task(id: resumed.flowId) {
                                stagingSpecies = nil
                                let species: PublishedSpeciesCard?
                                if let taxonId = resumed.identification?.taxonId {
                                    species = try? await catalogue.apiClient?.fetchPublishedSpecies(taxonId: taxonId, locale: .en)
                                } else {
                                    species = try? await catalogue.apiClient?.fetchPublishedSpecies(slug: resumed.speciesSlug, locale: .en)
                                }
                                guard !Task.isCancelled, stagingResume?.flowId == resumed.flowId else { return }
                                stagingSpecies = species
                            }
                            Button("Back") {
                                stagingResume = nil
                                analysisModel.router.navigateBack()
                            }
                            .disabled(stagingResumeLocked)
                            .accessibilityIdentifier("catalogue.back")
                        } else {
                            GuestCatalogueView(connection: catalogue, polish: isPolish, back: closeCatalogue)
                        }
#else
                        GuestCatalogueView(connection: catalogue, polish: isPolish, back: closeCatalogue)
#endif
                    } else {
                        if !startupFailed { ProgressView() }
                        Button(isPolish ? "Wstecz" : "Back") {
                            closeCatalogue()
                        }
                        .accessibilityIdentifier("catalogue.back")
                    }
                case .selectPhoto, .careQuestions:
                    CareQuestionsView(
                        model: analysisModel, languageStore: languageStore, accessSource: analysisAccessSource
                    )
                case .analyzing, .preliminaryResult, .diagnosticRefinement:
                    PreliminaryResultView(
                        model: analysisModel, languageStore: languageStore,
                        catalogueConnection: analysisOwner != nil && catalogue?.snapshot?.session.userId == analysisOwner
                            ? catalogue : nil,
                        guestActions: guestIdentificationActions
                    )
                default:
                    welcomeIntentSection
                }
                if usesLegacyWelcome, catalogue != nil,
                   [.selectIntent, .selectCatalogueSpecies].contains(analysisModel.router.flowState.currentStep) {
                    Button(isPolish ? "Moje rośliny" : "My plants") { showingCollection = true }
                        .accessibilityIdentifier("collection.open")
                }
                if usesLegacyWelcome { guestSaveButtons }
            }
        }
        .task { await prepareCatalogue() }
        .task(id: reminderRead) { await observeTrialReminder(reminderRead) }
        .sheet(isPresented: $showingCollection) {
            if let catalogue {
                CatalogueCollectionView(
                    connection: catalogue, polish: isPolish, repeatDiagnosis: repeatDiagnosisEntry(for: catalogue),
                    trialReminder: trialReminder
                )
            }
        }
        .sheet(item: $accountDestination, onDismiss: {
            if collectionAfterSignIn {
                collectionAfterSignIn = false
                showingCollection = true
            } else {
                showPendingGuestTransfer()
            }
        }) { destination in
            if let catalogue {
                AccountSignInView(
                    connection: catalogue,
                    cancel: { accountDestination = nil }
                ) { snapshot, original in
                    switch destination {
                    case .collection:
                        collectionAfterSignIn = true
                    case .guestTransfer:
                        finishGuestSignIn(snapshot, original: original)
                    case .diagnosis, .identification:
                        activate(destination, connection: catalogue, snapshot: snapshot)
                    }
                    accountDestination = nil
                }
            }
        }
#if DEBUG && (targetEnvironment(simulator) || NARAT_DEVICE_STAGING_ANALYSIS)
        .sheet(item: $stagingAccount, onDismiss: showPendingGuestTransfer) { account in
            AccountSignInView(
                connection: account.connection, staging: true,
                cancel: account.guestTransfer ? { stagingAccount = nil } : nil
            ) { snapshot, original in finishStagingSignIn(account, snapshot: snapshot, original: original) }
        }
#endif
        .sheet(isPresented: $showingGuestTransfer, onDismiss: {
            if openClaimCollection {
                openClaimCollection = false
                showingCollection = true
            }
        }) {
            if let claim = guestPhotoClaim {
                GuestPhotoTransferView(claim: claim) {
                    openClaimCollection = true
                    showingGuestTransfer = false
                }
            }
        }
    }

    @ViewBuilder
    private var guestSaveButtons: some View {
        if analysisModel.router.flowState.currentStep == .selectIntent,
           let claim = guestPhotoClaim, let scope = catalogue?.snapshot, claim.canResumeDraft(for: scope) {
            Button("Continue saving") {
                Task { @MainActor in
                    handleGuestDraft(await claim.resumeDraft(), claim: claim)
                }
            }
            .disabled(claim.busy)
            .accessibilityIdentifier("staging.guest.draft.resume")
            if claim.failed { Text("Couldn’t prepare your plant. Try again.") }
        }
        if let claim = guestPhotoClaim, let scope = catalogue?.snapshot, claim.pending(for: scope),
           !showingGuestTransfer {
            Button("Finish saving your plant") { showingGuestTransfer = true }
                .accessibilityIdentifier("staging.guest.claim.resume")
        }
    }

    private func observeTrialReminder(_ read: TrialReminderRead) async {
        guard !Task.isCancelled else { return }
        guard let connection = catalogue, let expected = read.snapshot, !expected.isAnonymous,
              let sync = connection.syncEngine else {
            if read.authResolved { trialReminder.update(ownerId: nil, entitlement: nil, locale: read.locale) }
            return
        }
        if let previousOwner = trialReminder.trial?.ownerId, previousOwner != expected.session.userId {
            trialReminder.update(ownerId: nil, entitlement: nil, locale: read.locale)
        }
        guard read.active else { return }
        let updates = await sync.canonicalSyncUpdates()
        func refresh() async {
            let entitlement = try? await connection.syncedTrialEntitlement(expected: expected)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            trialReminder.update(ownerId: expected.session.userId, entitlement: entitlement, locale: read.locale)
        }
        await refresh()
        for await _ in updates { await refresh() }
    }

    private var analysisAccessSource: AnalysisAccessSource? {
        guard let catalogue, analysisOwner != nil else { return nil }
        return AnalysisAccessSource(
            connection: catalogue, repository: analysisAccessRepository, guestCredential: analysisCredential
        )
    }

    private func repeatDiagnosisEntry(for connection: CatalogueConnection) -> RepeatDiagnosisEntry? {
        guard !isPolish, let api = connection.apiClient else { return nil }
#if DEBUG
        guard fixtureContext == nil else { return nil }
#endif
        return RepeatDiagnosisEntry(
            languageStore: languageStore,
            accessSource: AnalysisAccessSource(connection: connection, repository: analysisAccessRepository, guestCredential: nil)
        ) { card, expected in
            guard connection.snapshot == expected, !expected.isAnonymous else { return nil }
            let target = RepeatDiagnosisTarget(plantId: card.id, ownerId: expected.session.userId)
            let service = PhotoAnalysisService(api: api, repeatDiagnosisTarget: target) {
                try await connection.collectionLease(expected: expected)
            }
            return AnalysisFlowModel(repeatDiagnosisTarget: target, service: service)
        }
    }

    private func closeCatalogue() {
        if usesLegacyWelcome {
            analysisModel.router.navigateBack()
        } else {
            analysisModel.router.flowState.currentStep = .selectIntent
        }
    }

    private func open(_ destination: AccountDestination) {
        guard opening == nil, accountDestination == nil, let connection = catalogue,
              connection.apiClient != nil else { return }
        opening = destination
        guestAccessFailed = false
        Task { @MainActor in
            defer { opening = nil }
            if let snapshot = try? await connection.sessionSnapshot(), !snapshot.isAnonymous {
                activate(destination, connection: connection, snapshot: snapshot)
            } else if destination == .identification || destination == .diagnosis {
                do { try await openGuestAnalysis(destination, connection: connection) }
                catch {
                    if !Task.isCancelled { guestAccessFailed = true }
                }
            } else if !Task.isCancelled {
                accountDestination = destination
            }
        }
    }

    private func openGuestAnalysis(_ destination: AccountDestination, connection: CatalogueConnection) async throws {
        _ = try await connection.sessionOwner()
        let expected = try await connection.sessionSnapshot()
        if !expected.isAnonymous {
            activate(destination, connection: connection, snapshot: expected)
            return
        }
        let claim = await photoClaim(for: connection)
        try await claim.register(expected)
        guard !Task.isCancelled, connection.snapshot == expected else {
            throw SyncWireValidationError.invalidSession
        }
        installAnalysis(connection: connection, owner: expected.session.userId,
                        identificationEnabled: true, guestCredential: claim.credential)
        if destination == .diagnosis {
            analysisModel.router.selectIntent(.problem)
        } else {
            analysisModel.router.selectIntent(.care)
            analysisModel.router.selectCareMethod(.scan)
        }
    }

    private func photoClaim(for connection: CatalogueConnection) async -> GuestPhotoClaim {
        if let guestPhotoClaim, guestPhotoClaim.connection === connection { return guestPhotoClaim }
        let claim = GuestPhotoClaim(connection: connection, credential: await analysisAccessRepository.installationCredential())
        guestPhotoClaim = claim
        return claim
    }

    private func finishGuestSignIn(_ snapshot: CatalogueSDKSnapshot, original: CatalogueSDKSnapshot?) {
        do {
            guard let guestPhotoClaim, let original else { throw SyncWireValidationError.invalidSession }
            try guestPhotoClaim.acceptDestination(snapshot, from: original)
            analysisModel.installAnalysisService(nil)
            analysisOwner = nil
            analysisCredential = nil
            analysisModel.router.flowState.currentStep = .selectIntent
        } catch {
            guestAccessFailed = true
            analysisModel.router.flowState.currentStep = .selectIntent
        }
    }

    private func activate(
        _ destination: AccountDestination, connection: CatalogueConnection, snapshot: CatalogueSDKSnapshot
    ) {
        guard connection.snapshot == snapshot, !snapshot.isAnonymous else { return }
        if destination == .collection {
            showingCollection = true
            return
        }
        installAnalysis(
            connection: connection, owner: snapshot.session.userId, identificationEnabled: true
        )
        if destination == .diagnosis {
            analysisModel.router.selectIntent(.problem)
        } else {
            analysisModel.router.selectIntent(.care)
            analysisModel.router.selectCareMethod(.scan)
        }
    }

    private var guestIdentificationActions: GuestIdentificationActions? {
        guard let claim = guestPhotoClaim, catalogue?.snapshot?.isAnonymous == true else { return nil }
        return GuestIdentificationActions(
            busy: claim.busy, failed: claim.failed,
            save: { selection in
                Task { @MainActor in
                    handleGuestDraft(await claim.createDraft(selection), claim: claim)
                }
            },
            saveDiagnosis: { selection in
                Task { @MainActor in
                    handleGuestDraft(await claim.createDraft(selection), claim: claim)
                }
            }
        )
    }

    @MainActor
    private func prepareCatalogue() async {
        guard !starting else { return }
        starting = true
#if DEBUG && (targetEnvironment(simulator) || NARAT_DEVICE_STAGING_ANALYSIS)
        if ProcessInfo.processInfo.arguments.contains("--narat-staging-analysis") {
            await prepareStagingAnalysis()
            return
        }
#endif
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let fixtureFlags = arguments.filter {
            $0.hasPrefix("--catalogue-fixture") || $0.hasPrefix("--catalogue-namespace")
        }
        if !fixtureFlags.isEmpty {
            func value(_ flag: String) -> String? {
                let positions = arguments.indices.filter { arguments[$0] == flag }
                guard positions.count == 1, let index = positions.first,
                      arguments.indices.contains(index + 1) else { return nil }
                return arguments[index + 1]
            }
            guard fixtureFlags.count == 2,
                  Set(fixtureFlags) == Set(["--catalogue-fixture", "--catalogue-namespace"]),
                  let name = value("--catalogue-fixture"),
                  let scenario = CatalogueUIFixtureScenario(rawValue: name),
                  let namespace = value("--catalogue-namespace"),
                  let id = UUID(uuidString: namespace),
                  id.uuidString.lowercased() == namespace.lowercased() else {
                startupFailed = true
                return
            }
            do {
                let context = try await CatalogueUIFixtures.make(namespace: namespace, scenario: scenario)
                fixtureContext = context
                catalogue = context.connection
            } catch {
                startupFailed = true
                return
            }
        } else {
            catalogue = CatalogueConnection(clientLocale: "en")
        }
#else
        catalogue = CatalogueConnection(clientLocale: "en")
#endif
        guard let catalogue else { return }
        if !usesLegacyWelcome {
            languageStore.currentLocale = SupportedLocale.resolveInitial()
        }
        do {
            if usesLegacyWelcome { _ = try await catalogue.sessionOwner() }
            guard analysisModel.router.flowState.currentStep == .selectIntent else { return }
            let expected = try await catalogue.sessionSnapshot()
            if !usesLegacyWelcome, catalogue.guestPhotoClaimData() != nil {
                let claim = await photoClaim(for: catalogue)
                if expected.isAnonymous {
                    try await claim.register(expected)
                } else if claim.pending(for: expected) {
                    showingGuestTransfer = true
                    return
                }
            }
            guard analysisModel.router.flowState.currentStep == .selectIntent,
                  let flow = try catalogue.resumableFlow(expected: expected) else { return }
            let result = await catalogue.restoreModel(
                ownerId: expected.session.userId, flowId: flow, expected: expected
            )
            // Only an actual current-owner SQLite input resumes the existing catalogue route.
            guard catalogue.snapshot == expected, case let .restored(model) = result,
                  model.input != nil,
                  analysisModel.router.flowState.currentStep == .selectIntent else { return }
            analysisModel.router.selectIntent(.care)
            analysisModel.router.selectCareMethod(.catalogue)
        } catch {
            // Preserve the default welcome and the catalogue's ordinary unavailable path.
        }
    }

    private func handleGuestDraft(_ outcome: GuestPhotoClaim.DraftOutcome, claim: GuestPhotoClaim) {
        switch outcome {
        case .ready:
#if DEBUG && (targetEnvironment(simulator) || NARAT_DEVICE_STAGING_ANALYSIS)
            if isStagingAnalysis {
                stagingAccount = StagingAccountPresentation(connection: claim.connection, guestTransfer: true)
                return
            }
#endif
            accountDestination = .guestTransfer
        case .expired:
            if analysisModel.router.flowState.currentStep == .preliminaryResult { analysisModel.returnFromAnalysis() }
        case .failed:
            break
        }
    }

    private func showPendingGuestTransfer() {
        guard let claim = guestPhotoClaim, let snapshot = catalogue?.snapshot,
              claim.pending(for: snapshot) else { return }
        showingGuestTransfer = true
    }

#if DEBUG && (targetEnvironment(simulator) || NARAT_DEVICE_STAGING_ANALYSIS)
    @MainActor
    private func prepareStagingAnalysis() async {
        guard let config = try? NativeAuthConfiguration(),
              PhotoAnalysisService.isEnabled(
                arguments: ProcessInfo.processInfo.arguments,
                expectedHost: Bundle.main.object(forInfoDictionaryKey: "NaratStagingAnalysisHost") as? String,
                apiOrigin: config.supabaseURL
              ) else {
            startupFailed = true
            return
        }
        let connection = CatalogueConnection(configuration: { config }, clientLocale: "en")
        guard connection.apiClient != nil else {
            startupFailed = true
            return
        }
        catalogue = connection
        languageStore.currentLocale = .en
        if ProcessInfo.processInfo.arguments.contains("--narat-staging-guest-claim") {
            let claim = GuestPhotoClaim(
                connection: connection, credential: await analysisAccessRepository.installationCredential()
            )
            guestPhotoClaim = claim
            do {
                _ = try await connection.sessionOwner()
                let snapshot = try await connection.sessionSnapshot()
                if snapshot.isAnonymous {
                    try await claim.register(snapshot)
                    installStagingAnalysis(connection: connection, owner: snapshot.session.userId,
                                           guestCredential: claim.credential)
                    return
                }
                if claim.pending(for: snapshot) {
                    showingGuestTransfer = true
                    installStagingAnalysis(connection: connection, owner: snapshot.session.userId)
                    return
                }
            } catch {
                startupFailed = true
                return
            }
        }
        if let snapshot = try? await connection.sessionSnapshot(), !snapshot.isAnonymous {
            installStagingAnalysis(connection: connection, owner: snapshot.session.userId)
            await restoreStagingCard(connection: connection)
        } else {
            stagingAccount = StagingAccountPresentation(connection: connection)
        }
    }

    @MainActor
    private func finishStagingSignIn(_ account: StagingAccountPresentation, snapshot: CatalogueSDKSnapshot, original: CatalogueSDKSnapshot?) {
        if account.guestTransfer {
            do {
                guard let claim = guestPhotoClaim, let original else { throw SyncWireValidationError.invalidSession }
                try claim.acceptDestination(snapshot, from: original)
            } catch {
                startupFailed = true
                stagingAccount = nil
                return
            }
            analysisModel.router.flowState.currentStep = .selectIntent
        }
        installStagingAnalysis(connection: account.connection, owner: snapshot.session.userId)
        stagingAccount = nil
        if !account.guestTransfer {
            Task { await restoreStagingCard(connection: account.connection) }
        }
    }

    @MainActor
    private func restoreStagingCard(connection: CatalogueConnection) async {
        do {
            let expected = try await connection.sessionSnapshot()
            guard !expected.isAnonymous,
                  analysisModel.router.flowState.currentStep == .selectIntent,
                  let flow = try connection.resumableFlow(expected: expected) else { return }
            let result = await connection.restoreModel(
                ownerId: expected.session.userId, flowId: flow, expected: expected
            )
            guard connection.snapshot == expected, !Task.isCancelled,
                  analysisModel.router.flowState.currentStep == .selectIntent,
                  case let .restored(model) = result,
                  let resumed = CatalogueResumeSelection(model) else { return }
            // The durable flow opens directly, independent of catalogue pages or RPC failures.
            stagingResume = resumed
            analysisModel.router.selectIntent(.care)
            analysisModel.router.selectCareMethod(.catalogue)
        } catch {
            // The catalogue can retry restoration explicitly.
        }
    }

    @MainActor
    private func installStagingAnalysis(connection: CatalogueConnection, owner: UUID, guestCredential: String? = nil) {
        installAnalysis(
            connection: connection, owner: owner,
            identificationEnabled: ProcessInfo.processInfo.arguments.contains("--narat-staging-identification"),
            guestCredential: guestCredential
        )
    }
#endif

    @MainActor
    private func installAnalysis(
        connection: CatalogueConnection, owner: UUID, identificationEnabled: Bool, guestCredential: String? = nil
    ) {
        guard let api = connection.apiClient else { return }
        analysisOwner = owner
        analysisCredential = guestCredential
        analysisModel.installAnalysisService(PhotoAnalysisService(
            api: api, identificationEnabled: identificationEnabled, guestCredential: guestCredential
        ) {
            let snapshot = try await connection.sessionSnapshot()
            guard snapshot.isAnonymous == (guestCredential != nil), snapshot.session.userId == owner else {
                throw AnalysisServiceFailure.unavailable
            }
            return try await connection.analysisLease(expected: snapshot)
        })
    }

    private var welcomeIntentSection: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(isPolish ? "Narat" : "Narat")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("welcome.title")

            Text(
                isPolish
                    ? "Wybierz, w czym możemy dziś pomóc Twojej roślinie."
                    : "Choose how we can help your plant today."
            )
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("welcome.subtitle")

            VStack(spacing: 12) {
                Button {
                    analysisModel.router.selectIntent(.problem)
                } label: {
                    Text(
                        isPolish
                            ? "Zdiagnozuj problem z rośliną"
                            : "Diagnose a plant problem"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("welcome.intent.problem")

                Button {
                    analysisModel.router.selectIntent(.care)
                } label: {
                    Text(
                        isPolish
                            ? "Dobierz pielęgnację i harmonogram"
                            : "Set up care and schedule"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("welcome.intent.care")
            }
            .padding(.horizontal)
            Spacer()
        }
        .padding()
    }

    private var careMethodPickerSection: some View {
        VStack(spacing: 16) {
            Text(
                isPolish
                    ? "Jak chcesz dodać roślinę do pielęgnacji?"
                    : "How would you like to add your plant for care?"
            )
            .font(.title3.bold())
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("care.method.title")

            Button {
                analysisModel.router.selectCareMethod(.scan)
            } label: {
                Text(isPolish ? "Rozpoznaj gatunek ze zdjęcia" : "Identify species from photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("care.method.scan")

            Button {
                analysisModel.router.selectCareMethod(.catalogue)
            } label: {
                Text(isPolish ? "Wybierz gatunek z katalogu (bez zdjęcia)" : "Choose species from catalogue (no photo)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("care.method.catalogue")

            Button {
                analysisModel.router.navigateBack()
            } label: {
                Text(isPolish ? "Wstecz" : "Back")
            }
            .accessibilityIdentifier("care.navigation.back")
        }
        .padding()
    }
}

@MainActor
final class PhotoAnalysisService: AnalysisService {
    private struct Progress {
        let request: AnalysisServiceRequest
        let ownerId: UUID
        var creationOperationId: UUID
        var photoId: UUID?
        var uploadAttempted = false
        var photoReady = false
        var jobId: UUID?
    }

    private let api: PlantsAPIClient
    private let identificationEnabled: Bool
    private let guestCredential: String?
    private let repeatDiagnosisTarget: RepeatDiagnosisTarget?
    private let session: @MainActor () async throws -> SyncSessionLease
    private var previous: Progress?
    private var activeAttempt: UUID?

    init(api: PlantsAPIClient, identificationEnabled: Bool = false, guestCredential: String? = nil,
         repeatDiagnosisTarget: RepeatDiagnosisTarget? = nil,
         session: @escaping @MainActor () async throws -> SyncSessionLease) {
        self.api = api
        self.identificationEnabled = identificationEnabled
        self.guestCredential = guestCredential
        self.repeatDiagnosisTarget = repeatDiagnosisTarget
        self.session = session
    }

    static func isEnabled(arguments: [String], expectedHost: String?, apiOrigin: URL) -> Bool {
        guard arguments.contains("--narat-staging-analysis"),
              let expectedHost, !expectedHost.isEmpty,
              apiOrigin.scheme == "https", apiOrigin.host == expectedHost,
              apiOrigin.port == nil || apiOrigin.port == 443,
              apiOrigin.path.isEmpty || apiOrigin.path == "/",
              apiOrigin.user == nil, apiOrigin.password == nil,
              apiOrigin.query == nil, apiOrigin.fragment == nil else { return false }
        return true
    }

    func analyze(_ request: AnalysisServiceRequest) async throws -> AnalysisServiceResult {
        guard request.repeatDiagnosisTarget == repeatDiagnosisTarget,
              (request.mode == .diagnosis && (guestCredential == nil || repeatDiagnosisTarget == nil)) ||
              (repeatDiagnosisTarget == nil && identificationEnabled && request.mode == .identification) else {
            throw AnalysisServiceFailure.unavailable
        }
        try Task.checkCancellation()
        let attempt = UUID()
        activeAttempt = attempt
        defer { if activeAttempt == attempt { activeAttempt = nil } }
        let lease = try await session()
        try verify(lease, attempt: attempt)
        if let repeatDiagnosisTarget, lease.ownerId != repeatDiagnosisTarget.ownerId {
            throw AnalysisServiceFailure.unavailable
        }

        var progress = Progress(request: request, ownerId: lease.ownerId, creationOperationId: request.operationId)
        if let previous, previous.request.operationId == request.operationId {
            guard previous.ownerId == lease.ownerId, previous.request == request else {
                throw AnalysisServiceFailure.unavailable
            }
            progress = previous
        }
        defer { if activeAttempt == attempt { previous = progress } }
        let locale = request.locale

        do {
            if progress.uploadAttempted, !progress.photoReady, let photoId = progress.photoId {
                do {
                    try await api.confirmAnalysisPhoto(id: photoId, locale: locale, context: lease, guestCredential: guestCredential)
                    try verify(lease, attempt: attempt)
                    progress.photoReady = true
                } catch let error as APIErrorResponse where error.error.code == "CONFLICT" && error.error.retryable {
                    // No confirmed upload. Refresh the ticket for the same operation and digest.
                    try verify(lease, attempt: attempt)
                }
            }
            if !progress.photoReady {
                let jpeg = request.photo.aiVisionJPEG
                let ticket = try await api.issueAnalysisUpload(
                    jpeg: jpeg, operationId: request.uploadOperationId, locale: locale, context: lease, guestCredential: guestCredential
                )
                try verify(lease, attempt: attempt)
                guard progress.photoId == nil || progress.photoId == ticket.photoAssetId else {
                    throw AnalysisHTTPError.invalidResponse
                }
                progress.photoId = ticket.photoAssetId
                progress.uploadAttempted = true
                if ticket.expiresInSeconds == 0 {
                    try await api.confirmAnalysisPhoto(id: ticket.photoAssetId, locale: locale, context: lease, guestCredential: guestCredential)
                } else {
                    try await api.uploadAnalysisJPEG(jpeg, ticket: ticket, locale: locale, context: lease, guestCredential: guestCredential)
                }
                try verify(lease, attempt: attempt)
                progress.photoReady = true
            }
            guard let photoId = progress.photoId else { throw AnalysisHTTPError.invalidResponse }
            let targetPlantId = repeatDiagnosisTarget?.plantId
            let expectedPhotoId = targetPlantId == nil ? nil : photoId
            var job: AnalysisJobWire
            var readStatus = false
            if let jobId = progress.jobId {
                job = try await api.fetchAnalysisJob(
                    id: jobId, mode: request.mode, targetPlantId: targetPlantId, photoAssetId: expectedPhotoId,
                    locale: locale, context: lease, guestCredential: guestCredential
                )
                readStatus = true
            } else {
                job = try await api.createAnalysisJob(
                    operationId: progress.creationOperationId, mode: request.mode, photoAssetId: photoId,
                    flowId: request.mode == .identification || targetPlantId != nil ? request.flowId : nil,
                    targetPlantId: targetPlantId,
                    initialContext: request.mode == .diagnosis && targetPlantId == nil
                        ? InitialDiagnosisContext(conditions: request.conditions) : nil,
                    locale: locale, context: lease, guestCredential: guestCredential
                )
            }
            try verify(lease, attempt: attempt)
            progress.jobId = job.jobId

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(90))
            while job.status == .queued || job.status == .running {
                guard clock.now < deadline else { throw AnalysisServiceFailure.unavailable }
                try await Task.sleep(for: .seconds(1))
                try verify(lease, attempt: attempt)
                job = try await api.fetchAnalysisJob(
                    id: job.jobId, mode: request.mode, targetPlantId: targetPlantId, photoAssetId: expectedPhotoId,
                    locale: locale, context: lease, guestCredential: guestCredential
                )
                readStatus = true
                try verify(lease, attempt: attempt)
            }
            if targetPlantId != nil, job.status == .succeeded, !readStatus {
                job = try await api.fetchAnalysisJob(
                    id: job.jobId, mode: request.mode, targetPlantId: targetPlantId, photoAssetId: expectedPhotoId,
                    locale: locale, context: lease, guestCredential: guestCredential
                )
                readStatus = true
                try verify(lease, attempt: attempt)
            }
            if job.status == .failed, job.errorCode?.hasPrefix("PROVIDER_") == true {
                if request.mode == .diagnosis, targetPlantId == nil, job.quotaState == .released {
                    // A terminal job cannot be replayed into a new run. Keep the upload
                    // and allocate one create operation for the user's next explicit retry.
                    progress.jobId = nil
                    progress.creationOperationId = UUID()
                    throw AnalysisServiceFailure.retryableProvider
                }
                throw AnalysisServiceFailure.providerFailed
            }
            guard job.status == .succeeded else { throw AnalysisServiceFailure.unavailable }
            if let result = job.identificationResult {
                var species: PhotoIdentificationResult.Species?
                if let plant = result.plant {
                    let card = try await api.fetchPublishedSpecies(taxonId: plant.taxonId, locale: locale)
                    try verify(lease, attempt: attempt)
                    species = .init(taxonId: card.taxonId, slug: card.id, displayName: plant.displayName)
                }
                return AnalysisServiceResult(identification: .init(
                    jobId: result.jobId, catalogueReleaseId: result.catalogueReleaseId, species: species
                ), uploadedPhotoId: photoId, photoOwnerId: lease.ownerId)
            }
            guard let result = job.result else { throw AnalysisServiceFailure.unavailable }
            return AnalysisServiceResult(
                analysis: result.domainValue,
                speciesLabel: result.plantDisplayName,
                conditionLabel: result.conditionDisplayName,
                uploadedPhotoId: photoId,
                firstAidAction: readStatus ? job.recordableFirstAid : nil, photoOwnerId: lease.ownerId
            )
        } catch let error as APIErrorResponse where error.error.code == "QUOTA_REGISTRATION_REQUIRED" {
            throw AnalysisServiceFailure.quotaRegistrationRequired
        } catch let error as APIErrorResponse where error.error.code == "QUOTA_EXHAUSTED" {
            throw AnalysisServiceFailure.quotaExhausted
        } catch let error as APIErrorResponse where error.error.code.hasPrefix("PROVIDER_") {
            throw AnalysisServiceFailure.retryableProvider
        }
    }

    private func verify(_ lease: SyncSessionLease, attempt: UUID) throws {
        try Task.checkCancellation()
        guard activeAttempt == attempt else { throw CancellationError() }
        try api.syncAuthority.withBoundValid(lease) {}
    }
}

@MainActor
@Observable
final class GuestPhotoClaim {
    enum DraftOutcome: Equatable { case ready, expired, failed }

    private enum DraftSource: String, Codable { case identification, diagnosis }

    private struct Journal: Codable, Equatable {
        let guestOwner: UUID
        let installationId: UUID
        let jobId: UUID
        let taxonId: UUID?
        // Absent in legacy identification journals, including an unprepared draft.
        var source: DraftSource? = nil
        let photoId: UUID

        var validSource: Bool {
            source == .diagnosis ? taxonId == nil : taxonId != nil
        }
        let draftOperationId: UUID
        let prepareOperationId: UUID
        let commitOperationId: UUID
        var draft: GuestPhotoDraftReceipt?
        var destinationOwner: UUID?
        var proof: GuestPhotoClaimProof?
        var receipt: GuestPhotoClaimReceipt?
    }

    let connection: CatalogueConnection
    let credential: String
    private var installationId: UUID?
    private var journal: Journal?
    private(set) var busy = false
    private(set) var failed = false

    init(connection: CatalogueConnection, credential: String) {
        self.connection = connection
        self.credential = credential
        if let data = connection.guestPhotoClaimData() {
            journal = try? JSONDecoder().decode(Journal.self, from: data)
        }
    }

    func register(_ expected: CatalogueSDKSnapshot) async throws {
        guard expected.isAnonymous, let api = connection.apiClient else { throw AnalysisHTTPError.invalidResponse }
        let lease = try await connection.analysisLease(expected: expected)
        let id = try await api.registerPhotoInstallation(credential: credential, context: lease)
        guard connection.snapshot == expected else { throw SyncWireValidationError.invalidSession }
        installationId = id
    }

    func createDraft(_ selection: PhotoIdentificationSelection) async -> DraftOutcome {
        await createDraft(jobId: selection.jobId, taxonId: selection.taxonId,
                          photoId: selection.photoAssetId, ownerId: selection.ownerId)
    }

    func createDraft(_ selection: GuestDiagnosisSelection) async -> DraftOutcome {
        guard let expected = connection.snapshot,
              PlantsAPIClient.isGuestPhotoSession(expected.session) else { return .failed }
        return await createDraft(jobId: selection.jobId, taxonId: nil, source: .diagnosis,
                                 photoId: selection.photoId, ownerId: selection.ownerId)
    }

    private func createDraft(
        jobId: UUID, taxonId: UUID?, source: DraftSource? = nil, photoId: UUID, ownerId: UUID?
    ) async -> DraftOutcome {
        guard !busy, let expected = connection.snapshot, expected.isAnonymous,
              ownerId == expected.session.userId, let installationId else { return .failed }
        failed = false
        do {
            if let journal, journal.receipt == nil {
                guard canResumeDraft(for: expected), journal.jobId == jobId,
                      journal.taxonId == taxonId, (journal.source ?? .identification) == (source ?? .identification),
                      journal.photoId == photoId else {
                    throw AnalysisHTTPError.invalidResponse
                }
            } else {
                try store(Journal(
                    guestOwner: expected.session.userId, installationId: installationId,
                    jobId: jobId, taxonId: taxonId, source: source, photoId: photoId,
                    draftOperationId: UUID(), prepareOperationId: UUID(), commitOperationId: UUID()
                ))
            }
        } catch {
            failed = true
            return .failed
        }
        return await resumeDraft()
    }

    func canResumeDraft(for expected: CatalogueSDKSnapshot) -> Bool {
        guard expected.isAnonymous, let installationId, let journal, journal.validSource,
              journal.source != .diagnosis || PlantsAPIClient.isGuestPhotoSession(expected.session) else { return false }
        return journal.guestOwner == expected.session.userId && journal.installationId == installationId
            && journal.destinationOwner == nil && journal.receipt == nil
    }

    func resumeDraft() async -> DraftOutcome {
        guard !busy, let expected = connection.snapshot, canResumeDraft(for: expected),
              var current = journal, let api = connection.apiClient else { return .failed }
        busy = true
        failed = false
        defer { busy = false }
        do {
            if current.draft == nil {
                let lease = try await connection.analysisLease(expected: expected)
                if current.source == .diagnosis {
                    current.draft = try await api.createDiagnosisPhotoDraft(
                        operationId: current.draftOperationId, jobId: current.jobId,
                        credential: credential, context: lease
                    )
                } else if let taxonId = current.taxonId {
                    current.draft = try await api.createPhotoDraft(
                        operationId: current.draftOperationId, jobId: current.jobId, taxonId: taxonId,
                        credential: credential, context: lease
                    )
                } else {
                    throw AnalysisHTTPError.invalidResponse
                }
                guard !Task.isCancelled, connection.snapshot == expected else { throw SyncWireValidationError.invalidSession }
                try store(current)
            }
            return connection.snapshot == expected ? .ready : .failed
        } catch let error as APIErrorResponse where error.error.code == "DRAFT_EXPIRED" {
            guard !Task.isCancelled, connection.snapshot == expected else { return .failed }
            discardJournal()
            return .expired
        } catch {
            if !Task.isCancelled, connection.snapshot == expected { failed = true }
            return .failed
        }
    }

    func acceptDestination(_ expected: CatalogueSDKSnapshot, from original: CatalogueSDKSnapshot) throws {
        guard canResumeDraft(for: original), !expected.isAnonymous, connection.snapshot == expected,
              var current = journal, current.draft != nil, current.destinationOwner == nil else {
            throw SyncWireValidationError.invalidSession
        }
        current.destinationOwner = expected.session.userId
        try store(current)
    }

    func pending(for expected: CatalogueSDKSnapshot) -> Bool {
        !expected.isAnonymous && journal?.validSource == true
            && journal?.destinationOwner == expected.session.userId && journal?.receipt == nil
    }

    var receipt: GuestPhotoClaimReceipt? {
        guard let expected = connection.snapshot, !expected.isAnonymous,
              journal?.destinationOwner == expected.session.userId else { return nil }
        return journal?.receipt
    }

    func transfer() async {
        guard !busy, let expected = connection.snapshot, pending(for: expected),
              var current = journal, let draft = current.draft, let api = connection.apiClient else { return }
        busy = true
        failed = false
        defer { busy = false }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            try await api.bindPhotoInstallation(id: current.installationId, credential: credential, context: lease)
            if current.proof == nil {
                current.proof = try await api.preparePhotoClaim(
                    operationId: current.prepareOperationId, draftId: draft.draftId, credential: credential, context: lease
                )
                guard !Task.isCancelled, connection.snapshot == expected else { throw SyncWireValidationError.invalidSession }
                try store(current)
            }
            guard let proof = current.proof else { throw AnalysisHTTPError.invalidResponse }
            let receipt: GuestPhotoClaimReceipt
            do {
                receipt = try await api.commitPhotoClaim(
                    operationId: current.commitOperationId, claimId: proof.claimId, credential: credential, context: lease
                )
            } catch let error as APIErrorResponse where error.error.code == "CONFLICT" && error.error.retryable {
                // Try the frozen commit first. An earlier successful receipt can still replay after proof expiry.
                let refreshed = try await api.preparePhotoClaim(
                    operationId: current.prepareOperationId, draftId: draft.draftId, credential: credential, context: lease
                )
                guard refreshed.claimId == proof.claimId else { throw AnalysisHTTPError.invalidResponse }
                guard !Task.isCancelled, connection.snapshot == expected else { throw SyncWireValidationError.invalidSession }
                current.proof = refreshed
                try store(current)
                receipt = try await api.commitPhotoClaim(
                    operationId: current.commitOperationId, claimId: proof.claimId, credential: credential, context: lease
                )
            }
            guard !Task.isCancelled, connection.snapshot == expected else { throw SyncWireValidationError.invalidSession }
            guard receipt.photoId == current.photoId else { throw AnalysisHTTPError.invalidResponse }
            current.receipt = receipt
            try store(current)
        } catch let error as APIErrorResponse where error.error.code == "DRAFT_EXPIRED" {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            discardJournal()
        } catch {
            if !Task.isCancelled, connection.snapshot == expected { failed = true }
        }
    }

    private func store(_ value: Journal) throws {
        connection.storeGuestPhotoClaimData(try JSONEncoder().encode(value))
        journal = value
    }

    private func discardJournal() {
        journal = nil
        connection.storeGuestPhotoClaimData(nil)
    }
}

@MainActor
private struct GuestPhotoTransferView: View {
    let claim: GuestPhotoClaim
    let openCollection: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if claim.receipt != nil {
                Text("Plant and photo saved.")
                    .accessibilityIdentifier("staging.guest.claim.status")
                Button("Open My plants", action: openCollection)
                    .accessibilityIdentifier("staging.guest.claim.collection")
            } else if claim.failed {
                Text("Couldn’t finish saving your plant.")
                    .accessibilityIdentifier("staging.guest.claim.status")
                Button("Retry transfer") { Task { await claim.transfer() } }
                    .accessibilityIdentifier("staging.guest.claim.retry")
            } else if let scope = claim.connection.snapshot, claim.pending(for: scope) {
                ProgressView("Saving your plant and photo…")
                    .accessibilityIdentifier("staging.guest.claim.status")
            } else {
                Button("Choose a photo") { dismiss() }
                    .accessibilityIdentifier("staging.guest.claim.closed")
            }
            Button("Close") { dismiss() }
        }
        .padding()
        .task { await claim.transfer() }
    }
}

#if DEBUG && (targetEnvironment(simulator) || NARAT_DEVICE_STAGING_ANALYSIS)
private struct StagingAccountPresentation: Identifiable {
    let id = UUID()
    let connection: CatalogueConnection
    var guestTransfer = false
}

#endif

private struct AccountSignInView: View {
    let connection: CatalogueConnection
    var staging = false
    let cancel: (() -> Void)?
    let signedIn: @MainActor (CatalogueSDKSnapshot, CatalogueSDKSnapshot?) -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var failed = false
    @State private var scope: CatalogueAccountScope?
    @State private var presenter: UIViewController?
    @State private var work: Task<Void, Never>?
    @State private var active = false
    @State private var completed = false

    private var busy: Bool { signingIn || connection.authenticationInFlight }

    var body: some View {
        NavigationStack {
            Form {
                if !staging {
                    ForEach(connection.accountProviders, id: \.rawValue) { provider in
                        Button(provider == .apple ? "Continue with Apple" : "Continue with Google") {
                            signIn(provider)
                        }
                        .disabled(busy || scope == nil || presenter?.viewIfLoaded?.window == nil)
                        .accessibilityIdentifier("account.signin." + provider.rawValue)
                    }
                }
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .accessibilityIdentifier(staging ? "staging.email" : "account.email")
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier(staging ? "staging.password" : "account.password")
                if failed {
                    Text(staging ? "Could not sign in to the test stand. Check the test account." : "Couldn’t sign in. Check your email and password and try again.")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(staging ? "staging.signin.error" : "account.signin.error")
                }
                Button(signingIn ? "Signing in…" : "Sign in") {
                    signIn()
                }
                .disabled(busy || scope == nil || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                .accessibilityIdentifier(staging ? "staging.signin" : "account.signin")
            }
            .navigationTitle(staging ? "Test account" : "Sign in to Narat")
            .toolbar {
                if let cancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: cancel).disabled(busy)
                    }
                }
            }
        }
        .background(CatalogueWindowPresenter(controller: $presenter).frame(width: 0, height: 0))
        .interactiveDismissDisabled(cancel == nil || busy)
        .task {
            active = true
            guard scope == nil else { return }
            do { scope = try await connection.accountScope() }
            catch { failed = true }
        }
        .onDisappear {
            active = false
            work?.cancel()
            password = ""
        }
    }

    private func signIn() {
        guard !busy, let scope else { return }
        let loginEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginPassword = password
        password = ""
        start(scope: scope) {
            try await connection.signInAccount(email: loginEmail, password: loginPassword, scope: scope)
        }
    }

    private func signIn(_ provider: NativeAuthProvider) {
        guard !busy, let scope, let presenter, presenter.viewIfLoaded?.window != nil else { return }
        start(scope: scope) {
            try await connection.signInAccount(with: provider, presenting: presenter, scope: scope)
        }
    }

    private func start(
        scope: CatalogueAccountScope,
        action: @escaping @MainActor () async throws -> CatalogueSDKSnapshot?
    ) {
        guard active, !completed else { return }
        signingIn = true
        failed = false
        work = Task { @MainActor in
            defer {
                signingIn = false
                work = nil
            }
            do {
                guard let snapshot = try await action() else { return }
                guard active, !completed, !Task.isCancelled, connection.snapshot == snapshot else { return }
                completed = true
                signedIn(snapshot, scope.snapshot)
            } catch {
                if active, !Task.isCancelled { failed = true }
            }
        }
    }
}

private struct PlantHomeView<GuestActions: View>: View {
    let polish: Bool
    let busy: Bool
    let unavailable: Bool
    let guestAccessFailed: Bool
    let check: () -> Void
    let identify: () -> Void
    let browse: () -> Void
    let collection: () -> Void
    @ViewBuilder let guestActions: () -> GuestActions

    private let green = Color(red: 0.13, green: 0.33, blue: 0.22)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Narat")
                        .font(.system(.largeTitle, design: .serif).weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("welcome.title")
                    Spacer()
                    Button(action: collection) {
                        Label(polish ? "Moje rośliny" : "My plants", systemImage: "leaf")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("collection.open").disabled(unavailable)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "leaf.circle")
                        .font(.system(size: 44, weight: .light))
                        .accessibilityHidden(true)
                    Text(polish ? "Jak się ma Twoja roślina?" : "How’s your plant doing?")
                        .font(.system(.largeTitle, design: .serif).weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(polish ? "Dodaj zdjęcie, aby sprawdzić, czego może potrzebować Twoja roślina." : "Use a photo to see what your plant might need.")
                        .font(.body)
                    Button(action: check) {
                        Label(polish ? "Sprawdź roślinę" : "Check a plant", systemImage: "camera")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(green)
                    .accessibilityIdentifier("welcome.check").disabled(unavailable)
                }
                .foregroundStyle(.white)
                .padding(24)
                .background(green, in: RoundedRectangle(cornerRadius: 28))

                VStack(spacing: 0) {
                    destination(polish ? "Rozpoznaj roślinę" : "Identify a plant", systemImage: "viewfinder", id: "welcome.identify", action: identify)
                        .disabled(unavailable)
                    Divider().padding(.leading, 52)
                    destination(polish ? "Przeglądaj katalog" : "Browse catalogue", systemImage: "books.vertical", id: "welcome.catalogue", action: browse)
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))

                guestActions()

                if unavailable {
                    Text(polish ? "Narat nie może się teraz połączyć. Sprawdź ustawienia połączenia aplikacji." : "Narat can’t connect right now. Check the app’s connection settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("welcome.unavailable")
                }
                if guestAccessFailed {
                    Text(polish ? "Nie udało się rozpocząć analizy zdjęcia. Spróbuj ponownie." : "Couldn’t start photo analysis. Try again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("welcome.guest.error")
                }
                if busy {
                    ProgressView(polish ? "Otwieranie…" : "Opening…")
                        .accessibilityIdentifier("welcome.opening")
                }
            }
            .padding(22)
            .disabled(busy)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func destination(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title).font(.body.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
