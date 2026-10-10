package dev.phonebridge.phonebridge

import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File

/** Activity adapter; updater state and network lifecycle remain independent of BridgeSession. */
internal class AppUpdater(private val activity: MainActivity) : UpdateHost {
    private val main = Handler(Looper.getMainLooper())
    private val controller = UpdateController(this, File(activity.cacheDir, "updates"),
        UpdateProtocol(activity.getString(R.string.update_manifest_url)))

    fun status() = controller.status()
    fun check(complete: (Map<String, Any?>?, UpdateFailure?) -> Unit) = controller.check(complete)
    fun download() = controller.download()
    fun install(complete: (Map<String, Any?>?, UpdateFailure?) -> Unit) { controller.install(complete) }
    fun observe(listener: ((Map<String, Any?>) -> Unit)?) = controller.observe(listener)
    fun onPause() = controller.onPause()
    fun onResume() = controller.onResume()
    fun close() = controller.close()

    override fun currentVersion(): InstalledVersion {
        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
        return InstalledVersion(info.versionName ?: "", info.longVersionCode)
    }

    override fun post(action: () -> Unit) { main.post(action) }

    override fun reportFailure(error: Exception) {
        if (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            // Updater has no pairing credentials. Keep diagnostics limited to its failure stack.
            Log.w("PhoneBridgeUpdater", "Update operation failed: ${error.javaClass.simpleName}", error)
        }
    }

    override fun verifyPackage(file: File, manifest: UpdateManifest) {
        val manager = activity.packageManager
        val flags = PackageManager.GET_SIGNING_CERTIFICATES
        val archive = manager.getPackageArchiveInfo(file.absolutePath, flags)
            ?: throw UpdateFailure("APK_PACKAGE_MISMATCH", "APK 格式无效，请重新下载")
        val installed = manager.getPackageInfo(activity.packageName, flags)
        val expected = installed.signingInfo?.apkContentsSigners?.map { UpdateProtocol.hex(it.toByteArray()) }?.toSet()
        val received = archive.signingInfo?.apkContentsSigners?.map { UpdateProtocol.hex(it.toByteArray()) }?.toSet()
        ApkIdentityPolicy.verify(archive.packageName, archive.versionName, archive.longVersionCode,
            activity.packageName, installed.longVersionCode, manifest, expected, received)
    }

    override fun canInstall() = activity.packageManager.canRequestPackageInstalls()

    override fun openInstallPermission() {
        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
    }

    override fun openInstaller(file: File) {
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
        activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).apply { clipData = ClipData.newRawUri("APK", uri) })
    }
}
