#if DEBUG
import Foundation
import Supabase
import SwiftData
import UIKit
import CryptoKit

enum CatalogueUIFixtureScenario: String, Codable, Sendable {
    case free2, paid4, cap3, server409, server503, lostresponse
    case publishedMedia, publishedIdentificationResume
    case photoIdentificationWrong, photoIdentificationUnknown
    case guestProviderCancel, guestProviderSuccess, ackFailure
    case guestProvidersUnavailable, guestProviderFailureRetry
    case firstAidControl, trialReminder, plantDeletion, photoHistory, analysisHistory, plantRename, plantRenameRejected
    case plantLightEdit, plantDrainageEdit, plantWateringEdit, plantPotTypeEdit, plantTaxonEdit, careRecommendationRefresh, basicCareEnable

    case careRecommendationRefreshRejected, routineSoilCheck, routineSoilCheckUndo, routineKnownExpiry, routineLateEntitlement
    case routinePendingPolish
    case profileReminderHour, accountSignOut
    case collectionWateringRecord, collectionWateringRecordRejected, collectionWateringMissingConditions, collectionWateringBackgroundFailure

    case todayMixed, todayFuture, todayNoSchedule, todayEmpty, todayFirstFailure, todaySaved, todaySDKOpening

    case directEntryDiagnosisExhausted, directEntryIdentificationExhausted

    var testsDirectEntry: Bool {
        self == .directEntryDiagnosisExhausted || self == .directEntryIdentificationExhausted
    }

    var testsPhotoIdentification: Bool {
        self == .photoIdentificationWrong || self == .photoIdentificationUnknown
    }

    var usesPublishedCatalogue: Bool {
        self == .publishedMedia || self == .publishedIdentificationResume || testsPhotoIdentification
    }

    var testsToday: Bool {
        if testsDirectEntry || testsPhotoIdentification { return true }
        return switch self {
        case .todayMixed, .todayFuture, .todayNoSchedule, .todayEmpty, .todayFirstFailure, .todaySaved, .todaySDKOpening: true
        default: false
        }
    }

    var testsSavedWatering: Bool { self == .collectionWateringRecord || self == .collectionWateringRecordRejected || self == .collectionWateringMissingConditions || self == .collectionWateringBackgroundFailure }

    var testsCareLifecycle: Bool {
        testsToday || testsSavedWatering || self == .profileReminderHour || self == .basicCareEnable
            || self == .careRecommendationRefresh || self == .careRecommendationRefreshRejected
            || testsRoutine || self == .firstAidControl || self == .plantWateringEdit
    }

    var testsRoutine: Bool { self == .routineSoilCheck || self == .routineSoilCheckUndo || self == .routineKnownExpiry || self == .routineLateEntitlement || self == .routinePendingPolish }

    var testsConditionEdit: Bool { self == .plantLightEdit || self == .plantDrainageEdit || self == .plantWateringEdit || self == .plantPotTypeEdit }
    var changesCareContext: Bool { testsConditionEdit || self == .plantTaxonEdit }
    var testsPlantEdit: Bool { self == .plantRename || self == .plantRenameRejected || changesCareContext }

    var startsAnonymous: Bool {
        testsPhotoIdentification || self == .guestProviderCancel || self == .guestProviderSuccess
            || self == .guestProvidersUnavailable || self == .guestProviderFailureRetry
    }
    var initialCount: Int {
        if self == .todayEmpty { return 0 }
        if self == .todayMixed || self == .todayFuture { return 3 }
        return self == .paid4 ? 4 : (self == .cap3 ? 3 : 2)
    }
}

enum CatalogueUIFixtureError: Error {
    case invalidNamespace, scenarioMismatch, namespaceInUse, invalidRequest, invalidStorage
}

/// Only this explicit entry point creates fixture resources. There is no launch wiring.
@MainActor
enum CatalogueUIFixtures {
    static func directory(namespace: String) throws -> URL {
        guard let id = UUID(uuidString: namespace),
              id.uuidString.lowercased() == namespace.lowercased() else {
            throw CatalogueUIFixtureError.invalidNamespace
        }
        return try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("NaratCatalogueUIFixtures", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    static func make(
        namespace: String, scenario: CatalogueUIFixtureScenario,
        reminderConfiguration: ReminderConsentLaunch.Configuration? = nil,
        reminderPreparation: ((CatalogueFixtureServer, URL) throws -> Void)? = nil,
        initialDate: Date = Date(), initialTimeZone: TimeZone = .current
    ) async throws -> CatalogueUIFixtureContext {
        if let reminderConfiguration {
            guard reminderConfiguration.namespace.uuidString.lowercased() == namespace.lowercased(),
                  scenario == .todayFuture else { throw CatalogueUIFixtureError.scenarioMismatch }
        }
        guard (reminderConfiguration != nil) == (reminderPreparation != nil)
        else { throw CatalogueUIFixtureError.invalidRequest }
        let reminderMode = reminderConfiguration?.mode.rawValue
        let directory = try directory(namespace: namespace)
        let name = UUID(uuidString: namespace)!.uuidString.lowercased()
        guard !CatalogueFixtureProtocol.registry.contains(name) else {
            throw CatalogueUIFixtureError.namespaceInUse
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let server = try CatalogueFixtureServer(directory: directory, namespace: name, scenario: scenario,
                                                reminderMode: reminderMode, initialDate: initialDate,
                                                initialTimeZone: initialTimeZone)
        try reminderPreparation?(server, directory) // Validate fake disk state BEFORE SDK construction.
        let schema = Schema([
            LocalOutboxRecord.self, CatalogueCreateConfirmationRecord.self,
            CatalogueInputCheckpointRecord.self, GuestDraftCacheRecord.self,
            SyncedEntityRecord.self, SyncCheckpointRecord.self
        ])
        let database = directory.appendingPathComponent("catalogue.sqlite")
        let preparePublishedResume = scenario == .publishedIdentificationResume
            && !FileManager.default.fileExists(atPath: database.path)
        let prepareACK = scenario == .ackFailure && !FileManager.default.fileExists(atPath: database.path)
        let prepareWateringCache = scenario.testsSavedWatering && !FileManager.default.fileExists(atPath: database.path)
        func container(allowsSave: Bool) throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: database, allowsSave: allowsSave)
            ])
        }
        // Recovery follows persisted real command attempts, never process launch counts.
        let allowsSave = scenario != .ackFailure || prepareACK || server.snapshot.attempts.count >= 2
        let storage = try container(allowsSave: allowsSave)
        let suite = "NaratCatalogueUIFixture." + name
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CatalogueUIFixtureError.invalidStorage
        }
        var authValues = [
            "NaratSupabaseURL": "https://" + name + ".invalid",
            "NaratSupabasePublishableKey": "fixture-only-public-key"
        ]
        let configuration: NativeAuthConfiguration
        if scenario.startsAnonymous {
            // Validate real synthetic Bundle metadata; never override production availability.
            let bundleURL = directory.appendingPathComponent("NativeProviders.bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            var metadata: [String: Any] = ["CFBundleIdentifier": "app.narat.fixture." + name]
            if scenario != .guestProvidersUnavailable {
                let clientID = "fixture-" + name + ".apps.googleusercontent.com"
                authValues["GIDClientID"] = clientID
                metadata["CFBundleURLTypes"] = [["CFBundleURLSchemes": [
                    clientID.split(separator: ".").reversed().joined(separator: ".")
                ]]]
            } else {
                authValues["NaratAppleSignInEnabled"] = "NO"
            }
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: bundleURL.appendingPathComponent("Info.plist"), options: .atomic)
            guard let bundle = Bundle(url: bundleURL) else { throw CatalogueUIFixtureError.invalidStorage }
            configuration = try NativeAuthConfiguration(values: authValues, bundle: bundle)
        } else {
            configuration = try NativeAuthConfiguration(values: authValues)
        }
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [CatalogueFixtureProtocol.self]
        options.httpAdditionalHeaders = ["X-Catalogue-Fixture-Namespace": name]
        options.urlCache = nil
        options.httpCookieStorage = nil
        let http = URLSession(configuration: options)
        try CatalogueFixtureProtocol.registry.insert(server, name: name)
        let authStorage = CatalogueFixtureAuthStorage(directory: directory, server: server)
        let client = SupabaseClient(
            supabaseURL: configuration.supabaseURL,
            supabaseKey: configuration.supabasePublishableKey,
            options: .init(
                auth: .init(
                    storage: authStorage,
                    storageKey: "catalogue-fixture-session", autoRefreshToken: false,
                    emitLocalSessionAsInitialSession: true
                ),
                global: .init(session: http)
            )
        )
        let identity = CatalogueFixtureIdentity(cancel: scenario == .guestProviderCancel)
        identity.beforeCredentials = { try server.recordProviderAttempt() }
        func connect(_ storage: ModelContainer) -> CatalogueConnection {
            CatalogueConnection(
                client: client, configuration: configuration,
                store: LocalStore(modelContainer: storage),
                transport: URLSessionAPITransport(session: http),
                identityProvider: identity, resumeDefaults: defaults
            )
        }
        let connection = connect(storage)
        if scenario == .routineKnownExpiry {
            // One deterministic second, persisted independently of process launches.
            let start = SQLTimestamp.date(from: "2099-01-01T00:00:00Z")!
            let key = "routine.fixture.clock"
            connection.routineFixtureNow = defaults.object(forKey: key) == nil
                ? start : Date(timeIntervalSince1970: defaults.double(forKey: key))
            connection.advanceRoutineFixtureClock = { [weak connection] in
                guard let connection, let now = connection.routineFixtureNow else { return }
                let advanced = now.addingTimeInterval(1)
                defaults.set(advanced.timeIntervalSince1970, forKey: key)
                connection.routineFixtureNow = advanced
            }
        }
        if scenario == .careRecommendationRefresh {
            connection.withdrawCareSourceFixture = { [weak connection] in
                guard let connection, let reconnect = connection.reconcileFixtureReconnect
                else { throw CatalogueUIFixtureError.invalidRequest }
                try server.withdrawCareSource()
                reconnect()
            }
        }
        let context = CatalogueUIFixtureContext(
            namespace: name, directory: directory, suite: suite, connection: connection,
            http: http, server: server, identity: identity, openingAuthStorage: authStorage
        )
        do {
            // Reuse the SDK's file-backed session; never manufacture a model session.
            if client.auth.currentSession == nil && !scenario.startsAnonymous
                && !(scenario == .accountSignOut && defaults.bool(forKey: "catalogue.explicitSignOut")) {
                _ = try await client.auth.signIn(
                    email: "fixture@" + name + ".invalid", password: "fixture-only-password"
                )
            }
            if scenario != .accountSignOut || client.auth.currentSession != nil {
                _ = try await connection.sessionOwner()
            }
            if prepareWateringCache {
                let expected = try await connection.sessionSnapshot()
                guard let sync = connection.syncEngine else { throw CatalogueUIFixtureError.invalidStorage }
                _ = try await sync.pullDelta(for: expected.session.userId)
            }
            if prepareACK {
                // Prepare exactly once through accepted APIs, with no command HTTP or
                // manufactured model phase. Reopening must replay this same disk intent.
                let expected = try await connection.sessionSnapshot()
                let pending = try await connection.makeModel(
                    input: CatalogueInput(speciesSlug: "fixture_fern", personalName: "Luna"),
                    flowId: UUID(), operationId: UUID(), expected: expected
                )
                guard let api = connection.apiClient, let store = connection.store else {
                    throw CatalogueUIFixtureError.invalidStorage
                }
                let lease = try await api.captureSyncContext(ownerId: expected.session.userId)
                let checkpoint = try await connection.rememberModel(pending, expected: expected)
                _ = try await store.catalogueCreateJournal(
                    checkpoint.envelope, mode: .enqueue(canCreate: true),
                    context: lease, authority: api.syncAuthority
                )
                // The connection handed to Root owns a genuinely read-only SQLite store.
                context.connection = connect(try container(allowsSave: false))
                _ = try await context.connection.sessionOwner()
            }
            if scenario.usesPublishedCatalogue {
                try await context.preparePublishedFixture(isNewResume: preparePublishedResume)
            }
            return context
        } catch {
            context.shutdown()
            throw error
        }
    }
}

@MainActor
final class CatalogueUIFixtureContext {
    let namespace: String
    let directory: URL
    private let suite: String
    fileprivate(set) var connection: CatalogueConnection!
    let http: URLSession
    let server: CatalogueFixtureServer
    let identity: CatalogueFixtureIdentity
    private let openingAuthStorage: CatalogueFixtureAuthStorage
    private var mediaProtocol: CatalogueScopedMediaProtocol.Type?
    private(set) var mediaHTTP: URLSession?
    private var openingReady = false
    private var openingExpiryArmed = false

    var testsDirectEntry: Bool { server.snapshot.scenario.testsDirectEntry }

    func verifyDirectEntry() throws { try server.verifyDirectEntry() }

    var testsSDKOpening: Bool { server.snapshot.scenario == .todaySDKOpening }

    func openingPreparationSettled(connection: CatalogueConnection) throws {
        guard testsSDKOpening else { return }
        guard self.connection === connection else { throw CatalogueUIFixtureError.invalidRequest }
        guard !openingReady else { return }
        try server.recordOpening("ready")
        openingReady = true
    }

    func armOpeningExpiry(connection: CatalogueConnection?) throws {
        guard testsSDKOpening, openingReady, !openingExpiryArmed,
              let connection, self.connection === connection,
              let snapshot = connection.snapshot, !snapshot.isAnonymous,
              snapshot.session.userId == server.snapshot.permanent else {
            throw CatalogueUIFixtureError.invalidRequest
        }
        try server.recordOpening("expiry-armed")
        openingExpiryArmed = true
    }

    func beginOpening(
        _ request: CollectionOpeningCoordinator.Request, connection: CatalogueConnection
    ) throws {
        guard testsSDKOpening else { return }
        guard openingReady, self.connection === connection,
              request.connection == ObjectIdentifier(connection) else {
            throw CatalogueUIFixtureError.invalidRequest
        }
        let owner = connection.snapshot?.session.userId
        try server.recordOpening("read-start", requestId: request.id, ownerId: owner)
        guard openingExpiryArmed else { return }
        guard let owner, owner == server.snapshot.permanent,
              connection.collectionOpeningLocalReadFixture == nil else {
            throw CatalogueUIFixtureError.invalidRequest
        }
        openingExpiryArmed = false
        connection.collectionOpeningLocalReadFixture = { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection else {
                throw CatalogueUIFixtureError.invalidRequest
            }
            try self.openingAuthStorage.expireOpeningSession(owner: owner)
            guard let injected = connection.client?.auth.currentSession,
                  injected.user.id == owner, injected.isExpired else {
                throw CatalogueUIFixtureError.invalidStorage
            }
            try self.server.recordOpening(
                "expiry-consumed", requestId: request.id, ownerId: injected.user.id,
                expired: injected.isExpired)
        }
    }

    func finishOpening(
        _ outcome: CatalogueCollectionOpeningOutcome,
        request: CollectionOpeningCoordinator.Request, connection: CatalogueConnection
    ) throws {
        guard testsSDKOpening else { return }
        guard self.connection === connection, request.connection == ObjectIdentifier(connection) else {
            throw CatalogueUIFixtureError.invalidRequest
        }
        switch outcome {
        case .permanent(let snapshot):
            guard connection.snapshot == snapshot, !snapshot.isAnonymous,
                  snapshot.session.userId == server.snapshot.permanent else {
                throw CatalogueUIFixtureError.invalidRequest
            }
            try server.recordOpening("read-permanent", requestId: request.id,
                                     ownerId: snapshot.session.userId)
        case .loginRequired:
            try server.recordOpening("read-login", requestId: request.id)
        case .temporarilyUnavailable, .superseded:
            break
        }
    }

    fileprivate init(
        namespace: String, directory: URL, suite: String, connection: CatalogueConnection,
        http: URLSession, server: CatalogueFixtureServer, identity: CatalogueFixtureIdentity,
        openingAuthStorage: CatalogueFixtureAuthStorage
    ) {
        self.namespace = namespace; self.directory = directory; self.suite = suite
        self.connection = connection; self.http = http; self.server = server; self.identity = identity
        self.openingAuthStorage = openingAuthStorage
    }

    var supportsCareReconnect: Bool {
        server.snapshot.scenario.testsSavedWatering && server.snapshot.scenario != .collectionWateringRecordRejected
    }

    /// Explicit fixture transport availability; Root receives the same reconnect trigger as production.
    func reconnectCare() throws {
        guard supportsCareReconnect, let reconnect = connection.reconcileFixtureReconnect
        else { throw CatalogueUIFixtureError.invalidRequest }
        try server.resumeCareNetwork()
        reconnect()
    }

    var testsToday: Bool { server.snapshot.scenario.testsToday }

    func changeTodayPhase(_ phase: CatalogueFixtureServer.TodayPhase) throws {
        guard phase != .normal else { throw CatalogueUIFixtureError.invalidRequest }
        try server.setTodayPhase(phase)
    }

