package dev.phonebridge.phonebridge

import androidx.core.content.FileProvider

// Android identifies a provider instance by its component class. Keep this
// separate from the APK updater so each authority retains its own path policy.
class InboxFileProvider : FileProvider()
