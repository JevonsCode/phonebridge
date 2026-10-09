package dev.phonebridge.phonebridge

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var controlChannel: MethodChannel? = null
    private var notificationPermissionResult: MethodChannel.Result? = null
    private val notificationPermissionRequest = 101

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.phonebridge/control")
            .also { controlChannel = it }
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "status" -> result.success(BridgeSession.status())
                        "openAccessibilitySettings" -> {
                            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                            result.success(null)
                        }
                        "requestNotificationPermission" -> {
                            requestNotificationPermission(result)
                        }
                        "connect" -> {
                            BridgeSession.connect(
                                call.argument<String>("endpoint") ?: "",
                                call.argument<String>("token") ?: "",
                                call.argument<Boolean>("allowInsecureLocal") == true,
                                call.argument<List<String>>("packages") ?: listOf(packageName, "com.tencent.mm"),
                            )
                            result.success(BridgeSession.status())
                        }
                        "setActionsEnabled" -> {
                            BridgeSession.setActionsEnabled(call.argument<Boolean>("enabled") == true)
                            result.success(BridgeSession.status())
                        }
                        "disconnect" -> {
                            BridgeSession.disconnect()
                            result.success(BridgeSession.status())
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: BridgeFailure) {
                    result.error(e.code, e.message, null)
                } catch (e: IllegalArgumentException) {
                    result.error("INVALID_ARGUMENT", e.message ?: "Invalid setting.", null)
                } catch (_: Exception) {
                    result.error("UNAVAILABLE", "Android could not complete this request.", null)
                }
            }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (notificationPermissionResult != null) {
            result.error("BUSY", "A notification permission request is already open.", null)
            return
        }
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            result.success(null)
            return
        }
        notificationPermissionResult = result
        try {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationPermissionRequest)
        } catch (error: Exception) {
            notificationPermissionResult = null
            throw error
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != notificationPermissionRequest) return
        val result = notificationPermissionResult ?: return
        notificationPermissionResult = null
        val index = permissions.indexOf(Manifest.permission.POST_NOTIFICATIONS)
        if (index >= 0 && grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED) {
            result.success(null)
        } else {
            result.error("NOTIFICATIONS_DISABLED",
                "Notification permission was denied or cancelled. Allow notifications before connecting.", null)
        }
    }

    private fun cancelPendingPermission() {
        val result = notificationPermissionResult ?: return
        notificationPermissionResult = null
        result.error("ACTIVITY_CLOSED", "The permission request was interrupted. Open PhoneBridge and try again.", null)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        cancelPendingPermission()
        controlChannel?.setMethodCallHandler(null)
        controlChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        cancelPendingPermission()
        super.onDestroy()
    }
}
