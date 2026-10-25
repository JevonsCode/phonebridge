package dev.phonebridge.phonebridge

import android.app.Notification
import android.app.KeyguardManager
import android.os.PowerManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Main-thread connection manager. Selection, transport life and executing authority are independent. */
object BridgeSession {
    val main = Handler(Looper.getMainLooper())
    var service: PhoneAccessibilityService? = null
        private set
    private data class Transport(val id: String, var record: TrustedPairing, val serial: Long,
        var socket: WebSocket? = null, var client: OkHttpClient? = null,
        var connected: Boolean = false, var connecting: Boolean = false,
        var negotiatedV2: Boolean = false,
        var error: String = "", var retryAttempt: Int = 0, var retry: Runnable? = null,
        var connectTimeout: Runnable? = null)
    private data class Operation(val id: String, val method: String, val transport: Transport,
        val lease: ControlLeaseManager.Lease, val record: TrustedPairing, val generation: Long,
        var timeout: Runnable? = null, var replied: Boolean = false, var invalidated: Boolean = false,
        val socket: WebSocket? = transport.socket)
    private val transports = linkedMapOf<String, Transport>()
    private val discovery = TrustedComputerDiscovery()
    private val discoveries = mutableMapOf<String, TrustedComputerDiscovery.Attempt>()
    private val discoveryTimes = mutableMapOf<String, Long>()
    private val automaticStarts = mutableMapOf<String, DesktopServiceRecovery>()
    private val control = ControlLeaseManager(SystemClock::elapsedRealtime)
    private val operationScope = SessionOperationScope()
    private var lastAuthority: ControlLeaseManager.Lease? = null
    private var lastWaitingCount = 0
    private var execution: Operation? = null
    private var serial = 0L
    /** Remains bound to the dispatched operation until its completion settles the executor fence. */
    val generation: Long get() = operationScope.generation
    val connected: Boolean get() = transports.values.any { it.connected }
    val actionsEnabled: Boolean get() = execution?.let { !it.invalidated && it.record.actionsEnabled }
        ?: (selectedTransport()?.let { it.record.actionsEnabled && it.connected } == true)
    private var context: Context? = null
    private var store: TrustedPairingStore? = null
    private var loaded = false
    private var computers = TrustedComputers()
    var appAccessOpen = false
        private set
    val appAccessBlocked: Boolean get() = AppAccessPolicy.blocksRemote(appAccessOpen,
        context?.let { AutomationPreferences.protectConnectionControls(it) } ?: false)
    // Local editor lifetime, independent of AI operations and control handoffs.
    private var appAccessRevision = 0L
    private var globalError = ""
    private var awake: ScreenAwakeController? = null
    private var deviceId = ""
    var fileInbox: FileInbox? = null
        private set
    private const val CHANNEL = "phonebridge_session"
    private const val NOTIFICATION_ID = 8721
    const val STOP_ACTION = "dev.phonebridge.phonebridge.STOP_SESSION"
    private val leaseTimer = object : Runnable {
        override fun run() {
            authorityChanged()
            if (service != null) main.postDelayed(this, 1000)
        }
    }

    fun initialize(value: Context) {
        context = value.applicationContext
        if (fileInbox == null) fileInbox = FileInbox(value.applicationContext)
        if (awake == null) awake = ScreenAwakeController(value.applicationContext, main)
        if (deviceId.isEmpty()) {
            val prefs = value.getSharedPreferences("phone_identity", Context.MODE_PRIVATE)
            deviceId = prefs.getString("deviceId", null) ?: UUID.randomUUID().toString().also {
                check(prefs.edit().putString("deviceId", it).commit()) { "Could not persist device identity." }
            }
        }
        if (loaded) return
        try {
            store = store ?: TrustedPairingStore(value.applicationContext)
            computers = store!!.list()
            computers.entries.forEach { validatePairing(it.pairing) }
            loaded = true
        } catch (_: Exception) {
            globalError = "Saved pairing is unavailable. Unlock the phone and reopen PhoneBridge."
        }
    }

    fun attach(value: PhoneAccessibilityService) {
        service = value
        initialize(value)
        main.removeCallbacks(leaseTimer)
        main.post(leaseTimer)
        updateAwake()
        tryAutoResume()
    }
    fun detach(value: PhoneAccessibilityService) {
        if (service !== value) return
        cancelAllDiscoveries()
        control.clear()
        authorityChanged()
        transports.values.toList().forEach { close(it, "Accessibility service stopped.") }
        service = null
        main.removeCallbacks(leaseTimer)
        updateAwake()
    }
    fun serviceInterrupted() {
        control.clear()
        authorityChanged()
        transports.values.toList().forEach { close(it, "Accessibility was interrupted."); scheduleReconnect(it) }
    }
    fun onOwnerActivityResumed(value: Context) { initialize(value); updateAwake(); tryAutoResume() }
    fun getScreenAwakeMode(): String = awake?.mode ?: "controlling"
    fun setScreenAwakeMode(mode: String) { awake!!.select(mode); updateAwake() }
    private fun updateAwake() { awake?.update(service != null, control.lease != null) }
    private fun selectedTransport() = computers.activeId?.let { transports[it] } ?: transports["temporary"]
    private fun entry(id: String) = computers.entries.find { it.id == id }
    private fun transportEnabled(t: Transport) = entry(t.id)?.pairing?.resumeAllowed ?: (t.id == "temporary")

