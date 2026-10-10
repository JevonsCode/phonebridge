package dev.phonebridge.phonebridge

internal object ApkIdentityPolicy {
    fun verify(packageName: String, versionName: String?, versionCode: Long,
        installedPackage: String, installedCode: Long, manifest: UpdateManifest,
        installedSigners: Set<String>?, archiveSigners: Set<String>?) {
        if (packageName != installedPackage || versionCode != manifest.versionCode ||
            versionName != manifest.versionName || versionCode < installedCode)
            throw UpdateFailure("APK_PACKAGE_MISMATCH", "APK 的应用或版本不符，请重新下载")
        if (installedSigners.isNullOrEmpty() || archiveSigners != installedSigners)
            throw UpdateFailure("APK_SIGNATURE_MISMATCH", "APK 签名不符，无法安装")
    }
}
