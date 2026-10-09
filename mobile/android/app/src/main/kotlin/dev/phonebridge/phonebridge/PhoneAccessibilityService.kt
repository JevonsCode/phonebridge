@file:Suppress("DEPRECATION")

package dev.phonebridge.phonebridge

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.app.KeyguardManager
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Base64
import android.view.Display
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

class PhoneAccessibilityService : AccessibilityService() {
    private val nodes = mutableMapOf<String, AccessibilityNodeInfo>()
    private val imageWorker = Executors.newSingleThreadExecutor()
    private var uiEpoch = 0L

    override fun onServiceConnected() {
        super.onServiceConnected()
        BridgeSession.attach(this)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        uiEpoch++
        if (event == null || ObservationPolicy.invalidatesNodeIds(event.eventType)) invalidateNodes()
    }

    override fun onInterrupt() {
        BridgeSession.disconnect("Accessibility was interrupted.")
    }

    override fun onUnbind(intent: Intent?): Boolean {
        BridgeSession.detach(this)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        BridgeSession.detach(this)
        imageWorker.shutdown()
        super.onDestroy()
    }

    fun invalidateNodes() {
        nodes.values.forEach { it.recycle() }
        nodes.clear()
    }

    fun requireUnlocked() {
        if (!isUnlocked()) throw BridgeFailure("DEVICE_LOCKED", "Unlock the phone before using PhoneBridge.")
    }

    private fun isUnlocked(): Boolean {
        val keyguard = getSystemService(KeyguardManager::class.java)
        val power = getSystemService(PowerManager::class.java)
        return !keyguard.isKeyguardLocked && !keyguard.isDeviceLocked && power.isInteractive
    }

    private fun requireSession(generation: Long, mutation: Boolean = false) {
        BridgeSession.requireNotifications(this)
        OperationPolicy.requireSession(BridgeSession.connected, BridgeSession.generation == generation,
            BridgeSession.service === this, isUnlocked(), BridgeSession.actionsEnabled, mutation)
    }

