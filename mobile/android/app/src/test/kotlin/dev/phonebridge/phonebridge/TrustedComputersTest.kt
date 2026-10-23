package dev.phonebridge.phonebridge

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class TrustedComputersTest {
    @Test fun forgettingAnotherComputerPreservesActiveTrustAndPermissions() {
        val first = TrustedComputers().remember(pairing())
        val both = first.remember(pairing("b".repeat(32), false))
        val remaining = both.forget(first.activeId!!)
        assertEquals(both.activeId, remaining.activeId)
        assertEquals(both.active, remaining.active)
        assertEquals(listOf(both.active!!), remaining.entries)
        assertEquals(remaining, TrustedComputers.decode(remaining.encode()))
    }

    @Test fun forgettingExplicitActiveIdNeverSelectsAnotherComputer() {
        val both = TrustedComputers().remember(pairing()).remember(pairing("b".repeat(32)))
        val remaining = both.forget(both.activeId!!)
        assertNull(remaining.activeId)
        assertEquals(listOf(both.entries.first()), remaining.entries)
    }

    @Test fun forgettingUnknownIdDoesNotDeleteActiveComputer() {
        val original = TrustedComputers().remember(pairing())
        try { original.forget("missing"); fail("Expected rejection") }
        catch (_: IllegalArgumentException) { }
        assertNotNull(original.active)
        assertEquals(1, original.entries.size)
    }

    @Test fun longValidHostnamesCannotMakeWrittenCatalogUnreadable() {
        val endpoint = EndpointPolicy.validate("wss://" + "a".repeat(60) + "." + "b".repeat(30) + ".com/device", false)
        val initial = TrustedComputers().remember(pairing())
        val added = initial.remember(pairing("b".repeat(32)).copy(endpoint = endpoint, allowInsecureLocal = false))
        assertEquals(80, added.active!!.name.length)
        val restored = TrustedComputers.decode(added.encode())
        assertEquals(added, restored)
        assertEquals(initial.entries.single(), restored.entries.first())
        val legacy = JSONObject().put("version", 1).put("endpoint", endpoint).put("token", pairing().token)
            .put("allowInsecureLocal", false).put("packages", org.json.JSONArray(pairing().packages))
            .put("actionsEnabled", true).put("resumeAllowed", true).toString()
        val migrated = TrustedComputers.decode(legacy)
        assertEquals(80, migrated.active!!.name.length)
        assertEquals(migrated, TrustedComputers.decode(migrated.encode()))
    }

    private fun pairing(token: String = "a".repeat(32), actions: Boolean = true, resume: Boolean = true) =
        TrustedPairing("ws://192.168.1.10:8765/device", token, true, listOf("com.tencent.mm"), actions, resume)

    @Test fun migratesLegacyWithoutLosingTrustOrPermission() {
        val json = JSONObject().put("version", 1).put("endpoint", pairing().endpoint).put("token", pairing().token)
            .put("allowInsecureLocal", true).put("packages", org.json.JSONArray(pairing().packages))
            .put("actionsEnabled", true).put("resumeAllowed", false).toString()
        val migrated = TrustedComputers.decode(json)
        assertEquals("legacy-v1", migrated.activeId)
        assertEquals(pairing(resume = false), migrated.active!!.pairing)
        assertEquals("192.168.1.10", migrated.active!!.name)
        assertEquals(migrated, TrustedComputers.decode(migrated.encode()))
    }

    @Test fun roundTripRetainsIndependentChoicesAndNames() {
        val first = TrustedComputers().remember(pairing())
        val second = first.remember(pairing("b".repeat(32), false, false).copy(packages = listOf("com.example.second"), allowInsecureLocal = false))
        val named = second.rename(first.activeId!!, "工作电脑").select(first.activeId!!)
        assertEquals(named, TrustedComputers.decode(named.encode()))
        assertTrue(named.active!!.pairing.actionsEnabled)
        assertEquals("工作电脑", named.active!!.name)
        val other = named.entries.last().pairing
        assertFalse(other.actionsEnabled)
        assertFalse(other.resumeAllowed)
        assertFalse(other.allowInsecureLocal)
        assertEquals(listOf("com.example.second"), other.packages)
    }

    @Test fun sameEndpointWithDifferentTokensIsDistinctWhileSameIdentityUpdatesInPlace() {
        val first = TrustedComputers().remember(pairing())
        val second = first.remember(pairing("b".repeat(32)))
        assertEquals(2, second.entries.size)
        assertNotEquals(first.activeId, second.activeId)
        val updated = second.remember(pairing(actions = false))
        assertEquals(first.activeId, updated.activeId)
        assertEquals(2, updated.entries.size)
        assertFalse(updated.active!!.pairing.actionsEnabled)
        assertTrue(updated.entries.last().pairing.actionsEnabled)
    }

    @Test fun forgettingSelectedPreservesOtherTrustWithoutSelectingIt() {
        val first = TrustedComputers().remember(pairing())
        val second = first.remember(pairing("b".repeat(32)))
        val forgotten = second.forgetActive()
        assertNull(forgotten.activeId)
        assertNull(forgotten.active)
        assertEquals(first.entries, forgotten.entries)
        assertEquals(forgotten, TrustedComputers.decode(forgotten.encode()))
    }

    @Test fun stopSurvivesRestartAndSelectingResumesOnlyThatComputer() {
        val backend = MemoryPersistence(TrustedComputers().remember(pairing()).remember(pairing("b".repeat(32), false)))
        backend.markPaused()
        val loaded = TrustedComputerRepository(backend).list()
        assertFalse(loaded.active!!.pairing.resumeAllowed)
        assertFalse(loaded.entries.first().pairing.resumeAllowed)
        val selected = TrustedComputerRepository(backend).mutate { it.select(it.entries.first().id) }
        assertTrue(selected.active!!.pairing.resumeAllowed)
        assertFalse(selected.entries.last().pairing.resumeAllowed)
        assertFalse(backend.paused)
    }

    @Test fun failedSavePreservesEveryIdentityAndDurablyBlocksBootResume() {
        val original = TrustedComputers().remember(pairing()).remember(pairing("b".repeat(32)))
        val backend = MemoryPersistence(original).apply { failWrite = true }
        try {
            TrustedComputerRepository(backend).mutate { it.forgetActive() }
            fail("Expected failed write")
        } catch (_: java.io.IOException) { }
        assertEquals(original, backend.stored)
        assertTrue(backend.paused)
        assertFalse(TrustedComputerRepository(backend).list().active!!.pairing.resumeAllowed)
        assertFalse(TrustedComputerRepository(backend).list().active!!.pairing.actionsEnabled)
        assertEquals(2, TrustedComputerRepository(backend).list().entries.size)
        assertFalse(TrustedComputerRepository(backend).list().entries.first().pairing.actionsEnabled)
        backend.failWrite = false
        val afterSwitch = TrustedComputerRepository(backend).mutate { it.select(it.entries.first().id) }
        assertFalse(afterSwitch.active!!.pairing.actionsEnabled)
        assertFalse(afterSwitch.entries.last().pairing.actionsEnabled)
    }

    @Test fun rejectsCorruptCatalogRatherThanDiscardingOtherRecords() {
        val good = TrustedComputers().remember(pairing())
        for (json in listOf(
            JSONObject(good.encode()).put("version", 3),
            JSONObject(good.encode()).put("activeId", "missing"),
            JSONObject(good.encode()).also { it.getJSONArray("computers").put(it.getJSONArray("computers").getJSONObject(0)) },
        )) {
            try { TrustedComputers.decode(json.toString()); fail("Expected rejection") }
            catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun switchingInvalidatesAuthorityButRetainsFenceUntilActualCompletion() {
        val scope = SessionOperationScope()
        assertTrue(scope.begin("request-1"))
        val firstGeneration = scope.generation
        assertFalse(scope.begin("request-2"))
        scope.invalidate()
        assertEquals("request-1", scope.pending)
        assertFalse(scope.isCurrent(firstGeneration))
        assertFalse(scope.begin("request-1"))
        assertTrue(scope.complete("request-1", firstGeneration))
        assertTrue(scope.begin("request-1"))
        assertFalse(scope.complete("request-1", firstGeneration))
        assertEquals("request-1", scope.pending)
        assertTrue(scope.complete("request-1", scope.generation))
        assertNull(scope.pending)
        assertFalse(scope.complete("request-1", scope.generation))
    }

    private class MemoryPersistence(var stored: TrustedComputers) : TrustedComputerPersistence {
        var paused = false
        var failWrite = false
        var failedActions = false
        override fun read() = TrustedComputers.decode(stored.encode())
        override fun write(computers: TrustedComputers) {
            if (failWrite) throw java.io.IOException("disk full")
            stored = TrustedComputers.decode(computers.encode())
        }
        override fun markPaused() { paused = true }
        override fun clearPaused() { paused = false }
        override fun isPaused() = paused
        override fun actionsPaused() = failedActions
        override fun markActionsPaused() { failedActions = true }
        override fun clearActionsPaused() { failedActions = false }
    }
}
