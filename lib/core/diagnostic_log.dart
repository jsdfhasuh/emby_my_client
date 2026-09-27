import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'sign_in_diagnostics.dart';
import 'token_redactor.dart';

typedef DiagnosticLogTestSink = void Function(String line);
typedef DiagnosticSafeEventTestSink =
    void Function(SafeDiagnosticRecord record);

class DiagnosticLog implements SafeDiagnosticEventSource {
  DiagnosticLog._({
    int maxFileBytes = _maxFileBytes,
    int retainedFileBytes = _retainedFileBytes,
  }) : _fileByteLimit = _validateMaxFileBytes(maxFileBytes),
       _retainedFileByteLimit = _validateRetainedFileBytes(
         retainedFileBytes,
         maxFileBytes,
       );

  @visibleForTesting
  DiagnosticLog.forTesting({
    int maxFileBytes = _maxFileBytes,
    int? retainedFileBytes,
  }) : this._(
         maxFileBytes: maxFileBytes,
         retainedFileBytes: retainedFileBytes ?? (maxFileBytes * 4 ~/ 5),
       );

  static final DiagnosticLog instance = DiagnosticLog._();
  static const _fileName = 'emby_client_diagnostics.log';
  static const _safeFileName = 'emby_safe_diagnostics_v1.jsonl';
  static const _maxFileBytes = 750 * 1024;
  static const _retainedFileBytes = 640 * 1024;
  static const _maxSafeEventBytes = 256 * 1024;
  static const _maxSafeEventRecords = 1000;
  static const truncationMarker = 'event=diagnostic_log_truncated';

  static int _validateMaxFileBytes(int value) {
    if (value < 256) {
      throw ArgumentError.value(value, 'maxFileBytes', 'must be at least 256');
    }
    return value;
  }

  static int _validateRetainedFileBytes(int value, int maxFileBytes) {
    if (value <= 0 || value >= maxFileBytes) {
      throw ArgumentError.value(
        value,
        'retainedFileBytes',
        'must be greater than 0 and less than maxFileBytes',
      );
    }
    return value;
  }

  final int _fileByteLimit;
  final int _retainedFileByteLimit;

  int _queuedBytes = 0;
  int droppedWrites = 0;
  int _unreportedDrops = 0;
  bool writeFailed = false;
  static const maxQueuedBytes = 256 * 1024;
  File? _file;
  File? _safeFile;
  Future<void> _pendingWrite = Future.value();
  Future<void> _pendingSafeOperation = Future.value();
  DiagnosticLogTestSink? _testSink;
  DiagnosticSafeEventTestSink? _safeEventTestSink;

  Future<void> initialize() async {
    try {
      final directory = await getApplicationSupportDirectory();
      await directory.create(recursive: true);
      final file = File('${directory.path}${Platform.pathSeparator}$_fileName');
      await _prepareLogFile(file);
      _file = file;
      _safeFile = File(
        '${directory.path}${Platform.pathSeparator}$_safeFileName',
      );
      info('app', 'Diagnostic log initialized');
    } catch (error) {
      writeFailed = true;
      debugPrint('[diagnostic] Failed to initialize log');
    }
  }

  void debug(String component, String message) =>
      _write('DEBUG', component, message);

  void info(String component, String message) =>
      _write('INFO', component, message);

  void warning(String component, String message) =>
      _write('WARN', component, message);

  void error(
    String component,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final details = [
      message,
      if (error != null) error.toString(),
      if (stackTrace != null) stackTrace.toString(),
    ].join('\n');
    _write('ERROR', component, details);
  }

  void safeFailure({
    required SafeDiagnosticComponent component,
    required SafeDiagnosticEvent event,
    required SignInStage stage,
    required SafeDiagnosticReason reason,
    required SafeDiagnosticErrorType errorType,
  }) {
    _write(
      'ERROR',
      component.code,
      'event=${event.code} stage=${stage.code} '
          'reason=${reason.code} errorType=${errorType.code}',
    );
    _writeSafeRecord(
      level: SafeDiagnosticLevel.error,
      component: component,
      event: event,
      stage: stage,
      reason: reason,
      errorType: errorType,
    );
  }

  void safeStage({
    required SafeDiagnosticComponent component,
    required SafeDiagnosticEvent event,
    required SignInStage stage,
    required SafeDiagnosticReason reason,
    required SafeDiagnosticErrorType errorType,
  }) {
    _write(
      'INFO',
      component.code,
      'event=${event.code} stage=${stage.code} '
          'reason=${reason.code} errorType=${errorType.code}',
    );
    _writeSafeRecord(
      level: SafeDiagnosticLevel.info,
      component: component,
      event: event,
      stage: stage,
      reason: reason,
      errorType: errorType,
    );
  }