    fun status(): Map<String, Any> {
        authorityChanged()
        val selected = selectedTransport()
        val saved = computers.active?.pairing
        val owner = control.lease
        return mapOf("accessibilityEnabled" to (service != null), "connected" to connected,
            "connectedComputerCount" to transports.values.count { it.connected },
            "waitingCount" to control.waitingCount,
            "connecting" to transports.values.any { it.connecting }, "actionsEnabled" to actionsEnabled,
            "lastError" to (selected?.error?.ifEmpty { null } ?: globalError), "endpoint" to (selected?.record?.endpoint ?: ""),
            "hasSavedPairing" to (saved != null), "savedEndpoint" to (saved?.endpoint ?: ""),
            "activeComputerId" to (computers.activeId ?: ""), "computerName" to (computers.active?.name ?: ""),
            "computers" to computerList(), "files" to (fileInbox?.status() ?: emptyList<Map<String, Any>>()),
            "autoReceiveFilesEnabled" to (fileInbox?.autoReceiveEnabled ?: true),
            "clipboardAccessEnabled" to (context?.let { AutomationPreferences.clipboardAccessEnabled(it) } ?: true),
            "protectConnectionControls" to (context?.let { AutomationPreferences.protectConnectionControls(it) } ?: false),
            "saveMediaToGallery" to (fileInbox?.saveMediaToGallery ?: true),
            "allowedPackages" to (saved ?: selected?.record)?.packages.orEmpty(),
            "effectiveAllowedPackages" to (if (selected?.connected == true) selected.record.packages else emptyList<String>()),
            "permissionRevision" to appAccessRevision,
            "autoReconnectEnabled" to (saved?.resumeAllowed == true), "rememberedActions" to (saved?.actionsEnabled == true),
            "reconnecting" to transports.values.any { it.retry != null },
            "controlOwnerId" to (owner?.computerId ?: ""), "controlOwnerName" to (owner?.name ?: ""),
            "awaitingGestureSettlement" to operationScope.awaitingGestureSettlement,
            "executorDiagnostic" to (if (operationScope.awaitingGestureSettlement) OperationTimeoutPolicy.awaitingGestureMessage else ""),
            "controlEvents" to control.events().map { mapOf("event" to it.event, "computerId" to it.computerId, "elapsedMillis" to it.elapsedMillis) },
            "controlling" to (owner != null), "screenAwakeMode" to getScreenAwakeMode(), "screenAwakeHeld" to (awake?.held == true),
            "deviceId" to deviceId, "deviceName" to Build.MODEL)
    }
    fun computerList(): List<Map<String, Any>> = computers.entries.map { c ->
        val t = transports[c.id]
        mapOf("id" to c.id, "name" to c.name, "endpoint" to c.pairing.endpoint,
            "active" to (c.id == computers.activeId), "connected" to (t?.connected == true),
            "connecting" to (t?.connecting == true || t?.retry != null),
            "controlling" to (control.lease?.computerId == c.id), "lastError" to (t?.error ?: ""),
            "state" to (if (control.lease?.computerId == c.id) "controlling" else if (t?.connected == true) "connected"
                else if (t?.connecting == true || t?.retry != null) "connecting" else "paused"),
            "actionsEnabled" to c.pairing.actionsEnabled, "resumeAllowed" to c.pairing.resumeAllowed)
    }
    fun isOperationCurrent(expected: Long): Boolean {
        val op = execution ?: return false
        val leaseValid = control.valid(op.lease)
        if (lastAuthority !== control.lease) authorityChanged()
        return operationScope.isCurrent(expected) && op.generation == expected && !op.invalidated && op.transport.connected &&
            current(op.transport, op.socket) && leaseValid
    }
    /** Acceptance may precede injection by an unbounded queue delay; duration is not settlement. */
    fun recordGestureDispatch(expected: Long, @Suppress("UNUSED_PARAMETER") durationMillis: Long) {
        operationScope.markGestureDispatched(expected)
    }
    fun isAllowed(packageName: String): Boolean = packageName in (execution?.record?.packages ?: computers.active?.pairing?.packages ?: emptyList())
    fun fileSource(): FileInbox.Source = sourceFor(selectedTransport())
    private fun sourceFor(t: Transport?): FileInbox.Source {
        require(t?.connected == true && t.socket != null) { "请先连接电脑" }
        val request = t!!.socket!!.request()
        val url = request.url.newBuilder().encodedPath("/").query(null).fragment(null).build()
        return FileInbox.Source(url.toString().trimEnd('/'), request.header("Authorization")!!,
            entry(t.id)?.name ?: url.host, t.serial)
    }
    fun isFileSourceCurrent(sourceGeneration: Long): Boolean = transports.values.any { it.serial == sourceGeneration && it.connected }
    fun offerFile(params: JSONObject): Map<String, Any> = fileInbox!!.offer(params, sourceFor(execution?.transport))

