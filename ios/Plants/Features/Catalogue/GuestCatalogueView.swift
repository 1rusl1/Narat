import Foundation
import Supabase
import SwiftUI
import UIKit

enum CatalogueConnectionUnavailable: Error, Sendable, Equatable {
    case configurationMissing
    case storageUnavailable
}

enum CatalogueNativeRetention: Sendable, Equatable {
    case cancelled
    case authenticationFailed(NativeAuthFailure)
}

/// Success carries the actual model state; sign-in alone is never a saved result.
@MainActor
enum CatalogueNativeOutcome: Sendable {
    case busy
    case inputRetained(CatalogueSaveModel, CatalogueNativeRetention)
    case continued(CatalogueSaveModel)
    case unavailable(CatalogueSaveUnavailable)
}

/// Carries the original SDK event epoch, including same-token refresh and ABA.
struct CatalogueSDKSnapshot: Sendable, Equatable {
    let session: NativeAuthSession
    let isAnonymous: Bool
    fileprivate let epoch: UInt64
}

/// No suspension or Observation mutation in this small callback-side gate.
private final class CatalogueSDKEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var hasEstablishedSession: Bool
    private var signedInEpoch: UInt64?

    init(hasEstablishedSession: Bool = false) {
        self.hasEstablishedSession = hasEstablishedSession
    }

    func read() -> UInt64 { lock.withLock { value } }

    func allowsAnonymousSignup(at epoch: UInt64) -> Bool {
        lock.withLock { !hasEstablishedSession && value == epoch }
    }

    // Pinned SDK 2.55.6 _signIn updates storage then synchronously emits ONE signedIn.
    func permitsNativeSignIn(after epoch: UInt64) -> Bool {
        lock.withLock { value == epoch &+ 1 && signedInEpoch == value }
    }

    func invalidate(
        _ authority: SyncSessionAuthority, session: Session? = nil, event: AuthChangeEvent? = nil
    ) {
        lock.withLock {
            value &+= 1
            signedInEpoch = event == .signedIn ? value : nil
            // Monotonic for this connection, including anonymous and expired sessions.
            if session != nil { hasEstablishedSession = true }
            authority.invalidate()
        }
    }
}

@MainActor
@Observable
final class CatalogueConnection {
    let client: SupabaseClient?
    let store: LocalStore?
    let apiClient: PlantsAPIClient?
    let syncEngine: SyncEngine?
    let repository: CollectionRepository?
    let unavailable: CatalogueConnectionUnavailable?
    private var observedSnapshot: CatalogueSDKSnapshot?
    @ObservationIgnored private let sdkEpoch: CatalogueSDKEpoch
    @ObservationIgnored private var observer: Task<any AuthStateChangeListenerRegistration, Never>?
    @ObservationIgnored private var pending: Task<UUID, Error>?
    @ObservationIgnored private var binding: Task<Void, Error>?
    @ObservationIgnored private var boundSnapshot: CatalogueSDKSnapshot?
    @ObservationIgnored private var boundEpoch: UInt64?
    @ObservationIgnored private let nativeAuth: NativeAuthService?
    @ObservationIgnored private let resumeDefaults: UserDefaults
    @ObservationIgnored private var nativeFlow: UUID?

    var nativeAuthState: NativeAuthState? { nativeAuth?.state }

    /// Configuration/disk errors remain stable for this connection; never use a memory fallback.
    convenience init(
        configuration: () throws -> NativeAuthConfiguration = { try NativeAuthConfiguration() },
        clientLocale: String = "pl",
        makeStore: () throws -> LocalStore = {
            LocalStore(modelContainer: try LocalStore.makeContainer())
        }
    ) {
        do {
            let configuration = try configuration()
            let store: LocalStore
            do { store = try makeStore() }
            catch { self.init(unavailable: .storageUnavailable); return }
            self.init(
                client: SupabaseClient(
                    supabaseURL: configuration.supabaseURL,
                    supabaseKey: configuration.supabasePublishableKey
                ),
                configuration: configuration, store: store, clientLocale: clientLocale
            )
        } catch {
            self.init(unavailable: .configurationMissing)
        }
    }

