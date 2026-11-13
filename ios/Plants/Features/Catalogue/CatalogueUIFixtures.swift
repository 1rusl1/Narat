#if DEBUG
import Foundation
import Supabase
import SwiftData
import UIKit

enum CatalogueUIFixtureScenario: String, Codable, Sendable {
    case free2, paid4, cap3, server409, server503, lostresponse
    case guestProviderCancel, guestProviderSuccess, ackFailure
    case firstAidControl, trialReminder, plantDeletion, photoHistory, analysisHistory, plantRename

    var startsAnonymous: Bool {
        self == .guestProviderCancel || self == .guestProviderSuccess
    }
    var initialCount: Int { self == .paid4 ? 4 : (self == .cap3 ? 3 : 2) }
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
        namespace: String, scenario: CatalogueUIFixtureScenario
    ) async throws -> CatalogueUIFixtureContext {
        let directory = try directory(namespace: namespace)
        let name = UUID(uuidString: namespace)!.uuidString.lowercased()
        guard !CatalogueFixtureProtocol.registry.contains(name) else {
            throw CatalogueUIFixtureError.namespaceInUse
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let server = try CatalogueFixtureServer(directory: directory, namespace: name, scenario: scenario)
        let schema = Schema([
            LocalOutboxRecord.self, CatalogueCreateConfirmationRecord.self,
            CatalogueInputCheckpointRecord.self, GuestDraftCacheRecord.self,
            SyncedEntityRecord.self, SyncCheckpointRecord.self
        ])
        let database = directory.appendingPathComponent("catalogue.sqlite")
        let prepareACK = scenario == .ackFailure && !FileManager.default.fileExists(atPath: database.path)
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
        let configuration = try NativeAuthConfiguration(values: [
            "NaratSupabaseURL": "https://" + name + ".invalid",
            "NaratSupabasePublishableKey": "fixture-only-public-key"
        ])
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [CatalogueFixtureProtocol.self]
        options.httpAdditionalHeaders = ["X-Catalogue-Fixture-Namespace": name]
        options.urlCache = nil
        options.httpCookieStorage = nil
        let http = URLSession(configuration: options)
        try CatalogueFixtureProtocol.registry.insert(server, name: name)
        let client = SupabaseClient(
            supabaseURL: configuration.supabaseURL,
            supabaseKey: configuration.supabasePublishableKey,
            options: .init(
                auth: .init(
                    storage: CatalogueFixtureAuthStorage(directory: directory, server: server),
                    storageKey: "catalogue-fixture-session", autoRefreshToken: false,
                    emitLocalSessionAsInitialSession: true
                ),
                global: .init(session: http)
            )
        )
        let identity = CatalogueFixtureIdentity(cancel: scenario == .guestProviderCancel)
        func connect(_ storage: ModelContainer) -> CatalogueConnection {
            CatalogueConnection(
                client: client, configuration: configuration,
                store: LocalStore(modelContainer: storage),
                transport: URLSessionAPITransport(session: http),
                identityProvider: identity, resumeDefaults: defaults
            )
        }
        let connection = connect(storage)
        let context = CatalogueUIFixtureContext(
            namespace: name, directory: directory, suite: suite, connection: connection,
            http: http, server: server, identity: identity
        )
        do {
            // Reuse the SDK's file-backed session; never manufacture a model session.
            if client.auth.currentSession == nil && !scenario.startsAnonymous {
                _ = try await client.auth.signIn(
                    email: "fixture@" + name + ".invalid", password: "fixture-only-password"
                )
            }
            _ = try await connection.sessionOwner()
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

    fileprivate init(
        namespace: String, directory: URL, suite: String, connection: CatalogueConnection,
        http: URLSession, server: CatalogueFixtureServer, identity: CatalogueFixtureIdentity
    ) {
        self.namespace = namespace; self.directory = directory; self.suite = suite
        self.connection = connection; self.http = http; self.server = server; self.identity = identity
    }

    /// Releases the connection without erasing SDK state, SQLite, receipts or scenario flags.
    func shutdown() {
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
    }
    struct Reply {
        let status: Int
        let data: Data
        var contentType = "application/json"
    }
    private let lock = NSLock()
    private let file: URL
    let namespace: String
    private var ledger: Ledger
    var snapshot: Ledger { lock.withLock { ledger } }

    fileprivate init(directory: URL, namespace: String, scenario: CatalogueUIFixtureScenario) throws {
        self.namespace = namespace
        file = directory.appendingPathComponent("server-ledger.json")
        if FileManager.default.fileExists(atPath: file.path) {
            ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: file))
            guard ledger.scenario == scenario else { throw CatalogueUIFixtureError.scenarioMismatch }
        } else {
            let owner = UUID()
            ledger = Ledger(scenario: scenario, guest: UUID(), permanent: owner, plants: [])
            ledger.plants = (0..<scenario.initialCount).map { index in
                Plant(owner: owner, id: UUID(), species: "fixture_fern", name: "Fixture \(index + 1)",
                      timestamp: Self.time(0))
            }
            try JSONEncoder().encode(ledger).write(to: file, options: .atomic)
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
    private func token(_ owner: UUID) -> String { "fixture-only-" + namespace + "-" + owner.uuidString.lowercased() }
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
            let body = request.httpBody ?? Data()
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let method = request.httpMethod ?? "GET"
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
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
                case "id_token":
                    guard object["id_token"] as? String == "fixture-only-identity",
                          ["apple", "google"].contains(object["provider"] as? String ?? ""),
                          object["nonce"] as? String == "fixture-only-nonce" else {
                        throw CatalogueUIFixtureError.invalidRequest
                    }
                    owner = ledger.permanent
                case "refresh_token":
                    guard let match = [ledger.guest, ledger.permanent].first(where: {
                        object["refresh_token"] as? String == "refresh-" + token($0) && !ledger.revoked.contains($0)
                    }) else { throw CatalogueUIFixtureError.invalidRequest }
                    owner = match
                default: throw CatalogueUIFixtureError.invalidRequest
                }
                var next = ledger; next.revoked.remove(owner); try persist(next)
                return try session(owner)
            }
            if method == "GET", url.path.hasPrefix("/functions/v1/plants-api/catalogue") {
                let path = "/functions/v1/plants-api/catalogue"
                guard request.value(forHTTPHeaderField: "Authorization") == nil,
                      request.value(forHTTPHeaderField: "X-Installation-Credential") == nil,
                      let locale = request.value(forHTTPHeaderField: "X-Client-Locale"),
                      ["pl", "en"].contains(locale) else { throw CatalogueUIFixtureError.invalidRequest }
                let taxon = "32e72c49-4e06-434a-86dd-bbf8a5cb209e"
                let fern: [String: Any] = [
                    "plant_id": "fixture_fern", "taxon_id": taxon,
                    "display_name": locale == "pl" ? "Paproć" : "Fern",
                    "scientific_name": "Nephrolepis exaltata", "description": NSNull(),
                    "hero_image": NSNull(), "care_profile_available": false
                ]
                if [path + "/fixture_fern", path + "/" + taxon].contains(url.path), query.isEmpty {
                    return Reply(status: 200, data: try json(fern))
                }
                guard url.path == path, query.map(\.name) == ["q", "limit", "offset"],
                      let term = query[0].value, let limit = query[1].value.flatMap(Int.init),
                      let offset = query[2].value.flatMap(Int.init), (1...200).contains(limit), offset >= 0 else {
                    throw CatalogueUIFixtureError.invalidRequest
                }
                let matches = term.isEmpty || ["Fern", "Paproć", "Nephrolepis exaltata"].contains {
                    $0.localizedStandardContains(term)
                }
                return Reply(status: 200, data: try json([
                    "release_version": "fixture", "kb_release_id": NSNull(), "locale": locale,
                    "total": matches ? 1 : 0, "limit": limit, "offset": offset,
                    "items": matches && offset == 0 ? [fern] : []
                ]))
            }
            let caller = try owner(request)
            if [.photoHistory, .plantRename].contains(ledger.scenario), method == "GET", url.lastPathComponent == "photo" {
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
               query.isEmpty || (query.count == 1 && query[0].name == "scope" && query[0].value == "global") {
                var next = ledger; next.revoked.insert(caller); try persist(next)
                return Reply(status: 204, data: Data())
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
                if [.analysisHistory, .plantRename].contains(ledger.scenario),
                   let plant = plants.first(where: { $0.id == ledger.plants.first?.id }),
                   let index = changes.firstIndex(where: { $0["id"] as? String == plant.id.uuidString }),
                   var data = changes[index]["data"] as? [String: Any] {
                    data["revision"] = ledger.scenario == .plantRename ? 4 + ledger.tick : 4
                    data["care_revision"] = 2
                    data["current_condition_snapshot_id"] = plant.id.uuidString
                    if ledger.scenario == .plantRename { data["main_photo_id"] = plant.id.uuidString }
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
                case .photoHistory:
                    entitlement = [
                        "product_id": "fixture-only-paid", "state": "expired", "offer_kind": "paid",
                        "valid_until": "2026-10-31T12:00:00Z", "grace_until": NSNull(),
                        "trial_end_at": NSNull(), "auto_renew_enabled": false
                    ] as [String: Any]
                default:
                    entitlement = NSNull()
                }
                let until = Self.time(ledger.tick)
                return Reply(status: 200, data: try json([
                    "until": until, "has_more": false, "last_cursor": NSNull(), "next_since": until,
                    "profile": ["preferred_locale": "pl", "reminder_hour_local": 9,
                                "report_notifications_enabled": true, "trial_reminder_enabled": false],
                    "entitlement": entitlement, "changes": firstAid + changes
                ]))
            }
            guard method == "POST", url.path == "/functions/v1/plants-api/commands", query.isEmpty,
                  caller == ledger.permanent else { throw CatalogueUIFixtureError.invalidRequest }
            let envelope = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: body)
            if ledger.scenario == .plantDeletion, envelope.commandName == "plant.delete" {
                return try deletePlant(envelope, body: body, caller: caller, header: request.value(forHTTPHeaderField: "X-Operation-Id"))
            }
            if ledger.scenario == .plantRename, let rename = PlantRenameCommand(envelope) {
                return try renamePlant(rename, body: body, caller: caller, header: request.value(forHTTPHeaderField: "X-Operation-Id"))
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

    private func renamePlant(_ rename: PlantRenameCommand, body: Data, caller: UUID, header: String?) throws -> Reply {
        let envelope = rename.envelope
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
        next.tick += 1
        let stamp = Self.time(next.tick)
        next.plants[0] = Plant(owner: caller, id: first.id, species: first.species, name: rename.personalName, timestamp: stamp)
        let receipt = try json(["plant_id": first.id.uuidString, "revision": 4 + next.tick, "care_revision": 2,
                                "condition_snapshot_id": first.id.uuidString, "watermark": stamp])
        next.commits[key] = Commit(owner: caller, envelope: envelope, body: body, receipt: receipt, plantID: first.id)
        try persist(next)
        throw URLError(.networkConnectionLost)
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
                    body.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = body
            }
            let reply = try server.handle(captured)
            guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                                headerFields: ["Content-Type": reply.contentType, "Cache-Control": "private, no-store"]) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
#endif
