import CryptoKit
import Foundation

struct PlantCareRecommendation: Decodable, Sendable, Equatable {
    struct Source: Decodable, Sendable, Equatable {
        let url: URL
        let locator: String
    }

    let actionId: String
    let actionCode: String
    let text: String
    let nextCheckIntervalDays: Int?
    let source: Source

    enum CodingKeys: String, CodingKey {
        case actionId = "action_id"
        case actionCode = "action_code"
        case text, source
        case nextCheckIntervalDays = "next_check_interval_days"
    }
}

private struct PlantCareRecommendationResponse: Decodable {
    enum Status: String, Decodable { case available, unavailable }

    let plantId: UUID
    let status: Status
    let recommendation: PlantCareRecommendation?

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case status, recommendation
    }

    func validated(for expectedPlantId: UUID) throws -> PlantCareRecommendation? {
        guard plantId == expectedPlantId else { throw AnalysisHTTPError.invalidResponse }
        if status == .unavailable, recommendation == nil { return nil }
        guard status == .available, let recommendation,
              recommendation.actionCode == "check_soil",
              recommendation.nextCheckIntervalDays == nil,
              [recommendation.actionId, recommendation.text, recommendation.source.locator].allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              let url = URLComponents(url: recommendation.source.url, resolvingAgainstBaseURL: false),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else {
            throw AnalysisHTTPError.invalidResponse
        }
        return recommendation
    }
}

enum ManualWateringAction: Sendable, Equatable {
    case record
    case undo(UUID)

    init?(envelope: CommandEnvelopeDTO) {
        guard envelope.plantId != nil,
              envelope.commandName == "care.record" || envelope.commandName == "care.undo",
              let payload = try? JSONSerialization.jsonObject(with: Data(envelope.payloadJSON.utf8)) as? [String: String] else {
            return nil
        }
        if envelope.commandName == "care.record" {
            guard payload.count == 3, payload["action_code"] == "water",
                  let occurredAt = payload["occurred_at"], SQLTimestamp.microseconds(from: occurredAt) != nil,
                  let timezone = payload["timezone"], TimeZone(identifier: timezone) != nil else { return nil }
            self = .record
        } else {
            guard payload.count == 1, let id = payload["entry_id"], let entryId = UUID(uuidString: id) else { return nil }
            self = .undo(entryId)
        }
    }

    func envelope(plantId: UUID, operationId: UUID = UUID(), now: Date = Date(),
                  timezone: TimeZone = .current) throws -> CommandEnvelopeDTO {
        let name: String
        let payload: [String: String]
        switch self {
        case .record:
            name = "care.record"
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = timezone
            payload = ["action_code": "water", "occurred_at": formatter.string(from: now), "timezone": timezone.identifier]
        case let .undo(entryId):
            name = "care.undo"
            payload = ["entry_id": entryId.uuidString.lowercased()]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return CommandEnvelopeDTO(operationId: operationId, commandName: name, plantId: plantId,
                                  payloadJSON: String(decoding: data, as: UTF8.self))
    }
}

private struct ManualWateringReceipt: Decodable {
    let plantId: UUID
    let entryId: UUID
    let reversalId: UUID?
    let state: String
    let watermark: String

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case entryId = "entry_id"
        case reversalId = "reversal_id"
        case state, watermark
    }

    func validate(plantId expectedPlantId: UUID?, action: ManualWateringAction) throws {
        guard plantId == expectedPlantId, SQLTimestamp.microseconds(from: watermark) != nil else {
            throw SyncWireValidationError.invalidPage
        }
        switch action {
        case .record:
            guard state == "active", reversalId == nil else { throw SyncWireValidationError.invalidPage }
        case let .undo(expectedEntryId):
            guard state == "voided", entryId == expectedEntryId, reversalId != nil else {
                throw SyncWireValidationError.invalidPage
            }
        }
    }
}

public struct APIErrorResponse: Codable, Sendable, Equatable, Error {
    public struct ErrorBody: Codable, Sendable, Equatable {
        public let code: String
        public let message: String
        public let retryable: Bool
    }
    public let error: ErrorBody
}