    /// Fixtures inject an actual isolated SDK, durable store and HTTP transport.
    init(
        client: SupabaseClient, configuration: NativeAuthConfiguration, store: LocalStore,
        transport: any PlantsAPITransport = URLSessionAPITransport(),
        clientLocale: String = "pl",
        identityProvider: (any NativeIdentityProviding)? = nil,
        resumeDefaults: UserDefaults = .standard
    ) {
        // Seed before initial-session delivery can delete storage and swallow its refresh error.
        sdkEpoch = CatalogueSDKEpoch(hasEstablishedSession: client.auth.currentSession != nil)
        let api = PlantsAPIClient(
            baseURL: configuration.supabaseURL.appendingPathComponent("functions/v1/plants-api"),
            transport: transport, clientLocale: clientLocale
        )
        let engine = SyncEngine(store: store, apiClient: api)
        self.client = client
        self.store = store
        apiClient = api
        syncEngine = engine
        repository = CollectionRepository(store: store, apiClient: api, syncEngine: engine)
        unavailable = nil
        self.resumeDefaults = resumeDefaults
        if let identityProvider {
            nativeAuth = NativeAuthService(
                identityProvider: identityProvider, exchange: SupabaseAuthExchange(client: client)
            )
        } else {
            nativeAuth = configuration.makeService(client: client)
        }
        let epoch = sdkEpoch
        let authority = api.syncAuthority
        observer = Task { [weak self] in
            let registration = await client.auth.onAuthStateChange { [weak self] event, session in
                // Record session history and invalidate before any MainActor publication/bind.
                epoch.invalidate(authority, session: session, event: event)
                Task { @MainActor [weak self] in
                    await self?.observeCurrentSession()
                }
            }
            if Task.isCancelled { registration.remove() }
            return registration
        }
    }

    private init(unavailable: CatalogueConnectionUnavailable) {
        client = nil
        store = nil
        apiClient = nil
        syncEngine = nil
        repository = nil
        self.unavailable = unavailable
        nativeAuth = nil
        resumeDefaults = .standard
        sdkEpoch = CatalogueSDKEpoch()
    }

    deinit {
        observer?.cancel()
        if let apiClient { sdkEpoch.invalidate(apiClient.syncAuthority) }
    }

    var snapshot: CatalogueSDKSnapshot? {
        guard let observedSnapshot, (try? validate(observedSnapshot)) != nil else { return nil }
        return observedSnapshot
    }

    private func observeCurrentSession() async {
        // Reading SDK state never creates an owner, sends commands or transfers data.
        guard let client else { return }
        let epoch = sdkEpoch.read()
        guard let current = client.auth.currentSession, !current.isExpired else {
            _ = try? await bind(nil, epoch: epoch)
            guard sdkEpoch.read() == epoch else { return }
            observedSnapshot = nil
            return
        }
        let snapshot = Self.snapshot(current, epoch: epoch)
        do { try await bind(snapshot) }
        catch { return }
        guard (try? validate(snapshot)) != nil else { return }
        observedSnapshot = snapshot
    }

    private static func snapshot(_ session: Session, epoch: UInt64) -> CatalogueSDKSnapshot {
        CatalogueSDKSnapshot(
            session: NativeAuthSession(
                userId: session.user.id, accessToken: session.accessToken,
                expiresAt: Date(timeIntervalSince1970: session.expiresAt)
            ),
            isAnonymous: session.user.isAnonymous, epoch: epoch
        )
    }

    private func validate(_ expected: CatalogueSDKSnapshot) throws {
        try Task.checkCancellation()
        guard isCurrent(expected) else { throw CatalogueSaveUnavailable.sessionChanged }
    }

