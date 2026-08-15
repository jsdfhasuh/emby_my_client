import 'package:flutter/foundation.dart';

/// Describes platform boundaries that affect application behavior.
///
/// The object is intentionally small and immutable so services and widgets can
/// receive a deterministic capability set in tests without changing the host
/// platform.
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.platformName,
    required this.embyDeviceName,
    required this.supportsAndroidForegroundDownloadExecutor,
    required this.supportsLanUdpDiscovery,
    required this.supportsPictureInPicture,
    required this.supportsLocalNetworkPermissionRecovery,
    required this.targetDeviceFamily,
    this.knownLimitations = const <String>[],
  });

  static const android = PlatformCapabilities(
    platformName: 'android',
    embyDeviceName: 'Android',
    supportsAndroidForegroundDownloadExecutor: true,
    supportsLanUdpDiscovery: true,
    supportsPictureInPicture: true,
    supportsLocalNetworkPermissionRecovery: false,
    targetDeviceFamily: 'Android',
  );

  static const ipad = PlatformCapabilities(
    platformName: 'ios',
    embyDeviceName: 'iPadOS',
    supportsAndroidForegroundDownloadExecutor: false,
    supportsLanUdpDiscovery: true,
    supportsPictureInPicture: false,
    supportsLocalNetworkPermissionRecovery: true,
    targetDeviceFamily: 'iPad',
    knownLimitations: <String>[
      '不支持 Android 前台下载执行器，应用前台下载在进程终止后不会自动继续',
      '首轮不支持画中画',
      '首轮仅支持 iPad，不支持 iPhone 或可调整多任务窗口',
    ],
  );

  static const unsupported = PlatformCapabilities(
    platformName: 'unknown',
    embyDeviceName: 'Unknown',
    supportsAndroidForegroundDownloadExecutor: false,
    supportsLanUdpDiscovery: false,
    supportsPictureInPicture: false,
    supportsLocalNetworkPermissionRecovery: false,
    targetDeviceFamily: 'unknown',
    knownLimitations: <String>['当前平台不在 iPadOS Core 支持范围内'],
  );

  /// Returns the runtime defaults. Tests should pass an explicit instance.
  factory PlatformCapabilities.current() {
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => android,
      TargetPlatform.iOS => ipad,
      _ => unsupported,
    };
  }

  final String platformName;
  final String embyDeviceName;
  final bool supportsAndroidForegroundDownloadExecutor;
  final bool supportsLanUdpDiscovery;
  final bool supportsPictureInPicture;
  final bool supportsLocalNetworkPermissionRecovery;
  final String targetDeviceFamily;
  final List<String> knownLimitations;

  String get deviceIdPrefix => 'emby-$platformName-';
}
