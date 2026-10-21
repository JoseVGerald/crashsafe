import Foundation

/// Everything the UI needs from an auth backend.
/// Implementations: `MockAuthService` (offline, default) and `FirebaseAuthService`.
protocol AuthService: AnyObject {
    /// A user restored from a previous session, if any.
    func restoreSession() async -> AuthUser?
    func signUp(name: String, email: String, password: String) async throws -> AuthUser
    func signIn(email: String, password: String) async throws -> AuthUser
    func signInWithApple() async throws -> AuthUser
    func sendPasswordReset(email: String) async throws
    func signOut() throws
    /// Permanently deletes the signed-in account (App Store guideline 5.1.1(v)).
    func deleteAccount() async throws
}

enum AuthError: LocalizedError, Equatable {
    case emailInUse
    case userNotFound
    case wrongPassword
    case weakPassword
    case invalidEmail
    case cancelled
    case network
    case other(String)

    var errorDescription: String? {
        switch self {
        case .emailInUse: "An account with this email already exists. Try signing in."
        case .userNotFound: "No account found with that email."
        case .wrongPassword: "That password is incorrect."
        case .weakPassword: "Choose a password with at least 8 characters."
        case .invalidEmail: "That email address doesn't look right."
        case .cancelled: "Sign in was cancelled."
        case .network: "Can't reach the server. Check your connection and try again."
        case .other(let message): message
        }
    }
}
