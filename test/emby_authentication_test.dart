import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final password in [
    '',
    'fixture-password',
    '  fixture password  ',
    '   ',
  ]) {
    test(
      'authentication sends the exact password ${jsonEncode(password)}',
      () async {
        final server = await _AuthServer.start();
        addTearDown(server.close);
        final logs = <String>[];
        DiagnosticLog.instance.setTestSink(logs.add);
        addTearDown(() => DiagnosticLog.instance.setTestSink(null));

        final session = await _authenticate(server, password: password);

        expect(server.paths, [
          '/System/Info/Public',
          '/Users/AuthenticateByName',
        ]);
        expect(server.credentials, {
          'Username': 'fixture-user',
          'Pw': password,
        });
        expect(session.accessToken, 'fixture-access-token');
        expect(session.userId, 'fixture-user-id');
        expect(session.serverUrl, server.url);
        final log = logs.join('\n');
        for (final secret in [
          'fixture-user',
          'fixture-access-token',
          'fixture-password',
          'fixture password',
          '"Pw"',
        ]) {
          expect(log, isNot(contains(secret)));
        }
      },
    );
  }

  for (final status in [401, 403, 500]) {
    test('empty password does not bypass HTTP $status', () async {
      final server = await _AuthServer.start(status: status);
      addTearDown(server.close);

      await expectLater(
        _authenticate(server),
        throwsA(
          isA<EmbyApiException>().having(
            (e) => e.statusCode,
            'statusCode',
            status,
          ),
        ),
      );
      expect(server.credentials, {'Username': 'fixture-user', 'Pw': ''});
    });
  }

  for (final body in <Map<String, dynamic>>[
    {},
    {
      'User': {'Id': 'fixture-user-id'},
    },
    {
      'AccessToken': '',
      'User': {'Id': 'fixture-user-id'},
    },
    {'AccessToken': 'fixture-access-token'},
    {
      'AccessToken': 'fixture-access-token',
      'User': {'Id': ''},
    },
  ]) {
    test('empty password requires a valid server session: $body', () async {
      final server = await _AuthServer.start(body: body);
      addTearDown(server.close);
      await expectLater(
        _authenticate(server),
        throwsA(
          isA<EmbyApiException>().having(
            (e) => e.message,
            'message',
            '服务器没有返回有效的登录会话',
          ),
        ),
      );
    });
  }

  test(
    'connection loss during empty-password authentication remains a failure',
    () async {
      final server = await _AuthServer.start(disconnect: true);
      addTearDown(server.close);
      await expectLater(
        _authenticate(server),
        throwsA(
          isA<EmbyApiException>().having(
            (e) => e.message,
            'message',
            '无法连接 Emby 服务器，请检查地址和网络',
          ),
        ),
      );
      expect(server.credentials, {'Username': 'fixture-user', 'Pw': ''});
    },
  );
}

Future<EmbySession> _authenticate(_AuthServer server, {String password = ''}) {
  final realHttp = _RealHttpOverrides();
  return HttpOverrides.runZoned(
    () => EmbyApi.authenticate(
      serverUrl: server.url,
      username: 'fixture-user',
      password: password,
      deviceId: 'fixture-device',
    ),
    createHttpClient: realHttp.createHttpClient,
  );
}

class _RealHttpOverrides extends HttpOverrides {}

// Only binds loopback on an ephemeral port; no real account or server is used.
class _AuthServer {
  _AuthServer(this.server);

  final HttpServer server;
  final List<String> paths = [];
  Map<String, dynamic>? credentials;
  String get url => 'http://127.0.0.1:${server.port}';

  static Future<_AuthServer> start({
    int status = 200,
    Map<String, dynamic>? body,
    bool disconnect = false,
  }) async {
    final fixture = _AuthServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen((request) async {
      fixture.paths.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/System/Info/Public') {
        expect(request.method, 'GET');
        request.response.write(
          jsonEncode({'ServerName': 'Fixture Emby', 'Id': 'fixture-server'}),
        );
      } else if (request.uri.path == '/Users/AuthenticateByName') {
        expect(request.method, 'POST');
        fixture.credentials =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        if (disconnect) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
          return;
        }
        request.response.statusCode = status;
        request.response.write(
          jsonEncode(
            body ??
                {
                  'AccessToken': 'fixture-access-token',
                  'User': {'Id': 'fixture-user-id', 'Name': 'fixture-user'},
                },
          ),
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    return fixture;
  }

  Future<void> close() async {
    await server.close(force: true);
  }
}
