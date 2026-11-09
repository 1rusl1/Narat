import XCTest
import SwiftData
@testable import Plants

private actor CatalogueTransport: PlantsAPITransport {
    enum Reply: Sendable {
        case http(Int, String)
        case network
    }

    private var replies: [Reply]
    private var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func capturedRequests() -> [URLRequest] { requests }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        switch replies.removeFirst() {
        case .network:
            throw URLError(.networkConnectionLost)
        case let .http(status, json):
            return (
                Data(json.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        }
    }
}

final class CollectionWireTests: XCTestCase {
    private let operationId = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let serverPlantId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let timestamp = "2026-11-03T09:00:00.999999+00:00"

    private func receiptJSON() -> String {
        """
        {"plant_id":"22222222-2222-4222-8222-222222222222","care_revision":1,
         "context_state":"current","next_available_step":"enable_basic_care",
         "paid_action":"generate_full_routine_plan","plan_availability":"available",
         "watermark":"\(timestamp)","future_field":{"ignored":true}}
        """
    }

    private func envelope(_ payload: String = #"{"creation_source":"catalogue","plant_id":"fixture_collection_cap"}"#)
        -> CommandEnvelopeDTO {
        CommandEnvelopeDTO(operationId: operationId, commandName: "plant.create", payloadJSON: payload)
    }

    private func client(_ transport: CatalogueTransport) -> PlantsAPIClient {
        PlantsAPIClient(
            baseURL: URL(string: "https://example.invalid/functions/v1/plants-api")!,
            transport: transport,
            installationCredential: "fixture-installation",
            clientLocale: "en",
            bearerToken: "fixture-user-token"
        )
    }

    func testCanonicalReceiptAndExactRequestRetryAfter503() async throws {
        let error = #"{"error":{"code":"INTERNAL_ERROR","message":"Try again","retryable":true}}"#
        let transport = CatalogueTransport([.http(503, error), .http(200, receiptJSON())])
        let api = client(transport)
        let command = envelope(#"{ "creation_source":"catalogue", "plant_id":"fixture_collection_cap", "display_name":null }"#)
        do {
            _ = try await api.sendCatalogueCreate(command)
            XCTFail("503 must not confirm creation")
        } catch let failure as APIErrorResponse {
            XCTAssertEqual(failure.error.code, "INTERNAL_ERROR")
            XCTAssertTrue(failure.error.retryable)
        }
        let receipt = try await api.sendCatalogueCreate(command)
        XCTAssertEqual(receipt.plantId, serverPlantId)
        XCTAssertEqual(receipt.careRevision, 1)
        XCTAssertEqual(receipt.contextState, "current")
        XCTAssertEqual(receipt.nextAvailableStep, "enable_basic_care")
        XCTAssertEqual(receipt.planAvailability, "available")
        XCTAssertEqual(receipt.paidAction, "generate_full_routine_plan")
        XCTAssertEqual(receipt.watermarkRaw, timestamp)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/functions/v1/plants-api/commands")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-user-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Installation-Credential"), "fixture-installation")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Locale"), "en")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), operationId.uuidString.lowercased())
            let body = try XCTUnwrap(request.httpBody)
            XCTAssertEqual(try JSONDecoder().decode(CommandEnvelopeDTO.self, from: body), command)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["operation_id", "command_name", "payload_json"])
            XCTAssertEqual(object["payload_json"] as? String, command.payloadJSON)
        }
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        let encoded = try JSONEncoder().encode(receipt)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["watermark"] as? String, timestamp)
        XCTAssertNil(object["status"])
        XCTAssertNil(object["operation_id"])
        XCTAssertNil(object["replayed"])
    }

    func testSQLTimestampsAndOptionalPaidAction() async throws {
        let base = ISO8601DateFormatter().date(from: "2026-11-03T09:00:00Z")!
        let variants: [(String, TimeInterval)] = [
            ("2026-11-03T09:00:00Z", 0),
            ("2026-11-03T09:00:00.1Z", 0.1),
            ("2026-11-03T09:00:00.12+02:30", 0.12 - 9000),
            ("2026-11-03T09:00:00.123-03:30", 0.123 + 12600),
            ("2026-11-03T09:00:00.1234Z", 0.1234),
            ("2026-11-03T09:00:00.12345+15:59", 0.12345 - 57540),
            ("2026-11-03T09:00:00.999999-15:59", 0.999999 + 57540)
        ]
        for (raw, delta) in variants {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receiptJSON().utf8)) as? [String: Any])
            object["watermark"] = raw
            object["paid_action"] = NSNull()
            let data = try JSONSerialization.data(withJSONObject: object)
            let transport = CatalogueTransport([.http(200, String(decoding: data, as: UTF8.self))])
            let receipt = try await client(transport).sendCatalogueCreate(envelope())
            XCTAssertNil(receipt.paidAction)
            XCTAssertEqual(receipt.watermarkRaw, raw)
            XCTAssertEqual(receipt.watermark.timeIntervalSince1970, base.timeIntervalSince1970 + delta, accuracy: 0.000001)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receiptJSON().utf8)) as? [String: Any])
        object.removeValue(forKey: "paid_action")
        let receipt = try JSONDecoder().decode(PlantCreateReceiptDTO.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(receipt.paidAction)
    }

    func testInvalidSuccessIsRejectedByTypedAPI() async throws {
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receiptJSON().utf8)) as? [String: Any])
        let required = ["plant_id", "care_revision", "context_state", "next_available_step", "plan_availability", "watermark"]
        var invalid: [[String: Any]] = []
        for key in required {
            var missing = valid
            missing.removeValue(forKey: key)
            invalid.append(missing)
            for value in [NSNull(), true, ["unexpected": "object"]] as [Any] {
                var object = valid
                object[key] = value
                invalid.append(object)
            }
        }
        let malformed: [(String, [Any])] = [
            ("plant_id", ["not-a-uuid", ""]),
            ("care_revision", [0, -1, 1.5, "1", 9_007_199_254_740_992]),
            ("context_state", ["", " \n"]),
            ("next_available_step", ["", " "]),
            ("plan_availability", ["", " "]),
            ("paid_action", [false, 1, ["action": "invented"]]),
            ("watermark", ["2026-11-03T09:00:00", "2026-02-30T09:00:00Z",
                           "2025-02-29T09:00:00Z", "2026-11-03T24:00:00Z",
                           "2026-11-03T09:00:60Z", "2026-11-03T09:00:00.1234567Z",
                           "2026-11-03T09:00:00+16:00", "2026-11-03T09:00:00+00:60",
                           "2026-11-03T09:00:00Z\n", "garbage"])
        ]
        for (key, values) in malformed {
            for value in values {
                var object = valid
                object[key] = value
                invalid.append(object)
            }
        }
        var jsons = try invalid.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        jsons += ["null", "[]", "{}", #"{"status":"committed","operation_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","replayed":false}"#]
        for json in jsons {
            let transport = CatalogueTransport([.http(200, json)])
            do {
                _ = try await client(transport).sendCatalogueCreate(envelope())
                XCTFail("Invalid receipt accepted: \(json)")
            } catch is DecodingError {
                // A 200 response is not sufficient evidence of creation.
            }
        }
    }

    func testErrorsPropagateWithoutConfirmationAndNetworkRetryKeepsOperation() async throws {
        for (status, code, retryable) in [
            (409, "COLLECTION_LIMIT_REACHED", false), (409, "CONFLICT", false),
            (401, "UNAUTHORIZED", false), (403, "FORBIDDEN", false),
            (400, "VALIDATION_ERROR", false), (503, "INTERNAL_ERROR", true)
        ] {
            let json = """
            {"error":{"code":"\(code)","message":"Server message","retryable":\(retryable)}}
            """
            let transport = CatalogueTransport([.http(status, json)])
            do {
                _ = try await client(transport).sendCatalogueCreate(envelope())
                XCTFail("Error response must throw")
            } catch let error as APIErrorResponse {
                XCTAssertEqual(error.error.code, code)
                XCTAssertEqual(error.error.message, "Server message")
                XCTAssertEqual(error.error.retryable, retryable)
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 1)
        }
        let transport = CatalogueTransport([.network, .http(200, receiptJSON())])
        let api = client(transport)
        do {
            _ = try await api.sendCatalogueCreate(envelope())
            XCTFail("Network error must throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        _ = try await api.sendCatalogueCreate(envelope())
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Operation-Id"),
                       requests[1].value(forHTTPHeaderField: "X-Operation-Id"))
    }

    func testCataloguePayloadValidationDoesNotSendOrSubstituteIdentity() async throws {
        let transport = CatalogueTransport([])
        let api = client(transport)
        let invalid = [
            "null", "[]", "{}", #"{"creation_source":"camera","plant_id":"slug"}"#,
            #"{"creation_source":"catalogue"}"#,
            #"{"creation_source":"catalogue","plant_id":" "}"#,
            #"{"creation_source":"catalogue","taxon_id":"bad"}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","owner_id":"injected"}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","conditions":{"owner_id":"injected"}}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","overrides":{"plan_availability":"available"}}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","photo_id":"unverified"}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","conditions":{"light_source":"camera_estimate"}}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","conditions":{"light_confirmed":1}}"#,
            #"{"creation_source":"catalogue","plant_id":"slug","overrides":null}"#
        ]
        for payload in invalid {
            do {
                _ = try await api.sendCatalogueCreate(envelope(payload))
                XCTFail("Invalid payload sent")
            } catch CatalogueCreateValidationError.invalidPayload {
                // Rejected before transport.
            }
        }
        for command in [
            CommandEnvelopeDTO(operationId: operationId, commandName: "plant.update", payloadJSON: envelope().payloadJSON),
            CommandEnvelopeDTO(operationId: operationId, commandName: "plant.create", plantId: UUID(), payloadJSON: envelope().payloadJSON)
        ] {
            do {
                _ = try await api.sendCatalogueCreate(command)
                XCTFail("Invalid command sent")
            } catch CatalogueCreateValidationError.invalidCommand {
                // The SQL-created instance must not be replaced by a client target.
            }
        }
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCanonicalOverridesAndNullConditionsPassUnchanged() async throws {
        let payload = """
        {"creation_source":"catalogue","plant_id":null,
         "origin_flow_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","photo_id":null,
         "creation_intent":"care","add_method":"catalogue","personal_name":"My plant",
         "conditions":{"light_code":"medium","light_source":"manual","light_confirmed":true,
                       "watering_code":"weekly","drainage_code":"yes","pot_type":null},
         "overrides":{"taxon_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","display_name":null}}
        """
        let transport = CatalogueTransport([.http(200, receiptJSON())])
        let receipt = try await client(transport).sendCatalogueCreate(envelope(payload))
        XCTAssertEqual(receipt.plantId, serverPlantId)
        let requests = await transport.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        let command = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(command.payloadJSON, payload)
        XCTAssertEqual(command.operationId, operationId)
        XCTAssertNil(command.plantId)
    }
}

extension CollectionWireTests {
    private var syncSince: String { "2026-11-03T08:00:00.000001+00:00" }
    private var syncUntil: String { "2026-11-03T09:00:00.999999+00:00" }
    private var syncOwner: UUID { UUID(uuidString: "11111111-1111-4111-8111-111111111111")! }
    private var syncSession: NativeAuthSession {
        NativeAuthSession(userId: syncOwner, accessToken: "sync-session-token", expiresAt: .distantFuture)
    }

    private func syncObject() -> [String: Any] {
        [
            "until": syncUntil, "has_more": false, "last_cursor": NSNull(), "next_since": syncUntil,
            "profile": ["preferred_locale": "pl", "reminder_hour_local": 9,
                        "report_notifications_enabled": true, "trial_reminder_enabled": false],
            "entitlement": NSNull(), "changes": [], "future_field": ["ignored": true]
        ]
    }

    private func syncChange(
        _ time: String? = nil, id: String = "22222222-2222-4222-8222-222222222222",
        entity: String = "plants"
    ) -> [String: Any] {
        ["entity_type": entity, "id": id, "updated_at": time ?? syncUntil,
         "deleted_at": NSNull(), "data": ["name": "Plant"]]
    }

    private func syncJSON(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func syncCursorObject(_ change: [String: Any]) -> [String: Any] {
        ["since": syncSince, "until": syncUntil, "updated_at": change["updated_at"]!,
         "entity_type": change["entity_type"]!, "id": change["id"]!]
    }

    private func assertSyncRejected(
        _ object: [String: Any], since: String? = nil, until: String? = nil,
        cursor: SyncWireCursorDTO? = nil, limit: Int = 200,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let transport = CatalogueTransport([.http(200, try syncJSON(object))])
        do {
            _ = try await client(transport).fetchSyncWirePage(
                session: syncSession, since: since, until: until, cursor: cursor, limit: limit
            )
            XCTFail("Invalid SQL page accepted", file: file, line: line)
        } catch is DecodingError {
        } catch SyncWireValidationError.invalidPage {
        }
    }

    func testSyncSQLNestedDataTombstoneAndAuthenticatedOwner() async throws {
        var object = syncObject()
        var live = syncChange("2026-11-03T09:00:00.123456+00:00")
        live["data"] = [
            "nested": ["array": [true, NSNull(), ["number": 123, "text": "żółty"]]],
            "decimal": 1.25, "owner_id": "projection-value"
        ]
        var tombstone = syncChange()
        tombstone["deleted_at"] = syncUntil
        tombstone["data"] = NSNull()
        object["changes"] = [live, tombstone]
        object["owner_id"] = "99999999-9999-4999-8999-999999999999"
        object["entitlement"] = [
            "product_id": "app.narat.plants.pro.yearly", "state": "active", "offer_kind": "paid",
            "valid_until": syncUntil, "grace_until": NSNull(), "trial_end_at": NSNull(),
            "auto_renew_enabled": true, "future": 1
        ]
        let transport = CatalogueTransport([.http(200, try syncJSON(object))])
        let result = try await client(transport).fetchSyncWirePage(session: syncSession, since: syncSince)
        XCTAssertEqual(result.ownerId, syncOwner)
        XCTAssertEqual(result.page.profile.preferredLocale, "pl")
        XCTAssertEqual(result.page.entitlement?.validUntil, syncUntil)
        XCTAssertNil(result.page.entitlement?.graceUntil)
        XCTAssertEqual(result.page.changes[1].data, .null)
        XCTAssertEqual(result.page.changes[1].deletedAt, syncUntil)
        guard case let .object(data) = result.page.changes[0].data else { return XCTFail("Expected SQL object") }
        XCTAssertEqual(data["nested"], .object([
            "array": .array([.bool(true), .null, .object(["number": .number(123), "text": .string("żółty")])])
        ]))
        XCTAssertEqual(data["decimal"], .number(Decimal(string: "1.25")!))
        let roundTrip = try JSONDecoder().decode(SyncWireJSON.self, from: JSONEncoder().encode(result.page.changes[0].data))
        XCTAssertEqual(roundTrip, result.page.changes[0].data)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sync-session-token")
    }

    func testSyncEmptyPageAndRawTimestampQueriesAcrossFractionsAndOffsets() async throws {
        let variants = [
            "2026-11-03T09:00:00Z", "2026-11-03T09:00:00.1Z",
            "2026-11-03T09:00:00.12+02:30", "2026-11-03T09:00:00.123-03:30",
            "2026-11-03T09:00:00.1234Z", "2026-11-03T09:00:00.12345+15:59",
            "2026-11-03T09:00:00.123456-15:59"
        ]
        for raw in variants {
            var object = syncObject()
            object["until"] = raw
            object["next_since"] = raw
            let transport = CatalogueTransport([.http(200, try syncJSON(object))])
            let result = try await client(transport).fetchSyncWirePage(
                session: syncSession, since: raw, until: raw, limit: 1
            )
            XCTAssertTrue(result.page.changes.isEmpty)
            XCTAssertNil(result.page.entitlement)
            XCTAssertFalse(result.page.profile.trialReminderEnabled)
            XCTAssertEqual(result.page.profile.reminderHourLocal, 9)
            XCTAssertEqual(result.page.until, raw)
            XCTAssertEqual(result.page.nextSince, raw)
            let requests = await transport.capturedRequests()
            let request = try XCTUnwrap(requests.first)
            let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/functions/v1/plants-api/sync")
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["since": raw, "until": raw, "limit": "1"])
            if raw.contains("+") { XCTAssertTrue(request.url!.absoluteString.contains("%2B")) }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sync-session-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Locale"), "en")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Installation-Credential"), "fixture-installation")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Operation-Id"))
        }
    }

    func testSyncPaginationKeepsWindowAndAdvancesOneMicrosecond() async throws {
        var first = syncObject()
        let change = syncChange("2026-11-03T09:00:00.999998+00:00")
        first["has_more"] = true
        first["next_since"] = NSNull()
        first["last_cursor"] = syncCursorObject(change)
        first["changes"] = [change]
        var final = syncObject()
        final["changes"] = [syncChange()]
        let transport = CatalogueTransport([.http(200, try syncJSON(first)), .http(200, try syncJSON(final))])
        let api = client(transport)
        let start = try await api.fetchSyncWirePage(session: syncSession, since: syncSince, until: syncUntil, limit: 1)
        let cursor = try XCTUnwrap(start.page.lastCursor)
        XCTAssertNil(start.page.nextSince)
        XCTAssertEqual(cursor.updatedAt, "2026-11-03T09:00:00.999998+00:00")
        XCTAssertEqual(cursor.since, syncSince)
        XCTAssertEqual(cursor.until, syncUntil)
        let end = try await api.fetchSyncWirePage(
            session: syncSession, since: cursor.since, until: cursor.until, cursor: cursor, limit: 1
        )
        XCTAssertEqual(end.page.nextSince, syncUntil)
        XCTAssertFalse(end.page.hasMore)
        XCTAssertNil(end.page.lastCursor)
        let requests = await transport.capturedRequests()
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, [
            "since": syncSince, "until": syncUntil, "limit": "1",
            "cursor_updated_at": cursor.updatedAt, "cursor_entity_type": "plants",
            "cursor_id": serverPlantId.uuidString.lowercased()
        ])
    }

    func testSyncStrictTupleOrderWithEqualTimestampAndEquivalentOffsets() async throws {
        let time = "2026-11-03T09:00:00.999999Z"
        let cursor = SyncWireCursorDTO(
            since: syncSince, until: syncUntil, updatedAt: time, entityType: "care_tasks", id: serverPlantId
        )
        var object = syncObject()
        object["changes"] = [
            syncChange(time, id: "33333333-3333-4333-8333-333333333333", entity: "care_tasks"),
            syncChange("2026-11-03T11:00:00.999999+02:00")
        ]
        let transport = CatalogueTransport([.http(200, try syncJSON(object))])
        let result = try await client(transport).fetchSyncWirePage(
            session: syncSession, since: syncSince, until: syncUntil, cursor: cursor
        )
        XCTAssertEqual(result.page.changes.count, 2)
        object["changes"] = [syncChange(time, entity: "care_tasks")]
        try await assertSyncRejected(object, since: syncSince, until: syncUntil, cursor: cursor)
        object["changes"] = [syncChange(time), syncChange(time)]
        try await assertSyncRejected(object)
        object["changes"] = [syncChange(time), syncChange(time, entity: "care_tasks")]
        try await assertSyncRejected(object)
    }

    func testSyncInvalidRequestsNeverReachTransport() async throws {
        let transport = CatalogueTransport([])
        let api = client(transport)
        let invalidDates = [
            "", "2026-11-03T09:00:00", "2026-02-30T09:00:00Z", "2025-02-29T09:00:00Z",
            "2026-11-03T24:00:00Z", "2026-11-03T09:00:60Z", "2026-11-03T09:00:00.1234567Z",
            "2026-11-03T09:00:00+16:00", "2026-11-03T09:00:00+00:60", "2026-11-03T09:00:00Z\n"
        ]
        var requests: [(String?, String?, SyncWireCursorDTO?, Int)] = invalidDates.flatMap { raw -> [(String?, String?, SyncWireCursorDTO?, Int)] in
            [(raw, nil, nil, 200), (nil, raw, nil, 200)]
        }
        requests += [(syncUntil, syncSince, nil, 200), (nil, nil, nil, 0), (nil, nil, nil, 501)]
        for (time, entity, end, start) in [
            (syncSince, "plants", syncUntil, syncSince),
            ("2026-11-03T09:00:01Z", "plants", syncUntil, syncSince),
            (syncUntil, "rooms", syncUntil, syncSince),
            ("bad", "plants", syncUntil, syncSince),
            (syncUntil, "plants", syncSince, syncSince)
        ] {
            let cursor = SyncWireCursorDTO(since: start, until: end, updatedAt: time, entityType: entity, id: serverPlantId)
            requests.append((syncSince, syncUntil, cursor, 200))
        }
        let cursor = SyncWireCursorDTO(since: syncSince, until: syncUntil, updatedAt: syncUntil, entityType: "plants", id: serverPlantId)
        requests += [(syncSince, nil, cursor, 200), (nil, syncUntil, cursor, 200)]
        for (since, until, cursor, limit) in requests {
            do {
                _ = try await api.fetchSyncWirePage(session: syncSession, since: since, until: until, cursor: cursor, limit: limit)
                XCTFail("Invalid query sent")
            } catch SyncWireValidationError.invalidRequest {}
        }
        for session in [
            NativeAuthSession(userId: syncOwner, accessToken: " ", expiresAt: .distantFuture),
            NativeAuthSession(userId: syncOwner, accessToken: "expired", expiresAt: .distantPast)
        ] {
            do {
                _ = try await api.fetchSyncWirePage(session: session)
                XCTFail("Invalid session sent")
            } catch SyncWireValidationError.invalidSession {}
        }
        let captured = await transport.capturedRequests()
        XCTAssertTrue(captured.isEmpty)
    }

    func testSyncMalformedEnvelopeAndProjectionsAreRejected() async throws {
        let valid = syncObject()
        for key in ["until", "has_more", "last_cursor", "next_since", "profile", "entitlement", "changes"] {
            var missing = valid
            missing.removeValue(forKey: key)
            try await assertSyncRejected(missing)
            var wrong = valid
            wrong[key] = ["wrong": true]
            try await assertSyncRejected(wrong)
        }
        let profile = try XCTUnwrap(valid["profile"] as? [String: Any])
        let entitlement: [String: Any] = [
            "product_id": "product", "state": "active", "offer_kind": "paid",
            "valid_until": NSNull(), "grace_until": NSNull(), "trial_end_at": NSNull(),
            "auto_renew_enabled": true
        ]
        for (projection, fields) in [("profile", profile), ("entitlement", entitlement), ("change", syncChange())] {
            for key in fields.keys {
                for replacement in [nil, ["unexpected": true]] as [Any?] {
                    var malformed = fields
                    malformed[key] = key == "data" && replacement != nil ? true : replacement
                    var object = valid
                    if projection == "change" { object["changes"] = [malformed] }
                    else { object[projection] = malformed }
                    try await assertSyncRejected(object)
                }
            }
        }
        for (field, value) in [
            ("preferred_locale", "de" as Any), ("reminder_hour_local", 24),
            ("reminder_hour_local", 1.5), ("report_notifications_enabled", 1)
        ] {
            var malformed = profile
            malformed[field] = value
            var object = valid
            object["profile"] = malformed
            try await assertSyncRejected(object)
        }
        for (field, value) in [
            ("id", "invalid" as Any), ("entity_type", "rooms"), ("entity_type", "free_care_slots"),
            ("updated_at", "2026-02-30T09:00:00Z"), ("deleted_at", "invalid"),
            ("data", NSNull()), ("data", []), ("data", "scalar")
        ] {
            var change = syncChange()
            change[field] = value
            var object = valid
            object["changes"] = [change]
            try await assertSyncRejected(object)
        }
        for field in ["valid_until", "grace_until", "trial_end_at", "offer_kind"] {
            var malformed = entitlement
            malformed[field] = "invalid"
            var object = valid
            object["entitlement"] = malformed
            try await assertSyncRejected(object)
        }
        var object = valid
        var tombstone = syncChange()
        tombstone["deleted_at"] = syncUntil
        object["changes"] = [tombstone]
        try await assertSyncRejected(object)
    }

    func testSyncPaginationRejectsPartialMismatchedAndCrossWindowPages() async throws {
        var page = syncObject()
        let change = syncChange()
        page["has_more"] = true
        page["next_since"] = NSNull()
        page["last_cursor"] = syncCursorObject(change)
        page["changes"] = [change]
        for key in ["since", "until", "updated_at", "entity_type", "id"] {
            var malformed = syncCursorObject(change)
            malformed.removeValue(forKey: key)
            var object = page
            object["last_cursor"] = malformed
            try await assertSyncRejected(object, since: syncSince)
        }
        for (key, value) in [
            ("since", syncUntil), ("until", syncSince), ("updated_at", syncSince),
            ("entity_type", "care_tasks"), ("id", "33333333-3333-4333-8333-333333333333")
        ] {
            var malformed = syncCursorObject(change)
            malformed[key] = value
            var object = page
            object["last_cursor"] = malformed
            try await assertSyncRejected(object, since: syncSince)
        }
        var empty = page
        empty["changes"] = []
        try await assertSyncRejected(empty, since: syncSince)
        var nextOnIntermediate = page
        nextOnIntermediate["next_since"] = syncUntil
        try await assertSyncRejected(nextOnIntermediate, since: syncSince)
        var final = syncObject()
        final["last_cursor"] = syncCursorObject(change)
        try await assertSyncRejected(final)
        final = syncObject()
        final["next_since"] = NSNull()
        try await assertSyncRejected(final)
        final["next_since"] = syncSince
        try await assertSyncRejected(final)
        final = syncObject()
        final["changes"] = [syncChange(syncSince)]
        try await assertSyncRejected(final, since: syncSince, until: syncUntil)
        final["changes"] = [syncChange("2026-11-03T09:00:01Z")]
        try await assertSyncRejected(final, until: syncUntil)
        final = syncObject()
        try await assertSyncRejected(final, until: "2026-11-03T09:00:01Z")
        final["changes"] = [syncChange("2026-11-03T09:00:00.999998Z"), syncChange()]
        try await assertSyncRejected(final, limit: 1)
    }

    func testSyncNetworkAuthAndUnavailableErrorsPropagate() async throws {
        for (status, code) in [(401, "UNAUTHORIZED"), (403, "FORBIDDEN"), (503, "INTERNAL_ERROR")] {
            let error = """
            {"error":{"code":"\(code)","message":"Server message","retryable":\(status == 503)}}
            """
            let transport = CatalogueTransport([.http(status, error)])
            do {
                _ = try await client(transport).fetchSyncWirePage(session: syncSession)
                XCTFail("HTTP error became a sync success")
            } catch let failure as APIErrorResponse {
                XCTAssertEqual(failure.error.code, code)
                XCTAssertEqual(failure.error.retryable, status == 503)
            }
        }
        let transport = CatalogueTransport([.network, .http(503, "{}"), .http(200, "null"), .http(200, "[]")])
        let api = client(transport)
        do {
            _ = try await api.fetchSyncWirePage(session: syncSession)
            XCTFail("Network failure became success")
        } catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        do {
            _ = try await api.fetchSyncWirePage(session: syncSession)
            XCTFail("Malformed 503 became success")
        } catch let error as URLError { XCTAssertEqual(error.code, .badServerResponse) }
        for _ in 0..<2 {
            do {
                _ = try await api.fetchSyncWirePage(session: syncSession)
                XCTFail("Non-object envelope accepted")
            } catch is DecodingError {}
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 4)
    }
}

