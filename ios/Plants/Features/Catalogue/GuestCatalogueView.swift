import Foundation
import PhotosUI
import Supabase
import SwiftUI
import UIKit

/// Missing canonical entitlement preserves Free behavior; known invalid access grants nothing.
enum CatalogueRoutineAccessPolicy {
    static func allows(_ entitlement: SyncWireEntitlementDTO?, at now: Date) -> Bool {
        guard let entitlement else { return true }
        return entitlement.verifiedAccessUntil.map { $0 > now } ?? false
    }
}

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

/// Transient explicit UI request, bound to the original connection, SDK epoch and locale.
struct CatalogueCareReadIntent: Equatable {
    let id = UUID()
    fileprivate let connection: ObjectIdentifier
    fileprivate let expected: CatalogueSDKSnapshot
    fileprivate let locale: String
}

/// Evidence for consumers that must distinguish HOLD from definite local sign-out.
enum CatalogueAuthClassification: Sendable, Equatable {
    case unresolved
    case permanent(CatalogueSDKSnapshot)
    case anonymous(CatalogueSDKSnapshot)
    case signedOut
}

/// Captured when the account sheet opens, including an absent SDK session.
struct CatalogueAccountScope: Sendable {
    let snapshot: CatalogueSDKSnapshot?
    fileprivate let epoch: UInt64
}

/// No suspension or Observation mutation in this small callback-side gate.
private final class CatalogueSDKEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var hasEstablishedSession: Bool
    private var signedInEpoch: UInt64?
    private var signedOutProof = false

    init(hasEstablishedSession: Bool = false) {
        self.hasEstablishedSession = hasEstablishedSession
    }

    func read() -> UInt64 { lock.withLock { value } }

    func allowsAnonymousSignup(at epoch: UInt64) -> Bool {
        lock.withLock { !hasEstablishedSession && value == epoch }
    }

    func provesSignOut(at epoch: UInt64) -> Bool {
        lock.withLock { value == epoch && signedOutProof }
    }

    // Pinned SDK 2.55.6 _signIn updates storage then synchronously emits ONE signedIn.
    func permitsNativeSignIn(after epoch: UInt64) -> Bool {
        lock.withLock { value == epoch &+ 1 && signedInEpoch == value }
    }

    @discardableResult
    func invalidate(
        _ authority: SyncSessionAuthority, session: Session? = nil, event: AuthChangeEvent? = nil
    ) -> UInt64 {
        lock.withLock {
            value &+= 1
            signedInEpoch = event == .signedIn ? value : nil
            // Initial nil may follow terminal refresh cleanup. Only that empty initial
            // event may carry proof forward; any new identity/event retires it.
            if event != .initialSession || session != nil {
                signedOutProof = event == .signedOut && session == nil
            }
            // Monotonic for this connection, including anonymous and expired sessions.
            if session != nil { hasEstablishedSession = true }
            authority.invalidate()
            return value
        }
    }
}

@MainActor
@Observable
final class CatalogueConnection {
    #if DEBUG
    var routineFixtureNow: Date?
    @ObservationIgnored var reconcileFixtureReconnect: (() -> Void)?
    @ObservationIgnored var withdrawCareSourceFixture: (() throws -> Void)?
    @ObservationIgnored var advanceRoutineFixtureClock: (() -> Void)?
    #endif

    let client: SupabaseClient?
    let store: LocalStore?
    let apiClient: PlantsAPIClient?
    let syncEngine: SyncEngine?
    let repository: CollectionRepository?
    let unavailable: CatalogueConnectionUnavailable?
    private(set) var explicitCareReadIntent: CatalogueCareReadIntent?

    /// Call only from explicit UI actions with original scope and positive command proof where required.
    @discardableResult
    func publishExplicitCareRead(
        expected: CatalogueSDKSnapshot, locale: String, isLocaleCurrent: () -> Bool
    ) -> Bool {
        guard !Task.isCancelled, isLocaleCurrent(),
              authClassification == .permanent(expected) else { return false }
        explicitCareReadIntent = CatalogueCareReadIntent(
            connection: ObjectIdentifier(self), expected: expected, locale: locale)
        return true
    }

    /// Only the explicit UI read completion calls this; canonical publication is passive.
    @discardableResult
    func publishCollectionLoadCompletion(
        _ result: CatalogueCollectionSnapshot, expected: CatalogueSDKSnapshot,
        context: SyncSessionLease, locale: String,
        isReadCurrent: () -> Bool, isLocaleCurrent: () -> Bool
    ) throws -> Bool {
        guard !result.isCached, isReadCurrent(), isLocaleCurrent(),
              !Task.isCancelled, snapshot == expected, let apiClient else { return false }
        try apiClient.syncAuthority.withPermanentBoundValid(context) {}
        return publishExplicitCareRead(expected: expected, locale: locale, isLocaleCurrent: isLocaleCurrent)
    }

    /// Root consumes once before requesting its existing external coalescer pass.
    func consumeExplicitCareRead(_ intent: CatalogueCareReadIntent, locale: String) -> Bool {
        guard intent.connection == ObjectIdentifier(self),
              explicitCareReadIntent == intent else { return false }
        explicitCareReadIntent = nil
        return !Task.isCancelled && intent.locale == locale
            && authClassification == .permanent(intent.expected)
    }

    private var observedSnapshot: CatalogueSDKSnapshot?
    private var observedNilEpoch: UInt64?
    private(set) var hasResolvedAuth = false
    private(set) var lastDeletedPlant: UUID?
    private(set) var didSignOut = false
    private(set) var signOutServerUnconfirmed = false
    @ObservationIgnored private let sdkEpoch: CatalogueSDKEpoch
    @ObservationIgnored private var observer: Task<any AuthStateChangeListenerRegistration, Never>?
    @ObservationIgnored private var pending: Task<UUID, Error>?
    @ObservationIgnored private var binding: Task<Void, Error>?
    @ObservationIgnored private var boundSnapshot: CatalogueSDKSnapshot?
    @ObservationIgnored private var boundEpoch: UInt64?
    @ObservationIgnored private let nativeAuth: NativeAuthService?
    @ObservationIgnored private let resumeDefaults: UserDefaults
    private var nativeFlow: UUID?
    let accountProviders: [NativeAuthProvider]

