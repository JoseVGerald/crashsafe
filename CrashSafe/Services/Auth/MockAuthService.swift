import CryptoKit
import Foundation

/// Offline auth so the app runs with zero setup. Accounts live in UserDefaults
/// (passwords stored as SHA-256 hashes). Not secure — for development and demos only.
final class MockAuthService: AuthService {
    private struct StoredAccount: Codable {
        var user: AuthUser
        var passwordHash: String
    }

    private let defaults: UserDefaults
    private let latency: Duration
    private let accountsKey = "mockAuth.accounts"
    private let sessionKey = "mockAuth.sessionUserID"

    init(defaults: UserDefaults = .standard, latency: Duration = .milliseconds(700)) {
        self.defaults = defaults
        self.latency = latency
    }

    func restoreSession() async -> AuthUser? {
        guard let id = defaults.string(forKey: sessionKey) else { return nil }
        return accounts().values.first { $0.user.id == id }?.user
    }

    func signUp(name: String, email: String, password: String) async throws -> AuthUser {
        try await Task.sleep(for: latency)
        let key = Self.normalize(email)
        var all = accounts()
        guard all[key] == nil else { throw AuthError.emailInUse }
        guard password.count >= 8 else { throw AuthError.weakPassword }
        let user = AuthUser(id: UUID().uuidString, name: name, email: key)
        all[key] = StoredAccount(user: user, passwordHash: Self.hash(password))
        save(all)
        defaults.set(user.id, forKey: sessionKey)
        return user
    }

    func signIn(email: String, password: String) async throws -> AuthUser {
        try await Task.sleep(for: latency)
        guard let account = accounts()[Self.normalize(email)] else { throw AuthError.userNotFound }
        guard account.passwordHash == Self.hash(password) else { throw AuthError.wrongPassword }
        defaults.set(account.user.id, forKey: sessionKey)
        return account.user
    }

    /// The real Apple flow needs a provisioned entitlement, so the mock just
    /// signs in a fixed demo Apple user.
    func signInWithApple() async throws -> AuthUser {
        try await Task.sleep(for: latency)
        let key = "apple-demo@privaterelay.appleid.com"
        var all = accounts()
        let account = all[key] ?? StoredAccount(
            user: AuthUser(id: "apple-demo-user", name: "Apple Demo", email: key),
            passwordHash: ""
        )
        all[key] = account
        save(all)
        defaults.set(account.user.id, forKey: sessionKey)
        return account.user
    }

    func sendPasswordReset(email: String) async throws {
        try await Task.sleep(for: latency)
        // Real backends don't reveal whether an account exists, so neither do we.
    }

    func signOut() throws {
        defaults.removeObject(forKey: sessionKey)
    }

    func deleteAccount() async throws {
        guard let id = defaults.string(forKey: sessionKey) else { return }
        save(accounts().filter { $0.value.user.id != id })
        defaults.removeObject(forKey: sessionKey)
    }

    // MARK: - Storage

    private func accounts() -> [String: StoredAccount] {
        guard let data = defaults.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([String: StoredAccount].self, from: data)
        else { return [:] }
        return decoded
    }

    private func save(_ accounts: [String: StoredAccount]) {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: accountsKey)
    }

    private static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func hash(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
