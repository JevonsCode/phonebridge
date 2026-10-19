package dev.phonebridge.phonebridge

import android.app.Activity
import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.provider.DocumentsContract
import java.io.File

/**
 * Files the owner keeps live in one visible folder (Download/PhoneBridge) so the system
 * file manager can open and delete them. Pairing secrets never leave private storage;
 * the app cache only holds what can be downloaded or rebuilt again.
 */
object AppStorage {
    const val FOLDER = "PhoneBridge"
    // Environment.DIRECTORY_DOWNLOADS; spelled out so it is a compile-time constant.
    private const val DOWNLOADS = "Download"
    const val relativePath = "$DOWNLOADS/$FOLDER/"
    private const val DOCUMENTS = "com.android.externalstorage.documents"

    /**
     * Opens the folder in a real file manager. A bare VIEW intent would offer unrelated
     * "open with" apps (cloud drives, transfer tools), so each candidate names its app.
     */
    fun openFolder(activity: Activity, hasFiles: Boolean) {
        // An empty folder may not exist yet; Downloads is the closest real place then.
        val relative = if (hasFiles) "$DOWNLOADS/$FOLDER" else DOWNLOADS
        @Suppress("DEPRECATION")
        val path = File(android.os.Environment.getExternalStorageDirectory(), relative).path
        val folder = DocumentsContract.buildDocumentUri(DOCUMENTS, "primary:$relative")
        val candidates = listOf(
            // Xiaomi / HyperOS file manager accepts a starting path.
            Intent(Intent.ACTION_VIEW).setClassName("com.android.fileexplorer", "com.android.fileexplorer.activity.FileActivity")
                .putExtra("explorer_path", path),
        ) + listOf("com.google.android.documentsui", "com.android.documentsui").map {
            Intent(Intent.ACTION_VIEW).setDataAndType(folder, DocumentsContract.Document.MIME_TYPE_DIR).setPackage(it)
        } + Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)
        for (intent in candidates) {
            try { activity.startActivity(intent); return }
            catch (_: ActivityNotFoundException) { } catch (_: SecurityException) { }
        }
        throw BridgeFailure("NO_FILE_MANAGER", "没有可以打开文件夹的文件管理应用")
    }

    fun cacheBytes(context: Context): Long = bytes(context.cacheDir)
    fun bytes(directory: File): Long = directory.walkBottomUp().filter { it.isFile }.sumOf { it.length() }

    /** Returns freed bytes. A downloaded update is kept while the updater still needs it. */
    fun clearCache(context: Context, keepUpdates: Boolean): Long = clear(context.cacheDir, keepUpdates)
    fun clear(cache: File, keepUpdates: Boolean): Long {
        var freed = 0L
        cache.listFiles()?.forEach { child ->
            if (keepUpdates && child.name == UPDATE_DIRECTORY) return@forEach
            val size = bytes(child)
            if (child.deleteRecursively()) freed += size
        }
        return freed
    }

    const val UPDATE_DIRECTORY = "updates"
}