    var authenticationInFlight: Bool { nativeFlow != nil }

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
        sdkEpoch = CatalogueSDKEpoch(
            hasEstablishedSession: client.auth.currentSession != nil
                || resumeDefaults.bool(forKey: "catalogue.explicitSignOut")
        )
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
        didSignOut = resumeDefaults.bool(forKey: "catalogue.explicitSignOut")
        var providers: [NativeAuthProvider] = []
        if configuration.supportsAppleSignIn { providers.append(.apple) }
        if configuration.supportsGoogleSignIn { providers.append(.google) }
        accountProviders = providers
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
                let causeEpoch = epoch.invalidate(authority, session: session, event: event)
                Task { @MainActor [weak self] in
                    await self?.observeCurrentSession(epoch: causeEpoch)
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
        accountProviders = []
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

    /// Read-only: never refreshes the SDK or treats a sticky preference as proof.
    var authClassification: CatalogueAuthClassification {
        if let snapshot {
            return snapshot.isAnonymous ? .anonymous(snapshot) : .permanent(snapshot)
        }
        guard !Task.isCancelled, let client, let epoch = observedNilEpoch,
              sdkEpoch.provesSignOut(at: epoch), client.auth.currentSession == nil,
              sdkEpoch.provesSignOut(at: epoch) else { return .unresolved }
        return .signedOut
    }

    func didDeletePlant(_ plantId: UUID, expected: CatalogueSDKSnapshot) {
        guard snapshot == expected else { return }
        lastDeletedPlant = plantId
    }

    private func observeCurrentSession(epoch: UInt64) async {
        // Reading SDK state never creates an owner, sends commands or transfers data.
        guard let client, sdkEpoch.read() == epoch else { return }
        guard let current = client.auth.currentSession, !current.isExpired else {
            do { try await bind(nil, epoch: epoch) }
            catch { return }
            guard (try? validateBinding(nil, epoch: epoch)) != nil else { return }
            observedSnapshot = nil
            observedNilEpoch = epoch
            hasResolvedAuth = true
            return
        }
        let snapshot = Self.snapshot(current, epoch: epoch)
        do { try await bind(snapshot) }
        catch { return }
        guard (try? validate(snapshot)) != nil else { return }
        observedSnapshot = snapshot
        hasResolvedAuth = true
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

    /// Captures existing identity without creating a guest or writing application data.
    func accountScope() async throws -> CatalogueAccountScope {
        guard let client else { throw NativeAuthFailure.configurationMissing }
        _ = await observer?.value
        let epoch = sdkEpoch.read()
        let snapshot = client.auth.currentSession.flatMap {
            $0.isExpired ? nil : Self.snapshot($0, epoch: epoch)
        }
        try validateBinding(snapshot, epoch: epoch)
        return CatalogueAccountScope(snapshot: snapshot, epoch: epoch)
    }

    func signInAccount(
        with provider: NativeAuthProvider, presenting: UIViewController,
        scope: CatalogueAccountScope
    ) async throws -> CatalogueSDKSnapshot? {
        guard let nativeAuth else { throw NativeAuthFailure.configurationMissing }
        guard provider != .apple || accountProviders.contains(.apple) else {
            throw NativeAuthFailure.configurationMissing
        }
        return try await signInAccount(scope: scope) {
            let result = await nativeAuth.signIn(
                with: provider, presenting: presenting,
                validateBeforeExchange: { try self.validateBinding(scope.snapshot, epoch: scope.epoch) },
                prepareForSessionChange: { try self.validateBinding(scope.snapshot, epoch: scope.epoch) }
            )
            if let result { return result.session }
            try self.validateBinding(scope.snapshot, epoch: scope.epoch)
            if case .cancelled = nativeAuth.state { return nil }
            if case let .failed(reason) = nativeAuth.state { throw reason }
            throw NativeAuthFailure.providerFailed
        }
    }

    func signInAccount(
        email: String, password: String, scope: CatalogueAccountScope
    ) async throws -> CatalogueSDKSnapshot? {
        guard let client else { throw NativeAuthFailure.configurationMissing }
        return try await signInAccount(scope: scope) {
            let session = try await client.auth.signIn(email: email, password: password)
            guard !session.user.isAnonymous else { throw NativeAuthFailure.invalidCredential }
            return NativeAuthSession(
                userId: session.user.id, accessToken: session.accessToken,
                expiresAt: Date(timeIntervalSince1970: session.expiresAt)
            )
        }
    }

    /// Shares the catalogue-native gate. Only the exchange's one signedIn event is accepted.
    private func signInAccount(
        scope: CatalogueAccountScope,
        exchange: @MainActor () async throws -> NativeAuthSession?
    ) async throws -> CatalogueSDKSnapshot? {
        guard nativeFlow == nil else { throw NativeAuthFailure.providerFailed }
        let intent = UUID()
        nativeFlow = intent
        defer { nativeFlow = nil }
        try validateBinding(scope.snapshot, epoch: scope.epoch)
        guard let session = try await exchange() else { return nil }
        try Task.checkCancellation()
        guard nativeFlow == intent, sdkEpoch.permitsNativeSignIn(after: scope.epoch),
              let current = client?.auth.currentSession, !current.isExpired,
              !current.user.isAnonymous else { throw CatalogueSaveUnavailable.sessionChanged }
        let expected = Self.snapshot(current, epoch: scope.epoch &+ 1)
        guard expected.session == session else { throw CatalogueSaveUnavailable.sessionChanged }
        try validate(expected)
        try await bind(expected)
        try validate(expected)
        observedSnapshot = expected
        try validate(expected)
        return expected
    }

    /// Uses the settings presentation's snapshot and the existing native exchange gate.
    func signOutAccount(expected: CatalogueSDKSnapshot) async throws {
        guard let client else { throw NativeAuthFailure.configurationMissing }
        guard nativeFlow == nil else { throw NativeAuthFailure.providerFailed }
        try validate(expected)
        guard !expected.isAnonymous else { throw CatalogueSaveUnavailable.sessionChanged }
        nativeFlow = UUID()
        defer { nativeFlow = nil }
        resumeDefaults.set(true, forKey: "catalogue.explicitSignOut")
        try validate(expected)
        didSignOut = true
        signOutServerUnconfirmed = false
        do {
            // SDK removes local storage and emits signedOut BEFORE the HTTP request.
            try await client.auth.signOut(scope: .local)
        } catch {
            // Never restore A or sign out B after a delayed transport response.
            signOutServerUnconfirmed = client.auth.currentSession == nil
            throw error
        }
    }

    /// Root and catalogue startup join exactly one anonymous signup.
    func sessionOwner() async throws -> UUID {
        guard let client else { throw unavailable ?? .configurationMissing }
        if let pending { return try await pending.value }
        if client.auth.currentSession == nil, resumeDefaults.bool(forKey: "catalogue.explicitSignOut") {
            throw CatalogueSaveUnavailable.sessionChanged
        }
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

    func collectionLease(expected: CatalogueSDKSnapshot) async throws -> SyncSessionLease {
        guard !expected.isAnonymous else { throw CatalogueSaveUnavailable.sessionChanged }
        return try await analysisLease(expected: expected)
    }

    func syncedTrialEntitlement(expected: CatalogueSDKSnapshot) async throws -> SyncWireEntitlementDTO? {
        let lease = try await collectionLease(expected: expected)
        guard let store, let apiClient else { throw CatalogueConnectionUnavailable.storageUnavailable }
        let entitlement = try await store.syncedCanonicalEntitlement(context: lease, authority: apiClient.syncAuthority)
        try validate(expected)
        return entitlement
    }

    func analysisLease(expected: CatalogueSDKSnapshot) async throws -> SyncSessionLease {
        guard let apiClient else { throw CatalogueSaveUnavailable.sessionChanged }
        try validate(expected)
        try await bind(expected)
        let lease = try await apiClient.captureSyncContext(ownerId: expected.session.userId)
        guard lease.session == expected.session else { throw CatalogueSaveUnavailable.sessionChanged }
        try validate(expected)
        return lease
    }

    func analysisAccess(
        using repository: AnalysisAccessRepository, expected: CatalogueSDKSnapshot, guestCredential: String?
    ) async throws -> AnalysisAccessWireDTO {
        guard let apiClient else { throw CatalogueConnectionUnavailable.configurationMissing }
        let lease = try await analysisLease(expected: expected)
        let access = try await repository.fetchSnapshot(
            api: apiClient, context: lease, expectedGuest: expected.isAnonymous, guestCredential: guestCredential
        )
        try validate(expected)
        return access
    }

    func guestPhotoClaimData() -> Data? { resumeDefaults.data(forKey: "staging.guest.photo.claim") }

    func storeGuestPhotoClaimData(_ data: Data?) {
        resumeDefaults.set(data, forKey: "staging.guest.photo.claim")
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
        guard let nativeAuth, let store, let apiClient,
              provider != .apple || accountProviders.contains(.apple) else {
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

struct RepeatDiagnosisEntry {
    let languageStore: LanguageStore
    let accessSource: AnalysisAccessSource
    let makeModel: @MainActor (CatalogueCardSummary, CatalogueSDKSnapshot) -> AnalysisFlowModel?
}

/// A one-shot request; selection always comes from the collection's canonical cards.
struct CataloguePlantTarget {
    let plantId: UUID
    let snapshot: CatalogueSDKSnapshot
}

struct CatalogueCollectionView: View {
    private struct Read: Equatable {
        let session: CatalogueSDKSnapshot?
        let attempt: Int
    }

    private struct Selected: Equatable {
        let card: CatalogueCardSummary
        let scope: CatalogueSDKSnapshot
    }

    let connection: CatalogueConnection
    let polish: Bool
    var repeatDiagnosis: RepeatDiagnosisEntry? = nil
    var trialReminder: TrialReminderScheduler? = nil
    var careReminder: CareReminderLifecycle? = nil
    var careReminderLocaleIsCurrent: () -> Bool = { false }
    var requestedTarget: CataloguePlantTarget? = nil
    @State private var targetConsumed = false
    @Environment(\.dismiss) private var dismiss
    @State private var loadedScope: CatalogueSDKSnapshot?
    @State private var cards: [CatalogueCardSummary] = []
    @State private var selected: Selected?
    @State private var accountSettingsScope: CatalogueSDKSnapshot?
    @State private var repeatModel: AnalysisFlowModel?
    @State private var loading = true
    @State private var failed = false
    @State private var usingCachedCards = false
    @State private var attempt = 0

    private var read: Read { Read(session: connection.snapshot, attempt: attempt) }
    private var currentSelection: Selected? {
        guard let selected, selected.scope == connection.snapshot else { return nil }
        return selected
    }

    var body: some View {
        NavigationStack {
            Group {
                if let selected = currentSelection {
                    if let repeatModel, let repeatDiagnosis {
                        if repeatModel.router.flowState.currentStep == .selectPhoto {
                            CareQuestionsView(
                                model: repeatModel, languageStore: repeatDiagnosis.languageStore,
                                accessSource: repeatDiagnosis.accessSource, returnToPlant: endRepeatDiagnosis
                            )
                        } else {
                            PreliminaryResultView(
                                model: repeatModel, languageStore: repeatDiagnosis.languageStore,
                                catalogueConnection: nil, returnToPlant: endRepeatDiagnosis,
                                firstAidContext: FirstAidResultContext(
                                    connection: connection, expected: selected.scope,
                                    openJournal: {
                                        if self.repeatModel === repeatModel { endRepeatDiagnosis() }
                                    }
                                )
                            )
                        }
                    } else {
                        CatalogueCollectionCardView(
                            connection: connection, card: selected.card, expected: selected.scope, polish: polish,
                            isLocaleCurrent: careReminder == nil ? { false } : careReminderLocaleIsCurrent,
                            startRepeatDiagnosis: repeatDiagnosis.map { entry in
                                { repeatModel = entry.makeModel(selected.card, selected.scope) }
                            },
                            onRenamed: { updated in
                                guard currentSelection == selected, updated.id == selected.card.id,
                                      let index = cards.firstIndex(where: { $0.id == updated.id }) else { return }
                                cards[index] = updated
                                self.selected = Selected(card: updated, scope: selected.scope)
                            },
                            onDeleted: {
                                guard currentSelection == selected else { return }
                                cards.removeAll { $0.id == selected.card.id }
                                self.selected = nil
                                connection.didDeletePlant(selected.card.id, expected: selected.scope)
                            }
                        )
                    }
                } else if read.session?.isAnonymous != false {
                    Text(polish ? "Zaloguj się, aby zobaczyć rośliny." : "Sign in to see your plants.")
                        .accessibilityIdentifier("collection.signInRequired")
                } else if loading || loadedScope != read.session {
                    ProgressView()
                } else if failed {
                    VStack {
                        Text(polish ? "Nie udało się wczytać roślin." : "Couldn’t load your plants.")
                        Button(polish ? "Spróbuj ponownie" : "Try again") { attempt += 1 }
                    }
                } else {
                    collectionList
                }
            }
            .navigationTitle(polish ? "Moje rośliny" : "My plants")
            .toolbar {
                if currentSelection == nil, let scope = loadedScope,
                   scope == connection.snapshot, !scope.isAnonymous {
                    ToolbarItem(placement: .primaryAction) {
                        Button(polish ? "Ustawienia konta" : "Account settings") {
                            accountSettingsScope = scope
                            if careReminder != nil {
                                connection.publishExplicitCareRead(expected: scope,
                                    locale: polish ? "pl" : "en", isLocaleCurrent: careReminderLocaleIsCurrent)
                            }
                        }
                        .accessibilityIdentifier("collection.settings.open")
                    }
                }
                if currentSelection == nil || repeatModel == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(currentSelection == nil ? (polish ? "Zamknij" : "Close") : (polish ? "Wstecz" : "Back")) {
                            if currentSelection != nil { selected = nil } else { dismiss() }
                        }
                        .accessibilityIdentifier("collection.back")
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { accountSettingsScope != nil },
            set: { if !$0 { accountSettingsScope = nil } }
        )) {
            NavigationStack {
                Group {
                    if let scope = accountSettingsScope,
                       scope == connection.snapshot, !scope.isAnonymous {
                        ScrollView {
                            VStack {
                                ProfileReminderHourSettings(connection: connection, expected: scope, polish: polish,
                                    isLocaleCurrent: careReminder == nil ? { false } : careReminderLocaleIsCurrent)
                                if let careReminder {
                                    ReminderConsentHost(
                                        lifecycle: careReminder, connection: connection,
                                        expected: scope, polish: polish,
                                        isLocaleCurrent: careReminderLocaleIsCurrent
                                    )
                                }
                                AccountSignOutSettings(connection: connection, expected: scope, polish: polish)
                            }
                        }
                        .id(scope.session.userId)
                    }
                }
                .navigationTitle(polish ? "Ustawienia konta" : "Account settings")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(polish ? "Zamknij" : "Close") { accountSettingsScope = nil }
                            .accessibilityIdentifier("collection.settings.close")
                    }
                }
            }
        }
        .onChange(of: connection.snapshot) { _, _ in
            accountSettingsScope = nil
            targetConsumed = true
        }
        .task(id: read) { await load(read) }
        .onDisappear(perform: endRepeatDiagnosis)
    }

    private func endRepeatDiagnosis() {
        repeatModel?.cancelAnalysis()
        repeatModel = nil
    }

    private var collectionList: some View {
        VStack {
            if let trialReminder, let trial = trialReminder.trial, trial.ownerId == loadedScope?.session.userId {
                trialReminderSettings(trialReminder, trial: trial)
            }
            if usingCachedCards {
                Text(polish ? "Rośliny z ostatniej synchronizacji." : "Showing last synced plants.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("collection.cached")
            }
            if cards.isEmpty {
                Text(polish ? "Nie masz jeszcze roślin." : "You haven’t saved any plants yet.")
                    .accessibilityIdentifier("collection.empty")
            } else {
                List(cards) { card in
                    Button {
                        guard let scope = loadedScope, scope == connection.snapshot else { return }
                        selected = Selected(card: card, scope: scope)
                    } label: {
                        Text(card.personalName ?? card.speciesSlug ?? (polish ? "Roślina" : "Plant"))
                    }
                    .accessibilityIdentifier("collection.plant." + card.id.uuidString.lowercased())
                }
            }
        }
    }

    private func trialReminderSettings(_ scheduler: TrialReminderScheduler, trial: VerifiedTrial) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(polish ? "Koniec okresu próbnego" : "Trial end")
                .font(.headline)
            Text(trial.end, format: .dateTime.day().month().year().hour().minute())
                .accessibilityIdentifier("trial.reminder.end")
            if trial.reminderDate > Date(), trial.reminderDate < trial.accessUntil {
                Toggle(polish ? "Przypomnij 24 godziny wcześniej" : "Remind me 24 hours before", isOn: Binding(
                    get: { scheduler.optedIn },
                    set: { enabled in Task { await scheduler.setOptIn(enabled, ownerId: trial.ownerId) } }
                ))
                .accessibilityIdentifier("trial.reminder.optIn")
            }
            if scheduler.notificationsDenied {
                Text(polish ? "Powiadomienia są wyłączone w ustawieniach iOS." : "Notifications are off in iOS Settings.")
                    .accessibilityIdentifier("trial.reminder.denied")
            } else if scheduler.schedulingFailed {
                Text(polish ? "Nie udało się ustawić przypomnienia." : "Couldn’t schedule the reminder.")
                    .accessibilityIdentifier("trial.reminder.failed")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    @MainActor
    private func load(_ requested: Read) async {
        guard !Task.isCancelled, read == requested else { return }
        endRepeatDiagnosis()
        selected = nil
        cards = []
        loadedScope = nil
        failed = false
        usingCachedCards = false
        loading = true
        guard let expected = requested.session, !expected.isAnonymous else { return }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            guard let repository = connection.repository else { throw CatalogueConnectionUnavailable.storageUnavailable }
            let result = try await repository.collectionCards(context: lease)
            guard !Task.isCancelled, read == requested else { return }
            try connection.publishCollectionLoadCompletion(
                result, expected: expected, context: lease, locale: polish ? "pl" : "en",
                isReadCurrent: { read == requested },
                isLocaleCurrent: { careReminder != nil && careReminderLocaleIsCurrent() })
            cards = result.cards
            usingCachedCards = result.isCached
            if !targetConsumed, let target = requestedTarget {
                targetConsumed = true
                if target.snapshot == expected, !result.isCached,
                   let card = cards.first(where: { $0.id == target.plantId }) {
                    selected = Selected(card: card, scope: expected)
                }
            }
        } catch {
            guard !Task.isCancelled, read == requested else { return }
            failed = true
        }
        loadedScope = expected
        loading = false
    }
}

private struct AccountSignOutSettings: View {
    let connection: CatalogueConnection
    let expected: CatalogueSDKSnapshot
    let polish: Bool
    @State private var confirming = false
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        if connection.snapshot == expected {
            VStack {
                Button(polish ? "Wyloguj się" : "Sign out", role: .destructive) {
                    confirming = true
                }
                .accessibilityIdentifier("account.signOut.open")
                .disabled(busy || connection.authenticationInFlight)
                if busy { ProgressView().accessibilityIdentifier("account.signOut.busy") }
                if failed {
                    Text(polish ? "Nie udało się wylogować. Spróbuj ponownie." : "Couldn’t sign out. Try again.")
                        .accessibilityIdentifier("account.signOut.failed")
                }
            }
            .alert(polish ? "Wylogować się?" : "Sign out?", isPresented: $confirming) {
                Button(polish ? "Anuluj" : "Cancel", role: .cancel) {}
                    .accessibilityIdentifier("account.signOut.cancel")
                Button(polish ? "Wyloguj się" : "Sign out", role: .destructive) {
                    guard !busy else { return }
                    busy = true
                    failed = false
                    Task { @MainActor in
                        defer { busy = false }
                        do { try await connection.signOutAccount(expected: expected) }
                        catch { failed = true }
                    }
                }
                .accessibilityIdentifier("account.signOut.confirm")
            } message: {
                Text(polish ? "Twoje rośliny pozostaną zapisane na koncie." : "Your plants will remain saved in your account.")
            }
        }
    }
}

private struct ProfileReminderHourSettings: View {
    let connection: CatalogueConnection
    let expected: CatalogueSDKSnapshot
    let polish: Bool
    let isLocaleCurrent: () -> Bool
    @State private var canonicalHour: Int?
    @State private var selectedHour = 9
    @State private var pending: ProfileReminderHourCommand?
    @State private var busy = true
    @State private var failed = false

    private var isCurrent: Bool {
        connection.snapshot == expected && !expected.isAnonymous
    }

    private func hourText(_ hour: Int) -> String { String(format: "%02d:00", hour) }

    var body: some View {
        Group {
            if isCurrent {
                VStack(alignment: .leading, spacing: 6) {
                    Text(polish ? "Ustawienia konta" : "Account settings").font(.headline)
                    Text(polish ? "Godzina przypomnień" : "Reminder hour")
                    if let pending {
                        Text((polish ? "Oczekuje: " : "Pending: ") + hourText(pending.reminderHourLocal))
                            .accessibilityIdentifier("profile.hour.pending")
                        Button(polish ? "Spróbuj ponownie" : "Try again") {
                            Task { await save(retrying: pending) }
                        }
                        .accessibilityIdentifier("profile.hour.retry")
                        .disabled(busy)
                    } else if let canonicalHour {
                        Text(hourText(canonicalHour))
                            .accessibilityIdentifier("profile.hour.synced")
                        Picker(polish ? "Wybierz godzinę" : "Choose hour", selection: $selectedHour) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(hourText(hour)).tag(hour)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 100)
                        .accessibilityIdentifier("profile.hour.picker")
                        .disabled(busy)
                        Button(polish ? "Zapisz" : "Save") {
                            Task { await save(retrying: nil) }
                        }
                        .accessibilityIdentifier("profile.hour.save")
                        .disabled(busy || selectedHour == canonicalHour)
                    }
                    if busy { ProgressView() }
                    if failed {
                        Text(polish ? "Nie udało się potwierdzić godziny." : "Couldn’t confirm the hour.")
                            .accessibilityIdentifier("profile.hour.failed")
                        if pending == nil {
                            Button(polish ? "Wczytaj ponownie" : "Reload") {
                                Task { await load() }
                            }
                            .accessibilityIdentifier("profile.hour.reload")
                            .disabled(busy)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
        }
        .task(id: expected) { await load() }
    }

    @MainActor
    private func load() async {
        guard isCurrent, !Task.isCancelled else { return }
        busy = true
        failed = false
        canonicalHour = nil
        pending = nil
        defer { if isCurrent { busy = false } }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            guard let repository = connection.repository, let api = connection.apiClient else {
                throw CatalogueConnectionUnavailable.storageUnavailable
            }
            let saved = try await repository.pendingProfileReminderHour(context: lease)
            guard isCurrent, !Task.isCancelled else { return }
            pending = saved
            if let saved {
                selectedHour = saved.reminderHourLocal
            } else {
                let profile = try await api.fetchProfileSettings(context: lease)
                guard isCurrent, !Task.isCancelled else { return }
                canonicalHour = profile.reminderHourLocal
                selectedHour = profile.reminderHourLocal
            }
        } catch {
            guard isCurrent, !Task.isCancelled else { return }
            failed = true
        }
    }

    @MainActor
    private func save(retrying command: ProfileReminderHourCommand?) async {
        guard isCurrent, !Task.isCancelled, !busy else { return }
        // Capture the selection before acquiring the owner-bound lease.
        let hour = selectedHour
        busy = true
        failed = false
        defer { if isCurrent { busy = false } }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            guard let repository = connection.repository else {
                throw CatalogueConnectionUnavailable.storageUnavailable
            }
            let saved: ProfileReminderHourCommand
            if let command {
                saved = command
            } else {
                saved = try await repository.enqueueProfileReminderHour(reminderHourLocal: hour, context: lease)
            }
            guard isCurrent, !Task.isCancelled else { return }
            pending = saved
            canonicalHour = nil
            let outcome = try await repository.retryProfileReminderHour(saved, context: lease)
            guard isCurrent, !Task.isCancelled else { return }
            switch outcome {
            case let .confirmed(hour):
                pending = nil
                canonicalHour = hour
                selectedHour = hour
                connection.publishExplicitCareRead(expected: expected, locale: polish ? "pl" : "en",
                    isLocaleCurrent: isLocaleCurrent)
            case .pending:
                break
            case .rejected, .unconfirmed:
                let restored = try await repository.pendingProfileReminderHour(context: lease)
                guard isCurrent, !Task.isCancelled else { return }
                pending = restored
                failed = true
            }
        } catch {
            guard isCurrent, !Task.isCancelled else { return }
            // Require a durable reload before allowing another edit.
            canonicalHour = nil
            failed = true
        }
    }
}

private struct CatalogueCollectionCardView: View {
    private struct SpeciesRead: Equatable {
        let slug: String?
        let taxonId: UUID?
        let locale: SupportedLocale
    }

    private struct CanonicalCareRead: Equatable {
        let revision: Int
        let active: Bool
    }

    private enum CorrectionPhase: Equatable {
        case loading, ready, saving, pending(CommandEnvelopeDTO), blocked, failed
        case recordSaving, recordPending(CommandEnvelopeDTO)
    }

    private enum FirstAidWrite {
        case retryRecord(FirstAidRecordCommand)
        case undo(UUID)
        case retryUndo(CommandEnvelopeDTO)
        case observe(UUID, FirstAidObservationStatus, Data?)
        case retryObservation(FirstAidObservationCommand)
        case retryObservationPhoto(FirstAidObservationPhotoDraft)
        case discardObservationPhoto(FirstAidObservationPhotoDraft)
    }

    private enum FirstAidDialog {
        case undo(UUID)
        case observe(UUID, Data?)

        var title: String {
            switch self {
            case .undo: "Undo the soil check?"
            case .observe: "How is the plant doing?"
            }
        }
    }

    let connection: CatalogueConnection
    let card: CatalogueCardSummary
    let expected: CatalogueSDKSnapshot
    let polish: Bool
    var isLocaleCurrent: () -> Bool = { false }
    var startRepeatDiagnosis: (() -> Void)? = nil
    let onRenamed: (CatalogueCardSummary) -> Void
    let onDeleted: () -> Void
    @State private var deleteConfirmation = false
    @State private var pendingDeletion: CommandEnvelopeDTO?
    @State private var checkingDeletion = true
    @State private var deleting = false
    @State private var deletionFailed = false
    @State private var pendingRename: CommandEnvelopeDTO?
    @State private var loadingRename = true
    @State private var savingRename = false
    @State private var renameFailed = false
    @State private var detailsReadFailed = false
    @State private var editingName = false
    @State private var nameInput = ""
    @State private var rejectedNameInput: String?
    @State private var editingSpecies = false
    @State private var editingLight = false
    @State private var editingDrainage = false
    @State private var editingWatering = false
    @State private var editingPotType = false
    @State private var currentConditions: PlantConditionCodes?
    @State private var species: PublishedSpeciesCard?
    @State private var advice: PlantCareRecommendation?
    @State private var history: [CatalogueCareJournalEntry]?
    @State private var analysisHistory: [CatalogueAnalysisHistoryRow] = []
    @State private var firstAid: CatalogueFirstAidSnapshot?
    @State private var firstAidHistory: [CatalogueCareJournalEntry] = []
    @State private var pendingFirstAid: FirstAidRecordCommand?
    @State private var pendingFirstAidUndo: CommandEnvelopeDTO?
    @State private var pendingObservation: FirstAidObservationCommand?
    @State private var pendingObservationPhoto: FirstAidObservationPhotoDraft?
    @State private var firstAidSelection: FirstAidDialog?
    @State private var showingFirstAidDialog = false
    @State private var savingFirstAid = false
    @State private var firstAidFailed = false
    @State private var historyFailed = false
    @State private var adviceFailed = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var routineEntitlement: SyncWireEntitlementDTO?
    @State private var routineAccessLoaded = false
    @State private var routineClock = Date()
    @State private var pendingRoutine: RoutineSoilCheckCompletionCommand?
    @State private var routineHistory: [CatalogueCareJournalEntry] = []
    @State private var pendingRoutineUndo: RoutineSoilCheckUndoCommand?
    @State private var routineUndoSelection: CatalogueCareJournalEntry?
    @State private var showingRoutineUndo = false
    @State private var routineUndoConfirmed = false
    @State private var checkingRoutine = true
    @State private var savingRoutine = false
    @State private var routineFailed = false
    @State private var routineConfirmed = false
    @State private var pendingAdviceRefresh: CommandEnvelopeDTO?
    @State private var checkingAdviceRefresh = true
    @State private var basicCareEnabled: Bool?
    @State private var basicCarePending = false
    @State private var enablingBasicCare = false
    @State private var basicCareEnableFailed = false
    @State private var basicCareReadFailed = false
    @State private var adviceRefreshRead: Int?
    @State private var refreshingAdvice = false
    @State private var adviceRefreshFailed = false
    @State private var adviceRefreshReadFailed = false
    @State private var attempt = 0
    @State private var adviceRequest = 0
    @State private var adviceResponse: Int?
    @State private var canonicalCareFingerprint: String?
    @State private var correction: CorrectionPhase = .loading
    @State private var dateEdit: WateringDateEdit?
    @State private var wateringUndoEntry: UUID?
    @State private var showingWateringUndo = false
    @State private var showingWateringRecord = false
    @State private var wateringRecordOutcome: SavedWateringOutcome?
    @State private var wateringRecordFailed = false
    @State private var wateringRecordOperation: UUID?
    @State private var wateringRecordNeedsReview = false
    // Retain the frozen intent until positive canonical proof or an explicit terminal retry.
    @State private var uncertainWateringCommand: CommandEnvelopeDTO?
    @State private var recoveringWateringRecord = false

    private var locale: SupportedLocale { polish ? .pl : .en }
    private var speciesRead: SpeciesRead { SpeciesRead(slug: card.speciesSlug, taxonId: card.taxonId, locale: locale) }
    private var currentSpecies: PublishedSpeciesCard? {
        guard let species, species.id == card.speciesSlug,
              card.taxonId == nil || species.taxonId == card.taxonId else { return nil }
        return species
    }

    var body: some View {
        let requestedAdvice = adviceRequest
        let requestedSpecies = speciesRead
        if connection.snapshot == expected {
            if checkingDeletion || deleting || pendingDeletion != nil {
                deletionStatus
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(card.personalName ?? currentSpecies?.displayName ?? (polish ? "Roślina" : "Plant"))
                        .font(.title)
                        .accessibilityIdentifier("catalogue.saved.name")
                    if let name = currentSpecies?.displayName ?? card.speciesSlug {
                        Text(name).accessibilityIdentifier("catalogue.saved.species")
                    }
                    if polish, let conditions = currentConditions {
                        CatalogueSavedConditionsView(conditions: conditions, polish: polish)
                    }
                    if !polish {
                        renameControls
                            .disabled(routineBusy || manualRecordBusy)
                    }
                    if deletionFailed {
                        Text(polish ? "Nie udało się usunąć rośliny." : "Couldn’t delete this plant.")
                            .accessibilityIdentifier("collection.delete.failed")
                    }
                    firstAidJournal
                        .disabled(routineBusy || manualRecordBusy)
                    if let startRepeatDiagnosis {
                        Button("Check plant again", action: startRepeatDiagnosis)
                            .buttonStyle(.bordered)
                            .disabled(manualRecordBusy)
                            .accessibilityIdentifier("collection.diagnosis.repeat")
                    }
                    if let photo = card.mainPhotoId {
                        CataloguePrivatePhotoView(connection: connection, expected: expected, subject: .plant(card.id), polish: polish)
                            .id(photo)
                    }
                    if let advice {
                        PlantCareRecommendationContent(
                            recommendation: advice,
                            showNextCheck: canShowAdviceDate
                        )
                    }
                    if !polish {
                        routineCompletionControls
                        #if DEBUG
                        if connection.withdrawCareSourceFixture != nil {
                            Button("Withdraw fixture care source") { try? connection.withdrawCareSourceFixture?() }
                                .accessibilityIdentifier("collection.care.fixture.withdraw")
                        }
                        if connection.routineFixtureNow != nil {
                            Button("Advance entitlement clock") { connection.advanceRoutineFixtureClock?() }
                                .accessibilityIdentifier("collection.routine.fixture.expire")
                        }
                        #endif
                        routineJournal
                        basicCareEnableControls
                            .disabled(routineBusy || manualRecordBusy)
                        adviceRefreshControls
                            .disabled(routineBusy || manualRecordBusy)
                        if let firstAid, firstAid.accessUntil.map({ $0 > Date() }) ?? true {
                            ForEach(firstAid.controls) { control in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("First-aid soil check · \(control.policy.dueOn)")
                                        .font(.headline)
                                        .accessibilityIdentifier("catalogue.saved.firstAid.date")
                                    Link("First-aid interval source", destination: control.policy.source.url)
                                        .accessibilityIdentifier("catalogue.saved.firstAid.source")
                                    if firstAidWriteAvailable, control.canObserve(careRevision: card.careRevision),
                                       firstAidHistory.contains(where: { $0.id == control.actionEntryId && $0.state == "active" }) {
                                        FirstAidObservationActions(controlId: control.id) { jpeg in
                                            firstAidSelection = .observe(control.id, jpeg)
                                            showingFirstAidDialog = true
                                        }
                                        .disabled(routineBusy || manualRecordBusy)
                                    }
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("catalogue.saved.firstAid." + control.id.uuidString.lowercased())
                            }
                        }
                        wateringRecordControls
                        Text("Manual watering history").font(.headline)
                        correctionStatus
                        if let history {
                            if history.isEmpty { Text("No manual watering recorded.") }
                            ForEach(history) { entry in
                                Text(entry.occurredLocalDate + (entry.state == "voided" ? " · Undone" : " · Active"))
                                    .accessibilityIdentifier("catalogue.saved.history." + entry.id.uuidString.lowercased())
                                if !routineBusy, correction == .ready, let edit = WateringDateEdit(entry) {
                                    Button("Correct watering date") { dateEdit = edit }
                                        .accessibilityIdentifier("collection.watering.correct." + entry.id.uuidString.lowercased())
                                }
                                if !routineBusy, correction == .ready, entry.state == "active" {
                                    Button("Undo watering") {
                                        wateringUndoEntry = entry.id
                                        showingWateringUndo = true
                                    }
                                    .accessibilityIdentifier("collection.watering.undo." + entry.id.uuidString.lowercased())
                                }
                            }
                        }
                        if historyFailed || adviceFailed || correction == .failed {
                            Button("Retry care details") {
                                attempt += 1
                                adviceRequest += 1
                            }
                        }
                        analysisHistorySection
                    }
                    Button(polish ? "Usuń roślinę" : "Delete plant", role: .destructive) {
                        deleteConfirmation = true
                    }
                    .disabled(routineBusy || manualRecordBusy)
                    .accessibilityIdentifier("collection.delete")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("catalogue.saved.card." + card.id.uuidString.lowercased())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .disabled(recoveringWateringRecord)
            .task(id: requestedSpecies) { await loadCardSpecies(requestedSpecies) }
            .task(id: attempt) { await loadCare() }
            .task(id: [attempt, card.careRevision]) { await loadFirstAidJournal() }
            .task(id: card.careRevision) { await loadAnalysisHistory() }
            .task { await loadRename() }
            .task {
                await loadPendingRoutine()
                await loadPendingAdviceRefresh()
                await loadBasicCareState()
            }
            .task(id: requestedAdvice) { await loadAdvice(requestedAdvice) }
            .task(id: firstAid?.accessUntil) {
                guard let expiry = firstAid?.accessUntil else { return }
                do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) }
                catch { return }
                if firstAid?.accessUntil == expiry { firstAid?.controls.removeAll() }
            }
            .task(id: CanonicalCareRead(revision: card.revision, active: scenePhase == .active)) {
                routineClock = Date()
                guard scenePhase == .active, let sync = connection.syncEngine else { return }
                let updates = await sync.canonicalSyncUpdates()
                await rereadCanonicalCare(refreshOnForeground: true)
                for await _ in updates {
                    guard !Task.isCancelled, connection.snapshot == expected else { return }
                    await rereadCanonicalCare()
                }
            }
            .task(id: CanonicalCareRead(revision: card.revision, active: scenePhase == .active)) {
                guard scenePhase == .active, let sync = connection.syncEngine else { return }
                let idle = await sync.outboxIdleUpdates(for: expected.session.userId)
                for await _ in idle {
                    guard !Task.isCancelled, connection.snapshot == expected else { return }
                    // A bounded owner pass can reveal publication changes with no owner rows.
                    // This GET revalidation does not drain or publish sync, so cannot self-retry.
                    await rereadCanonicalCare(refreshOnForeground: true)
                }
            }
            .task(id: routineEntitlement?.verifiedAccessUntil) {
                guard let expiry = routineEntitlement?.verifiedAccessUntil else { return }
                do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) }
                catch { return }
                guard !Task.isCancelled, connection.snapshot == expected,
                      routineEntitlement?.verifiedAccessUntil == expiry else { return }
                routineClock = max(Date(), expiry)
            }
            .alert("Undo this soil check?", isPresented: $showingRoutineUndo) {
                Button("Undo soil check", role: .destructive) {
                    let entry = routineUndoSelection
                    routineUndoSelection = nil
                    Task { await undoRoutine(entry) }
                }
                Button("Cancel", role: .cancel) { routineUndoSelection = nil }
            }
            .alert("Edit plant name", isPresented: $editingName) {
                TextField("Plant name", text: $nameInput)
                    .accessibilityIdentifier("collection.rename.input")
                Button("Save name") {
                    let input = nameInput
                    Task { await editPlant(.name(input)) }
                }
                .disabled(PlantEditCommand.normalizedName(nameInput) == nil)
                .accessibilityIdentifier("collection.rename.save")
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Edit light", isPresented: $editingLight, titleVisibility: .visible) {
                ForEach(PlantLightCode.allCases, id: \.self) { light in
                    Button(light.label) { Task { await editPlant(.light(light)) } }
                        .accessibilityIdentifier("collection.light.\(light.rawValue)")
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Edit drainage", isPresented: $editingDrainage, titleVisibility: .visible) {
                ForEach(PlantDrainageCode.allCases, id: \.self) { drainage in
                    Button(drainage.label) { Task { await editPlant(.drainage(drainage)) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Edit watering frequency", isPresented: $editingWatering, titleVisibility: .visible) {
                ForEach(PlantWateringCode.choices, id: \.self) { watering in
                    Button(watering.label) { Task { await editPlant(.watering(watering)) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Edit pot type", isPresented: $editingPotType, titleVisibility: .visible) {
                ForEach(PlantPotType.allCases, id: \.self) { potType in
                    Button(potType.label) { Task { await editPlant(.potType(potType)) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $editingSpecies) {
                if connection.snapshot == expected {
                    NavigationStack {
                        GuestCatalogueView(
                            connection: connection, polish: false,
                            speciesPicker: .init(taxonId: card.taxonId, slug: card.speciesSlug) { taxonId in
                                guard connection.snapshot == expected else { return }
                                editingSpecies = false
                                Task { await editPlant(.taxon(taxonId)) }
                            },
                            back: { editingSpecies = false }
                        )
                        .navigationTitle("Change species")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
            .alert(
                polish ? "Usunąć tę roślinę?" : "Delete this plant?", isPresented: $deleteConfirmation
            ) {
                Button(polish ? "Usuń" : "Delete", role: .destructive) {
                    Task { await deletePlant(retry: nil) }
                }
                .accessibilityIdentifier("collection.delete.confirm")
                Button(polish ? "Anuluj" : "Cancel", role: .cancel) {}
            } message: {
                Text(polish ? "Zdjęcia i historia tej rośliny zostaną usunięte."
                     : "This plant’s photos and history will be deleted.")
            }
            .confirmationDialog(
                firstAidSelection?.title ?? "", isPresented: $showingFirstAidDialog, titleVisibility: .visible,
                presenting: firstAidSelection
            ) { selection in
                switch selection {
                case let .undo(entryId):
                    Button("Undo soil check", role: .destructive) { Task { await writeFirstAid(.undo(entryId)) } }
                        .accessibilityIdentifier("collection.firstAid.undo.confirm")
                case let .observe(controlId, jpeg):
                    ForEach(FirstAidObservationStatus.allCases, id: \.self) { status in
                        Button(status.label) {
                            firstAidSelection = nil
                            Task { await writeFirstAid(.observe(controlId, status, jpeg)) }
                        }
                            .accessibilityIdentifier("collection.firstAid.observe.status." + status.rawValue)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $dateEdit) { edit in
                WateringDateEditor(edit: edit) { date in
                    dateEdit = nil
                    Task { await correctDate(edit, to: date) }
                }
            }
            .alert("Record watering now?", isPresented: $showingWateringRecord) {
                Button("Confirm watering") {
                    let date = Date()
                    let timezone = TimeZone.current
                    Task { await recordWatering(date: date, timezone: timezone) }
                }
                .accessibilityIdentifier("collection.watering.record.confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Record that you watered this plant. This does not complete a soil check.")
            }
            .alert("Undo this watering?", isPresented: $showingWateringUndo, presenting: wateringUndoEntry) { entryId in
                Button("Undo watering", role: .destructive) {
                    Task { await enqueueWateringEdit(.undo(entryId)) }
                }
                .accessibilityIdentifier("collection.watering.undo.confirm")
                Button("Cancel", role: .cancel) {}
            }
            }
        }
    }

    private var deletionStatus: some View {
        Group {
            if checkingDeletion || deleting {
                ProgressView()
                    .task { await loadDeletion() }
            } else if let pendingDeletion {
                VStack(spacing: 12) {
                    Text(polish ? "Usunięcie oczekuje na synchronizację." : "Deletion pending sync.")
                        .accessibilityIdentifier("collection.delete.pending")
                    Button(polish ? "Ponów usunięcie" : "Retry deletion") {
                        Task { await deletePlant(retry: pendingDeletion) }
                    }
                    .accessibilityIdentifier("collection.delete.retry")
                }
                .padding()
            }
        }
    }

    private func loadDeletion() async {
        guard checkingDeletion else { return }
        defer { checkingDeletion = false }
        do {
            guard let repository = connection.repository else { throw SyncWireValidationError.invalidSession }
            let lease = try await connection.collectionLease(expected: expected)
            let pending = try await repository.pendingPlantDeletion(plantId: card.id, context: lease)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            pendingDeletion = pending
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            deletionFailed = true
        }
    }

    private func deletePlant(retry: CommandEnvelopeDTO?) async {
        guard !deleting, let repository = connection.repository else { return }
        deleting = true
        deletionFailed = false
        defer { deleting = false }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let command: CommandEnvelopeDTO
            if let retry {
                command = retry
            } else {
                command = try await repository.enqueuePlantDeletion(plantId: card.id, context: lease)
            }
            pendingDeletion = command
            let outcome = try await repository.retryPlantDeletion(command, context: lease)
            guard connection.snapshot == expected else { return }
            switch outcome {
            case .pending: break
            case .confirmed:
                try publishConfirmedCareRead(lease)
                onDeleted()
            case .rejected:
                pendingDeletion = nil
                deletionFailed = true
            }
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            deletionFailed = true
        }
    }

    @ViewBuilder
    private var renameControls: some View {
        if savingRename {
            ProgressView("Saving plant edit…")
        } else if let pendingRename, let edit = PlantEditCommand(pendingRename) {
            let labels = switch edit.change {
            case .name: ("Plant name pending sync.", "Retry name change")
            case .taxon: ("Species change pending sync.", "Retry species change")
            case .light: ("Light change pending sync.", "Retry light change")
            case .drainage: ("Drainage change pending sync.", "Retry drainage change")
            case .watering: ("Watering frequency pending sync.", "Retry watering frequency")
            case .potType: ("Pot type pending sync.", "Retry pot type change")
            }
            Text(labels.0)
                .accessibilityIdentifier("collection.rename.pending")
            Button(labels.1) { Task { await editPlant() } }
                .accessibilityIdentifier("collection.rename.retry")
        } else if !loadingRename {
            Button("Edit name") {
                nameInput = rejectedNameInput ?? card.personalName ?? ""
                editingName = true
            }
            .accessibilityIdentifier("collection.rename.open")
            if let currentLight = currentConditions?.light {
                Text(currentLight.label).accessibilityIdentifier("collection.light.current")
            }
            Button("Edit light") { editingLight = true }
                .accessibilityIdentifier("collection.light.open")
            if let drainage = currentConditions?.drainage {
                Text(drainage.label).accessibilityIdentifier("collection.drainage.current")
            }
            Button("Edit drainage") { editingDrainage = true }
                .accessibilityIdentifier("collection.drainage.open")
            if let watering = currentConditions?.watering {
                Text(watering.label).accessibilityIdentifier("collection.watering.frequency.current")
            }
            Button("Edit watering frequency") { editingWatering = true }
                .accessibilityIdentifier("collection.watering.frequency.open")
            if let potType = currentConditions?.potType {
                Text(potType.label).accessibilityIdentifier("collection.pot.type.current")
            }
            Button("Edit pot type") { editingPotType = true }
                .accessibilityIdentifier("collection.pot.type.open")
            Button("Change species") { editingSpecies = true }
                .accessibilityIdentifier("collection.species.open")
        }
        if detailsReadFailed {
            Text("Some plant details are unavailable.")
                .accessibilityIdentifier("collection.details.unavailable")
        }
        if renameFailed {
            Text("Couldn’t save the plant edit.")
                .accessibilityIdentifier("collection.rename.failed")
        }
    }

    private func loadCardSpecies(_ requested: SpeciesRead) async {
        guard let api = connection.apiClient else { return }
        let loaded: PublishedSpeciesCard?
        if let taxonId = requested.taxonId {
            loaded = try? await api.fetchPublishedSpecies(taxonId: taxonId, locale: requested.locale)
        } else if let slug = requested.slug {
            loaded = try? await api.fetchPublishedSpecies(slug: slug, locale: requested.locale)
        } else {
            loaded = nil
        }
        guard !Task.isCancelled, connection.snapshot == expected else { return }
        species = loaded
    }

    private func loadRename() async {
        guard let repository = connection.repository else { return }
        loadingRename = true
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let pending: CommandEnvelopeDTO? = if polish {
                nil
            } else {
                try await repository.pendingPlantEdit(plantId: card.id, context: lease)
            }
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            // Pending identity is mandatory; missing optional condition fields must not
            // leave manual care locked after the pending read already succeeded.
            pendingRename = pending
            loadingRename = false
            do {
                let conditions = try await repository.syncedPlantConditions(for: card, context: lease)
                guard !Task.isCancelled, connection.snapshot == expected else { return }
                currentConditions = conditions
                detailsReadFailed = card.currentConditionSnapshotId != nil && conditions == nil
            } catch {
                guard !Task.isCancelled, connection.snapshot == expected else { return }
                currentConditions = nil
                detailsReadFailed = true
            }
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            renameFailed = true
        }
    }

    private func editPlant(_ change: PlantEditCommand.Change? = nil) async {
        guard !savingRename, let repository = connection.repository else { return }
        savingRename = true
        renameFailed = false
        defer { savingRename = false }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let command: CommandEnvelopeDTO
            if let pendingRename {
                command = pendingRename
            } else if let change {
                command = try await repository.enqueuePlantEdit(plantId: card.id, change: change, context: lease)
            } else {
                return
            }
            pendingRename = command
            let acceptance = try await repository.retryPlantEditAcceptance(command, context: lease)
            if acceptance == .confirmed { try publishConfirmedCareRead(lease) }
            let updated = try await repository.plantEditCard(command, context: lease)
            let remaining = try await repository.pendingPlantEdit(plantId: card.id, context: lease)
            let savedConditions: PlantConditionCodes?
            if let updated {
                savedConditions = try await repository.syncedPlantConditions(for: updated, context: lease)
            } else {
                savedConditions = nil
            }
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            pendingRename = remaining
            guard remaining == nil, let edit = PlantEditCommand(command) else { return }
            if let updated {
                currentConditions = savedConditions
                if updated.careRevision != card.careRevision {
                    firstAid?.controls.removeAll()
                    advice = nil
                    adviceRequest += 1
                }
                onRenamed(updated)
            }
            switch edit.change {
            case let .name(requested):
                renameFailed = updated?.personalName != requested
                if case let .name(input) = change, renameFailed {
                    rejectedNameInput = input
                } else {
                    rejectedNameInput = renameFailed ? requested : nil
                }
            case let .taxon(requested):
                renameFailed = updated?.taxonId != requested
            case let .light(requested):
                renameFailed = updated == nil || (savedConditions?.light ?? .unknown) != requested
            case let .drainage(requested):
                renameFailed = updated == nil || (savedConditions?.drainage ?? .unknown) != requested
            case let .watering(requested):
                renameFailed = updated == nil || (savedConditions?.watering ?? .unknown) != requested
            case let .potType(requested):
                renameFailed = updated == nil || (savedConditions?.potType ?? .unknown) != requested
            }
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            renameFailed = true
            if pendingRename == nil, case let .name(input) = change { rejectedNameInput = input }
        }
    }

    @ViewBuilder
    private var analysisHistorySection: some View {
        if !analysisHistory.isEmpty {
            Text("Analysis history").font(.headline)
            ForEach(analysisHistory) { item in
                let title = switch item.mode {
                case .identification: "Species identification"
                case .diagnosis: "Diagnosis"
                case .followUp: "Follow-up analysis"
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text(item.date, format: .dateTime.month(.abbreviated).day().year().locale(locale.locale))
                        .font(.caption)
                    if item.previousConditions {
                        Text("Based on previous conditions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("collection.analysis.previous." + item.id.uuidString.lowercased())
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("collection.analysis.history." + item.id.uuidString.lowercased())
            }
        }
    }

    private func loadAnalysisHistory() async {
        guard !polish, let repository = connection.repository else { return }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let rows = try await repository.collectionAnalysisHistory(plantId: card.id, context: lease)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            analysisHistory = rows
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            analysisHistory = []
        }
    }

    @ViewBuilder
    private var firstAidJournal: some View {
        if !polish {
            if !firstAidHistory.isEmpty {
                Text("First-aid journal").font(.headline)
                ForEach(firstAidHistory) { entry in
                    Text("Soil checked · " + entry.occurredLocalDate + (entry.state == "voided" ? " · Undone" : ""))
                        .accessibilityIdentifier("catalogue.saved.firstAid.entry." + entry.id.uuidString.lowercased())
                    if entry.state == "active", firstAidWriteAvailable {
                        Button("Undo soil check") {
                            firstAidSelection = .undo(entry.id)
                            showingFirstAidDialog = true
                        }
                        .accessibilityIdentifier("collection.firstAid.undo." + entry.id.uuidString.lowercased())
                    }
                }
            }
            ForEach(firstAid?.observations ?? []) { observation in
                Text("Observation · \(observation.status.label)")
                    .accessibilityIdentifier("catalogue.saved.firstAid.observation." + observation.id.uuidString.lowercased())
                if let date = SQLTimestamp.date(from: observation.observedAt) {
                    Text(date, format: .dateTime.month(.abbreviated).day().year().locale(locale.locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("catalogue.saved.firstAid.observation.date." + observation.id.uuidString.lowercased())
                }
                if let photoId = observation.photoId {
                    CataloguePrivatePhotoView(
                        connection: connection, expected: expected, subject: .observation(observation.id), polish: polish
                    )
                    .id(photoId)
                }
            }
            if savingFirstAid {
                ProgressView("Syncing first-aid journal…")
            } else if let pendingObservationPhoto {
                Text("Observation photo couldn’t finish uploading.")
                    .accessibilityIdentifier("collection.firstAid.photo.pending")
                Button("Retry photo upload") { Task { await writeFirstAid(.retryObservationPhoto(pendingObservationPhoto)) } }
                    .accessibilityIdentifier("collection.firstAid.photo.retry")
                Button("Discard pending photo", role: .destructive) {
                    Task { await writeFirstAid(.discardObservationPhoto(pendingObservationPhoto)) }
                }
                .accessibilityIdentifier("collection.firstAid.photo.discard")
            } else if let pendingObservation {
                Text("Observation pending sync.")
                    .accessibilityIdentifier("collection.firstAid.observe.pending")
                Button("Retry observation") { Task { await writeFirstAid(.retryObservation(pendingObservation)) } }
                    .accessibilityIdentifier("collection.firstAid.observe.retry")
            } else if let pendingFirstAidUndo {
                Text("Soil check undo pending sync.")
                    .accessibilityIdentifier("collection.firstAid.undo.pending")
                Button("Retry undo") { Task { await writeFirstAid(.retryUndo(pendingFirstAidUndo)) } }
                    .accessibilityIdentifier("collection.firstAid.undo.retry")
            } else if let pendingFirstAid {
                Text("Soil check pending sync.")
                Button("Retry soil check") { Task { await writeFirstAid(.retryRecord(pendingFirstAid)) } }
                    .accessibilityIdentifier("collection.firstAid.retry")
            }
            if firstAidFailed {
                Text("Couldn’t sync the first-aid journal.")
                if firstAidWriteAvailable {
                    Button("Reload first-aid journal") { Task { await loadFirstAidJournal() } }
                }
            }
        }
    }

    private var firstAidWriteAvailable: Bool {
        !savingFirstAid && pendingFirstAid == nil && pendingFirstAidUndo == nil
            && pendingObservation == nil && pendingObservationPhoto == nil
    }

    private func loadFirstAidJournal() async {
        guard !polish, let repository = connection.repository else { return }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            try await loadFirstAidJournal(repository, lease: lease)
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            firstAidFailed = true
        }
    }

    private func loadFirstAidJournal(_ repository: CollectionRepository, lease: SyncSessionLease) async throws {
        let pending = try await repository.pendingFirstAidRecord(plantId: card.id, context: lease)
        let pendingUndo = try await repository.pendingFirstAidUndo(plantId: card.id, context: lease)
        let observation = try await repository.pendingFirstAidObservation(plantId: card.id, context: lease)
        let photo = try await repository.pendingFirstAidPhotoDraft(plantId: card.id, context: lease)
        let journal = try await repository.collectionFirstAidHistory(plantId: card.id, context: lease)
        let control = try? await repository.collectionFirstAidControls(plantId: card.id, context: lease)
        guard !Task.isCancelled, connection.snapshot == expected else { throw CancellationError() }
        pendingFirstAid = pending
        pendingFirstAidUndo = pendingUndo
        pendingObservation = observation
        pendingObservationPhoto = photo
        firstAidHistory = journal
        firstAid = control
        firstAidFailed = false
    }

    private func publishConfirmedCareRead(_ lease: SyncSessionLease) throws {
        // Disabled integration must not impose JWT requirements on legacy domain callers.
        guard isLocaleCurrent() else { return }
        try Task.checkCancellation()
        guard connection.snapshot == expected, let api = connection.apiClient else { return }
        try api.syncAuthority.withPermanentBoundValid(lease) {}
        connection.publishExplicitCareRead(expected: expected, locale: polish ? "pl" : "en",
                                           isLocaleCurrent: isLocaleCurrent)
    }

    private func writeFirstAid(_ write: FirstAidWrite) async {
        guard !savingFirstAid, let repository = connection.repository else { return }
        savingFirstAid = true
        defer { savingFirstAid = false }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let outcome: FirstAidWriteOutcome
            switch write {
            case let .retryRecord(command):
                outcome = try await repository.retryFirstAidRecord(command, context: lease)
            case let .undo(entryId):
                let command = try await repository.enqueueFirstAidUndo(plantId: card.id, entryId: entryId, context: lease)
                pendingFirstAidUndo = command
                outcome = try await repository.retryFirstAidUndo(command, context: lease)
            case let .retryUndo(command):
                outcome = try await repository.retryFirstAidUndo(command, context: lease)
            case let .observe(controlId, status, jpeg):
                if let jpeg {
                    let draft = try await repository.enqueueFirstAidPhotoDraft(
                        plantId: card.id, controlId: controlId, status: status, jpeg: jpeg, context: lease
                    )
                    pendingObservationPhoto = draft
                    outcome = try await repository.retryFirstAidPhotoDraft(draft, context: lease)
                } else {
                    let command = try await repository.enqueueFirstAidObservation(
                        plantId: card.id, controlId: controlId, status: status, context: lease
                    )
                    pendingObservation = command
                    outcome = try await repository.retryFirstAidObservation(command, context: lease)
                }
            case let .retryObservation(command):
                outcome = try await repository.retryFirstAidObservation(command, context: lease)
            case let .retryObservationPhoto(draft):
                outcome = try await repository.retryFirstAidPhotoDraft(draft, context: lease)
            case let .discardObservationPhoto(draft):
                try await repository.discardFirstAidPhotoDraft(draft, context: lease)
                try await loadFirstAidJournal(repository, lease: lease)
                return
            }
            if case .confirmed = outcome { try publishConfirmedCareRead(lease) }
            try await loadFirstAidJournal(repository, lease: lease)
            if case .rejected = outcome { firstAidFailed = true }
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            firstAidFailed = true
        }
    }

    private var manualRecordBusy: Bool {
        switch correction {
        case .recordSaving, .recordPending: true
        default: false
        }
    }

    private var canRecordWatering: Bool {
        connection.snapshot == expected && !polish && !recoveringWateringRecord && correction == .ready
            && !checkingDeletion && !deleting && pendingDeletion == nil
            && !loadingRename && !savingRename && pendingRename == nil
            && !editingName && !editingSpecies && !editingLight && !editingDrainage
            && !editingWatering && !editingPotType && dateEdit == nil && !showingWateringUndo
            && !savingRoutine && !savingFirstAid && !refreshingAdvice && !enablingBasicCare
    }

    private var canRecoverUnconfirmedWatering: Bool {
        connection.snapshot == expected && !polish && uncertainWateringCommand != nil
            && wateringRecordOutcome == .unconfirmed && !recoveringWateringRecord && !manualRecordBusy
            && !routineBusy && firstAidWriteAvailable
            && !checkingDeletion && !deleting && pendingDeletion == nil
            && !loadingRename && !savingRename && pendingRename == nil
            && !editingName && !editingSpecies && !editingLight && !editingDrainage
            && !editingWatering && !editingPotType && dateEdit == nil && !showingWateringUndo
            && !savingRoutine && !savingFirstAid && !refreshingAdvice && !enablingBasicCare
    }

    @MainActor
    private func recoverUnconfirmedWatering(retryOriginal: Bool) async {
        guard canRecoverUnconfirmedWatering, let original = uncertainWateringCommand,
              original.plantId == card.id, ManualWateringAction(envelope: original) == .record,
              let repository = connection.repository, let sync = connection.syncEngine,
              let api = connection.apiClient else { return }
        recoveringWateringRecord = true
        wateringRecordFailed = false
        defer { recoveringWateringRecord = false }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            guard try await repository.pendingManualWatering(plantId: card.id, context: lease) == nil,
                  try await repository.pendingPlantEdit(plantId: card.id, context: lease) == nil else {
                throw SyncWireValidationError.invalidRequest
            }
            if retryOriginal {
                // Explicit user intent only. This reuses the original UUID/body, never a new record.
                let outcome = try await repository.retryUncertainSavedPlantWatering(original, context: lease)
                try Task.checkCancellation()
                try api.syncAuthority.withPermanentBoundValid(lease) {}
                guard connection.snapshot == expected, uncertainWateringCommand == original else { return }
                if outcome == .confirmed { try publishConfirmedCareRead(lease) }
                if outcome == .confirmed || outcome == .rejected {
                    uncertainWateringCommand = nil
                    wateringRecordNeedsReview = false
                    try await loadHistory(repository, lease: lease)
                    guard !Task.isCancelled, connection.snapshot == expected else { return }
                    wateringRecordOutcome = outcome
                    adviceRequest += 1
                } else {
                    try await loadHistory(repository, lease: lease)
                }
            } else {
                _ = try await sync.performFullRefresh(context: lease)
                try Task.checkCancellation()
                try api.syncAuthority.withPermanentBoundValid(lease) {}
                guard connection.snapshot == expected, uncertainWateringCommand == original else { return }
                // Probe the original fact before optional view reads; a negative window is not proof.
                if let store = connection.store,
                   try await store.confirmedWateringRecord(original, context: lease, authority: api.syncAuthority) != nil,
                   try await repository.pendingManualWatering(plantId: card.id, context: lease) == nil,
                   try await repository.pendingPlantEdit(plantId: card.id, context: lease) == nil {
                    try publishConfirmedCareRead(lease)
                }
                try await loadHistory(repository, lease: lease)
                if wateringRecordOutcome == .confirmed { adviceRequest += 1 }
            }
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            correction = .blocked
            wateringRecordOutcome = .unconfirmed
            wateringRecordFailed = true
        }
    }

    @ViewBuilder
    private var wateringRecordControls: some View {
        Button("Record watering") { showingWateringRecord = true }
            .disabled(!canRecordWatering)
            .accessibilityIdentifier("collection.watering.record")
        switch correction {
        case .recordSaving:
            ProgressView("Saving watering record…")
                .accessibilityIdentifier("collection.watering.record.saving")
        case let .recordPending(command):
            if wateringRecordNeedsReview {
                Text("Watering record needs review. Retry this record to resolve it.")
                    .accessibilityIdentifier("collection.watering.record.failed")
                    #if DEBUG
                    .accessibilityValue(command.operationId.uuidString.lowercased())
                    #endif
            } else {
                Text("Watering record pending sync.")
                    .accessibilityIdentifier("collection.watering.record.pending")
                    #if DEBUG
                    .accessibilityValue(command.operationId.uuidString.lowercased())
                    #endif
            }
            Button("Retry watering record") { Task { await retryWateringRecord(command) } }
                .accessibilityIdentifier("collection.watering.record.retry")
        default:
            EmptyView()
        }
        if let wateringRecordOutcome {
            switch wateringRecordOutcome {
            case .confirmed:
                Text("Watering recorded.")
                    .accessibilityIdentifier("collection.watering.record.confirmed")
            case .rejected:
                Text("Watering record rejected. No watering was recorded. You can try a new record.")
                    .accessibilityIdentifier("collection.watering.record.rejected")
                    #if DEBUG
                    .accessibilityValue(wateringRecordOperation?.uuidString.lowercased() ?? "")
                    #endif
            case .unconfirmed:
                Text("Watering could not be confirmed. Reload history or retry the original record.")
                    .accessibilityIdentifier("collection.watering.record.unconfirmed")
                    #if DEBUG
                    .accessibilityValue(wateringRecordOperation?.uuidString.lowercased() ?? "")
                    #endif
                Button("Reload care history") { Task { await recoverUnconfirmedWatering(retryOriginal: false) } }
                    .disabled(!canRecoverUnconfirmedWatering)
                    .accessibilityIdentifier("collection.watering.record.reload")
                Button("Retry original watering") { Task { await recoverUnconfirmedWatering(retryOriginal: true) } }
                    .disabled(!canRecoverUnconfirmedWatering)
                    .accessibilityIdentifier("collection.watering.record.retryOriginal")
                    #if DEBUG
                    .accessibilityValue(wateringRecordOperation?.uuidString.lowercased() ?? "")
                    #endif
            case .pending:
                EmptyView()
            }
        }
        if recoveringWateringRecord {
            ProgressView("Checking original watering…")
                .accessibilityIdentifier("collection.watering.record.reloading")
        }
        if wateringRecordFailed && !wateringRecordNeedsReview {
            Text("Couldn’t save or confirm the watering record.")
                .accessibilityIdentifier("collection.watering.record.failed")
        }
    }

    @MainActor
    private func recordWatering(date: Date, timezone: TimeZone) async {
        guard canRecordWatering, let repository = connection.repository else { return }
        correction = .recordSaving
        wateringRecordOutcome = nil
        wateringRecordFailed = false
        wateringRecordNeedsReview = false
        uncertainWateringCommand = nil
        do {
            let lease = try await connection.collectionLease(expected: expected)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            let command = try await repository.enqueueSavedPlantWatering(
                plantId: card.id, date: date, timezone: timezone, context: lease
            )
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            wateringRecordOperation = command.operationId
            correction = .recordPending(command)
            await retryWateringRecord(command)
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            correction = .failed
            wateringRecordFailed = true
        }
    }

    @MainActor
    private func retryWateringRecord(_ command: CommandEnvelopeDTO) async {
        guard connection.snapshot == expected, correction == .recordPending(command),
              let repository = connection.repository else { return }
        correction = .recordSaving
        wateringRecordOperation = command.operationId
        wateringRecordFailed = false
        wateringRecordOutcome = nil
        do {
            let lease = try await connection.collectionLease(expected: expected)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            let outcome = try await repository.retrySavedPlantWatering(command, context: lease)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            switch outcome {
            case .pending:
                correction = .recordPending(command)
            case .confirmed:
                try publishConfirmedCareRead(lease)
                uncertainWateringCommand = nil
                wateringRecordNeedsReview = false
                try await loadHistory(repository, lease: lease)
                guard !Task.isCancelled, connection.snapshot == expected else { return }
                wateringRecordOutcome = .confirmed
                adviceRequest += 1
            case .rejected:
                uncertainWateringCommand = nil
                wateringRecordNeedsReview = false
                correction = .ready
                wateringRecordOutcome = .rejected
            case .unconfirmed:
                uncertainWateringCommand = command
                correction = .blocked
                wateringRecordOutcome = .unconfirmed
                attempt += 1
                adviceRequest += 1
            }
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            correction = .recordPending(command)
            wateringRecordFailed = true
        }
    }

    @ViewBuilder
    private var correctionStatus: some View {
        switch correction {
        case .saving:
            ProgressView("Saving watering date…")
        case let .pending(command):
            let undo = command.commandName == ManualWateringAction.undoCommand
            Text(undo ? "Watering undo pending sync." : "Watering date pending sync.")
                .accessibilityIdentifier("collection.watering.pending")
            Button(undo ? "Retry watering undo" : "Retry watering date") { Task { await retryCorrection() } }
                .accessibilityIdentifier("collection.watering.retry")
        case .blocked:
            Text("Another watering change is pending.")
        case .failed:
            if !wateringRecordFailed { Text("Couldn’t load or save the watering date.") }
        default:
            EmptyView()
        }
    }

    @MainActor
    private func loadCare() async {
        guard let repository = connection.repository,
              let lease = try? await connection.collectionLease(expected: expected) else {
            guard !Task.isCancelled, connection.snapshot == expected,
                  !recoveringWateringRecord, correction != .saving, correction != .recordSaving else { return }
            historyFailed = true
            return
        }
        guard !Task.isCancelled, connection.snapshot == expected else { return }
        if !recoveringWateringRecord, correction != .saving && correction != .recordSaving {
            // Keep the frozen record visible to loadHistory until its pending/proof reads finish.
            if case .recordPending = correction {} else { correction = .loading }
            do {
                try await loadHistory(repository, lease: lease, passive: true)
            } catch {
                guard !Task.isCancelled, connection.snapshot == expected else { return }
                historyFailed = true
                correction = .failed
            }
        }
    }

    private var routineNow: Date {
        #if DEBUG
        if let now = connection.routineFixtureNow { return now }
        #endif
        return max(Date(), routineClock)
    }

    private var routineAccessAvailable: Bool {
        routineAccessLoaded && CatalogueRoutineAccessPolicy.allows(routineEntitlement, at: routineNow)
    }

    @MainActor
    private func rereadCanonicalCare(refreshOnForeground: Bool = false) async {
        guard !Task.isCancelled, connection.snapshot == expected else { return }
        // Access publication also fences dates on read-only Polish recommendations.
        await loadRoutineAccess()
        guard !Task.isCancelled, connection.snapshot == expected else { return }
        if !routineAccessAvailable { firstAid?.controls.removeAll() }
        guard let repository = connection.repository,
              let store = connection.store, let api = connection.apiClient else { return }
        guard !recoveringWateringRecord, !savingRename, !savingFirstAid, !savingRoutine,
              !enablingBasicCare, !refreshingAdvice,
              correction != .saving, correction != .recordSaving else { return }
        let previous = canonicalCareFingerprint
        // Unresolved, failed and deleted canonical reads cannot authorize an old date.
        canonicalCareFingerprint = nil
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let current = try await store.syncedCollectionCard(plantId: card.id, context: lease,
                                                               authority: api.syncAuthority)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            guard let current else {
                if try await store.plantDeletionWatermark(plantId: card.id, context: lease,
                                                          authority: api.syncAuthority) != nil {
                    guard !Task.isCancelled, connection.snapshot == expected else { return }
                    onDeleted()
                }
                return
            }
            if current != card {
                if current.careRevision != card.careRevision {
                    advice = nil
                    adviceResponse = nil
                    adviceRequest += 1
                    firstAid?.controls.removeAll()
                }
                onRenamed(current)
                return // The new card/revision task will reread its own context.
            }
            var parts: [String] = []
            for kind in ["plants", "condition_snapshots", "care_entries", "care_reversals", "care_tasks",
                         "care_plan_summaries", "basic_care_memberships", "first_aid_followups", "care_observations"] {
                for row in try await store.activeSyncedEntities(ownerId: lease.ownerId, entityType: kind) {
                    let body = try? JSONSerialization.jsonObject(with: Data(row.payloadJSON.utf8)) as? [String: Any]
                    let target = (body?["plant_id"] as? String).flatMap(UUID.init(uuidString:))
                    if (kind == "plants" && row.id == card.id) || target == card.id {
                        let normalized = try JSONSerialization.data(withJSONObject: body ?? [:], options: [.sortedKeys])
                        parts.append(kind + ":" + row.id.uuidString + ":" + String(decoding: normalized, as: UTF8.self))
                    }
                }
            }
            let fingerprint = parts.sorted().joined(separator: "\n")
            guard !Task.isCancelled, connection.snapshot == expected, !recoveringWateringRecord,
                  correction != .saving, correction != .recordSaving else { return }
            try await loadHistory(repository, lease: lease, passive: true)
            await loadPendingRoutine()
            await loadPendingAdviceRefresh()
            await loadBasicCareState()
            await loadFirstAidJournal()
            await loadAnalysisHistory()
            await loadRename()
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            // GET does not publish sync. Do not re-fetch merely because another sync
            // was published with the same care facts (including this GET's own callers).
            // A nil baseline also means a prior read may have been cancelled. Require
            // a fresh response before restoring date eligibility, even at the same revision.
            if previous != fingerprint || refreshOnForeground {
                adviceResponse = nil
                adviceRequest += 1
            }
            canonicalCareFingerprint = fingerprint
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            historyFailed = true
            adviceResponse = nil
            adviceRequest += 1
        }
    }

    private func loadRoutineAccess() async {
        routineAccessLoaded = false
        do {
            let entitlement = try await connection.syncedTrialEntitlement(expected: expected)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            routineEntitlement = entitlement
            routineAccessLoaded = true
        } catch {
            // A failed read must not turn unknown or expired access into Free.
        }
    }

    private var canShowAdviceDate: Bool {
        routineAccessAvailable && canonicalCareFingerprint != nil
            && adviceResponse == adviceRequest && !adviceFailed
            && correction == .ready && !historyFailed && !routineFailed && !routineBusy
            && !checkingAdviceRefresh && pendingAdviceRefresh == nil
            && !refreshingAdvice && !adviceRefreshFailed && !adviceRefreshReadFailed
            && basicCareEnabled != nil && !basicCarePending && !enablingBasicCare
            && !basicCareEnableFailed && !basicCareReadFailed
    }

    private var routineBusy: Bool {
        checkingRoutine || savingRoutine || pendingRoutine != nil || pendingRoutineUndo != nil
    }

    private var routineWriteAvailable: Bool {
        !checkingDeletion && !deleting && pendingDeletion == nil && !deletionFailed
            && !loadingRename && !savingRename && pendingRename == nil
            && !editingName && !editingSpecies && !editingLight && !editingDrainage
            && !editingWatering && !editingPotType && correction == .ready
            && dateEdit == nil && !showingWateringUndo && firstAidWriteAvailable
            && !refreshingAdvice && !checkingAdviceRefresh && pendingAdviceRefresh == nil
            && !enablingBasicCare && !basicCarePending
    }

    private var dueRoutine: PlantCareRecommendation.RoutineContext? {
        guard routineAccessAvailable, !checkingRoutine, !routineFailed, adviceResponse == adviceRequest,
              !adviceFailed, basicCareEnabled == true,
              let context = advice?.routineContext, context.plantId == card.id,
              context.check.careRevision == card.careRevision,
              let due = SQLCalendarDay.date(from: context.check.dueLocalDate) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        guard let today = SQLCalendarDay.date(from: formatter.string(from: Date())), due <= today else { return nil }
        return context
    }

    @ViewBuilder
    private var routineCompletionControls: some View {
        if savingRoutine {
            ProgressView("Saving soil check…")
        } else if pendingRoutine != nil {
            Text("Soil check pending sync.")
                .accessibilityIdentifier("collection.routine.pending")
            Button("Retry soil check") { Task { await completeRoutine() } }
                .disabled(!routineWriteAvailable)
                .accessibilityIdentifier("collection.routine.retry")
        } else if pendingRoutineUndo == nil, dueRoutine != nil, routineWriteAvailable {
            Button("Mark soil checked") { Task { await completeRoutine() } }
                .accessibilityIdentifier("collection.routine.complete")
        }
        if routineFailed {
            Text("Couldn’t confirm the soil check.")
                .accessibilityIdentifier("collection.routine.failed")
        }
        if routineConfirmed {
            Text("Soil check saved.")
                .accessibilityIdentifier("collection.routine.confirmed")
        }
    }

    @ViewBuilder
    private var routineJournal: some View {
        Text("Soil check history").font(.headline)
        ForEach(routineHistory) { entry in
            Text(entry.occurredLocalDate + (entry.state == "voided" ? " · Undone" : " · Active"))
                .accessibilityIdentifier("collection.routine.history." + entry.id.uuidString.lowercased())
            if entry.state == "active", entry.taskId != nil, !routineBusy, routineWriteAvailable {
                Button("Undo soil check") {
                    routineUndoSelection = entry
                    showingRoutineUndo = true
                }
                .accessibilityIdentifier("collection.routine.undo." + entry.id.uuidString.lowercased())
            }
        }
        if pendingRoutineUndo != nil {
            Text("Soil check undo pending sync.")
                .accessibilityIdentifier("collection.routine.undo.pending")
            Button("Retry soil check undo") { Task { await undoRoutine(nil) } }
                .disabled(savingRoutine || !routineWriteAvailable)
                .accessibilityIdentifier("collection.routine.undo.retry")
        }
        if routineUndoConfirmed {
            Text("Soil check undone.")
                .accessibilityIdentifier("collection.routine.undo.confirmed")
        }
        if routineFailed {
            Button("Reload soil check history") { Task { await loadPendingRoutine() } }
                .disabled(savingRoutine)
                .accessibilityIdentifier("collection.routine.history.retry")
        }
    }

    private func loadRoutineHistory(_ repository: CollectionRepository, lease: SyncSessionLease) async throws {
        let rows = try await repository.collectionRoutineSoilCheckHistory(plantId: card.id, context: lease)
        guard !Task.isCancelled, connection.snapshot == expected else { throw CancellationError() }
        routineHistory = rows
    }

    private func undoRoutine(_ entry: CatalogueCareJournalEntry?) async {
        guard !checkingRoutine, !savingRoutine, pendingRoutine == nil, routineWriteAvailable,
              connection.snapshot == expected, let repository = connection.repository else { return }
        guard pendingRoutineUndo != nil || entry.map({ selected in
            selected.state == "active" && selected.taskId != nil && routineHistory.contains(selected)
        }) == true else { return }
        savingRoutine = true
        routineFailed = false
        routineConfirmed = false
        routineUndoConfirmed = false
        defer { savingRoutine = false }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let command: RoutineSoilCheckUndoCommand
            if let pendingRoutineUndo {
                command = pendingRoutineUndo
            } else if let entry, let taskId = entry.taskId {
                command = try await repository.enqueueRoutineUndo(
                    plantId: card.id, taskId: taskId, entryId: entry.id, context: lease
                )
            } else { return }
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            pendingRoutineUndo = command
            let outcome = try await repository.retryRoutineUndo(command, context: lease)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            switch outcome {
            case .pending: break
            case .confirmed:
                try publishConfirmedCareRead(lease)
                pendingRoutineUndo = nil
                routineUndoConfirmed = true
                adviceRequest += 1
                try await loadRoutineHistory(repository, lease: lease)
            case .rejected, .unconfirmed:
                pendingRoutineUndo = nil
                routineFailed = true
                adviceRequest += 1
            }
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            routineFailed = true
        }
    }

    private func loadPendingRoutine() async {
        guard !savingRoutine, let repository = connection.repository else { return }
        checkingRoutine = true
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let pending = try await repository.pendingRoutineCompletion(plantId: card.id, context: lease)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            let undo = try await repository.pendingRoutineUndo(plantId: card.id, context: lease)
            try await loadRoutineHistory(repository, lease: lease)
            guard !Task.isCancelled, connection.snapshot == expected, !savingRoutine else { return }
            pendingRoutine = pending
            pendingRoutineUndo = undo
            routineFailed = false
            checkingRoutine = false
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            routineFailed = true
        }
    }

    private func completeRoutine() async {
        guard pendingRoutineUndo == nil, !savingRoutine, !checkingRoutine, routineWriteAvailable,
              connection.snapshot == expected, let repository = connection.repository else { return }
        let captured = dueRoutine
        guard pendingRoutine != nil || captured != nil else { return }
        savingRoutine = true
        routineFailed = false
        routineConfirmed = false
        routineUndoConfirmed = false
        defer { savingRoutine = false }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let command: RoutineSoilCheckCompletionCommand
            if let pendingRoutine {
                command = pendingRoutine
            } else if let captured {
                // Recheck after lease acquisition. Exact pending replay and undo
                // deliberately bypass this gate.
                let entitlement = try await connection.syncedTrialEntitlement(expected: expected)
                guard CatalogueRoutineAccessPolicy.allows(entitlement, at: routineNow) else {
                    await loadRoutineAccess()
                    return
                }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                command = try await repository.enqueueRoutineCompletion(
                    plantId: card.id, routineContext: captured,
                    occurredAt: formatter.string(from: Date()), timezone: TimeZone.current.identifier, context: lease
                )
            } else { return }
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            pendingRoutine = command
            let outcome = try await repository.retryRoutineCompletion(command, context: lease)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            switch outcome {
            case .pending: break
            case .confirmed:
                try publishConfirmedCareRead(lease)
                pendingRoutine = nil
                routineConfirmed = true
                adviceRequest += 1
                try await loadRoutineHistory(repository, lease: lease)
                await loadFirstAidJournal()
            case .rejected, .unconfirmed:
                pendingRoutine = nil
                routineFailed = true
                adviceRequest += 1
            }
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            routineFailed = true
        }
    }

    @ViewBuilder
    private var basicCareEnableControls: some View {
        if enablingBasicCare {
            ProgressView("Enabling basic care…")
        } else if basicCarePending {
            Text("Basic care is pending sync.")
                .accessibilityIdentifier("collection.care.enable.pending")
            Button("Retry enabling basic care") { Task { await enableBasicCare() } }
                .accessibilityIdentifier("collection.care.enable.retry")
        } else if basicCareEnabled == false, adviceResponse == adviceRequest,
                  advice?.nextCheckIntervalDays != nil, !savingRename, pendingRename == nil {
            Button("Enable basic care") { Task { await enableBasicCare() } }
                .accessibilityIdentifier("collection.care.enable")
        }
        if basicCareEnableFailed {
            Text("Couldn’t enable basic care.")
        }
    }

    private func loadBasicCareState() async {
        guard !enablingBasicCare else { return }
        basicCareReadFailed = true
        basicCareEnabled = nil
        guard let repository = connection.repository else { return }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let state = try await repository.basicCareEnableState(plantId: card.id, context: lease)
            guard !Task.isCancelled, connection.snapshot == expected, !enablingBasicCare else { return }
            basicCareEnabled = state.enabled
            basicCarePending = state.pending
            basicCareReadFailed = false
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            basicCareReadFailed = true
        }
    }

    private func enableBasicCare() async {
        guard !enablingBasicCare, let repository = connection.repository else { return }
        enablingBasicCare = true
        basicCareEnableFailed = false
        defer { enablingBasicCare = false }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let outcome = try await repository.enableBasicCare(plantId: card.id, context: lease)
            if outcome == .confirmed { try publishConfirmedCareRead(lease) }
            let state = try await repository.basicCareEnableState(plantId: card.id, context: lease)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            basicCareEnabled = state.enabled
            basicCarePending = state.pending
            if state.enabled && !state.pending {
                adviceRequest += 1
            } else if !state.pending {
                basicCareEnableFailed = true
            }
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            basicCareEnableFailed = true
        }
    }

    @ViewBuilder
    private var adviceRefreshControls: some View {
        if refreshingAdvice {
            ProgressView("Updating care recommendation…")
        } else if pendingAdviceRefresh != nil {
            Text("Care recommendation update pending.")
                .accessibilityIdentifier("collection.care.refresh.pending")
            Button("Retry recommendation update") {
                Task { await refreshAdvice() }
            }
            .accessibilityIdentifier("collection.care.refresh.retry")
        } else if !checkingAdviceRefresh, adviceResponse == adviceRequest, let advice,
                  advice.nextCheckIntervalDays != nil, advice.nextCheck == nil,
                  basicCareEnabled == true, !basicCarePending, !enablingBasicCare,
                  !loadingRename, !savingRename, pendingRename == nil {
            Button("Update care recommendation") {
                Task { await refreshAdvice() }
            }
            .accessibilityIdentifier("collection.care.refresh")
        }
        if adviceRefreshFailed {
            Text("Couldn’t update the care recommendation.")
        } else if !checkingAdviceRefresh, !adviceRefreshReadFailed, !basicCareReadFailed,
                  let request = adviceRefreshRead, request == adviceResponse, request == adviceRequest,
                  advice?.nextCheck == nil {
            Text("No next soil check is available yet.")
        }
    }

    private func loadPendingAdviceRefresh() async {
        guard !refreshingAdvice else { return }
        adviceRefreshReadFailed = true
        guard let repository = connection.repository else { return }
        checkingAdviceRefresh = true
        defer { checkingAdviceRefresh = false }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let pending = try await repository.pendingCareRecommendationRefresh(plantId: card.id, context: lease)
            guard !Task.isCancelled, connection.snapshot == expected, !refreshingAdvice else { return }
            pendingAdviceRefresh = pending
            adviceRefreshReadFailed = false
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected, !refreshingAdvice else { return }
            adviceRefreshReadFailed = true
        }
    }

    private func refreshAdvice() async {
        guard !refreshingAdvice, !savingRename, let repository = connection.repository else { return }
        refreshingAdvice = true
        adviceRefreshFailed = false
        adviceRefreshRead = nil
        defer { refreshingAdvice = false }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let command = try await repository.enqueueCareRecommendationRefresh(plantId: card.id, context: lease)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            pendingAdviceRefresh = command
            let outcome = try await repository.retryCareRecommendationRefresh(command, context: lease)
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            switch outcome {
            case .confirmed:
                try publishConfirmedCareRead(lease)
                pendingAdviceRefresh = nil
                adviceRequest += 1
                adviceRefreshRead = adviceRequest
            case .pending:
                pendingAdviceRefresh = command
            case .rejected, .unconfirmed:
                pendingAdviceRefresh = nil
                adviceRefreshFailed = true
            }
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            adviceRefreshFailed = true
        }
    }

    private func loadAdvice(_ requested: Int) async {
        guard !Task.isCancelled, connection.snapshot == expected,
              let api = connection.apiClient else { return }
        do {
            let lease = try await connection.collectionLease(expected: expected)
            guard !Task.isCancelled, connection.snapshot == expected, adviceRequest == requested else { return }
            let result = try await api.fetchCareRecommendation(plantId: card.id, context: lease, locale: polish ? .pl : .en)
            guard !Task.isCancelled, connection.snapshot == expected, adviceRequest == requested else { return }
            advice = result
            adviceResponse = requested
            adviceFailed = false
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected, adviceRequest == requested else { return }
            adviceFailed = true
        }
    }

    private func loadHistory(
        _ repository: CollectionRepository, lease: SyncSessionLease, passive: Bool = false
    ) async throws {
        let initialPhase = correction
        if passive, recoveringWateringRecord || correction == .saving || correction == .recordSaving { return }
        let original: CommandEnvelopeDTO?
        if case let .recordPending(command) = correction { original = command }
        else { original = uncertainWateringCommand }
        let result = try await repository.collectionWateringHistory(plantId: card.id, context: lease)
        let queued = try await repository.pendingManualWatering(plantId: card.id, context: lease)
        let review: Bool
        if let queued, ManualWateringAction(envelope: queued) == .record {
            review = try await repository.pendingWateringRecordRequiresReview(queued, context: lease)
        } else { review = false }
        guard !Task.isCancelled, connection.snapshot == expected else { throw CancellationError() }
        if passive, recoveringWateringRecord || correction != initialPhase { return }
        history = result
        historyFailed = false
        if let queued {
            if let uncertainWateringCommand, uncertainWateringCommand != queued {
                correction = .blocked
                wateringRecordOutcome = .unconfirmed
                return
            }
            wateringRecordNeedsReview = review
            if ManualWateringAction(envelope: queued) == .record {
                wateringRecordOperation = queued.operationId
                wateringRecordOutcome = .pending
                correction = .recordPending(queued)
            } else {
                correction = queued.commandName == ManualWateringAction.correctionCommand
                    || queued.commandName == ManualWateringAction.undoCommand ? .pending(queued) : .blocked
            }
        } else if let original {
            // Empty queue is not a receipt. Block BEFORE awaiting the canonical probe.
            uncertainWateringCommand = original
            wateringRecordOperation = original.operationId
            wateringRecordOutcome = .unconfirmed
            correction = .blocked
            guard let store = connection.store, let api = connection.apiClient else {
                throw SyncWireValidationError.invalidSession
            }
            let entry = try await store.confirmedWateringRecord(original, context: lease, authority: api.syncAuthority)
            let pending = try await repository.pendingManualWatering(plantId: card.id, context: lease)
            let edit = try await repository.pendingPlantEdit(plantId: card.id, context: lease)
            try Task.checkCancellation()
            try api.syncAuthority.withPermanentBoundValid(lease) {}
            guard connection.snapshot == expected, uncertainWateringCommand == original else {
                throw CancellationError()
            }
            if passive, recoveringWateringRecord || correction != .blocked { return }
            if entry != nil, pending == nil, edit == nil {
                uncertainWateringCommand = nil
                wateringRecordNeedsReview = false
                wateringRecordOutcome = .confirmed
                correction = .ready
            }
        } else {
            wateringRecordNeedsReview = false
            correction = .ready
        }
    }

    private func correctDate(_ edit: WateringDateEdit, to date: Date) async {
        await enqueueWateringEdit(.correction(entryId: edit.id, date: date, timezone: edit.timezone))
    }

    private func enqueueWateringEdit(_ action: ManualWateringAction) async {
        guard correction == .ready, let repository = connection.repository else { return }
        correction = .saving
        wateringRecordOutcome = nil
        wateringRecordFailed = false
        do {
            let lease = try await connection.collectionLease(expected: expected)
            try await repository.enqueueWateringEdit(action, plantId: card.id, context: lease)
            try await loadHistory(repository, lease: lease)
            await retryCorrection()
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            correction = .failed
        }
    }

    private func retryCorrection() async {
        guard case let .pending(command) = correction, let repository = connection.repository else { return }
        correction = .saving
        do {
            let lease = try await connection.collectionLease(expected: expected)
            let outcome = try await repository.retryWateringEdit(command, context: lease)
            if outcome == .confirmed { try publishConfirmedCareRead(lease) }
            try await loadHistory(repository, lease: lease)
            if correction == .ready { adviceRequest += 1 }
        } catch {
            guard !Task.isCancelled, connection.snapshot == expected else { return }
            correction = .pending(command)
        }
    }


}

private struct FirstAidObservationActions: View {
    let controlId: UUID
    let record: (Data?) -> Void
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var jpeg: Data?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Text(jpeg == nil ? "Add optional photo" : "Replace photo")
            }
            .accessibilityIdentifier("collection.firstAid.photo.select." + controlId.uuidString.lowercased())
            if loading {
                ProgressView("Preparing photo…")
            } else if jpeg != nil {
                Text("Photo ready").accessibilityIdentifier("collection.firstAid.photo.ready")
            } else if failed {
                Text("Couldn’t open the selected photo.")
                    .accessibilityIdentifier("collection.firstAid.photo.error")
            }
            if selectedPhoto != nil {
                Button("Remove photo") {
                    selectedPhoto = nil
                    jpeg = nil
                    failed = false
                    loading = false
                }
            }
            Button("Record observation") { record(jpeg) }
                .disabled(loading || failed || (selectedPhoto != nil && jpeg == nil))
                .accessibilityIdentifier("collection.firstAid.observe." + controlId.uuidString.lowercased())
        }
        .onChange(of: selectedPhoto) { _, item in
            jpeg = nil
            loading = item != nil
            failed = false
        }
        .task(id: selectedPhoto) {
            guard let item = selectedPhoto else { return }
            do {
                guard let raw = try await item.loadTransferable(type: Data.self)
                else { throw PhotoInputError.unreadableOrCorruptImage }
                let prepared = try AnalysisPhotoInput().preparePhoto(from: raw).cloudNormalizedJPEG
                guard !Task.isCancelled, item == selectedPhoto else { return }
                jpeg = prepared
            } catch {
                guard !Task.isCancelled, item == selectedPhoto else { return }
                failed = true
            }
            loading = false
        }
    }
}

private extension FirstAidObservationStatus {
    var label: String {
        switch self {
        case .improved: "Improved"
        case .unchanged: "Unchanged"
        case .worse: "Worse"
        case .unknown: "Not sure"
        }
    }
}

private struct WateringDateEdit: Identifiable {
    let id: UUID
    let original: Date
    let timezone: TimeZone

    init?(_ entry: CatalogueCareJournalEntry) {
        guard entry.state == "active", let name = entry.timezone, let zone = TimeZone(identifier: name),
              let occurredAt = SQLTimestamp.date(from: entry.occurredAt) else { return nil }
        id = entry.id
        original = occurredAt
        timezone = zone
    }
}

private struct WateringDateEditor: View {
    let edit: WateringDateEdit
    let save: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(edit: WateringDateEdit, save: @escaping (Date) -> Void) {
        self.edit = edit
        self.save = save
        _date = State(initialValue: edit.original)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = edit.timezone
        return calendar
    }

    private var correctedDate: Date? {
        guard !calendar.isDate(date, inSameDayAs: edit.original) else { return nil }
        let time = calendar.dateComponents([.hour, .minute, .second], from: edit.original)
        guard let hour = time.hour, let minute = time.minute, let second = time.second,
              let corrected = calendar.date(
                bySettingHour: hour, minute: minute, second: second, of: date,
                matchingPolicy: .nextTimePreservingSmallerComponents
              ), calendar.isDate(date, inSameDayAs: corrected), corrected <= Date() else { return nil }
        return corrected
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Watering date", selection: $date, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.calendar, calendar)
                    .environment(\.timeZone, edit.timezone)
                    .accessibilityIdentifier("collection.watering.date")
            }
            .navigationTitle("Correct watering date")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save date") {
                        if let correctedDate { save(correctedDate) }
                    }
                    .disabled(correctedDate == nil)
                    .accessibilityIdentifier("collection.watering.save")
                }
            }
        }
    }
}

