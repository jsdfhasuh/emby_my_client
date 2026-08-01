import 'dart:async';
import 'dart:io';

import 'package:emby_my_client/images/emby_image_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('same-origin redirects preserve image authentication headers', () async {
    String? receivedToken;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/redirect') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/image');
      } else {
        receivedToken = request.headers.value('X-Emby-Token');
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('image', 'jpeg')
          ..add([1, 2, 3]);
      }
      await request.response.close();
    });
    final service = SameOriginImageFileService();

    final response = await service.get(
      'http://${server.address.address}:${server.port}/redirect',
      headers: const {'X-Emby-Token': 'secret-token'},
    );
    final bytes = await response.content.expand((chunk) => chunk).toList();

    expect(response.statusCode, HttpStatus.ok);
    expect(bytes, [1, 2, 3]);
    expect(receivedToken, 'secret-token');
  });

  test(
    'cross-origin redirects are rejected before credentials are sent',
    () async {
      var targetWasCalled = false;
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await source.close(force: true);
        await target.close(force: true);
      });
      target.listen((request) async {
        targetWasCalled = true;
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      source.listen((request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://${target.address.address}:${target.port}/image',
          );
        await request.response.close();
      });
      final service = SameOriginImageFileService();

      final request = service.get(
        'http://${source.address.address}:${source.port}/redirect',
        headers: const {'X-Emby-Token': 'secret-token'},
      );

      await expectLater(
        request,
        throwsA(
          isA<UnsafeImageRedirectException>().having(
            (error) => error.toString(),
            'message',
            isNot(contains('secret-token')),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(targetWasCalled, isFalse);
    },
  );

  test('times out while waiting for image response headers', () async {
    final service = SameOriginImageFileService(
      client: MockClient((_) => Completer<http.Response>().future),
      responseTimeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      service.get('https://emby.example.test/image'),
      throwsA(
        isA<ImageRequestTimeoutException>()
            .having(
              (error) => error.stage,
              'stage',
              ImageRequestTimeoutStage.response,
            )
            .having(
              (error) => error.duration,
              'duration',
              const Duration(milliseconds: 20),
            ),
      ),
    );
  });

  test('times out when an image response body stalls', () async {
    final stalledBody = StreamController<List<int>>();
    addTearDown(stalledBody.close);
    final service = SameOriginImageFileService(
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          stalledBody.stream,
          HttpStatus.ok,
          headers: const {'content-type': 'image/jpeg'},
        ),
      ),
      responseIdleTimeout: const Duration(milliseconds: 20),
    );

    final response = await service.get('https://emby.example.test/image');

    await expectLater(
      response.content.toList(),
      throwsA(
        isA<ImageRequestTimeoutException>()
            .having(
              (error) => error.stage,
              'stage',
              ImageRequestTimeoutStage.responseBody,
            )
            .having(
              (error) => error.duration,
              'duration',
              const Duration(milliseconds: 20),
            ),
      ),
    );
  });

  test('byte budget evicts least recently used entries first', () {
    final policy = EmbyImageCacheBudgetPolicy(maxBytes: 10);
    final removals = policy.keysToRemove([
      EmbyImageCacheEntry(
        key: 'newest',
        bytes: 5,
        touched: DateTime.utc(2026, 1, 3),
      ),
      EmbyImageCacheEntry(
        key: 'oldest',
        bytes: 6,
        touched: DateTime.utc(2026, 1, 1),
      ),
      EmbyImageCacheEntry(
        key: 'middle',
        bytes: 4,
        touched: DateTime.utc(2026, 1, 2),
      ),
    ]);

    expect(removals, ['oldest']);
  });
}
