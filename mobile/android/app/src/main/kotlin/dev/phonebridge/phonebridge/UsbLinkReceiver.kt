package dev.phonebridge.phonebridge

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/**
 * Receives `am broadcast` from a USB-debugging-authorized computer. The manifest requires
 * android.permission.DUMP, which ADB's shell holds and ordinary apps cannot obtain.
 * The reply carries only connection state and the app version, never pairing data.
 */
class UsbLinkReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != UsbLinkPolicy.ACTION_LINK) return
        val state = try {
            BridgeSession.usbLinkOffered(context, intent.getStringExtra("computer") ?: "", intent.getIntExtra("port", -1))
        } catch (_: Exception) { "unavailable" }
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        resultCode = Activity.RESULT_OK
        resultData = JSONObject().put("protocol", UsbLinkPolicy.PROTOCOL).put("state", state)
            .put("versionName", info.versionName ?: "").put("versionCode", info.longVersionCode).toString()
    }
}
