import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

const releaseRepository = 'jsdfhasuh/emby_my_client';
const releasePage = 'https://github.com/$releaseRepository/releases/latest';
const maxApkBytes = 512 * 1024 * 1024;
const androidVersionStride = 10000;

void _throwIfCancelled(CancelToken cancel) {
  if (cancel.isCancelled) throw const UpdateFailure('cancelled');
}

class UpdateFailure implements Exception {
  const UpdateFailure(this.code);
  final String code;

  String get message => switch (code) {
    'cancelled' => '已取消。可以重新检查或下载。',
    'network' => '无法连接更新服务，请检查网络后重试。',
    'rate_limit' => '更新服务暂时限制请求，请稍后重试。',
    'checksum' => '安装包校验失败，文件已丢弃。请重新下载。',
    'size' => '安装包大小不符或超出限制，文件已丢弃。',
    'signature' => '安装包签名与当前应用不兼容，无法覆盖升级。请保留当前应用和数据，等待兼容签名的版本。',
    'downgrade' => '安装包版本没有高于当前版本，已阻止安装。',
    'package' => '安装包身份或版本与所选 Release 不符，已阻止安装。',
    'unsupported' => '没有适合此设备的安装包。',
    'metadata' => '无法读取当前应用版本，请重新打开此页面。',
    'storage' => '无法保存安装包，请检查可用存储空间后重试。',
    'installer' => '无法打开系统安装程序，请稍后重试。',
    _ => '更新信息无效或不完整，请稍后重试。',
  };
}

enum UpdatePlatform { android, ios, unsupported }

class InstalledApp {
  const InstalledApp({
    required this.version,
    required this.buildNumber,
    required this.platform,
    this.abis = const [],
  });
  final String version;
  final int buildNumber;
  final UpdatePlatform platform;
  final List<String> abis;

  // Legacy Android builds used ABI offsets around base code 1. Only the
  // documented new versionName + code pair identifies a release reliably.
  int? get releaseNumber {
    final match = RegExp(r'^1\.0\.([1-9][0-9]*)$').firstMatch(version);
    if (match == null) return null;
    final number = int.tryParse(match[1]!);
    if (number == null) return null;
    if (platform == UpdatePlatform.ios && buildNumber == number) return number;
    if (platform == UpdatePlatform.android &&
        buildNumber ~/ androidVersionStride == number) {
      return number;
    }
    return null;
  }
}

class ReleaseAsset {
  const ReleaseAsset(this.name, this.url, this.size);
  final String name;
  final Uri url;
  final int size;
}

class AppRelease {
  const AppRelease({
    required this.number,
    required this.notes,
    required this.assets,
  });
  final int number;
  final String notes;
  final Map<String, ReleaseAsset> assets;
  String get tag => 'build-$number';
  String get page => 'https://github.com/$releaseRepository/releases/tag/$tag';
  bool isNewerThan(InstalledApp app) =>
      app.releaseNumber == null || number > app.releaseNumber!;

  ReleaseAsset apkFor(InstalledApp app) {
    if (app.platform != UpdatePlatform.android) {
      throw const UpdateFailure('unsupported');
    }
    for (final abi in app.abis) {
      if (!const ['arm64-v8a', 'armeabi-v7a', 'x86_64'].contains(abi)) continue;
      final asset = assets['app-$abi-debug.apk'];
      if (asset != null) return asset;
    }
    if (app.abis.any(const ['arm64-v8a', 'armeabi-v7a', 'x86_64'].contains)) {
      final universal = assets['app-debug.apk'];
      if (universal != null) return universal;
    }
    throw const UpdateFailure('unsupported');
  }

  factory AppRelease.parse(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['draft'] != false ||
        value['prerelease'] != false) {
      throw const UpdateFailure('release');
    }
    final tag = value['tag_name'];
    final match = tag is String
        ? RegExp(r'^build-([1-9][0-9]{0,5})$').firstMatch(tag)
        : null;
    if (match == null) throw const UpdateFailure('release');
    final number = int.parse(match[1]!);
    if (number > 209999) throw const UpdateFailure('release');
    if (value['assets'] is! List) throw const UpdateFailure('release');
    final assets = <String, ReleaseAsset>{};
    for (final item in value['assets'] as List) {
      if (item is! Map<String, dynamic>) throw const UpdateFailure('release');
      final name = item['name'];
      if (name is! String ||
          !const {
            'app-debug.apk',
            'app-arm64-v8a-debug.apk',
            'app-armeabi-v7a-debug.apk',
            'app-x86_64-debug.apk',
            'SHA256SUMS.txt',
          }.contains(name)) {
        continue;
      }
      final size = item['size'];
      final expected =
          'https://github.com/$releaseRepository/releases/download/$tag/$name';
      if (item['browser_download_url'] != expected ||
          assets.containsKey(name) ||
          size is! int ||
          size <= 0 ||
          size > (name == 'SHA256SUMS.txt' ? 65536 : maxApkBytes)) {
        throw const UpdateFailure('release');
      }
      assets[name] = ReleaseAsset(name, Uri.parse(expected), size);
    }
    final notes = value['body'];
    if (notes != null && notes is! String) throw const UpdateFailure('release');
    return AppRelease(
      number: number,
      notes: notes as String? ?? '',
      assets: assets,
    );
  }
}

class VerifiedDownload {
  const VerifiedDownload(this.file, this.sha256, this.size, this.releaseNumber);
  final File file;
  final String sha256;
  final int size;
  final int releaseNumber;
  Map<String, Object> get arguments => {
    'path': file.path,
    'sha256': sha256,
    'size': size,
    'release': releaseNumber,
  };
  Future<void> discard() async {
    if (await file.parent.exists()) await file.parent.delete(recursive: true);
  }
}

