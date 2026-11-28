package dev.phonebridge.phonebridge

import android.Manifest
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.MotionEvent
import android.view.KeyEvent
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
    private companion object {
        /** Process-wide: the DUMP-protected alias hands the request to the regular owner task. */
        var pendingUsbPairing: Map<String, Any>? = null
        const val FORWARDED_USB_PAIRING = "dev.phonebridge.phonebridge.FORWARDED_USB_PAIRING"
    }

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
                        "getTapJitter" -> result.success(AutomationPreferences.tapJitter(this))
                        "setTapJitter" -> {
                            val enabled = call.argument<Boolean>("enabled") ?: throw IllegalArgumentException("enabled must be a boolean.")
                            AutomationPreferences.setTapJitter(this, enabled)
                            result.success(null)
                        }
                        "getRandomControlDelay" -> result.success(AutomationPreferences.randomControlDelay(this))
                        "setRandomControlDelay" -> {
                            val enabled = call.argument<Boolean>("enabled") ?: throw IllegalArgumentException("enabled must be a boolean.")
                            AutomationPreferences.setRandomControlDelay(this, enabled)
                            result.success(null)
                        }
                        "getShowControlIndicator" -> result.success(AutomationPreferences.showControlIndicator(this))
                        "setShowControlIndicator" -> {
                            val enabled = call.argument<Boolean>("enabled") ?: throw IllegalArgumentException("enabled must be a boolean.")
                            AutomationPreferences.setShowControlIndicator(this, enabled)
                            BridgeSession.refreshControlIndicator()
                            result.success(null)
                        }
                        "getClipboardAccessEnabled" -> result.success(AutomationPreferences.clipboardAccessEnabled(this))
                        "setClipboardAccessEnabled" -> {
                            val enabled = call.argument<Boolean>("enabled") ?: throw IllegalArgumentException("enabled must be a boolean.")
                            AutomationPreferences.setClipboardAccessEnabled(this, enabled)
                            result.success(null)
                        }
                        "getProtectConnectionControls" -> result.success(AutomationPreferences.protectConnectionControls(this))
                        "setProtectConnectionControls" -> {
                            val enabled = call.argument<Boolean>("enabled") ?: throw IllegalArgumentException("enabled must be a boolean.")
                            AutomationPreferences.setProtectConnectionControls(this, enabled)
                            result.success(null)
                        }
                        "getAutoReceiveFilesEnabled" -> result.success(BridgeSession.fileInbox!!.autoReceiveEnabled)
                        "setAutoReceiveFilesEnabled" -> {
                            val enabled = call.argument<Boolean>("enabled")
                                ?: throw IllegalArgumentException("enabled must be a boolean.")
                            BridgeSession.fileInbox!!.setAutoReceiveEnabled(enabled)
                            result.success(null)
                        }
                        "getSaveMediaToGallery" -> result.success(BridgeSession.fileInbox!!.saveMediaToGallery)
                        "setSaveMediaToGallery" -> {
                            BridgeSession.fileInbox!!.setSaveMediaToGallery(call.argument<Boolean>("enabled")
                                ?: throw IllegalArgumentException("enabled must be a boolean."))
                            result.success(null)
                        }
                        "allowAllAutomation" -> result.success(BridgeSession.allowAllAutomation(call.argument<String>("id")))
                        "getShowOperationTrails" -> result.success(OperationTrailPreference.enabled(this))
                        "setShowOperationTrails" -> {
                            val enabled = call.argument<Boolean>("enabled")
                                ?: throw IllegalArgumentException("enabled must be a boolean.")
                            if (!enabled) BridgeSession.service?.clearOperationTrail()
                            OperationTrailPreference.save(this, enabled)
                            result.success(null)
                        }
                        "getLanguagePreference" -> result.success(AppLanguage.preference(this))
                        "setLanguagePreference" -> {
                            AppLanguage.select(this, call.argument<String>("language") ?: "system")
                            BridgeSession.refreshNotificationLanguage()
                            result.success(null)
                        }
                        "receiveFile" -> { BridgeSession.fileInbox!!.receive(call.argument<String>("id") ?: ""); result.success(null) }
                        "declineFile" -> { BridgeSession.fileInbox!!.decline(call.argument<String>("id") ?: ""); result.success(null) }
                        "removeReceivedFile" -> { BridgeSession.fileInbox!!.remove(call.argument<String>("id") ?: ""); result.success(null) }
                        "shareFile" -> { BridgeSession.fileInbox!!.share(this, call.argument<String>("id") ?: ""); result.success(null) }
                        "storageStatus" -> result.success(BridgeSession.fileInbox!!.storage())
                        "openFilesFolder" -> {
                            AppStorage.openFolder(this, BridgeSession.fileInbox!!.storage()["downloadFiles"] != 0)
                            result.success(null)
                        }
                        "cleanupFiles" -> {
                            val days = call.argument<Int>("olderThanDays")
                            result.success(BridgeSession.fileInbox!!.cleanup(days))
                        }
                        "clearCache" -> {
                            // Keep an update that is downloading or waiting to be installed.
                            val phase = updater?.status()?.get("phase")
                            val keepUpdates = phase in setOf("downloading", "ready", "permissionRequired", "installerOpened")
                            result.success(AppStorage.clearCache(this, keepUpdates))
                        }
                        "operationHistory" -> {
                            val inbox = BridgeSession.fileInbox!!
                            if (!BridgeSession.connected) result.success(mapOf("operations" to "[]", "files" to inbox.history(), "error" to "连接电脑后可查看电脑操作日志"))
                            else inbox.readHistory(BridgeSession.fileSource()) { operations, error ->
                                result.success(mapOf("operations" to (operations ?: "[]"), "files" to inbox.history(), "error" to error))
                            }
                        }
                        "status" -> result.success(BridgeSession.status() + ("usbPairingPending" to (pendingUsbPairing != null)))
                        "takeUsbPairing" -> { result.success(pendingUsbPairing); pendingUsbPairing = null }
                        "openNotificationSettings" -> {
                            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                            result.success(null)
                        }
                        "openLiveUpdateSettings" -> {
                            val promotion = Intent("android.settings.APP_NOTIFICATION_PROMOTION_SETTINGS").putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            val target = if (promotion.resolveActivity(packageManager) != null) promotion
                                else Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            startActivity(target)
                            result.success(null)
                        }
                        "openDeveloperSettings" -> {
                            startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
                            result.success(null)
                        }
                        "getScreenAwakeMode" -> result.success(BridgeSession.getScreenAwakeMode())
                        "setScreenAwakeMode" -> {
                            BridgeSession.setScreenAwakeMode(call.argument<String>("mode") ?: "")
                            result.success(BridgeSession.status())
                        }
                        "setComputerResumeAllowed" -> {
                            BridgeSession.setComputerResumeAllowed(call.argument<String>("id") ?: "", call.argument<Boolean>("enabled") == true)
                            result.success(BridgeSession.status())
                        }
                        "getAppAccess" -> result.success(BridgeSession.getAppAccess(
                            call.argument<Boolean>("draft") == true,
                            call.argument<String>("endpoint") ?: "", call.argument<String>("token") ?: ""))
                        "closeAppAccess" -> { BridgeSession.closeAppAccess(); result.success(null) }
                        "setAllowedPackages" -> {
                            cancelDesktopRecovery()
                            result.success(BridgeSession.setAllowedPackages(
                                call.argument<String>("computerId") ?: "",
                                call.argument<Number>("permissionRevision")?.toLong() ?: -1L,
                                call.argument<List<String>>("expectedPackages") ?: emptyList(),
                                call.argument<List<String>>("packages") ?: emptyList()))
                        }
                        "listComputers" -> result.success(BridgeSession.computerList())
                        "selectComputer" -> {
                            cancelDesktopRecovery()
                            BridgeSession.selectComputer(call.argument<String>("id") ?: "")
                            result.success(BridgeSession.status())
                        }
                        "renameComputer" -> {
                            BridgeSession.renameComputer(call.argument<String>("id") ?: "", call.argument<String>("name") ?: "")
                            result.success(BridgeSession.status())
                        }
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
                            cancelDesktopRecovery()
                            BridgeSession.connect(
                                call.argument<String>("endpoint") ?: "",
                                call.argument<String>("token") ?: "",
                                call.argument<Boolean>("allowInsecureLocal") == true,
                                call.argument<List<String>>("packages") ?: listOf(packageName, "com.tencent.mm"),
                                call.argument<Boolean>("remember") ?: true,
                                call.argument<Boolean>("replaceAllowedPackages") == true,
                                call.argument<String>("name") ?: "",
                            )
                            result.success(BridgeSession.status())
                        }
                        "setActionsEnabled" -> {
                            BridgeSession.setActionsEnabled(call.argument<Boolean>("enabled") == true, call.argument<String>("id"))
                            result.success(BridgeSession.status())
                        }
                        "disconnect" -> {
                            cancelDesktopRecovery()
                            BridgeSession.disconnect()
                            result.success(BridgeSession.status())
                        }
                        "resumeSavedConnection" -> {
                            BridgeSession.resumeSavedConnection(call.argument<String>("id"))
                            result.success(BridgeSession.status())
                        }
                        "startDesktopService" -> startDesktopService(result, call.argument<String>("id"))
                        "forgetSavedConnection" -> {
                            cancelDesktopRecovery()
                            BridgeSession.forgetSavedConnection()
                            result.success(BridgeSession.status())
                        }
                        "forgetComputer" -> {
                            val id = call.argument<String>("id") ?: ""
                            if (BridgeSession.status()["activeComputerId"] == id) cancelDesktopRecovery()
                            BridgeSession.forgetComputer(id)
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

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        acceptUsbPairing(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptUsbPairing(intent)
    }

    private fun viaUsbAlias(value: Intent?) = value?.component?.className == "$packageName.UsbPairingActivity"

    /**
     * Only the DUMP-protected alias (ADB shell of a USB-debugging-authorized computer) can carry
     * a pairing request. The request only pre-fills the normal pairing form; the owner still
     * reviews the computer and confirms consent before anything connects.
     */
    private fun acceptUsbPairing(value: Intent?) {
        if (value?.getBooleanExtra(FORWARDED_USB_PAIRING, false) == true && !viaUsbAlias(value)) {
            value.removeExtra(FORWARDED_USB_PAIRING)
            if (pendingUsbPairing != null) requestOwnerUnlock()
            return
        }
        if (value?.action != UsbLinkPolicy.ACTION_PAIR || !viaUsbAlias(value)) return
        // Hand over to the regular PhoneBridge task, so the owner sees one App, not a second copy.
        forwardToOwnerTask()
        val token = value.getStringExtra("token") ?: return
        val port = value.getIntExtra("port", -1)
        val endpoint = value.getStringExtra("endpoint")
        val name = (value.getStringExtra("name") ?: "").filter { !it.isISOControl() }.take(64)
        value.removeExtra("token")
        try {
            EndpointPolicy.validateToken(token)
            require(UsbLinkPolicy.validPort(port))
            val normalized = if (endpoint.isNullOrEmpty()) UsbLinkPolicy.loopbackEndpoint(port) else EndpointPolicy.validate(endpoint, true)
            BridgeSession.initialize(this)
            BridgeSession.usbPairingOffered(token, port)
            if (BridgeSession.isKnownToken(token)) return
            pendingUsbPairing = mapOf("endpoint" to normalized, "token" to token, "name" to name)
        } catch (_: Exception) {
            Log.w("PhoneBridgeConnection", "Rejected USB pairing request.")
        }
    }

    private fun forwardToOwnerTask() {
        // Runs after the extras were read below; posting keeps the order explicit.
        BridgeSession.main.post {
            startActivity(Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(FORWARDED_USB_PAIRING, true))
            finish()
        }
    }

    /** Public API: wakes the display and asks the system to show its own unlock prompt. */
    private fun requestOwnerUnlock() {
        val keyguard = getSystemService(android.app.KeyguardManager::class.java)
        if (!keyguard.isKeyguardLocked) return
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        keyguard.requestDismissKeyguard(this, object : android.app.KeyguardManager.KeyguardDismissCallback() {
            override fun onDismissSucceeded() { setShowWhenLocked(false); setTurnScreenOn(false) }
            override fun onDismissCancelled() { setShowWhenLocked(false); setTurnScreenOn(false) }
            override fun onDismissError() { setShowWhenLocked(false); setTurnScreenOn(false) }
        })
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        // A hardware touch in our own window is authoritative even while an AI gesture
        // is pending. Android's accessibility injector uses a virtual input device.
        if (event.device?.isVirtual == false) {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    BridgeSession.localUse.begin(LocalPhoneUse.Touch.ACTIVITY)
                    BridgeSession.localInputDetected()
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> BridgeSession.localUse.end(LocalPhoneUse.Touch.ACTIVITY)
            }
        }
        return super.dispatchTouchEvent(event)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.device?.isVirtual == false && event.action == KeyEvent.ACTION_DOWN) {
            BridgeSession.localUse.activity()
            BridgeSession.localInputDetected()
        }
        return super.dispatchKeyEvent(event)
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

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Manifest handles locale changes without recreating this owner. Keep a
        // stable session's native notification in sync with Flutter's system locale.
        if (AppLanguage.preference(this) == "system") {
            BridgeSession.refreshNotificationLanguage()
        }
    }

    override fun onPause() {
        BridgeSession.localUse.end(LocalPhoneUse.Touch.ACTIVITY)
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

    private fun startDesktopService(result: MethodChannel.Result, computerId: String? = null) {
        if (recoveryResult != null) {
            result.error("BUSY", "正在启动电脑服务，请稍候", null)
            return
        }
        val record = BridgeSession.prepareDesktopRecovery(computerId)
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
        BridgeSession.closeAppAccess()
        cancelPendingPermission()
        cancelDesktopRecovery()
        cleanUpUpdater()
        super.onDestroy()
    }
}