    func resumeToday() throws {
        guard testsToday, let reconnect = connection.reconcileFixtureReconnect
        else { throw CatalogueUIFixtureError.invalidRequest }
        try server.setTodayPhase(.normal)
        reconnect()
    }

    /// Releases the connection without erasing SDK state, SQLite, receipts or scenario flags.
    func shutdown() {
        server.cancelPhotoValidation()
        if let mediaProtocol {
            mediaHTTP?.invalidateAndCancel()
            CatalogueScopedMediaProtocol.release(mediaProtocol, server: server)
            self.mediaProtocol = nil
            mediaHTTP = nil
        }
        connection = nil
        http.invalidateAndCancel()
        CatalogueFixtureProtocol.registry.remove(server, name: namespace)
    }

    /// Explicit destructive teardown for tests, separate from restart.
    func cleanup() throws {
        shutdown()
        guard !CatalogueFixtureProtocol.registry.contains(namespace) else {
            throw CatalogueUIFixtureError.namespaceInUse
        }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

@MainActor
final class CatalogueFixtureIdentity: NativeIdentityProviding {
    let cancel: Bool
    var beforeCredentials: (() async throws -> Void)?
    private(set) var calls = 0
    init(cancel: Bool) { self.cancel = cancel }
    func credentials(for provider: NativeAuthProvider, presenting: UIViewController) async throws -> NativeAuthCredentials {
        calls += 1
        try await beforeCredentials?()
        if cancel { throw CancellationError() }
        return NativeAuthCredentials(
            provider: provider, idToken: "fixture-only-identity", nonce: "fixture-only-nonce"
        )
    }
}

/// SDK storage is deliberately outside keychain, app defaults and the production store.
private final class CatalogueFixtureAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL
    private let server: CatalogueFixtureServer
    init(directory: URL, server: CatalogueFixtureServer) {
        file = directory.appendingPathComponent("fixture-sdk-session.json")
        self.server = server
    }
    private func validate(_ key: String, _ data: Data) throws {
        guard key == "catalogue-fixture-session",
              let session = try? JSONDecoder().decode(Session.self, from: data),
              server.isFixtureSession(session) else { throw CatalogueUIFixtureError.invalidStorage }
    }
    func store(key: String, value: Data) throws {
        try lock.withLock {
            try validate(key, value)
            try value.write(to: file, options: .atomic)
        }
    }
    func retrieve(key: String) throws -> Data? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let value = try Data(contentsOf: file)
            try validate(key, value)
            return value
        }
    }
    /// Mutates only expiry in this isolated injected SDK's file-backed session.
    func expireOpeningSession(owner: UUID) throws {
        try lock.withLock {
            guard server.snapshot.scenario == .todaySDKOpening else {
                throw CatalogueUIFixtureError.invalidRequest
            }
            let value = try Data(contentsOf: file)
            try validate("catalogue-fixture-session", value)
            var session = try JSONDecoder().decode(Session.self, from: value)
            guard session.user.id == owner, !session.isExpired else {
                throw CatalogueUIFixtureError.invalidStorage
            }
            session.expiresAt = Date().addingTimeInterval(-60).timeIntervalSince1970
            try JSONEncoder().encode(session).write(to: file, options: .atomic)
        }
    }

    func remove(key: String) throws {
        try lock.withLock {
            guard key == "catalogue-fixture-session" else { throw CatalogueUIFixtureError.invalidStorage }
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}

/// One ledger transaction contains inventory, exact request identity, receipt and loss flag.
final class CatalogueFixtureServer: @unchecked Sendable {
    struct Plant: Codable, Sendable {
        let owner: UUID
        let id: UUID
        let species: String
        let name: String?
        let timestamp: String
    }
    struct Commit: Codable, Sendable {
        let owner: UUID
        let envelope: CommandEnvelopeDTO
        let body: Data
        let receipt: Data
        let plantID: UUID
    }
    struct Attempt: Codable, Sendable {
        let owner: UUID
        let body: Data
    }
    enum TodayPhase: String, Codable, Sendable { case normal, failOverview, offline, withdrawn }

    struct OpeningProof: Codable, Sendable {
        let version: Int
        var events: [OpeningEvent]
    }
    struct OpeningEvent: Codable, Sendable {
        let ordinal: Int
        let name: String
        let requestId: UUID?
        let ownerId: UUID?
        let expired: Bool?
    }

    struct AuthProof: Codable, Sendable {
        var version = 1
        var providerAttempts = 0
        var providerFailures = 0
        var authIdTokenRequests = 0
        var passwordRequests = 0
        var emailRegistrationRequests = 0
    }

    struct Ledger: Codable, Sendable {
        let scenario: CatalogueUIFixtureScenario
        let guest: UUID
        let permanent: UUID
        var plants: [Plant]
        var commits: [String: Commit] = [:]
        var attempts: [Attempt] = []
        var lostResponseCommitted = false
        var signupCount = 0
        var tick = 0
        var revoked: Set<UUID> = []
        var routineEntitlementDeadline: Date?
        var routineEntitlementState: String?
        var wateringCachePrimed: Bool?
        var wateringNetworkResumed: Bool?
        var careSourceWithdrawn: Bool?
        var careSourceEmptyWindowProved: Bool?
        var backgroundWateringRejected: Bool?
        var todayAnchorDay: String?
        var todayClockSeed: String?
        var todayTransport: TodayPhase?
        var todayWithdrawn: Bool?
        var overviewRequests: Int?
        var reminderMode: String?
        var reminderCommandRequests: Int?
        var reminderAuthRequests: Int?
        var reminderReadRequests: Int?
        var reminderScheduleRestored: Bool?
        var openingProof: OpeningProof?
        var authProof: AuthProof?
        var directEntryAccessReads: Int?
        var directEntryDeniedRequests: Int?
        var photo: CataloguePhotoFixtureState? = nil
    }
    struct Reply: Sendable {
        let status: Int
        let data: Data
        var contentType = "application/json"
    }
    private let lock = NSLock()
    private let file: URL
    let namespace: String
    private var ledger: Ledger
    private var canonicalProfileHour: Int {
        (ledger.scenario == .profileReminderHour || ledger.reminderMode == ReminderConsentFixtureMode.hour.rawValue)
            && ledger.tick > 0 ? 23 : 9
    }
    var snapshot: Ledger { lock.withLock { ledger } }

    /// Actual fake identity entry only; availability and read predicates have no side effects.
    func recordProviderAttempt() throws {
        let outcome = try lock.withLock {
            var next = ledger
            var proof = next.authProof ?? AuthProof()
            guard proof.version == 1 else { throw CatalogueUIFixtureError.invalidStorage }
            proof.providerAttempts += 1
            let photo = next.scenario.testsPhotoIdentification
            let cancel = photo && proof.providerAttempts == 1
            let fail = (next.scenario == .guestProviderFailureRetry && proof.providerAttempts == 1)
                || (photo && proof.providerAttempts == 2)
            if fail { proof.providerFailures += 1 }
            next.authProof = proof
            try persist(next)
            return (cancel, fail)
        }
        if outcome.0 { throw CancellationError() }
        if outcome.1 { throw NativeAuthFailure.providerFailed }
    }

    func verifyDirectEntry() throws {
        try lock.withLock {
            guard ledger.scenario.testsDirectEntry, ledger.signupCount == 0,
                  ledger.attempts.isEmpty, ledger.commits.isEmpty,
                  (ledger.directEntryAccessReads ?? 0) >= 2,
                  (ledger.directEntryDeniedRequests ?? 0) == 0,
                  capturedRequests.filter({ $0.httpMethod == "POST" }).count == 1,
                  capturedRequests.filter({ $0.httpMethod == "POST" }).allSatisfy({
                      $0.url?.path == "/auth/v1/token"
                          && $0.url?.query == "grant_type=password"
                  }) else { throw CatalogueUIFixtureError.invalidRequest }
        }
    }
    private var photoValidation: CataloguePhotoValidationToken?
    private var capturedRequests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { capturedRequests } }

    fileprivate init(directory: URL, namespace: String, scenario: CatalogueUIFixtureScenario,
                     reminderMode: String? = nil, initialDate: Date = Date(),
                     initialTimeZone: TimeZone = .current) throws {
        self.namespace = namespace
        file = directory.appendingPathComponent("server-ledger.json")
        if FileManager.default.fileExists(atPath: file.path) {
            ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: file))
            guard ledger.authProof == nil || ledger.authProof?.version == 1,
                  ledger.scenario == scenario, ledger.reminderMode == reminderMode
            else { throw CatalogueUIFixtureError.scenarioMismatch }
        } else {
            let owner = UUID()
            ledger = Ledger(scenario: scenario, guest: UUID(), permanent: owner, plants: [])
            ledger.authProof = AuthProof()
            ledger.reminderMode = reminderMode
            if reminderMode != nil {
                ledger.reminderCommandRequests = 0; ledger.reminderAuthRequests = 0
                ledger.reminderReadRequests = 0; ledger.reminderScheduleRestored = false
            }
            if scenario.testsToday {
                let now = initialDate
                ledger.todayClockSeed = ISO8601DateFormatter().string(from: now)
                let day = ISO8601DateFormatter()
                day.formatOptions = [.withFullDate]
                // Ordinary Today uses the local day; consent runs on its fake UTC clock.
                day.timeZone = reminderMode == nil ? initialTimeZone : TimeZone(secondsFromGMT: 0)!
                ledger.todayAnchorDay = day.string(from: now)
                ledger.todayTransport = scenario == .todayFirstFailure ? .failOverview : .normal
                ledger.todayWithdrawn = reminderMode == ReminderConsentFixtureMode.noSchedule.rawValue
                ledger.overviewRequests = 0
            }
            ledger.plants = (0..<scenario.initialCount).map { index in
                Plant(owner: owner, id: UUID(), species: "fixture_fern", name: "Fixture \(index + 1)",
                      timestamp: Self.time(reminderMode == ReminderConsentFixtureMode.routing.rawValue ? index - 2 : 0))
            }
            try JSONEncoder().encode(ledger).write(to: file, options: .atomic)
        }
    }
    /// Explicit DEBUG actions only. Withdrawal itself never requests HTTP.
    func setTodayPhase(_ phase: TodayPhase) throws {
        try lock.withLock {
            guard ledger.scenario.testsToday else { throw CatalogueUIFixtureError.invalidRequest }
            var next = ledger
            if phase == .withdrawn {
                next.todayWithdrawn = true
            } else {
                next.todayTransport = phase
                if phase == .normal {
                    next.todayWithdrawn = false
                    if next.reminderMode == ReminderConsentFixtureMode.noSchedule.rawValue {
                        next.reminderScheduleRestored = true
                    }
                }
            }
            try persist(next)
        }
    }

    /// Change server authority only; clients must receive this via SDK sync.
    func setRoutineEntitlement(deadline: Date, state: String = "active") throws {
        try lock.withLock {
            guard ledger.scenario == .routineLateEntitlement else {
                throw CatalogueUIFixtureError.invalidRequest
            }
            var next = ledger
            next.tick += 1
            next.routineEntitlementDeadline = deadline
            next.routineEntitlementState = state
            try persist(next)
        }
    }

    private static func time(_ tick: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: 1_793_491_200 + Double(tick))) + ".123456Z"
    }
    private func persist(_ next: Ledger) throws {
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        ledger = next
    }
    func recordOpening(
        _ name: String, requestId: UUID? = nil, ownerId: UUID? = nil, expired: Bool? = nil
    ) throws {
        try lock.withLock {
            try recordOpeningLocked(name, requestId: requestId, ownerId: ownerId, expired: expired)
        }
    }

    /// Caller already owns the server lock; no await and no SDK/HTTP reads.
    private func recordOpeningLocked(
        _ name: String, requestId: UUID? = nil, ownerId: UUID? = nil, expired: Bool? = nil
    ) throws {
        guard ledger.scenario == .todaySDKOpening else { return }
        var next = ledger
        var proof = next.openingProof ?? OpeningProof(version: 1, events: [])
        proof.events.append(OpeningEvent(ordinal: proof.events.count, name: name,
                                        requestId: requestId, ownerId: ownerId, expired: expired))
        next.openingProof = proof
        try persist(next)
    }

    func withdrawCareSource() throws {
        try lock.withLock {
            guard ledger.scenario == .careRecommendationRefresh else { throw CatalogueUIFixtureError.invalidRequest }
            var next = ledger
            next.careSourceWithdrawn = true
            next.careSourceEmptyWindowProved = false
            // No owner revision/tick change: this models a remote publication withdrawal.
            try persist(next)
        }
    }

    func resumeCareNetwork() throws {
        try lock.withLock {
            guard ledger.scenario.testsSavedWatering else { throw CatalogueUIFixtureError.invalidRequest }
            var next = ledger
            next.wateringNetworkResumed = true
            try persist(next)
        }
    }

    private func token(_ owner: UUID) -> String {
        guard ledger.scenario.testsCareLifecycle else {
            return "fixture-only-" + namespace + "-" + owner.uuidString.lowercased()
        }
        // Exercise the production permanent-owner claim gate through the SDK bearer.
        // This DEBUG-only token is accepted solely by this namespace's fixture server.
        func base64URL(_ value: String) -> String {
            Data(value.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = base64URL(#"{"alg":"HS256","typ":"JWT"}"#)
        let claims = base64URL(
            "{\"sub\":\"\(owner.uuidString.lowercased())\",\"is_anonymous\":\(owner == ledger.guest),"
                + "\"fixture_namespace\":\"\(namespace)\"}"
        )
        return header + "." + claims + ".fixture-only-signature"
    }
    func isFixtureSession(_ session: Session) -> Bool {
        lock.withLock {
            [ledger.guest, ledger.permanent].contains(session.user.id) &&
            session.user.isAnonymous == (session.user.id == ledger.guest) &&
            session.accessToken == token(session.user.id) &&
            session.refreshToken == "refresh-" + token(session.user.id)
        }
    }
    private func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private func user(_ owner: UUID) -> [String: Any] {
        ["id": owner.uuidString, "aud": "authenticated", "role": "authenticated",
         "app_metadata": [:], "user_metadata": [:], "is_anonymous": owner == ledger.guest,
         "created_at": Self.time(0), "updated_at": Self.time(ledger.tick)]
    }
    private func session(_ owner: UUID) throws -> Reply {
        Reply(status: 200, data: try json([
            "access_token": token(owner), "token_type": "bearer", "expires_in": 3600,
            "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "refresh_token": "refresh-" + token(owner), "user": user(owner)
        ]))
    }
    private func error(_ status: Int, _ code: String, retryable: Bool = false) throws -> Reply {
        Reply(status: status, data: try json([
            "error": ["code": code, "message": "Fixture request rejected", "retryable": retryable]
        ]))
    }
    private func owner(_ request: URLRequest) throws -> UUID {
        guard let owner = [ledger.guest, ledger.permanent].first(where: {
            request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token($0)
        }), !ledger.revoked.contains(owner) else { throw CatalogueUIFixtureError.invalidRequest }
        return owner
    }

    private static let fernTaxon = "32e72c49-4e06-434a-86dd-bbf8a5cb209e"
    private static let palmTaxon = "42e72c49-4e06-434a-86dd-bbf8a5cb209e"
    private static let historyObservationIDs = [
        UUID(uuidString: "12340000-0000-4000-8000-000000000001")!,
        UUID(uuidString: "12340000-0000-4000-8000-000000000002")!
    ]

    private func photoHistory(for plant: Plant) -> [[String: Any]] {
        Self.historyObservationIDs.enumerated().flatMap { index, id -> [[String: Any]] in
            let observedAt = index == 0 ? "2026-10-29T12:00:00Z" : "2026-10-30T12:00:00Z"
            let status = index == 0 ? "unchanged" : "improved"
            return [
                ["entity_type": "care_observations", "id": id.uuidString, "updated_at": plant.timestamp,
                 "deleted_at": NSNull(), "data": ["id": id.uuidString, "plant_id": plant.id.uuidString,
                    "first_aid_control_id": id.uuidString, "operation_id": id.uuidString,
                    "photo_id": id.uuidString, "status_code": status, "observed_at": observedAt]],
                ["entity_type": "first_aid_followups", "id": id.uuidString, "updated_at": plant.timestamp,
                 "deleted_at": NSNull(), "data": ["id": id.uuidString, "plant_id": plant.id.uuidString,
                    "action_entry_id": id.uuidString, "action_code": "check_soil", "state": "completed"]]
            ]
        }
    }

    fileprivate func handle(_ request: URLRequest) throws -> Reply {
        try lock.withLock {
            guard let url = request.url, url.scheme == "https", url.host == namespace + ".invalid",
                  url.port == nil, url.user == nil, url.password == nil, url.fragment == nil else {
                throw URLError(.unsupportedURL)
            }
            capturedRequests.append(request)
            // Atomic counters at HTTP dispatch, including rejected email signup attempts.
            if request.httpMethod == "POST", url.path.hasPrefix("/auth/v1/") {
                var next = ledger
                var proof = next.authProof ?? AuthProof()
                guard proof.version == 1 else { throw CatalogueUIFixtureError.invalidStorage }
                let grant = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "grant_type" })?.value
                let authBody = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let emailSignup = url.path == "/auth/v1/signup"
                    && (authBody?["email"] != nil || authBody?["password"] != nil)
                if emailSignup { proof.emailRegistrationRequests += 1 }
                if url.path == "/auth/v1/token", grant == "password" { proof.passwordRequests += 1 }
                if url.path == "/auth/v1/token", grant == "id_token" { proof.authIdTokenRequests += 1 }
                next.authProof = proof
                try persist(next)
                if emailSignup { throw CatalogueUIFixtureError.invalidRequest }
            }
            if ledger.scenario.testsDirectEntry, request.httpMethod != "GET" {
                // Only fixture bootstrap may write. Providers, uploads, commands and signup are denied.
                let bootstrap = request.httpMethod == "POST" && url.path == "/auth/v1/token"
                    && url.query == "grant_type=password"
                    && capturedRequests.filter({ $0.httpMethod == "POST" }).count == 1
                if !bootstrap {
                    var next = ledger
                    next.directEntryDeniedRequests = (next.directEntryDeniedRequests ?? 0) + 1
                    try persist(next)
                    return try error(403, "fixture_read_only")
                }
            }
            if ledger.scenario == .todaySDKOpening, url.path.hasSuffix("/commands") {
                try recordOpeningLocked("domain-command")
                return try error(403, "fixture_read_only")
            }
            if ledger.reminderMode != nil {
                var next = ledger
                if url.path.hasSuffix("/commands") {
                    next.reminderCommandRequests = (next.reminderCommandRequests ?? 0) + 1
                } else if url.path.hasPrefix("/auth/") {
                    next.reminderAuthRequests = (next.reminderAuthRequests ?? 0) + 1
                } else {
                    next.reminderReadRequests = (next.reminderReadRequests ?? 0) + 1
                }
                try persist(next)
                if url.path.hasSuffix("/commands") {
                    // The eighth mode opens exactly one typed profile write, never care/plant writes.
                    guard ledger.reminderMode == ReminderConsentFixtureMode.hour.rawValue,
                          request.httpMethod == "POST",
                          url.path == "/functions/v1/plants-api/commands", url.query == nil,
                          request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token(ledger.permanent),
                          !ledger.revoked.contains(ledger.permanent),
                          let body = request.httpBody,
                          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                          Set(object.keys) == Set(["operation_id", "command_name", "payload_json"]),
                          let envelope = try? JSONDecoder().decode(CommandEnvelopeDTO.self, from: body),
                          let command = ProfileReminderHourCommand(envelope),
                          command.reminderHourLocal == 23,
                          request.value(forHTTPHeaderField: "X-Operation-Id") == envelope.operationId.uuidString.lowercased()
                    else { return try error(403, "fixture_read_only") }
                }
            }
            let body = request.httpBody ?? Data()
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let method = request.httpMethod ?? "GET"
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if ledger.scenario.testsDirectEntry, url.path == "/functions/v1/plants-api/analysis/access" {
                guard method == "GET", query.isEmpty, body.isEmpty,
                      request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token(ledger.permanent),
                      request.value(forHTTPHeaderField: "X-Installation-Credential") == nil,
                      let locale = request.value(forHTTPHeaderField: "X-Client-Locale"),
                      ["en", "pl"].contains(locale) else { throw CatalogueUIFixtureError.invalidRequest }
                let exhausted = ledger.scenario == .directEntryDiagnosisExhausted ? "diagnosis" : "identification"
                let null = NSNull()
                let modes = Dictionary(uniqueKeysWithValues: ["diagnosis", "identification"].map { mode in
                    (mode, [
                        "mode": mode, "allowed": mode != exhausted,
                        "activeQuotaKind": "starter_" + mode, "remaining": mode == exhausted ? 0 : 1,
                        "limit": 1, "inProgressJobId": null, "nextResetAt": null,
                        "reason": mode == exhausted ? "starter_exhausted" as Any : null
                    ] as [String: Any])
                })
                var next = ledger
                next.directEntryAccessReads = (next.directEntryAccessReads ?? 0) + 1
                try persist(next)
                return Reply(status: 200, data: try json([
                    "owner_id": ledger.permanent.uuidString, "is_guest": false,
                    "starter": [
                        "identification_remaining": exhausted == "identification" ? 0 : 1,
                        "diagnosis_remaining": exhausted == "diagnosis" ? 0 : 1,
                        "identification_in_progress_job_id": null, "diagnosis_in_progress_job_id": null,
                        "first_starter_success_at": null
                    ],
                    "monthly": [
                        "quota_kind": "free_monthly", "registered_at": null, "period_start": null,
                        "period_end": null, "limit": null, "consumed": null, "reserved": null,
                        "remaining": null, "status": "history_unresolved"
                    ], "modes": modes
                ]))
            }
            if method == "POST", url.path == "/auth/v1/signup", query.isEmpty {
                guard Set(object.keys).isSubset(of: ["data", "gotrue_meta_security"]) else {
                    throw CatalogueUIFixtureError.invalidRequest
                }
                var next = ledger; next.signupCount += 1; next.revoked.remove(next.guest)
                try persist(next)
                return try session(ledger.guest)
            }
            if method == "POST", url.path == "/auth/v1/token", query.count == 1,
               query[0].name == "grant_type" {
                let owner: UUID
                switch query[0].value {
                case "password":
                    guard object["email"] as? String == "fixture@" + namespace + ".invalid",
                          object["password"] as? String == "fixture-only-password" else {
                        throw CatalogueUIFixtureError.invalidRequest
                    }
                    owner = ledger.permanent
                    try recordOpeningLocked("auth-password")
                case "id_token":
                    guard object["id_token"] as? String == "fixture-only-identity",
                          ["apple", "google"].contains(object["provider"] as? String ?? ""),
                          object["nonce"] as? String == "fixture-only-nonce" else {
                        throw CatalogueUIFixtureError.invalidRequest
                    }
                    owner = ledger.permanent
                case "refresh_token":
                    try recordOpeningLocked("auth-refresh-start")
                    guard let match = [ledger.guest, ledger.permanent].first(where: {
                        object["refresh_token"] as? String == "refresh-" + token($0) && !ledger.revoked.contains($0)
                    }) else { throw CatalogueUIFixtureError.invalidRequest }
                    owner = match
                default: throw CatalogueUIFixtureError.invalidRequest
                }
                var next = ledger; next.revoked.remove(owner); try persist(next)
                let reply = try session(owner)
                if query[0].value == "refresh_token" {
                    try recordOpeningLocked("auth-refresh-complete")
                }
                return reply
            }
            if method == "GET", url.path.hasPrefix("/functions/v1/plants-api/catalogue") {
                let path = "/functions/v1/plants-api/catalogue"
                guard request.value(forHTTPHeaderField: "Authorization") == nil,
                      request.value(forHTTPHeaderField: "X-Installation-Credential") == nil,
                      let locale = request.value(forHTTPHeaderField: "X-Client-Locale"),
                      ["pl", "en"].contains(locale) else { throw CatalogueUIFixtureError.invalidRequest }
                if ledger.scenario.usesPublishedCatalogue {
                    return try publishedCatalogue(request, locale: locale)
                }
                let fern: [String: Any] = [
                    "plant_id": "fixture_fern", "taxon_id": Self.fernTaxon,
                    "display_name": locale == "pl" ? "Paproć" : "Fern",
                    "scientific_name": "Nephrolepis exaltata", "description": NSNull(),
                    "hero_image": NSNull(), "care_profile_available": false
                ]
                if [path + "/fixture_fern", path + "/" + Self.fernTaxon].contains(url.path), query.isEmpty {
                    var detail = fern
                    if ProcessInfo.processInfo.arguments.contains("--catalogue-long-details"),
                       [.guestProviderCancel, .guestProviderFailureRetry].contains(ledger.scenario) {
                        let paragraph = locale == "pl"
                            ? "Nephrolepis exaltata to paproć o długich, łukowato wygiętych liściach. Wzdłuż osi każdego liścia wyrastają liczne drobne listki."
                            : "Nephrolepis exaltata is a fern with long, arching fronds. Each frond carries many small leaflets along its central stem."
                        detail["description"] = [
                            "text": Array(repeating: paragraph, count: 16).joined(separator: "\n\n"),
                            "language": locale
                        ]
                    }
                    return Reply(status: 200, data: try json(detail))
                }
                let palm: [String: Any] = [
                    "plant_id": "fixture_palm", "taxon_id": Self.palmTaxon,
                    "display_name": locale == "pl" ? "Palma" : "Palm",
                    "scientific_name": "Chamaedorea elegans", "description": NSNull(),
                    "hero_image": NSNull(), "care_profile_available": false
                ]
                if ledger.scenario == .plantTaxonEdit, query.isEmpty,
                   [path + "/fixture_palm", path + "/" + Self.palmTaxon].contains(url.path) {
                    return Reply(status: 200, data: try json(palm))
                }
                guard url.path == path, query.map(\.name) == ["q", "limit", "offset"],
                      let term = query[0].value, let limit = query[1].value.flatMap(Int.init),
                      let offset = query[2].value.flatMap(Int.init), (1...200).contains(limit), offset >= 0 else {
                    throw CatalogueUIFixtureError.invalidRequest
                }
                let published = ledger.scenario == .plantTaxonEdit ? [fern, palm] : [fern]
                let matches = published.filter { card in
                    term.isEmpty || ["display_name", "scientific_name"].contains {
                        (card[$0] as? String)?.localizedStandardContains(term) == true
                    } || (card["plant_id"] as? String == "fixture_fern" && ["Fern", "Paproć"].contains {
                        $0.localizedStandardContains(term)
                    })
                }
                return Reply(status: 200, data: try json([
                    "release_version": "fixture", "kb_release_id": NSNull(), "locale": locale,
                    "total": matches.count, "limit": limit, "offset": offset,
                    "items": Array(matches.dropFirst(offset).prefix(limit))
                ]))
            }
            if ledger.scenario.testsPhotoIdentification,
               let reply = try photoRoute(request) { return reply }
            let caller = try owner(request)
            if method == "GET", url.path == "/functions/v1/care-overview" {
                guard ledger.scenario.testsToday, caller == ledger.permanent, body.isEmpty,
                      request.value(forHTTPHeaderField: "X-Catalogue-Fixture-Namespace") == namespace,
                      request.value(forHTTPHeaderField: "X-Installation-Credential") == nil,
                      ["en", "pl"].contains(request.value(forHTTPHeaderField: "X-Client-Locale") ?? ""),
                      Set(query.map(\.name)).count == query.count,
                      Set(query.map(\.name)).isSubset(of: ["limit", "after"]),
                      let raw = query.first(where: { $0.name == "limit" })?.value,
                      let limit = Int(raw), (1...200).contains(limit), raw == String(limit)
                else { throw CatalogueUIFixtureError.invalidRequest }
                let cursor = query.first(where: { $0.name == "after" })
                let after = cursor?.value.flatMap(UUID.init(uuidString:))
                if let cursor {
                    guard let after, cursor.value == after.uuidString.lowercased()
                    else { throw CatalogueUIFixtureError.invalidRequest }
                }
                var next = ledger
                next.overviewRequests = (next.overviewRequests ?? 0) + 1
                try persist(next)
                if ledger.todayTransport == .offline { throw URLError(.notConnectedToInternet) }
                if ledger.todayTransport == .failOverview {
                    return try error(503, "SERVICE_UNAVAILABLE", retryable: true)
                }
                guard let clock = ledger.todayClockSeed else { throw CatalogueUIFixtureError.invalidStorage }
                let ordered = ledger.plants.filter { plant in
                    plant.owner == caller && (after.map {
                        plant.id.uuidString.lowercased() > $0.uuidString.lowercased()
                    } ?? true)
                }.sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
                let page = Array(ordered.prefix(limit))
                let rows: [[String: Any]] = try page.map { plant in
                    ["plant_id": plant.id.uuidString, "care_revision": 1,
                     "care_recommendation": try cardProjection(plant),
                     "first_aid_controls": []] as [String: Any]
                }
                return Reply(status: 200, data: try json([
                    "owner_id": caller.uuidString, "server_now": clock,
                    "owner_watermark": Self.time(ledger.tick),
                    "publication_fingerprint": String(repeating: ledger.todayWithdrawn == true ? "b" : "a", count: 64),
                    "reminder_hour_local": ledger.reminderMode == ReminderConsentFixtureMode.hour.rawValue ? canonicalProfileHour : 9, "automation_allowed": true,
                    "verified_access_until": NSNull(), "plants": rows,
                    "next_after": ordered.count > limit ? page.last!.id.uuidString.lowercased() as Any : NSNull()
                ]))
            }
            if ledger.scenario.testsToday, ledger.todayTransport == .offline,
               url.path.hasPrefix("/functions/v1/") { throw URLError(.notConnectedToInternet) }
            if method == "GET", url.path == "/functions/v1/plants-api/me" {
                guard caller == ledger.permanent, query.isEmpty else {
                    throw CatalogueUIFixtureError.invalidRequest
                }
                if ledger.scenario == .profileReminderHour, ledger.tick > 0 {
                    // A lost reply must remain pending until exactly one explicit replay.
                    guard ledger.attempts.count == 2, ledger.commits.count == 1,
                          ledger.attempts[0].owner == caller, ledger.attempts[1].owner == caller,
                          ledger.attempts[0].body == ledger.attempts[1].body else {
                        throw CatalogueUIFixtureError.invalidRequest
                    }
                }
                return Reply(status: 200, data: try json([
                    "profile": ["preferred_locale": "en",
                                "reminder_hour_local": canonicalProfileHour]
                ]))
            }
            if ledger.scenario == .photoHistory || ledger.scenario.testsPlantEdit,
               method == "GET", url.lastPathComponent == "photo" {
                guard query.isEmpty, request.value(forHTTPHeaderField: "X-Installation-Credential") == nil,
                      let plant = ledger.plants.first, caller == plant.owner else {
                    return try error(404, "NOT_FOUND")
                }
                let root = "/functions/v1/plants-api"
                let paths = [root + "/plants/\(plant.id.uuidString.lowercased())/photo"]
                    + Self.historyObservationIDs.map { root + "/care/observations/\($0.uuidString.lowercased())/photo" }
                guard paths.contains(url.path) else { return try error(404, "NOT_FOUND") }
                let png = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGMQK9bBihiGlgQAqUctQVytyU8AAAAASUVORK5CYII="
                return Reply(status: 200, data: Data(base64Encoded: png)!, contentType: "image/png")
            }
            if method == "GET", url.path == "/auth/v1/user", query.isEmpty {
                return Reply(status: 200, data: try json(user(caller)))
            }
            if method == "POST", url.path == "/auth/v1/logout",
               query.isEmpty || (query.count == 1 && query[0].name == "scope" && ["global", "local"].contains(query[0].value ?? "")) {
                var next = ledger; next.revoked.insert(caller); try persist(next)
                try recordOpeningLocked("auth-logout")
                return Reply(status: 204, data: Data())
            }
            // UI fault injection: cached collection remains usable while advice/first-aid GETs fail.
            if ledger.scenario.testsSavedWatering, method == "GET",
               let plant = ledger.plants.first,
               url.path.hasPrefix("/functions/v1/plants-api/plants/" + plant.id.uuidString.lowercased() + "/") {
                return try error(503, "SERVICE_UNAVAILABLE", retryable: true)
            }
            if (ledger.scenario == .careRecommendationRefresh || ledger.scenario == .careRecommendationRefreshRejected
                || ledger.scenario == .basicCareEnable || ledger.scenario.testsRoutine || ledger.scenario.testsToday),
               method == "GET", query.isEmpty,
               let plant = ledger.plants.first(where: {
                   $0.owner == caller && (ledger.scenario.testsToday || $0.id == ledger.plants.first?.id)
                       && url.path == "/functions/v1/plants-api/plants/\($0.id.uuidString.lowercased())/care/recommendation"
               }) {
                return Reply(status: 200, data: try json(cardProjection(
                    plant, locale: request.value(forHTTPHeaderField: "X-Client-Locale")
                )))
            }
            if method == "GET", url.path == "/functions/v1/plants-api/sync" {
                guard Set(query.map(\.name)).count == query.count,
                      Set(query.map(\.name)).isSubset(of: ["limit", "since"]),
                      query.first(where: { $0.name == "limit" })?.value == "200" else {
                    throw CatalogueUIFixtureError.invalidRequest
                }
                let since = query.first(where: { $0.name == "since" })?.value
                if let since, SQLTimestamp.microseconds(from: since) == nil {
                    throw CatalogueUIFixtureError.invalidRequest
                }
                try recordOpeningLocked("canonical-get")
                let plants = ledger.plants.filter {
                    $0.owner == caller && (since == nil || SQLTimestamp.microseconds(from: $0.timestamp)! > SQLTimestamp.microseconds(from: since!)!)
                }.sorted {
                    $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp
                }
                var changes: [[String: Any]] = plants.map { plant in
                    ["entity_type": "plants", "id": plant.id.uuidString, "updated_at": plant.timestamp,
                     "deleted_at": NSNull(), "data": [
                        "id": plant.id.uuidString, "plant_id": plant.species,
                        "personal_name": plant.name as Any? ?? NSNull(),
                        "display_name": plant.name as Any? ?? NSNull(),
                        "revision": 1, "care_revision": 1,
                        "created_at": plant.timestamp
                     ]]
                }
                if ledger.scenario.testsPhotoIdentification, let photo = ledger.photo,
                   let plantId = photo.plantId, let taxon = photo.selectedTaxon,
                   let index = changes.firstIndex(where: { $0["id"] as? String == plantId.uuidString }),
                   var data = changes[index]["data"] as? [String: Any] {
                    data["main_photo_id"] = photo.photoId.uuidString
                    data["taxon_id"] = taxon.uuidString
                    data["display_name"] = CataloguePhotoFixture.name(taxon, locale: "en")
                    changes[index]["data"] = data
                }
                if ledger.scenario == .collectionWateringMissingConditions,
                   let plant = plants.first(where: { $0.id == ledger.plants.first?.id }),
                   let index = changes.firstIndex(where: { $0["id"] as? String == plant.id.uuidString }),
                   var data = changes[index]["data"] as? [String: Any] {
                    // A valid plant can outlive a condition row absent from this offline cache.
                    // Manual journal access must depend on pending metadata, not this optional read.
                    data["current_condition_snapshot_id"] = plant.id.uuidString
                    changes[index]["data"] = data
                }
                if ledger.scenario == .analysisHistory || ledger.scenario.testsPlantEdit,
                   let plant = plants.first(where: { $0.id == ledger.plants.first?.id }),
                   let index = changes.firstIndex(where: { $0["id"] as? String == plant.id.uuidString }),
                   var data = changes[index]["data"] as? [String: Any] {
                    data["revision"] = 4 + ledger.tick
                    let conditionsChanged = ledger.scenario.changesCareContext && ledger.tick > 0
                    let snapshot = conditionsChanged ? Self.historyObservationIDs[1] : plant.id
                    data["care_revision"] = conditionsChanged ? 3 : 2
                    data["current_condition_snapshot_id"] = snapshot.uuidString
                    if ledger.scenario.testsPlantEdit { data["main_photo_id"] = plant.id.uuidString }
                    if ledger.scenario == .plantTaxonEdit {
                        data["taxon_id"] = plant.species == "fixture_palm" ? Self.palmTaxon : Self.fernTaxon
                    }
                    changes[index]["data"] = data
                    for (index, id) in Self.historyObservationIDs.enumerated() {
                        let older = index == 0
                        changes.append([
                            "entity_type": "analysis_summaries", "id": id.uuidString,
                            "updated_at": Self.time(0), "deleted_at": NSNull(),
                            "data": ["id": id.uuidString, "plant_id": plant.id.uuidString,
                                     "mode": older ? "identification" : "diagnosis",
                                     "source_snapshot_id": older ? id.uuidString : plant.id.uuidString,
                                     "source_care_revision": older ? 1 : 2, "context_state": "current",
                                     "created_at": older ? "2026-10-29T12:00:00Z" : "2026-10-30T12:00:00Z"]
                        ])
                    }
                    if ledger.scenario.changesCareContext {
                        let lightChanged = conditionsChanged && ledger.scenario == .plantLightEdit
                        let drainageChanged = conditionsChanged && ledger.scenario == .plantDrainageEdit
                        let wateringChanged = conditionsChanged && ledger.scenario == .plantWateringEdit
                        let potChanged = conditionsChanged && ledger.scenario == .plantPotTypeEdit
                        changes.append([
                            "entity_type": "condition_snapshots", "id": snapshot.uuidString,
                            "updated_at": plant.timestamp, "deleted_at": NSNull(),
                            "data": ["id": snapshot.uuidString, "plant_id": plant.id.uuidString,
                                     "light_code": lightChanged ? "direct_sun" : "medium",
                                     "drainage_code": drainageChanged ? "no" : "yes",
                                     "watering_code": wateringChanged ? "weekly" : "moderate",
                                     "pot_type": potChanged ? "glazed_ceramic" : "plastic"]
                        ])
                    }
                    if let since {
                        changes.removeAll {
                            SQLTimestamp.microseconds(from: $0["updated_at"] as! String)!
                                <= SQLTimestamp.microseconds(from: since)!
                        }
                    }
                    changes.sort {
                        ($0["updated_at"] as! String, $0["entity_type"] as! String, $0["id"] as! String)
                            < ($1["updated_at"] as! String, $1["entity_type"] as! String, $1["id"] as! String)
                    }
                }
                if ledger.scenario == .photoHistory, let plant = plants.first(where: { $0.id == ledger.plants.first?.id }),
                   let index = changes.firstIndex(where: { $0["id"] as? String == plant.id.uuidString }),
                   var data = changes[index]["data"] as? [String: Any] {
                    data["main_photo_id"] = plant.id.uuidString
                    changes[index]["data"] = data
                    changes += photoHistory(for: plant)
                    changes.sort {
                        ($0["updated_at"] as! String, $0["entity_type"] as! String, $0["id"] as! String)
                            < ($1["updated_at"] as! String, $1["entity_type"] as! String, $1["id"] as! String)
                    }
                }
                if ledger.scenario == .plantDeletion {
                    for commit in ledger.commits.values where commit.owner == caller && commit.envelope.commandName == "plant.delete" {
                        let data = try JSONSerialization.jsonObject(with: commit.receipt) as? [String: String]
                        guard let stamp = data?["watermark"], let time = SQLTimestamp.microseconds(from: stamp) else {
                            throw CatalogueUIFixtureError.invalidRequest
                        }
                        if let since, time <= SQLTimestamp.microseconds(from: since)! { continue }
                        changes.append(["entity_type": "plants", "id": commit.plantID.uuidString,
                                        "updated_at": stamp, "deleted_at": stamp, "data": NSNull()])
                    }
                    changes.sort {
                        ($0["updated_at"] as! String, $0["id"] as! String)
                            < ($1["updated_at"] as! String, $1["id"] as! String)
                    }
                }
                let firstAid: [[String: Any]] = ledger.scenario == .firstAidControl ? plants.map { plant in
                    [
                        "entity_type": "first_aid_followups", "id": plant.id.uuidString,
                        "updated_at": plant.timestamp, "deleted_at": NSNull(),
                        "data": [
                            "id": plant.id.uuidString, "plant_id": plant.id.uuidString,
                            "action_entry_id": plant.id.uuidString, "action_code": "check_soil",
                            "state": plant.name == "Fixture 1" ? "active" : "undone",
                            "check_policy_snapshot": [
                                "due_on": "2026-11-08", "interval_days": 5,
                                "source": ["url": "https://example.invalid/control", "locator": "Fixture interval"]
                            ] as [String: Any]
                        ] as [String: Any]
                    ]
                } : []
                for plant in ledger.scenario.testsToday ? ledger.plants : Array(ledger.plants.prefix(1)) {
                    guard plant.owner == caller, let enabledAt = basicCareEnabledAt(for: plant),
                          since.map({ $0 < enabledAt }) ?? true else { continue }
                    changes.append([
                        "entity_type": "basic_care_memberships", "id": plant.id.uuidString,
                        "updated_at": enabledAt, "deleted_at": NSNull(),
                        "data": ["id": plant.id.uuidString, "plant_id": plant.id.uuidString,
                                 "enabled": true, "enabled_at": enabledAt] as [String: Any]
                    ])
                    changes.sort {
                        ($0["updated_at"] as! String, $0["entity_type"] as! String, $0["id"] as! String)
                            < ($1["updated_at"] as! String, $1["entity_type"] as! String, $1["id"] as! String)
                    }
                }
                if ledger.scenario.testsRoutine,
                   let commit = ledger.commits.values.first(where: {
                       $0.envelope.commandName == RoutineSoilCheckCompletionCommand.name
                   }), commit.owner == caller,
                   since.map({ $0 < Self.time(ledger.tick) }) ?? true {
                    let undo = ledger.commits.values.first {
                        $0.owner == caller && $0.envelope.commandName == RoutineSoilCheckUndoCommand.name
                    }
                    changes += try routineChanges(commit, undo: undo)
                    changes.sort {
                        ($0["updated_at"] as! String, $0["entity_type"] as! String, $0["id"] as! String)
                            < ($1["updated_at"] as! String, $1["entity_type"] as! String, $1["id"] as! String)
                    }
                }
                let entitlement: Any
                switch ledger.scenario {
                case .paid4 where caller == ledger.permanent:
                    entitlement = [
                        "product_id": "fixture-only-paid", "state": "active", "offer_kind": "paid",
                        "valid_until": "2099-01-01T00:00:00.000000Z", "grace_until": NSNull(),
                        "trial_end_at": NSNull(), "auto_renew_enabled": false
                    ] as [String: Any]
                case .trialReminder where caller == ledger.permanent:
                    entitlement = [
                        "product_id": "app.narat.plants.pro.yearly", "state": "active", "offer_kind": "trial",
                        "valid_until": "2099-01-08T12:00:00Z", "grace_until": NSNull(),
                        "trial_end_at": "2099-01-08T12:00:00Z", "auto_renew_enabled": true
                    ] as [String: Any]
                case .routineKnownExpiry:
                    entitlement = [
                        "product_id": "fixture-only-paid", "state": "active", "offer_kind": "paid",
                        "valid_until": "2099-01-01T00:00:01Z", "grace_until": NSNull(),
                        "trial_end_at": NSNull(), "auto_renew_enabled": false
                    ] as [String: Any]
                case .routineLateEntitlement where caller == ledger.permanent:
                    if let deadline = ledger.routineEntitlementDeadline {
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        entitlement = [
                            "product_id": "fixture-only-paid",
                            "state": ledger.routineEntitlementState ?? "active", "offer_kind": "paid",
                            "valid_until": formatter.string(from: deadline), "grace_until": NSNull(),
                            "trial_end_at": NSNull(), "auto_renew_enabled": false
                        ] as [String: Any]
                    } else {
                        entitlement = NSNull()
                    }
                case .photoHistory:
                    entitlement = [
                        "product_id": "fixture-only-paid", "state": "expired", "offer_kind": "paid",
                        "valid_until": "2026-10-31T12:00:00Z", "grace_until": NSNull(),
                        "trial_end_at": NSNull(), "auto_renew_enabled": false
                    ] as [String: Any]
                default:
                    entitlement = NSNull()
                }
                if (ledger.scenario == .routineKnownExpiry || ledger.scenario == .routineLateEntitlement), since == nil,
                   let plant = plants.first(where: { $0.id == ledger.plants.first?.id }) {
                    let id = "19190000-0000-4000-8000-000000000005"
                    changes.append([
                        "entity_type": "care_entries", "id": id, "updated_at": plant.timestamp,
                        "deleted_at": NSNull(), "data": [
                            "id": id, "plant_id": plant.id.uuidString, "action_code": "water",
                            "state": "active", "occurred_at": "2026-10-30T12:00:00Z",
                            "occurred_local_date": "2026-10-30", "timezone": "UTC"
                        ] as [String: Any]
                    ])
                }
                if ledger.scenario.testsSavedWatering {
                    let record = ledger.commits.values.first { ManualWateringAction(envelope: $0.envelope) == .record }
                    // Foreground retries must not implicitly restore the fixture network.
                    // Persist offline across every process launch until explicit Root reconnect.
                    if ledger.wateringCachePrimed == true && ledger.wateringNetworkResumed != true
                        && !(ledger.scenario == .collectionWateringBackgroundFailure && ledger.backgroundWateringRejected == true) {
                        // collectionCards falls back to disk on transport loss, not HTTP errors.
                        // This remains isolated UI fault injection; advice GET still returns 503.
                        throw URLError(.networkConnectionLost)
                    }
                    if ledger.wateringCachePrimed != true {
                        var next = ledger
                        next.wateringCachePrimed = true
                        try persist(next)
                    }
                    if let record, record.owner == caller,
                       since.map({ $0 < Self.time(ledger.tick) }) ?? true {
                        changes += try savedWateringChanges(record)
                    }
                }
                let orderedChanges = (firstAid + changes).sorted {
                    ($0["updated_at"] as! String, $0["entity_type"] as! String, $0["id"] as! String)
                        < ($1["updated_at"] as! String, $1["entity_type"] as! String, $1["id"] as! String)
                }
                let until = Self.time(ledger.tick)
                if ledger.careSourceWithdrawn == true {
                    guard orderedChanges.isEmpty, let since,
                          SQLTimestamp.microseconds(from: since) == SQLTimestamp.microseconds(from: until)
                    else { throw CatalogueUIFixtureError.invalidRequest }
                    var next = ledger
                    next.careSourceEmptyWindowProved = true
                    try persist(next)
                }
                return Reply(status: 200, data: try json([
                    "until": until, "has_more": false, "last_cursor": NSNull(), "next_since": until,
                    "profile": ["preferred_locale": "pl",
                                "reminder_hour_local": canonicalProfileHour,
                                "report_notifications_enabled": true, "trial_reminder_enabled": false],
                    "entitlement": entitlement, "changes": orderedChanges
                ]))
            }
            guard method == "POST", url.path == "/functions/v1/plants-api/commands", query.isEmpty,
                  caller == ledger.permanent else { throw CatalogueUIFixtureError.invalidRequest }
            let envelope = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: body)
            if ledger.scenario == .profileReminderHour || ledger.reminderMode == ReminderConsentFixtureMode.hour.rawValue,
               let command = ProfileReminderHourCommand(envelope) {
                guard command.reminderHourLocal == 23,
                      request.value(forHTTPHeaderField: "X-Operation-Id") == envelope.operationId.uuidString.lowercased()
                else { throw CatalogueUIFixtureError.invalidRequest }
                let key = caller.uuidString + ":" + envelope.operationId.uuidString
                var next = ledger
                next.attempts.append(Attempt(owner: caller, body: body))
                if let commit = ledger.commits[key] {
                    guard (ledger.attempts.count == 1 || ledger.reminderMode == ReminderConsentFixtureMode.hour.rawValue), ledger.commits.count == 1,
                          commit.owner == caller, commit.body == body, commit.envelope == envelope
                    else {
                        try persist(next)
                        throw CatalogueUIFixtureError.invalidRequest
                    }
                    try persist(next)
                    return Reply(status: 200, data: commit.receipt)
                }
                guard ledger.attempts.isEmpty, ledger.commits.isEmpty else {
                    try persist(next)
                    throw CatalogueUIFixtureError.invalidRequest
                }
                next.tick += 1
                let receipt = try json([
                    "profile": ["preferred_locale": "en", "reminder_hour_local": 23],
                    "watermark": Self.time(next.tick)
                ])
                next.commits[key] = Commit(owner: caller, envelope: envelope, body: body,
                                           receipt: receipt, plantID: caller)
                try persist(next)
                throw URLError(.networkConnectionLost)
            }
            if ledger.scenario.testsSavedWatering, let action = ManualWateringAction(envelope: envelope) {
                return try savedWatering(action, envelope: envelope, body: body, caller: caller,
                                        header: request.value(forHTTPHeaderField: "X-Operation-Id"))
            }
            if ledger.scenario == .plantDeletion, envelope.commandName == "plant.delete" {
                return try deletePlant(envelope, body: body, caller: caller, header: request.value(forHTTPHeaderField: "X-Operation-Id"))
            }
            if ledger.scenario.testsPlantEdit, let edit = PlantEditCommand(envelope) {
                return try editPlant(edit, body: body, caller: caller, header: request.value(forHTTPHeaderField: "X-Operation-Id"))
            }
            if ledger.scenario == .routineSoilCheckUndo, envelope.commandName == RoutineSoilCheckUndoCommand.name {
                return try undoRoutine(envelope, body: body, caller: caller,
                                       header: request.value(forHTTPHeaderField: "X-Operation-Id"))
            }
            if ledger.scenario.testsRoutine, let command = RoutineSoilCheckCompletionCommand(envelope) {
                guard let plant = ledger.plants.first, plant.id == envelope.plantId, plant.owner == caller,
                      command.ruleId.uuidString.lowercased() == Self.routineRule,
                      command.careRevision == 1, command.dueLocalDate == "2000-01-01",
                      request.value(forHTTPHeaderField: "X-Operation-Id") == envelope.operationId.uuidString.lowercased()
                else { throw CatalogueUIFixtureError.invalidRequest }
                if ledger.scenario == .routinePendingPolish {
                    var next = ledger
                    next.attempts.append(Attempt(owner: caller, body: body))
                    try persist(next)
                }
                let key = caller.uuidString + ":" + envelope.operationId.uuidString
                if let commit = ledger.commits[key] {
                    guard commit.owner == caller, commit.envelope == envelope, commit.body == body
                    else { throw CatalogueUIFixtureError.invalidRequest }
                    if ledger.scenario == .routinePendingPolish {
                        guard ledger.attempts.count <= 4 else { throw CatalogueUIFixtureError.invalidRequest }
                        // Keep the original operation pending: never deliver the receipt
                        // and never create a second canonical commit on a Root replay.
                        return try error(503, "SERVICE_UNAVAILABLE", retryable: true)
                    }
                    return Reply(status: 200, data: commit.receipt)
                }
                guard ledger.commits.isEmpty else { throw CatalogueUIFixtureError.invalidRequest }
                var next = ledger
                next.tick += 1
                let receipt = try json([
                    "plant_id": plant.id.uuidString, "rule_id": Self.routineRule, "care_revision": 1,
                    "occurrence_key": Self.routineRule + ":2000-01-01", "due_local_date": "2000-01-01",
                    "task_id": Self.routineTask, "entry_id": Self.routineEntry,
                    "state": "completed", "watermark": Self.time(next.tick)
                ])
                next.commits[key] = Commit(owner: caller, envelope: envelope, body: body, receipt: receipt, plantID: plant.id)
                try persist(next)
                if ledger.scenario == .routineSoilCheckUndo { return Reply(status: 200, data: receipt) }
                throw URLError(.networkConnectionLost)
            }
            if ledger.scenario == .basicCareEnable, envelope.commandName == BasicCareEnableReceipt.commandName {
                guard let plant = ledger.plants.first, plant.id == envelope.plantId, plant.owner == caller,
                      envelope.payloadJSON == "{}",
                      request.value(forHTTPHeaderField: "X-Operation-Id") == envelope.operationId.uuidString.lowercased()
                else { throw CatalogueUIFixtureError.invalidRequest }
                let key = caller.uuidString + ":" + envelope.operationId.uuidString
                if let commit = ledger.commits[key] {
                    guard commit.envelope == envelope, commit.body == body else { throw CatalogueUIFixtureError.invalidRequest }
                    return Reply(status: 200, data: commit.receipt)
                }
                guard ledger.commits.isEmpty else { throw CatalogueUIFixtureError.invalidRequest }
                var next = ledger
                next.tick += 1
                let receipt = try json([
                    "plant_id": plant.id.uuidString, "enabled": true, "enabled_at": Self.time(next.tick)
                ])
                next.commits[key] = Commit(owner: caller, envelope: envelope, body: body, receipt: receipt, plantID: plant.id)
                try persist(next)
                throw URLError(.networkConnectionLost)
            }
            if (ledger.scenario == .careRecommendationRefresh || ledger.scenario == .careRecommendationRefreshRejected
                || ledger.scenario == .routineLateEntitlement),
               let refresh = CareRecommendationRefreshCommand(envelope) {
                guard let plant = ledger.plants.first, plant.id == envelope.plantId, plant.owner == caller,
                      refresh.careRevision == 1,
                      request.value(forHTTPHeaderField: "X-Operation-Id") == envelope.operationId.uuidString.lowercased()
                else { throw CatalogueUIFixtureError.invalidRequest }
                if ledger.scenario == .careRecommendationRefreshRejected {
                    return try error(409, "CONFLICT", retryable: false)
                }
                let key = caller.uuidString + ":" + envelope.operationId.uuidString
                if let commit = ledger.commits[key] {
                    guard commit.envelope == envelope, commit.body == body else { throw CatalogueUIFixtureError.invalidRequest }
                    return Reply(status: 200, data: commit.receipt)
                }
                guard ledger.commits.isEmpty else { throw CatalogueUIFixtureError.invalidRequest }
                var next = ledger
                next.tick += 1
                let receipt = try json([
                    "plant_id": plant.id.uuidString, "care_revision": refresh.careRevision,
                    "state": "refreshed", "reason": NSNull(), "watermark": Self.time(next.tick)
                ])
                next.commits[key] = Commit(owner: caller, envelope: envelope, body: body, receipt: receipt, plantID: plant.id)
                if ledger.scenario == .routineLateEntitlement {
                    // Arm only after the open card's initial nil entitlement was read.
                    // Persist the real deadline; reopening cannot grant another interval.
                    next.routineEntitlementDeadline = Date().addingTimeInterval(6)
                    next.routineEntitlementState = "active"
                    try persist(next)
                    return Reply(status: 200, data: receipt)
                }
                try persist(next)
                throw URLError(.networkConnectionLost)
            }
            try CatalogueCreateWire.validate(envelope)
            guard request.value(forHTTPHeaderField: "X-Operation-Id") == envelope.operationId.uuidString.lowercased(),
                  Set(object.keys).isSubset(of: ["operation_id", "command_name", "plant_id", "payload_json"]),
                  let payload = try JSONSerialization.jsonObject(with: Data(envelope.payloadJSON.utf8)) as? [String: Any],
                  payload["plant_id"] as? String == "fixture_fern",
                  Set(payload.keys).isSubset(of: ["plant_id", "personal_name", "creation_source"]) else {
                throw CatalogueUIFixtureError.invalidRequest
            }
            let key = caller.uuidString + ":" + envelope.operationId.uuidString
            if let commit = ledger.commits[key] {
                guard commit.owner == caller, commit.body == body, commit.envelope == envelope else {
                    throw CatalogueUIFixtureError.invalidRequest
                }
                var next = ledger; next.attempts.append(Attempt(owner: caller, body: body)); try persist(next)
                return Reply(status: 200, data: commit.receipt)
            }
            var next = ledger
            next.attempts.append(Attempt(owner: caller, body: body))
            if ledger.scenario == .server503 {
                try persist(next); return try error(503, "INTERNAL_ERROR", retryable: true)
            }
            if ledger.scenario == .server409 || (ledger.scenario != .paid4 && ledger.plants.filter({ $0.owner == caller }).count >= 3) {
                try persist(next); return try error(409, "COLLECTION_LIMIT_REACHED")
            }
            next.tick += 1
            // Match SQL trim/NULLIF and the published Polish catalogue-name fallback.
            let suppliedName = (payload["personal_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: " "))
            let personalName = suppliedName.flatMap { $0.isEmpty ? nil : $0 } ?? "Paproć"
            let plant = Plant(owner: caller, id: UUID(), species: "fixture_fern",
                              name: personalName, timestamp: Self.time(next.tick))
            let receipt = try json([
                "plant_id": plant.id.uuidString, "care_revision": 1, "context_state": "current",
                // This published species has no published care profile or generated plan.
                "next_available_step": "view_plant", "paid_action": NSNull(),
                "plan_availability": "care_profile_unavailable", "watermark": plant.timestamp
            ])
            next.plants.append(plant)
            next.commits[key] = Commit(owner: caller, envelope: envelope, body: body, receipt: receipt, plantID: plant.id)
            let lose = next.scenario == .lostresponse && !next.lostResponseCommitted
            if lose { next.lostResponseCommitted = true }
            try persist(next)
            if lose { throw URLError(.networkConnectionLost) }
            return Reply(status: 200, data: receipt)
        }
    }

    private func savedWatering(
        _ action: ManualWateringAction, envelope: CommandEnvelopeDTO, body: Data, caller: UUID, header: String?
    ) throws -> Reply {
        guard let plant = ledger.plants.first, plant.owner == caller, envelope.plantId == plant.id,
              header == envelope.operationId.uuidString.lowercased()
        else { throw CatalogueUIFixtureError.invalidRequest }
        let key = caller.uuidString + ":" + envelope.operationId.uuidString
        var next = ledger
        next.attempts.append(Attempt(owner: caller, body: body))
        if let commit = ledger.commits[key] {
            guard commit.owner == caller, commit.body == body, commit.envelope == envelope
            else { throw CatalogueUIFixtureError.invalidRequest }
            try persist(next)
            if action == .record && ledger.wateringNetworkResumed != true {
                throw URLError(.networkConnectionLost)
            }
            return Reply(status: 200, data: commit.receipt)
        }
        if ledger.scenario == .collectionWateringBackgroundFailure {
            guard action == .record else { throw CatalogueUIFixtureError.invalidRequest }
            guard let first = ledger.attempts.first else {
                // Fault injection before server commit: the original fact does not yet exist.
                try persist(next)
                throw URLError(.networkConnectionLost)
            }
            let original = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: first.body)
            if envelope.operationId == original.operationId {
                guard envelope == original, body == first.body else { throw CatalogueUIFixtureError.invalidRequest }
                next.backgroundWateringRejected = true
                try persist(next)
                return try error(409, "CONFLICT")
            }
            // Exactly original loss, one automatic rejection, one explicit retry.
            // Any automatic resend on cold/foreground makes a later new record fail.
            guard ledger.backgroundWateringRejected == true, ledger.attempts.count == 3,
                  ledger.commits.isEmpty else { throw CatalogueUIFixtureError.invalidRequest }
            next.tick += 1
            let receipt = try json([
                "plant_id": plant.id.uuidString, "entry_id": envelope.operationId.uuidString,
                "state": "active", "watermark": Self.time(next.tick)
            ])
            next.commits[key] = Commit(owner: caller, envelope: envelope, body: body,
                                       receipt: receipt, plantID: plant.id)
            try persist(next)
            return Reply(status: 200, data: receipt)
        }
        if ledger.scenario == .collectionWateringRecordRejected {
            guard action == .record, !ledger.attempts.contains(where: {
                (try? JSONDecoder().decode(CommandEnvelopeDTO.self, from: $0.body))?.operationId == envelope.operationId
            }) else { throw CatalogueUIFixtureError.invalidRequest }
            try persist(next)
            return try error(409, "CONFLICT")
        }
        let record = ledger.commits.values.first { ManualWateringAction(envelope: $0.envelope) == .record }
        let entryId: UUID
        let state: String
        switch action {
        case .record:
            // Any duplicate new operation fails the fixture instead of creating a second fact.
            guard record == nil, ledger.attempts.isEmpty else { throw CatalogueUIFixtureError.invalidRequest }
            entryId = envelope.operationId
            state = "active"
        case let .correctDate(id, _, _), let .undo(id):
            guard let record, id == record.envelope.operationId,
                  !ledger.commits.values.contains(where: { $0.envelope.commandName == envelope.commandName })
            else { throw CatalogueUIFixtureError.invalidRequest }
            entryId = id
            state = envelope.commandName == ManualWateringAction.undoCommand ? "voided" : "active"
        }
        next.tick += 1
        var value: [String: Any] = [
            "plant_id": plant.id.uuidString, "entry_id": entryId.uuidString,
            "state": state, "watermark": Self.time(next.tick)
        ]
        if state == "voided" { value["reversal_id"] = envelope.operationId.uuidString }
        let receipt = try json(value)
        next.commits[key] = Commit(owner: caller, envelope: envelope, body: body, receipt: receipt, plantID: plant.id)
        try persist(next)
        if action == .record { throw URLError(.networkConnectionLost) }
        return Reply(status: 200, data: receipt)
    }

    private func savedWateringChanges(_ record: Commit) throws -> [[String: Any]] {
        let correction = ledger.commits.values.first {
            $0.envelope.commandName == ManualWateringAction.correctionCommand
        }
        let undo = ledger.commits.values.first { $0.envelope.commandName == ManualWateringAction.undoCommand }
        let current = correction ?? record
        let payload = try JSONDecoder().decode([String: String].self, from: Data(current.envelope.payloadJSON.utf8))
        let id = record.envelope.operationId.uuidString
        let entry: [String: Any] = [
            "id": id, "plant_id": record.plantID.uuidString,
            "operation_id": record.envelope.operationId.uuidString,
            "action_code": "water", "state": undo == nil ? "active" : "voided",
            "occurred_at": payload["occurred_at"]!, "timezone": payload["timezone"]!,
            "occurred_local_date": try routineLocalDate(current)
        ]
        var rows = [("care_entries", id, entry)]
        if let undo {
            rows.append(("care_reversals", undo.envelope.operationId.uuidString, [
                "id": undo.envelope.operationId.uuidString, "plant_id": record.plantID.uuidString,
                "entry_id": id, "operation_id": undo.envelope.operationId.uuidString
            ]))
        }
        return rows.map { entity, id, data in
            ["entity_type": entity, "id": id, "updated_at": Self.time(ledger.tick),
             "deleted_at": NSNull(), "data": data]
        }
    }

    private static let routineRule = "19190000-0000-4000-8000-000000000001"
    private static let routineTask = "19190000-0000-4000-8000-000000000002"
    private static let routineEntry = "19190000-0000-4000-8000-000000000003"

    private static let routineReversal = "19190000-0000-4000-8000-000000000004"

    private func undoRoutine(_ envelope: CommandEnvelopeDTO, body: Data, caller: UUID, header: String?) throws -> Reply {
        guard let plant = ledger.plants.first, plant.owner == caller, plant.id == envelope.plantId,
              let command = RoutineSoilCheckUndoCommand(envelope, taskId: UUID(uuidString: Self.routineTask)!),
              command.entryId == UUID(uuidString: Self.routineEntry)!,
              header == envelope.operationId.uuidString.lowercased(),
              ledger.commits.values.contains(where: {
                  $0.owner == caller && $0.plantID == plant.id
                      && $0.envelope.commandName == RoutineSoilCheckCompletionCommand.name
              }) else { throw CatalogueUIFixtureError.invalidRequest }
        let key = caller.uuidString + ":" + envelope.operationId.uuidString
        if let commit = ledger.commits[key] {
            guard commit.owner == caller, commit.envelope == envelope, commit.body == body
            else { throw CatalogueUIFixtureError.invalidRequest }
            return Reply(status: 200, data: commit.receipt)
        }
        guard !ledger.commits.values.contains(where: {
            $0.envelope.commandName == RoutineSoilCheckUndoCommand.name
        }) else { throw CatalogueUIFixtureError.invalidRequest }
        var next = ledger
        next.tick += 1
        let receipt = try json([
            "plant_id": plant.id.uuidString, "task_id": Self.routineTask,
            "entry_id": Self.routineEntry, "reversal_id": Self.routineReversal,
            "state": "voided", "watermark": Self.time(next.tick)
        ])
        next.commits[key] = Commit(owner: caller, envelope: envelope, body: body, receipt: receipt, plantID: plant.id)
        try persist(next)
        throw URLError(.networkConnectionLost)
    }

    /// One ledger-backed card wire projection, shared by card and overview GETs.
    private func cardProjection(_ plant: Plant, locale: String? = nil) throws -> [String: Any] {
        if ledger.scenario.testsToday {
            guard let day = ledger.todayAnchorDay,
                  let index = ledger.plants.firstIndex(where: { $0.id == plant.id })
            else { throw CatalogueUIFixtureError.invalidStorage }
            if ledger.todayWithdrawn == true {
                return ["plant_id": plant.id.uuidString, "status": "unavailable",
                        "recommendation": NSNull(), "next_check": NSNull(), "routine_check": NSNull()]
            }
            // Explicit fixture policies; no catalogue/source interval derivation.
            let scheduled = ledger.scenario != .todayNoSchedule && index < 2
            let due = routineNextDate(day, days: ledger.scenario == .todayFuture ? 2 : -index)
            let anchor = routineNextDate(due, days: -7)
            let source = ["url": "https://example.invalid/soil", "locator": "Fixture interval"]
            var response: [String: Any] = [
                "plant_id": plant.id.uuidString, "status": "available",
                "recommendation": [
                    "action_id": "fixture_soil_check", "action_code": "check_soil",
                    "text": "Check the soil before watering.", "next_check_interval_days": 7, "source": source
                ] as [String: Any],
                "next_check": NSNull(), "routine_check": NSNull()
            ]
            if scheduled {
                response["next_check"] = [
                    "due_on": due, "anchor_on": anchor, "interval_days": 7,
                    "basis": "Based on the last soil check.", "source": source
                ] as [String: Any]
                response["routine_check"] = [
                    "rule_id": plant.id.uuidString, "care_revision": 1,
                    "due_local_date": due, "anchor_local_date": anchor, "anchor_kind": "check_soil"
                ] as [String: Any]
            }
            return response
        }
        if ledger.careSourceWithdrawn == true {
            guard ledger.careSourceEmptyWindowProved == true else { throw CatalogueUIFixtureError.invalidRequest }
            return [
                "plant_id": plant.id.uuidString, "status": "unavailable",
                "recommendation": NSNull(), "next_check": NSNull(), "routine_check": NSNull()
            ]
        }
        if ledger.scenario.testsRoutine {
            if ledger.scenario == .routinePendingPolish,
               locale == "pl" {
                // Opening the same card after Root locale revalidation must prove
                // one intent/commit and bounded, byte-identical durable replays.
                guard (2...4).contains(ledger.attempts.count), ledger.commits.count == 1,
                      let commit = ledger.commits.values.first,
                      commit.owner == plant.owner, commit.plantID == plant.id,
                      commit.envelope.commandName == RoutineSoilCheckCompletionCommand.name,
                      ledger.attempts.allSatisfy({ $0.owner == plant.owner && $0.body == commit.body })
                else { throw CatalogueUIFixtureError.invalidRequest }
            }
            let completion = ledger.commits.values.first {
                $0.plantID == plant.id && $0.envelope.commandName == RoutineSoilCheckCompletionCommand.name
            }
            let undone = ledger.commits.values.contains { $0.plantID == plant.id && $0.envelope.commandName == RoutineSoilCheckUndoCommand.name }
            let anchor = try (!undone ? completion : nil).map { try routineLocalDate($0) } ?? "1999-12-25"
            let due = completion == nil || undone ? "2000-01-01" : routineNextDate(anchor)
            let source = ["url": "https://example.invalid/soil", "locator": "Fixture interval"]
            var response: [String: Any] = [
                "plant_id": plant.id.uuidString, "status": "available",
                "next_check": ["due_on": due, "anchor_on": anchor, "interval_days": 7,
                               "basis": "Based on the last soil check.", "source": source] as [String: Any],
                "routine_check": ["rule_id": Self.routineRule, "care_revision": 1,
                                  "due_local_date": due, "anchor_local_date": anchor,
                                  "anchor_kind": "check_soil"] as [String: Any],
                "recommendation": ["action_id": "fixture_soil_check", "action_code": "check_soil",
                                   "text": "Check the soil before watering.",
                                   "next_check_interval_days": 7, "source": source] as [String: Any]
            ]
            if ledger.scenario == .routineLateEntitlement, ledger.routineEntitlementDeadline == nil {
                // Refresh is offered only while there is no scheduled next check.
                response["next_check"] = NSNull()
                response["routine_check"] = NSNull()
            }
            return response
        }
        let source = ["url": "https://example.invalid/soil", "locator": "Fixture interval"]
        let check: Any = ledger.scenario != .careRecommendationRefresh || ledger.commits.isEmpty ? NSNull() : [
            "due_on": "2026-10-28", "anchor_on": "2026-10-21", "interval_days": 7,
            "basis": "Based on your last watering.", "source": source
        ] as [String: Any]
        return [
            "plant_id": plant.id.uuidString, "status": "available", "next_check": check,
            "recommendation": [
                "action_id": "fixture_soil_check", "action_code": "check_soil",
                "text": "Check the soil before watering.", "next_check_interval_days": 7, "source": source
            ] as [String: Any]
        ]
    }

    private func routineLocalDate(_ commit: Commit) throws -> String {
        let payload = try JSONSerialization.jsonObject(with: Data(commit.envelope.payloadJSON.utf8)) as? [String: Any]
        guard let timestamp = payload?["occurred_at"] as? String,
              let date = ISO8601DateFormatter().date(from: timestamp),
              let zone = payload?["timezone"] as? String, let timezone = TimeZone(identifier: zone)
        else { throw CatalogueUIFixtureError.invalidRequest }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = timezone
        return formatter.string(from: date)
    }

    private func routineNextDate(_ anchor: String, days: Int = 7) -> String {
        let date = SQLCalendarDay.calendar.date(byAdding: .day, value: days, to: SQLCalendarDay.date(from: anchor)!)!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func routineChanges(_ commit: Commit, undo: Commit? = nil) throws -> [[String: Any]] {
        let payload = try JSONSerialization.jsonObject(with: Data(commit.envelope.payloadJSON.utf8)) as! [String: Any]
        let task: [String: Any] = [
            "id": Self.routineTask, "plant_id": commit.plantID.uuidString, "rule_id": Self.routineRule,
            "occurrence_key": Self.routineRule + ":2000-01-01", "due_local_date": "2000-01-01",
            "action_code": "check_soil", "condition_code": "check_soil_first",
            "state": undo == nil ? "completed" : "superseded", "completed_entry_id": Self.routineEntry
        ]
        let entry: [String: Any] = [
            "id": Self.routineEntry, "plant_id": commit.plantID.uuidString,
            "task_id": Self.routineTask, "operation_id": commit.envelope.operationId.uuidString,
            "action_code": "check_soil", "state": undo == nil ? "active" : "voided", "occurred_at": payload["occurred_at"]!,
            "timezone": payload["timezone"]!, "occurred_local_date": try routineLocalDate(commit)
        ]
        var rows = [("care_tasks", Self.routineTask, task), ("care_entries", Self.routineEntry, entry)]
        if let undo {
            rows.append(("care_reversals", Self.routineReversal, [
                "id": Self.routineReversal, "plant_id": commit.plantID.uuidString,
                "entry_id": Self.routineEntry, "operation_id": undo.envelope.operationId.uuidString
            ]))
        }
        return rows.map { entity, id, data in
            ["entity_type": entity, "id": id, "updated_at": Self.time(ledger.tick),
             "deleted_at": NSNull(), "data": data] as [String: Any]
        }
    }

    private func basicCareEnabledAt(for plant: Plant) -> String? {
        if ledger.scenario.testsToday || ledger.scenario == .careRecommendationRefresh || ledger.scenario == .careRecommendationRefreshRejected || ledger.scenario.testsRoutine {
            return plant.timestamp
        }
        guard ledger.scenario == .basicCareEnable,
              let receipt = ledger.commits.values.first(where: { $0.plantID == plant.id })?.receipt
        else { return nil }
        return (try? JSONDecoder().decode(BasicCareEnableReceipt.self, from: receipt))?.enabledAt
    }

    private func editPlant(_ edit: PlantEditCommand, body: Data, caller: UUID, header: String?) throws -> Reply {
        let envelope = edit.envelope
        guard let first = ledger.plants.first, envelope.plantId == first.id, first.owner == caller,
              header == envelope.operationId.uuidString.lowercased() else { throw CatalogueUIFixtureError.invalidRequest }
        let key = caller.uuidString + ":" + envelope.operationId.uuidString
        var next = ledger
        next.attempts.append(Attempt(owner: caller, body: body))
        if let commit = ledger.commits[key] {
            guard commit.body == body, commit.envelope == envelope else { throw CatalogueUIFixtureError.invalidRequest }
            try persist(next)
            return Reply(status: 200, data: commit.receipt)
        }
        guard ledger.commits.isEmpty else { throw CatalogueUIFixtureError.invalidRequest }
        if ledger.scenario == .plantRenameRejected {
            if let attempt = ledger.attempts.first {
                let rejected = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: attempt.body)
                guard rejected.operationId != envelope.operationId, rejected.payloadJSON != envelope.payloadJSON
                else { throw CatalogueUIFixtureError.invalidRequest }
            } else {
                try persist(next)
                return try error(400, "VALIDATION_ERROR")
            }
        }
        let name: String?
        var species = first.species
        let snapshot: UUID
        let careRevision: Int
        switch edit.change {
        case let .name(requested):
            guard !ledger.scenario.changesCareContext else { throw CatalogueUIFixtureError.invalidRequest }
            name = requested
            snapshot = first.id
            careRevision = 2
        case .light(.directSun) where ledger.scenario == .plantLightEdit,
             .drainage(.no) where ledger.scenario == .plantDrainageEdit,
             .watering(.weekly) where ledger.scenario == .plantWateringEdit,
             .potType(.glazedCeramic) where ledger.scenario == .plantPotTypeEdit:
            name = first.name
            snapshot = Self.historyObservationIDs[1]
            careRevision = 3
        case let .taxon(taxon) where ledger.scenario == .plantTaxonEdit && taxon.uuidString.lowercased() == Self.palmTaxon:
            species = "fixture_palm"
            name = first.name
            snapshot = Self.historyObservationIDs[1]
            careRevision = 3
        default:
            throw CatalogueUIFixtureError.invalidRequest
        }
        next.tick += 1
        let stamp = Self.time(next.tick)
        next.plants[0] = Plant(owner: caller, id: first.id, species: species, name: name, timestamp: stamp)
        let receipt = try json(["plant_id": first.id.uuidString, "revision": 4 + next.tick, "care_revision": careRevision,
                                "condition_snapshot_id": snapshot.uuidString, "watermark": stamp])
        next.commits[key] = Commit(owner: caller, envelope: envelope, body: body, receipt: receipt, plantID: first.id)
        try persist(next)
        if ledger.scenario != .plantRenameRejected { throw URLError(.networkConnectionLost) }
        return Reply(status: 200, data: receipt)
    }

    private func deletePlant(_ envelope: CommandEnvelopeDTO, body: Data, caller: UUID, header: String?) throws -> Reply {
        guard let plant = envelope.plantId, envelope.payloadJSON == "{}",
              header == envelope.operationId.uuidString.lowercased() else {
            throw CatalogueUIFixtureError.invalidRequest
        }
        let key = caller.uuidString + ":" + envelope.operationId.uuidString
        var next = ledger
        next.attempts.append(Attempt(owner: caller, body: body))
        if let commit = ledger.commits[key] {
            guard commit.body == body, commit.envelope == envelope else { throw CatalogueUIFixtureError.invalidRequest }
            try persist(next)
            return Reply(status: 200, data: commit.receipt)
        }
        guard next.plants.contains(where: { $0.owner == caller && $0.id == plant })
        else { return try error(404, "NOT_FOUND") }
        next.plants.removeAll { $0.owner == caller && $0.id == plant }
        next.tick += 1
        let receipt = try json(["plant_id": plant.uuidString, "deletion_job_id": UUID().uuidString,
                                "state": "deleting", "watermark": Self.time(next.tick)])
        next.commits[key] = Commit(owner: caller, envelope: envelope, body: body, receipt: receipt, plantID: plant)
        try persist(next)
        throw URLError(.networkConnectionLost)
    }
}