public protocol PlantsAPITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func sendWithoutRedirect(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension PlantsAPITransport {
    public func sendWithoutRedirect(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }
}

public struct URLSessionAPITransport: PlantsAPITransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    public func sendWithoutRedirect(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: AnalysisUploadRedirectDelegate())
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// A captured operation is invalid after *any* auth-context change, including A -> B -> A.
struct SyncSessionLease: Sendable {
    let ownerId: UUID
    let generation: UInt64
    let session: NativeAuthSession?
    fileprivate let authority: SyncSessionAuthority
}

/// The short synchronous critical section also covers LocalStore's save. There is no
/// lock across an await: auth changes and disk publication have one ordering.
final class SyncSessionAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var canonical = false
    private var session: NativeAuthSession?

    func bind(_ session: NativeAuthSession?) {
        lock.withLock {
            generation &+= 1
            canonical = true
            self.session = session
        }
    }

    func invalidate() {
        lock.withLock {
            generation &+= 1
            session = nil
        }
    }

    func capture(ownerId: UUID, explicitSession: NativeAuthSession? = nil) throws -> SyncSessionLease {
        try lock.withLock {
            let captured = canonical ? session : explicitSession
            if canonical {
                guard let captured, explicitSession == nil || captured == explicitSession else {
                    throw SyncWireValidationError.invalidSession
                }
            }
            let lease = SyncSessionLease(
                ownerId: ownerId, generation: generation, session: captured, authority: self
            )
            try validateLocked(lease)
            return lease
        }
    }

    private func validateLocked(_ lease: SyncSessionLease) throws {
        try Task.checkCancellation()
        guard lease.generation == generation,
              !canonical || (session != nil && session == lease.session) else {
            throw SyncWireValidationError.invalidSession
        }
        if let captured = lease.session {
            guard captured.userId == lease.ownerId,
                  !captured.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  captured.expiresAt > Date() else { throw SyncWireValidationError.invalidSession }
        }
    }

    /// Explicit-session capture is a transport compatibility path, not bound proof.
    /// Check on this authority under the very lock that covers the disk action.
    func withBoundValid<T>(_ lease: SyncSessionLease, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            try validateLocked(lease)
            guard canonical, session != nil, lease.authority === self else {
                throw SyncWireValidationError.invalidSession
            }
            return try body()
        }
    }

    func withValid<T>(_ lease: SyncSessionLease, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            try validateLocked(lease)
            return try body()
        }
    }
}

/// Only a typed canonical receipt can authorize the durable create acknowledgement.
enum OutboxCommandResult: Sendable {
    case generic
    case catalogueCreate(PlantCreateReceiptDTO)
}

