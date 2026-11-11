import XCTest
import SwiftData
@testable import Plants

extension CollectionWireTests {
    /// Exact agreed wire6d689b7 responses, embedded for Simulator execution.
    private var accessFixtures: [(name: String, json: String)] {
        [
            ("free_starter_and_shared_month", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":false,"starter":{"identification_remaining":1,"diagnosis_remaining":0,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":"2026-11-01T10:20:00.123456Z"},"monthly":{"quota_kind":"free_monthly","registered_at":"2026-10-31T10:20:00.123456Z","period_start":"2026-10-31T10:20:00.123456Z","period_end":"2026-11-30T10:20:00.123456Z","limit":3,"consumed":2,"reserved":0,"remaining":1,"status":"ready"},"modes":{"identification":{"mode":"identification","allowed":true,"activeQuotaKind":"starter_identification","remaining":1,"limit":1,"inProgressJobId":null,"nextResetAt":null},"diagnosis":{"mode":"diagnosis","allowed":true,"activeQuotaKind":"free_monthly","remaining":1,"limit":3,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z"}}}"#),
            ("trial_or_paid_same_spend", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":false,"starter":{"identification_remaining":1,"diagnosis_remaining":0,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":"2026-11-01T10:20:00.123456Z"},"monthly":{"quota_kind":"paid_monthly","registered_at":"2026-10-31T10:20:00.123456Z","period_start":"2026-10-31T10:20:00.123456Z","period_end":"2026-11-30T10:20:00.123456Z","limit":100,"consumed":2,"reserved":0,"remaining":98,"status":"ready"},"modes":{"identification":{"mode":"identification","allowed":true,"activeQuotaKind":"paid_monthly","remaining":98,"limit":100,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z"},"diagnosis":{"mode":"diagnosis","allowed":true,"activeQuotaKind":"paid_monthly","remaining":98,"limit":100,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z"}}}"#),
            ("expired_paid_no_refill", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":false,"starter":{"identification_remaining":0,"diagnosis_remaining":0,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":"2026-11-01T10:20:00.123456Z"},"monthly":{"quota_kind":"free_monthly","registered_at":"2026-10-31T10:20:00.123456Z","period_start":"2026-10-31T10:20:00.123456Z","period_end":"2026-11-30T10:20:00.123456Z","limit":3,"consumed":7,"reserved":0,"remaining":0,"status":"ready"},"modes":{"identification":{"mode":"identification","allowed":false,"activeQuotaKind":"free_monthly","remaining":0,"limit":3,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z","reason":"free_monthly_exhausted"},"diagnosis":{"mode":"diagnosis","allowed":false,"activeQuotaKind":"free_monthly","remaining":0,"limit":3,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z","reason":"free_monthly_exhausted"}}}"#),
            ("legacy_unknown_starter_still_available", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":false,"starter":{"identification_remaining":1,"diagnosis_remaining":0,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":"2026-11-01T10:20:00.123456Z"},"monthly":{"quota_kind":"free_monthly","registered_at":null,"period_start":null,"period_end":null,"limit":null,"consumed":null,"reserved":null,"remaining":null,"status":"registration_required"},"modes":{"identification":{"mode":"identification","allowed":true,"activeQuotaKind":"starter_identification","remaining":1,"limit":1,"inProgressJobId":null,"nextResetAt":null},"diagnosis":{"mode":"diagnosis","allowed":false,"activeQuotaKind":"free_monthly","remaining":0,"limit":3,"inProgressJobId":null,"nextResetAt":null,"reason":"quota_registration_required"}}}"#),
            ("legacy_spend_unresolved", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":false,"starter":{"identification_remaining":1,"diagnosis_remaining":0,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":"2026-11-01T10:20:00.123456Z"},"monthly":{"quota_kind":"free_monthly","registered_at":"2026-10-31T10:20:00.123456Z","period_start":"2026-10-31T10:20:00.123456Z","period_end":"2026-11-30T10:20:00.123456Z","limit":null,"consumed":null,"reserved":null,"remaining":null,"status":"history_unresolved"},"modes":{"identification":{"mode":"identification","allowed":true,"activeQuotaKind":"starter_identification","remaining":1,"limit":1,"inProgressJobId":null,"nextResetAt":null},"diagnosis":{"mode":"diagnosis","allowed":false,"activeQuotaKind":"free_monthly","remaining":0,"limit":3,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z","reason":"quota_history_unresolved"}}}"#),
            ("guest_two_independent_starters", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":true,"starter":{"identification_remaining":1,"diagnosis_remaining":1,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":null},"monthly":{"quota_kind":null,"registered_at":null,"period_start":null,"period_end":null,"limit":null,"consumed":null,"reserved":null,"remaining":null,"status":"not_applicable"},"modes":{"identification":{"mode":"identification","allowed":true,"activeQuotaKind":"starter_identification","remaining":1,"limit":1,"inProgressJobId":null,"nextResetAt":null},"diagnosis":{"mode":"diagnosis","allowed":true,"activeQuotaKind":"starter_diagnosis","remaining":1,"limit":1,"inProgressJobId":null,"nextResetAt":null}}}"#),
            ("paid_exhausted_no_starter_fallback", #"{"owner_id":"16380000-0000-4000-8000-000000000001","is_guest":false,"starter":{"identification_remaining":1,"diagnosis_remaining":0,"identification_in_progress_job_id":null,"diagnosis_in_progress_job_id":null,"first_starter_success_at":"2026-11-01T10:20:00.123456Z"},"monthly":{"quota_kind":"paid_monthly","registered_at":"2026-10-31T10:20:00.123456Z","period_start":"2026-10-31T10:20:00.123456Z","period_end":"2026-11-30T10:20:00.123456Z","limit":100,"consumed":100,"reserved":0,"remaining":0,"status":"ready"},"modes":{"identification":{"mode":"identification","allowed":false,"activeQuotaKind":"paid_monthly","remaining":0,"limit":100,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z","reason":"paid_monthly_exhausted"},"diagnosis":{"mode":"diagnosis","allowed":false,"activeQuotaKind":"paid_monthly","remaining":0,"limit":100,"inProgressJobId":null,"nextResetAt":"2026-11-30T10:20:00.123456Z","reason":"paid_monthly_exhausted"}}}"#)
        ]
    }

    private var accessOwner: UUID { UUID(uuidString: "16380000-0000-4000-8000-000000000001")! }
    private var accessSession: NativeAuthSession {
        NativeAuthSession(userId: accessOwner, accessToken: "captured-access-token", expiresAt: .distantFuture)
    }

    private func accessObject(_ index: Int = 0) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(accessFixtures[index].json.utf8)) as? [String: Any])
    }

    private func decodeAccess(_ object: [String: Any]) throws -> AnalysisAccessWireDTO {
        try JSONDecoder().decode(AnalysisAccessWireDTO.self, from: Data(syncJSON(object).utf8))
    }

    private func setAccessValue(_ object: inout [String: Any], path: [String], value: Any?) {
        let key = path[0]
        if path.count == 1 {
            object[key] = value
        } else {
            var child = object[key] as! [String: Any]
            setAccessValue(&child, path: Array(path.dropFirst()), value: value)
            object[key] = child
        }
    }

    func testAccessSevenCanonicalFixturesThroughRealBoundTransport() async throws {
        let limits: [Int?] = [3, 100, 3, nil, nil, nil, 100]
        let consumed: [Int?] = [2, 2, 7, nil, nil, nil, 100]
        let reserved: [Int?] = [0, 0, 0, nil, nil, nil, 0]
        let remaining: [Int?] = [1, 98, 0, nil, nil, nil, 0]
        let statuses: [AnalysisAccessWireDTO.Status] = [
            .ready, .ready, .ready, .registrationRequired, .historyUnresolved, .notApplicable, .ready
        ]
        let identificationKinds: [AnalysisAccessWireDTO.QuotaKind] = [
            .starterIdentification, .paidMonthly, .freeMonthly, .starterIdentification,
            .starterIdentification, .starterIdentification, .paidMonthly
        ]
        for (index, fixture) in accessFixtures.enumerated() {
            let direct = try JSONDecoder().decode(AnalysisAccessWireDTO.self, from: Data(fixture.json.utf8))
            let transport = CatalogueTransport([.http(200, fixture.json)])
            let api = client(transport)
            await api.bindSyncSession(accessSession)
            let context = try await api.captureSyncContext(ownerId: accessOwner)
            let snapshot = try await api.fetchAnalysisAccess(context: context, expectedGuest: index == 5)
            XCTAssertEqual(snapshot, direct, fixture.name)
            XCTAssertEqual(snapshot.ownerId, accessOwner)
            XCTAssertEqual(snapshot.isGuest, index == 5)
            XCTAssertEqual(snapshot.monthly.status, statuses[index])
            XCTAssertEqual(snapshot.monthly.limit, limits[index])
            XCTAssertEqual(snapshot.monthly.consumed, consumed[index])
            XCTAssertEqual(snapshot.monthly.reserved, reserved[index])
            XCTAssertEqual(snapshot.monthly.remaining, remaining[index])
            XCTAssertEqual(snapshot.modes["identification"]?.activeQuotaKind, identificationKinds[index])
            XCTAssertEqual(snapshot.modes["identification"]?.allowed, ![2, 6].contains(index))
            XCTAssertEqual(snapshot.modes["diagnosis"]?.allowed, [0, 1, 5].contains(index))
            XCTAssertEqual(snapshot.starter.identificationRemaining, index == 2 ? 0 : 1)
            XCTAssertEqual(snapshot.starter.diagnosisRemaining, index == 5 ? 1 : 0)
            XCTAssertNil(snapshot.starter.identificationInProgressJobId)
            XCTAssertNil(snapshot.starter.diagnosisInProgressJobId)
            XCTAssertEqual(snapshot.starter.firstStarterSuccessAt, index == 5 ? nil : "2026-11-01T10:20:00.123456Z")
            let knownPeriod = ![3, 5].contains(index)
            XCTAssertEqual(snapshot.monthly.registeredAt, knownPeriod ? "2026-10-31T10:20:00.123456Z" : nil)
            XCTAssertEqual(snapshot.monthly.periodStart, knownPeriod ? "2026-10-31T10:20:00.123456Z" : nil)
            XCTAssertEqual(snapshot.monthly.periodEnd, knownPeriod ? "2026-11-30T10:20:00.123456Z" : nil)
            if index == 1 || index == 2 || index == 6 {
                // Both modes read the same monthly pool, including consumed > current limit.
                XCTAssertEqual(snapshot.modes["identification"]?.remaining, remaining[index])
                XCTAssertEqual(snapshot.modes["diagnosis"]?.remaining, remaining[index])
                XCTAssertEqual(snapshot.modes["diagnosis"]?.limit, limits[index])
            }
            if index == 3 || index == 4 {
                XCTAssertNil(snapshot.monthly.remaining)
                XCTAssertEqual(snapshot.modes["diagnosis"]?.remaining, 0)
                XCTAssertEqual(snapshot.modes["diagnosis"]?.limit, 3)
                XCTAssertEqual(snapshot.modes["diagnosis"]?.reason,
                               index == 3 ? .registrationRequired : .historyUnresolved)
            }
            if index == 6 {
                XCTAssertEqual(snapshot.starter.identificationRemaining, 1)
                XCTAssertEqual(snapshot.modes["identification"]?.reason, .paidMonthlyExhausted)
                XCTAssertFalse(try XCTUnwrap(snapshot.modes["identification"]).allowed)
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/functions/v1/plants-api/analysis/access")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Operation-Id"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer captured-access-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Installation-Credential"), "fixture-installation")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Locale"), "en")
        }
    }

    func testAccessRequiredKeysNullsAndMalformedValuesFailClosed() throws {
        let required: [[String]] = [
            ["owner_id"], ["is_guest"], ["starter"], ["monthly"], ["modes"],
            ["starter", "identification_remaining"], ["starter", "diagnosis_remaining"],
            ["monthly", "status"], ["modes", "identification"], ["modes", "diagnosis"]
        ] + ["mode", "allowed", "activeQuotaKind", "remaining", "limit"].map { ["modes", "identification", $0] }
        let nullable: [[String]] = [
            ["starter", "identification_in_progress_job_id"], ["starter", "diagnosis_in_progress_job_id"],
            ["starter", "first_starter_success_at"]
        ] + ["quota_kind", "registered_at", "period_start", "period_end", "limit", "consumed", "reserved", "remaining"]
            .map { ["monthly", $0] }
          + ["inProgressJobId", "nextResetAt"].map { ["modes", "identification", $0] }
        for path in required + nullable {
            var object = try accessObject()
            setAccessValue(&object, path: path, value: nil)
            XCTAssertThrowsError(try decodeAccess(object), "Missing \(path)")
        }
        for path in required {
            var object = try accessObject()
            setAccessValue(&object, path: path, value: NSNull())
            XCTAssertThrowsError(try decodeAccess(object), "Null \(path)")
        }
        // Ready fields are nullable on the wire only in the explicitly unknown states.
        for key in ["quota_kind", "registered_at", "period_start", "period_end", "limit", "consumed", "reserved", "remaining"] {
            var object = try accessObject()
            setAccessValue(&object, path: ["monthly", key], value: NSNull())
            XCTAssertThrowsError(try decodeAccess(object), key)
        }
        let invalid: [([String], Any)] = [
            (["owner_id"], "foreign-not-a-uuid"), (["is_guest"], "false"),
            (["monthly", "status"], "unknown"), (["monthly", "quota_kind"], "starter_identification"),
            (["monthly", "quota_kind"], "unknown"), (["monthly", "registered_at"], "2026-02-30T00:00:00Z"),
            (["monthly", "period_start"], "2026-11-30T10:20:00.123456Z"),
            (["monthly", "period_end"], "2026-10-30T10:20:00.123456Z"),
            (["monthly", "consumed"], -1), (["monthly", "reserved"], -1),
            (["monthly", "remaining"], 2), (["monthly", "limit"], 100),
            (["monthly", "consumed"], 1.5), (["monthly", "reserved"], NSNumber(value: UInt64.max)),
            (["starter", "identification_remaining"], 2), (["starter", "diagnosis_remaining"], -1),
            (["starter", "first_starter_success_at"], "2026-11-01"),
            (["starter", "identification_in_progress_job_id"], "bad-job"),
            (["modes", "identification", "mode"], "diagnosis"),
            (["modes", "identification", "activeQuotaKind"], "unknown"),
            (["modes", "identification", "activeQuotaKind"], "starter_diagnosis"),
            (["modes", "identification", "remaining"], -1),
            (["modes", "identification", "remaining"], 2),
            (["modes", "identification", "remaining"], 0),
            (["modes", "identification", "allowed"], 1),
            (["modes", "identification", "inProgressJobId"], "not-a-uuid"),
            (["modes", "identification", "nextResetAt"], "2026-11-30T10:20:00Z"),
            (["modes", "diagnosis", "remaining"], 2),
            (["modes", "diagnosis", "nextResetAt"], "2026-11-30T10:20:00.123457Z")
        ]
        for (path, value) in invalid {
            var object = try accessObject()
            setAccessValue(&object, path: path, value: value)
            XCTAssertThrowsError(try decodeAccess(object), "\(path): \(value)")
        }
        var renamed = try accessObject()
        var modes = renamed["modes"] as! [String: Any]
        modes["care"] = modes.removeValue(forKey: "diagnosis")
        renamed["modes"] = modes
        XCTAssertThrowsError(try decodeAccess(renamed))
        for index in [3, 4, 5] {
            var object = try accessObject(index)
            setAccessValue(&object, path: ["monthly", "limit"], value: 0)
            XCTAssertThrowsError(try decodeAccess(object))
        }
        var guestMismatch = try accessObject(5)
        guestMismatch["is_guest"] = false
        XCTAssertThrowsError(try decodeAccess(guestMismatch))
    }

    func testAccessRawBoundariesAdditiveFieldsInProgressAndOverflowSafeCounts() throws {
        for offset in ["Z", "+02:30", "-03:30"] {
            var object = try accessObject()
            let start = "2026-11-01T10:20:00.000001\(offset)"
            let end = "2026-11-01T10:20:00.000002\(offset)"
            setAccessValue(&object, path: ["monthly", "registered_at"], value: start)
            setAccessValue(&object, path: ["monthly", "period_start"], value: start)
            setAccessValue(&object, path: ["monthly", "period_end"], value: end)
            setAccessValue(&object, path: ["modes", "diagnosis", "nextResetAt"], value: end)
            setAccessValue(&object, path: ["starter", "first_starter_success_at"], value: start)
            let decoded = try decodeAccess(object)
            XCTAssertEqual(decoded.monthly.registeredAt, start)
            XCTAssertEqual(decoded.monthly.periodStart, start)
            XCTAssertEqual(decoded.monthly.periodEnd, end)
            XCTAssertEqual(decoded.starter.firstStarterSuccessAt, start)
            XCTAssertEqual(decoded.modes["diagnosis"]?.nextResetAt, end)
            for path in [["future"], ["starter", "future"], ["monthly", "future"], ["modes", "diagnosis", "future"]] {
                setAccessValue(&object, path: path, value: ["additive": true])
            }
            XCTAssertEqual(try decodeAccess(object), decoded)
        }
        var inProgress = try accessObject(5)
        let job = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        setAccessValue(&inProgress, path: ["starter", "identification_in_progress_job_id"], value: job)
        setAccessValue(&inProgress, path: ["modes", "identification", "allowed"], value: false)
        setAccessValue(&inProgress, path: ["modes", "identification", "inProgressJobId"], value: job)
        setAccessValue(&inProgress, path: ["modes", "identification", "reason"], value: "starter_in_progress")
        let denied = try decodeAccess(inProgress)
        XCTAssertEqual(denied.modes["identification"]?.reason, .starterInProgress)
        XCTAssertEqual(denied.modes["identification"]?.inProgressJobId, UUID(uuidString: job))
        XCTAssertEqual(denied.modes["identification"]?.remaining, 1)
        var huge = try accessObject(2)
        setAccessValue(&huge, path: ["monthly", "consumed"], value: Int.max)
        setAccessValue(&huge, path: ["monthly", "reserved"], value: Int.max)
        let saturated = try decodeAccess(huge)
        XCTAssertEqual(saturated.monthly.remaining, 0)
        XCTAssertEqual(saturated.monthly.consumed, Int.max)
        XCTAssertEqual(saturated.monthly.reserved, Int.max)
    }

    func testAccessGuestCredentialPermanentAccountAndENPLHeaders() async throws {
        let credentials: [String?] = [nil, "", " \n "]
        for credential in credentials {
            let transport = CatalogueTransport([])
            let api = PlantsAPIClient(transport: transport, installationCredential: credential)
            await api.bindSyncSession(accessSession)
            let lease = try await api.captureSyncContext(ownerId: accessOwner)
            do {
                _ = try await api.fetchAnalysisAccess(context: lease, expectedGuest: true)
                XCTFail("Guest must provide an installation credential")
            } catch AnalysisAccessWireError.missingInstallationCredential {}
            let requests = await transport.capturedRequests()
            XCTAssertTrue(requests.isEmpty)
        }
        let transport = CatalogueTransport([.http(200, accessFixtures[0].json), .http(200, accessFixtures[0].json)])
        let api = PlantsAPIClient(transport: transport, installationCredential: nil, clientLocale: "en")
        await api.bindSyncSession(accessSession)
        let lease = try await api.captureSyncContext(ownerId: accessOwner)
        _ = try await api.fetchAnalysisAccess(context: lease, expectedGuest: false)
        try await api.updateClientLocale("pl")
        _ = try await api.fetchAnalysisAccess(context: lease, expectedGuest: false)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "X-Client-Locale") }, ["en", "pl"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Installation-Credential") == nil })
    }

    func testAccessExplicitRetryErrorsWrongSuccessAndForeignScope() async throws {
        let error = #"{"error":{"code":"INTERNAL_ERROR","message":"Try again","retryable":true}}"#
        let transport = CatalogueTransport([.http(503, error), .http(200, accessFixtures[0].json)])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let lease = try await api.captureSyncContext(ownerId: accessOwner)
        do {
            _ = try await api.fetchAnalysisAccess(context: lease, expectedGuest: false)
            XCTFail("503 must propagate")
        } catch let failure as APIErrorResponse {
            XCTAssertEqual(failure.error.code, "INTERNAL_ERROR")
            XCTAssertTrue(failure.error.retryable)
        }
        let beforeRetry = await transport.capturedRequests()
        XCTAssertEqual(beforeRetry.count, 1)
        _ = try await api.fetchAnalysisAccess(context: lease, expectedGuest: false)
        let afterRetry = await transport.capturedRequests()
        XCTAssertEqual(afterRetry.count, 2)
        XCTAssertEqual(afterRetry.first, afterRetry.last)
        for (status, code) in [(401, "UNAUTHORIZED"), (403, "FORBIDDEN")] {
            let json = #"{"error":{"code":"__CODE__","message":"Denied","retryable":false}}"#
                .replacingOccurrences(of: "__CODE__", with: code)
            let mock = CatalogueTransport([.http(status, json)])
            let failingAPI = client(mock)
            await failingAPI.bindSyncSession(accessSession)
            let context = try await failingAPI.captureSyncContext(ownerId: accessOwner)
            do {
                _ = try await failingAPI.fetchAnalysisAccess(context: context, expectedGuest: false)
                XCTFail("Auth errors must propagate")
            } catch let failure as APIErrorResponse { XCTAssertEqual(failure.error.code, code) }
            let requests = await mock.capturedRequests()
            XCTAssertEqual(requests.count, 1)
        }
        for reply in [CatalogueTransport.Reply.network, .cancelled, .urlCancelled] {
            let mock = CatalogueTransport([reply])
            let failingAPI = client(mock)
            await failingAPI.bindSyncSession(accessSession)
            let context = try await failingAPI.captureSyncContext(ownerId: accessOwner)
            do {
                _ = try await failingAPI.fetchAnalysisAccess(context: context, expectedGuest: false)
                XCTFail("Transport errors must propagate")
            } catch is CancellationError {
                if case .cancelled = reply {} else { XCTFail("Wrong cancellation") }
            } catch let failure as URLError {
                if case .network = reply { XCTAssertEqual(failure.code, .networkConnectionLost) }
                else { XCTAssertEqual(failure.code, .cancelled) }
            }
            let requests = await mock.capturedRequests()
            XCTAssertEqual(requests.count, 1)
        }
        var foreign = try accessObject()
        foreign["owner_id"] = otherSyncOwner.uuidString
        let invalidReplies: [(Int, String)] = [
            (201, accessFixtures[0].json), (204, accessFixtures[0].json),
            (200, "{}"), (200, "null"), (200, "invalid-json"),
            (200, try syncJSON(foreign)), (200, accessFixtures[5].json)
        ]
        for (status, json) in invalidReplies {
            let mock = CatalogueTransport([.http(status, json)])
            let failingAPI = client(mock)
            await failingAPI.bindSyncSession(accessSession)
            let context = try await failingAPI.captureSyncContext(ownerId: accessOwner)
            do {
                _ = try await failingAPI.fetchAnalysisAccess(context: context, expectedGuest: false)
                XCTFail("Wrong success or foreign scope must be rejected")
            } catch {}
            let requests = await mock.capturedRequests()
            XCTAssertEqual(requests.count, 1)
        }
        let wrongGuest = client(CatalogueTransport([.http(200, accessFixtures[0].json)]))
        await wrongGuest.bindSyncSession(accessSession)
        let guestLease = try await wrongGuest.captureSyncContext(ownerId: accessOwner)
        do {
            _ = try await wrongGuest.fetchAnalysisAccess(context: guestLease, expectedGuest: true)
            XCTFail("Permanent response cannot satisfy guest scope")
        } catch AnalysisAccessWireError.identityMismatch {}
    }

    func testAccessUnboundForeignStaleAndInvalidSessionsNeverDispatch() async throws {
        let transport = CatalogueTransport([])
        let api = client(transport)
        let explicitSessions: [NativeAuthSession?] = [nil, accessSession]
        for explicit in explicitSessions {
            let legacy = try api.syncAuthority.capture(ownerId: accessOwner, explicitSession: explicit)
            do {
                _ = try await api.fetchAnalysisAccess(context: legacy, expectedGuest: false)
                XCTFail("Legacy bearer-only/explicit context is not bound proof")
            } catch SyncWireValidationError.invalidSession {}
        }
        await api.bindSyncSession(accessSession)
        let lease = try await api.captureSyncContext(ownerId: accessOwner)
        let otherAPI = client(transport)
        await otherAPI.bindSyncSession(accessSession)
        do {
            _ = try await otherAPI.fetchAnalysisAccess(context: lease, expectedGuest: false)
            XCTFail("A lease from another authority is invalid")
        } catch SyncWireValidationError.invalidSession {}
        await api.bindSyncSession(accessSession)
        do {
            _ = try await api.fetchAnalysisAccess(context: lease, expectedGuest: false)
            XCTFail("Even rebinding the same session invalidates old leases")
        } catch SyncWireValidationError.invalidSession {}
        for session in [
            NativeAuthSession(userId: accessOwner, accessToken: "", expiresAt: .distantFuture),
            NativeAuthSession(userId: accessOwner, accessToken: "expired", expiresAt: .distantPast),
            NativeAuthSession(userId: otherSyncOwner, accessToken: "foreign", expiresAt: .distantFuture)
        ] {
            await api.bindSyncSession(session)
            do {
                _ = try await api.captureSyncContext(ownerId: accessOwner)
                XCTFail("Invalid session cannot be captured")
            } catch SyncWireValidationError.invalidSession {}
        }
        await api.bindSyncSession(nil)
        do {
            _ = try await api.captureSyncContext(ownerId: accessOwner)
            XCTFail("Signed-out authority cannot be captured")
        } catch SyncWireValidationError.invalidSession {}
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testAccessSuspendedSignoutRefreshABABACancelAndLocaleCapture() async throws {
        for action in 0...6 {
            let transport = SuspendedCollectionTransport(accessFixtures[0].json)
            let api = client(transport)
            let session = accessSession
            await api.bindSyncSession(session)
            let lease = try await api.captureSyncContext(ownerId: accessOwner)
            let operation = Task { try await api.fetchAnalysisAccess(context: lease, expectedGuest: false) }
            await transport.waitForRequest()
            switch action {
            case 0: await api.bindSyncSession(nil)
            case 1:
                await api.bindSyncSession(NativeAuthSession(
                    userId: accessOwner, accessToken: "refreshed-token", expiresAt: .distantFuture
                ))
            case 2, 3:
                await api.bindSyncSession(NativeAuthSession(
                    userId: otherSyncOwner, accessToken: "owner-b-token", expiresAt: .distantFuture
                ))
                if action == 3 { await api.bindSyncSession(session) }
            case 4:
                await api.updateContext(installationCredential: "changed", clientLocale: "pl", bearerToken: "changed")
            case 5: operation.cancel()
            default: try await api.updateClientLocale("pl")
            }
            await transport.resume()
            do {
                let snapshot = try await operation.value
                XCTAssertEqual(action, 6, "Stale/cancelled snapshots must never publish")
                XCTAssertEqual(snapshot.ownerId, accessOwner)
            } catch is CancellationError {
                XCTAssertEqual(action, 5)
            } catch SyncWireValidationError.invalidSession {
                XCTAssertLessThan(action, 5)
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer captured-access-token")
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Installation-Credential"), "fixture-installation")
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Client-Locale"), "en")
        }
    }
}

private actor CatalogueTransport: PlantsAPITransport {
    enum Reply: Sendable {
        case http(Int, String)
        case network
        case cancelled
        case urlCancelled
    }

    private var replies: [Reply]
    private var requests: [URLRequest] = []
    private(set) var nonRedirectingRequests = 0

    init(_ replies: [Reply]) { self.replies = replies }

    func capturedRequests() -> [URLRequest] { requests }

    func sendWithoutRedirect(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        nonRedirectingRequests += 1
        return try await send(request)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        switch replies.removeFirst() {
        case .network:
            throw URLError(.networkConnectionLost)
        case .cancelled:
            throw CancellationError()
        case .urlCancelled:
            throw URLError(.cancelled)
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

    private func client(_ transport: any PlantsAPITransport) -> PlantsAPIClient {
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
            SyncedEntityRecord.self, SyncCheckpointRecord.self,
            CatalogueCreateConfirmationRecord.self
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

extension CollectionWireTests {
    private func createCommand(operationId: UUID = UUID()) -> CommandEnvelopeDTO {
        CommandEnvelopeDTO(
            operationId: operationId, commandName: "plant.create",
            payloadJSON: #"{ "creation_source":"catalogue", "plant_id":"fixture_collection_cap", "display_name":"żółty", "photo_id":null }"#
        )
    }

    private func decodedCreateReceipt(_ changes: [String: Any] = [:]) throws -> PlantCreateReceiptDTO {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receiptJSON().utf8)) as? [String: Any])
        object.merge(changes) { _, replacement in replacement }
        return try JSONDecoder().decode(
            PlantCreateReceiptDTO.self, from: JSONSerialization.data(withJSONObject: object)
        )
    }

    @MainActor
    private func queueCreate(
        _ command: CommandEnvelopeDTO, ownerId: UUID, in store: LocalStore
    ) async throws -> OutboxEntrySnapshot {
        try await store.enqueueCommand(
            operationId: command.operationId, ownerId: ownerId, plantId: command.plantId,
            commandName: command.commandName, payloadJSON: command.payloadJSON
        )
    }

    @MainActor
    private func assertCreateStillPending(
        _ url: URL, store: LocalStore, outbox: [OutboxEntrySnapshot], create: OutboxEntrySnapshot
    ) async throws {
        for inspected in [store, LocalStore(modelContainer: try diskContainer(url))] {
            for (index, owner) in [syncOwner, otherSyncOwner].enumerated() {
                let pending = try await inspected.pendingOutboxEntries(for: owner)
                let confirmation = try await inspected.catalogueCreateConfirmation(
                    ownerId: owner, operationId: create.operationId
                )
                XCTAssertEqual(pending, [outbox[index]] + (index == 0 ? [create] : []))
                XCTAssertNil(confirmation)
            }
        }
        try await assertSeedUnchanged(url, outbox: outbox, extraA: [create])
    }

    @MainActor
    func testCreateAcknowledgementCommitsReceiptAndOnlyOriginalCommandAcrossReopen() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let command = createCommand()
        let receipt = try decodedCreateReceipt()
        let api = client(CatalogueTransport([]))
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let create = try await queueCreate(command, ownerId: syncOwner, in: store)
        let oldProfile = try await store.syncedProfile(ownerId: syncOwner)
        let oldRights = try await store.syncedEntitlement(ownerId: syncOwner)
        let oldItems = try await store.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
        try await assertCreateStillPending(url, store: store, outbox: outbox, create: create)

        try await store.acknowledgeCatalogueCreate(
            command, receipt: receipt, context: lease, authority: api.syncAuthority
        )
        for inspected in [store, LocalStore(modelContainer: try diskContainer(url))] {
            let value = try await inspected.catalogueCreateConfirmation(
                ownerId: syncOwner, operationId: command.operationId
            )
            let saved = try XCTUnwrap(value)
            XCTAssertEqual(saved.ownerId, syncOwner)
            XCTAssertEqual(saved.operationId, command.operationId)
            XCTAssertTrue(saved.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8))
            XCTAssertEqual(saved.receipt, receipt)
            XCTAssertEqual(saved.receipt.plantId, serverPlantId)
            XCTAssertEqual(saved.receipt.careRevision, 1)
            XCTAssertEqual(saved.receipt.contextState, "current")
            XCTAssertEqual(saved.receipt.nextAvailableStep, "enable_basic_care")
            XCTAssertEqual(saved.receipt.paidAction, "generate_full_routine_plan")
            XCTAssertEqual(saved.receipt.planAvailability, "available")
            XCTAssertEqual(saved.receipt.watermarkRaw, timestamp)
            // Exact replay succeeds even after the queued command has disappeared.
            try await inspected.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: lease, authority: api.syncAuthority
            )
            let afterReplay = try await inspected.catalogueCreateConfirmation(
                ownerId: syncOwner, operationId: command.operationId
            )
            let pending = try await inspected.pendingOutboxEntries(for: syncOwner)
            let raw = try await inspected.currentWatermarkRaw(ownerId: syncOwner)
            let date = try await inspected.currentWatermark(ownerId: syncOwner)
            let profile = try await inspected.syncedProfile(ownerId: syncOwner)
            let rights = try await inspected.syncedEntitlement(ownerId: syncOwner)
            let items = try await inspected.activeSyncedEntities(ownerId: syncOwner, entityType: "plants")
            XCTAssertEqual(afterReplay, saved)
            XCTAssertEqual(pending, [outbox[0]])
            XCTAssertEqual(raw, syncSince)
            XCTAssertEqual(date, SQLTimestamp.date(from: syncSince))
            XCTAssertEqual(profile, oldProfile)
            XCTAssertEqual(rights, oldRights)
            XCTAssertEqual(items, oldItems)
        }
        try await assertSeedUnchanged(url, outbox: outbox)
    }

    @MainActor
    func testCreateAcknowledgementRejectsQueueMismatchAndEveryReceiptConflict() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let command = createCommand()
        let create = try await queueCreate(command, ownerId: syncOwner, in: store)
        let wrongTarget = try await store.enqueueCommand(
            ownerId: syncOwner, plantId: serverPlantId, commandName: "plant.create",
            payloadJSON: command.payloadJSON
        )
        let receipt = try decodedCreateReceipt()
        let api = client(CatalogueTransport([]))
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let invalid: [(CommandEnvelopeDTO, CatalogueCreateAcknowledgementError)] = [
            (CommandEnvelopeDTO(operationId: command.operationId, commandName: "care.record",
                                payloadJSON: command.payloadJSON), .invalidCommand),
            (CommandEnvelopeDTO(operationId: command.operationId, commandName: "plant.create",
                                plantId: serverPlantId, payloadJSON: command.payloadJSON), .invalidCommand),
            (CommandEnvelopeDTO(operationId: command.operationId, commandName: "plant.create",
                                payloadJSON: command.payloadJSON + " "), .queuedCommandMismatch),
            (createCommand(operationId: operationId), .queuedCommandMismatch),
            (createCommand(operationId: wrongTarget.operationId), .queuedCommandMismatch),
            (createCommand(), .missingQueuedOperation)
        ]
        for (attempt, expected) in invalid {
            do {
                try await store.acknowledgeCatalogueCreate(
                    attempt, receipt: receipt, context: lease, authority: api.syncAuthority
                )
                XCTFail("A different or missing queued command must not be acknowledged")
            } catch let error as CatalogueCreateAcknowledgementError {
                XCTAssertEqual(error, expected)
            }
            let confirmation = try await store.catalogueCreateConfirmation(
                ownerId: syncOwner, operationId: attempt.operationId
            )
            XCTAssertNil(confirmation)
            let pending = try await store.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(pending, [outbox[0], create, wrongTarget])
        }
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receipt, context: lease, authority: api.syncAuthority
        )
        let original = try await store.catalogueCreateConfirmation(
            ownerId: syncOwner, operationId: command.operationId
        )
        XCTAssertNotNil(original)
        // Swift String equality normalizes Unicode; association metadata must compare bytes.
        let decomposed = command.payloadJSON.replacingOccurrences(of: "ż", with: "z\u{307}")
        XCTAssertEqual(decomposed, command.payloadJSON)
        XCTAssertFalse(decomposed.utf8.elementsEqual(command.payloadJSON.utf8))
        for payload in [command.payloadJSON + " ", decomposed] {
            do {
                try await store.acknowledgeCatalogueCreate(
                    CommandEnvelopeDTO(operationId: command.operationId, commandName: "plant.create",
                                       payloadJSON: payload),
                    receipt: receipt, context: lease, authority: api.syncAuthority
                )
                XCTFail("Changed original payload must conflict after removal")
            } catch CatalogueCreateAcknowledgementError.confirmationConflict {}
        }
        let changes: [[String: Any]] = [
            ["plant_id": otherSyncOwner.uuidString], ["care_revision": 2],
            ["context_state": "stale"], ["next_available_step": "review_conditions"],
            ["paid_action": NSNull()], ["plan_availability": "unavailable"],
            // Same instant, different exact SQL spelling is still a different receipt.
            ["watermark": "2026-11-03T11:00:00.999999+02:00"]
        ]
        for change in changes {
            do {
                try await store.acknowledgeCatalogueCreate(
                    command, receipt: decodedCreateReceipt(change), context: lease, authority: api.syncAuthority
                )
                XCTFail("A different server receipt must not overwrite confirmation")
            } catch CatalogueCreateAcknowledgementError.confirmationConflict {}
        }
        for inspected in [store, LocalStore(modelContainer: try diskContainer(url))] {
            let saved = try await inspected.catalogueCreateConfirmation(
                ownerId: syncOwner, operationId: command.operationId
            )
            let pending = try await inspected.pendingOutboxEntries(for: syncOwner)
            XCTAssertEqual(saved, original)
            XCTAssertEqual(pending, [outbox[0], wrongTarget])
        }
        try await assertSeedUnchanged(url, outbox: outbox, extraA: [wrongTarget])
    }

    @MainActor
    func testCreateConfirmationOwnerNamespacesPermitSameOperationWithoutCrossAcknowledgement() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let command = createCommand()
        let create = try await queueCreate(command, ownerId: syncOwner, in: store)
        let receiptA = try decodedCreateReceipt()
        let api = client(CatalogueTransport([]))
        let sessionB = NativeAuthSession(
            userId: otherSyncOwner, accessToken: "owner-b-token", expiresAt: .distantFuture
        )
        await api.bindSyncSession(sessionB)
        let leaseB = try await api.captureSyncContext(ownerId: otherSyncOwner)
        do {
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receiptA, context: leaseB, authority: api.syncAuthority
            )
            XCTFail("B must not acknowledge A's queue")
        } catch CatalogueCreateAcknowledgementError.missingQueuedOperation {}
        try await assertCreateStillPending(url, store: store, outbox: outbox, create: create)

        await api.bindSyncSession(syncSession)
        let leaseA = try await api.captureSyncContext(ownerId: syncOwner)
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receiptA, context: leaseA, authority: api.syncAuthority
        )
        await api.bindSyncSession(sessionB)
        let currentB = try await api.captureSyncContext(ownerId: otherSyncOwner)
        let hidden = try await store.catalogueCreateConfirmation(
            ownerId: otherSyncOwner, operationId: command.operationId
        )
        XCTAssertNil(hidden)
        do {
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receiptA, context: currentB, authority: api.syncAuthority
            )
            XCTFail("A's receipt cannot prove a missing B operation")
        } catch CatalogueCreateAcknowledgementError.missingQueuedOperation {}
        // Keep the historical global outbox uniqueness, then reuse its freed UUID for B.
        let queuedB = try await queueCreate(command, ownerId: otherSyncOwner, in: store)
        XCTAssertEqual(queuedB.ownerId, otherSyncOwner)
        let replayAPI = client(CatalogueTransport([]))
        await replayAPI.bindSyncSession(syncSession)
        let replayLease = try await replayAPI.captureSyncContext(ownerId: syncOwner)
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receiptA, context: replayLease, authority: replayAPI.syncAuthority
        )
        let stillPendingB = try await store.pendingOutboxEntries(for: otherSyncOwner)
        let stillHiddenB = try await store.catalogueCreateConfirmation(
            ownerId: otherSyncOwner, operationId: command.operationId
        )
        XCTAssertEqual(stillPendingB, [outbox[1], queuedB])
        XCTAssertNil(stillHiddenB)
        let receiptB = try decodedCreateReceipt([
            "plant_id": otherSyncOwner.uuidString, "paid_action": NSNull(),
            "context_state": "needs_review", "plan_availability": "unavailable"
        ])
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receiptB, context: currentB, authority: api.syncAuthority
        )
        for inspected in [store, LocalStore(modelContainer: try diskContainer(url))] {
            for (owner, expected) in [(syncOwner, receiptA), (otherSyncOwner, receiptB)] {
                let value = try await inspected.catalogueCreateConfirmation(
                    ownerId: owner, operationId: command.operationId
                )
                let saved = try XCTUnwrap(value)
                XCTAssertEqual(saved.ownerId, owner)
                XCTAssertEqual(saved.operationId, command.operationId)
                XCTAssertEqual(saved.receipt, expected)
                XCTAssertTrue(saved.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8))
            }
        }
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receiptB, context: currentB, authority: api.syncAuthority
        )
        do {
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receiptA, context: currentB, authority: api.syncAuthority
            )
            XCTFail("B replay cannot replace its receipt with A's receipt")
        } catch CatalogueCreateAcknowledgementError.confirmationConflict {}
        await api.bindSyncSession(syncSession)
        let currentA = try await api.captureSyncContext(ownerId: syncOwner)
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receiptA, context: currentA, authority: api.syncAuthority
        )
        try await assertSeedUnchanged(url, outbox: outbox)
    }

    @MainActor
    func testCreateAcknowledgementRejectsStaleABALeaseAnonymousContextAndCancellation() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let command = createCommand()
        let create = try await queueCreate(command, ownerId: syncOwner, in: store)
        let receipt = try decodedCreateReceipt()
        let api = client(CatalogueTransport([]))
        await api.bindSyncSession(syncSession)
        let stale = try await api.captureSyncContext(ownerId: syncOwner)
        await api.bindSyncSession(NativeAuthSession(
            userId: otherSyncOwner, accessToken: "owner-b-token", expiresAt: .distantFuture
        ))
        await api.bindSyncSession(syncSession)
        do {
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: stale, authority: api.syncAuthority
            )
            XCTFail("Returning to A must not revive a captured lease")
        } catch SyncWireValidationError.invalidSession {}
        try await assertCreateStillPending(url, store: store, outbox: outbox, create: create)

        let anonymousAPI = client(CatalogueTransport([]))
        let anonymous = try await anonymousAPI.captureSyncContext(ownerId: syncOwner)
        do {
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: anonymous, authority: anonymousAPI.syncAuthority
            )
            XCTFail("Legacy anonymous sync context must not authorize create confirmation")
        } catch SyncWireValidationError.invalidSession {}
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        // Inherits MainActor: cancel before yielding so the store receives a cancelled task.
        let cancelled = Task {
            try await store.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: lease, authority: api.syncAuthority
            )
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("A cancelled acknowledgement must not publish")
        } catch is CancellationError {}
        try await assertCreateStillPending(url, store: store, outbox: outbox, create: create)
        // The unchanged original operation remains retryable with a current lease.
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receipt, context: lease, authority: api.syncAuthority
        )
        try await assertSeedUnchanged(url, outbox: outbox)
    }

    @MainActor
    func testCreateAcknowledgementReadOnlySQLiteSaveRetainsQueueAndReceiptThenRetries() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outbox = try await seedSyncDisk(url)
        let command = createCommand()
        let receipt = try decodedCreateReceipt(["paid_action": NSNull()])
        let create: OutboxEntrySnapshot
        do {
            let writable = LocalStore(modelContainer: try diskContainer(url))
            create = try await queueCreate(command, ownerId: syncOwner, in: writable)
        }
        let api = client(CatalogueTransport([]))
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        do {
            let store = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
            try await assertCreateStillPending(url, store: store, outbox: outbox, create: create)
            for _ in 0..<2 {
                do {
                    try await store.acknowledgeCatalogueCreate(
                        command, receipt: receipt, context: lease, authority: api.syncAuthority
                    )
                    XCTFail("Read-only SQLite must reject the atomic save")
                } catch {
                    let failure = error as NSError
                    XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                    XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
                }
                // Check this actor and a separate disk container after each actual failed save.
                try await assertCreateStillPending(url, store: store, outbox: outbox, create: create)
            }
        }
        do {
            let retry = LocalStore(modelContainer: try diskContainer(url))
            try await retry.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: lease, authority: api.syncAuthority
            )
            try await retry.acknowledgeCatalogueCreate(
                command, receipt: receipt, context: lease, authority: api.syncAuthority
            )
            let saved = try await retry.catalogueCreateConfirmation(
                ownerId: syncOwner, operationId: command.operationId
            )
            XCTAssertEqual(saved?.receipt, receipt)
        }
        let reopened = LocalStore(modelContainer: try diskContainer(url))
        let saved = try await reopened.catalogueCreateConfirmation(
            ownerId: syncOwner, operationId: command.operationId
        )
        XCTAssertEqual(saved?.receipt, receipt)
        XCTAssertNil(saved?.receipt.paidAction)
        XCTAssertEqual(saved?.receipt.watermarkRaw, timestamp)
        XCTAssertTrue(saved?.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8) == true)
        try await assertSeedUnchanged(url, outbox: outbox)
    }

    @MainActor
    func testCreateConfirmationSchemaPreservesHistoricalDiskQueueAndCache() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let oldDate = SQLTimestamp.date(from: "2026-11-03T08:00:00Z")!
        let historical = SyncItemDTO(
            entityType: "room", id: serverPlantId, updatedAt: oldDate,
            payloadJSON: #"{"name":"historical","unknown":{"kept":true}}"#
        )
        let queued: OutboxEntrySnapshot
        do {
            // The pre-confirmation production schema, on a real SQLite file.
            let schema = Schema([
                LocalOutboxRecord.self, GuestDraftCacheRecord.self,
                SyncedEntityRecord.self, SyncCheckpointRecord.self
            ])
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url)
            ])
            let oldStore = LocalStore(modelContainer: container)
            queued = try await queueCreate(command, ownerId: syncOwner, in: oldStore)
            try await oldStore.applySyncedItems([historical], ownerId: syncOwner)
            try await oldStore.updateWatermark(ownerId: syncOwner, watermark: oldDate)
        }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let pending = try await store.pendingOutboxEntries(for: syncOwner)
        let before = try await store.catalogueCreateConfirmation(
            ownerId: syncOwner, operationId: command.operationId
        )
        XCTAssertEqual(pending, [queued])
        XCTAssertNil(before)
        let api = client(CatalogueTransport([]))
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        let receipt = try decodedCreateReceipt()
        try await store.acknowledgeCatalogueCreate(
            command, receipt: receipt, context: lease, authority: api.syncAuthority
        )
        let container = try diskContainer(url)
        let reopened = LocalStore(modelContainer: container)
        let retained = try await reopened.activeSyncedEntities(ownerId: syncOwner, entityType: "room")
        let date = try await reopened.currentWatermark(ownerId: syncOwner)
        let raw = try await reopened.currentWatermarkRaw(ownerId: syncOwner)
        let after = try await reopened.pendingOutboxEntries(for: syncOwner)
        let saved = try await reopened.catalogueCreateConfirmation(
            ownerId: syncOwner, operationId: command.operationId
        )
        let checkpoint = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<SyncCheckpointRecord>()).first)
        XCTAssertEqual(retained, [historical])
        XCTAssertEqual(date, oldDate)
        XCTAssertEqual(raw, "2026-11-03T08:00:00.000Z")
        XCTAssertNil(checkpoint.watermarkRaw)
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(saved?.receipt, receipt)
        XCTAssertTrue(saved?.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8) == true)
    }
}

