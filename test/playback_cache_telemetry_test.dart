import 'dart:async';

import 'package:emby_my_client/playback/cache/native_playback_property_access.dart';
import 'package:emby_my_client/playback/cache/playback_cache_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pure node parser accepts only the stable telemetry shape', () {
    final state = PlaybackCacheNativeNodeParser.parse({
      'file-cache-bytes': 12,
      'raw-input-rate': '2048',
      'seekable-ranges': [
        {'start': 0, 'end': 10},
        {'start': 10, 'end': 5},
      ],
      'unknown': r'C:\Users\owner\secret',
    });
    expect(state?.fileCacheBytes, 12);
    expect(state?.rawInputRateBytesPerSecond, 2048);
    expect(state?.seekableRanges, hasLength(1));
    expect(PlaybackCacheNativeNodeParser.parse({'unknown': 'only'}), isNull);
    expect(
      PlaybackCacheNativeNodeParser.parse({'file-cache-bytes': double.nan}),
      isNull,
    );
  });

  test(
    'structured property-list entries are matched without debug strings',
    () {
      const propertyList = [
        {'name': 'demuxer-cache-state', 'value': 'node'},
        {'name': 'idle-active'},
      ];

      expect(
        nativePropertyListContains(propertyList, 'demuxer-cache-state'),
        isTrue,
      );
      expect(nativePropertyListContains(propertyList, 'missing'), isFalse);
      expect(
        nativePropertyListContains([
          {'value': 'demuxer-cache-state'},
          {'name': 42},
        ], 'demuxer-cache-state'),
        isFalse,
      );
      expect(
        nativePropertyListContains([
          'demuxer-cache-state',
        ], 'demuxer-cache-state'),
        isTrue,
      );
    },
  );

  test('property support prefers the structured active-handle node', () async {
    var fallbackReads = 0;

    final supported = await nativePropertyAvailableFromPropertyList(
      propertyName: 'demuxer-cache-state',
      readStructured: () async => const ['idle-active', 'demuxer-cache-state'],
      readFallback: () async {
        fallbackReads++;
        return const [];
      },
    );

    expect(supported, isTrue);
    expect(fallbackReads, 0);
  });

  test(
    'property support safely uses the string fallback for a null node',
    () async {
      var fallbackReads = 0;

      final supported = await nativePropertyAvailableFromPropertyList(
        propertyName: 'demuxer-cache-state',
        readStructured: () async => null,
        readFallback: () async {
          fallbackReads++;
          return const ['demuxer-cache-state'];
        },
      );

      expect(supported, isTrue);
      expect(fallbackReads, 1);
    },
  );

  test(
    'property node timeout fails closed without a second native read',
    () async {
      final pending = Completer<Object?>();
      var fallbackReads = 0;
      final timeouts = <NativePlaybackOperationKind>[];

      final supported = await nativePropertyAvailableFromPropertyList(
        propertyName: 'demuxer-cache-state',
        readStructured: () => pending.future,
        readFallback: () async {
          fallbackReads++;
          return const ['demuxer-cache-state'];
        },
        timeout: const Duration(milliseconds: 1),
        timeoutReporter: timeouts.add,
      );

      expect(supported, isFalse);
      expect(fallbackReads, 0);
      expect(timeouts, [NativePlaybackOperationKind.propertyRead]);
    },
  );

  test(
    'property string fallback is bounded by the same read timeout',
    () async {
      final pending = Completer<Object?>();
      final timeouts = <NativePlaybackOperationKind>[];

      final supported = await nativePropertyAvailableFromPropertyList(
        propertyName: 'demuxer-cache-state',
        readStructured: () async => null,
        readFallback: () => pending.future,
        timeout: const Duration(milliseconds: 1),
        timeoutReporter: timeouts.add,
      );

      expect(supported, isFalse);
      expect(timeouts, [NativePlaybackOperationKind.propertyRead]);
    },
  );

  test(
    'parses a valid native cache state and ignores damaged ranges',
    () async {
      final access = _Access(
        native: {
          'demuxer-cache-state': {
            'file-cache-bytes': '1234',
            'raw-input-rate': 8192,
            'cache-duration': 12.5,
            'reader-pts': '20',
            'seekable-ranges': [
              {'start': 10, 'end': 20.5},
              {'start': 'bad', 'end': 50},
            ],
            'unknown': 'ignored',
          },
        },
      );

      final result = await NativePlaybackCacheTelemetryReader(
        access: access,
      ).readDemuxerCacheState();

      expect(result.status, PlaybackCacheTelemetryStatus.available);
      expect(result.state?.fileCacheBytes, 1234);
      expect(result.state?.rawInputRateBytesPerSecond, 8192);
      expect(result.state?.seekableRanges, hasLength(1));
      expect(
        result.state?.seekableRanges.single.start,
        const Duration(seconds: 10),
      );
      expect(
        result.state?.seekableRanges.single.end,
        const Duration(milliseconds: 20500),
      );
      expect(result.state?.cacheDuration, const Duration(milliseconds: 12500));
    },
  );

  test(
    'distinguishes missing field, unsupported property, and read failure',
    () async {
      final missing = _Access(
        native: {'demuxer-cache-state': <String, Object>{}},
      );
      expect(
        (await NativePlaybackCacheTelemetryReader(
          access: missing,
        ).readDemuxerCacheState()).status,
        PlaybackCacheTelemetryStatus.fieldTemporarilyAbsent,
      );

      final unsupported = _Access(hasPropertyValue: false);
      expect(
        (await NativePlaybackCacheTelemetryReader(
          access: unsupported,
        ).readDemuxerCacheState()).status,
        PlaybackCacheTelemetryStatus.unsupported,
      );

      final failed = _Access(throwOnNativeRead: true);
      expect(
        (await NativePlaybackCacheTelemetryReader(
          access: failed,
        ).readDemuxerCacheState()).status,
        PlaybackCacheTelemetryStatus.readFailed,
      );
    },
  );

  test(
    'single flight keeps one active read and only the latest pending read',
    () async {
      final first = Completer<PlaybackCacheTelemetryRead>();
      final reader = _Reader([
        first.future,
        Future.value(
          const PlaybackCacheTelemetryRead.available(
            PlaybackCacheNativeState(fileCacheBytes: 2),
          ),
        ),
      ]);
      final coordinator = PlaybackCacheTelemetryReadCoordinator(reader: reader);
      final firstRead = coordinator.readForGeneration(
        generation: 1,
        isGenerationCurrent: (_) => true,
      );
      final replaced = coordinator.readForGeneration(
        generation: 2,
        isGenerationCurrent: (_) => true,
      );
      final latest = coordinator.readForGeneration(
        generation: 3,
        isGenerationCurrent: (_) => true,
      );

      expect(await replaced, isNull);
      expect(reader.calls, 1);
      first.complete(
        const PlaybackCacheTelemetryRead.available(
          PlaybackCacheNativeState(fileCacheBytes: 1),
        ),
      );
      expect((await firstRead)?.state?.fileCacheBytes, 1);
      expect((await latest)?.state?.fileCacheBytes, 2);
      expect(reader.calls, 2);
      coordinator.dispose();
    },
  );

  test('stale generation result is discarded', () async {
    final pending = Completer<PlaybackCacheTelemetryRead>();
    final coordinator = PlaybackCacheTelemetryReadCoordinator(
      reader: _Reader([pending.future]),
    );
    var currentGeneration = 1;
    final result = coordinator.readForGeneration(
      generation: 1,
      isGenerationCurrent: (generation) => generation == currentGeneration,
    );
    currentGeneration = 2;
    pending.complete(
      const PlaybackCacheTelemetryRead.available(
        PlaybackCacheNativeState(fileCacheBytes: 5),
      ),
    );
    expect(await result, isNull);
    coordinator.dispose();
  });

  test('stale engine identity result is discarded', () async {
    final pending = Completer<PlaybackCacheTelemetryRead>();
    final coordinator = PlaybackCacheTelemetryReadCoordinator(
      reader: _Reader([pending.future]),
    );
    final session = Object();
    final firstEngine = Object();
    var currentEngine = firstEngine;
    final identity = PlaybackCacheReadIdentity(
      sessionIdentity: session,
      engineIdentity: firstEngine,
      operationGeneration: 1,
    );
    final result = coordinator.readForIdentity(
      identity: identity,
      isIdentityCurrent: (candidate) =>
          identical(candidate.sessionIdentity, session) &&
          identical(candidate.engineIdentity, currentEngine) &&
          candidate.operationGeneration == 1,
    );

    currentEngine = Object();
    pending.complete(
      const PlaybackCacheTelemetryRead.available(
        PlaybackCacheNativeState(fileCacheBytes: 5),
      ),
    );

    expect(await result, isNull);
    coordinator.dispose();
  });

  test('stale pending identity never starts a native read', () async {
    final first = Completer<PlaybackCacheTelemetryRead>();
    final reader = _Reader([
      first.future,
      Future.value(
        const PlaybackCacheTelemetryRead.available(
          PlaybackCacheNativeState(fileCacheBytes: 2),
        ),
      ),
    ]);
    final coordinator = PlaybackCacheTelemetryReadCoordinator(reader: reader);
    final session = Object();
    final engine = Object();
    var currentGeneration = 1;
    final firstRead = coordinator.readForIdentity(
      identity: PlaybackCacheReadIdentity(
        sessionIdentity: session,
        engineIdentity: engine,
        operationGeneration: 1,
      ),
      isIdentityCurrent: (identity) =>
          identity.operationGeneration == currentGeneration,
    );
    final pending = coordinator.readForIdentity(
      identity: PlaybackCacheReadIdentity(
        sessionIdentity: session,
        engineIdentity: engine,
        operationGeneration: 2,
      ),
      isIdentityCurrent: (identity) =>
          identity.operationGeneration == currentGeneration,
    );

    currentGeneration = 3;
    first.complete(
      const PlaybackCacheTelemetryRead.available(
        PlaybackCacheNativeState(fileCacheBytes: 1),
      ),
    );

    expect(await firstRead, isNull);
    expect(await pending, isNull);
    expect(reader.calls, 1);
    coordinator.dispose();
  });

  test(
    'dispose releases an active read without waiting for the native future',
    () async {
      final pending = Completer<PlaybackCacheTelemetryRead>();
      final coordinator = PlaybackCacheTelemetryReadCoordinator(
        reader: _Reader([pending.future]),
      );
      final result = coordinator.readForGeneration(
        generation: 1,
        isGenerationCurrent: (_) => true,
      );

      coordinator.dispose();

      expect(await result, isNull);
      pending.complete(
        const PlaybackCacheTelemetryRead.available(
          PlaybackCacheNativeState(fileCacheBytes: 99),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        coordinator.readForGeneration(
          generation: 2,
          isGenerationCurrent: (_) => true,
        ),
        completion(isNull),
      );
    },
  );
}

class _Reader implements PlaybackCacheTelemetryReader {
  _Reader(this.results);

  final List<Future<PlaybackCacheTelemetryRead>> results;
  int calls = 0;

  @override
  Future<PlaybackCacheTelemetryRead> readDemuxerCacheState() {
    calls++;
    return results.removeAt(0);
  }
}

class _Access implements NativePlaybackPropertyAccess {
  _Access({
    this.native = const {},
    this.hasPropertyValue = true,
    this.throwOnNativeRead = false,
  });

  final Map<String, Object?> native;
  final bool hasPropertyValue;
  final bool throwOnNativeRead;

  @override
  Future<Object?> getNative(String name) async {
    if (throwOnNativeRead) throw StateError('native failure');
    return native[name];
  }

  @override
  Future<bool> hasOption(String name) async => false;

  @override
  Future<bool> hasProperty(String name) async => hasPropertyValue;

  @override
  Future<String?> getString(String name) async => null;

  @override
  Future<void> setString(String name, String value) async {}

  @override
  Future<void> command(List<String> command) async {}
}
