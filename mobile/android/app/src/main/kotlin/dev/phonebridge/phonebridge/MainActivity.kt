package dev.phonebridge.phonebridge

import android.Manifest
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import okhttp3.Call
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private var controlChannel: MethodChannel? = null
    private var notificationPermissionResult: MethodChannel.Result? = null
    private val notificationPermissionRequest = 101
    private var recovery: DesktopServiceRecovery? = null
    private var recoveryCall: Call? = null
    private var recoveryResult: MethodChannel.Result? = null
    private var updater: AppUpdater? = null
    private var updateEvents: EventChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        BridgeSession.initialize(this)
        cleanUpUpdater()
        updater = AppUpdater(this)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.phonebridge/updates")
            .also { updateEvents = it }
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    updater?.observe { events.success(it) }
                }
                override fun onCancel(arguments: Any?) { updater?.observe(null) }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.phonebridge/control")
            .also { controlChannel = it }
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "status" -> result.success(BridgeSession.status())
                        "getUpdateStatus" -> result.success(updater!!.status())
                        "checkUpdate" -> updater!!.check { status, failure ->
                            if (failure == null) result.success(status)
                            else result.error(failure.code, failure.message, null)
                        }
                        "downloadUpdate" -> result.success(updater!!.download())
                        "installUpdate" -> updater!!.install { status, failure ->
                            if (failure == null) result.success(status)
                            else result.error(failure.code, failure.message, null)
                        }
                        "openAccessibilitySettings" -> {
                            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                            result.success(null)
                        }
                        "openProjectLink" -> {
                            val url = when (call.argument<String>("destination")) {
                                "github" -> "https://github.com/JevonsCode/phonebridge"
                                "website" -> "https://xn--8ovp9s.xn--m8txu.com/phonebridge/"
                                else -> throw IllegalArgumentException("Unknown project link.")
                            }
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE))
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
                                call.argument<Boolean>("remember") ?: true,
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
                        "resumeSavedConnection" -> {
                            BridgeSession.resumeSavedConnection()
                            result.success(BridgeSession.status())
                        }
                        "startDesktopService" -> startDesktopService(result)
                        "forgetSavedConnection" -> {
                            BridgeSession.forgetSavedConnection()
                            result.success(BridgeSession.status())
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: UpdateFailure) {
                    result.error(e.code, e.message, null)
                } catch (e: BridgeFailure) {
                    result.error(e.code, e.message, null)
                } catch (e: IllegalArgumentException) {
                    result.error("INVALID_ARGUMENT", e.message ?: "Invalid setting.", null)
                } catch (_: Exception) {
                    result.error("UNAVAILABLE", "Android could not complete this request.", null)
                }
            }
    }

    override fun onResume() {
        super.onResume()
        updater?.onResume()
        BridgeSession.onOwnerActivityResumed(this)
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            val status = BridgeSession.status()
            val diagnostic = JSONObject()
            listOf("savedEndpoint", "autoReconnectEnabled", "accessibilityEnabled",
                "connecting", "connected", "lastError").forEach { name ->
                diagnostic.put(name, status[name])
            }
            Log.d("PhoneBridgeConnection", "ownerResume $diagnostic")
        }
    }

    override fun onPause() {
        updater?.onPause()
        super.onPause()
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

    private fun startDesktopService(result: MethodChannel.Result) {
        if (recoveryResult != null) {
            result.error("BUSY", "正在启动电脑服务，请稍候", null)
            return
        }
        val record = BridgeSession.prepareDesktopRecovery()
        val ownerService = BridgeSession.service
        val transport = DesktopServiceRecovery()
        recovery = transport
        recoveryResult = result
        try {
            recoveryCall = transport.start(record) { failure ->
                BridgeSession.main.post {
                    if (recoveryResult !== result) return@post
                    recoveryResult = null
                    recoveryCall = null
                    recovery = null
                    transport.close()
                    try {
                        if (isFinishing || isDestroyed) throw BridgeFailure("ACTIVITY_CLOSED", "界面已关闭，请重新打开 PhoneBridge")
                        if (failure != null) throw failure
                        BridgeSession.resumeAfterDesktopRecovery(record, ownerService)
                        result.success(BridgeSession.status())
                    } catch (error: BridgeFailure) {
                        result.error(error.code, error.message, null)
                    } catch (_: Exception) {
                        result.error("DESKTOP_START_FAILED", "无法恢复连接，请检查手机权限与电脑服务", null)
                    }
                }
            }
        } catch (error: Exception) {
            recoveryResult = null
            recovery = null
            transport.close()
            throw error
        }
    }

    private fun cancelDesktopRecovery() {
        val result = recoveryResult
        recoveryResult = null
        recoveryCall?.cancel()
        recoveryCall = null
        recovery?.close()
        recovery = null
        result?.error("ACTIVITY_CLOSED", "启动请求已取消，请重新打开 PhoneBridge 后操作", null)
    }

    private fun cleanUpUpdater() {
        updater?.observe(null)
        updateEvents?.setStreamHandler(null)
        updateEvents = null
        updater?.close()
        updater = null
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        cancelPendingPermission()
        cancelDesktopRecovery()
        cleanUpUpdater()
        controlChannel?.setMethodCallHandler(null)
        controlChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        cancelPendingPermission()
        cancelDesktopRecovery()
        cleanUpUpdater()
        super.onDestroy()
    }
}
