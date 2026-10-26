package org.cac.crashsafe.features.auth

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import org.cac.crashsafe.app.SessionStore
import org.cac.crashsafe.core.util.Validation
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.services.auth.AuthError
import org.cac.crashsafe.services.auth.AuthService

class SignUpViewModel(private val session: SessionStore) {
    enum class Field { fullName, email, password, confirm }

    var name by mutableStateOf("")
    var email by mutableStateOf("")
    var password by mutableStateOf("")
    var confirmPassword by mutableStateOf("")
    /** Fields the user has left at least once; errors only show for these (or after submit). */
    var touched by mutableStateOf(setOf<Field>())
    var submitAttempted by mutableStateOf(false)
        private set
    var isLoading by mutableStateOf(false)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set

    fun error(field: Field): String? = if (submitAttempted || field in touched) rawError(field) else null

    val isValid: Boolean get() = Field.entries.all { rawError(it) == null }

    suspend fun submit() {
        submitAttempted = true
        errorMessage = null
        if (!isValid || isLoading) return
        isLoading = true
        try {
            session.didAuthenticate(session.auth.signUp(name.trim(), email.trim(), password))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    private fun rawError(field: Field): String? = when (field) {
        Field.fullName -> Validation.name(name)
        Field.email -> Validation.email(email)
        Field.password -> Validation.newPassword(password)
        Field.confirm -> Validation.confirmation(confirmPassword, password)
    }
}

class SignInViewModel(private val session: SessionStore) {
    var email by mutableStateOf("")
    var password by mutableStateOf("")
    var submitAttempted by mutableStateOf(false)
        private set
    var isLoading by mutableStateOf(false)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set

    val emailError: String? get() = if (submitAttempted) Validation.email(email) else null
    val passwordError: String? get() = if (submitAttempted && password.isEmpty()) "Enter your password." else null

    suspend fun signIn() {
        submitAttempted = true
        errorMessage = null
        if (Validation.email(email) != null || password.isEmpty() || isLoading) return
        run { it.signIn(email.trim(), password) }
    }

    suspend fun signInWithGoogle() {
        errorMessage = null
        if (isLoading) return
        run { it.signInWithGoogle() }
    }

    private suspend fun run(action: suspend (AuthService) -> AuthUser) {
        isLoading = true
        try {
            session.didAuthenticate(action(session.auth))
        } catch (e: CancellationException) {
            throw e
        } catch (e: AuthError) {
            // Closing the Google sheet isn't an error worth showing.
            if (e.kind != AuthError.Kind.cancelled) errorMessage = e.message
        } catch (e: Exception) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }
}

class ForgotPasswordViewModel(private val auth: AuthService, email: String = "") {
    var email by mutableStateOf(email)
    var isLoading by mutableStateOf(false)
        private set
    var sent by mutableStateOf(false)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set

    suspend fun send() {
        errorMessage = Validation.email(email)
        if (errorMessage != null) return
        isLoading = true
        try {
            auth.sendPasswordReset(email.trim())
            sent = true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }
}