    /** Never operate Android's authorization/settings surfaces, even if allowlisted. */
    private fun requireOrdinaryApp(packageName: String) {
        val protected = setOf("android", "com.android.systemui", "com.android.settings",
            "com.android.permissioncontroller", "com.google.android.permissioncontroller",
            "com.android.packageinstaller", "com.google.android.packageinstaller")
        val settingsOwner = packageManager.resolveActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS), 0)
            ?.activityInfo?.packageName
        val generalSettingsOwner = packageManager.resolveActivity(Intent(Settings.ACTION_SETTINGS), 0)
            ?.activityInfo?.packageName
        val permissionOwner = packageManager.resolveActivity(Intent("android.intent.action.MANAGE_PERMISSIONS"), 0)
            ?.activityInfo?.packageName
        if (packageName in protected || packageName == settingsOwner || packageName == generalSettingsOwner ||
            packageName == permissionOwner) {
            throw BridgeFailure("PROTECTED_APP", "Android permission and settings screens must be operated locally.")
        }
    }

    private data class WindowScope(
        val packageName: String,
        val windowId: Int,
        val bounds: Rect,
        val screenWidth: Int,
        val screenHeight: Int,
        val foreign: List<Rect>,
    )

    /**
     * Fail closed for split-screen, PIP, inaccessible windows and focused system UI.
     * Bounds are physical display coordinates, not Flutter logical coordinates.
     */
    private fun windowScope(): WindowScope {
        requireUnlocked()
        val root = rootInActiveWindow ?: throw BridgeFailure("NO_WINDOW", "No accessible active application window.")
        val activePackage: String
        val rootBounds = Rect()
        val rootId: Int
        try {
            activePackage = root.packageName?.toString() ?: throw BridgeFailure("NO_WINDOW", "Active package is unknown.")
            rootId = root.windowId
            root.getBoundsInScreen(rootBounds)
        } finally {
            root.recycle()
        }
        if (!BridgeSession.isAllowed(activePackage)) {
            throw BridgeFailure("PACKAGE_BLOCKED", "The active application is not in the phone allowlist.")
        }
        requireOrdinaryApp(activePackage)
        val visible = windows
        try {
            val active = visible.firstOrNull { it.id == rootId }
                ?: throw BridgeFailure("WINDOW_UNSAFE", "Cannot verify the active window.")
            if (active.type != AccessibilityWindowInfo.TYPE_APPLICATION ||
                active.displayId != Display.DEFAULT_DISPLAY || active.isInPictureInPictureMode) {
                throw BridgeFailure("WINDOW_UNSAFE", "Only a normal application on the primary display is supported.")
            }
            val metrics = getSystemService(WindowManager::class.java).maximumWindowMetrics
            val screen = metrics.bounds
            val appBounds = Rect().also { active.getBoundsInScreen(it) }
            val bars = metrics.windowInsets.getInsetsIgnoringVisibility(
                WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
            val crop = WindowGeometry.safeApplicationBounds(
                geometry(screen), geometry(appBounds), geometry(rootBounds),
                WindowGeometry.Insets(bars.left, bars.top, bars.right, bars.bottom))
                ?: throw BridgeFailure("WINDOW_UNSAFE", "Application bounds cannot be verified.")
            val bounds = Rect(crop.left, crop.top, crop.right, crop.bottom)
            val foreign = mutableListOf<Rect>()
            for (window in visible) {
                if (window.id == rootId || window.displayId != Display.DEFAULT_DISPLAY) continue
                val area = Rect().also { window.getBoundsInScreen(it) }
                if (area.isEmpty) continue
                val otherRoot = window.root
                val owner = try { otherRoot?.packageName?.toString() } finally { otherRoot?.recycle() }
                if (owner == activePackage && window.type == AccessibilityWindowInfo.TYPE_APPLICATION) continue
                if (window.type == AccessibilityWindowInfo.TYPE_APPLICATION ||
                    window.isFocused || window.isActive ||
                    window.type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY) {
                    throw BridgeFailure("WINDOW_UNSAFE", "Dismiss other apps, focused panels, and accessibility overlays first.")
                }
                foreign.add(area)
            }
            return WindowScope(activePackage, rootId, bounds, screen.width(), screen.height(), foreign)
        } finally {
            visible.forEach { it.recycle() }
        }
    }

    private fun requireClearCrop(scope: WindowScope) {
        if (scope.foreign.any { Rect.intersects(it, scope.bounds) }) {
            throw BridgeFailure("WINDOW_OBSCURED", "Dismiss the keyboard or other overlapping windows first.")
        }
    }

    private fun requireSameWindow(before: WindowScope, after: WindowScope) {
        if (before.packageName != after.packageName || before.windowId != after.windowId ||
            before.bounds != after.bounds || before.screenWidth != after.screenWidth ||
            before.screenHeight != after.screenHeight) {
            throw BridgeFailure("WINDOW_CHANGED", "The application window changed. Observe again.")
        }
    }

    fun execute(method: String, params: JSONObject, generation: Long,
                complete: (JSONObject?, BridgeFailure?) -> Unit) {
        val mutation = method in setOf("tap", "long_press", "swipe", "set_text", "global_action", "launch_app")
        requireSession(generation, mutation)
        when (method) {
            "state" -> {
                validateKeys(params, emptySet())
                complete(observe(), null)
            }
            "screenshot" -> {
                validateKeys(params, emptySet())
                invalidateNodes()
                screenshot(generation, complete)
            }
            "tap", "long_press", "swipe" -> gesture(method, params, generation, complete)
            "set_text" -> {
                validateKeys(params, setOf("nodeId", "text"))
                setText(params, generation)
                complete(completed(), null)
            }
            "global_action" -> {
                validateKeys(params, setOf("action"))
                val action = when (params.opt("action") as? String) {
                    "back" -> GLOBAL_ACTION_BACK
                    "home" -> GLOBAL_ACTION_HOME
                    "recents" -> GLOBAL_ACTION_RECENTS
                    else -> throw BridgeFailure("INVALID_ARGUMENT", "Supported actions: back, home, recents.")
                }
                windowScope()
                requireSession(generation, true)
                invalidateNodes()
                if (!performGlobalAction(action)) throw BridgeFailure("ACTION_REJECTED", "Android rejected the global action.")
                complete(completed(), null)
            }
            "launch_app" -> {
                validateKeys(params, setOf("packageName"))
                val target = params.opt("packageName") as? String
                    ?: throw BridgeFailure("INVALID_ARGUMENT", "packageName must be a string.")
                if (!BridgeSession.isAllowed(target)) throw BridgeFailure("PACKAGE_BLOCKED", "Target application is not allowed.")
                requireOrdinaryApp(target)
                val launch = packageManager.getLaunchIntentForPackage(target)
                    ?: throw BridgeFailure("APP_UNAVAILABLE", "Application is not installed or has no launch activity.")
                requireSession(generation, true)
                invalidateNodes()
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try { startActivity(launch) } catch (_: Exception) {
                    throw BridgeFailure("ACTION_REJECTED", "Android could not launch that application.")
                }
                complete(completed(), null)
            }
            else -> throw BridgeFailure("UNKNOWN_METHOD", "Unsupported operation.")
        }
    }

    private fun observe(): JSONObject {
        invalidateNodes()
        val scope = windowScope()
        val root = rootInActiveWindow ?: throw BridgeFailure("NO_WINDOW", "No accessible application window.")
        val result = JSONArray()
        val observationId = UUID.randomUUID().toString()
        var visited = 0
        var truncated = false
        fun walk(node: AccessibilityNodeInfo, depth: Int, inheritedPassword: Boolean) {
            if (visited >= 500 || depth > 30) { truncated = true; return }
            visited++
            val owner = node.packageName?.toString()
            if (owner != null && owner != scope.packageName) return
            val area = Rect().also { node.getBoundsInScreen(it) }
            val password = inheritedPassword || node.isPassword
            if (node.isVisibleToUser && Rect.intersects(area, scope.bounds)) {
                val id = observationId + ":" + visited
                nodes[id] = AccessibilityNodeInfo.obtain(node)
                result.put(JSONObject()
                    .put("id", id)
                    .put("text", if (password) "" else node.text?.toString()?.take(512) ?: "")
                    .put("description", if (password) "" else node.contentDescription?.toString()?.take(256) ?: "")
                    .put("className", node.className?.toString()?.take(128) ?: "")
                    .put("bounds", rectJson(area))
                    .put("clickable", node.isClickable)
                    .put("editable", node.isEditable)
                    .put("scrollable", node.isScrollable)
                    .put("password", password))
            }
            for (i in 0 until node.childCount) {
                if (visited >= 500 || depth >= 30) { truncated = true; break }
                val child = node.getChild(i) ?: continue
                try { walk(child, depth + 1, password) } finally { child.recycle() }
            }
        }
        try {
            if (root.windowId != scope.windowId) throw BridgeFailure("WINDOW_CHANGED", "Window changed. Observe again.")
            walk(root, 0, false)
            requireSameWindow(scope, windowScope())
        } catch (e: Exception) {
            invalidateNodes()
            throw e
        } finally { root.recycle() }
        return JSONObject().put("packageName", scope.packageName)
            .put("width", scope.screenWidth).put("height", scope.screenHeight)
            .put("nodes", result).put("truncated", truncated)
    }

    private fun setText(params: JSONObject, generation: Long) {
        val id = params.opt("nodeId") as? String ?: throw BridgeFailure("INVALID_ARGUMENT", "nodeId must be a string.")
        val text = params.opt("text") as? String ?: throw BridgeFailure("INVALID_ARGUMENT", "text must be a string.")
        if (text.length > 4000) throw BridgeFailure("INVALID_ARGUMENT", "Text is limited to 4000 characters.")
        val cached = nodes[id] ?: throw BridgeFailure("STALE_NODE", "Node ID expired. Request state again.")
        val observedBounds = Rect().also { cached.getBoundsInScreen(it) }
        val node = AccessibilityNodeInfo.obtain(cached)
        try {
            val scope = windowScope()
            if (!node.refresh() || node.windowId != scope.windowId ||
                node.packageName?.toString() != scope.packageName || !node.isVisibleToUser) {
                throw BridgeFailure("STALE_NODE", "The editable node changed. Request state again.")
            }
            // Check password ancestors too; some custom widgets put the flag on a container.
            var ancestor: AccessibilityNodeInfo? = AccessibilityNodeInfo.obtain(node)
            var depth = 0
            var password = false
            try {
                while (ancestor != null && depth++ <= 30) {
                    if (ancestor.isPassword) password = true
                    val parent = ancestor.parent
                    ancestor.recycle()
                    ancestor = parent
                }
                if (ancestor != null) password = true // Cannot prove the ancestry safe.
            } finally { ancestor?.recycle() }
            if (password || !node.isEditable || !node.isEnabled) {
                throw BridgeFailure("NODE_BLOCKED", "Only enabled, non-password editable nodes accept text.")
            }
            OperationPolicy.requireInputFocus(node.isFocused)
            val area = Rect().also { node.getBoundsInScreen(it) }
            if (area != observedBounds || cached.className?.toString() != node.className?.toString() ||
                cached.viewIdResourceName != node.viewIdResourceName ||
                cached.text?.toString() != node.text?.toString() ||
                cached.contentDescription?.toString() != node.contentDescription?.toString()) {
                throw BridgeFailure("STALE_NODE", "The editable target changed or moved. Request state again.")
            }
            if (!scope.bounds.contains(area) || scope.foreign.any { Rect.intersects(it, area) }) {
                throw BridgeFailure("WINDOW_OBSCURED", "The editable node is outside the safe application area.")
            }
            requireSession(generation, true)
            val recheck = windowScope()
            requireSameWindow(scope, recheck)
            if (recheck.foreign.any { Rect.intersects(it, area) }) {
                throw BridgeFailure("WINDOW_OBSCURED", "The editable node became obscured.")
            }
            invalidateNodes()
            val args = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text) }
            if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                throw BridgeFailure("ACTION_REJECTED", "The application rejected text entry.")
            }
        } finally { node.recycle() }
    }

    private fun gesture(method: String, params: JSONObject, generation: Long,
                        complete: (JSONObject?, BridgeFailure?) -> Unit) {
        validateKeys(params, when (method) {
            "swipe" -> setOf("x1", "y1", "x2", "y2", "durationMs")
            "long_press" -> setOf("x", "y", "durationMs")
            else -> setOf("x", "y")
        })
        val x1 = number(params, if (method == "swipe") "x1" else "x")
        val y1 = number(params, if (method == "swipe") "y1" else "y")
        val x2 = if (method == "swipe") number(params, "x2") else x1
        val y2 = if (method == "swipe") number(params, "y2") else y1
        val duration = when (method) {
            "long_press" -> duration(params, 600, 400)
            "swipe" -> duration(params, 400, 100)
            else -> 80L
        }
        val scope = windowScope()
        requireClearCrop(scope)
        if (!contains(scope.bounds, x1, y1) || !contains(scope.bounds, x2, y2)) {
            throw BridgeFailure("OUT_OF_BOUNDS", "Gesture coordinates must be inside the allowed application window.")
        }
        val path = Path().apply { moveTo(x1, y1); if (method == "swipe") lineTo(x2, y2) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, duration)).build()
        requireSession(generation, true)
        val recheck = windowScope()
        requireSameWindow(scope, recheck)
        requireClearCrop(recheck)
        invalidateNodes()
        val accepted = dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                if (generation == BridgeSession.generation) {
                    invalidateNodes()
                    complete(completed(), null)
                }
            }
            override fun onCancelled(gestureDescription: GestureDescription?) {
                if (generation == BridgeSession.generation) {
                    invalidateNodes()
                    complete(null, BridgeFailure("GESTURE_CANCELLED", "Android cancelled the gesture; observe before retrying."))
                }
            }
        }, BridgeSession.main)
        if (!accepted) throw BridgeFailure("ACTION_REJECTED", "Android rejected gesture dispatch.")
    }

    private fun screenshot(generation: Long, complete: (JSONObject?, BridgeFailure?) -> Unit) {
        val scope = windowScope()
        requireClearCrop(scope)
        val epoch = uiEpoch
        takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
            override fun onSuccess(screenshot: ScreenshotResult) {
                val hardware = screenshot.hardwareBuffer
                var source: Bitmap? = null
                try {
                    requireSession(generation)
                    if (epoch != uiEpoch) throw BridgeFailure("WINDOW_CHANGED", "Screen changed during capture. Observe again.")
                    val after = windowScope()
                    requireSameWindow(scope, after)
                    requireClearCrop(after)
                    source = Bitmap.wrapHardwareBuffer(hardware, screenshot.colorSpace)
                        ?: throw BridgeFailure("SCREENSHOT_UNAVAILABLE", "Android did not provide a readable screenshot.")
                    if (source.width != scope.screenWidth || source.height != scope.screenHeight) {
                        throw BridgeFailure("WINDOW_CHANGED", "Display geometry changed. Observe again.")
                    }
                    val bitmap = source.copy(Bitmap.Config.ARGB_8888, false)
                        ?: throw BridgeFailure("SCREENSHOT_UNAVAILABLE", "Could not copy the screenshot.")
                    imageWorker.execute {
                        val encoded = try { encodeScreenshot(bitmap, scope) } catch (_: Exception) { null }
                        finally { bitmap.recycle() }
                        BridgeSession.main.post {
                            if (generation != BridgeSession.generation) return@post
                            try {
                                requireSession(generation)
                                if (epoch != uiEpoch) throw BridgeFailure("WINDOW_CHANGED", "Screen changed during capture. Observe again.")
                                val latest = windowScope()
                                requireSameWindow(scope, latest)
                                requireClearCrop(latest)
                                if (encoded == null) throw BridgeFailure("SCREENSHOT_UNAVAILABLE", "Screenshot could not be encoded within the size limit.")
                                complete(encoded, null)
                            } catch (e: BridgeFailure) { complete(null, e) }
                            catch (_: Exception) { complete(null, BridgeFailure("SCREENSHOT_UNAVAILABLE", "Screenshot is unavailable.")) }
                        }
                    }
                } catch (e: BridgeFailure) {
                    complete(null, e)
                } catch (_: Exception) {
                    complete(null, BridgeFailure("SCREENSHOT_UNAVAILABLE", "Screenshot is unavailable."))
                } finally {
                    source?.recycle()
                    hardware.close()
                }
            }

            override fun onFailure(errorCode: Int) {
                complete(null, BridgeFailure("SCREENSHOT_UNAVAILABLE",
                    "Android refused capture (secure content, capture rate, or display restriction)."))
            }
        })
    }

    private fun encodeScreenshot(source: Bitmap, scope: WindowScope): JSONObject {
        val crop = scope.bounds
        val cropped = Bitmap.createBitmap(source, crop.left, crop.top, crop.width(), crop.height())
        var scaled: Bitmap? = null
        try {
            val factor = minOf(1.0, 1280.0 / max(cropped.width, cropped.height))
            scaled = Bitmap.createScaledBitmap(cropped,
                max(1, (cropped.width * factor).roundToInt()),
                max(1, (cropped.height * factor).roundToInt()), true)
            val bytes = ByteArrayOutputStream().use {
                check(scaled.compress(Bitmap.CompressFormat.JPEG, 65, it))
                it.toByteArray()
            }
            check(bytes.size <= 2 * 1024 * 1024)
            return JSONObject().put("mimeType", "image/jpeg").put("data", Base64.encodeToString(bytes, Base64.NO_WRAP))
                .put("width", scaled.width).put("height", scaled.height)
                .put("screenWidth", scope.screenWidth).put("screenHeight", scope.screenHeight)
                .put("cropLeft", crop.left).put("cropTop", crop.top)
                .put("cropWidth", crop.width()).put("cropHeight", crop.height())
        } finally {
            if (scaled !== cropped && scaled !== source) scaled?.recycle()
            if (cropped !== source) cropped.recycle()
        }
    }

    private fun validateKeys(params: JSONObject, allowed: Set<String>) {
        if (params.keys().asSequence().any { it !in allowed }) {
            throw BridgeFailure("INVALID_ARGUMENT", "Unexpected operation parameter.")
        }
    }

    private fun number(params: JSONObject, key: String): Float {
        val value = (params.opt(key) as? Number)?.toDouble()
            ?: throw BridgeFailure("INVALID_ARGUMENT", "Gesture coordinates must be numbers.")
        if (!value.isFinite() || value < 0 || value > 100000) throw BridgeFailure("INVALID_ARGUMENT", "Invalid coordinate.")
        return value.toFloat()
    }

    private fun duration(params: JSONObject, default: Long, minimum: Long): Long {
        if (!params.has("durationMs")) return default
        val value = (params.opt("durationMs") as? Number)?.toDouble()
            ?: throw BridgeFailure("INVALID_ARGUMENT", "durationMs must be an integer.")
        if (!value.isFinite() || value != value.toLong().toDouble() || value < minimum || value > 2000) {
            throw BridgeFailure("INVALID_ARGUMENT", "durationMs is outside the supported range.")
        }
        return value.toLong()
    }

    private fun contains(area: Rect, x: Float, y: Float) =
        x >= area.left && y >= area.top && x < area.right && y < area.bottom

    private fun rectJson(area: Rect) = JSONObject().put("left", area.left).put("top", area.top)
        .put("right", area.right).put("bottom", area.bottom)

    private fun geometry(area: Rect) = WindowGeometry.Bounds(area.left, area.top, area.right, area.bottom)

    private fun completed() = JSONObject().put("completed", true)
}