public actor PlantsAPIClient {
    public let baseURL: URL
    private let transport: any PlantsAPITransport
    private var installationCredential: String?
    private var clientLocale: String
    private var bearerToken: String?
    nonisolated let syncAuthority = SyncSessionAuthority()

    public init(
        baseURL: URL = URL(string: "https://api.narat.app/functions/v1/plants-api")!,
        transport: any PlantsAPITransport = URLSessionAPITransport(),
        installationCredential: String? = nil,
        clientLocale: String = "pl",
        bearerToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.installationCredential = installationCredential
        self.clientLocale = clientLocale
        self.bearerToken = bearerToken
    }

    public enum LocaleError: Error, Sendable, Equatable {
        case unsupportedLocale
    }

    /// Header metadata only: retain credentials, bound authority and in-flight operations.
    public func updateClientLocale(_ locale: String) throws {
        try Task.checkCancellation()
        guard locale == "en" || locale == "pl" else { throw LocaleError.unsupportedLocale }
        clientLocale = locale
    }

    public func updateContext(
        installationCredential: String?,
        clientLocale: String,
        bearerToken: String?
    ) {
        syncAuthority.invalidate()
        self.installationCredential = installationCredential
        self.clientLocale = clientLocale
        self.bearerToken = bearerToken
    }

    /// Bind on sign-in/refresh, and bind nil on sign-out. Once bound, this client
    /// never falls back to legacy sync, even while signed out. UI wiring is separate.
    public func bindSyncSession(_ session: NativeAuthSession?) {
        syncAuthority.bind(session)
        bearerToken = session?.accessToken
    }

    func captureSyncContext(ownerId: UUID) throws -> SyncSessionLease {
        try syncAuthority.capture(ownerId: ownerId)
    }

    func validateSyncContext(_ context: SyncSessionLease) throws {
        try syncAuthority.withValid(context) {}
    }

    /// Authenticated engine path; errors never trigger a legacy retry.
    func fetchSyncPage(
        context: SyncSessionLease, since: String?, until: String?,
        cursor: SyncWireCursorDTO?, limit: Int
    ) async throws -> SyncWireResult {
        try validateSyncContext(context)
        guard let session = context.session else { throw SyncWireValidationError.invalidSession }
        let result = try await fetchSyncWirePage(
            session: session, since: since, until: until, cursor: cursor, limit: limit
        )
        try validateSyncContext(context)
        return result
    }

    func sendOutboxCommand(
        _ envelope: CommandEnvelopeDTO, context: SyncSessionLease
    ) async throws -> OutboxCommandResult {
        try validateSyncContext(context)
        let catalogueCreate = context.session != nil && envelope.commandName == "plant.create"
        let manualWatering = context.session == nil ? nil : ManualWateringAction(envelope: envelope)
        if catalogueCreate { try CatalogueCreateWire.validate(envelope) }
        let encoder = JSONEncoder()
        if catalogueCreate || manualWatering != nil { encoder.outputFormatting = [.sortedKeys] }
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(envelope)
        var request = try buildRequest(
            path: "commands", method: "POST", operationId: envelope.operationId, body: body
        )
        if let session = context.session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        }
        if manualWatering != nil {
            request.setValue("en", forHTTPHeaderField: "X-Client-Locale")
            request.setValue(nil, forHTTPHeaderField: "X-Installation-Credential")
        }
        // Build and dispatch with the captured token in the same actor turn.
        let result: OutboxCommandResult
        if catalogueCreate {
            result = .catalogueCreate(try await execute(request, as: PlantCreateReceiptDTO.self, expectedStatus: 200))
        } else if let manualWatering {
            let receipt = try await execute(request, as: ManualWateringReceipt.self, expectedStatus: 200)
            try receipt.validate(plantId: envelope.plantId, action: manualWatering)
            result = .generic
        } else {
            _ = try await execute(request, as: CommandResponseDTO.self)
            result = .generic
        }
        try validateSyncContext(context)
        return result
    }

    /// Read-only wire boundary; callers must supply a lease from the bound session.
    /// Guest/permanent metadata is explicit because NativeAuthSession has no anonymous flag.
    func fetchAnalysisAccess(
        context: SyncSessionLease, expectedGuest: Bool
    ) async throws -> AnalysisAccessWireDTO {
        let session = try syncAuthority.withBoundValid(context) {
            guard let session = context.session else { throw SyncWireValidationError.invalidSession }
            return session
        }
        if expectedGuest {
            guard let credential = installationCredential,
                  !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AnalysisAccessWireError.missingInstallationCredential
            }
        }
        var request = try buildRequest(path: "analysis/access", method: "GET")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let snapshot = try await execute(request, as: AnalysisAccessWireDTO.self, expectedStatus: 200)
        // Validate the captured generation, including cancellation and A -> B -> A,
        // before exposing a snapshot. Never consult a replacement bearer or owner.
        return try syncAuthority.withBoundValid(context) {
            guard snapshot.ownerId == context.ownerId, snapshot.isGuest == expectedGuest else {
                throw AnalysisAccessWireError.identityMismatch
            }
            return snapshot
        }
    }

    public func buildRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        operationId: UUID? = nil,
        body: Data? = nil
    ) throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            resolvingAgainstBaseURL: false
        )
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientLocale, forHTTPHeaderField: "X-Client-Locale")

        if let credential = installationCredential, !credential.isEmpty {
            request.setValue(credential, forHTTPHeaderField: "X-Installation-Credential")
        }
        if let opId = operationId {
            request.setValue(opId.uuidString.lowercased(), forHTTPHeaderField: "X-Operation-Id")
        }
        if let token = bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }

    public func sendCommand(_ envelope: CommandEnvelopeDTO) async throws -> CommandResponseDTO {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(envelope)
        let request = try buildRequest(
            path: "commands",
            method: "POST",
            operationId: envelope.operationId,
            body: body
        )
        return try await execute(request, as: CommandResponseDTO.self)
    }

    /// Returns only the SQL receipt. Outbox acknowledgement belongs to the sync layer.
    public func sendCatalogueCreate(_ envelope: CommandEnvelopeDTO) async throws -> PlantCreateReceiptDTO {
        try CatalogueCreateWire.validate(envelope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(envelope)
        let request = try buildRequest(
            path: "commands",
            method: "POST",
            operationId: envelope.operationId,
            body: body
        )
        return try await execute(request, as: PlantCreateReceiptDTO.self)
    }

    /// Explicit legacy DTO/Date compatibility API. Bound SyncEngine uses the overload above.
    public func fetchSyncPage(
        since: Date?,
        until: Date?,
        cursor: SyncCursorDTO?,
        limit: Int = 200
    ) async throws -> SyncPageDTO {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let since {
            query.append(URLQueryItem(name: "since", value: formatter.string(from: since)))
        }
        if let until {
            query.append(URLQueryItem(name: "until", value: formatter.string(from: until)))
        }
        if let cursor {
            query.append(URLQueryItem(name: "cursor_updated_at", value: formatter.string(from: cursor.updatedAt)))
            query.append(URLQueryItem(name: "cursor_entity_type", value: cursor.entityType))
            query.append(URLQueryItem(name: "cursor_id", value: cursor.id.uuidString.lowercased()))
        }

        let request = try buildRequest(path: "sync", method: "GET", queryItems: query)
        return try await execute(request, as: SyncPageDTO.self)
    }

    private func execute<T: Decodable>(
        _ request: URLRequest, as type: T.Type, expectedStatus: Int? = nil
    ) async throws -> T {
        let (data, http) = try await transport.send(request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard (200..<300).contains(http.statusCode) else {
            if let apiErr = try? decoder.decode(APIErrorResponse.self, from: data) {
                throw apiErr
            }
            throw URLError(.badServerResponse)
        }
        if let expectedStatus, http.statusCode != expectedStatus {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(T.self, from: data)
    }
}

public enum CatalogueCreateValidationError: Error, Sendable {
    case invalidCommand
    case invalidPayload
}

// Validate the catalogue subset without rewriting the caller's persisted payload.
enum CatalogueCreateWire {
    private static let conditionValues: [String: Set<String>] = [
        "light_level": ["low", "medium", "bright_indirect", "direct_sun", "unknown"],
        "light_code": ["low", "medium", "bright_indirect", "direct_sun", "unknown"],
        "light_source": ["manual", "unknown"],
        "watering_habit": ["several_weekly", "weekly", "less_often", "frequent", "moderate", "sparse", "unknown"],
        "watering_code": ["several_weekly", "weekly", "less_often", "frequent", "moderate", "sparse", "unknown"],
        "last_watered": ["yes", "no", "within_7_days", "over_7_days", "unknown"],
        "drainage_code": ["yes", "no", "within_7_days", "over_7_days", "unknown"],
        "pot_type": ["terracotta", "plastic", "glazed_ceramic", "standard_drainage", "other", "unknown"]
    ]

    static func validate(_ envelope: CommandEnvelopeDTO) throws {
        guard envelope.commandName == "plant.create", envelope.plantId == nil else {
            throw CatalogueCreateValidationError.invalidCommand
        }
        guard let data = envelope.payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["creation_source"] as? String == "catalogue",
              fields(payload, kind: "payload") else {
            throw CatalogueCreateValidationError.invalidPayload
        }
        let overrides = payload["overrides"] as? [String: Any] ?? [:]
        guard [payload["plant_id"], payload["taxon_id"], overrides["plant_id"], overrides["taxon_id"]]
            .contains(where: { ($0 as? String)?.isEmpty == false }) else {
            throw CatalogueCreateValidationError.invalidPayload
        }
    }

    private static func fields(_ object: [String: Any], kind: String) -> Bool {
        for (key, value) in object {
            let isNull = value is NSNull
            if kind != "payload", let allowed = conditionValues[key] {
                guard isNull || (value as? String).map(allowed.contains) == true else { return false }
            } else if kind != "payload", key == "light_confirmed" {
                // NSNumber bridges numeric 0/1 to Bool; accept only JSON booleans.
                guard isNull || (value as? NSNumber).map({ String(cString: $0.objCType) == "c" }) == true else {
                    return false
                }
            } else if kind != "conditions", ["plant_id", "personal_name", "display_name"].contains(key) {
                guard isNull || (value as? String).map({
                    key != "plant_id" || !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) == true else { return false }
            } else if kind != "conditions", key == "taxon_id" {
                guard isNull || (value as? String).flatMap(UUID.init(uuidString:)) != nil else { return false }
            } else if kind == "payload", key == "origin_flow_id" {
                guard isNull || (value as? String).flatMap(UUID.init(uuidString:)) != nil else { return false }
            } else if kind == "payload", key == "photo_id" {
                guard isNull else { return false }
            } else if kind == "payload", ["creation_source", "add_method"].contains(key) {
                guard value as? String == "catalogue" else { return false }
            } else if kind == "payload", key == "creation_intent" {
                guard let intent = value as? String, ["care", "problem"].contains(intent) else { return false }
            } else if kind == "payload", ["conditions", "overrides"].contains(key) {
                guard let nested = value as? [String: Any], fields(nested, kind: key) else { return false }
            } else {
                return false
            }
        }
        return true
    }
}

// MARK: - Canonical SQL transport, separate from the legacy engine API

extension PlantsAPIClient {
    /// The caller supplies one authenticated session for both ownership and Authorization.
    /// This does not apply changes or advance any persisted checkpoint.
    public func fetchSyncWirePage(
        session: NativeAuthSession,
        since: String? = nil,
        until: String? = nil,
        cursor: SyncWireCursorDTO? = nil,
        limit: Int = 200
    ) async throws -> SyncWireResult {
        let context = try syncAuthority.capture(ownerId: session.userId, explicitSession: session)
        try SyncWireRules.validateRequest(since: since, until: until, cursor: cursor, limit: limit)
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        if let until { query.append(URLQueryItem(name: "until", value: until)) }
        if let cursor {
            query.append(URLQueryItem(name: "cursor_updated_at", value: cursor.updatedAt))
            query.append(URLQueryItem(name: "cursor_entity_type", value: cursor.entityType))
            query.append(URLQueryItem(name: "cursor_id", value: cursor.id.uuidString.lowercased()))
        }
        var request = try buildRequest(path: "sync", method: "GET", queryItems: query)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        // A literal '+' must not be interpreted as a form-encoded space by a query parser.
        if let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            request.url = components.url
        }
        let page = try await execute(request, as: SyncWirePageDTO.self)
        try validateSyncContext(context)
        try page.validate(since: since, requestedUntil: until, cursor: cursor, limit: limit)
        return SyncWireResult(ownerId: session.userId, page: page)
    }
}

private final class AnalysisUploadRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension PlantsAPIClient {
    func issueAnalysisUpload(
        jpeg: Data, operationId: UUID, locale: SupportedLocale, context: SyncSessionLease
    ) async throws -> AnalysisUploadTicket {
        guard !jpeg.isEmpty, jpeg.count <= AnalysisPhotoInput.maxCloudBytes else {
            throw AnalysisHTTPError.invalidUpload
        }
        let digest = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        let body = try JSONSerialization.data(withJSONObject: [
            "operation_id": operationId.uuidString.lowercased(), "mime_type": "image/jpeg",
            "byte_size": jpeg.count, "content_sha256": digest
        ], options: [.sortedKeys])
        let request = try buildRequest(path: "media/upload-ticket", method: "POST", body: body)
        let ticket: AnalysisUploadTicket = try await analysisRequest(
            request, locale: locale, context: context, status: [200]
        )
        guard (0...60).contains(ticket.expiresInSeconds), ticket.maxByteSize >= jpeg.count,
              !ticket.storageBucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !ticket.storagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isAnalysisUploadURL(ticket.signedUploadURL, photoAssetId: ticket.photoAssetId) else {
            throw AnalysisHTTPError.invalidUpload
        }
        return ticket
    }

    func uploadAnalysisJPEG(
        _ jpeg: Data, ticket: AnalysisUploadTicket, locale: SupportedLocale,
        context: SyncSessionLease
    ) async throws {
        guard !jpeg.isEmpty, jpeg.count <= min(ticket.maxByteSize, AnalysisPhotoInput.maxCloudBytes),
              isAnalysisUploadURL(ticket.signedUploadURL, photoAssetId: ticket.photoAssetId) else {
            throw AnalysisHTTPError.invalidUpload
        }
        var request = URLRequest(url: ticket.signedUploadURL)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        let photo: AnalysisUploadedPhoto = try await analysisRequest(
            request, locale: locale, context: context, status: [200], forbidRedirects: true
        )
        try validateUploadedPhoto(photo, id: ticket.photoAssetId)
    }

    func confirmAnalysisPhoto(
        id: UUID, locale: SupportedLocale, context: SyncSessionLease
    ) async throws {
        let body = try JSONEncoder().encode(["photo_asset_id": id.uuidString.lowercased()])
        let request = try buildRequest(path: "media/complete", method: "POST", body: body)
        let photo: AnalysisUploadedPhoto = try await analysisRequest(
            request, locale: locale, context: context, status: [200]
        )
        try validateUploadedPhoto(photo, id: id)
    }

    func createAnalysisJob(
        operationId: UUID, mode: AnalysisMode, photoAssetId: UUID,
        locale: SupportedLocale, context: SyncSessionLease
    ) async throws -> AnalysisJobWire {
        guard mode == .diagnosis || mode == .identification else {
            throw AnalysisHTTPError.invalidResponse
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode([
            "operation_id": operationId.uuidString.lowercased(), "mode": mode.rawValue,
            "photo_asset_id": photoAssetId.uuidString.lowercased()
        ])
        let request = try buildRequest(path: "analysis/jobs", method: "POST", body: body)
        let job: AnalysisJobWire = try await analysisRequest(
            request, locale: locale, context: context, status: [200, 202]
        )
        try job.validate(mode: mode)
        return job
    }

    func fetchAnalysisJob(
        id: UUID, mode: AnalysisMode, locale: SupportedLocale, context: SyncSessionLease
    ) async throws -> AnalysisJobWire {
        guard mode == .diagnosis || mode == .identification else {
            throw AnalysisHTTPError.invalidResponse
        }
        let request = try buildRequest(path: "analysis/jobs/\(id.uuidString.lowercased())", method: "GET")
        let job: AnalysisJobWire = try await analysisRequest(
            request, locale: locale, context: context, status: [200]
        )
        try job.validate(mode: mode, jobId: id)
        return job
    }

    func fetchCareRecommendation(
        plantId: UUID, context: SyncSessionLease
    ) async throws -> PlantCareRecommendation? {
        let request = try buildRequest(
            path: "plants/\(plantId.uuidString.lowercased())/care/recommendation", method: "GET"
        )
        let response: PlantCareRecommendationResponse = try await analysisRequest(
            request, locale: .en, context: context, status: [200], forbidRedirects: true
        )
        return try syncAuthority.withBoundValid(context) { try response.validated(for: plantId) }
    }

    private func validateUploadedPhoto(_ photo: AnalysisUploadedPhoto, id: UUID) throws {
        guard photo.photoAssetId == id, photo.state == "ready" else {
            throw AnalysisHTTPError.invalidResponse
        }
    }

    private func analysisRequest<T: Decodable>(
        _ input: URLRequest, locale: SupportedLocale, context: SyncSessionLease,
        status: Set<Int>, forbidRedirects: Bool = false
    ) async throws -> T {
        var request = input
        try syncAuthority.withBoundValid(context) {
            guard let session = context.session else { throw SyncWireValidationError.invalidSession }
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(locale.rawValue, forHTTPHeaderField: "X-Client-Locale")
            request.setValue(nil, forHTTPHeaderField: "X-Installation-Credential")
        }
        let data: Data
        let response: HTTPURLResponse
        if forbidRedirects {
            (data, response) = try await transport.sendWithoutRedirect(request)
        } else {
            (data, response) = try await transport.send(request)
        }
        try syncAuthority.withBoundValid(context) {}
        let decoder = JSONDecoder()
        guard status.contains(response.statusCode) else {
            if let failure = try? decoder.decode(APIErrorResponse.self, from: data) {
                throw failure
            }
            throw AnalysisHTTPError.invalidResponse
        }
        let decoded = try decoder.decode(T.self, from: data)
        return try syncAuthority.withBoundValid(context) { decoded }
    }

    private func isAnalysisUploadURL(_ url: URL, photoAssetId: UUID) -> Bool {
        guard let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              base.scheme?.lowercased() == "https", candidate.scheme?.lowercased() == "https",
              let expectedHost = base.host?.lowercased(),
              candidate.host?.lowercased() == expectedHost,
              (candidate.port ?? 443) == (base.port ?? 443),
              candidate.user == nil, candidate.password == nil, candidate.fragment == nil
        else { return false }
        let prefix = base.percentEncodedPath.hasSuffix("/")
            ? base.percentEncodedPath : base.percentEncodedPath + "/"
        return candidate.percentEncodedPath == prefix + "media/uploads/" + photoAssetId.uuidString.lowercased()
    }
}
