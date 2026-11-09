import Foundation
import Supabase
import SwiftUI

enum CatalogueConnectionUnavailable: Error, Sendable, Equatable {
    case configurationMissing
    case storageUnavailable
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

    init(hasEstablishedSession: Bool = false) {
        self.hasEstablishedSession = hasEstablishedSession
    }

    func read() -> UInt64 { lock.withLock { value } }

    func allowsAnonymousSignup(at epoch: UInt64) -> Bool {
        lock.withLock { !hasEstablishedSession && value == epoch }
    }

    func invalidate(_ authority: SyncSessionAuthority, session: Session? = nil) {
        lock.withLock {
            value &+= 1
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

    /// Configuration/disk errors remain stable for this connection; never use a memory fallback.
    convenience init(
        configuration: () throws -> NativeAuthConfiguration = { try NativeAuthConfiguration() },
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
                configuration: configuration, store: store
            )
        } catch {
            self.init(unavailable: .configurationMissing)
        }
    }

    /// Fixtures inject an actual isolated SDK, durable store and HTTP transport.
    init(
        client: SupabaseClient, configuration: NativeAuthConfiguration, store: LocalStore,
        transport: any PlantsAPITransport = URLSessionAPITransport(),
        clientLocale: String = "pl"
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
        let epoch = sdkEpoch
        let authority = api.syncAuthority
        observer = Task { [weak self] in
            let registration = await client.auth.onAuthStateChange { [weak self] _, session in
                // Record session history and invalidate before any MainActor publication/bind.
                epoch.invalidate(authority, session: session)
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
        guard let client, sdkEpoch.read() == expected.epoch,
              let current = client.auth.currentSession, !current.isExpired,
              Self.snapshot(current, epoch: expected.epoch) == expected,
              sdkEpoch.read() == expected.epoch else {
            throw CatalogueSaveUnavailable.sessionChanged
        }
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
    @State private var ownerKey: String?
    @State private var query = ""
    @State private var loading = true
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        VStack {
            if loading {
                ProgressView()
            } else if failed {
                Text(polish ? "Nie udało się pobrać katalogu." : "Couldn’t load the catalogue.")
                    .accessibilityIdentifier("catalogue.error")
                Button(polish ? "Spróbuj ponownie" : "Try again") { retry += 1 }
            } else if let card = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(card.display_name).font(.title)
                        Text(card.scientific_name).italic()
                            .accessibilityIdentifier("catalogue.selected.scientific")
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
                    }.padding()
                }
                Button(polish ? "Wybierz inny gatunek" : "Choose another species") {
                    if let ownerKey { UserDefaults.standard.removeObject(forKey: ownerKey) }
                    selected = nil
                }.accessibilityIdentifier("catalogue.change")
            } else {
                TextField(polish ? "Szukaj gatunku" : "Search species", text: $query)
                    .textFieldStyle(.roundedBorder).padding(.horizontal)
                List(cards.filter { query.isEmpty || ($0.scientific_name + " " + $0.display_name).localizedStandardContains(query) }) { card in
                    Button {
                        if let ownerKey { UserDefaults.standard.set(card.id, forKey: ownerKey) }
                        selected = card
                    } label: {
                        VStack(alignment: .leading) {
                            Text(card.display_name)
                            Text(card.scientific_name).font(.caption)
                        }
                    }.accessibilityIdentifier("catalogue.species." + card.id)
                }
            }
            Button(polish ? "Wstecz" : "Back", action: back)
                .accessibilityIdentifier("catalogue.back")
        }
        .task(id: "\(polish)-\(retry)") {
            loading = true
            failed = false
            do {
                let owner = try await connection.sessionOwner()
                guard let client = connection.client else { throw NativeAuthFailure.configurationMissing }
                let page: SpeciesPage = try await client.rpc("search_catalogue_species", params: ["p_locale": polish ? "pl" : "en"]).execute().value
                try Task.checkCancellation()
                let key = "catalogue.selection." + owner.uuidString
                ownerKey = key
                cards = page.items
                selected = cards.first { $0.id == UserDefaults.standard.string(forKey: key) }
            } catch {
                if Task.isCancelled { return }
                failed = true
            }
            loading = false
        }
    }
}
