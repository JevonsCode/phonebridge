package dev.phonebridge.phonebridge

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

data class TrustedPairing(
    val endpoint: String,
    val token: String,
    val allowInsecureLocal: Boolean,
    val packages: List<String>,
    val actionsEnabled: Boolean,
    val resumeAllowed: Boolean,
) {
    override fun toString() = "TrustedPairing(redacted)"
}

/** Private no-backup ciphertext; the AES key never leaves AndroidKeyStore. */
class TrustedPairingStore(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "trusted-pairing.enc"))
    // Non-secret durable stop marker makes Stop fail closed even while Keystore is unavailable.
    private val paused = AtomicFile(File(context.noBackupFilesDir, "trusted-pairing.paused"))
    private val keyStore by lazy { KeyStore.getInstance("AndroidKeyStore").apply { load(null) } }
    private val alias = "dev.phonebridge.trusted-pairing.v1"

    private fun key(create: Boolean): SecretKey {
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) { "Saved pairing key is unavailable." }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build())
        }.generateKey()
    }

    fun load(): TrustedPairing? {
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        file.openRead().close() // Recover an interrupted AtomicFile update before inspecting length.
        check(file.baseFile.length() in 29..32800)
        val plain = PairingCrypto.decrypt(file.readFully(), key(false))
        try {
            val json = JSONObject(String(plain, Charsets.UTF_8))
            check(json.getInt("version") == 1)
            val packages = json.getJSONArray("packages")
            return TrustedPairing(json.getString("endpoint"), json.getString("token"),
                json.getBoolean("allowInsecureLocal"),
                (0 until packages.length()).map { packages.getString(it) },
                json.getBoolean("actionsEnabled"),
                json.getBoolean("resumeAllowed") && !paused.baseFile.exists() &&
                    !File(paused.baseFile.path + ".bak").exists())
        } finally { plain.fill(0) }
    }

    fun save(record: TrustedPairing) {
        if (!record.resumeAllowed) pauseAutomaticResume()
        val plain = JSONObject().put("version", 1).put("endpoint", record.endpoint).put("token", record.token)
            .put("allowInsecureLocal", record.allowInsecureLocal).put("packages", JSONArray(record.packages))
            .put("actionsEnabled", record.actionsEnabled).put("resumeAllowed", record.resumeAllowed)
            .toString().toByteArray(Charsets.UTF_8)
        val encrypted = try { PairingCrypto.encrypt(plain, key(true)) } finally { plain.fill(0) }
        val output = file.startWrite()
        try {
            output.write(encrypted)
            file.finishWrite(output)
            if (record.resumeAllowed) {
                paused.delete()
                check(!paused.baseFile.exists())
            }
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }

    fun pauseAutomaticResume() {
        val output = paused.startWrite()
        try {
            output.write(1)
            paused.finishWrite(output)
        } catch (error: Exception) {
            paused.failWrite(output)
            throw error
        }
    }

    fun clear() {
        pauseAutomaticResume()
        // Deleting the key first also makes residual ciphertext unusable.
        if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
        file.delete()
        check(!file.baseFile.exists()) { "Saved pairing could not be removed." }
        paused.delete()
    }
}
