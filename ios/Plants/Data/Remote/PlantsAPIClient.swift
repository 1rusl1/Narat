import Foundation

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
}

public actor PlantsAPIClient {
    public let baseURL: URL
    private let transport: any PlantsAPITransport
    private var installationCredential: String?
    private var clientLocale: String
    private var bearerToken: String?

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

    public func updateContext(
        installationCredential: String?,
        clientLocale: String,
        bearerToken: String?
    ) {
        self.installationCredential = installationCredential
        self.clientLocale = clientLocale
        self.bearerToken = bearerToken
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

    private func execute<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, http) = try await transport.send(request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard (200..<300).contains(http.statusCode) else {
            if let apiErr = try? decoder.decode(APIErrorResponse.self, from: data) {
                throw apiErr
            }
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(T.self, from: data)
    }
}
