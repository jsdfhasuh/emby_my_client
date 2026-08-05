import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';

import '../core/diagnostic_log.dart';
import '../core/sign_in_diagnostics.dart';
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
    final value = await readSession();
    if (value == null || value.isEmpty) return null;
    try {
      return EmbySession.fromJson(
        Map<String, dynamic>.from(jsonDecode(value) as Map),
      );
    } catch (_) {
      DiagnosticLog.instance.safeStage(
        component: SafeDiagnosticComponent.storage,
        event: SafeDiagnosticEvent.signInStageStart,
        stage: SignInStage.sessionDelete,
        reason: SafeDiagnosticReason.unknown,
        errorType: SafeDiagnosticErrorType.unknown,
      );
      try {
        await deleteSession();
        DiagnosticLog.instance.safeStage(
          component: SafeDiagnosticComponent.storage,
          event: SafeDiagnosticEvent.signInStageSuccess,
          stage: SignInStage.sessionDelete,
          reason: SafeDiagnosticReason.unknown,
          errorType: SafeDiagnosticErrorType.unknown,
        );
      } on SecureStorageFailure catch (error) {
        DiagnosticLog.instance.safeFailure(
          component: SafeDiagnosticComponent.storage,
          event: SafeDiagnosticEvent.sessionDeleteFailure,
          stage: SignInStage.sessionDelete,
          reason: safeReasonForStorage(error.reason),
          errorType: SafeDiagnosticErrorType.secureStorageFailure,
        );
      }
      return null;
    }
  }

  Future<String?> readDeviceId() =>
      _guard(SecureStorageOperation.readDeviceId, () {
        return _storage.read(_deviceIdKey);
      });

  Future<void> writeDeviceId(String deviceId) => _guard(
    SecureStorageOperation.writeDeviceId,
    () => _storage.write(_deviceIdKey, deviceId),
  );

  Future<String?> readSession() =>
      _guard(SecureStorageOperation.readSession, () {
        return _storage.read(_sessionKey);
      });

  Future<void> writeSession(EmbySession session) => _guard(
    SecureStorageOperation.writeSession,
    () => _storage.write(_sessionKey, jsonEncode(session.toJson())),
  );

  Future<void> deleteSession() => _guard(
    SecureStorageOperation.deleteSession,
    () => _storage.delete(_sessionKey),
  );

  Future<void> saveSession(EmbySession session) => writeSession(session);

  Future<void> clearSession() => deleteSession();

  Future<String> getOrCreateDeviceId() async {
    final existing = await readDeviceId();
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = generateDeviceId();
    await writeDeviceId(generated);
    return generated;
  }

  String generateDeviceId() =>
      '${_capabilities.deviceIdPrefix}${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

  Future<T> _guard<T>(
    SecureStorageOperation operation,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } on SecureStorageFailure {
      rethrow;
    } on PlatformException catch (error) {
      throw SecureStorageFailure(
        operation: operation,
        reason: classifyPlatformException(error),
      );
    } catch (_) {
      throw SecureStorageFailure(
        operation: operation,
        reason: SecureStorageFailureReason.unexpected,
      );
    }
  }

  static SecureStorageFailureReason classifyPlatformException(
    PlatformException error,
  ) {
    if (_isMissingEntitlementValue(error.code) ||
        _isMissingEntitlementValue(error.details) ||
        _isMissingEntitlementValue(error.message)) {
      return SecureStorageFailureReason.missingEntitlement;
    }

    final code = error.code.trim().toLowerCase();
    if (const {
      'unavailable',
      'not_available',
      'notavailable',
      'secure_storage_unavailable',
      'errsecnotavailable',
      '-25291',
    }.contains(code)) {
      return SecureStorageFailureReason.unavailable;
    }
    if (const {
      'access_denied',
      'accessdenied',
      'permission_denied',
      'permissiondenied',
      'denied',
      'errsecinteractionnotallowed',
      '-25308',
    }.contains(code)) {
      return SecureStorageFailureReason.accessDenied;
    }
    return SecureStorageFailureReason.unexpected;
  }

  static bool _isMissingEntitlementValue(Object? value) {
    if (value is int) return value == -34018;
    if (value is! String) return false;
    final normalized = value.trim();
    if (normalized == '-34018' ||
        normalized.toLowerCase() == 'errsecmissingentitlement') {
      return true;
    }
    return RegExp(
          r'^OSStatus(?:\s+error)?\s*-34018\.?$',
          caseSensitive: false,
        ).hasMatch(normalized) ||
        RegExp(
          r'''^The operation couldn['’]t be completed\. \(OSStatus error -34018\.\)$''',
        ).hasMatch(normalized);
  }
}