    /// Also usable after committed exchange when the original caller was cancelled.
    private func isCurrent(_ expected: CatalogueSDKSnapshot) -> Bool {
        guard let client, sdkEpoch.read() == expected.epoch,
              let current = client.auth.currentSession, !current.isExpired,
              Self.snapshot(current, epoch: expected.epoch) == expected,
              sdkEpoch.read() == expected.epoch else { return false }
        return true
    }

    private func validateBinding(_ expected: CatalogueSDKSnapshot?, epoch: UInt64) throws {
        if let expected {
            try validate(expected)
            return
        }
        try Task.checkCancellation()
        guard let client, sdkEpoch.read() == epoch,
              client.auth.currentSession?.isExpired != false,
              sdkEpoch.read() == epoch else { throw CatalogueSaveUnavailable.sessionChanged }
    }

    private func bind(_ expected: CatalogueSDKSnapshot) async throws {
        try await bind(expected, epoch: expected.epoch)
    }

    /// Serializes actor hops so identical reads cannot revoke their own in-flight models.
    private func bind(_ expected: CatalogueSDKSnapshot?, epoch: UInt64) async throws {
        guard let apiClient else { throw unavailable ?? .storageUnavailable }
        while let binding {
            _ = try? await binding.value
            try validateBinding(expected, epoch: epoch)
        }
        try validateBinding(expected, epoch: epoch)
        if boundEpoch == epoch, boundSnapshot == expected { return }
        let task = Task {
            defer { binding = nil }
            try validateBinding(expected, epoch: epoch)
            await apiClient.bindSyncSession(expected?.session)
            do {
                try validateBinding(expected, epoch: epoch)
                boundSnapshot = expected
                boundEpoch = epoch
            } catch {
                apiClient.syncAuthority.invalidate()
                boundSnapshot = nil
                boundEpoch = nil
                throw error
            }
        }
        binding = task
        try await task.value
        try validateBinding(expected, epoch: epoch)
    }

    /// Explicit verified read. A refresh that changes the epoch requires a fresh read.
    func sessionSnapshot() async throws -> CatalogueSDKSnapshot {
        guard let client else { throw unavailable ?? .configurationMissing }
        _ = await observer?.value
        let epoch = sdkEpoch.read()
        let current = try await client.auth.session
        let expected = Self.snapshot(current, epoch: epoch)
        try validate(expected)
        try await bind(expected)
        try validate(expected)
        observedSnapshot = expected
        try validate(expected)
        return expected
    }

    /// Root and catalogue startup join exactly one anonymous signup.
    func sessionOwner() async throws -> UUID {
        guard let client else { throw unavailable ?? .configurationMissing }
        if let pending { return try await pending.value }
        let task = Task {
            _ = await observer?.value
            let epoch = sdkEpoch.read()
            var expectedEpoch = epoch
            let current: Session
            do {
                current = try await client.auth.session
            } catch AuthError.sessionMissing {
                guard sdkEpoch.allowsAnonymousSignup(at: epoch), client.auth.currentSession == nil else {
                    throw CatalogueSaveUnavailable.sessionChanged
                }
                current = try await client.auth.signInAnonymously()
                // Only the signup's own signedIn event may advance this startup.
                expectedEpoch = epoch &+ 1
            }
            let expected = Self.snapshot(current, epoch: expectedEpoch)
            try validate(expected)
            try await bind(expected)
            try validate(expected)
            observedSnapshot = expected
            try validate(expected)
            return expected.session.userId
        }
        pending = task
        defer { pending = nil }
        return try await task.value
    }

