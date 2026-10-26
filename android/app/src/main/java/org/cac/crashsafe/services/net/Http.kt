package org.cac.crashsafe.services.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** One response, read fully (bodies here are small JSON or a short audio clip). */
class HttpResult(val status: Int, val body: ByteArray, val contentType: String?, val headers: Map<String, String>) {
    val text: String get() = body.toString(Charsets.UTF_8)
    val isOK: Boolean get() = status == 200
}

object Http {
    const val userAgent = "CrashSafe/0.1 (Congressional App Challenge student project)"

    val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }

    private val base: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .build()
    }

    /** A client with an overall time limit per call (like URLSession's resource timeout). */
    fun client(timeoutSeconds: Double): OkHttpClient =
        base.newBuilder().callTimeout((timeoutSeconds * 1000).toLong(), TimeUnit.MILLISECONDS).build()

    fun jsonBody(text: String): RequestBody = text.toRequestBody("application/json".toMediaType())

    fun formBody(text: String): RequestBody = text.toRequestBody("application/x-www-form-urlencoded".toMediaType())

    /** Runs the request off the main thread; cancels the call if the coroutine is cancelled. */
    suspend fun send(request: Request, client: OkHttpClient = base, maxBytes: Long = 4_000_000): HttpResult = withContext(Dispatchers.IO) {
        val call = client.newCall(request.newBuilder().header("User-Agent", userAgent).build())
        val response = call.await()
        response.use { r ->
            val body = r.body?.let { b ->
                val bytes = b.byteStream().readNBytesCompat(maxBytes)
                bytes
            } ?: ByteArray(0)
            HttpResult(r.code, body, r.header("Content-Type"), r.headers.toMap())
        }
    }

    private suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
        enqueue(object : Callback {
            override fun onResponse(call: Call, response: Response) = continuation.resume(response)
            override fun onFailure(call: Call, e: IOException) {
                if (!continuation.isCancelled) continuation.resumeWithException(e)
            }
        })
        continuation.invokeOnCancellation { runCatching { cancel() } }
    }

    private fun java.io.InputStream.readNBytesCompat(max: Long): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        var total = 0L
        while (true) {
            val n = read(buffer)
            if (n < 0) break
            total += n
            if (total > max) throw IOException("response too large")
            out.write(buffer, 0, n)
        }
        return out.toByteArray()
    }
}
