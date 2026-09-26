# Branch integration — 2026-09-26

## Fixed inputs and authorization

- Initial main: `23dea387279ee72661727310c758d71ecba38b52`.
- PR #9: open, draft; head `codex/home-media-mixed-viewer` at
  `7a0b5785ace0aabdc708d076b71777af752ac1c4`.
- Diagnostic source: `f80546d9d196368c1941b7ae3852dc647789845b`.
- Multi-server source: `fc0dc038e5e744456b500ebeafffac0a85d01b46`.
- Local backups: `refs/backups/branch-integration-20260926-101024/`
  (`main`, `mixed-viewer`, `diagnostic`, `multi-server`).
- Original WIP worktree has seven modified files; integration uses the separate
  `emby_integration_20260926` worktree. No stash, reset, or clean is used.
- No AGENTS.md was found in the repository or applicable parent directories.
- The owner's current authorization supersedes the earlier Draft-only plan:
  merge PR #9 after verification, using a merge commit, without deleting sources.
- GitHub reports push permission and merge-commit support; main has no branch
  protection or rulesets at the initial inspection. There are no PR reviews or
  comments. The workflow still supplies the required project verification.

## Source inventory

`git log --graph`, merge-base, left/right counts, diff and `git cherry` show:
main is already an ancestor of PR #9; no main merge is necessary initially.
The diagnostic branch shares history through `49d1ff8`; its five unique commits
are all non-equivalent to PR #9 (PR-only/source-only count: 9/5).
The multi-server branch forks at main and has one unique, non-equivalent commit.

| Source | Unique changes | Integration and semantic resolution | Tests |
| --- | --- | --- | --- |
| PR #9 through `7a0b578` | Mixed sequence, single inline session, stale work rejection, bounded native retirement/exit, late subtitles, Trickplay deadlines, serialized reporting, local video rebuilds, stable/identity pagination | Integration base; preserve all remediation commits | inline coordinator/video, photo viewer/controller, playback controller/reporter, Trickplay, library pagination/viewer |
| `ea6254c` | Bounded diagnostic storage and large-file tail reader | Ordinary three-way merge | diagnostic_log_large_file |
| `1d5ebaf` | Full export error handling, bounded preview, privacy validation and native tests | Same merge; no privacy policy relaxation | full_diagnostic_export; iOS RunnerTests in CI |
| `f090241` | Download cache maintenance, missing-file validation and UI | Same merge | download_service, downloads_ui |
| `c6803a2` | WebSocket generation/socket guards and late connection disposal | Same merge | emby_websocket_client |
| `f80546d` | Completed filtered local scan removes departing members without restarting or losing position | Auto-merge reviewed in library_screen and library_user_data_membership_test: retain identity-rescan pagination and its request expectations, plus completed-scan position preservation | library_user_data_membership, library viewer/pagination |
| `fc0dc03` | Stored accounts, transactional activation/rollback, login/relogin/removal, scoped workspace lifecycle and management UI | Planned ordinary three-way merge after diagnostic focused tests | account repository/controller/UI, login, shell, scope and cache isolation |

No unique source functionality is intentionally omitted or replaced. Historical
shared mixed-viewer commits are inherited once, not reapplied.

## Verification and acceptance

Toolchain follows `.github/workflows/ios-core.yml`: Flutter commit
`67323de285b00232883f53b84095eb72be97d35c` (3.38.9), Dart 3.10.8.
Use `flutter pub get --enforce-lockfile`; do not upgrade dependencies.
CI jobs: **Quality and Android**, followed by **iPadOS device IPA**. CI also
checks protected-file/lock drift, shell scripts, Android native capability and
emulator probes, iOS simulator XCTest, unsigned device build and IPA validation.
The old successful run `33365201068` only covers the initial PR head.

Local and final-head CI results will be recorded after execution.
Local iOS build: NOT_RUN (Windows; no Xcode).
`DEVICE_ACCEPTANCE=PENDING`; automation and simulator checks do not satisfy it.