    func makeModel(
        input: CatalogueInput, flowId: UUID, operationId: UUID,
        expected: CatalogueSDKSnapshot
    ) async throws -> CatalogueSaveModel {
        guard let store, let apiClient, let repository else {
            throw unavailable ?? .storageUnavailable
        }
        try validate(expected)
        try await bind(expected)
        try validate(expected)
        let model = try await CatalogueSaveModel(
            store: store, apiClient: apiClient, repository: repository,
            flowId: flowId, operationId: operationId, input: input,
            session: expected.session, isAnonymous: expected.isAnonymous
        )
        try validate(expected)
        guard model.input == input else { throw CatalogueSaveUnavailable.sessionChanged }
        return model
    }

    private func resumeKey(_ owner: UUID) -> String {
        "catalogue.native.flow." + owner.uuidString.lowercased()
    }

    private func validate(_ model: CatalogueSaveModel, expected: CatalogueSDKSnapshot) throws {
        guard let store, let apiClient else { throw unavailable ?? .storageUnavailable }
        try validate(expected)
        try model.validateScope(
            of: store, apiClient: apiClient, session: expected.session,
            isAnonymous: expected.isAnonymous
        )
        try validate(expected)
    }

    /// Explicit checkpoint under the model's ORIGINAL lease; no sends or owner transfer.
    @discardableResult
    func rememberModel(
        _ model: CatalogueSaveModel, expected: CatalogueSDKSnapshot
    ) async throws -> CatalogueInputCheckpointSnapshot {
        try validate(model, expected: expected)
        let checkpoint = try await model.checkpointInput()
        try validate(model, expected: expected)
        guard checkpoint.ownerId == expected.session.userId else {
            throw CatalogueSaveUnavailable.sessionChanged
        }
        let key = resumeKey(checkpoint.ownerId)
        let previous = resumeDefaults.string(forKey: key)
        let pointer = checkpoint.flowId.uuidString
        try validate(model, expected: expected)
        // UserDefaults notifications are synchronous: publication and rollback must hold neither lock.
        resumeDefaults.set(pointer, forKey: key)
        do {
            try validate(model, expected: expected)
        } catch {
            // A callback may revoke this lease or publish a newer flow. Undo only our pointer.
            if resumeDefaults.string(forKey: key) == pointer {
                if let previous { resumeDefaults.set(previous, forKey: key) }
                else { resumeDefaults.removeObject(forKey: key) }
            }
            throw error
        }
        return checkpoint
    }

    /// Explicit new intent may forget ONLY the matching pointer, never durable records.
    @discardableResult
    func forgetResumableFlow(
        ownerId: UUID, expectedFlowId: UUID, expected: CatalogueSDKSnapshot
    ) throws -> Bool {
        try validate(expected)
        guard ownerId == expected.session.userId else { throw CatalogueSaveUnavailable.sessionChanged }
        let key = resumeKey(ownerId)
        let previous = resumeDefaults.string(forKey: key)
        guard previous.flatMap(UUID.init(uuidString:)) == expectedFlowId else { return false }
        try validate(expected)
        resumeDefaults.removeObject(forKey: key)
        do {
            try validate(expected)
        } catch {
            // Restore only the absence this call published; preserve any callback's newer flow.
            if resumeDefaults.object(forKey: key) == nil, let previous {
                resumeDefaults.set(previous, forKey: key)
            }
            throw error
        }
        return true
    }

    /// Language is header metadata and must never revoke a model's original lease.
    func updateClientLocale(_ locale: String) async throws {
        guard let apiClient else { throw unavailable ?? .configurationMissing }
        try await apiClient.updateClientLocale(locale)
    }

    /// Current-owner metadata only, for guests and permanent users alike.
    /// Payload and receipt remain exclusively in SQLite.
    func resumableFlow(expected: CatalogueSDKSnapshot) throws -> UUID? {
        try validate(expected)
        let flow = resumeDefaults.string(forKey: resumeKey(expected.session.userId)).flatMap(UUID.init(uuidString:))
        try validate(expected)
        return flow
    }

