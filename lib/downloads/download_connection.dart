import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hysteria2/hysteria2.dart';

import '../core/server_scope.dart';
import '../data/session_store.dart';
import '../models/emby_models.dart';
import 'download_http_client.dart';

enum DownloadConnectionMode { direct, hysteria2 }

class DownloadConnectionException implements Exception {
  const DownloadConnectionException(this.code);
  final String code;
  @override
  String toString() => 'Download connection failed ($code)';
}

bool _profileHost(String host) {
  if (host.isEmpty || host.length > 253) return false;
  if (InternetAddress.tryParse(host) != null) return true;
  final dns = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
  return dns
      .split('.')
      .every(
        (label) =>
            label.isNotEmpty &&
            label.length <= 63 &&
            !label.startsWith('-') &&
            !label.endsWith('-') &&
            RegExp(r'^[A-Za-z0-9-]+$').hasMatch(label),
      );
}

class Hysteria2Profile {
  const Hysteria2Profile({
    required this.host,
    required this.port,
    required this.auth,
    required this.sni,
    this.obfsPassword,
  });

  factory Hysteria2Profile.parse(String value) {
    try {
      if (value.length > 16 * 1024) throw const FormatException();
      final uri = Uri.parse(value.trim());
      if (!const {'hysteria2', 'hy2'}.contains(uri.scheme.toLowerCase()) ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.userInfo.isEmpty ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(uri.host)) {
        throw const FormatException();
      }
      final query = uri.queryParametersAll;
      const allowed = {'sni', 'insecure', 'obfs', 'obfs-password'};
      if (query.keys.any((key) => !allowed.contains(key)) ||
          query.values.any((values) => values.length != 1)) {
        throw const FormatException();
      }
      final insecure = uri.queryParameters['insecure'];
      if (insecure != null && insecure != '0' && insecure != 'false') {
        throw const FormatException();
      }
      final obfs = uri.queryParameters['obfs'];
      final obfsPassword = uri.queryParameters['obfs-password'];
      if ((obfs != null && obfs != 'salamander') ||
          (obfs == null && obfsPassword != null) ||
          (obfs == 'salamander' &&
              (obfsPassword == null || obfsPassword.isEmpty))) {
        throw const FormatException();
      }
      // Custom schemes normalize an explicit :0 away. Parse the original
      // authority with HTTPS's default port to distinguish :0 from omission.
      final raw = value.trim();
      final port = Uri.parse(
        'https:${raw.substring(raw.indexOf(':') + 1)}',
      ).port;
      final auth = Uri.decodeComponent(uri.userInfo);
      final sni = uri.queryParameters['sni'] ?? uri.host;
      if (port < 1 ||
          port > 65535 ||
          auth.isEmpty ||
          utf8.encode(auth).length > 4096 ||
          sni.isEmpty ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(auth)) {
        throw const FormatException();
      }
      if (RegExp(r'[\s\x00-\x1f\x7f/:@]').hasMatch(sni) &&
          InternetAddress.tryParse(sni)?.type != InternetAddressType.IPv6) {
        throw const FormatException();
      }
      if (!_profileHost(uri.host) ||
          !_profileHost(sni) ||
          (obfsPassword != null &&
              (utf8.encode(obfsPassword).length < 4 ||
                  utf8.encode(obfsPassword).length > 4096))) {
        throw const FormatException();
      }
      return Hysteria2Profile(
        host: uri.host,
        port: port,
        auth: auth,
        sni: sni,
        obfsPassword: obfsPassword,
      );
    } catch (_) {
      throw const FormatException('连接链接无效、包含不支持的参数，或关闭了证书校验');
    }
  }

  factory Hysteria2Profile.fromJson(Map<String, dynamic> json) {
    final host = json['host'] as String;
    final port = json['port'] as int;
    if (port < 1 || port > 65535) throw const FormatException();
    final auth = json['auth'] as String;
    final sni = json['sni'] as String;
    final obfsPassword = json['obfsPassword'] as String?;
    return Hysteria2Profile.parse(
      Uri(
        scheme: 'hysteria2',
        host: host,
        port: port,
        userInfo: Uri.encodeComponent(auth),
        queryParameters: {
          'sni': sni,
          if (obfsPassword != null) ...{
            'obfs': 'salamander',
            'obfs-password': obfsPassword,
          },
        },
      ).toString(),
    );
  }

