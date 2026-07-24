import AuthenticationServices
import Combine
import CryptoKit
import FirebaseAuth
import Foundation
import Security

@MainActor
final class AuthenticationService: ObservableObject {
    @Published private(set) var userID: String?
    @Published private(set) var displayName: String?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    var onUserChanged: ((String?) -> Void)?

    private let cloudConfigured: Bool
    private var authListener: AuthStateDidChangeListenerHandle?
    private var currentNonce: String?

    init(cloudConfigured: Bool) {
        self.cloudConfigured = cloudConfigured

        guard cloudConfigured else { return }
        self.userID = Auth.auth().currentUser?.uid
        self.displayName = Auth.auth().currentUser?.displayName
        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                guard let self else { return }
                self.userID = user?.uid
                self.displayName = user?.displayName
                self.onUserChanged?(user?.uid)
            }
        }
    }

    deinit {
        if cloudConfigured, let authListener {
            Auth.auth().removeStateDidChangeListener(authListener)
        }
    }

    var isSignedIn: Bool {
        userID != nil
    }

    var isCloudConfigured: Bool {
        cloudConfigured
    }

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
        errorMessage = nil
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        guard cloudConfigured else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let authorization = try result.get()
            guard
                let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let nonce = currentNonce,
                let tokenData = appleCredential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8)
            else {
                throw AuthenticationError.invalidAppleCredential
            }

            let credential = OAuthProvider.appleCredential(
                withIDToken: idToken,
                rawNonce: nonce,
                fullName: appleCredential.fullName
            )
            _ = try await Auth.auth().signIn(with: credential)
            currentNonce = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        guard cloudConfigured else { return }
        do {
            try Auth.auth().signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }

        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { characters[Int($0) % characters.count] })
    }
}

private enum AuthenticationError: LocalizedError {
    case invalidAppleCredential

    var errorDescription: String? {
        "Apple did not return a valid sign-in credential. Please try again."
    }
}
