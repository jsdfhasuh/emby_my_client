import 'dart:io';
import 'package:flutter/services.dart';

import '../core/safe_diagnostic_export.dart';
import 'app_update.dart';

enum InstallHandoff { permissionRequired, opened }

abstract interface class UpdateGateway {
  Future<InstalledApp> installed();
  Future<void> validate(VerifiedDownload download);
  Future<InstallHandoff> install(VerifiedDownload download);
  Future<void> allowInstalls();
}

class MethodChannelUpdateGateway implements UpdateGateway {
  const MethodChannelUpdateGateway();
  static const channel = MethodChannel('emby_my_client/app_updates');

  @override
  Future<InstalledApp> installed() async {
    try {
      if (Platform.isAndroid) {
        final values = await channel.invokeMapMethod<String, Object?>(
          'metadata',
        );
        final version = values?['version'];
        final code = values?['buildNumber'];
        final abis = values?['abis'];
        if (version is! String || code is! int || code <= 0 || abis is! List) {
          throw const UpdateFailure('metadata');
        }
        return InstalledApp(
          version: version,
          buildNumber: code,
          platform: UpdatePlatform.android,
          abis: abis.cast<String>(),
        );
      }
      if (Platform.isIOS) {
        final values = await const MethodChannelSafeDiagnosticMetadataProvider()
            .read();
        return InstalledApp(
          version: values.appVersion,
          buildNumber: int.parse(values.buildNumber),
          platform: UpdatePlatform.ios,
        );
      }
      throw const UpdateFailure('unsupported');
    } catch (_) {
      throw const UpdateFailure('metadata');
    }
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw UpdateFailure(error.code);
    } catch (_) {
      throw const UpdateFailure('installer');
    }
  }

  @override
  Future<void> validate(VerifiedDownload download) =>
      _invoke<void>('validate', download.arguments);
  @override
  Future<InstallHandoff> install(VerifiedDownload download) async {
    final value = await _invoke<String>('install', download.arguments);
    if (value == 'permission') return InstallHandoff.permissionRequired;
    if (value == 'opened') return InstallHandoff.opened;
    throw const UpdateFailure('installer');
  }

  @override
  Future<void> allowInstalls() => _invoke<void>('allowInstalls');
}
