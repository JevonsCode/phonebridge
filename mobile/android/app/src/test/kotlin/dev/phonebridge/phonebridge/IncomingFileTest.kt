package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

class IncomingFileTest {
    private val bytes = "图片传输".toByteArray()
    private fun offer() = JSONObject().put("id", "11111111-1111-4111-8111-111111111111")
        .put("name", "图片.png").put("size", bytes.size).put("mimeType", "image/png")
        .put("sha256", MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
    @Test fun verifiedBytesCanBeShared() {
        val file = IncomingFile.parse(offer()); val out = ByteArrayOutputStream()
        file.copyVerified(ByteArrayInputStream(bytes), out)
        assertArrayEquals(bytes, out.toByteArray())
    }
    @Test fun untrustedMetadataCannotSelectPathsOrOversizedFiles() {
        for (name in listOf("../secret", "dir/file", "a\\b", ".", "..", "bad\nname")) {
            assertThrows(IllegalArgumentException::class.java) { IncomingFile.parse(offer().put("name", name)) }
        }
        assertThrows(IllegalArgumentException::class.java) { IncomingFile.parse(offer().put("size", IncomingFile.MAX_BYTES + 1)) }
        assertThrows(IllegalArgumentException::class.java) { IncomingFile.parse(offer().put("url", "https://evil.example")) }
    }
    @Test fun truncatedOverflowAndModifiedFilesAreRejected() {
        val file = IncomingFile.parse(offer())
        for (data in listOf(bytes.dropLast(1).toByteArray(), bytes + byteArrayOf(1), ByteArray(bytes.size))) {
            assertThrows(IllegalArgumentException::class.java) { file.copyVerified(ByteArrayInputStream(data), ByteArrayOutputStream()) }
        }
    }
}
