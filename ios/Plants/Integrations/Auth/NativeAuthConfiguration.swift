import Foundation
import Supabase

public struct NativeAuthConfiguration: Sendable {
    public let supabaseURL: URL
    public let supabasePublishableKey: String
    public let googleClientId: String?
    public let googleServerClientId: String?
    public let supportsAppleSignIn: Bool

    public var supportsGoogleSignIn: Bool {
        NativeIdentityProvider.isGoogleConfigured(clientId: googleClientId)
    }

    public init(values: [String: String]) throws {
        func configured(_ key: String) -> String? {
            guard let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !value.contains("$(") else { return nil }
            return value
        }
        guard let rawURL = configured("NaratSupabaseURL"), let url = URL(string: rawURL),
              url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil,
              let key = configured("NaratSupabasePublishableKey") else {
            throw NativeAuthFailure.configurationMissing
        }
        supabaseURL = url
        supabasePublishableKey = key
        googleClientId = configured("GIDClientID")
        googleServerClientId = configured("GIDServerClientID")
        supportsAppleSignIn = configured("NaratAppleSignInEnabled") != "NO"
    }

    public init(bundle: Bundle = .main) throws {
        try self.init(values: (bundle.infoDictionary ?? [:]).compactMapValues { $0 as? String })
    }

    /// Use one shared SupabaseClient for auth, claim preparation and session refresh.
    @MainActor
    public func makeService(client: SupabaseClient) -> NativeAuthService {
        NativeAuthService(
            identityProvider: NativeIdentityProvider(googleClientId: googleClientId, googleServerClientId: googleServerClientId),
            exchange: SupabaseAuthExchange(client: client)
        )
    }
}
