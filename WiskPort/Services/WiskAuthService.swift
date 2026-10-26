import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import Foundation
import GoogleSignIn
import Observation
import Security

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum WiskAuthState: Equatable {
    case loading
    case signedOut
    case signingIn
    case signedIn
    case failed(String)
}

@MainActor
@Observable
final class WiskAuthService: SyncAuthProviding {
    private(set) var currentUser: FirebaseAuth.User?
    private(set) var authState: WiskAuthState = .loading
    private(set) var lastErrorMessage: String?
    private var currentAppleNonce: String?
    private let debugSyncTestUID: String?
    private let forceSignedOutOverlay: Bool

    @ObservationIgnored nonisolated(unsafe) private var authStateHandle: AuthStateDidChangeListenerHandle?

    init() {
        #if DEBUG
        debugSyncTestUID = ProcessInfo.processInfo.environment["WISK_SYNC_TEST_UID"]?.nilIfBlank
        forceSignedOutOverlay = ProcessInfo.processInfo.environment["WISK_FORCE_SIGN_OUT"] == "1"
        let syncTestCredentials = WiskDebugSyncConfiguration.syncTestCredentials
        #else
        debugSyncTestUID = nil
        forceSignedOutOverlay = false
        #endif
        configureGoogleSignIn()
        #if DEBUG
        if syncTestCredentials != nil {
            try? Auth.auth().signOut()
        }
        #endif
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                if self?.forceSignedOutOverlay == true {
                    self?.authState = .signedOut
                    return
                }
                if self?.debugSyncTestUID != nil {
                    self?.authState = .signedIn
                    return
                }
                #if DEBUG
                if let syncTestCredentials {
                    self?.currentUser = user
                    self?.authState = user?.email == syncTestCredentials.email ? .signedIn : .signedOut
                    return
                }
                #endif
                self?.currentUser = user
                self?.authState = user?.isAnonymous == false ? .signedIn : .signedOut
            }
        }
        #if DEBUG
        if forceSignedOutOverlay {
            authState = .signedOut
        } else if debugSyncTestUID != nil {
            authState = .signedIn
        } else if let credentials = syncTestCredentials {
            Task { [weak self] in
                await self?.signInForSyncTesting(email: credentials.email, password: credentials.password)
            }
        } else {
            adoptPersistedAuthUserIfAvailable()
        }
        #else
        adoptPersistedAuthUserIfAvailable()
        #endif
    }

    private func adoptPersistedAuthUserIfAvailable() {
        guard forceSignedOutOverlay == false, debugSyncTestUID == nil else { return }
        guard let user = Auth.auth().currentUser, user.isAnonymous == false else { return }
        currentUser = user
        authState = .signedIn
    }

    deinit {
        if let authStateHandle {
            Auth.auth().removeStateDidChangeListener(authStateHandle)
        }
    }

    var isSignedIn: Bool {
        if forceSignedOutOverlay { return false }
        if debugSyncTestUID != nil { return true }
        #if DEBUG
        if let credentials = WiskDebugSyncConfiguration.syncTestCredentials {
            return currentUser?.email == credentials.email
        }
        #endif
        return currentUser?.isAnonymous == false
    }

    var isLoading: Bool {
        authState == .loading
    }

    var displayName: String {
        currentUser?.displayName ?? currentUser?.email ?? "Wisk user"
    }

    var accountSubtitle: String {
        currentUser?.email ?? currentUser?.providerData.first?.providerID ?? "Signed in"
    }

    var photoURL: URL? {
        currentUser?.photoURL
    }

    var firebaseUID: String? {
        if forceSignedOutOverlay { return nil }
        if let debugSyncTestUID { return debugSyncTestUID }
        #if DEBUG
        if let credentials = WiskDebugSyncConfiguration.syncTestCredentials,
           let user = Auth.auth().currentUser,
           user.email == credentials.email {
            return user.uid
        }
        #endif
        return currentUser?.uid
    }

    #if DEBUG
    private func signInForSyncTesting(email: String, password: String) async {
        authState = .signingIn
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            currentUser = result.user
            authState = .signedIn
            lastErrorMessage = nil
        } catch {
            setError(error)
        }
    }
    #endif

    func signInAnonymouslyIfNeeded() async {
        guard Auth.auth().currentUser == nil else { return }
        do {
            let result = try await Auth.auth().signInAnonymously()
            currentUser = result.user
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func idToken(forceRefresh: Bool = false) async throws -> String {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else {
            throw WiskAuthError.accountRequired
        }
        return try await user.getIDTokenResult(forcingRefresh: forceRefresh).token
    }

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentAppleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
        authState = .signingIn
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let nonce = currentAppleNonce,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8)
            else {
                throw WiskAuthError.invalidAppleCredential
            }

            let authCredential = OAuthProvider.appleCredential(
                withIDToken: token,
                rawNonce: nonce,
                fullName: credential.fullName
            )
            try await linkOrSignIn(with: authCredential)
        } catch {
            setError(error)
        }
        currentAppleNonce = nil
    }

    func signInWithGoogle() async {
        authState = .signingIn
        do {
            configureGoogleSignIn()
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: try presentingAnchor())
            guard let idToken = result.user.idToken?.tokenString else {
                throw WiskAuthError.invalidGoogleCredential
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            try await linkOrSignIn(with: credential)
        } catch {
            setError(error)
        }
    }

    func handleOpenURL(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    func signOut() throws {
        GIDSignIn.sharedInstance.signOut()
        try Auth.auth().signOut()
        currentUser = nil
        authState = .signedOut
        lastErrorMessage = nil
    }

    func refreshCurrentUserFromFirebase() {
        currentUser = Auth.auth().currentUser
    }

    private func linkOrSignIn(with credential: AuthCredential) async throws {
        if let user = Auth.auth().currentUser, user.isAnonymous {
            do {
                let result = try await user.link(with: credential)
                currentUser = result.user
                authState = .signedIn
                lastErrorMessage = nil
                return
            } catch {
                if let updatedCredential = (error as NSError).userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential {
                    let result = try await Auth.auth().signIn(with: updatedCredential)
                    currentUser = result.user
                    authState = .signedIn
                    lastErrorMessage = nil
                    return
                }
                let code = AuthErrorCode(rawValue: (error as NSError).code)
                guard code == .credentialAlreadyInUse || code == .providerAlreadyLinked else {
                    throw error
                }
            }
        }

        let result = try await Auth.auth().signIn(with: credential)
        currentUser = result.user
        authState = .signedIn
        lastErrorMessage = nil
    }

    private func configureGoogleSignIn() {
        guard let clientID = FirebaseApp.app()?.options.clientID else { return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }

    private func setError(_ error: Error) {
        let message = Self.displayMessage(for: error)
        lastErrorMessage = message
        authState = .failed(message)
    }

    private static func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let nsError = error as NSError
        #if os(macOS)
        if nsError.domain == GIDSignInError.errorDomain,
           nsError.code == GIDSignInError.keychain.rawValue {
            return "Google Sign-In needs a signed Wisk Mac build to store your account in Keychain."
        }
        #endif
        return nsError.localizedDescription
    }

    private func presentingAnchor() throws -> PlatformPresentationAnchor {
        #if os(iOS)
        guard let controller = UIApplication.shared.wiskTopMostViewController() else {
            throw WiskAuthError.missingPresentationAnchor
        }
        return controller
        #elseif os(macOS)
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            throw WiskAuthError.missingPresentationAnchor
        }
        return window
        #endif
    }

    private static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            guard status == errSecSuccess else {
                fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(status)")
            }

            for random in randoms where remainingLength > 0 {
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return result
    }
}

