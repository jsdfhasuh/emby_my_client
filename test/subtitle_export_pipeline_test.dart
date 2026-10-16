import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/core/full_diagnostic_export.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_diagnostics.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/track_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'codec enums survive the complete Android export and credentials stay hidden',
    () async {
      final lines = <String>[];
      DiagnosticLog.instance.setTestSink(lines.add);
      addTearDown(() => DiagnosticLog.instance.setTestSink(null));
      const mapper = TrackMapper();
      final plan = PlaybackPlan(
        uri: Uri.parse('file:///private-movie.mkv'),
        mediaSourceId: 'source',
        playSessionId: null,
        method: PlayMethod.directPlay,
        usesServerAuthentication: false,
        mediaStreams: const [],
        transcodingReasons: const [],
        availableMediaSources: const [],
      );
      final diagnostics = PlaybackDiagnostics();
      diagnostics.subtitleMappingFailed(
        selectionSource: 'explicit',
        subtitleKind: 'embedded',
        streamIndex: 2,
        generation: 1,
        result: mapper.match(
          const PlaybackTrack(
            index: 2,
            type: 'Subtitle',
            codec: 'secret-codec-value',
          ),
          const [
            EngineTrack(id: 'private-id', codec: 'ass', title: 'private-title'),
          ],
        ),
        source: mapper.sourceEvidence(plan, 2),
      );
      DiagnosticLog.instance.warning(
        'fixture',
        'password=fixture-secret https://example.invalid/x?custom_secret=query-secret',
      );
      diagnostics.subtitleDeliveryResolved(
        const PlaybackTrack(
          index: 2,
          type: 'Subtitle',
          deliveryMethod: 'secret-delivery',
          format: 'secret-format',
          deliveryUrl: 'https://private-subtitle.invalid/path?token=url-secret',
        ),
        SubtitleDelivery.unsupported,
      );
      final report = await FullDiagnosticExportService(
        readLog: () async => lines.join('\n'),
        appVersion: '1.0.186',
        buildNumber: '1862000',
        platform: 'Android',
      ).buildReport();
      FullDiagnosticExportService.validateSnapshot(report.content);
      expect(report.content, contains('serverCodec=other'));
      expect(report.content, contains('track0Codec=ass,other,ass,strict'));
      expect(
        report.content,
        contains(
          'event=playback_subtitle_delivery delivery=unsupported '
          'streamIndex=2 format=other urlPresent=true',
        ),
      );
      for (final secret in [
        'secret-codec-value',
        'private-title',
        'private-id',
        'private-movie',
        'fixture-secret',
        'query-secret',
        'secret-delivery',
        'secret-format',
        'private-subtitle',
        'url-secret',
      ]) {
        expect(report.content, isNot(contains(secret)));
      }
    },
  );
}
