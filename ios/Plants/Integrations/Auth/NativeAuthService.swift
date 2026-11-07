import Foundation
import Observation
import UIKit

public enum NativeAuthProvider: String, Sendable, Equatable {
    case apple, google
}

/// Ephemeral provider credentials. Never log or persist these as application data.
public struct NativeAuthCredentials: Sendable {
    public let provider: NativeAuthProvider
    public let idToken: String
    public let accessToken: String?
    public let nonce: String?
    public let authorizationCode: String?

    public init(provider: NativeAuthProvider, idToken: String, accessToken: String? = nil,
                nonce: String? = nil, authorizationCode: String? = nil) {
        self.provider = provider
        self.idToken = idToken
        self.accessToken = accessToken
        self.nonce = nonce
        self.authorizationCode = authorizationCode
    }
}

public struct NativeAuthSession: Sendable, Equatable {
    public let userId: UUID
    public let accessToken: String
    public let expiresAt: Date

    public init(userId: UUID, accessToken: String, expiresAt: Date) {
        self.userId = userId
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

public struct NativeSignInResult: Sendable {
    public let session: NativeAuthSession
    /// Forward to the server's Apple revoke-credential exchange when that endpoint is available.
    /// Never put this in the diary, logs, UserDefaults, or claim payload.
    public let appleAuthorizationCode: String?
}

public enum NativeAuthFailure: String, Error, Sendable, Equatable {
    case configurationMissing, presentationUnavailable, invalidCredential
    case preparationFailed, providerFailed, exchangeFailed
}

public enum NativeAuthState: Sendable, Equatable {
    case idle, preparing, authorizing(NativeAuthProvider), exchanging
    case signedIn(UUID), cancelled, failed(NativeAuthFailure)
}

@MainActor
public protocol NativeIdentityProviding {
    func credentials(for provider: NativeAuthProvider, presenting: UIViewController) async throws -> NativeAuthCredentials
}

@MainActor
public protocol NativeAuthExchanging {
    func exchange(_ credentials: NativeAuthCredentials) async throws -> NativeAuthSession
}

@MainActor
@Observable
public final class NativeAuthService {
    public private(set) var state: NativeAuthState = .idle
    public private(set) var isSigningIn = false
    private let identityProvider: any NativeIdentityProviding
    private let exchange: any NativeAuthExchanging

    public init(identityProvider: any NativeIdentityProviding, exchange: any NativeAuthExchanging) {
        self.identityProvider = identityProvider
        self.exchange = exchange
    }

    /// The caller must durably checkpoint GuestDraftCache and obtain/persist the claim proof
    /// before the native provider is opened. A failure here prevents any auth-session change.
    /// Neither cancellation nor failure clears the cache, signs out the guest, or resets AddFlowState.
    public func signIn(
        with provider: NativeAuthProvider,
        presenting: UIViewController,
        prepareForSessionChange: @MainActor () async throws -> Void
    ) async -> NativeSignInResult? {
        guard !isSigningIn else { return nil }
        isSigningIn = true
        defer { isSigningIn = false }
        state = .preparing
        var failure: NativeAuthFailure = .preparationFailed
        do {
            try Task.checkCancellation()
            try await prepareForSessionChange()
            try Task.checkCancellation()
            failure = .providerFailed
            state = .authorizing(provider)
            let credentials = try await identityProvider.credentials(for: provider, presenting: presenting)
            try Task.checkCancellation()
            guard credentials.provider == provider, !credentials.idToken.isEmpty,
                  provider != .apple || !(credentials.nonce ?? "").isEmpty else {
                throw NativeAuthFailure.invalidCredential
            }
            failure = .exchangeFailed
            state = .exchanging
            let session = try await exchange.exchange(credentials)
            // Once Supabase has committed the session, report it even if the caller's task
            // was cancelled during exchange. Do not leave UI claiming the user is still a guest.
            guard !session.accessToken.isEmpty, session.expiresAt > Date() else {
                throw NativeAuthFailure.invalidCredential
            }
            state = .signedIn(session.userId)
            return NativeSignInResult(session: session, appleAuthorizationCode: credentials.authorizationCode)
        } catch is CancellationError {
            state = .cancelled
        } catch let error as NativeAuthFailure {
            state = .failed(error)
        } catch {
            // Surface only stable app error codes, never raw SDK errors with token/PII context.
            state = .failed(failure)
        }
        return nil
    }
}
