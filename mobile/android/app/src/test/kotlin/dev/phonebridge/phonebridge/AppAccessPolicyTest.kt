package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class AppAccessPolicyTest {
    @Test fun packageValidationHasNoAppCountCeiling() {
        AppAccessPolicy.requirePackages((0 until 300).map { "com.example.app$it" })
    }

    @Test fun emptyOrMalformedPackagesRemainInvalid() {
        for (packages in listOf(emptyList(), listOf("invalid"), listOf("com.example.bad-name"),
                listOf("com." + "a".repeat(252)))) {
            try { AppAccessPolicy.requirePackages(packages); fail("Expected invalid package rejection") }
            catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun switchedComputerOrChangedGenerationOrGrantsRejectsStaleEditor() {
        val original = listOf("com.android.chrome")
        for ((id, revision, packages) in listOf(
            Triple("other", 4L, original), Triple("mac", 5L, original),
            Triple("mac", 4L, listOf("com.tencent.mm")))) {
            try {
                AppAccessPolicy.requireSnapshot("mac", 4L, original, id, revision, packages)
                fail("Expected stale editor rejection")
            } catch (e: BridgeFailure) { assertEquals("POLICY_CHANGED", e.code) }
        }
        AppAccessPolicy.requireSnapshot("mac", 4L, original, "mac", 4L, original)
    }

    @Test fun ownerAuthorizationScreenBlocksRemoteReadAndWriteOnlyWhileProtectionIsEnabled() {
        for (editorOpen in listOf(false, true)) for (protection in listOf(false, true)) {
            val blocked = AppAccessPolicy.blocksRemote(editorOpen, protection)
            assertEquals(editorOpen && protection, blocked)
            for (mutation in listOf(false, true)) {
                if (blocked) {
                    assertEquals("OWNER_AUTHORIZATION", assertThrows(BridgeFailure::class.java) {
                        OperationPolicy.requireSession(true, true, true, true, true, mutation, blocked)
                    }.code)
                } else OperationPolicy.requireSession(true, true, true, true, true, mutation, blocked)
            }
        }
    }
}
