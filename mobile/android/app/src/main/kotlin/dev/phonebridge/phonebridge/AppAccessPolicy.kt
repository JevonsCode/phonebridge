package dev.phonebridge.phonebridge

/** Compare-and-set boundary for a local editor; an old screen never changes new trust. */
object AppAccessPolicy {
    private val packageName = Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")

    fun blocksRemote(editorOpen: Boolean, protectConnectionControls: Boolean): Boolean =
        editorOpen && protectConnectionControls

    fun requirePackages(packages: List<String>) {
        require(packages.isNotEmpty() && packages.all { it.length <= 255 && packageName.matches(it) }) {
            "Select at least one app with a valid package name."
        }
    }

    fun requireSnapshot(expectedId: String, expectedRevision: Long, expectedPackages: List<String>,
                        currentId: String, currentRevision: Long, currentPackages: List<String>) {
        if (expectedId != currentId || expectedRevision != currentRevision ||
            expectedPackages.toSet() != currentPackages.toSet()) {
            throw BridgeFailure("POLICY_CHANGED", "Connection or app access changed. Reopen the app list.")
        }
    }
}
