package org.cac.crashsafe.services.auth

import android.content.SharedPreferences
import kotlinx.coroutines.delay
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import org.cac.crashsafe.core.util.newID
import org.cac.crashsafe.model.AuthUser
import java.security.MessageDigest

/**
 * Everything the UI needs from an auth backend.
 * `MockAuthService` (offline, default); a Firebase implementation can be swapped in at `AppEnvironment.live()`.
 */
interface AuthService {
    /** A user restored from a previous session, if any. */
    suspend fun restoreSession(): AuthUser?
    suspend fun signUp(name: String, email: String, password: String): AuthUser
    suspend fun signIn(email: String, password: String): AuthUser
    /** "Continue with Google" (the iOS app's Sign in with Apple). */
    suspend fun signInWithGoogle(): AuthUser
    suspend fun sendPasswordReset(email: String)
    fun signOut()
    /** Permanently deletes the signed-in account. */
    suspend fun deleteAccount()
}

class AuthError(val kind: Kind, detail: String? = null) : Exception(detail ?: kind.message) {
    enum class Kind(val message: String) {
        emailInUse("An account with this email already exists. Try signing in."),
        userNotFound("No account found with that email."),
        wrongPassword("That password is incorrect."),
        weakPassword("Choose a password with at least 8 characters."),
        invalidEmail("That email address doesn't look right."),
        cancelled("Sign in was cancelled."),
        network("Can't reach the server. Check your connection and try again."),
        other("Something went wrong."),
    }
}

/**
 * Offline auth so the app runs with zero setup. Accounts live in SharedPreferences
 * (passwords stored as SHA-256 hashes). Not secure — for development and demos only.
 */
class MockAuthService(private val prefs: SharedPreferences, private val latencyMillis: Long = 700) : AuthService {
    @Serializable
    private data class StoredAccount(val user: AuthUser, val passwordHash: String)

    private val serializer = MapSerializer(String.serializer(), StoredAccount.serializer())

    override suspend fun restoreSession(): AuthUser? {
        val id = prefs.getString(SESSION_KEY, null) ?: return null
        return accounts().values.firstOrNull { it.user.id == id }?.user
    }

    override suspend fun signUp(name: String, email: String, password: String): AuthUser {
        delay(latencyMillis)
        val key = normalize(email)
        val all = accounts().toMutableMap()
        if (all[key] != null) throw AuthError(AuthError.Kind.emailInUse)
        if (password.length < 8) throw AuthError(AuthError.Kind.weakPassword)
        val user = AuthUser(id = newID(), name = name, email = key)
        all[key] = StoredAccount(user, hash(password))
        save(all)
        prefs.edit().putString(SESSION_KEY, user.id).apply()
        return user
    }

    override suspend fun signIn(email: String, password: String): AuthUser {
        delay(latencyMillis)
        val account = accounts()[normalize(email)] ?: throw AuthError(AuthError.Kind.userNotFound)
        if (account.passwordHash != hash(password)) throw AuthError(AuthError.Kind.wrongPassword)
        prefs.edit().putString(SESSION_KEY, account.user.id).apply()
        return account.user
    }

    /** The real Google flow needs a configured OAuth client, so the mock signs in a fixed demo user. */
    override suspend fun signInWithGoogle(): AuthUser {
        delay(latencyMillis)
        val key = "google-demo@example.com"
        val all = accounts().toMutableMap()
        val account = all[key] ?: StoredAccount(AuthUser(id = "google-demo-user", name = "Google Demo", email = key), "")
        all[key] = account
        save(all)
        prefs.edit().putString(SESSION_KEY, account.user.id).apply()
        return account.user
    }

    override suspend fun sendPasswordReset(email: String) {
        delay(latencyMillis)
        // Real backends don't reveal whether an account exists, so neither do we.
    }

    override fun signOut() {
        prefs.edit().remove(SESSION_KEY).apply()
    }

    override suspend fun deleteAccount() {
        val id = prefs.getString(SESSION_KEY, null) ?: return
        save(accounts().filterValues { it.user.id != id })
        prefs.edit().remove(SESSION_KEY).apply()
    }

    private fun accounts(): Map<String, StoredAccount> =
        prefs.getString(ACCOUNTS_KEY, null)?.let { runCatching { Json.decodeFromString(serializer, it) }.getOrNull() } ?: emptyMap()

    private fun save(accounts: Map<String, StoredAccount>) {
        prefs.edit().putString(ACCOUNTS_KEY, Json.encodeToString(serializer, accounts)).apply()
    }

    private fun normalize(email: String) = email.trim().lowercase()

    private fun hash(password: String): String =
        MessageDigest.getInstance("SHA-256").digest(password.toByteArray()).joinToString("") { "%02x".format(it) }

    private companion object {
        const val ACCOUNTS_KEY = "mockAuth.accounts"
        const val SESSION_KEY = "mockAuth.sessionUserID"
    }
}
