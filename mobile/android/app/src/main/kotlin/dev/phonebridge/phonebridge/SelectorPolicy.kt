package dev.phonebridge.phonebridge

import org.json.JSONObject

/** Exact/contains filters are conjunctive. The optional index is zero based after filtering. */
data class NodeSelector(val text: String? = null, val description: String? = null,
                        val textContains: String? = null, val descriptionContains: String? = null,
                        val resourceId: String? = null, val className: String? = null, val index: Int? = null) {
    init {
        val conditions = listOf(text, description, textContains, descriptionContains, resourceId, className)
        if (conditions.all { it == null } || conditions.any { it != null && it.isEmpty() } ||
            index?.let { it < 0 } == true) {
            throw BridgeFailure("INVALID_ARGUMENT", "A selector needs at least one nonempty text or attribute filter; index is zero based.")
        }
    }

    fun matches(target: NodeActionPolicy.Target): Boolean =
        (text == null || target.text == text) && (description == null || target.description == description) &&
        (textContains == null || target.text?.contains(textContains) == true) &&
        (descriptionContains == null || target.description?.contains(descriptionContains) == true) &&
        (resourceId == null || target.resourceId == resourceId) && (className == null || target.className == className)

    companion object {
        fun parse(value: JSONObject): NodeSelector {
            val fields = setOf("text", "description", "textContains", "descriptionContains", "resourceId", "className", "index")
            if (value.keys().asSequence().any { it !in fields }) throw BridgeFailure("INVALID_ARGUMENT", "Unexpected selector field.")
            fun filter(key: String): String? {
                if (!value.has(key)) return null
                return value.opt(key) as? String ?: throw BridgeFailure("INVALID_ARGUMENT", "Selector filters must be strings.")
            }
            val index = if (!value.has("index")) null else {
                val number = (value.opt("index") as? Number)?.toDouble()
                    ?: throw BridgeFailure("INVALID_ARGUMENT", "Selector index must be a nonnegative integer.")
                if (!number.isFinite() || number < 0 || number > Int.MAX_VALUE || number != number.toInt().toDouble())
                    throw BridgeFailure("INVALID_ARGUMENT", "Selector index must be a nonnegative integer.")
                number.toInt()
            }
            return NodeSelector(filter("text"), filter("description"), filter("textContains"), filter("descriptionContains"),
                filter("resourceId"), filter("className"), index)
        }
    }
}

object SelectorPolicy {
    enum class TapMode { PHYSICAL, SELECTOR, IMAGE }
    fun tapMode(keys: Set<String>): TapMode {
        val physical = keys.any { it == "x" || it == "y" }
        val selector = "selector" in keys
        val image = keys.any { it in setOf("imageX", "imageY", "screenshotId") }
        if (listOf(physical, selector, image).count { it } != 1 ||
            (physical && !("x" in keys && "y" in keys)) ||
            (image && !("imageX" in keys && "imageY" in keys && "screenshotId" in keys))) {
            throw BridgeFailure("INVALID_ARGUMENT", "Choose exactly one complete tap target: x/y, selector, or imageX/imageY/screenshotId.")
        }
        return if (selector) TapMode.SELECTOR else if (image) TapMode.IMAGE else TapMode.PHYSICAL
    }

    fun choose(selector: NodeSelector, matches: Int, truncated: Boolean = false): Int {
        if (truncated) throw BridgeFailure("SELECTOR_INCOMPLETE", "The current tree exceeded the search limit. Use a more specific visible target after navigating closer.")
        if (matches == 0 || selector.index?.let { it >= matches } == true) {
            throw BridgeFailure("SELECTOR_NOT_FOUND", "No current node matches that selector and index. Request state and refine the selector.", mapOf("matchCount" to matches))
        }
        if (matches > 1 && selector.index == null) {
            throw BridgeFailure("AMBIGUOUS_SELECTOR", "More than one current node matches. Add text/resourceId/className filters or an explicit zero-based index.", mapOf("matchCount" to matches))
        }
        return selector.index ?: 0
    }
}
