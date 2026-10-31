# STRM Detail-First Direct Playback

## Resolution

Confirmed STRM playback reads a fresh authorized item detail before requesting
PlaybackInfo. When the fixed media source exposes an HTTP(S) Path, the client
uses that complete source snapshot (URL, required headers and tracks) directly.
It does not trigger Emby's PlaybackInfo/ffprobe prerequisite. Cached URLs are
not trusted, and missing/duplicate source IDs, authorization failures and sources
requiring server opening still fail closed. Non-HTTP detail paths retain the
existing strict, same-source PlaybackInfo compatibility request.

The metadata-first plan has no PlaySessionId. Existing reporting keeps ItemId,
MediaSourceId and PlayMethod and omits the optional PlaySessionId. Source traffic
continues through the controlled input adapter with per-redirect destination and
header validation; Emby credentials are not passed to an external source.

Diagnostics emit `resolution=detail_direct` or `resolution=playback_info`.

## Startup Budgets

STRM preparation and native opening have a dedicated 120-second bounded budget
in both the controller and engine. Ordinary/native and optional progressive
opening retain the 18-second budget. Controlled-input readiness permits 30
seconds without new byte ranges and retains its 120-second total budget.
Cancellation, teardown barriers and suppression of late native events remain
active; failed/unsettled opens do not authorize native or transcoding fallback.

## Verification Boundary

Regression coverage includes fresh source/header replacement, no PlaybackInfo
on the direct path, legacy local-path compatibility, identity and authorization
failures, cancellation and the dedicated bounded source-open deadline.

Windows direct-URL short-segment decoding was demonstrated before implementation.
That is not acceptance of this application's controlled-input path on iPadOS.
The release still requires device playback, cancellation, resume/seek, subtitle
selection and progress-reporting validation. Source HTTP 5xx and truncated data
are not repaired by bypassing server probing.
