import Foundation
import Observation
import XCTest
import SwiftData
import Supabase
import UIKit
@testable import Plants

private final class ConnectionAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { values[key] = nil } }
}

@MainActor
private final class ConnectionIdentityProvider: NativeIdentityProviding {
    var calls = 0
    var result: Result<NativeAuthCredentials, any Error> = .success(
        .init(provider: .apple, idToken: "FIXTURE-ONLY-ID-TOKEN", nonce: "fixture-nonce")
    )
    var onRequest: (() async throws -> Void)?

    func credentials(for provider: NativeAuthProvider, presenting: UIViewController) async throws -> NativeAuthCredentials {
        calls += 1
        try await onRequest?()
        return try result.get()
    }
}

/// Observe literal dotted owner-key writes synchronously on their MainActor caller.
@MainActor
private final class ConnectionDefaultsObserver {
    private var token: (any NSObjectProtocol)?

    init(defaults: UserDefaults, onChange: @escaping @MainActor () throws -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                do { try onChange() }
                catch { XCTFail("Defaults notification callback failed: \(error)") }
            }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

private final class ConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    func set(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = action } }
    func cancel() {
        let callback = lock.withLock { action }
        callback?()
    }
}

/// Only HTTP is scripted. Unknown URLs fail closed, including accidental live traffic.
private final class ConnectionHTTPFixture: @unchecked Sendable {
    struct Reply: Sendable {
        let method: String
        let path: String
        let data: Data
        var status = 200
        var suspend = false
        var query: String? = nil
        var failure: URLError.Code? = nil
    }
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var requests: [URLRequest] = []
    private var failures: [String] = []
    private var held: (@Sendable () -> Void)?

    func append(_ reply: Reply) { lock.withLock { replies.append(reply) } }
    var captured: [URLRequest] { lock.withLock { requests } }
    var unexpected: [String] { lock.withLock { failures } }
    var remaining: Int { lock.withLock { replies.count } }
    var suspended: Bool { lock.withLock { held != nil } }

    func accept(_ request: URLRequest, complete: @escaping @Sendable (Reply?) -> Void) {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        let reply: Reply? = lock.withLock {
            requests.append(captured)
            guard let index = replies.firstIndex(where: {
                $0.method == request.httpMethod && $0.path == request.url?.path &&
                $0.query == request.url?.query
            }) else {
                failures.append((request.httpMethod ?? "") + " " + (request.url?.path ?? ""))
                return nil
            }
            return replies.remove(at: index)
        }
        if let reply, reply.suspend {
            lock.withLock { held = { complete(reply) } }
        } else {
            complete(reply)
        }
    }

    func release() {
        let callback = lock.withLock { let value = held; held = nil; return value }
        callback?()
    }
}

private final class ConnectionFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: ConnectionHTTPFixture] = [:]
    func set(_ fixture: ConnectionHTTPFixture?, host: String) {
        lock.withLock { fixtures[host] = fixture }
    }
    func fixture(host: String) -> ConnectionHTTPFixture? { lock.withLock { fixtures[host] } }
}