  final String host;
  final int port;
  final String auth;
  final String sni;
  final String? obfsPassword;
  String get label => '${host.contains(':') ? '[$host]' : host}:$port';
  Map<String, Object?> toNativeConfig() => {
    'host': host,
    'port': port,
    'auth': auth,
    'sni': sni,
    if (obfsPassword != null) 'obfsPassword': obfsPassword,
  };
  @override
  String toString() => 'Hysteria2Profile';
}

class DownloadConnectionSettings {
  const DownloadConnectionSettings({
    this.mode = DownloadConnectionMode.direct,
    this.profile,
  });
  final DownloadConnectionMode mode;
  final Hysteria2Profile? profile;
  DownloadConnectionSettings copyWith({
    DownloadConnectionMode? mode,
    Hysteria2Profile? profile,
    bool clearProfile = false,
  }) => DownloadConnectionSettings(
    mode: mode ?? this.mode,
    profile: clearProfile ? null : profile ?? this.profile,
  );
}

class DownloadConnectionStatus {
  const DownloadConnectionStatus({
    this.downloads = 0,
    this.playbacks = 0,
    this.editing = false,
  });
  final int downloads;
  final int playbacks;
  final bool editing;
  bool get isBusy => downloads > 0 || playbacks > 0 || editing;
}

class DownloadConnectionTestResult {
  const DownloadConnectionTestResult({
    required this.handshakeSucceeded,
    required this.serverReachable,
    this.errorCode,
    this.handshakeTime,
    this.serverTime,
  });
  final bool handshakeSucceeded;
  final bool serverReachable;
  final String? errorCode;
  final Duration? handshakeTime;
  final Duration? serverTime;
}

class DownloadConnectionRepository {
  DownloadConnectionRepository({SessionStorage? storage})
    : _storage = storage ?? _ConnectionStorage();
  final SessionStorage _storage;
  String _key(ServerScope scope) =>
      'download_connection_v1_${sha256.convert(utf8.encode(scope.databaseKey))}';

  Future<DownloadConnectionSettings> load(ServerScope scope) async {
    try {
      final raw = await _storage.read(_key(scope));
      if (raw == null) return const DownloadConnectionSettings();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final mode = DownloadConnectionMode.values.byName(json['mode'] as String);
      final profile = json['profile'] == null
          ? null
          : Hysteria2Profile.fromJson(json['profile'] as Map<String, dynamic>);
      if (mode == DownloadConnectionMode.hysteria2 && profile == null) {
        throw const FormatException();
      }
      return DownloadConnectionSettings(mode: mode, profile: profile);
    } catch (_) {
      throw const DownloadConnectionException('configurationUnavailable');
    }
  }

  Future<void> save(
    ServerScope scope,
    DownloadConnectionSettings settings,
  ) async {
    if (settings.mode == DownloadConnectionMode.hysteria2 &&
        settings.profile == null) {
      throw const DownloadConnectionException('configurationUnavailable');
    }
    try {
      await _storage.write(
        _key(scope),
        jsonEncode({
          'mode': settings.mode.name,
          if (settings.profile != null)
            'profile': settings.profile!.toNativeConfig(),
        }),
      );
    } catch (_) {
      throw const DownloadConnectionException('configurationUnavailable');
    }
  }

  Future<void> delete(ServerScope scope) async {
    try {
      await _storage.delete(_key(scope));
    } catch (_) {
      throw const DownloadConnectionException('configurationUnavailable');
    }
  }
}

class _ConnectionStorage implements SessionStorage {
  final _storage = const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class DownloadRouteLease {
  DownloadRouteLease({
    required this.mode,
    this.proxy,
    required Future<void> Function() release,
  }) : _release = release;
  final DownloadConnectionMode mode;
  final DownloadProxy? proxy;
  final Future<void> Function() _release;
  Future<void>? _closing;
  Future<void> close() => _closing ??= _release();
}

class DownloadConnectionManager {
  DownloadConnectionManager({
    DownloadConnectionRepository? repository,
    Hysteria2Platform? platform,
    bool? supportedOverride,
  }) : _repository = repository ?? DownloadConnectionRepository(),
       _platform = platform ?? Hysteria2Platform(),
       supported = supportedOverride ?? Platform.isAndroid;
  static final instance = DownloadConnectionManager();
  final DownloadConnectionRepository _repository;
  final Hysteria2Platform _platform;
  final bool supported;

  Future<DownloadConnectionSettings> load(ServerScope scope) =>
      _repository.load(scope);

  Future<String> _acquire(ServerScope scope, String kind) async {
    try {
      return await _platform.acquire(scope: scope.databaseKey, kind: kind);
    } on PlatformException catch (error) {
      throw DownloadConnectionException(
        error.code == 'busy' || error.code == 'configBusy'
            ? 'configBusy'
            : 'tunnelUnavailable',
      );
    } catch (_) {
      throw const DownloadConnectionException('tunnelUnavailable');
    }
  }

