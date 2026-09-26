# Home Media Mixed Viewer

Status: DESIGN_DEFINED
Device acceptance: DEVICE_ACCEPTANCE_PENDING

## Scope

The mixed viewer is enabled only when a photo is opened from a
`LibraryContentProfileKind.homeVideosAndPhotos` library. It keeps the existing
full-screen photo-viewer route and extends that route's sequence to playable
videos. Search, Home, the standalone photo browser, photo libraries, generic
mixed libraries, movie libraries, and television libraries remain photo-only
unless a future caller explicitly supplies the home-media mode.

Direct taps on video cards continue to open the existing detail route. Folder,
collection-folder, and photo-album navigation, play-all queues, filters, sorting,
facets, alphabet navigation, and library layout are unchanged.

## Media Sequence Model

`PhotoSequenceSource` gains an explicit viewer policy:

- `MediaViewerMode.photosOnly` accepts only `item.isPhoto`.
- `MediaViewerMode.homeMedia` accepts `item.isPhoto || item.isPlayable`.

The compatibility-oriented `Photo*` class names remain in place to avoid a
repo-wide rename. `PhotoViewerController` exposes the filtered list as viewer
media, while narrow photo-named accessors may remain temporarily where needed
by existing callers. The policy is the only place that decides whether an item
belongs in the viewer.

Initial and paged items are scanned once in Emby API order. Accepted items are
appended in that same relative order; photos and videos are never collected
into separate arrays or concatenated. Folder, `CollectionFolder`, `PhotoAlbum`,
`Series`, and all other unsupported entries are excluded by the policy. The
initial index and `positionLabel` are calculated against the filtered viewer
media list, so their counts exclude directories and albums.

## Pagination And Raw Cursor

The source continues to hold raw directory or query results. The controller
keeps distinct raw-item and viewer-media collections:

- the raw cursor advances by `EmbyItemPage.rawItemCount`;
- duplicate IDs are rejected before either collection is updated;
- only accepted items enter the viewer-media list;
- a page with no newly accepted media is followed by another page while the
  raw cursor reports more data;
- a page containing only folders, unsupported items, or duplicates therefore
  cannot terminate pagination early;
- pagination-stalled, changing-total, dirty-total, and total-below-loaded
  diagnostics retain their existing behavior;
- a response arriving after controller disposal is discarded before state is
  updated.

The current bounded image prefetch window remains unchanged. It requests the
primary image for photos and the cover image for videos. Prefetch never calls
`getPlaybackPlan`, opens a media URL, creates a `Player`, or starts a neighboring
video session.

## Single Player Rule

One viewer-level playback coordinator owns video activation. Individual
`InlineVideoPage` widgets are passive views and never own long-lived players.
Across the entire route there can be at most one:

- media_kit `Player`;
- `VideoController`/video output;
- `PlaybackController`;
- active `InlinePlaybackSession`.

Every target change first invalidates the current generation, pauses the active
session, records its position, and begins its single-flight shutdown. Creation
of the next session is serialized behind completion of that shutdown. Adjacent
PageView children may build their covers, but building a child cannot create a
playback session.

## Inline Playback Session

`InlinePlaybackSession` is an injectable interface used by both the coordinator
and deterministic tests. It exposes an immutable state/listenable plus start,
play, pause, seek, memory-pressure, and idempotent shutdown operations. State
contains the item identity, phase, position, duration, buffering/error data,
playing/completed flags, and the optional media_kit video output required by the
ready view.

The production implementation owns one media_kit `Player`, one
`VideoController`, one `MediaKitPlaybackEngine`, and one `PlaybackController`.
It does not enter `PlayerScreen`, invoke `PlayerSystemUiController`, force an
orientation, add queue behavior, or implement PIP, Trickplay, brightness,
volume, subtitle-selection, audio-track, speed, or cache-settings panels.

Production sessions continue to use the current playback stack:

- `EmbyStreamResolver` chooses DirectPlay, DirectStream, or Transcode and keeps
  the existing direct-play failure fallback;
- `PlaybackSessionReporter` reports start, progress, and stop;
- `api.playbackHeaders`, `PlaybackCacheStorage`, and the current maximum bitrate
  and cache settings are passed through;
- persisted playback rate, audio delay, subtitle delay, and subtitle style are
  applied through existing playback APIs;
- playback URLs are never assembled in the viewer.

## Shared Playback Bootstrap

A small online playback bootstrap/factory is extracted from the current
`PlayerScreen` startup path. It is responsible only for constructing and
configuring `PlaybackController` with the resolver, reporter, engine, headers,
cache, item session, diagnostic overrides, and `PlaybackSettings`, then starting
the controller.

Both `PlayerScreen` and the production inline session use this bootstrap. Full
player state synchronization, queue changes, Trickplay, PIP, gestures, remote
controls, system UI, and orientation stay in `PlayerScreen`. Offline playback
continues on its existing path unless the shared helper can support it without
changing behavior.

`PlaybackController.start` may gain the backward-compatible optional arguments
`Duration? resumePosition` and `bool playAfterReady = true`. Its existing
defaults preserve PlayerScreen behavior. An explicit viewer-local resume
position takes precedence over the Emby item resume point; when absent, the
existing Emby resume rule remains authoritative.

## Session Lifecycle

When the current PageView index becomes a video, the coordinator creates a new
session after any prior shutdown, starts it with the saved local position when
present, and autoplays with sound. Activating the same current video is a no-op.

When the index leaves a video, the coordinator performs this order:

