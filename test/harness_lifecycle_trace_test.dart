import 'package:flutter_test/flutter_test.dart';
import 'support/harness_lifecycle_trace.dart';

void main() {
  test('cache safety exports only fixed subtitle state and bounded counters', () {
    expect(
      safeHarnessLifecycleEvent(
        'event=playback_cache_memory_pressure reason=memoryPressure '
        'subtitleStatus=applying subtitleSource=native subtitleRevision=4 inputEpoch=1 '
        'nativeId=secret url=https://private.invalid/token',
      ),
      {
        'event': 'playback_cache_memory_pressure',
        'reason': 'memoryPressure',
        'subtitleStatus': 'applying',
        'subtitleSource': 'native',
        'subtitleRevision': 4,
        'inputEpoch': 1,
      },
    );
    expect(
      safeHarnessLifecycleEvent(
        'event=playback_cache_memory_pressure reason=memoryPressure '
        'subtitleStatus=https://private.invalid subtitleSource=secret '
        'subtitleRevision=12345678901 inputEpoch=-1',
      ),
      {'event': 'playback_cache_memory_pressure', 'reason': 'memoryPressure'},
    );
  });
  test('fixed lifecycle and recovery fields exclude arbitrary diagnostics', () {
    expect(
      safeHarnessLifecycleEvent(
        'prefix event=playback_seek_recovery_started trace=secret '
        'fingerprint=partial_file url=https://private.invalid/token',
      ),
      {
        'event': 'playback_seek_recovery_started',
        'fingerprint': 'partial_file',
      },
    );
    expect(
      safeHarnessLifecycleEvent(
        'event=app_lifecycle_changed lifecycleState=paused',
      ),
      {'event': 'app_lifecycle_changed', 'lifecycleState': 'paused'},
    );
    expect(
      safeHarnessLifecycleEvent('event=playback_ready method=DirectPlay'),
      {'event': 'playback_ready', 'method': 'DirectPlay'},
    );
    expect(
      safeHarnessLifecycleEvent(
        'event=playback_cache_memory_pressure reason=memoryPressure',
      ),
      {'event': 'playback_cache_memory_pressure', 'reason': 'memoryPressure'},
    );
  });
  test('unapproved events and field values are never exported', () {
    expect(safeHarnessLifecycleEvent('event=private value=secret'), isNull);
    expect(
      safeHarnessLifecycleEvent(
        'event=app_lifecycle_changed lifecycleState=https://private.invalid',
      ),
      isNull,
    );
    expect(
      safeHarnessLifecycleEvent('event=playback_ready method=/private/file'),
      isNull,
    );
    expect(
      safeHarnessLifecycleEvent(
        'event=playback_seek_recovery_failed fingerprint=secret',
      ),
      {'event': 'playback_seek_recovery_failed'},
    );
  });
}