enum WiskAuthError: LocalizedError {
    case missingUser
    case accountRequired
    case invalidAppleCredential
    case invalidGoogleCredential
    case missingPresentationAnchor

    var errorDescription: String? {
        switch self {
        case .missingUser:
            return "Wisk could not create a Firebase session."
        case .accountRequired:
            return "Sign in with Apple or Google to sync Wisk."
        case .invalidAppleCredential:
            return "Wisk could not read the Apple sign-in response."
        case .invalidGoogleCredential:
            return "Wisk could not read the Google sign-in response."
        case .missingPresentationAnchor:
            return "Wisk could not present the sign-in window."
        }
    }
}

#if os(iOS)
typealias PlatformPresentationAnchor = UIViewController

private extension UIApplication {
    func wiskTopMostViewController(
        base: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
    ) -> UIViewController? {
        if let navigation = base as? UINavigationController {
            return wiskTopMostViewController(base: navigation.visibleViewController)
        }
        if let tab = base as? UITabBarController, let selected = tab.selectedViewController {
            return wiskTopMostViewController(base: selected)
        }
        if let presented = base?.presentedViewController {
            return wiskTopMostViewController(base: presented)
        }
        return base
    }
}
#elseif os(macOS)
typealias PlatformPresentationAnchor = NSWindow
#endif