    /// Explicit user intent only. The auth observer never invokes this continuation.
    func signInAndSave(
        _ original: CatalogueSaveModel, with provider: NativeAuthProvider,
        presenting: UIViewController
    ) async -> CatalogueNativeOutcome {
        guard nativeFlow == nil else { return .busy }
        guard let nativeAuth, let store, let apiClient else {
            return .unavailable(.storageOrServiceUnavailable)
        }
        let intent = UUID()
        nativeFlow = intent
        defer { nativeFlow = nil }
        do {
            let preparedSDK = try await sessionSnapshot()
            guard original.isGuest(of: store, apiClient: apiClient, session: preparedSDK.session),
                  preparedSDK.isAnonymous else {
                return .unavailable(.sessionChanged)
            }
            // Capture ONLY the selected immutable input while its original facade is accessible.
            var prepared: (input: CatalogueInput, checkpoint: CatalogueInputCheckpointSnapshot)?
            let result = await nativeAuth.signIn(
                with: provider, presenting: presenting,
                validateBeforeExchange: {
                    try self.validate(preparedSDK)
                    if original.isCancelled { throw CancellationError() }
                    guard self.nativeFlow == intent else { throw CatalogueSaveUnavailable.sessionChanged }
                },
                prepareForSessionChange: {
                    try self.validate(preparedSDK)
                    guard let input = original.input else { throw CatalogueSaveUnavailable.sessionChanged }
                    let checkpoint = try await original.checkpointInput()
                    try self.validate(preparedSDK)
                    prepared = (input, checkpoint)
                }
            )
            guard let result else {
                guard isCurrent(preparedSDK) else { return .unavailable(.sessionChanged) }
                guard prepared != nil else {
                    return .unavailable(Task.isCancelled ? .cancelled : .storageOrServiceUnavailable)
                }
                if case .cancelled = nativeAuth.state { return .inputRetained(original, .cancelled) }
                if case let .failed(reason) = nativeAuth.state {
                    return .inputRetained(original, .authenticationFailed(reason))
                }
                return .unavailable(.storageOrServiceUnavailable)
            }
            guard let prepared else { return .unavailable(.storageOrServiceUnavailable) }

            // Finite local reconciliation survives caller cancellation AFTER SDK commit.
            // It never sends plants HTTP and never repairs or rolls back SDK identity.
            let reconciliation = Task { @MainActor () async throws -> (CatalogueSaveModel, CatalogueSDKSnapshot) in
                guard self.nativeFlow == intent,
                      self.sdkEpoch.permitsNativeSignIn(after: preparedSDK.epoch),
                      let current = self.client?.auth.currentSession, !current.user.isAnonymous else {
                    throw CatalogueSaveUnavailable.sessionChanged
                }
                let expected = Self.snapshot(current, epoch: preparedSDK.epoch &+ 1)
                guard expected.session == result.session else { throw CatalogueSaveUnavailable.sessionChanged }
                try self.validate(expected)
                let model = try await self.makeModel(
                    input: prepared.input, flowId: prepared.checkpoint.flowId,
                    operationId: prepared.checkpoint.operationId, expected: expected
                )
                let checkpoint = try await model.checkpointInput()
                guard checkpoint.envelope.operationId == prepared.checkpoint.operationId,
                      checkpoint.envelope.payloadJSON.utf8.elementsEqual(prepared.checkpoint.envelope.payloadJSON.utf8),
                      self.nativeFlow == intent else { throw CatalogueSaveUnavailable.sessionChanged }
                try self.validate(expected)
                self.resumeDefaults.set(checkpoint.flowId.uuidString, forKey: self.resumeKey(expected.session.userId))
                try self.validate(expected)
                return (model, expected)
            }
            let (model, expected) = try await reconciliation.value
            guard nativeFlow == intent, isCurrent(expected) else { return .unavailable(.sessionChanged) }
            // A cancelled caller may explicitly retry later via the guarded flow pointer.
            guard !Task.isCancelled, !original.isCancelled else { return .inputRetained(model, .cancelled) }
            await model.save()
            guard isCurrent(expected) else { return .unavailable(.sessionChanged) }
            if Task.isCancelled || original.isCancelled { return .inputRetained(model, .cancelled) }
            return .continued(model)
        } catch is CancellationError {
            return .unavailable(.cancelled)
        } catch SyncWireValidationError.invalidSession {
            return .unavailable(.sessionChanged)
        } catch {
            if error as? CatalogueSaveUnavailable == .sessionChanged {
                return .unavailable(.sessionChanged)
            }
            return .unavailable(.storageOrServiceUnavailable)
        }
    }

