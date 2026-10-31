# ldid Runtime Compatibility Gate

Build 212 passed the quality/Android job, native XCTest and unsigned iOS build,
but failed in TrollStore packaging. The locked ldid 2.1.5_1 bottle loaded
`libplist-2.0.4.dylib`, which is absent from the runner's libplist 2.8.0 install.
The signing process aborted with exit code 134. The previous version/formula
checks did not execute ldid, so they missed the broken dynamic dependency.

Homebrew Core commit `dff1605b28060adcec7b36e81f9aac33b3f48d97` rebuilds ldid
for libplist 2.8.0. The lock now pins the subsequent bottle commit
`98c83f94a011f8af7ebbf406a1f1f56672fbd976` and its formula SHA-256.
ldid remains upstream 2.1.5 at the same source revision; only the Homebrew
package revision moves from 1 to 2. No application or entitlement policy changes.

Verification now requires the exact package revision, runs `brew linkage --test`
and runs the locked formula's `brew test`, which fakesigns a disposable Mach-O
fixture. Offline regression tests reject old revisions, missing dynamic
dependencies and signing failures, and verify failed-install cleanup.

The Windows shell regression tests do not validate Mach-O signing. Actual
linkage, signing and IPA acceptance remain gated by the macOS CI run and
subsequent iPad testing.
