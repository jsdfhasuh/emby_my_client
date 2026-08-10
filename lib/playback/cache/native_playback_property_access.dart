import 'dart:async';
import 'dart:convert';

import 'package:media_kit/media_kit.dart';

abstract interface class NativePlaybackPropertyAccess {
  Future<void> setString(String name, String value);
  Future<String?> getString(String name);
  Future<Object?> getNative(String name);
  Future<bool> hasOption(String name);
  Future<bool> hasProperty(String name);
}

class NativePlaybackOperationTimeout implements Exception {
  const NativePlaybackOperationTimeout(this.operation);

  final String operation;

  @override
  String toString() => 'Native playback operation timed out: $operation';
}

Future<T> withNativePlaybackTimeout<T>(
  Future<T> future, {
  required String operation,
  Duration timeout = const Duration(seconds: 1),
}) => future.timeout(
  timeout,
  onTimeout: () => throw NativePlaybackOperationTimeout(operation),
);

class MediaKitNativePlaybackPropertyAccess
    implements NativePlaybackPropertyAccess {
  const MediaKitNativePlaybackPropertyAccess(
    this.player, {
    this.timeout = const Duration(seconds: 1),
  });

  final NativePlayer player;
  final Duration timeout;

  @override
  Future<void> setString(String name, String value) =>
      withNativePlaybackTimeout(
        player.setProperty(name, value),
        operation: 'propertyWrite',
        timeout: timeout,
      );

  @override
  Future<String?> getString(String name) async => withNativePlaybackTimeout(
    player.getProperty(name),
    operation: 'propertyRead',
    timeout: timeout,
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
}