1. invalidate the generation and target identity;
2. pause immediately so sound stops;
3. snapshot and save the current position by video ID;
4. unsubscribe the session state listener;
5. await `PlaybackController.shutdown` through the session;
6. dispose the controller, player, video controller/output, and related
   resources owned by the session.

Returning to that video creates a fresh session and supplies the saved position.
A failed session is closed; retry always creates a fresh session. Natural
completion stays on the current page and exposes replay. Replay seeks to zero
before playing and never advances PageView or invokes PlayerScreen queue logic.

## Stale Async Results

Each target change and route shutdown increments a generation. Factory, start,
state-listener, retry, lifecycle-resume, and seek continuations capture both the
generation and target item ID. A continuation may publish state or play only if
both still match and the coordinator is not shutting down.

If an obsolete factory or start operation completes, its session is immediately
paused and shut down. It cannot replace the active output, publish a ready/error
state, or emit sound. The previous session's shutdown Future is awaited before a
new production session is constructed, preserving the one-player invariant even
during Video A -> Photo -> Video B and Video A -> Video B swipes.

## UI And Gestures

The route keeps one `PageView.builder`:

- photo items build `ZoomablePhotoPage`;
- video items build `InlineVideoPage`.

Inactive video pages show their Emby cover and a video icon without creating a
session. Loading keeps the cover visible with a centered progress indicator.
Ready uses media_kit `Video` with `NoVideoControls`, a black background, and
`BoxFit.contain`. Paused and completed states show a central play/replay button.
Failed state keeps the cover, shows a concise error, and offers retry.

The inline controls provide play/pause, current time, total duration, a draggable
progress slider, buffering feedback, and retry. The existing viewer top bar
continues to show back, current media name, and filtered position. Bottom
previous/next navigation remains available with media-neutral tooltips.

Photo zoom continues to disable PageView scrolling. Video pixels outside the
slider remain horizontally pageable. Slider drag start temporarily disables
PageView physics; drag updates only the preview position, and drag end seeks and
reenables paging. Control hits are handled inside the video page so they do not
toggle the outer controls or accidentally turn the page.

## Route And App Lifecycle

The viewer becomes a `WidgetsBindingObserver`. Initial entry changes only the
system UI mode to `immersiveSticky`; inline video never changes orientation.

An idempotent asynchronous close operation is shared by the toolbar back button,
`PopScope` system back, and dispose fallback. It pauses and shuts down the
coordinator, restores `SystemUiMode.edgeToEdge`, and only then pops with the
current media ID. Repeated close requests join the same Future and pop once.

For `inactive`, `paused`, and `detached`, the coordinator pauses the current
session and records whether it had been playing. On `resumed`, it plays only if
that exact session and video are still current and were playing before the
lifecycle pause. It never revives a session after a swipe to a photo. Memory
pressure is forwarded only to the current session/controller. Observer removal
precedes final disposal.

## Library Integration

`LibraryBrowseScreen` assigns `homeMedia` only when
`profile.kind == LibraryContentProfileKind.homeVideosAndPhotos`; every other
source is explicitly or by default `photosOnly`. The existing source loader
continues to capture the current directory/media/favorites/facet scope, media
type, played and favorite filters, sort order, alphabet filter, genre/tag IDs,
raw cursor, total, and page size.

The photo route result is interpreted as the final media ID. If that item is in
the loaded library result, the existing browse scroll-position machinery is
asked to restore it without restarting the query. Video-card taps remain detail
navigation and are covered by regression tests.

## Automated Test Matrix

Sequence tests cover both modes, stable mixed ordering, unsupported containers,
initial video/photo index, filtered position labels, mixed pagination, empty
accepted pages, raw cursor and dirty/stalled behavior, duplicate IDs, disposed
responses, and cover-only prefetch.

Coordinator tests use controllable fake sessions to cover one autoplaying
activation, same-video idempotence, pause-before-shutdown, A-before-B teardown,
maximum concurrency one, delayed stale initialization, A -> Photo -> B, local
resume, fresh-session retry, repeated shutdown, lifecycle pause/resume identity,
memory pressure, and completion/replay.

Widget tests use fake sessions rather than libmpv. They cover Photo -> Video ->
Photo ordering, video activation and teardown, inactive/loading/ready/paused/
completed/failed views, title and position, slider gesture isolation, existing
photo zoom behavior, photos-only zero-session behavior, async back ordering and
result, edge-to-edge restoration, stale rapid swipes, and consecutive videos
with one active fake session.

Playback regression tests cover the unchanged default start behavior, explicit
resume override, `playAfterReady: false`, shutdown during resolve/open, direct
play fallback, and subtitle-default behavior. Library tests cover source mode by
profile, current query capture, mixed initial items, unchanged video-detail tap,
and final-media-ID restoration.

## Device Acceptance

Owner acceptance remains pending for both iPhone/iPad and Android. It must cover
Photo A -> Video B -> Photo C -> Video D, sound stopping on every leave, local
resume, consecutive videos, rapid swipe while loading, route exit, background
pause/resume, unchanged orientation, restored status bars, HEVC/H.264/MOV and
server transcode cases, at least 20 mixed swipes without player accumulation,
and a sequence crossing the 60-item pagination boundary.

No automated or simulator result marks these owner gates accepted.

## Non-Goals

This change does not alter video-card routing, add a second player dependency,
force DirectPlay, construct stream URLs, add native/system/external player
routes, prefetch video plans or streams, change Emby played thresholds, add
subtitle/audio/speed/cache dialogs, add brightness or volume gestures, add PIP
or Trickplay, add automatic next playback, change library queries globally,
redesign library layout, or modify Android/iOS platform projects and workflows.