private final class CatalogueFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [String: CatalogueFixtureServer] = [:]
    func contains(_ name: String) -> Bool { lock.withLock { servers[name] != nil } }
    func insert(_ server: CatalogueFixtureServer, name: String) throws {
        try lock.withLock {
            guard servers[name] == nil else { throw CatalogueUIFixtureError.namespaceInUse }
            servers[name] = server
        }
    }
    func remove(_ server: CatalogueFixtureServer, name: String) {
        lock.withLock { if servers[name] === server { servers[name] = nil } }
    }
    func get(_ name: String) -> CatalogueFixtureServer? { lock.withLock { servers[name] } }
}

/// Claims every URL, including unknown hosts, so the isolated session cannot reach the network.
private final class CatalogueFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let registry = CatalogueFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let name = request.value(forHTTPHeaderField: "X-Catalogue-Fixture-Namespace"),
                  let server = Self.registry.get(name), let url = request.url else {
                throw URLError(.unsupportedURL)
            }
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    if server.snapshot.scenario.testsPhotoIdentification,
                       body.count + count > AnalysisPhotoInput.maxCloudBytes {
                        throw URLError(.dataLengthExceedsMaximum)
                    }
                    body.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = body
            }
            let reply = try server.handle(captured)
            let held = server.takePhotoValidation(captured)
            let wasStopped = deliveryLock.withLock {
                heldReply = held
                return stopped
            }
            if wasStopped { held?.cancel() }
            guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                                headerFields: ["Content-Type": reply.contentType, "Cache-Control": "private, no-store"]) else {
                throw URLError(.badServerResponse)
            }
            let deliver: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                self.deliveryLock.withLock {
                    guard !self.stopped else { return }
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    guard !self.stopped else { return }
                    self.client?.urlProtocol(self, didLoad: reply.data)
                    guard !self.stopped else { return }
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            }
            if let held { held.attach(deliver) } else { deliver() }
        } catch {
            let held = deliveryLock.withLock { () -> CataloguePhotoValidationToken? in
                if !stopped { client?.urlProtocol(self, didFailWithError: error) }
                return heldReply
            }
            held?.cancel()
        }
    }
    private let deliveryLock = NSRecursiveLock()
    private var stopped = false
    private var heldReply: CataloguePhotoValidationToken?
    override func stopLoading() {
        let held = deliveryLock.withLock {
            stopped = true
            return heldReply
        }
        held?.cancel()
    }
}

