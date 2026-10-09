package dev.phonebridge.phonebridge

import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Versioned authenticated encryption; never permits unauthenticated/legacy plaintext. */
object PairingCrypto {
    private val aad = "PhoneBridge trusted pairing v1".toByteArray(Charsets.UTF_8)

    fun encrypt(plain: ByteArray, key: SecretKey): ByteArray {
        require(plain.size <= 32768)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(aad)
        require(cipher.iv.size == 12)
        return byteArrayOf(1) + cipher.iv + cipher.doFinal(plain)
    }

    fun decrypt(record: ByteArray, key: SecretKey): ByteArray {
        require(record.size in 29..32800 && record[0] == 1.toByte())
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, record.copyOfRange(1, 13)))
        cipher.updateAAD(aad)
        return cipher.doFinal(record, 13, record.size - 13)
    }
}
