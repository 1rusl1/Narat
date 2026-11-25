import AuthenticationServices
import CryptoKit
import GoogleSignIn
import Security
import UIKit

struct AppleSignInNonce {
    let raw: String
    var sha256: String { SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined() }

    init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NativeAuthFailure.providerFailed
        }
        raw = bytes.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
public final class NativeIdentityProvider: NativeIdentityProviding {
    private let googleClientId: String?
    private let googleServerClientId: String?
    private var appleRequest: AppleAuthorizationRequest?
    struct GoogleTokens: Sendable {
        let idToken: String?
        let accessToken: String
    }
    typealias GoogleSignInCall = @MainActor (UIViewController, String) async throws -> GoogleTokens
    private let googleBundle: Bundle
    private let googleSignIn: GoogleSignInCall

    public init(googleClientId: String?, googleServerClientId: String? = nil) {
        self.googleClientId = googleClientId
        self.googleServerClientId = googleServerClientId
        self.googleBundle = .main
        self.googleSignIn = Self.signInGoogle
    }

    internal init(googleClientId: String?, googleServerClientId: String? = nil,
                  bundle: Bundle, googleSignIn: @escaping GoogleSignInCall) {
        self.googleClientId = googleClientId
        self.googleServerClientId = googleServerClientId
        self.googleBundle = bundle
        self.googleSignIn = googleSignIn
    }

    private static func signInGoogle(presenting: UIViewController, nonce: String) async throws -> GoogleTokens {
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presenting, hint: nil, additionalScopes: nil, nonce: nonce
        )
        return GoogleTokens(idToken: result.user.idToken?.tokenString,
                            accessToken: result.user.accessToken.tokenString)
    }

    nonisolated static func isGoogleConfigured(clientId: String?, bundle: Bundle = .main) -> Bool {
        guard let clientId, !clientId.isEmpty, !clientId.contains("$("),
              clientId.hasSuffix(".apps.googleusercontent.com") else { return false }
        let callbackScheme = clientId.split(separator: ".").reversed().joined(separator: ".")
        let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.contains(callbackScheme)
    }

    public func credentials(for provider: NativeAuthProvider, presenting: UIViewController) async throws -> NativeAuthCredentials {
        guard presenting.viewIfLoaded?.window != nil else { throw NativeAuthFailure.presentationUnavailable }
        switch provider {
        case .apple:
            guard appleRequest == nil, let window = presenting.view.window else {
                throw NativeAuthFailure.presentationUnavailable
            }
            let request = try AppleAuthorizationRequest(window: window)
            appleRequest = request
            defer { appleRequest = nil }
            return try await request.perform()
        case .google:
            guard let clientId = googleClientId, Self.isGoogleConfigured(clientId: clientId, bundle: googleBundle) else {
                throw NativeAuthFailure.configurationMissing
            }
            try Task.checkCancellation()
            let nonce = try AppleSignInNonce()
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(
                clientID: clientId, serverClientID: googleServerClientId
            )
            do {
                let result = try await googleSignIn(presenting, nonce.sha256)
                try Task.checkCancellation()
                guard let token = result.idToken, !token.isEmpty else {
                    throw NativeAuthFailure.invalidCredential
                }
                return NativeAuthCredentials(provider: .google, idToken: token,
                                             accessToken: result.accessToken, nonce: nonce.raw)
            } catch {
                try Task.checkCancellation()
                let nsError = error as NSError
                if nsError.domain == kGIDSignInErrorDomain && nsError.code == GIDSignInError.canceled.rawValue {
                    throw CancellationError()
                }
                throw error
            }
        }
    }

    public static func handleCallbackURL(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }
}

@MainActor
private final class AppleAuthorizationRequest: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    private let window: UIWindow
    private let nonce: AppleSignInNonce
    private var continuation: CheckedContinuation<NativeAuthCredentials, any Error>?
    private var controller: ASAuthorizationController?

    init(window: UIWindow) throws {
        self.window = window
        self.nonce = try AppleSignInNonce()
        super.init()
    }

    func perform() async throws -> NativeAuthCredentials {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = [.email, .fullName]
                request.nonce = nonce.sha256
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.controller = controller
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.controller?.cancel()
            }
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            finish(.failure(NativeAuthFailure.invalidCredential))
            return
        }
        finish(.success(NativeAuthCredentials(
            provider: .apple, idToken: token, nonce: nonce.raw,
            authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        )))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let nsError = error as NSError
        if nsError.domain == ASAuthorizationError.errorDomain && nsError.code == ASAuthorizationError.canceled.rawValue {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<NativeAuthCredentials, any Error>) {
        let pending = continuation
        continuation = nil
        controller = nil
        pending?.resume(with: result)
    }
}
