package dev.phonebridge.phonebridge

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class AppUpdaterTest {
    private val apk = ByteArray(150000) { (it % 251).toByte() }
    private val officialApk = "https://github.com/JevonsCode/phonebridge/releases/download/v0.2.4-preview.1/PhoneBridge-arm64.apk"

    private fun manifest(url: String = officialApk, code: Long = 2008, bytes: ByteArray = apk): String = JSONObject()
        .put("schema", 1).put("versionName", "0.2.4").put("versionCode", code).put("apkUrl", url)
        .put("sha256", UpdateProtocol.hex(MessageDigest.getInstance("SHA-256").digest(bytes)))
        .put("size", bytes.size).put("notes", "Test release").toString()

    @Test fun officialPolicyRejectsUntrustedAndAmbiguousOrigins() {
        val protocol = UpdateProtocol()
        try {
            assertEquals(2008L, protocol.parse(manifest()).versionCode)
            for (url in listOf("http://github.com/JevonsCode/phonebridge/releases/download/v1/a.apk",
                "https://github.com/other/phonebridge/releases/download/v1/a.apk", "$officialApk?token=secret",
                "$officialApk#fragment", "https://user@github.com/JevonsCode/phonebridge/releases/download/v1/a.apk",
                "https://github.com:8443/JevonsCode/phonebridge/releases/download/v1/a.apk",
                "https://github.com/JevonsCode/phonebridge/releases/download/v1/%2e%2e.apk")) {
                assertFalse(url, protocol.allowedApkUrl(url))
                assertThrows(UpdateFailure::class.java) { protocol.parse(manifest(url)) }
            }
        } finally { protocol.close() }
    }

    @Test fun strictManifestHasBoundedAndTypedRequiredFields() {
        val protocol = UpdateProtocol()
        try {
            val mutations: List<(JSONObject) -> Unit> = listOf(
                { it.put("schema", 2) }, { it.put("versionCode", "2008") }, { it.put("versionCode", 2008.1) },
                { it.put("versionCode", 0) }, { it.put("size", -1) }, { it.put("size", UpdateProtocol.MAX_APK + 1) },
                { it.put("sha256", "bad") }, { it.put("versionName", "") }, { it.put("notes", false) },
                { it.remove("apkUrl") })
            mutations.forEach { mutation ->
                val json = JSONObject(manifest()); mutation(json)
                assertThrows(UpdateFailure::class.java) { protocol.parse(json.toString()) }
            }
            assertThrows(UpdateFailure::class.java) { protocol.parse("x".repeat(UpdateProtocol.MAX_MANIFEST + 1)) }
        } finally { protocol.close() }
    }

    @Test fun compileTimeFixtureRequiresPrivateOriginAndSameOriginApk() {
        for (url in listOf("http://127.0.0.1/update.json", "http://8.8.8.8/update.json", "https://192.168.1.1/update.json"))
            assertThrows(IllegalArgumentException::class.java) { UpdateProtocol(url) }
        val protocol = UpdateProtocol("http://192.168.1.20:1234/update.json")
        try {
            assertTrue(protocol.allowedApkUrl("http://192.168.1.20:1234/update.apk"))
            assertFalse(protocol.allowedApkUrl("http://192.168.1.20:4321/update.apk"))
            assertFalse(protocol.allowedApkUrl(officialApk))
        } finally { protocol.close() }
    }

    @Test fun realHttpDownloadsAreBoundedHashedAndUnauthenticated() = Fixture().use { fixture ->
        fixture.respond = { path -> Response(if (path == "/update.json") manifest(fixture.apkUrl).toByteArray() else apk) }
        val protocol = UpdateProtocol(fixture.manifestUrl)
        val directory = Files.createTempDirectory("updater-test").toFile()
        try {
            val parsed = protocol.check()
            val partial = File(directory, "partial")
            val progress = mutableListOf<Long>()
            protocol.download(parsed, partial) { progress.add(it) }
            assertArrayEquals(apk, partial.readBytes())
            assertEquals(apk.size.toLong(), progress.last())
            protocol.verifyBytes(partial, parsed)
            assertFalse(fixture.headers.any { lines -> lines.any { it.startsWith("Authorization:", true) || it.startsWith("Cookie:", true) } })
            fixture.respond = { Response(ByteArray(apk.size) { 9 }) }
            assertEquals("APK_HASH_MISMATCH", assertThrows(UpdateFailure::class.java) { protocol.download(parsed, partial) {} }.code)
            assertFalse(partial.exists())
            fixture.respond = { Response(apk.copyOf(apk.size - 1)) }
            assertEquals("APK_LENGTH_MISMATCH", assertThrows(UpdateFailure::class.java) { protocol.download(parsed, partial) {} }.code)
            assertFalse(partial.exists())
            fixture.respond = { Response(apk.copyOf(apk.size - 1), advertisedSize = apk.size) }
            val requestsBeforeTruncation = fixture.headers.size
            assertThrows(java.io.IOException::class.java) { protocol.download(parsed, partial) {} }
            assertFalse(partial.exists())
            assertEquals("Body-stream failures must not replay downloads", requestsBeforeTruncation + 1, fixture.headers.size)
        } finally { protocol.close(); directory.deleteRecursively() }
    }

    @Test fun realHttpRejectsOversizedManifestNetworkErrorsAndRedirects() = Fixture().use { fixture ->
        val protocol = UpdateProtocol(fixture.manifestUrl)
        try {
            fixture.respond = { Response(ByteArray(UpdateProtocol.MAX_MANIFEST + 1)) }
            assertEquals("INVALID_MANIFEST", assertThrows(UpdateFailure::class.java) { protocol.check() }.code)
            fixture.respond = { Response(ByteArray(0), code = 503) }
            assertEquals("UPDATE_CHECK_FAILED", assertThrows(UpdateFailure::class.java) { protocol.check() }.code)
            fixture.respond = { Response(ByteArray(0), code = 302, extra = "Location: http://8.8.8.8/private\r\n") }
            assertEquals("UPDATE_REDIRECT_REJECTED", assertThrows(UpdateFailure::class.java) { protocol.check() }.code)
        } finally { protocol.close() }
    }

    @Test fun staleManifestKeepAliveConnectionRecoversApkGetOnFreshSocket() {
        val address = Collections.list(NetworkInterface.getNetworkInterfaces()).flatMap { Collections.list(it.inetAddresses) }
            .filterIsInstance<Inet4Address>().first { UpdateProtocol.privateIpv4(it.hostAddress) }.hostAddress!!
        val server = ServerSocket(0).apply { soTimeout = 6000 }
        val origin = "http://$address:${server.localPort}"
        val releaseStaleSocket = CountDownLatch(1)
        val staleSocketClosed = CountDownLatch(1)
        val requests = LinkedBlockingQueue<String>()
        val serverFailure = AtomicReference<Throwable?>()
        fun readRequest(socket: Socket) {
            socket.soTimeout = 5000
            val reader = socket.getInputStream().bufferedReader()
            requests.add(reader.readLine())
            while (!reader.readLine().isNullOrEmpty()) {}
        }
        val fixture = Thread {
            try {
                server.accept().use { first ->
                    readRequest(first)
                    val bytes = manifest("$origin/update.apk").toByteArray()
                    first.getOutputStream().apply {
                        write(("HTTP/1.1 200 OK\r\nContent-Length: ${bytes.size}\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\n\r\n").toByteArray())
                        write(bytes); flush()
                    }
                    // The client has fully consumed the manifest and pooled this connection.
                    assertTrue(releaseStaleSocket.await(5, TimeUnit.SECONDS))
                }
                staleSocketClosed.countDown()
                server.accept().use { fresh ->
                    readRequest(fresh)
                    fresh.getOutputStream().apply {
                        write(("HTTP/1.1 200 OK\r\nContent-Length: ${apk.size}\r\nConnection: close\r\n\r\n").toByteArray())
                        write(apk); flush()
                    }
                }
            } catch (error: Exception) { if (!server.isClosed) serverFailure.set(error) }
        }.apply { isDaemon = true; start() }
        val protocol = UpdateProtocol("$origin/update.json")
        val directory = Files.createTempDirectory("stale-update-test").toFile()
        try {
            val value = protocol.check()
            releaseStaleSocket.countDown()
            assertTrue(staleSocketClosed.await(5, TimeUnit.SECONDS))
            val partial = File(directory, "download.partial")
            protocol.download(value, partial) {}
            assertArrayEquals(apk, partial.readBytes())
            assertEquals("GET /update.json HTTP/1.1", requests.poll(5, TimeUnit.SECONDS))
            assertEquals("GET /update.apk HTTP/1.1", requests.poll(5, TimeUnit.SECONDS))
            fixture.join(6000)
            serverFailure.get()?.let { throw AssertionError(it) }
        } finally {
            releaseStaleSocket.countDown(); protocol.close(); server.close(); fixture.join(6000)
            directory.deleteRecursively()
        }
    }

    @Test fun packageVersionAndSignaturesMustMatch() {
        val protocol = UpdateProtocol()
        try {
            val value = protocol.parse(manifest())
            fun verify(pkg: String = "dev.phonebridge.phonebridge", name: String = "0.2.4", code: Long = 2008,
                installed: Long = 2007, signers: Set<String>? = setOf("owner")) =
                ApkIdentityPolicy.verify(pkg, name, code, "dev.phonebridge.phonebridge", installed, value, setOf("owner"), signers)
            verify()
            assertEquals("APK_PACKAGE_MISMATCH", assertThrows(UpdateFailure::class.java) { verify(pkg = "attacker") }.code)
            assertThrows(UpdateFailure::class.java) { verify(code = 2009) }
            assertThrows(UpdateFailure::class.java) { verify(name = "0.2.5") }
            assertThrows(UpdateFailure::class.java) { verify(installed = 2009) }
            assertEquals("APK_SIGNATURE_MISMATCH", assertThrows(UpdateFailure::class.java) { verify(signers = setOf("attacker")) }.code)
            assertThrows(UpdateFailure::class.java) { verify(signers = null) }
        } finally { protocol.close() }
    }

    @Test fun codeControlsAvailabilityAndInitialVersionIsNative() = Session().use { session ->
        assertEquals(setOf("phase", "currentVersion", "currentVersionCode", "versionName", "versionCode",
            "updateAvailable", "downloadedBytes", "totalBytes", "progress", "errorMessage", "errorCode"), session.controller.status().keys)
        assertNull(session.controller.status()["errorCode"])
        assertEquals("0.2.3", session.controller.status()["currentVersion"])
        assertEquals(2007L, session.controller.status()["currentVersionCode"])
        session.check()
        assertEquals("available", session.controller.status()["phase"])
        assertEquals(true, session.controller.status()["updateAvailable"])
        session.host.version = InstalledVersion("different-name", 2008)
        session.check()
        assertEquals("current", session.controller.status()["phase"])
        assertEquals(false, session.controller.status()["updateAvailable"])
    }

    @Test fun errorsStayErrorsAndSingleFlightRejectsOverlaps() = Session().use { session ->
        val gate = CountDownLatch(1)
        session.fixture.respond = { gate.await(5, TimeUnit.SECONDS); Response(ByteArray(0), code = 503) }
        session.controller.check { _, _ -> }
        assertEquals("BUSY", assertThrows(UpdateFailure::class.java) { session.controller.check { _, _ -> } }.code)
        assertEquals("BUSY", assertThrows(UpdateFailure::class.java) { session.controller.download() }.code)
        assertEquals("checking", session.controller.status()["phase"])
        gate.countDown()
        session.host.until { session.controller.status()["phase"] == "error" }
        assertNotNull(session.controller.status()["errorMessage"])
        assertEquals("UPDATE_CHECK_FAILED", session.controller.status()["errorCode"])
        assertEquals(false, session.controller.status()["updateAvailable"])
        session.fixture.respond = { Response(manifest(session.fixture.apkUrl).toByteArray()) }
        session.controller.check { _, _ -> }
        // Starting a fresh operation clears the old failure before its worker completes.
        assertEquals("checking", session.controller.status()["phase"])
        assertNull(session.controller.status()["errorCode"])
        assertNull(session.controller.status()["errorMessage"])
        session.host.until { session.controller.status()["phase"] == "available" }
        assertNull(session.controller.status()["errorCode"])
    }

    @Test fun downloadAutoInstallsOnceOnlyAfterResumeAndCancellationNeedsExplicitRetry() = Session().use { session ->
        session.check()
        assertEquals("downloading", session.controller.download()["phase"])
        assertEquals("BUSY", assertThrows(UpdateFailure::class.java) { session.controller.check { _, _ -> } }.code)
        session.host.until { session.controller.status()["phase"] == "ready" }
        assertEquals(0, session.host.installs)
        session.controller.onResume()
        assertEquals(1, session.host.installs)
        assertEquals("installerOpened", session.controller.status()["phase"])
        session.controller.onResume()
        assertEquals("installerOpened", session.controller.status()["phase"])
        session.controller.onPause(); session.controller.onResume()
        assertEquals("ready", session.controller.status()["phase"])
        session.controller.onResume()
        assertEquals(1, session.host.installs)
        session.controller.install()
        session.host.until { session.host.installs == 2 }
    }

    @Test fun permissionDenialDoesNotLoopAndGrantContinuesExactlyOnce() = Session().use { session ->
        session.host.allowed = false
        session.controller.onResume(); session.check(); session.controller.download()
        session.host.until { session.host.permissions == 1 }
        session.controller.onResume() // Same frame cannot mean permission returned.
        assertEquals(1, session.host.permissions)
        session.controller.onPause(); session.controller.onResume()
        assertEquals("permissionRequired", session.controller.status()["phase"])
        session.controller.onResume(); assertEquals(1, session.host.permissions)
        session.controller.install(); session.host.until { session.host.permissions == 2 }
        session.controller.onPause(); session.host.allowed = true; session.controller.onResume()
        assertEquals(1, session.host.installs)
        session.controller.onResume(); assertEquals(1, session.host.installs)
    }

    @Test fun cachedApkIsReverifiedAndPartialNeverInstalls() = Session().use { session ->
        session.check(); session.controller.download()
        session.host.until { session.controller.status()["phase"] == "ready" }
        session.controller.onResume(); session.controller.onPause(); session.controller.onResume()
        val cached = File(session.directory, "update.apk")
        cached.writeBytes(ByteArray(apk.size) { 5 })
        session.controller.install()
        session.host.until { session.controller.status()["phase"] == "error" }
        assertEquals(1, session.host.installs)
        session.fixture.respond = { path -> Response(if (path == "/update.json") manifest(session.fixture.apkUrl).toByteArray() else ByteArray(apk.size) { 5 }) }
        session.controller.download()
        session.host.until { session.controller.status()["phase"] == "error" }
        assertTrue(partials(session.directory).isEmpty())
        assertEquals(1, session.host.installs)
    }

    @Test fun closingPendingCheckCompletesOnceAndDropsStaleCallback() = Session().use { session ->
        val gate = CountDownLatch(1)
        session.fixture.respond = { gate.await(5, TimeUnit.SECONDS); Response(manifest(session.fixture.apkUrl).toByteArray()) }
        var callbacks = 0
        var code: String? = null
        session.controller.check { _, failure -> callbacks++; code = failure?.code }
        session.controller.close()
        gate.countDown()
        session.host.drain()
        assertEquals(1, callbacks)
        assertEquals("ACTIVITY_CLOSED", code)
        assertEquals("ACTIVITY_CLOSED", assertThrows(UpdateFailure::class.java) { session.controller.download() }.code)
    }

    @Test fun newObserverSeesExistingCheckCompletionWithoutAnotherRequest() = Session().use { session ->
        val gate = CountDownLatch(1)
        session.fixture.respond = { gate.await(5, TimeUnit.SECONDS); Response(manifest(session.fixture.apkUrl).toByteArray()) }
        val first = mutableListOf<String>()
        session.controller.observe { first.add(it["phase"] as String) }
        assertEquals(listOf("idle"), first)
        var originalCompletion = 0
        session.controller.check { _, _ -> originalCompletion++ }
        assertEquals("checking", first.last())
        session.controller.observe(null)
        val reopened = mutableListOf<String>()
        session.controller.observe { reopened.add(it["phase"] as String) }
        assertEquals(listOf("checking"), reopened)
        gate.countDown()
        session.host.until { originalCompletion == 1 }
        assertEquals(listOf("checking", "available"), reopened)
        assertEquals(1, session.fixture.headers.size)
    }

    @Test fun installVerificationFailureReturnsTerminalResultAndPublishesError() = Session().use { session ->
        session.check(); session.controller.download()
        session.host.until { session.controller.status()["phase"] == "ready" }
        val observed = mutableListOf<Map<String, Any?>>()
        session.controller.observe { observed.add(it) }
        session.host.verificationFailure = UpdateFailure("APK_SIGNATURE_MISMATCH", "APK 签名不符，无法安装")
        var callbacks = 0
        var terminal: Map<String, Any?>? = null
        session.controller.install { status, failure -> assertNull(failure); callbacks++; terminal = status }
        assertEquals(0, callbacks)
        session.host.until { callbacks == 1 }
        assertEquals("error", terminal!!["phase"])
        assertEquals("APK 签名不符，无法安装", terminal!!["errorMessage"])
        assertEquals("APK_SIGNATURE_MISMATCH", terminal!!["errorCode"])
        assertEquals("error", observed.last()["phase"])
        assertEquals("APK_SIGNATURE_MISMATCH", observed.last()["errorCode"])
        assertEquals(0, session.host.installs)
    }

    @Test fun installerLaunchFailureIsObservableAndTerminalRetryDoesNotReplay() = Session().use { session ->
        session.check(); session.controller.download()
        session.host.until { session.controller.status()["phase"] == "ready" }
        session.host.launchFailure = IllegalStateException("Missing installer")
        session.controller.onResume() // Consumes download's pending request and reports launch failure.
        val observed = mutableListOf<Map<String, Any?>>()
        session.controller.observe { observed.add(it) }
        var callbacks = 0
        var terminal: Map<String, Any?>? = null
        session.controller.install { status, failure -> assertNull(failure); callbacks++; terminal = status }
        session.host.until { callbacks == 1 }
        assertEquals("error", terminal!!["phase"])
        assertNotNull(terminal!!["errorMessage"])
        assertEquals("UPDATE_INSTALL_FAILED", terminal!!["errorCode"])
        assertEquals("error", observed.last()["phase"])
        val attempts = session.host.installAttempts
        session.controller.onPause(); session.controller.onResume()
        assertEquals(attempts, session.host.installAttempts)
    }

    @Test fun installCloseCompletesOnceAndClearsObserverBeforeStaleWorkerReturns() = Session().use { session ->
        session.check(); session.controller.download()
        session.host.until { session.controller.status()["phase"] == "ready" }
        val started = CountDownLatch(1)
        val gate = CountDownLatch(1)
        session.host.beforeVerification = { started.countDown(); gate.await(5, TimeUnit.SECONDS) }
        var events = 0
        session.controller.observe { events++ }
        var callbacks = 0
        var code: String? = null
        session.controller.install { _, failure -> callbacks++; code = failure?.code }
        assertTrue(started.await(5, TimeUnit.SECONDS))
        session.controller.close()
        val lastEvents = events
        gate.countDown(); session.host.drain()
        assertEquals(1, callbacks)
        assertEquals("ACTIVITY_CLOSED", code)
        assertEquals(lastEvents, events)
        assertEquals(0, session.host.installs)
    }

    @Test fun rejectedArchiveNeverBecomesReadyOrInstallable() = Session().use { session ->
        session.check()
        session.host.verificationFailure = UpdateFailure("APK_SIGNATURE_MISMATCH", "APK 签名不符，无法安装")
        session.controller.onResume(); session.controller.download()
        session.host.until { session.controller.status()["phase"] == "error" }
        assertEquals(0, session.host.installs)
        assertTrue(partials(session.directory).isEmpty())
        assertFalse(File(session.directory, "update.apk").exists())
        assertEquals("UPDATE_NOT_READY", assertThrows(UpdateFailure::class.java) { session.controller.install() }.code)
    }

    @Test fun recreatedControllerRestoresVerifiedReadyWithoutInstallReplay() = Session().use { session ->
        session.check(); session.controller.download()
        session.host.until { session.controller.status()["phase"] == "ready" }
        session.controller.close()
        val host = Host()
        val recreated = UpdateController(host, session.directory, UpdateProtocol(session.fixture.manifestUrl))
        try {
            recreated.onResume()
            var checked = false
            recreated.check { _, error -> assertNull(error); checked = true }
            host.until { checked }
            assertEquals("ready", recreated.status()["phase"])
            assertEquals(0, host.installs)
            recreated.onResume(); assertEquals(0, host.installs)
            checked = false
            recreated.check { _, _ -> checked = true }; host.until { checked }
            assertEquals("ready", recreated.status()["phase"])
            recreated.install(); host.until { host.installs == 1 }
        } finally { recreated.close() }
    }

    @Test fun changedManifestAndCorruptedRestoredCacheCannotClaimReady() = Session().use { session ->
        session.check(); session.controller.download()
        session.host.until { session.controller.status()["phase"] == "ready" }
        File(session.directory, "update.apk").writeBytes(ByteArray(apk.size) { 12 })
        session.check()
        assertEquals("available", session.controller.status()["phase"])
        session.controller.download()
        session.host.until { session.controller.status()["phase"] == "ready" }
        assertArrayEquals(apk, File(session.directory, "update.apk").readBytes())
        session.fixture.respond = { Response(manifest(session.fixture.apkUrl, code = 2009).toByteArray()) }
        session.check()
        assertEquals("available", session.controller.status()["phase"])
        assertEquals("UPDATE_NOT_READY", assertThrows(UpdateFailure::class.java) { session.controller.install() }.code)
    }

    @Test fun closingDownloadCancelsNetworkDeletesPartialAndNeverInstalls() = Session().use { session ->
        session.check(); session.controller.onResume()
        val started = CountDownLatch(1)
        val gate = CountDownLatch(1)
        session.fixture.respond = { Response(apk, beforeBody = { started.countDown(); gate.await(5, TimeUnit.SECONDS) }) }
        session.controller.download()
        assertTrue(started.await(5, TimeUnit.SECONDS))
        session.controller.close(); gate.countDown()
        session.host.drain()
        assertTrue(partials(session.directory).isEmpty())
        assertEquals(0, session.host.installs)
    }

    private inner class Session : Closeable {
        val fixture = Fixture()
        val directory = Files.createTempDirectory("update-controller-test").toFile()
        val host = Host()
        val controller = UpdateController(host, directory, UpdateProtocol(fixture.manifestUrl))
        init { fixture.respond = { path -> Response(if (path == "/update.json") manifest(fixture.apkUrl).toByteArray() else apk) } }
        fun check() { var complete = false; controller.check { _, error -> assertNull(error); complete = true }; host.until { complete } }
        override fun close() { controller.close(); fixture.close(); directory.deleteRecursively() }
    }

    @Test fun closingBlockedVerifierCannotDeleteOrPromoteSuccessorDownload() = Session().use { old ->
        val oldStarted = CountDownLatch(1)
        val releaseOld = CountDownLatch(1)
        old.host.beforeVerification = {
            val owned = partials(old.directory).single { it.name.endsWith(".apk.partial") }
            oldStarted.countDown()
            awaitIgnoringInterrupt(releaseOld)
            // Model an opaque verifier/file handle keeping staged bytes alive across close.
            // Cancellation must prevent promotion even when the old temporary file exists.
            owned.writeBytes(apk)
        }
        old.check(); old.controller.download()
        assertTrue(oldStarted.await(5, TimeUnit.SECONDS))
        old.host.drain() // All stream progress posts precede the blocked verifier.
        val oldPath = partials(old.directory).single { it.name.endsWith(".apk.partial") }
        old.controller.close()

        val successorBytes = ByteArray(apk.size) { 23 }
        old.fixture.respond = { path -> Response(if (path == "/update.json")
            manifest(old.fixture.apkUrl, code = 2009, bytes = successorBytes).toByteArray() else successorBytes) }
        val successorHost = Host()
        val successorStarted = CountDownLatch(1)
        val releaseSuccessor = CountDownLatch(1)
        successorHost.beforeVerification = { successorStarted.countDown(); awaitIgnoringInterrupt(releaseSuccessor) }
        val successor = UpdateController(successorHost, old.directory, UpdateProtocol(old.fixture.manifestUrl))
        try {
            var checked = false
            successor.check { _, failure -> assertNull(failure); checked = true }
            successorHost.until { checked }
            successor.download()
            assertTrue(successorStarted.await(5, TimeUnit.SECONDS))
            val successorPath = partials(old.directory).single { it.name.endsWith(".apk.partial") }
            assertNotEquals(oldPath, successorPath)
            releaseOld.countDown()
            // Old worker always posts its stale completion only after its local cleanup finishes.
            val oldCompletion = old.host.actions.poll(5, TimeUnit.SECONDS)
            assertNotNull("Old verifier did not unwind", oldCompletion)
            oldCompletion!!.invoke()
            assertTrue(successorPath.isFile)
            assertArrayEquals(successorBytes, successorPath.readBytes())
            assertFalse(File(old.directory, "update.apk").exists())
            assertFalse(oldPath.exists())
            releaseSuccessor.countDown()
            successorHost.until { successor.status()["phase"] == "ready" }
            assertArrayEquals(successorBytes, File(old.directory, "update.apk").readBytes())
            assertEquals(2009L, JSONObject(File(old.directory, "verified.json").readText()).getLong("versionCode"))
            assertTrue(partials(old.directory).isEmpty())
            assertEquals(0, old.host.installs)
        } finally {
            releaseOld.countDown(); releaseSuccessor.countDown(); successor.close()
        }
    }

    private fun partials(directory: File) = directory.listFiles()?.filter { it.name.endsWith(".partial") } ?: emptyList()

    private fun awaitIgnoringInterrupt(latch: CountDownLatch) {
        while (true) try { if (!latch.await(6, TimeUnit.SECONDS)) fail("Verifier release timed out"); return }
        catch (_: InterruptedException) { /* Opaque Android package verification may not cancel. */ }
    }

    private class Host : UpdateHost {
        val actions = LinkedBlockingQueue<() -> Unit>()
        var version = InstalledVersion("0.2.3", 2007)
        var allowed = true
        var permissions = 0
        var installs = 0
        var installAttempts = 0
        var verificationFailure: UpdateFailure? = null
        var beforeVerification: (() -> Unit)? = null
        var launchFailure: Exception? = null
        override fun currentVersion() = version
        override fun post(action: () -> Unit) { actions.add(action) }
        override fun verifyPackage(file: File, manifest: UpdateManifest) {
            assertTrue(file.isFile); beforeVerification?.invoke(); verificationFailure?.let { throw it }
        }
        override fun canInstall() = allowed
        override fun openInstallPermission() { permissions++ }
        override fun openInstaller(file: File) {
            assertEquals("update.apk", file.name); installAttempts++
            launchFailure?.let { throw it }; installs++
        }
        fun until(condition: () -> Boolean) {
            val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(6)
            while (!condition()) {
                if (System.nanoTime() > end) fail("Update operation timed out")
                actions.poll(50, TimeUnit.MILLISECONDS)?.invoke()
            }
        }
        fun drain() { while (true) (actions.poll(150, TimeUnit.MILLISECONDS) ?: return).invoke() }
    }

    private data class Response(val body: ByteArray, val code: Int = 200, val extra: String = "",
        val beforeBody: (() -> Unit)? = null, val advertisedSize: Int? = null)
    private class Fixture : Closeable {
        private val privateHost = Collections.list(NetworkInterface.getNetworkInterfaces()).flatMap { Collections.list(it.inetAddresses) }
            .filterIsInstance<Inet4Address>().first { UpdateProtocol.privateIpv4(it.hostAddress) }.hostAddress!!
        private val server = ServerSocket(0)
        val manifestUrl = "http://$privateHost:${server.localPort}/update.json"
        val apkUrl = "http://$privateHost:${server.localPort}/update.apk"
        val headers = Collections.synchronizedList(mutableListOf<List<String>>())
        @Volatile var respond: (String) -> Response = { Response(ByteArray(0)) }
        private val error = AtomicReference<Throwable?>()
        @Volatile private var closed = false
        private val thread = Thread {
            while (!closed) try {
                server.accept().use { socket ->
                    socket.soTimeout = 5000
                    val reader = socket.getInputStream().bufferedReader()
                    val lines = mutableListOf<String>()
                    while (true) { val line = reader.readLine() ?: break; if (line.isEmpty()) break; lines.add(line) }
                    headers.add(lines)
                    val response = respond(lines.first().split(' ')[1])
                    socket.getOutputStream().apply {
                        write(("HTTP/1.1 ${response.code} Test\r\nContent-Length: ${response.advertisedSize ?: response.body.size}\r\nConnection: close\r\n${response.extra}\r\n").toByteArray())
                        flush(); response.beforeBody?.invoke(); write(response.body); flush()
                    }
                }
            } catch (failure: Exception) { if (!closed && failure !is java.net.SocketException) error.set(failure) }
        }.apply { isDaemon = true; start() }
        override fun close() { closed = true; server.close(); thread.join(6000); error.get()?.let { throw AssertionError(it) } }
    }
}
