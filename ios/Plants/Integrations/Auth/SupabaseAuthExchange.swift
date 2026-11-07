import Foundation
import Supabase

@MainActor
public final class SupabaseAuthExchange: NativeAuthExchanging {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func exchange(_ credentials: NativeAuthCredentials) async throws -> NativeAuthSession {
        let session = try await client.auth.signInWithIdToken(credentials: .init(
            provider: credentials.provider == .apple ? .apple : .google,
            idToken: credentials.idToken,
            accessToken: credentials.accessToken,
            nonce: credentials.nonce
        ))
        guard !session.user.isAnonymous else { throw NativeAuthFailure.invalidCredential }
        return NativeAuthSession(
            userId: session.user.id,
            accessToken: session.accessToken,
            expiresAt: Date(timeIntervalSince1970: session.expiresAt)
        )
    }
}
