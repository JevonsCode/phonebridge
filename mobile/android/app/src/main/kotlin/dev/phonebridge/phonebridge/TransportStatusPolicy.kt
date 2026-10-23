package dev.phonebridge.phonebridge

import org.json.JSONObject

object TransportStatusPolicy {
    fun message(negotiatedV2: Boolean, connected: Boolean, actionsEnabled: Boolean,
                computerId: String, ownerComputerId: String?, ownerName: String?, waitingCount: Int = 0): JSONObject? {
        if (!negotiatedV2 || !connected) return null
        return JSONObject().put("type", "status").put("readOnly", !actionsEnabled)
            .put("controlling", ownerComputerId == computerId).put("controlOwnerName", ownerName ?: "")
            .put("waitingCount", waitingCount)
    }
}
