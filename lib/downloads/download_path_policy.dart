import 'dart:io';

import 'package:path/path.dart' as path;

class DownloadPathPolicy {
  DownloadPathPolicy(Directory directory)
    : root = path.normalize(directory.absolute.path);

  final String root;

  String resolveStoredPath(String storedPath) {
    final candidate = path.isAbsolute(storedPath)
        ? storedPath
        : path.join(root, storedPath);
    return path.normalize(path.absolute(candidate));
  }

  bool contains(String resolvedPath) =>
      path.isWithin(root, path.normalize(path.absolute(resolvedPath)));

  Future<bool> resolvesWithinRoot(FileSystemEntity entity) async {
    if (!await entity.exists()) return true;
    try {
      final resolvedRoot = path.normalize(
        await Directory(root).resolveSymbolicLinks(),
      );
      final resolvedEntity = path.normalize(
        await entity.resolveSymbolicLinks(),
      );
      return path.isWithin(resolvedRoot, resolvedEntity);
    } on FileSystemException {
      return false;
    }
  }
}
