import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/downloads/download_connection.dart';
import 'package:emby_my_client/downloads/download_http_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'explicit close terminates an active reader without cancelling its task',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.add([1]);
        await request.response.flush();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/body');
      final client = DownloadHttpClient(server: uri, headers: {});
      addTearDown(client.close);
      final token = CancelToken();
      final response = await client.open(uri, cancelToken: token);
      final reader = response.stream.drain<void>();
      final observed = expectLater(
        reader.timeout(const Duration(seconds: 1)),
        throwsA(isNot(isA<TimeoutException>())),
      );
      await Future<void>.delayed(Duration.zero);
      await response.close();
      await observed;
      expect(token.isCancelled, isFalse);
    },
  );

  test(
    'HTTPS CONNECT keeps origin TLS and proxy credentials separate',
    () async {
      final certificate = await File(
        'test/fixtures/download_tls/localhost.pem',
      ).readAsBytes();
      final key = await File(
        'test/fixtures/download_tls/localhost.key',
      ).readAsBytes();
      final context = SecurityContext()
        ..useCertificateChainBytes(certificate)
        ..usePrivateKeyBytes(key);
      final origin = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await origin.close(force: true);
        await proxy.close(force: true);
      });
      var connects = 0;
      var challenges = 0;
      origin.listen((request) async {
        expect(request.headers.value('proxy-authorization'), isNull);
        expect(request.headers.value('X-Emby-Token'), 'fixture-token');
        if (request.uri.path == '/challenge') {
          challenges++;
          request.response.statusCode = 407;
          request.response.headers.set(
            'proxy-authenticate',
            'Basic realm="origin"',
          );
          await request.response.close();
          return;
        }
        request.response.add([1, 2, 3]);
        await request.response.close();
      }, onError: (Object _) {});
      proxy.listen((request) async {
        if (request.headers.value('proxy-authorization') == null) {
          request.response.statusCode = 407;
          request.response.headers.set(
            'proxy-authenticate',
            'Basic realm="download"',
          );
          await request.response.close();
          return;
        }
        expect(request.method, 'CONNECT');
        expect(
          request.headers.value('proxy-authorization'),
          'Basic ${base64Encode(utf8.encode('local:fixture-password'))}',
        );
        connects++;
        final remote = await Socket.connect(
          InternetAddress.loopbackIPv4,
          origin.port,
        );
        final local = await request.response.detachSocket(writeHeaders: false);
        sockets.addAll([remote, local]);
        local.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        unawaited(
          local.cast<List<int>>().pipe(remote).catchError((Object _) {}),
        );
        unawaited(
          remote.cast<List<int>>().pipe(local).catchError((Object _) {}),
        );
      });
      final uri = Uri.parse('https://localhost:${origin.port}/file');
      final trusted = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(certificate);
      final client = DownloadHttpClient(
        server: uri,
        headers: {'X-Emby-Token': 'fixture-token'},
        securityContext: trusted,
        proxy: DownloadProxy(
          host: '127.0.0.1',
          port: proxy.port,
          username: 'local',
          password: 'fixture-password',
        ),
      );
      addTearDown(client.close);
      final response = await client.open(uri, cancelToken: CancelToken());
      expect(await response.stream.expand((bytes) => bytes).toList(), [
        1,
        2,
        3,
      ]);
      await response.close();
      expect(connects, 1);
      await expectLater(
        client.open(
          uri.replace(path: '/challenge'),
          cancelToken: CancelToken(),
        ),
        throwsA(
          isA<DownloadHttpStatusException>().having(
            (error) => error.statusCode,
            '407',
            407,
          ),
        ),
      );
      expect(challenges, 1);
      final untrusted = DownloadHttpClient(
        server: uri,
        headers: {},
        proxy: DownloadProxy(
          host: '127.0.0.1',
          port: proxy.port,
          username: 'local',
          password: 'fixture-password',
        ),
      );
      addTearDown(untrusted.close);
      await expectLater(
        untrusted.open(uri, cancelToken: CancelToken()),
        throwsA(isA<HandshakeException>()),
      );
    },
  );

  test(
    'cross-origin redirect strips headers and preserves the new signed query',
    () async {
      final entry = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final logs = <String>[];
      DiagnosticLog.instance.setTestSink(logs.add);
      addTearDown(() => DiagnosticLog.instance.setTestSink(null));
      addTearDown(() => entry.close(force: true));
      addTearDown(() => target.close(force: true));
      HttpRequest? received;
      target.listen((request) async {
        received = request;
        request.response.add([1, 2, 3]);
        await request.response.close();
      });
      entry.listen((request) async {
        expect(request.headers.value('X-Emby-Token'), 'source-secret');
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://localhost:${target.port}/media?signature=target%2Fsecret&token=target-token',
        );
        await request.response.close();
      });
      final uri = Uri.parse(
        'http://127.0.0.1:${entry.port}/media?password=private-password',
      );
      final client = DownloadHttpClient(
        server: uri,
        headers: {
          'X-Emby-Token': 'source-secret',
          'X-Emby-Authorization': 'source-secret',
          'Authorization': 'Basic private-basic',
          'Cookie': 'private-cookie',
        },
      );
      addTearDown(client.close);
      final response = await client.open(uri, cancelToken: CancelToken());
      expect(await response.stream.expand((bytes) => bytes).toList(), [
        1,
        2,
        3,
      ]);
      await response.close();
      expect(received!.headers.value('X-Emby-Token'), isNull);
      expect(received!.headers.value('X-Emby-Authorization'), isNull);
      expect(received!.headers.value('Authorization'), isNull);
      expect(received!.headers.value('Cookie'), isNull);
      expect(
        received!.uri.query,
        'signature=target%2Fsecret&token=target-token',
      );
      for (final secret in [
        'source-secret',
        'target%2Fsecret',
        'target-token',
        'private-password',
        'private-basic',
        'private-cookie',
      ]) {
        expect(logs.join(), isNot(contains(secret)));
      }
      expect(logs.join(), contains('download_redirect'));
      expect(logs.join(), contains('firstByteMs'));
    },
  );

  test(
    'completed responses reuse a connection and close is idempotent',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final ports = <int>[];
      server.listen((request) async {
        ports.add(request.connectionInfo!.remotePort);
        request.response.contentLength = 3;
        request.response.add([1, 2, 3]);
        await request.response.close();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/media');
      final client = DownloadHttpClient(server: uri, headers: {});
      addTearDown(client.close);
      for (var count = 0; count < 2; count++) {
        final response = await client.open(uri, cancelToken: CancelToken());
        await response.stream.drain<void>();
        await response.close();
        await response.close();
      }
      expect(ports, hasLength(2));
      expect(ports.toSet(), hasLength(1));
    },
  );

  for (final discard in [false, true]) {
    test(
      '${discard ? 'discard' : 'task cancel'} really closes the old response',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <Socket>[];
        addTearDown(() async {
          for (final socket in sockets) {
            socket.destroy();
          }
          await server.close();
        });
        final stopped = Completer<void>();
        final sentFirst = Completer<void>();
        server.listen((socket) {
          sockets.add(socket);
          final headers = StringBuffer();
          var responding = false;
          void disconnected() {
            if (!stopped.isCompleted) stopped.complete();
          }

          socket.listen(
            (data) {
              headers.write(latin1.decode(data));
              if (!responding && headers.toString().contains('\r\n\r\n')) {
                responding = true;
                socket.write(
                  'HTTP/1.1 200 OK\r\nContent-Length: 16777216\r\n\r\n',
                );
                socket.add(List.filled(65536, 1));
                unawaited(
                  socket.flush().then((_) {
                    sentFirst.complete();
                  }),
                );
                // Leave the body unfinished. Only client cancellation can end it.
              }
            },
            onDone: disconnected,
            onError: (Object _) => disconnected(),
          );
        });
        final uri = Uri.parse('http://127.0.0.1:${server.port}/large');
        final client = DownloadHttpClient(server: uri, headers: {});
        addTearDown(client.close);
        final token = CancelToken();
        final response = await client.open(uri, cancelToken: token);
        await sentFirst.future;
        if (discard) {
          await response.discard();
        } else {
          token.cancel('test pause');
          await response.close();
        }
        await stopped.future.timeout(const Duration(seconds: 3));
      },
    );
  }

  test('a slow body is not subject to a whole-file timeout', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.bufferOutput = false;
      for (var i = 0; i < 8; i++) {
        request.response.add([i]);
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await request.response.close();
    });
    final uri = Uri.parse('http://127.0.0.1:${server.port}/slow');
    final client = DownloadHttpClient(
      server: uri,
      headers: {},
      receiveTimeout: const Duration(milliseconds: 400),
    );
    addTearDown(client.close);
    final response = await client.open(uri, cancelToken: CancelToken());
    expect(
      await response.stream.expand((bytes) => bytes).toList(),
      List.generate(8, (i) => i),
    );
    await response.close();
  });

  test('response idle timeout releases the stream', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.add([1]);
      await request.response.flush();
    });
    final uri = Uri.parse('http://127.0.0.1:${server.port}/stalled');
    final client = DownloadHttpClient(
      server: uri,
      headers: {},
      receiveTimeout: const Duration(milliseconds: 80),
    );
    addTearDown(client.close);
    final response = await client.open(uri, cancelToken: CancelToken());
    await expectLater(
      response.stream.drain<void>(),
      throwsA(isA<TimeoutException>()),
    );
    await response.close();
  });

  test(
    'an unavailable selected proxy never connects directly to the origin',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = unused.port;
      await unused.close();
      addTearDown(() => origin.close(force: true));
      var requests = 0;
      origin.listen((request) async {
        requests++;
        await request.response.close();
      });
      final uri = Uri.parse('http://127.0.0.1:${origin.port}/file');
      final client = DownloadHttpClient(
        server: uri,
        headers: {},
        proxy: DownloadProxy(
          host: '127.0.0.1',
          port: port,
          username: 'local',
          password: 'secret',
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.open(uri, cancelToken: CancelToken()),
        throwsA(isA<DownloadConnectionException>()),
      );
      expect(requests, 0);
    },
  );

  test('manual redirect limit stops a loop without consuming bodies', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = 302;
      request.response.headers.set('location', '/again');
      await request.response.close();
    });
    final uri = Uri.parse('http://127.0.0.1:${server.port}/first');
    final client = DownloadHttpClient(server: uri, headers: {});
    addTearDown(client.close);
    await expectLater(
      client.open(uri, cancelToken: CancelToken()),
      throwsA(isA<DownloadConnectionException>()),
    );
    expect(requests, 2);
  });

  test('proxy credentials are not forwarded as origin credentials', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    var requests = 0;
    final sockets = <Socket>[];
    addTearDown(() {
      for (final socket in sockets) {
        socket.destroy();
      }
    });
    proxy.listen((request) async {
      requests++;
      final auth = request.headers.value('proxy-authorization');
      if (auth == null) {
        request.response.statusCode = 407;
        request.response.headers.set(
          'proxy-authenticate',
          'Basic realm="download"',
        );
      } else {
        expect(auth, 'Basic ${base64Encode(utf8.encode('local:secret'))}');
        expect(request.headers.value('authorization'), isNull);
        expect(request.method, 'CONNECT');
        final socket = await request.response.detachSocket(writeHeaders: false);
        sockets.add(socket);
        socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        final headers = StringBuffer();
        var responded = false;
        socket.listen((bytes) {
          headers.write(latin1.decode(bytes));
          if (!responded && headers.toString().contains('\r\n\r\n')) {
            responded = true;
            expect(
              headers.toString().toLowerCase(),
              isNot(contains('proxy-authorization')),
            );
            socket.add(
              utf8.encode(
                'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n',
              ),
            );
            socket.add([4, 5]);
            unawaited(socket.close());
          }
        }, onError: (Object _) {});
        return;
      }
      await request.response.close();
    });
    final uri = Uri.parse('http://origin.invalid/file');
    final client = DownloadHttpClient(
      server: uri,
      headers: {},
      proxy: DownloadProxy(
        host: '127.0.0.1',
        port: proxy.port,
        username: 'local',
        password: 'secret',
      ),
    );
    addTearDown(client.close);
    final response = await client.open(uri, cancelToken: CancelToken());
    expect(await response.stream.expand((chunk) => chunk).toList(), [4, 5]);
    expect(requests, inInclusiveRange(1, 2));
    await response.close();
  });
}
