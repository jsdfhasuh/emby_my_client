import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:emby_my_client/updates/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

const installed = InstalledApp(
  version: '1.0.179',
  buildNumber: 1792000,
  platform: UpdatePlatform.android,
  abis: ['arm64-v8a', 'armeabi-v7a'],
);

Map<String, dynamic> releaseJson({int number = 180, int size = 4}) => {
  'tag_name': 'build-$number',
  'draft': false,
  'prerelease': false,
  'body': 'A public release',
  'assets': [
    for (final name in [
      'app-debug.apk',
      'app-arm64-v8a-debug.apk',
      'SHA256SUMS.txt',
    ])
      {
        'name': name,
        'size': size,
        'browser_download_url':
            'https://github.com/$releaseRepository/releases/download/build-$number/$name',
      },
  ],
};

Matcher failure(String code) =>
    isA<UpdateFailure>().having((e) => e.code, 'code', code);

class Adapter implements HttpClientAdapter {
  Adapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions) handler;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('compares numeric versions and identifies legacy build as unknown', () {
    expect(AppRelease.parse(releaseJson()).isNewerThan(installed), isTrue);
    expect(
      AppRelease.parse(releaseJson(number: 179)).isNewerThan(installed),
      isFalse,
    );
    expect(
      AppRelease.parse(releaseJson(number: 99)).isNewerThan(installed),
      isFalse,
    );
    expect(
      const InstalledApp(
        version: '1.0.0',
        buildNumber: 2001,
        platform: UpdatePlatform.android,
      ).releaseNumber,
      isNull,
    );
    expect(
      const InstalledApp(
        version: '1.0.179',
        buildNumber: 42,
        platform: UpdatePlatform.android,
      ).releaseNumber,
      isNull,
    );
    expect(
      const InstalledApp(
        version: '1.0.179',
        buildNumber: 179,
        platform: UpdatePlatform.ios,
      ).releaseNumber,
      179,
    );
  });

  test('selects preferred real ABI then universal fallback', () {
    final json = releaseJson();
    expect(
      AppRelease.parse(json).apkFor(installed).name,
      'app-arm64-v8a-debug.apk',
    );
    (json['assets'] as List).removeAt(1);
    expect(AppRelease.parse(json).apkFor(installed).name, 'app-debug.apk');
  });

  test('rejects unsupported ABI and never supplies APK to iOS', () {
    final release = AppRelease.parse(releaseJson());
    for (final app in [
      const InstalledApp(
        version: '1',
        buildNumber: 1,
        platform: UpdatePlatform.android,
        abis: ['riscv64'],
      ),
      const InstalledApp(
        version: '1',
        buildNumber: 1,
        platform: UpdatePlatform.ios,
      ),
    ]) {
      expect(() => release.apkFor(app), throwsA(failure('unsupported')));
    }
  });

  for (final invalid in <String, Object?>{
    'draft': true,
    'prerelease': true,
    'tag_name': 'build-0180',
    'assets': null,
    'body': 4,
  }.entries) {
    test('rejects invalid release ${invalid.key}', () {
      final json = releaseJson()..[invalid.key] = invalid.value;
      expect(() => AppRelease.parse(json), throwsA(failure('release')));
    });
  }

  test('rejects foreign URLs, duplicate assets, oversized and empty APKs', () {
    for (final change in <void Function(Map<String, dynamic>)>[
      (j) => j['assets'][0]['browser_download_url'] =
          'https://example.com/app-debug.apk',
      (j) => j['assets'][0]['size'] = maxApkBytes + 1,
      (j) => j['assets'][0]['size'] = 0,
      (j) => (j['assets'] as List).add(j['assets'][0]),
    ]) {
      final json = releaseJson();
      change(json);
      expect(() => AppRelease.parse(json), throwsA(failure('release')));
    }
  });

  test(
    'checksum manifest uses exact names and rejects duplicates/path injection',
    () {
      final hash = 'a' * 64;
      expect(
        GitHubUpdateSource.checksumFor(
          '$hash  app-debug.apk\n',
          'app-debug.apk',
        ),
        hash,
      );
      for (final manifest in [
        '$hash  ../app-debug.apk\n',
        '$hash  other.apk\n',
        '$hash  app-debug.apk\n$hash  app-debug.apk\n',
        'nonsense',
      ]) {
        expect(
          () => GitHubUpdateSource.checksumFor(manifest, 'app-debug.apk'),
          throwsA(failure('checksum')),
        );
      }
    },
  );

  test(
    'public client sends no Emby or user authentication and parses latest',
    () async {
      final adapter = Adapter(
        (_) => ResponseBody.fromString(jsonEncode(releaseJson()), 200),
      );
      final source = GitHubUpdateSource(adapter: adapter);
      addTearDown(source.close);
      expect((await source.latest(CancelToken())).number, 180);
      final request = adapter.requests.single;
      expect(
        request.uri.toString(),
        'https://api.github.com/repos/$releaseRepository/releases/latest',
      );
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(
          anyElement(
            anyOf(
              'authorization',
              'cookie',
              'x-emby-token',
              'x-emby-authorization',
            ),
          ),
        ),
      );
      expect(request.followRedirects, isFalse);
    },
  );

  test(
    'rejects HTTP and foreign-host redirects before contacting target',
    () async {
      for (final target in [
        'http://github.com/file',
        'https://evil.example/file',
        'https://user@github.com/file',
      ]) {
        final adapter = Adapter(
          (_) => ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': [target],
            },
          ),
        );
        final source = GitHubUpdateSource(adapter: adapter);
        addTearDown(source.close);
        await expectLater(
          source.latest(CancelToken()),
          throwsA(failure('release')),
        );
        expect(adapter.requests.length, 1);
      }
    },
  );

  test(
    'surfaces rate limits and network failures with safe messages',
    () async {
      for (final status in [403, 429, 500]) {
        final source = GitHubUpdateSource(
          adapter: Adapter(
            (_) => ResponseBody.fromString('private server detail', status),
          ),
        );
        addTearDown(source.close);
        await expectLater(
          source.latest(CancelToken()),
          throwsA(failure(status == 500 ? 'network' : 'rate_limit')),
        );
      }
      final source = GitHubUpdateSource(
        adapter: Adapter(
          (r) => throw DioException(
            requestOptions: r,
            type: DioExceptionType.connectionError,
            error: 'sensitive detail',
          ),
        ),
      );
      addTearDown(source.close);
      await expectLater(
        source.latest(CancelToken()),
        throwsA(failure('network')),
      );
      expect(
        const UpdateFailure('network').message,
        isNot(contains('sensitive')),
      );
    },
  );

  group('download verification', () {
    late Directory cache;
    const bytes = [1, 2, 3, 4];
    late AppRelease release;
    setUp(() async {
      cache = await Directory.systemTemp.createTemp('update-test-');
      release = AppRelease.parse(releaseJson());
    });
    tearDown(() async {
      await cache.delete(recursive: true);
    });

    GitHubUpdateSource sourceFor({
      List<int> data = bytes,
      String? digest,
      void Function()? onApk,
      bool missingManifest = false,
    }) {
      final source = GitHubUpdateSource(
        cache: () async => cache,
        adapter: Adapter((request) {
          if (request.path.endsWith('.txt')) {
            return ResponseBody.fromString(
              '${digest ?? sha256.convert(bytes)}  ${missingManifest ? 'other.apk' : 'app-arm64-v8a-debug.apk'}\n',
              200,
            );
          }
          onApk?.call();
          return ResponseBody.fromBytes(data, 200);
        }),
      );
      addTearDown(source.close);
      return source;
    }

    test(
      'streams verified bytes, reports progress, and cleans on discard',
      () async {
        final progress = <int>[];
        final value = await sourceFor().download(
          release,
          release.apkFor(installed),
          CancelToken(),
          (received, total) {
            progress.add(received);
            expect(total, 4);
          },
        );
        expect(await value.file.readAsBytes(), bytes);
        expect(value.sha256, sha256.convert(bytes).toString());
        expect(progress.last, 4);
        expect(value.releaseNumber, 180);
        await value.discard();
        expect(await value.file.exists(), isFalse);
      },
    );

    for (final data in [
      [1, 2],
      [1, 2, 3, 4, 5],
    ]) {
      test(
        'rejects wrong byte count ${data.length} and removes partial file',
        () async {
          await expectLater(
            sourceFor(data: data).download(
              release,
              release.apkFor(installed),
              CancelToken(),
              (_, _) {},
            ),
            throwsA(failure('size')),
          );
          expect(
            await cache.list(recursive: true).where((e) => e is File).isEmpty,
            isTrue,
          );
        },
      );
    }

    test(
      'rejects corrupted APK, missing checksum and duplicate manifest',
      () async {
        for (final source in [
          sourceFor(digest: '0' * 64),
          sourceFor(missingManifest: true),
        ]) {
          await expectLater(
            source.download(
              release,
              release.apkFor(installed),
              CancelToken(),
              (_, _) {},
            ),
            throwsA(failure('checksum')),
          );
        }
        expect(
          await cache.list(recursive: true).where((e) => e is File).isEmpty,
          isTrue,
        );
      },
    );

    test('cancellation never leaves an installable file', () async {
      final cancel = CancelToken();
      await expectLater(
        sourceFor(
          onApk: cancel.cancel,
        ).download(release, release.apkFor(installed), cancel, (_, _) {}),
        throwsA(failure('cancelled')),
      );
      expect(
        await cache.list(recursive: true).where((e) => e is File).isEmpty,
        isTrue,
      );
    });

    test('unavailable storage produces a retryable storage error', () async {
      final source = GitHubUpdateSource(
        cache: () async => throw const FileSystemException('disk full'),
        adapter: Adapter(
          (_) => ResponseBody.fromString(
            '${sha256.convert(bytes)}  app-arm64-v8a-debug.apk\n',
            200,
          ),
        ),
      );
      addTearDown(source.close);
      await expectLater(
        source.download(
          release,
          release.apkFor(installed),
          CancelToken(),
          (_, _) {},
        ),
        throwsA(failure('storage')),
      );
    });
  });
}
