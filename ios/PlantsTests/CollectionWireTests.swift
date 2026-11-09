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
