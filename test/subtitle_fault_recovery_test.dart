import 'dart:io';

import 'package:emby_my_client/playback/external_subtitle_loader.dart';
import 'package:emby_my_client/playback/source_http_input.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/synthetic_playback_origin.dart';

void main() {
  test(
    'repeated HTTP subtitle failures release budget and a later retry works',
    () async {
      final origin = await SyntheticPlaybackOrigin.start(
        await File('test/fixtures/subtitles/synthetic-pgs.mkv').readAsBytes(),
      );
      addTearDown(origin.close);
      final api = origin.createApi();
      addTearDown(api.dispose);
      final loader = ExternalSubtitleLoader(api);
      addTearDown(loader.dispose);
      origin.subtitleStatus = 503;
      for (var attempt = 0; attempt < 5; attempt++) {
        await expectLater(
          loader.load(
            '/Videos/generated/generated-source/Subtitles/5/Stream.srt',
            itemId: 'generated',
            sourceId: 'generated-source',
          ),
          throwsA(isA<SourceInputException>()),
        );
      }
      origin.subtitleStatus = 200;
      final lease = await loader.load(
        '/Videos/generated/generated-source/Subtitles/5/Stream.srt',
        itemId: 'generated',
        sourceId: 'generated-source',
      );
      expect(await lease.file.readAsString(), contains('EXTERNAL_CUE'));
      await loader.dispose();
      expect(await lease.file.exists(), isFalse);
    },
  );

  test(
    'cancelled delayed response cannot publish into a new loader session',
    () async {
      final origin = await SyntheticPlaybackOrigin.start(
        await File('test/fixtures/subtitles/synthetic-pgs.mkv').readAsBytes(),
      );
      addTearDown(origin.close);
      final api = origin.createApi();
      addTearDown(api.dispose);
      final first = ExternalSubtitleLoader(api);
      origin.holdSubtitle = true;
      final pending = first.load(
        '/Videos/generated/generated-source/Subtitles/5/Stream.srt',
        itemId: 'generated',
        sourceId: 'generated-source',
      );
      final failed = expectLater(pending, throwsA(isA<SourceInputException>()));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (origin.requests.isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Delayed request did not arrive');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await first.dispose();
      await failed;
      origin.holdSubtitle = false;
      origin.releaseSubtitle();
      final second = ExternalSubtitleLoader(api);
      addTearDown(second.dispose);
      final lease = await second.load(
        '/Videos/generated/generated-source/Subtitles/5/Stream.srt',
        itemId: 'generated',
        sourceId: 'generated-source',
      );
      expect(await lease.file.readAsString(), contains('EXTERNAL_CUE'));
      await second.dispose();
      expect(await lease.file.exists(), isFalse);
    },
  );
}
