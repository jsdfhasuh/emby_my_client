# Verified STRM disk cache

Previously the source-direct plan remained `unknown`, so the cache resolver
selected `liveOrUnknownLength` even after the HTTP adapter discovered a finite
file. The disk capability probe could pass while no disk cache was requested.

The controller now asks capable source engines to prepare their controlled input
before resolving the cache profile. Preparation validates the HTTP range,
total length and progressive container, then registers the input with libmpv.
The engine retains that input until `openSource` consumes it, so the 256 KiB
prefix is not downloaded again between cache configuration and media load.

Only evidence belonging to the exact active source request can refine the plan.
The verified total replaces the previously declared size for cache budgeting;
URL, headers, tracks and reporting identity remain unchanged. A finite positive
duration and no live-stream ID are required for progressive disk eligibility.
Unknown duration, unsupported engines and live plans keep the conservative
memory policy. HTTP/format failures retain existing bounded playback errors.

All existing cache settings, disk capability checks, free-space guards,
memory-pressure handling and session cleanup still apply. On a recovery or
player recreation, verification runs again on the replacement input. Retirement
and stop cancel pending verification and release any unconsumed prepared input.

## Validation

- Flutter 3.38.9 / Dart 3.10.8: all 1,318 local tests passed (3 skipped).
- Whole-project static analysis and formatting checks passed.
- Real Windows libmpv 0.36 and the compiled C stream bridge: STRM playback and
  resume succeeded with disk cache enabled and `fileCacheBytes > 0`. Only one
  prefix request was made before playback; shutdown removed the cache session.
- Native tests also cover prepared-input reuse, invalidation after stop and
  cancellation during a blocked HTTP preflight.
- Controller tests cover automatic/aggressive/full-read-ahead/memory-only modes,
  low disk space, absent/zero duration, live sources, failed HTTP verification
  and revalidation after player recreation. Identity tests reject unrelated
  requests and non-positive lengths.

The iPad disk-cache outcome still needs confirmation in a new device build.
