package org.cac.crashsafe.services.keys

import android.os.Build
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import org.cac.crashsafe.BuildConfig

/**
 * Pulse's keys for calling OpenRouter and Cartesia straight from the phone, and TomTom for speed limits. They come
 * from the git-ignored `Config/Pulse.xcconfig.local` (see `app/build.gradle.kts`), so they are in builds made on
 * this Mac and never in git. Anyone holding a build could read them, so builds shared beyond your own phones
 * should leave them out and use a server (`Backend/Dockerfile`) instead.
 */
object PulseKeys {
    fun openRouter(): String? = value(BuildConfig.PULSE_OPENROUTER_KEY)
    fun cartesia(): String? = value(BuildConfig.PULSE_CARTESIA_KEY)
    /** Used when the main Cartesia key is refused (out of credits, revoked, rate-limited). */
    fun cartesiaBackup(): String? = value(BuildConfig.PULSE_CARTESIA_BACKUP_KEY)
    /** TomTom Snap to Roads, for speed limits. */
    fun tomTom(): String? = value(BuildConfig.PULSE_TOMTOM_KEY)

    private fun value(raw: String): String? = raw.trim().takeIf { it.length >= 20 && !it.startsWith("$(") }
}

/**
 * Where the Pulse backend is: an HTTPS `PULSE_RAG_ENDPOINT`; in debug builds, the Mac itself (from the emulator,
 * 10.0.2.2) or, on a phone, the Mac over Wi-Fi (`PULSE_LAN_HOST` + `PULSE_LAN_TOKEN`, from `Backend/rag/.env`;
 * the backend runs with `serve --lan`). API keys live only on the server, never here.
 */
object PulseBackend {
    fun endpoint(): HttpUrl? {
        BuildConfig.RAG_ENDPOINT.toHttpUrlOrNull()?.takeIf { it.isHttps }?.let { return it }
        if (!BuildConfig.DEBUG) return null
        if (isEmulator) return "http://10.0.2.2:8787/".toHttpUrlOrNull()
        val host = BuildConfig.PULSE_LAN_HOST.takeIf { it.isNotBlank() } ?: return null
        token() ?: return null
        return "http://$host:8787/".toHttpUrlOrNull()
    }

    /** Lets this phone past the backend's Wi-Fi check (the Mac itself needs none). */
    fun token(): String? = BuildConfig.PULSE_LAN_TOKEN.takeIf { it.isNotBlank() && !it.startsWith("$(") }

    fun authorize(builder: Request.Builder): Request.Builder {
        token()?.let { builder.header("X-Pulse-Token", it) }
        return builder
    }

    val isEmulator: Boolean
        get() = Build.FINGERPRINT.startsWith("generic") || Build.FINGERPRINT.contains("emulator") ||
            Build.HARDWARE.contains("ranchu") || Build.HARDWARE.contains("goldfish") || Build.PRODUCT.contains("sdk")
}

fun HttpUrl.appending(path: String): HttpUrl = newBuilder().addPathSegments(path.trim('/')).build()
