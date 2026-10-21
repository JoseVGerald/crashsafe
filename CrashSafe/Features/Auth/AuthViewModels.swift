import Foundation
import Observation

/// Pure validation rules, shared by sign-in and sign-up (and unit tested).
enum Validation {
    static func name(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter your name." : nil
    }

    static func email(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Enter your email." }
        let pattern = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return trimmed.range(of: pattern, options: .regularExpression) == nil ? "Enter a valid email address." : nil
    }

    static func newPassword(_ value: String) -> String? {
        if value.isEmpty { return "Choose a password." }
        return value.count < 8 ? "Use at least 8 characters." : nil
    }

    static func confirmation(_ value: String, matches password: String) -> String? {
        if value.isEmpty { return "Re-enter your password." }
        return value != password ? "Passwords don't match." : nil
    }
}

@Observable
final class SignUpViewModel {
    enum Field: Hashable { case name, email, password, confirm }

    var name = ""
    var email = ""
    var password = ""
    var confirmPassword = ""
    /// Fields the user has left at least once; errors only show for these (or after submit).
    var touched: Set<Field> = []
    private(set) var submitAttempted = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let session: SessionStore

    init(session: SessionStore) {
        self.session = session
    }

    func error(for field: Field) -> String? {
        guard submitAttempted || touched.contains(field) else { return nil }
        return rawError(for: field)
    }

    var isValid: Bool {
        [Field.name, .email, .password, .confirm].allSatisfy { rawError(for: $0) == nil }
    }

    func submit() async {
        submitAttempted = true
        errorMessage = nil
        guard isValid, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let user = try await session.auth.signUp(
                name: name.trimmingCharacters(in: .whitespaces),
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
            session.didAuthenticate(user)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rawError(for field: Field) -> String? {
        switch field {
        case .name: Validation.name(name)
        case .email: Validation.email(email)
        case .password: Validation.newPassword(password)
        case .confirm: Validation.confirmation(confirmPassword, matches: password)
        }
    }
}

@Observable
final class SignInViewModel {
    var email = ""
    var password = ""
    private(set) var submitAttempted = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let session: SessionStore

    init(session: SessionStore) {
        self.session = session
    }

    var emailError: String? { submitAttempted ? Validation.email(email) : nil }
    var passwordError: String? { submitAttempted && password.isEmpty ? "Enter your password." : nil }

    func signIn() async {
        submitAttempted = true
        errorMessage = nil
        guard Validation.email(email) == nil, !password.isEmpty, !isLoading else { return }
        await run { try await $0.signIn(email: self.email.trimmingCharacters(in: .whitespaces), password: self.password) }
    }

    func signInWithApple() async {
        errorMessage = nil
        guard !isLoading else { return }
        await run { try await $0.signInWithApple() }
    }

    private func run(_ action: (any AuthService) async throws -> AuthUser) async {
        isLoading = true
        defer { isLoading = false }
        do {
            session.didAuthenticate(try await action(session.auth))
        } catch AuthError.cancelled {
            // User closed the Apple sheet; not an error worth showing.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@Observable
final class ForgotPasswordViewModel {
    var email: String
    private(set) var isLoading = false
    private(set) var sent = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let auth: any AuthService

    init(auth: any AuthService, email: String = "") {
        self.auth = auth
        self.email = email
    }

    func send() async {
        errorMessage = Validation.email(email)
        guard errorMessage == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await auth.sendPasswordReset(email: email.trimmingCharacters(in: .whitespaces))
            sent = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