struct GuestCatalogueView: View {
    struct SpeciesPicker {
        let taxonId: UUID?
        let slug: String?
        let select: (UUID) -> Void

        func isCurrent(_ card: PublishedSpeciesCard) -> Bool {
            taxonId.map { card.taxonId == $0 } ?? (card.id == slug)
        }
    }

    private struct Search: Equatable {
        let locale: SupportedLocale
        let query: String
        let attempt: Int
    }

    private struct Detail: Equatable {
        let slug: String?
        let taxonId: UUID?
        let locale: SupportedLocale
        let attempt: Int
    }

    let connection: CatalogueConnection
    let polish: Bool
    var speciesPicker: SpeciesPicker? = nil
    var openCollection: ((CatalogueSDKSnapshot) -> Void)? = nil
    let back: () -> Void
    @State private var cards: [PublishedSpeciesCard] = []
    @State private var page: PublishedCataloguePage?
    @State private var selection: String?
    @State private var selectedTaxon: UUID?
    @State private var selectedCard: PublishedSpeciesCard?
    @State private var selectionLocked = false
    @State private var restoredSelection = false
    @State private var query = ""
    @State private var loading = true
    @State private var loadingMore = false
    @State private var searchFailed = false
    @State private var detailFailed = false
    @State private var searchAttempt = 0
    @State private var detailAttempt = 0

