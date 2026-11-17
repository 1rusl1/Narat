import AuthenticationServices
import GoogleSignIn
import SwiftData
import UIKit
import XCTest
@testable import Plants

@MainActor
private final class IdentityProviderStub: NativeIdentityProviding {
    var result: Result<NativeAuthCredentials, any Error> = .success(.init(provider: .apple, idToken: "apple-token", nonce: "nonce", authorizationCode: "code"))
    var calls = 0
    var onRequest: (() async throws -> Void)?

    func credentials(for provider: NativeAuthProvider, presenting: UIViewController) async throws -> NativeAuthCredentials {
        calls += 1
        try await onRequest?()
        return try result.get()
    }
}

@MainActor
private final class AuthExchangeStub: NativeAuthExchanging {
    var calls = 0
    var received: NativeAuthCredentials?
    var failure: (any Error)?
    let session = NativeAuthSession(userId: UUID(), accessToken: "permanent-token", expiresAt: Date().addingTimeInterval(3600))

    func exchange(_ credentials: NativeAuthCredentials) async throws -> NativeAuthSession {
        calls += 1
        received = credentials
        if let failure { throw failure }
        return session
    }
}

@MainActor
final class NativeAuthTests: XCTestCase {
    func testCancellationKeepsPersistentGuestDraftAndFlowUnchanged() async throws {
        let container = try LocalStore.makeContainer(accountScope: UUID().uuidString, inMemory: true)
        let store = LocalStore(modelContainer: container)
        let router = AddPlantRouter(initialState: AddFlowState(
            currentStep: .preliminaryResult, photoLocalIdentifier: "retained-photo.jpg",
            confirmedPlantId: "monstera_deliciosa", resultMode: .diagnosis, draftId: UUID()
        ))
        let original = router.flowState
        let draftId = try XCTUnwrap(original.draftId)
        let snapshot = GuestDraftCacheSnapshot(draftId: draftId, flowState: original)
        let provider = IdentityProviderStub()
        provider.result = .failure(CancellationError())
        // Verify the checkpoint exists BEFORE the provider is opened.
        provider.onRequest = {
            let cached = try await store.loadGuestDraft(draftId: draftId)
            XCTAssertEqual(cached?.flowState.photoLocalIdentifier, "retained-photo.jpg")
        }
        let exchange = AuthExchangeStub()
        let service = NativeAuthService(identityProvider: provider, exchange: exchange)
        let result = await service.signIn(with: .apple, presenting: UIViewController()) {
            try await store.saveGuestDraft(snapshot)
        }
        XCTAssertNil(result)
        XCTAssertEqual(service.state, .cancelled)
        XCTAssertEqual(exchange.calls, 0)
        XCTAssertEqual(router.flowState, original)
        let reloaded = try await LocalStore(modelContainer: container).loadGuestDraft(draftId: draftId)
        XCTAssertEqual(reloaded?.flowState.draftId, original.draftId)
        XCTAssertEqual(reloaded?.flowState.conditions, original.conditions)
        XCTAssertFalse(service.isSigningIn)
    }

    func testCheckpointFailureNeverOpensProviderOrChangesSession() async {
        let provider = IdentityProviderStub(), exchange = AuthExchangeStub()
        let service = NativeAuthService(identityProvider: provider, exchange: exchange)
        let result = await service.signIn(with: .apple, presenting: UIViewController()) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        XCTAssertNil(result)
        XCTAssertEqual(provider.calls, 0)
        XCTAssertEqual(exchange.calls, 0)
        XCTAssertEqual(service.state, .failed(.preparationFailed))
    }

    func testSuccessfulAppleExchangeForwardsRawNonceAndAuthorizationCode() async {
        let provider = IdentityProviderStub(), exchange = AuthExchangeStub()
        let service = NativeAuthService(identityProvider: provider, exchange: exchange)
        let result = await service.signIn(with: .apple, presenting: UIViewController()) {}
        XCTAssertEqual(result?.session, exchange.session)
        XCTAssertEqual(result?.appleAuthorizationCode, "code")
        XCTAssertEqual(exchange.received?.nonce, "nonce")
        XCTAssertEqual(service.state, .signedIn(exchange.session.userId))
    }

    func testGoogleExchangesIDAndAccessTokensWithoutAppleNonce() async {
        let provider = IdentityProviderStub(), exchange = AuthExchangeStub()
        provider.result = .success(.init(provider: .google, idToken: "google-token", accessToken: "google-access"))
        let service = NativeAuthService(identityProvider: provider, exchange: exchange)
        let result = await service.signIn(with: .google, presenting: UIViewController()) {}
        XCTAssertNotNil(result)
        XCTAssertNil(result?.appleAuthorizationCode)
        XCTAssertEqual(exchange.received?.provider, .google)
        XCTAssertEqual(exchange.received?.accessToken, "google-access")
        XCTAssertNil(exchange.received?.nonce)
    }

