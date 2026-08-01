import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:disk_space_plus/disk_space_plus.dart';

abstract interface class DownloadPreflight {
  Stream<void> get networkChanges;

  Future<void> verifyNetwork({required bool wifiOnly});

  Future<void> verifyStorage({
    required Directory directory,
    required int? expectedBytes,
    required int downloadedBytes,
  });
}

class PlatformDownloadPreflight implements DownloadPreflight {
  PlatformDownloadPreflight({
    Connectivity? connectivity,
    DiskSpacePlus? diskSpace,
    this.minimumUnknownSizeBytes = 128 * 1024 * 1024,
    this.minimumSafetyMarginBytes = 64 * 1024 * 1024,
  }) : _connectivity = connectivity ?? Connectivity(),
       _diskSpace = diskSpace ?? DiskSpacePlus();

  final Connectivity _connectivity;
  final DiskSpacePlus _diskSpace;
  final int minimumUnknownSizeBytes;
  final int minimumSafetyMarginBytes;

  @override
  Stream<void> get networkChanges =>
      _connectivity.onConnectivityChanged.map((_) {});

  @override
  Future<void> verifyNetwork({required bool wifiOnly}) async {
    final connections = await _connectivity.checkConnectivity();
    if (connections.isEmpty ||
        (connections.length == 1 &&
            connections.single == ConnectivityResult.none)) {
      throw const DownloadPreflightException(
        code: 'networkUnavailable',
        message: '当前没有可用网络',
      );
    }
    if (wifiOnly &&
        !connections.contains(ConnectivityResult.wifi) &&
        !connections.contains(ConnectivityResult.ethernet)) {
      throw const DownloadPreflightException(
        code: 'wifiRequired',
        message: '当前设置为仅通过 Wi-Fi 下载',
      );
    }
  }

  @override
  Future<void> verifyStorage({
    required Directory directory,
    required int? expectedBytes,
    required int downloadedBytes,
  }) async {
    await directory.create(recursive: true);
    final freeMegabytes = await _diskSpace.getFreeDiskSpaceForPath(
      directory.path,
    );
    if (freeMegabytes == null) return;
    final freeBytes = (freeMegabytes * 1024 * 1024).floor();
    final remaining =
        (expectedBytes == null
                ? minimumUnknownSizeBytes
                : max(0, expectedBytes - downloadedBytes))
            .toInt();
    final proportionalMargin = expectedBytes == null
        ? 0
        : (expectedBytes * 0.05).ceil();
    final required =
        remaining + max(minimumSafetyMarginBytes, proportionalMargin).toInt();
    if (freeBytes < required) {
      throw DownloadPreflightException(
        code: 'insufficientStorage',
        message: '可用空间不足，需要至少 ${_formatBytes(required)}',
      );
    }
  }
}

class NoopDownloadPreflight implements DownloadPreflight {
  const NoopDownloadPreflight();

  @override
  Stream<void> get networkChanges => const Stream<void>.empty();

  @override
  Future<void> verifyNetwork({required bool wifiOnly}) async {}

  @override
  Future<void> verifyStorage({
    required Directory directory,
    required int? expectedBytes,
    required int downloadedBytes,
  }) async {}
}

class DownloadPreflightException implements Exception {
  const DownloadPreflightException({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => message;
}

String _formatBytes(int bytes) {
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).ceil()} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
