package com.example.emby_my_client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ApkUpdatePolicyTest {
    private val current = UpdatePackageIdentity(
        "com.jsdfhasuh.emoemby", 1792000, "1.0.179", 24, setOf("stable-key"), setOf("arm64-v8a"),
    )
    private val next = current.copy(versionCode = 1802000, versionName = "1.0.180")

    private fun verify(candidate: UpdatePackageIdentity, installed: UpdatePackageIdentity = current) =
        ApkUpdatePolicy.verify(installed, candidate, 35, setOf("arm64-v8a", "armeabi-v7a"), 180)

    private fun rejected(reason: String, candidate: UpdatePackageIdentity,
                         installed: UpdatePackageIdentity = current) {
        assertEquals(reason, assertThrows(UpdateRejected::class.java) { verify(candidate, installed) }.reason)
    }

    @Test fun acceptsSameSignerNewerPackage() { verify(next) }
    @Test fun universalCanUpgradePreviousSplit() { verify(next.copy(versionCode = 1800000)) }
    @Test fun splitCanUpgradePreviousUniversal() { verify(next, current.copy(versionCode = 1790000)) }
    @Test fun legacyRequiresCompatibleSigner() { verify(next, current.copy(versionCode = 2001, versionName = "1.0.0")) }
    @Test fun rejectsWrongPackage() { rejected("package", next.copy(packageName = "other.app")) }
    @Test fun rejectsLegacyPackageEvenWithStableSigner() {
        rejected("package", next.copy(packageName = "com.example.embyclient"))
    }
    @Test fun rejectsChangedSigner() { rejected("signature", next.copy(signers = setOf("different-key"))) }
    @Test fun rejectsEmptySigners() { rejected("signature", next.copy(signers = emptySet())) }
    @Test fun rejectsUnknownInstalledSigner() { rejected("signature", next, current.copy(signers = emptySet())) }
    @Test fun rejectsAddedSigner() { rejected("signature", next.copy(signers = setOf("stable-key", "extra-key"))) }
    @Test fun rejectsDowngrade() { rejected("downgrade", next.copy(versionCode = 1791000)) }
    @Test fun rejectsSameVersion() { rejected("downgrade", current) }
    @Test fun checksSignatureBeforeSameVersionForLegacyReleases() {
        rejected("signature", current.copy(signers = setOf("different-key")))
    }
    @Test fun rejectsWrongReleaseCode() { rejected("package", next.copy(versionCode = 1812000)) }
    @Test fun rejectsWrongVersionName() { rejected("package", next.copy(versionName = "1.0.181")) }
    @Test fun rejectsUnsupportedSdk() { rejected("unsupported", next.copy(minSdk = 36)) }
    @Test fun rejectsWrongAbi() { rejected("unsupported", next.copy(abis = setOf("x86_64"))) }
    @Test fun rejectsMissingNativePayload() { rejected("unsupported", next.copy(abis = emptySet())) }
}
