import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'download_integrity.dart';

/// Cheap repeat checks reuse only a successful digest for an unchanged file.
/// Explicit checks and playback must request fresh verification. A missing
/// digest permits header/size checks only, not a content integrity guarantee.
class DownloadMediaVerifier {
  final Map<String, _VerifiedMedia> _verified = {};

  Future<String?> check(
    File file, {
    int? expectedBytes,
    DownloadIntegrity? integrity,
    bool fresh = false,
  }) async {
    try {
      final before = await file.stat();
      if (before.type != FileSystemEntityType.file) return 'missingFile';
      if (before.size <= 0 ||
          (expectedBytes != null &&
              expectedBytes > 0 &&
              before.size != expectedBytes)) {
        return 'localMediaCorrupt';
      }
      final stamp = _VerifiedMedia(before, integrity);
      if (!fresh &&
          integrity != null &&
          _verified[file.path]?.matches(stamp) == true) {
        return null;
      }
      final handle = await file.open();
      late List<int> prefix;
      try {
        prefix = await handle.read(min(512, before.size));
      } finally {
        await handle.close();
      }
      final text = utf8
          .decode(prefix, allowMalformed: true)
          .trimLeft()
          .toLowerCase();
      if (text.startsWith('<!doctype html') ||
          text.startsWith('<html') ||
          text.startsWith('{"message"') ||
          text.startsWith('{"error"')) {
        return 'localMediaCorrupt';
      }
      if (integrity != null &&
          !await verifyDownloadIntegrity(file, integrity)) {
        _verified.remove(file.path);
        return 'checksumMismatch';
      }
      final after = _VerifiedMedia(await file.stat(), integrity);
      if (!stamp.matches(after)) return 'localMediaCorrupt';
      if (integrity != null) _verified[file.path] = after;
      return null;
    } on FileSystemException {
      _verified.remove(file.path);
      return 'localMediaCorrupt';
    }
  }
}

class _VerifiedMedia {
  const _VerifiedMedia(this.stat, this.integrity);
  final FileStat stat;
  final DownloadIntegrity? integrity;

  bool matches(_VerifiedMedia other) =>
      stat.type == other.stat.type &&
      stat.size == other.stat.size &&
      stat.modified == other.stat.modified &&
      stat.changed == other.stat.changed &&
      integrity == other.integrity;
}
