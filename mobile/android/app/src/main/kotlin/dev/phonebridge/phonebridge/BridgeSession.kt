package dev.phonebridge.phonebridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** Main-thread state; encrypted owner trust is separate from the disposable transport. */
object BridgeSession {
    val main = Handler(Looper.getMainLooper())
    var service: PhoneAccessibilityService? = null
        private set
    var generation = 0L
        private set
    var connected = false
        private set
    var actionsEnabled = false
        private set
    private var connecting = false
    private var lastError = ""
    private var endpoint = ""
    private var socket: WebSocket? = null
    private var client: OkHttpClient? = null
    private var packages = emptySet<String>()
    private var desiredActions = false
    private var pending: String? = null
    private var timeout: Runnable? = null
    private var connectTimeout: Runnable? = null
    private var retryTask: Runnable? = null
    private var retryAttempt = 0
    private var appContext: Context? = null
    private var store: TrustedPairingStore? = null
    private var saved: TrustedPairing? = null
    private var loaded = false
    private const val CHANNEL = "phonebridge_session"
    private const val NOTIFICATION_ID = 8721
    const val STOP_ACTION = "dev.phonebridge.phonebridge.STOP_SESSION"

    fun initialize(context: Context) {
        appContext = context.applicationContext
        if (loaded) return
        try {
            val storage = store ?: TrustedPairingStore(context.applicationContext).also { store = it }
            saved = storage.load()?.also { validatePairing(it) }
            loaded = true
        } catch (_: Exception) {
            // Do not erase an unreadable record; the Keystore may temporarily be unavailable.
            saved = null
            lastError = "Saved pairing is unavailable. Unlock the phone and reopen PhoneBridge."
        }
    }

    fun attach(value: PhoneAccessibilityService) {
        service = value
        initialize(value)
        if (lastError == "Accessibility service stopped.") lastError = ""
        tryAutoResume()
    }

    fun detach(value: PhoneAccessibilityService) {
        if (service === value) {
            closeTransport("Accessibility service stopped.")
            service = null
        }
    }

    fun serviceInterrupted() {
        closeTransport("Accessibility was interrupted.")
        scheduleReconnect()
    }

    fun onOwnerActivityResumed(context: Context) {
        initialize(context)
        tryAutoResume()
    }

    fun status(): Map<String, Any> = mapOf(
        "accessibilityEnabled" to (service != null),
        "connected" to connected,
        "connecting" to connecting,
        "actionsEnabled" to actionsEnabled,
        "lastError" to lastError,
        "endpoint" to endpoint,
        "hasSavedPairing" to (saved != null),
        "savedEndpoint" to (saved?.endpoint ?: ""),
        "autoReconnectEnabled" to (saved?.resumeAllowed == true),
        "rememberedActions" to (saved?.actionsEnabled == true),
        "reconnecting" to (retryTask != null),
    )

    fun isAllowed(packageName: String) = packageName in packages