    private var locale: SupportedLocale { polish ? .pl : .en }
    private var search: Search {
        Search(locale: locale, query: query.trimmingCharacters(in: .whitespacesAndNewlines), attempt: searchAttempt)
    }
    private var detail: Detail {
        Detail(slug: selection, taxonId: selectedTaxon, locale: locale, attempt: detailAttempt)
    }

    var body: some View {
        VStack {
            if let selection {
                selectedSpecies(selection)
            } else {
                searchResults
            }
            Button(speciesPicker == nil ? (polish ? "Wstecz" : "Back") : "Cancel", action: back)
                .accessibilityIdentifier("catalogue.back")
        }
        .task { if speciesPicker == nil { await restoreSelection() } }
        .task(id: search) { await loadCatalogue(search) }
        .task(id: detail) { await loadSpecies(detail) }
    }

    @ViewBuilder
    private var searchResults: some View {
        TextField(polish ? "Szukaj gatunku" : "Search species", text: $query)
            .textFieldStyle(.roundedBorder).padding(.horizontal)
            .accessibilityIdentifier("catalogue.search")
        if loading {
            ProgressView()
        } else if searchFailed && cards.isEmpty {
            catalogueError { searchAttempt += 1 }
        } else if cards.isEmpty {
            Text(polish ? "Brak wyników." : "No species found.")
                .accessibilityIdentifier("catalogue.empty")
        } else {
            List {
                ForEach(cards) { card in
                    Button {
                        restoredSelection = false
                        selectedCard = nil
                        selectedTaxon = card.taxonId
                        selection = card.id
                    } label: {
                        VStack(alignment: .leading) {
                            Text(card.displayName)
                            Text(card.scientificName).font(.caption)
                        }
                    }
                    .accessibilityIdentifier("catalogue.species." + card.id)
                    .disabled(speciesPicker?.isCurrent(card) == true)
                }
                if searchFailed {
                    catalogueError { Task { await loadMore() } }
                } else if let page, cards.count < page.total {
                    Button(polish ? "Załaduj więcej" : "Load more") { Task { await loadMore() } }
                        .disabled(loadingMore)
                        .accessibilityIdentifier("catalogue.more")
                }
            }
        }
    }

