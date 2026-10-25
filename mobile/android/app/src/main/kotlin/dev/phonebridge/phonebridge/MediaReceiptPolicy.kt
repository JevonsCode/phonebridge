package dev.phonebridge.phonebridge

import java.net.URI

object MediaReceiptPolicy {
    data class Destination(val collection: String, val relativePath: String)
    fun destination(mimeType: String, galleryEnabled: Boolean): Destination = when {
        galleryEnabled && mimeType.startsWith("image/") -> Destination("images", "Pictures/PhoneBridge/")
        galleryEnabled && mimeType.startsWith("video/") -> Destination("video", "Movies/PhoneBridge/")
        else -> Destination("downloads", "Download/PhoneBridge/")
    }

    /** Gallery provider failures must not prevent reception of an otherwise verified file. */
    fun <T> publish(mimeType: String, galleryEnabled: Boolean, write: (Destination) -> T): T {
        val requested = destination(mimeType, galleryEnabled)
        return try { write(requested) } catch (error: Exception) {
            if (requested.collection == "downloads") throw error
            write(destination(mimeType, false))
        }
    }

    fun requirePublished(updatedRows: Int) {
        check(updatedRows == 1) { "The received file could not be published." }
    }

    fun persistGalleryPreference(previous: Boolean, value: Boolean, write: (Boolean) -> Boolean): Boolean {
        try { check(write(value)) { "Could not save gallery preference." } }
        catch (error: Exception) { runCatching { write(previous) }; throw error }
        return value
    }

    /** Keep collection and volume identity. Media IDs alone are not a complete file identity. */
    fun collectionUri(uri: String): String? = try {
        val parsed = URI(uri)
        val parts = parsed.path.trim('/').split('/')
        val known = (parts.size == 4 && parts[1] in setOf("images", "video") && parts[2] == "media") ||
            (parts.size == 3 && parts[1] in setOf("downloads", "file"))
        if (parsed.scheme != "content" || parsed.authority != "media" || parsed.query != null || parsed.fragment != null ||
            !known || parts.last().toLongOrNull()?.let { it < 0 } != false) null
        else URI("content", "media", "/" + parts.dropLast(1).joinToString("/"), null).toString()
    } catch (_: Exception) { null }

    fun storedDestination(uri: String): Destination? {
        val collection = collectionUri(uri) ?: return null
        return when {
            collection.endsWith("/images/media") -> Destination("images", "Pictures/PhoneBridge/")
            collection.endsWith("/video/media") -> Destination("video", "Movies/PhoneBridge/")
            collection.endsWith("/downloads") -> Destination("downloads", "Download/PhoneBridge/")
            else -> null
        }
    }
}
