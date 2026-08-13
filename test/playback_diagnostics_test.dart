import 'dart:io';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/cache/native_playback_property_access.dart';
import 'package:emby_my_client/playback/cache/playback_cache_capabilities.dart';
import 'package:emby_my_client/playback/cache/playback_cache_coordinator.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_evidence.dart';
import 'package:emby_my_client/playback/cache/playback_cache_policy.dart';
import 'package:emby_my_client/playback/cache/playback_cache_option_bindings.dart';
import 'package:emby_my_client/playback/cache/playback_cache_settings.dart';
import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:emby_my_client/playback/cache/playback_cache_telemetry.dart';
import 'package:emby_my_client/playback/playback_diagnostics.dart';
import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
import 'package:emby_my_client/playback/playback_seek_statistics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fixed playback diagnostics never expose source strings or paths', () {
    final lines = <String>[];
    final diagnostics = PlaybackDiagnostics(
      writer: (_, component, message) => lines.add('$component $message'),
      seekFlushInterval: const Duration(hours: 1),
    );
    PlaybackCacheEngineCapabilities capabilitiesWith(
      String fingerprint,
      String platform,
    ) => PlaybackCacheEngineCapabilities(
      mpvVersionFingerprint: fingerprint,
      platform: platform,
      optionSupport: {
        for (final option in playbackCacheOptionNames) option: true,
      },
      propertySupport: {
        for (final property in playbackCachePropertyNames) property: true,
      },
      supportsImmediateUnlink: true,
      profileSwitchStrategy:
          PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop,
      resetValues: const {
        'demuxer-cache-dir':
            r'C:\Users\owner\Library\password-token-media-title',
      },
      optionBindings: resolvePlaybackCacheOptionBindings(
        optionSupport: {
          for (final option in playbackCacheOptionNames) option: true,
        },
        resetValues: const {
          'demuxer-cache-dir':
              r'C:\Users\owner\Library\password-token-media-title',
        },
        requiredChoiceAvailable: const {'demuxer-cache-unlink-files': true},
        writeReadBackPassed: const {'demuxer-cache-dir': true},
      ),
    );
    final capabilities = capabilitiesWith(
      'https://media.example.test/file?X-Emby-Token=secret',
      'username@host:8096',
    );
    final profile = ResolvedPlaybackCacheProfile(
      runtimeMode: PlaybackCacheRuntimeMode.disk,
      transportKind: PlaybackTransportKind.progressiveHttp,
      fallbackReason: PlaybackCacheFallbackReason.none,
      forwardTarget: const Duration(minutes: 3),
      backwardTarget: const Duration(minutes: 2),
      sessionTargetBytes: 512 << 20,
      reservedFreeBytes: 2 << 30,
      demuxerForwardMetadataBytes: 32 << 20,
      demuxerBackwardMetadataBytes: 16 << 20,
      metadataBudgetCapBytes: 64 << 20,
      streamBufferBytes: 128 << 10,
      donateBuffer: true,
      sessionDirectory: Directory(
        r'C:\Users\owner\Library\password-token-media-title',
      ),
    );

    diagnostics.cacheCapabilitiesResolved(capabilities);
    expect(
      lines,
      contains(
        allOf(
          contains('cacheDirectoryVariant=modern'),
          contains('cacheDirectoryModernStatus=usable'),
          contains('cacheUnlinkVariant=unavailable'),
          contains('diskCache=true'),
        ),
      ),
    );
    for (final payload in const [
      'Authorization: Basic credential',
      'Bearer accessTokenValue',
      'Cookie=session-value',
      'deviceId=device-value',
      'movie-title.mkv',
      'server_name',
    ]) {
      diagnostics.cacheCapabilitiesResolved(capabilitiesWith(payload, payload));
    }
    diagnostics.cacheSettingsLoaded(PlaybackCacheMode.balanced);
    diagnostics.cacheDirectoryResult(
      PlaybackCacheStorageSnapshot.available(
        session: PlaybackCacheSession(
          directory: profile.sessionDirectory!,
          nonce: '0123456789abcdef0123456789abcdef',
        ),
        freeBytes: 20 << 30,
      ),
    );
    diagnostics.cacheDirectoryResult(
      const PlaybackCacheStorageSnapshot.unavailable(
        PlaybackCacheStorageFailureReason.directoryUnavailable,
      ),
    );
    diagnostics.cacheProfileResolved(profile);
    diagnostics.cacheApplyResult(
      const PlaybackCacheApplyResult(
        requestedMode: PlaybackCacheRuntimeMode.disk,
        actualMode: PlaybackCacheRuntimeMode.disk,
        fallbackReason: PlaybackCacheFallbackReason.none,
        requiresPlayerRecreation: false,
        readBack: {
          'demuxer-cache-dir':
              r'C:\Users\owner\Library\password-token-media-title',
        },
      ),
    );
    diagnostics.cacheMpvCreateFailed();
    diagnostics.cacheSafetyTriggered(PlaybackCacheSafetyReason.lowSpace);
    diagnostics.cacheSnapshotUnavailable();
    diagnostics.cacheSessionCleaned();
    diagnostics.cacheStaleCleanup();
    diagnostics.operationTimeout(
      PlaybackOperationTimeoutKind.nativePropertyRead,
    );
    diagnostics.automaticOpenBudgetExhausted(
      reason: AutomaticPlaybackOpenReason.runtimeTranscodeRecovery,
      automaticOpenCount: 6,
    );
    diagnostics.seekRecovery(
      PlaybackRecoveryDiagnosticEvent.pending,
      fingerprint: PlaybackRecoveryFingerprint.partialFile,
    );

    final joined = lines.join('\n').toLowerCase();
    for (final forbidden in const [
      'https://',
      'x-emby-token',
      'secret',
      'username',
      'host:8096',
      r'c:\users',
      'password-token-media-title',
      'demuxer-cache-dir',
      'authorization',
      'basic',
      'credential',
      'bearer',
      'accesstokenvalue',
      'cookie',
      'session-value',
      'deviceid',
      'device-value',
      'movie-title.mkv',
      'server_name',
    ]) {
      expect(joined, isNot(contains(forbidden)));
    }
    expect(joined, contains('mpvversionfingerprint=unavailable'));
    expect(joined, contains('platform=unsupported'));
    expect(joined, isNot(contains('option_demuxer_cache_dir')));
    expect(joined, isNot(contains('property_demuxer_cache_state')));
    expect(joined, contains('event=playback_cache_disk_enabled'));
    expect(joined, contains('fingerprint=partial_file'));
  });

  test('100 seek requests are emitted as bounded aggregate counts', () {
    final lines = <String>[];
    final diagnostics = PlaybackDiagnostics(
      writer: (_, _, message) => lines.add(message),
      seekFlushInterval: const Duration(hours: 1),
    );

    for (var index = 0; index < 100; index++) {
      diagnostics.seekRequested();
    }
    for (var index = 0; index < 98; index++) {
      diagnostics.seekCompleted(
        const SeekResult(
          disposition: SeekDisposition.superseded,
          requestedTarget: Duration(hours: 99),
          settled: false,
        ),
      );
    }
    for (var index = 0; index < 2; index++) {
      diagnostics.seekCompleted(
        const SeekResult(
          disposition: SeekDisposition.executed,
          requestedTarget: Duration(hours: 99),
          settled: true,
        ),
      );
    }
    diagnostics.flushSeekSummary();

    expect(lines, hasLength(3));
    expect(lines, contains('event=playback_seek_requested count=100'));
    expect(lines, contains('event=playback_seek_coalesced count=98'));
    expect(lines, contains('event=playback_seek_executed count=2'));
    expect(lines.join('\n'), isNot(contains('99:00:00')));
  });

  test('cache session summaries contain only fixed aggregate fields', () {
    final lines = <String>[];
    final diagnostics = PlaybackDiagnostics(
      writer: (_, _, message) => lines.add(message),
    );
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('private-session-id'),
    );
    accumulator.observe(
      const PlaybackCacheEvidenceObservation(
        cacheEvidence: PlaybackCacheEvidence.diskDataObserved,
        telemetryStatus: PlaybackCacheTelemetryStatus.available,
        fileCacheBytes: 10 << 20,
        actualForward: Duration(seconds: 45),
        actualBackward: Duration(seconds: 20),
        requestedMode: PlaybackCacheRuntimeMode.disk,
        confirmedMode: PlaybackCacheRuntimeMode.disk,
        fallbackReason: PlaybackCacheFallbackReason.none,
        testOverrideActive: true,
      ),
    );
    accumulator.recordCleanup(PlaybackCacheCleanupResult.succeeded);
    diagnostics.cacheSessionSummary(accumulator.finalize());

    final output = lines.join('\n');
    expect(output, contains('event=playback_cache_session_summary'));
    expect(output, contains('cacheEvidence=diskDataObserved'));
    expect(output, contains('peakFileCacheBytes=lte16MiB'));
    expect(output, contains('seekRequestedCount=0'));
    expect(output, contains('seekExecutedCount=0'));
    expect(output, contains('seekSupersededCount=0'));
    expect(output, contains('seekFailedCount=0'));
    expect(output, contains('seekCancelledCount=0'));
    expect(output, contains('testOverrideUsed=true'));
    expect(output, isNot(contains('private-session-id')));
    expect(output, isNot(contains('10')));
  });

  test('seek timeout categories remain fixed and aggregated', () {
    final lines = <String>[];
    final diagnostics = PlaybackDiagnostics(
      writer: (_, _, message) => lines.add(message),
      seekFlushInterval: const Duration(hours: 1),
    );

    diagnostics.seekRequested();
    diagnostics.seekCompleted(
      const SeekResult(
        disposition: SeekDisposition.failed,
        requestedTarget: Duration(minutes: 42),
        settled: false,
        failureKind: SeekFailureKind.callTimeout,
      ),
    );
    diagnostics.flushSeekSummary();

    expect(lines, contains('event=playback_operation_timeout kind=seek_call'));
    expect(lines, contains('event=playback_seek_requested count=1'));
    expect(lines, contains('event=playback_seek_failed count=1'));
    expect(lines.join('\n'), isNot(contains('42')));
  });

  test('repeated timeout kinds are rate limited independently', () {
    final lines = <String>[];
    var now = DateTime.utc(2026, 8, 10);
    final diagnostics = PlaybackDiagnostics(
      writer: (_, _, message) => lines.add(message),
      clock: () => now,
    );

    diagnostics.operationTimeout(
      PlaybackOperationTimeoutKind.nativePropertyRead,
    );
    diagnostics.nativeOperationTimeout(
      NativePlaybackOperationKind.propertyRead,
    );
    diagnostics.operationTimeout(PlaybackOperationTimeoutKind.engineStop);
    now = now.add(const Duration(seconds: 2));
    diagnostics.operationTimeout(
      PlaybackOperationTimeoutKind.nativePropertyRead,
    );

    expect(
      lines.where((line) => line.contains('kind=native_property_read')),
      hasLength(2),
    );
    expect(
      lines.where((line) => line.contains('kind=engine_stop')),
      hasLength(1),
    );
  });

  test('cache diagnostic fields distinguish unavailable from zero', () {
    final lines = <String>[];
    final diagnostics = PlaybackDiagnostics(
      writer: (_, _, message) => lines.add(message),
    );
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('diagnostic-missing'),
    );
    diagnostics.cacheSessionSummary(accumulator.finalize());
    expect(lines.single, contains('peakFileCacheBytes=unavailable'));
    expect(lines.single, contains('maxActualForward=unavailable'));
    expect(lines.single, contains('maxActualBackward=unavailable'));
  });

  test('cache and seek summaries use the same frozen exact counts', () {
    final lines = <String>[];
    final diagnostics = PlaybackDiagnostics(
      writer: (_, _, message) => lines.add(message),
    );
    final accumulator = PlaybackCacheEvidenceAccumulator(
      sessionId: const PlaybackItemSessionId('frozen-counts'),
    );
    final snapshot = const PlaybackSeekStatisticsSnapshot(
      requested: 101,
      executed: 2,
      superseded: 97,
      failed: 1,
      cancelled: 1,
    );

    diagnostics.cacheSessionSummary(
      accumulator.finalize(seekStatistics: snapshot),
    );
    diagnostics.flushSeekSummary(snapshot: snapshot);

    final summary = lines.singleWhere(
      (line) => line.contains('event=playback_cache_session_summary'),
    );
    expect(summary, contains('seekRequestedCount=101'));
    expect(summary, contains('seekExecutedCount=2'));
    expect(summary, contains('seekSupersededCount=97'));
    expect(summary, contains('seekFailedCount=1'));
    expect(summary, contains('seekCancelledCount=1'));
    expect(lines, contains('event=playback_seek_requested count=101'));
    expect(lines, contains('event=playback_seek_coalesced count=97'));
    expect(lines, contains('event=playback_seek_executed count=2'));
    expect(lines, contains('event=playback_seek_failed count=1'));
    expect(lines, contains('event=playback_seek_cancelled count=1'));
  });
}
