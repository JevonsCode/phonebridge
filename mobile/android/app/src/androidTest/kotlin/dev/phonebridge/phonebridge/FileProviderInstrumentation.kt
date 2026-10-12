package dev.phonebridge.phonebridge

import android.app.Activity
import android.app.Instrumentation
import android.content.ClipData
import android.os.Build
import android.os.Bundle
import androidx.core.content.FileProvider
import java.io.File
import java.util.UUID

/** Runtime regression for provider component collisions. Never run on an owner's phone. */
class FileProviderInstrumentation : Instrumentation() {
    private var confirmed = false
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        confirmed = arguments?.getString("verifyFileProviders") == "isolated-emulator"
        start()
    }

    override fun onStart() {
        val result = Bundle()
        val directories = mutableListOf<File>()
        var code = Activity.RESULT_CANCELED
        try {
            check(confirmed && Build.HARDWARE in setOf("ranchu", "goldfish")) { "Explicit isolated emulator required" }
            val name = "provider-test-${UUID.randomUUID()}"
            val inbox = File(targetContext.filesDir, "inbox/$name").apply { mkdirs() }
            val updates = File(targetContext.cacheDir, "updates/$name").apply { mkdirs() }
            directories.addAll(listOf(inbox, updates))
            val files = listOf(
                Triple("files", File(inbox, "test.png"), "image/png"),
                Triple("updates", File(updates, "test.apk"), "application/vnd.android.package-archive"),
            )
            for ((authority, file, mime) in files) {
                val bytes = "JVS-A isolated provider fixture".toByteArray()
                file.writeBytes(bytes)
                val uri = FileProvider.getUriForFile(targetContext, "${targetContext.packageName}.$authority", file)
                // getType/newUri cross the real ContentProvider transport. Merely
                // generating a URI does not detect Android reusing the wrong component.
                check(targetContext.contentResolver.getType(uri) == mime) { "$authority provider did not resolve $mime" }
                check(ClipData.newUri(targetContext.contentResolver, "Test file", uri).description.hasMimeType(mime)) { "$authority share MIME missing" }
                check(targetContext.contentResolver.openInputStream(uri)!!.use { it.readBytes() }.contentEquals(bytes)) { "$authority file bytes differ" }
                val other = if (authority == "files") "updates" else "files"
                check(runCatching { FileProvider.getUriForFile(targetContext, "${targetContext.packageName}.$other", file) }.isFailure) { "$other provider exposed another authority's file" }
            }
            result.putString("fileProviders", "passed")
            result.putInt("authoritiesVerified", files.size)
            code = Activity.RESULT_OK
        } catch (error: Exception) {
            result.putString("fileProviders", "failed")
            result.putString("failure", "${error.javaClass.simpleName}: ${error.message}")
        } finally {
            directories.forEach { it.deleteRecursively() }
        }
        finish(code, result)
    }
}