    func testExchangeFailureKeepsDraftAndCanRetry() async throws {
        let container = try LocalStore.makeContainer(accountScope: UUID().uuidString, inMemory: true)
        let store = LocalStore(modelContainer: container)
        let draftId = UUID()
        let snapshot = GuestDraftCacheSnapshot(draftId: draftId, flowState: AddFlowState(draftId: draftId))
        let provider = IdentityProviderStub(), exchange = AuthExchangeStub()
        exchange.failure = URLError(.notConnectedToInternet)
        let service = NativeAuthService(identityProvider: provider, exchange: exchange)
        let failed = await service.signIn(with: .apple, presenting: UIViewController()) {
            try await store.saveGuestDraft(snapshot)
        }
        XCTAssertNil(failed)
        XCTAssertEqual(service.state, .failed(.exchangeFailed))
        let retained = try await store.loadGuestDraft(draftId: draftId)
        XCTAssertNotNil(retained)
        exchange.failure = nil
        let retried = await service.signIn(with: .apple, presenting: UIViewController()) {}
        XCTAssertNotNil(retried)
        let afterSuccess = try await store.loadGuestDraft(draftId: draftId)
        XCTAssertNotNil(afterSuccess, "Only confirmed claim/plant.create may clear a guest draft, never sign-in.")
    }

    func testWrongProviderAndMissingAppleNonceAreRejectedBeforeExchange() async {
        for credentials in [
            NativeAuthCredentials(provider: .google, idToken: "wrong-provider"),
            NativeAuthCredentials(provider: .apple, idToken: "token")
        ] {
            let provider = IdentityProviderStub(), exchange = AuthExchangeStub()
            provider.result = .success(credentials)
            let service = NativeAuthService(identityProvider: provider, exchange: exchange)
            let result = await service.signIn(with: .apple, presenting: UIViewController()) {}
            XCTAssertNil(result)
            XCTAssertEqual(service.state, .failed(.invalidCredential))
            XCTAssertEqual(exchange.calls, 0)
        }
    }

    func testConcurrentSignInDoesNotOpenSecondProvider() async {
        let provider = IdentityProviderStub(), exchange = AuthExchangeStub()
        let service = NativeAuthService(identityProvider: provider, exchange: exchange)
        var checkpoint: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await service.signIn(with: .apple, presenting: UIViewController()) {
                await withCheckedContinuation { checkpoint = $0 }
            }
        }
        while checkpoint == nil { await Task.yield() }
        let second = await service.signIn(with: .google, presenting: UIViewController()) {
            XCTFail("Second sign-in must not touch the draft or claim proof.")
        }
        XCTAssertNil(second)
        XCTAssertEqual(service.state, .preparing)
        checkpoint?.resume()
        _ = await first.value
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(exchange.calls, 1)
    }

    func testTaskCancellationBeforeExchangePreservesGuestSession() async {
        let provider = IdentityProviderStub(), exchange = AuthExchangeStub()
        let service = NativeAuthService(identityProvider: provider, exchange: exchange)
        let task = Task { @MainActor in
            await service.signIn(with: .apple, presenting: UIViewController()) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(service.state, .cancelled)
        XCTAssertEqual(provider.calls, 0)
        XCTAssertEqual(exchange.calls, 0)
    }

    func testConfigurationRejectsMissingValuesAndNonHTTPSURL() throws {
        XCTAssertThrowsError(try NativeAuthConfiguration(values: [:]))
        XCTAssertThrowsError(try NativeAuthConfiguration(values: [
            "NaratSupabaseURL": "http://project.supabase.co", "NaratSupabasePublishableKey": "public-key"
        ]))
        let config = try NativeAuthConfiguration(values: [
            "NaratSupabaseURL": "https://project.supabase.co", "NaratSupabasePublishableKey": "public-key",
            "GIDClientID": "$(GOOGLE_IOS_CLIENT_ID)"
        ])
        XCTAssertEqual(config.supabaseURL.host, "project.supabase.co")
        XCTAssertNil(config.googleClientId)
        XCTAssertTrue(config.supportsAppleSignIn)
    }

    func testPersonalConfigurationDisablesAppleSignIn() throws {
        let config = try NativeAuthConfiguration(values: [
            "NaratSupabaseURL": "https://project.supabase.co", "NaratSupabasePublishableKey": "public-key",
            "NaratAppleSignInEnabled": "NO"
        ])
        XCTAssertFalse(config.supportsAppleSignIn)
    }

    func testNonceIsFreshAndSHA256MatchesRawNonce() throws {
        let first = try AppleSignInNonce(), second = try AppleSignInNonce()
        XCTAssertEqual(first.raw.count, 64)
        XCTAssertNotEqual(first.raw, second.raw)
        XCTAssertNotEqual(first.sha256, second.sha256)
        XCTAssertEqual(first.sha256.count, 64)
        XCTAssertNotEqual(first.raw, first.sha256)
    }
}
