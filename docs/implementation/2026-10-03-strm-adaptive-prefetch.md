# Adaptive STRM ranges

Source input now starts with 2 MiB ranges and at most eight concurrent requests.
The 256 KiB format/length probe is unchanged. Normal sequential reads may
promote to 4 MiB and then 6 MiB; slow requests or failures may reduce the block
size to 1 MiB. Explicit seeks and discontinuous reads reset to 2 MiB without
clearing verified cached data.

Promotion requires four fast full-size transfers (each at most two seconds)
and consumption of at least four blocks of sequential data at the current
tier. A response taking four seconds or more reduces the tier. Old requests
cannot train a newer tier or seek generation. EOF tails and window fragments
are not evidence for promotion.

After promotion, four full-size samples compare bytes/time adjusted for the
new concurrency limit with the previous tier. If this estimated aggregate
throughput falls by more than 20%, the policy rolls back and avoids retrying
that tier until the next seek/reset. This is a request-based estimate, not a
measurement of device-wide bandwidth; it cannot guarantee optimal throughput.

The forward window is capped at 24 MiB, leaving room in the existing 32 MiB
input payload budget for the pinned prefix and other cached bytes. Nominal
limits are eight connections at 1/2 MiB, six at 4 MiB and four at 6 MiB. Earlier
in-flight requests may finish across a transition; future scheduling respects
the new limit and all active body reservations still count against the budget.
The payload budget excludes transient copies, sockets and native decoder memory.

The scheduler walks actual cached/pending byte intervals, handles holes, and
does not assume equal block sizes across a tier change. It waits for a full
block at the moving window edge except at EOF, avoiding repetitive small
requests. Playback-demand bytes retain priority and speculative cancellation,
source identity checks, redirects and failure fallback remain in effect.
Existing diagnostic fields report the current block size and concurrency.

## Validation

Policy tests cover promotion, slow-response demotion, throughput rollback,
retry suppression, seek reset, stale samples, fixed mode and EOF fragments.
Socket fixtures exercise mixed-size sequential coverage, no overlapping
requests, exact returned bytes, seek reset and cached-plus-reserved budget.
The full local suite passed (1,332 tests; 3 skipped), including real Windows
libmpv playback/cache tests. Whole-project analysis and formatting passed.

A temporary benchmark of the actual Dart transport on this Windows computer
read 128 MiB from disjoint ranges of the same OpenList source:

| Configuration | Time | Delivered throughput |
| --- | --- | --- |
| Adaptive, starting at 2 MiB | 4.048 s | 33.15 MB/s |
| Fixed 2 MiB, eight connections | 5.317 s | 25.24 MB/s |

The adaptive run reached 2/4/6 MiB, had no speculative failures, and stayed
within the payload budget. This short benchmark is not an iPad speed promise;
device Wi-Fi, source load and playback pacing affect the result.
