import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'sign_in_diagnostics.dart';

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
      debugPrint('[diagnostic] Failed to initialize log: $error');
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
    final clean = redact(message).replaceAll('\r', '');
    final timestamp = DateTime.now().toIso8601String();
    final candidate = '$timestamp [$level] [$component] $clean\n';
    final candidateBytes = utf8.encode(candidate).length;
    final line = candidateBytes <= _fileByteLimit
        ? candidate
        : '$timestamp [WARN] [diagnostic] '
              'event=diagnostic_entry_dropped reason=oversized '
              'bytes=$candidateBytes\n';
    debugPrint(line.trimRight());
    _testSink?.call(line.trimRight());

    final file = _file;
    if (file == null) return;
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        await _recoverLogBackup(file);
        await file.writeAsString(line, mode: FileMode.append, flush: true);
        if (await file.length() > _fileByteLimit) {
          await _trimLogFile(file);
        }
      } catch (error) {
        debugPrint('[diagnostic] Failed to write log: $error');
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

  static String redact(String value) {
    var result = value;
    result = result.replaceAll(
      RegExp(r'''\b(?:https?|wss?)://[^\s<>"']+''', caseSensitive: false),
      '<redacted-url>',
    );
    result = result.replaceAll(
      RegExp(r'''\b(?:https?|wss?)%3A%2F%2F[^\s<>"']+''', caseSensitive: false),
      '<redacted-url>',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'(api_key|x-emby-token)(=|%3D|:\s*)([^&\s,"%}\]]+)',
        caseSensitive: false,
      ),
      (match) => '${match[1]}${match[2]}<redacted>',
    );
    result = result.replaceAllMapped(
      RegExp(r'(Token\s*=\s*")[^"]+(")', caseSensitive: false),
      (match) => '${match[1]}<redacted>${match[2]}',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'''((?:["']?authorization["']?\s*[:=]\s*["']?))(?:basic|bearer)?(?:\s+)?([^"'\s,}\]]+)(["']?)''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}<redacted>${match[3]}',
    );
    result = result.replaceAllMapped(
      RegExp(r'(Bearer\s+)[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      (match) => '${match[1]}<redacted>',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'''((?:["']?(?:password|pw|accesstoken|api_key|x-emby-token|username|deviceid)["']?\s*(?:=|:|%3d)\s*)["'])([^"']*)(["'])''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}<redacted>${match[3]}',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'''(\b(?:password|pw|accesstoken|api_key|x-emby-token|username|deviceid)\b\s*(?:=|:|%3d)\s*)([^&\s,}\]]+)''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}<redacted>',
    );
    result = result.replaceAllMapped(
      RegExp(r'(Authenticated user\s+)[^\r\n]+', caseSensitive: false),
      (match) => '${match[1]}<redacted>',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'(Selected [^\r\n]*?\bsource=\S+\s+name=).*?(\s+container=)',
        caseSensitive: false,
      ),
      (match) => '${match[1]}<redacted>${match[2]}',
    );
    return result;
  }
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
