import SwiftUI
import Combine
import Supabase
import Observation
import Network
import UIKit

/// The ordinary My plants route and its held-SDK tests execute this same fence.
@MainActor
@Observable
final class CollectionOpeningCoordinator {
    struct Request {
        let id = UUID()
        let connection: ObjectIdentifier
        let locale: SupportedLocale
    }

    private(set) var starting = false
    private(set) var preparationSettled = false
    private(set) var active: Request?
    var busy: Bool { active != nil }

    func beginPreparation() -> Bool {
        guard !starting else { return false }
        starting = true
        return true
    }

    func finishPreparation() { preparationSettled = true }

    func begin(
        connection: CatalogueConnection, locale: SupportedLocale,
        presentationAvailable: Bool = true
    ) -> Request? {
        guard preparationSettled, active == nil, presentationAvailable else { return nil }
        let request = Request(connection: ObjectIdentifier(connection), locale: locale)
        active = request
        return request
    }

    /// A replaced connection retires intent; a transient nil snapshot does not.
    func connectionReplaced() { active = nil }

    /// Irrevocable retirement at Root's synchronous presentation boundary.
    /// Dismissal never restores the old UUID, even if availability returns.
    func presentationBegan() { active = nil }

    func execute(
        _ request: Request, connection: CatalogueConnection,
        currentConnection: @MainActor () -> CatalogueConnection?,
        currentLocale: @MainActor () -> SupportedLocale,
        presentationAvailable: @MainActor () -> Bool = { true },
        publish: @MainActor (CatalogueCollectionOpeningOutcome) -> Void
    ) async {
        defer {
            // Locale can change while suspended. Only the UUID owns busy cleanup.
            if active?.id == request.id { active = nil }
        }
        func isCurrent() -> Bool {
            !Task.isCancelled && active?.id == request.id
                && request.connection == ObjectIdentifier(connection)
                && currentConnection().map { ObjectIdentifier($0) } == request.connection
                && currentLocale() == request.locale
                && presentationAvailable()
        }
        guard isCurrent() else { return }
        let outcome = await connection.collectionOpeningSnapshot(isRequestCurrent: isCurrent)
        guard isCurrent() else { return }
        switch outcome {
        case .permanent(let snapshot):
            guard connection.snapshot == snapshot, !snapshot.isAnonymous else { return }
            publish(outcome)
        case .loginRequired, .temporarilyUnavailable:
            publish(outcome)
        case .superseded:
            break
        }
    }
}

@main
struct PlantsApp: App {
    @State private var languageStore = LanguageStore()
    @State private var analysisModel = AnalysisFlowModel()
    @UIApplicationDelegateAdaptor(CareReminderAppDelegate.self) private var appDelegate
    @StateObject private var reminderBootstrap = CareReminderBootstrap()

    var body: some Scene {
        WindowGroup {
            Group {
                switch reminderBootstrap.startup {
                case .loading:
                    ProgressView()
                case .failed:
                    Text("Unable to start.")
                case .ordinary(let runtime):
                    RootContainerView(languageStore: languageStore,
                                      analysisModel: analysisModel, careReminderRuntime: runtime,
                                      careReminderInbox: appDelegate.inbox)
#if DEBUG
                case .fixture(let fixture):
                    RootContainerView(languageStore: languageStore,
                                      analysisModel: analysisModel, careReminderRuntime: fixture.runtime,
                                      careReminderInbox: appDelegate.inbox,
                                      preloadedReminderFixture: fixture)
                        .environment(\.reminderConsentFixture, fixture)
#endif
                }
            }
            .task { await reminderBootstrap.prepare() }
            .environment(\.locale, languageStore.currentLocale.locale)
            .onOpenURL { url in
                _ = NativeIdentityProvider.handleCallbackURL(url)
            }
        }
    }
}


/// Serializes real lifecycle requests; idle only resumes a request that got busy.
/// It never treats a completed pass as confirmation of an individual care action.
@MainActor
final class CareLifecycleCoordinator {
    typealias Action = @MainActor () async -> CareReconciliationOutcome?
    private var pending: (generation: UInt64, action: Action)?
    private var lifecycleGeneration: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var current: Task<CareReconciliationOutcome?, Never>?
    private var waitingForIdle = false
    private var idleGeneration: UInt64 = 0

    func request(replacingCurrent: Bool = false, _ action: @escaping Action) {
        lifecycleGeneration &+= 1
        pending = (lifecycleGeneration, action)
        waitingForIdle = false
        if replacingCurrent { current?.cancel() }
        startIfNeeded()
    }

    @discardableResult
    func suspend() -> Task<Void, Never>? {
        lifecycleGeneration &+= 1
        pending = nil
        waitingForIdle = false
        current?.cancel()
        return worker
    }

    func didBecomeIdle() {
        idleGeneration &+= 1
        guard waitingForIdle else { return }
        waitingForIdle = false
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard worker == nil, !waitingForIdle, pending != nil else { return }
        worker = Task { await drainRequests() }
    }

    private func drainRequests() async {
        while let request = pending {
            pending = nil
            let before = idleGeneration
            let pass = Task { await request.action() }
            current = pass
            let outcome = await pass.value
            current = nil
            if outcome == .busy, pending == nil, !pass.isCancelled,
               request.generation == lifecycleGeneration {
                pending = request
                // A foreign drain can finish before its busy result reaches this actor.
                if before == idleGeneration {
                    waitingForIdle = true
                    break
                }
            }
        }
        worker = nil
    }
}

/// Shared by Root and regression tests; this reader never establishes an SDK session.
@MainActor
enum CareReminderRootRouting {
    typealias Coordinator = CareReminderTapCoordinator<CatalogueSDKSnapshot>

    static func current(connection: CatalogueConnection, snapshot: CatalogueSDKSnapshot,
                        locale: SupportedLocale, runtime: CareReminderRuntime,
                        currentConnection: CatalogueConnection?, currentLocale: SupportedLocale,
                        currentRuntime: CareReminderRuntime) -> Bool {
        currentConnection === connection && currentRuntime === runtime
            && currentLocale == locale && connection.authClassification == .permanent(snapshot)
    }

    static func source(connection: CatalogueConnection, snapshot: CatalogueSDKSnapshot,
                       locale: String, isCurrent: @escaping @MainActor () -> Bool) -> Coordinator.Source {
        let authority = connection.apiClient?.syncAuthority
        let repository = connection.repository
        // SDK's read-only classification includes cancellation. Cancellation is HOLD,
        // not proof of logout; a replacement Root task checks the original scope again.
        let valid: @MainActor () -> Bool = { Task.isCancelled || isCurrent() }
        return .init(connection: ObjectIdentifier(connection), ownerId: snapshot.session.userId,
                     snapshot: snapshot, locale: locale, isCurrent: valid, readCache: {
            try await read(ownerId: snapshot.session.userId, authority: authority,
                           isCurrent: valid) { lease in
                guard let repository else { return nil }
                return try await repository.cachedCareOverview(context: lease)
            }
        })
    }

