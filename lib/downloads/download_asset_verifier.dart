import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'download_models.dart';
import 'download_path_policy.dart';

const maximumOfflineAssetBytes = 20 * 1024 * 1024;

/// Format describes the delivered sidecar; Codec identifies the source track.
/// An explicit unsupported format must not fall back to a guessed conversion.
String? offlineSubtitleExtension(Map<String, dynamic> stream) {
  final format = stream['Format']?.toString().trim().toLowerCase();
  if (format != null && format.isNotEmpty) {
    return switch (format) {
      'subrip' || 'srt' => 'srt',
      'ass' => 'ass',
      'ssa' => 'ssa',
      'webvtt' || 'vtt' => 'vtt',
      _ => null,
    };
  }
  return switch (stream['Codec']?.toString().trim().toLowerCase()) {
    'subrip' || 'srt' || 'mov_text' => 'srt',
    'ass' || 'ssa' => 'ass',
    'webvtt' || 'vtt' => 'vtt',
    _ => null,
  };
}

void validateOfflineSubtitle(List<int> bytes, String format) {
  if (bytes.isEmpty || bytes.length > maximumOfflineAssetBytes) {
    throw const FormatException('subtitleSize');
  }
  var text = utf8.decode(bytes, allowMalformed: false).trimLeft();
  if (text.startsWith('\uFEFF')) text = text.substring(1).trimLeft();
  if (text.startsWith('<') ||
      text.toLowerCase().contains('<html') ||
      !(switch (format) {
        'vtt' => text.startsWith('WEBVTT'),
        'ass' ||
        'ssa' => text.contains('[Script Info]') && text.contains('[Events]'),
        _ => RegExp(r'\d{1,2}:\d{2}:\d{2}[,.]\d{3}\s*-->').hasMatch(text),
      })) {
    throw const FormatException('subtitleFormat');
  }
}

Future<void> validateOfflineImage(List<int> bytes) async {
  if (bytes.isEmpty || bytes.length > maximumOfflineAssetBytes) {
    throw const FormatException('imageSize');
  }
  final codec = await ui.instantiateImageCodec(
    Uint8List.fromList(bytes),
    targetWidth: 1,
    targetHeight: 1,
  );
  try {
    final frame = await codec.getNextFrame();
    frame.image.dispose();
  } finally {
    codec.dispose();
  }
}

/// Rechecks local sidecars without network access. Old manifests with local
/// paths but no state are upgraded; remote paths are never passed to playback.
Future<OfflineMediaMetadata> verifyOfflineAssets(
  OfflineMediaMetadata metadata, {
  Directory? directory,
}) async {
  final policy = directory == null ? null : DownloadPathPolicy(directory);
  Future<File?> localFile(Object? stored) async {
    if (stored is! String ||
        stored.isEmpty ||
        stored.contains('://') ||
        stored.contains('?')) {
      return null;
    }
    if (policy == null && !OfflineMediaMetadata.isLocalAssetPath(stored)) {
      return null;
    }
    final file = File(policy?.resolveStoredPath(stored) ?? stored);
    if (policy != null &&
        (!policy.contains(file.path) ||
            !await policy.resolvesWithinRoot(file))) {
      return null;
    }
    return file;
  }

  final streams = <Map<String, dynamic>>[];
  for (final original in metadata.mediaStreams) {
    final stream = Map<String, dynamic>.from(original);
    if (!OfflineMediaMetadata.isExternalSubtitle(stream)) {
      streams.add(stream);
      continue;
    }
    stream.remove('Path');
    final stored = stream.remove('DeliveryUrl');
    final extension = offlineSubtitleExtension(stream);
    if (extension == null) {
      stream['OfflineSubtitleState'] = 'unsupported';
    } else {
      try {
        final file = await localFile(stored);
        if (file == null || !await file.exists()) {
          // Preserve a meaningful transfer failure when there is no local file.
          if (stream['OfflineSubtitleState'] != 'failed') {
            stream['OfflineSubtitleState'] = 'missing';
          }
        } else {
          final length = await file.length();
          if (length <= 0 || length > maximumOfflineAssetBytes) {
            throw const FormatException('subtitleSize');
          }
          validateOfflineSubtitle(await file.readAsBytes(), extension);
          stream['DeliveryUrl'] = file.path;
          stream['OfflineSubtitleState'] = 'available';
        }
      } catch (_) {
        stream['OfflineSubtitleState'] = 'failed';
      }
    }
    streams.add(stream);
  }

  String? imagePath;
  var imageState = metadata.primaryImageState;
  try {
    final image = await localFile(metadata.primaryImagePath);
    if (image != null && await image.exists()) {
      final length = await image.length();
      if (length <= 0 || length > maximumOfflineAssetBytes) {
        throw const FormatException('imageSize');
      }
      await validateOfflineImage(await image.readAsBytes());
      imagePath = image.path;
      imageState = OfflineAssetState.available;
    } else if (metadata.primaryImagePath != null) {
      imageState = OfflineAssetState.missing;
    } else if (imageState != OfflineAssetState.failed &&
        imageState != OfflineAssetState.missing) {
      imageState = metadata.primaryImageTag?.isNotEmpty == true
          ? OfflineAssetState.missing
          : OfflineAssetState.notProvided;
    }
  } catch (_) {
    imageState = OfflineAssetState.failed;
  }
  return metadata.copyWith(
    mediaStreams: streams,
    primaryImagePath: imagePath,
    clearPrimaryImagePath: imagePath == null,
    primaryImageState: imageState,
  );
}