    /// Same-owner, explicit-flow restoration. No plants HTTP or operation generation.
    func restoreModel(
        ownerId: UUID, flowId: UUID, expected: CatalogueSDKSnapshot
    ) async -> CatalogueSaveRestoration {
        guard let store, let apiClient, let repository else {
            return .unavailable(.storageOrServiceUnavailable)
        }
        do {
            guard ownerId == expected.session.userId else { throw CatalogueSaveUnavailable.sessionChanged }
            try validate(expected)
            try await bind(expected)
            try validate(expected)
            let result = await CatalogueSaveModel.restore(
                store: store, apiClient: apiClient, repository: repository,
                ownerId: ownerId, flowId: flowId, session: expected.session,
                isAnonymous: expected.isAnonymous
            )
            try validate(expected)
            return result
        } catch is CancellationError {
            return .unavailable(.cancelled)
        } catch {
            return .unavailable(.sessionChanged)
        }
    }
}

private struct SpeciesCard: Decodable, Identifiable {
    struct Description: Decodable {
        let text: String
        let attribution: String?
        let source_url: URL?
    }

    struct Photo: Decodable {
        let download_url: URL?
        let source_page: URL?
        let attribution: String?
    }

    let plant_id: String
    let display_name: String
    let scientific_name: String
    let description: Description?
    let hero_image: Photo?
    var id: String { plant_id }
}

private struct SpeciesPage: Decodable {
    let items: [SpeciesCard]
}

