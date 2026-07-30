import 'dart:io';

import 'package:emby_my_client/core/server_scope.dart';
import 'package:emby_my_client/downloads/download_cleanup.dart';
import 'package:emby_my_client/downloads/download_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  test('deletes only expired files without database ownership', () async {
    final now = DateTime.utc(2026, 7, 30, 12);
    final directory = await Directory.systemTemp.createTemp(
      'emby-cleanup-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final finalFile = File(_join(directory, 'known.mkv'));
    final temporary = File(_join(directory, 'known.mkv.part'));
    final asset = File(_join(directory, 'assets', 'known.jpg'));
    final oldOrphan = File(_join(directory, 'old.part'));
    final freshOrphan = File(_join(directory, 'fresh.part'));
    for (final file in [finalFile, temporary, asset, oldOrphan, freshOrphan]) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
    }
    await oldOrphan.setLastModified(now.subtract(const Duration(days: 8)));
    await freshOrphan.setLastModified(now.subtract(const Duration(days: 1)));
    final task = _task(
      finalPath: finalFile.path,
      tempPath: temporary.path,
      imagePath: asset.path,
      now: now,
    );

    final report = await DownloadCleanup(
      now: () => now,
    ).run(directory: directory, tasks: [task]);

    expect(report.deletedFiles, 1);
    expect(report.reclaimedBytes, 3);
    expect(await oldOrphan.exists(), isFalse);
    expect(await freshOrphan.exists(), isTrue);
    expect(await finalFile.exists(), isTrue);
    expect(await temporary.exists(), isTrue);
    expect(await asset.exists(), isTrue);
  });

  test('preserves expired files referenced by relative task paths', () async {
    final now = DateTime.utc(2026, 7, 30, 12);
    final directory = await Directory.systemTemp.createTemp(
      'emby-cleanup-relative-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relativeFinal = path.join('media', 'known.mkv');
    final relativeTemporary = path.join('parts', 'known.mkv.part');
    final relativeAsset = path.join('media', 'assets', 'known.jpg');
    final finalFile = File(path.join(directory.path, relativeFinal));
    final temporary = File(path.join(directory.path, relativeTemporary));
    final asset = File(path.join(directory.path, relativeAsset));
    for (final file in [finalFile, temporary, asset]) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
      await file.setLastModified(now.subtract(const Duration(days: 8)));
    }
    final task = _task(
      finalPath: relativeFinal,
      tempPath: relativeTemporary,
      imagePath: relativeAsset,
      now: now,
    );

    final report = await DownloadCleanup(
      now: () => now,
    ).run(directory: directory, tasks: [task]);

    expect(report.deletedFiles, 0);
    expect(await finalFile.exists(), isTrue);
    expect(await temporary.exists(), isTrue);
    expect(await asset.exists(), isTrue);
  });
}

DownloadTaskRecord _task({
  required String finalPath,
  required String tempPath,
  required String imagePath,
  required DateTime now,
}) => DownloadTaskRecord(
  id: 'task-1',
  scope: const ServerScope(serverId: 'server-1', userId: 'user-1'),
  itemId: 'item-1',
  mediaSourceId: 'source-1',
  sourceKind: DownloadSourceKind.original,
  sourceFingerprint: 'fingerprint',
  status: DownloadStatus.completed,
  downloadedBytes: 3,
  retryCount: 0,
  tempPath: tempPath,
  finalPath: finalPath,
  metadata: OfflineMediaMetadata(
    name: 'Known',
    itemType: 'Movie',
    primaryImagePath: imagePath,
    mediaStreams: const [],
  ),
  createdAt: now,
  updatedAt: now,
);

String _join(Directory directory, String first, [String? second]) {
  final parts = [directory.path, first];
  if (second != null) parts.add(second);
  return parts.join(Platform.pathSeparator);
}
