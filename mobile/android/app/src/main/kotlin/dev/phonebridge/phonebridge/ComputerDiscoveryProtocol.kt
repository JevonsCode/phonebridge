package dev.phonebridge.phonebridge

import org.json.JSONObject
import java.net.URI
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Uses the already paired identity; discovery never sends its bearer credential. */
object ComputerDiscoveryProtocol {
    const val PORT = 8766
    private fun hmac(token: String, value: String): String = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(token.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        doFinal(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    fun identity(token: String) = hmac(token, "PhoneBridge discovery identity v1")
    fun sameResumableTrust(expected: TrustedPairing, current: TrustedPairing?): Boolean =
        current != null && current.resumeAllowed && current.token == expected.token && current.endpoint == expected.endpoint
    fun request(token: String, nonce: String): String {
        require(nonce.matches(Regex("[a-f0-9]{32}")))
        return JSONObject().put("type", "phonebridge_discover").put("version", 1)
            .put("identity", identity(token)).put("nonce", nonce).toString()
    }
    fun verify(text: String, record: TrustedPairing, nonce: String): String? = try {
        require(text.toByteArray(Charsets.UTF_8).size <= 4096)
        val json = JSONObject(text)
        val id = identity(record.token)
        require(json.getString("type") == "phonebridge_found" && json.getInt("version") == 1)
        require(json.getString("identity") == id && json.getString("nonce") == nonce)
        val endpoint = json.getString("endpoint")
        val expected = hmac(record.token, "PhoneBridge discovery v1\n$id\n$nonce\n$endpoint")
        require(MessageDigest.isEqual(expected.toByteArray(), json.getString("proof").toByteArray()))
        val canonical = EndpointPolicy.validate(endpoint, record.allowInsecureLocal)
        require(EndpointPolicy.isPrivateLiteral(URI(canonical).host))
        canonical
    } catch (_: Exception) { null }
}
