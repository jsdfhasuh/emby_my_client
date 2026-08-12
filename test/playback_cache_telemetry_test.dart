import 'dart:async';

import 'package:emby_my_client/playback/cache/native_playback_property_access.dart';
import 'package:emby_my_client/playback/cache/playback_cache_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
