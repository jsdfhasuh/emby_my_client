import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:emby_my_client/playback/subtitle_problem.dart';
import 'package:emby_my_client/playback/source_input_failure.dart';

void main() {
  test('unknown errors never invent corruption or disclose native text', () {
    for (final error in [
      StateError('token=private'),
      const SourceInputException('unrecognized'),
    ]) {
      final result = SubtitleProblem.classify(error);
      expect(result.kind, SubtitleProblemKind.unknown);
      expect(result.message, isNot(contains('private')));
      expect(result.message, isNot(contains('损坏')));
    }
  });
  test('positive network, missing, decoder and file evidence are distinct', () {
    expect(
      SubtitleProblem.classify(const SocketException('private')).kind,
      SubtitleProblemKind.network,
    );
    expect(
      SubtitleProblem.classify(TimeoutException('private')).kind,
      SubtitleProblemKind.network,
    );
    expect(
      SubtitleProblem.classify(
        const SourceInputException('subtitle_missing'),
      ).kind,
      SubtitleProblemKind.notDownloaded,
    );
    expect(
      SubtitleProblem.classify(
        const SourceInputException('subtitle_decoder_unsupported'),
      ).kind,
      SubtitleProblemKind.unsupported,
    );
    expect(
      SubtitleProblem.classify(
        const SourceInputException('subtitle_format'),
      ).kind,
      SubtitleProblemKind.unreadable,
    );
  });
  test('native decoder evidence must name the active subtitle codec', () {
    expect(
      SubtitleProblem.fromNative(
        "Could not find a matching decoder for codec hdmv_pgs_subtitle",
        'hdmv_pgs_subtitle',
      )?.kind,
      SubtitleProblemKind.unsupported,
    );
    expect(
      SubtitleProblem.fromNative('No decoder found for h264', 'ass'),
      isNull,
    );
    expect(
      SubtitleProblem.fromNative(
        'No decoder found for ass',
        'hdmv_pgs_subtitle',
      ),
      isNull,
    );
    expect(SubtitleProblem.fromNative('No decoder found', 'ass'), isNull);
    expect(
      SubtitleProblem.fromNative('No decoder found for ass', null),
      isNull,
    );
  });
}
