package dev.phonebridge.phonebridge

import java.io.ByteArrayOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URL
import java.security.SecureRandom
import java.util.Collections
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ExecutorCompletionService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Broadcast first; the HTTP fallback also works with existing TCP-only firewall rules. */
class TrustedComputerDiscovery {
    class Attempt {
        private val cancelled = AtomicBoolean(false)
        private val closers = CopyOnWriteArrayList<() -> Unit>()
        val active get() = !cancelled.get()
        fun onClose(close: () -> Unit) { closers.add(close); if (!active) close() }
        fun cancel() { if (cancelled.compareAndSet(false, true)) closers.forEach { runCatching { it() } }; closers.clear() }
    }
    private data class LocalNetwork(val address: Inet4Address, val prefix: Int, val broadcast: InetAddress?)
    private val workers = Executors.newCachedThreadPool { Thread(it, "phonebridge-discovery").apply { isDaemon = true } }
    private val probes = Executors.newFixedThreadPool(12) { Thread(it, "phonebridge-discovery-probe").apply { isDaemon = true } }
    private val scanOffsets = mutableMapOf<String, Long>()

    fun discover(record: TrustedPairing, complete: (String?) -> Unit): Attempt {
        val attempt = Attempt()
        workers.execute {
            val nonce = ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }
            val networks = localNetworks()
            val endpoint = try { broadcast(record, nonce, networks, attempt) ?: probe(record, nonce, networks, attempt) } catch (_: Exception) { null }
            if (attempt.active) complete(endpoint)
            attempt.cancel()
        }
        return attempt
    }
    private fun localNetworks(): List<LocalNetwork> = try {
        val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces()).filter { it.isUp && !it.isLoopback }
        val physical = interfaces.filter { it.name.startsWith("wlan") || it.name.startsWith("eth") }
        (physical.ifEmpty { interfaces }).flatMap { nic -> nic.interfaceAddresses.mapNotNull {
            val address = it.address as? Inet4Address ?: return@mapNotNull null
            if (!EndpointPolicy.isPrivateLiteral(address.hostAddress ?: "") || address.isLoopbackAddress) null
            else LocalNetwork(address, it.networkPrefixLength.toInt(), it.broadcast)
        } }.distinctBy { it.address.hostAddress }
    } catch (_: Exception) { emptyList() }

    private fun broadcast(record: TrustedPairing, nonce: String, networks: List<LocalNetwork>, attempt: Attempt): String? {
        if (networks.isEmpty() || !attempt.active) return null
        return DatagramSocket().use { socket ->
            attempt.onClose { socket.close() }
            socket.broadcast = true; socket.soTimeout = 200
            val bytes = ComputerDiscoveryProtocol.request(record.token, nonce).toByteArray(Charsets.UTF_8)
            val destinations = (networks.mapNotNull { it.broadcast } + InetAddress.getByName("255.255.255.255")).distinct()
            destinations.forEach { address -> runCatching { socket.send(DatagramPacket(bytes, bytes.size, address, ComputerDiscoveryProtocol.PORT)) } }
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(1200)
            while (attempt.active && System.nanoTime() < deadline) {
                val packet = DatagramPacket(ByteArray(4097), 4097)
                try {
                    socket.receive(packet)
                    if (packet.length <= 4096) ComputerDiscoveryProtocol.verify(String(packet.data, packet.offset, packet.length, Charsets.UTF_8), record, nonce)?.let { return@use it }
                } catch (_: SocketTimeoutException) { }
            }
            null
        }
    }

    private fun probe(record: TrustedPairing, nonce: String, networks: List<LocalNetwork>, attempt: Attempt): String? {
        val original = URI(record.endpoint)
        // HTTPS relies on the original certificate identity; UDP can locate its private endpoint.
        if (original.scheme != "ws" || !record.allowInsecureLocal || !attempt.active) return null
        val port = if (original.port > 0) original.port else 80
        val id = ComputerDiscoveryProtocol.identity(record.token)
        val targets = networks.flatMap { network -> synchronized(scanOffsets) {
            val address = network.address.hostAddress!!
            val key = "$id:$address/${network.prefix}"
            val batch = DiscoveryScanPlan.batch(address, network.prefix, scanOffsets[key] ?: 0L, original.host)
            scanOffsets[key] = batch.nextOffset
            batch.targets
        } }.distinct()
        val completions = ExecutorCompletionService<String?>(probes)
        val futures = targets.map { address -> completions.submit(java.util.concurrent.Callable {
            if (!attempt.active) return@Callable null
            var connection: HttpURLConnection? = null
            try {
                connection = URL("http://$address:$port/discovery?identity=$id&nonce=$nonce").openConnection() as HttpURLConnection
                val current = connection
                attempt.onClose { current.disconnect() }
                current.connectTimeout = 220; current.readTimeout = 350; current.instanceFollowRedirects = false
                if (current.responseCode != 200) return@Callable null
                val output = ByteArrayOutputStream()
                current.inputStream.use { input ->
                    val buffer = ByteArray(1024)
                    while (attempt.active) { val size = input.read(buffer); if (size < 0) break; if (output.size() + size > 4096) return@Callable null; output.write(buffer, 0, size) }
                }
                ComputerDiscoveryProtocol.verify(output.toString("UTF-8"), record, nonce)
            } catch (_: Exception) { null } finally { connection?.disconnect() }
        }) }
        return try {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
            var remaining = futures.size
            var result: String? = null
            while (remaining > 0 && attempt.active && System.nanoTime() < deadline) {
                val done = completions.poll(300, TimeUnit.MILLISECONDS) ?: continue
                remaining--
                result = runCatching { done.get() }.getOrNull()
                if (result != null) break
            }
            result
        } finally { futures.forEach { it.cancel(true) } }
    }
}
