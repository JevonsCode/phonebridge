package dev.phonebridge.phonebridge

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
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
class TrustedPairingStore(context: Context) : TrustedComputerPersistence {
    private val repository = TrustedComputerRepository(this)
    private val file = AtomicFile(File(context.noBackupFilesDir, "trusted-pairing.enc"))
    // Non-secret durable stop marker makes Stop fail closed even while Keystore is unavailable.
    private val paused = AtomicFile(File(context.noBackupFilesDir, "trusted-pairing.paused"))
    private val actionsPaused = AtomicFile(File(context.noBackupFilesDir, "trusted-pairing.permissions-paused"))
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

    fun load(): TrustedPairing? = list().active?.pairing

    fun list(): TrustedComputers = repository.list()

    // Preserve legacy service callers, updating only this identity and making it active.
    fun save(record: TrustedPairing) { repository.mutate { it.remember(record) } }
    fun select(id: String): TrustedPairing = repository.mutate { it.select(id) }.active!!.pairing
    fun rename(id: String, name: String) { repository.mutate { it.rename(id, name) } }
    fun deactivate() { repository.mutate { it.copy(activeId = null) } }

    override fun read(): TrustedComputers {
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return TrustedComputers()
        file.openRead().close()
        check(file.baseFile.length() in 29..PairingCrypto.MAX_RECORD_BYTES.toLong())
        val plain = PairingCrypto.decrypt(file.readFully(), key(false))
        try { return TrustedComputers.decode(String(plain, Charsets.UTF_8)) }
        finally { plain.fill(0) }
    }

    override fun write(computers: TrustedComputers) {
        val encoded = computers.encode()
        // Check the reader contract before replacing the last usable ciphertext.
        check(TrustedComputers.decode(encoded) == computers)
        val plain = encoded.toByteArray(Charsets.UTF_8)
        val encrypted = try { PairingCrypto.encrypt(plain, key(true)) } finally { plain.fill(0) }
        val output = file.startWrite()
        try {
            output.write(encrypted)
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }

    override fun isPaused() = paused.baseFile.exists() || File(paused.baseFile.path + ".bak").exists()
    override fun actionsPaused() = actionsPaused.baseFile.exists() || File(actionsPaused.baseFile.path + ".bak").exists()
    override fun markActionsPaused() {
        val output = actionsPaused.startWrite()
        try {
            output.write(1)
            actionsPaused.finishWrite(output)
        } catch (error: Exception) {
            actionsPaused.failWrite(output)
            throw error
        }
    }
    override fun clearActionsPaused() {
        actionsPaused.delete()
        check(!actionsPaused())
    }
    override fun markPaused() = pauseAutomaticResume()
    override fun clearPaused() {
        paused.delete()
        check(!isPaused())
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

    /** Remove only selected trust. Other computers still require the same Keystore key. */
    fun clear() { repository.mutate { it.forgetActive() } }
}
