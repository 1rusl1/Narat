import Foundation
import XCTest
import SwiftData
import Supabase
@testable import Plants

private final class ConnectionAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { values[key] = nil } }
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
        let reply: Reply? = lock.withLock {
            requests.append(request)
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

        init(
            storedSession: Session? = nil, emitLocalSessionAsInitialSession: Bool = true,
            prepareFixture: (ConnectionHTTPFixture) throws -> Void = { _ in }
        ) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = try NativeAuthConfiguration(values: [
                "NaratSupabaseURL": "https://" + UUID().uuidString.lowercased() + ".invalid",
                "NaratSupabasePublishableKey": "fixture-public-key"
            ])
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
            let schema = Schema([
                LocalOutboxRecord.self, CatalogueCreateConfirmationRecord.self,
                CatalogueInputCheckpointRecord.self, GuestDraftCacheRecord.self,
                SyncedEntityRecord.self, SyncCheckpointRecord.self
            ])
            store = LocalStore(modelContainer: try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: directory.appendingPathComponent("connection.sqlite"))
            ]))
            connection = CatalogueConnection(
                client: client, configuration: configuration, store: store,
                transport: URLSessionAPITransport(session: http)
            )
        }

        func close() {
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
        signup: Bool = false, expired: Bool = false, suspend: Bool = false, refresh: Bool = false
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
            query: signup ? nil : (refresh ? "grant_type=refresh_token" : "grant_type=id_token")
        ))
    }

    private func plants(_ h: Harness, suspendGET: Bool = false, suspendPOST: Bool = false) throws {
        let timestamp = "2026-11-03T09:00:00.123456+00:00"
        h.fixture.append(.init(
            method: "GET", path: "/functions/v1/plants-api/sync",
            data: try json([
                "until": timestamp, "has_more": false, "last_cursor": NSNull(),
                "next_since": timestamp, "entitlement": NSNull(), "changes": [],
                "profile": ["preferred_locale": "pl", "reminder_hour_local": 9,
                            "report_notifications_enabled": true, "trial_reminder_enabled": false]
            ]), suspend: suspendGET, query: "limit=200"
        ))
        h.fixture.append(.init(
            method: "POST", path: "/functions/v1/plants-api/commands",
            data: try json([
                "plant_id": "33333333-3333-4333-8333-333333333333", "care_revision": 1,
                "context_state": "current", "next_available_step": "enable_basic_care",
                "paid_action": NSNull(), "plan_availability": "available",
                "watermark": "2026-11-03T09:00:01.123456+00:00"
            ]), suspend: suspendPOST
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
}
