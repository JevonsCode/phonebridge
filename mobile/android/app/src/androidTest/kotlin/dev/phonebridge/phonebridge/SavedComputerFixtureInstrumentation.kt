package dev.phonebridge.phonebridge

import android.app.Activity
import android.app.Instrumentation
import android.content.pm.ApplicationInfo
import android.os.Bundle
import java.net.URI

/**
 * Explicit, test-APK-only fixture setup for an already paired debug application.
 * Never prints, exports, or accepts a credential. No activity/service is launched.
 *
 * Required args: fixtureAction=seed|inspect|restorePrimary|cleanup|resumePrimaryAfterFixtureRemoval,
 * confirmSavedPairingFixture=local-secondary-endpoint,
 * primaryEndpoint=<existing endpoint>, fixtureEndpoint=<same-host/different-port endpoint>.
 * An omitted/unknown action fails without writing. Generic connected tests cannot mutate trust.
 * Running instrumentation may restart the target process; OEM Accessibility behavior is
 * not guaranteed. This runner deliberately makes no force-stop or shell input calls.
 */
class SavedComputerFixtureInstrumentation : Instrumentation() {
    private lateinit var arguments: Bundle

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        this.arguments = arguments ?: Bundle()
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            check(targetContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
            check(arguments.getString("confirmSavedPairingFixture") == "local-secondary-endpoint")
            val action = arguments.getString("fixtureAction")
            check(action in setOf("seed", "inspect", "restorePrimary", "cleanup", "resumePrimaryAfterFixtureRemoval"))
            val primaryEndpoint = requireNotNull(arguments.getString("primaryEndpoint"))
            val fixtureEndpoint = requireNotNull(arguments.getString("fixtureEndpoint"))
            checkLocalEndpoints(primaryEndpoint, fixtureEndpoint)

            val store = TrustedPairingStore(targetContext)
            val before = store.read()
            val primary = before.entries.singleOrNull { it.pairing.endpoint == primaryEndpoint }
                ?: error("Primary record required")
            val fixture = before.entries.singleOrNull { it.id == FIXTURE_ID }
            // Never overwrite or delete an unrelated record occupying our fixture identity.
            if (fixture != null) {
                check(fixture.name == FIXTURE_NAME)
                check(fixture.pairing.endpoint == fixtureEndpoint)
                check(fixture.pairing.token == primary.pairing.token)
            }
            val paused = store.isPaused()
            val actionsPaused = store.actionsPaused()
            val next = when (action) {
                "seed" -> {
                    check(before.activeId == primary.id)
                    check(primary.pairing.allowInsecureLocal)
                    if (fixture == null) {
                        check(before.entries.size < 16)
                        check(before.entries.none { it.pairing.endpoint == fixtureEndpoint })
                        before.copy(entries = before.entries + TrustedComputer(
                            FIXTURE_ID, FIXTURE_NAME,
                            primary.pairing.copy(endpoint = fixtureEndpoint, actionsEnabled = true)))
                    } else before // Re-running setup preserves any per-computer UI choices.
                }
                "restorePrimary" -> before.copy(activeId = primary.id)
                "resumePrimaryAfterFixtureRemoval" -> {
                    check(fixture == null && before.entries.none { it.pairing.endpoint == fixtureEndpoint })
                    check(before.activeId == null || before.activeId == primary.id)
                    check(paused && !actionsPaused && primary.pairing.resumeAllowed)
                    before.copy(activeId = primary.id)
                }
                "cleanup" -> before.copy(
                    entries = before.entries.filterNot { it.id == FIXTURE_ID }, activeId = primary.id)
                else -> before
            }
            // Fixture plumbing preserves durable Stop markers and every primary permission.
            // Selection / Forget behavior must be verified through the app separately.
            if (action == "resumePrimaryAfterFixtureRemoval") {
                // Same persistence operation used by BridgeSession.selectComputer. No fake
                // Accessibility service, transport launch, or claim of UI resume coverage.
                store.select(primary.id)
            } else if (next != before) store.write(next)
            val after = store.read()
            check(after == next)
            check(after.entries.single { it.id == primary.id } == primary)
            if (action == "restorePrimary" || action == "resumePrimaryAfterFixtureRemoval")
                check(after.entries == before.entries)
            val expectedPaused = if (action == "resumePrimaryAfterFixtureRemoval") false else paused
            check(store.isPaused() == expectedPaused && store.actionsPaused() == actionsPaused)
            val remainingFixture = after.entries.singleOrNull { it.id == FIXTURE_ID }
            result.putString("fixtureResult", "passed")
            result.putString("fixtureAction", action)
            result.putInt("savedComputers", after.entries.size)
            result.putBoolean("primaryActive", after.activeId == primary.id)
            result.putBoolean("fixtureActive", after.activeId == FIXTURE_ID)
            result.putBoolean("fixturePresent", remainingFixture != null)
            result.putBoolean("primaryHasLegacyIdentity", primary.id == "legacy-v1")
            result.putBoolean("legacyCollectionRewritten", primary.id == "legacy-v1" && next != before)
            result.putBoolean("primaryActionsEnabled", primary.pairing.actionsEnabled)
            result.putBoolean("fixtureActionsEnabled", remainingFixture?.pairing?.actionsEnabled == true)
            result.putInt("primaryPackages", primary.pairing.packages.size)
            result.putInt("fixturePackages", remainingFixture?.pairing?.packages?.size ?: 0)
            result.putBoolean("automaticResumePaused", store.isPaused())
            result.putBoolean("actionsPaused", actionsPaused)
            finish(Activity.RESULT_OK, result)
        } catch (_: Throwable) {
            // Exceptions can include sensitive JSON from decoding. Never expose their text/stack.
            result.putString("fixtureResult", "failed-precondition-or-verification")
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    private fun checkLocalEndpoints(primaryText: String, fixtureText: String) {
        val primary = URI(primaryText)
        val fixture = URI(fixtureText)
        check(primary.scheme == "ws" && fixture.scheme == "ws")
        check(primary.host == fixture.host && privateIpv4(primary.host))
        check(primary.port in 1..65535 && fixture.port in 1..65535 && primary.port != fixture.port)
        check(primary.path == "/device" && fixture.path == "/device")
        check(primary.userInfo == null && fixture.userInfo == null)
        check(primary.query == null && fixture.query == null)
        check(primary.fragment == null && fixture.fragment == null)
    }

    private fun privateIpv4(host: String?): Boolean {
        val parts = host?.split('.')?.map { it.toIntOrNull() ?: -1 } ?: return false
        return parts.size == 4 && parts.all { it in 0..255 } &&
            (parts[0] == 10 || (parts[0] == 172 && parts[1] in 16..31) ||
                (parts[0] == 192 && parts[1] == 168))
    }

    companion object {
        private const val FIXTURE_ID = "instrumentation-secondary-endpoint"
        private const val FIXTURE_NAME = "PhoneBridge local endpoint fixture"
    }
}
