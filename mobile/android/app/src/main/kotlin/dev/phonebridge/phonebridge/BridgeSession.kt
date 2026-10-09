package dev.phonebridge.phonebridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * All session state is main-thread confined, including socket callbacks.
 * No preferences, saved state, work scheduler, reconnect loop, or disk token store.
 */
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
    private var pending: String? = null
    private var timeout: Runnable? = null
    private var connectTimeout: Runnable? = null
    private const val CHANNEL = "phonebridge_session"
    private const val NOTIFICATION_ID = 8721
    const val STOP_ACTION = "dev.phonebridge.phonebridge.STOP_SESSION"

    fun attach(value: PhoneAccessibilityService) {
        service = value
        if (lastError == "Accessibility service stopped.") lastError = ""
    }

    fun detach(value: PhoneAccessibilityService) {
        if (service === value) {
            disconnect("Accessibility service stopped.")
            service = null
        }
    }

    fun status(): Map<String, Any> = mapOf(
        "accessibilityEnabled" to (service != null),
        "connected" to connected,
        "connecting" to connecting,
        "actionsEnabled" to actionsEnabled,
        "lastError" to lastError,
        "endpoint" to endpoint,
    )

    fun isAllowed(packageName: String) = packageName in packages

    fun requireNotifications(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        try {
            OperationPolicy.requireNotifications(manager.areNotificationsEnabled(),
                manager.getNotificationChannel(CHANNEL)?.importance)
        } catch (error: BridgeFailure) {
            disconnect("PhoneBridge session notifications were disabled.")
            throw error
        }
    }

    fun connect(url: String, token: String, allowInsecureLocal: Boolean, allowed: List<String>) {
        val native = service ?: throw BridgeFailure("ACCESSIBILITY_DISABLED", "Enable PhoneBridge in Accessibility settings.")
        val normalized = EndpointPolicy.validate(url, allowInsecureLocal)
        EndpointPolicy.validateToken(token)
        require(allowed.isNotEmpty() && allowed.size <= 64 &&
            allowed.all { it.length <= 255 && it.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")) }) {
            "Enter 1–64 valid allowed package names."
        }
        native.requireUnlocked()
        val manager = native.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "PhoneBridge session", NotificationManager.IMPORTANCE_LOW))
        requireNotifications(native)
        disconnect()
        endpoint = normalized
        packages = allowed.toSet()
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
        // The token exists only in this in-memory Request and is never logged.
        val request = Request.Builder().url(normalized).header("Authorization", "Bearer $token").build()
        socket = transport.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                main.post {
                    if (generation != current || socket !== webSocket) {
                        webSocket.cancel()
                        return@post
                    }
                    connectTimeout?.let { main.removeCallbacks(it) }
                    connectTimeout = null
                    connecting = false
                    connected = true
                    lastError = ""
                    webSocket.send(JSONObject().put("type", "hello").put("protocol", 1)
                        .put("device", "Android").put("readOnly", true).toString())
                    showNotification()
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (text.length > 32768 || text.toByteArray(Charsets.UTF_8).size > 32768) {
                    main.post { if (generation == current) disconnect("Command exceeded the size limit.") }
                    return
                }
                main.post { if (generation == current && socket === webSocket) receive(text, current) }
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                main.post { if (generation == current) disconnect("Binary commands are not supported.") }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                main.post { if (generation == current) disconnect("Desktop disconnected.") }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                main.post { if (generation == current) disconnect("Desktop disconnected.") }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                // Exceptions, server bodies, and peer close reasons may contain secrets.
                main.post { if (generation == current) disconnect("Connection failed. Check pairing, network, and certificate.") }
            }
        })
        connectTimeout = Runnable { if (generation == current && connecting) disconnect("Connection timed out.") }
            .also { main.postDelayed(it, 12000) }
    }

    fun setActionsEnabled(enabled: Boolean) {
        if (enabled) {
            if (!connected) throw BridgeFailure("NO_SESSION", "Connect before enabling actions.")
            service?.requireUnlocked() ?: throw BridgeFailure("ACCESSIBILITY_DISABLED", "Accessibility is unavailable.")
        }
        actionsEnabled = enabled
        service?.invalidateNodes()
        showNotification()
    }

    fun disconnect(error: String = "") {
        generation++
        connected = false
        connecting = false
        actionsEnabled = false
        pending = null
        timeout?.let { main.removeCallbacks(it) }
        connectTimeout?.let { main.removeCallbacks(it) }
        timeout = null
        connectTimeout = null
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
        service?.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }

    private fun receive(text: String, expectedGeneration: Long) {
        if (!connected) return
        val request = try { JSONObject(text) } catch (_: Exception) {
            disconnect("Invalid command format.")
            return
        }
        val id = request.opt("id") as? String
        val method = request.opt("method") as? String
        if (id == null || !id.matches(Regex("[A-Za-z0-9_-]{1,128}")) || method == null) {
            disconnect("Invalid command format.")
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
                disconnect("Operation timed out. Reconnect locally and observe before retrying.")
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
        } catch (e: BridgeFailure) {
            complete(null, e)
        } catch (_: Exception) {
            complete(null, BridgeFailure("UNAVAILABLE", "Android could not complete the operation."))
        }
    }

    private fun send(id: String, result: JSONObject?, error: BridgeFailure?) {
        val message = JSONObject().put("id", id)
        if (error != null) message.put("error", JSONObject().put("code", error.code).put("message", error.message))
        else message.put("result", result ?: JSONObject())
        val encoded = message.toString()
        if (encoded.length > 3 * 1024 * 1024 || socket?.send(encoded) != true) {
            disconnect("Could not send operation result.")
        }
    }

    private fun showNotification() {
        val context = service ?: return
        if (!connected && !connecting) return
        val stop = PendingIntent.getBroadcast(context, 1,
            Intent(context, StopSessionReceiver::class.java).setAction(STOP_ACTION),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(context, 2, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("PhoneBridge • " + if (connecting) "Connecting" else if (actionsEnabled) "Actions enabled" else "Read only")
            .setContentText("Your paired computer can inspect allowed apps. Tap Stop to end access.")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
        context.getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
    }
}

class StopSessionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == BridgeSession.STOP_ACTION) BridgeSession.disconnect()
    }
}
