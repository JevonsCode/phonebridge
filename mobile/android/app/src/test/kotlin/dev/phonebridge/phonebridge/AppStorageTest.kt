package dev.phonebridge.phonebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class AppStorageTest {
    private fun cache() = Files.createTempDirectory("cache").toFile().apply {
        resolve("updates").mkdirs(); resolve("updates/update.apk").writeBytes(ByteArray(300))
        resolve("mlkit").mkdirs(); resolve("mlkit/model.bin").writeBytes(ByteArray(200))
        resolve("loose.tmp").writeBytes(ByteArray(50))
    }

    @Test fun clearingCacheKeepsAnUpdateTheUpdaterStillNeeds() {
        val dir = cache()
        assertEquals(550, AppStorage.bytes(dir))
        assertEquals(250, AppStorage.clear(dir, keepUpdates = true))
        assertTrue(dir.resolve("updates/update.apk").isFile)
        assertFalse(dir.resolve("mlkit").exists())
        assertFalse(dir.resolve("loose.tmp").exists())
        dir.deleteRecursively()
    }

    @Test fun clearingCacheRemovesUpdatesWhenIdle() {
        val dir = cache()
        assertEquals(550, AppStorage.clear(dir, keepUpdates = false))
        assertEquals(0, AppStorage.bytes(dir))
        assertTrue("the cache directory itself stays", dir.isDirectory)
        dir.deleteRecursively()
    }

    @Test fun visibleFolderIsUnderDownloads() {
        assertEquals("Download/PhoneBridge/", AppStorage.relativePath)
    }
}
