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
| `fc0dc03` | Stored accounts, transactional activation/rollback, login/relogin/removal, scoped workspace lifecycle and management UI | Ordinary three-way merge `8ea4cbf`, after diagnostic merge `69f60ed`; no textual conflicts | account repository/controller/UI, login, shell, scope and cache isolation |

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

### Integration correction

Key the application route tree by API instance, not just the HomeShell. Before
this correction, replacing A with B (or reauthenticating A) left a pushed photo
viewer/player route alive with A's API. Two new regression cases both fail on
the unmodified post-merge `8ea4cbf` app and pass after the correction. They prove
old delayed initialization cannot autoplay, old session shutdown occurs once,
and the same item ID in B does not inherit position or late state from A.
This also retires full-player routes through their existing bounded disposal,
subtitle invalidation and Trickplay listener cleanup.

Additional cross-feature cases prove active-account secure-store failure
restores A and permits a retry, B's WebSocket ignores A's late same-item events
and disconnect callback, and A's cancelled transfer is drained before B loads
the same item using independent scoped offline records and file contents.

### Executed local verification

- Diagnostic stage: **144 passed, 0 failed, 0 skipped**. An initial command
  referenced a nonexistent test filename; corrected using the actual test
  inventory before the successful run. This was a command error, not a waived
  regression.
- Multi-server stage: **78 passed, 0 failed, 0 skipped**.
- Viewer/account UI regression run: **28 passed, 0 failed, 0 skipped**.
- Cross-service regression run: **75 passed, 0 failed, 0 skipped**.
- Format (`lib test`): **270 files, 0 changed**.
- Analyze: **No issues found**.
- Full Windows test run: **1196 passed, 0 failed, 3 pre-existing skips**.
  The skipped native-player genre navigation tests are platform-conditional
  and execute in the Linux CI run. No new skip or weakened assertion was added.
- `git diff --check`: **PASS**.
- Protected files and lockfile compared with workflow baseline `7f985810`: no drift.

Build and final candidate/main CI outcomes are maintained in the live
[PR #9 verification record](https://github.com/jsdfhasuh/emby_my_client/pull/9)
and its linked Actions runs, since the validated SHA is only known after this
document is committed. Only successful checks on that exact candidate count.
The workflow runs on PR code changes and main pushes; iOS has a dependency on
the Quality and Android job. Do not infer readiness from the earlier run.

### Required regression coverage

| Scenario | Evidence |
| --- | --- |
| Photo/video/photo, rapid switches, close and system UI restoration | photo_viewer_screen, inline_playback_coordinator |
| Never-ending play/seek/pause/quiesce/dispose; bounded logical exit | playback_controller, playback_operation_coordinator, photo_viewer_screen |
| Late default subtitles, disable or switch during track wait | playback_controller |
| Trickplay timeout, source changes and late frames | trickplay_preview, seek_preview_controller |
| Prepared-but-paused Start; serialized Progress and exactly-once Stop | playback_controller, playback_session_reporter |
| Raw 59/60/61 boundaries, stable offset and identity rescan | photo_viewer_controller, library_pagination_integrity |
| PlayCount reorder, played/unplayed membership, return position | library_user_data_membership, library_position_integration, library_pagination_integrity |
| A/B and reauthentication route isolation, same item ID | new photo_viewer_screen cases |
| Old realtime/download callbacks; failed secure storage | new emby_websocket_client, download_service, app_controller_multi_server cases |
| Large log tails/export bounds/redaction and download errors | diagnostic_log_large_file, full_diagnostic_export, download_service, downloads_ui; native RunnerTests via CI |

Local iOS build: NOT_RUN (Windows; no Xcode).
`DEVICE_ACCEPTANCE=PENDING`; automation and simulator checks do not satisfy it.
