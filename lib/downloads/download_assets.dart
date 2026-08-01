import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

import '../core/diagnostic_log.dart';
import '../data/emby_api.dart';
import 'download_models.dart';

abstract interface class DownloadAssetService {
  Future<OfflineMediaMetadata> downloadAssets(
    DownloadTaskRecord task,
    Directory downloadDirectory,
  );
}

class EmbyDownloadAssetService implements DownloadAssetService {
  EmbyDownloadAssetService(
    this.api, {
    this.maximumAssetBytes = 20 * 1024 * 1024,
  });

  final EmbyApi api;
  final int maximumAssetBytes;

  @override
  Future<OfflineMediaMetadata> downloadAssets(
    DownloadTaskRecord task,
    Directory downloadDirectory,
  ) async {
    if (task.id.isEmpty) throw ArgumentError.value(task.id, 'task.id');
    final assetKey = task.id.length <= 16 ? task.id : task.id.substring(0, 16);
    final assetDirectory = Directory(
      path.join(downloadDirectory.path, 'assets', assetKey),
    );
    final temporaryDirectory = Directory(
      path.join(downloadDirectory.path, 'parts', 'assets', assetKey),
    );
    await assetDirectory.create(recursive: true);
    var primaryImagePath = task.metadata.primaryImagePath;
    final imageTag = task.metadata.primaryImageTag;
    if (imageTag != null && imageTag.isNotEmpty) {
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
        final imageFile = File(path.join(assetDirectory.path, 'primary.jpg'));
        await _download(
          imageUri,
          imageFile,
          temporaryDirectory: temporaryDirectory,
          requireImage: true,
        );
        primaryImagePath = imageFile.path;
      } catch (error, stackTrace) {
        DiagnosticLog.instance.warning(
          'download',
          'Offline primary image failed item=${task.itemId}: '
              '${error.runtimeType}',
        );
        DiagnosticLog.instance.debug('download', stackTrace.toString());
      }
    }

    final mediaStreams = <Map<String, dynamic>>[];
    for (final original in task.metadata.mediaStreams) {
      final stream = Map<String, dynamic>.from(original);
      final externalSubtitle =
          stream['Type']?.toString().toLowerCase() == 'subtitle' &&
          stream['IsExternal'] == true;
      if (!externalSubtitle) {
        mediaStreams.add(stream);
        continue;
      }
      final rawUrl = stream['DeliveryUrl']?.toString();
      if (rawUrl == null || rawUrl.isEmpty) continue;
      try {
        final uri = api.resolveMediaUrl(rawUrl);
        _requireSameServer(uri);
        final index = _integer(stream['Index']) ?? mediaStreams.length;
        final extension = _subtitleExtension(stream, uri);
        final subtitleFile = File(
          path.join(assetDirectory.path, 'subtitle-$index.$extension'),
        );
        await _download(
          uri,
          subtitleFile,
          temporaryDirectory: temporaryDirectory,
        );
        stream['DeliveryUrl'] = subtitleFile.path;
        mediaStreams.add(stream);
      } catch (error, stackTrace) {
        DiagnosticLog.instance.warning(
          'download',
          'Offline subtitle failed item=${task.itemId} '
              'index=${stream['Index'] ?? 'unknown'}: ${error.runtimeType}',
        );
        DiagnosticLog.instance.debug('download', stackTrace.toString());
      }
    }

    if (await temporaryDirectory.exists() &&
        await temporaryDirectory.list(followLinks: false).isEmpty) {
      await temporaryDirectory.delete();
    }
    return task.metadata.copyWith(
      primaryImagePath: primaryImagePath,
      mediaStreams: mediaStreams,
    );
  }

  Future<void> _download(
    Uri uri,
    File destination, {
    required Directory temporaryDirectory,
    bool requireImage = false,
  }) async {
    _requireSameServer(uri);
    final cancelToken = CancelToken();
    final response = await api.openDownload(uri, cancelToken: cancelToken);
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
      if (await destination.exists()) await destination.delete();
      await temporary.rename(destination.path);
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
    Directory downloadDirectory,
  ) async => task.metadata;
}

String _subtitleExtension(Map<String, dynamic> stream, Uri uri) {
  final fromPath = path.extension(uri.path).replaceFirst('.', '').toLowerCase();
  if (RegExp(r'^[a-z0-9]{1,8}$').hasMatch(fromPath)) return fromPath;
  return switch (stream['Codec']?.toString().toLowerCase()) {
    'subrip' => 'srt',
    'ass' || 'ssa' => 'ass',
    'webvtt' || 'vtt' => 'vtt',
    'mov_text' => 'srt',
    final codec
        when codec != null && RegExp(r'^[a-z0-9]{1,8}$').hasMatch(codec) =>
      codec,
    _ => 'srt',
  };
}

int? _integer(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