// F1a: real SDK/service HTTP fixtures. This is not a replacement AnalysisService.
enum CataloguePhotoFixture {
    static let originalTaxon = CataloguePublishedFixture.taxon
    static let correctedTaxon = UUID(uuidString: "a2000000-0000-4000-8000-000000000003")!
    static let release = UUID(uuidString: "b2000000-0000-4000-8000-000000000001")!
    static let expiry = "2099-01-08T12:00:00.000000Z"
    static let correctedPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGMQK9bBihiGlgQAqUctQVytyU8AAAAASUVORK5CYII="
    )!

    static func name(_ taxon: UUID, locale: String) -> String {
        if taxon == originalTaxon { return locale == "pl" ? "Nefrolepis" : "Boston fern" }
        if taxon == correctedTaxon { return locale == "pl" ? "Chamedora" : "Parlour palm" }
        return "Published fixture species " + String(taxon.uuidString.suffix(12))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func description(locale: String) -> String {
        if locale == "pl" {
            return """
                Ten opublikowany rekord testowy opisuje kształt i układ liści. Okaz ma widoczną główną łodygę oraz oddzielne obszary nowego przyrostu. Te szczegóły należą do rekordu katalogowego i nie stanowią diagnozy stanu sfotografowanej rośliny.

                Dojrzałe liście mogą różnić się od rozwijających się liści rozmiarem, obrysem i kolorem. Przy porównywaniu okazu z materiałem referencyjnym należy obserwować kilka liści razem. Pojedynczy uszkodzony liść nie jest wystarczającym dowodem do określenia gatunku.

                Ilustracja referencyjna jest syntetycznym studium kolorystycznym. W tym deterministycznym zestawie danych testowych demonstruje ładowanie obrazów i oznaczenie autorstwa. Nie jest fotografią botaniczną i nie może służyć jako dowód dokładności rozpoznawania.

                Informacje katalogowe pozostają oddzielone od prywatnego zdjęcia przesłanego do rozpoznania. Zmiana wybranego gatunku zachowuje pierwotnie przesłane zdjęcie oraz jego zadanie analizy. Otwarcie tego opisu nie powoduje zlecenia dodatkowej analizy.

                Ogólny wygląd zmienia się wraz z dojrzałością i warunkami wzrostu. Ten tekst dostarcza wyłącznie kontekstu opisowego dla długiego, przewijanego widoku szczegółów; nie zawiera spersonalizowanych porad, wniosków dotyczących toksyczności, leczenia, harmonogramu podlewania ani zaleceń.
                """
        }
        return description
    }

    // Unique paragraphs exercise scrolling without repeating a common name.
    static let description = """
        This published fixture describes the shape and arrangement of the leaves. The specimen \
        has a visible central stem and separate areas of new growth. These details belong to \
        the catalogue record and do not diagnose the condition of the photographed plant.

        Mature foliage can differ from emerging foliage in size, outline and colour. Observe \
        several leaves together when comparing a specimen with a reference. A single damaged \
        leaf is not sufficient evidence for a species decision.

        The reference illustration is a synthetic colour study. It demonstrates image loading \
        and attribution in this deterministic fixture. It is not a botanical photograph and \
        must not be treated as evidence of identification accuracy.

        Catalogue information remains separate from the private photograph submitted for \
        identification. Correcting the selected species retains that original upload and its \
        analysis job. No additional analysis is requested when this description is opened.

        General appearance varies with maturity and growing conditions. This text supplies \
        descriptive context for a long detail sheet only; it supplies no personalised advice, \
        toxicity conclusion, treatment, watering schedule or recommendation.
        """
}