/// A fixture ledger commits before optionally losing its response. No live SQL/server.
private actor CommittingCatalogueTransport: PlantsAPITransport {
    private let receiptJSON: String
    private var loseResponse: Bool
    private var bodies: [UUID: Data] = [:]
    private var requests: [URLRequest] = []

    init(_ receiptJSON: String, loseResponse: Bool = false) {
        self.receiptJSON = receiptJSON
        self.loseResponse = loseResponse
    }

    func capturedRequests() -> [URLRequest] { requests }
    func committedCount() -> Int { bodies.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let body = request.httpBody else { throw URLError(.badServerResponse) }
        let command = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: body)
        guard request.httpMethod == "POST", command.commandName == "plant.create",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer sync-session-token",
              request.value(forHTTPHeaderField: "X-Operation-Id") == command.operationId.uuidString.lowercased()
        else { throw URLError(.badServerResponse) }
        if let prior = bodies[command.operationId] {
            guard prior == body else { throw URLError(.badServerResponse) }
        } else {
            bodies[command.operationId] = body
        }
        if loseResponse {
            loseResponse = false
            throw URLError(.networkConnectionLost)
        }
        return (Data(receiptJSON.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension CollectionWireTests {
    /// Retain the seeded checkpoint/cache and B queue; A starts with only this create.
    @MainActor
    private func seedEngineCreate(
        _ url: URL, command: CommandEnvelopeDTO
    ) async throws -> (create: OutboxEntrySnapshot, other: OutboxEntrySnapshot) {
        let seeded = try await seedSyncDisk(url)
        let store = LocalStore(modelContainer: try diskContainer(url))
        try await store.markOutboxCommitted(operationId: seeded[0].operationId)
        let create = try await queueCreate(command, ownerId: syncOwner, in: store)
        return (create, seeded[1])
    }

    @MainActor
    private func assertEngineCreateState(
        _ url: URL, store: LocalStore, command: CommandEnvelopeDTO,
        pending: [OutboxEntrySnapshot], other: OutboxEntrySnapshot,
        receipt: PlantCreateReceiptDTO? = nil
    ) async throws {
        let container = try diskContainer(url)
        let expectedProfile = try JSONDecoder().decode(
            SyncWireProfileDTO.self,
            from: JSONSerialization.data(withJSONObject: syncObject()["profile"]!)
        )
        let expectedRights = try JSONDecoder().decode(
            SyncWireEntitlementDTO.self,
            from: JSONSerialization.data(withJSONObject: paidSyncEntitlement())
        )
        for inspected in [store, LocalStore(modelContainer: container)] {
            let pendingA = try await inspected.pendingOutboxEntries(for: syncOwner)
            let pendingB = try await inspected.pendingOutboxEntries(for: otherSyncOwner)
            let confirmation = try await inspected.catalogueCreateConfirmation(
                ownerId: syncOwner, operationId: command.operationId
            )
            let hidden = try await inspected.catalogueCreateConfirmation(
                ownerId: otherSyncOwner, operationId: command.operationId
            )
            XCTAssertEqual(pendingA, pending)
            XCTAssertEqual(pendingB, [other])
            XCTAssertNil(hidden)
            XCTAssertEqual(confirmation?.receipt, receipt)
            if receipt != nil {
                XCTAssertEqual(confirmation?.ownerId, syncOwner)
                XCTAssertEqual(confirmation?.operationId, command.operationId)
                XCTAssertTrue(confirmation?.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8) == true)
            } else {
                XCTAssertNil(confirmation)
            }
            let raw = try await inspected.currentWatermarkRaw(ownerId: syncOwner)
            let date = try await inspected.currentWatermark(ownerId: syncOwner)
            let profile = try await inspected.syncedProfile(ownerId: syncOwner)
            let rights = try await inspected.syncedEntitlement(ownerId: syncOwner)
            XCTAssertEqual(raw, syncSince)
            XCTAssertEqual(date, SQLTimestamp.date(from: syncSince))
            XCTAssertEqual(profile, expectedProfile)
            XCTAssertEqual(rights, expectedRights)
            for owner in [syncOwner, otherSyncOwner] {
                let cached = try await inspected.activeSyncedEntities(ownerId: owner, entityType: "plants")
                XCTAssertEqual(cached, [
                    SyncItemDTO(entityType: "plants", id: serverPlantId,
                                updatedAt: SQLTimestamp.date(from: syncSince)!,
                                payloadJSON: #"{"name":"confirmed"}"#)
                ])
            }
        }
        let confirmations = try ModelContext(container).fetch(FetchDescriptor<CatalogueCreateConfirmationRecord>())
        XCTAssertEqual(confirmations.count, receipt == nil ? 0 : 1)
    }

    private func assertCreateRequests(
        _ requests: [URLRequest], command: CommandEnvelopeDTO, count: Int
    ) throws {
        XCTAssertEqual(requests.count, count)
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sync-session-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Operation-Id"), command.operationId.uuidString.lowercased())
            let body = try XCTUnwrap(request.httpBody)
            let sent = try JSONDecoder().decode(CommandEnvelopeDTO.self, from: body)
            XCTAssertEqual(sent, command)
            XCTAssertTrue(sent.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8))
            XCTAssertEqual(body, requests.first?.httpBody)
        }
    }

    @MainActor
    func testEngineCreatePersistsAuthoritativeReceiptAndOriginalPayloadOnDisk() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let transport = CatalogueTransport([.http(200, receiptJSON())])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let store = LocalStore(modelContainer: try diskContainer(url))
        // Prime committed reads before the isolated ACK replaces the queue.
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [seeded.create], other: seeded.other
        )
        let engine = SyncEngine(store: store, apiClient: api)
        let committed = try await engine.flushOutbox(for: syncOwner)
        let next = try await engine.flushOutbox(for: syncOwner)
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(next, 0)
        let receipt = try decodedCreateReceipt()
        XCTAssertEqual(receipt.watermarkRaw, timestamp)
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [], other: seeded.other, receipt: receipt
        )
        let requests = await transport.capturedRequests()
        try assertCreateRequests(requests, command: command, count: 1)
    }

    @MainActor
    func testEngineCreateLostCommittedResponseReopensAndRetriesSameServerOperation() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let transport = CommittingCatalogueTransport(receiptJSON(), loseResponse: true)
        do {
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let store = LocalStore(modelContainer: try diskContainer(url))
            let count = try await SyncEngine(store: store, apiClient: api).flushOutbox(for: syncOwner)
            XCTAssertEqual(count, 0)
            let pending = try await store.pendingOutboxEntries(for: syncOwner)
            let failed = try XCTUnwrap(pending.first)
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(failed.operationId, command.operationId)
            XCTAssertTrue(failed.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8))
            XCTAssertEqual(failed.sequenceNumber, seeded.create.sequenceNumber)
            XCTAssertEqual(failed.createdAt, seeded.create.createdAt)
            XCTAssertEqual(failed.retryCount, 1)
            XCTAssertNotNil(failed.lastError)
            try await assertEngineCreateState(
                url, store: store, command: command, pending: [failed], other: seeded.other
            )
        }
        let serverCommitsBeforeRetry = await transport.committedCount()
        XCTAssertEqual(serverCommitsBeforeRetry, 1)
        // Recreate API, engine, actor and disk container after the lost response.
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let engine = SyncEngine(store: store, apiClient: api)
        let count = try await engine.flushOutbox(for: syncOwner)
        let next = try await engine.flushOutbox(for: syncOwner)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(next, 0)
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [], other: seeded.other,
            receipt: decodedCreateReceipt()
        )
        let requests = await transport.capturedRequests()
        let serverCommits = await transport.committedCount()
        try assertCreateRequests(requests, command: command, count: 2)
        XCTAssertEqual(serverCommits, 1)
    }

    @MainActor
    func testEngineCreateInvalid200CapAuthAndTransportErrorsNeverConfirmOrChangeCommand() async throws {
        func errorJSON(_ code: String, retryable: Bool = false) -> String {
            """
            {"error":{"code":"\(code)","message":"Fixture error","retryable":\(retryable)}}
            """
        }
        let failures: [(CatalogueTransport.Reply, String?)] = [
            (.http(200, "{}"), nil), (.http(200, "null"), nil),
            (.http(201, receiptJSON()), nil), (.http(202, receiptJSON()), nil),
            (.http(200, #"{"status":"committed","operation_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","replayed":false}"#), nil),
            (.http(409, errorJSON("COLLECTION_LIMIT_REACHED")), "COLLECTION_LIMIT_REACHED"),
            (.http(401, errorJSON("UNAUTHORIZED")), "UNAUTHORIZED"),
            (.http(403, errorJSON("FORBIDDEN")), "FORBIDDEN"),
            (.http(503, errorJSON("INTERNAL_ERROR", retryable: true)), "INTERNAL_ERROR"),
            (.network, nil)
        ]
        for (reply, code) in failures {
            let url = try diskURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let command = createCommand()
            let seeded = try await seedEngineCreate(url, command: command)
            let laterCommand = createCommand()
            let transport = CatalogueTransport([reply, reply])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let original = LocalStore(modelContainer: try diskContainer(url))
            let later = try await queueCreate(laterCommand, ownerId: syncOwner, in: original)
            for attempt in 1...2 {
                let store = attempt == 1 ? original : LocalStore(modelContainer: try diskContainer(url))
                let count = try await SyncEngine(store: store, apiClient: api).flushOutbox(for: syncOwner)
                XCTAssertEqual(count, 0)
                let entries = try await store.pendingOutboxEntries(for: syncOwner)
                let failed = try XCTUnwrap(entries.first)
                XCTAssertEqual(failed.operationId, seeded.create.operationId)
                XCTAssertEqual(failed.ownerId, seeded.create.ownerId)
                XCTAssertEqual(failed.plantId, seeded.create.plantId)
                XCTAssertEqual(failed.commandName, seeded.create.commandName)
                XCTAssertTrue(failed.payloadJSON.utf8.elementsEqual(command.payloadJSON.utf8))
                XCTAssertEqual(failed.createdAt, seeded.create.createdAt)
                XCTAssertEqual(failed.sequenceNumber, seeded.create.sequenceNumber)
                XCTAssertEqual(failed.retryCount, attempt)
                let message = try XCTUnwrap(failed.lastError)
                if let code { XCTAssertTrue(message.contains(code)) }
                try await assertEngineCreateState(
                    url, store: original, command: command, pending: [failed, later], other: seeded.other
                )
            }
            let requests = await transport.capturedRequests()
            try assertCreateRequests(requests, command: command, count: 2)
        }
    }

    @MainActor
    func testEngineCreateOwnerSwitchABAAndCancellationCannotAcknowledgeOrSendNextCommand() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let later = try await queueCreate(createCommand(), ownerId: syncOwner, in: store)
        for mode in 0..<3 {
            let transport = SuspendedCollectionTransport(receiptJSON())
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            let engine = SyncEngine(store: store, apiClient: api)
            let owner = syncOwner
            let operation = Task { try await engine.flushOutbox(for: owner) }
            await transport.waitForRequest()
            if mode == 2 {
                operation.cancel()
            } else {
                await api.bindSyncSession(NativeAuthSession(
                    userId: otherSyncOwner, accessToken: "owner-b-token", expiresAt: .distantFuture
                ))
                do {
                    _ = try await engine.flushOutbox(for: syncOwner)
                    XCTFail("A must not be dispatched with B's token")
                } catch SyncWireValidationError.invalidSession {}
                if mode == 1 { await api.bindSyncSession(syncSession) }
            }
            await transport.resume()
            do {
                _ = try await operation.value
                XCTFail("Stale/cancelled typed response must not acknowledge")
            } catch is CancellationError {
                XCTAssertEqual(mode, 2)
            } catch SyncWireValidationError.invalidSession {
                XCTAssertNotEqual(mode, 2)
            }
            try await assertEngineCreateState(
                url, store: store, command: command, pending: [seeded.create, later], other: seeded.other
            )
            let requests = await transport.capturedRequests()
            try assertCreateRequests(requests, command: command, count: 1)
        }
    }

    @MainActor
    func testEngineCreateReadOnlyAcknowledgementDoesNotRecordSendFailureAndWritableRetryCommits() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let transport = CommittingCatalogueTransport(receiptJSON())
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        do {
            let store = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
            let engine = SyncEngine(store: store, apiClient: api)
            try await assertEngineCreateState(
                url, store: store, command: command, pending: [seeded.create], other: seeded.other
            )
            for _ in 0..<2 {
                do {
                    _ = try await engine.flushOutbox(for: syncOwner)
                    XCTFail("Actual read-only SQLite ACK must fail")
                } catch {
                    let failure = error as NSError
                    XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                    XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
                }
                try await assertEngineCreateState(
                    url, store: store, command: command, pending: [seeded.create], other: seeded.other
                )
            }
        }
        let store = LocalStore(modelContainer: try diskContainer(url))
        let engine = SyncEngine(store: store, apiClient: api)
        let count = try await engine.flushOutbox(for: syncOwner)
        let next = try await engine.flushOutbox(for: syncOwner)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(next, 0)
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [], other: seeded.other,
            receipt: decodedCreateReceipt()
        )
        let requests = await transport.capturedRequests()
        let serverCommits = await transport.committedCount()
        try assertCreateRequests(requests, command: command, count: 3)
        XCTAssertEqual(serverCommits, 1)
    }

    @MainActor
    func testEngineCreateReadOnlyFailureBookkeepingAndLegacyWritesLeaveNoCachedMutations() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let transport = CatalogueTransport([.network, .network])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let store = LocalStore(modelContainer: try diskContainer(url, allowsSave: false))
        let engine = SyncEngine(store: store, apiClient: api)
        for mode in 0..<5 {
            do {
                switch mode {
                case 0, 1:
                    _ = try await engine.flushOutbox(for: syncOwner)
                case 2:
                    try await store.recordOutboxFailure(operationId: command.operationId, errorMessage: "unsaved")
                case 3:
                    try await store.markOutboxCommitted(operationId: command.operationId)
                default:
                    _ = try await queueCreate(createCommand(), ownerId: syncOwner, in: store)
                }
                XCTFail("Read-only SQLite outbox mutation must fail")
            } catch {
                let failure = error as NSError
                XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
            }
            try await assertEngineCreateState(
                url, store: store, command: command, pending: [seeded.create], other: seeded.other
            )
        }
        let requests = await transport.capturedRequests()
        try assertCreateRequests(requests, command: command, count: 2)
        let retryAPI = client(CatalogueTransport([.http(200, receiptJSON())]))
        await retryAPI.bindSyncSession(syncSession)
        let writable = LocalStore(modelContainer: try diskContainer(url))
        let count = try await SyncEngine(store: writable, apiClient: retryAPI).flushOutbox(for: syncOwner)
        XCTAssertEqual(count, 1)
        try await assertEngineCreateState(
            url, store: writable, command: command, pending: [], other: seeded.other,
            receipt: decodedCreateReceipt()
        )
    }

    @MainActor
    func testEngineCreateConcurrentDuplicateFlushDispatchesOnceAndCountsOneDurableCommit() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let transport = SuspendedCollectionTransport(receiptJSON())
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let engine = SyncEngine(store: store, apiClient: api)
        let owner = syncOwner
        let first = Task { try await engine.flushOutbox(for: owner) }
        await transport.waitForRequest()
        let overlapping = try await engine.flushOutbox(for: owner)
        XCTAssertEqual(overlapping, 0)
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [seeded.create], other: seeded.other
        )
        await transport.resume()
        let committed = try await first.value
        let next = try await engine.flushOutbox(for: owner)
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(next, 0)
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [], other: seeded.other,
            receipt: decodedCreateReceipt()
        )
        let requests = await transport.capturedRequests()
        try assertCreateRequests(requests, command: command, count: 1)
    }

    @MainActor
    func testCanonicalCreateRejectsGenericSuccessButPersistsValidationFailureMetadata() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let store = LocalStore(modelContainer: try diskContainer(url))
        let transport = CatalogueTransport([.http(200, receiptJSON())])
        let api = client(transport)
        await api.bindSyncSession(syncSession)
        let lease = try await api.captureSyncContext(ownerId: syncOwner)
        do {
            try await store.finishOutboxEntry(
                operationId: command.operationId, context: lease, authority: api.syncAuthority
            )
            XCTFail("Canonical plant.create requires durable receipt acknowledgement")
        } catch CatalogueCreateAcknowledgementError.invalidCommand {}
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [seeded.create], other: seeded.other
        )
        let engine = SyncEngine(store: store, apiClient: api)
        let committed = try await engine.flushOutbox(for: syncOwner)
        XCTAssertEqual(committed, 1)
        let invalid = createCommand()
        let invalidCommand = CommandEnvelopeDTO(
            operationId: invalid.operationId, commandName: "plant.create",
            payloadJSON: #"{"creation_source":"catalogue","plant_id":"fixture_collection_cap","owner_id":"injected"}"#
        )
        let queued = try await queueCreate(invalidCommand, ownerId: syncOwner, in: store)
        let failedCount = try await engine.flushOutbox(for: syncOwner)
        XCTAssertEqual(failedCount, 0)
        let pending = try await store.pendingOutboxEntries(for: syncOwner)
        let failed = try XCTUnwrap(pending.first)
        XCTAssertEqual(failed.operationId, queued.operationId)
        XCTAssertEqual(failed.sequenceNumber, queued.sequenceNumber)
        XCTAssertEqual(failed.createdAt, queued.createdAt)
        XCTAssertTrue(failed.payloadJSON.utf8.elementsEqual(invalidCommand.payloadJSON.utf8))
        XCTAssertEqual(failed.retryCount, 1)
        XCTAssertTrue(try XCTUnwrap(failed.lastError).contains("invalidPayload"))
        let invalidConfirmation = try await store.catalogueCreateConfirmation(
            ownerId: syncOwner, operationId: invalidCommand.operationId
        )
        XCTAssertNil(invalidConfirmation)
        try await assertEngineCreateState(
            url, store: store, command: command, pending: [failed], other: seeded.other,
            receipt: decodedCreateReceipt()
        )
        let requests = await transport.capturedRequests()
        try assertCreateRequests(requests, command: command, count: 1)
    }

    @MainActor
    func testEngineCreateTransportCancellationNeverBecomesRetryMetadata() async throws {
        let url = try diskURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let command = createCommand()
        let seeded = try await seedEngineCreate(url, command: command)
        let store = LocalStore(modelContainer: try diskContainer(url))
        for reply in [CatalogueTransport.Reply.cancelled, .urlCancelled] {
            let transport = CatalogueTransport([reply])
            let api = client(transport)
            await api.bindSyncSession(syncSession)
            do {
                _ = try await SyncEngine(store: store, apiClient: api).flushOutbox(for: syncOwner)
                XCTFail("Transport cancellation must propagate")
            } catch is CancellationError {
            } catch let error as URLError {
                XCTAssertEqual(error.code, .cancelled)
            }
            try await assertEngineCreateState(
                url, store: store, command: command, pending: [seeded.create], other: seeded.other
            )
            let requests = await transport.capturedRequests()
            try assertCreateRequests(requests, command: command, count: 1)
        }
    }
}