    @ViewBuilder
    private func selectedSpecies(_ slug: String) -> some View {
        if let speciesPicker, let card = selectedCard, card.id == slug {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(card.displayName).font(.title)
                    Text(card.scientificName).font(.subheadline)
                    speciesDetails(card)
                    Button("Confirm species change") { speciesPicker.select(card.taxonId) }
                        .buttonStyle(.borderedProminent)
                        .disabled(speciesPicker.isCurrent(card))
                        .accessibilityIdentifier("collection.species.confirm")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else if selectedCard?.id == slug || restoredSelection {
            let card = selectedCard
            ScrollView {
                CatalogueSaveView(
                    connection: connection, speciesSlug: slug,
                    displayName: card?.displayName ?? slug, scientificName: card?.scientificName ?? "",
                    polish: polish, openCollection: openCollection, selectionLocked: $selectionLocked
                ) {
                    if let card { speciesDetails(card) }
                }
                .id(slug)
                .padding()
            }
        } else if detailFailed {
            catalogueError { detailAttempt += 1 }
        } else {
            ProgressView()
        }
        Button(polish ? "Wybierz inny gatunek" : "Choose another species") { beginNewPlantIntent() }
            .disabled(selectionLocked)
            .accessibilityIdentifier("catalogue.change")
    }

    private func catalogueError(retry: @escaping () -> Void) -> some View {
        VStack {
            Text(polish ? "Nie udało się pobrać katalogu." : "Couldn’t load the catalogue.")
                .accessibilityIdentifier("catalogue.error")
            Button(polish ? "Spróbuj ponownie" : "Try again", action: retry)
                .accessibilityIdentifier("catalogue.retry")
        }
    }

    @ViewBuilder
    private func speciesDetails(_ card: PublishedSpeciesCard) -> some View {
        if let photo = card.heroImage, let url = safeWebURL(photo.downloadURL) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: { Color.clear }
            .frame(maxHeight: 240)
            let credit = [photo.author ?? photo.attribution, photo.license].compactMap { $0 }.joined(separator: " · ")
            if !credit.isEmpty {
                if let source = safeWebURL(photo.sourcePage) {
                    Link(credit, destination: source).font(.caption)
                        .accessibilityIdentifier("catalogue.species.photo.credit")
                } else {
                    Text(credit).font(.caption)
                        .accessibilityIdentifier("catalogue.species.photo.credit")
                }
            }
        }
        if let description = card.description {
            Text(description.text)
            if let source = safeWebURL(description.sourceURL) {
                Link(description.attribution ?? (polish ? "Źródło" : "Source"), destination: source)
                    .font(.caption)
            }
        }
    }

