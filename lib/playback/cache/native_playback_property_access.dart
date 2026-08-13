import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/media_kit.dart';
// The locked media_kit release exposes the active player's native library only
// through this bridge; no second Player or probe context is created.
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';

abstract interface class NativePlaybackPropertyAccess {
  Future<void> setString(String name, String value);
  Future<String?> getString(String name);
  Future<Object?> getNative(String name);
  Future<bool> hasOption(String name);
  Future<bool> hasProperty(String name);
  Future<void> command(List<String> command);
}

/// Access to the structured value returned by the active mpv context.
///
/// This is intentionally separate from [NativePlaybackPropertyAccess] so test
/// fakes that only model string properties remain small. Production native
/// access implements it with the same NativePlayer handle used for playback.
abstract interface class NativePlaybackNodeAccess {
  Future<Object?> getNativeNode(String name);
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
    implements NativePlaybackPropertyAccess, NativePlaybackNodeAccess {
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
        _withActivePlayer(() => player.setProperty(name, value)),
        operation: NativePlaybackOperationKind.propertyWrite,
        timeout: timeout,
        onTimeout: timeoutReporter,
      );

  @override
  Future<String?> getString(String name) async => withNativePlaybackTimeout(
    _withActivePlayer(() => player.getProperty(name)),
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
  Future<Object?> getNativeNode(String name) => _withActivePlayer(() async {
    final handleAddress = await player.handle;
    if (handleAddress == 0) return null;

    final mpv = generated.MPV(DynamicLibrary.open(NativeLibrary.path));
    final context = Pointer<generated.mpv_handle>.fromAddress(handleAddress);
    final nativeName = name.toNativeUtf8();
    final node = calloc<generated.mpv_node>();
    try {
      final status = mpv.mpv_get_property(
        context,
        nativeName.cast(),
        generated.mpv_format.MPV_FORMAT_NODE,
        node.cast(),
      );
      if (status < 0) return null;
      return _copyNode(node.ref);
    } finally {
      try {
        mpv.mpv_free_node_contents(node);
      } finally {
        calloc.free(node);
        calloc.free(nativeName);
      }
    }
  });

  static Object? _copyNode(generated.mpv_node node) {
    switch (node.format) {
      case generated.mpv_format.MPV_FORMAT_STRING:
      case generated.mpv_format.MPV_FORMAT_OSD_STRING:
        final value = node.u.string;
        return value == nullptr ? null : value.cast<Utf8>().toDartString();
      case generated.mpv_format.MPV_FORMAT_FLAG:
        return node.u.flag != 0;
      case generated.mpv_format.MPV_FORMAT_INT64:
        return node.u.int64;
      case generated.mpv_format.MPV_FORMAT_DOUBLE:
        return node.u.double_;
      case generated.mpv_format.MPV_FORMAT_NODE_ARRAY:
        return _copyArray(node.u.list);
      case generated.mpv_format.MPV_FORMAT_NODE_MAP:
        return _copyMap(node.u.list);
      case generated.mpv_format.MPV_FORMAT_NONE:
      case generated.mpv_format.MPV_FORMAT_BYTE_ARRAY:
        return null;
      default:
        return null;
    }
  }

  static List<Object?> _copyArray(Pointer<generated.mpv_node_list> list) {
    if (list == nullptr || list.ref.num <= 0 || list.ref.values == nullptr) {
      return const [];
    }
    final count = list.ref.num;
    return List<Object?>.generate(
      count,
      (index) => _copyNode((list.ref.values + index).ref),
      growable: false,
    );
  }

  static Map<String, Object?> _copyMap(Pointer<generated.mpv_node_list> list) {
    if (list == nullptr || list.ref.num <= 0 || list.ref.values == nullptr) {
      return const {};
    }
    final result = <String, Object?>{};
    final count = list.ref.num;
    for (var index = 0; index < count; index++) {
      if (list.ref.keys == nullptr) continue;
      final keyPointer = (list.ref.keys + index).value;
      if (keyPointer == nullptr) continue;
      result[keyPointer.cast<Utf8>().toDartString()] = _copyNode(
        (list.ref.values + index).ref,
      );
    }
    return result;
  }

  @override
  Future<bool> hasOption(String name) async {
    final optionName = await getString('option-info/$name/name');
    return optionName == name;
  }

  @override
  Future<bool> hasProperty(String name) async {
    final value = await getNative('property-list');
    return nativePropertyListContains(value, name);
  }

  @override
  Future<void> command(List<String> command) =>
      _withActivePlayer(() => player.command(command)).timeout(commandTimeout);

  Future<T> _withActivePlayer<T>(Future<T> Function() operation) =>
      NativePlayer.lock.synchronized(() async {
        if (player.disposed) {
          throw StateError('Native player is unavailable');
        }
        return operation();
      });
}

/// Matches structured mpv property-list nodes without inspecting debug text.
bool nativePropertyListContains(Object? value, String name) {
  if (value is! Iterable) return false;
  for (final entry in value) {
    if (entry is String && entry == name) return true;
    if (entry is Map) {
      final candidate = entry['name'];
      if (candidate is String && candidate == name) return true;
    }
  }
  return false;
}