/// Optional on old ledgers. Receipts contain only public IDs and hashes of canonical bodies.
struct CataloguePhotoFixtureState: Codable, Sendable {
    struct Receipt: Codable, Sendable {
        let route: String
        let owner: UUID
        let bodySHA256: String
        let status: Int
        let data: Data
    }
    let installationId: UUID
    let photoId: UUID
    var uploadOperation: UUID?
    var byteSize: Int?
    var jpegSHA256: String?
    var ready = false
    var jobId: UUID?
    var jobOperation: UUID?
    var flowId: UUID?
    var succeeded = false
    var selectedTaxon: UUID?
    var draftId: UUID?
    var claimId: UUID?
    var destination: UUID?
    var plantId: UUID?
    var receipts: [String: Receipt] = [:]
    var requests: [String: Int] = [:]
}

struct CataloguePhotoFixtureProof: Sendable {
    let namespace: String
    let sourceOwner: UUID
    let state: CataloguePhotoFixtureState?
    let providerAttempts: Int
    let providerFailures: Int
}

struct CataloguePhotoValidationProof: Sendable, Equatable {
    let namespace: String
    let requestId: UUID
    let owner: UUID
    let taxon: UUID
    let locale: String
    var arrivals = 0
    var cancellations = 0
    var releases = 0
}

