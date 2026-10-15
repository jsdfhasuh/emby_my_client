import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:emby_my_client/updates/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

// Builds 186, 187 and 191 share the unchanged production updater Git blob
// 17a42502e293bc9c1456d0f11c91f6794b34a08f. The Python release tests compare
// this fixture against prepare_release's actual output names, bytes and sums.
class ReleaseFixtureAdapter implements HttpClientAdapter {
  ReleaseFixtureAdapter(this.fixture, {String? checksums})
    : checksums = checksums ?? fixture['checksums'] as String;
  final Map<String, dynamic> fixture;
  final String checksums;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final name = options.uri.pathSegments.last;
    if (name == 'latest') {
      return ResponseBody.fromString(jsonEncode(fixture['release']), 200);
    }
    if (name == 'SHA256SUMS.txt') {
      return ResponseBody.fromString(checksums, 200);
    }
    final contents = (fixture['apkContents'] as Map)[name];
    if (contents is! String) {
      throw StateError('Unexpected release download: $name');
    }
    return ResponseBody.fromBytes(utf8.encode(contents), 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Map<String, dynamic> fixture;
  late Directory cache;
  setUp(() async {
    fixture =
        jsonDecode(
              await File(
                'test/fixtures/releases/versioned-build-192.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    cache = await Directory.systemTemp.createTemp('versioned-release-test-');
  });
  tearDown(() async => cache.delete(recursive: true));

  InstalledApp installed(int build, List<String> abis) => InstalledApp(
    version: '1.0.$build',
    buildNumber:
        build * androidVersionStride +
        (const {
              'arm64-v8a': 2000,
              'armeabi-v7a': 1000,
              'x86_64': 4000,
            }[abis.first] ??
            0),
    platform: UpdatePlatform.android,
    abis: abis,
  );

  GitHubUpdateSource sourceFor(ReleaseFixtureAdapter adapter) {
    final source = GitHubUpdateSource(
      adapter: adapter,
      cache: () async => cache,
    );
    addTearDown(source.close);
    return source;
  }

  for (final build in [186, 187, 191]) {
    for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'universal']) {
      test(
        'build $build selects and verifies the $abi compatibility alias',
        () async {
          if (abi == 'universal') {
            (fixture['release']['assets'] as List).removeWhere(
              (item) => const [
                'app-arm64-v8a-debug.apk',
                'app-armeabi-v7a-debug.apk',
                'app-x86_64-debug.apk',
              ].contains(item['name']),
            );
          }
          // Asset order is not a preference, even with versioned alternatives.
          fixture['release']['assets'] = (fixture['release']['assets'] as List)
              .reversed
              .toList();
          final adapter = ReleaseFixtureAdapter(fixture);
          final source = sourceFor(adapter);
          final release = await source.latest(CancelToken());
          final app = installed(build, [
            abi == 'universal' ? 'arm64-v8a' : abi,
          ]);
          expect(app.releaseNumber, build);
          expect(release.number, 192);
          expect(release.isNewerThan(app), isTrue);
          final selected = release.apkFor(app);
          final alias = abi == 'universal'
              ? 'app-debug.apk'
              : 'app-$abi-debug.apk';
          expect(selected.name, alias);
          expect(
            release.assets.keys,
            isNot(anyElement(startsWith('EmoEmby-'))),
          );
          final download = await source.download(
            release,
            selected,
            CancelToken(),
            (_, _) {},
          );
          final contents = utf8.encode(fixture['apkContents'][alias] as String);
          expect(await download.file.readAsBytes(), contents);
          expect(download.sha256, sha256.convert(contents).toString());
          expect(download.size, selected.size);
          expect(download.releaseNumber, 192);
          expect(
            GitHubUpdateSource.checksumFor(
              fixture['checksums'] as String,
              'EmoEmby-1.0.192-$abi.apk',
            ),
            download.sha256,
          );
          expect(adapter.requests.last.pathSegments.last, alias);
          await download.discard();
        },
      );
    }
  }

  test(
    'device ABI order wins over versioned, universal and stale candidates',
    () {
      final assets = fixture['release']['assets'] as List;
      for (final name in [
        'EmoEmby-1.0.191-arm64-v8a.apk',
        'EmoEmby-1.0.193-arm64-v8a.apk',
        'app-riscv64-debug.apk',
      ]) {
        assets.insert(0, {
          'name': name,
          'size': 1000000,
          'browser_download_url':
              'https://github.com/$releaseRepository/releases/download/build-192/$name',
        });
      }
      final release = AppRelease.parse(fixture['release']);
      expect(
        release.apkFor(installed(191, ['armeabi-v7a', 'arm64-v8a'])).name,
        'app-armeabi-v7a-debug.apk',
      );
      expect(
        release.apkFor(installed(191, ['arm64-v8a', 'armeabi-v7a'])).name,
        'app-arm64-v8a-debug.apk',
      );
    },
  );

  test('removing all compatibility aliases would break installed updaters', () {
    (fixture['release']['assets'] as List).removeWhere(
      (item) => (item['name'] as String).startsWith('app-'),
    );
    final release = AppRelease.parse(fixture['release']);
    expect(
      () => release.apkFor(installed(191, ['arm64-v8a'])),
      throwsA(
        isA<UpdateFailure>().having((e) => e.code, 'code', 'unsupported'),
      ),
    );
  });

  test('duplicate alias candidates fail instead of choosing the first', () {
    final assets = fixture['release']['assets'] as List;
    assets.add(
      assets.firstWhere((item) => item['name'] == 'app-arm64-v8a-debug.apk'),
    );
    expect(
      () => AppRelease.parse(fixture['release']),
      throwsA(isA<UpdateFailure>().having((e) => e.code, 'code', 'release')),
    );
  });

  for (final invalid in [
    'missing alias',
    'duplicate alias',
    'wrong alias hash',
  ]) {
    test('mixed-name manifest rejects $invalid', () async {
      const alias = 'app-arm64-v8a-debug.apk';
      final lines = const LineSplitter().convert(
        fixture['checksums'] as String,
      );
      final record = lines.singleWhere((line) => line.endsWith('  $alias'));
      if (invalid == 'missing alias') lines.remove(record);
      if (invalid == 'duplicate alias') lines.add(record);
      if (invalid == 'wrong alias hash') {
        lines[lines.indexOf(record)] = '${'0' * 64}  $alias';
      }
      final adapter = ReleaseFixtureAdapter(
        fixture,
        checksums: '${lines.join('\n')}\n',
      );
      final source = sourceFor(adapter);
      final release = await source.latest(CancelToken());
      await expectLater(
        source.download(
          release,
          release.apkFor(installed(191, ['arm64-v8a'])),
          CancelToken(),
          (_, _) {},
        ),
        throwsA(isA<UpdateFailure>().having((e) => e.code, 'code', 'checksum')),
      );
      expect(
        await cache.list(recursive: true).where((e) => e is File).isEmpty,
        isTrue,
      );
    });
  }
}
