package com.example.emby_my_client

internal data class UpdatePackageIdentity(
    val packageName: String,
    val versionCode: Long,
    val versionName: String,
    val minSdk: Int,
    val signers: Set<String>,
    val abis: Set<String>,
)

internal class UpdateRejected(val reason: String) : Exception(reason)

internal object ApkUpdatePolicy {
    fun verify(
        installed: UpdatePackageIdentity,
        candidate: UpdatePackageIdentity,
        deviceSdk: Int,
        deviceAbis: Set<String>,
        release: Int,
    ) {
        if (candidate.packageName != installed.packageName) throw UpdateRejected("package")
        // Deliberately require the same current signer set. Key rotation requires
        // a separately designed/verified migration; never accept an arbitrary key.
        if (installed.signers.isEmpty() || candidate.signers != installed.signers) {
            throw UpdateRejected("signature")
        }
        if (candidate.versionCode <= installed.versionCode) throw UpdateRejected("downgrade")
        if (release <= 0 || release > 209999 ||
            candidate.versionCode / 10000 != release.toLong() ||
            candidate.versionName != "1.0.$release") throw UpdateRejected("package")
        if (candidate.minSdk > deviceSdk || candidate.abis.intersect(deviceAbis).isEmpty()) {
            throw UpdateRejected("unsupported")
        }
    }
}
