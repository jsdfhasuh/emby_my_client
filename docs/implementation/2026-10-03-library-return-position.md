# Library position after playback

Returning from movie details and playback could land at the bottom of the
first 60 items regardless of the original position. An obscured library route
continues receiving realtime changes. Its preserving refresh cleared the
displayed items and rebuilt them page by page; the immediate post-frame
restoration then clamped the saved offset against an outdated grid extent.

The regression was reproduced at item indices 70, 100, and 180 with delayed
pages and two covering routes. On a compact viewport all three returned to
11,176.61 pixels, the first page's bottom. Waiting 90 seconds without a refresh
preserved the original position.

The preserving refresh now displays its complete previous snapshot until the
replacement prefix is ready. A generation-bound restoration waits for the
replacement sliver's actual layout before applying the saved offset. Repeated
background refreshes carry forward an unapplied position. Local rescans use
the same layout boundary; empty results also complete pending restoration.
Changing filters cancels both the old display snapshot and pending position.
Playback actions remain disabled while a server reload is incomplete.

Regression coverage includes compact and iPad landscape layouts, repeated
refreshes behind detail/playback routes, returning while pages are pending,
later-page failure, genuinely shorter or empty results, filter invalidation,
and a local rescan behind covering routes. Existing pagination strategies and
failure rollback continue to run through the same loading paths.

Validation uses the pinned Flutter/Dart toolchain: formatting, static analysis,
the complete Flutter test suite, and the real Windows libmpv custom-input tests
with the existing cached native libraries. The route/viewport tests simulate
navigation and do not replace physical iPad acceptance.

- Format: 298 files checked, no changes required.
- Static analysis: no issues.
- Full test suite: 1,357 passed, 3 skipped under their existing conditions.
- The 4 real Windows libmpv custom-input tests also pass independently.
