# Feature branch integration — 2026-10-03

## Frozen source inventory

Initial main: `43728897f7a7d486acfa2db8fe8973132380de45`.
There were four remote feature branches and no open pull requests.

| Branch | Frozen SHA | Unique commits versus initial main | Result |
| --- | --- | ---: | --- |
| `codex/home-media-mixed-viewer` | `6c4b1b59621fb5cfea7d500d68ce5197288457d6` | 0 | Already included through PR #9; retained |
| `codex/multi-server-switching` | `fc0dc038e5e744456b500ebeafffac0a85d01b46` | 0 | Already included through PR #9; retained |
| `codex/strm-read-ahead` | `f73be7a1b4b799c913fd9d737537622c96f9ba40` | 4 | Merge with source history preserved |
| `wip/full-diagnostic-export-20260827` | `517da0842ad146755b24f28e0016063ffeb7b480` | 1 | Merge new cache recovery and scroll restoration fixes; prior diagnostics already included |

The STRM branch descends directly from initial main. The diagnostic branch
contains one new fix beyond its previously integrated ancestor `f80546d`.
There are no release, backup, or dependency-update branches to exclude.
No source branch is deleted and no release/version/deployment change is made.
Work uses a separate cloud checkout; existing user and unrelated worktrees are
untouched. No repository AGENTS.md or `.agents/skills` files were present.

## Semantic integration

Two textual conflicts in `playback_controller.dart` are resolved by retaining:

- source-direct memory-pressure fallback when no cache coordinator is available;
- generation-bound cache-safety error deferral when the coordinator is active;
- typed STRM source-failure classification/deduplication and source trace checks;
- the diagnostic branch's generation-aware generic engine error handling.

Three integration regressions receive explicit corrections and tests:

1. Typed source failures now follow the same cache-safety deferral boundary as
   generic native errors. A deferred typed failure is replayed if the reopen
   does not replace its generation; a replacement-generation/startup failure
   remains visible. Source identity and native duplicate suppression are kept.
2. A position-preserving local library rescan keeps the visible items and
   offset but updates the active scan snapshot, disabling Play All until the
   replacement result is complete instead of using stale completed metadata.
3. A demand read cannot be blocked for the full HTTP timeout by a large,
   continuously advancing prefetch body. After four seconds an incomplete
   oversized range and speculative peers are cancelled, and the exact native
   demand is retried in serial mode. The existing 25-second HTTP timeout stays
   below the native bridge's 30-second wait when combined with that budget.
   Response validators, payload budgets, fast parallel/adaptive behavior, and
   byte-exact validation remain in place.

## Verification record

Pinned toolchain: Flutter 3.38.9, commit
`67323de285b00232883f53b84095eb72be97d35c`, Dart 3.10.8.
Dependencies use `flutter pub get --enforce-lockfile`; no dependency upgrade is
part of this merge. The protected files and workflow are unchanged.

The associated pull request records actual local checks and the final candidate
and main CI run links after their SHAs exist. The existing iOS Core workflow
covers full Flutter formatting, analysis and tests, native libmpv/bridge tests,
Android universal/split APK builds and runtime probes, iOS XCTest, unsigned
arm64 device build, and IPA packaging/entitlement/checksum gates.

Local iOS/device builds are not run on the Linux cloud host. Automated checks
are not physical iPhone/iPad/Android or real Emby/OpenList device acceptance;
those remain unclaimed.
