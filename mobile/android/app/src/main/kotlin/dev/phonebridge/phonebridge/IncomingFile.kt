package dev.phonebridge.phonebridge

import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

data class IncomingFile(val id: String, val name: String, val mimeType: String, val size: Long, val sha256: String) {
    fun json() = JSONObject().put("id", id).put("name", name).put("mimeType", mimeType).put("size", size).put("sha256", sha256)
    fun copyVerified(input: InputStream, output: OutputStream) {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024); var count = 0L
        while (true) {
            val read = input.read(buffer); if (read < 0) break
            count += read
            require(count <= size && count <= MAX_BYTES) { "File exceeded its declared size." }
            digest.update(buffer, 0, read); output.write(buffer, 0, read)
        }
        require(count == size && digest.digest().joinToString("") { "%02x".format(it) } == sha256) { "File size or checksum did not match." }
    }
    companion object {
        const val MAX_BYTES = 50L * 1024 * 1024
        fun parse(value: JSONObject): IncomingFile {
            require(value.keys().asSequence().toSet() == setOf("id", "name", "mimeType", "size", "sha256"))
            val id = value.get("id") as String
            val name = value.get("name") as String
            val mime = value.get("mimeType") as String
            val rawSize = value.get("size")
            require(rawSize is Int || rawSize is Long)
            val size = (rawSize as Number).toLong()
            val hash = value.get("sha256") as String
            require(id.matches(Regex("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}")))
            require(name.length in 1..180 && name != "." && name != ".." && name.none { it == '/' || it == '\\' || it.isISOControl() })
            require(mime.length <= 100 && mime.matches(Regex("[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*")))
            require(size in 1..MAX_BYTES && hash.matches(Regex("[0-9a-f]{64}")))
            return IncomingFile(id, name, mime, size, hash)
        }
    }
}