  Future<void> _release(String id) => _platform.release(id);

  Future<T> _edit<T>(ServerScope scope, Future<T> Function() action) async {
    if (!supported) throw const DownloadConnectionException('unsupported');
    final lease = await _acquire(scope, 'configuration');
    try {
      return await action();
    } finally {
      await _release(lease);
    }
  }

  Future<void> save(ServerScope scope, DownloadConnectionSettings settings) =>
      _edit(scope, () => _repository.save(scope, settings));
  Future<void> delete(ServerScope scope) =>
      _edit(scope, () => _repository.delete(scope));

  Future<DownloadConnectionStatus> status() async {
    if (!supported) return const DownloadConnectionStatus();
    try {
      final result = await _platform.status();
      return DownloadConnectionStatus(
        downloads: result['downloads'] as int? ?? 0,
        playbacks: result['playbacks'] as int? ?? 0,
        editing: result['editing'] as bool? ?? false,
      );
    } catch (_) {
      throw const DownloadConnectionException('tunnelUnavailable');
    }
  }

  Future<DownloadProxy> _connect(String lease, Hysteria2Profile profile) async {
    try {
      final result = await _platform.connect(
        leaseId: lease,
        config: profile.toNativeConfig(),
      );
      final proxy = DownloadProxy(
        host: result['host'] as String,
        port: result['port'] as int,
        username: result['username'] as String,
        password: result['password'] as String,
      );
      if (proxy.host != '127.0.0.1' ||
          proxy.port < 1 ||
          proxy.port > 65535 ||
          proxy.username.isEmpty ||
          proxy.password.isEmpty) {
        throw const FormatException();
      }
      return proxy;
    } catch (_) {
      throw const DownloadConnectionException('tunnelUnavailable');
    }
  }

  Future<DownloadRouteLease> acquireDownload(ServerScope scope) async {
    if (!supported) {
      return DownloadRouteLease(
        mode: DownloadConnectionMode.direct,
        release: () async {},
      );
    }
    final lease = await _acquire(scope, 'download');
    try {
      // Read after acquiring the native gate, so an edit cannot race this snapshot.
      final settings = await load(scope);
      final proxy = settings.mode == DownloadConnectionMode.hysteria2
          ? await _connect(lease, settings.profile!)
          : null;
      return DownloadRouteLease(
        mode: settings.mode,
        proxy: proxy,
        release: () => _release(lease),
      );
    } catch (_) {
      await _release(lease);
      rethrow;
    }
  }

  Future<DownloadRouteLease?> acquirePlayback() async {
    if (!supported) return null;
    final lease = await _acquire(
      const ServerScope(serverId: 'playback', userId: 'playback'),
      'playback',
    );
    return DownloadRouteLease(
      mode: DownloadConnectionMode.direct,
      release: () => _release(lease),
    );
  }

  Future<DownloadConnectionTestResult> test(
    EmbySession session,
    Hysteria2Profile profile,
  ) async {
    if (!supported) throw const DownloadConnectionException('unsupported');
    final lease = await _acquire(
      ServerScope.fromSession(session),
      'configuration',
    );
    final clock = Stopwatch()..start();
    var handshake = false;
    Duration? handshakeTime;
    DownloadHttpClient? client;
    try {
      final proxy = await _connect(lease, profile);
      handshake = true;
      handshakeTime = clock.elapsed;
      client = DownloadHttpClient(
        server: Uri.parse(session.serverUrl),
        headers: {'X-Emby-Token': session.accessToken},
        proxy: proxy,
      );
      clock.reset();
      final response = await client.open(
        Uri.parse('${session.serverUrl}/System/Info/Public'),
        cancelToken: CancelToken(),
      );
      await response.discard();
      return DownloadConnectionTestResult(
        handshakeSucceeded: true,
        serverReachable: response.statusCode == 200,
        handshakeTime: handshakeTime,
        serverTime: clock.elapsed,
        errorCode: response.statusCode == 200 ? null : 'serverUnavailable',
      );
    } catch (_) {
      return DownloadConnectionTestResult(
        handshakeSucceeded: handshake,
        serverReachable: false,
        handshakeTime: handshakeTime,
        errorCode: handshake ? 'serverUnavailable' : 'tunnelUnavailable',
      );
    } finally {
      client?.close();
      await _release(lease);
    }
  }
}
