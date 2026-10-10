package dev.phonebridge.phonebridge

import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

internal data class UpdateManifest(val versionName: String, val versionCode: Long,
    val apkUrl: String, val sha256: String, val size: Long, val notes: String) {
    fun json(): String = JSONObject().put("schema", 1).put("versionName", versionName)
        .put("versionCode", versionCode).put("apkUrl", apkUrl).put("sha256", sha256)
        .put("size", size).put("notes", notes).toString()
}

internal class UpdateFailure(val code: String, override val message: String) : IOException(message)

/** No pairing dependencies or headers: this client only talks to update origins. */
internal class UpdateProtocol(val manifestUrl: String = OFFICIAL_MANIFEST) {
    private val fixtureOrigin: URI? = if (manifestUrl != OFFICIAL_MANIFEST) {
        URI(manifestUrl).also {
            require(it.scheme == "http" && privateIpv4(it.host) && it.userInfo == null && it.fragment == null)
        }
    } else null
    private val client = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS).callTimeout(10, TimeUnit.MINUTES)
        // Requests are public read-only GETs: recover stale pooled sockets before response.
        .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(true).build()
    @Volatile private var closed = false

    fun check(): UpdateManifest {
        val bytes = request(manifestUrl, false) { response ->
            val body = response.body ?: throw UpdateFailure("UPDATE_CHECK_FAILED", "更新服务没有返回版本信息")
            if (body.contentLength() > MAX_MANIFEST) throw UpdateFailure("INVALID_MANIFEST", "版本信息过大")
            body.byteStream().use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > MAX_MANIFEST) throw UpdateFailure("INVALID_MANIFEST", "版本信息过大")
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        }
        return parse(bytes.toString(Charsets.UTF_8))
    }

    fun parse(text: String): UpdateManifest = try {
        if (text.toByteArray(Charsets.UTF_8).size > MAX_MANIFEST) throw IllegalArgumentException()
        val json = JSONObject(text)
        fun integer(name: String): Long {
            val value = json.get(name)
            require(value is Int || value is Long)
            return (value as Number).toLong()
        }
        fun string(name: String): String = (json.get(name) as? String) ?: throw IllegalArgumentException()
        require(integer("schema") == 1L)
        val name = string("versionName")
        val code = integer("versionCode")
        val url = string("apkUrl")
        val sha = string("sha256").lowercase()
        val size = integer("size")
        val notes = string("notes")
        require(name.isNotBlank() && name.length <= 100 && code in 1..Int.MAX_VALUE.toLong())
        require(sha.matches(Regex("[a-f0-9]{64}")) && size in 1..MAX_APK && notes.length <= 16000)
        require(allowedApkUrl(url))
        UpdateManifest(name, code, url, sha, size, notes)
    } catch (_: Exception) { throw UpdateFailure("INVALID_MANIFEST", "版本信息无效，请稍后重试") }

    fun allowedApkUrl(url: String): Boolean = try {
        val uri = URI(url)
        val fixture = fixtureOrigin
        uri.userInfo == null && uri.fragment == null && uri.rawQuery == null &&
            if (fixture != null) uri.scheme == fixture.scheme && uri.host == fixture.host && uri.port == fixture.port
            else uri.scheme == "https" && uri.host == "github.com" && (uri.port == -1 || uri.port == 443) &&
                uri.rawPath.matches(Regex("/JevonsCode/phonebridge/releases/download/[^/]+/[^/]+\\.apk")) &&
                !uri.rawPath.contains('%') && uri.rawPath.split('/').none { it == "." || it == ".." }
    } catch (_: Exception) { false }

    fun download(manifest: UpdateManifest, partial: File, progress: (Long) -> Unit) {
        try {
            request(manifest.apkUrl, true) { response ->
                val body = response.body ?: throw UpdateFailure("UPDATE_DOWNLOAD_FAILED", "下载没有返回 APK")
                if (body.contentLength() >= 0 && body.contentLength() != manifest.size)
                    throw UpdateFailure("APK_LENGTH_MISMATCH", "APK 大小不符，请重新下载")
                val digest = MessageDigest.getInstance("SHA-256")
                var received = 0L
                partial.outputStream().use { output ->
                    body.byteStream().use { input ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            if (closed || Thread.currentThread().isInterrupted) throw IOException("Cancelled")
                            val count = input.read(buffer)
                            if (count < 0) break
                            received += count
                            if (received > manifest.size) throw UpdateFailure("APK_LENGTH_MISMATCH", "APK 大小不符，请重新下载")
                            output.write(buffer, 0, count)
                            digest.update(buffer, 0, count)
                            progress(received)
                        }
                    }
                }
                if (received != manifest.size) throw UpdateFailure("APK_LENGTH_MISMATCH", "APK 下载不完整，请重新下载")
                if (hex(digest.digest()) != manifest.sha256) throw UpdateFailure("APK_HASH_MISMATCH", "APK 校验失败，请重新下载")
            }
        } catch (error: Exception) { partial.delete(); throw error }
    }

    fun verifyBytes(file: File, manifest: UpdateManifest) {
        if (!file.isFile || file.length() != manifest.size) throw UpdateFailure("APK_LENGTH_MISMATCH", "APK 不完整，请重新下载")
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                if (closed || Thread.currentThread().isInterrupted) throw IOException("Cancelled")
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        if (hex(digest.digest()) != manifest.sha256) throw UpdateFailure("APK_HASH_MISMATCH", "APK 校验失败，请重新下载")
    }

    private fun <T> request(url: String, apk: Boolean, read: (okhttp3.Response) -> T): T {
        var target = url
        repeat(5) {
            if (closed) throw IOException("Cancelled")
            val call: Call = client.newCall(Request.Builder().url(target).get().build())
            call.execute().use { response ->
                if (response.code in listOf(301, 302, 303, 307, 308)) {
                    val location = response.header("Location") ?: throw IOException("Missing redirect")
                    val next = response.request.url.resolve(location)?.toString() ?: throw IOException("Invalid redirect")
                    // GitHub release downloads redirect to their asset CDN; never follow arbitrary hosts.
                    val uri = URI(next)
                    val cdn = fixtureOrigin == null && apk && uri.scheme == "https" &&
                        uri.host in setOf("release-assets.githubusercontent.com", "objects.githubusercontent.com") &&
                        (uri.port == -1 || uri.port == 443) && uri.userInfo == null && uri.fragment == null
                    if (!(apk && allowedApkUrl(next)) && !cdn)
                        throw UpdateFailure("UPDATE_REDIRECT_REJECTED", "更新服务跳转到不可信来源")
                    target = next
                } else {
                    if (!response.isSuccessful) throw UpdateFailure(if (apk) "UPDATE_DOWNLOAD_FAILED" else "UPDATE_CHECK_FAILED", "更新服务暂时不可用，请重试")
                    return read(response)
                }
            }
        }
        throw UpdateFailure("UPDATE_REDIRECT_REJECTED", "更新服务跳转次数过多")
    }

    fun close() { closed = true; client.dispatcher.cancelAll(); client.connectionPool.evictAll(); client.dispatcher.executorService.shutdown() }

    companion object {
        const val OFFICIAL_MANIFEST = "https://xn--8ovp9s.xn--m8txu.com/phonebridge/update.json"
        const val MAX_MANIFEST = 32768
        const val MAX_APK = 512L * 1024 * 1024
        fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
        fun privateIpv4(host: String?): Boolean {
            val parts = host?.split('.')?.map { it.toIntOrNull() ?: -1 } ?: return false
            return parts.size == 4 && parts.all { it in 0..255 } &&
                (parts[0] == 10 || (parts[0] == 172 && parts[1] in 16..31) || (parts[0] == 192 && parts[1] == 168))
        }
    }
}
