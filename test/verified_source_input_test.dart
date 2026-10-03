import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_resource_request.dart';
import 'package:flutter_test/flutter_test.dart';

import 'source_http_input_test.dart' show fixtureRequest;

void main() {
  final request = fixtureRequest('https://source.invalid/video.mp4');
  final plan = PlaybackPlan(
    uri: Uri.parse('embyinput://pending'),
    mediaSourceId: 'source',
    playSessionId: 'cycle',
    method: PlayMethod.directPlay,
    usesServerAuthentication: false,
    mediaStreams: const [],
    transcodingReasons: const [],
    availableMediaSources: const [],
    sourceRequest: request,
    duration: const Duration(hours: 1),
    sourceSizeBytes: 42,
  );

  test(
    'verified input refines size without changing source or reporting identity',
    () {
      final refined = plan.withVerifiedSourceInput(
        VerifiedSourceInput(request: request, sizeBytes: 1000000),
      );
      expect(refined.sourceSizeBytes, 1000000);
      expect(refined.transportKind, PlaybackTransportKind.progressiveHttp);
      expect(refined.sourceRequest, same(request));
      expect(refined.mediaStreams, same(plan.mediaStreams));
      expect(refined.uri, plan.uri);
      expect(refined.playSessionId, plan.playSessionId);
      expect(plan.transportKind, PlaybackTransportKind.unknown);
      expect(plan.sourceSizeBytes, 42);
      expect(() => plan.copyWith(sourceSizeBytes: 1000000), throwsStateError);
    },
  );

  test('evidence from a different request cannot promote this source', () {
    final other = fixtureRequest(request.rawUrl);
    expect(
      () => plan.withVerifiedSourceInput(
        VerifiedSourceInput(request: other, sizeBytes: 1000000),
      ),
      throwsStateError,
    );
  });

  for (final size in [0, -1]) {
    test('invalid verified length $size cannot promote this source', () {
      expect(
        () => plan.withVerifiedSourceInput(
          VerifiedSourceInput(request: request, sizeBytes: size),
        ),
        throwsStateError,
      );
    });
  }
}
