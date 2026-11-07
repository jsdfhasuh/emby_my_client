import 'package:emby_my_client/core/strm_diagnostics.dart';
import 'package:emby_my_client/playback/playback_controller.dart';
import 'package:emby_my_client/playback/source_input_failure.dart';
import 'package:flutter_test/flutter_test.dart';

SourceInputFailure wrapped(SourceInputException error) => SourceInputFailure(
  error: error,
  trace: StrmTrace(),
  openAttempt: 1,
  request: 1,
  stale: false,
);

void main() {
  for (final entry in <(String, int)>[
    ('source_server_error', 500),
    ('source_denied', 403),
    ('source_http_error', 404),
    ('range_unsupported', 206),
  ]) {
    test('direct and wrapped ${entry.$1} retain HTTP ${entry.$2}', () {
      final error = SourceInputException(
        entry.$1,
        stage: 'range_response',
        httpStatus: entry.$2,
      );
      final direct = PlaybackController.friendlyPlaybackError(error);
      expect(direct, contains('HTTP ${entry.$2}'));
      expect(PlaybackController.friendlyPlaybackError(wrapped(error)), direct);
      expect(
        PlaybackController.friendlyPlaybackError(
          error,
          fallbackMessage: '源站读取失败，请返回后重试',
        ),
        direct,
      );
    });
  }
  test('startup and runtime unknown failures keep contextual fallbacks', () {
    const error = SourceInputException('unknown');
    expect(PlaybackController.friendlyPlaybackError(error), '播放失败，请返回后重试');
    expect(
      PlaybackController.friendlyPlaybackError(
        error,
        fallbackMessage: '源站读取失败，请返回后重试',
      ),
      '源站读取失败，请返回后重试',
    );
    expect(
      PlaybackController.friendlyPlaybackError(StateError('fixture')),
      '播放失败，请返回后重试',
    );
  });
  test('direct and wrapped timeouts retain their specific message', () {
    const error = SourceInputException('timeout');
    for (final value in <Object>[error, wrapped(error)]) {
      expect(PlaybackController.friendlyPlaybackError(value), '媒体连接超时');
    }
    expect(
      PlaybackController.friendlyPlaybackError(
        StateError('resume seek did not settle'),
      ),
      '恢复播放位置超时，请重试',
    );
  });
}
