import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test(
    'P0 locked Media normalizes percent escapes: raw URL adapter is required',
    () {
      const raw =
          'https://source.invalid/a%2fb.mp4?sig=%7e&x=1&x=2&q=a+b&q=a%20b';
      final media = Media(raw, httpHeaders: const {});
      // This records a blocker in the pinned dependency, NOT source-direct success.
      expect(media.uri, isNot(raw));
      expect(media.uri, contains('x=1&x=2'));
    },
  );

  test('P0 explicit empty Media headers replace the URL cache entry', () {
    const raw = 'https://source.invalid/fixture';
    final first = Media(raw, httpHeaders: const {'X-Fixture': 'synthetic'});
    final empty = Media(raw, httpHeaders: const {});
    expect(first.httpHeaders, isNotEmpty);
    expect(empty.httpHeaders, isEmpty);
    expect(Media(raw).httpHeaders, isEmpty);
    // Native cookie/property cleanup is a separate NOT_RUN capability.
  });
}
