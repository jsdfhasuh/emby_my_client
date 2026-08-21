import 'dart:typed_data';

import 'package:emby_my_client/playback/preview/media_kit_frame_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('probe diagnostics do not expose media bytes or identity', () {
    final result = MediaKitFrameProbeResult(
      success: true,
      reason: 'ready',
      stage: 'screenshot',
      format: 'image/jpeg',
      openLatency: const Duration(milliseconds: 120),
      screenshotLatency: const Duration(milliseconds: 80),
      imageBytes: Uint8List.fromList(<int>[1, 2, 3]),
    );

    expect(result.toSafeMap(), <String, Object?>{
      'success': true,
      'reason': 'ready',
      'stage': 'screenshot',
      'format': 'image/jpeg',
      'errorType': null,
      'openLatencyMs': 120,
      'screenshotLatencyMs': 80,
      'byteLength': 3,
    });
    expect(result.toString(), isNot(contains('1, 2, 3')));
    expect(result.toString(), isNot(contains('http')));
    expect(result.toString(), isNot(contains('Authorization')));
  });
}
