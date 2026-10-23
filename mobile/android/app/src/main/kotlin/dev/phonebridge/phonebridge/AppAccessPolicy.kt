package dev.phonebridge.phonebridge

/** Compare-and-set boundary for a local editor; an old screen never changes new trust. */
object AppAccessPolicy {
    fun requireSnapshot(expectedId: String, expectedRevision: Long, expectedPackages: List<String>,
                        currentId: String, currentRevision: Long, currentPackages: List<String>) {
        if (expectedId != currentId || expectedRevision != currentRevision ||
            expectedPackages.toSet() != currentPackages.toSet()) {
            throw BridgeFailure("POLICY_CHANGED", "Connection or app access changed. Reopen the app list.")
        }
    }
}
