// Run with flutter test scripts/diagnostics/probe_strm_read_ahead.dart.
// Set STRM_PROBE_URL, STRM_PROBE_OFFSET and STRM_PROBE_LENGTH explicitly.
// Reads at most 32 MiB plus the 256 KiB prefix; never downloads the whole movie.
import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/playback/playback_resource_request.dart';
import 'package:emby_my_client/playback/source_http_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final url = Platform.environment['STRM_PROBE_URL'];
  test(
    'read an explicitly selected source range through the production cache',
    () async {
      final offset = int.parse(Platform.environment['STRM_PROBE_OFFSET']!);
      final length = int.parse(Platform.environment['STRM_PROBE_LENGTH']!);
      expect(offset, greaterThanOrEqualTo(0));
      expect(length, inInclusiveRange(1, 32 * 1024 * 1024));
      final emby = Uri.parse('https://emby.invalid');
      final input = SourceHttpInput(
        PlaybackResourceRequest(
          rawUrl: url!,
          headers: const {},
          embyServer: emby,
          identity: PlaybackResourceIdentity(
            scope: const ServerScope(serverId: 'probe', userId: 'probe'),
            apiSession: Object(),
            itemId: 'probe',
            sourceId: 'probe',
            itemSession: Object(),
            generation: 1,
          ),
        ),
        embyServer: emby,
      );
      addTearDown(input.close);
      await input.prepare();
      expect(offset + length, lessThanOrEqualTo(input.size));
      final initialRequests = input.httpRequests;
      final clock = Stopwatch()..start();
      var delivered = 0;
      while (delivered < length) {
        final bytes = await input.read(
          offset + delivered,
          (length - delivered).clamp(1, 65536),
        );
        expect(bytes, isNotEmpty);
        delivered += bytes.length;
      }
      clock.stop();
      // Only counters are printed, never source URLs or headers.
      // ignore: avoid_print
      print(
        jsonEncode({
          'deliveredBytes': delivered,
          'elapsedMs': clock.elapsedMilliseconds,
          'httpRequests': input.httpRequests - initialRequests,
          'readAheadHits': input.readAheadHits,
          'cachedBytes': input.cachedBytes,
        }),
      );
    },
    skip: url == null
        ? 'Set STRM_PROBE_URL to run this opt-in network probe'
        : false,
  );
}
