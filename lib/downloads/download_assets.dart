import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

import '../core/diagnostic_log.dart';
import '../data/emby_api.dart';
import 'download_models.dart';

abstract interface class DownloadAssetService {
  Future<OfflineMediaMetadata> downloadAssets(
    DownloadTaskRecord task,
    Directory downloadDirectory, {
    CancelToken? cancelToken,
  });
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
    Directory downloadDirectory, {
    CancelToken? cancelToken,
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
    var streams = task.metadata.mediaStreams;
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
      // Keep the manifest so an incomplete discovery remains repairable.
    }
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
          cancellation: cancellation,
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
    for (final original in streams) {
      _checkCancelled(cancellation);
      final stream = Map<String, dynamic>.from(original);
      final externalSubtitle =
          stream['Type']?.toString().toLowerCase() == 'subtitle' &&
          stream['IsExternal'] == true;
      if (!externalSubtitle) {
        mediaStreams.add(stream);
        continue;
      }
      final rawUrl = stream.remove('DeliveryUrl')?.toString();
      stream.remove('Path');
      stream['OfflineSubtitleState'] = 'missing';
      try {
        final index = _integer(stream['Index']);
        if (index == null || index < 0) {
          throw const FormatException('subtitleIndex');
        }
        final extension = _supportedSubtitleExtension(stream);
        if (extension == null) {
          stream['OfflineSubtitleState'] = 'unsupported';
          mediaStreams.add(stream);
          continue;
        }
        final subtitleFile = File(
          path.join(assetDirectory.path, 'subtitle-$index.$extension'),
        );
        // A saved local file is usable during an interrupted discovery too.
        if (!discovered &&
            rawUrl == subtitleFile.path &&
            await subtitleFile.exists()) {
          _validateSubtitle(await subtitleFile.readAsBytes(), extension);
        } else {
          if (!discovered) throw const FormatException('sourceUnverified');
          // The documented endpoint binds both the source and track when item
          // metadata omits DeliveryUrl. Never guess a different media source.
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
          _requireSameServer(uri);
          await _download(
            uri,
            subtitleFile,
            temporaryDirectory: temporaryDirectory,
            cancellation: cancellation,
            subtitleFormat: extension,
          );
        }
        stream['DeliveryUrl'] = subtitleFile.path;
        stream['OfflineSubtitleState'] = 'available';
      } catch (error, stackTrace) {
        _checkCancelled(cancellation);
        stream['OfflineSubtitleState'] = 'failed';
        DiagnosticLog.instance.warning(
          'download',
          'Offline subtitle failed item=${task.itemId} '
              'index=${stream['Index'] ?? 'unknown'}: ${error.runtimeType}',
        );
        DiagnosticLog.instance.debug('download', stackTrace.toString());
      }
      mediaStreams.add(stream);
    }

    if (await temporaryDirectory.exists() &&
        await temporaryDirectory.list(followLinks: false).isEmpty) {
      await temporaryDirectory.delete();
    }
    return task.metadata.copyWith(
      primaryImagePath: primaryImagePath,
      mediaStreams: mediaStreams,
      subtitleDiscoveryComplete: discovered,
    );
  }

  Future<void> _download(
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
    );
    for (
      var count = 0;
      [301, 302, 303, 307, 308].contains(response.statusCode);
      count++
    ) {
      final location = response.headers.value('location');
      await response.data?.stream.drain<void>();
      if (location == null || count >= 3) {
        throw const FormatException('assetRedirect');
      }
      uri = uri.resolve(location);
      _requireSameServer(uri);
      response = await api.openDownload(
        uri,
        cancelToken: cancelToken,
        followRedirects: false,
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
        _validateSubtitle(await temporary.readAsBytes(), subtitleFormat);
      }
      _checkCancelled(cancellation);
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
    Directory downloadDirectory, {
    CancelToken? cancelToken,
  }) async => task.metadata.copyWith(subtitleDiscoveryComplete: true);
}

String? _supportedSubtitleExtension(Map<String, dynamic> stream) {
  return switch (stream['Codec']?.toString().toLowerCase()) {
    'subrip' => 'srt',
    'ass' || 'ssa' => 'ass',
    'webvtt' || 'vtt' => 'vtt',
    'mov_text' => 'srt',
    'srt' => 'srt',
    _ => null,
  };
}

void _validateSubtitle(List<int> bytes, String format) {
  var text = utf8.decode(bytes, allowMalformed: false).trimLeft();
  if (text.startsWith('\uFEFF')) text = text.substring(1).trimLeft();
  if (text.startsWith('<') ||
      text.toLowerCase().contains('<html') ||
      !(switch (format) {
        'vtt' => text.startsWith('WEBVTT'),
        'ass' => text.contains('[Script Info]') && text.contains('[Events]'),
        _ => RegExp(r'\d{1,2}:\d{2}:\d{2}[,.]\d{3}\s*-->').hasMatch(text),
      })) {
    throw const FormatException('subtitleFormat');
  }
}

int? _integer(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

void _checkCancelled(CancelToken token) {
  if (token.isCancelled) throw token.cancelError!;
}
