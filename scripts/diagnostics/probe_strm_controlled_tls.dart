import 'package:flutter_test/flutter_test.dart';
import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/core/full_diagnostic_export.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/playback/playback_resource_request.dart';
import 'package:emby_my_client/playback/source_http_input.dart';
import '../../test/support/progressive_fixture.dart';

void main() {
  test('controlled TLS policy and diagnostic export', () async {
    final output = Platform.environment['STRM_DIAGNOSTIC_EVIDENCE'];
    final directory = output == null
        ? await Directory.systemTemp.createTemp('strm-tls-evidence-')
        : await Directory(output).create(recursive: true);
    final file = File('${directory.path}/tls-local.log');
    // This script is a flutter test entry point, outside the test/ directory.
    // ignore: invalid_use_of_visible_for_testing_member
    await DiagnosticLog.instance.initializeFileForTesting(file);
    await runControlledTlsProbe(['${directory.path}/tls-probe.json']);
    final report = await FullDiagnosticExportService(
      appVersion: '1.0.0',
      buildNumber: '156',
    ).buildReport();
    expect(
      report.content,
      contains('stage=tls reason=tls_certificate http=unavailable'),
    );
    expect(report.content, contains('reason=tls_downgrade'));
    await File(
      '${directory.path}/tls-export.txt',
    ).writeAsString(report.content);
    if (output == null) await directory.delete(recursive: true);
  });
}

Future<void> runControlledTlsProbe(List<String> args) async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  final host = interfaces
      .expand((i) => i.addresses)
      .firstWhere((a) => !a.isLoopback)
      .address;
  final temp = await Directory.systemTemp.createTemp('strm-tls-');
  final cert = '${temp.path}/certificate.pem', key = '${temp.path}/key.pem';
  try {
    final result = await Process.run(
      Platform.isWindows
          ? r'C:\Program Files\Git\usr\bin\openssl.exe'
          : 'openssl',
      [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        key,
        '-out',
        cert,
        '-days',
        '1',
        '-subj',
        '/CN=synthetic-strm-fixture',
        '-addext',
        'subjectAltName=IP:$host',
      ],
    );
    if (result.exitCode != 0) {
      throw StateError('fixture certificate generation failed');
    }
    final context = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    final server = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      0,
      context,
    );
    final plain = await ProgressiveOrigin.start();
    final video = progressiveVideo();
    var requests = 0, downgrade = false;

    server.listen((request) async {
      requests++;
      if (downgrade) {
        request.response.statusCode = 302;
        request.response.headers.set('Location', '${plain.origin}/video');
      } else {
        final range = RegExp(
          r'bytes=(\d+)-(\d+)',
        ).firstMatch(request.headers.value('Range')!)!;
        final first = int.parse(range[1]!);
        final last = min(int.parse(range[2]!), video.length - 1);
        request.response.statusCode = 206;
        request.response.headers.set(
          'Content-Range',
          'bytes $first-$last/${video.length}',
        );
        request.response.contentLength = last - first + 1;
        request.response.add(video.sublist(first, last + 1));
      }
      await request.response.close();
    });
    SourceHttpInput input() => SourceHttpInput(
      PlaybackResourceRequest(
        rawUrl: 'https://$host:${server.port}/a%2fb?sig=%7e&x=1&x=2',
        headers: {},
        identity: PlaybackResourceIdentity(
          scope: const ServerScope(serverId: 's', userId: 'u'),
          apiSession: Object(),
          itemId: 'item',
          sourceId: 'source',
          itemSession: Object(),
          generation: 1,
        ),
        embyServer: Uri.parse('https://emby.invalid'),
      ),
      embyServer: Uri.parse('https://emby.invalid'),
    );
    try {
      final untrusted = input();
      var rejected = false;
      try {
        await untrusted.prepare();
      } on SourceInputException {
        rejected = true;
      } finally {
        untrusted.close();
      }
      if (!rejected || requests != 0) {
        throw StateError('untrusted certificate gate failed');
      }
      SecurityContext.defaultContext.setTrustedCertificates(cert);
      final trusted = input();
      await trusted.prepare();
      final data = await trusted.read(400000, 4096);
      trusted.close();
      if (trusted.format != 'avi' || data.length != 4096 || requests != 2) {
        throw StateError('TLS range failed');
      }
      for (var i = 0; i < data.length; i++) {
        if (data[i] != video[400000 + i]) {
          throw StateError('TLS payload mismatch');
        }
      }
      downgrade = true;
      final downgradeInput = input();
      var refused = false;
      try {
        await downgradeInput.prepare();
      } on SourceInputException catch (e) {
        refused = e.code == 'tls_downgrade';
      } finally {
        downgradeInput.close();
      }
      if (!refused || plain.requests.isNotEmpty) {
        throw StateError('TLS downgrade gate failed');
      }
      final evidence = {
        'schema': 'emby-strm-tls-probe/v1',
        'untrustedCertificate': 'tested-rejected-before-http',
        'validatedIpTlsHostnameCertificate': 'tested',
        'httpsRangePayload': 'tested',
        'downgradeBeforeRequest': 'tested',
        'syntheticTlsRequests': requests,
        'realOpenList': 'NOT_RUN',
        'physicalDevice': 'NOT_RUN',
      };
      await File(
        args.single,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
      stdout.writeln(jsonEncode(evidence));
    } finally {
      await server.close(force: true);
      await plain.close();
    }
  } finally {
    for (final path in [cert, key]) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    await temp.delete();
  }
}