extension CollectionWireTests {
    private func diagnosisTicket(url: String, photoId: UUID) -> String {
        #"{"photo_asset_id":"\#(photoId.uuidString)","storage_bucket":"photos","storage_path":"test.jpg","signed_upload_url":"\#(url)","expires_in_seconds":60,"max_byte_size":10485760}"#
    }

    private func diagnosisJob(id: UUID, status: String, result: String = "null", errorCode: String = "null") -> String {
        #"{"job_id":"\#(id.uuidString)","mode":"diagnosis","status":"\#(status)","quota_kind":"free_monthly","quota_state":"reserved","result":\#(result),"error_code":\#(errorCode),"error_message":null}"#
    }

    func testDiagnosisUploadAndReplaySendCanonicalWireWithBoundToken() async throws {
        let photo = serverPlantId
        let uploadOperationId = UUID()
        let upload = "https://example.invalid/functions/v1/plants-api/media/uploads/\(photo.uuidString.lowercased())?token=mock"
        let ready = #"{"photo_asset_id":"\#(photo.uuidString)","state":"ready"}"#
        let queued = diagnosisJob(id: operationId, status: "queued")
        let transport = CatalogueTransport([
            .http(200, diagnosisTicket(url: upload, photoId: photo)), .http(200, ready),
            .http(200, ready), .http(202, queued), .http(200, queued),
        ])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let context = try await api.captureSyncContext(ownerId: accessOwner)
        let bytes = Data("abc".utf8)
        let ticket = try await api.issueAnalysisUpload(jpeg: bytes, operationId: uploadOperationId, locale: .en, context: context)
        try await api.uploadAnalysisJPEG(bytes, ticket: ticket, locale: .en, context: context)
        try await api.confirmAnalysisPhoto(id: photo, locale: .en, context: context)
        let created = try await api.createAnalysisJob(operationId: operationId, mode: .diagnosis, photoAssetId: photo, locale: .en, context: context)
        let replay = try await api.createAnalysisJob(operationId: operationId, mode: .diagnosis, photoAssetId: photo, locale: .en, context: context)
        XCTAssertEqual(created.jobId, replay.jobId)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "POST", "POST", "POST"])
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(accessSession.accessToken)"
                && $0.value(forHTTPHeaderField: "X-Client-Locale") == "en"
                && $0.value(forHTTPHeaderField: "X-Installation-Credential") == nil
        })
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(body["content_sha256"] as? String, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(body["byte_size"] as? Int, bytes.count)
        XCTAssertEqual(body["operation_id"] as? String, uploadOperationId.uuidString.lowercased())
        XCTAssertEqual(body["mime_type"] as? String, "image/jpeg")
        XCTAssertEqual(requests[1].url?.absoluteString, upload)
        XCTAssertEqual(requests[1].httpBody, bytes)
        let nonRedirectingRequests = await transport.nonRedirectingRequests
        XCTAssertEqual(nonRedirectingRequests, 1)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(requests[2].url?.lastPathComponent, "complete")
        let jobBody = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[3].httpBody))
        XCTAssertEqual(jobBody, ["operation_id": operationId.uuidString.lowercased(), "mode": "diagnosis",
                                 "photo_asset_id": photo.uuidString.lowercased()])
        let replayBody = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[4].httpBody))
        XCTAssertEqual(jobBody, replayBody)
        XCTAssertEqual(requests[3].httpBody, requests[4].httpBody)
    }

    func testDiagnosisRejectsSignedUploadOutsideExactAssetPath() async throws {
        let suffix = "/functions/v1/plants-api/media/uploads/\(serverPlantId.uuidString.lowercased())"
        let urls = [
            "https://another.invalid\(suffix)", "http://example.invalid\(suffix)",
            "https://example.invalid:444\(suffix)", "https://user@example.invalid\(suffix)",
            "https://example.invalid/functions/v1/plants-api/%2e%2e/media/uploads/\(serverPlantId.uuidString)",
            "https://example.invalid\(suffix)/extra", "https://example.invalid\(suffix)#fragment",
        ]
        for url in urls {
            let transport = CatalogueTransport([.http(200, diagnosisTicket(url: url, photoId: serverPlantId))])
            let api = client(transport)
            await api.bindSyncSession(accessSession)
            let context = try await api.captureSyncContext(ownerId: accessOwner)
            do {
                _ = try await api.issueAnalysisUpload(jpeg: Data([1]), operationId: operationId, locale: .en, context: context)
                XCTFail("Unsafe ticket was accepted")
            } catch AnalysisHTTPError.invalidUpload {}
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["POST"])
        }
    }

    func testDiagnosisMalformedTicketCannotProceedToUpload() async throws {
        let path = "https://example.invalid/functions/v1/plants-api/media/uploads/\(serverPlantId.uuidString.lowercased())"
        let valid = Data(diagnosisTicket(url: path, photoId: serverPlantId).utf8)
        let original = try XCTUnwrap(try JSONSerialization.jsonObject(with: valid) as? [String: Any])
        for (key, wrongValue) in [("storage_bucket", nil), ("storage_path", 1)] as [(String, Int?)] {
            var malformed = original
            if let wrongValue {
                malformed[key] = wrongValue
            } else {
                malformed.removeValue(forKey: key)
            }
            let json = try syncJSON(malformed)
            let transport = CatalogueTransport([.http(200, json)])
            let api = client(transport)
            await api.bindSyncSession(accessSession)
            let context = try await api.captureSyncContext(ownerId: accessOwner)
            do {
                _ = try await api.issueAnalysisUpload(jpeg: Data([1]), operationId: operationId, locale: .en, context: context)
                XCTFail("Malformed storage metadata was accepted")
            } catch is DecodingError {}
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["POST"])
        }
    }

    func testDiagnosisStatusUnknownFailureAndWrongJobRemainDistinct() async throws {
        let id = operationId
        let result = #"{"analysis_id":"\#(serverPlantId.uuidString)","job_id":"\#(id.uuidString)","kb_release_id":"\#(serverPlantId.uuidString)","mode":"diagnosis","identification_status":"unknown","plant_id":null,"genus_id":null,"diagnosis_status":"insufficient_data","selected_condition_id":null,"candidates":[],"visual_markers":[],"evidence_basis":[],"limitations":["Photo too unclear."],"first_action_summary":null,"control_interval_days":null,"plan_availability":"diagnosis_unresolved","analysis_receipt":"test-receipt"}"#
        let malformedCandidateResult = result.replacingOccurrences(
            of: #""candidates":[]"#,
            with: #""candidates":[{"condition_id":"test","rank":3,"confidence":0.5}]"#
        )
        let outOfRangeConfidence = result.replacingOccurrences(
            of: #""candidates":[]"#,
            with: #""candidates":[{"condition_id":"test","rank":1,"confidence":2}]"#
        )
        let transport = CatalogueTransport([
            .http(200, diagnosisJob(id: id, status: "succeeded", result: result)),
            .http(200, diagnosisJob(id: id, status: "failed", errorCode: #""PROVIDER_UNAVAILABLE""#)),
            .http(200, diagnosisJob(id: serverPlantId, status: "running")),
            .http(200, diagnosisJob(id: id, status: "succeeded")),
            .http(200, diagnosisJob(id: id, status: "succeeded", result: malformedCandidateResult)),
            .http(200, diagnosisJob(id: id, status: "succeeded", result: outOfRangeConfidence)),
        ])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let context = try await api.captureSyncContext(ownerId: accessOwner)
        let succeeded = try await api.fetchAnalysisJob(id: id, mode: .diagnosis, locale: .en, context: context)
        XCTAssertEqual(succeeded.result?.domainValue.identificationStatus, .unknown)
        XCTAssertEqual(succeeded.result?.domainValue.diagnosisStatus, .unknown)
        XCTAssertEqual(succeeded.result?.limitations, ["Photo too unclear."])
        let failed = try await api.fetchAnalysisJob(id: id, mode: .diagnosis, locale: .en, context: context)
        XCTAssertNil(failed.result)
        XCTAssertEqual(failed.errorCode, "PROVIDER_UNAVAILABLE")
        for _ in 0..<4 {
            do {
                _ = try await api.fetchAnalysisJob(id: id, mode: .diagnosis, locale: .en, context: context)
                XCTFail("Invalid job response was accepted")
            } catch AnalysisHTTPError.invalidResponse {}
        }
        await api.bindSyncSession(nil)
        do {
            _ = try await api.fetchAnalysisJob(id: id, mode: .diagnosis, locale: .en, context: context)
            XCTFail("Stale request dispatched")
        } catch SyncWireValidationError.invalidSession {}
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.lastPathComponent == id.uuidString.lowercased() })
    }
}