private final class ConnectionURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ConnectionFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let fixture = Self.registry.fixture(host: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        fixture.accept(request) { [self] reply in
            if let failure = reply?.failure {
                client?.urlProtocol(self, didFailWithError: URLError(failure))
                return
            }
            guard let reply, let url = request.url,
                  let response = HTTPURLResponse(
                    url: url, statusCode: reply.status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private extension PlantsAPIClient {
    /// Deterministically hold a real actor hop while a factory keeps its original epoch.
    func holdConnectionTest(started: DispatchSemaphore, release: DispatchSemaphore) {
        started.signal()
        _ = release.wait(timeout: .now() + 5)
    }
}

@MainActor
private final class ConnectionCheckpointPublication {
    let metadataBefore: NSDictionary
    var fired = false
    var committed: CatalogueInputCheckpointSnapshot?
    var sdkWork: Task<Void, Error>?

    init(metadataBefore: NSDictionary) { self.metadataBefore = metadataBefore }
}

@MainActor
final class CatalogueConnectionTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let other = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let input = CatalogueInput(speciesSlug: "fixture-fern", personalName: " e\u{0301} ")

    @MainActor
    private final class Harness {
        let directory: URL
        let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
        let configuration: NativeAuthConfiguration
        let fixture: ConnectionHTTPFixture
        let http: URLSession
        let client: SupabaseClient
        let store: LocalStore
        let connection: CatalogueConnection
        let identity = ConnectionIdentityProvider()
        let defaultsSuite = "catalogue-native-tests." + UUID().uuidString
        let defaults: UserDefaults

        nonisolated static func container(_ url: URL, allowsSave: Bool = true) throws -> ModelContainer {
            let schema = Schema([
                LocalOutboxRecord.self, CatalogueCreateConfirmationRecord.self,
                CatalogueInputCheckpointRecord.self, GuestDraftCacheRecord.self,
                SyncedEntityRecord.self, SyncCheckpointRecord.self
            ])
            return try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url, allowsSave: allowsSave)
            ])
        }

        init(
            storedSession: Session? = nil, emitLocalSessionAsInitialSession: Bool = true,
            allowsSave: Bool = true, configuredGoogle: Bool = false,
            prepareFixture: (ConnectionHTTPFixture) throws -> Void = { _ in }
        ) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = [
                "NaratSupabaseURL": "https://" + UUID().uuidString.lowercased() + ".invalid",
                "NaratSupabasePublishableKey": "fixture-public-key"
            ]
            if configuredGoogle {
                values["GIDClientID"] = "fixture.apps.googleusercontent.com"
                configuration = try NativeAuthConfiguration(values: values, bundle: Self.googleBundle(in: directory))
            } else {
                configuration = try NativeAuthConfiguration(values: values)
            }
            fixture = ConnectionHTTPFixture()
            ConnectionURLProtocol.registry.set(fixture, host: configuration.supabaseURL.host!)
            try prepareFixture(fixture)
            let storage = ConnectionAuthStorage()
            let storageKey = UUID().uuidString
            if let storedSession {
                try storage.store(key: storageKey, value: JSONEncoder().encode(storedSession))
            }
            let options = URLSessionConfiguration.ephemeral
            options.protocolClasses = [ConnectionURLProtocol.self]
            http = URLSession(configuration: options)
            client = SupabaseClient(
                supabaseURL: configuration.supabaseURL,
                supabaseKey: configuration.supabasePublishableKey,
                options: .init(
                    auth: .init(
                        storage: storage, storageKey: storageKey,
                        autoRefreshToken: false,
                        emitLocalSessionAsInitialSession: emitLocalSessionAsInitialSession
                    ),
                    global: .init(session: http)
                )
            )
            let diskURL = directory.appendingPathComponent("connection.sqlite")
            if !allowsSave { _ = try Self.container(diskURL) }
            store = LocalStore(modelContainer: try Self.container(diskURL, allowsSave: allowsSave))
            defaults = UserDefaults(suiteName: defaultsSuite)!
            connection = CatalogueConnection(
                client: client, configuration: configuration, store: store,
                transport: URLSessionAPITransport(session: http),
                identityProvider: identity, resumeDefaults: defaults
            )
        }

        static func googleBundle(
            in directory: URL, callback: String? = "com.googleusercontent.apps.fixture"
        ) throws -> Bundle {
            let url = directory.appendingPathComponent(UUID().uuidString + ".bundle")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var plist: [String: Any] = [
                "CFBundleIdentifier": "invalid.fixture." + UUID().uuidString,
                "NaratSupabaseURL": "https://fixture.invalid",
                "NaratSupabasePublishableKey": "fixture-public-key",
                "GIDClientID": "fixture.apps.googleusercontent.com"
            ]
            if let callback {
                plist["CFBundleURLTypes"] = [["CFBundleURLSchemes": [callback]]]
            }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Info.plist"))
            return try XCTUnwrap(Bundle(url: url))
        }

        func close() {
            defaults.removePersistentDomain(forName: defaultsSuite)
            fixture.release()
            http.invalidateAndCancel()
            ConnectionURLProtocol.registry.set(nil, host: configuration.supabaseURL.host!)
            try? FileManager.default.removeItem(at: directory)
        }

        func ready() async { _ = try? await connection.sessionSnapshot() }

        func signIn() async throws {
            _ = try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: "FIXTURE-ONLY-ID-TOKEN")
            )
        }
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func auth(
        _ h: Harness, owner: UUID, token: String = "fixture-a", anonymous: Bool = false,
        signup: Bool = false, expired: Bool = false, suspend: Bool = false, refresh: Bool = false,
        grant: String = "id_token"
    ) throws {
        h.fixture.append(.init(
            method: "POST", path: signup ? "/auth/v1/signup" : "/auth/v1/token",
            data: try json([
                "access_token": token, "token_type": "bearer", "expires_in": expired ? -60 : 3600,
                "expires_at": h.expiresAt - (expired ? 3660 : 0),
                "refresh_token": "refresh-" + token,
                "user": [
                    "id": owner.uuidString, "aud": "authenticated", "role": "authenticated",
                    "app_metadata": [:], "user_metadata": [:], "is_anonymous": anonymous,
                    "created_at": "2026-11-01T00:00:00Z", "updated_at": "2026-11-01T00:00:00Z"
                ]
            ]), suspend: suspend,
            query: signup ? nil : (refresh ? "grant_type=refresh_token" : "grant_type=" + grant)
        ))
    }

    private func plants(
        _ h: Harness, suspendGET: Bool = false, suspendPOST: Bool = false,
        commandStatus: Int = 200, commandError: Data? = nil,
        includeGET: Bool = true, commandFailure: URLError.Code? = nil
    ) throws {
        let timestamp = "2026-11-03T09:00:00.123456+00:00"
        if includeGET {
            h.fixture.append(.init(
                method: "GET", path: "/functions/v1/plants-api/sync",
                data: try json([
                    "until": timestamp, "has_more": false, "last_cursor": NSNull(),
                    "next_since": timestamp, "entitlement": NSNull(), "changes": [],
                    "profile": ["preferred_locale": "pl", "reminder_hour_local": 9,
                                "report_notifications_enabled": true, "trial_reminder_enabled": false]
                ]), suspend: suspendGET, query: "limit=200"
            ))
        }
        h.fixture.append(.init(
            method: "POST", path: "/functions/v1/plants-api/commands",
            data: try commandError ?? json([
                "plant_id": "33333333-3333-4333-8333-333333333333", "care_revision": 1,
                "context_state": "current", "next_available_step": "enable_basic_care",
                "paid_action": NSNull(), "plan_availability": "available",
                "watermark": "2026-11-03T09:00:01.123456+00:00"
            ]), status: commandStatus, suspend: suspendPOST, failure: commandFailure
        ))
    }

    private func waitForSuspension(_ fixture: ConnectionHTTPFixture) async throws {
        let end = Date().addingTimeInterval(5)
        while !fixture.suspended && Date() < end { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(fixture.suspended)
        if !fixture.suspended { throw URLError(.timedOut) }
    }

    private func assertClosed(_ h: Harness, remaining: Int = 0) {
        XCTAssertTrue(h.fixture.unexpected.isEmpty, "Unhandled fixture URL")
        XCTAssertEqual(h.fixture.remaining, remaining)
    }

    private func assertRedacted(_ model: CatalogueSaveModel) {
        XCTAssertEqual(model.state, .unavailable(.sessionChanged))
        XCTAssertNil(model.input)
        XCTAssertNil(model.checkpoint)
        XCTAssertNil(model.envelope)
    }

    private func guestModel(
        _ h: Harness, flow: UUID, operation: UUID
    ) async throws -> CatalogueSaveModel {
        await h.ready()
        try auth(h, owner: owner, anonymous: true, signup: true)
        _ = try await h.connection.sessionOwner()
        let expected = try await h.connection.sessionSnapshot()
        return try await h.connection.makeModel(
            input: input, flowId: flow, operationId: operation, expected: expected
        )
    }

    /// Reopen the SQLite file rather than inspect the model's cached checkpoint.
    private func diskInput(_ h: Harness, owner: UUID, flow: UUID) throws -> CatalogueInputCheckpointSnapshot? {
        let disk = ModelContext(try Harness.container(h.directory.appendingPathComponent("connection.sqlite")))
        guard let record = try disk.fetch(FetchDescriptor<CatalogueInputCheckpointRecord>()).first(where: {
            $0.ownerId == owner && $0.flowId == flow
        }) else { return nil }
        return CatalogueInputCheckpointSnapshot(
            ownerId: record.ownerId, flowId: record.flowId,
            envelope: CommandEnvelopeDTO(
                operationId: record.operationId, commandName: "plant.create", payloadJSON: record.payloadJSON
            ), createdAt: record.createdAt
        )
    }

    private func continued(_ outcome: CatalogueNativeOutcome) throws -> CatalogueSaveModel {
        guard case let .continued(model) = outcome else {
            XCTFail("Expected a verified permanent continuation")
            throw URLError(.badServerResponse)
        }
        return model
    }

    private func assertUnavailable(_ outcome: CatalogueNativeOutcome, _ reason: CatalogueSaveUnavailable) {
        guard case let .unavailable(actual) = outcome else { return XCTFail("Expected typed unavailable") }
        XCTAssertEqual(actual, reason)
    }

    private func assertNoPlants(_ h: Harness) {
        XCTAssertFalse(h.fixture.captured.contains { $0.url?.path.contains("/plants-api/") == true })
    }

    private func resumeKey(_ owner: UUID) -> String {
        "catalogue.native.flow." + owner.uuidString.lowercased()
    }

    private func metadata(_ h: Harness) -> NSDictionary {
        NSDictionary(dictionary: h.defaults.persistentDomain(forName: h.defaultsSuite) ?? [:])
    }

    private func reopenedConnection(_ h: Harness) throws -> CatalogueConnection {
        let store = LocalStore(modelContainer: try Harness.container(
            h.directory.appendingPathComponent("connection.sqlite")
        ))
        return CatalogueConnection(
            client: h.client, configuration: h.configuration, store: store,
            transport: URLSessionAPITransport(session: h.http), identityProvider: h.identity,
            resumeDefaults: try XCTUnwrap(UserDefaults(suiteName: h.defaultsSuite))
        )
    }

    func testRememberDefaultsNotificationReentersConnectionAndOriginalModelAfterDiskCommit() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID(), operation = UUID(), foreignFlow = UUID()
        let model = try await guestModel(h, flow: flow, operation: operation)
        let expected = try await h.connection.sessionSnapshot()
        let key = resumeKey(owner)
        h.defaults.set(foreignFlow.uuidString, forKey: resumeKey(other))
        let requests = h.fixture.captured.count
        var callbacks = 0
        var returned = false
        let observer = ConnectionDefaultsObserver(defaults: h.defaults) {
            callbacks += 1
            XCTAssertFalse(returned)
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(h.connection.snapshot, expected)
            XCTAssertEqual(h.defaults.string(forKey: key), flow.uuidString)
            XCTAssertEqual(try h.connection.resumableFlow(expected: expected), flow)
            XCTAssertEqual(model.state, .ready)
            XCTAssertEqual(model.input, self.input)
            XCTAssertEqual(model.envelope, try self.input.makeEnvelope(operationId: operation))
            XCTAssertEqual(model.checkpoint?.flowId, flow)
            XCTAssertEqual(try self.diskInput(h, owner: self.owner, flow: flow), model.checkpoint)
        }
        defer { observer.stop() }
        let checkpoint = try await h.connection.rememberModel(model, expected: expected)
        returned = true
        XCTAssertGreaterThan(callbacks, 0)
        XCTAssertEqual(try h.connection.resumableFlow(expected: expected), flow)
        XCTAssertEqual(model.checkpoint, checkpoint)
        XCTAssertEqual(h.defaults.string(forKey: resumeKey(other)), foreignFlow.uuidString)
        let queue = try await h.store.pendingOutboxEntries(for: owner)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(h.fixture.captured.count, requests)
        XCTAssertEqual(h.identity.calls, 0)
        assertNoPlants(h)
        assertClosed(h)
    }

    func testRememberDefaultsNotificationRevokesOriginalLeaseAndConditionallyRollsBackOnlyOwnPointer() async throws {
        // Exercise absent/previous pointers, a newer callback publication, and model cancellation.
        for mode in 0..<4 {
            let h = try Harness()
            defer { h.close() }
            await h.ready()
            try auth(h, owner: owner)
            try await h.signIn()
            let expected = try await h.connection.sessionSnapshot()
            let api = try XCTUnwrap(h.connection.apiClient)
            let flow = UUID(), operation = UUID(), previous = UUID(), newer = UUID(), foreignFlow = UUID()
            let model = try await h.connection.makeModel(
                input: input, flowId: flow, operationId: operation, expected: expected
            )
            let checkpoint = try await model.checkpointInput()
            try plants(h, commandFailure: .networkConnectionLost)
            await model.save()
            guard case .pending = model.state else { return XCTFail("Keep a real pending operation") }
            let queue = try await h.store.pendingOutboxEntries(for: owner)
            XCTAssertEqual(queue.count, 1)
            let profile = try await h.store.syncedProfile(ownerId: owner)
            let watermark = try await h.store.currentWatermarkRaw(ownerId: owner)
            let key = resumeKey(owner)
            if mode != 0 { h.defaults.set(previous.uuidString, forKey: key) }
            h.defaults.set(foreignFlow.uuidString, forKey: resumeKey(other))
            let requests = h.fixture.captured.count
            var handled = false
            var callbacks = 0
            var returned = false
            let observer = ConnectionDefaultsObserver(defaults: h.defaults) {
                callbacks += 1
                XCTAssertFalse(returned)
                XCTAssertTrue(Thread.isMainThread)
                // Rollback and a newer pointer also notify synchronously.
                guard !handled else { return }
                handled = true
                XCTAssertEqual(h.connection.snapshot, expected)
                XCTAssertEqual(try h.connection.resumableFlow(expected: expected), flow)
                if mode == 2 { h.defaults.set(newer.uuidString, forKey: key) }
                if mode == 3 {
                    model.cancel()
                    XCTAssertEqual(model.state, .unavailable(.cancelled))
                    XCTAssertNil(model.input)
                    XCTAssertNil(model.checkpoint)
                } else {
                    api.syncAuthority.invalidate()
                    self.assertRedacted(model)
                }
                // SDK truth remains readable even when the original model lease is revoked.
                XCTAssertEqual(h.connection.snapshot, expected)
                XCTAssertNoThrow(try h.connection.resumableFlow(expected: expected))
            }
            defer { observer.stop() }
            do {
                try await h.connection.rememberModel(model, expected: expected)
                XCTFail("Synchronous preference callbacks revoked the original intent")
            } catch {
                if mode == 3 { XCTAssertTrue(error is CancellationError) }
                else if case SyncWireValidationError.invalidSession = error {}
                else { XCTFail("Expected rejection of the original bound lease") }
            }
            returned = true
            XCTAssertGreaterThan(callbacks, 0)
            let retained: UUID? = mode == 0 ? nil : (mode == 2 ? newer : previous)
            XCTAssertEqual(try h.connection.resumableFlow(expected: expected), retained)
            XCTAssertEqual(h.defaults.string(forKey: resumeKey(other)), foreignFlow.uuidString)
            XCTAssertEqual(try diskInput(h, owner: owner, flow: flow), checkpoint)
            let afterQueue = try await h.store.pendingOutboxEntries(for: owner)
            let afterProfile = try await h.store.syncedProfile(ownerId: owner)
            let afterWatermark = try await h.store.currentWatermarkRaw(ownerId: owner)
            let receipt = try await h.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
            XCTAssertEqual(afterQueue, queue)
            XCTAssertEqual(afterProfile, profile)
            XCTAssertEqual(afterWatermark, watermark)
            XCTAssertNil(receipt)
            XCTAssertEqual(h.fixture.captured.count, requests)
            XCTAssertEqual(h.identity.calls, 0)
            assertClosed(h)
        }
    }

    func testForgetDefaultsNotificationSynchronouslyReentersSourceAndPreservesOtherOrNewerPointers() async throws {
        for publishNewer in [false, true] {
            let h = try Harness()
            defer { h.close() }
            let flow = UUID(), newer = UUID(), foreignFlow = UUID()
            let model = try await guestModel(h, flow: flow, operation: UUID())
            let expected = try await h.connection.sessionSnapshot()
            let checkpoint = try await h.connection.rememberModel(model, expected: expected)
            let key = resumeKey(owner)
            h.defaults.set(foreignFlow.uuidString, forKey: resumeKey(other))
            let requests = h.fixture.captured.count
            var handled = false
            var callbacks = 0
            var returned = false
            let observer = ConnectionDefaultsObserver(defaults: h.defaults) {
                callbacks += 1
                XCTAssertFalse(returned)
                XCTAssertTrue(Thread.isMainThread)
                guard !handled else { return }
                handled = true
                XCTAssertEqual(h.connection.snapshot, expected)
                XCTAssertNil(try h.connection.resumableFlow(expected: expected))
                XCTAssertEqual(model.state, .ready)
                XCTAssertEqual(model.input, self.input)
                XCTAssertEqual(model.checkpoint, checkpoint)
                if publishNewer { h.defaults.set(newer.uuidString, forKey: key) }
            }
            defer { observer.stop() }
            XCTAssertFalse(try h.connection.forgetResumableFlow(
                ownerId: owner, expectedFlowId: UUID(), expected: expected
            ))
            XCTAssertEqual(callbacks, 0)
            XCTAssertTrue(try h.connection.forgetResumableFlow(
                ownerId: owner, expectedFlowId: flow, expected: expected
            ))
            returned = true
            XCTAssertGreaterThan(callbacks, 0)
            XCTAssertEqual(try h.connection.resumableFlow(expected: expected), publishNewer ? newer : nil)
            XCTAssertEqual(h.defaults.string(forKey: resumeKey(other)), foreignFlow.uuidString)
            XCTAssertEqual(try diskInput(h, owner: owner, flow: flow), checkpoint)
            let queue = try await h.store.pendingOutboxEntries(for: owner)
            XCTAssertTrue(queue.isEmpty)
            XCTAssertEqual(h.fixture.captured.count, requests)
            XCTAssertEqual(h.identity.calls, 0)
            assertNoPlants(h)
            assertClosed(h)
        }
    }

    func testGuestRememberPublishesAfterDiskCommitAndRestartsAfterProviderCancellation() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID(), operation = UUID()
        await h.ready()
        try auth(h, owner: owner, anonymous: true)
        try await h.signIn()
        let source = h.connection
        let expected = try await source.sessionSnapshot()
        let model = try await source.makeModel(
            input: input, flowId: flow, operationId: operation, expected: expected
        )
        XCTAssertNil(try source.resumableFlow(expected: expected))
        XCTAssertNil(try diskInput(h, owner: owner, flow: flow))
        XCTAssertNil(model.checkpoint)
        var callbacks = 0
        var returned = false
        let observer = ConnectionDefaultsObserver(defaults: h.defaults) {
            callbacks += 1
            XCTAssertFalse(returned)
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(source.snapshot, expected)
            XCTAssertEqual(try source.resumableFlow(expected: expected), flow)
            XCTAssertEqual(model.state, .ready)
            XCTAssertEqual(model.input, self.input)
            let committed = try XCTUnwrap(self.diskInput(h, owner: self.owner, flow: flow))
            XCTAssertEqual(committed.ownerId, self.owner)
            XCTAssertEqual(committed.flowId, flow)
            XCTAssertEqual(committed.envelope, try self.input.makeEnvelope(operationId: operation))
            XCTAssertEqual(model.checkpoint, committed)
        }
        defer { observer.stop() }
        // The real synchronous notification must see committed SQLite before remember returns.
        let checkpoint = try await source.rememberModel(model, expected: expected)
        returned = true
        observer.stop()
        XCTAssertGreaterThan(callbacks, 0)
        XCTAssertEqual(try diskInput(h, owner: owner, flow: flow), checkpoint)
        XCTAssertEqual(try source.resumableFlow(expected: expected), flow)
        h.identity.result = .failure(CancellationError())
        let result = await source.signInAndSave(model, with: .apple, presenting: UIViewController())
        guard case .inputRetained(_, .cancelled) = result else { return XCTFail("Keep guest intent") }
        let count = h.fixture.captured.count
        let restarted = try reopenedConnection(h)
        let current = try await restarted.sessionSnapshot()
        XCTAssertTrue(current.isAnonymous)
        XCTAssertEqual(current.session, expected.session)
        XCTAssertEqual(try restarted.resumableFlow(expected: current), flow)
        guard case let .restored(restored) = await restarted.restoreModel(
            ownerId: owner, flowId: flow, expected: current
        ) else { return XCTFail("Discover the guest's own durable flow") }
        XCTAssertEqual(restored.checkpoint, checkpoint)
        XCTAssertEqual(restored.envelope, try input.makeEnvelope(operationId: operation))
        XCTAssertEqual(restored.input, input)
        XCTAssertEqual(restored.state, .signInRequired)
        XCTAssertEqual(h.fixture.captured.count, count)
        XCTAssertEqual(h.identity.calls, 1)
        let queue = try await h.store.pendingOutboxEntries(for: owner)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(metadata(h), NSDictionary(dictionary: [resumeKey(owner): flow.uuidString]))
        assertNoPlants(h)
        assertClosed(h)
    }

    func testPermanentRememberDiscoversLostResponseAndRetriesExactBodyAfterDiskRestart() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner)
        try await h.signIn()
        let expected = try await h.connection.sessionSnapshot()
        let flow = UUID(), operation = UUID()
        let model = try await h.connection.makeModel(
            input: input, flowId: flow, operationId: operation, expected: expected
        )
        let checkpoint = try await h.connection.rememberModel(model, expected: expected)
        XCTAssertEqual(model.state, .ready)
        assertNoPlants(h)
        try plants(h, commandFailure: .networkConnectionLost)
        await model.save()
        guard case let .pending(pending) = model.state else { return XCTFail("Lost response stays pending") }
        let count = h.fixture.captured.count
        let restarted = try reopenedConnection(h)
        let current = try await restarted.sessionSnapshot()
        XCTAssertFalse(current.isAnonymous)
        XCTAssertEqual(try restarted.resumableFlow(expected: current), flow)
        guard case let .restored(restored) = await restarted.restoreModel(
            ownerId: owner, flowId: flow, expected: current
        ) else { return XCTFail("Discover the permanent owner's pending flow") }
        XCTAssertEqual(restored.state, .pending(pending))
        XCTAssertEqual(restored.input, input)
        XCTAssertEqual(restored.checkpoint, checkpoint)
        XCTAssertEqual(h.fixture.captured.count, count)
        try plants(h, includeGET: false)
        await restored.save()
        guard case let .saved(receipt) = restored.state else { return XCTFail("Retry requires durable receipt") }
        XCTAssertEqual(receipt.operationId, operation)
        XCTAssertEqual(receipt.payloadJSON, checkpoint.envelope.payloadJSON)
        let posts = h.fixture.captured.filter { $0.url?.path.hasSuffix("/commands") == true }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.first?.httpBody, posts.last?.httpBody)
        XCTAssertEqual(posts.first?.value(forHTTPHeaderField: "X-Operation-Id"), operation.uuidString.lowercased())
        XCTAssertEqual(posts.last?.value(forHTTPHeaderField: "X-Operation-Id"), operation.uuidString.lowercased())
        XCTAssertEqual(h.identity.calls, 0)
        assertClosed(h)
    }

    func testRememberReadOnlyDiskPreservesBothOwnerPointersAndNeverOpensProvider() async throws {
        let h = try Harness(allowsSave: false)
        defer { h.close() }
        let flow = UUID()
        let model = try await guestModel(h, flow: flow, operation: UUID())
        let expected = try await h.connection.sessionSnapshot()
        h.defaults.set(UUID().uuidString, forKey: resumeKey(owner))
        h.defaults.set(UUID().uuidString, forKey: resumeKey(other))
        let before = metadata(h)
        do {
            try await h.connection.rememberModel(model, expected: expected)
            XCTFail("No pointer without a committed checkpoint")
        } catch {}
        XCTAssertEqual(metadata(h), before)
        XCTAssertNil(try diskInput(h, owner: owner, flow: flow))
        let result = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        assertUnavailable(result, .storageOrServiceUnavailable)
        XCTAssertEqual(metadata(h), before)
        XCTAssertEqual(h.identity.calls, 0)
        assertNoPlants(h)
        assertClosed(h)
    }

    func testRememberReplaysCachedCheckpointBeforeReplacingMetadata() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID()
        let model = try await guestModel(h, flow: flow, operation: UUID())
        await model.save()
        XCTAssertNotNil(model.checkpoint)
        let expected = try await h.connection.sessionSnapshot()
        h.defaults.set(UUID().uuidString, forKey: resumeKey(owner))
        let before = metadata(h)
        let disk = ModelContext(h.store.modelContainer)
        let record = try XCTUnwrap(try disk.fetch(FetchDescriptor<CatalogueInputCheckpointRecord>()).first)
        record.payloadJSON = "{}"
        try disk.save()
        do {
            try await h.connection.rememberModel(model, expected: expected)
            XCTFail("Cached input is not proof of a valid disk checkpoint")
        } catch {}
        XCTAssertEqual(metadata(h), before)
        XCTAssertEqual(try diskInput(h, owner: owner, flow: flow)?.envelope.payloadJSON, "{}")
        XCTAssertEqual(h.identity.calls, 0)
        assertNoPlants(h)
        assertClosed(h)
    }

    func testRememberRejectsSameOwnerForeignStoreAPIAnonymitySessionLeaseAndCancellation() async throws {
        for mode in 0..<7 {
            let h = try Harness()
            defer { h.close() }
            await h.ready()
            try auth(h, owner: owner, anonymous: true)
            try await h.signIn()
            let expected = try await h.connection.sessionSnapshot()
            let api = try XCTUnwrap(h.connection.apiClient)
            var candidateStore = h.store
            var candidateAPI = api
            var candidateSession = expected.session
            if mode == 0 {
                candidateStore = LocalStore(modelContainer: try Harness.container(
                    h.directory.appendingPathComponent("foreign.sqlite")
                ))
            } else if mode == 1 {
                candidateAPI = PlantsAPIClient(
                    baseURL: h.configuration.supabaseURL.appendingPathComponent("functions/v1/plants-api"),
                    transport: URLSessionAPITransport(session: h.http)
                )
                await candidateAPI.bindSyncSession(expected.session)
            } else if mode == 4 {
                candidateSession = NativeAuthSession(
                    userId: owner, accessToken: "fixture-other-session", expiresAt: expected.session.expiresAt
                )
                await api.bindSyncSession(candidateSession)
            }
            let flow = UUID()
            let model = try await CatalogueSaveModel(
                store: candidateStore, apiClient: candidateAPI,
                repository: CollectionRepository(
                    store: candidateStore, apiClient: candidateAPI,
                    syncEngine: SyncEngine(store: candidateStore, apiClient: candidateAPI)
                ), flowId: flow, operationId: UUID(), input: input,
                session: candidateSession, isAnonymous: mode != 2
            )
            if mode == 3 { await api.bindSyncSession(expected.session) }
            if mode == 5 { model.cancel() }
            h.defaults.set(UUID().uuidString, forKey: resumeKey(owner))
            h.defaults.set(UUID().uuidString, forKey: resumeKey(other))
            let before = metadata(h)
            let remembering = Task { try await h.connection.rememberModel(model, expected: expected) }
            if mode == 6 { remembering.cancel() }
            do { _ = try await remembering.value; XCTFail("Exact original scope is required: \(mode)") }
            catch {}
            XCTAssertEqual(metadata(h), before)
            XCTAssertNil(try diskInput(h, owner: owner, flow: flow))
            XCTAssertEqual(h.identity.calls, 0)
            assertNoPlants(h)
            assertClosed(h)
        }
    }

    func testRememberCheckpointPublicationRejectsSwitchABASameTokenRefreshAndCancellationBeforeMetadata() async throws {
        for mode in 0..<5 {
            let h = try Harness()
            defer { h.close() }
            await h.ready()
            try auth(h, owner: owner, anonymous: true)
            try await h.signIn()
            let source = h.connection
            let expected = try await source.sessionSnapshot()
            let flow = UUID(), operation = UUID()
            let model = try await source.makeModel(
                input: input, flowId: flow, operationId: operation, expected: expected
            )
            h.defaults.set(UUID().uuidString, forKey: resumeKey(owner))
            h.defaults.set(UUID().uuidString, forKey: resumeKey(other))
            let before = metadata(h)
            XCTAssertNil(try diskInput(h, owner: owner, flow: flow))
            XCTAssertNil(model.checkpoint)
            // Prepare actual SDK HTTP responses before entering the synchronous observer.
            if mode < 2 {
                try auth(h, owner: other, token: "fixture-b")
                if mode == 1 { try auth(h, owner: owner, anonymous: true) }
            } else if mode == 2 {
                try auth(h, owner: owner, anonymous: true, refresh: true)
            }
            let client = h.client
            let publication = ConnectionCheckpointPublication(metadataBefore: before)
            var metadataCallbacks = 0
            let observer = ConnectionDefaultsObserver(defaults: h.defaults) {
                metadataCallbacks += 1
            }
            defer { observer.stop() }
            let checkpointPublication: @MainActor () throws -> Void = {
                guard !publication.fired else { return }
                publication.fired = true
                XCTAssertTrue(Thread.isMainThread)
                // Observation fires at willSet, after SQLite commit and before UUID metadata.
                XCTAssertNil(model.checkpoint)
                XCTAssertEqual(model.state, .ready)
                XCTAssertEqual(model.input, self.input)
                XCTAssertEqual(self.metadata(h), publication.metadataBefore)
                do {
                    let committed = try XCTUnwrap(self.diskInput(h, owner: self.owner, flow: flow))
                    publication.committed = committed
                    XCTAssertEqual(committed.ownerId, self.owner)
                    XCTAssertEqual(committed.flowId, flow)
                    XCTAssertEqual(committed.envelope, try self.input.makeEnvelope(operationId: operation))
                } catch {
                    XCTFail("Checkpoint publication must follow a real disk commit: \(error)")
                }
                if mode < 3 {
                    let done = DispatchSemaphore(value: 0)
                    publication.sdkWork = Task.detached {
                        defer { done.signal() }
                        if mode < 2 {
                            _ = try await client.auth.signInWithIdToken(
                                credentials: .init(provider: .apple, idToken: "FIXTURE-ONLY-ID-TOKEN")
                            )
                            if mode == 1 {
                                _ = try await client.auth.signInWithIdToken(
                                    credentials: .init(provider: .apple, idToken: "FIXTURE-ONLY-ID-TOKEN")
                                )
                            }
                        } else {
                            _ = try await client.auth.refreshSession()
                        }
                    }
                    // No store/SQLite/authority lock is held here. Keep the queued MainActor
                    // observer out until the real SDK callback has synchronously revoked the lease.
                    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
                    self.assertRedacted(model)
                    XCTAssertThrowsError(try source.resumableFlow(expected: expected))
                } else if mode == 3 {
                    withUnsafeCurrentTask {
                        XCTAssertNotNil($0)
                        $0?.cancel()
                    }
                    XCTAssertTrue(Task.isCancelled)
                } else {
                    model.cancel()
                    XCTAssertEqual(model.state, .unavailable(.cancelled))
                }
                XCTAssertEqual(self.metadata(h), publication.metadataBefore)
            }
            withObservationTracking {
                _ = model.checkpoint
            } onChange: {
                MainActor.assumeIsolated {
                    do { try checkpointPublication() }
                    catch { XCTFail("Checkpoint publication callback failed: \(error)") }
                }
            }
            let remembering = Task { try await source.rememberModel(model, expected: expected) }
            do { _ = try await remembering.value; XCTFail("Revoked intent must not publish metadata: \(mode)") }
            catch {}
            if let sdkWork = publication.sdkWork { try await sdkWork.value }
            observer.stop()
            XCTAssertTrue(publication.fired, "Must revoke inside actual checkpoint publication")
            let committed = try XCTUnwrap(publication.committed)
            XCTAssertEqual(try diskInput(h, owner: owner, flow: flow), committed)
            XCTAssertEqual(metadata(h), before)
            XCTAssertEqual(metadataCallbacks, 0, "No transient pointer publication before rejection")
            XCTAssertNil(try diskInput(h, owner: other, flow: flow))
            let ownQueue = try await h.store.pendingOutboxEntries(for: owner)
            let foreignQueue = try await h.store.pendingOutboxEntries(for: other)
            let ownReceipt = try await h.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
            let foreignReceipt = try await h.store.catalogueCreateConfirmation(ownerId: other, operationId: operation)
            XCTAssertTrue(ownQueue.isEmpty)
            XCTAssertTrue(foreignQueue.isEmpty)
            XCTAssertNil(ownReceipt)
            XCTAssertNil(foreignReceipt)
            if mode < 3 {
                XCTAssertThrowsError(try source.resumableFlow(expected: expected))
                XCTAssertThrowsError(try source.forgetResumableFlow(
                    ownerId: owner, expectedFlowId: UUID(), expected: expected
                ))
                let current = try await source.sessionSnapshot()
                XCTAssertNotEqual(current, expected)
                XCTAssertEqual(current.session.userId, mode == 0 ? other : owner)
                if mode != 0 {
                    XCTAssertEqual(current.session, expected.session)
                    XCTAssertTrue(current.isAnonymous)
                }
            }
            XCTAssertEqual(h.identity.calls, 0)
            assertNoPlants(h)
            assertClosed(h)
        }
    }

    func testExplicitForgetMatchesOwnerAndFlowAndPreservesPendingRecordsAndReceipts() async throws {
        for pending in [true, false] {
            let h = try Harness()
            defer { h.close() }
            await h.ready()
            try auth(h, owner: owner)
            try await h.signIn()
            let expected = try await h.connection.sessionSnapshot()
            let flow = UUID(), operation = UUID(), foreignFlow = UUID()
            let model = try await h.connection.makeModel(
                input: input, flowId: flow, operationId: operation, expected: expected
            )
            let checkpoint = try await h.connection.rememberModel(model, expected: expected)
            try plants(h, commandFailure: pending ? .networkConnectionLost : nil)
            await model.save()
            if pending {
                guard case .pending = model.state else { return XCTFail("Pending fixture") }
            } else {
                guard case .saved = model.state else { return XCTFail("Receipt fixture") }
            }
            h.defaults.set(foreignFlow.uuidString, forKey: resumeKey(other))
            let queue = try await h.store.pendingOutboxEntries(for: owner)
            let receipt = try await h.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
            XCTAssertFalse(try h.connection.forgetResumableFlow(
                ownerId: owner, expectedFlowId: UUID(), expected: expected
            ))
            XCTAssertThrowsError(try h.connection.forgetResumableFlow(
                ownerId: other, expectedFlowId: foreignFlow, expected: expected
            ))
            XCTAssertEqual(try h.connection.resumableFlow(expected: expected), flow)
            XCTAssertTrue(try h.connection.forgetResumableFlow(
                ownerId: owner, expectedFlowId: flow, expected: expected
            ))
            XCTAssertNil(try h.connection.resumableFlow(expected: expected))
            XCTAssertFalse(try h.connection.forgetResumableFlow(
                ownerId: owner, expectedFlowId: flow, expected: expected
            ))
            XCTAssertEqual(h.defaults.string(forKey: resumeKey(other)), foreignFlow.uuidString)
            XCTAssertEqual(try diskInput(h, owner: owner, flow: flow), checkpoint)
            let afterQueue = try await h.store.pendingOutboxEntries(for: owner)
            let afterReceipt = try await h.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
            XCTAssertEqual(afterQueue, queue)
            XCTAssertEqual(afterReceipt, receipt)
            let newFlow = UUID()
            let newModel = try await h.connection.makeModel(
                input: input, flowId: newFlow, operationId: UUID(), expected: expected
            )
            try await h.connection.rememberModel(newModel, expected: expected)
            XCTAssertFalse(try h.connection.forgetResumableFlow(
                ownerId: owner, expectedFlowId: flow, expected: expected
            ))
            XCTAssertEqual(try h.connection.resumableFlow(expected: expected), newFlow)
            XCTAssertEqual(h.defaults.string(forKey: resumeKey(other)), foreignFlow.uuidString)
            XCTAssertEqual(h.identity.calls, 0)
            assertClosed(h)
        }
    }

    func testSourceLocaleUpdatesRealGETPOSTHeadersWithoutRevokingModelOrFrozenPendingOperation() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner)
        try await h.signIn()
        let expected = try await h.connection.sessionSnapshot()
        let api = try XCTUnwrap(h.connection.apiClient)
        let lease = try await api.captureSyncContext(ownerId: owner)
        let flow = UUID(), operation = UUID()
        let model = try await h.connection.makeModel(
            input: input, flowId: flow, operationId: operation, expected: expected
        )
        let checkpoint = try await h.connection.rememberModel(model, expected: expected)
        for locale in ["en", "pl"] {
            try await h.connection.updateClientLocale(locale)
            try plants(h, commandFailure: .networkConnectionLost)
            if locale == "pl" { _ = try await api.fetchSyncWirePage(session: expected.session) }
            await model.save()
            guard case .pending = model.state else { return XCTFail("Same original model stays usable") }
            XCTAssertEqual(model.input, input)
            XCTAssertEqual(model.envelope, checkpoint.envelope)
            XCTAssertEqual(model.checkpoint, checkpoint)
            try api.syncAuthority.withBoundValid(lease) {}
        }
        let pending = model.state
        for locale in ["de", "", "EN", "pl "] {
            do { try await h.connection.updateClientLocale(locale); XCTFail("Reject unsupported locale") }
            catch { XCTAssertEqual(error as? PlantsAPIClient.LocaleError, .unsupportedLocale) }
            XCTAssertEqual(model.state, pending)
            XCTAssertEqual(model.envelope, checkpoint.envelope)
        }
        let after = try await h.connection.sessionSnapshot()
        let afterLease = try await api.captureSyncContext(ownerId: owner)
        XCTAssertEqual(after, expected)
        XCTAssertEqual(afterLease.generation, lease.generation)
        XCTAssertEqual(afterLease.session, lease.session)
        try plants(h, includeGET: false)
        await model.save()
        guard case let .saved(receipt) = model.state else { return XCTFail("Original lease retries successfully") }
        XCTAssertEqual(receipt.operationId, operation)
        let requests = h.fixture.captured.filter { $0.url?.path.contains("/plants-api/") == true }
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "POST", "POST"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "X-Client-Locale") }, ["en", "en", "pl", "pl", "pl"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-a" })
        let posts = requests.filter { $0.httpMethod == "POST" }
        XCTAssertTrue(posts.allSatisfy { $0.httpBody == posts.first?.httpBody })
        XCTAssertTrue(posts.allSatisfy { $0.value(forHTTPHeaderField: "X-Operation-Id") == operation.uuidString.lowercased() })
        XCTAssertEqual(h.identity.calls, 0)
        assertClosed(h)
    }

    func testAPILocaleMethodPreservesInstallationAndBoundAuthorizationOnActualRequests() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner)
        try await h.signIn()
        let expected = try await h.connection.sessionSnapshot()
        let api = PlantsAPIClient(
            baseURL: h.configuration.supabaseURL.appendingPathComponent("functions/v1/plants-api"),
            transport: URLSessionAPITransport(session: h.http), installationCredential: "fixture-installation"
        )
        await api.bindSyncSession(expected.session)
        let lease = try await api.captureSyncContext(ownerId: owner)
        let envelope = try input.makeEnvelope(operationId: UUID())
        for locale in ["en", "pl"] {
            try await api.updateClientLocale(locale)
            try plants(h)
            _ = try await api.fetchSyncWirePage(session: expected.session)
            _ = try await api.sendOutboxCommand(envelope, context: lease)
        }
        let requests = h.fixture.captured.filter { $0.url?.path.contains("/plants-api/") == true }
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "POST"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "X-Client-Locale") }, ["en", "en", "pl", "pl"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-a" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Installation-Credential") == "fixture-installation" })
        try api.syncAuthority.withBoundValid(lease) {}
        assertClosed(h)
    }

    func testOrdinaryEmailKeepsVerifiedBindingAndSerializesNativeSignIn() async throws {
        let h = try Harness()
        defer { h.close() }
        let scope = try await h.connection.accountScope()
        try auth(h, owner: other, suspend: true, grant: "password")
        let signing = Task {
            try await h.connection.signInAccount(
                email: "fixture@example.invalid", password: "fixture", scope: scope
            )
        }
        try await waitForSuspension(h.fixture)
        do {
            _ = try await h.connection.signInAccount(with: .apple, presenting: UIViewController(), scope: scope)
            XCTFail("Native sign-in must wait for email")
        } catch {
            XCTAssertEqual(error as? NativeAuthFailure, .providerFailed)
        }
        h.fixture.release()
        let result = try await signing.value
        XCTAssertEqual(result?.session.userId, other)
        XCTAssertEqual(result, h.connection.snapshot)
        XCTAssertEqual(h.identity.calls, 0)
        XCTAssertFalse(h.connection.authenticationInFlight)
        assertNoPlants(h)
        assertClosed(h)
    }

    func testOrdinaryGoogleAvailabilityRequiresClientAndRegisteredCallback() throws {
        let h = try Harness()
        defer { h.close() }
        let bundleURL = h.directory.appendingPathComponent("GoogleFixture.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "invalid.fixture.google",
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["com.googleusercontent.apps.fixture"]]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertTrue(NativeIdentityProvider.isGoogleConfigured(clientId: "fixture.apps.googleusercontent.com", bundle: bundle))
        for client in [nil, "", "$(GOOGLE_IOS_CLIENT_ID)", "wrong.apps.googleusercontent.com", "invalid"] {
            XCTAssertFalse(NativeIdentityProvider.isGoogleConfigured(clientId: client, bundle: bundle))
        }
        XCTAssertEqual(h.connection.accountProviders, [.apple])
        assertClosed(h)
    }

    func testConfigurationValidatesCallbacksInTheSuppliedBundle() throws {
        let h = try Harness()
        defer { h.close() }
        let callbacks: [String?] = [nil, "wrong.callback", "com.googleusercontent.apps.fixture"]
        for callback in callbacks {
            let bundle = try Harness.googleBundle(in: h.directory, callback: callback)
            let expected = callback == "com.googleusercontent.apps.fixture"
            XCTAssertEqual(try NativeAuthConfiguration(bundle: bundle).supportsGoogleSignIn, expected)
            let values = try XCTUnwrap(bundle.infoDictionary).compactMapValues { $0 as? String }
            XCTAssertEqual(try NativeAuthConfiguration(values: values, bundle: bundle).supportsGoogleSignIn, expected)
            var missingClient = values
            missingClient.removeValue(forKey: "GIDClientID")
            XCTAssertFalse(try NativeAuthConfiguration(values: missingClient, bundle: bundle).supportsGoogleSignIn)
        }
        XCTAssertEqual(h.connection.accountProviders, [.apple])
        assertClosed(h)
    }

    func testOrdinaryUnavailableGoogleDoesNotOpenProviderOrChangeSDKOrDisk() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID(), operation = UUID()
        let model = try await guestModel(h, flow: flow, operation: operation)
        let checkpoint = try await model.checkpointInput()
        let scope = try await h.connection.accountScope()
        let session = try XCTUnwrap(h.client.auth.currentSession)
        let journal = Data("fixture-existing-photo-journal".utf8)
        h.connection.storeGuestPhotoClaimData(journal)
        let beforeMetadata = metadata(h)
        do {
            _ = try await h.connection.signInAccount(with: .google, presenting: UIViewController(), scope: scope)
            XCTFail("Unconfigured Google must be rejected")
        } catch { XCTAssertEqual(error as? NativeAuthFailure, .configurationMissing) }
        XCTAssertEqual(h.identity.calls, 0)
        XCTAssertEqual(h.connection.snapshot, scope.snapshot)
        XCTAssertEqual(h.client.auth.currentSession?.user.id, session.user.id)
        XCTAssertEqual(h.client.auth.currentSession?.accessToken, session.accessToken)
        XCTAssertEqual(h.client.auth.currentSession?.user.isAnonymous, true)
        XCTAssertEqual(model.input, input)
        XCTAssertEqual(model.checkpoint, checkpoint)
        XCTAssertEqual(try diskInput(h, owner: owner, flow: flow), checkpoint)
        XCTAssertEqual(h.connection.guestPhotoClaimData(), journal)
        XCTAssertEqual(metadata(h), beforeMetadata)
        XCTAssertFalse(h.connection.authenticationInFlight)
        XCTAssertEqual(h.fixture.captured.map(\.url?.path), ["/auth/v1/signup"])
        assertNoPlants(h)
        assertClosed(h)
    }

    func testCatalogueUnavailableGoogleRetainsRememberedInputAndBothOwnerQueues() async throws {
        for selected in [input, CatalogueInput(diagnosisJobId: UUID(), speciesSlug: "fixture-fern", personalName: input.personalName),
                         CatalogueInput(identification: .init(jobId: UUID(), taxonId: UUID()), personalName: input.personalName)] {
            let h = try Harness()
            defer { h.close() }
            await h.ready()
            try auth(h, owner: owner, anonymous: true, signup: true)
            _ = try await h.connection.sessionOwner()
            let expected = try await h.connection.sessionSnapshot()
            let flow = UUID(), operation = UUID()
            let model = try await h.connection.makeModel(
                input: selected, flowId: flow, operationId: operation, expected: expected
            )
            let checkpoint = try await h.connection.rememberModel(model, expected: expected)
            let envelope = try selected.makeEnvelope(operationId: operation)
            let state = model.state
            for queueOwner in [owner, other] {
                _ = try await h.store.enqueueCommand(
                    ownerId: queueOwner, plantId: UUID(), commandName: "care.complete", payloadJSON: "{}"
                )
            }
            let ownQueue = try await h.store.pendingOutboxEntries(for: owner)
            let foreignQueue = try await h.store.pendingOutboxEntries(for: other)
            let journal = Data("fixture-existing-photo-journal".utf8)
            h.connection.storeGuestPhotoClaimData(journal)
            let beforeMetadata = metadata(h)
            let result = await h.connection.signInAndSave(model, with: .google, presenting: UIViewController())
            assertUnavailable(result, .storageOrServiceUnavailable)
            XCTAssertEqual(h.identity.calls, 0)
            XCTAssertEqual(model.input, selected)
            XCTAssertEqual(model.state, state)
            XCTAssertEqual(model.checkpoint, checkpoint)
            XCTAssertEqual(checkpoint.flowId, flow)
            XCTAssertEqual(checkpoint.operationId, operation)
            XCTAssertEqual(checkpoint.envelope, envelope)
            XCTAssertEqual(try diskInput(h, owner: owner, flow: flow), checkpoint)
            XCTAssertNil(try diskInput(h, owner: other, flow: flow))
            XCTAssertEqual(h.connection.snapshot, expected)
            XCTAssertEqual(h.client.auth.currentSession?.accessToken, expected.session.accessToken)
            XCTAssertEqual(h.client.auth.currentSession?.user.id, owner)
            XCTAssertEqual(h.client.auth.currentSession?.user.isAnonymous, true)
            XCTAssertEqual(h.connection.guestPhotoClaimData(), journal)
            XCTAssertEqual(metadata(h), beforeMetadata)
            XCTAssertEqual(try h.connection.resumableFlow(expected: expected), flow)
            XCTAssertFalse(h.connection.authenticationInFlight)
            let disk = try Harness.container(h.directory.appendingPathComponent("connection.sqlite"))
            let reopened = LocalStore(modelContainer: disk)
            let afterOwn = try await reopened.pendingOutboxEntries(for: owner)
            let afterForeign = try await reopened.pendingOutboxEntries(for: other)
            XCTAssertEqual(afterOwn, ownQueue)
            XCTAssertEqual(afterForeign, foreignQueue)
            XCTAssertEqual(try ModelContext(disk).fetchCount(FetchDescriptor<CatalogueCreateConfirmationRecord>()), 0)
            XCTAssertEqual(h.fixture.captured.map(\.url?.path), ["/auth/v1/signup"])
            assertNoPlants(h)
            assertClosed(h)
        }
    }

    func testOrdinaryNativeCancellationPreservesDraftAndOwnerWithoutWrites() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID()
        let model = try await guestModel(h, flow: flow, operation: UUID())
        let checkpoint = try await model.checkpointInput()
        let scope = try await h.connection.accountScope()
        let journal = Data("fixture-existing-photo-journal".utf8)
        h.connection.storeGuestPhotoClaimData(journal)
        h.identity.result = .failure(CancellationError())
        let result = try await h.connection.signInAccount(with: .apple, presenting: UIViewController(), scope: scope)
        XCTAssertNil(result)
        XCTAssertEqual(h.connection.snapshot, scope.snapshot)
        XCTAssertEqual(h.connection.guestPhotoClaimData(), journal)
        XCTAssertEqual(try diskInput(h, owner: owner, flow: flow)?.envelope, checkpoint.envelope)
        XCTAssertEqual(model.input, input)
        XCTAssertEqual(h.identity.calls, 1)
        XCTAssertFalse(h.connection.authenticationInFlight)
        XCTAssertEqual(h.fixture.captured.map(\.url?.path), ["/auth/v1/signup"])
        assertNoPlants(h)
        assertClosed(h)
    }

    func testOrdinaryNativeSuccessReturnsOneVerifiedPermanentSnapshotWithoutMigration() async throws {
        for provider in [NativeAuthProvider.apple, .google] {
            let h = try Harness(configuredGoogle: provider == .google)
            defer { h.close() }
            let flow = UUID(), operation = UUID()
            let model = try await guestModel(h, flow: flow, operation: operation)
            let checkpoint = try await model.checkpointInput()
            let scope = try await h.connection.accountScope()
            let journal = Data("fixture-existing-photo-journal".utf8)
            h.connection.storeGuestPhotoClaimData(journal)
            h.identity.result = .success(.init(
                provider: provider, idToken: "FIXTURE-ONLY-ID-TOKEN", nonce: "fixture-nonce"
            ))
            try auth(h, owner: other, token: "fixture-ordinary")
            var callbacks = 0
            if let snapshot = try await h.connection.signInAccount(
                with: provider, presenting: UIViewController(), scope: scope
            ) {
                XCTAssertFalse(snapshot.isAnonymous)
                XCTAssertEqual(snapshot.session.userId, other)
                XCTAssertEqual(snapshot, h.connection.snapshot)
                XCTAssertEqual(snapshot.session.accessToken, h.client.auth.currentSession?.accessToken)
                callbacks += 1
            }
            await h.ready()
            XCTAssertEqual(callbacks, 1)
            XCTAssertEqual(h.identity.calls, 1)
            XCTAssertEqual(h.connection.guestPhotoClaimData(), journal)
            XCTAssertEqual(try diskInput(h, owner: owner, flow: flow)?.envelope, checkpoint.envelope)
            XCTAssertNil(try diskInput(h, owner: other, flow: flow))
            let queue = try await h.store.pendingOutboxEntries(for: other)
            XCTAssertTrue(queue.isEmpty)
            assertNoPlants(h)
            assertClosed(h)
        }
    }

    func testOrdinaryNativeSignInWithoutSessionDoesNotCreateAnonymousIdentity() async throws {
        let h = try Harness()
        defer { h.close() }
        let scope = try await h.connection.accountScope()
        XCTAssertNil(scope.snapshot)
        try auth(h, owner: other)
        let snapshot = try await h.connection.signInAccount(with: .apple, presenting: UIViewController(), scope: scope)
        XCTAssertEqual(snapshot?.session.userId, other)
        XCTAssertEqual(h.fixture.captured.map(\.url?.path), ["/auth/v1/token"])
        XCTAssertTrue((h.defaults.persistentDomain(forName: h.defaultsSuite) ?? [:]).isEmpty)
        assertNoPlants(h)
        assertClosed(h)
    }

    func testOrdinaryAccountRejectsScopeReplacementBeforeAndDuringProviderIncludingABA() async throws {
        for timing in 0..<3 {
            let h = try Harness()
            defer { h.close() }
            _ = try await guestModel(h, flow: UUID(), operation: UUID())
            let scope = try await h.connection.accountScope()
            let replace: () async throws -> Void = {
                try self.auth(h, owner: self.other)
                try await h.signIn()
                if timing == 2 {
                    try self.auth(h, owner: self.owner, anonymous: true)
                    try await h.signIn()
                }
            }
            if timing == 0 { try await replace() }
            else { h.identity.onRequest = replace }
            do {
                _ = try await h.connection.signInAccount(with: .apple, presenting: UIViewController(), scope: scope)
                XCTFail("Replaced scope must not reach caller")
            } catch {
                XCTAssertEqual(error as? CatalogueSaveUnavailable, .sessionChanged)
            }
            XCTAssertEqual(h.identity.calls, timing == 0 ? 0 : 1)
            XCTAssertEqual(h.fixture.captured.filter { $0.url?.path == "/auth/v1/token" }.count, timing == 2 ? 2 : 1)
            assertNoPlants(h)
            assertClosed(h)
        }
    }

    func testOrdinaryAccountRejectsUnrelatedSessionDuringCommittedExchange() async throws {
        let h = try Harness()
        defer { h.close() }
        let scope = try await h.connection.accountScope()
        try auth(h, owner: other, token: "fixture-intended", suspend: true)
        let signing = Task {
            try await h.connection.signInAccount(with: .apple, presenting: UIViewController(), scope: scope)
        }
        try await waitForSuspension(h.fixture)
        try auth(h, owner: UUID(), token: "fixture-unrelated")
        try await h.signIn()
        h.fixture.release()
        do {
            _ = try await signing.value
            XCTFail("Extra SDK event must invalidate the result")
        } catch {
            XCTAssertEqual(error as? CatalogueSaveUnavailable, .sessionChanged)
        }
        assertNoPlants(h)
        assertClosed(h)
    }

    func testOrdinaryNativeSerializesEmailAndCatalogueActions() async throws {
        let h = try Harness()
        defer { h.close() }
        let model = try await guestModel(h, flow: UUID(), operation: UUID())
        let scope = try await h.connection.accountScope()
        var gate: CheckedContinuation<Void, Never>?
        h.identity.onRequest = { await withCheckedContinuation { gate = $0 } }
        h.identity.result = .failure(CancellationError())
        let signing = Task {
            try await h.connection.signInAccount(with: .apple, presenting: UIViewController(), scope: scope)
        }
        let deadline = Date().addingTimeInterval(5)
        while gate == nil && Date() < deadline { await Task.yield() }
        guard let release = gate else {
            signing.cancel()
            return XCTFail("Provider did not open")
        }
        XCTAssertTrue(h.connection.authenticationInFlight)
        do {
            _ = try await h.connection.signInAccount(email: "fixture@example.invalid", password: "fixture", scope: scope)
            XCTFail("Concurrent email sign-in must be rejected")
        } catch {
            XCTAssertEqual(error as? NativeAuthFailure, .providerFailed)
        }
        let duplicate = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        if case .busy = duplicate {} else { XCTFail("Catalogue must share the account gate") }
        release.resume()
        let result = try await signing.value
        XCTAssertNil(result)
        XCTAssertEqual(h.identity.calls, 1)
        XCTAssertEqual(h.fixture.captured.map(\.url?.path), ["/auth/v1/signup"])
        assertNoPlants(h)
        assertClosed(h)
    }

    func testNativeProviderOpensOnlyAfterExactDiskCheckpointAndCancellationRetainsGuest() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID(), operation = UUID()
        let model = try await guestModel(h, flow: flow, operation: operation)
        let envelope = try input.makeEnvelope(operationId: operation)
        h.identity.onRequest = {
            let disk = try XCTUnwrap(self.diskInput(h, owner: self.owner, flow: flow))
            XCTAssertEqual(disk.operationId, operation)
            XCTAssertEqual(Data(disk.envelope.payloadJSON.utf8), Data(envelope.payloadJSON.utf8))
            XCTAssertEqual(h.client.auth.currentSession?.user.isAnonymous, true)
        }
        h.identity.result = .failure(CancellationError())
        let result = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        guard case let .inputRetained(retained, .cancelled) = result else {
            return XCTFail("Provider cancellation must retain the original input")
        }
        XCTAssertTrue(retained === model)
        XCTAssertEqual(model.input, input)
        XCTAssertEqual(try diskInput(h, owner: owner, flow: flow)?.envelope, envelope)
        XCTAssertEqual(h.connection.nativeAuthState, .cancelled)
        XCTAssertEqual(h.client.auth.currentSession?.user.id, owner)
        XCTAssertEqual(h.client.auth.currentSession?.user.isAnonymous, true)
        XCTAssertEqual(h.identity.calls, 1)
        XCTAssertEqual(h.fixture.captured.map(\.url?.path), ["/auth/v1/signup"])
        let queue = try await h.store.pendingOutboxEntries(for: owner)
        XCTAssertTrue(queue.isEmpty)
        assertClosed(h)
    }

    func testNativeReadOnlySQLitePreparationNeverOpensProvider() async throws {
        let h = try Harness(allowsSave: false)
        defer { h.close() }
        let flow = UUID()
        let model = try await guestModel(h, flow: flow, operation: UUID())
        let result = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        assertUnavailable(result, .storageOrServiceUnavailable)
        XCTAssertEqual(h.connection.nativeAuthState, .failed(.preparationFailed))
        XCTAssertEqual(h.identity.calls, 0)
        XCTAssertNil(try diskInput(h, owner: owner, flow: flow))
        XCTAssertEqual(h.client.auth.currentSession?.user.isAnonymous, true)
        XCTAssertEqual(h.fixture.captured.map(\.url?.path), ["/auth/v1/signup"])
        assertClosed(h)
    }

    func testNativePreparationReplaysDiskEvenWithPreviouslyCachedCheckpoint() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID()
        let model = try await guestModel(h, flow: flow, operation: UUID())
        await model.save()
        XCTAssertNotNil(model.checkpoint)
        let disk = ModelContext(h.store.modelContainer)
        let record = try XCTUnwrap(try disk.fetch(FetchDescriptor<CatalogueInputCheckpointRecord>()).first)
        record.payloadJSON = "{}"
        try disk.save()
        let result = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        assertUnavailable(result, .storageOrServiceUnavailable)
        XCTAssertEqual(h.identity.calls, 0)
        XCTAssertEqual(try diskInput(h, owner: owner, flow: flow)?.envelope.payloadJSON, "{}")
        XCTAssertEqual(h.client.auth.currentSession?.user.isAnonymous, true)
        assertNoPlants(h)
        assertClosed(h)
    }

    func testNativeSuccessUsesSameSDKExactOperationAndDurableReceiptWithoutForeignTransfer() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID(), operation = UUID(), foreign = UUID()
        let model = try await guestModel(h, flow: flow, operation: operation)
        _ = try await h.store.enqueueCommand(
            ownerId: owner, plantId: UUID(), commandName: "care.complete", payloadJSON: "{}"
        )
        _ = try await h.store.enqueueCommand(
            ownerId: foreign, plantId: UUID(), commandName: "care.complete", payloadJSON: "{}"
        )
        let oldQueue = try await h.store.pendingOutboxEntries(for: owner)
        let foreignQueue = try await h.store.pendingOutboxEntries(for: foreign)
        let disk = ModelContext(h.store.modelContainer)
        disk.insert(SyncedEntityRecord(
            ownerId: owner, entityType: "care_event", entityId: UUID(), updatedAt: Date(),
            payloadJSON: #"{"fixture":"guest-history"}"#
        ))
        try disk.save()
        try auth(h, owner: other, token: "fixture-permanent")
        try plants(h)
        let result = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        let permanent = try continued(result)
        assertRedacted(model)
        XCTAssertFalse(permanent === model)
        XCTAssertEqual(h.client.auth.currentSession?.user.id, other)
        XCTAssertEqual(h.client.auth.currentSession?.user.isAnonymous, false)
        let snapshot = try await h.connection.sessionSnapshot()
        XCTAssertEqual(h.connection.nativeAuthState, .signedIn(other))
        XCTAssertEqual(try h.connection.resumableFlow(expected: snapshot), flow)
        guard case let .saved(receipt) = permanent.state else { return XCTFail("Actual receipt required") }
        let persisted = try await h.store.catalogueCreateConfirmation(ownerId: other, operationId: operation)
        XCTAssertEqual(persisted, receipt)
        XCTAssertEqual(receipt.ownerId, other)
        XCTAssertEqual(receipt.operationId, operation)
        let original = try XCTUnwrap(try diskInput(h, owner: owner, flow: flow))
        let destination = try XCTUnwrap(try diskInput(h, owner: other, flow: flow))
        XCTAssertEqual(Data(destination.envelope.payloadJSON.utf8), Data(original.envelope.payloadJSON.utf8))
        XCTAssertEqual(receipt.payloadJSON, original.envelope.payloadJSON)
        let afterOld = try await h.store.pendingOutboxEntries(for: owner)
        let afterForeign = try await h.store.pendingOutboxEntries(for: foreign)
        XCTAssertEqual(afterOld, oldQueue)
        XCTAssertEqual(afterForeign, foreignQueue)
        let reopened = ModelContext(try Harness.container(h.directory.appendingPathComponent("connection.sqlite")))
        let history = try reopened.fetch(FetchDescriptor<SyncedEntityRecord>())
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.ownerId, owner)
        XCTAssertEqual(history.first?.payloadJSON, #"{"fixture":"guest-history"}"#)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<CatalogueCreateConfirmationRecord>()), 1)
        let posts = h.fixture.captured.filter { $0.url?.path.hasSuffix("/commands") == true }
        XCTAssertEqual(posts.count, 1)
        let sent = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(posts.first?.httpBody))
        XCTAssertEqual(sent.operationId, operation)
        XCTAssertEqual(Data(sent.payloadJSON.utf8), Data(original.envelope.payloadJSON.utf8))
        XCTAssertEqual(posts.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-permanent")
        XCTAssertEqual(h.identity.calls, 1)
        assertClosed(h)
    }

    func testNativeFirstSettlementIncludesManualPolicyAndDoesNotReloadSavedModel() async throws {
        for pending in [false, true] {
            let h = try Harness()
            defer { h.close() }
            let flow = UUID(), operation = UUID()
            let original = try await guestModel(h, flow: flow, operation: operation)
            let claims = try json(["sub": other.uuidString, "is_anonymous": false])
            let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            try auth(h, owner: other, token: "eyJhbGciOiJIUzI1NiJ9.\(payload).fixture-signature")
            try plants(h)
            let plant = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
            let time = "2026-11-04T09:00:00.123456+00:00"
            h.fixture.append(.init(method: "GET", path: "/functions/v1/plants-api/sync",
                data: try json([
                    "until": time, "next_since": time, "has_more": false, "last_cursor": NSNull(),
                    "entitlement": NSNull(),
                    "profile": ["preferred_locale": "pl", "reminder_hour_local": 9,
                                "report_notifications_enabled": true, "trial_reminder_enabled": false],
                    "changes": [["entity_type": "plants", "id": plant.uuidString, "updated_at": time,
                        "deleted_at": NSNull(), "data": ["id": plant.uuidString, "plant_id": "fixture-fern",
                                                         "revision": 1, "care_revision": 1]]]
                ]), suspend: true, query: "limit=200"))
            var completions = 0
            let signing = Task { await h.connection.signInAndSave(original, with: .apple, presenting: UIViewController(),
                includeManualWateringActions: true, completion: { _ in
                    CatalogueSaveCompletion(isCurrent: { true }, publish: { completions += 1 })
                }) }
            try await waitForSuspension(h.fixture)
            XCTAssertEqual(completions, 0)
            if pending {
                let api = try XCTUnwrap(h.connection.apiClient)
                let sdk = try await h.connection.sessionSnapshot()
                let lease = try await api.captureSyncContext(ownerId: sdk.session.userId)
                let queued = try ManualWateringAction.record.envelope(plantId: plant)
                try await h.store.enqueueManualWatering(queued, context: lease, authority: api.syncAuthority)
            }
            h.fixture.release()
            let result = await signing.value
            let permanent = try continued(result)
            // Outcome precedes SwiftUI adoption: its .loaded skip must preserve this ready phase.
            guard case .loaded = permanent.cardState else { return XCTFail("First settlement required") }
            XCTAssertEqual(permanent.manualWateringState, pending ? .pending : .ready)
            XCTAssertEqual(completions, 1)
            XCTAssertEqual(permanent.envelope?.operationId, operation)
            XCTAssertEqual(permanent.checkpoint?.flowId, flow)
            let source = try XCTUnwrap(try diskInput(h, owner: owner, flow: flow))
            XCTAssertEqual(permanent.envelope?.payloadJSON, source.envelope.payloadJSON)
            await permanent.save(completion: CatalogueSaveCompletion(
                isCurrent: { true }, publish: { completions += 1 }), includeManualWateringActions: true)
            XCTAssertEqual(permanent.manualWateringState, pending ? .pending : .ready)
            XCTAssertEqual(completions, 1)
            let requests = h.fixture.captured.filter { $0.url?.path.contains("/plants-api/") == true }
            XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["sync", "commands", "sync"])
            XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
            assertRedacted(original)
            assertClosed(h)
        }
    }

    func testNativeSameUUIDStillReplacesGuestModelAndSDKGeneration() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID(), operation = UUID()
        let model = try await guestModel(h, flow: flow, operation: operation)
        let before = try await h.connection.sessionSnapshot()
        try auth(h, owner: owner) // Same UUID AND token, but actual SDK permanent truth.
        try plants(h)
        let result = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        let permanent = try continued(result)
        let after = try await h.connection.sessionSnapshot()
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.session, after.session)
        XCTAssertFalse(after.isAnonymous)
        assertRedacted(model)
        XCTAssertFalse(permanent === model)
        guard case let .saved(receipt) = permanent.state else { return XCTFail("Durable receipt required") }
        XCTAssertEqual(receipt.operationId, operation)
        assertClosed(h)
    }

    func testNativeProviderExchangeAndInvalidSDKResultsNeverReportSavedOrLoseInput() async throws {
        for mode in 0..<5 {
            let h = try Harness()
            defer { h.close() }
            let flow = UUID(), operation = UUID()
            let model = try await guestModel(h, flow: flow, operation: operation)
            if mode == 0 {
                h.identity.result = .failure(URLError(.notConnectedToInternet))
            } else if mode == 1 {
                h.fixture.append(.init(
                    method: "POST", path: "/auth/v1/token",
                    data: try json(["code": "invalid_credentials", "message": "Fixture rejected"]),
                    status: 400, query: "grant_type=id_token"
                ))
            } else if mode == 2 {
                h.identity.result = .success(.init(provider: .google, idToken: "FIXTURE-WRONG-PROVIDER"))
            } else {
                try auth(h, owner: other, anonymous: mode == 3, expired: mode == 4)
            }
            let result = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
            if mode < 3 {
                guard case let .inputRetained(retained, .authenticationFailed(reason)) = result else {
                    return XCTFail("Failed auth must retain the guest input")
                }
                XCTAssertTrue(retained === model)
                XCTAssertEqual(reason, mode == 0 ? .providerFailed : (mode == 1 ? .exchangeFailed : .invalidCredential))
                XCTAssertEqual(h.client.auth.currentSession?.user.isAnonymous, true)
                XCTAssertEqual(model.input, input)
            } else {
                assertUnavailable(result, .sessionChanged)
                assertRedacted(model)
                XCTAssertEqual(h.connection.nativeAuthState, .failed(.invalidCredential))
            }
            let original = try XCTUnwrap(try diskInput(h, owner: owner, flow: flow))
            XCTAssertEqual(Data(original.envelope.payloadJSON.utf8), Data(try input.makeEnvelope(operationId: operation).payloadJSON.utf8))
            XCTAssertNil(try diskInput(h, owner: other, flow: flow))
            XCTAssertTrue((h.defaults.persistentDomain(forName: h.defaultsSuite) ?? [:]).isEmpty)
            let disk = ModelContext(h.store.modelContainer)
            XCTAssertEqual(try disk.fetchCount(FetchDescriptor<CatalogueCreateConfirmationRecord>()), 0)
            assertNoPlants(h)
            assertClosed(h)
        }
    }

    func testNativeOwnerChangeOrABADuringProviderAbortsBeforeIntendedExchange() async throws {
        for aba in [false, true] {
            let h = try Harness()
            defer { h.close() }
            let flow = UUID()
            let model = try await guestModel(h, flow: flow, operation: UUID())
            h.identity.onRequest = {
                try self.auth(h, owner: self.other, token: "fixture-unrelated")
                try await h.signIn()
                if aba {
                    try self.auth(h, owner: self.owner, anonymous: true)
                    try await h.signIn()
                }
            }
            let result = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
            assertUnavailable(result, .sessionChanged)
            XCTAssertEqual(h.identity.calls, 1)
            XCTAssertEqual(h.fixture.captured.filter { $0.url?.path == "/auth/v1/token" }.count, aba ? 2 : 1)
            XCTAssertNotNil(try diskInput(h, owner: owner, flow: flow))
            assertRedacted(model)
            XCTAssertTrue((h.defaults.persistentDomain(forName: h.defaultsSuite) ?? [:]).isEmpty)
            assertNoPlants(h)
            assertClosed(h)
        }
    }

    func testNativeUnrelatedOwnerDuringExchangeRejectedEvenWhenSDKEndsAtIntendedResult() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID()
        let model = try await guestModel(h, flow: flow, operation: UUID())
        try auth(h, owner: other, token: "fixture-intended", suspend: true)
        let signing = Task {
            await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        }
        try await waitForSuspension(h.fixture)
        try auth(h, owner: UUID(), token: "fixture-unrelated")
        try await h.signIn()
        h.fixture.release()
        let result = await signing.value
        assertUnavailable(result, .sessionChanged)
        XCTAssertEqual(h.client.auth.currentSession?.user.id, other)
        XCTAssertEqual(h.client.auth.currentSession?.accessToken, "fixture-intended")
        XCTAssertEqual(h.connection.nativeAuthState, .signedIn(other))
        XCTAssertNotNil(try diskInput(h, owner: owner, flow: flow))
        XCTAssertNil(try diskInput(h, owner: other, flow: flow))
        XCTAssertTrue((h.defaults.persistentDomain(forName: h.defaultsSuite) ?? [:]).isEmpty)
        assertRedacted(model)
        assertNoPlants(h)
        assertClosed(h)
    }

    func testNativeCommittedExchangeCancellationKeepsSDKAndNewOwnerInputUntilExplicitRetry() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID(), operation = UUID()
        let model = try await guestModel(h, flow: flow, operation: operation)
        try auth(h, owner: other, token: "fixture-permanent")
        let cancellation = ConnectionCancellation()
        let target = other
        // Cancel synchronously AFTER _signIn committed the real SDK session.
        let registration = await h.client.auth.onAuthStateChange { event, session in
            if event == .signedIn && session?.user.id == target { cancellation.cancel() }
        }
        defer { registration.remove() }
        let signing = Task {
            await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        }
        cancellation.set { signing.cancel() }
        let result = await signing.value
        guard case let .inputRetained(permanent, .cancelled) = result else {
            return XCTFail("Committed auth must retain input without automatic create")
        }
        XCTAssertFalse(permanent === model)
        XCTAssertEqual(h.client.auth.currentSession?.user.id, other)
        XCTAssertEqual(h.client.auth.currentSession?.user.isAnonymous, false)
        XCTAssertEqual(h.connection.nativeAuthState, .signedIn(other))
        assertRedacted(model)
        let expected = try await h.connection.sessionSnapshot()
        XCTAssertEqual(try h.connection.resumableFlow(expected: expected), flow)
        let retained = try XCTUnwrap(try diskInput(h, owner: other, flow: flow))
        XCTAssertEqual(retained.operationId, operation)
        let envelope = try input.makeEnvelope(operationId: operation)
        XCTAssertEqual(Data(retained.envelope.payloadJSON.utf8), Data(envelope.payloadJSON.utf8))
        XCTAssertNotNil(try diskInput(h, owner: owner, flow: flow))
        assertNoPlants(h)
        let queue = try await h.store.pendingOutboxEntries(for: other)
        XCTAssertTrue(queue.isEmpty)
        let metadata = h.defaults.persistentDomain(forName: h.defaultsSuite) ?? [:]
        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(metadata.values.compactMap { $0 as? String }, [flow.uuidString])
        guard case let .restored(retry) = await h.connection.restoreModel(
            ownerId: other, flowId: flow, expected: expected
        ) else { return XCTFail("Explicit owner/flow restoration required") }
        try plants(h)
        await retry.save()
        guard case let .saved(receipt) = retry.state else { return XCTFail("Retry must get an actual receipt") }
        XCTAssertEqual(receipt.operationId, operation)
        XCTAssertEqual(receipt.payloadJSON, envelope.payloadJSON)
        XCTAssertEqual(h.fixture.captured.filter { $0.url?.path.hasSuffix("/commands") == true }.count, 1)
        XCTAssertEqual(try h.connection.resumableFlow(expected: expected), flow)
        try auth(h, owner: owner, token: "fixture-switched")
        try await h.signIn()
        let switched = try await h.connection.sessionSnapshot()
        XCTAssertNil(try h.connection.resumableFlow(expected: switched))
        XCTAssertThrowsError(try h.connection.resumableFlow(expected: expected))
        assertRedacted(permanent)
        assertClosed(h)
    }

    func testNativeWithdrawnOriginalIntentDuringProviderNeverExchangesOrCreates() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID(), operation = UUID()
        let model = try await guestModel(h, flow: flow, operation: operation)
        h.identity.onRequest = { model.cancel() }
        let result = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        guard case .inputRetained(_, .cancelled) = result else { return XCTFail("Withdrawn intent must stop auth") }
        XCTAssertEqual(h.connection.nativeAuthState, .cancelled)
        XCTAssertEqual(h.client.auth.currentSession?.user.isAnonymous, true)
        XCTAssertEqual(try diskInput(h, owner: owner, flow: flow)?.operationId, operation)
        XCTAssertEqual(h.fixture.captured.map(\.url?.path), ["/auth/v1/signup"])
        assertClosed(h)
    }

    func testNativeBusyGuardDoesNotOpenAnotherProviderOrCreateAnotherCheckpoint() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID()
        let model = try await guestModel(h, flow: flow, operation: UUID())
        var gate: CheckedContinuation<Void, Never>?
        h.identity.onRequest = { await withCheckedContinuation { gate = $0 } }
        h.identity.result = .failure(CancellationError())
        let signing = Task {
            await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        }
        let deadline = Date().addingTimeInterval(5)
        while gate == nil && Date() < deadline { await Task.yield() }
        guard let release = gate else {
            signing.cancel()
            _ = await signing.value
            return XCTFail("Provider did not open")
        }
        let duplicate = await h.connection.signInAndSave(model, with: .google, presenting: UIViewController())
        guard case .busy = duplicate else {
            release.resume()
            _ = await signing.value
            return XCTFail("Concurrent native flow must be busy")
        }
        XCTAssertEqual(h.identity.calls, 1)
        let disk = ModelContext(h.store.modelContainer)
        XCTAssertEqual(try disk.fetchCount(FetchDescriptor<CatalogueInputCheckpointRecord>()), 1)
        release.resume()
        _ = await signing.value
        assertNoPlants(h)
        assertClosed(h)
    }

    func testNativeForeignOperationConflictNeverMovesQueueOrContinuesCreate() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID(), operation = UUID(), foreign = UUID()
        let model = try await guestModel(h, flow: flow, operation: operation)
        let envelope = try input.makeEnvelope(operationId: operation)
        h.identity.onRequest = {
            let disk = ModelContext(h.store.modelContainer)
            disk.insert(LocalOutboxRecord(
                operationId: operation, ownerId: foreign, commandName: "plant.create",
                payloadJSON: envelope.payloadJSON, sequenceNumber: 1
            ))
            try disk.save()
        }
        try auth(h, owner: other, token: "fixture-permanent")
        let result = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        assertUnavailable(result, .storageOrServiceUnavailable)
        XCTAssertEqual(h.client.auth.currentSession?.user.id, other)
        XCTAssertNotNil(try diskInput(h, owner: owner, flow: flow))
        XCTAssertNil(try diskInput(h, owner: other, flow: flow))
        let foreignQueue = try await h.store.pendingOutboxEntries(for: foreign)
        XCTAssertEqual(foreignQueue.count, 1)
        XCTAssertEqual(foreignQueue.first?.operationId, operation)
        XCTAssertEqual(foreignQueue.first?.ownerId, foreign)
        XCTAssertEqual(foreignQueue.first?.payloadJSON, envelope.payloadJSON)
        XCTAssertTrue((h.defaults.persistentDomain(forName: h.defaultsSuite) ?? [:]).isEmpty)
        assertNoPlants(h)
        assertClosed(h)
    }

    func testNativeServerLimitRemainsTypedPendingAndPreservesNewOwnerInput() async throws {
        let h = try Harness()
        defer { h.close() }
        let flow = UUID(), operation = UUID()
        let model = try await guestModel(h, flow: flow, operation: operation)
        try auth(h, owner: other, token: "fixture-permanent")
        let error = try json([
            "error": ["code": "COLLECTION_LIMIT_REACHED", "message": "Limit", "retryable": false]
        ])
        try plants(h, commandStatus: 409, commandError: error)
        let result = await h.connection.signInAndSave(model, with: .apple, presenting: UIViewController())
        let permanent = try continued(result)
        guard case let .pending(entry) = permanent.state else { return XCTFail("Server limit must remain pending") }
        XCTAssertEqual(entry.operationId, operation)
        XCTAssertEqual(permanent.pendingAPIError, try JSONDecoder().decode(APIErrorResponse.self, from: error))
        XCTAssertEqual(permanent.input, input)
        XCTAssertEqual(try diskInput(h, owner: other, flow: flow)?.operationId, operation)
        let receipt = try await h.store.catalogueCreateConfirmation(ownerId: other, operationId: operation)
        XCTAssertNil(receipt)
        assertClosed(h)
    }

    func testConcurrentStartupUsesOneRealSDKSignupAndSameClientCatalogueRPC() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner, anonymous: true, signup: true, suspend: true)
        let first = Task { try await h.connection.sessionOwner() }
        try await waitForSuspension(h.fixture)
        var second: Task<UUID, Error>?
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            second = Task {
                entered.resume()
                return try await h.connection.sessionOwner()
            }
        }
        h.fixture.release()
        let firstOwner = try await first.value
        let secondOwner = try await XCTUnwrap(second).value
        XCTAssertEqual(firstOwner, owner)
        XCTAssertEqual(secondOwner, owner)
        let snapshot = try await h.connection.sessionSnapshot()
        let sdk = try XCTUnwrap(h.client.auth.currentSession)
        XCTAssertEqual(snapshot.session.userId, sdk.user.id)
        XCTAssertEqual(snapshot.session.accessToken, sdk.accessToken)
        XCTAssertEqual(snapshot.session.expiresAt, Date(timeIntervalSince1970: sdk.expiresAt))
        XCTAssertEqual(snapshot.isAnonymous, sdk.user.isAnonymous)
        XCTAssertTrue(snapshot.isAnonymous)
        XCTAssertTrue(h.connection.client === h.client)
        h.fixture.append(.init(
            method: "POST", path: "/rest/v1/rpc/search_catalogue_species",
            data: try json(["items": []])
        ))
        _ = try await h.connection.client!.rpc(
            "search_catalogue_species", params: ["p_locale": "pl"]
        ).execute()
        XCTAssertEqual(h.fixture.captured.map(\.url?.path), [
            "/auth/v1/signup", "/rest/v1/rpc/search_catalogue_species"
        ])
        XCTAssertEqual(h.fixture.captured.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-a")
        let api = try XCTUnwrap(h.connection.apiClient)
        let baseURL = await api.baseURL
        XCTAssertEqual(baseURL, h.configuration.supabaseURL.appendingPathComponent("functions/v1/plants-api"))
        assertClosed(h)
    }

    func testAnonymousModelCheckpointsExactInputWithoutPlantsHTTP() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner, anonymous: true, signup: true)
        _ = try await h.connection.sessionOwner()
        let snapshot = try await h.connection.sessionSnapshot()
        let flow = UUID(), operation = UUID()
        let model = try await h.connection.makeModel(
            input: input, flowId: flow, operationId: operation, expected: snapshot
        )
        // Identical reads must preserve the original model's lease.
        _ = try await h.connection.sessionSnapshot()
        _ = try await h.connection.sessionSnapshot()
        await model.save()
        XCTAssertEqual(model.state, .signInRequired)
        XCTAssertEqual(model.input, input)
        XCTAssertEqual(model.checkpoint?.flowId, flow)
        XCTAssertEqual(model.checkpoint?.envelope, try input.makeEnvelope(operationId: operation))
        let queue = try await h.store.pendingOutboxEntries(for: owner)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(h.fixture.captured.map(\.url?.path), ["/auth/v1/signup"])
        assertClosed(h)
    }