/// Deliberately ignores task cancellation until released; no sleeps or blocking waits.
private actor SuspendedCollectionTransport: PlantsAPITransport {
    private let json: String
    private var requests: [URLRequest] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    init(_ json: String) { self.json = json }
    func capturedRequests() -> [URLRequest] { requests }

    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func resume() {
        release?.resume()
        release = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard requests.count == 1 else { throw URLError(.resourceUnavailable) }
        await withCheckedContinuation { continuation in
            release = continuation
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
        return (Data(json.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension CollectionWireTests {
    private var otherSyncOwner: UUID { UUID(uuidString: "44444444-4444-4444-8444-444444444444")! }

    private func diskURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sync.sqlite")
    }

    private func diskContainer(_ url: URL, allowsSave: Bool = true) throws -> ModelContainer {
        let schema = Schema([
            LocalOutboxRecord.self, GuestDraftCacheRecord.self,
            SyncedEntityRecord.self, SyncCheckpointRecord.self
        ])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, allowsSave: allowsSave)
        ])
    }

    private func requestQuery(_ request: URLRequest) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func paidSyncEntitlement() -> [String: Any] {
        ["product_id": "app.narat.pro", "state": "active", "offer_kind": "paid",
         "valid_until": syncUntil, "grace_until": NSNull(), "trial_end_at": NSNull(),
         "auto_renew_enabled": true]
    }

    /// Seeds through the real bound API/engine, then closes the disk container.
    @MainActor
    private func seedSyncDisk(_ url: URL) async throws -> [OutboxEntrySnapshot] {
        let store = LocalStore(modelContainer: try diskContainer(url))
        var page = syncObject()
        page["until"] = syncSince
        page["next_since"] = syncSince
        page["entitlement"] = paidSyncEntitlement()
        let api = client(CatalogueTransport([.http(200, try syncJSON(page))]))
        await api.bindSyncSession(syncSession)
        _ = try await SyncEngine(store: store, apiClient: api).pullDelta(for: syncOwner)
        for owner in [syncOwner, otherSyncOwner] {
            try await store.applySyncedItems([
                SyncItemDTO(entityType: "plants", id: serverPlantId,
                            updatedAt: SQLTimestamp.date(from: syncSince)!, payloadJSON: #"{"name":"confirmed"}"#)
            ], ownerId: owner)
        }
        let a = try await store.enqueueCommand(
            operationId: operationId, ownerId: syncOwner, plantId: serverPlantId,
            commandName: "care.record", payloadJSON: #"{"action":"water"}"#
        )
        let b = try await store.enqueueCommand(
            ownerId: otherSyncOwner, plantId: serverPlantId, commandName: "care.record", payloadJSON: "{}"
        )
        return [a, b]
    }

    @MainActor
    private func assertSeedUnchanged(
        _ url: URL, outbox: [OutboxEntrySnapshot], extraA: [OutboxEntrySnapshot] = []
    ) async throws {
        // An independent container must see the old checkpoint, entities, rights and queue.
        let store = LocalStore(modelContainer: try diskContainer(url))
        let raw = try await store.currentWatermarkRaw(ownerId: syncOwner)
        let profile = try await store.syncedProfile(ownerId: syncOwner)
        let rights = try await store.syncedEntitlement(ownerId: syncOwner)
        XCTAssertEqual(raw, syncSince)
        XCTAssertEqual(profile?.preferredLocale, "pl")
        XCTAssertEqual(rights?.productId, "app.narat.pro")
        for (index, owner) in [syncOwner, otherSyncOwner].enumerated() {
            let items = try await store.activeSyncedEntities(ownerId: owner, entityType: "plants")
            let pending = try await store.pendingOutboxEntries(for: owner)
            XCTAssertEqual(items.map(\.payloadJSON), [#"{"name":"confirmed"}"#])
            XCTAssertEqual(pending, [outbox[index]] + (index == 0 ? extraA : []))
        }
    }

    @MainActor
    func testCanonicalEngineTwoPagesExactDiskCheckpointAndNextRequest() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let nextSince = "2026-11-03T11:00:00.999999+02:00"
        let liveId = "33333333-3333-4333-8333-333333333333"
        var live = syncChange("2026-11-03T09:00:00.999998+00:00", id: liveId)
        live["data"] = ["nested": ["array": [true, NSNull(), ["decimal": 1.25, "name": "żółty"]]]]
        var first = syncObject()
        first["has_more"] = true
        first["next_since"] = NSNull()
        first["last_cursor"] = syncCursorObject(live)
        first["changes"] = [live]
        first["entitlement"] = paidSyncEntitlement()
        var tombstone = syncChange()
        tombstone["deleted_at"] = syncUntil
        tombstone["data"] = NSNull()
        var last = syncObject()
        last["changes"] = [tombstone]
        last["entitlement"] = paidSyncEntitlement()
        last["next_since"] = nextSince
        let transport = CatalogueTransport([.http(200, try syncJSON(first)), .http(200, try syncJSON(last))])
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let before = try await store.currentWatermarkRaw(ownerId: syncOwner)
            XCTAssertEqual(before, syncSince)
            let result = try await SyncEngine(store: store, apiClient: api).pullDelta(for: syncOwner, pageSize: 1)
            XCTAssertEqual(result, SQLTimestamp.date(from: syncUntil))
            let saved = try await store.currentWatermarkRaw(ownerId: syncOwner)
            let savedItems = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
            XCTAssertEqual(saved, nextSince)
            XCTAssertEqual(savedItems.map(\.id), [UUID(uuidString: liveId)!])
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try requestQuery(requests[0]), ["since": syncSince, "limit": "1"])
        XCTAssertEqual(try requestQuery(requests[1]), [
            "since": syncSince, "until": syncUntil, "limit": "1",
            "cursor_updated_at": "2026-11-03T09:00:00.999998+00:00",
            "cursor_entity_type": "plants", "cursor_id": liveId
        ])
        do {
            let container = try diskContainer(url)
            let store = LocalStore(modelContainer: container)
            let raw = try await store.currentWatermarkRaw(ownerId: syncOwner)
            let active = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
            let rights = try await store.syncedEntitlement(ownerId: syncOwner)
            XCTAssertEqual(raw, nextSince)
            XCTAssertEqual(active.map(\.id), [UUID(uuidString: liveId)!])
            XCTAssertEqual(rights?.validUntil, syncUntil)
            let records = try ModelContext(container).fetch(FetchDescriptor<SyncedEntityRecord>())
            let deleted = try XCTUnwrap(records.first { $0.ownerId == syncOwner && $0.entityId == serverPlantId })
            XCTAssertNotNil(deleted.deletedAt)
            XCTAssertEqual(deleted.payloadJSON, "null")
            XCTAssertEqual(deleted.updatedAtRaw, syncUntil)
            for (index, owner) in [syncOwner, otherSyncOwner].enumerated() {
                let pending = try await store.pendingOutboxEntries(for: owner)
                XCTAssertEqual(pending, [outbox[index]])
            }
        }
        // Cold-open delta must send the original SQL next_since, including its offset.
        var empty = syncObject()
        let end = "2026-11-03T10:01:00.000001Z"
        empty["until"] = end
        empty["next_since"] = end
        empty["profile"] = ["preferred_locale": "en", "reminder_hour_local": 17,
                            "report_notifications_enabled": false, "trial_reminder_enabled": true]
        let nextTransport = CatalogueTransport([.http(200, try syncJSON(empty))])
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let items = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
            let item = try XCTUnwrap(items.first)
            let data = try JSONDecoder().decode(SyncWireJSON.self, from: Data(item.payloadJSON.utf8))
            XCTAssertEqual(data, .object(["nested": .object([
                "array": .array([.bool(true), .null, .object(["decimal": .number(Decimal(string: "1.25")!), "name": .string("żółty")])])
            ])]))
            let api = client(nextTransport)
            await api.bindSyncSession(syncSession)
            let previousRights = try await store.syncedEntitlement(ownerId: syncOwner)
            let previousProfile = try await store.syncedProfile(ownerId: syncOwner)
            XCTAssertNotNil(previousRights)
            XCTAssertEqual(previousProfile?.preferredLocale, "pl")
            _ = try await SyncEngine(store: store, apiClient: api).pullDelta(for: syncOwner)
            let savedRights = try await store.syncedEntitlement(ownerId: syncOwner)
            let savedProfile = try await store.syncedProfile(ownerId: syncOwner)
            XCTAssertNil(savedRights)
            XCTAssertEqual(savedProfile?.preferredLocale, "en")
            XCTAssertEqual(savedProfile?.reminderHourLocal, 17)
        }
        let nextRequests = await nextTransport.capturedRequests()
        XCTAssertEqual(try requestQuery(XCTUnwrap(nextRequests.first)), ["since": nextSince, "limit": "200"])
        do {
            let container = try diskContainer(url)
            let store = LocalStore(modelContainer: container)
            let profile = try await store.syncedProfile(ownerId: syncOwner)
            let rights = try await store.syncedEntitlement(ownerId: syncOwner)
            XCTAssertEqual(profile?.preferredLocale, "en")
            XCTAssertEqual(profile?.reminderHourLocal, 17)
            XCTAssertEqual(profile?.trialReminderEnabled, true)
            XCTAssertNil(rights)
            let checkpoints = try ModelContext(container).fetch(FetchDescriptor<SyncCheckpointRecord>())
            let checkpoint = try XCTUnwrap(checkpoints.first { $0.ownerId == syncOwner })
            XCTAssertEqual(checkpoint.watermarkRaw, end)
            XCTAssertNil(checkpoint.entitlementState)
            XCTAssertNil(checkpoint.entitlementValidUntil)
            XCTAssertNil(checkpoint.entitlementOfferKind)
        }
        // Successful full refresh replaces only this owner's cache and preserves both queues.
        empty["until"] = "2026-11-03T10:02:00.000001Z"
        empty["next_since"] = "2026-11-03T10:02:00.000001Z"
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let refreshTransport = CatalogueTransport([.http(200, try syncJSON(empty))])
            let api = client(refreshTransport)
            await api.bindSyncSession(syncSession)
            _ = try await SyncEngine(store: store, apiClient: api).performFullRefresh(for: syncOwner)
            let own = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
            let foreign = try await store.activeSyncedEntities(ownerId: otherSyncOwner, entityType: "plants")
            let pending = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertTrue(own.isEmpty)
            XCTAssertEqual(foreign.count, 1)
            XCTAssertEqual(pending, [outbox[0]])
            let refreshRequests = await refreshTransport.capturedRequests()
            XCTAssertEqual(refreshRequests.count, 1)
            XCTAssertEqual(try requestQuery(XCTUnwrap(refreshRequests.first)), ["limit": "200"])
        }
    }

    @MainActor
    func testCanonicalFailedMalformedNonadvancingWindowsAreAtomicOnDisk() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        for mode in 0..<6 {
            let refresh = mode == 5
            let change = syncChange("2026-11-03T09:00:00.999998+00:00")
            var first = syncObject()
            var cursor = syncCursorObject(change)
            if refresh { cursor["since"] = NSNull() }
            first["changes"] = [change]
            first["has_more"] = true
            first["last_cursor"] = cursor
            first["next_since"] = NSNull()
            // If these projections were published early, existing rights would be cleared.
            var second = syncObject()
            let reply: CatalogueTransport.Reply
            switch mode {
            case 0, 5: reply = .network
            case 1:
                second.removeValue(forKey: "profile")
                reply = .http(200, try syncJSON(second))
            case 2: reply = .http(200, try syncJSON(first)) // Repeated tuple cannot progress.
            case 3:
                second["until"] = "2026-11-03T09:01:00Z"
                second["next_since"] = "2026-11-03T09:01:00Z"
                reply = .http(200, try syncJSON(second))
            default:
                second["has_more"] = true // Missing advancing cursor.
                second["next_since"] = NSNull()
                reply = .http(200, try syncJSON(second))
            }
            let transport = CatalogueTransport([.http(200, try syncJSON(first)), reply])
            do {
                let store = LocalStore(modelContainer: try diskContainer(url))
                let api = client(transport)
                await api.bindSyncSession(syncSession)
                let engine = SyncEngine(store: store, apiClient: api)
                do {
                    if refresh { _ = try await engine.performFullRefresh(for: syncOwner) }
                    else { _ = try await engine.pullDelta(for: syncOwner, pageSize: 1) }
                    XCTFail("Invalid/failed window must not commit, mode \(mode)")
                } catch is URLError {
                    XCTAssertTrue(mode == 0 || mode == 5)
                } catch is DecodingError {
                    XCTAssertEqual(mode, 1)
                } catch SyncWireValidationError.invalidPage {
                    XCTAssertTrue((2...4).contains(mode))
                }
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 2)
            try await assertSeedUnchanged(url, outbox: outbox)
        }
    }

    @MainActor
    func testCanonicalSaveFailureRollsBackWindowAndProjection() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        do {
            let store = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
            // Prime every view before publishing; neither a failed write nor a
            // cached read may replace the last committed snapshot.
            let oldDate = try await store.currentWatermark(ownerId: syncOwner)
            let oldProfile = try await store.syncedProfile(ownerId: syncOwner)
            let oldRights = try await store.syncedEntitlement(ownerId: syncOwner)
            var page = syncObject()
            page["changes"] = [syncChange()]
            page["profile"] = ["preferred_locale": "en", "reminder_hour_local": 17,
                               "report_notifications_enabled": false, "trial_reminder_enabled": true]
            let json = try syncJSON(page)
            let transport = CatalogueTransport([.http(200, json), .http(200, json), .network])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let engine = SyncEngine(store: store, apiClient: api)
            for refresh in [true, false] {
                let before = try await store.currentWatermarkRaw(ownerId: syncOwner)
                let beforeItems = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
                XCTAssertEqual(before, syncSince)
                XCTAssertEqual(beforeItems.map(\.payloadJSON), [#"{"name":"confirmed"}"#])
                do {
                    if refresh { _ = try await engine.performFullRefresh(for: syncOwner) }
                    else { _ = try await engine.pullDelta(for: syncOwner) }
                    XCTFail("Read-only disk save must fail")
                } catch {
                    // Require the actual SQLite read-only save error.
                    let failure = error as NSError
                    XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                    XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
                }
                let raw = try await store.currentWatermarkRaw(ownerId: syncOwner)
                let date = try await store.currentWatermark(ownerId: syncOwner)
                let items = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
                let profile = try await store.syncedProfile(ownerId: syncOwner)
                let rights = try await store.syncedEntitlement(ownerId: syncOwner)
                XCTAssertEqual(raw, syncSince)
                XCTAssertEqual(date, oldDate)
                XCTAssertEqual(items, beforeItems)
                XCTAssertEqual(profile, oldProfile)
                XCTAssertEqual(rights, oldRights)
                XCTAssertEqual(rights?.state, "active")
                XCTAssertEqual(profile?.preferredLocale, "pl")
                for (index, owner) in [syncOwner, otherSyncOwner].enumerated() {
                    let pending = try await store.pendingOutboxEntries(for: owner)
                    let confirmed = try await store.activeSyncedEntities(ownerId: owner, entityType: "plants")
                    XCTAssertEqual(pending, [outbox[index]])
                    XCTAssertEqual(confirmed.map(\.payloadJSON), [#"{"name":"confirmed"}"#])
                }
                try await assertSeedUnchanged(url, outbox: outbox)
            }
            // A subsequent delta on this same store must request the old exact
            // since, even after both failed replacement and failed entity update.
            do {
                _ = try await engine.pullDelta(for: syncOwner)
                XCTFail("Network failure must propagate")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .networkConnectionLost)
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(try requestQuery(XCTUnwrap(requests.first)), ["limit": "200"])
            for request in requests.dropFirst() {
                XCTAssertEqual(try requestQuery(request), ["since": syncSince, "limit": "200"])
            }
        }
        try await assertSeedUnchanged(url, outbox: outbox)
    }

    @MainActor
    func testLegacyDiskDateAndPageRemainReadableAndCanonicalNeverDowngrades() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let oldDate = SQLTimestamp.date(from: "2026-11-03T08:00:00Z")!
        let oldItem = SyncItemDTO(entityType: "room", id: serverPlantId, updatedAt: oldDate,
                                  payloadJSON: #"{"name":"historical","unknown":{"kept":true}}"#)
        let legacy = SyncPageDTO(ownerId: syncOwner, items: [oldItem], hasMore: false,
                                 nextCursor: nil, serverWatermark: oldDate, limit: 200)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyJSON = String(decoding: try encoder.encode(legacy), as: UTF8.self)
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let api = client(CatalogueTransport([.http(200, legacyJSON)]))
            _ = try await SyncEngine(store: store, apiClient: api).pullDelta(for: syncOwner)
        }
        do {
            let container = try diskContainer(url)
            let store = LocalStore(modelContainer: container)
            let raw = try await store.currentWatermarkRaw(ownerId: syncOwner)
            XCTAssertEqual(raw, "2026-11-03T08:00:00.000Z")
            let checkpoint = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<SyncCheckpointRecord>()).first)
            XCTAssertNil(checkpoint.watermarkRaw) // Reading has not migrated/reformatted disk data.
            let items = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "room")
            XCTAssertEqual(items, [oldItem])
            let foreign = SyncPageDTO(ownerId: otherSyncOwner, items: [], hasMore: false,
                                      nextCursor: nil, serverWatermark: oldDate.addingTimeInterval(60), limit: 200)
            let transport = CatalogueTransport([
                .http(200, String(decoding: try encoder.encode(foreign), as: UTF8.self)),
                .http(200, legacyJSON)
            ])
            let api = client(transport)
            let engine = SyncEngine(store: store, apiClient: api)
            do {
                _ = try await engine.pullDelta(for: syncOwner)
                XCTFail("Legacy foreign owner must be rejected")
            } catch SyncWireValidationError.invalidSession {}
            await api.bindSyncSession(syncSession)
            do {
                _ = try await engine.pullDelta(for: syncOwner)
                XCTFail("Canonical client must not downgrade to legacy JSON")
            } catch is DecodingError {}
            let retained = try await store.currentWatermark(ownerId: syncOwner)
            XCTAssertEqual(retained, oldDate)
            await api.bindSyncSession(nil)
            do {
                _ = try await engine.pullDelta(for: syncOwner)
                XCTFail("Sign-out must not enable legacy mode")
            } catch SyncWireValidationError.invalidSession {}
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 2)
        }
        let transport = CatalogueTransport([.http(200, try syncJSON(syncObject()))])
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            _ = try await SyncEngine(store: store, apiClient: api).pullDelta(for: syncOwner)
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(try requestQuery(XCTUnwrap(requests.first)), [
            "since": "2026-11-03T08:00:00.000Z", "limit": "200"
        ])
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let history = try await reopened.activeSyncedEntities(ownerId: syncOwner, entityType: "room")
        XCTAssertEqual(history, [oldItem])
    }

    @MainActor
    func testOwnerSwitchABAAndCancellationDuringPullAndFlushRetainDiskState() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let extra: OutboxEntrySnapshot
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            extra = try await store.enqueueCommand(
                ownerId: syncOwner, plantId: UUID(), commandName: "care.record", payloadJSON: "{}"
            )
        }
        for flush in [false, true] {
            for mode in 0..<3 {
                let json = flush
                    ? #"{"status":"committed","operation_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","replayed":false}"#
                    : try syncJSON(syncObject())
                let transport = SuspendedCollectionTransport(json)
                let api = PlantsAPIClient(transport: transport)
                await api.bindSyncSession(syncSession)
                do {
                    let store = LocalStore(modelContainer: try diskContainer(url))
                    let engine = SyncEngine(store: store, apiClient: api)
                    let owner = syncOwner
                    let operation = Task {
                        if flush { _ = try await engine.flushOutbox(for: owner) }
                        else { _ = try await engine.pullDelta(for: owner) }
                    }
                    await transport.waitForRequest()
                    if mode == 2 {
                        operation.cancel()
                    } else {
                        await api.bindSyncSession(NativeAuthSession(
                            userId: otherSyncOwner, accessToken: "owner-b-token", expiresAt: .distantFuture
                        ))
                        do {
                            _ = try await engine.flushOutbox(for: syncOwner)
                            XCTFail("Owner A queue must never be sent with owner B token")
                        } catch SyncWireValidationError.invalidSession {}
                        if mode == 1 { await api.bindSyncSession(syncSession) }
                    }
                    await transport.resume()
                    do {
                        try await operation.value
                        XCTFail("Stale/cancelled operation must fail")
                    } catch is CancellationError {
                        XCTAssertEqual(mode, 2)
                    } catch SyncWireValidationError.invalidSession {
                        XCTAssertNotEqual(mode, 2)
                    }
                    let requests = await transport.capturedRequests()
                    XCTAssertEqual(requests.count, 1)
                    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sync-session-token")
                }
                try await assertSeedUnchanged(url, outbox: outbox, extraA: [extra])
            }
        }
    }

    @MainActor
    func testStorePublicationRevalidatesSessionGenerationAndCanonicalCreateDrainsExistingOutbox() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            let api = client(CatalogueTransport([]))
            await api.bindSyncSession(syncSession)
            let stale = try await api.captureSyncContext(ownerId: syncOwner)
            await api.bindSyncSession(NativeAuthSession(
                userId: otherSyncOwner, accessToken: "b-token", expiresAt: .distantFuture
            ))
            await api.bindSyncSession(syncSession)
            do {
                try await store.publishSyncWindow(
                    items: [], ownerId: syncOwner, watermark: SQLTimestamp.date(from: syncUntil),
                    fullRefresh: true, context: stale, authority: api.syncAuthority
                )
                XCTFail("Store must reject a stale generation even when owner A is active again")
            } catch SyncWireValidationError.invalidSession {}
            do {
                try await store.finishOutboxEntry(
                    operationId: operationId, context: stale, authority: api.syncAuthority
                )
                XCTFail("Store must not acknowledge a stale operation")
            } catch SyncWireValidationError.invalidSession {}
        }
        try await assertSeedUnchanged(url, outbox: outbox)
        do {
            let store = LocalStore(modelContainer: try diskContainer(url))
            // Existing legacy entry remains meaningful; canonical create consumes the
            // accepted SQL receipt on the same drain, without a second queue.
            let create = try await store.enqueueCommand(
                ownerId: syncOwner, plantId: nil, commandName: "plant.create", payloadJSON: envelope().payloadJSON
            )
            let transport = CatalogueTransport([
                .http(200, #"{"status":"committed","operation_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","replayed":false}"#),
                .http(200, receiptJSON())
            ])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let count = try await SyncEngine(store: store, apiClient: api).flushOutbox(for: syncOwner)
            XCTAssertEqual(count, 2)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Operation-Id"), create.operationId.uuidString.lowercased())
        }
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let pendingA = try await reopened.pendingOutboxEntries(for: syncOwner)
        let pendingB = try await reopened.pendingOutboxEntries(for: otherSyncOwner)
        XCTAssertTrue(pendingA.isEmpty)
        XCTAssertEqual(pendingB, [outbox[1]])
    }
}
