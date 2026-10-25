package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class MediaReceiptPolicyTest {
    @Test fun photosAndVideoGoToGalleryCollections() {
        assertEquals(MediaReceiptPolicy.Destination("images", "Pictures/PhoneBridge/"), MediaReceiptPolicy.destination("image/png", true))
        assertEquals(MediaReceiptPolicy.Destination("video", "Movies/PhoneBridge/"), MediaReceiptPolicy.destination("video/mp4", true))
    }
    @Test fun documentsAndDisabledGalleryKeepDownloads() {
        assertEquals("downloads", MediaReceiptPolicy.destination("text/plain", true).collection)
        assertEquals("Download/PhoneBridge/", MediaReceiptPolicy.destination("video/mp4", false).relativePath)
    }

    @Test fun galleryProviderFailureKeepsTheVerifiedFileInDownloads() {
        val attempts = mutableListOf<String>()
        val actual = MediaReceiptPolicy.publish("video/mp4", true) { destination ->
            attempts.add(destination.collection)
            if (destination.collection == "video") throw IllegalStateException("gallery provider unavailable")
            destination
        }
        assertEquals(listOf("video", "downloads"), attempts)
        assertEquals(MediaReceiptPolicy.Destination("downloads", "Download/PhoneBridge/"), actual)
    }

    @Test fun downloadsFailureDoesNotPretendThereWasAnotherSuccessfulDestination() {
        var attempts = 0
        assertThrows(IllegalStateException::class.java) {
            MediaReceiptPolicy.publish("text/plain", true) { _ -> attempts++; throw IllegalStateException("disk full") }
        }
        assertEquals(1, attempts)
    }

    @Test fun clearingPendingMustActuallyPublishExactlyOneMediaItem() {
        MediaReceiptPolicy.requirePublished(1)
        for (rows in listOf(0, -1, 2)) assertThrows(IllegalStateException::class.java) { MediaReceiptPolicy.requirePublished(rows) }
    }

    @Test fun collectionQueriesPreserveVolumeAndCollectionWhenIdsCoincide() {
        assertEquals("content://media/external/images/media", MediaReceiptPolicy.collectionUri("content://media/external/images/media/42"))
        assertEquals("content://media/external/video/media", MediaReceiptPolicy.collectionUri("content://media/external/video/media/42"))
        assertEquals("content://media/external/downloads", MediaReceiptPolicy.collectionUri("content://media/external/downloads/42"))
        assertEquals("content://media/1234-5678/images/media", MediaReceiptPolicy.collectionUri("content://media/1234-5678/images/media/42"))
        assertNull(MediaReceiptPolicy.collectionUri("content://foreign/external/images/media/42"))
        assertNull(MediaReceiptPolicy.collectionUri("content://media/external/images/media/not-an-id"))
        assertNull(MediaReceiptPolicy.collectionUri("content://media/external/downloads/42?unsafe=true"))
    }

    @Test fun storedLocationUsesTheActualUriInsteadOfTheCurrentGalleryPreference() {
        assertEquals("Pictures/PhoneBridge/", MediaReceiptPolicy.storedDestination("content://media/external/images/media/1")!!.relativePath)
        assertEquals("Movies/PhoneBridge/", MediaReceiptPolicy.storedDestination("content://media/external/video/media/2")!!.relativePath)
        assertEquals("Download/PhoneBridge/", MediaReceiptPolicy.storedDestination("content://media/external/downloads/3")!!.relativePath)
    }

    @Test fun failedGalleryPreferenceWriteRestoresThePreviousEffectiveValue() {
        var effective = true
        var stored = true
        assertThrows(IllegalStateException::class.java) {
            effective = MediaReceiptPolicy.persistGalleryPreference(effective, false) { value ->
                stored = value
                false
            }
        }
        assertTrue(effective)
        assertTrue(stored)
    }
}