    private fun validatePairing(record: TrustedPairing) {
        EndpointPolicy.validate(record.endpoint, record.allowInsecureLocal)
        EndpointPolicy.validateToken(record.token)
        require(record.packages.isNotEmpty() && record.packages.size <= 64 &&
            record.packages.all { it.length <= 255 && it.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")) }) {
            "Enter 1–64 valid allowed package names."
        }
    }

    private fun persist(record: TrustedPairing) {
        try {
            (store ?: throw IllegalStateException()).save(record)
            saved = record
            loaded = true
        } catch (_: Exception) {
            // Do not leave older action/resume permission on disk after a failed revocation.
            try { store?.clear() } catch (_: Exception) { }
            saved = null
            loaded = false
            closeTransport("Could not safely save pairing. Please pair again.")
            throw BridgeFailure("PAIRING_STORAGE_FAILED", "Could not safely save pairing. Please pair again.")
        }
    }

    fun requireNotifications(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        try {
            OperationPolicy.requireNotifications(manager.areNotificationsEnabled(),
                manager.getNotificationChannel(CHANNEL)?.importance)
        } catch (error: BridgeFailure) {
            pause("PhoneBridge session notifications were disabled.", ReconnectPolicy.EndReason.NOTIFICATIONS)
            throw error
        }
    }

    fun connect(url: String, token: String, allowInsecureLocal: Boolean, allowed: List<String>, remember: Boolean = true) {
        val native = service ?: throw BridgeFailure("ACCESSIBILITY_DISABLED", "Enable PhoneBridge in Accessibility settings.")
        initialize(native)
        val record = TrustedPairing(EndpointPolicy.validate(url, allowInsecureLocal), token,
            allowInsecureLocal, allowed.distinct(), false, true)
        validatePairing(record)
        native.requireUnlocked()
        val manager = native.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, AppLanguage.resources(native).getString(R.string.session_channel), NotificationManager.IMPORTANCE_LOW))
        requireNotifications(native)
        closeTransport()
        retryAttempt = 0
        if (remember) persist(record) else forgetSavedConnection()
        openTransport(record)
    }

    fun resumeSavedConnection() {
        val native = service ?: throw BridgeFailure("ACCESSIBILITY_DISABLED", "Enable PhoneBridge in Accessibility settings.")
        initialize(native)
        val record = saved ?: throw BridgeFailure("NO_SAVED_PAIRING", "Pair with your computer first.")
        validatePairing(record)
        native.requireUnlocked()
        requireNotifications(native)
        closeTransport()
        retryAttempt = 0
        val resumed = record.copy(resumeAllowed = true)
        persist(resumed)
        openTransport(resumed)
    }

    /** Capture native trust; normal network retries do not invalidate the owner's request. */
    fun prepareDesktopRecovery(): TrustedPairing {
        val native = service ?: throw BridgeFailure("ACCESSIBILITY_DISABLED", "请先开启 PhoneBridge 无障碍服务")
        initialize(native)
        val record = saved ?: throw BridgeFailure("NO_SAVED_PAIRING", "请先与电脑配对")
        validatePairing(record)
        native.requireUnlocked()
        requireNotifications(native)
        if (connected) throw BridgeFailure("BUSY", "手机已连接电脑")
        return record
    }

    fun resumeAfterDesktopRecovery(record: TrustedPairing, ownerService: PhoneAccessibilityService?) {
        // Pause, forget, changed consent/pairing, or a replaced accessibility service invalidates it.
        if (saved !== record || service !== ownerService || ownerService == null) {
            throw BridgeFailure("RECOVERY_CANCELLED", "连接状态已改变，启动请求已取消，请重新确认后操作")
        }
        ownerService.requireUnlocked()
        requireNotifications(ownerService)
        // An automatic reconnect may have succeeded while the HTTP request was pending.
        if (connected) return
        resumeSavedConnection()
    }

    fun forgetSavedConnection() {
        closeTransport()
        try {
            store?.clear()
            saved = null
            loaded = true
        } catch (_: Exception) {
            saved = null
            loaded = false
            lastError = "Saved pairing could not be removed. Try again."
            throw BridgeFailure("PAIRING_STORAGE_FAILED", lastError)
        }
    }

    private fun tryAutoResume() {
        if (connected || connecting || retryTask != null) return
        val record = saved ?: return
        if (!ReconnectPolicy.shouldReconnect(true, record.resumeAllowed, service != null)) return
        try {
            validatePairing(record)
            requireNotifications(service!!)
            service!!.requireUnlocked()
            openTransport(record)
        } catch (error: BridgeFailure) {
            if (error.code == "DEVICE_LOCKED") {
                lastError = "Waiting for the phone to be unlocked."
                scheduleReconnect()
            } else if (error.code != "NOTIFICATIONS_DISABLED") {
                pause("Saved connection needs local attention.", ReconnectPolicy.EndReason.PROTOCOL)
            }
        } catch (_: Exception) {
            pause("Saved pairing is invalid. Pair with your computer again.", ReconnectPolicy.EndReason.PROTOCOL)
        }
    }

    private fun scheduleReconnect() {
        if (!ReconnectPolicy.shouldReconnect(saved != null, saved?.resumeAllowed == true, service != null) ||
            retryTask != null || connected || connecting) return
        val delay = ReconnectPolicy.delayMillis(retryAttempt++)
        retryTask = Runnable {
            retryTask = null
            tryAutoResume()
        }.also { main.postDelayed(it, delay) }
        showNotification()
    }

    private fun transportLost(message: String) {
        closeTransport(message)
        scheduleReconnect()
    }

    private fun pause(message: String, reason: ReconnectPolicy.EndReason) {
        closeTransport(message)
        if (!ReconnectPolicy.permitsAutomaticResume(reason)) {
            try { store?.pauseAutomaticResume() } catch (_: Exception) {
                lastError = "Could not persist Stop. Forget this computer before closing PhoneBridge."
            }
            saved?.let {
                try {
                    persist(it.copy(resumeAllowed = ReconnectPolicy.resumeAllowedAfterEnd(it.resumeAllowed, reason)))
                } catch (_: BridgeFailure) { }
            }
        }
    }

    private fun openTransport(record: TrustedPairing) {
        // This is a new connection only. Pending RPC IDs and messages are never replayed.
        val native = service ?: throw BridgeFailure("ACCESSIBILITY_DISABLED", "Accessibility is unavailable.")
        native.requireUnlocked()
        requireNotifications(native)
        endpoint = record.endpoint
        packages = record.packages.toSet()
        desiredActions = record.actionsEnabled
        connecting = true
        val current = generation
        showNotification()
        val transport = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS)
            .pingInterval(20, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .followRedirects(false)
            .followSslRedirects(false)
            .build()
        client = transport
        val request = Request.Builder().url(record.endpoint)
            .header("Authorization", "Bearer " + record.token).build()
        socket = transport.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                main.post {
                    if (generation != current || socket !== webSocket) {
                        webSocket.cancel()
                        return@post
                    }
                    try {
                        native.requireUnlocked()
                        requireNotifications(native)
                    } catch (error: BridgeFailure) {
                        if (error.code == "DEVICE_LOCKED") transportLost("Waiting for the phone to be unlocked.")
                        return@post
                    }
                    connectTimeout?.let { main.removeCallbacks(it) }
                    connectTimeout = null
                    connecting = false
                    connected = true
                    actionsEnabled = desiredActions
                    retryAttempt = 0
                    lastError = ""
                    if (!webSocket.send(JSONObject().put("type", "hello").put("protocol", 1)
                            .put("device", "Android").put("readOnly", !actionsEnabled).toString())) {
                        transportLost("Connection was interrupted.")
                        return@post
                    }
                    showNotification()
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (text.length > 32768 || text.toByteArray(Charsets.UTF_8).size > 32768) {
                    main.post { if (generation == current) pause("Command exceeded the size limit.", ReconnectPolicy.EndReason.PROTOCOL) }
                    return
                }
                main.post { if (generation == current && socket === webSocket) receive(text, current) }
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                main.post { if (generation == current) pause("Binary commands are not supported.", ReconnectPolicy.EndReason.PROTOCOL) }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                main.post {
                    if (generation != current) return@post
                    if (code == 1002 || code == 1003 || code == 1007 || code == 1008 || code == 1009) {
                        pause("Desktop rejected this session. Resume locally after checking pairing.", ReconnectPolicy.EndReason.PROTOCOL)
                    } else transportLost("Desktop disconnected. Reconnecting to the trusted computer.")
                }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                main.post { if (generation == current) transportLost("Desktop disconnected. Reconnecting to the trusted computer.") }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                main.post {
                    if (generation != current) return@post
                    if ((appContext?.applicationInfo?.flags ?: 0) and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
                        Log.d("PhoneBridgeConnection", "webSocketFailure type=${t.javaClass.simpleName} http=${response?.code ?: "none"}")
                    }
                    if (ReconnectPolicy.isPermanentHttpRejection(response?.code) || t is javax.net.ssl.SSLException) {
                        pause("Pairing or certificate was rejected. Check your computer, then resume locally.",
                            ReconnectPolicy.EndReason.AUTHENTICATION)
                    } else transportLost("Connection lost. Reconnecting to the trusted computer.")
                }
            }
        })
        connectTimeout = Runnable {
            if (generation == current && connecting) transportLost("Connection timed out. Reconnecting to the trusted computer.")
        }.also { main.postDelayed(it, 12000) }
    }

    fun setActionsEnabled(enabled: Boolean) {
        if (enabled) {
            if (!connected) throw BridgeFailure("NO_SESSION", "Connect before enabling actions.")
            service?.requireUnlocked() ?: throw BridgeFailure("ACCESSIBILITY_DISABLED", "Accessibility is unavailable.")
            requireNotifications(service!!)
        }
        // Revocation takes effect in memory before touching the encrypted record.
        if (!enabled) { actionsEnabled = false; desiredActions = false }
        saved?.let { persist(it.copy(actionsEnabled = enabled)) }
        actionsEnabled = enabled
        desiredActions = enabled
        service?.invalidateNodes()
        showNotification()
    }

    /** Explicit owner Stop; keeps credentials, but disables persisted automatic resume. */
    fun disconnect(error: String = "") {
        pause(error, ReconnectPolicy.EndReason.OWNER_STOP)
    }

    private fun closeTransport(error: String = "") {
        generation++
        connected = false
        connecting = false
        actionsEnabled = false
        desiredActions = false
        pending = null
        timeout?.let { main.removeCallbacks(it) }
        connectTimeout?.let { main.removeCallbacks(it) }
        retryTask?.let { main.removeCallbacks(it) }
        timeout = null
        connectTimeout = null
        retryTask = null
        service?.invalidateNodes()
        val oldSocket = socket
        socket = null
        oldSocket?.cancel()
        client?.connectionPool?.evictAll()
        client?.dispatcher?.executorService?.shutdown()
        client = null
        packages = emptySet()
        endpoint = ""
        lastError = error
        appContext?.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }

    private fun receive(text: String, expectedGeneration: Long) {
        if (!connected) return
        val request = try { JSONObject(text) } catch (_: Exception) {
            pause("Invalid command format.", ReconnectPolicy.EndReason.PROTOCOL)
            return
        }
        val id = request.opt("id") as? String
        val method = request.opt("method") as? String
        if (id == null || !id.matches(Regex("[A-Za-z0-9_-]{1,128}")) || method == null) {
            pause("Invalid command format.", ReconnectPolicy.EndReason.PROTOCOL)
            return
        }
        if (pending != null) {
            send(id, null, BridgeFailure("BUSY", "One operation is already in progress."))
            return
        }
        val params = request.opt("params")
        if (params !is JSONObject) {
            send(id, null, BridgeFailure("INVALID_ARGUMENT", "params must be an object."))
            return
        }
        pending = id
        timeout = Runnable {
            if (generation == expectedGeneration && pending == id) {
                send(id, null, BridgeFailure("TIMEOUT", "Operation timed out; outcome may be unknown. Do not retry automatically."))
                if (ReconnectPolicy.timedOutReadCanReconnect(method)) {
                    transportLost("Observation timed out. Reconnecting to the trusted computer.")
                } else {
                    pause("Operation timed out. Resume locally and observe before retrying.", ReconnectPolicy.EndReason.TIMEOUT)
                }
            }
        }.also { main.postDelayed(it, 12000) }
        val complete: (JSONObject?, BridgeFailure?) -> Unit = complete@{ result, error ->
            if (generation != expectedGeneration || pending != id) return@complete
            timeout?.let { main.removeCallbacks(it) }
            timeout = null
            pending = null
            send(id, result, error)
        }
        try {
            val native = service ?: throw BridgeFailure("ACCESSIBILITY_DISABLED", "Accessibility is unavailable.")
            native.execute(method, params, expectedGeneration, complete)
        } catch (error: BridgeFailure) {
            complete(null, error)
        } catch (_: Exception) {
            complete(null, BridgeFailure("UNAVAILABLE", "Android could not complete the operation."))
        }
    }

    private fun send(id: String, result: JSONObject?, error: BridgeFailure?) {
        val message = JSONObject().put("id", id)
        if (error != null) message.put("error", JSONObject().put("code", error.code).put("message", error.message))
        else message.put("result", result ?: JSONObject())
        val encoded = message.toString()
        if (encoded.length > 3 * 1024 * 1024) {
            pause("Operation result exceeded the size limit.", ReconnectPolicy.EndReason.PROTOCOL)
        } else if (socket?.send(encoded) != true) {
            transportLost("Result could not be delivered. Observe after reconnection; never retry automatically.")
        }
    }

    fun refreshNotificationLanguage() { showNotification() }

    private fun showNotification() {
        val context = appContext ?: return
        if (!connected && !connecting && retryTask == null) return
        val stop = PendingIntent.getBroadcast(context, 1,
            Intent(context, StopSessionReceiver::class.java).setAction(STOP_ACTION),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(context, 2, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val strings = AppLanguage.resources(context)
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, strings.getString(R.string.session_channel), NotificationManager.IMPORTANCE_LOW))
        val state = strings.getString(if (retryTask != null) R.string.session_reconnecting else if (connecting) R.string.session_connecting
            else if (actionsEnabled) R.string.session_actions_enabled else R.string.session_read_only)
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("PhoneBridge • " + state)
            .setContentText(strings.getString(R.string.session_description))
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, strings.getString(R.string.session_stop), stop).build())
            .build()
        context.getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
    }
}

class StopSessionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == BridgeSession.STOP_ACTION) {
            BridgeSession.initialize(context)
            BridgeSession.disconnect()
        }
    }
}
