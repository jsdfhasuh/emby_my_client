import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

enum PlaybackCacheStorageFailureReason {
  none,
  directoryUnavailable,
  storageCapacityUnknown,
}

class PlaybackCacheSession {
  const PlaybackCacheSession({required this.directory, required this.nonce});

  final Directory directory;
  final String nonce;
}

class PlaybackCacheStorageSnapshot {
  const PlaybackCacheStorageSnapshot.available({
    required PlaybackCacheSession this.session,
    required int this.freeBytes,
  }) : failureReason = PlaybackCacheStorageFailureReason.none;

  const PlaybackCacheStorageSnapshot.unavailable(this.failureReason)
    : session = null,
      freeBytes = null;

  final PlaybackCacheSession? session;
  final int? freeBytes;
  final PlaybackCacheStorageFailureReason failureReason;

  bool get isAvailable =>
      session != null &&
      freeBytes != null &&
      failureReason == PlaybackCacheStorageFailureReason.none;
}

abstract interface class PlaybackCacheStorage {
  Future<PlaybackCacheStorageSnapshot> prepareSession();
  Future<int?> freeBytesFor(Directory directory);
  Future<void> cleanupSession(PlaybackCacheSession session);
  Future<void> cleanupNonActiveMarkedSessions();
}

typedef PlaybackCacheRootResolver = Future<Directory> Function();
typedef PlaybackCacheFreeBytesResolver =
    Future<int?> Function(Directory directory);

class PlatformPlaybackCacheStorage implements PlaybackCacheStorage {
  PlatformPlaybackCacheStorage({
    PlaybackCacheRootResolver? rootResolver,
    PlaybackCacheFreeBytesResolver? freeBytesResolver,
    String Function()? nonceFactory,
  }) : _rootResolver = rootResolver ?? _defaultRoot,
       _freeBytesResolver = freeBytesResolver ?? _defaultFreeBytes,
       _nonceFactory = nonceFactory ?? _secureNonce;

  static const String rootDirectoryName = 'emby-playback-cache';
  static const String markerFileName = '.emby-playback-cache-session-v1';
  static const String markerSchema = 'emby-playback-cache-session/v1';
  static const String probeFileName = '.probe';
  static const String _probePayload = 'emby-cache-probe-v1';

  final PlaybackCacheRootResolver _rootResolver;
  final PlaybackCacheFreeBytesResolver _freeBytesResolver;
  final String Function() _nonceFactory;
  final Set<String> _activeSessionPaths = {};
  Future<void> _tail = Future<void>.value();

  @override
  Future<PlaybackCacheStorageSnapshot> prepareSession() => _enqueue(() async {
    Directory root;
    try {
      root = await _rootResolver();
      await root.create(recursive: true);
      await _cleanupNonActiveMarkedSessions(root);
    } on FileSystemException {
      return const PlaybackCacheStorageSnapshot.unavailable(
        PlaybackCacheStorageFailureReason.directoryUnavailable,
      );
    }

    final nonce = _nonceFactory();
    if (!_validNonce(nonce)) {
      return const PlaybackCacheStorageSnapshot.unavailable(
        PlaybackCacheStorageFailureReason.directoryUnavailable,
      );
    }
    final directory = Directory(path.join(root.path, 'session-$nonce'));
    final session = PlaybackCacheSession(directory: directory, nonce: nonce);

    try {
      await directory.create();
      await _writeMarker(session);
      await _probe(directory);
    } on FileSystemException {
      await _deleteSessionDirectoryBestEffort(root, session);
      return const PlaybackCacheStorageSnapshot.unavailable(
        PlaybackCacheStorageFailureReason.directoryUnavailable,
      );
    }

    final freeBytes = await freeBytesFor(directory);
    if (freeBytes == null || freeBytes < 0) {
      await _deleteSessionDirectoryBestEffort(root, session);
      return const PlaybackCacheStorageSnapshot.unavailable(
        PlaybackCacheStorageFailureReason.storageCapacityUnknown,
      );
    }

    _activeSessionPaths.add(_normalized(directory.path));
    return PlaybackCacheStorageSnapshot.available(
      session: session,
      freeBytes: freeBytes,
    );
  });

