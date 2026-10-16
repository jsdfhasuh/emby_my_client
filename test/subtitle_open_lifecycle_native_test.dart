import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/native_failure_evidence.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  for (final window in ['before', 'overlap', 'after']) {
    test('host native local open lifecycle $window', () async {
      MediaKit.ensureInitialized();
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final engine = MediaKitPlaybackEngine(player);
      final native = player.platform as NativePlayer;
      final failures = <String>[];
      final evidence = NativeFailureEvidence();
      var step = NativeStartupStep.engineOpen;
      final logs = player.stream.log.listen((log) {
        if (log.level == 'error' || log.level == 'fatal') {
          final record = evidence.record(
            message: log.toString(),
            fromLog: true,
            generation: 0,
            inputEpoch: 0,
            phase: PlaybackPhase.opening,
            step: step,
            lifecycleSuspended: false,
          );
          failures.add(record ?? 'additional_native_error');
        }
      });
      try {
        // No audio device is claimed by this desktop input/lifecycle experiment.
        await native.setProperty('aid', 'no');
        await native.setProperty('vid', 'auto');
        // The host mkv demuxer marks this generated MJPEG track as a still
        // image. Use lavf only for this Linux fixture so its video clock runs.
        if (Platform.isLinux) {
          await native.setProperty('demuxer', 'lavf');
          expect(await native.getProperty('demuxer'), 'lavf');
        }
        // Match the production offline disabled profile, not media_kit's
        // default disk cache (the initial experiment preserved that failure).
        await native.setProperty('cache', 'no');
        await native.setProperty('cache-on-disk', 'no');
        expect(await native.getProperty('cache'), 'no');
        expect(await native.getProperty('cache-on-disk'), 'no');
        if (window == 'before') {
          await engine.quiesceForLifecycle();
        }
        final opening = engine.open(
          File('test/fixtures/subtitles/synthetic-pgs.mkv').absolute.uri,
          headers: const {},
          play: true,
        );
        if (window == 'overlap') {
          await engine.quiesceForLifecycle();
        }
        await opening;
        step = NativeStartupStep.waitingReady;
        await _until(
          () => player.state.duration.inSeconds == 12,
          stage: '$window-duration',
          player: player,
          native: native,
          failures: failures,
        );
        final nativeTracks =
            jsonDecode(await native.getProperty('track-list')) as List<dynamic>;
        final video = nativeTracks.cast<Map<String, dynamic>>().singleWhere(
          (track) => track['type'] == 'video',
        );
        expect(video['image'], isNot(true));
        if (window == 'after') {
          await engine.quiesceForLifecycle();
        }
        step = NativeStartupStep.presentation;
        await _until(
          () => !player.state.playing,
          stage: '$window-paused',
          player: player,
          native: native,
          failures: failures,
        );
        expect(await native.getProperty('pause'), 'yes');
        await engine.resumeFromLifecycleQuiescence();
        expect(await native.getProperty('pause'), 'yes');
        await engine.play();
        step = NativeStartupStep.playbackIntent;
        await _until(
          () => player.state.position.inMilliseconds >= 500,
          stage: '$window-position',
          player: player,
          native: native,
          failures: failures,
        );
        await engine.pause();
        expect(await native.getProperty('pause'), 'yes');
        expect(player.state.duration.inSeconds, 12);
        expect(
          player.state.tracks.subtitle.where((t) => t.codec != null).length,
          3,
        );
      } finally {
        await engine.dispose();
        await logs.cancel();
      }
      expect(
        failures,
        isEmpty,
        reason: 'Fixed one-pass host experiment; no retry',
      );
    });
  }
}

Future<void> _until(
  bool Function() predicate, {
  required String stage,
  required Player player,
  required NativePlayer native,
  required List<String> failures,
}) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  final reachedAtDeadline = predicate();
  if (reachedAtDeadline) {
    return;
  }
  final state = <String, Object?>{
    'snapshotTiming': 'after_failed_deadline',
    'stage': stage,
    'dartPlaying': player.state.playing,
    'dartCompleted': player.state.completed,
    'dartPositionMs': player.state.position.inMilliseconds,
    'dartDurationMs': player.state.duration.inMilliseconds,
    'nativeErrors': failures,
  };
  for (final key in [
    'pause',
    'idle-active',
    'eof-reached',
    'duration',
    'time-pos',
  ]) {
    try {
      final value = await native
          .getProperty(key)
          .timeout(const Duration(seconds: 1));
      final number = double.tryParse(value);
      state[key] = value == 'yes' || value == 'no'
          ? value
          : number != null && number.isFinite && number.abs() <= 1000000
          ? number
          : 'unavailable';
    } catch (_) {
      state[key] = 'read_failed';
    }
  }
  expect(reachedAtDeadline, isTrue, reason: jsonEncode(state));
}