    static func read(ownerId: UUID, authority: SyncSessionAuthority?,
                     isCurrent: @MainActor () -> Bool,
                     cache: @MainActor (SyncSessionLease) async throws -> CareOverviewViewState?)
        async throws -> CareOverviewViewState? {
        try Task.checkCancellation()
        guard isCurrent(), let authority else { return nil }
        let lease: SyncSessionLease
        do {
            lease = try authority.capture(ownerId: ownerId)
            try authority.withPermanentBoundValid(lease) {}
        } catch { return nil }
        let state = try await cache(lease)
        guard isCurrent() else { return nil }
        try authority.withPermanentBoundValid(lease) {}
        return state
    }

    /// Each callback is an event, including identical payloads; attachment never replays one.
    static func foregroundEvents(_ inbox: CareReminderNotificationInbox)
        -> AnyPublisher<CareReminderNotificationRoute, Never> {
        inbox.$latestForeground.dropFirst().compactMap { $0 }.eraseToAnyPublisher()
    }

    static func foreground(_ route: CareReminderNotificationRoute, ownerId: UUID,
                           context: CareReminderLifecycle.Context?,
                           isCurrent: () -> Bool, publish: () -> Void) {
        guard route.candidate.ownerId == ownerId, isCurrent(),
              let context, context.lease.ownerId == ownerId, context.isCurrent(),
              (try? context.authority.withPermanentBoundValid(context.lease) {}) != nil else { return }
        publish()
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
    @ObservedObject var careReminderRuntime: CareReminderRuntime
    @ObservedObject var careReminderInbox: CareReminderNotificationInbox
    private var careReminder: CareReminderLifecycle { careReminderRuntime.core }
    @State private var careReminderContext: CareReminderLifecycle.Context?
    @State private var careReminderClockRevision: UInt64 = 0
    @State private var tapCoordinator: CareReminderRootRouting.Coordinator?
    @State private var routingDismissal = false {
        didSet { if routingDismissal { collectionOpening.presentationBegan() } }
    }
    @State private var routingRevision: UInt64 = 0
    private struct RoutingRead: Equatable {
        let intent: UUID?
        let auth: CareReminderRead
        let revision: UInt64
        let modalRevision: UInt64
        let active: Bool
    }
    private struct CareReminderRead: Equatable {
        let connection: ObjectIdentifier?
        let auth: CatalogueAuthClassification
        let locale: SupportedLocale
    }
    private struct CareReminderClockRead: Equatable {
        let auth: CareReminderRead
        let deadline: Date?
        let revision: UInt64
    }
    @State private var trialReminder = TrialReminderScheduler()
    @State private var careLifecycle = CareLifecycleCoordinator()
    @State private var careReconnectRevision: UInt64 = 0
    private struct CareLifecycleRead: Equatable {
        let snapshot: CatalogueSDKSnapshot?
        let active: Bool
        let reconnectRevision: UInt64
        let locale: SupportedLocale
    }
    private struct TodayContext {
        let snapshot: CatalogueSDKSnapshot
        let lease: SyncSessionLease
        let scope: TodayModel.Scope
    }
    @State private var todayModel = TodayModel()
    @State private var todayContext: TodayContext?
    @State private var todayLocalRead: Task<Void, Never>?
    @State private var todayRevision: UInt64 = 0
    @State private var todayFenced = true
    @State private var todayUnavailable = false
    private struct CollectionPresentation: Identifiable {
        let id = UUID()
        let target: CataloguePlantTarget?

        init(target: CataloguePlantTarget? = nil) { self.target = target }
    }
    private enum AccountDestination: String, Identifiable {
        case diagnosis, identification, collection, guestTransfer
        var id: Self { self }
    }

    @State private var collectionPresentation: CollectionPresentation? {
        didSet { if collectionPresentation != nil { collectionOpening.presentationBegan() } }
    }
    @State private var accountDestination: AccountDestination? {
        didSet { if accountDestination != nil { collectionOpening.presentationBegan() } }
    }
    @State private var collectionAfterSignIn = false
    @State private var opening: AccountDestination? {
        didSet { if opening != nil { collectionOpening.presentationBegan() } }
    }
    @State private var analysisOpeningId: UUID?
    @State private var analysisOwner: UUID?
    @State private var analysisCredential: String?
    @State private var guestPhotoClaim: GuestPhotoClaim?
    @State private var guestAccessFailed = false
    @State private var showingGuestTransfer = false {
        didSet { if showingGuestTransfer { collectionOpening.presentationBegan() } }
    }
    @State private var openClaimCollection = false
    @State private var analysisAccessRepository = AnalysisAccessRepository()
    @State private var collectionOpening = CollectionOpeningCoordinator()
    @State private var collectionOpeningFailed = false
#if DEBUG
    @State private var directEntryVerified = false
#endif
    @State private var startupFailed = false
#if DEBUG && (targetEnvironment(simulator) || NARAT_DEVICE_STAGING_ANALYSIS)
    @State private var stagingAccount: StagingAccountPresentation? {
        didSet { if stagingAccount != nil { collectionOpening.presentationBegan() } }
    }
    @State private var stagingResume: CatalogueResumeSelection? {
        didSet { if stagingResume != nil { collectionOpening.presentationBegan() } }
    }
    @State private var stagingResumeLocked = false
    @State private var stagingSpecies: PublishedSpeciesCard?
#endif
#if DEBUG
    var preloadedReminderFixture: ReminderConsentFixture? = nil
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

    private var isolatesCareReminders: Bool {
#if DEBUG
        if let fixture = preloadedReminderFixture,
           case .fixture(let configuration) = ReminderConsentLaunch.parse(ProcessInfo.processInfo.arguments),
           configuration == fixture.configuration, fixture.runtime === careReminderRuntime,
           let fixtureContext, let catalogue,
           fixture.matches(context: fixtureContext, connection: catalogue) { return false }
        if fixtureContext != nil { return true }
#endif
        return !CareReminderSystemLaunchPolicy.allowsSystem(
            arguments: ProcessInfo.processInfo.arguments)
    }

    private var accountConsentLifecycle: CareReminderLifecycle? {
        guard !isolatesCareReminders, let connection = catalogue,
              case .permanent = connection.authClassification else { return nil }
        return careReminder
    }

    private var consentOwnerId: UUID? {
        guard !isolatesCareReminders, let connection = catalogue,
              case .permanent(let expected) = connection.authClassification,
              let context = careReminderContext, context.isCurrent(),
              context.lease.ownerId == expected.session.userId,
              careReminder.isCurrent(ownerId: expected.session.userId) else { return nil }
        return expected.session.userId
    }

    private var careReminderRead: CareReminderRead {
        CareReminderRead(connection: catalogue.map { ObjectIdentifier($0) },
                         auth: catalogue?.authClassification ?? .unresolved,
                         locale: languageStore.currentLocale)
    }

    private var usesLegacyWelcome: Bool {
#if DEBUG
        isStagingAnalysis || (fixtureContext != nil && fixtureContext?.testsToday != true)
#else
        false
#endif
    }

    private var ownsAnalysisNativeBack: Bool {
        opening != nil || (analysisModel.router.isDirectAnalysisEntry
            && analysisModel.router.flowState.currentStep == .selectPhoto
            && !analysisModel.isReplacingQuestionPhoto)
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
                    if let fixtureContext, fixtureContext.testsSDKOpening,
                       collectionOpening.preparationSettled {
                        Text("Ready").accessibilityIdentifier("sdk-opening.ready")
                        Button("Arm expiry") {
                            do { try fixtureContext.armOpeningExpiry(connection: catalogue) }
                            catch { collectionOpeningFailed = true }
                        }
                        .disabled(collectionOpening.busy)
                        .accessibilityIdentifier("sdk-opening.arm")
                    }
                    if let fixtureContext, fixtureContext.testsToday {
                        HStack {
                            Button("Offline") { try? fixtureContext.changeTodayPhase(.offline) }
                                .accessibilityIdentifier("today.fixture.offline")
                            Button("Fail overview") { try? fixtureContext.changeTodayPhase(.failOverview) }
                                .accessibilityIdentifier("today.fixture.fail")
                            Button("Withdraw") { try? fixtureContext.changeTodayPhase(.withdrawn) }
                                .accessibilityIdentifier("today.fixture.withdraw")
                            Button("Resume") { try? fixtureContext.resumeToday() }
                                .accessibilityIdentifier("today.fixture.resume")
                        }
                    }
                    if let fixtureContext, fixtureContext.testsDirectEntry {
                        Button("Verify no actions") {
                            do {
                                try fixtureContext.verifyDirectEntry()
                                directEntryVerified = true
                            } catch { directEntryVerified = false }
                        }
                        .accessibilityIdentifier("direct-entry.verify")
                        if directEntryVerified {
                            Text("No actions").accessibilityIdentifier("direct-entry.proof")
                        }
                    }
                    if fixtureContext?.supportsCareReconnect == true {
                        Button("Reconnect fixture network") { try? fixtureContext?.reconnectCare() }
                            .accessibilityIdentifier("care.fixture.reconnect")
                    }
                }
#endif
                if startupFailed && usesLegacyWelcome {
                    Text(isPolish ? "Katalog jest niedostępny." : "Catalogue unavailable.")
                        .accessibilityIdentifier("catalogue.error")
                }
                if let catalogue, catalogue.didSignOut, catalogue.snapshot == nil {
                    Text(isPolish ? "Wylogowano na tym urządzeniu." : "You’re signed out on this device.")
                        .accessibilityIdentifier("account.signedOut")
                    if catalogue.signOutServerUnconfirmed {
                        Text(isPolish
                             ? "Nie potwierdzono wylogowania na serwerze. Zaloguj się ponownie, aby spróbować jeszcze raz."
                             : "Server logout wasn’t confirmed. Sign in again to retry.")
                            .accessibilityIdentifier("account.signOut.serverUnconfirmed")
                    }
                }
                if collectionOpeningFailed {
                    Text(isPolish ? "Nie udało się otworzyć kolekcji. Spróbuj ponownie." : "Couldn’t open your collection. Try again.")
                        .foregroundStyle(QuietGarden.secondaryText)
                        .accessibilityIdentifier("collection.open.failed")
                    Button(isPolish ? "Spróbuj ponownie" : "Try again") { open(.collection) }
                        .buttonStyle(QuietGardenSecondaryButtonStyle())
                        .disabled(collectionOpening.busy || !collectionOpening.preparationSettled)
                        .accessibilityIdentifier("collection.open.retry")
                }
                if opening != nil || collectionOpening.busy {
                    ProgressView(isPolish ? "Otwieranie…" : "Opening…")
                        .accessibilityIdentifier("welcome.opening")
                }
                switch analysisModel.router.flowState.currentStep {
                case .selectIntent:
                    if usesLegacyWelcome {
                        welcomeIntentSection
                    } else if catalogue?.snapshot?.isAnonymous == false {
                        TodayHomeView(
                            model: todayModel,
                            visible: todayContext.map { isTodayCurrent($0) && !todayFenced } ?? false,
                            unavailable: todayUnavailable, polish: isPolish, busy: opening != nil || collectionOpening.busy || !collectionOpening.preparationSettled,
                            retry: { careReconnectRevision &+= 1 },
                            localBoundary: {
                                careReminderCachePublished()
                                if let context = todayContext { requestTodayLocal(context) }
                            },
                            openPlant: openTodayPlant,
                            collection: { open(.collection) },
                            browse: {
                                collectionOpening.presentationBegan()
                                analysisModel.router.selectIntent(.care)
                                analysisModel.router.selectCareMethod(.catalogue)
                            },
                            check: { open(.diagnosis) }, identify: { open(.identification) }
                        )
                        if let ownerId = consentOwnerId,
                           todayContext.map({ isTodayCurrent($0) && !todayFenced }) == true,
                           !todayUnavailable, careReminder.offersConsent(expectedOwnerId: ownerId),
                           let binding = careReminder.consentBinding(
                            expectedOwnerId: ownerId, locale: isPolish ? "pl" : "en") {
                            ReminderConsentView(lifecycle: careReminder, binding: binding,
                                                polish: isPolish, compact: true)
                        }
                    } else {
                        PlantHomeView(
                            polish: isPolish,
                            busy: opening != nil || collectionOpening.busy || !collectionOpening.preparationSettled,
                            unavailable: catalogue?.unavailable != nil || startupFailed,
                            guestAccessFailed: guestAccessFailed,
                            check: { open(.diagnosis) },
                            identify: { open(.identification) },
                            browse: {
                                collectionOpening.presentationBegan()
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
                                    openCollection: openSavedCollection,
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
                            GuestCatalogueView(connection: catalogue, polish: isPolish,
                                           careReminderLocaleIsCurrent: { [languageStore, locale = languageStore.currentLocale] in
                                               languageStore.currentLocale == locale
                                           },
                                           openCollection: openSavedCollection, back: closeCatalogue)
                        }
#else
                        GuestCatalogueView(connection: catalogue, polish: isPolish,
                                           careReminderLocaleIsCurrent: { [languageStore, locale = languageStore.currentLocale] in
                                               languageStore.currentLocale == locale
                                           },
                                           openCollection: openSavedCollection, back: closeCatalogue)
#endif
                    } else {
                        if !startupFailed { ProgressView() }
                        Button(isPolish ? "Wstecz" : "Back") {
                            closeCatalogue()
                        }
                        .buttonStyle(QuietGardenSecondaryButtonStyle())
                        .accessibilityIdentifier("catalogue.back")
                    }
                case .selectPhoto, .careQuestions:
                    CareQuestionsView(
                        model: analysisModel, languageStore: languageStore, accessSource: analysisAccessSource,
                        hostOwnsNativeBack: ownsAnalysisNativeBack
                    )
                case .analyzing, .preliminaryResult, .diagnosticRefinement:
                    PreliminaryResultView(
                        model: analysisModel, languageStore: languageStore,
                        catalogueConnection: analysisOwner != nil && catalogue?.snapshot?.session.userId == analysisOwner
                            ? catalogue : nil,
                        guestActions: guestIdentificationActions, openCollection: openSavedCollection
                    )
                default:
                    welcomeIntentSection
                }
                if usesLegacyWelcome, catalogue != nil,
                   [.selectIntent, .selectCatalogueSpecies].contains(analysisModel.router.flowState.currentStep) {
                    Button(isPolish ? "Moje rośliny" : "My plants") { collectionPresentation = CollectionPresentation() }
                        .accessibilityIdentifier("collection.open")
                }
                if usesLegacyWelcome { guestSaveButtons }
            }
            .toolbar {
                if ownsAnalysisNativeBack {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            if opening != nil { cancelAnalysisOpening() }
                            else { analysisModel.returnFromAnalysis() }
                        } label: {
                            Label(isPolish ? "Wstecz" : "Back", systemImage: "chevron.left")
                        }
                        .accessibilityIdentifier("analysis.navigation.back")
                    }
                }
            }
        }
        .onChange(of: languageStore.currentLocale) { _, _ in cancelAnalysisOpening() }
        .onChange(of: catalogue.map { ObjectIdentifier($0) }) { _, _ in
            cancelAnalysisOpening()
            collectionOpening.connectionReplaced()
        }
        .qgScreen()
        .onChange(of: catalogue?.snapshot) { previous, current in
            if previous != nil, previous != current { cancelAnalysisOpening() }
            if let target = collectionPresentation?.target, target.snapshot != current {
                collectionPresentation = nil
            }
            if let context = todayContext, context.snapshot != current { clearToday() }
            guard let previous, !previous.isAnonymous,
                  previous.session.userId != current?.session.userId else { return }
            collectionPresentation = nil
            accountDestination = nil
            collectionAfterSignIn = false
            opening = nil
            showingGuestTransfer = false
            openClaimCollection = false
            guestPhotoClaim = nil
            guestAccessFailed = false
            analysisOwner = nil
            analysisCredential = nil
            analysisModel.installAnalysisService(nil)
            analysisModel.router.flowState = AddFlowState()
        }
        .onChange(of: catalogue?.explicitCareReadIntent?.id) { _, _ in
            guard scenePhase == .active, !usesLegacyWelcome, !isolatesCareReminders,
                  let connection = catalogue, let intent = connection.explicitCareReadIntent,
                  connection.consumeExplicitCareRead(intent, locale: languageStore.currentLocale.rawValue) else { return }
            careReconnectRevision &+= 1
        }
        .onChange(of: analysisModel.router.flowState.currentStep) { previous, current in
            guard previous != .selectIntent, current == .selectIntent,
                  scenePhase == .active, !usesLegacyWelcome,
                  catalogue?.snapshot?.isAnonymous == false else { return }
            careReconnectRevision &+= 1
        }
        .task { await prepareCatalogue() }
        .task(id: reminderRead) { await observeTrialReminder(reminderRead) }
        .task(id: careReminderRead) { await observeCareReminder(careReminderRead) }
        .task(id: RoutingRead(intent: careReminderInbox.pendingTap?.id, auth: careReminderRead,
                             revision: careReminder.revision, modalRevision: routingRevision,
                             active: scenePhase == .active)) {
            await routeReminderTap()
        }
        .onReceive(CareReminderRootRouting.foregroundEvents(careReminderInbox)) { route in
            guard !isolatesCareReminders, let connection = catalogue,
                  case .permanent(let expected) = connection.authClassification else { return }
            CareReminderRootRouting.foreground(route, ownerId: expected.session.userId,
                context: careReminderContext, isCurrent: {
                    !isolatesCareReminders && catalogue === connection
                        && connection.authClassification == .permanent(expected)
                        && careReminderContext?.locale == languageStore.currentLocale.rawValue
                }, publish: { careReminderCachePublished() })
        }
        .task(id: CareReminderClockRead(auth: careReminderRead, deadline: careReminder.state?.verifiedAccessUntil,
                                       revision: careReminderClockRevision)) {
            await observeCareReminderClock()
        }
        .task { await observeCareConnectivity() }
        .task(id: CareLifecycleRead(snapshot: catalogue?.snapshot, active: scenePhase == .active,
                                    reconnectRevision: careReconnectRevision, locale: languageStore.currentLocale)) {
            await observeCareLifecycle(snapshot: catalogue?.snapshot, active: scenePhase == .active)
        }
        .task(id: todayModel.scope) { await observeTodaySignals(canonical: false) }
        .task(id: todayModel.scope) { await observeTodaySignals(canonical: true) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            careReminderClockChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            careReminderClockChanged()
        }
        .onChange(of: scenePhase) { _, phase in
            if !isolatesCareReminders { careReminder.setSceneActive(phase == .active) }
            if phase != .active { clearToday(); careLifecycle.suspend() }
        }
        .onChange(of: languageStore.currentLocale) { _, locale in
            if let context = todayContext, context.scope.locale != locale {
                clearToday(); careLifecycle.suspend()
            }
        }
        .onDisappear {
            if !isolatesCareReminders { careReminder.setSceneActive(false) }
            clearToday()
            careLifecycle.suspend()
            #if DEBUG
            catalogue?.reconcileFixtureReconnect = nil
            #endif
        }
        .sheet(item: $collectionPresentation, onDismiss: {
            let wasRouting = routingDismissal
            routingDismissal = false
            routingRevision &+= 1
            if !usesLegacyWelcome && !wasRouting { careReconnectRevision &+= 1 }
        }) { presentation in
            if let catalogue {
                CatalogueCollectionView(
                    connection: catalogue, polish: isPolish, repeatDiagnosis: repeatDiagnosisEntry(for: catalogue),
                    trialReminder: trialReminder,
                    careReminder: accountConsentLifecycle,
                    careReminderLocaleIsCurrent: { [languageStore, locale = languageStore.currentLocale] in
                        languageStore.currentLocale == locale
                    },
                    requestedTarget: presentation.target
                )
                .id(presentation.id)
            }
        }
        .sheet(item: $accountDestination, onDismiss: {
            routingRevision &+= 1
            if collectionAfterSignIn {
                collectionAfterSignIn = false
                collectionPresentation = CollectionPresentation()
            } else {
                showPendingGuestTransfer()
            }
        }) { destination in
            if let catalogue {
                AccountSignInView(
                    connection: catalogue, polish: isPolish,
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
        .sheet(item: $stagingAccount, onDismiss: {
            routingRevision &+= 1
            showPendingGuestTransfer()
        }) { account in
            AccountSignInView(
                connection: account.connection, staging: true,
                cancel: account.guestTransfer ? { stagingAccount = nil } : nil
            ) { snapshot, original in finishStagingSignIn(account, snapshot: snapshot, original: original) }
        }
#endif
        .sheet(isPresented: $showingGuestTransfer, onDismiss: {
            routingRevision &+= 1
            if openClaimCollection {
                openClaimCollection = false
                collectionPresentation = CollectionPresentation()
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
            .buttonStyle(QuietGardenSecondaryButtonStyle())
            .accessibilityIdentifier("staging.guest.draft.resume")
            if claim.failed { Text("Couldn’t prepare your plant. Try again.") }
        }
        if let claim = guestPhotoClaim, let scope = catalogue?.snapshot, claim.pending(for: scope),
           !showingGuestTransfer {
            Button("Finish saving your plant") { showingGuestTransfer = true }
                .buttonStyle(QuietGardenSecondaryButtonStyle())
                .accessibilityIdentifier("staging.guest.claim.resume")
        }
    }

    private var reminderRoutingScope: CareReminderRootRouting.Coordinator.Scope {
        guard !isolatesCareReminders, let connection = catalogue else { return .unresolved }
        switch connection.authClassification {
        case .unresolved: return .unresolved
        case .signedOut: return .signedOut
        case .anonymous: return .anonymous
        case .permanent(let expected):
            let locale = languageStore.currentLocale
            let runtime = careReminderRuntime
            return .permanent(CareReminderRootRouting.source(
                connection: connection, snapshot: expected, locale: locale.rawValue, isCurrent: {
                    !isolatesCareReminders && CareReminderRootRouting.current(
                        connection: connection, snapshot: expected, locale: locale, runtime: runtime,
                        currentConnection: catalogue, currentLocale: languageStore.currentLocale,
                        currentRuntime: careReminderRuntime)
                }))
        }
    }

    private func routeReminderTap() async {
        guard let intent = careReminderInbox.pendingTap else { return }
        if tapCoordinator == nil {
            let core = careReminder
            tapCoordinator = .init(inbox: careReminderInbox, clock: { core.currentDate },
                                   timeZone: { core.currentTimeZone })
        }
        guard let coordinator = tapCoordinator else { return }
        // Scope is pinned synchronously, before the first cache suspension.
        let scope = reminderRoutingScope
        guard let resolution = await coordinator.resolve(intent, scope: scope) else { return }
        if resolution.decision == .drop {
            careReminderInbox.consume(intentID: intent.id)
            return
        }
        guard !Task.isCancelled, scenePhase == .active,
              case .open = resolution.decision else { return }
        // Settings is nested inside this sheet. Wait for its actual outer dismissal.
        if collectionPresentation != nil {
            routingDismissal = true
            collectionPresentation = nil
            return
        }
        guard !routingDismissal, accountDestination == nil, !showingGuestTransfer else { return }
#if DEBUG && (targetEnvironment(simulator) || NARAT_DEVICE_STAGING_ANALYSIS)
        guard stagingAccount == nil else { return }
#endif
        if let target = coordinator.consumeOpen(resolution, scope: reminderRoutingScope,
                                                 presentationAvailable: true) {
            collectionPresentation = CollectionPresentation(
                target: CataloguePlantTarget(plantId: target.plantId, snapshot: target.source.snapshot))
        }
    }

    private func observeCareConnectivity() async {
        let monitor = NWPathMonitor()
        let updates = AsyncStream<Bool>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
        }
        monitor.start(queue: DispatchQueue(label: "narat.care.connectivity"))
        defer { monitor.cancel() }
        var previous: Bool?
        for await connected in updates {
            guard !Task.isCancelled else { return }
            if previous == false, connected { careReconnectRevision &+= 1 }
            previous = connected
        }
    }

    private func observeCareReminder(_ read: CareReminderRead) async {
        guard !Task.isCancelled, careReminderRead == read else { return }
        careReminderContext = nil
        // Launch flags protect bootstrap, before fixtureContext has been assigned.
        guard !isolatesCareReminders else { careReminder.suspendAuth(); return }
        careReminder.setSceneActive(scenePhase == .active)
        switch read.auth {
        case .unresolved:
            careReminder.suspendAuth()
        case .anonymous, .signedOut:
            guard careReminderRead == read else { return }
            careReminder.logout()
        case .permanent(let expected):
            careReminder.suspendAuth()
            guard let connection = catalogue, let store = connection.store,
                  let authority = connection.apiClient?.syncAuthority,
                  let engine = connection.syncEngine else { return }
            let language = languageStore
            do {
                guard careReminderRead == read else { return }
                let lease = try await connection.collectionLease(expected: expected)
                guard !Task.isCancelled, !isolatesCareReminders, careReminderRead == read else { return }
                try await careReminderRuntime.readiness.wait()
                guard !Task.isCancelled, !isolatesCareReminders, careReminderRead == read,
                      catalogue === connection,
                      connection.authClassification == .permanent(expected),
                      language.currentLocale == read.locale else { return }
                try authority.withPermanentBoundValid(lease) {}
                let context = CareReminderLifecycle.Context(
                    lease: lease, store: store, authority: authority, engine: engine,
                    locale: read.locale.rawValue,
                    isCurrent: {
                        connection.authClassification == .permanent(expected)
                            && language.currentLocale == read.locale
                            && (try? authority.withPermanentBoundValid(lease) {}) != nil
                    }
                )
                careReminderContext = context
                careReminder.accept(context)
            } catch {
                guard !Task.isCancelled, careReminderRead == read else { return }
                careReminder.suspendAuth()
            }
        }
    }

    private func careReminderCachePublished(_ source: TodayContext? = nil) {
        guard !isolatesCareReminders, let context = careReminderContext,
              let connection = catalogue, connection.apiClient?.syncAuthority === context.authority,
              context.isCurrent() else { return }
        if let source {
            guard connection.authClassification == .permanent(source.snapshot),
                  source.lease.ownerId == context.lease.ownerId,
                  source.lease.generation == context.lease.generation,
                  source.lease.session == context.lease.session else { return }
        }
        careReminder.cachePublicationOrTimeChanged()
    }

    private func careReminderClockChanged() {
        guard !isolatesCareReminders, let connection = catalogue,
              case .permanent = connection.authClassification else { return }
        careReminderClockRevision &+= 1
        careReminderCachePublished()
    }

    private func observeCareReminderClock() async {
        guard !isolatesCareReminders, let connection = catalogue,
              case .permanent(let expected) = connection.authClassification else { return }
        let locale = languageStore.currentLocale
        while !Task.isCancelled {
            let boundary = TodayCalendar.boundary(now: Date(), deadline: careReminder.state?.verifiedAccessUntil,
                                                  timeZone: .current)
            do { try await Task.sleep(for: .seconds(max(0, boundary.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled, !isolatesCareReminders,
                  connection.authClassification == .permanent(expected),
                  languageStore.currentLocale == locale else { return }
            careReminderCachePublished()
        }
    }

    private func observeCareLifecycle(snapshot: CatalogueSDKSnapshot?, active: Bool) async {
        guard !Task.isCancelled else { return }
        guard active, let connection = catalogue, let expected = snapshot, !expected.isAnonymous,
              connection.snapshot == expected, let repository = connection.repository,
              let sync = connection.syncEngine else {
            clearToday()
            careLifecycle.suspend()
            #if DEBUG
            catalogue?.reconcileFixtureReconnect = nil
            #endif
            return
        }
        // Subscribe before attempting work; this is an outbox-lock event, not canonical sync.
        let idle = await sync.outboxIdleUpdates(for: expected.session.userId)
        guard !Task.isCancelled, connection.snapshot == expected else { return }
        #if DEBUG
        connection.reconcileFixtureReconnect = {
            guard connection.snapshot == expected else { return }
            careReconnectRevision &+= 1
        }
        #endif
        var scopedToday: TodayContext?
        if !usesLegacyWelcome {
            do {
                if let context = todayContext, isTodayCurrent(context) {
                    scopedToday = context
                } else {
                    clearToday()
                    let locale = languageStore.currentLocale
                    let lease = try await connection.collectionLease(expected: expected)
                    guard !Task.isCancelled, scenePhase == .active, connection.snapshot == expected,
                          languageStore.currentLocale == locale else { return }
                    guard let authority = connection.apiClient?.syncAuthority else { throw SyncWireValidationError.invalidSession }
                    try authority.withPermanentBoundValid(lease) {}
                    let scope = todayModel.activate(ownerId: lease.ownerId, generation: lease.generation, locale: locale)
                    let context = TodayContext(snapshot: expected, lease: lease, scope: scope)
                    todayContext = context
                    scopedToday = context
                    requestTodayLocal(context)
                }
                guard let context = scopedToday else { return }
                try await waitTodayLocal(context)
            } catch {
                guard !Task.isCancelled, connection.snapshot == expected, scenePhase == .active else { return }
                todayUnavailable = true
                return
            }
        }
        let context = scopedToday
        careLifecycle.request(replacingCurrent: true) {
            do {
                try Task.checkCancellation()
                guard connection.snapshot == expected else { return nil }
                if let context { return try await refreshToday(context, repository: repository) }
                let lease = try await connection.collectionLease(expected: expected)
                return try await repository.reconcilePendingCare(context: lease)
            } catch {
                // Queue/action state remains authoritative; next real lifecycle event may retry.
                return nil
            }
        }
        for await _ in idle {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            careLifecycle.didBecomeIdle()
        }
    }

    private func clearToday() {
        todayLocalRead?.cancel()
        todayLocalRead = nil
        todayContext = nil
        todayModel.suspend()
        todayFenced = true
        todayUnavailable = false
    }

    private func isTodayCurrent(_ context: TodayContext) -> Bool {
        guard !usesLegacyWelcome, scenePhase == .active,
              todayContext?.scope == context.scope, todayModel.scope == context.scope,
              languageStore.currentLocale == context.scope.locale,
              let connection = catalogue, connection.snapshot == context.snapshot,
              let authority = connection.apiClient?.syncAuthority else { return false }
        return (try? authority.withPermanentBoundValid(context.lease) { true }) == true
    }

    private func requireToday(_ context: TodayContext) throws {
        try Task.checkCancellation()
        guard isTodayCurrent(context) else { throw CancellationError() }
    }

    private func waitTodayLocal(_ context: TodayContext) async throws {
        try requireToday(context)
        try await TodayModel.waitLatestLocalRead(
            current: { (todayRevision, todayLocalRead) },
            validate: { try requireToday(context) }
        )
        try requireToday(context)
    }

    /// All durable signals fence presentation synchronously, then coalesce local reads only.
    private func requestTodayLocal(_ context: TodayContext) {
        guard isTodayCurrent(context), let repository = catalogue?.repository else { return }
        todayFenced = true
        todayRevision &+= 1
        let revision = todayRevision
        todayLocalRead?.cancel()
        todayLocalRead = Task { @MainActor in
            guard !Task.isCancelled, isTodayCurrent(context) else { return }
            await todayModel.rereadLocal(scope: context.scope) {
                try requireToday(context)
                let result = try await repository.cachedCareOverview(context: context.lease)
                try requireToday(context)
                return result
            }
            guard !Task.isCancelled, isTodayCurrent(context), todayRevision == revision else { return }
            todayFenced = false
        }
    }

    private func observeTodaySignals(canonical: Bool) async {
        guard let context = todayContext, isTodayCurrent(context), !Task.isCancelled,
              let store = catalogue?.store, let sync = catalogue?.syncEngine else { return }
        let updates: AsyncStream<Void>
        if canonical { updates = await sync.canonicalSyncUpdates() }
        else { updates = await store.localOutboxUpdates(ownerId: context.lease.ownerId) }
        guard !Task.isCancelled, isTodayCurrent(context) else { return }
        for await _ in updates {
            guard !Task.isCancelled, isTodayCurrent(context) else { return }
            requestTodayLocal(context)
        }
    }

    private func refreshToday(
        _ context: TodayContext, repository: CollectionRepository
    ) async throws -> CareReconciliationOutcome {
        try requireToday(context)
        let outcome: CareReconciliationOutcome
        do {
            outcome = try await repository.reconcilePendingCare(context: context.lease)
        } catch {
            try requireToday(context)
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            guard CareReconciliationOutcome.permitsOverviewRead(after: error) else {
                // Integrity/authorization errors must not leave a warm projection looking fresh.
                todayUnavailable = true
                throw error
            }
            // Same external pass and lease; never retry reconciliation or drain commands here.
            outcome = .pending
        }
        try requireToday(context)
        guard outcome != .busy else { return outcome }
        todayUnavailable = false
        if todayModel.needsLocalRead { requestTodayLocal(context) }
        try await waitTodayLocal(context)
        guard !todayFenced, !todayModel.needsLocalRead else { return outcome }
        let revision = todayRevision
        var publicationRevision: UInt64?
        await todayModel.refresh(scope: context.scope) {
            try requireToday(context)
            let result: CareOverviewViewState
            do {
                result = try await repository.refreshCareOverview(locale: context.scope.locale, context: context.lease)
            } catch {
                await Task { @MainActor in careReminderCachePublished(context) }.value
                throw error
            }
            // Fresh task: SDK proof must survive cancellation of the Today caller.
            await Task { @MainActor in careReminderCachePublished(context) }.value
            try requireToday(context)
            if result.failure == nil { publicationRevision = todayRevision }
            return result
        }
        try requireToday(context)
        // C1 can discard a successful publication after a local revision. Never repeat HTTP.
        if let publicationRevision, publicationRevision != revision {
            try await waitTodayLocal(context)
            // A newer signal already owns the latest read, including any failure.
            guard todayRevision == publicationRevision else { return outcome }
            // Read current durable state even if the displaced read saw revalidation.
            requestTodayLocal(context)
            try await waitTodayLocal(context)
        }
        return outcome
    }

    private func openTodayPlant(_ plantId: UUID) {
        guard let context = todayContext, isTodayCurrent(context), !todayFenced else { return }
        collectionPresentation = CollectionPresentation(
            target: CataloguePlantTarget(plantId: plantId, snapshot: context.snapshot)
        )
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

    private func openSavedCollection(_ expected: CatalogueSDKSnapshot) {
        guard let connection = catalogue, connection.snapshot == expected, !expected.isAnonymous else { return }
        activate(.collection, connection: connection, snapshot: expected)
    }

    private var collectionOpeningAvailable: Bool {
        guard collectionPresentation == nil, accountDestination == nil,
              opening == nil, !showingGuestTransfer, !routingDismissal,
              scenePhase == .active,
              analysisModel.router.flowState.currentStep == .selectIntent else { return false }
#if DEBUG && (targetEnvironment(simulator) || NARAT_DEVICE_STAGING_ANALYSIS)
        guard stagingAccount == nil, stagingResume == nil else { return false }
#endif
        return true
    }

    private func open(_ destination: AccountDestination) {
        guard opening == nil, accountDestination == nil, let connection = catalogue,
              connection.apiClient != nil else { return }
        if destination == .collection {
            guard let request = collectionOpening.begin(
                connection: connection, locale: languageStore.currentLocale,
                presentationAvailable: collectionOpeningAvailable
            ) else { return }
            collectionOpeningFailed = false
#if DEBUG
            do { try fixtureContext?.beginOpening(request, connection: connection) }
            catch {
                collectionOpening.connectionReplaced()
                collectionOpeningFailed = true
                return
            }
#endif
            Task { @MainActor in
                await collectionOpening.execute(
                    request, connection: connection,
                    currentConnection: { catalogue },
                    currentLocale: { languageStore.currentLocale },
                    presentationAvailable: { collectionOpeningAvailable }
                ) { outcome in
                    guard collectionOpeningAvailable else { return }
#if DEBUG
                    do { try fixtureContext?.finishOpening(outcome, request: request, connection: connection) }
                    catch { collectionOpeningFailed = true; return }
#endif
                    switch outcome {
                    case .permanent(let snapshot):
                        activate(.collection, connection: connection, snapshot: snapshot)
                    case .loginRequired:
                        accountDestination = .collection
                    case .temporarilyUnavailable:
                        collectionOpeningFailed = true
                    case .superseded:
                        break
                    }
                }
            }
            return
        }
        let requestId = UUID()
        let original = connection.snapshot
        let locale = languageStore.currentLocale
        analysisOpeningId = requestId
        opening = destination
        guestAccessFailed = false
        func isCurrent() -> Bool {
            !Task.isCancelled && analysisOpeningId == requestId && opening == destination
                && catalogue === connection && languageStore.currentLocale == locale
                && analysisModel.router.flowState.currentStep == .selectIntent
                && (original == nil || connection.snapshot == original)
        }
        Task { @MainActor in
            defer {
                if analysisOpeningId == requestId { cancelAnalysisOpening() }
            }
            do {
                // Explicit entry may join the existing guarded guest bootstrap.
                if original == nil {
                    _ = try await connection.sessionOwner()
                    guard isCurrent() else { return }
                }
                let snapshot = try await connection.sessionSnapshot()
                guard isCurrent(), connection.snapshot == snapshot else { return }
                if !snapshot.isAnonymous {
                    activate(destination, connection: connection, snapshot: snapshot)
                } else if destination == .identification || destination == .diagnosis {
                    try await openGuestAnalysis(
                        destination, connection: connection, expected: snapshot, isCurrent: isCurrent
                    )
                } else {
                    accountDestination = destination
                }
            } catch {
                // An unresolved session is an availability failure, never proof of sign-out.
                if isCurrent() { guestAccessFailed = true }
            }
        }
    }

    private func cancelAnalysisOpening() {
        analysisOpeningId = nil
        opening = nil
    }

    private func openGuestAnalysis(
        _ destination: AccountDestination, connection: CatalogueConnection,
        expected: CatalogueSDKSnapshot, isCurrent: @MainActor () -> Bool
    ) async throws {
        guard isCurrent(), connection.snapshot == expected, expected.isAnonymous else { return }
        let claim = await photoClaim(for: connection)
        guard isCurrent(), connection.snapshot == expected else { return }
        try await claim.register(expected)
        guard isCurrent(), connection.snapshot == expected else { return }
        installAnalysis(connection: connection, owner: expected.session.userId,
                        identificationEnabled: true, guestCredential: claim.credential)
        analysisModel.startDirectAnalysis(destination == .diagnosis ? .problem : .care)
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
            collectionPresentation = CollectionPresentation()
            return
        }
        collectionOpening.presentationBegan()
        installAnalysis(
            connection: connection, owner: snapshot.session.userId, identificationEnabled: true
        )
        analysisModel.startDirectAnalysis(destination == .diagnosis ? .problem : .care)
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
        guard collectionOpening.beginPreparation() else { return }
        defer {
            collectionOpening.finishPreparation()
#if DEBUG
            if let connection = catalogue {
                try? fixtureContext?.openingPreparationSettled(connection: connection)
            }
#endif
        }
#if DEBUG
        if let fixture = preloadedReminderFixture {
            guard case .fixture(let configuration) = ReminderConsentLaunch.parse(ProcessInfo.processInfo.arguments),
                  configuration == fixture.configuration, fixture.runtime === careReminderRuntime,
                  let connection = fixture.context.connection,
                  fixture.matches(context: fixture.context, connection: connection) else {
                startupFailed = true
                return
            }
            fixture.notificationInbox = careReminderInbox
            fixtureContext = fixture.context
            catalogue = connection
        } else if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--care-reminder") }) {
            startupFailed = true
            return
        }
#endif
#if DEBUG && (targetEnvironment(simulator) || NARAT_DEVICE_STAGING_ANALYSIS)
        if ProcessInfo.processInfo.arguments.contains("--narat-staging-analysis") {
            guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--today-fixture") })
            else { startupFailed = true; return }
            await prepareStagingAnalysis()
            return
        }
#endif
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let fixtureFlags = arguments.filter {
            $0.hasPrefix("--catalogue-fixture") || $0.hasPrefix("--catalogue-namespace")
                || $0.hasPrefix("--today-fixture")
        }
        if preloadedReminderFixture != nil {
            // The validated bootstrap already owns this exact SDK and runtime pair.
        } else if !fixtureFlags.isEmpty {
            func value(_ flag: String) -> String? {
                let positions = arguments.indices.filter { arguments[$0] == flag }
                guard positions.count == 1, let index = positions.first,
                      arguments.indices.contains(index + 1) else { return nil }
                return arguments[index + 1]
            }
            let today = arguments.contains("--today-fixture")
            let scenarioFlag = today ? "--today-fixture" : "--catalogue-fixture"
            guard fixtureFlags.count == 2,
                  Set(fixtureFlags) == Set([scenarioFlag, "--catalogue-namespace"]),
                  let name = value(scenarioFlag),
                  let scenario = CatalogueUIFixtureScenario(rawValue: name),
                  scenario.testsToday == today,
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
            .foregroundStyle(QuietGarden.secondaryText)
            .accessibilityIdentifier("welcome.subtitle")

            VStack(spacing: 12) {
                Button {
                    collectionOpening.presentationBegan()
                    analysisModel.router.selectIntent(.problem)
                } label: {
                    Text(
                        isPolish
                            ? "Zdiagnozuj problem z rośliną"
                            : "Diagnose a plant problem"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietGardenPrimaryButtonStyle())
                .accessibilityIdentifier("welcome.intent.problem")

                Button {
                    collectionOpening.presentationBegan()
                    analysisModel.router.selectIntent(.care)
                } label: {
                    Text(
                        isPolish
                            ? "Dobierz pielęgnację i harmonogram"
                            : "Set up care and schedule"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietGardenSecondaryButtonStyle())
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
            .buttonStyle(QuietGardenPrimaryButtonStyle())
            .accessibilityIdentifier("care.method.scan")

            Button {
                analysisModel.router.selectCareMethod(.catalogue)
            } label: {
                Text(isPolish ? "Wybierz gatunek z katalogu (bez zdjęcia)" : "Choose species from catalogue (no photo)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietGardenSecondaryButtonStyle())
            .accessibilityIdentifier("care.method.catalogue")

            Button {
                analysisModel.router.navigateBack()
            } label: {
                Text(isPolish ? "Wstecz" : "Back")
            }
            .buttonStyle(QuietGardenSecondaryButtonStyle())
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
            if job.status == .expired {
                // Only a canonical, released first-diagnosis timeout permits a new
                // create. Transport timeouts keep replaying the existing operation.
                guard request.mode == .diagnosis, targetPlantId == nil,
                      job.errorCode == "ANALYSIS_TIMEOUT", job.quotaState == .released,
                      ["starter_diagnosis", "free_monthly", "paid_monthly"].contains(job.quotaKind),
                      job.photoAssetId == nil || job.photoAssetId == photoId else {
                    throw AnalysisServiceFailure.expiredTerminal
                }
                // Retain the confirmed upload and frozen request. A lost create
                // reply must replay this replacement ID on the next explicit Retry.
                progress.jobId = nil
                progress.creationOperationId = UUID()
                throw AnalysisServiceFailure.releasedTimeout
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
                    species = .init(published: card, displayName: plant.displayName)
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
        .buttonStyle(QuietGardenSecondaryButtonStyle())
        .qgCard()
        .qgScreen()
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
    var polish = false
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
    private var isPolish: Bool { polish && !staging }

    var body: some View {
        NavigationStack {
            Form {
                if !staging {
                    ForEach(connection.accountProviders, id: \.rawValue) { provider in
                        Button(provider == .apple
                               ? (isPolish ? "Kontynuuj z Apple" : "Continue with Apple")
                               : (isPolish ? "Kontynuuj z Google" : "Continue with Google")) {
                            signIn(provider)
                        }
                        .disabled(busy || scope == nil || presenter?.viewIfLoaded?.window == nil)
                        .accessibilityIdentifier("account.signin." + provider.rawValue)
                    }
                }
                TextField(isPolish ? "Adres e-mail" : "Email", text: $email)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .accessibilityIdentifier(staging ? "staging.email" : "account.email")
                SecureField(isPolish ? "Hasło" : "Password", text: $password)
                    .textContentType(.password)
                    .keyboardType(.asciiCapable)
                    .accessibilityIdentifier(staging ? "staging.password" : "account.password")
                if failed {
                    Text(staging ? "Could not sign in to the test stand. Check the test account."
                         : (isPolish ? "Nie udało się zalogować. Sprawdź adres e-mail i hasło, a następnie spróbuj ponownie."
                            : "Couldn’t sign in. Check your email and password and try again."))
                        .foregroundStyle(QuietGarden.danger)
                        .qgNotice(.error)
                        .accessibilityIdentifier(staging ? "staging.signin.error" : "account.signin.error")
                }
                Button(signingIn ? (isPolish ? "Logowanie…" : "Signing in…")
                       : (isPolish ? "Zaloguj się" : "Sign in")) {
                    signIn()
                }
                .disabled(busy || scope == nil || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                .buttonStyle(QuietGardenPrimaryButtonStyle())
                .accessibilityIdentifier(staging ? "staging.signin" : "account.signin")
            }
            .qgForm()
            .buttonStyle(QuietGardenSecondaryButtonStyle())
            .navigationTitle(staging ? "Test account" : (isPolish ? "Zaloguj się do Narat" : "Sign in to Narat"))
            .toolbar {
                if let cancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isPolish ? "Anuluj" : "Cancel", action: cancel).disabled(busy)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let polish: Bool
    let busy: Bool
    let unavailable: Bool
    let guestAccessFailed: Bool
    let check: () -> Void
    let identify: () -> Void
    let browse: () -> Void
    let collection: () -> Void
    @ViewBuilder let guestActions: () -> GuestActions

    private var green: Color { QuietGarden.accent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerLayout {
                    Text("Narat")
                        .font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("welcome.title")
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Button(action: collection) {
                        Label(polish ? "Moje rośliny" : "My plants", systemImage: "leaf")
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                            .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : nil)
                    }
                    .buttonStyle(QuietGardenSecondaryButtonStyle())
                    .accessibilityIdentifier("collection.open").disabled(unavailable)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "leaf.circle")
                        .font(.system(size: 44, weight: .light))
                        .accessibilityHidden(true)
                    Text(polish ? "Jak się ma Twoja roślina?" : "How’s your plant doing?")
                        .font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                    Text(polish ? "Dodaj zdjęcie, aby sprawdzić, czego może potrzebować Twoja roślina." : "Use a photo to see what your plant might need.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                    Button(action: check) {
                        Label(polish ? "Sprawdź zdrowie rośliny" : "Check plant health", systemImage: "camera")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                            .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .buttonStyle(QuietGardenPrimaryButtonStyle(inverted: true))
                    .foregroundStyle(QuietGarden.onAccent)
                    .accessibilityIdentifier("welcome.check").disabled(unavailable)
                }
                .foregroundStyle(QuietGarden.onAccent)
                .padding(24)
                .background(green, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(spacing: 0) {
                    destination(polish ? "Rozpoznaj gatunek" : "Identify species", systemImage: "viewfinder", id: "welcome.identify", action: identify)
                        .disabled(unavailable)
                    Divider().padding(.leading, 52)
                    destination(polish ? "Przeglądaj katalog" : "Browse catalogue", systemImage: "books.vertical", id: "welcome.catalogue", action: browse)
                }
                .background(QuietGarden.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                guestActions()

                if unavailable {
                    Text(polish ? "Narat nie może się teraz połączyć. Sprawdź ustawienia połączenia aplikacji." : "Narat can’t connect right now. Check the app’s connection settings.")
                        .font(.footnote)
                        .foregroundStyle(QuietGarden.secondaryText)
                        .qgNotice(.warning)
                        .accessibilityIdentifier("welcome.unavailable")
                }
                if guestAccessFailed {
                    Text(polish ? "Nie udało się rozpocząć analizy zdjęcia. Spróbuj ponownie." : "Couldn’t start photo analysis. Try again.")
                        .font(.footnote)
                        .foregroundStyle(QuietGarden.secondaryText)
                        .qgNotice(.error)
                        .accessibilityIdentifier("welcome.guest.error")
                }
            }
            .padding(20)
            .disabled(busy)
        }
        .qgScreen()
    }

    private var headerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout())
    }

    private func destination(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text(title).font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(QuietGarden.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
