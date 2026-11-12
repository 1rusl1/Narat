import SwiftUI
#if DEBUG && targetEnvironment(simulator)
import Observation
import Supabase
#endif

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
    @Bindable var languageStore: LanguageStore
    @Bindable var analysisModel: AnalysisFlowModel

    @State private var catalogue: CatalogueConnection?
    @State private var showingCollection = false
    @State private var starting = false
    @State private var startupFailed = false
#if DEBUG && targetEnvironment(simulator)
    @State private var stagingAccount: StagingAccountPresentation?
    @State private var stagingResume: CatalogueResumeSelection?
    @State private var stagingResumeLocked = false
    @State private var stagingSpecies: PublishedSpeciesCard?
    @State private var stagingGuestClaim: StagingGuestPhotoClaim?
    @State private var showingGuestTransfer = false
    @State private var openClaimCollection = false
#endif
#if DEBUG
    @State private var fixtureContext: CatalogueUIFixtureContext?
#endif

    private var isPolish: Bool {
        languageStore.currentLocale == .pl
    }

    private var isStagingAnalysis: Bool {
#if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--narat-staging-analysis")
#else
        false
#endif
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if !isStagingAnalysis {
                Picker("profile.language.picker", selection: $languageStore.currentLocale) {
                    Text("Polski").tag(SupportedLocale.pl)
                    Text("English").tag(SupportedLocale.en)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityIdentifier("welcome.language.picker")
                }

                if startupFailed {
                    Text(isPolish ? "Katalog jest niedostępny." : "Catalogue unavailable.")
                        .accessibilityIdentifier("catalogue.error")
                }
                switch analysisModel.router.flowState.currentStep {
                case .selectIntent:
                    welcomeIntentSection
                case .selectCareMethod:
                    careMethodPickerSection
                case .selectCatalogueSpecies:
                    if let catalogue {
#if DEBUG && targetEnvironment(simulator)
                        if isStagingAnalysis, let resumed = stagingResume {
                            ScrollView {
                                CatalogueSaveView(
                                    connection: catalogue, speciesSlug: resumed.speciesSlug,
                                    displayName: stagingSpecies?.displayName ?? (resumed.identification == nil ? resumed.speciesSlug : "Plant"),
                                    scientificName: stagingSpecies?.scientificName ?? "", polish: false,
                                    analysisSaveIdentity: resumed.flowId,
                                    identification: resumed.identification,
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
                            GuestCatalogueView(connection: catalogue, polish: isPolish) {
                                analysisModel.router.navigateBack()
                            }
                        }
#else
                        GuestCatalogueView(connection: catalogue, polish: isPolish) {
                            analysisModel.router.navigateBack()
                        }
#endif
                    } else {
                        if !startupFailed { ProgressView() }
                        Button(isPolish ? "Wstecz" : "Back") {
                            analysisModel.router.navigateBack()
                        }
                        .accessibilityIdentifier("catalogue.back")
                    }
                case .selectPhoto, .careQuestions:
                    CareQuestionsView(model: analysisModel, languageStore: languageStore)
                case .analyzing, .preliminaryResult, .diagnosticRefinement:
                    PreliminaryResultView(
                        model: analysisModel, languageStore: languageStore,
                        catalogueConnection: isStagingAnalysis ? catalogue : nil,
                        guestActions: guestIdentificationActions
                    )
                default:
                    welcomeIntentSection
                }
                if catalogue != nil,
                   [.selectIntent, .selectCatalogueSpecies].contains(analysisModel.router.flowState.currentStep) {
                    Button(isPolish ? "Moje rośliny" : "My plants") { showingCollection = true }
                        .accessibilityIdentifier("collection.open")
                }
#if DEBUG && targetEnvironment(simulator)
                if analysisModel.router.flowState.currentStep == .selectIntent,
                   let claim = stagingGuestClaim, let scope = catalogue?.snapshot, claim.canResumeDraft(for: scope) {
                    Button("Continue saving") {
                        Task { @MainActor in
                            handleGuestDraft(await claim.resumeDraft(), claim: claim)
                        }
                    }
                    .disabled(claim.busy)
                    .accessibilityIdentifier("staging.guest.draft.resume")
                    if claim.failed { Text("Couldn’t prepare your plant. Try again.") }
                }
                if let claim = stagingGuestClaim, let scope = catalogue?.snapshot, claim.pending(for: scope),
                   !showingGuestTransfer {
                    Button("Finish saving your plant") { showingGuestTransfer = true }
                        .accessibilityIdentifier("staging.guest.claim.resume")
                }
#endif
            }
        }
        .task { await prepareCatalogue() }
        .sheet(isPresented: $showingCollection) {
            if let catalogue { CatalogueCollectionView(connection: catalogue, polish: isPolish) }
        }
#if DEBUG && targetEnvironment(simulator)
        .sheet(item: $stagingAccount, onDismiss: showPendingGuestTransfer) { account in
            StagingAccountView(
                connection: account.connection,
                cancel: account.guestTransfer ? { stagingAccount = nil } : nil
            ) { snapshot in finishStagingSignIn(account, snapshot: snapshot) }
        }
        .sheet(isPresented: $showingGuestTransfer, onDismiss: {
            if openClaimCollection {
                openClaimCollection = false
                showingCollection = true
            }
        }) {
            if let claim = stagingGuestClaim {
                StagingGuestTransferView(claim: claim) {
                    openClaimCollection = true
                    showingGuestTransfer = false
                }
            }
        }
#endif
    }

    private var guestIdentificationActions: GuestIdentificationActions? {
#if DEBUG && targetEnvironment(simulator)
        guard let claim = stagingGuestClaim, catalogue?.snapshot?.isAnonymous == true else { return nil }
        return GuestIdentificationActions(busy: claim.busy, failed: claim.failed) { selection in
            Task { @MainActor in
                handleGuestDraft(await claim.createDraft(selection), claim: claim)
            }
        }
#else
        return nil
#endif
    }

    @MainActor
    private func prepareCatalogue() async {
        guard !starting else { return }
        starting = true
#if DEBUG && targetEnvironment(simulator)
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
            catalogue = CatalogueConnection()
        }
#else
        catalogue = CatalogueConnection()
#endif
        guard let catalogue else { return }
        do {
            _ = try await catalogue.sessionOwner()
            guard analysisModel.router.flowState.currentStep == .selectIntent else { return }
            let expected = try await catalogue.sessionSnapshot()
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

#if DEBUG && targetEnvironment(simulator)
    private func handleGuestDraft(_ outcome: StagingGuestPhotoClaim.DraftOutcome, claim: StagingGuestPhotoClaim) {
        switch outcome {
        case .ready:
            stagingAccount = StagingAccountPresentation(connection: claim.connection, guestTransfer: true)
        case .expired:
            if analysisModel.router.flowState.currentStep == .preliminaryResult { analysisModel.returnFromAnalysis() }
        case .failed:
            break
        }
    }

    @MainActor
    private func prepareStagingAnalysis() async {
        guard let config = try? NativeAuthConfiguration(),
              StagingAnalysisService.isEnabled(
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
            let claim = StagingGuestPhotoClaim(
                connection: connection, credential: KeychainInstallationCredentialStore().getOrCreateCredential()
            )
            stagingGuestClaim = claim
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
    private func finishStagingSignIn(_ account: StagingAccountPresentation, snapshot: CatalogueSDKSnapshot) {
        if account.guestTransfer {
            do {
                guard let claim = stagingGuestClaim else { throw SyncWireValidationError.invalidSession }
                try claim.acceptDestination(snapshot)
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

    private func showPendingGuestTransfer() {
        guard let claim = stagingGuestClaim, let snapshot = catalogue?.snapshot,
              claim.pending(for: snapshot) else { return }
        showingGuestTransfer = true
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
        guard let api = connection.apiClient else { return }
        let identificationEnabled = ProcessInfo.processInfo.arguments.contains("--narat-staging-identification")
        analysisModel.installAnalysisService(StagingAnalysisService(
            api: api, identificationEnabled: identificationEnabled, guestCredential: guestCredential
        ) {
            let snapshot = try await connection.sessionSnapshot()
            guard snapshot.isAnonymous == (guestCredential != nil), snapshot.session.userId == owner else {
                throw AnalysisServiceFailure.unavailable
            }
            let lease = try await api.captureSyncContext(ownerId: owner)
            guard connection.snapshot == snapshot else { throw SyncWireValidationError.invalidSession }
            return lease
        })
    }
#endif

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

#if DEBUG && targetEnvironment(simulator)
@MainActor
final class StagingAnalysisService: AnalysisService {
    private struct Progress {
        let request: AnalysisServiceRequest
        let ownerId: UUID
        var photoId: UUID?
        var uploadAttempted = false
        var photoReady = false
        var jobId: UUID?
    }

    private let api: PlantsAPIClient
    private let identificationEnabled: Bool
    private let guestCredential: String?
    private let session: @MainActor () async throws -> SyncSessionLease
    private var previous: Progress?
    private var activeAttempt: UUID?

    init(api: PlantsAPIClient, identificationEnabled: Bool = false, guestCredential: String? = nil,
         session: @escaping @MainActor () async throws -> SyncSessionLease) {
        self.api = api
        self.identificationEnabled = identificationEnabled
        self.guestCredential = guestCredential
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
        guard (guestCredential == nil && request.mode == .diagnosis) || (identificationEnabled && request.mode == .identification) else {
            throw AnalysisServiceFailure.unavailable
        }
        try Task.checkCancellation()
        let attempt = UUID()
        activeAttempt = attempt
        defer { if activeAttempt == attempt { activeAttempt = nil } }
        let lease = try await session()
        try verify(lease, attempt: attempt)

        var progress = Progress(request: request, ownerId: lease.ownerId)
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
            var job: AnalysisJobWire
            if let jobId = progress.jobId {
                job = try await api.fetchAnalysisJob(id: jobId, mode: request.mode, locale: locale, context: lease, guestCredential: guestCredential)
            } else {
                job = try await api.createAnalysisJob(
                    operationId: request.operationId, mode: request.mode, photoAssetId: photoId,
                    flowId: request.mode == .identification ? request.flowId : nil,
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
                job = try await api.fetchAnalysisJob(id: job.jobId, mode: request.mode, locale: locale, context: lease, guestCredential: guestCredential)
                try verify(lease, attempt: attempt)
            }
            if job.status == .failed, job.errorCode?.hasPrefix("PROVIDER_") == true {
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
                uploadedPhotoId: photoId
            )
        } catch let error as APIErrorResponse where error.error.code == "QUOTA_REGISTRATION_REQUIRED" {
            throw AnalysisServiceFailure.quotaRegistrationRequired
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
final class StagingGuestPhotoClaim {
    enum DraftOutcome: Equatable { case ready, expired, failed }

    private struct Journal: Codable, Equatable {
        let guestOwner: UUID
        let installationId: UUID
        let jobId: UUID
        let taxonId: UUID
        let photoId: UUID
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
        guard !busy, let expected = connection.snapshot, expected.isAnonymous,
              selection.ownerId == expected.session.userId, let installationId else { return .failed }
        failed = false
        do {
            if let journal, journal.receipt == nil {
                guard canResumeDraft(for: expected), journal.jobId == selection.jobId,
                      journal.taxonId == selection.taxonId, journal.photoId == selection.photoAssetId else {
                    throw AnalysisHTTPError.invalidResponse
                }
            } else {
                try store(Journal(
                    guestOwner: expected.session.userId, installationId: installationId,
                    jobId: selection.jobId, taxonId: selection.taxonId, photoId: selection.photoAssetId,
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
        guard expected.isAnonymous, let installationId, let journal else { return false }
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
                current.draft = try await api.createPhotoDraft(
                    operationId: current.draftOperationId, jobId: current.jobId, taxonId: current.taxonId,
                    credential: credential, context: lease
                )
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

    func acceptDestination(_ expected: CatalogueSDKSnapshot) throws {
        guard !expected.isAnonymous, connection.snapshot == expected,
              var current = journal, current.draft != nil, current.destinationOwner == nil else {
            throw SyncWireValidationError.invalidSession
        }
        current.destinationOwner = expected.session.userId
        try store(current)
    }

    func pending(for expected: CatalogueSDKSnapshot) -> Bool {
        !expected.isAnonymous && journal?.destinationOwner == expected.session.userId && journal?.receipt == nil
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
private struct StagingGuestTransferView: View {
    let claim: StagingGuestPhotoClaim
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

private struct StagingAccountPresentation: Identifiable {
    let id = UUID()
    let connection: CatalogueConnection
    var guestTransfer = false
}

private struct StagingAccountView: View {
    let connection: CatalogueConnection
    let cancel: (() -> Void)?
    let signedIn: @MainActor (CatalogueSDKSnapshot) -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .accessibilityIdentifier("staging.email")
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("staging.password")
                if failed {
                    Text("Could not sign in to the test stand. Check the test account.")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("staging.signin.error")
                }
                Button(signingIn ? "Signing in…" : "Sign in") {
                    signIn()
                }
                .disabled(signingIn || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                .accessibilityIdentifier("staging.signin")
            }
            .navigationTitle("Test account")
            .toolbar {
                if let cancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: cancel).disabled(signingIn)
                    }
                }
            }
        }
        .interactiveDismissDisabled(cancel == nil || signingIn)
    }

    private func signIn() {
        guard !signingIn, let client = connection.client else { return }
        let loginEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginPassword = password
        password = ""
        signingIn = true
        failed = false
        Task { @MainActor in
            defer { signingIn = false }
            do {
                let session = try await client.auth.signIn(email: loginEmail, password: loginPassword)
                let snapshot = try await connection.sessionSnapshot()
                guard !snapshot.isAnonymous, snapshot.session.userId == session.user.id,
                      snapshot.session.accessToken == session.accessToken else {
                    throw AnalysisServiceFailure.unavailable
                }
                signedIn(snapshot)
            } catch {
                failed = true
            }
        }
    }
}
#endif