/// One held reply, owned by one server and one URLProtocol instance, never a global queue.
fileprivate final class CataloguePhotoValidationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CataloguePhotoValidationProof
    private var callback: (@Sendable () -> Void)?
    init(_ value: CataloguePhotoValidationProof) { self.value = value }
    var proof: CataloguePhotoValidationProof { lock.withLock { value } }
    var finished: Bool { lock.withLock { value.cancellations + value.releases > 0 } }

    func take(_ request: URLRequest) -> Bool {
        lock.withLock {
            guard value.arrivals == 0, value.cancellations == 0,
                  request.httpMethod == "GET", request.httpBody?.isEmpty != false,
                  request.url?.absoluteString == "https://" + value.namespace
                    + ".invalid/functions/v1/plants-api/catalogue/" + value.taxon.uuidString.lowercased(),
                  request.value(forHTTPHeaderField: "X-Client-Locale") == value.locale,
                  request.value(forHTTPHeaderField: "Authorization") == nil,
                  request.value(forHTTPHeaderField: "X-Installation-Credential") == nil else { return false }
            value.arrivals = 1
            return true
        }
    }

    func attach(_ delivery: @escaping @Sendable () -> Void) {
        let immediate = lock.withLock {
            guard value.cancellations == 0 else { return false }
            if value.releases == 1 { return true }
            callback = delivery
            return false
        }
        if immediate { delivery() }
    }

    func release() {
        // Detach under lock; URLProtocol serializes client delivery with stopLoading.
        let delivery = lock.withLock { () -> (@Sendable () -> Void)? in
            guard value.cancellations == 0, value.releases == 0 else { return nil }
            value.releases = 1
            let pending = callback
            callback = nil
            return pending
        }
        delivery?()
    }

    func cancel() {
        lock.withLock {
            guard value.cancellations == 0, value.releases == 0 else { return }
            value.cancellations = 1
            callback = nil
        }
    }
}

