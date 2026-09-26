# PR #9 Mixed Viewer Remediation

Status: IN_PROGRESS
Device acceptance: DEVICE_ACCEPTANCE_PENDING

2026-09-26 authorization update: the owner now authorizes integrating the
diagnostic and multi-server branches, marking PR #9 Ready, and merging after
verification. This supersedes the historical Draft-only/no-merge instructions
below. See [the integration record](../reviews/2026-09-26-branch-integration.md)
and the live PR checks for current evidence. Device acceptance remains pending.

## Baseline

- PR: `#9` (`codex/home-media-mixed-viewer` -> `main`)
- PR state at start: `OPEN`, `DRAFT`
- `INITIAL_PR9_HEAD`: `34d2132390ad896bcdd1d4fd925e71a6f160c2c9`
- `BASE_MAIN`: `23dea387279ee72661727310c758d71ecba38b52`
- ancestry: `origin/main` is already an ancestor of the PR head; the PR is 12
  commits ahead and 0 commits behind, so no merge commit is required
- PR worktree status at start: clean, tracking
  `origin/codex/home-media-mixed-viewer` with `+0/-0`
- the original repository worktree is on
  `wip/full-diagnostic-export-20260827` with seven unrelated modified files; it
  is intentionally left untouched while all PR work happens in the existing
  `emby_my_client_pr9` worktree

## Fixed Constraints

- Continue the existing branch and PR. Do not create, close, merge, or replace
  the PR.
- Keep PR #9 in Draft until the owner explicitly changes it.
- Keep each remediation phase in its own reviewable and revertible commit after
  its focused tests pass.
- Do not add offline mirroring, liked-page synchronization, or other unrelated
  work.
- Automated checks and emulator results do not satisfy real-device acceptance.

## Phase A - Preview Semantics

- Preserve old `automatic` and `serverOnly` configuration values but normalize
  both to server Trickplay behavior.
- Expose only server thumbnails and disabled picture preview in settings, and
  retain time/progress-only feedback when the server has no Trickplay images.
- Bound Trickplay image loading to three seconds and distinguish metadata
  unavailable, source mismatch, invalid metadata, request timeout, network
  failure, and decode failure.
- Make drag generation, media-source changes, player-generation changes, and
  disposal invalidate prior image work and remove every image stream listener.
- Run focused preview/settings tests before committing.

## Phase B - Late Subtitle Tracks

- Keep the initial two-second subtitle-track wait, but allow playback to become
  Ready with subtitle state `waitingForTracks` after that bound.
- Continue one bounded background wait for up to eight more seconds and reapply
  the desired subtitle as soon as embedded or external tracks arrive.
- Bind the task to item ID, playback item session ID, controller generation,
  engine identity, and immutable subtitle selection. Invalidate it on subtitle
  disable, media switch, engine rebuild, shutdown, or disposal.
- Surface a retryable failure only after the full ten-second budget expires.
- Cover delayed embedded tracks, delayed external tracks, and stale events.

## Phase C - Native Operation Barriers

- Model open, play, pause, seek, stop, property write, lifecycle quiesce,
  retirement quiesce, and dispose as typed native operations. Track both the
  original native future and a bounded barrier future.
- Apply the required limits: urgent mute 750 ms; play/pause 3 s; lifecycle
  quiesce 2 s; retirement quiesce 3 s; seek 8 s; stop 5 s; open 18 s; property
  write 2 s; overall shutdown barrier 5 s.
- Add `PlaybackRetirementState` (`active`, `quiescing`, `retiring`,
  `quarantined`, `closed`). Entering quiescing immediately invalidates the
  generation, clears UI playback state, cancels subtitle/cache recovery, and
  rejects new play, seek, reconfiguration, and lifecycle resume work.
- Prove logical exit and stale-event isolation with never-completing play, seek,
  pause, quiesce, and dispose futures.
- Add an application-level `InlinePlaybackResourceLease`; poison it when native
  player destruction cannot be confirmed so later inline playback cannot create
  additional players.

## Phase D - Bounded Viewer Exit

- Reject swipe, seek, playback, and retry after close begins.
- Bound inline coordinator shutdown to three seconds, then detach and quarantine.
- Use `try/finally` to restore system UI and make `Navigator.pop` exactly once.
- Ensure `PopScope` cannot wait forever on a native future and cover this with a
  never-completing shutdown test.

## Phase E - Server Playback Session

- Require `isPaused` in `PlaybackReporter.reportStart`.
- Report Start with `IsPaused=true` for `playAfterReady=false`, then report
  Progress with `IsPaused=false` only after a real successful play.
- Suppress stale-generation/unviewed starts, make Stopped exactly once, and
  always clear transcoding `ActiveEncoding` state.
- Add focused reporter race tests.

## Phase F - Mixed Media And Rebuild Scope

- Define home-media eligibility as `item.isPhoto || item.isPlayable`, including
  `Type=CustomVideo` with `MediaType=Video`.
- Move high-frequency playback listening into the current `InlineVideoPage`,
  keep adjacent video pages cover-only, and wrap the video surface in a
  `RepaintBoundary`.
- Verify eligibility and localized rebuild behavior with focused tests.

## Phase G - Pagination Consistency

- Add explicit `stableOffset` and `identityRescan` pagination strategies.
- Keep raw cursors for stable ordering. Use ID rescan for PlayCount ordering and
  mutable played, unplayed, and favorite queries.
- Test IDs around raw items 59, 60, and 61, as well as reorder-after-play and
  filter-member removal.
- Restore the parent list to the final media ID and correctly propagate
  `totalDirty`.

## Final Verification And Delivery

Run, in order:

1. `dart format --output=none --set-exit-if-changed lib test`
2. `flutter analyze`
3. `flutter test`
4. `git diff --check`
5. `flutter build apk --debug`
6. `flutter build apk --debug --split-per-abi`

Push the existing branch, confirm PR #9 remains Draft, and wait for every GitHub
Actions check to reach a terminal state. Device acceptance remains pending.