    private func safeWebURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    @MainActor
    private func beginNewPlantIntent() {
        guard !selectionLocked else { return }
        do {
            if speciesPicker == nil, let expected = connection.snapshot,
               let flow = try connection.resumableFlow(expected: expected) {
                guard try connection.forgetResumableFlow(
                    ownerId: expected.session.userId, expectedFlowId: flow, expected: expected
                ) else { throw CatalogueSaveUnavailable.sessionChanged }
            }
            restoredSelection = false
            selection = nil
            selectedTaxon = nil
            selectedCard = nil
        } catch {
            detailFailed = true
        }
    }

    @MainActor
    private func restoreSelection() async {
        do {
            _ = try await connection.sessionOwner()
            let expected = try await connection.sessionSnapshot()
            guard let flow = try connection.resumableFlow(expected: expected) else { return }
            let outcome = await connection.restoreModel(
                ownerId: expected.session.userId, flowId: flow, expected: expected
            )
            guard connection.snapshot == expected, !Task.isCancelled, selection == nil,
                  case let .restored(model) = outcome, let slug = model.input?.speciesSlug else { return }
            restoredSelection = true
            selection = slug
        } catch {
            // Public search is independent of authentication and local restoration.
        }
    }

    @MainActor
    private func loadCatalogue(_ requested: Search) async {
        guard !Task.isCancelled, search == requested else { return }
        loading = true
        loadingMore = false
        searchFailed = false
        cards = []
        page = nil
        do {
            if !requested.query.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            guard let api = connection.apiClient else { throw NativeAuthFailure.configurationMissing }
            if speciesPicker == nil { try await connection.updateClientLocale(requested.locale.rawValue) }
            let first = try await api.searchPublishedCatalogue(
                query: requested.query, locale: requested.locale, limit: 50, offset: 0
            )
            guard !Task.isCancelled, search == requested else { return }
            cards = first.items
            page = first
        } catch {
            guard !Task.isCancelled, search == requested else { return }
            searchFailed = true
        }
        loading = false
    }

