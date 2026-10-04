# Ordinary progressive video controlled input

Ordinary online Emby playback can reuse the existing bounded HTTP Range input
and adaptive read-ahead policy. This is an optional transport optimization;
`sourceRequest` / `isSourceDirect` still mean the strict STRM route.

## Admission and identity

The online resolver admits only an already classified, fixed ordinary source
from its authorized PlaybackInfo response. DirectPlay or DirectStream must have
positive finite duration, progressive HTTP transport, a recognized progressive
container (MP4/M4V/MOV, MKV/Matroska, AVI, TS/MPEGTS), no live stream, opening
token, requires-opening flag, or infinite-stream flag. HLS/DASH, transcode,
unknown-duration, offline, external ordinary URLs, and unrelated HTTP endpoints
keep their original playback path. Neither file suffix nor transportKind alone
is authorization to use the adapter.

The request uses the original selected plan URI and API playback headers, never
the source filesystem path or independently grafted RequiredHttpHeaders. It is
bound to server/user scope, the exact API object, item, source, item session, and
resolver generation. API disposal revokes it. Engine input revisions and
controller generations cancel replacement attempts. Resolver preflight alone
does not revoke a still-playing source when a proposed source switch fails.

The explicit ordinary request policy admits only the configured server origin,
base path, and selected item's stream endpoint, with unchanged routing selectors
on same-origin redirects. The default STRM URL/header restrictions are unchanged.
Configured loopback servers and unsupported endpoint spellings conservatively
retain ordinary native playback. All controlled requests still validate each
redirect and resolved address, enforce TLS, and bound redirect count. Crossing
origin permanently strips headers and Emby credential query data for that chain;
headers are not restored by redirecting back. Observed cross-origin redirects
and unsafe policy/authentication/source-identity failures permanently revoke
native-fallback permission, including failures encountered only by speculative
prefetch. The controller checks that evidence again after stopping the old
input and before resuming a deferred fallback.

## Probe, fallback, and reporting

A preparation probe must verify HTTP 206, finite Content-Range, bounded body,
stable source size/validators, and a sniffed supported container before opening
the controlled native input. Native demuxer/reference restrictions remain active.
The same prepared input supplies cache-size evidence and native playback.

| Situation | Result |
| --- | --- |
| Admission not applicable or engine lacks both preparation and controlled-open capabilities | Original ordinary URL/method/authentication |
| Settled clean Range/container/native-capability rejection | Original ordinary plan, same reporting cycle |
| Settled controlled startup/readiness or compatible runtime failure | At most one original-input reopen per item session, within the existing automatic-open limit |
| Cancellation, stale API/controller, unsettled native timeout | No fallback open |
| Observed destination, TLS, redirect-policy, authentication, invalid-range or source-change rejection | Fail closed; no native/transcode bypass |
| Any observed cross-origin redirect followed by failure | Fail closed rather than reopen an authenticated redirecting URL in native networking |
| Original ordinary fallback itself fails | Existing ordinary transcode/recovery policy applies |
| STRM failure | Existing strict STRM behavior; never ordinary server fallback |

Fallback stops the old native input before another open, releases prepared and
prefetch resources, drops failed size evidence, and preserves source, play
session, selections, position, pause intent, and reporting cycle. A native stop
failure blocks replacement. A generation-bound continuation handles backgrounding
during a committed runtime fallback without spending its one-shot allowance
again. Newer pause intent wins. Reconfiguration/shutdown invalidates the deferred
continuation. The optimization stays disabled for the remainder of the item
session after fallback, preventing retry loops.

No read-ahead or cache budgets increase: adaptive blocks remain 1/2/4/6 MiB,
at most 8 concurrent requests, a 24 MiB forward window, and a 32 MiB input LRU.
Disk-cache and memory-pressure policies remain shared with the existing player.

## Verification

Regression coverage includes the admission matrix, plan/identity invariants,
real authenticated HTTP range reads, redirect/header/query policy, malformed
ranges and source changes, seek/cancellation/resource bounds, exactly-once
reporting, original-path/transcode ordering, lifecycle races, and native libmpv
bootstrap playback, resume, seek, fallback, and teardown. Fixtures are generated
locally and contain no user media or server credentials.

Local verification uses the pinned Dart formatter, whitespace checks, and a
strict `-Wall -Wextra -Werror` native bridge build. Flutter dependencies are not
fully available in this cloud workspace; no denied online dependency fetch is
retried. The existing pull-request CI must run the full format/analyze/test,
Android builds/native checks, and unsigned iOS build/symbol/package gates for
the delivered head commit before this change is considered verified.
