package dev.phonebridge.phonebridge

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.util.UUID

data class TrustedComputer(val id: String, val name: String, val pairing: TrustedPairing) {
    override fun toString() = "TrustedComputer(redacted)"
}

/** The active choice is separate from trust. Forgetting it never silently connects another computer. */
data class TrustedComputers(val entries: List<TrustedComputer> = emptyList(), val activeId: String? = null) {
    val active: TrustedComputer? get() = entries.find { it.id == activeId }

    fun remember(pairing: TrustedPairing): TrustedComputers {
        val previous = entries.find { it.pairing.endpoint == pairing.endpoint && it.pairing.token == pairing.token }
        val entry = previous?.copy(pairing = pairing)
            ?: TrustedComputer(UUID.randomUUID().toString(), hostName(pairing.endpoint), pairing)
        require(previous != null || entries.size < 16) { "At most 16 computers can be remembered." }
        return copy(entries = if (previous == null) entries + entry else entries.map { if (it.id == entry.id) entry else it },
            activeId = entry.id)
    }

    fun select(id: String): TrustedComputers {
        val entry = entries.find { it.id == id } ?: throw BridgeFailure("NO_SAVED_PAIRING", "Pair with your computer first.")
        return copy(entries = entries.map { if (it.id == id) entry.copy(pairing = entry.pairing.copy(resumeAllowed = true)) else it }, activeId = id)
    }

    fun forgetActive() = copy(entries = entries.filterNot { it.id == activeId }, activeId = null)

    fun rename(id: String, name: String): TrustedComputers {
        val trimmed = name.trim()
        require(trimmed.isNotEmpty() && trimmed.length <= 80 && trimmed.none { it.isISOControl() })
        require(entries.any { it.id == id })
        return copy(entries = entries.map { if (it.id == id) it.copy(name = trimmed) else it })
    }

    fun encode(): String = JSONObject().put("version", 2).put("activeId", activeId ?: JSONObject.NULL)
        .put("computers", JSONArray(entries.map { entry -> pairingJson(entry.pairing)
            .put("id", entry.id).put("name", entry.name) })).toString()

    companion object {
        fun hostName(endpoint: String): String = (URI(endpoint).host?.takeIf { it.isNotBlank() } ?: "Computer").take(80)

        fun decode(text: String): TrustedComputers {
            val json = JSONObject(text)
            if (json.getInt("version") == 1) {
                val pairing = pairingFrom(json)
                // Stable on repeated reads before the first successful v2 write.
                return TrustedComputers(listOf(TrustedComputer("legacy-v1", hostName(pairing.endpoint), pairing)), "legacy-v1")
            }
            require(json.getInt("version") == 2)
            val array = json.getJSONArray("computers")
            require(array.length() <= 16)
            val entries = (0 until array.length()).map {
                val entry = array.getJSONObject(it)
                val id = entry.getString("id")
                val name = entry.getString("name")
                require(id.matches(Regex("[A-Za-z0-9_-]{1,80}")))
                require(name.isNotBlank() && name.length <= 80 && name.none { char -> char.isISOControl() })
                TrustedComputer(id, name, pairingFrom(entry))
            }
            require(entries.map { it.id }.distinct().size == entries.size)
            val activeId = if (json.isNull("activeId")) null else json.getString("activeId")
            require(activeId == null || entries.any { it.id == activeId })
            return TrustedComputers(entries, activeId)
        }

        private fun pairingJson(pairing: TrustedPairing) = JSONObject().put("endpoint", pairing.endpoint)
            .put("token", pairing.token).put("allowInsecureLocal", pairing.allowInsecureLocal)
            .put("packages", JSONArray(pairing.packages)).put("actionsEnabled", pairing.actionsEnabled)
            .put("resumeAllowed", pairing.resumeAllowed)

        private fun pairingFrom(json: JSONObject): TrustedPairing {
            val packages = json.getJSONArray("packages")
            require(packages.length() in 1..64)
            return TrustedPairing(json.getString("endpoint"), json.getString("token"), json.getBoolean("allowInsecureLocal"),
                (0 until packages.length()).map { packages.getString(it) }, json.getBoolean("actionsEnabled"), json.getBoolean("resumeAllowed"))
        }
    }
}

/** Independently testable transaction boundary. A failed mutation preserves ciphertext and durable Stop. */
interface TrustedComputerPersistence {
    fun read(): TrustedComputers
    fun write(computers: TrustedComputers)
    fun markPaused()
    fun clearPaused()
    fun isPaused(): Boolean
    fun actionsPaused(): Boolean
    fun markActionsPaused()
    fun clearActionsPaused()
}

class TrustedComputerRepository(private val persistence: TrustedComputerPersistence) {
    fun list(): TrustedComputers {
        val computers = persistence.read()
        return computers.copy(entries = computers.entries.map {
            if (it.id == computers.activeId) it.copy(pairing = it.pairing.copy(
                resumeAllowed = it.pairing.resumeAllowed && !persistence.isPaused(),
                actionsEnabled = it.pairing.actionsEnabled && !persistence.actionsPaused())) else it
        })
    }

    fun mutate(update: (TrustedComputers) -> TrustedComputers): TrustedComputers {
        val next = update(list())
        persistence.markPaused()
        try {
            persistence.write(next)
            persistence.clearActionsPaused()
            if (next.active?.pairing?.resumeAllowed == true) persistence.clearPaused()
        } catch (error: Exception) {
            // Revocation must survive restart even when rewriting the encrypted collection fails.
            try { persistence.markActionsPaused() } catch (_: Exception) { }
            throw error
        }
        return next
    }
}
