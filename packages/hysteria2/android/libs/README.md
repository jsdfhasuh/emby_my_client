Generated locally by `python scripts/android/build_hysteria2.py all`.

`hysteria2.aar` and `hysteria2.provenance.json` are ignored build artifacts, not
vendored binaries. Gradle verifies the source fingerprints, upstream/tool pins,
license notices, all three ABIs, native hashes and ELF 16 KB page compatibility
before extracting the embedded JNI library, generated Java classes and assets.
