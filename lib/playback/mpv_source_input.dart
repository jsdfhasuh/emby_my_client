import '../core/strm_diagnostics.dart';
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';

import 'playback_resource_request.dart';
import 'source_http_input.dart';

/// One registration per actual mpv core. The native cookie outlives logical
/// timeouts and is freed only after the core's real disposal Future completes.
class MpvSourceInput {
  MpvSourceInput._(this._library, this._context, this._onReadFailure) {
    _timer = Timer.periodic(const Duration(milliseconds: 4), (_) => _poll());
  }

  static Future<MpvSourceInput> create(
    NativePlayer player, {
    void Function(SourceInputFailure)? onReadFailure,
  }) async {
    final library = Platform.isIOS
        ? DynamicLibrary.process()
        : DynamicLibrary.open(
            Platform.environment['STRM_INPUT_LIBRARY'] ??
                (Platform.isWindows ? 'strm_input.dll' : 'libstrm_input.so'),
          );
    final create = library
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Void>)
        >('strm_create');
    final mpv = DynamicLibrary.open(NativeLibrary.path);
    final version = mpv.lookupFunction<Uint64 Function(), int Function()>(
      'mpv_client_api_version',
    )();
    if (version < ((1 << 16) | 106)) {
      throw const SourceInputException('native_api_version');
    }
    final context = create(
      Pointer.fromAddress(await player.handle),
      mpv.lookup<Void>('mpv_stream_cb_add_ro'),
    );
    if (context == nullptr) {
      throw const SourceInputException('native_registration');
    }
    return MpvSourceInput._(library, context, onReadFailure);
  }

  final DynamicLibrary _library;
  final Pointer<Void> _context;
  final void Function(SourceInputFailure)? _onReadFailure;
  late final Timer _timer;
  final Map<int, SourceHttpInput> _inputs = {};
  int _nextId = 0;
  StrmTrace? _lastTrace;
  int _lastAttempt = 0;
  bool _destroyed = false;
  late final _add = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int64, Int64),
        int Function(Pointer<Void>, int, int)
      >('strm_add');
  late final _next = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Int64>),
        int Function(Pointer<Void>, Pointer<Int64>)
      >('strm_poll');
  late final _complete = _library
      .lookupFunction<
        Void Function(Pointer<Void>, Int64, Int64, Pointer<Uint8>, Int64),
        void Function(Pointer<Void>, int, int, Pointer<Uint8>, int)
      >('strm_complete');
  late final _release = _library
      .lookupFunction<
        Void Function(Pointer<Void>, Int64),
        void Function(Pointer<Void>, int)
      >('strm_release');
  late final _destroy = _library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('strm_destroy');

  Future<({Uri uri, String format, int sizeBytes})> prepare(
    PlaybackResourceRequest request, [
    int? attempt,
  ]) async {
    final openAttempt = attempt ?? request.trace.nextOpen();
    if (_destroyed) throw const SourceInputException('cancelled');
    releaseAll();
    _lastTrace = request.trace;
    _lastAttempt = openAttempt;
    final id = ++_nextId;
    final input = SourceHttpInput(
      request,
      embyServer: request.embyServer,
      openAttempt: openAttempt,
    );
    _inputs[id] = input;
    try {
      await input.prepare();
      if (_destroyed || !identical(_inputs[id], input)) {
        throw const SourceInputException('cancelled');
      }
      if (_add(_context, id, input.size) != 1) {
        throw const SourceInputException('native_registration');
      }
      request.trace.emit('strm_native', {
        'openAttempt': openAttempt,
        'stage': 'native_register',
        'outcome': 'succeeded',
      });
      return (
        uri: Uri.parse('embyinput://$id'),
        format: input.format!,
        sizeBytes: input.size,
      );
    } catch (_) {
      _inputs.remove(id)?.close();
      rethrow;
    }
  }

  void _poll() {
    if (_destroyed) return;
    final event = calloc<Int64>(4);
    try {
      // No native callback runs on Dart's thread or holds a Dart buffer.
      while (_next(_context, event) == 1) {
        unawaited(_read(event[0], event[1], event[2], event[3]));
      }
    } finally {
      calloc.free(event);
    }
  }

  Future<void> _read(int id, int sequence, int offset, int count) async {
    final input = _inputs[id];
    try {
      if (input == null) throw const SourceInputException('cancelled');
      input.recordNativeRead();
      final bytes = await input.read(offset, count);
      if (_destroyed || !identical(_inputs[id], input)) return;
      final copy = calloc<Uint8>(bytes.length);
      try {
        copy.asTypedList(bytes.length).setAll(0, bytes);
        _complete(_context, id, sequence, copy, bytes.length);
        input.recordDelivery(bytes.length);
      } finally {
        calloc.free(copy);
      }
    } catch (error) {
      if (input != null) {
        final stale =
            _destroyed ||
            !identical(_inputs[id], input) ||
            !input.request.sessionActive;
        final failure =
            (error is SourceInputException ? error.failure : null) ??
            SourceInputFailure(
              error: SourceInputException.from(error, stage: 'native_read'),
              trace: input.request.trace,
              openAttempt: input.openAttempt,
              request: input.requestNumber,
              stale: stale,
            );
        failure.record(staleOverride: stale);
        if (!stale) _onReadFailure?.call(failure);
      }
      if (!_destroyed) _complete(_context, id, sequence, nullptr, -1);
    }
  }

  void releaseAll() {
    if (_destroyed) return;
    for (final entry in _inputs.entries) {
      _release(_context, entry.key);
      entry.value.close();
      entry.value.request.trace.emit('strm_native', {
        'openAttempt': entry.value.openAttempt,
        'stage': 'native_read',
        'outcome': 'cancelled',
      });
    }
    _inputs.clear();
  }

  void afterNativeDisposal() {
    if (_destroyed) return;
    releaseAll();
    _destroyed = true;
    _timer.cancel();
    _destroy(_context);
    _lastTrace?.emit('strm_native', {
      'openAttempt': _lastAttempt,
      'stage': 'native_register',
      'outcome': 'released',
    });
  }
}