    private fun validatePairing(record: TrustedPairing) {
        EndpointPolicy.validate(record.endpoint, record.allowInsecureLocal)
        EndpointPolicy.validateToken(record.token)
        AppAccessPolicy.requirePackages(record.packages)
    }
    private fun updateTrust(update: () -> Unit) {
        try { update(); computers = store!!.list(); loaded = true }
        catch (_: Exception) { storageFailure() }
    }
    private fun storageFailure(): Nothing {
        cancelAllDiscoveries()
        try { store?.pauseAutomaticResume(); store?.markActionsPaused() } catch (_: Exception) { }
        computers = computers.copy(entries = computers.entries.map { it.copy(pairing = it.pairing.copy(resumeAllowed = false, actionsEnabled = false)) })
        loaded = false
        control.clear(); authorityChanged()
        transports.values.toList().forEach { close(it, "Could not safely save pairing. Please pair again.") }
        throw BridgeFailure("PAIRING_STORAGE_FAILED", "Could not safely save pairing. Please pair again.")
    }
    fun requireNotifications(value: Context) {
        val manager = value.getSystemService(NotificationManager::class.java)
        try { OperationPolicy.requireNotifications(manager.areNotificationsEnabled(), manager.getNotificationChannel(CHANNEL)?.importance) }
        catch (error: BridgeFailure) { disconnect("PhoneBridge session notifications were disabled."); throw error }
    }
    private fun requireReady(): PhoneAccessibilityService {
        val native = service ?: throw BridgeFailure("ACCESSIBILITY_DISABLED", "Enable PhoneBridge in Accessibility settings.")
        native.requireUnlocked()
        val strings = AppLanguage.resources(native)
        native.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, strings.getString(R.string.session_channel), NotificationManager.IMPORTANCE_LOW))
        requireNotifications(native)
        return native
    }
    fun connect(url: String, token: String, allowInsecureLocal: Boolean, allowed: List<String>, remember: Boolean = true,
                replaceAllowedPackages: Boolean = false) {
        val native = requireReady(); initialize(native)
        val record = computers.forConnection(TrustedPairing(EndpointPolicy.validate(url, allowInsecureLocal), token,
            allowInsecureLocal, allowed.distinct(), false, true), replaceAllowedPackages)
        validatePairing(record)
        transports.remove("temporary")?.let { close(it) }
        if (remember) {
            updateTrust { store!!.save(record) }
            val id = computers.activeId!!
            // Updating a remembered identity must also replace its live consent/allowlist snapshot.
            transports.remove(id)?.let { close(it) }
            control.select(id); authorityChanged(); ensureTransport(id, record)
        } else {
            updateTrust { store!!.deactivate() }
            control.select("temporary"); authorityChanged(); ensureTransport("temporary", record)
        }
        tryAutoResume()
    }

    private fun requireOwnerUnlocked() {
        val value = context ?: throw BridgeFailure("ACTIVITY_CLOSED", "Reopen PhoneBridge.")
        val keyguard = value.getSystemService(KeyguardManager::class.java)
        if (keyguard.isKeyguardLocked || keyguard.isDeviceLocked ||
            !value.getSystemService(PowerManager::class.java).isInteractive) {
            throw BridgeFailure("DEVICE_LOCKED", "Unlock the phone before editing app access.")
        }
        if (!loaded) throw BridgeFailure("PAIRING_STORAGE_FAILED", "Saved trust is unavailable. Reopen PhoneBridge.")
    }

    /** Local MethodChannel only. AI control handoffs never change the editor's target. */
    fun getAppAccess(draft: Boolean, url: String, token: String): Map<String, Any> {
        requireOwnerUnlocked()
        val record = if (draft) {
            val requested = TrustedPairing(EndpointPolicy.validate(url, true), token, true,
                listOf(context!!.packageName, "com.tencent.mm"), false, true)
            validatePairing(requested)
            computers.forConnection(requested)
        } else computers.active?.pairing ?: selectedTransport()?.record
            ?: throw BridgeFailure("NO_SAVED_PAIRING", "Pair with your computer first.")
        val apps = AppAccessCatalog.list(context!!, record.packages)
        appAccessOpen = true
        appAccessRevision++
        execution?.let { if (operationScope.invalidateForOwnerAuthorization(appAccessBlocked)) it.invalidated = true }
        service?.invalidateNodes()
        service?.clearOperationTrail()
        val computer = computers.entries.find { it.pairing.endpoint == record.endpoint && it.pairing.token == record.token }
        return status() + mapOf("allowedPackages" to record.packages, "apps" to apps,
            "computerName" to (computer?.name ?: TrustedComputers.hostName(record.endpoint)))
    }

    fun closeAppAccess() {
        appAccessOpen = false
        appAccessRevision++
        service?.invalidateNodes()
    }

    fun setAllowedPackages(id: String, revision: Long, expected: List<String>, allowed: List<String>): Map<String, Any> {
        requireOwnerUnlocked()
        if (!appAccessOpen) throw BridgeFailure("OWNER_AUTHORIZATION", "Open app access locally first.")
        val selectedId = computers.activeId ?: "temporary"
        val transport = transports[selectedId]
        val saved = computers.active
        val current = saved?.pairing ?: transport?.record
            ?: throw BridgeFailure("NO_SAVED_PAIRING", "Pair with your computer first.")
        AppAccessPolicy.requireSnapshot(id, revision, expected, computers.activeId ?: "", appAccessRevision, current.packages)
        val record = current.copy(packages = allowed.distinct())
        validatePairing(record)
        if (record.packages.toSet() == current.packages.toSet()) return status()
        val reconnect = transport?.let { it.connected || it.connecting || it.retry != null } == true
        // Only this computer loses its old operation snapshot and connection. Other peers stay online.
        transport?.let { close(it) }
        if (saved != null) {
            updateTrust { store!!.update(selectedId, record) }
            if (entry(selectedId)?.pairing != record) storageFailure()
        }
        transport?.record = record
        if (reconnect) {
            try { ensureTransport(selectedId, record) }
            catch (failure: BridgeFailure) { transports[selectedId]?.error = failure.message ?: "Connection unavailable." }
        }
        return status()
    }
    fun selectComputer(id: String) {
        requireReady()
        val c = entry(id) ?: throw BridgeFailure("NO_SAVED_PAIRING", "Pair with your computer first.")
        validatePairing(c.pairing)
        transports.remove("temporary")?.let { close(it) }
        updateTrust { store!!.select(id) }
        control.select(id); authorityChanged()
        ensureTransport(id, entry(id)!!.pairing)
    }
    fun renameComputer(id: String, name: String) { updateTrust { store!!.rename(id, name) } }
    fun setActionsEnabled(enabled: Boolean, computerId: String? = null) {
        val id = computerId ?: computers.activeId ?: "temporary"
        val t = transports[id]
        require(entry(id) != null || t != null) { "Unknown computer." }
        if (enabled) { requireReady(); if (t?.connected != true) throw BridgeFailure("NO_SESSION", "Connect before enabling actions.") }
        if (!enabled && execution?.transport?.id == id) {
            execution?.invalidated = true; operationScope.invalidate(); service?.clearOperationTrail()
        }
        val c = entry(id)
        if (c != null) updateTrust { store!!.update(id, c.pairing.copy(actionsEnabled = enabled)) }
        if (t != null) t.record = (entry(id)?.pairing ?: t.record).copy(actionsEnabled = enabled)
        service?.invalidateNodes(); broadcastStatus(); showNotification()
    }
    /** One local owner action configures the selected trusted computer and shared automation preferences. */
    fun allowAllAutomation(computerId: String? = null): Map<String, Any> {
        requireOwnerUnlocked()
        val id = computerId ?: computers.activeId ?: "temporary"
        val previous = entry(id)?.pairing ?: transports[id]?.record
            ?: throw BridgeFailure("NO_SAVED_PAIRING", "Connect a computer once before enabling automation.")
        val value = context!!
        val packages = AppAccessCatalog.list(value, previous.packages)
            .filter { it["protected"] != true && (it["installed"] == true || it["packageName"] in previous.packages) }
            .map { it["packageName"] as String }.distinct()
        val record = previous.copy(packages = packages, actionsEnabled = true, resumeAllowed = true)
        validatePairing(record)
        val inbox = fileInbox!!
        val clipboard = AutomationPreferences.clipboardAccessEnabled(value)
        val protection = AutomationPreferences.protectConnectionControls(value)
        val gallery = inbox.saveMediaToGallery
        val reception = inbox.autoReceiveEnabled
        try {
            AutomationPreferences.setClipboardAccessEnabled(value, true)
            AutomationPreferences.setProtectConnectionControls(value, false)
            inbox.setSaveMediaToGallery(true)
            // Persist every setting before running downloads or changing the current transport.
            inbox.setAutoReceiveEnabled(true, resumePending = false)
            if (entry(id) != null) updateTrust { store!!.update(id, record) }
        } catch (error: Exception) {
            runCatching { AutomationPreferences.setClipboardAccessEnabled(value, clipboard) }
            runCatching { AutomationPreferences.setProtectConnectionControls(value, protection) }
            runCatching { inbox.setSaveMediaToGallery(gallery) }
            runCatching { inbox.setAutoReceiveEnabled(reception, resumePending = false) }
            throw error
        }
        appAccessRevision++
        // This only expands the selected computer's grants. Its connection and other computers stay live.
        transports[id]?.record = record
        service?.invalidateNodes()
        if (service != null) runCatching { ensureTransport(id, record) }
        inbox.resumePending()
        broadcastStatus(); showNotification()
        return status()
    }
    fun setComputerResumeAllowed(id: String, enabled: Boolean) {
        val c = entry(id) ?: throw IllegalArgumentException("Unknown computer.")
        if (enabled) requireReady()
        updateTrust { store!!.update(id, c.pairing.copy(resumeAllowed = enabled)) }
        if (enabled) ensureTransport(id, entry(id)!!.pairing) else {
            cancelDiscovery(id)
            control.revoke(id); authorityChanged()
            transports[id]?.let { close(it) }
        }
    }
    fun resumeSavedConnection(computerId: String? = null) {
        val id = computerId ?: computers.activeId ?: throw BridgeFailure("NO_SAVED_PAIRING", "Pair with your computer first.")
        setComputerResumeAllowed(id, true)
    }
    fun prepareDesktopRecovery(computerId: String? = null): TrustedPairing {
        requireReady()
        val id = computerId ?: computers.activeId ?: throw BridgeFailure("NO_SAVED_PAIRING", "请先与电脑配对")
        val record = entry(id)?.pairing ?: throw BridgeFailure("NO_SAVED_PAIRING", "请先与电脑配对")
        validatePairing(record)
        if (transports[id]?.connected == true) throw BridgeFailure("BUSY", "手机已连接电脑")
        return record
    }
    fun resumeAfterDesktopRecovery(record: TrustedPairing, ownerService: PhoneAccessibilityService?) {
        val c = computers.entries.find { it.pairing === record }
        if (c == null || service !== ownerService || ownerService == null)
            throw BridgeFailure("RECOVERY_CANCELLED", "连接状态已改变，启动请求已取消，请重新确认后操作")
        requireReady()
        if (transports[c.id]?.connected != true) resumeSavedConnection(c.id)
    }
    fun forgetComputer(id: String) {
        require(entry(id) != null) { "Unknown computer." }
        cancelDiscovery(id)
        transports[id]?.let { close(it); transports.remove(id) }
        control.revoke(id); authorityChanged()
        updateTrust { store!!.forget(id) }
    }
    fun forgetSavedConnection() { computers.activeId?.let { forgetComputer(it) } }
    /** Global owner Stop preserves every credential and pauses every independent transport. */
    fun disconnect(error: String = "") {
        cancelAllDiscoveries()
        control.clear(); authorityChanged()
        transports.values.toList().forEach { close(it, error) }
        try {
            store?.pauseAutomaticResume()
            updateTrust { store!!.pauseAll() }
        } catch (_: Exception) { globalError = "Could not persist Stop. Forget this computer before closing PhoneBridge." }
    }
    private fun tryAutoResume() {
        if (service == null || !loaded) return
        computers.entries.filter { it.pairing.resumeAllowed }.forEach { c ->
            try { requireReady(); ensureTransport(c.id, c.pairing) }
            catch (e: BridgeFailure) {
                if (e.code == "DEVICE_LOCKED") {
                    val t = transports.getOrPut(c.id) { Transport(c.id, c.pairing, ++serial) }
                    t.error = "Waiting for the phone to be unlocked."; scheduleReconnect(t)
                }
            }
        }
    }
    private fun ensureTransport(id: String, record: TrustedPairing) {
        val old = transports[id]
        if (old?.connected == true || old?.connecting == true || old?.retry != null) return
        // Fail before replacing the retry owner, so a newly locked phone keeps its retry timer.
        requireReady()
        old?.let { close(it) }
        val t = Transport(id, record, ++serial, retryAttempt = old?.retryAttempt ?: 0)
        transports[id] = t
        open(t)
    }
    private fun current(t: Transport, expectedSocket: WebSocket? = t.socket): Boolean {
        val active = transports[t.id]
        return active === t && TransportLifecyclePolicy.isCurrent(t.serial, active?.serial, expectedSocket, active?.socket)
    }
    private fun open(t: Transport) {
        val native = requireReady()
        t.connecting = true
        showNotification()
        val client = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS).readTimeout(0, TimeUnit.SECONDS)
            .pingInterval(20, TimeUnit.SECONDS).retryOnConnectionFailure(false).followRedirects(false).followSslRedirects(false).build()
        t.client = client
        val request = Request.Builder().url(t.record.endpoint).header("Authorization", "Bearer " + t.record.token).build()
        t.socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) { main.post {
                if (!current(t) || t.socket !== ws) { ws.cancel(); return@post }
                try { native.requireUnlocked(); requireNotifications(native) }
                catch (_: BridgeFailure) { lost(t, "Waiting for the phone to be unlocked."); return@post }
                t.connectTimeout?.let { main.removeCallbacks(it) }; t.connectTimeout = null
                cancelDiscovery(t.id)
                t.connecting = false; t.connected = true; t.retryAttempt = 0; t.error = ""; globalError = ""
                val hello = JSONObject().put("type", "hello").put("protocol", 1).put("device", "Android").put("readOnly", !t.record.actionsEnabled)
                t.negotiatedV2 = response.header("X-PhoneBridge-Protocol") == "2"
                if (t.negotiatedV2) hello.put("protocol", 2).put("deviceId", deviceId)
                    .put("device", Build.MODEL).put("capabilities", JSONArray(listOf("multi_device", "control_lease", "control_queue", "element_actions", "state_v2", "display_awake", "clipboard", "selectors", "image_coordinates", "text_actions", "control_renew")))
                if (!ws.send(hello.toString())) lost(t, "Connection was interrupted.") else { sendStatus(t); showNotification() }
            } }
            override fun onMessage(ws: WebSocket, text: String) { main.post {
                if (!current(t) || t.socket !== ws) return@post
                if (text.length > 32768 || text.toByteArray(Charsets.UTF_8).size > 32768) pause(t, "Command exceeded the size limit.")
                else receive(t, text)
            } }
            override fun onMessage(ws: WebSocket, bytes: ByteString) { main.post { if (current(t) && t.socket === ws) pause(t, "Binary commands are not supported.") } }
            override fun onClosing(ws: WebSocket, code: Int, reason: String) { main.post {
                if (!current(t) || t.socket !== ws) return@post
                if (code in setOf(1002, 1003, 1007, 1008, 1009)) pause(t, "Desktop rejected this session. Resume locally after checking pairing.")
                else lost(t, "Desktop disconnected. Reconnecting to the trusted computer.")
            } }
            override fun onClosed(ws: WebSocket, code: Int, reason: String) { main.post { if (current(t) && t.socket === ws) lost(t, "Desktop disconnected. Reconnecting to the trusted computer.") } }
            override fun onFailure(ws: WebSocket, error: Throwable, response: Response?) { main.post {
                if (!current(t) || t.socket !== ws) return@post
                if (ReconnectPolicy.isPermanentHttpRejection(response?.code) || error is javax.net.ssl.SSLException)
                    pause(t, "Pairing or certificate was rejected. Check your computer, then resume locally.")
                else lost(t, "Connection lost. Reconnecting to the trusted computer.")
            } }
        })
        t.connectTimeout = Runnable { if (current(t) && t.connecting) lost(t, "Connection timed out. Reconnecting to the trusted computer.") }
            .also { main.postDelayed(it, 12000) }
    }
    private fun cancelDiscovery(id: String) {
        discoveries.remove(id)?.cancel()
        automaticStarts.remove(id)?.close()
    }
    private fun cancelAllDiscoveries() {
        (discoveries.keys + automaticStarts.keys).toSet().forEach(::cancelDiscovery)
    }
    private fun discoverComputer(t: Transport) {
        val saved = entry(t.id)?.pairing ?: return
        if (!saved.resumeAllowed || !loaded || service == null || discoveries.containsKey(t.id) || automaticStarts.containsKey(t.id)) return
        val now = SystemClock.elapsedRealtime()
        val previous = discoveryTimes[t.id]
        if (previous != null && now - previous < 10000) return
        discoveryTimes[t.id] = now
        t.error = "Saved computer address is unavailable. Finding this computer on the current network."
        val ownerService = service
        lateinit var attempt: TrustedComputerDiscovery.Attempt
        attempt = discovery.discover(saved) { endpoint -> main.post {
            if (discoveries[t.id] !== attempt) return@post
            discoveries.remove(t.id)
            val currentRecord = entry(t.id)?.pairing
            if (endpoint == null || service !== ownerService || service == null ||
                !ComputerDiscoveryProtocol.sameResumableTrust(saved, currentRecord) || transports[t.id]?.connected == true) return@post
            val restored = currentRecord!!.copy(endpoint = endpoint)
            try {
                validatePairing(restored)
                if (endpoint != saved.endpoint) {
                    transports[t.id]?.let { close(it) }
                    updateTrust { store!!.update(t.id, restored) }
                }
                val recovery = DesktopServiceRecovery()
                automaticStarts[t.id] = recovery
                recovery.start(restored) { _ -> main.post {
                    if (automaticStarts[t.id] !== recovery) return@post
                    automaticStarts.remove(t.id); recovery.close()
                    val latest = entry(t.id)?.pairing
                    if (service === ownerService && latest != null &&
                        ComputerDiscoveryProtocol.sameResumableTrust(restored, latest)) {
                        try { ensureTransport(t.id, latest) } catch (_: Exception) { transports[t.id]?.let(::scheduleReconnect) }
                    }
                } }
                // The management endpoint may be an older release; reconnect independently.
                ensureTransport(t.id, entry(t.id)!!.pairing)
            } catch (_: Exception) { transports[t.id]?.let(::scheduleReconnect) }
        } }
        discoveries[t.id] = attempt
    }
    private fun scheduleReconnect(t: Transport) {
        if (!current(t) || !transportEnabled(t) || service == null || t.connected || t.connecting || t.retry != null) return
        t.retry = Runnable {
            t.retry = null
            if (!current(t) || !transportEnabled(t)) return@Runnable
            try { ensureTransport(t.id, entry(t.id)?.pairing ?: t.record) }
            catch (_: Exception) { scheduleReconnect(t) }
        }.also { main.postDelayed(it, ReconnectPolicy.delayMillis(t.retryAttempt++)) }
        showNotification()
    }
    private fun lost(t: Transport, error: String) {
        if (!current(t)) return
        close(t, error); discoverComputer(t); scheduleReconnect(t)
    }
    private fun pause(t: Transport, error: String) {
        if (!current(t)) return
        cancelDiscovery(t.id)
        control.revoke(t.id); authorityChanged()
        close(t, error)
        entry(t.id)?.let { c -> updateTrust { store!!.update(t.id, c.pairing.copy(resumeAllowed = false)) } }
    }
    private fun close(t: Transport, error: String = "") {
        control.disconnect(t.id, t.serial)
        if (execution?.transport === t) execution?.invalidated = true
        authorityChanged()
        t.connected = false; t.connecting = false; t.error = error
        t.retry?.let { main.removeCallbacks(it) }; t.retry = null
        t.connectTimeout?.let { main.removeCallbacks(it) }; t.connectTimeout = null
        val old = t.socket; t.socket = null; old?.cancel()
        t.client?.connectionPool?.evictAll(); t.client?.dispatcher?.executorService?.shutdown(); t.client = null
        fileInbox?.disconnected(t.serial)
        showNotification()
    }
    private fun authorityChanged() {
        control.advance(operationScope.pending == null && service != null) { id, connection ->
            transports[id]?.let { it.serial == connection && it.connected && current(it) } == true
        }
        execution?.let { if (!control.valid(it.lease)) { it.invalidated = true; operationScope.invalidate() } }
        val ownerChanged = lastAuthority !== control.lease
        if (ownerChanged) {
            lastAuthority = control.lease
            service?.clearOperationTrail(); service?.invalidateNodes()
        }
        if (ownerChanged || lastWaitingCount != control.waitingCount) broadcastStatus()
        lastWaitingCount = control.waitingCount
        flushControlEvents()
        updateAwake(); showNotification()
    }
    private fun receive(t: Transport, text: String) {
        if (!t.connected) return
        val request = try { JSONObject(text) } catch (_: Exception) { pause(t, "Invalid command format."); return }
        val id = request.opt("id") as? String
        val method = request.opt("method") as? String
        if (id == null || !id.matches(Regex("[A-Za-z0-9_-]{1,128}")) || method == null) { pause(t, "Invalid command format."); return }
        val params = request.opt("params")
        if (params !is JSONObject) { send(t, id, null, BridgeFailure("INVALID_ARGUMENT", "params must be an object.")); return }
        try {
            if (request.has("controlId") && request.opt("controlId") !is String) throw BridgeFailure("INVALID_ARGUMENT", "controlId must be a UUID.")
            val task = request.opt("controlId") as? String
            val name = entry(t.id)?.name ?: "Computer"
            if (method == "acquire_control" || method == "release_control" || method == "control_status" || method == "renew_control") {
                val controlId = params.opt("controlId") as? String ?: task ?: throw BridgeFailure("INVALID_ARGUMENT", "controlId must be a UUID.")
                if (task != null && task != controlId) throw BridgeFailure("INVALID_ARGUMENT", "Conflicting control IDs.")
                if (method == "acquire_control") {
                    requireReady()
                    if (params.has("queue") && params.opt("queue") !is Boolean)
                        throw BridgeFailure("INVALID_ARGUMENT", "queue must be a boolean.")
                    val queue = params.optBoolean("queue", false)
                    if (!queue) operationScope.requireIdle()
                    val result = control.request(t.id, t.serial, name, controlId, queue,
                        operationScope.pending == null) { computerId, connection ->
                            transports[computerId]?.let { it.serial == connection && it.connected && current(it) } == true
                        }
                    authorityChanged()
                    send(t, id, taskStatus(result), null)
                } else if (method == "renew_control") {
                    send(t, id, taskStatus(control.renew(t.id, t.serial, controlId)), null)
                    authorityChanged()
                } else if (method == "control_status") {
                    control.status(t.id, t.serial, controlId)
                    authorityChanged()
                    send(t, id, taskStatus(control.status(t.id, t.serial, controlId)), null)
                } else {
                    val result = control.release(t.id, t.serial, controlId)
                    authorityChanged()
                    send(t, id, taskStatus(result).put("released", true), null)
                }
                updateAwake(); return
            }
            if (method !in setOf("file_offer", "state", "screenshot", "tap", "long_press", "swipe", "set_text",
                    "node_action", "commit_text", "global_action", "launch_app", "get_clipboard", "set_clipboard"))
                throw BridgeFailure("UNKNOWN_METHOD", "Unknown Android method.")
            if (appAccessBlocked) throw BridgeFailure("OWNER_AUTHORIZATION", "Complete app authorization locally on the phone.")
            // Invalid explicit tasks must report terminal expiry even while another operation is running.
            if (execution != null) {
                if (task != null) control.requireExistingControl(t.id, t.serial, task)
                operationScope.requireIdle()
            }
            val before = control.lease
            val lease = control.authorize(t.id, t.serial, name, task)
            if (before !== lease) authorityChanged()
            updateAwake()
            check(operationScope.begin(id))
            val op = Operation(id, method, t, lease, t.record.copy(), operationScope.generation)
            execution = op
            val complete: (JSONObject?, BridgeFailure?) -> Unit = { result, error -> main.post { settle(op, result, error) } }
            op.timeout = Runnable {
                if (execution !== op || op.replied) return@Runnable
                op.invalidated = true
                operationScope.invalidate()
                op.replied = true
                if (current(t, op.socket)) {
                    send(t, id, null, BridgeFailure("TIMEOUT", "Operation timed out; outcome may be unknown. Do not retry automatically."))
                    if (ReconnectPolicy.timedOutReadCanReconnect(method))
                        lost(t, "Observation timed out. Reconnecting to the trusted computer.")
                    else pause(t, "Operation timed out. Resume locally and observe before retrying.")
                }
                // Read-only callbacks cannot apply late results. A delayed, never-dispatched call
                // fails its authority check. Accepted gestures retain the fence until the real
                // Android completion/cancellation callback, regardless of elapsed time.
                if (operationScope.canSettleOnTimeout()) settle(op, null, null)
            }.also { main.postDelayed(it, 12000) }
            try {
                val native = service ?: throw BridgeFailure("ACCESSIBILITY_DISABLED", "Accessibility is unavailable.")
                native.execute(method, params, op.generation, complete)
            } catch (e: BridgeFailure) { complete(null, e) }
            catch (_: Exception) { complete(null, BridgeFailure("UNAVAILABLE", "Android could not complete the operation.")) }
        } catch (e: BridgeFailure) {
            authorityChanged()
            send(t, id, null, e)
        }
    }
    private fun settle(op: Operation, result: JSONObject?, error: BridgeFailure?) {
        if (execution !== op) return
        val valid = isOperationCurrent(op.generation)
        op.timeout?.let { main.removeCallbacks(it) }
        execution = null
        check(operationScope.complete(op.id, op.generation))
        if (!op.replied && current(op.transport) && op.transport.connected)
            send(op.transport, op.id, if (valid) result else null,
                if (valid) error else BridgeFailure("CONTROL_EXPIRED", "This control task has ended. Acquire a new task explicitly."))
        authorityChanged()
    }
    private fun send(t: Transport, id: String, result: JSONObject?, error: BridgeFailure?) {
        if (!current(t) || !t.connected) return
        val message = JSONObject().put("id", id)
        if (error != null) message.put("error", JSONObject().put("code", error.code).put("message", error.message)
            .also { if (error.details.isNotEmpty()) it.put("details", JSONObject(error.details)) })
        else message.put("result", result ?: JSONObject())
        val encoded = message.toString()
        if (encoded.length > 3 * 1024 * 1024) pause(t, "Operation result exceeded the size limit.")
        else if (t.connected && t.socket?.send(encoded) != true) lost(t, "Result could not be delivered. Observe after reconnection; never retry automatically.")
    }
    private fun broadcastStatus() { transports.values.toList().forEach(::sendStatus) }
    private fun sendStatus(t: Transport) {
        if (!current(t)) return
        val owner = control.lease
        val message = TransportStatusPolicy.message(t.negotiatedV2, t.connected, t.record.actionsEnabled,
            t.id, owner?.computerId, owner?.name, control.waitingCount) ?: return
        val socket = t.socket ?: return
        if (!socket.send(message.toString())) main.post {
            if (current(t, socket)) lost(t, "Connection status could not be delivered.")
        }
    }
    fun refreshNotificationLanguage() { showNotification() }
    private fun taskStatus(value: ControlLeaseManager.TaskStatus): JSONObject = JSONObject()
        .put("controlId", value.controlId).put("state", value.state).apply {
            value.position?.let { put("position", it) }
            value.ownerName?.let { put("ownerName", it) }
            value.expiresInMs?.let { put("expiresInMs", it) }
        }
    private fun flushControlEvents() {
        control.drainControlEvents().forEach { event ->
            val t = transports[event.computerId] ?: return@forEach
            if (!current(t) || t.serial != event.connection || !t.connected || !t.negotiatedV2) return@forEach
            val message = JSONObject().put("type", "control_event").put("controlId", event.controlId).put("state", event.state)
            event.position?.let { message.put("position", it) }
            event.ownerName?.let { message.put("ownerName", it) }
            val socket = t.socket ?: return@forEach
            if (!socket.send(message.toString())) main.post {
                if (current(t, socket)) lost(t, "Control notification could not be delivered.")
            }
        }
    }
    private fun showNotification() {
        val value = context ?: return
        val manager = value.getSystemService(NotificationManager::class.java)
        if (transports.values.none { it.connected || it.connecting || it.retry != null }) { manager.cancel(NOTIFICATION_ID); return }
        val stop = PendingIntent.getBroadcast(value, 1, Intent(value, StopSessionReceiver::class.java).setAction(STOP_ACTION), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(value, 2, Intent(value, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val strings = AppLanguage.resources(value)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, strings.getString(R.string.session_channel), NotificationManager.IMPORTANCE_LOW))
        val state = strings.getString(if (transports.values.any { it.retry != null }) R.string.session_reconnecting
            else if (!connected) R.string.session_connecting else if (actionsEnabled) R.string.session_actions_enabled else R.string.session_read_only)
        manager.notify(NOTIFICATION_ID, Notification.Builder(value, CHANNEL).setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("PhoneBridge • $state").setContentText(strings.getString(R.string.session_description))
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, strings.getString(R.string.session_stop), stop).build()).build())
    }
}

class StopSessionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == BridgeSession.STOP_ACTION) { BridgeSession.initialize(context); BridgeSession.disconnect() }
    }
}