#if DEBUG && targetEnvironment(simulator)
    private func guestDiagnosisResult(
        identification: IdentificationStatus = .resolved, plant: String? = "monstera_deliciosa",
        mode: AnalysisMode = .diagnosis
    ) -> PreliminaryAnalysis {
        PreliminaryAnalysis(
            id: UUID(), jobId: UUID(), kbReleaseId: UUID(), mode: mode,
            identificationStatus: identification, plantId: plant, genusId: nil,
            diagnosisStatus: .healthy, candidates: [], selectedConditionId: nil,
            visualMarkers: [], evidenceBasis: [], limitations: [], firstActionSummary: nil,
            controlIntervalDays: nil, analysisReceipt: "fixture-receipt"
        )
    }

    func testResumedGuestDiagnosisOrdinaryEmailRequiresCurrentScopeWithoutReplayingDraft() async throws {
        // 0: unchanged; 1: refresh before opening; 2: refresh after opening;
        // 3: unrelated owner; 4: guest -> unrelated owner -> same guest (ABA).
        for scenario in 0..<5 {
            let h = try Harness()
            defer { h.close() }
            await h.ready()
            let payload = try json(["sub": owner.uuidString, "is_anonymous": true]).base64EncodedString()
            let token = "header.\(payload).signature"
            try auth(h, owner: owner, token: token, anonymous: true, signup: true)
            _ = try await h.connection.sessionOwner()
            let originalScope = try await h.connection.accountScope()
            let original = try XCTUnwrap(originalScope.snapshot)
            let selection = try XCTUnwrap(GuestDiagnosisSelection(
                result: guestDiagnosisResult(), photo: (UUID(), owner),
                isInitial: true, expected: original
            ))
            let registration = try json(["installation_id": UUID().uuidString])
            let registerPath = "/functions/v1/plants-api/installations/register"
            let draftPath = "/functions/v1/plants-api/drafts"
            h.fixture.append(.init(method: "POST", path: registerPath, data: registration))
            h.fixture.append(.init(
                method: "POST", path: draftPath,
                data: try json(["draft_id": UUID().uuidString, "expires_at": "2026-11-19T08:30:00Z"])
            ))
            let initial = GuestPhotoClaim(connection: h.connection, credential: "fixture-stable-installation")
            try await initial.register(original)
            let created = await initial.createDraft(selection)
            XCTAssertEqual(created, .ready)
            let journal = try XCTUnwrap(h.connection.guestPhotoClaimData())
            h.identity.result = .failure(CancellationError())
            let cancelled = try await h.connection.signInAccount(
                with: .apple, presenting: UIViewController(), scope: originalScope
            )
            XCTAssertNil(cancelled)
            XCTAssertEqual(h.connection.guestPhotoClaimData(), journal)

            // A second connection reopens SQLite and the same defaults suite.
            // The SDK is retained: this covers app binding, not Keychain/process restoration.
            let connection = try reopenedConnection(h)
            let restored = try await connection.sessionSnapshot()
            let resumed = GuestPhotoClaim(connection: connection, credential: "fixture-stable-installation")
            h.fixture.append(.init(method: "POST", path: registerPath, data: registration))
            try await resumed.register(restored)
            XCTAssertTrue(resumed.canResumeDraft(for: restored))
            let outcome = await resumed.resumeDraft()
            XCTAssertEqual(outcome, .ready)
            XCTAssertEqual(connection.guestPhotoClaimData(), journal)

            if scenario == 1 {
                try auth(h, owner: owner, token: token, anonymous: true, refresh: true)
                _ = try await h.client.auth.refreshSession()
                _ = try await connection.sessionSnapshot()
            }
            let scope = try await connection.accountScope()
            XCTAssertEqual(scope.snapshot?.session.userId, owner)
            XCTAssertEqual(scope.snapshot?.isAnonymous, true)
            let before = metadata(h)
            if scenario == 2 {
                try auth(h, owner: owner, token: token, anonymous: true, refresh: true)
                _ = try await h.client.auth.refreshSession()
            } else if scenario >= 3 {
                try auth(h, owner: other)
                try await h.signIn()
                if scenario == 4 {
                    try auth(h, owner: owner, token: token, anonymous: true)
                    try await h.signIn()
                }
            }
            let requestCount = h.fixture.captured.count
            if scenario < 2 {
                try auth(h, owner: other, token: "fixture-email", grant: "password")
                let signedIn = try await connection.signInAccount(
                    email: "fixture@example.invalid", password: "fixture", scope: scope
                )
                let permanent = try XCTUnwrap(signedIn)
                XCTAssertEqual(permanent.session.userId, other)
                XCTAssertFalse(permanent.isAnonymous)
                XCTAssertEqual(connection.snapshot, permanent)
                XCTAssertEqual(h.fixture.captured.count, requestCount + 1)
                XCTAssertEqual(h.fixture.captured.last?.url?.query, "grant_type=password")
            } else {
                do {
                    _ = try await connection.signInAccount(
                        email: "fixture@example.invalid", password: "fixture", scope: scope
                    )
                    XCTFail("Stale or replaced scope must fail before password HTTP")
                } catch {
                    XCTAssertEqual(error as? CatalogueSaveUnavailable, .sessionChanged)
                }
                XCTAssertEqual(h.fixture.captured.count, requestCount)
            }
            XCTAssertFalse(connection.authenticationInFlight)
            XCTAssertEqual(metadata(h), before)
            XCTAssertEqual(connection.guestPhotoClaimData(), journal)
            XCTAssertEqual(h.identity.calls, 1)
            XCTAssertEqual(h.fixture.captured.filter { $0.url?.path == draftPath }.count, 1)
            XCTAssertFalse(h.fixture.captured.contains { $0.url?.path.contains("/claims") == true })
            let guestQueue = try await h.store.pendingOutboxEntries(for: owner)
            let permanentQueue = try await h.store.pendingOutboxEntries(for: other)
            XCTAssertTrue(guestQueue.isEmpty)
            XCTAssertTrue(permanentQueue.isEmpty)
            assertClosed(h)
        }
    }

    func testGuestDiagnosisDraftIsExplicitBoundRestartSafeAndSurvivesAccountCancellation() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        let payload = try json(["sub": owner.uuidString, "is_anonymous": true]).base64EncodedString()
        try auth(h, owner: owner, token: "header.\(payload).signature", anonymous: true, signup: true)
        _ = try await h.connection.sessionOwner()
        let scope = try await h.connection.accountScope()
        let original = try XCTUnwrap(scope.snapshot)
        let photo = UUID(), installation = UUID()
        let result = guestDiagnosisResult()
        let selection = try XCTUnwrap(GuestDiagnosisSelection(
            result: result, photo: (photo, owner), isInitial: true, expected: original
        ))
        XCTAssertEqual(selection.jobId, result.jobId)
        XCTAssertNil(GuestDiagnosisSelection(result: result, photo: nil, isInitial: true, expected: original))
        XCTAssertNil(GuestDiagnosisSelection(result: result, photo: (photo, other), isInitial: true, expected: original))
        XCTAssertNil(GuestDiagnosisSelection(result: result, photo: (photo, owner), isInitial: false, expected: original))
        for invalid in [
            guestDiagnosisResult(identification: .unknown),
            guestDiagnosisResult(plant: nil), guestDiagnosisResult(plant: "  "),
            guestDiagnosisResult(mode: .identification)
        ] {
            XCTAssertNil(GuestDiagnosisSelection(result: invalid, photo: (photo, owner),
                                                isInitial: true, expected: original))
        }
        XCTAssertNil(h.connection.guestPhotoClaimData())
        XCTAssertEqual(h.identity.calls, 0)
        let registerPath = "/functions/v1/plants-api/installations/register"
        let draftPath = "/functions/v1/plants-api/drafts"
        let registration = try json(["installation_id": installation.uuidString])
        h.fixture.append(.init(method: "POST", path: registerPath, data: registration))
        h.fixture.append(.init(method: "POST", path: draftPath, data: Data(), failure: .networkConnectionLost))
        let initial = GuestPhotoClaim(connection: h.connection, credential: "fixture-stable-installation")
        try await initial.register(original)
        let lost = await initial.createDraft(selection)
        XCTAssertEqual(lost, .failed)
        let pending = try XCTUnwrap(h.connection.guestPhotoClaimData())

        let restarted = GuestPhotoClaim(connection: h.connection, credential: "fixture-stable-installation")
        h.fixture.append(.init(method: "POST", path: registerPath,
                               data: try json(["installation_id": UUID().uuidString])))
        try await restarted.register(original)
        XCTAssertFalse(restarted.canResumeDraft(for: original))
        let wrongInstallation = await restarted.resumeDraft()
        XCTAssertEqual(wrongInstallation, .failed)
        XCTAssertEqual(h.connection.guestPhotoClaimData(), pending)
        h.fixture.append(.init(method: "POST", path: registerPath, data: registration))
        try await restarted.register(original)
        let foreignSource = try XCTUnwrap(GuestDiagnosisSelection(
            result: guestDiagnosisResult(), photo: (photo, owner), isInitial: true, expected: original
        ))
        let rejected = await restarted.createDraft(foreignSource)
        XCTAssertEqual(rejected, .failed)
        XCTAssertEqual(h.connection.guestPhotoClaimData(), pending)
        h.fixture.append(.init(method: "POST", path: draftPath,
                               data: try json(["draft_id": UUID().uuidString, "expires_at": "2026-11-19T08:30:00Z"])))
        let resumed = await restarted.resumeDraft()
        XCTAssertEqual(resumed, .ready)
        let ready = try XCTUnwrap(h.connection.guestPhotoClaimData())
        h.identity.result = .failure(CancellationError())
        let cancelled = try await h.connection.signInAccount(with: .apple, presenting: UIViewController(), scope: scope)
        XCTAssertNil(cancelled)
        XCTAssertEqual(h.connection.snapshot, original)
        XCTAssertEqual(h.connection.guestPhotoClaimData(), ready)

        let reopened = GuestPhotoClaim(connection: h.connection, credential: "fixture-stable-installation")
        h.fixture.append(.init(method: "POST", path: registerPath, data: registration))
        try await reopened.register(original)
        let sameDraft = await reopened.createDraft(selection)
        XCTAssertEqual(sameDraft, .ready)
        XCTAssertEqual(h.connection.guestPhotoClaimData(), ready)
        let posts = h.fixture.captured.filter { $0.url?.path == draftPath }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.first?.httpBody, posts.last?.httpBody)
        let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(posts.last?.httpBody))
        let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: ready) as? [String: Any])
        XCTAssertEqual(body, ["operation_id": (journal["draftOperationId"] as? String)?.lowercased() ?? "",
                              "diagnosis_job_id": result.jobId.uuidString.lowercased()])
        XCTAssertNil(journal["taxonId"])
        XCTAssertEqual(journal["source"] as? String, "diagnosis")
        XCTAssertEqual(h.identity.calls, 1)

        h.identity.result = .success(.init(provider: .apple, idToken: "FIXTURE-ONLY-ID-TOKEN", nonce: "fixture-nonce"))
        try auth(h, owner: other)
        let signedIn = try await h.connection.signInAccount(with: .apple, presenting: UIViewController(), scope: scope)
        let permanent = try XCTUnwrap(signedIn)
        XCTAssertFalse(reopened.pending(for: permanent))
        XCTAssertNil(GuestDiagnosisSelection(result: result, photo: (photo, owner),
                                            isInitial: true, expected: permanent))
        XCTAssertThrowsError(try reopened.acceptDestination(permanent, from: permanent))
        try reopened.acceptDestination(permanent, from: original)
        XCTAssertTrue(reopened.pending(for: permanent))
        let accepted = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(h.connection.guestPhotoClaimData())) as? [String: Any])
        for key in ["draftOperationId", "prepareOperationId", "commitOperationId", "draft", "source"] {
            XCTAssertEqual(journal[key] as? NSObject, accepted[key] as? NSObject)
        }
        assertClosed(h)
    }

    func testOrdinaryPhotoClaimRequiresExplicitMatchingGuestAndKeepsOperationIDs() async throws {
        let h = try Harness()
        defer { h.close() }
        _ = try await guestModel(h, flow: UUID(), operation: UUID())
        let scope = try await h.connection.accountScope()
        let original = try XCTUnwrap(scope.snapshot)
        h.fixture.append(.init(
            method: "POST", path: "/functions/v1/plants-api/installations/register",
            data: try json(["installation_id": UUID().uuidString])
        ))
        h.fixture.append(.init(
            method: "POST", path: "/functions/v1/plants-api/drafts",
            data: try json(["draft_id": UUID().uuidString, "expires_at": "2026-11-19T08:30:00Z"])
        ))
        let claim = GuestPhotoClaim(connection: h.connection, credential: "fixture-installation")
        try await claim.register(original)
        let draft = await claim.createDraft(.init(
            jobId: UUID(), photoAssetId: UUID(), speciesSlug: "monstera_deliciosa", taxonId: UUID(), ownerId: owner
        ))
        XCTAssertEqual(draft, .ready)
        let before = try XCTUnwrap(h.connection.guestPhotoClaimData())
        try auth(h, owner: other)
        let result = try await h.connection.signInAccount(with: .apple, presenting: UIViewController(), scope: scope)
        let permanent = try XCTUnwrap(result)
        XCTAssertFalse(claim.pending(for: permanent))
        XCTAssertEqual(h.connection.guestPhotoClaimData(), before)
        do {
            try claim.acceptDestination(permanent, from: permanent)
            XCTFail("Permanent or foreign source cannot authorize a guest claim")
        } catch {
            guard case SyncWireValidationError.invalidSession = error else {
                return XCTFail("Expected invalid source scope")
            }
        }
        XCTAssertEqual(h.connection.guestPhotoClaimData(), before)
        try claim.acceptDestination(permanent, from: original)
        XCTAssertTrue(claim.pending(for: permanent))
        let after = try XCTUnwrap(h.connection.guestPhotoClaimData())
        let old = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        let new = try XCTUnwrap(JSONSerialization.jsonObject(with: after) as? [String: Any])
        for key in ["draftOperationId", "prepareOperationId", "commitOperationId", "draft"] {
            XCTAssertEqual(old[key] as? NSObject, new[key] as? NSObject)
        }
        XCTAssertEqual(h.fixture.captured.map(\.url?.path), [
            "/auth/v1/signup", "/functions/v1/plants-api/installations/register",
            "/functions/v1/plants-api/drafts", "/auth/v1/token"
        ])
        assertClosed(h)
    }

    func testGuestDraftResumesLostResponseFromPersistedInputWithoutIdentificationScreen() async throws {
        let credential = "fixture-stable-installation"
        let registerPath = "/functions/v1/plants-api/installations/register"
        let draftPath = "/functions/v1/plants-api/drafts"
        for expires in [false, true] {
            let h = try Harness()
            defer { h.close() }
            await h.ready()
            try auth(h, owner: owner, anonymous: true, signup: true)
            _ = try await h.connection.sessionOwner()
            let scope = try await h.connection.sessionSnapshot()
            let installation = UUID()
            let registration = try json(["installation_id": installation.uuidString])
            h.fixture.append(.init(method: "POST", path: registerPath, data: registration))
            h.fixture.append(.init(method: "POST", path: draftPath, data: Data(), failure: .networkConnectionLost))
            let selection = PhotoIdentificationSelection(
                jobId: UUID(), photoAssetId: UUID(), speciesSlug: "monstera_deliciosa", taxonId: UUID(), ownerId: owner
            )
            do {
                let initial = GuestPhotoClaim(connection: h.connection, credential: credential)
                try await initial.register(scope)
                let lost = await initial.createDraft(selection)
                XCTAssertEqual(lost, .failed)
            }
            let legacyData = try XCTUnwrap(h.connection.guestPhotoClaimData())
            let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
            XCTAssertNil(legacy["source"])
            XCTAssertNil(legacy["draft"])
            XCTAssertEqual(legacy["taxonId"] as? String, selection.taxonId.uuidString)
            h.fixture.append(.init(method: "POST", path: registerPath, data: registration))
            let reply = expires ? try json(["error": ["code": "DRAFT_EXPIRED", "message": "Expired", "retryable": false]])
                : try json(["draft_id": UUID().uuidString, "expires_at": "2026-11-19T08:30:00Z"])
            h.fixture.append(.init(method: "POST", path: draftPath, data: reply, status: expires ? 410 : 200))
            let restarted = GuestPhotoClaim(connection: h.connection, credential: credential)
            try await restarted.register(scope)
            XCTAssertTrue(restarted.canResumeDraft(for: scope))
            let resumed = await restarted.resumeDraft()
            XCTAssertEqual(resumed, expires ? .expired : .ready)
            XCTAssertEqual(restarted.canResumeDraft(for: scope), !expires)
            XCTAssertEqual(h.connection.guestPhotoClaimData() == nil, expires)
            let posts = h.fixture.captured.filter { $0.url?.path == draftPath }
            XCTAssertEqual(posts.count, 2)
            XCTAssertEqual(posts.first?.httpBody, posts.last?.httpBody)
            let identificationBody = try JSONDecoder().decode(
                [String: String].self, from: XCTUnwrap(posts.last?.httpBody)
            )
            XCTAssertEqual(Set(identificationBody.keys), ["operation_id", "identification_job_id", "taxon_id"])
            XCTAssertEqual(identificationBody["identification_job_id"], selection.jobId.uuidString.lowercased())
            XCTAssertEqual(identificationBody["taxon_id"], selection.taxonId.uuidString.lowercased())
            XCTAssertTrue(posts.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-a"
                    && $0.value(forHTTPHeaderField: "X-Installation-Credential") == credential
            })
            assertClosed(h)
        }
    }
