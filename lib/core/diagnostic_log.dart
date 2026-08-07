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
  DiagnosticLog._();

  @visibleForTesting
  DiagnosticLog.forTesting() : this._();

  static final DiagnosticLog instance = DiagnosticLog._();
  static const _fileName = 'emby_client_diagnostics.log';
  static const _safeFileName = 'emby_safe_diagnostics_v1.jsonl';
  static const _maxFileBytes = 750 * 1024;
  static const _maxSafeEventBytes = 256 * 1024;
  static const _maxSafeEventRecords = 1000;

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
      if (await file.exists()) {
        if (await file.length() > _maxFileBytes) {
          await file.writeAsString('');
        } else {
          final existing = await file.readAsString();
          final sanitized = redact(existing);
          if (sanitized != existing) await file.writeAsString(sanitized);
        }
      }
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
    if (file == null || !await file.exists()) return '';
    return redact(await file.readAsString());
  }

  Future<void> clear() async {
    await _pendingWrite;
    final file = _file;
    if (file != null) await file.writeAsString('');
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
    final line = '$timestamp [$level] [$component] $clean\n';
    debugPrint(line.trimRight());
    _testSink?.call(line.trimRight());

    final file = _file;
    if (file == null) return;
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        await file.writeAsString(line, mode: FileMode.append, flush: true);
      } catch (error) {
        debugPrint('[diagnostic] Failed to write log: $error');
      }
    });
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
