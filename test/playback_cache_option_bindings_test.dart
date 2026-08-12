import 'package:emby_my_client/playback/cache/playback_cache_option_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('logical candidates prefer the first complete modern option', () {
    final bindings = resolvePlaybackCacheOptionBindings(
      optionSupport: {
        'demuxer-cache-dir': true,
        'cache-dir': true,
        'demuxer-cache-unlink-files': true,
        'cache-unlink-files': true,
      },
      resetValues: {
        'demuxer-cache-dir': '',
        'cache-dir': '',
        'demuxer-cache-unlink-files': 'no',
        'cache-unlink-files': 'no',
      },
      requiredChoiceAvailable: {
        'demuxer-cache-unlink-files': true,
        'cache-unlink-files': true,
      },
      writeReadBackPassed: {
        'demuxer-cache-dir': true,
        'cache-dir': true,
        'demuxer-cache-unlink-files': true,
        'cache-unlink-files': true,
      },
    );

    expect(
      bindings.nativeName(PlaybackCacheLogicalOption.cacheDirectory),
      'demuxer-cache-dir',
    );
    expect(
      bindings.nativeName(PlaybackCacheLogicalOption.cacheUnlinkFiles),
      'demuxer-cache-unlink-files',
    );
    expect(
      bindings.variantFor(PlaybackCacheLogicalOption.cacheDirectory),
      PlaybackNativeOptionVariant.modern,
    );
  });

  test('incomplete modern candidate falls through to usable legacy', () {
    final bindings = resolvePlaybackCacheOptionBindings(
      optionSupport: {'demuxer-cache-dir': true, 'cache-dir': true},
      resetValues: {'cache-dir': ''},
      writeReadBackPassed: {'cache-dir': true},
    );

    expect(
      bindings.nativeName(PlaybackCacheLogicalOption.cacheDirectory),
      'cache-dir',
    );
    expect(
      bindings.statusFor(PlaybackCacheLogicalOption.cacheDirectory, 0),
      PlaybackNativeOptionCandidateStatus.presentButIncomplete,
    );
    expect(
      bindings.statusFor(PlaybackCacheLogicalOption.cacheDirectory, 1),
      PlaybackNativeOptionCandidateStatus.usable,
    );
  });

  test('both aliases incomplete are explicitly unavailable', () {
    final bindings = resolvePlaybackCacheOptionBindings(
      optionSupport: {'demuxer-cache-dir': true, 'cache-dir': true},
      resetValues: const {},
    );

    expect(
      bindings.nativeName(PlaybackCacheLogicalOption.cacheDirectory),
      isNull,
    );
    expect(
      bindings.variantFor(PlaybackCacheLogicalOption.cacheDirectory),
      PlaybackNativeOptionVariant.unavailable,
    );
  });

  test('canonicalizer accepts approved boolean and finite integer forms', () {
    const canonicalizer = PlaybackNativeValueCanonicalizer();

    for (final value in ['yes', 'true', '1']) {
      expect(
        canonicalizer.canonicalize(
          PlaybackCacheLogicalOption.cacheOnDisk,
          value,
        ),
        'true',
      );
    }
    for (final value in ['no', 'false', '0']) {
      expect(
        canonicalizer.canonicalize(
          PlaybackCacheLogicalOption.cacheOnDisk,
          value,
        ),
        'false',
      );
    }
    expect(
      canonicalizer.equivalent(
        PlaybackCacheLogicalOption.cacheSeconds,
        '3600000.0',
        '3600000',
      ),
      isTrue,
    );
    expect(
      canonicalizer.canonicalize(
        PlaybackCacheLogicalOption.cacheSeconds,
        'NaN',
      ),
      isNull,
    );
  });

  test('canonicalizer normalizes paths but rejects unknown enums', () {
    const canonicalizer = PlaybackNativeValueCanonicalizer();

    expect(
      canonicalizer.equivalent(
        PlaybackCacheLogicalOption.cacheDirectory,
        r'C:\cache\./session\\',
        'C:/cache/session',
      ),
      isTrue,
    );
    expect(
      canonicalizer.canonicalize(
        PlaybackCacheLogicalOption.cacheUnlinkFiles,
        'later',
      ),
      isNull,
    );
    expect(
      canonicalizer.canonicalize(
        PlaybackCacheLogicalOption.cacheDirectory,
        '\u0001bad',
      ),
      isNull,
    );
  });
}
