import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/emby_models.dart';
import '../platform/platform_capabilities.dart';

abstract interface class SessionStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class _FlutterSecureSessionStorage implements SessionStorage {
  _FlutterSecureSessionStorage(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class SessionStore {
  SessionStore({
    FlutterSecureStorage? storage,
    SessionStorage? sessionStorage,
    PlatformCapabilities? capabilities,
  }) : _storage =
           sessionStorage ??
           _FlutterSecureSessionStorage(
             storage ?? const FlutterSecureStorage(),
           ),
       _capabilities = capabilities ?? PlatformCapabilities.current();

  static const _sessionKey = 'emby_session_v1';
  static const _deviceIdKey = 'emby_device_id_v1';

  final SessionStorage _storage;
  final PlatformCapabilities _capabilities;

  Future<EmbySession?> loadSession() async {
    final value = await _storage.read(_sessionKey);
    if (value == null || value.isEmpty) return null;
    try {
      return EmbySession.fromJson(
        Map<String, dynamic>.from(jsonDecode(value) as Map),
      );
    } catch (_) {
      await clearSession();
      return null;
    }
  }

  Future<void> saveSession(EmbySession session) =>
      _storage.write(_sessionKey, jsonEncode(session.toJson()));

  Future<void> clearSession() => _storage.delete(_sessionKey);

  Future<String> getOrCreateDeviceId() async {
    final existing = await _storage.read(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated =
        '${_capabilities.deviceIdPrefix}${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    await _storage.write(_deviceIdKey, generated);
    return generated;
  }
}
