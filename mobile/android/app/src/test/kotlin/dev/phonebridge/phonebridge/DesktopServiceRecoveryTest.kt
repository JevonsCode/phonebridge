package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class DesktopServiceRecoveryTest {
    @Test fun endpointPreservesAuthorityAndTls() {
        assertEquals("http://192.168.31.159:8767/service/start",
            DesktopServiceRecovery.startEndpoint("ws://192.168.31.159:8767/device", true))
        assertEquals("https://desktop.example:443/service/start",
            DesktopServiceRecovery.startEndpoint("wss://desktop.example:443/device", false))
        assertEquals("http://[::1]:8767/service/start",
            DesktopServiceRecovery.startEndpoint("ws://[::1]:8767/device", true))
    }

    @Test fun endpointRejectsUntrustedOrAmbiguousAddresses() {
        for (endpoint in listOf("ws://8.8.8.8/device", "wss://user:pass@desktop/device",
            "wss://desktop/device?target=other", "wss://desktop/arbitrary")) {
            assertThrows(IllegalArgumentException::class.java) {
                DesktopServiceRecovery.startEndpoint(endpoint, true)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            DesktopServiceRecovery.startEndpoint("ws://192.168.1.1/device", false)
        }
    }

    @Test fun readinessRequiresExplicitBoolean() {
        assertTrue(DesktopServiceRecovery.readyResponse("{\"serviceRunning\":true}"))
        for (text in listOf("{}", "{\"serviceRunning\":false}", "{\"serviceRunning\":\"true\"}", "not json")) {
            assertFalse(DesktopServiceRecovery.readyResponse(text))
        }
    }

    @Test fun requestIsEmptyAuthenticatedAndHasNoBrowserOrigin() {
        val result = request(200, "{\"serviceRunning\":true}")
        assertNull(result.failure)
        assertEquals("POST /service/start HTTP/1.1", result.headers.first())
        assertTrue(result.headers.contains("Authorization: Bearer " + "A".repeat(32)))
        assertTrue(result.headers.contains("Content-Length: 0"))
        assertFalse(result.headers.any { it.startsWith("Origin:", true) })
    }

    @Test fun errorsAreCategorizedAndRedirectsNeverFollowed() {
        assertEquals("DESKTOP_AUTH_FAILED", request(401, "").failure?.code)
        assertEquals("DESKTOP_AUTH_FAILED", request(403, "").failure?.code)
        assertEquals("DESKTOP_UPDATE_REQUIRED", request(404, "").failure?.code)
        assertEquals("DESKTOP_UPDATE_REQUIRED", request(405, "").failure?.code)
        assertEquals("DESKTOP_START_FAILED", request(503, "").failure?.code)
        assertEquals("DESKTOP_START_FAILED", request(200, "{\"serviceRunning\":false}").failure?.code)
        assertEquals("DESKTOP_START_FAILED", request(200, "x".repeat(4097)).failure?.code)
        assertEquals("DESKTOP_START_FAILED", request(302, "", "Location: http://127.0.0.1:1/secret\r\n").failure?.code)
    }

    private data class Outcome(val headers: List<String>, val failure: BridgeFailure?)

    private fun request(code: Int, body: String, extra: String = ""): Outcome {
        val server = ServerSocket(0)
        server.soTimeout = 5000
        val headers = AtomicReference<List<String>>()
        val failure = AtomicReference<BridgeFailure?>()
        val serverError = AtomicReference<Throwable?>()
        val complete = CountDownLatch(1)
        val worker = Thread {
            try {
                server.accept().use { socket ->
                    socket.soTimeout = 5000
                    val reader = socket.getInputStream().bufferedReader()
                    val lines = mutableListOf<String>()
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.isEmpty()) break
                        lines.add(line)
                    }
                    headers.set(lines)
                    val bytes = body.toByteArray(Charsets.UTF_8)
                    socket.getOutputStream().apply {
                        write(("HTTP/1.1 $code Test\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n" + extra + "\r\n").toByteArray())
                        write(bytes)
                        flush()
                    }
                }
            } catch (error: Throwable) { serverError.set(error) }
        }.apply { start() }
        val recovery = DesktopServiceRecovery()
        try {
            recovery.start(TrustedPairing("ws://127.0.0.1:${server.localPort}/device", "A".repeat(32),
                true, listOf("dev.phonebridge.phonebridge"), false, false)) {
                failure.set(it)
                complete.countDown()
            }
            assertTrue("Recovery response timed out", complete.await(5, TimeUnit.SECONDS))
            worker.join(5000)
            serverError.get()?.let { throw AssertionError(it) }
            return Outcome(headers.get(), failure.get())
        } finally {
            recovery.close()
            server.close()
        }
    }
}
