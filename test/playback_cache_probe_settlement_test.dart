import 'dart:async';
import 'dart:io';

import 'package:emby_my_client/playback/cache/native_playback_property_access.dart';
import 'package:emby_my_client/playback/cache/playback_cache_capabilities.dart';
import 'package:emby_my_client/playback/cache/playback_cache_engine.dart';
import 'package:emby_my_client/playback/cache/playback_cache_option_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'successful probe observes its loaded path before stop and deletion',
    () async {
      final access = _PendingProbeAccess('delayedPath');
      final result = await const RuntimePlaybackCacheProfileSwitchExperiment()
          .run(access: access, bindings: _bindings());
      expect(result, PlaybackCacheProfileSwitchStrategy.inPlaceAfterMediaStop);
      expect(access.loads, 3);
      expect(access.stops, 3);
      expect(access.loadedPathReads, greaterThan(3));
      expect(access.fileExistedAtStop, isTrue);
      expect(access.inputPending, isFalse);
      expect(await File(access.media!).exists(), isFalse);
      expect(access.pauseWrites, 0);
    },
  );

  for (final condition in ['playing', 'nonempty', 'busy']) {
    test(
      'unsafe initial $condition state never loads or changes pause',
      () async {
        final access = _PendingProbeAccess(condition);
        final result = await const RuntimePlaybackCacheProfileSwitchExperiment()
            .run(access: access, bindings: _bindings());
        expect(result, PlaybackCacheProfileSwitchStrategy.unsupported);
        expect(access.loads, 0);
        expect(access.stops, 0);
        expect(access.pauseWrites, 0);
      },
    );
  }

  for (final failure in [
    'stopThrow',
    'stopTimeout',
    'stopRead',
    'stopBusy',
    'stopQueued',
  ]) {
    test('$failure retains probe input until native owner disposal', () async {
      final access = _PendingProbeAccess(failure);
      final retained = <Future<void> Function()>[];
      await expectLater(
        RuntimePlaybackCacheProfileSwitchExperiment(
          settlementTimeout: const Duration(milliseconds: 40),
          retainUntilNativeDisposal: retained.add,
        ).run(access: access, bindings: _bindings()),
        throwsA(isA<PlaybackCacheProbeUnsettled>()),
      );
      expect(access.stops, 1);
      expect(access.fileExistedAtStop, isTrue);
      expect(access.inputPending, isTrue);
      expect(await File(access.media!).exists(), isTrue);
      expect(retained, hasLength(1));
      // Model the owner's real disposal completing before invoking releases.
      access.inputPending = false;
      await retained.single();
      expect(await File(access.media!).exists(), isFalse);
    });
  }
  for (final failure in ['idleRead', 'loadCommand', 'loadNeverReady']) {
    test(
      'probe $failure failure stops accepted input before deleting it',
      () async {
        final access = _PendingProbeAccess(failure);
        final result = await const RuntimePlaybackCacheProfileSwitchExperiment(
          settlementTimeout: Duration(milliseconds: 60),
        ).run(access: access, bindings: _bindings());
        expect(result, PlaybackCacheProfileSwitchStrategy.unsupported);
        expect(
          access.inputPending,
          isFalse,
          reason: 'unsupported must not leave an accepted load alive',
        );
        expect(access.stops, greaterThanOrEqualTo(1));
        expect(access.fileExistedAtStop, isTrue);
        expect(await File(access.media!).exists(), isFalse);
      },
    );
  }
}

ResolvedPlaybackCacheOptionBindings _bindings() =>
    ResolvedPlaybackCacheOptionBindings(
      nativeNames: {
        for (final option in playbackCacheLogicalOptions)
          option: playbackCacheNativeOptionCandidates[option]!.first,
      },
      resetValues: {
        for (final option in playbackCacheLogicalOptions) option: '',
      },
      supported: playbackCacheLogicalOptions.toSet(),
      optionalTuningUnavailable: const {},
      evidence: const {},
    );

class _PendingProbeAccess implements NativePlaybackPropertyAccess {
  _PendingProbeAccess(this.failure);
  final String failure;
  final values = <String, String>{'pause': 'yes'};
  String? media;
  bool inputPending = false;
  bool fileExistedAtStop = false;
  bool failedRead = false;
  int stops = 0;
  int loads = 0;
  int loadedPathReads = 0;
  int pauseWrites = 0;
  bool delayedPathRead = false;

  @override
  Future<void> command(List<String> command) async {
    if (command.first == 'loadfile') {
      loads++;
      delayedPathRead = false;
      media = command[1];
      inputPending = true;
      if (failure == 'loadCommand') {
        throw StateError('command failed after acceptance');
      }
    } else if (command.first == 'stop') {
      stops++;
      fileExistedAtStop = await File(media!).exists();
      if (failure == 'stopThrow') throw StateError('stop failed');
      if (failure == 'stopTimeout') throw TimeoutException('stop timed out');
      if (failure != 'stopRead' &&
          failure != 'stopBusy' &&
          failure != 'stopQueued') {
        inputPending = false;
      }
    }
  }

  @override
  Future<String?> getString(String name) async {
    if (name == 'pause' && failure == 'playing') return 'no';
    if (name == 'idle-active') {
      if (failure == 'busy') return 'no';
      if (failure == 'stopQueued' && stops > 0) return 'yes';
      if (failure == 'loadNeverReady') return 'yes';
      if (failure == 'stopRead' && stops > 0) {
        throw StateError('stop read failed');
      }
      if (failure == 'idleRead' && inputPending && !failedRead) {
        failedRead = true;
        throw StateError('property read failed after acceptance');
      }
      return inputPending ? 'no' : 'yes';
    }
    if (name == 'playlist-count') {
      return inputPending || failure == 'nonempty' ? '1' : '0';
    }
    if (name == 'path') {
      loadedPathReads++;
      if (failure == 'delayedPath' && !delayedPathRead) {
        delayedPathRead = true;
        return null;
      }
      return inputPending ? media : null;
    }
    if (name == 'duration') return inputPending ? '0.000125' : null;
    return values[name];
  }

  @override
  Future<void> setString(String name, String value) async {
    if (name == 'pause') pauseWrites++;
    values[name] = value;
  }

  @override
  Future<Object?> getNative(String name) => getString(name);
  @override
  Future<bool> hasOption(String name) async => true;
  @override
  Future<bool> hasProperty(String name) async => true;
}
