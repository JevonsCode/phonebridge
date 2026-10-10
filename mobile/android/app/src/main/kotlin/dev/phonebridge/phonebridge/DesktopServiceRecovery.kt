package dev.phonebridge.phonebridge

import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject
import java.io.IOException
import java.net.URI
import java.util.concurrent.TimeUnit

/** Native-only pairing credentials, default TLS verification, one request and no redirect/retry. */
class DesktopServiceRecovery {
    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .callTimeout(20, TimeUnit.SECONDS)
        .retryOnConnectionFailure(false)
        .followRedirects(false)
        .followSslRedirects(false)
        .build()

    fun start(record: TrustedPairing, complete: (BridgeFailure?) -> Unit): Call {
        val request = Request.Builder()
            .url(startEndpoint(record.endpoint, record.allowInsecureLocal))
            .header("Authorization", "Bearer " + record.token)
            .post(ByteArray(0).toRequestBody(null))
            .build()
        return client.newCall(request).also { call ->
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    // Exception text may contain URLs or credential details; never forward/log it.
                    complete(BridgeFailure("DESKTOP_UNREACHABLE", "无法联系电脑，请确认电脑已开机并连接同一网络"))
                }

                override fun onResponse(call: Call, response: Response) {
                    val failure = try { response.use {
                        when (it.code) {
                            401, 403 -> BridgeFailure("DESKTOP_AUTH_FAILED", "电脑拒绝了配对身份，请检查电脑端配对设置")
                            404, 405 -> BridgeFailure("DESKTOP_UPDATE_REQUIRED", "电脑端尚不支持一键启动，请更新并安装电脑端后台服务")
                            200 -> {
                                // Bound input before parsing, and require an actual boolean true.
                                val source = it.body?.source()
                                source?.request(4097)
                                val text = if (source != null && source.buffer.size <= 4096)
                                    source.buffer.readUtf8() else ""
                                if (text.length <= 4096 && readyResponse(text)) null
                                else BridgeFailure("DESKTOP_START_FAILED", "电脑服务未确认启动成功，请检查电脑端后台服务")
                            }
                            else -> BridgeFailure("DESKTOP_START_FAILED", "电脑服务启动失败，请检查电脑端后台服务")
                        }
                    } } catch (_: Exception) {
                        BridgeFailure("DESKTOP_START_FAILED", "电脑服务未确认启动成功，请检查电脑端后台服务")
                    }
                    complete(failure)
                }
            })
        }
    }

    fun close() {
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
    }

    companion object {
        fun startEndpoint(endpoint: String, allowInsecureLocal: Boolean): String {
            val uri = URI(EndpointPolicy.validate(endpoint, allowInsecureLocal))
            return URI(if (uri.scheme == "wss") "https" else "http", null,
                uri.host, uri.port, "/service/start", null, null).toASCIIString()
        }

        internal fun readyResponse(text: String): Boolean = try {
            JSONObject(text).opt("serviceRunning") == true
        } catch (_: Exception) { false }
    }
}
