import SwiftUI
#if DEBUG && targetEnvironment(simulator)
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
                                    displayName: stagingSpecies?.displayName ?? resumed.speciesSlug,
                                    scientificName: stagingSpecies?.scientificName ?? "", polish: false,
                                    analysisSaveIdentity: resumed.flowId,
                                    selectionLocked: $stagingResumeLocked
                                ) { EmptyView() }
                                .id(resumed.flowId)
                                .padding()
                            }
                            .task(id: resumed.flowId) {
                                stagingSpecies = nil
                                let species = try? await catalogue.apiClient?.fetchPublishedSpecies(
                                    slug: resumed.speciesSlug, locale: .en
                                )
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
                        catalogueConnection: isStagingAnalysis ? catalogue : nil
                    )
                default:
                    welcomeIntentSection
                }
                if catalogue != nil,
                   [.selectIntent, .selectCatalogueSpecies].contains(analysisModel.router.flowState.currentStep) {
                    Button(isPolish ? "Moje rośliny" : "My plants") { showingCollection = true }
                        .accessibilityIdentifier("collection.open")
                }
            }
        }
        .task { await prepareCatalogue() }
        .sheet(isPresented: $showingCollection) {
            if let catalogue { CatalogueCollectionView(connection: catalogue, polish: isPolish) }
        }
#if DEBUG && targetEnvironment(simulator)
        .sheet(item: $stagingAccount) { account in
            StagingAccountView(connection: account.connection) { snapshot in
                installStagingAnalysis(connection: account.connection, owner: snapshot.session.userId)
                stagingAccount = nil
                Task { await restoreStagingCard(connection: account.connection) }
            }
        }
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
        if let snapshot = try? await connection.sessionSnapshot(), !snapshot.isAnonymous {
            installStagingAnalysis(connection: connection, owner: snapshot.session.userId)
            await restoreStagingCard(connection: connection)
        } else {
            stagingAccount = StagingAccountPresentation(connection: connection)
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
    private func installStagingAnalysis(connection: CatalogueConnection, owner: UUID) {
        guard let api = connection.apiClient else { return }
        analysisModel.installAnalysisService(StagingAnalysisService(api: api) {
            let snapshot = try await connection.sessionSnapshot()
            guard !snapshot.isAnonymous, snapshot.session.userId == owner else {
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
        let operationId: UUID
        let ownerId: UUID
        var photoId: UUID?
        var uploadAttempted = false
        var photoReady = false
        var jobId: UUID?
    }

    private let api: PlantsAPIClient
    private let session: @MainActor () async throws -> SyncSessionLease
    private var previous: Progress?
    private var activeAttempt: UUID?

    init(api: PlantsAPIClient, session: @escaping @MainActor () async throws -> SyncSessionLease) {
        self.api = api
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
        guard request.mode == .diagnosis else { throw AnalysisServiceFailure.unavailable }
        try Task.checkCancellation()
        let attempt = UUID()
        activeAttempt = attempt
        defer { if activeAttempt == attempt { activeAttempt = nil } }
        let lease = try await session()
        try verify(lease, attempt: attempt)

        var progress = Progress(operationId: request.operationId, ownerId: lease.ownerId)
        if let previous, previous.operationId == request.operationId {
            guard previous.ownerId == lease.ownerId else { throw AnalysisServiceFailure.unavailable }
            progress = previous
        }
        defer { if activeAttempt == attempt { previous = progress } }
        let locale = request.locale

        do {
            if progress.uploadAttempted, !progress.photoReady, let photoId = progress.photoId {
                do {
                    try await api.confirmAnalysisPhoto(id: photoId, locale: locale, context: lease)
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
                    jpeg: jpeg, operationId: request.uploadOperationId, locale: locale, context: lease
                )
                try verify(lease, attempt: attempt)
                guard progress.photoId == nil || progress.photoId == ticket.photoAssetId else {
                    throw AnalysisHTTPError.invalidResponse
                }
                progress.photoId = ticket.photoAssetId
                progress.uploadAttempted = true
                if ticket.expiresInSeconds == 0 {
                    try await api.confirmAnalysisPhoto(id: ticket.photoAssetId, locale: locale, context: lease)
                } else {
                    try await api.uploadAnalysisJPEG(jpeg, ticket: ticket, locale: locale, context: lease)
                }
                try verify(lease, attempt: attempt)
                progress.photoReady = true
            }
            guard let photoId = progress.photoId else { throw AnalysisHTTPError.invalidResponse }
            var job: AnalysisJobWire
            if let jobId = progress.jobId {
                job = try await api.fetchAnalysisJob(id: jobId, mode: request.mode, locale: locale, context: lease)
            } else {
                job = try await api.createAnalysisJob(
                    operationId: request.operationId, mode: request.mode, photoAssetId: photoId,
                    locale: locale, context: lease
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
                job = try await api.fetchAnalysisJob(id: job.jobId, mode: request.mode, locale: locale, context: lease)
                try verify(lease, attempt: attempt)
            }
            if job.status == .failed, job.errorCode?.hasPrefix("PROVIDER_") == true {
                throw AnalysisServiceFailure.providerFailed
            }
            guard job.status == .succeeded, let result = job.result else {
                throw AnalysisServiceFailure.unavailable
            }
            return AnalysisServiceResult(
                analysis: result.domainValue,
                speciesLabel: result.plantDisplayName,
                conditionLabel: result.conditionDisplayName
            )
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

private struct StagingAccountPresentation: Identifiable {
    let id = UUID()
    let connection: CatalogueConnection
}

private struct StagingAccountView: View {
    let connection: CatalogueConnection
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
        }
        .interactiveDismissDisabled()
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
                _ = try await client.auth.signIn(email: loginEmail, password: loginPassword)
                let snapshot = try await connection.sessionSnapshot()
                guard !snapshot.isAnonymous else { throw AnalysisServiceFailure.unavailable }
                signedIn(snapshot)
            } catch {
                failed = true
            }
        }
    }
}
#endif
