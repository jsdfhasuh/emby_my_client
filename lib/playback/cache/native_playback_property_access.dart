import 'dart:async';
import 'dart:convert';

import 'package:media_kit/media_kit.dart';

abstract interface class NativePlaybackPropertyAccess {
  Future<void> setString(String name, String value);
  Future<String?> getString(String name);
  Future<Object?> getNative(String name);
  Future<bool> hasOption(String name);
  Future<bool> hasProperty(String name);
  Future<void> command(List<String> command);
}

class NativePlaybackOperationTimeout implements Exception {
  const NativePlaybackOperationTimeout(this.operation);

  final NativePlaybackOperationKind operation;

  @override
  String toString() => 'Native playback operation timed out: ${operation.code}';
}

enum NativePlaybackOperationKind {
  propertyRead('property_read'),
  propertyWrite('property_write');

  const NativePlaybackOperationKind(this.code);

  final String code;
}

typedef NativePlaybackTimeoutReporter =
    void Function(NativePlaybackOperationKind operation);

Future<T> withNativePlaybackTimeout<T>(
  Future<T> future, {
  required NativePlaybackOperationKind operation,
  Duration timeout = const Duration(seconds: 1),
  NativePlaybackTimeoutReporter? onTimeout,
}) => future.timeout(
  timeout,
  onTimeout: () {
    onTimeout?.call(operation);
    throw NativePlaybackOperationTimeout(operation);
  },
);

class MediaKitNativePlaybackPropertyAccess
    implements NativePlaybackPropertyAccess {
  const MediaKitNativePlaybackPropertyAccess(
    this.player, {
    this.timeout = const Duration(seconds: 1),
    this.commandTimeout = const Duration(seconds: 2),
    this.timeoutReporter,
  });

  final NativePlayer player;
  final Duration timeout;
  final Duration commandTimeout;
  final NativePlaybackTimeoutReporter? timeoutReporter;

  @override
  Future<void> setString(String name, String value) =>
      withNativePlaybackTimeout(
        player.setProperty(name, value),
        operation: NativePlaybackOperationKind.propertyWrite,
        timeout: timeout,
        onTimeout: timeoutReporter,
      );

  @override
  Future<String?> getString(String name) async => withNativePlaybackTimeout(
    player.getProperty(name),
    operation: NativePlaybackOperationKind.propertyRead,
    timeout: timeout,
    onTimeout: timeoutReporter,
  );

  @override
  Future<Object?> getNative(String name) async {
    final value = await getString(name);
    if (value == null || value.isEmpty) return value;
    try {
      return jsonDecode(value);
    } catch (_) {
      return value;
    }
  }

  @override
  Future<bool> hasOption(String name) async {
    final optionName = await getString('option-info/$name/name');
    return optionName == name;
  }

  @override
  Future<bool> hasProperty(String name) async {
    final value = await getNative('property-list');
    if (value is Iterable) {
      return value.map((entry) => entry.toString()).contains(name);
    }
    final raw = value?.toString() ?? '';
    return RegExp(
      r'(^|[^A-Za-z0-9_-])' + RegExp.escape(name) + r'([^A-Za-z0-9_-]|$)',
    ).hasMatch(raw);
  }

  @override
  Future<void> command(List<String> command) =>
      player.command(command).timeout(commandTimeout);
}
