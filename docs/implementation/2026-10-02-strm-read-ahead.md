# STRM read-ahead and startup progress

The iPad b162 diagnostic showed successful HTTP 206 responses followed by a
readiness timeout 18 seconds after native open. Most subsequent requests fetched
only 64 KiB. The affected MP4 has a 16,588,046-byte `moov` atom at its tail, so
request latency prevented the demuxer from reading the index before the deadline.

## Implementation

- Keep the existing 256 KiB container-sniff prefix pinned. On subsequent cache
  misses fetch up to 1 MiB from the requested offset, clipped at EOF.
- Serve native reads from that range and retain recently used ranges in LRU
  order. Prefix plus retained data has a 32 MiB limit per input. Overlapping
  concurrent reads serialize and share the resulting cache.
- Each new HTTP request still checks destinations, redirects, credentials,
  Content-Range, source length, validators and bounded response bodies.
- Release buffers on close. Queued reads check cancellation before using any
  cached data, and late responses cannot repopulate a closed input.
- Source-direct readiness allows 15 seconds without new response-body bytes,
  with a fixed 120-second total readiness budget. Distinct byte intervals are
  tracked only during this wait; repeated ranges and cache hits do not renew it.
  Cancellation and errors from the controller terminate the wait immediately.
  Ordinary server playback and the native open deadline retain their existing
  timeout behavior.
- Add read-ahead hit and retained-byte counters to input diagnostics, with the
  corresponding iOS export schema updated as well.

## Verification

The local production-transport probe read the affected file's complete tail
index in **7,639 ms**, using **16 HTTP requests** and **238 cache hits**. It
retained 16,850,190 bytes including the prefix. This measures HTTP input on the
Windows server; it is not an iPad first-frame or decoding benchmark.

The opt-in probe is `scripts/diagnostics/probe_strm_read_ahead.dart`. Supply
`STRM_PROBE_URL`, `STRM_PROBE_OFFSET` and `STRM_PROBE_LENGTH`, then run it with
`flutter test`. It prints aggregate counters without source addresses and reads
no more than 32 MiB plus the initial prefix.

Regression coverage includes byte-exact 64 KiB reads of a 16 MiB tail (16 data
requests instead of 256), backward seeks, EOF clipping, cache eviction,
overlapping reads, queued cancellation, source validator changes, idle/total
deadlines, repeated byte intervals, controller readiness and shutdown, and
diagnostic/export schema parity. Tests and analysis use Flutter 3.38.9 at the
repository's pinned revision, with Dart 3.10.8.

All 228 tests in the selected input, startup, controller, cache-controller,
engine, resolver, policy, snapshot, diagnostics and export suites passed after
correcting the shutdown test's expected terminal state to `idle`. Whole-project
analysis and formatting checks passed. Native bridge decoding tests were not
run in this Windows environment.

An iOS build and real-device first-frame/seek/exit checks remain necessary.
Existing iPad installations will continue using the old behavior until updated.
