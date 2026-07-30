import 'dart:io';

import 'package:path/path.dart' as path;

import 'download_models.dart';
import 'download_path_policy.dart';

class DownloadCleanupReport {
  const DownloadCleanupReport({
    required this.deletedFiles,
    required this.reclaimedBytes,
  });

  final int deletedFiles;
  final int reclaimedBytes;
}

class DownloadCleanup {
  const DownloadCleanup({
    this.retention = const Duration(days: 7),
    this.now = DateTime.now,
  });

  final Duration retention;
  final DateTime Function() now;

  Future<DownloadCleanupReport> run({
    required Directory directory,
    required Iterable<DownloadTaskRecord> tasks,
  }) async {
    if (!await directory.exists()) {
      return const DownloadCleanupReport(deletedFiles: 0, reclaimedBytes: 0);
    }
    final pathPolicy = DownloadPathPolicy(directory);
    final knownPaths = <String>{
      for (final task in tasks) ...[
        pathPolicy.resolveStoredPath(task.tempPath),
        pathPolicy.resolveStoredPath(task.finalPath),
        for (final assetPath in task.metadata.assetPaths)
          pathPolicy.resolveStoredPath(assetPath),
      ],
    }.where(pathPolicy.contains).toSet();
    final cutoff = now().toUtc().subtract(retention);
    var deletedFiles = 0;
    var reclaimedBytes = 0;
    final entities = await directory
        .list(recursive: true, followLinks: false)
        .toList();
    for (final entity in entities.whereType<File>()) {
      final candidate = path.normalize(entity.absolute.path);
      if (!pathPolicy.contains(candidate) || knownPaths.contains(candidate)) {
        continue;
      }
      final modified = await entity.lastModified();
      if (modified.toUtc().isAfter(cutoff)) continue;
      final length = (await entity.length()).toInt();
      await entity.delete();
      deletedFiles++;
      reclaimedBytes += length;
    }
    final directories = entities.whereType<Directory>().toList()
      ..sort((left, right) => right.path.length.compareTo(left.path.length));
    for (final child in directories) {
      if (await child.exists() &&
          await child.list(followLinks: false).isEmpty) {
        await child.delete();
      }
    }
    return DownloadCleanupReport(
      deletedFiles: deletedFiles,
      reclaimedBytes: reclaimedBytes,
    );
  }
}