  Future<String> read() async {
    await _pendingWrite;
    final file = _file;
    if (file == null) return '';
    await _recoverLogBackup(file);
    if (!await file.exists()) return '';
    final snapshot = await DiagnosticLogTailReader.read(
      FileDiagnosticLogByteSource(file),
      maxBytes: _fileByteLimit,
    );
    return redact(snapshot.content);
  }

  Future<void> clear() async {
    final file = _file;
    final clearOperation = _pendingWrite.then((_) async {
      if (file != null) {
        await _recoverLogBackup(file);
        await file.writeAsString('');
      }
    });
    _pendingWrite = clearOperation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[diagnostic] Failed to clear log');
      },
    );
    await clearOperation;
    info('app', 'Diagnostic log cleared');
  }

  @override
  Future<List<SafeDiagnosticRecord>> readSafeEvents() async {
    return _enqueueSafeOperation(() async {
      final file = _safeFile;
      if (file == null || !await file.exists()) return const [];
      return _readSafeRecords(file);
    });
  }

  @override
  Future<void> clearSafeEvents() async {
    await _enqueueSafeOperation(() async {
      final file = _safeFile;
      if (file == null) return;
      await _replaceSafeRecords(file, const []);
    });
  }

  String? get path => _file?.path;

  @visibleForTesting
  void setTestSink(DiagnosticLogTestSink? sink) => _testSink = sink;

  @visibleForTesting
  Future<void> initializeFileForTesting(File file) async {
    await file.parent.create(recursive: true);
    await _prepareLogFile(file);
    _file = file;
  }

  @visibleForTesting
  static int get maxFileBytesForTesting => _maxFileBytes;

  @visibleForTesting
  static int get retainedFileBytesForTesting => _retainedFileBytes;

  @visibleForTesting
  void setSafeEventTestSink(DiagnosticSafeEventTestSink? sink) {
    _safeEventTestSink = sink;
  }

  @visibleForTesting
  void setTestSafeEventFile(File? file) {
    _safeFile = file;
  }

  void _writeSafeRecord({
    required SafeDiagnosticLevel level,
    required SafeDiagnosticComponent component,
    required SafeDiagnosticEvent event,
    required SignInStage stage,
    required SafeDiagnosticReason reason,
    required SafeDiagnosticErrorType errorType,
  }) {
    final record = SafeDiagnosticRecord(
      atUtc: DateTime.now().toUtc(),
      level: level,
      component: component,
      event: event,
      stage: stage,
      reason: reason,
      errorType: errorType,
    );
    _enqueueSafeOperation(() async {
      try {
        _safeEventTestSink?.call(record);
        final file = _safeFile;
        if (file == null) return;
        final records = <SafeDiagnosticRecord>[];
        if (await file.exists()) {
          records.addAll(await _readSafeRecords(file));
        }
        records.add(record);
        while (records.length > _maxSafeEventRecords) {
          records.removeAt(0);
        }
        while (records.isNotEmpty &&
            _encodedSafeRecordsLength(records) > _maxSafeEventBytes) {
          records.removeAt(0);
        }
        if (_encodedSafeRecordsLength(records) <= _maxSafeEventBytes) {
          await _replaceSafeRecords(file, records);
        }
      } catch (_) {
        debugPrint('[diagnostic] Safe diagnostic event write failed');
      }
    });
  }

  Future<T> _enqueueSafeOperation<T>(Future<T> Function() operation) {
    final next = _pendingSafeOperation.then((_) => operation());
    _pendingSafeOperation = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[diagnostic] Safe diagnostic event operation failed');
      },
    );
    return next;
  }

  Future<List<SafeDiagnosticRecord>> _readSafeRecords(File file) async {
    final bytes = await file.readAsBytes();
    if (bytes.length > _maxSafeEventBytes) {
      throw const SafeDiagnosticValidationException();
    }
    if (bytes.isEmpty) return <SafeDiagnosticRecord>[];
    late final String contents;
    try {
      contents = utf8.decode(bytes);
    } catch (_) {
      throw const SafeDiagnosticValidationException();
    }
    if (contents.contains('\r') || !contents.endsWith('\n')) {
      throw const SafeDiagnosticValidationException();
    }
    final records = <SafeDiagnosticRecord>[];
    final lines = contents.split('\n');
    lines.removeLast();
    for (final line in lines) {
      if (line.isEmpty) throw const SafeDiagnosticValidationException();
      try {
        records.add(SafeDiagnosticRecord.fromJson(jsonDecode(line)));
      } on SafeDiagnosticValidationException {
        rethrow;
      } catch (_) {
        throw const SafeDiagnosticValidationException();
      }
    }
    if (records.length > _maxSafeEventRecords) {
      throw const SafeDiagnosticValidationException();
    }
    return records;
  }

  int _encodedSafeRecordsLength(List<SafeDiagnosticRecord> records) {
    var length = 0;
    for (final record in records) {
      length += utf8.encode('${jsonEncode(record.toJson())}\n').length;
    }
    return length;
  }

  Future<void> _replaceSafeRecords(
    File file,
    List<SafeDiagnosticRecord> records,
  ) async {
    final content = records.isEmpty
        ? ''
        : '${records.map((record) => jsonEncode(record.toJson())).join('\n')}\n';
    final bytes = utf8.encode(content);
    if (bytes.length > _maxSafeEventBytes) {
      throw const SafeDiagnosticValidationException();
    }
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (Platform.isWindows && await file.exists()) {
        await file.delete();
      }
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  void _write(String level, String component, String message) {
    final clean = TokenRedactor.escapeControls(redact(message));
    final timestamp = DateTime.now().toIso8601String();
    final candidate = '$timestamp [$level] [$component] $clean\n';
    final candidateBytes = utf8.encode(candidate).length;
    final entryLimit = _fileByteLimit < 16384 ? _fileByteLimit : 16384;
    var line = candidate;
    if (candidateBytes > entryLimit) {
      final marker =
          '\n$timestamp [WARN] [diagnostic] '
          '$truncationMarker eventDetail=diagnostic_entry_truncated '
          'reason=oversized originalBytes=$candidateBytes\n';
      final bytes = utf8.encode(candidate);
      var end = (entryLimit - utf8.encode(marker).length).clamp(
        0,
        bytes.length,
      );
      while (end > 0 && end < bytes.length && (bytes[end] & 0xc0) == 0x80) {
        end--;
      }
      line = '${utf8.decode(bytes.sublist(0, end))}$marker';
    }
    try {
      _testSink?.call(line.trimRight());
    } catch (_) {
      writeFailed = true;
    }

    final file = _file;
    if (file == null) return;
    final bytes = utf8.encode(line).length;
    if (_queuedBytes + bytes > maxQueuedBytes) {
      droppedWrites++;
      _unreportedDrops++;
      return;
    }
    _queuedBytes += bytes;
    // STRM events already have a bounded asynchronous file queue; avoid a
    // second unbounded Flutter console queue on the media input path.
    if (component != 'strm') debugPrint(line.trimRight());
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        await _recoverLogBackup(file);
        await file.writeAsString(line, mode: FileMode.append, flush: true);
        if (await file.length() > _fileByteLimit) {
          await _trimLogFile(file);
        }
      } catch (error) {
        writeFailed = true;
        debugPrint('[diagnostic] Failed to write log');
      } finally {
        _queuedBytes -= bytes;
        if (_queuedBytes == 0 && _unreportedDrops > 0) {
          final count = _unreportedDrops;
          _unreportedDrops = 0;
          try {
            await file.writeAsString(
              '${DateTime.now().toIso8601String()} [WARN] [diagnostic] event=diagnostic_entries_dropped count=${count.clamp(1, 999999)}\n',
              mode: FileMode.append,
              flush: true,
            );
            if (await file.length() > _fileByteLimit) await _trimLogFile(file);
          } catch (_) {
            writeFailed = true;
          }
        }
      }
    });
  }

  Future<void> _prepareLogFile(File file) async {
    await _recoverLogBackup(file);
    if (!await file.exists()) return;
    try {
      final source = FileDiagnosticLogByteSource(file);
      if (await file.length() > _fileByteLimit) {
        await _trimLogFile(file);
        return;
      }
      final existing = await DiagnosticLogTailReader.read(
        source,
        maxBytes: _fileByteLimit,
      );
      final sanitized = redact(existing.content);
      if (sanitized != existing.content) {
        await _replaceLogFile(file, sanitized);
      }
    } on FormatException {
      final marker =
          '${DateTime.now().toIso8601String()} [WARN] [diagnostic] '
          '$truncationMarker retainedBytes=0 reason=unreadable_content\n';
      await _replaceLogFile(file, marker);
    }
  }

  Future<void> _trimLogFile(File file) async {
    final marker =
        '${DateTime.now().toIso8601String()} [WARN] [diagnostic] '
        '$truncationMarker retainedBytes=$_retainedFileByteLimit\n';
    final markerBytes = utf8.encode(marker).length;
    final tailBudget = _retainedFileByteLimit - markerBytes;
    final tail = tailBudget <= 0
        ? const DiagnosticLogTailSnapshot(
            content: '',
            sourceTruncated: true,
            bytesRead: 0,
          )
        : await DiagnosticLogTailReader.read(
            FileDiagnosticLogByteSource(file),
            maxBytes: tailBudget,
          );
    await _replaceLogFile(file, '$marker${tail.content}');
  }

  Future<void> _replaceLogFile(File file, String content) async {
    final temporary = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    final backup = File('${file.path}.backup');
    try {
      await _recoverLogBackup(file);
      await temporary.writeAsString(content, flush: true);
      if (Platform.isWindows && await file.exists()) {
        await file.rename(backup.path);
        try {
          await temporary.rename(file.path);
        } catch (_) {
          if (!await file.exists() && await backup.exists()) {
            await backup.rename(file.path);
          }
          rethrow;
        }
        try {
          await backup.delete();
        } catch (_) {
          // A stale backup is harmless and is reconciled on the next access.
        }
      } else {
        await temporary.rename(file.path);
      }
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  Future<void> _recoverLogBackup(File file) async {
    if (!Platform.isWindows) return;
    final backup = File('${file.path}.backup');
    if (!await backup.exists()) return;
    if (!await file.exists()) {
      await backup.rename(file.path);
      return;
    }
    try {
      await backup.delete();
    } catch (_) {
      // Keep the valid primary file; cleanup can be retried on the next access.
    }
  }

  static String redact(String value) => TokenRedactor.redact(value);
}

@visibleForTesting
abstract interface class DiagnosticLogByteSource {
  Future<int> length();

  Future<Uint8List> read(int offset, int length);
}

final class FileDiagnosticLogByteSource implements DiagnosticLogByteSource {
  const FileDiagnosticLogByteSource(this.file);

  final File file;

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> read(int offset, int length) async {
    final handle = await file.open();
    try {
      await handle.setPosition(offset);
      return await handle.read(length);
    } finally {
      await handle.close();
    }
  }
}

@immutable
class DiagnosticLogTailSnapshot {
  const DiagnosticLogTailSnapshot({
    required this.content,
    required this.sourceTruncated,
    required this.bytesRead,
  });

  final String content;
  final bool sourceTruncated;
  final int bytesRead;
}

@visibleForTesting
final class DiagnosticLogTailReader {
  const DiagnosticLogTailReader._();

  static Future<DiagnosticLogTailSnapshot> read(
    DiagnosticLogByteSource source, {
    required int maxBytes,
  }) => _read(source, maxBytes: maxBytes, retryShortRead: true);

  static Future<DiagnosticLogTailSnapshot> _read(
    DiagnosticLogByteSource source, {
    required int maxBytes,
    required bool retryShortRead,
  }) async {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be positive');
    }
    final sourceLength = await source.length();
    if (sourceLength <= 0) {
      return const DiagnosticLogTailSnapshot(
        content: '',
        sourceTruncated: false,
        bytesRead: 0,
      );
    }
    final bytesToRead = sourceLength < maxBytes ? sourceLength : maxBytes;
    final offset = sourceLength - bytesToRead;
    final bytes = await source.read(offset, bytesToRead);
    if (bytes.length != bytesToRead) {
      if (retryShortRead) {
        return _read(source, maxBytes: maxBytes, retryShortRead: false);
      }
      throw const FormatException('Incomplete diagnostic log read');
    }

    var start = 0;
    var end = bytes.length;
    if (offset > 0) {
      final firstNewline = bytes.indexOf(0x0a);
      if (firstNewline < 0) {
        return DiagnosticLogTailSnapshot(
          content: '',
          sourceTruncated: true,
          bytesRead: bytes.length,
        );
      }
      start = firstNewline + 1;
    }
    if (end > start && bytes[end - 1] != 0x0a) {
      final lastNewline = bytes.lastIndexOf(0x0a, end - 1);
      end = lastNewline < start ? start : lastNewline + 1;
    }
    final content = start >= end
        ? ''
        : utf8.decode(
            Uint8List.sublistView(bytes, start, end),
            allowMalformed: false,
          );
    return DiagnosticLogTailSnapshot(
      content: content,
      sourceTruncated: offset > 0,
      bytesRead: bytes.length,
    );
  }
}
