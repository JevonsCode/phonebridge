package dev.phonebridge.phonebridge

import java.net.URI

/** No DNS resolution for cleartext: a hostname may resolve to a public address later. */
object EndpointPolicy {
    fun validateToken(token: String) {
        require(token.matches(Regex("[A-Za-z0-9_-]{32,256}"))) {
            "Pairing token must contain 32–256 base64url characters (letters, digits, - and _)."
        }
    }

    fun validate(value: String, allowInsecureLocal: Boolean): String {
        require(value.length <= 2048) { "Endpoint is too long." }
        val uri = try { URI(value.trim()) } catch (_: Exception) {
            throw IllegalArgumentException("Enter a valid WebSocket endpoint.")
        }
        require(uri.scheme == "ws" || uri.scheme == "wss") { "Use ws:// or wss://." }
        require(uri.host != null && uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null) {
            "Endpoint must have a host, with no credentials, query, or fragment."
        }
        require(uri.port == -1 || uri.port in 1..65535) { "Invalid port." }
        require(uri.rawPath.isNullOrEmpty() || uri.rawPath == "/" || uri.rawPath == "/device") {
            "Endpoint path must be /device."
        }
        if (uri.scheme == "ws") {
            require(allowInsecureLocal) { "Acknowledge private-network cleartext pairing first." }
            require(isPrivateLiteral(uri.host)) { "Cleartext requires a literal private, loopback, or CGNAT IP." }
        }
        return URI(uri.scheme, null, uri.host, uri.port, "/device", null, null).toASCIIString()
    }

    fun isPrivateLiteral(raw: String): Boolean {
        val host = raw.removePrefix("[").removeSuffix("]").lowercase()
        // Deliberately only accept this unambiguous IPv6 loopback spelling for WS.
        if (host == "::1") return true
        val parts = host.split('.')
        if (parts.size != 4 || parts.any { !it.matches(Regex("0|[1-9][0-9]{0,2}")) }) return false
        val bytes = parts.map { it.toInt() }
        if (bytes.any { it !in 0..255 }) return false
        return bytes[0] == 10 || bytes[0] == 127 ||
            (bytes[0] == 172 && bytes[1] in 16..31) ||
            (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 100 && bytes[1] in 64..127)
    }
}
