package dev.phonebridge.phonebridge

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.UUID

internal data class InstalledVersion(val name: String, val code: Long)
internal interface UpdateHost {
    fun currentVersion(): InstalledVersion
    fun post(action: () -> Unit)
    fun verifyPackage(file: File, manifest: UpdateManifest)
    fun canInstall(): Boolean
    fun openInstallPermission()
    fun openInstaller(file: File)
    fun reportFailure(error: Exception) {}
}

/** All state is confined to the owner thread; the worker only posts immutable results. */
internal class UpdateController(private val host: UpdateHost, private val directory: File,
    private val protocol: UpdateProtocol,
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()) {
    private var phase = "idle"
    private var metadata: UpdateManifest? = null
    private var readyIdentity: UpdateManifest? = null
    private var downloaded = 0L
    private var errorMessage: String? = null
    private var errorCode: String? = null
    private var operation = false
    @Volatile private var closed = false
    @Volatile private var generation = 0L
    private val fileLifecycle = CACHE_LOCK
    private val instanceId = UUID.randomUUID().toString()
    private var activePartial: File? = null
    private var activeIdentityPartial: File? = null
    private var checkCompletion: ((Map<String, Any?>?, UpdateFailure?) -> Unit)? = null
    private var installCompletion: ((Map<String, Any?>?, UpdateFailure?) -> Unit)? = null
    private var observer: ((Map<String, Any?>) -> Unit)? = null
    private var resumed = false
    private var pendingInstall = false
    private var permissionOpen = false
    private var installerOpen = false
    private var externalPaused = false
    private val readyFile get() = File(directory, "update.apk")
    private val identityFile get() = File(directory, "verified.json")

    fun observe(listener: ((Map<String, Any?>) -> Unit)?) {
        observer = if (closed) null else listener
        observer?.invoke(status())
    }

    private fun publish() { observer?.invoke(status()) }

    fun status(): Map<String, Any?> {
        val installed = host.currentVersion()
        val value = metadata
        return mapOf("phase" to phase, "currentVersion" to installed.name, "currentVersionCode" to installed.code,
            "versionName" to value?.versionName, "versionCode" to value?.versionCode,
            "updateAvailable" to (value != null && value.versionCode > installed.code),
            "downloadedBytes" to downloaded, "totalBytes" to (value?.size ?: 0L),
            "progress" to if (value != null && value.size > 0) (downloaded.toDouble() / value.size).coerceIn(0.0, 1.0) else 0.0,
            "errorMessage" to errorMessage, "errorCode" to errorCode)
    }

    fun check(complete: (Map<String, Any?>?, UpdateFailure?) -> Unit) {
        ensureAvailable()
        operation = true; phase = "checking"; errorMessage = null; errorCode = null
        checkCompletion = complete
        publish()
        val ticket = ++generation
        val previousReady = readyIdentity
        worker.execute {
            var value: UpdateManifest? = null
            var failure: Exception? = null
            var verifiedCache = false
            try {
                value = protocol.check()
                val identity = previousReady ?: readCachedIdentity()
                if (identity == value && readyFile.isFile) {
                    try {
                        protocol.verifyBytes(readyFile, value!!); host.verifyPackage(readyFile, value!!)
                        verifiedCache = true
                    } catch (_: Exception) { /* An unusable cache remains downloadable. */ }
                }
            } catch (error: Exception) { failure = error }
            host.post {
                if (closed || generation != ticket) return@post
                operation = false
                if (failure != null) fail(failure!!, "UPDATE_CHECK_FAILED", "无法检查版本，请检查网络后重试")
                else {
                    metadata = value!!
                    if (verifiedCache) readyIdentity = value
                    else if (readyIdentity == value) readyIdentity = null
                    downloaded = if (verifiedCache) value!!.size else 0
                    phase = if (value!!.versionCode <= host.currentVersion().code) "current"
                        else if (verifiedCache) "ready" else "available"
                }
                val callback = checkCompletion; checkCompletion = null
                publish()
                callback?.invoke(status(), null)
            }
        }
    }

    fun download(): Map<String, Any?> {
        ensureAvailable()
        val snapshot = metadata ?: throw UpdateFailure("UPDATE_NOT_CHECKED", "请先检查版本")
        operation = true; phase = "downloading"; downloaded = 0; errorMessage = null; errorCode = null
        pendingInstall = true
        publish()
        val ticket = ++generation
        val reuse = readyIdentity == snapshot && readyFile.isFile
        val partialFile = File(directory, "update-$instanceId-$ticket.apk.partial")
        val identityPartial = File(directory, "verified-$instanceId-$ticket.json.partial")
        synchronized(fileLifecycle) {
            activePartial = partialFile
            activeIdentityPartial = identityPartial
        }
        worker.execute {
            var failure: Exception? = null
            try {
                if (!directory.isDirectory && !directory.mkdirs()) throw java.io.IOException("Cache unavailable")
                var validCache = false
                if (reuse) {
                    try {
                        protocol.verifyBytes(readyFile, snapshot); host.verifyPackage(readyFile, snapshot)
                        validCache = true
                    } catch (_: Exception) { /* Download retry replaces a corrupt completed cache. */ }
                }
                if (!validCache) {
                    partialFile.delete()
                    protocol.download(snapshot, partialFile) { bytes ->
                        host.post { if (!closed && ticket == generation) downloaded = bytes }
                    }
                    host.verifyPackage(partialFile, snapshot)
                }
                identityPartial.writeText(snapshot.json(), Charsets.UTF_8)
                // Close and promotion share the lock. An old Activity can never promote after
                // close returns, even when package verification ignores thread interruption.
                synchronized(fileLifecycle) {
                    if (closed || generation != ticket || Thread.currentThread().isInterrupted)
                        throw java.io.IOException("Cancelled")
                    // Same-directory atomic rename: only verified APKs become shared cache.
                    if (!validCache) Files.move(partialFile.toPath(), readyFile.toPath(),
                        StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
                    Files.move(identityPartial.toPath(), identityFile.toPath(),
                        StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
                }
            } catch (error: Exception) { partialFile.delete(); identityPartial.delete(); failure = error }
            host.post {
                if (closed || generation != ticket) return@post
                synchronized(fileLifecycle) { activePartial = null; activeIdentityPartial = null }
                operation = false
                if (failure != null) { pendingInstall = false; fail(failure!!, "UPDATE_DOWNLOAD_FAILED", "下载失败，请检查网络或存储后重试") }
                else { readyIdentity = snapshot; downloaded = snapshot.size; phase = "ready" }
                publish()
                if (failure == null) launchPending()
            }
        }
        return status()
    }

    fun install(complete: ((Map<String, Any?>?, UpdateFailure?) -> Unit)? = null): Map<String, Any?> {
        ensureAvailable()
        val snapshot = readyIdentity ?: throw UpdateFailure("UPDATE_NOT_READY", "请先下载 APK")
        if (metadata != snapshot || !readyFile.isFile) throw UpdateFailure("UPDATE_NOT_READY", "版本信息已变化，请重新下载 APK")
        operation = true; errorMessage = null; errorCode = null; pendingInstall = true
        installCompletion = complete
        publish()
        val ticket = ++generation
        worker.execute {
            var failure: Exception? = null
            try { protocol.verifyBytes(readyFile, snapshot); host.verifyPackage(readyFile, snapshot) }
            catch (error: Exception) { failure = error }
            host.post {
                if (closed || generation != ticket) return@post
                operation = false
                if (failure != null) { pendingInstall = false; fail(failure!!, "UPDATE_INSTALL_FAILED", "APK 不可安装，请重新下载") }
                else { phase = "ready" }
                publish()
                if (failure == null) launchPending()
                val callback = installCompletion; installCompletion = null
                callback?.invoke(status(), null)
            }
        }
        return status()
    }

    fun onPause() { resumed = false; if (permissionOpen || installerOpen) externalPaused = true }

    fun onResume() {
        if (closed) return
        resumed = true
        // A same-frame resume after launch isn't evidence the user returned from the system UI.
        if (permissionOpen && externalPaused) {
            permissionOpen = false; externalPaused = false
            if (host.canInstall()) { pendingInstall = true; phase = "ready" }
            else { pendingInstall = false; phase = "permissionRequired" }
        } else if (installerOpen && externalPaused) {
            installerOpen = false; externalPaused = false
            phase = if ((readyIdentity?.versionCode ?: Long.MAX_VALUE) <= host.currentVersion().code) "current" else "ready"
        }
        publish()
        launchPending()
    }

    private fun launchPending() {
        if (!resumed || !pendingInstall || closed || operation || permissionOpen || installerOpen) return
        pendingInstall = false // Consume before crossing the OS boundary.
        val snapshot = readyIdentity
        if (snapshot == null || metadata != snapshot || !readyFile.isFile) {
            fail(UpdateFailure("UPDATE_NOT_READY", "请重新下载 APK"), "UPDATE_NOT_READY", "请重新下载 APK"); publish(); return
        }
        try {
            externalPaused = false
            if (!host.canInstall()) {
                phase = "permissionRequired"; permissionOpen = true
                host.openInstallPermission()
            } else {
                phase = "installerOpened"; installerOpen = true
                host.openInstaller(readyFile)
            }
        } catch (error: Exception) {
            permissionOpen = false; installerOpen = false
            fail(error, "UPDATE_INSTALL_FAILED", "无法打开系统安装界面，请重试")
        }
        publish()
    }

    private fun ensureAvailable() {
        if (closed) throw UpdateFailure("ACTIVITY_CLOSED", "界面已关闭，请重新打开 PhoneBridge")
        if (operation || permissionOpen || installerOpen) throw UpdateFailure("BUSY", "更新操作正在进行，请稍候")
    }

    private fun readCachedIdentity(): UpdateManifest? = try {
        if (identityFile.isFile && identityFile.length() in 1..UpdateProtocol.MAX_MANIFEST.toLong())
            protocol.parse(identityFile.readText(Charsets.UTF_8)) else null
    } catch (_: Exception) { null }

    private fun fail(error: Exception, code: String, message: String) {
        host.reportFailure(error)
        phase = "error"; errorMessage = if (error is UpdateFailure) error.message else message
        errorCode = if (error is UpdateFailure) error.code else code
    }

    fun close() {
        synchronized(fileLifecycle) {
            if (closed) return
            closed = true; generation++
            // Never enumerate/delete another Activity's temporary download files.
            activePartial?.delete(); activeIdentityPartial?.delete()
            activePartial = null; activeIdentityPartial = null
        }
        pendingInstall = false; permissionOpen = false; installerOpen = false
        observer = null
        protocol.close(); worker.shutdownNow()
        val callback = checkCompletion; checkCompletion = null
        callback?.invoke(null, UpdateFailure("ACTIVITY_CLOSED", "检查已取消，请重新打开 PhoneBridge"))
        val installCallback = installCompletion; installCompletion = null
        installCallback?.invoke(null, UpdateFailure("ACTIVITY_CLOSED", "安装准备已取消，请重新打开 PhoneBridge"))
    }

    companion object {
        // All Activity instances serialize completed APK + identity promotion and closure.
        // Slow downloads, hashing, and Android package verification stay outside this lock.
        private val CACHE_LOCK = Any()
    }
}