extension CollectionWireTests {
    func testDiagnosisDropsStatusFromInvalidatedBoundSession() async throws {
        let id = operationId
        let transport = SuspendedCollectionTransport(diagnosisJob(id: id, status: "running"))
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let context = try await api.captureSyncContext(ownerId: accessOwner)
        let pending = Task { try await api.fetchAnalysisJob(id: id, mode: .diagnosis, locale: .en, context: context) }
        await transport.waitForRequest()
        await api.bindSyncSession(nil)
        await api.bindSyncSession(accessSession)
        await transport.resume()
        do {
            _ = try await pending.value
            XCTFail("Stale response crossed the session boundary")
        } catch SyncWireValidationError.invalidSession {}
    }
}

#if DEBUG && targetEnvironment(simulator)
extension CollectionWireTests {
    @MainActor
    func testStagingResumeLoadsExactCardWithoutCatalogueSelection() async throws {
        let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .free2)
        defer { try? h.cleanup() }
        let expected = try await h.connection.sessionSnapshot()
        let flow = UUID()
        let model = try await h.connection.makeModel(
            input: CatalogueInput(speciesSlug: "fixture-fern", personalName: "Diagnosis plant"),
            flowId: flow, operationId: UUID(), expected: expected
        )
        _ = try await h.connection.rememberModel(model, expected: expected)
        await model.save()
        guard case let .saved(saved) = model.state else {
            return XCTFail("Expected durable save")
        }
        let result = await h.connection.restoreModel(
            ownerId: expected.session.userId, flowId: flow, expected: expected
        )
        guard case let .restored(restored) = result else {
            return XCTFail("Expected exact restored flow")
        }
        let selection = try XCTUnwrap(CatalogueResumeSelection(restored))
        let firstCataloguePage: [String] = []
        XCTAssertFalse(firstCataloguePage.contains(selection.speciesSlug))
        XCTAssertEqual(selection.flowId, flow)
        XCTAssertEqual(selection.speciesSlug, "fixture-fern")
        await restored.loadCard()
        XCTAssertEqual(restored.cardSummary?.id, saved.receipt.plantId)
        XCTAssertEqual(restored.cardSummary?.personalName, "Diagnosis plant")
        XCTAssertEqual(h.server.snapshot.commits.count, 1)
        XCTAssertEqual(h.server.snapshot.attempts.count, 1)
    }

    @MainActor
    func testAnalysisLimitDisallowsNewCheckpointAndRetriesFrozenSave() async throws {
        let h = try await CatalogueUIFixtures.make(namespace: UUID().uuidString, scenario: .cap3)
        defer { try? h.cleanup() }
        let expected = try await h.connection.sessionSnapshot()
        let analysisFlow = UUID()
        let model = try await h.connection.makeModel(
            input: CatalogueInput(speciesSlug: "fixture-fern", personalName: "Original"),
            flowId: analysisFlow, operationId: UUID(), expected: expected
        )
        _ = try await h.connection.rememberModel(model, expected: expected)
        let envelope = try XCTUnwrap(model.envelope)
        let checkpoint = try XCTUnwrap(model.checkpoint)
        await model.save()
        guard case .collectionLimitNotEnqueued = model.state else {
            return XCTFail("Expected preflight limit")
        }
        XCTAssertFalse(CatalogueSaveIdentity.allowsEditingAsNewSave(analysisFlow: analysisFlow))
        XCTAssertTrue(CatalogueSaveIdentity.allowsEditingAsNewSave(analysisFlow: nil))
        await model.save()
        XCTAssertEqual(model.envelope, envelope)
        XCTAssertEqual(model.checkpoint, checkpoint)
        XCTAssertEqual(model.input?.personalName, "Original")
        XCTAssertTrue(h.server.snapshot.attempts.isEmpty)
    }

    @MainActor
    func testAnalysisSaveRestoresOnlyItsExactDiagnosisFlow() {
        let flow = UUID()
        XCTAssertTrue(CatalogueSaveIdentity.canRestore(
            selectedSpecies: "species", restoredSpecies: "species",
            analysisFlow: flow, restoredFlow: flow
        ))
        XCTAssertFalse(CatalogueSaveIdentity.canRestore(
            selectedSpecies: "species", restoredSpecies: "species",
            analysisFlow: flow, restoredFlow: UUID()
        ))
        XCTAssertFalse(CatalogueSaveIdentity.canRestore(
            selectedSpecies: "species", restoredSpecies: "other",
            analysisFlow: flow, restoredFlow: flow
        ))
        XCTAssertFalse(CatalogueSaveIdentity.canRestore(
            selectedSpecies: "species", restoredSpecies: "species",
            analysisFlow: flow, restoredFlow: nil
        ))
        XCTAssertTrue(CatalogueSaveIdentity.canRestore(
            selectedSpecies: "species", restoredSpecies: "species",
            analysisFlow: nil, restoredFlow: UUID()
        ))
    }

    @MainActor
    func testStagingAnalysisRequiresAnExplicitMatchingHTTPSHost() {
        let flag = ["--narat-staging-analysis"]
        let host = "staging.example.invalid"
        let https = URL(string: "https://\(host)")!
        XCTAssertTrue(StagingAnalysisService.isEnabled(arguments: flag, expectedHost: host, apiOrigin: https))
        XCTAssertFalse(StagingAnalysisService.isEnabled(arguments: [], expectedHost: host, apiOrigin: https))
        XCTAssertFalse(StagingAnalysisService.isEnabled(arguments: flag, expectedHost: nil, apiOrigin: https))
        XCTAssertFalse(StagingAnalysisService.isEnabled(arguments: flag, expectedHost: "other.invalid", apiOrigin: https))
        XCTAssertFalse(StagingAnalysisService.isEnabled(
            arguments: flag, expectedHost: host, apiOrigin: URL(string: "http://\(host)")!
        ))
    }

    @MainActor
    func testStagingAnalysisRecoversLostUploadAndJobRepliesWithDistinctStableOperations() async throws {
        let photo = serverPlantId
        let id = operationId
        let jobId = UUID()
        let url = "https://example.invalid/functions/v1/plants-api/media/uploads/\(photo.uuidString.lowercased())?sig=mock"
        let ready = #"{"photo_asset_id":"\#(photo.uuidString)","state":"ready"}"#
        let result = #"{"analysis_id":"\#(photo.uuidString)","job_id":"\#(jobId.uuidString)","kb_release_id":"\#(photo.uuidString)","mode":"diagnosis","identification_status":"identified","plant_id":"monstera_deliciosa","genus_id":"monstera","diagnosis_status":"problem_detected","selected_condition_id":"root_rot","candidates":[{"condition_id":"root_rot","rank":1,"confidence":0.7}],"visual_markers":[],"evidence_basis":[],"limitations":[],"first_action_summary":null,"control_interval_days":null,"plan_availability":"missing_condition_profile","analysis_receipt":"test-receipt","plant_display_name":"Monstera deliciosa","condition_display_name":"Root rot"}"#
        let transport = CatalogueTransport([
            .network, .http(200, diagnosisTicket(url: url, photoId: photo)),
            .network, .http(200, ready),
            .network, .http(200, diagnosisJob(id: jobId, status: "queued")),
            .http(200, diagnosisJob(id: jobId, status: "succeeded", result: result)
                .replacingOccurrences(of: #""quota_state":"reserved""#, with: #""quota_state":"consumed""#))
        ])
        let api = client(transport)
        await api.bindSyncSession(accessSession)
        let owner = accessOwner
        let service = StagingAnalysisService(api: api) {
            try await api.captureSyncContext(ownerId: owner)
        }
        let input = AnalysisServiceRequest(
            operationId: id, flowId: UUID(), mode: .diagnosis, intent: .problem,
            photo: PreparedAnalysisPhoto(
                cloudNormalizedJPEG: Data([1, 2]), aiVisionJPEG: Data([1, 2]),
                aiWidthPx: 1, aiHeightPx: 1, originalByteCount: 2
            ),
            conditions: CareConditionsInput(), locale: .en
        )
        for _ in 0..<3 {
            do {
                _ = try await service.analyze(input)
                XCTFail("Expected a lost response")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .networkConnectionLost)
            }
        }
        let finished = try await service.analyze(input)
        XCTAssertEqual(finished.speciesLabel, "Monstera deliciosa")
        XCTAssertEqual(finished.conditionLabel, "Root rot")
        XCTAssertEqual(finished.analysis.jobId, jobId)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "PUT", "POST", "POST", "POST", "GET"])
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, [
            "upload-ticket", "upload-ticket", photo.uuidString.lowercased(), "complete",
            "jobs", "jobs", jobId.uuidString.lowercased()
        ])
        guard requests.count == 7 else { return }
        let uploadBody = try XCTUnwrap(requests[0].httpBody)
        let upload = try XCTUnwrap(JSONSerialization.jsonObject(with: uploadBody) as? [String: Any])
        let jobBody = try XCTUnwrap(requests[4].httpBody)
        let job = try JSONDecoder().decode([String: String].self, from: jobBody)
        XCTAssertEqual(upload["operation_id"] as? String, input.uploadOperationId.uuidString.lowercased())
        XCTAssertEqual(job["operation_id"], id.uuidString.lowercased())
        XCTAssertNotEqual(upload["operation_id"] as? String, job["operation_id"])
        XCTAssertEqual(requests[1].httpBody, uploadBody)
        XCTAssertEqual(requests[5].httpBody, jobBody)
    }
}
#endif
