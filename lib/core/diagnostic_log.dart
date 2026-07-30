import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class DiagnosticLog {
  DiagnosticLog._();

  static final DiagnosticLog instance = DiagnosticLog._();
  static const _fileName = 'emby_client_diagnostics.log';
  static const _maxFileBytes = 750 * 1024;

  File? _file;
  Future<void> _pendingWrite = Future.value();

  Future<void> initialize() async {
    try {
      final directory = await getApplicationSupportDirectory();
      await directory.create(recursive: true);
      final file = File('${directory.path}${Platform.pathSeparator}$_fileName');
      if (await file.exists() && await file.length() > _maxFileBytes) {
        await file.writeAsString('');
      }
      _file = file;
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

  String? get path => _file?.path;

  void _write(String level, String component, String message) {
    final clean = redact(message).replaceAll('\r', '');
    final timestamp = DateTime.now().toIso8601String();
    final line = '$timestamp [$level] [$component] $clean\n';
    debugPrint(line.trimRight());

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

  @visibleForTesting
  static String redact(String value) {
    var result = value;
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
      RegExp(r'(Bearer\s+)[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      (match) => '${match[1]}<redacted>',
    );
    return result;
  }
}
