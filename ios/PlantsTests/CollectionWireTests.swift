import XCTest
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
        var requests: [(String?, String?, SyncWireCursorDTO?, Int)] = invalidDates.flatMap {
            [($0, nil, nil, 200), (nil, $0, nil, 200)]
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