extension CatalogueUIFixtureContext {
    var testsPhotoIdentification: Bool { server.snapshot.scenario.testsPhotoIdentification }

    var photoInstallationCredential: String {
        get throws {
            guard testsPhotoIdentification else { throw CatalogueUIFixtureError.invalidRequest }
            return server.photoCredential
        }
    }

    /// Synthetic input for the real model.selectPhotoData path, separate from public C2 PNG.
    var photoSelectionData: Data {
        get throws {
            guard testsPhotoIdentification else { throw CatalogueUIFixtureError.invalidRequest }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format)
            let image = renderer.image { context in
                UIColor(red: 0.15, green: 0.45, blue: 0.25, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
                UIColor.white.setFill()
                context.fill(CGRect(x: 5, y: 3, width: 3, height: 17))
            }
            guard let data = image.jpegData(compressionQuality: 0.9) else {
                throw CatalogueUIFixtureError.invalidStorage
            }
            return data
        }
    }

    var photoProof: CataloguePhotoFixtureProof { server.photoProof }

    /// Call after picker preview, immediately before invoking Model validation.
    /// Public HTTP has no owner headers: the current local SDK epoch supplies the owner proof.
    func armPhotoValidation(
        taxonId: UUID, locale: SupportedLocale, requestId: UUID, expected: CatalogueSDKSnapshot
    ) throws {
        guard testsPhotoIdentification, let connection, connection.snapshot == expected,
              expected.isAnonymous, expected.session.userId == server.snapshot.guest else {
            throw CatalogueUIFixtureError.invalidRequest
        }
        try server.armPhotoValidation(taxon: taxonId, locale: locale.rawValue,
                                      requestId: requestId, owner: expected.session.userId)
    }

    func photoValidationProof(requestId: UUID) throws -> CataloguePhotoValidationProof {
        try server.photoValidationProof(requestId: requestId)
    }

    func releasePhotoValidation(requestId: UUID) throws {
        try server.releasePhotoValidation(requestId: requestId)
    }
}

extension CatalogueFixtureServer {
    fileprivate var photoCredential: String { "fixture-photo-" + namespace }
    private var privatePhotoFile: URL {
        file.deletingLastPathComponent().appendingPathComponent("private-original-upload.jpg")
    }

    var photoProof: CataloguePhotoFixtureProof {
        lock.withLock {
            CataloguePhotoFixtureProof(namespace: namespace, sourceOwner: ledger.guest,
                                       state: ledger.photo,
                                       providerAttempts: ledger.authProof?.providerAttempts ?? 0,
                                       providerFailures: ledger.authProof?.providerFailures ?? 0)
        }
    }

    fileprivate func armPhotoValidation(taxon: UUID, locale: String, requestId: UUID, owner: UUID) throws {
        try lock.withLock {
            let path = "/functions/v1/plants-api/catalogue/" + taxon.uuidString.lowercased()
            guard ledger.scenario.testsPhotoIdentification, owner == ledger.guest,
                  ledger.photo?.succeeded == true, ["en", "pl"].contains(locale),
                  [CataloguePhotoFixture.originalTaxon, CataloguePhotoFixture.correctedTaxon].contains(taxon),
                  photoValidation == nil || photoValidation?.finished == true,
                  photoValidation?.proof.requestId != requestId,
                  capturedRequests.contains(where: {
                      $0.httpMethod == "GET" && $0.url?.path == path && $0.url?.query == nil
                          && $0.value(forHTTPHeaderField: "X-Client-Locale") == locale
                  }) else { throw CatalogueUIFixtureError.invalidRequest }
            photoValidation = CataloguePhotoValidationToken(.init(
                namespace: namespace, requestId: requestId, owner: owner, taxon: taxon, locale: locale))
        }
    }

    fileprivate func validationToken(requestId: UUID) throws -> CataloguePhotoValidationToken {
        try lock.withLock {
            guard let token = photoValidation, token.proof.requestId == requestId else {
                throw CatalogueUIFixtureError.invalidRequest
            }
            return token
        }
    }

    fileprivate func photoValidationProof(requestId: UUID) throws -> CataloguePhotoValidationProof {
        try validationToken(requestId: requestId).proof
    }

    fileprivate func releasePhotoValidation(requestId: UUID) throws {
        let token = try validationToken(requestId: requestId)
        guard token.proof.arrivals == 1 else { throw CatalogueUIFixtureError.invalidRequest }
        token.release()
    }

    fileprivate func cancelPhotoValidation() {
        let token = lock.withLock { photoValidation }
        token?.cancel()
    }

    fileprivate func takePhotoValidation(_ request: URLRequest) -> CataloguePhotoValidationToken? {
        lock.withLock {
            guard let token = photoValidation, token.take(request) else { return nil }
            return token
        }
    }

    // Called under handle's existing lock; no network, second server, copied service or fake UI.
    private func photoRoute(_ request: URLRequest) throws -> Reply? {
        guard let url = request.url else { throw CatalogueUIFixtureError.invalidRequest }
        let root = "/functions/v1/plants-api/"
        guard url.path.hasPrefix(root) else { return nil }
        let route = String(url.path.dropFirst(root.count))
        let posts = ["media/upload-ticket", "analysis/jobs", "installations/register",
                     "installations/bind", "drafts", "claims/prepare", "claims/commit"]
        let privatePhoto = route.hasPrefix("plants/") && route.hasSuffix("/photo")
        guard posts.contains(route) || route.hasPrefix("media/uploads/")
                || route.hasPrefix("analysis/jobs/") || privatePhoto || route == "analysis/access" else { return nil }
        guard url.query == nil, let caller = try? owner(request) else { return try error(403, "FORBIDDEN") }
        let body = request.httpBody ?? Data()
        if privatePhoto {
            guard request.httpMethod == "GET", body.isEmpty,
                  request.value(forHTTPHeaderField: "X-Installation-Credential") == nil,
                  let state = ledger.photo, state.destination == caller, state.ready,
                  let id = state.plantId, route == "plants/" + id.uuidString.lowercased() + "/photo",
                  ledger.plants.contains(where: { $0.id == id && $0.owner == caller }) else {
                return try error(404, "NOT_FOUND")
            }
            let original = try Data(contentsOf: privatePhotoFile)
            guard original.count == state.byteSize,
                  CataloguePhotoFixture.digest(original) == state.jpegSHA256 else {
                throw CatalogueUIFixtureError.invalidStorage
            }
            return Reply(status: 200, data: original, contentType: "image/jpeg")
        }
        guard request.value(forHTTPHeaderField: "X-Installation-Credential") == photoCredential,
              ["en", "pl"].contains(request.value(forHTTPHeaderField: "X-Client-Locale") ?? "") else {
            return try error(403, "FORBIDDEN")
        }
        // B2_PHOTO_ACCESS_BEGIN
        if route == "analysis/access" {
            guard request.httpMethod == "GET", body.isEmpty,
                  caller == ledger.guest, let state = ledger.photo else {
                return try error(403, "FORBIDDEN")
            }
            let null = NSNull()
            let remaining = state.succeeded || state.jobId != nil ? 0 : 1
            let pointer: Any = state.succeeded ? null : (state.jobId.map { $0.uuidString as Any } ?? null)
            let reason: Any = state.succeeded ? "starter_exhausted" as Any
                : state.jobId != nil ? "starter_in_progress" as Any : null
            return Reply(status: 200, data: try json([
                "owner_id": caller.uuidString, "is_guest": true,
                "starter": [
                    "identification_remaining": remaining, "diagnosis_remaining": 1,
                    "identification_in_progress_job_id": pointer,
                    "diagnosis_in_progress_job_id": null,
                    "first_starter_success_at": state.succeeded ? Self.time(ledger.tick) as Any : null
                ],
                "monthly": [
                    "quota_kind": null, "registered_at": null, "period_start": null,
                    "period_end": null, "limit": null, "consumed": null, "reserved": null,
                    "remaining": null, "status": "not_applicable"
                ],
                "modes": [
                    "identification": [
                        "mode": "identification", "allowed": remaining == 1,
                        "activeQuotaKind": "starter_identification", "remaining": remaining,
                        "limit": 1, "inProgressJobId": pointer, "nextResetAt": null, "reason": reason
                    ],
                    "diagnosis": [
                        "mode": "diagnosis", "allowed": true,
                        "activeQuotaKind": "starter_diagnosis", "remaining": 1,
                        "limit": 1, "inProgressJobId": null, "nextResetAt": null, "reason": null
                    ]
                ]
            ]))
        }
        // B2_PHOTO_ACCESS_END
        var state = ledger.photo ?? CataloguePhotoFixtureState(installationId: UUID(), photoId: UUID())
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let canonical = try json(object)
        let bodyHash = CataloguePhotoFixture.digest(canonical)
        func id(_ key: String) -> UUID? { (object[key] as? String).flatMap(UUID.init(uuidString:)) }
        func keys(_ expected: [String]) -> Bool { Set(object.keys) == Set(expected) }
        func finish(_ status: Int, _ payload: [String: Any], operation: UUID? = nil) throws -> Reply {
            let data = try json(payload)
            state.requests[route, default: 0] += 1
            if let operation {
                state.receipts[operation.uuidString] = .init(
                    route: route, owner: caller, bodySHA256: bodyHash, status: status, data: data)
            }
            var next = ledger
            next.photo = state
            try persist(next)
            return Reply(status: status, data: data)
        }
        func replay(_ operation: UUID) throws -> Reply? {
            guard let receipt = state.receipts[operation.uuidString] else { return nil }
            guard receipt.route == route, receipt.owner == caller, receipt.bodySHA256 == bodyHash else {
                return try error(409, "CONFLICT")
            }
            state.requests[route, default: 0] += 1
            var next = ledger
            next.photo = state
            try persist(next)
            return Reply(status: receipt.status, data: receipt.data)
        }
        func jobPayload(completed: Bool) -> [String: Any] {
            let unknown = ledger.scenario == .photoIdentificationUnknown
            let result: [String: Any] = [
                "schema_version": "1.0", "job_id": state.jobId!.uuidString,
                "mode": "identification", "catalogue_release_id": CataloguePhotoFixture.release.uuidString,
                "identification_status": unknown ? "unknown" : "identified",
                "plant_id": unknown ? NSNull() : CataloguePhotoFixture.originalTaxon.uuidString as Any,
                "plant_display_name": unknown ? NSNull()
                    : CataloguePhotoFixture.name(CataloguePhotoFixture.originalTaxon,
                                                 locale: request.value(forHTTPHeaderField: "X-Client-Locale")!) as Any
            ]
            return [
                "job_id": state.jobId!.uuidString, "mode": "identification",
                "status": completed ? "succeeded" : "queued", "quota_kind": "starter_identification",
                "quota_state": completed ? "consumed" : "reserved", "target_plant_id": NSNull(),
                "photo_asset_id": state.photoId.uuidString, "result": completed ? result as Any : NSNull(),
                "error_code": NSNull(), "error_message": NSNull()
            ]
        }
        if route.hasPrefix("media/uploads/") {
            guard request.httpMethod == "PUT", caller == ledger.guest, ledger.photo != nil,
                  route == "media/uploads/" + state.photoId.uuidString.lowercased(),
                  state.uploadOperation != nil, request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg",
                  body.count == state.byteSize, CataloguePhotoFixture.digest(body) == state.jpegSHA256,
                  body.starts(with: [0xff, 0xd8]), body.suffix(2) == Data([0xff, 0xd9]),
                  body.count <= AnalysisPhotoInput.maxCloudBytes else { return try error(409, "CONFLICT") }
            try body.write(to: privatePhotoFile, options: .atomic)
            state.ready = true
            return try finish(200, ["photo_asset_id": state.photoId.uuidString, "state": "ready"])
        }
        if route.hasPrefix("analysis/jobs/") {
            guard request.httpMethod == "GET", caller == ledger.guest, body.isEmpty, state.ready,
                  let job = state.jobId, route == "analysis/jobs/" + job.uuidString.lowercased() else {
                return try error(404, "NOT_FOUND")
            }
            state.succeeded = true
            return try finish(200, jobPayload(completed: true))
        }
        guard request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true,
              (try? JSONSerialization.jsonObject(with: body)) is [String: Any] else {
            return try error(400, "VALIDATION_ERROR")
        }
        if route == "installations/register" {
            guard caller == ledger.guest, keys([]) else { return try error(403, "FORBIDDEN") }
            return try finish(200, ["installation_id": state.installationId.uuidString])
        }
        guard ledger.photo != nil else { return try error(403, "FORBIDDEN") }
        if route == "installations/bind" {
            guard caller == ledger.permanent, keys(["installation_id"]),
                  id("installation_id") == state.installationId,
                  state.destination == nil || state.destination == caller else { return try error(403, "FORBIDDEN") }
            state.destination = caller
            return try finish(200, ["installation_id": state.installationId.uuidString,
                                    "owner_id": caller.uuidString, "bound": true])
        }
        guard let operation = id("operation_id") else { return try error(400, "VALIDATION_ERROR") }
        switch route {
        case "media/upload-ticket":
            guard caller == ledger.guest, keys(["operation_id", "mime_type", "byte_size", "content_sha256"]),
                  object["mime_type"] as? String == "image/jpeg",
                  let number = object["byte_size"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let size = object["byte_size"] as? Int, (1...AnalysisPhotoInput.maxCloudBytes).contains(size),
                  let sha = object["content_sha256"] as? String, sha.count == 64,
                  sha.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                return try error(400, "VALIDATION_ERROR")
            }
            if let reply = try replay(operation) { return reply }
            guard state.uploadOperation == nil else { return try error(409, "CONFLICT") }
            state.uploadOperation = operation
            state.byteSize = size
            state.jpegSHA256 = sha
            return try finish(200, [
                "photo_asset_id": state.photoId.uuidString, "storage_bucket": "fixture-private",
                "storage_path": namespace + "/" + state.photoId.uuidString.lowercased() + ".jpg",
                "signed_upload_url": "https://" + namespace + ".invalid" + root
                    + "media/uploads/" + state.photoId.uuidString.lowercased(),
                "expires_in_seconds": 60, "max_byte_size": AnalysisPhotoInput.maxCloudBytes
            ], operation: operation)
        case "analysis/jobs":
            guard caller == ledger.guest, keys(["operation_id", "mode", "photo_asset_id", "flow_id"]),
                  object["mode"] as? String == "identification", id("photo_asset_id") == state.photoId,
                  let flow = id("flow_id"), state.ready else { return try error(400, "VALIDATION_ERROR") }
            if let reply = try replay(operation) { return reply }
            guard state.jobId == nil else { return try error(409, "CONFLICT") }
            state.jobOperation = operation
            state.flowId = flow
            state.jobId = UUID()
            return try finish(202, jobPayload(completed: false), operation: operation)
        case "drafts":
            guard caller == ledger.guest, keys(["operation_id", "identification_job_id", "taxon_id"]),
                  id("identification_job_id") == state.jobId, state.succeeded, state.ready,
                  id("taxon_id") == CataloguePhotoFixture.correctedTaxon else {
                return try error(400, "VALIDATION_ERROR")
            }
            if let reply = try replay(operation) { return reply }
            guard state.draftId == nil else { return try error(409, "CONFLICT") }
            state.selectedTaxon = CataloguePhotoFixture.correctedTaxon
            state.draftId = UUID()
            return try finish(201, ["draft_id": state.draftId!.uuidString,
                                    "expires_at": CataloguePhotoFixture.expiry], operation: operation)
        case "claims/prepare":
            guard caller == ledger.permanent, state.destination == caller,
                  keys(["operation_id", "draft_id"]), let draft = state.draftId,
                  id("draft_id") == draft, state.succeeded, state.ready else { return try error(403, "FORBIDDEN") }
            if let reply = try replay(operation) { return reply }
            guard state.claimId == nil else { return try error(409, "CONFLICT") }
            state.claimId = UUID()
            return try finish(200, ["claim_id": state.claimId!.uuidString, "draft_id": draft.uuidString,
                                    "proof_expires_at": CataloguePhotoFixture.expiry], operation: operation)
        case "claims/commit":
            guard caller == ledger.permanent, state.destination == caller,
                  keys(["operation_id", "claim_id"]), let claim = state.claimId,
                  id("claim_id") == claim, state.ready, state.succeeded,
                  state.selectedTaxon == CataloguePhotoFixture.correctedTaxon else { return try error(403, "FORBIDDEN") }
            if let reply = try replay(operation) { return reply }
            guard state.plantId == nil, ledger.plants.filter({ $0.owner == caller }).count < 3 else {
                return try error(409, "CONFLICT")
            }
            let original = try Data(contentsOf: privatePhotoFile)
            guard original.count == state.byteSize,
                  CataloguePhotoFixture.digest(original) == state.jpegSHA256 else {
                throw CatalogueUIFixtureError.invalidStorage
            }
            let plant = UUID()
            state.plantId = plant
            // Persist canonical inventory and the idempotent receipt in ONE ledger transaction.
            var next = ledger
            next.tick += 1
            next.plants.append(Plant(owner: caller, id: plant, species: "fixture_palm", name: CataloguePhotoFixture.name(CataloguePhotoFixture.correctedTaxon, locale: "en"),
                                     timestamp: Self.time(next.tick)))
            let payload = ["plant_id": plant.uuidString, "photo_id": state.photoId.uuidString]
            let data = try json(payload)
            state.requests[route, default: 0] += 1
            state.receipts[operation.uuidString] = .init(
                route: route, owner: caller, bodySHA256: bodyHash, status: 200, data: data)
            next.photo = state
            try persist(next)
            return Reply(status: 200, data: data)
        default:
            return try error(404, "NOT_FOUND")
        }
    }
}