  @override
  Future<int?> freeBytesFor(Directory directory) async {
    try {
      return await _freeBytesResolver(directory);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> cleanupSession(PlaybackCacheSession session) =>
      _enqueue(() async {
        _activeSessionPaths.remove(_normalized(session.directory.path));
        try {
          final root = await _rootResolver();
          await _deleteSessionDirectoryBestEffort(root, session);
        } catch (_) {
          // Cache cleanup is best-effort and must not block playback shutdown.
        }
      });

  @override
  Future<void> cleanupNonActiveMarkedSessions() => _enqueue(() async {
    try {
      final root = await _rootResolver();
      await _cleanupNonActiveMarkedSessions(root);
    } catch (_) {
      // Cold-start cleanup is best-effort.
    }
  });

  Future<void> _cleanupNonActiveMarkedSessions(Directory root) async {
    if (!await root.exists()) return;
    final normalizedRoot = _normalized(root.path);
    await for (final entity in root.list(followLinks: false)) {
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      final candidatePath = _normalized(entity.path);
      if (path.dirname(candidatePath) != normalizedRoot ||
          _activeSessionPaths.contains(candidatePath)) {
        continue;
      }
      final marker = await _readValidMarker(Directory(entity.path));
      if (marker == null ||
          path.basename(candidatePath) != 'session-${marker.nonce}') {
        continue;
      }
      try {
        await Directory(entity.path).delete(recursive: true);
      } on FileSystemException {
        // A single stale cache directory must not abort cleanup.
      }
    }
  }

  Future<void> _writeMarker(PlaybackCacheSession session) async {
    final marker = File(path.join(session.directory.path, markerFileName));
    await marker.writeAsString(
      jsonEncode({'schema': markerSchema, 'nonce': session.nonce}),
      flush: true,
    );
  }

  Future<void> _probe(Directory directory) async {
    final file = File(path.join(directory.path, probeFileName));
    RandomAccessFile? handle;
    try {
      handle = await file.open(mode: FileMode.write);
      await handle.writeString(_probePayload);
      await handle.flush();
      await handle.close();
      handle = null;
      final bytes = await file.readAsBytes();
      if (utf8.decode(bytes) != _probePayload) {
        throw const FileSystemException('Playback cache probe mismatch');
      }
    } finally {
      if (handle != null) {
        await handle.close();
      }
      if (await file.exists()) await file.delete();
    }
  }

  Future<_PlaybackCacheMarker?> _readValidMarker(Directory directory) async {
    try {
      final marker = File(path.join(directory.path, markerFileName));
      if (await FileSystemEntity.type(marker.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map ||
          decoded.length != 2 ||
          decoded['schema'] != markerSchema ||
          decoded['nonce'] is! String ||
          !_validNonce(decoded['nonce'] as String)) {
        return null;
      }
      return _PlaybackCacheMarker(decoded['nonce'] as String);
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteSessionDirectoryBestEffort(
    Directory root,
    PlaybackCacheSession session,
  ) async {
    final normalizedRoot = _normalized(root.path);
    final normalizedSession = _normalized(session.directory.path);
    if (path.dirname(normalizedSession) != normalizedRoot ||
        path.basename(normalizedSession) != 'session-${session.nonce}' ||
        !_validNonce(session.nonce)) {
      return;
    }
    if (await FileSystemEntity.type(
          session.directory.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      return;
    }
    final marker = await _readValidMarker(session.directory);
    if (marker?.nonce != session.nonce) return;
    try {
      await session.directory.delete(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup deliberately preserves non-owned directories.
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final next = _tail.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _tail = next;
    return completer.future;
  }

  static Future<Directory> _defaultRoot() async {
    final cache = await getApplicationCacheDirectory();
    return Directory(path.join(cache.path, rootDirectoryName));
  }

  static Future<int?> _defaultFreeBytes(Directory directory) async {
    final megabytes = await DiskSpacePlus().getFreeDiskSpaceForPath(
      directory.path,
    );
    return megabytes == null ? null : (megabytes * 1024 * 1024).floor();
  }

  static String _secureNonce() {
    final random = Random.secure();
    return List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static bool _validNonce(String value) =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

  static String _normalized(String value) =>
      path.normalize(path.absolute(value));
}

class _PlaybackCacheMarker {
  const _PlaybackCacheMarker(this.nonce);

  final String nonce;
}