#endif

    func testSavedDiagnosisConditionsRestoreAndRemainIsolated() async throws {
        // Exercise diagnosis, catalogue and identification through the real connection.
        for source in 0..<3 {
            let h = try Harness()
            defer { h.close() }
            await h.ready()
            try auth(h, owner: owner)
            try await h.signIn()
            let expected = try await h.connection.sessionSnapshot()
            let flow = UUID(), photo = UUID(), snapshot = UUID(), taxon = UUID()
            let plant = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
            let selected: CatalogueInput
            switch source {
            case 0: selected = CatalogueInput(diagnosisJobId: UUID(), speciesSlug: "fixture-fern")
            case 1: selected = input
            default: selected = CatalogueInput(identification: .init(jobId: UUID(), taxonId: taxon))
            }
            try plants(h, commandError: json([
                "plant_id": plant.uuidString, "photo_id": photo.uuidString, "care_revision": 1,
                "context_state": "current", "next_available_step": "enable_basic_care",
                "paid_action": NSNull(), "plan_availability": "available",
                "watermark": "2026-11-03T09:00:01.123456+00:00"
            ]))
            let model = try await h.connection.makeModel(
                input: selected, flowId: flow, operationId: UUID(), expected: expected
            )
            _ = try await h.connection.rememberModel(model, expected: expected)
            await model.save()
            guard case .saved = model.state else { return XCTFail("Confirmed receipt required") }
            XCTAssertNil(model.diagnosisConditions)

            func appendCard(pointer: UUID?, snapshotPlant: UUID? = nil) throws {
                let timestamp = "2026-11-03T09:00:02.123456+00:00"
                let rows: [[String: Any]] = [
                    ["entity_type": "condition_snapshots", "id": snapshot.uuidString,
                     "updated_at": timestamp, "deleted_at": NSNull(),
                     "data": ["id": snapshot.uuidString, "plant_id": (snapshotPlant ?? plant).uuidString,
                              "light_code": "bright_indirect", "watering_code": "weekly", "drainage_code": "yes"]],
                    ["entity_type": "plants", "id": plant.uuidString,
                     "updated_at": timestamp, "deleted_at": NSNull(),
                     "data": ["id": plant.uuidString, "plant_id": "fixture-fern", "taxon_id": taxon.uuidString,
                              "main_photo_id": photo.uuidString, "revision": 1, "care_revision": 1,
                              "current_condition_snapshot_id": pointer.map { $0.uuidString as Any } ?? NSNull()]]
                ]
                h.fixture.append(.init(method: "GET", path: "/functions/v1/plants-api/sync", data: try json([
                    "until": timestamp, "has_more": false, "last_cursor": NSNull(), "next_since": timestamp,
                    "entitlement": NSNull(), "changes": rows,
                    "profile": ["preferred_locale": "pl", "reminder_hour_local": 9,
                                "report_notifications_enabled": true, "trial_reminder_enabled": false]
                ]), query: "limit=200"))
            }
            func assertConditions(_ target: CatalogueSaveModel) {
                XCTAssertEqual(target.cardSummary?.id, plant)
                if source == 0 {
                    XCTAssertEqual(target.diagnosisConditions?.id, snapshot)
                    XCTAssertEqual(target.diagnosisConditions?.light, .brightIndirect)
                    XCTAssertEqual(target.diagnosisConditions?.watering, .weekly)
                    XCTAssertEqual(target.diagnosisConditions?.drainage, .yes)
                } else {
                    XCTAssertNil(target.diagnosisConditions)
                }
            }
            try appendCard(pointer: snapshot)
            await model.loadCard()
            assertConditions(model)

            // Reopen SQLite and restore the exact persisted flow with a new connection.
            let restarted = try reopenedConnection(h)
            let restoredScope = try await restarted.sessionSnapshot()
            guard case let .restored(restored) = await restarted.restoreModel(
                ownerId: owner, flowId: flow, expected: restoredScope
            ) else { return XCTFail("Exact saved flow must restore") }
            XCTAssertNil(restored.diagnosisConditions)
            try appendCard(pointer: snapshot)
            await restored.loadCard()
            assertConditions(restored)
            for pointer in [nil, UUID(), snapshot] as [UUID?] {
                // Missing pointer, old snapshot, and a snapshot belonging to another plant.
                try appendCard(pointer: pointer, snapshotPlant: pointer == snapshot ? other : plant)
                await restored.loadCard()
                XCTAssertNil(restored.diagnosisConditions)
                XCTAssertEqual(restored.cardSummary?.id, plant)
                XCTAssertEqual(restored.wateringHistoryState, .loaded([]))
            }
            try appendCard(pointer: snapshot)
            await restored.loadCard()
            assertConditions(restored)
            try auth(h, owner: other, token: "fixture-b")
            try await h.signIn()
            let foreign = try await restarted.sessionSnapshot()
            _ = try await h.connection.sessionSnapshot()
            XCTAssertNil(model.diagnosisConditions)
            XCTAssertNil(restored.diagnosisConditions)
            let wrongOwner = await restarted.restoreModel(ownerId: other, flowId: flow, expected: foreign)
            if case .absent = wrongOwner {} else { XCTFail("Do not restore another owner's flow") }
            let writes = h.fixture.captured.filter {
                $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/commands") == true
            }
            XCTAssertEqual(writes.count, 1)
            assertClosed(h)
        }
    }

    func testPermanentSDKModelUsesProductionCreateAndDurableReceipt() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner)
        try await h.signIn()
        let snapshot = try await h.connection.sessionSnapshot()
        XCTAssertFalse(snapshot.isAnonymous)
        try plants(h)
        let operation = UUID()
        let model = try await h.connection.makeModel(
            input: input, flowId: UUID(), operationId: operation, expected: snapshot
        )
        await model.save()
        guard case let .saved(confirmation) = model.state else { return XCTFail("Durable receipt required") }
        XCTAssertEqual(confirmation.operationId, operation)
        XCTAssertEqual(confirmation.payloadJSON, try input.makeEnvelope(operationId: operation).payloadJSON)
        let receipt = try await h.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
        XCTAssertEqual(receipt, confirmation)
        let sent = h.fixture.captured.filter { $0.url?.path.contains("/plants-api/") == true }
        XCTAssertEqual(sent.map(\.httpMethod), ["GET", "POST"])
        XCTAssertTrue(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-a" })
        assertClosed(h)
    }

    func testRealSDKSignoutSwitchAndABAWhileGETOrPOSTSuspendedCannotPublishOrACK() async throws {
        for post in [false, true] {
            for mode in 0..<3 {
                let h = try Harness()
                defer { h.close() }
                await h.ready()
                try auth(h, owner: owner)
                try await h.signIn()
                let snapshot = try await h.connection.sessionSnapshot()
                try plants(h, suspendGET: !post, suspendPOST: post)
                let operation = UUID()
                let model = try await h.connection.makeModel(
                    input: input, flowId: UUID(), operationId: operation, expected: snapshot
                )
                let saving = Task { await model.save() }
                try await waitForSuspension(h.fixture)
                let queue = try await h.store.pendingOutboxEntries(for: owner)
                if mode == 0 {
                    h.fixture.append(.init(method: "POST", path: "/auth/v1/logout", data: Data(), query: "scope=local"))
                    try await h.client.auth.signOut(scope: .local)
                } else {
                    try auth(h, owner: other, token: "fixture-b")
                    try await h.signIn()
                    if mode == 2 {
                        try auth(h, owner: owner)
                        try await h.signIn()
                    }
                }
                assertRedacted(model)
                h.fixture.release()
                await saving.value
                assertRedacted(model)
                let after = try await h.store.pendingOutboxEntries(for: owner)
                let receipt = try await h.store.catalogueCreateConfirmation(ownerId: owner, operationId: operation)
                XCTAssertEqual(after, queue)
                XCTAssertEqual(after.count, post ? 1 : 0)
                XCTAssertNil(receipt)
                let foreignQueue = try await h.store.pendingOutboxEntries(for: other)
                XCTAssertTrue(foreignQueue.isEmpty)
                assertClosed(h, remaining: post ? 0 : 1)
            }
        }
    }

    func testConfirmedAccountLocalSignOutRetainsOutboxAndRefusesGuestRecreation() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner)
        try await h.signIn()
        let expected = try await h.connection.sessionSnapshot()
        let model = try await h.connection.makeModel(
            input: input, flowId: UUID(), operationId: UUID(), expected: expected
        )
        let api = try XCTUnwrap(h.connection.apiClient)
        let lease = try await api.captureSyncContext(ownerId: owner)
        let checkpoint = try await h.connection.rememberModel(model, expected: expected)
        _ = try await h.store.catalogueCreateJournal(
            checkpoint.envelope, mode: .enqueue(canCreate: true), context: lease, authority: api.syncAuthority
        )
        let queue = try await h.store.pendingOutboxEntries(for: owner)
        XCTAssertEqual(queue.count, 1)
        h.fixture.append(.init(method: "POST", path: "/auth/v1/logout", data: Data(), query: "scope=local"))
        try await h.connection.signOutAccount(expected: expected)
        XCTAssertNil(h.client.auth.currentSession)
        XCTAssertNil(h.connection.snapshot)
        assertRedacted(model)
        XCTAssertFalse(h.connection.signOutServerUnconfirmed)
        for connection in [h.connection, try reopenedConnection(h)] {
            do {
                _ = try await connection.sessionOwner()
                XCTFail("Logout must require explicit sign-in")
            } catch { XCTAssertEqual(error as? CatalogueSaveUnavailable, .sessionChanged) }
        }
        try auth(h, owner: other, token: "fixture-b", grant: "password")
        _ = try await h.connection.signInAccount(
            email: "fixture@example.invalid", password: "fixture",
            scope: try await h.connection.accountScope()
        )
        XCTAssertEqual(h.client.auth.currentSession?.user.id, other)
        let retained = try await h.store.pendingOutboxEntries(for: owner)
        let foreign = try await h.store.pendingOutboxEntries(for: other)
        XCTAssertEqual(retained, queue)
        XCTAssertTrue(foreign.isEmpty)
        XCTAssertFalse(h.fixture.captured.contains { $0.url?.path.contains("/plants-api/") == true })
        assertClosed(h)
    }

    func testAccountSignOutRejectsStaleOwnerAndABASnapshotsWithoutHTTP() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner)
        try await h.signIn()
        let stale = try await h.connection.sessionSnapshot()
        for id in [other, owner] {
            try auth(h, owner: id, token: "fixture-replacement")
            try await h.signIn()
            let current = try await h.connection.sessionSnapshot()
            let requests = h.fixture.captured.count
            do {
                try await h.connection.signOutAccount(expected: stale)
                XCTFail("A delayed confirmation must not log out the current session")
            } catch { XCTAssertEqual(error as? CatalogueSaveUnavailable, .sessionChanged) }
            XCTAssertEqual(h.connection.snapshot, current)
            XCTAssertEqual(h.fixture.captured.count, requests)
        }
        assertClosed(h)
    }

    func testAccountSignOutTransportFailureUsesRealSDKLocalRemovalAndDoesNotTouchLaterOwner() async throws {
        for replaceOwner in [false, true] {
            let h = try Harness()
            defer { h.close() }
            await h.ready()
            try auth(h, owner: owner)
            try await h.signIn()
            let expected = try await h.connection.sessionSnapshot()
            let model = try await h.connection.makeModel(
                input: input, flowId: UUID(), operationId: UUID(), expected: expected
            )
            h.fixture.append(.init(
                method: "POST", path: "/auth/v1/logout", data: Data(), suspend: true,
                query: "scope=local", failure: .notConnectedToInternet
            ))
            // Pinned Auth HTTP retries POST once, including an offline local logout.
            h.fixture.append(.init(
                method: "POST", path: "/auth/v1/logout", data: Data(),
                query: "scope=local", failure: .notConnectedToInternet
            ))
            let logout = Task { try await h.connection.signOutAccount(expected: expected) }
            try await waitForSuspension(h.fixture)
            XCTAssertNil(h.client.auth.currentSession)
            XCTAssertNil(h.connection.snapshot)
            assertRedacted(model)
            XCTAssertTrue(h.connection.authenticationInFlight)
            do {
                _ = try await h.connection.signInAccount(
                    email: "fixture@example.invalid", password: "fixture",
                    scope: try await h.connection.accountScope()
                )
                XCTFail("Auth exchanges must serialize with logout")
            } catch { XCTAssertEqual(error as? NativeAuthFailure, .providerFailed) }
            if replaceOwner {
                try auth(h, owner: other, token: "fixture-b")
                try await h.signIn()
                _ = try await h.connection.sessionSnapshot()
            }
            h.fixture.release()
            do {
                try await logout.value
                XCTFail("Offline HTTP must not claim server logout succeeded")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
            }
            let logoutRequests = h.fixture.captured.filter { $0.url?.path == "/auth/v1/logout" }
            XCTAssertEqual(logoutRequests.count, 2)
            XCTAssertTrue(logoutRequests.allSatisfy {
                $0.httpMethod == "POST" && $0.url?.query == "scope=local"
                    && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-a"
            })
            XCTAssertFalse(h.connection.authenticationInFlight)
            XCTAssertEqual(h.connection.signOutServerUnconfirmed, !replaceOwner)
            XCTAssertEqual(h.client.auth.currentSession?.user.id, replaceOwner ? other : nil)
            assertRedacted(model)
            assertClosed(h)
        }
    }

    func testSDKCallbackInvalidatesSynchronouslyBeforeMainActorCanObserve() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner)
        try await h.signIn()
        let snapshot = try await h.connection.sessionSnapshot()
        let model = try await h.connection.makeModel(
            input: input, flowId: UUID(), operationId: UUID(), expected: snapshot
        )
        h.fixture.append(.init(method: "POST", path: "/auth/v1/logout", data: Data(), query: "scope=local"))
        let done = DispatchSemaphore(value: 0)
        let client = h.client
        let signout = Task.detached {
            defer { done.signal() }
            try await client.auth.signOut(scope: .local)
        }
        // Deliberately prevent the queued MainActor observer from running.
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        assertRedacted(model)
        try await signout.value
        assertClosed(h)
    }

    /// Expiry is delivered by the real fixture SDK, without a production clock override.
    private func expiredOpeningSession(_ h: Harness) async throws -> (CatalogueSDKSnapshot, CatalogueSaveModel) {
        await h.ready()
        try auth(h, owner: owner)
        try await h.signIn()
        let old = try await h.connection.sessionSnapshot()
        let model = try await h.connection.makeModel(
            input: input, flowId: UUID(), operationId: UUID(), expected: old)
        try auth(h, owner: owner, expired: true)
        try await h.signIn()
        return (old, model)
    }

    private func assertOpeningReadOnly(_ h: Harness, refreshes: Int) {
        XCTAssertEqual(h.fixture.captured.filter { $0.url?.query == "grant_type=refresh_token" }.count, refreshes)
        XCTAssertFalse(h.fixture.captured.contains {
            $0.url?.path == "/auth/v1/signup" || $0.url?.path.contains("/plants-api/") == true
        })
        assertClosed(h)
    }

    private func preparedOpeningCoordinator() -> CollectionOpeningCoordinator {
        let coordinator = CollectionOpeningCoordinator()
        XCTAssertTrue(coordinator.beginPreparation())
        coordinator.finishPreparation()
        return coordinator
    }

    func testRootOpeningWaitsForActualInitialObserverPreparationAndDoesNotLoseFirstTap() async throws {
        let seed = try Harness(emitLocalSessionAsInitialSession: false)
        defer { seed.close() }
        _ = try await expiredOpeningSession(seed)
        let stored = try XCTUnwrap(seed.client.auth.currentSession)
        let h = try Harness(storedSession: stored, emitLocalSessionAsInitialSession: false) { fixture in
            fixture.append(.init(method: "POST", path: "/auth/v1/token",
                data: try json(["code": "validation_failed", "message": "Fixture rejected"]),
                status: 422, suspend: true, query: "grant_type=refresh_token"))
        }
        defer { h.close() }
        // The SDK's own listener and the connection listener can share the held
        // failure or perform separate initial reads. A successful next refresh
        // makes every later startup read local, independent of that scheduling.
        try auth(h, owner: owner, token: "fixture-ready", refresh: true)
        let coordinator = CollectionOpeningCoordinator()
        XCTAssertNil(coordinator.begin(connection: h.connection, locale: .en))
        XCTAssertTrue(coordinator.beginPreparation())
        let preparation = Task {
            defer { coordinator.finishPreparation() }
            _ = try? await h.connection.sessionSnapshot()
        }
        try await waitForSuspension(h.fixture)
        XCTAssertFalse(coordinator.beginPreparation())
        XCTAssertFalse(coordinator.preparationSettled)
        XCTAssertNil(coordinator.active)
        XCTAssertNil(coordinator.begin(connection: h.connection, locale: .en))
        h.fixture.release()
        await preparation.value
        XCTAssertTrue(coordinator.preparationSettled)
        XCTAssertTrue(coordinator.starting) // Never reset the single-attempt latch.
        XCTAssertEqual(h.client.auth.currentSession?.user.id, owner)
        XCTAssertFalse(h.client.auth.currentSession?.isExpired ?? true)
        assertOpeningReadOnly(h, refreshes: 2)
        let request = try XCTUnwrap(coordinator.begin(connection: h.connection, locale: .en))
        var publications = 0
        await coordinator.execute(request, connection: h.connection,
            currentConnection: { h.connection }, currentLocale: { .en }) {
            guard case .permanent(let snapshot) = $0 else { return XCTFail("First tap must open") }
            XCTAssertEqual(snapshot.session.userId, self.owner)
            publications += 1
        }
        XCTAssertEqual(publications, 1)
        XCTAssertFalse(coordinator.busy)
        assertOpeningReadOnly(h, refreshes: 2)
    }

    func testRootOpeningHeldSameOwnerRefreshKeepsOriginalRequestDespiteNilProjection() async throws {
        for cancel in [false, true] {
            let h = try Harness(emitLocalSessionAsInitialSession: false)
            defer { h.close() }
            _ = try await expiredOpeningSession(h)
            try auth(h, owner: owner, token: "fixture-root-refreshed", suspend: true, refresh: true)
            let coordinator = preparedOpeningCoordinator()
            let request = try XCTUnwrap(coordinator.begin(connection: h.connection, locale: .en))
            var publications = 0
            let operation = Task {
                await coordinator.execute(request, connection: h.connection,
                    currentConnection: { h.connection }, currentLocale: { .en }) {
                    guard case .permanent(let snapshot) = $0 else { return XCTFail("Refresh is not login") }
                    XCTAssertEqual(snapshot.session.userId, self.owner)
                    publications += 1
                }
            }
            try await waitForSuspension(h.fixture)
            XCTAssertNil(h.connection.snapshot)
            XCTAssertEqual(coordinator.active?.id, request.id)
            XCTAssertNil(coordinator.begin(connection: h.connection, locale: .en))
            if cancel { operation.cancel() }
            h.fixture.release()
            await operation.value
            XCTAssertEqual(publications, cancel ? 0 : 1)
            XCTAssertFalse(coordinator.busy)
            assertOpeningReadOnly(h, refreshes: 1)
        }
    }

    func testRootOpeningNewPresentationRetiresHeldRefreshEvenAfterDismissal() async throws {
        for dismiss in [false, true] {
            let h = try Harness(emitLocalSessionAsInitialSession: false)
            defer { h.close() }
            _ = try await expiredOpeningSession(h)
            try auth(h, owner: owner, token: "fixture-presentation", suspend: true, refresh: true)
            let coordinator = preparedOpeningCoordinator()
            var available = false
            XCTAssertNil(coordinator.begin(connection: h.connection, locale: .en,
                                           presentationAvailable: available))
            // Even a request admitted earlier must check actual availability before SDK work.
            let blocked = try XCTUnwrap(coordinator.begin(connection: h.connection, locale: .en))
            await coordinator.execute(blocked, connection: h.connection,
                currentConnection: { h.connection }, currentLocale: { .en },
                presentationAvailable: { available }) { _ in XCTFail("Unavailable Root must not publish") }
            XCTAssertFalse(coordinator.busy)
            XCTAssertFalse(h.fixture.suspended)
            available = true
            let request = try XCTUnwrap(coordinator.begin(connection: h.connection, locale: .en,
                                                         presentationAvailable: available))
            var publications = 0
            var newerUI = "target"
            let operation = Task {
                await coordinator.execute(request, connection: h.connection,
                    currentConnection: { h.connection }, currentLocale: { .en },
                    presentationAvailable: { available }) { _ in
                    publications += 1
                    newerUI = "overwritten"
                }
            }
            try await waitForSuspension(h.fixture)
            available = false
            coordinator.presentationBegan()
            XCTAssertNil(coordinator.active)
            XCTAssertFalse(coordinator.busy)
            if dismiss { available = true; newerUI = "dismissed" }
            h.fixture.release()
            await operation.value
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(newerUI, dismiss ? "dismissed" : "target")
            XCTAssertNil(coordinator.active)
            XCTAssertFalse(coordinator.busy)
            let session = try XCTUnwrap(h.client.auth.currentSession)
            XCTAssertEqual(session.user.id, owner)
            XCTAssertFalse(session.isExpired)
            XCTAssertEqual(session.accessToken, "fixture-presentation")
            assertOpeningReadOnly(h, refreshes: 1)
        }
    }

    func testRootOpeningRetiredCompletionCannotClearNewRequestPendingRealBind() async throws {
        let h = try Harness(emitLocalSessionAsInitialSession: false)
        defer { h.close() }
        _ = try await expiredOpeningSession(h)
        try auth(h, owner: owner, token: "fixture-presentation-next", suspend: true, refresh: true)
        let coordinator = preparedOpeningCoordinator()
        var available = true
        let original = try XCTUnwrap(coordinator.begin(connection: h.connection, locale: .en))
        var oldPublications = 0
        let first = Task {
            await coordinator.execute(original, connection: h.connection,
                currentConnection: { h.connection }, currentLocale: { .en },
                presentationAvailable: { available }) { _ in oldPublications += 1 }
        }
        try await waitForSuspension(h.fixture)
        available = false
        coordinator.presentationBegan()
        available = true // New presentation was dismissed before the old callback.
        let replacement = try XCTUnwrap(coordinator.begin(connection: h.connection, locale: .en,
                                                          presentationAvailable: available))
        XCTAssertNotEqual(original.id, replacement.id)
        let api = try XCTUnwrap(h.connection.apiClient)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let hold = Task.detached { await api.holdConnectionTest(started: started, release: release) }
        defer { release.signal() }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        var newPublications = 0
        var second: Task<Void, Never>?
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            second = Task {
                entered.resume()
                await coordinator.execute(replacement, connection: h.connection,
                    currentConnection: { h.connection }, currentLocale: { .en },
                    presentationAvailable: { available }) {
                    guard case .permanent(let snapshot) = $0 else {
                        return XCTFail("New manual intent must open the current collection")
                    }
                    XCTAssertEqual(snapshot.session.userId, self.owner)
                    newPublications += 1
                }
            }
        }
        h.fixture.release()
        await first.value
        XCTAssertEqual(oldPublications, 0)
        XCTAssertEqual(newPublications, 0)
        XCTAssertEqual(coordinator.active?.id, replacement.id)
        XCTAssertTrue(coordinator.busy)
        let session = try XCTUnwrap(h.client.auth.currentSession)
        XCTAssertEqual(session.user.id, owner)
        XCTAssertFalse(session.isExpired)
        XCTAssertEqual(session.accessToken, "fixture-presentation-next")
        release.signal()
        await hold.value
        let next = try XCTUnwrap(second)
        await next.value
        XCTAssertEqual(newPublications, 1)
        XCTAssertNil(coordinator.active)
        XCTAssertFalse(coordinator.busy)
        assertOpeningReadOnly(h, refreshes: 1)
    }

    func testRootOpeningLocaleChangeDiscardsHeldResultAndReleasesBusyForNewLocale() async throws {
        let h = try Harness(emitLocalSessionAsInitialSession: false)
        defer { h.close() }
        _ = try await expiredOpeningSession(h)
        try auth(h, owner: owner, token: "fixture-root-locale", suspend: true, refresh: true)
        let coordinator = preparedOpeningCoordinator()
        var locale: SupportedLocale = .pl
        let request = try XCTUnwrap(coordinator.begin(connection: h.connection, locale: locale))
        var publications = 0
        let operation = Task {
            await coordinator.execute(request, connection: h.connection,
                currentConnection: { h.connection }, currentLocale: { locale }) { _ in publications += 1 }
        }
        try await waitForSuspension(h.fixture)
        locale = .en
        try await h.connection.updateClientLocale("en")
        h.fixture.release()
        await operation.value
        XCTAssertEqual(publications, 0)
        XCTAssertFalse(coordinator.busy)
        let next = try XCTUnwrap(coordinator.begin(connection: h.connection, locale: locale))
        XCTAssertNotEqual(next.id, request.id)
        await coordinator.execute(next, connection: h.connection,
            currentConnection: { h.connection }, currentLocale: { locale }) {
            guard case .permanent = $0 else { return XCTFail("New locale must remain usable") }
            publications += 1
        }
        XCTAssertEqual(publications, 1)
        XCTAssertFalse(coordinator.busy)
        assertOpeningReadOnly(h, refreshes: 1)
    }

    func testRootOpeningOldConnectionCompletionCannotClearNewHeldRequest() async throws {
        let old = try Harness(emitLocalSessionAsInitialSession: false)
        let newer = try Harness(emitLocalSessionAsInitialSession: false)
        defer { old.close(); newer.close() }
        _ = try await expiredOpeningSession(old)
        _ = try await expiredOpeningSession(newer)
        try auth(old, owner: owner, token: "fixture-root-old", suspend: true, refresh: true)
        try auth(newer, owner: owner, token: "fixture-root-new", suspend: true, refresh: true)
        let coordinator = preparedOpeningCoordinator()
        var current: CatalogueConnection? = old.connection
        let original = try XCTUnwrap(coordinator.begin(connection: old.connection, locale: .en))
        var oldPublications = 0
        let first = Task {
            await coordinator.execute(original, connection: old.connection,
                currentConnection: { current }, currentLocale: { .en }) { _ in oldPublications += 1 }
        }
        try await waitForSuspension(old.fixture)
        current = newer.connection
        coordinator.connectionReplaced()
        let replacement = try XCTUnwrap(coordinator.begin(connection: newer.connection, locale: .en))
        var newPublications = 0
        let second = Task {
            await coordinator.execute(replacement, connection: newer.connection,
                currentConnection: { current }, currentLocale: { .en }) {
                guard case .permanent = $0 else { return XCTFail("Replacement must open") }
                newPublications += 1
            }
        }
        try await waitForSuspension(newer.fixture)
        old.fixture.release()
        await first.value
        XCTAssertEqual(oldPublications, 0)
        XCTAssertEqual(coordinator.active?.id, replacement.id)
        XCTAssertTrue(coordinator.busy)
        newer.fixture.release()
        await second.value
        XCTAssertEqual(newPublications, 1)
        XCTAssertFalse(coordinator.busy)
        assertOpeningReadOnly(old, refreshes: 1)
        assertOpeningReadOnly(newer, refreshes: 1)
    }

    func testRootOpeningSignOutAndEqualSessionABAHaveNoStaleCollectionOrLogin() async throws {
        for relogin in [false, true] {
            let h = try Harness(emitLocalSessionAsInitialSession: false)
            defer { h.close() }
            _ = try await expiredOpeningSession(h)
            let original = h.client.auth.currentSession
            h.fixture.append(.init(method: "POST", path: "/auth/v1/token",
                data: try json(["code": "validation_failed", "message": "Fixture rejected"]),
                status: 422, suspend: true, query: "grant_type=refresh_token"))
            let coordinator = preparedOpeningCoordinator()
            let request = try XCTUnwrap(coordinator.begin(connection: h.connection, locale: .en))
            var publications = 0
            let operation = Task {
                await coordinator.execute(request, connection: h.connection,
                    currentConnection: { h.connection }, currentLocale: { .en }) { _ in publications += 1 }
            }
            try await waitForSuspension(h.fixture)
            h.fixture.append(.init(method: "POST", path: "/auth/v1/logout", data: Data(), query: "scope=local"))
            try await h.client.auth.signOut(scope: .local)
            if relogin {
                try auth(h, owner: owner, expired: true)
                try await h.signIn()
                XCTAssertEqual(h.client.auth.currentSession, original)
            }
            h.fixture.release()
            await operation.value
            XCTAssertEqual(publications, 0)
            XCTAssertFalse(coordinator.busy)
            if !relogin {
                let next = try XCTUnwrap(coordinator.begin(connection: h.connection, locale: .en))
                await coordinator.execute(next, connection: h.connection,
                    currentConnection: { h.connection }, currentLocale: { .en }) {
                    guard case .loginRequired = $0 else { return XCTFail("New signed-out intent requires login") }
                    publications += 1
                }
                XCTAssertEqual(publications, 1)
            }
            assertOpeningReadOnly(h, refreshes: 1)
        }
    }

    func testRootOpeningTransportFailurePublishesUnavailableAndExplicitRetryRecovers() async throws {
        let h = try Harness(emitLocalSessionAsInitialSession: false)
        defer { h.close() }
        _ = try await expiredOpeningSession(h)
        for held in [true, false] {
            h.fixture.append(.init(method: "POST", path: "/auth/v1/token", data: Data(),
                suspend: held, query: "grant_type=refresh_token", failure: .notConnectedToInternet))
        }
        let coordinator = preparedOpeningCoordinator()
        let request = try XCTUnwrap(coordinator.begin(connection: h.connection, locale: .en))
        var failures = 0
        let operation = Task {
            await coordinator.execute(request, connection: h.connection,
                currentConnection: { h.connection }, currentLocale: { .en }) {
                guard case .temporarilyUnavailable = $0 else { return XCTFail("Transport error must not open login") }
                failures += 1
            }
        }
        try await waitForSuspension(h.fixture)
        h.fixture.release()
        await operation.value
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(coordinator.busy)
        try auth(h, owner: owner, token: "fixture-root-retry", refresh: true)
        let next = try XCTUnwrap(coordinator.begin(connection: h.connection, locale: .en))
        var opened = false
        await coordinator.execute(next, connection: h.connection,
            currentConnection: { h.connection }, currentLocale: { .en }) {
            guard case .permanent = $0 else { return XCTFail("Explicit retry must recover") }
            opened = true
        }
        XCTAssertTrue(opened)
        XCTAssertFalse(coordinator.busy)
        assertOpeningReadOnly(h, refreshes: 3)
    }

    func testCollectionOpeningRefreshInsideProductionReadKeepsOldSnapshotsAndModelsRevoked() async throws {
        for sameToken in [false, true] {
            let h = try Harness(emitLocalSessionAsInitialSession: false)
            defer { h.close() }
            let (old, model) = try await expiredOpeningSession(h)
            try auth(h, owner: owner, token: sameToken ? "fixture-a" : "fixture-renewed",
                     suspend: true, refresh: true)
            let opening = Task { await h.connection.collectionOpeningSnapshot() }
            try await waitForSuspension(h.fixture)
            h.fixture.release()
            guard case let .permanent(current) = await opening.value else {
                XCTFail("The exact production read must recover its own refresh"); continue
            }
            XCTAssertEqual(current.session.userId, owner)
            XCTAssertEqual(current.session.accessToken, sameToken ? "fixture-a" : "fixture-renewed")
            if sameToken { XCTAssertEqual(current.session, old.session) }
            XCTAssertNotEqual(current, old)
            XCTAssertEqual(h.connection.snapshot, current)
            _ = try await h.connection.collectionLease(expected: current)
            do {
                _ = try await h.connection.collectionLease(expected: old)
                XCTFail("Old strict snapshot must stay invalid")
            } catch { XCTAssertEqual(error as? CatalogueSaveUnavailable, .sessionChanged) }
            assertRedacted(model)
            assertOpeningReadOnly(h, refreshes: 1)
        }
    }

    func testCollectionOpeningHeldReadRejectsOwnerRefreshABAAndEqualFieldRelogin() async throws {
        for mode in 0..<7 {
            let h = try Harness(emitLocalSessionAsInitialSession: false)
            defer { h.close() }
            _ = try await expiredOpeningSession(h)
            let original = try XCTUnwrap(h.client.auth.currentSession)
            // ABA cases isolate ancestry with a nonterminal response. Terminal cases
            // prove that sessionMissing must not attribute an explicit signOut to this read.
            let code = mode == 5 ? "refresh_token_not_found"
                : mode == 6 ? "session_expired" : "validation_failed"
            h.fixture.append(.init(method: "POST", path: "/auth/v1/token",
                data: try json(["code": code, "error_code": code, "message": "Fixture rejected"]),
                status: mode >= 5 ? 400 : 422, suspend: true, query: "grant_type=refresh_token"))
            let opening = Task { await h.connection.collectionOpeningSnapshot() }
            try await waitForSuspension(h.fixture)
            if mode == 0 {
                try auth(h, owner: other, token: "fixture-b")
                try await h.signIn()
            } else if mode == 1 {
                try auth(h, owner: other, token: "fixture-b", refresh: true)
                _ = try await h.client.auth.refreshSession(refreshToken: "independent-b")
                try auth(h, owner: owner, expired: true, refresh: true)
                _ = try await h.client.auth.refreshSession()
            } else {
                if mode != 3 {
                    h.fixture.append(.init(method: "POST", path: "/auth/v1/logout",
                                          data: Data(), query: "scope=local"))
                    try await h.client.auth.signOut(scope: .local)
                }
                if mode < 4 {
                    try auth(h, owner: owner, expired: true)
                    try await h.signIn()
                }
            }
            let replacement = h.client.auth.currentSession
            if (1...3).contains(mode) { XCTAssertEqual(replacement, original) }
            h.fixture.release()
            guard case .superseded = await opening.value else {
                XCTFail("Every disruptive event must retire the original request"); continue
            }
            XCTAssertEqual(h.client.auth.currentSession, replacement)
            if mode >= 4 {
                XCTAssertNil(replacement)
                guard case .loginRequired = await h.connection.collectionOpeningSnapshot() else {
                    XCTFail("A new explicit request must recognize the completed signOut"); continue
                }
            }
            assertOpeningReadOnly(h, refreshes: mode == 1 ? 3 : 1)
        }
    }

    func testCollectionOpeningCancellationAndCallerRequestLocaleFencesCannotPresentOrRetarget() async throws {
        for mode in 0..<4 {
            let h = try Harness(emitLocalSessionAsInitialSession: false)
            defer { h.close() }
            _ = try await expiredOpeningSession(h)
            try auth(h, owner: owner, token: "fixture-renewed", suspend: true, refresh: true)
            var currentRequest = true
            let opening = Task {
                await h.connection.collectionOpeningSnapshot(isRequestCurrent: { currentRequest })
            }
            try await waitForSuspension(h.fixture)
            if mode == 0 { opening.cancel() } else { currentRequest = false }
            if mode == 2 { try await h.connection.updateClientLocale("en") }
            var replacement: Session?
            if mode == 3 {
                try auth(h, owner: other, token: "fixture-b")
                try await h.signIn()
                replacement = h.client.auth.currentSession
                guard case let .permanent(new) = await h.connection.collectionOpeningSnapshot() else {
                    XCTFail("Replacement request must remain usable"); continue
                }
                XCTAssertEqual(new.session.userId, other)
            }
            h.fixture.release()
            guard case .superseded = await opening.value else {
                XCTFail("Cancelled/replaced requests must never return collection or login"); continue
            }
            if mode == 3 { XCTAssertEqual(h.client.auth.currentSession, replacement) }
            guard case .permanent = await h.connection.collectionOpeningSnapshot() else {
                XCTFail("A later explicit request must remain usable"); continue
            }
            assertOpeningReadOnly(h, refreshes: 1)
        }
    }

    func testCollectionOpeningTransportFailureIsUnavailableAndNextExplicitRequestCanRecover() async throws {
        let h = try Harness(emitLocalSessionAsInitialSession: false)
        defer { h.close() }
        _ = try await expiredOpeningSession(h)
        let original = h.client.auth.currentSession
        for held in [true, false] {
            // Pinned SDK HTTP transport retries this failed POST once.
            h.fixture.append(.init(method: "POST", path: "/auth/v1/token", data: Data(),
                suspend: held, query: "grant_type=refresh_token", failure: .notConnectedToInternet))
        }
        let opening = Task { await h.connection.collectionOpeningSnapshot() }
        try await waitForSuspension(h.fixture)
        h.fixture.release()
        guard case .temporarilyUnavailable = await opening.value else {
            return XCTFail("Transport failure is not evidence of missing credentials")
        }
        XCTAssertEqual(h.client.auth.currentSession, original)
        try auth(h, owner: owner, token: "fixture-recovered", refresh: true)
        guard case let .permanent(current) = await h.connection.collectionOpeningSnapshot() else {
            return XCTFail("Only a new explicit request retries the failed read")
        }
        XCTAssertEqual(current.session.accessToken, "fixture-recovered")
        assertOpeningReadOnly(h, refreshes: 3)
    }

    func testCollectionOpeningMissingAnonymousAndTerminalCleanupRequireLoginWithoutRecoveryLoops() async throws {
        for mode in 0..<4 {
            let h = try Harness(emitLocalSessionAsInitialSession: false)
            defer { h.close() }
            await h.ready()
            if mode == 1 {
                try auth(h, owner: owner, anonymous: true)
                try await h.signIn()
            } else if mode >= 2 {
                try auth(h, owner: owner, expired: true)
                try await h.signIn()
                let code = mode == 2 ? "refresh_token_not_found" : "session_expired"
                h.fixture.append(.init(method: "POST", path: "/auth/v1/token",
                    data: try json(["code": code, "error_code": code, "message": "Fixture rejected"]),
                    status: 400, query: "grant_type=refresh_token"))
            }
            if mode >= 2 {
                guard case .superseded = await h.connection.collectionOpeningSnapshot() else {
                    XCTFail("In-flight terminal cleanup must retire the original request"); continue
                }
                XCTAssertNil(h.client.auth.currentSession)
            }
            for _ in 0..<3 {
                guard case .loginRequired = await h.connection.collectionOpeningSnapshot() else {
                    XCTFail("A new explicit read of stable absence/anonymous state must require login"); continue
                }
            }
            if mode >= 2 { XCTAssertNil(h.client.auth.currentSession) }
            assertOpeningReadOnly(h, refreshes: mode >= 2 ? 1 : 0)
        }
    }

    func testCollectionOpeningSeedsExpiredSDKIdentityAfterProductionInitialNilWithoutCacheProof() async throws {
        let seed = try Harness(emitLocalSessionAsInitialSession: false)
        defer { seed.close() }
        _ = try await expiredOpeningSession(seed)
        let persisted = try XCTUnwrap(seed.client.auth.currentSession)
        let h = try Harness(storedSession: persisted, emitLocalSessionAsInitialSession: false) { fixture in
            fixture.append(.init(method: "POST", path: "/auth/v1/token",
                data: try json(["code": "validation_failed", "message": "Fixture rejected"]),
                status: 422, suspend: true, query: "grant_type=refresh_token"))
        }
        defer { h.close() }
        try await waitForSuspension(h.fixture)
        var initial: Task<CatalogueCollectionOpeningOutcome, Never>?
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            var announced = false
            initial = Task {
                await h.connection.collectionOpeningSnapshot(isRequestCurrent: {
                    if !announced { announced = true; entered.resume() }
                    return true
                })
            }
        }
        h.fixture.release()
        let initialRead = try XCTUnwrap(initial)
        guard case .superseded = await initialRead.value else {
            return XCTFail("Initial nil during observer registration must retire the waiting request")
        }
        let scope = try await h.connection.accountScope() // Wait for the real initial observer, no refresh.
        XCTAssertNil(scope.snapshot)
        XCTAssertEqual(h.client.auth.currentSession, persisted)
        XCTAssertEqual(h.connection.authClassification, .unresolved)
        try auth(h, owner: owner, token: "fixture-established", suspend: true, refresh: true)
        let opening = Task { await h.connection.collectionOpeningSnapshot() }
        try await waitForSuspension(h.fixture)
        h.fixture.release()
        guard case let .permanent(current) = await opening.value else {
            return XCTFail("Established expired SDK identity must survive a nonterminal initial nil")
        }
        XCTAssertEqual(current.session.userId, owner)
        assertOpeningReadOnly(h, refreshes: 2)
        assertOpeningReadOnly(seed, refreshes: 0)
    }

    func testRealSDKRefreshInvalidatesOldModelAndSameOwnerRestoreKeepsExactOperation() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner, anonymous: true)
        try await h.signIn()
        let snapshot = try await h.connection.sessionSnapshot()
        let flow = UUID(), operation = UUID()
        let model = try await h.connection.makeModel(
            input: input, flowId: flow, operationId: operation, expected: snapshot
        )
        await model.save()
        let checkpoint = try XCTUnwrap(model.checkpoint)
        try auth(h, owner: owner, token: "fixture-refreshed", anonymous: true, refresh: true)
        _ = try await h.client.auth.refreshSession()
        assertRedacted(model)
        let refreshed = try await h.connection.sessionSnapshot()
        XCTAssertEqual(refreshed.session.accessToken, "fixture-refreshed")
        let restored = await h.connection.restoreModel(ownerId: owner, flowId: flow, expected: refreshed)
        guard case let .restored(newModel) = restored else { return XCTFail("Same-owner restore required") }
        XCTAssertEqual(newModel.checkpoint, checkpoint)
        XCTAssertEqual(newModel.envelope?.operationId, operation)
        XCTAssertEqual(newModel.envelope?.payloadJSON, checkpoint.envelope.payloadJSON)
        await newModel.save()
        XCTAssertEqual(newModel.state, .signInRequired)
        let wrongOwner = await h.connection.restoreModel(ownerId: other, flowId: flow, expected: refreshed)
        if case .unavailable(.sessionChanged) = wrongOwner {} else { XCTFail("Owner must be explicit") }
        XCTAssertFalse(h.fixture.captured.contains { $0.url?.path.contains("/plants-api/") == true })
        assertClosed(h)
    }

    func testStaleAwaitedSDKSessionCannotRetargetAfterOwnerChange() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner, expired: true)
        try await h.signIn()
        try auth(h, owner: owner, token: "fixture-late-refresh", suspend: true, refresh: true)
        let reading = Task { try await h.connection.sessionSnapshot() }
        try await waitForSuspension(h.fixture)
        try auth(h, owner: other, token: "fixture-b")
        try await h.signIn()
        h.fixture.release()
        do { _ = try await reading.value; XCTFail("Stale SDK read must fail") } catch {}
        let current = try await h.connection.sessionSnapshot()
        XCTAssertEqual(current.session.userId, other)
        XCTAssertEqual(current.session.accessToken, "fixture-b")
        XCTAssertFalse(h.fixture.captured.contains { $0.url?.path == "/auth/v1/signup" })
        assertClosed(h)
    }

    func testFactorySuspendedOnRealAPIActorRejectsOriginalEpochAfterABA() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner)
        try await h.signIn()
        let snapshot = try await h.connection.sessionSnapshot()
        let api = try XCTUnwrap(h.connection.apiClient)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let hold = Task.detached { await api.holdConnectionTest(started: started, release: release) }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        var making: Task<CatalogueSaveModel, Error>?
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            making = Task {
                entered.resume()
                return try await h.connection.makeModel(
                    input: input, flowId: UUID(), operationId: UUID(), expected: snapshot
                )
            }
        }
        let factory = try XCTUnwrap(making)
        try auth(h, owner: other, token: "fixture-b")
        try await h.signIn()
        try auth(h, owner: owner)
        try await h.signIn()
        release.signal()
        await hold.value
        do {
            _ = try await factory.value
            XCTFail("Old epoch must never return a model")
        } catch { XCTAssertEqual(error as? CatalogueSaveUnavailable, .sessionChanged) }
        let current = try await h.connection.sessionSnapshot()
        XCTAssertEqual(current.session, snapshot.session)
        XCTAssertNotEqual(current, snapshot)
        let fresh = try await h.connection.makeModel(
            input: input, flowId: UUID(), operationId: UUID(), expected: current
        )
        XCTAssertEqual(fresh.input, input)
        XCTAssertFalse(h.fixture.captured.contains { $0.url?.path.contains("/plants-api/") == true })
        assertClosed(h)
    }

    func testGenericSDKEventsNeverCreateOrTransferGuestCheckpoint() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner, anonymous: true)
        try await h.signIn()
        let snapshot = try await h.connection.sessionSnapshot()
        let flow = UUID(), operation = UUID()
        let model = try await h.connection.makeModel(
            input: input, flowId: flow, operationId: operation, expected: snapshot
        )
        await model.save()
        let original = try XCTUnwrap(model.checkpoint)
        try auth(h, owner: other, token: "fixture-b")
        try await h.signIn()
        let foreign = try await h.connection.sessionSnapshot()
        let result = await h.connection.restoreModel(ownerId: other, flowId: flow, expected: foreign)
        if case .absent = result {} else { XCTFail("Never transfer a guest checkpoint") }
        try auth(h, owner: owner, anonymous: true)
        try await h.signIn()
        let current = try await h.connection.sessionSnapshot()
        let restored = await h.connection.restoreModel(ownerId: owner, flowId: flow, expected: current)
        guard case let .restored(sameOwner) = restored else { return XCTFail("Original checkpoint retained") }
        XCTAssertEqual(sameOwner.checkpoint, original)
        try auth(h, owner: owner, anonymous: true, refresh: true)
        _ = try await h.client.auth.refreshSession()
        assertRedacted(sameOwner)
        let sameTokenRefresh = try await h.connection.sessionSnapshot()
        XCTAssertEqual(sameTokenRefresh.session, current.session)
        XCTAssertNotEqual(sameTokenRefresh, current)
        let ownQueue = try await h.store.pendingOutboxEntries(for: owner)
        let foreignQueue = try await h.store.pendingOutboxEntries(for: other)
        XCTAssertTrue(ownQueue.isEmpty)
        XCTAssertTrue(foreignQueue.isEmpty)
        XCTAssertFalse(h.fixture.captured.contains { $0.url?.path.contains("/plants-api/") == true })
        assertRedacted(model)
        assertClosed(h)
    }

    func testAuthRefreshFailureDoesNotCreateAnotherAnonymousOwner() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner, expired: true)
        try await h.signIn()
        h.fixture.append(.init(
            method: "POST", path: "/auth/v1/token",
            data: try json(["code": "validation_failed", "message": "Fixture rejected"]),
            status: 422, query: "grant_type=refresh_token"
        ))
        do { _ = try await h.connection.sessionOwner(); XCTFail("Auth failure must propagate") } catch {}
        XCTAssertFalse(h.fixture.captured.contains { $0.url?.path == "/auth/v1/signup" })
        assertClosed(h)
    }

    private func waitForAuthClassification(
        _ h: Harness, _ expected: CatalogueAuthClassification
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while h.connection.authClassification != expected && Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(h.connection.authClassification, expected)
    }

    func testProductionTransientInitialNilIsUnresolvedWithoutRefreshingOnProofRead() async throws {
        let seed = try Harness()
        defer { seed.close() }
        await seed.ready()
        try auth(seed, owner: owner, expired: true)
        try await seed.signIn()
        let persisted = try XCTUnwrap(seed.client.auth.currentSession)
        let h = try Harness(
            storedSession: persisted, emitLocalSessionAsInitialSession: false
        ) { fixture in
            fixture.append(.init(
                method: "POST", path: "/auth/v1/token", data: Data(),
                suspend: true, query: "grant_type=refresh_token",
                failure: .notConnectedToInternet
            ))
            // Pinned Auth HTTP retries a failed POST once.
            fixture.append(.init(
                method: "POST", path: "/auth/v1/token", data: Data(),
                query: "grant_type=refresh_token", failure: .notConnectedToInternet
            ))
        }
        defer { h.close() }
        try await waitForSuspension(h.fixture)
        XCTAssertEqual(h.connection.authClassification, .unresolved)
        h.fixture.release()
        let deadline = Date().addingTimeInterval(5)
        while !h.connection.hasResolvedAuth && Date() < deadline { await Task.yield() }
        XCTAssertTrue(h.connection.hasResolvedAuth)
        XCTAssertEqual(h.client.auth.currentSession?.user.id, owner)
        XCTAssertTrue(try XCTUnwrap(h.client.auth.currentSession).isExpired)
        XCTAssertNil(h.connection.snapshot)
        for _ in 0..<3 { XCTAssertEqual(h.connection.authClassification, .unresolved) }
        XCTAssertEqual(h.fixture.captured.count, 2)
        assertClosed(h)
        assertClosed(seed)
    }

    func testSignOutProofSurvivesOfflineACKButStickyFlagDoesNotAuthorizeLaterNil() async throws {
        let h = try Harness()
        defer { h.close() }
        await h.ready()
        try auth(h, owner: owner)
        try await h.signIn()
        let original = try await h.connection.sessionSnapshot()
        XCTAssertEqual(h.connection.authClassification, .permanent(original))
        h.fixture.append(.init(
            method: "POST", path: "/auth/v1/logout", data: Data(),
            suspend: true, query: "scope=local", failure: .notConnectedToInternet
        ))
        h.fixture.append(.init(
            method: "POST", path: "/auth/v1/logout", data: Data(),
            query: "scope=local", failure: .notConnectedToInternet
        ))
        let logout = Task { try await h.connection.signOutAccount(expected: original) }
        try await waitForSuspension(h.fixture)
        await waitForAuthClassification(h, .signedOut)
        h.fixture.release()
        do { try await logout.value; XCTFail("Fixture logout ACK must fail") } catch {}
        XCTAssertTrue(h.connection.signOutServerUnconfirmed)
        XCTAssertEqual(h.connection.authClassification, .signedOut)

        try auth(h, owner: other, token: "fixture-b")
        try await h.signIn()
        let replacement = try await h.connection.sessionSnapshot()
        XCTAssertEqual(h.connection.authClassification, .permanent(replacement))
        XCTAssertTrue(h.connection.didSignOut)
        XCTAssertTrue(h.defaults.bool(forKey: "catalogue.explicitSignOut"))
        try auth(h, owner: other, token: "fixture-b-expired", expired: true)
        try await h.signIn()
        XCTAssertEqual(h.connection.authClassification, .unresolved)
        // Both attempts must fail with the intended transient transport error.
        for _ in 0..<2 {
            h.fixture.append(.init(
                method: "POST", path: "/auth/v1/token", data: Data(),
                query: "grant_type=refresh_token", failure: .notConnectedToInternet
            ))
        }
        do { _ = try await h.client.auth.refreshSession(); XCTFail("Fixture refresh must fail") } catch {}
        XCTAssertTrue(h.connection.didSignOut)
        XCTAssertEqual(h.connection.authClassification, .unresolved)
        XCTAssertEqual(h.client.auth.currentSession?.user.id, other)
        assertClosed(h)
    }

    func testQueuedSignOutProofCannotPublishOverBOrSameTokenABA() async throws {
        for returnToA in [false, true] {
            let h = try Harness()
            defer { h.close() }
            await h.ready()
            try auth(h, owner: owner, anonymous: true)
            try await h.signIn()
            let original = try await h.connection.sessionSnapshot()
            XCTAssertEqual(h.connection.authClassification, .anonymous(original))
            h.fixture.append(.init(
                method: "POST", path: "/auth/v1/logout", data: Data(), query: "scope=local"
            ))
            try auth(h, owner: other, token: "fixture-b")
            if returnToA { try auth(h, owner: owner, anonymous: true) }
            let client = h.client
            let done = DispatchSemaphore(value: 0)
            let change = Task.detached {
                defer { done.signal() }
                try await client.auth.signOut(scope: .local)
                _ = try await client.auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: "FIXTURE-ONLY-ID-TOKEN")
                )
                if returnToA {
                    _ = try await client.auth.signInWithIdToken(
                        credentials: .init(provider: .apple, idToken: "FIXTURE-ONLY-ID-TOKEN")
                    )
                }
            }
            // Keep every callback's MainActor publication queued until B/ABA is installed.
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(h.connection.authClassification, .unresolved)
            try await change.value
            let current = try await h.connection.sessionSnapshot()
            XCTAssertEqual(current.session.userId, returnToA ? owner : other)
            if returnToA {
                XCTAssertEqual(current.session, original.session)
                XCTAssertNotEqual(current, original)
            }
            let classification: CatalogueAuthClassification = returnToA
                ? .anonymous(current) : .permanent(current)
            await waitForAuthClassification(h, classification)
            assertClosed(h)
        }
    }

    func testProductionInitialRefreshCleanupCannotCreateReplacementAnonymousOwner() async throws {
        let seed = try Harness()
        defer { seed.close() }
        await seed.ready()
        try auth(seed, owner: owner, expired: true)
        try await seed.signIn()
        let persisted = try XCTUnwrap(seed.client.auth.currentSession)
        XCTAssertTrue(persisted.isExpired)
        assertClosed(seed)

        for code in ["refresh_token_not_found", "session_expired"] {
            for startDuringRefresh in [true, false] {
                let h = try Harness(
                    storedSession: persisted, emitLocalSessionAsInitialSession: false
                ) { fixture in
                    fixture.append(.init(
                        method: "POST", path: "/auth/v1/token",
                        data: try json([
                            "code": code, "error_code": code, "message": "Fixture rejected"
                        ]),
                        status: 400, suspend: true, query: "grant_type=refresh_token"
                    ))
                }
                defer { h.close() }
                try await waitForSuspension(h.fixture)
                XCTAssertEqual(h.client.auth.currentSession?.user.id, owner)

                var startup: Task<UUID, Error>?
                if startDuringRefresh {
                    await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
                        startup = Task {
                            entered.resume()
                            return try await h.connection.sessionOwner()
                        }
                    }
                }
                h.fixture.release()
                if let startup {
                    do {
                        _ = try await startup.value
                        XCTFail("Initial refresh failure must not replace the owner")
                    } catch {
                        XCTAssertEqual(error as? CatalogueSaveUnavailable, .sessionChanged)
                    }
                } else {
                    // Also cover a root that starts after SDK cleanup/initialSession completed.
                    await h.ready()
                }

                for _ in 0..<2 {
                    do {
                        _ = try await h.connection.sessionOwner()
                        XCTFail("Retry must not turn an initial auth failure into signup")
                    } catch {
                        XCTAssertEqual(error as? CatalogueSaveUnavailable, .sessionChanged)
                    }
                }
                // Registration completes after the SDK's following initialSession(nil).
                // That event must retain this terminal cleanup proof.
                await h.ready()
                await waitForAuthClassification(h, .signedOut)
                XCTAssertNil(h.client.auth.currentSession)
                XCTAssertNil(h.connection.snapshot)
                XCTAssertEqual(h.fixture.captured.map(\.url?.path), ["/auth/v1/token"])
                assertClosed(h)
            }
        }
    }

    func testLaterSDKTerminalCleanupNeverCreatesReplacementOwnerOnRepeatedStartup() async throws {
        for code in ["refresh_token_not_found", "session_expired"] {
            for anonymous in [true, false] {
                for cleanupBeforeCall in [true, false] {
                    let h = try Harness(emitLocalSessionAsInitialSession: false)
                    defer { h.close() }
                    await h.ready()
                    XCTAssertNil(h.client.auth.currentSession)
                    try auth(h, owner: owner, anonymous: anonymous, expired: true)
                    h.fixture.append(.init(
                        method: "POST", path: "/auth/v1/token",
                        data: try json([
                            "code": code, "error_code": code, "message": "Fixture rejected"
                        ]),
                        status: 400, suspend: !cleanupBeforeCall,
                        query: "grant_type=refresh_token"
                    ))

                    if cleanupBeforeCall {
                        let done = DispatchSemaphore(value: 0)
                        let client = h.client
                        let cleanup = Task.detached {
                            defer { done.signal() }
                            let established = try await client.auth.signInWithIdToken(
                                credentials: .init(provider: .apple, idToken: "FIXTURE-ONLY-ID-TOKEN")
                            )
                            do {
                                _ = try await client.auth.refreshSession()
                                return (established, false)
                            } catch AuthError.sessionMissing {
                                return (established, true)
                            }
                        }
                        // Both SDK events complete while the MainActor observer cannot run.
                        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
                        let (established, rejected) = try await cleanup.value
                        XCTAssertTrue(rejected)
                        XCTAssertEqual(established.user.id, owner)
                        XCTAssertEqual(established.user.isAnonymous, anonymous)
                        XCTAssertTrue(established.isExpired)
                    } else {
                        try await h.signIn()
                        XCTAssertEqual(h.client.auth.currentSession?.user.id, owner)
                        XCTAssertEqual(h.client.auth.currentSession?.user.isAnonymous, anonymous)
                        let startup = Task { try await h.connection.sessionOwner() }
                        try await waitForSuspension(h.fixture)
                        h.fixture.release()
                        do {
                            _ = try await startup.value
                            XCTFail("Terminal refresh must not replace an established owner")
                        } catch {
                            XCTAssertEqual(error as? CatalogueSaveUnavailable, .sessionChanged)
                        }
                    }

                    for _ in 0..<2 {
                        do {
                            _ = try await h.connection.sessionOwner()
                            XCTFail("Session history must survive cleanup and every retry")
                        } catch {
                            XCTAssertEqual(error as? CatalogueSaveUnavailable, .sessionChanged)
                        }
                    }
                    XCTAssertNil(h.client.auth.currentSession)
                    XCTAssertNil(h.connection.snapshot)
                    // Exactly one fixture sign-in and one terminal refresh: no signup or plants HTTP.
                    XCTAssertEqual(h.fixture.captured.map(\.url?.path), [
                        "/auth/v1/token", "/auth/v1/token"
                    ])
                    XCTAssertEqual(h.fixture.captured.map(\.url?.query), [
                        "grant_type=id_token", "grant_type=refresh_token"
                    ])
                    let disk = ModelContext(h.store.modelContainer)
                    XCTAssertEqual(try disk.fetchCount(FetchDescriptor<CatalogueInputCheckpointRecord>()), 0)
                    XCTAssertEqual(try disk.fetchCount(FetchDescriptor<GuestDraftCacheRecord>()), 0)
                    XCTAssertEqual(try disk.fetchCount(FetchDescriptor<LocalOutboxRecord>()), 0)
                    XCTAssertEqual(try disk.fetchCount(FetchDescriptor<CatalogueCreateConfirmationRecord>()), 0)
                    XCTAssertEqual(try disk.fetchCount(FetchDescriptor<SyncedEntityRecord>()), 0)
                    XCTAssertEqual(try disk.fetchCount(FetchDescriptor<SyncCheckpointRecord>()), 0)
                    assertClosed(h)
                }
            }
        }
    }

    func testMissingConfigurationAndDiskFailureStayExplicitlyUnavailable() async throws {
        var configurationReads = 0, diskAttempts = 0
        let missing = CatalogueConnection(configuration: {
            configurationReads += 1
            return try NativeAuthConfiguration(values: [:])
        }, makeStore: {
            diskAttempts += 1
            throw CocoaError(.fileWriteNoPermission)
        })
        for _ in 0..<2 {
            do { _ = try await missing.sessionOwner(); XCTFail("Missing config") }
            catch { XCTAssertEqual(error as? CatalogueConnectionUnavailable, .configurationMissing) }
        }
        XCTAssertEqual(configurationReads, 1)
        XCTAssertEqual(diskAttempts, 0)
        XCTAssertNil(missing.client)
        XCTAssertNil(missing.store)
        let configuration = try NativeAuthConfiguration(values: [
            "NaratSupabaseURL": "https://disk-fixture.invalid",
            "NaratSupabasePublishableKey": "fixture-public-key"
        ])
        let failedDisk = CatalogueConnection(configuration: { configuration }, makeStore: {
            diskAttempts += 1
            throw CocoaError(.fileWriteNoPermission)
        })
        for _ in 0..<2 {
            do { _ = try await failedDisk.sessionOwner(); XCTFail("Disk failure") }
            catch { XCTAssertEqual(error as? CatalogueConnectionUnavailable, .storageUnavailable) }
        }
        XCTAssertEqual(diskAttempts, 1)
        XCTAssertEqual(failedDisk.unavailable, .storageUnavailable)
        XCTAssertNil(failedDisk.client)
        XCTAssertNil(failedDisk.apiClient)
        XCTAssertNil(failedDisk.repository)
    }

    private func collectionReadReply(_ h: Harness, failure: URLError.Code? = nil, suspend: Bool = false) throws {
        let at = "2026-11-03T09:00:00.123456+00:00"
        h.fixture.append(.init(method: "GET", path: "/functions/v1/plants-api/sync",
            data: try json(["until": at, "next_since": at, "has_more": false,
                "last_cursor": NSNull(), "changes": [], "entitlement": NSNull(),
                "profile": ["preferred_locale": "en", "reminder_hour_local": 9,
                    "report_notifications_enabled": true, "trial_reminder_enabled": false]]),
            suspend: suspend, query: "limit=200", failure: failure))
    }

    private func permanentCollection(_ h: Harness) async throws -> CatalogueSDKSnapshot {
        let payload = try json(["sub": owner.uuidString, "is_anonymous": false]).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try auth(h, owner: owner, token: "fixture." + payload + ".signature")
        try await h.signIn()
        return try await h.connection.sessionSnapshot()
    }

    func testCollectionFreshCompletionEmitsOnceButQuietCanonicalCachedAndFailedReadsDoNot() async throws {
        let h = try Harness()
        defer { h.close() }
        let original = try await permanentCollection(h)
        let lease = try await h.connection.collectionLease(expected: original)
        let repository = try XCTUnwrap(h.connection.repository)
        try collectionReadReply(h)
        let fresh = try await repository.collectionCards(context: lease)
        XCTAssertTrue(fresh.cards.isEmpty, "A legitimate empty collection is still a fresh read")
        XCTAssertFalse(fresh.isCached)
        XCTAssertNil(h.connection.explicitCareReadIntent, "Canonical publication itself is quiet")
        let requests = h.fixture.captured.count
        XCTAssertTrue(try h.connection.publishCollectionLoadCompletion(fresh, expected: original,
            context: lease, locale: "en", isReadCurrent: { true }, isLocaleCurrent: { true }))
        let intent = try XCTUnwrap(h.connection.explicitCareReadIntent)
        XCTAssertTrue(h.connection.consumeExplicitCareRead(intent, locale: "en"))
        XCTAssertFalse(h.connection.consumeExplicitCareRead(intent, locale: "en"))
        XCTAssertEqual(h.fixture.captured.count, requests, "Publication never performs HTTP")
        try collectionReadReply(h, failure: .notConnectedToInternet)
        let cached = try await repository.collectionCards(context: lease)
        XCTAssertTrue(cached.isCached)
        XCTAssertFalse(try h.connection.publishCollectionLoadCompletion(cached, expected: original,
            context: lease, locale: "en", isReadCurrent: { true }, isLocaleCurrent: { true }))
        XCTAssertNil(h.connection.explicitCareReadIntent)
        assertClosed(h)

        let empty = try Harness()
        defer { empty.close() }
        let scope = try await permanentCollection(empty)
        let emptyLease = try await empty.connection.collectionLease(expected: scope)
        try collectionReadReply(empty, failure: .notConnectedToInternet)
        do {
            _ = try await XCTUnwrap(empty.connection.repository).collectionCards(context: emptyLease)
            XCTFail("No cached profile: a failed read must throw")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        XCTAssertNil(empty.connection.explicitCareReadIntent)
        assertClosed(empty)
    }

    func testCollectionCompletionRejectsOldReadLocaleAndSDKEpochABA() async throws {
        for mode in 0..<4 {
            let h = try Harness()
            defer { h.close() }
            let original = try await permanentCollection(h)
            let lease = try await h.connection.collectionLease(expected: original)
            try collectionReadReply(h)
            let result = try await XCTUnwrap(h.connection.repository).collectionCards(context: lease)
            if mode >= 2 {
                try auth(h, owner: other, token: "fixture-b")
                try await h.signIn()
                if mode == 3 { _ = try await permanentCollection(h) }
            }
            let count = h.fixture.captured.count
            XCTAssertFalse(try h.connection.publishCollectionLoadCompletion(result, expected: original,
                context: lease, locale: "en", isReadCurrent: { mode != 0 },
                isLocaleCurrent: { mode != 1 }))
            XCTAssertNil(h.connection.explicitCareReadIntent)
            XCTAssertEqual(h.fixture.captured.count, count)
            assertClosed(h)
        }
    }

    func testSuspendedCollectionLoadCannotPublishAfterLocaleChangeCancellationOrABA() async throws {
        for mode in 0..<3 {
            let h = try Harness()
            defer { h.close() }
            let original = try await permanentCollection(h)
            let lease = try await h.connection.collectionLease(expected: original)
            let repository = try XCTUnwrap(h.connection.repository)
            var localeCurrent = true
            try collectionReadReply(h, suspend: true)
            let task = Task { @MainActor in
                let result = try await repository.collectionCards(context: lease)
                return try h.connection.publishCollectionLoadCompletion(result, expected: original,
                    context: lease, locale: "en", isReadCurrent: { true },
                    isLocaleCurrent: { localeCurrent })
            }
            try await waitForSuspension(h.fixture)
            if mode == 0 { localeCurrent = false }
            if mode == 1 { task.cancel() }
            if mode == 2 {
                try auth(h, owner: other, token: "fixture-b")
                try await h.signIn()
                _ = try await permanentCollection(h)
            }
            h.fixture.release()
            do {
                let published = try await task.value
                XCTAssertFalse(published)
            } catch {
                XCTAssertNotEqual(mode, 0, "Locale-only completion must finish the domain read")
            }
            XCTAssertNil(h.connection.explicitCareReadIntent)
            assertClosed(h)
        }
    }

    func testExplicitCareReadIsOneShotScopedAndPassiveCacheReadsEmitNothing() async throws {
        let h = try Harness(), foreign = try Harness()
        defer { h.close(); foreign.close() }
        // Cache APIs require permanent JWT claims as well as the real SDK binding.
        let payload = try json(["sub": owner.uuidString, "is_anonymous": false]).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try auth(h, owner: owner, token: "fixture." + payload + ".signature")
        try await h.signIn()
        let original = try await h.connection.sessionSnapshot()
        let lease = try await h.connection.collectionLease(expected: original)
        let repository = try XCTUnwrap(h.connection.repository)
        _ = try await repository.cachedCareOverview(context: lease)
        _ = try await repository.pendingProfileReminderHour(context: lease)
        XCTAssertEqual(h.connection.authClassification, .permanent(original))
        XCTAssertNil(h.connection.explicitCareReadIntent)
        let requests = h.fixture.captured.count
        var currentLocale = "en"
        let retainedLocale = {
            h.connection.publishExplicitCareRead(expected: original, locale: "en",
                isLocaleCurrent: { currentLocale == "en" })
        }
        XCTAssertTrue(retainedLocale())
        let oldLocale = try XCTUnwrap(h.connection.explicitCareReadIntent)
        currentLocale = "pl"
        XCTAssertFalse(retainedLocale())
        XCTAssertFalse(h.connection.consumeExplicitCareRead(oldLocale, locale: currentLocale))
        XCTAssertNil(h.connection.explicitCareReadIntent)
        XCTAssertFalse(h.connection.publishExplicitCareRead(expected: original, locale: "en", isLocaleCurrent: { false }))
        XCTAssertNil(h.connection.explicitCareReadIntent)
        XCTAssertTrue(h.connection.publishExplicitCareRead(expected: original, locale: "en", isLocaleCurrent: { true }))
        let first = try XCTUnwrap(h.connection.explicitCareReadIntent)
        XCTAssertFalse(foreign.connection.consumeExplicitCareRead(first, locale: "en"))
        XCTAssertTrue(h.connection.consumeExplicitCareRead(first, locale: "en"))
        XCTAssertNil(h.connection.explicitCareReadIntent)
        XCTAssertFalse(h.connection.consumeExplicitCareRead(first, locale: "en"))
        XCTAssertTrue(h.connection.publishExplicitCareRead(expected: original, locale: "en", isLocaleCurrent: { true }))
        let second = try XCTUnwrap(h.connection.explicitCareReadIntent)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(h.connection.consumeExplicitCareRead(first, locale: "en"))
        XCTAssertFalse(h.connection.consumeExplicitCareRead(second, locale: "pl"))
        XCTAssertFalse(h.connection.consumeExplicitCareRead(second, locale: "en"))
        XCTAssertTrue(h.connection.publishExplicitCareRead(expected: original, locale: "pl", isLocaleCurrent: { true }))
        let third = try XCTUnwrap(h.connection.explicitCareReadIntent)
        XCTAssertNotEqual(second.id, third.id)
        XCTAssertTrue(h.connection.consumeExplicitCareRead(third, locale: "pl"))
        XCTAssertEqual(h.fixture.captured.count, requests)
        assertClosed(h)
        assertClosed(foreign)
    }

    func testExplicitCareReadRejectsRetainedPublicationAndConsumptionAfterSDKEpochChanges() async throws {
        // Owner switch, same-token refresh, and same-token A-B-A.
        for mode in 0..<3 {
            let h = try Harness()
            defer { h.close() }
            try auth(h, owner: owner)
            try await h.signIn()
            let original = try await h.connection.sessionSnapshot()
            let retained = {
                h.connection.publishExplicitCareRead(expected: original, locale: "en", isLocaleCurrent: { true })
            }
            XCTAssertTrue(retained())
            let emitted = try XCTUnwrap(h.connection.explicitCareReadIntent)
            if mode == 1 {
                try auth(h, owner: owner, refresh: true)
                _ = try await h.client.auth.refreshSession()
            } else {
                try auth(h, owner: other, token: "fixture-b")
                try await h.signIn()
                if mode == 2 {
                    try auth(h, owner: owner)
                    try await h.signIn()
                }
            }
            // Callback-side epoch invalidation protects both gates before rebinding.
            XCTAssertFalse(retained())
            XCTAssertFalse(h.connection.consumeExplicitCareRead(emitted, locale: "en"))
            let current = try await h.connection.sessionSnapshot()
            XCTAssertNotEqual(current, original)
            XCTAssertFalse(retained())
            XCTAssertNil(h.connection.explicitCareReadIntent)
            XCTAssertTrue(h.connection.publishExplicitCareRead(expected: current, locale: "en", isLocaleCurrent: { true }))
            let fresh = try XCTUnwrap(h.connection.explicitCareReadIntent)
            XCTAssertFalse(h.connection.consumeExplicitCareRead(emitted, locale: "en"))
            XCTAssertTrue(h.connection.consumeExplicitCareRead(fresh, locale: "en"))
            assertClosed(h)
        }
    }

    func testExplicitCareReadRejectsAnonymousAndUnresolvedSDKWithoutNetwork() async throws {
        let h = try Harness()
        defer { h.close() }
        try auth(h, owner: owner, anonymous: true)
        try await h.signIn()
        let anonymous = try await h.connection.sessionSnapshot()
        XCTAssertFalse(h.connection.publishExplicitCareRead(expected: anonymous, locale: "en", isLocaleCurrent: { true }))
        XCTAssertNil(h.connection.explicitCareReadIntent)
        try auth(h, owner: owner, anonymous: true, refresh: true)
        _ = try await h.client.auth.refreshSession()
        XCTAssertFalse(h.connection.publishExplicitCareRead(expected: anonymous, locale: "en", isLocaleCurrent: { true }))
        XCTAssertNil(h.connection.explicitCareReadIntent)
        let unresolved = try Harness()
        defer { unresolved.close() }
        XCTAssertEqual(unresolved.connection.authClassification, .unresolved)
        XCTAssertFalse(unresolved.connection.publishExplicitCareRead(expected: anonymous, locale: "en", isLocaleCurrent: { true }))
        XCTAssertNil(unresolved.connection.explicitCareReadIntent)
        XCTAssertTrue(unresolved.fixture.captured.isEmpty)
        assertClosed(unresolved)
        assertClosed(h)
    }
}