// C2 fixtures use a separate public transport. These values contain no session data.
enum CataloguePublishedFixture {
    static let taxon = UUID(uuidString: "32e72c49-4e06-434a-86dd-bbf8a5cb209e")!
    static let job = UUID(uuidString: "6e816a9e-f658-44cb-803e-535aaf87e019")!
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAHElEQVR4nGNQWODw/0ODwH9cNAM+SRDNMCxMAAAEvo/B6J5EcQAAAABJRU5ErkJggg==")!
    static let author = "Narat Fixture Studio"
    static let license = "CC0-1.0"
    static let attribution = "Deterministic fern colour study"
    static let sourcePage = "https://catalogue-media.fixture.invalid/sources/fern"
    static let pngSHA256 = "86c56b330ed7a9d3659270bbaaff8906aa19837c0d8f21097c91c368234b3671"

    static func imageURL(namespace: String, filename: String = "fern.png") -> URL {
        URL(string: "https://catalogue-media.fixture.invalid/media/" + namespace + "/" + filename)!
    }

    static func envelopeHash(_ envelope: CommandEnvelopeDTO) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(envelope)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CataloguePublishedMediaLedger: Codable, Sendable {
    struct Request: Codable, Sendable {
        let path: String
        let accepted: Bool
        let authorizationPresent: Bool
        let installationPresent: Bool
        let namespaceHeaderPresent: Bool
        let cookiePresent: Bool
    }
    let namespace: String
    let scenario: CatalogueUIFixtureScenario
    let author: String
    let license: String
    let attribution: String
    let sourcePage: String
    let pngSHA256: String
    let width: Int
    let height: Int
    var listGETs = 0
    var detailGETs = 0
    var requests: [Request] = []
}

struct CataloguePublishedResumeProof: Codable {
    struct Identity: Codable, Equatable {
        let owner: UUID
        let flow: UUID
        let operation: UUID
        let job: UUID
        let taxon: UUID
        let name: String
        let envelopeSHA256: String

        @MainActor init(_ model: CatalogueSaveModel) throws {
            guard let checkpoint = model.checkpoint, let input = model.input,
                  let identification = input.identification, let name = input.personalName else {
                throw CatalogueUIFixtureError.invalidStorage
            }
            owner = checkpoint.ownerId; flow = checkpoint.flowId
            operation = checkpoint.operationId; job = identification.jobId
            taxon = identification.taxonId; self.name = name
            envelopeSHA256 = try CataloguePublishedFixture.envelopeHash(checkpoint.envelope)
        }
    }
    let namespace: String
    let original: Identity
    let current: Identity
    let checkpointCount: Int
    let commandAttempts: Int
    let newCommits: Int
    let plantCount: Int
}

extension CatalogueUIFixtureContext {
    fileprivate func preparePublishedFixture(isNewResume: Bool) async throws {
        try server.preparePublishedMedia()
        let type = try CatalogueScopedMediaProtocol.scopes.reserve(server)
        mediaProtocol = type
        let configuration = PublishedPlantImageLoader.publicConfiguration()
        configuration.protocolClasses = [type]
        let session = URLSession(configuration: configuration)
        mediaHTTP = session
        connection.publicMediaLoader = PublishedPlantImageLoader(session: session)
        guard server.snapshot.scenario == .publishedIdentificationResume else { return }
        let expected = try await connection.sessionSnapshot()
        let proofURL = directory.appendingPathComponent("c2-resume-proof.json")
        let original: CataloguePublishedResumeProof.Identity
        let restored: CatalogueSaveModel
        if isNewResume {
            guard !FileManager.default.fileExists(atPath: proofURL.path),
                  try connection.resumableFlow(expected: expected) == nil else {
                throw CatalogueUIFixtureError.invalidStorage
            }
            let model = try await connection.makeModel(
                input: CatalogueInput(identification: .init(
                    jobId: CataloguePublishedFixture.job, taxonId: CataloguePublishedFixture.taxon
                ), personalName: "Luna"),
                flowId: UUID(), operationId: UUID(), expected: expected
            )
            _ = try await connection.rememberModel(model, expected: expected)
            restored = model
            original = try CataloguePublishedResumeProof.Identity(model)
        } else {
            // An existing namespace must restore its actual SQLite checkpoint, never reseed.
            let proof = try JSONDecoder().decode(CataloguePublishedResumeProof.self, from: Data(contentsOf: proofURL))
            guard proof.namespace == namespace,
                  try connection.resumableFlow(expected: expected) == proof.original.flow else {
                throw CatalogueUIFixtureError.invalidStorage
            }
            let result = await connection.restoreModel(
                ownerId: expected.session.userId, flowId: proof.original.flow, expected: expected
            )
            guard case let .restored(model) = result else { throw CatalogueUIFixtureError.invalidStorage }
            restored = model
            original = proof.original
        }
        let current = try CataloguePublishedResumeProof.Identity(restored)
        guard current == original, let store = connection.store else {
            throw CatalogueUIFixtureError.invalidStorage
        }
        let disk = ModelContext(store.modelContainer)
        let count = try disk.fetchCount(FetchDescriptor<CatalogueInputCheckpointRecord>())
        guard count == 1 else { throw CatalogueUIFixtureError.invalidStorage }
        let ledger = server.snapshot
        let proof = CataloguePublishedResumeProof(
            namespace: namespace, original: original, current: current, checkpointCount: count,
            commandAttempts: ledger.attempts.count, newCommits: ledger.commits.count,
            plantCount: ledger.plants.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(proof).write(to: proofURL, options: .atomic)
    }
}

extension CatalogueFixtureServer {
    private var publishedMediaFile: URL {
        file.deletingLastPathComponent().appendingPathComponent("media-ledger.json")
    }

    var publishedMediaLedger: CataloguePublishedMediaLedger {
        get throws {
            try lock.withLock {
                try JSONDecoder().decode(CataloguePublishedMediaLedger.self, from: Data(contentsOf: publishedMediaFile))
            }
        }
    }

    fileprivate func preparePublishedMedia() throws {
        try lock.withLock {
            if FileManager.default.fileExists(atPath: publishedMediaFile.path) {
                let old = try JSONDecoder().decode(CataloguePublishedMediaLedger.self, from: Data(contentsOf: publishedMediaFile))
                guard old.namespace == namespace, old.scenario == ledger.scenario else {
                    throw CatalogueUIFixtureError.scenarioMismatch
                }
                return
            }
            let value = CataloguePublishedMediaLedger(
                namespace: namespace, scenario: ledger.scenario,
                author: CataloguePublishedFixture.author, license: CataloguePublishedFixture.license,
                attribution: CataloguePublishedFixture.attribution, sourcePage: CataloguePublishedFixture.sourcePage,
                pngSHA256: CataloguePublishedFixture.pngSHA256, width: 8, height: 8
            )
            try JSONEncoder().encode(value).write(to: publishedMediaFile, options: .atomic)
        }
    }

    // Called only while handle owns the server lock. Ordinary scenarios never enter this branch.
    fileprivate func publishedCatalogue(_ request: URLRequest, locale: String) throws -> Reply {
        guard let url = request.url, request.httpMethod == "GET",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CatalogueUIFixtureError.invalidRequest
        }
        let root = "/functions/v1/plants-api/catalogue"
        let rows: [[String: Any]] = (0..<50).map { index in
            let photoMode = ledger.scenario.testsPhotoIdentification
            let slug = photoMode && index == 3 ? "fixture_palm"
                : (index == 0 ? "fixture_fern" : (index == 1 ? "fixture_missing" : (index == 2 ? "fixture_error" : String(format: "fixture_media_%03d", index))))
            let taxon = index == 0 ? CataloguePublishedFixture.taxon
                : UUID(uuidString: String(format: "a2000000-0000-4000-8000-%012d", index))!
            let name = index == 0 ? (locale == "pl" ? "Paproć" : "Fern")
                : (index == 1 ? (locale == "pl" ? "Bez zdjęcia" : "Missing photo")
                   : (index == 2 ? (locale == "pl" ? "Błąd zdjęcia" : "Failed photo") : "Fern \(index)"))
            let filename = index == 0 ? "fern.png" : (index == 2 ? "error.png" : String(format: "row-%03d.png", index))
            let photo: Any = index == 1 ? NSNull() : [
                "download_url": CataloguePublishedFixture.imageURL(namespace: namespace, filename: filename).absoluteString,
                "author": CataloguePublishedFixture.author, "license": CataloguePublishedFixture.license,
                "attribution": CataloguePublishedFixture.attribution, "source_page": CataloguePublishedFixture.sourcePage
            ]
            return [
                "plant_id": slug, "taxon_id": taxon.uuidString.lowercased(),
                "display_name": photoMode ? CataloguePhotoFixture.name(taxon, locale: locale) : name,
                "scientific_name": photoMode && index == 3 ? "Chamaedorea elegans"
                    : (index == 0 ? "Nephrolepis exaltata" : "Fixture taxon \(index)"),
                "description": NSNull(), "hero_image": photo, "care_profile_available": false
            ]
        }
        var media = try JSONDecoder().decode(CataloguePublishedMediaLedger.self, from: Data(contentsOf: publishedMediaFile))
        if url.path != root {
            guard components.queryItems == nil,
                  var row = rows.first(where: {
                      url.path == root + "/" + ($0["plant_id"] as! String)
                          || url.path == root + "/" + ($0["taxon_id"] as! String)
                  }) else { throw CatalogueUIFixtureError.invalidRequest }
            media.detailGETs += 1
            try JSONEncoder().encode(media).write(to: publishedMediaFile, options: .atomic)
            if ledger.scenario == .publishedIdentificationResume, media.detailGETs == 1 {
                return try error(503, "INTERNAL_ERROR", retryable: true)
            }
            if ledger.scenario.testsPhotoIdentification {
                row["description"] = ["text": CataloguePhotoFixture.description(locale: locale), "language": locale]
            }
            return Reply(status: 200, data: try json(row))
        }
        let query = components.queryItems ?? []
        guard query.map(\.name) == ["q", "limit", "offset"],
              let term = query[0].value, let limit = query[1].value.flatMap(Int.init),
              let offset = query[2].value.flatMap(Int.init), (1...200).contains(limit), offset >= 0 else {
            throw CatalogueUIFixtureError.invalidRequest
        }
        let matches = rows.filter {
            term.isEmpty || ($0["display_name"] as! String).localizedStandardContains(term)
                || ($0["scientific_name"] as! String).localizedStandardContains(term)
        }
        media.listGETs += 1
        try JSONEncoder().encode(media).write(to: publishedMediaFile, options: .atomic)
        return Reply(status: 200, data: try json([
            "release_version": "fixture", "kb_release_id": NSNull(), "locale": locale,
            "total": matches.count, "limit": limit, "offset": offset,
            "items": Array(matches.dropFirst(offset).prefix(limit))
        ]))
    }

    fileprivate func publishedMedia(_ request: URLRequest) throws -> Reply {
        try lock.withLock {
            let url = request.url
            let filename = url?.lastPathComponent ?? ""
            let allowed = filename == "fern.png" || filename == "error.png"
                || (3..<50).contains(where: { filename == String(format: "row-%03d.png", $0) })
            let valid = allowed && request.httpMethod == "GET"
                && url?.absoluteString == CataloguePublishedFixture.imageURL(namespace: namespace, filename: filename).absoluteString
            let capture = CataloguePublishedMediaLedger.Request(
                path: valid ? "/media/" + namespace + "/" + filename : "<rejected>", accepted: valid,
                authorizationPresent: request.value(forHTTPHeaderField: "Authorization") != nil,
                installationPresent: request.value(forHTTPHeaderField: "X-Installation-Credential") != nil,
                namespaceHeaderPresent: request.value(forHTTPHeaderField: "X-Catalogue-Fixture-Namespace") != nil,
                cookiePresent: request.value(forHTTPHeaderField: "Cookie") != nil
            )
            var media = try JSONDecoder().decode(CataloguePublishedMediaLedger.self, from: Data(contentsOf: publishedMediaFile))
            guard media.requests.count < 256 else { throw CatalogueUIFixtureError.invalidRequest }
            media.requests.append(capture)
            try JSONEncoder().encode(media).write(to: publishedMediaFile, options: .atomic)
            guard valid, !capture.authorizationPresent, !capture.installationPresent,
                  !capture.namespaceHeaderPresent, !capture.cookiePresent else { throw URLError(.unsupportedURL) }
            if filename == "error.png" { return Reply(status: 503, data: Data(), contentType: "image/png") }
            return Reply(status: 200, data: ledger.scenario.testsPhotoIdentification && filename == "row-003.png" ? CataloguePhotoFixture.correctedPNG : CataloguePublishedFixture.png, contentType: "image/png")
        }
    }
}

// A bounded class pool binds each session to ONE namespace, including when another context is active.
// Only configuration.protocolClasses is used; no process-wide URLProtocol registration.
private final class CatalogueMediaScopes: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [ObjectIdentifier: CatalogueFixtureServer] = [:]
    private let types: [CatalogueScopedMediaProtocol.Type] = [
        CatalogueMediaProtocolA.self, CatalogueMediaProtocolB.self,
        CatalogueMediaProtocolC.self, CatalogueMediaProtocolD.self
    ]
    func reserve(_ server: CatalogueFixtureServer) throws -> CatalogueScopedMediaProtocol.Type {
        try lock.withLock {
            guard let type = types.first(where: { servers[ObjectIdentifier($0)] == nil }) else {
                throw CatalogueUIFixtureError.namespaceInUse
            }
            servers[ObjectIdentifier(type)] = server
            return type
        }
    }
    func get(_ type: CatalogueScopedMediaProtocol.Type) -> CatalogueFixtureServer? {
        lock.withLock { servers[ObjectIdentifier(type)] }
    }
    func release(_ type: CatalogueScopedMediaProtocol.Type, server: CatalogueFixtureServer) {
        lock.withLock {
            if servers[ObjectIdentifier(type)] === server { servers[ObjectIdentifier(type)] = nil }
        }
    }
}

private class CatalogueScopedMediaProtocol: URLProtocol, @unchecked Sendable {
    static let scopes = CatalogueMediaScopes()
    static func release(_ type: CatalogueScopedMediaProtocol.Type, server: CatalogueFixtureServer) {
        scopes.release(type, server: server)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let server = Self.scopes.get(type(of: self)), let url = request.url else {
                throw URLError(.unsupportedURL)
            }
            let reply = try server.publishedMedia(request)
            guard let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: nil,
                headerFields: ["Content-Type": reply.contentType, "Cache-Control": "no-store"]
            ) else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class CatalogueMediaProtocolA: CatalogueScopedMediaProtocol, @unchecked Sendable {}
private final class CatalogueMediaProtocolB: CatalogueScopedMediaProtocol, @unchecked Sendable {}
private final class CatalogueMediaProtocolC: CatalogueScopedMediaProtocol, @unchecked Sendable {}
private final class CatalogueMediaProtocolD: CatalogueScopedMediaProtocol, @unchecked Sendable {}
#endif
