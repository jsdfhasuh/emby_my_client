import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

import '../core/diagnostic_log.dart';
import '../data/emby_api.dart';
import 'download_asset_verifier.dart';
import 'download_models.dart';

abstract interface class DownloadAssetService {
  Future<OfflineMediaMetadata> downloadAssets(
    DownloadTaskRecord task,
    Directory downloadDirectory, {
    CancelToken? cancelToken,
  });
}

abstract interface class SubtitleRepairAssetService {
  Future<OfflineMediaMetadata> repairSubtitles(
    DownloadTaskRecord task,
    Directory downloadDirectory, {
    CancelToken? cancelToken,
  });
}

class EmbyDownloadAssetService
    implements DownloadAssetService, SubtitleRepairAssetService {
  EmbyDownloadAssetService(
    this.api, {
    this.maximumAssetBytes = 20 * 1024 * 1024,
  });

  final EmbyApi api;
  final int maximumAssetBytes;

  @override
  Future<OfflineMediaMetadata> downloadAssets(
    DownloadTaskRecord task,
    Directory downloadDirectory, {
    CancelToken? cancelToken,
  }) => _downloadAssets(
    task,
    downloadDirectory,
    cancelToken: cancelToken,
    includeCover: true,
  );

  @override
  Future<OfflineMediaMetadata> repairSubtitles(
    DownloadTaskRecord task,
    Directory downloadDirectory, {
    CancelToken? cancelToken,
  }) => _downloadAssets(
    task,
    downloadDirectory,
    cancelToken: cancelToken,
    includeCover: false,
  );

  Future<OfflineMediaMetadata> _downloadAssets(
    DownloadTaskRecord task,
    Directory downloadDirectory, {
    CancelToken? cancelToken,
    required bool includeCover,
  }) async {
    if (task.id.isEmpty) throw ArgumentError.value(task.id, 'task.id');
    final assetKey = task.id.length <= 16 ? task.id : task.id.substring(0, 16);
    final assetDirectory = Directory(
      path.join(downloadDirectory.path, 'assets', assetKey),
    );
    final temporaryDirectory = Directory(
      path.join(downloadDirectory.path, 'parts', 'assets', assetKey),
    );
    await assetDirectory.create(recursive: true);
    final cancellation = cancelToken ?? CancelToken();
    _checkCancelled(cancellation);
    final previous = await verifyOfflineAssets(
      task.metadata,
      directory: downloadDirectory,
    );
    _checkCancelled(cancellation);
    var streams = previous.mediaStreams;
    var discovered = false;
    try {
      final source = await api.getDownloadMediaSource(
        task.itemId,
        task.mediaSourceId,
        cancelToken: cancellation,
      );
      if (source.size != null &&
          task.expectedBytes != null &&
          source.size != task.expectedBytes) {
        throw const FormatException('downloadSourceChanged');
      }
      streams = source.mediaStreams;
      discovered = true;
    } catch (_) {
      _checkCancelled(cancellation);
      // Existing verified assets remain playable even if discovery is offline.
    }
    var primaryImagePath = previous.primaryImagePath;
    var primaryImageState = previous.primaryImageState;
    final imageTag = previous.primaryImageTag;
    if (includeCover && imageTag != null && imageTag.isNotEmpty) {
      try {
        final imageUri =
            Uri.parse(
              '${api.session.serverUrl}/Items/'
              '${Uri.encodeComponent(task.itemId)}/Images/Primary',
            ).replace(
              queryParameters: {
                'tag': imageTag,
                'maxWidth': '600',
                'quality': '90',
              },
            );
        final imageFile = await _download(
          imageUri,
          File(path.join(assetDirectory.path, 'primary.jpg')),
          temporaryDirectory: temporaryDirectory,
          requireImage: true,
          cancellation: cancellation,
        );
        primaryImagePath = imageFile.path;
        primaryImageState = OfflineAssetState.available;
      } catch (error) {
        _checkCancelled(cancellation);
        if (primaryImagePath == null) {
          primaryImageState = OfflineAssetState.failed;
        }
        DiagnosticLog.instance.warning(
          'download',
          'Offline primary image failed item=${task.itemId}: ${error.runtimeType}',
        );
      }
    }

    final saved = <int, Map<String, dynamic>>{
      for (final stream in previous.mediaStreams)
        if (OfflineMediaMetadata.isExternalSubtitle(stream) &&
            stream['OfflineSubtitleState'] == 'available' &&
            _integer(stream['Index']) != null)
          _integer(stream['Index'])!: stream,
    };
    final mediaStreams = <Map<String, dynamic>>[];
    final seen = <int>{};
    for (final original in streams) {
      _checkCancelled(cancellation);
      var stream = Map<String, dynamic>.from(original);
      if (!OfflineMediaMetadata.isExternalSubtitle(stream)) {
        final index = _integer(stream['Index']);
        final retained = stream['Type']?.toString().toLowerCase() == 'subtitle'
            ? saved[index]
            : null;
        if (retained != null) {
          // A negotiation change to Embed does not remove a verified sidecar
          // or create two playback identities for the same source index.
          seen.add(index!);
          mediaStreams.add(Map<String, dynamic>.from(retained));
        } else {
          mediaStreams.add(stream);
        }
        continue;
      }
      final rawUrl = stream.remove('DeliveryUrl')?.toString();
      stream.remove('Path');
      stream.remove('OfflineSubtitleError');
      final index = _integer(stream['Index']);
      if (index != null) seen.add(index);
      final existing = saved[index];
      stream['OfflineSubtitleState'] = 'missing';
      try {
        if (index == null || index < 0) {
          throw const FormatException('subtitleIndex');
        }
        final extension = offlineSubtitleExtension(stream);
        if (extension == null) {
          stream['OfflineSubtitleState'] = 'unsupported';
          throw const FormatException('unsupportedSubtitle');
        }
        if (!discovered) {
          if (existing == null) throw const FormatException('sourceUnverified');
          stream = Map<String, dynamic>.from(existing);
        } else {
          final uri =
              rawUrl != null &&
                  rawUrl.isNotEmpty &&
                  !OfflineMediaMetadata.isLocalAssetPath(rawUrl)
              ? api.resolveMediaUrl(rawUrl)
              : Uri.parse(
                  '${api.session.serverUrl}/Videos/'
                  '${Uri.encodeComponent(task.itemId)}/'
                  '${Uri.encodeComponent(task.mediaSourceId)}/Subtitles/'
                  '$index/Stream.$extension',
                );
          final subtitleFile = await _download(
            uri,
            File(path.join(assetDirectory.path, 'subtitle-$index.$extension')),
            temporaryDirectory: temporaryDirectory,
            cancellation: cancellation,
            subtitleFormat: extension,
          );
          stream['DeliveryUrl'] = subtitleFile.path;
          stream['Format'] = extension;
          stream['OfflineSubtitleState'] = 'available';
        }
      } catch (error) {
        _checkCancelled(cancellation);
        if (existing != null) {
          stream = Map<String, dynamic>.from(existing);
          stream['OfflineSubtitleError'] = 'refreshFailed';
        } else if (stream['OfflineSubtitleState'] != 'unsupported') {
          stream['OfflineSubtitleState'] = 'failed';
        }
        DiagnosticLog.instance.warning(
          'download',
          'Offline subtitle failed item=${task.itemId} index=$index: ${error.runtimeType}',
        );
      }
      mediaStreams.add(stream);
    }
    // A server removing a track does not delete a user's already saved subtitle.
    for (final entry in saved.entries) {
      if (!seen.contains(entry.key)) mediaStreams.add(entry.value);
    }
    _checkCancelled(cancellation);
    if (await temporaryDirectory.exists() &&
        await temporaryDirectory.list(followLinks: false).isEmpty) {
      await temporaryDirectory.delete();
    }
    return previous.copyWith(
      primaryImagePath: primaryImagePath,
      clearPrimaryImagePath: primaryImagePath == null,
      primaryImageState: primaryImageState,
      mediaStreams: mediaStreams,
      subtitleDiscoveryComplete: discovered,
    );
  }

  Future<File> _download(
    Uri uri,
    File destination, {
    required Directory temporaryDirectory,
    bool requireImage = false,
    required CancelToken cancellation,
    String? subtitleFormat,
  }) async {
    _requireSameServer(uri);
    final cancelToken = CancelToken();
    unawaited(
      cancellation.whenCancel.then((error) {
        if (!cancelToken.isCancelled) cancelToken.cancel('assetCancelled');
      }),
    );
    _checkCancelled(cancellation);
    var response = await api.openDownload(
      uri,
      cancelToken: cancelToken,
      followRedirects: false,
      downloadTaskToken: cancellation,
    );
    for (
      var count = 0;
      [301, 302, 303, 307, 308].contains(response.statusCode);
      count++
    ) {
      final location = response.headers.value('location');
      final close = response.extra['downloadClose'] as Future<void> Function()?;
      if (close != null) {
        await close();
      } else {
        await response.data?.stream.listen((_) {}).cancel();
      }
      if (location == null || count >= 3) {
        throw const FormatException('assetRedirect');
      }
      uri = uri.resolve(location);
      _requireSameServer(uri);
      response = await api.openDownload(
        uri,
        cancelToken: cancelToken,
        followRedirects: false,
        downloadTaskToken: cancellation,
      );
    }
    File? temporary;
    try {
      if (response.statusCode != 200) {
        throw EmbyApiException('附属资源下载失败', statusCode: response.statusCode);
      }
      final contentType = response.headers.value('content-type')?.toLowerCase();
      if (requireImage &&
          contentType != null &&
          !contentType.startsWith('image/')) {
        throw const FormatException('nonImageAsset');
      }
      final contentLength = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (contentLength != null && contentLength > maximumAssetBytes) {
        throw const FormatException('assetTooLarge');
      }
      await destination.parent.create(recursive: true);
      await temporaryDirectory.create(recursive: true);
      temporary = File(
        path.join(
          temporaryDirectory.path,
          '${path.basename(destination.path)}.part',
        ),
      );
      if (await temporary.exists()) await temporary.delete();
      final sink = await temporary.open(mode: FileMode.writeOnly);
      var received = 0;
      final body = response.data;
      if (body == null) throw const FormatException('emptyAsset');
      try {
        await for (final chunk in body.stream) {
          _checkCancelled(cancellation);
          received += chunk.length;
          if (received > maximumAssetBytes) {
            throw const FormatException('assetTooLarge');
          }
          await sink.writeFrom(chunk);
        }
      } finally {
        await sink.close();
      }
      if (received <= 0) throw const FormatException('emptyAsset');
      if (contentLength != null && contentLength != received) {
        throw const FormatException('assetLengthMismatch');
      }
      if (subtitleFormat != null) {
        validateOfflineSubtitle(await temporary.readAsBytes(), subtitleFormat);
      }
      final bytes = await temporary.readAsBytes();
      if (requireImage) await validateOfflineImage(bytes);
      _checkCancelled(cancellation);
      // Content-addressed sidecars preserve old manifests during cancellation,
      // failed refresh, or process death before the new manifest is committed.
      final digest = sha256.convert(bytes).toString().substring(0, 24);
      final published = File(
        path.join(
          destination.parent.path,
          '${path.basenameWithoutExtension(destination.path)}-$digest'
          '${path.extension(destination.path)}',
        ),
      );
      return await temporary.rename(published.path);
    } catch (_) {
      if (!cancelToken.isCancelled) cancelToken.cancel('assetDownloadFailed');
      final partial = temporary;
      if (partial != null) {
        try {
          if (await partial.exists()) await partial.delete();
        } on FileSystemException {
          // The orphan cleanup pass will retry a partial file we cannot remove.
        }
      }
      rethrow;
    } finally {
      final close = response.extra['downloadClose'] as Future<void> Function()?;
      await close?.call();
    }
  }

  void _requireSameServer(Uri uri) {
    final server = Uri.parse(api.session.serverUrl);
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.scheme.toLowerCase() != server.scheme.toLowerCase() ||
        uri.host.toLowerCase() != server.host.toLowerCase() ||
        uri.port != server.port) {
      throw const FormatException('crossOriginAsset');
    }
  }
}

class NoopDownloadAssetService implements DownloadAssetService {
  const NoopDownloadAssetService();

  @override
  Future<OfflineMediaMetadata> downloadAssets(
    DownloadTaskRecord task,
    Directory downloadDirectory, {
    CancelToken? cancelToken,
  }) async => task.metadata.copyWith(subtitleDiscoveryComplete: true);
}

int? _integer(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

void _checkCancelled(CancelToken token) {
  if (token.isCancelled) throw token.cancelError!;
}
