import 'package:emby_my_client/ui/player_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('brightness read failure disables only brightness controls', () async {
    final controls = _FakePlayerSystemControls()..failBrightnessReads = true;
    final failures = <bool>[];
    final safe = SafePlayerSystemControls(
      controls,
      onFailure: ({required brightness, required error}) =>
          failures.add(brightness),
    );

    expect(await safe.readBrightness(), isNull);
    await safe.setBrightness(0.5);
    await safe.setVolume(0.5);

    expect(safe.brightnessAvailable, isFalse);
    expect(safe.volumeAvailable, isTrue);
    expect(controls.brightnessSetCalls, 0);
    expect(controls.volumeSetCalls, 1);
    expect(failures, [true]);
  });

  test('brightness set failure is safe and reported once', () async {
    final controls = _FakePlayerSystemControls()..failBrightnessSets = true;
    final failures = <bool>[];
    final safe = SafePlayerSystemControls(
      controls,
      onFailure: ({required brightness, required error}) =>
          failures.add(brightness),
    );

    await safe.setBrightness(0.4);
    await safe.setBrightness(0.6);
    await safe.resetBrightness();

    expect(safe.brightnessAvailable, isFalse);
    expect(controls.brightnessSetCalls, 1);
    expect(controls.brightnessResetCalls, 0);
    expect(failures, [true]);
  });

  test('brightness reset still runs once after a later set failure', () async {
    final controls = _FakePlayerSystemControls();
    final failures = <bool>[];
    final safe = SafePlayerSystemControls(
      controls,
      onFailure: ({required brightness, required error}) =>
          failures.add(brightness),
    );

    await safe.setBrightness(0.4);
    controls.failBrightnessSets = true;
    await safe.setBrightness(0.6);
    await safe.setVolume(0.5);
    await safe.resetBrightness();
    await safe.resetBrightness();

    expect(safe.brightnessAvailable, isFalse);
    expect(safe.brightnessModified, isFalse);
    expect(controls.brightnessSetCalls, 2);
    expect(controls.brightnessResetCalls, 1);
    expect(controls.volumeSetCalls, 1);
    expect(safe.volumeAvailable, isTrue);
    expect(failures, [true]);
  });

  test(
    'brightness reset failure is contained and clears modified state',
    () async {
      final controls = _FakePlayerSystemControls();
      final safe = SafePlayerSystemControls(controls);

      await safe.setBrightness(0.4);
      controls.failBrightnessSets = true;
      await safe.setBrightness(0.6);
      controls.failBrightnessResets = true;
      await safe.resetBrightness();
      await safe.resetBrightness();

      expect(safe.brightnessAvailable, isFalse);
      expect(safe.brightnessModified, isFalse);
      expect(controls.brightnessResetCalls, 1);
    },
  );

  test('volume set failure does not disable brightness', () async {
    final controls = _FakePlayerSystemControls()..failVolumeSets = true;
    final failures = <bool>[];
    final safe = SafePlayerSystemControls(
      controls,
      onFailure: ({required brightness, required error}) =>
          failures.add(brightness),
    );

    await safe.setVolume(0.4);
    await safe.setVolume(0.6);
    await safe.setBrightness(0.7);

    expect(safe.volumeAvailable, isFalse);
    expect(safe.brightnessAvailable, isTrue);
    expect(controls.volumeSetCalls, 1);
    expect(controls.brightnessSetCalls, 1);
    expect(failures, [false]);
  });
}

class _FakePlayerSystemControls implements PlayerSystemControls {
  bool failBrightnessReads = false;
  bool failBrightnessSets = false;
  bool failBrightnessResets = false;
  bool failVolumeSets = false;
  int brightnessSetCalls = 0;
  int brightnessResetCalls = 0;
  int volumeSetCalls = 0;

  @override
  Future<double> readBrightness() async {
    if (failBrightnessReads) throw StateError('brightness read failed');
    return 0.5;
  }

  @override
  Future<void> setBrightness(double value) async {
    brightnessSetCalls++;
    if (failBrightnessSets) throw StateError('brightness set failed');
  }

  @override
  Future<void> resetBrightness() async {
    brightnessResetCalls++;
    if (failBrightnessResets) throw StateError('brightness reset failed');
  }

  @override
  Future<double> readVolume() async => 0.5;

  @override
  Future<void> setVolume(double value) async {
    volumeSetCalls++;
    if (failVolumeSets) throw StateError('volume set failed');
  }
}
