@file:Suppress("DEPRECATION")

package dev.phonebridge.phonebridge

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.app.KeyguardManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.os.Build
import android.text.InputType
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
    private var lastScreenshot: ScreenshotPolicy.Frame? = null
    private val operationTrail by lazy { OperationTrail(this) }

    override fun onServiceConnected() {
        super.onServiceConnected()
        if (Build.VERSION.SDK_INT >= 33) {
            serviceInfo = serviceInfo.apply { flags = flags or AccessibilityServiceInfo.FLAG_INPUT_METHOD_EDITOR }
        }
        BridgeSession.attach(this)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (operationTrail.ownsEvent(event)) return
        // A clock/status-bar refresh outside our verified screenshot crop does
        // not change the application image. Unknown, focused, overlapping and
        // structural events still invalidate the capture as before.
        if (event?.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) {
            val excluded = try { windowScope().excludedSystemWindowIds } catch (_: Exception) { emptySet() }
            if (ObservationPolicy.isExcludedSystemRefresh(event.eventType, event.windowId, excluded)) return
        }
        uiEpoch++
        if (event == null || ObservationPolicy.invalidatesNodeIds(event.eventType)) invalidateNodes()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        clearOperationTrail()
        // This service may keep the session alive after the owner Activity is
        // destroyed. Locale changes must still refresh its native notification.
        if (AppLanguage.preference(this) == "system") {
            BridgeSession.refreshNotificationLanguage()
        }
    }

    override fun onInterrupt() {
        clearOperationTrail()
        BridgeSession.serviceInterrupted()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        clearOperationTrail()
        BridgeSession.detach(this)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        clearOperationTrail()
        ClipboardBridge.cancel(this)
        BridgeSession.detach(this)
        imageWorker.shutdown()
        super.onDestroy()
    }

    fun invalidateNodes() {
        nodes.values.forEach { it.recycle() }
        nodes.clear()
        lastScreenshot = null
    }

    fun clearOperationTrail() = operationTrail.clear()

    fun requireUnlocked() {
        if (!isUnlocked()) throw BridgeFailure("DEVICE_LOCKED", "Unlock the phone before using PhoneBridge.", mapOf("obscuredBy" to "lockscreen"))
    }

    private fun isUnlocked(): Boolean {
        val keyguard = getSystemService(KeyguardManager::class.java)
        val power = getSystemService(PowerManager::class.java)
        return !keyguard.isKeyguardLocked && !keyguard.isDeviceLocked && power.isInteractive
    }

    private fun requireSession(generation: Long, mutation: Boolean = false) {
        BridgeSession.requireNotifications(this)
        if (!BridgeSession.isOperationCurrent(generation)) {
            throw BridgeFailure("CONTROL_EXPIRED", "The control task has ended. Acquire control and observe again.")
        }
        OperationPolicy.requireSession(BridgeSession.connected, BridgeSession.isOperationCurrent(generation),
            BridgeSession.service === this, isUnlocked(), BridgeSession.actionsEnabled, mutation, BridgeSession.appAccessOpen)
    }

    /** Never operate Android's authorization/settings surfaces, even if allowlisted. */
    private fun requireOrdinaryApp(packageName: String) {
        if (packageName in AppAccessCatalog.protectedPackages(this)) {
            throw BridgeFailure("PROTECTED_APP", "Android permission and settings screens must be operated locally.", mapOf("foregroundPackage" to packageName))
        }
    }

    private data class WindowScope(
        val packageName: String,
        val windowId: Int,
        val bounds: Rect,
        val screenWidth: Int,
        val screenHeight: Int,
        val foreign: List<Rect>,
        val excludedSystemWindowIds: Set<Int>,
        val occlusions: List<Occlusion>,
    )
    private data class Occlusion(val bounds: Rect, val details: Map<String, Any>, val toast: Boolean)

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
        val visible = windows
        try {
            val active = visible.firstOrNull { it.id == rootId }
                ?: throw BridgeFailure("WINDOW_UNSAFE", "Cannot verify the active window.")
            if (!BridgeSession.isAllowed(activePackage)) {
                throw BridgeFailure("PACKAGE_BLOCKED", "The active application is not in the phone allowlist.",
                    mapOf("foregroundPackage" to activePackage, "windowType" to active.type))
            }
            requireOrdinaryApp(activePackage)
            if (active.type != AccessibilityWindowInfo.TYPE_APPLICATION ||
                active.displayId != Display.DEFAULT_DISPLAY || active.isInPictureInPictureMode) {
                throw BridgeFailure("WINDOW_UNSAFE", "Only a normal application on the primary display is supported.",
                    mapOf("foregroundPackage" to activePackage, "windowType" to active.type))
            }
            val metrics = getSystemService(WindowManager::class.java).maximumWindowMetrics
            val screen = metrics.bounds
            val appBounds = Rect().also { active.getBoundsInScreen(it) }
            val bars = metrics.windowInsets.getInsetsIgnoringVisibility(
                WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
            val crop = WindowGeometry.safeApplicationBounds(
                geometry(screen), geometry(appBounds), geometry(rootBounds),
                WindowGeometry.Insets(bars.left, bars.top, bars.right, bars.bottom))
                ?: throw BridgeFailure("WINDOW_UNSAFE", "Application bounds cannot be verified. window=" +
                    rootId + " screen=" + screen.toShortString() + " app=" + appBounds.toShortString() +
                    " root=" + rootBounds.toShortString() + " insets=[" +
                    bars.left + "," + bars.top + "," + bars.right + "," + bars.bottom + "]")
            val bounds = Rect(crop.left, crop.top, crop.right, crop.bottom)
            val foreign = mutableListOf<Rect>()
            val occlusions = mutableListOf<Occlusion>()
            for (window in visible) {
                if (window.id == rootId || window.displayId != Display.DEFAULT_DISPLAY) continue
                val area = Rect().also { window.getBoundsInScreen(it) }
                if (area.isEmpty) continue
                val otherRoot = window.root
                var rootClass: String? = null
                var interactive = true
                val owner = try {
                    rootClass = otherRoot?.className?.toString()
                    if (otherRoot != null && WindowOcclusionPolicy.isNonInteractiveToast(window.type, window.isFocused, window.isActive,
                            rootClass, window.title?.toString(), false)) interactive = interactiveTree(otherRoot)
                    otherRoot?.packageName?.toString()
                } finally { otherRoot?.recycle() }
                if (owner == activePackage && window.type == AccessibilityWindowInfo.TYPE_APPLICATION) continue
                val toast = owner in setOf(activePackage, "android", "com.android.systemui", "com.miui.systemui") &&
                    WindowOcclusionPolicy.isNonInteractiveToast(window.type, window.isFocused, window.isActive,
                        rootClass, window.title?.toString(), interactive)
                val details = WindowOcclusionPolicy.details(activePackage, window.type, owner, toast)
                // A lower, unfocused system window cannot cover this application's input area.
                if (window.layer < active.layer && !window.isFocused && !window.isActive && window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                if (window.type == AccessibilityWindowInfo.TYPE_APPLICATION ||
                    window.isFocused || window.isActive ||
                    window.type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY) {
                    throw BridgeFailure("WINDOW_UNSAFE", "Another application or focused system panel is in front. Dismiss it and observe again.", details)
                }
                occlusions.add(Occlusion(area, details, toast))
                if (!toast) foreign.add(area)
            }
            // Service window metrics can omit ROM system-bar insets. Use actual
            // OS window rectangles to exclude edge bars/IME from the app crop.
            for (area in foreign) {
                val trimmed = WindowGeometry.trimEdgeOcclusion(geometry(bounds), geometry(area))
                bounds.set(trimmed.left, trimmed.top, trimmed.right, trimmed.bottom)
            }
            val excludedSystemWindowIds = visible.filter { window ->
                val area = Rect().also { window.getBoundsInScreen(it) }
                window.id != rootId && window.displayId == Display.DEFAULT_DISPLAY &&
                    window.type == AccessibilityWindowInfo.TYPE_SYSTEM &&
                    !window.isFocused && !window.isActive && !area.isEmpty &&
                    !Rect.intersects(area, bounds)
            }.map { it.id }.toSet()
            return WindowScope(activePackage, rootId, bounds, screen.width(), screen.height(), foreign, excludedSystemWindowIds, occlusions)
        } finally {
            visible.forEach { it.recycle() }
        }
    }

    private fun requireClearCrop(scope: WindowScope) {
        val covering = scope.occlusions.firstOrNull { Rect.intersects(it.bounds, scope.bounds) } ?: return
        throw BridgeFailure("WINDOW_OBSCURED", if (covering.toast) "A temporary toast covers the screenshot. Wait for it to disappear and capture again."
            else "A system window covers part of the application. Dismiss it or choose an unobscured target.", covering.details)
    }

    private fun interactiveTree(root: AccessibilityNodeInfo): Boolean {
        var visited = 0
        fun walk(node: AccessibilityNodeInfo, depth: Int): Boolean {
            if (++visited > 500 || depth > 30) return true
            if (node.isClickable || node.isLongClickable || node.isEditable || node.isFocusable || node.isScrollable) return true
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                try { if (walk(child, depth + 1)) return true } finally { child.recycle() }
            }
            return false
        }
        return walk(root, 0)
    }

    private fun requireClearGesture(scope: WindowScope, x1: Float, y1: Float, x2: Float, y2: Float) {
        val covering = scope.occlusions.firstOrNull { !it.toast && ProtectedControlPolicy.touches(geometry(it.bounds), x1, y1, x2, y2) } ?: return
        throw BridgeFailure("WINDOW_OBSCURED", "A system window covers this gesture. Choose an unobscured target or dismiss the indicated window.", covering.details)
    }

    private fun screenshotWindow(scope: WindowScope) = ScreenshotPolicy.Window(scope.packageName, scope.windowId,
        geometry(scope.bounds), scope.screenWidth, scope.screenHeight)

    private fun requireSameWindow(before: WindowScope, after: WindowScope) {
        if (before.packageName != after.packageName || before.windowId != after.windowId ||
            before.bounds != after.bounds || before.screenWidth != after.screenWidth ||
            before.screenHeight != after.screenHeight) {
            throw BridgeFailure("WINDOW_CHANGED", "The application window changed. Observe again.")
        }
    }

    fun execute(method: String, params: JSONObject, generation: Long,
                complete: (JSONObject?, BridgeFailure?) -> Unit) {
        operationTrail.beforeRpc {
            try { executeReady(method, params, generation, complete) }
            catch (error: BridgeFailure) { complete(null, error) }
            catch (_: Exception) { complete(null, BridgeFailure("UNAVAILABLE", "Android could not complete the operation.")) }
        }
    }

    private fun executeReady(method: String, params: JSONObject, generation: Long,
                             complete: (JSONObject?, BridgeFailure?) -> Unit) {
        val mutation = method in setOf("tap", "long_press", "swipe", "set_text", "node_action", "commit_text", "global_action", "launch_app", "set_clipboard")
        requireSession(generation, mutation)
        when (method) {
            "get_clipboard" -> {
                validateKeys(params, emptySet())
                ClipboardPolicy.requireEnabled(AutomationPreferences.clipboardAccessEnabled(this))
                invalidateNodes()
                ClipboardBridge.read(this, {
                    requireSession(generation)
                    ClipboardPolicy.requireEnabled(AutomationPreferences.clipboardAccessEnabled(this))
                }, complete)
            }
            "set_clipboard" -> {
                validateKeys(params, setOf("text"))
                val text = params.opt("text") as? String ?: throw BridgeFailure("INVALID_ARGUMENT", "text must be a string.")
                ClipboardPolicy.requireEnabled(AutomationPreferences.clipboardAccessEnabled(this))
                requireSession(generation, true)
                try { getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("PhoneBridge", text)) }
                catch (_: Exception) { throw BridgeFailure("CLIPBOARD_UNAVAILABLE", "Android could not write clipboard text.") }
                complete(completed(), null)
            }
            "file_offer" -> {
                complete(JSONObject(BridgeSession.offerFile(params)), null)
            }
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
            "node_action" -> {
                validateKeys(params, setOf("nodeId", "selector", "action"))
                nodeAction(params, generation)
                complete(completed(), null)
            }
            "commit_text" -> {
                validateKeys(params, setOf("text", "packageName"))
                if (Build.VERSION.SDK_INT < 33) throw BridgeFailure("UNSUPPORTED", "Focused input requires Android 13 or later.")
                val text = params.opt("text") as? String ?: throw BridgeFailure("INVALID_ARGUMENT", "text must be a string.")
                if (text.isEmpty() || text.length > 4000) throw BridgeFailure("INVALID_ARGUMENT", "Text must contain 1..4000 characters.")
                val scope = windowScope()
                requireClearCrop(scope)
                if (params.optString("packageName") != scope.packageName) throw BridgeFailure("WINDOW_CHANGED", "Focused app does not match the requested package.")
                val ime = inputMethod ?: throw BridgeFailure("FOCUS_REQUIRED", "Tap an input field first.")
                val editor = ime.currentInputEditorInfo ?: throw BridgeFailure("FOCUS_REQUIRED", "No focused input field.")
                val connection = ime.currentInputConnection ?: throw BridgeFailure("FOCUS_REQUIRED", "No focused input connection.")
                val kind = editor.inputType and InputType.TYPE_MASK_CLASS
                val variation = editor.inputType and InputType.TYPE_MASK_VARIATION
                if (editor.packageName != scope.packageName || kind == InputType.TYPE_NULL ||
                    (kind == InputType.TYPE_CLASS_TEXT && variation in setOf(InputType.TYPE_TEXT_VARIATION_PASSWORD,
                        InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD, InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)) ||
                    (kind == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD)) {
                    throw BridgeFailure("NODE_BLOCKED", "Focused input must belong to the allowed app and must not be a password.")
                }
                requireSession(generation, true)
                val recheck = windowScope()
                requireSameWindow(scope, recheck)
                requireClearCrop(recheck)
                requireFocusedInputProtection(recheck)
                if (!ime.currentInputStarted || ime.currentInputEditorInfo !== editor)
                    throw BridgeFailure("FOCUS_REQUIRED", "Input focus changed. Observe again.")
                invalidateNodes()
                connection.commitText(text, 1, null)
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
        val observedAt = System.currentTimeMillis()
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
                    .put("stateDescription", if (password) "" else node.stateDescription?.toString() ?: "")
                    .put("className", node.className?.toString()?.take(128) ?: "")
                    .put("resourceId", node.viewIdResourceName?.take(256) ?: "")
                    .put("bounds", rectJson(area))
                    .put("clickable", node.isClickable)
                    .put("editable", node.isEditable)
                    .put("scrollable", node.isScrollable)
                    .put("enabled", node.isEnabled)
                    .put("selected", node.isSelected)
                    .put("checked", node.isChecked)
                    .put("checkable", node.isCheckable)
                    .put("focused", node.isFocused)
                    .put("selectionStart", if (password) -1 else node.textSelectionStart)
                    .put("selectionEnd", if (password) -1 else node.textSelectionEnd)
                    .put("supportedActions", JSONArray(supportedNodeActions(node).toList()))
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
            .put("snapshotId", observationId).put("observedAt", observedAt)
            .put("width", scope.screenWidth).put("height", scope.screenHeight)
            .put("nodes", result).put("truncated", truncated)
    }

    private fun nodeAction(params: JSONObject, generation: Long) {
        val action = params.opt("action") as? String
            ?: throw BridgeFailure("INVALID_ARGUMENT", "action must be a string.")
        if (action !in NodeActionPolicy.actions) throw BridgeFailure("INVALID_ARGUMENT", "Unsupported node action.")
        val scope = windowScope()
        val node = targetNode(params, scope)
        val observed = nodeTarget(node)
        try {
            if (!node.refresh() || node.windowId != scope.windowId ||
                node.packageName?.toString() != scope.packageName) {
                throw BridgeFailure("STALE_NODE", "The target is no longer in the active window. Request state again.")
            }
            NodeActionPolicy.requireUnchanged(observed, nodeTarget(node))
            NodeActionPolicy.requireAction(action, supportedNodeActions(node), node.isVisibleToUser,
                node.isEnabled, hasPasswordAncestry(node, scope))
            requireTextAction(action, node)
            requireNodeProtection(scope, node, action)
            val area = nodeTarget(node).bounds
            safeNodeBounds(action, area, scope)
            requireSession(generation, true)
            val recheck = windowScope()
            requireSameWindow(scope, recheck)
            if (!node.refresh()) throw BridgeFailure("STALE_NODE", "The target expired. Request state again.")
            NodeActionPolicy.requireUnchanged(observed, nodeTarget(node))
            NodeActionPolicy.requireAction(action, supportedNodeActions(node), node.isVisibleToUser,
                node.isEnabled, hasPasswordAncestry(node, recheck))
            requireTextAction(action, node)
            requireNodeProtection(recheck, node, action)
            safeNodeBounds(action, area, recheck)
            requireSession(generation, true)
            // Every attempted dispatch consumes the snapshot, including a negative Android response.
            invalidateNodes()
            val arguments = if (action == "select_all") Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, node.text?.length ?: 0)
            } else null
            if (!node.performAction(nodeActionId(action), arguments)) {
                throw BridgeFailure("ACTION_REJECTED", "The application rejected the node action.")
            }
        } finally { node.recycle() }
    }

    private fun requireTextAction(action: String, node: AccessibilityNodeInfo) {
        if (action in setOf("copy", "cut", "paste")) ClipboardPolicy.requireEnabled(AutomationPreferences.clipboardAccessEnabled(this))
        NodeActionPolicy.requireTextAction(action, node.isEditable, node.isFocused, node.text?.length ?: 0,
            node.textSelectionStart, node.textSelectionEnd)
    }

    private fun safeNodeBounds(action: String, area: WindowGeometry.Bounds, scope: WindowScope): WindowGeometry.Bounds {
        try {
            return NodeActionPolicy.safeActionBounds(action, area, geometry(scope.bounds),
                WindowGeometry.Bounds(0, 0, scope.screenWidth, scope.screenHeight), scope.foreign.map(::geometry))
        } catch (error: BridgeFailure) {
            if (error.code != "WINDOW_OBSCURED") throw error
            val covering = scope.occlusions.firstOrNull { !it.toast && Rect.intersects(it.bounds, Rect(area.left, area.top, area.right, area.bottom)) }
            throw BridgeFailure(error.code, error.message, covering?.details ?: mapOf("foregroundPackage" to scope.packageName))
        }
    }

    private fun targetNode(params: JSONObject, scope: WindowScope): AccessibilityNodeInfo {
        if (params.has("nodeId") == params.has("selector")) throw BridgeFailure("INVALID_ARGUMENT", "Choose exactly one target: nodeId or selector.")
        if (params.has("selector")) {
            val value = params.opt("selector") as? JSONObject ?: throw BridgeFailure("INVALID_ARGUMENT", "selector must be an object.")
            return resolveSelector(NodeSelector.parse(value), scope)
        }
        val id = params.opt("nodeId") as? String ?: throw BridgeFailure("INVALID_ARGUMENT", "nodeId must be a string.")
        val cached = nodes[id] ?: throw BridgeFailure("STALE_NODE", "Node ID expired. Request state again or use a current selector.")
        return AccessibilityNodeInfo.obtain(cached)
    }

    private fun resolveSelector(selector: NodeSelector, scope: WindowScope): AccessibilityNodeInfo {
        val root = rootInActiveWindow ?: throw BridgeFailure("NO_WINDOW", "No accessible application window.")
        val matches = mutableListOf<AccessibilityNodeInfo>()
        var visited = 0
        var truncated = false
        fun walk(node: AccessibilityNodeInfo, depth: Int, inheritedPassword: Boolean) {
            if (visited >= 500 || depth > 30) { truncated = true; return }
            visited++
            if (node.windowId != scope.windowId || node.packageName?.toString()?.let { it != scope.packageName } == true) return
            val password = inheritedPassword || node.isPassword
            val area = Rect().also { node.getBoundsInScreen(it) }
            if (!password && node.isVisibleToUser && Rect.intersects(area, scope.bounds) && selector.matches(nodeTarget(node))) {
                matches.add(AccessibilityNodeInfo.obtain(node))
            }
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                try { walk(child, depth + 1, password) } finally { child.recycle() }
                if (truncated) break
            }
        }
        try {
            if (root.windowId != scope.windowId) throw BridgeFailure("WINDOW_CHANGED", "The active window changed. Observe again.")
            walk(root, 0, false)
            requireSameWindow(scope, windowScope())
            val position = SelectorPolicy.choose(selector, matches.size, truncated)
            return matches.removeAt(position)
        } finally { root.recycle(); matches.forEach { it.recycle() } }
    }

    private fun protectedBounds(scope: WindowScope): List<WindowGeometry.Bounds> {
        if (scope.packageName != packageName || !AutomationPreferences.protectConnectionControls(this)) return emptyList()
        val root = rootInActiveWindow ?: throw BridgeFailure("NO_WINDOW", "No accessible application window.")
        val result = mutableListOf<WindowGeometry.Bounds>()
        var visited = 0
        fun walk(node: AccessibilityNodeInfo, depth: Int) {
            if (++visited > 500 || depth > 30) throw BridgeFailure("PROTECTED_CONTROL", "Cannot verify all PhoneBridge control boundaries. Scroll to a smaller view or change protection locally.")
            if (node.windowId != scope.windowId || node.packageName?.toString()?.let { it != packageName } == true) return
            if (node.isVisibleToUser && ProtectedControlPolicy.isProtected(node.viewIdResourceName)) {
                result.add(nodeTarget(node).bounds)
            }
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                try { walk(child, depth + 1) } finally { child.recycle() }
            }
        }
        try {
            if (root.windowId != scope.windowId) throw BridgeFailure("WINDOW_CHANGED", "The active window changed. Observe again.")
            walk(root, 0)
            return result
        } finally { root.recycle() }
    }

    private fun requireNodeProtection(scope: WindowScope, node: AccessibilityNodeInfo, action: String = "click") {
        ProtectedControlPolicy.requireNode(AutomationPreferences.protectConnectionControls(this), scope.packageName == packageName,
            nodeTarget(node).bounds, protectedBounds(scope), action)
    }

    private fun requireFocusedInputProtection(scope: WindowScope) {
        if (scope.packageName != packageName || !AutomationPreferences.protectConnectionControls(this)) return
        val root = rootInActiveWindow ?: throw BridgeFailure("NO_WINDOW", "No accessible application window.")
        try {
            val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                ?: throw BridgeFailure("PROTECTED_CONTROL", "Cannot verify this PhoneBridge input field. Choose another target.")
            try { requireNodeProtection(scope, focused) } finally { focused.recycle() }
        } finally { root.recycle() }
    }

    private fun nodeTarget(node: AccessibilityNodeInfo): NodeActionPolicy.Target {
        val area = Rect().also { node.getBoundsInScreen(it) }
        return NodeActionPolicy.Target(node.windowId, node.packageName?.toString(), geometry(area),
            node.className?.toString(), node.viewIdResourceName, node.text?.toString(), node.contentDescription?.toString(),
            node.isSelected, node.isChecked, node.isCheckable, node.isFocused, node.stateDescription?.toString(),
            node.isEditable, node.textSelectionStart, node.textSelectionEnd)
    }

    private fun hasPasswordAncestry(node: AccessibilityNodeInfo, scope: WindowScope): Boolean {
        var ancestor: AccessibilityNodeInfo? = AccessibilityNodeInfo.obtain(node)
        var depth = 0
        try {
            while (ancestor != null && depth++ <= 30) {
                if (ancestor.isPassword || ancestor.windowId != scope.windowId ||
                    ancestor.packageName?.toString()?.let { it != scope.packageName } == true) return true
                val parent = ancestor.parent
                ancestor.recycle()
                ancestor = parent
            }
            return ancestor != null // Cannot prove the ancestry safe.
        } finally { ancestor?.recycle() }
    }

    private fun nodeActionId(action: String): Int = when (action) {
        "click" -> AccessibilityNodeInfo.ACTION_CLICK
        "long_click" -> AccessibilityNodeInfo.ACTION_LONG_CLICK
        "scroll_forward" -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        "scroll_backward" -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        "focus" -> AccessibilityNodeInfo.ACTION_FOCUS
        "paste" -> AccessibilityNodeInfo.ACTION_PASTE
        "copy" -> AccessibilityNodeInfo.ACTION_COPY
        "cut" -> AccessibilityNodeInfo.ACTION_CUT
        "select_all" -> AccessibilityNodeInfo.ACTION_SET_SELECTION
        "set_text" -> AccessibilityNodeInfo.ACTION_SET_TEXT
        else -> throw BridgeFailure("INVALID_ARGUMENT", "Unsupported node action.")
    }

    private fun supportedNodeActions(node: AccessibilityNodeInfo): Set<String> {
        val ids = node.actionList.map { it.id }.toSet()
        return (NodeActionPolicy.actions + "set_text").filter { nodeActionId(it) in ids }.toSet()
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
            requireNodeProtection(scope, node)
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
            else -> setOf("x", "y", "selector", "imageX", "imageY", "screenshotId")
        })
        val scope = windowScope()
        var selected: AccessibilityNodeInfo? = null
        var observed: NodeActionPolicy.Target? = null
        try {
            val mode = if (method == "tap") SelectorPolicy.tapMode(params.keys().asSequence().toSet()) else SelectorPolicy.TapMode.PHYSICAL
            val point = when (mode) {
                SelectorPolicy.TapMode.SELECTOR -> {
                    val node = targetNode(JSONObject().put("selector", params.get("selector")), scope)
                    selected = node
                    requirePointerNode(node, scope)
                    val target = nodeTarget(node)
                    observed = target
                    safeNodeBounds("click", target.bounds, scope)
                    Pair((target.bounds.left + target.bounds.right) / 2f, (target.bounds.top + target.bounds.bottom) / 2f)
                }
                SelectorPolicy.TapMode.IMAGE -> screenshotPoint(params, scope)
                SelectorPolicy.TapMode.PHYSICAL -> Pair(number(params, if (method == "swipe") "x1" else "x"),
                    number(params, if (method == "swipe") "y1" else "y"))
            }
            val x1 = point.first; val y1 = point.second
            val x2 = if (method == "swipe") number(params, "x2") else x1
            val y2 = if (method == "swipe") number(params, "y2") else y1
            val duration = when (method) {
                "long_press" -> duration(params, 600, 400)
                "swipe" -> duration(params, 400, 100)
                else -> 80L
            }
            requireClearGesture(scope, x1, y1, x2, y2)
            if (!contains(scope.bounds, x1, y1) || !contains(scope.bounds, x2, y2)) {
                throw BridgeFailure("OUT_OF_BOUNDS", "Gesture coordinates must be inside the allowed application window.")
            }
            ProtectedControlPolicy.requireGesture(AutomationPreferences.protectConnectionControls(this), scope.packageName == packageName,
                x1, y1, x2, y2, protectedBounds(scope))
            val path = Path().apply { moveTo(x1, y1); if (method == "swipe") lineTo(x2, y2) }
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, duration)).build()
            requireSession(generation, true)
            val recheck = windowScope()
            requireSameWindow(scope, recheck)
            requireClearGesture(recheck, x1, y1, x2, y2)
            selected?.let { node ->
                requirePointerNode(node, recheck)
                NodeActionPolicy.requireUnchanged(observed!!, nodeTarget(node))
                requireNodeProtection(recheck, node)
            }
            if (mode == SelectorPolicy.TapMode.IMAGE) screenshotPoint(params, recheck)
            ProtectedControlPolicy.requireGesture(AutomationPreferences.protectConnectionControls(this), recheck.packageName == packageName,
                x1, y1, x2, y2, protectedBounds(recheck))
            requireSession(generation, true)
            invalidateNodes()
            val accepted = dispatchGesture(gesture, object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    if (BridgeSession.isOperationCurrent(generation)) { invalidateNodes(); complete(completed(), null) }
                    else complete(null, BridgeFailure("CONTROL_EXPIRED", "The control task ended during the gesture."))
                }
                override fun onCancelled(gestureDescription: GestureDescription?) {
                    if (BridgeSession.isOperationCurrent(generation)) {
                        clearOperationTrail(); invalidateNodes()
                        complete(null, BridgeFailure("GESTURE_CANCELLED", "Android cancelled the gesture; observe before retrying."))
                    } else complete(null, BridgeFailure("CONTROL_EXPIRED", "The control task ended during the gesture."))
                }
            }, BridgeSession.main)
            if (!accepted) throw BridgeFailure("ACTION_REJECTED", "Android rejected gesture dispatch.")
            BridgeSession.recordGestureDispatch(generation, duration)
            operationTrail.show(TrailMotion(method, x1, y1, x2, y2, duration))
        } finally { selected?.recycle() }
    }

    private fun requirePointerNode(node: AccessibilityNodeInfo, scope: WindowScope) {
        if (!node.refresh() || node.windowId != scope.windowId || node.packageName?.toString() != scope.packageName)
            throw BridgeFailure("STALE_NODE", "The selected target changed. Refine the selector and observe again.")
        if (!node.isVisibleToUser || !node.isEnabled || hasPasswordAncestry(node, scope))
            throw BridgeFailure("NODE_BLOCKED", "Only visible, enabled, non-password targets accept taps.")
    }

    private fun screenshotPoint(params: JSONObject, scope: WindowScope): Pair<Float, Float> {
        val id = params.opt("screenshotId") as? String ?: throw BridgeFailure("INVALID_ARGUMENT", "screenshotId must be a string.")
        fun coordinate(key: String): Double {
            val value = (params.opt(key) as? Number)?.toDouble() ?: throw BridgeFailure("INVALID_ARGUMENT", "Image coordinates must be integers.")
            if (!value.isFinite() || value != value.toLong().toDouble()) throw BridgeFailure("INVALID_ARGUMENT", "Image coordinates must be integers.")
            return value
        }
        return ScreenshotPolicy.point(lastScreenshot, id, coordinate("imageX"), coordinate("imageY"), uiEpoch, screenshotWindow(scope))
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
                            try {
                                requireSession(generation)
                                if (epoch != uiEpoch) throw BridgeFailure("WINDOW_CHANGED", "Screen changed during capture. Observe again.")
                                val latest = windowScope()
                                requireSameWindow(scope, latest)
                                requireClearCrop(latest)
                                if (encoded == null) throw BridgeFailure("SCREENSHOT_UNAVAILABLE", "Screenshot could not be encoded within the size limit.")
                                val id = UUID.randomUUID().toString()
                                lastScreenshot = ScreenshotPolicy.Frame(id, epoch, screenshotWindow(latest), encoded.getInt("width"), encoded.getInt("height"))
                                encoded.put("screenshotId", id)
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
                if (!BridgeSession.isOperationCurrent(generation)) {
                    complete(null, BridgeFailure("CONTROL_EXPIRED", "The control task ended during capture."))
                } else complete(null, BridgeFailure("SCREENSHOT_UNAVAILABLE",
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
