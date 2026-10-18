package dev.phonebridge.phonebridge

import android.app.Activity
import android.content.ClipData
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import android.util.AtomicFile
import androidx.core.content.FileProvider
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Duration
import java.time.Instant
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Called on the main thread; only bounded file IO happens on the worker. Secrets never persist.
 * Verified files are published to Download/PhoneBridge so the owner can open, share or delete
 * them with the system file manager; deleting a file there removes it from this list.
 */
class FileInbox(private val context: Context) {
    companion object {
        /** The phone lists files page by page; the byte budget stays the real bound. */
        const val MAX_FILES = 100
        const val MAX_BYTES = 200L * 1024 * 1024
        private const val CHECK_INTERVAL_MS = 5_000L
    }
    data class Source(val origin: String, val authorization: String, val name: String, val generation: Long)
    /** [uri] is the published copy; files from older versions keep a private copy until migrated. */
    private data class Entry(val file: IncomingFile, val sourceName: String, var state: String, var time: String = Instant.now().toString(), var error: String = "", var source: Source? = null, val expires: Long = System.currentTimeMillis() + 600000, var uri: Uri? = null)
    private val root = File(context.filesDir, "inbox").apply { mkdirs() }
    private val index = AtomicFile(File(root, "index.json"))
    private val entries = mutableListOf<Entry>()
    private val events = mutableListOf<Map<String, Any>>()
    private val worker = Executors.newSingleThreadExecutor()
    private val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).callTimeout(60, TimeUnit.SECONDS).build()
    private var call: Call? = null
    private var receiving: String? = null
    private var lastCheck = 0L

    init {
        try {
            val data = JSONObject(index.openRead().use { String(it.readBytes()) })
            val records = data.optJSONArray("files") ?: JSONArray()
            for (i in 0 until minOf(records.length(), MAX_FILES)) {
                val record = records.getJSONObject(i)
                val file = IncomingFile.parse(record.getJSONObject("file"))
                val uri = record.optString("uri").takeIf { it.startsWith("content://") }?.let(Uri::parse)
                val entry = Entry(file, record.optString("sourceName").take(180), "received", record.getString("time"), uri = uri)
                if (uri != null || (privateCopy(file).isFile && privateCopy(file).length() == file.size)) entries.add(entry)
            }
            val history = data.optJSONArray("events") ?: JSONArray()
            for (i in maxOf(0, history.length() - 100) until history.length()) {
                val event = history.getJSONObject(i)
                events.add(mapOf("time" to event.getString("time"), "method" to "file_transfer", "status" to event.getString("status"), "requestId" to event.getString("requestId"), "sourceName" to event.optString("sourceName").take(180)))
            }
        } catch (_: Exception) { /* A missing index never makes unverified files shareable. */ }
        root.listFiles()?.filter { it.isFile && it.name.endsWith(".part") }?.forEach { it.delete() }
        // Preserve completed files even if their index is unreadable. Never erase owner data during recovery.
        migrateLegacyFiles()
    }

    private fun privateCopy(file: IncomingFile) = File(File(root, file.id), file.name)

    /** Moves files received by earlier versions into the visible folder, one at a time. */
    private fun migrateLegacyFiles() {
        entries.filter { it.uri == null }.forEach { entry ->
            val source = privateCopy(entry.file)
            worker.execute {
                val uri = try { publish(entry.file, source) } catch (_: Exception) { null }
                BridgeSession.main.post {
                    if (uri == null) return@post
                    if (entries.contains(entry)) {
                        entry.uri = uri
                        try { persist() } catch (_: Exception) { }
                        source.parentFile?.deleteRecursively()
                    } else {
                        // Removed while copying: do not leave an orphan in the owner's folder.
                        delete(uri)
                    }
                }
            }
        }
    }

    /** Copies a verified file into Download/PhoneBridge. Worker thread only. */
    private fun publish(file: IncomingFile, verified: File): Uri {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
            put(MediaStore.MediaColumns.MIME_TYPE, file.mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, AppStorage.relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Could not create the file in Download.")
        try {
            resolver.openOutputStream(uri, "w")!!.use { output -> verified.inputStream().use { it.copyTo(output) } }
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (error: Exception) {
            delete(uri); throw error
        }
        return uri
    }

    private fun delete(uri: Uri) = try { context.contentResolver.delete(uri, null, null) > 0 } catch (_: Exception) { false }

    /** Drops entries whose published file the owner deleted elsewhere. One query, throttled. */
    private fun forgetDeletedFiles() {
        val now = System.currentTimeMillis()
        if (now - lastCheck < CHECK_INTERVAL_MS) return
        lastCheck = now
        val published = entries.filter { it.state == "received" && it.uri != null }
        if (published.isEmpty()) return
        val ids = published.map { ContentUris.parseId(it.uri!!) }
        val existing = mutableSetOf<Long>()
        try {
            context.contentResolver.query(MediaStore.Downloads.EXTERNAL_CONTENT_URI, arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns._ID} IN (${ids.joinToString(",")})", null, null)?.use { cursor ->
                while (cursor.moveToNext()) existing.add(cursor.getLong(0))
            } ?: return
        } catch (_: Exception) { return }
        val gone = published.filter { ContentUris.parseId(it.uri!!) !in existing }
        if (gone.isEmpty()) return
        entries.removeAll(gone)
        try { persist() } catch (_: Exception) { }
    }

    private fun persist() {
        val data = JSONObject().put("files", JSONArray(entries.filter { it.state == "received" }.map {
            JSONObject().put("file", it.file.json()).put("sourceName", it.sourceName).put("time", it.time).put("uri", it.uri?.toString() ?: "")
        })).put("events", JSONArray(events.map { JSONObject(it) }))
        val output = index.startWrite()
        try { output.write(data.toString().toByteArray()); index.finishWrite(output) }
        catch (error: Exception) { index.failWrite(output); throw error }
    }
    private fun record(entry: Entry, state: String) {
        entry.state = state; entry.time = Instant.now().toString()
        events.add(mapOf("time" to entry.time, "method" to "file_transfer", "status" to state, "requestId" to "${entry.file.id}:$state", "sourceName" to entry.sourceName))
        while (events.size > 100) events.removeAt(0)
        try { persist() } catch (_: Exception) { entry.error = "无法保存接收记录，请检查手机存储空间" }
    }
    fun history(): List<Map<String, Any>> = events.toList()
    fun status(): List<Map<String, Any>> {
        entries.filter { it.state == "pending" && System.currentTimeMillis() >= it.expires }.forEach { it.source = null; record(it, "expired") }
        forgetDeletedFiles()
        return entries.asReversed().map { mapOf("id" to it.file.id, "name" to it.file.name, "size" to it.file.size, "sourceName" to it.sourceName, "state" to it.state, "error" to it.error, "time" to it.time) }
    }
    fun storage(): Map<String, Any> {
        val received = entries.filter { it.state == "received" }
        return mapOf("folder" to AppStorage.relativePath.trimEnd('/'), "files" to received.size,
            "bytes" to received.sumOf { it.file.size }, "cacheBytes" to AppStorage.cacheBytes(context))
    }
    fun offer(value: JSONObject, source: Source) {
        val file = IncomingFile.parse(value)
        status()
        require(entries.none { it.state == "pending" || it.state == "receiving" }) { "Please handle the pending file first." }
        require(entries.none { it.file.id == file.id }) { "Duplicate file offer." }
        val retained = entries.filter { it.state == "received" }
        require(retained.size < MAX_FILES && retained.sumOf { it.file.size } + file.size <= MAX_BYTES) { "Inbox full. Remove received files first." }
        entries.removeAll { it.state != "received" }
        val entry = Entry(file, source.name, "pending", source = source)
        entries.add(entry); record(entry, "pending")
    }
    fun disconnected() {
        call?.cancel(); call = null; receiving = null
        entries.filter { it.state == "pending" || it.state == "receiving" }.forEach { it.source = null; record(it, "cancelled") }
    }
    private fun entry(id: String) = entries.find { it.file.id == id } ?: throw IllegalArgumentException("File unavailable.")
    private fun request(source: Source, path: String) = Request.Builder().url(source.origin + path).header("Authorization", source.authorization)
    fun receive(id: String) {
        status()
        val entry = entry(id); val source = entry.source
        require(entry.state == "pending" && source != null && receiving == null) { "File expired or disconnected. Ask the computer to send it again." }
        val partial = File(root, "$id.part")
        val download = http.newCall(request(source, "/files/$id").build())
        call = download; receiving = id; record(entry, "receiving")
        worker.execute {
            var published: Uri? = null
            try {
                download.execute().use { response ->
                    require(response.isSuccessful && response.body != null)
                    val body = response.body!!
                    require(body.contentLength() == entry.file.size)
                    body.byteStream().use { input -> partial.outputStream().use { output -> entry.file.copyVerified(input, output) } }
                }
                // Only a verified file ever reaches the visible folder.
                published = publish(entry.file, partial)
            } catch (_: Exception) { }
            partial.delete()
            BridgeSession.main.post {
                if (receiving != id || entry.source !== source || !BridgeSession.connected || BridgeSession.generation != source.generation) {
                    published?.let(::delete); return@post
                }
                call = null; receiving = null
                if (published == null) {
                    entry.error = "接收失败，文件可能已过期，请让电脑重新发送"; entry.source = null; record(entry, "failed")
                    // Release the hub's slot after a failed local reception.
                    worker.execute { acknowledge(source, id, false) }
                } else {
                    entry.uri = published; entry.source = null; record(entry, "received")
                    worker.execute {
                        val acknowledged = acknowledge(source, id, true)
                        if (!acknowledged) BridgeSession.main.post { entry.error = "文件已接收，电脑未收到回执" }
                    }
                }
            }
        }
    }
    private fun acknowledge(source: Source, id: String, received: Boolean): Boolean = try {
        val builder = request(source, "/files/$id" + if (received) "/received" else "")
        if (received) builder.post(ByteArray(0).toRequestBody()) else builder.delete()
        http.newCall(builder.build()).execute().use { it.isSuccessful }
    } catch (_: Exception) { false }
    fun decline(id: String) {
        val entry = entry(id); require(entry.state == "pending")
        val source = entry.source; entry.source = null; record(entry, "declined")
        if (source != null) worker.execute { acknowledge(source, id, false) }
    }
    private fun discard(entry: Entry) {
        val uri = entry.uri
        if (uri != null) {
            context.revokeUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            delete(uri)
        } else if (entry.state == "received") {
            val legacy = FileProvider.getUriForFile(context, "${context.packageName}.files", privateCopy(entry.file))
            context.revokeUriPermission(legacy, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        privateCopy(entry.file).parentFile?.let { if (it.exists()) it.deleteRecursively() }
        entries.remove(entry)
    }
    fun remove(id: String) {
        val entry = entry(id); require(entry.state != "receiving" && entry.state != "pending")
        discard(entry); persist()
    }
    /** Deletes finished files older than [olderThanDays]; null clears every finished file. */
    fun cleanup(olderThanDays: Int?): Int {
        require(olderThanDays == null || olderThanDays in 1..3650)
        val cutoff = olderThanDays?.let { Instant.now().minus(Duration.ofDays(it.toLong())) }
        val old = entries.filter { it.state != "pending" && it.state != "receiving" }
            .filter { cutoff == null || (runCatching { Instant.parse(it.time) }.getOrNull() ?: Instant.EPOCH).isBefore(cutoff) }
        old.forEach(::discard)
        persist()
        return old.size
    }
    fun share(activity: Activity, id: String) {
        val entry = entry(id); require(entry.state == "received")
        val uri = entry.uri ?: privateCopy(entry.file).let {
            require(it.isFile); FileProvider.getUriForFile(context, "${context.packageName}.files", it)
        }
        val intent = Intent(Intent.ACTION_SEND).setType(entry.file.mimeType)
            .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        intent.clipData = ClipData.newUri(context.contentResolver, entry.file.name, uri)
        activity.startActivity(Intent.createChooser(intent, null))
        events.add(mapOf("time" to Instant.now().toString(), "method" to "file_transfer", "status" to "share_opened", "requestId" to "${entry.file.id}:share:${System.currentTimeMillis()}", "sourceName" to entry.sourceName))
        while (events.size > 100) events.removeAt(0)
        persist()
    }
    fun readHistory(source: Source, complete: (String?, String?) -> Unit) {
        worker.execute {
            val result = try {
                http.newCall(request(source, "/operations?limit=100").build()).execute().use { response ->
                    require(response.isSuccessful)
                    val input = response.body!!.byteStream()
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer); if (count < 0) break
                        require(output.size() + count <= 1024 * 1024)
                        output.write(buffer, 0, count)
                    }
                    val bytes = output.toByteArray()
                    require(bytes.size <= 1024 * 1024)
                    JSONObject(String(bytes)).getJSONArray("operations").toString()
                }
            } catch (_: Exception) { null }
            BridgeSession.main.post {
                if (source.generation != BridgeSession.generation) complete(null, "连接已切换，请刷新日志")
                else complete(result, if (result == null) "无法读取电脑日志，请检查连接后刷新" else null)
            }
        }
    }
}
