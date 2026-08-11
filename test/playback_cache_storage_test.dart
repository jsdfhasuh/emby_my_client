import 'dart:convert';
import 'dart:io';

import 'package:emby_my_client/playback/cache/playback_cache_storage.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporaryRoot;
  late Directory cacheRoot;

  setUp(() async {
    temporaryRoot = await Directory.systemTemp.createTemp(
      'emby-cache-storage-test-',
    );
    cacheRoot = Directory(path.join(temporaryRoot.path, 'cache-root'));
  });

  tearDown(() async {
    if (await temporaryRoot.exists()) {
      await temporaryRoot.delete(recursive: true);
    }
  });

  PlatformPlaybackCacheStorage storage({Future<int?>? freeBytes}) =>
      PlatformPlaybackCacheStorage(
        rootResolver: () async => cacheRoot,
        freeBytesResolver: (_) => freeBytes ?? Future<int?>.value(8 << 30),
        nonceFactory: () => '0123456789abcdef0123456789abcdef',
      );

  test(
    'prepare writes a safe marker, verifies the probe, and registers active',
    () async {
      final cacheStorage = storage();

      final snapshot = await cacheStorage.prepareSession();

      expect(snapshot.isAvailable, isTrue);
      expect(snapshot.freeBytes, 8 << 30);
      final session = snapshot.session!;
      expect(await session.directory.exists(), isTrue);
      expect(
        await File(
          path.join(
            session.directory.path,
            PlatformPlaybackCacheStorage.probeFileName,
          ),
        ).exists(),
        isFalse,
      );
      final marker =
          jsonDecode(
                await File(
                  path.join(
                    session.directory.path,
                    PlatformPlaybackCacheStorage.markerFileName,
                  ),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(marker, {
        'schema': PlatformPlaybackCacheStorage.markerSchema,
        'nonce': '0123456789abcdef0123456789abcdef',
      });

      await cacheStorage.cleanupNonActiveMarkedSessions();
      expect(await session.directory.exists(), isTrue);
      await cacheStorage.cleanupSession(session);
      expect(await session.directory.exists(), isFalse);
    },
  );

  test(
    'unknown storage capacity fails closed and removes the new session',
    () async {
      final snapshot = await storage(
        freeBytes: Future<int?>.value(),
      ).prepareSession();

      expect(snapshot.isAvailable, isFalse);
      expect(
        snapshot.failureReason,
        PlaybackCacheStorageFailureReason.storageCapacityUnknown,
      );
      expect(
        await cacheRoot
            .list()
            .where(
              (entity) => path.basename(entity.path).startsWith('session-'),
            )
            .isEmpty,
        isTrue,
      );
    },
  );

  test(
    'an unavailable root reports directory failure without throwing',
    () async {
      await temporaryRoot.delete(recursive: true);
      await File(temporaryRoot.path).writeAsString('not a directory');
      final cacheStorage = PlatformPlaybackCacheStorage(
        rootResolver: () async =>
            Directory(path.join(temporaryRoot.path, 'cache-root')),
        freeBytesResolver: (_) async => 8 << 30,
      );

      final snapshot = await cacheStorage.prepareSession();

      expect(snapshot.isAvailable, isFalse);
      expect(
        snapshot.failureReason,
        PlaybackCacheStorageFailureReason.directoryUnavailable,
      );
    },
  );

  test(
    'cold cleanup removes only direct valid non-active marked sessions',
    () async {
      await cacheRoot.create(recursive: true);
      final stale = await _writeMarkedSession(
        cacheRoot,
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      final unmarked = Directory(path.join(cacheRoot.path, 'unmarked'));
      await unmarked.create();
      final malformed = Directory(
        path.join(cacheRoot.path, 'session-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
      );
      await malformed.create();
      await File(
        path.join(malformed.path, PlatformPlaybackCacheStorage.markerFileName),
      ).writeAsString('{bad-json');
      final nested = await _writeMarkedSession(
        unmarked,
        'cccccccccccccccccccccccccccccccc',
      );

      await storage().cleanupNonActiveMarkedSessions();

      expect(await stale.exists(), isFalse);
      expect(await unmarked.exists(), isTrue);
      expect(await malformed.exists(), isTrue);
      expect(await nested.exists(), isTrue);
    },
  );

  test('cleanup rejects a forged session outside the cache root', () async {
    final outside = await _writeMarkedSession(
      temporaryRoot,
      'dddddddddddddddddddddddddddddddd',
    );
    final forged = PlaybackCacheSession(
      directory: outside,
      nonce: 'dddddddddddddddddddddddddddddddd',
    );

    await storage().cleanupSession(forged);

    expect(await outside.exists(), isTrue);
  });

  test(
    'cold cleanup never follows a marked symlink outside the root',
    () async {
      if (Platform.isWindows) return;
      await cacheRoot.create(recursive: true);
      const nonce = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
      final outside = await _writeMarkedSession(temporaryRoot, nonce);
      final linkedPath = path.join(cacheRoot.path, 'session-$nonce');
      final link = Link(linkedPath);
      await link.create(outside.path);

      await storage().cleanupNonActiveMarkedSessions();

      expect(await link.exists(), isTrue);
      expect(await outside.exists(), isTrue);
    },
  );

  test('concurrent prepare and cleanup operations remain serialized', () async {
    final cacheStorage = PlatformPlaybackCacheStorage(
      rootResolver: () async => cacheRoot,
      freeBytesResolver: (_) async => 8 << 30,
      nonceFactory: _NonceSequence([
        '11111111111111111111111111111111',
        '22222222222222222222222222222222',
      ]).next,
    );

    final snapshots = await Future.wait([
      cacheStorage.prepareSession(),
      cacheStorage.prepareSession(),
    ]);
    await cacheStorage.cleanupNonActiveMarkedSessions();

    expect(snapshots.every((snapshot) => snapshot.isAvailable), isTrue);
    expect(await snapshots[0].session!.directory.exists(), isTrue);
    expect(await snapshots[1].session!.directory.exists(), isTrue);
    await Future.wait(
      snapshots.map(
        (snapshot) => cacheStorage.cleanupSession(snapshot.session!),
      ),
    );
    expect(
      await cacheRoot
          .list()
          .where((entity) => path.basename(entity.path).startsWith('session-'))
          .isEmpty,
      isTrue,
    );
  });

  test('100 real filesystem sessions leave no cache residue', () async {
    final nonces = List<String>.generate(
      100,
      (index) => index.toRadixString(16).padLeft(32, '0'),
    );
    final cacheStorage = PlatformPlaybackCacheStorage(
      rootResolver: () async => cacheRoot,
      freeBytesResolver: (_) async => 8 << 30,
      nonceFactory: _NonceSequence(nonces).next,
    );

    for (var index = 0; index < 100; index++) {
      final snapshot = await cacheStorage.prepareSession();
      expect(snapshot.isAvailable, isTrue, reason: 'cycle ${index + 1}');
      await cacheStorage.cleanupSession(snapshot.session!);
    }

    expect(
      await cacheRoot
          .list()
          .where((entity) => path.basename(entity.path).startsWith('session-'))
          .isEmpty,
      isTrue,
    );
  });
}

Future<Directory> _writeMarkedSession(Directory parent, String nonce) async {
  final directory = Directory(path.join(parent.path, 'session-$nonce'));
  await directory.create(recursive: true);
  await File(
    path.join(directory.path, PlatformPlaybackCacheStorage.markerFileName),
  ).writeAsString(
    jsonEncode({
      'schema': PlatformPlaybackCacheStorage.markerSchema,
      'nonce': nonce,
    }),
    flush: true,
  );
  return directory;
}

class _NonceSequence {
  _NonceSequence(this.values);

  final List<String> values;
  int _index = 0;

  String next() => values[_index++];
}