abstract interface class UpdateSource {
  Future<AppRelease> latest(CancelToken cancel);
  Future<VerifiedDownload> download(
    AppRelease release,
    ReleaseAsset asset,
    CancelToken cancel,
    void Function(int received, int total) progress,
  );
  void close();
}

/// A dedicated public client. Never accepts an Emby client, session or headers.
class GitHubUpdateSource implements UpdateSource {
  GitHubUpdateSource({
    HttpClientAdapter? adapter,
    Future<Directory> Function()? cache,
  }) : _cache = cache ?? getTemporaryDirectory {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }
  final Future<Directory> Function() _cache;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: false,
      validateStatus: (_) => true,
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'emo-emby-updater',
      },
    ),
  );

  Future<ResponseBody> _get(Uri uri, CancelToken cancel) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.port != 443 ||
          !const {
            'api.github.com',
            'github.com',
            'release-assets.githubusercontent.com',
            'objects.githubusercontent.com',
          }.contains(uri.host)) {
        throw const UpdateFailure('release');
      }
      final response = await _dio.getUri<ResponseBody>(
        uri,
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancel,
      );
      final body = response.data;
      if (body == null) throw const UpdateFailure('network');
      if (response.statusCode == 200) return body;
      await body.stream.listen(null).cancel();
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw const UpdateFailure('rate_limit');
      }
      if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value('location');
        if (location == null) throw const UpdateFailure('release');
        uri = uri.resolve(location);
        continue;
      }
      throw const UpdateFailure('network');
    }
    throw const UpdateFailure('release');
  }

  Future<String> _text(Uri uri, int limit, CancelToken cancel) async {
    final body = await _get(uri, cancel);
    final bytes = <int>[];
    await for (final chunk in body.stream) {
      _throwIfCancelled(cancel);
      if (bytes.length + chunk.length > limit) {
        throw const UpdateFailure('release');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  @override
  Future<AppRelease> latest(CancelToken cancel) async {
    try {
      final json = await _text(
        Uri.parse(
          'https://api.github.com/repos/$releaseRepository/releases/latest',
        ),
        1024 * 1024,
        cancel,
      );
      return AppRelease.parse(jsonDecode(json));
    } catch (error) {
      throw _failure(error);
    }
  }

  static String checksumFor(String manifest, String filename) {
    final records = <String, String>{};
    for (final line in const LineSplitter().convert(manifest)) {
      if (line.isEmpty) continue;
      final match = RegExp(
        r'^([0-9a-fA-F]{64}) [ *]([A-Za-z0-9_.-]+)$',
      ).firstMatch(line);
      if (match == null || records.containsKey(match[2])) {
        throw const UpdateFailure('checksum');
      }
      records[match[2]!] = match[1]!.toLowerCase();
    }
    return records[filename] ?? (throw const UpdateFailure('checksum'));
  }

  @override
  Future<VerifiedDownload> download(
    AppRelease release,
    ReleaseAsset asset,
    CancelToken cancel,
    void Function(int, int) progress,
  ) async {
    Directory? directory;
    IOSink? sink;
    try {
      if (!identical(release.assets[asset.name], asset)) {
        throw const UpdateFailure('release');
      }
      final sums = release.assets['SHA256SUMS.txt'];
      if (sums == null) throw const UpdateFailure('checksum');
      final expected = checksumFor(
        await _text(sums.url, 65536, cancel),
        asset.name,
      );
      final root = Directory('${(await _cache()).path}/app_updates');
      await root.create(recursive: true);
      // Only this updater's private cache is touched. Keep recently handed-off
      // packages available to the system installer, prune abandoned old ones.
      await for (final entry in root.list(followLinks: false)) {
        if (entry is Directory &&
            entry.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('download-') &&
            DateTime.now().difference((await entry.stat()).modified).inHours >=
                24) {
          await entry.delete(recursive: true);
        }
      }
      directory = await root.createTemp('download-');
      final file = File('${directory.path}/update.apk');
      sink = file.openWrite();
      final body = await _get(asset.url, cancel);
      var received = 0;
      await for (final chunk in body.stream) {
        _throwIfCancelled(cancel);
        received += chunk.length;
        if (received > asset.size || received > maxApkBytes) {
          throw const UpdateFailure('size');
        }
        sink.add(chunk);
        await sink.flush();
        progress(received, asset.size);
      }
      await sink.close();
      sink = null;
      _throwIfCancelled(cancel);
      if (received != asset.size) throw const UpdateFailure('size');
      final actual = (await sha256.bind(file.openRead()).first).toString();
      _throwIfCancelled(cancel);
      if (actual != expected) throw const UpdateFailure('checksum');
      return VerifiedDownload(file, actual, received, release.number);
    } catch (error) {
      try {
        await sink?.close();
      } catch (_) {
        /* Cleanup must still run. */
      }
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
      throw _failure(error);
    }
  }

  UpdateFailure _failure(Object error) {
    if (error is UpdateFailure) return error;
    if (error is DioException) {
      return UpdateFailure(
        CancelToken.isCancel(error) ? 'cancelled' : 'network',
      );
    }
    if (error is FileSystemException) return const UpdateFailure('storage');
    if (error is FormatException) return const UpdateFailure('release');
    return const UpdateFailure('network');
  }

  @override
  void close() => _dio.close(force: true);
}
