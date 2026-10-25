package dev.phonebridge.phonebridge

/** Rotating batches cover the real subnet, without allocating a whole /8 or /16. */
object DiscoveryScanPlan {
    data class Batch(val targets: List<String>, val nextOffset: Long)
    private fun number(address: String): Long = address.split('.').fold(0L) { value, part -> (value shl 8) or part.toLong() }
    private fun text(address: Long) = (3 downTo 0).joinToString(".") { ((address shr (it * 8)) and 255).toString() }
    fun batch(address: String, prefix: Int, offset: Long, preferred: String?, budget: Int = 256): Batch {
        require(prefix in 0..32 && budget > 0)
        val own = number(address)
        val size = 1L shl (32 - prefix)
        val base = own and ((0xffffffffL shl (32 - prefix)) and 0xffffffffL)
        val first = if (prefix >= 31) base else base + 1
        val last = if (prefix >= 31) base + size - 1 else base + size - 2
        val count = last - first + 1
        val start = (own and 0xffffff00L).coerceIn(first, last) - first
        val targets = linkedSetOf<String>()
        preferred?.let { runCatching { number(it) }.getOrNull() }?.takeIf { it in first..last && it != own }
            ?.let { if (EndpointPolicy.isPrivateLiteral(text(it))) targets.add(text(it)) }
        var scanned = 0L
        while (scanned < minOf(budget.toLong(), count)) {
            val candidate = first + ((start + offset + scanned) % count)
            if (candidate != own && EndpointPolicy.isPrivateLiteral(text(candidate))) targets.add(text(candidate))
            scanned++
        }
        return Batch(targets.toList(), (offset + scanned) % count)
    }
}
