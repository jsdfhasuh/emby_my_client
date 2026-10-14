import 'dart:async';
import 'dart:io';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/images/emby_image_cache.dart';
import 'package:emby_my_client/images/persistent_image_file_system.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getTemporaryDirectory'
              ? Directory.systemTemp.path
              : null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });
  const a = ServerScope(serverId: 'server', userId: 'a');
  const b = ServerScope(serverId: 'server', userId: 'b');
  String key(ServerScope scope, int item) =>
      'emby-image-v2:${scope.cacheNamespace}:$item:primary:tag:w600:h900:q90';

  test(
    'image bytes and index survive manager disposal and reopening',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'persistent-images-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = _manager(directory);
      final saved = await first.putFile(
        'https://fixture.invalid/image',
        Uint8List.fromList([1, 2, 3]),
        key: key(a, 1),
        fileExtension: 'jpg',
      );
      expect(
        path.isWithin(path.join(directory.path, 'images'), saved.path),
        isTrue,
      );
      await first.dispose();
      final reopened = _manager(directory);
      addTearDown(reopened.dispose);
      final cached = await reopened.getFileFromCache(key(a, 1));
      expect(cached, isNotNull);
      expect(await cached!.file.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'scoped image clearing and budget preserve other accounts and offline assets',
    () async {
      final directory = await Directory.systemTemp.createTemp('image-scope-');
      addTearDown(() => directory.delete(recursive: true));
      final manager = _manager(directory, budget: 6);
      addTearDown(manager.dispose);
      final downloaded = File(
        '${directory.path}/offline/a/assets/subtitle.srt',
      );
      await downloaded.parent.create(recursive: true);
      await downloaded.writeAsString('retained downloaded asset');
      await manager.putFile(
        'https://fixture.invalid/a',
        Uint8List.fromList([1, 2, 3]),
        key: key(a, 1),
      );
      await manager.putFile(
        'https://fixture.invalid/b',
        Uint8List.fromList([4, 5, 6]),
        key: key(b, 1),
      );
      await manager.clearScope(a);
      expect(await manager.getFileFromCache(key(a, 1)), isNull);
      expect(await manager.getFileFromCache(key(b, 1)), isNotNull);
      await manager.putFile(
        'https://fixture.invalid/a2',
        Uint8List.fromList([7, 8, 9, 10]),
        key: key(a, 2),
      );
      final usage = await manager.enforceBudget();
      expect(usage.bytes, lessThanOrEqualTo(6));
      expect(await downloaded.readAsString(), 'retained downloaded asset');
    },
  );

  test('persistent image filesystem rejects escaping paths', () async {
    final fs = PersistentImageFileSystem(
      directoryResolver: () async => 'unused',
    );
    await expectLater(fs.createFile('../escape.jpg'), throwsFormatException);
  });

  test('late image response cannot recreate a cleared account cache', () async {
    final directory = await Directory.systemTemp.createTemp('late-image-');
    addTearDown(() => directory.delete(recursive: true));
    final started = Completer<void>();
    final gate = Completer<void>();
    final client = MockClient((request) async {
      started.complete();
      await gate.future;
      return http.Response.bytes(
        [1, 2, 3],
        200,
        headers: {'content-type': 'image/jpeg'},
      );
    });
    addTearDown(client.close);
    final manager = EmbyImageCacheManager(
      fileService: SameOriginImageFileService(client: client),
      fileSystem: PersistentImageFileSystem(
        directoryResolver: () async => '${directory.path}/images',
      ),
      repository: JsonCacheInfoRepository.withFile(
        File('${directory.path}/index.json'),
      ),
    );
    addTearDown(manager.dispose);
    final pending = manager.downloadFile(
      'https://fixture.invalid/late',
      key: key(a, 9),
    );
    final rejected = expectLater(pending, throwsA(isA<FileSystemException>()));
    await started.future;
    await manager.clearScope(a);
    gate.complete();
    await rejected;
    expect(await manager.getFileFromCache(key(a, 9)), isNull);
  });
}

EmbyImageCacheManager _manager(
  Directory directory, {
  int budget = 256 * 1024 * 1024,
}) => EmbyImageCacheManager(
  fileSystem: PersistentImageFileSystem(
    directoryResolver: () async => '${directory.path}/images',
  ),
  repository: JsonCacheInfoRepository.withFile(
    File('${directory.path}/index.json'),
  ),
  maxCacheBytes: budget,
);
