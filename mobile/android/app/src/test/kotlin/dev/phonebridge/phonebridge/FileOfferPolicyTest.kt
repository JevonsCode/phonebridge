package dev.phonebridge.phonebridge

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class FileOfferPolicyTest {
    private fun offer() = JSONObject().put("id", "11111111-1111-4111-8111-111111111111")
        .put("name", "video.mp4").put("mimeType", "video/mp4").put("size", 1).put("sha256", "a".repeat(64))

    @Test fun hubExpiryIsConsumedWithoutChangingTheStrictFileMetadata() {
        val (file, deadline) = FileInbox.parseOffer(offer().put("expiresAt", 1793000000123L), 1000)
        assertEquals(1793000000123L, deadline)
        assertEquals("video.mp4", file.name)
        assertEquals(setOf("id", "name", "mimeType", "size", "sha256"), file.json().keys().asSequence().toSet())
    }

    @Test fun olderHubsKeepTheExistingTenMinuteFallback() {
        assertEquals(601000L, FileInbox.parseOffer(offer(), 1000).second)
    }

    @Test fun invalidExpiryAndUnknownMetadataAreRejectedBeforeAnyReceptionStarts() {
        for (value in listOf(-1, 0, 1.5, "1793000000123", JSONObject.NULL)) {
            assertThrows(IllegalArgumentException::class.java) { FileInbox.parseOffer(offer().put("expiresAt", value), 1000) }
        }
        assertThrows(IllegalArgumentException::class.java) { FileInbox.parseOffer(offer().put("url", "https://untrusted.example"), 1000) }
    }
}
