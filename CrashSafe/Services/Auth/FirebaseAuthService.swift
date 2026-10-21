// Compiled only once the Firebase package is added (see README → "Switching to Firebase").
#if canImport(FirebaseAuth) && canImport(FirebaseCore)
import FirebaseAuth
import FirebaseCore
import Foundation

/// Firebase email/password + Sign in with Apple.
/// Requires `GoogleService-Info.plist` in the app target (never commit it).
final class FirebaseAuthService: AuthService {
    private let apple = AppleSignInCoordinator()

    init() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }

    func restoreSession() async -> AuthUser? {
        Auth.auth().currentUser.map(Self.makeUser)
    }

    func signUp(name: String, email: String, password: String) async throws -> AuthUser {
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            let change = result.user.createProfileChangeRequest()
            change.displayName = name
            try await change.commitChanges()
            var user = Self.makeUser(result.user)
            user.name = name
            return user
        } catch {
            throw Self.map(error)
        }
    }

    func signIn(email: String, password: String) async throws -> AuthUser {
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            return Self.makeUser(result.user)
        } catch {
            throw Self.map(error)
        }
    }

    func signInWithApple() async throws -> AuthUser {
        let apple = try await apple.signIn()
        let credential = OAuthProvider.appleCredential(
            withIDToken: apple.idToken,
            rawNonce: apple.rawNonce,
            fullName: apple.credential.fullName
        )
        do {
            let result = try await Auth.auth().signIn(with: credential)
            return Self.makeUser(result.user)
        } catch {
            throw Self.map(error)
        }
    }

    func sendPasswordReset(email: String) async throws {
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email)
        } catch {
            throw Self.map(error)
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }

    func deleteAccount() async throws {
        do {
            try await Auth.auth().currentUser?.delete()
        } catch {
            // Firebase requires a recent sign-in; the UI asks the user to sign in again.
            throw Self.map(error)
        }
    }

    private static func makeUser(_ user: User) -> AuthUser {
        AuthUser(id: user.uid, name: user.displayName ?? "", email: user.email ?? "")
    }

    private static func map(_ error: Error) -> AuthError {
        let code = AuthErrorCode(rawValue: (error as NSError).code)
        switch code {
        case .emailAlreadyInUse: return .emailInUse
        case .userNotFound: return .userNotFound
        case .wrongPassword, .invalidCredential: return .wrongPassword
        case .weakPassword: return .weakPassword
        case .invalidEmail: return .invalidEmail
        case .networkError: return .network
        default: return .other(error.localizedDescription)
        }
    }
}
#endif
