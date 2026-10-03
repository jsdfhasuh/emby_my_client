# STRM parallel prefetch

The source input now uses up to eight concurrent HTTP Range requests, each up
to 2 MiB. The initial format/length probe remains 256 KiB. A native read starts
or joins its required range before the input fills the forward window; it does
not wait for the other seven responses. Completed ranges are consumed by byte
offset, independently of response order. Native read callbacks remain serial.

Each active transfer owns its HTTP client and diagnostics context. Successfully
completed clients are reused. Redirect credentials, opaque URL spelling,
destination/DNS checks, Content-Range, resource length and validators are still
checked for every request. Speculative failures stop parallel scheduling for
that input; missing bytes are retried on demand with the same validation.

Explicit player seeks cancel unfinished speculative requests before submitting
the native seek. Discontinuous native reads also cancel obsolete prefetch while
preserving a pending range that covers the requested offset. The current native
read is allowed to finish to avoid reporting cancellation as a playback error.
Completed cache entries remain available until ordinary LRU eviction. Closed
or cancelled transfers cannot insert late responses into the cache.

The 32 MiB input payload budget includes the pinned prefix, completed ranges
and reservations for active response bodies. This is separate from libmpv's
disk-cache budget and excludes transient copies, socket buffers and the native
decoder. The window advances only as the decoder requests bytes; it does not
download an entire source independently of playback. Speculative downloads do
not extend the startup watchdog until their bytes are actually requested.

Input summaries include prefetchConcurrency, prefetchBlockBytes,
activeRequests, prefetchCancellations and prefetchFailures. Dart and Swift
diagnostic export schemas carry the same fields.

## Validation

Socket-fixture tests cover eight overlapping requests, demand completion while
background requests are blocked, out-of-order results, seek cancellation,
cache reuse, late replies, single-request fallback, changed validators,
cross-origin credential stripping, rolling memory limits, EOF and shutdown.
Existing native libmpv playback/resume/seek and disk-cache tests remain enabled.
The full local suite passed (1,325 tests; 3 skipped), including native Windows
libmpv tests. Whole-project analysis and formatting checks passed.

A temporary benchmark using the actual Dart source input read 32 MiB from
disjoint ranges of the user's OpenList source on this Windows computer:

| Configuration | Time | Delivered throughput |
| --- | --- | --- |
| One connection, 1 MiB blocks | 14.489 s | 2.32 MB/s |
| Eight connections, 2 MiB blocks | 1.767 s | 18.99 MB/s |

Both runs had zero speculative failures and stayed within the payload budget.
These short transport measurements exclude the native decoder and iPad Wi-Fi;
device throughput must be verified after installation.