struct GuestCatalogueView: View {
    let connection: CatalogueConnection
    let polish: Bool
    let back: () -> Void
    @State private var cards: [SpeciesCard] = []
    @State private var selected: SpeciesCard?
    @State private var selectionLocked = false
    @State private var resumedSpecies: String?
    @State private var bootstrapped = false
    @State private var query = ""
    @State private var loading = true
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        VStack {
            // Keep the same save child mounted while localized public data is refetched.
            if let card = selected {
                ScrollView {
                    CatalogueSaveView(
                        connection: connection, speciesSlug: card.id,
                        displayName: card.display_name, scientificName: card.scientific_name,
                        polish: polish, selectionLocked: $selectionLocked
                    ) {
                        speciesDetails(card)
                    }
                    .id(card.id)
                    .padding()
                }
                if loading { ProgressView() }
                if failed { catalogueError }
                Button(polish ? "Wybierz inny gatunek" : "Choose another species") {
                    beginNewPlantIntent()
                }
                .disabled(selectionLocked)
                .accessibilityIdentifier("catalogue.change")
            } else if loading {
                ProgressView()
            } else if failed {
                catalogueError
            } else {
                TextField(polish ? "Szukaj gatunku" : "Search species", text: $query)
                    .textFieldStyle(.roundedBorder).padding(.horizontal)
                    .accessibilityIdentifier("catalogue.search")
                List(cards.filter {
                    query.isEmpty || ($0.scientific_name + " " + $0.display_name).localizedStandardContains(query)
                }) { card in
                    Button {
                        if let owner = connection.snapshot?.session.userId {
                            UserDefaults.standard.set(card.id, forKey: selectionKey(owner))
                        }
                        selected = card
                    } label: {
                        VStack(alignment: .leading) {
                            Text(card.display_name)
                            Text(card.scientific_name).font(.caption)
                        }
                    }
                    .accessibilityIdentifier("catalogue.species." + card.id)
                }
            }
            Button(polish ? "Wstecz" : "Back", action: back)
                .accessibilityIdentifier("catalogue.back")
        }
        .task(id: "\(polish)-\(retry)") { await loadCatalogue() }
    }

    private var catalogueError: some View {
        VStack {
            Text(polish ? "Nie udało się pobrać katalogu." : "Couldn’t load the catalogue.")
                .accessibilityIdentifier("catalogue.error")
            Button(polish ? "Spróbuj ponownie" : "Try again") { retry += 1 }
                .accessibilityIdentifier("catalogue.retry")
        }
    }

    @ViewBuilder
    private func speciesDetails(_ card: SpeciesCard) -> some View {
        if let photo = card.hero_image, let url = photo.download_url {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: { Color.clear }
            .frame(maxHeight: 240)
            if let source = photo.source_page, let credit = photo.attribution {
                Link(credit, destination: source).font(.caption)
            }
        }
        if let description = card.description {
            Text(description.text)
            if let source = description.source_url {
                Link(description.attribution ?? (polish ? "Źródło" : "Source"), destination: source)
                    .font(.caption)
            }
        }
    }

    @MainActor
    private func beginNewPlantIntent() {
        guard !selectionLocked, let expected = connection.snapshot else { return }
        do {
            if let flow = try connection.resumableFlow(expected: expected) {
                // Forget only this owner's current resume pointer. SQLite keeps the original
                // checkpoint, pending command, receipt and canonical plant history intact.
                guard try connection.forgetResumableFlow(
                    ownerId: expected.session.userId, expectedFlowId: flow, expected: expected
                ) else { throw CatalogueSaveUnavailable.sessionChanged }
            }
            guard connection.snapshot == expected else { throw CatalogueSaveUnavailable.sessionChanged }
            UserDefaults.standard.removeObject(forKey: selectionKey(expected.session.userId))
            resumedSpecies = nil
            selected = nil
        } catch {
            failed = true
        }
    }

    private func selectionKey(_ owner: UUID) -> String {
        "catalogue.selection." + owner.uuidString
    }

    @MainActor
    private func loadCatalogue() async {
        loading = true
        failed = false
        do {
            if !bootstrapped {
                _ = try await connection.sessionOwner()
                let expected = try await connection.sessionSnapshot()
                if let flow = try connection.resumableFlow(expected: expected) {
                    switch await connection.restoreModel(
                        ownerId: expected.session.userId, flowId: flow, expected: expected
                    ) {
                    case let .restored(model):
                        guard connection.snapshot == expected, let input = model.input else {
                            throw CatalogueSaveUnavailable.sessionChanged
                        }
                        resumedSpecies = input.speciesSlug
                    case .absent: break
                    case let .unavailable(reason): throw reason
                    }
                }
                try Task.checkCancellation()
                guard connection.snapshot == expected else { throw CatalogueSaveUnavailable.sessionChanged }
                bootstrapped = true
            }
            try await connection.updateClientLocale(polish ? "pl" : "en")
            guard let client = connection.client else { throw NativeAuthFailure.configurationMissing }
            let page: SpeciesPage = try await client.rpc(
                "search_catalogue_species", params: ["p_locale": polish ? "pl" : "en"]
            ).execute().value
            try Task.checkCancellation()
            cards = page.items
            // A permanent owner's restored flow wins even without a public preference.
            let preferred = selected?.id ?? resumedSpecies ?? connection.snapshot.flatMap {
                UserDefaults.standard.string(forKey: selectionKey($0.session.userId))
            }
            if let matching = cards.first(where: { $0.id == preferred }) {
                selected = matching
            }
        } catch {
            if Task.isCancelled { return }
            failed = true
        }
        loading = false
    }
}
