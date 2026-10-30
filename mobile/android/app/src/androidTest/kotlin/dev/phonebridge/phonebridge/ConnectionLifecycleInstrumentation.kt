package dev.phonebridge.phonebridge

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.SystemClock

/** Fresh-emulator-only fixture; never installed in the release APK or run on an owner's phone. */
class ConnectionLifecycleInstrumentation : Instrumentation() {
    private var confirmed = false
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        confirmed = arguments?.getString("confirmIsolatedEmulator") == "JVS-A-usability"
        start()
    }
    override fun onStart() {
        val result = Bundle()
        try {
            check(confirmed && Build.HARDWARE in setOf("ranchu", "goldfish")) { "Isolated emulator required" }
            val store = TrustedPairingStore(targetContext)
            check(store.read().entries.isEmpty()) { "Fixture requires a fresh install without saved pairings" }
            val fixture = TrustedComputers()
                .remember(TrustedPairing("ws://10.0.2.2:8885/device", "a".repeat(32), true, listOf(targetContext.packageName), false, true))
                .remember(TrustedPairing("ws://10.0.2.2:8886/device", "b".repeat(32), true, listOf(targetContext.packageName), false, true))
            store.write(fixture)
            var activity = startActivitySync(Intent(targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            // The host enables this test app's accessibility service only on this disposable emulator.
            waitFor { BridgeSession.status()["connectedComputerCount"] == 2 }
            var originalService: PhoneAccessibilityService? = null
            runOnMainSync {
                originalService = BridgeSession.service
                check(BridgeSession.status()["accessibilityAuthorized"] == true)
                check(originalService?.foregroundProtected == true)
            }
            val paired = store.read()
            check(paired.entries.all { it.systemName == "macOS" })
            repeat(3) {
                runOnMainSync { activity.finish() }
                waitForIdleSync()
                activity = startActivitySync(Intent(targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                waitFor { BridgeSession.status()["connectedComputerCount"] == 2 }
                runOnMainSync {
                    check(BridgeSession.service === originalService)
                    check(BridgeSession.status()["accessibilityAuthorized"] == true)
                    check(BridgeSession.service?.foregroundProtected == true)
                }
                check(store.read() == paired)
            }
            result.putInt("connectedComputers", 2)
            result.putInt("activityRestarts", 3)
            result.putBoolean("authorizationRetained", true)
            result.putBoolean("foregroundProtected", true)
            result.putBoolean("computerSystemsPersisted", true)
            runOnMainSync {
                BridgeSession.disconnect()
                check(BridgeSession.service?.foregroundProtected == false)
                check(BridgeSession.status()["connectedComputerCount"] == 0)
            }
            result.putBoolean("pauseStopsConnectionsAndForeground", true)
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            result.putString("failure", "${error.javaClass.simpleName}: ${error.message}")
            finish(Activity.RESULT_CANCELED, result)
        }
    }
    private fun waitFor(check: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 45_000
        while (SystemClock.elapsedRealtime() < deadline) {
            var ready = false
            runOnMainSync { ready = check() }
            if (ready) return
            Thread.sleep(100)
        }
        error("Timed out waiting for test connections")
    }
}