    @MainActor
    private func loadMore() async {
        guard !loadingMore, let page, cards.count < page.total, let api = connection.apiClient else { return }
        let requested = search
        let offset = cards.count
        loadingMore = true
        searchFailed = false
        defer { if search == requested { loadingMore = false } }
        do {
            let next = try await api.searchPublishedCatalogue(
                query: requested.query, locale: requested.locale, limit: page.limit, offset: offset
            )
            guard !Task.isCancelled, search == requested else { return }
            guard next.releaseVersion == page.releaseVersion, next.kbReleaseId == page.kbReleaseId,
                  next.total == page.total,
                  Set(cards.map(\.id)).isDisjoint(with: next.items.map(\.id)) else {
                await loadCatalogue(requested)
                return
            }
            cards.append(contentsOf: next.items)
        } catch {
            guard !Task.isCancelled, search == requested else { return }
            searchFailed = true
        }
    }

    @MainActor
    private func loadSpecies(_ requested: Detail) async {
        guard let slug = requested.slug, !Task.isCancelled, detail == requested else { return }
        detailFailed = false
        do {
            guard let api = connection.apiClient else { throw NativeAuthFailure.configurationMissing }
            let card: PublishedSpeciesCard
            if let taxonId = requested.taxonId {
                card = try await api.fetchPublishedSpecies(taxonId: taxonId, locale: requested.locale)
            } else {
                card = try await api.fetchPublishedSpecies(slug: slug, locale: requested.locale)
            }
            guard card.id == slug else { throw URLError(.cannotParseResponse) }
            guard !Task.isCancelled, detail == requested else { return }
            selectedCard = card
        } catch {
            guard !Task.isCancelled, detail == requested else { return }
            detailFailed = true
        }
    }
}
