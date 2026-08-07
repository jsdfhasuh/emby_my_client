import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'diagnostic_log.dart';
import 'safe_diagnostic_export.dart';

const _maxFullDiagnosticBytes = 750 * 1024;

class FullDiagnosticExportException implements Exception {
  const FullDiagnosticExportException(this.code);

  static const read = 'FULL-DIAG-READ';
  static const unsafe = 'FULL-DIAG-UNSAFE';
  static const write = 'FULL-DIAG-WRITE';
  static const share = 'FULL-DIAG-SHARE';
  static const busy = 'FULL-DIAG-BUSY';

  final String code;

  @override
  String toString() => code;
}

enum FullDiagnosticShareOutcome { completed, cancelled }

abstract interface class FullDiagnosticShareGateway {
  Future<FullDiagnosticShareOutcome> share(
    FullDiagnosticReport report, {
    required SafeDiagnosticPopoverAnchor anchor,
  });
}

class MethodChannelFullDiagnosticShareGateway
    implements FullDiagnosticShareGateway {
  const MethodChannelFullDiagnosticShareGateway();

  static const channel = MethodChannel('emby_my_client/full_diagnostic_export');

  @override
  Future<FullDiagnosticShareOutcome> share(
    FullDiagnosticReport report, {
    required SafeDiagnosticPopoverAnchor anchor,
  }) async {
    try {
      final outcome = await channel.invokeMethod<String>(
        'fullShare',
        <String, Object>{'content': report.content, ...anchor.toArguments()},
      );
      return switch (outcome) {
        'completed' => FullDiagnosticShareOutcome.completed,
        'cancelled' => FullDiagnosticShareOutcome.cancelled,
        _ => throw const FullDiagnosticExportException(
          FullDiagnosticExportException.unsafe,
        ),
      };
    } on PlatformException catch (error) {
      throw FullDiagnosticExportException(_nativeErrorCode(error.code));
    } catch (_) {
      rethrow;
    }
  }

  static String _nativeErrorCode(String code) => switch (code) {
    FullDiagnosticExportException.unsafe =>
      FullDiagnosticExportException.unsafe,
    FullDiagnosticExportException.write => FullDiagnosticExportException.write,
    FullDiagnosticExportException.busy => FullDiagnosticExportException.busy,
    FullDiagnosticExportException.share => FullDiagnosticExportException.share,
    _ => FullDiagnosticExportException.share,
  };
}

class FullDiagnosticReport {
  const FullDiagnosticReport({
    required this.filename,
    required this.content,
    required this.sha256,
    required this.appVersion,
    required this.buildNumber,
    required this.truncated,
    required this.lineCount,
  });

  final String filename;
  final String content;
  final String sha256;
  final String appVersion;
  final String buildNumber;
  final bool truncated;
  final int lineCount;
}

class FullDiagnosticExportService {
  FullDiagnosticExportService({
    Future<String> Function()? readLog,
    SafeDiagnosticMetadataProvider? metadataProvider,
    String? appVersion,
    String? buildNumber,
  }) : _readLog = readLog ?? DiagnosticLog.instance.read,
       _metadataProvider =
           metadataProvider ??
           const MethodChannelSafeDiagnosticMetadataProvider(),
       _metadata = appVersion == null && buildNumber == null
           ? null
           : SafeDiagnosticMetadata(
               appVersion: appVersion ?? '',
               buildNumber: buildNumber ?? '',
             );

  final Future<String> Function() _readLog;
  final SafeDiagnosticMetadataProvider _metadataProvider;
  final SafeDiagnosticMetadata? _metadata;

  Future<FullDiagnosticReport> buildReport({DateTime? generatedAtUtc}) async {
    final metadata = await _readMetadata();
    _validateMetadata(metadata);

    final rawLog = await _readRawLog();
    late final String redactedLog;
    try {
      redactedLog = FullDiagnosticRedactor.redact(DiagnosticLog.redact(rawLog));
    } on FullDiagnosticExportException {
      rethrow;
    } catch (_) {
      throw const FullDiagnosticExportException(
        FullDiagnosticExportException.unsafe,
      );
    }

    final lines = _completeLines(redactedLog);
    final timestamp = (generatedAtUtc ?? DateTime.now()).toUtc();
    var firstLine = 0;
    var bodyBytes = _bodyByteLength(lines);
    final headerBytes = _headerByteLength(
      metadata: metadata,
      generatedAtUtc: timestamp,
    );
    while (headerBytes + bodyBytes > _maxFullDiagnosticBytes &&
        firstLine < lines.length) {
      bodyBytes -= utf8.encode(lines[firstLine]).length + 1;
      firstLine++;
    }
    if (headerBytes + bodyBytes > _maxFullDiagnosticBytes) {
      throw const FullDiagnosticExportException(
        FullDiagnosticExportException.unsafe,
      );
    }

    final selected = lines.sublist(firstLine);
    final truncated = firstLine > 0;
    final body = _encodeBody(selected);
    final content = _encodeReport(
      metadata: metadata,
      generatedAtUtc: timestamp,
      body: body,
      truncated: truncated,
    );
    validateSnapshot(content);
    final digest = sha256.convert(utf8.encode(body)).toString();
    return FullDiagnosticReport(
      filename: _filename(metadata.buildNumber, timestamp),
      content: content,
      sha256: digest,
      appVersion: metadata.appVersion,
      buildNumber: metadata.buildNumber,
      truncated: truncated,
      lineCount: selected.length,
    );
  }

  Future<SafeDiagnosticMetadata> _readMetadata() async {
    try {
      return _metadata ?? await _metadataProvider.read();
    } catch (_) {
      throw const FullDiagnosticExportException(
        FullDiagnosticExportException.unsafe,
      );
    }
  }

  Future<String> _readRawLog() async {
    try {
      return await _readLog();
    } catch (_) {
      throw const FullDiagnosticExportException(
        FullDiagnosticExportException.read,
      );
    }
  }

  static void _validateMetadata(SafeDiagnosticMetadata metadata) {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(metadata.appVersion) ||
        !RegExp(r'^\d+$').hasMatch(metadata.buildNumber)) {
      throw const FullDiagnosticExportException(
        FullDiagnosticExportException.unsafe,
      );
    }
  }

  static List<String> _completeLines(String value) {
    final normalized = value.replaceAll('\r', '');
    if (normalized.isEmpty) return const <String>[];
    final lines = normalized.split('\n');
    if (lines.last.isEmpty) lines.removeLast();
    return lines;
  }

  static String _encodeBody(List<String> lines) =>
      lines.isEmpty ? '' : '${lines.join('\n')}\n';

  static int _bodyByteLength(List<String> lines) => lines.fold<int>(
    lines.length,
    (total, line) => total + utf8.encode(line).length,
  );

  static int _headerByteLength({
    required SafeDiagnosticMetadata metadata,
    required DateTime generatedAtUtc,
  }) {
    final placeholder = List<String>.filled(64, '0').join();
    final header = [
      'schema=emby-full-diagnostics/v1',
      'generatedAtUtc=${generatedAtUtc.toUtc().toIso8601String()}',
      'appVersion=${metadata.appVersion}',
      'buildNumber=${metadata.buildNumber}',
      'platform=iPadOS',
      'redaction=best-effort',
      'truncated=false',
      'sha256=$placeholder',
    ].join('\n');
    return utf8.encode('$header\n').length;
  }

  static String _encodeReport({
    required SafeDiagnosticMetadata metadata,
    required DateTime generatedAtUtc,
    required String body,
    required bool truncated,
  }) {
    final digest = sha256.convert(utf8.encode(body)).toString();
    return [
      'schema=emby-full-diagnostics/v1',
      'generatedAtUtc=${generatedAtUtc.toUtc().toIso8601String()}',
      'appVersion=${metadata.appVersion}',
      'buildNumber=${metadata.buildNumber}',
      'platform=iPadOS',
      'redaction=best-effort',
      'truncated=$truncated',
      'sha256=$digest',
      body,
    ].join('\n');
  }

  static String _filename(String buildNumber, DateTime timestamp) {
    final utc = timestamp.toUtc();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${utc.year.toString().padLeft(4, '0')}'
        '${twoDigits(utc.month)}${twoDigits(utc.day)}T'
        '${twoDigits(utc.hour)}${twoDigits(utc.minute)}'
        '${twoDigits(utc.second)}Z';
    return 'emby-full-diagnostics-b$buildNumber-$stamp.txt';
  }

  @visibleForTesting
  static void validateSnapshot(String content) {
    if (utf8.encode(content).length > _maxFullDiagnosticBytes ||
        content.contains('\r') ||
        content.codeUnits.any(
          (unit) =>
              (unit < 0x20 && unit != 0x09 && unit != 0x0a) || unit == 0x7f,
        )) {
      throw const FullDiagnosticExportException(
        FullDiagnosticExportException.unsafe,
      );
    }
    final lines = content.split('\n');
    const keys = [
      'schema',
      'generatedAtUtc',
      'appVersion',
      'buildNumber',
      'platform',
      'redaction',
      'truncated',
      'sha256',
    ];
    if (lines.length < keys.length) {
      throw const FullDiagnosticExportException(
        FullDiagnosticExportException.unsafe,
      );
    }
    final header = <String, String>{};
    for (var index = 0; index < keys.length; index++) {
      final separator = lines[index].indexOf('=');
      if (separator <= 0 ||
          lines[index].substring(0, separator) != keys[index]) {
        throw const FullDiagnosticExportException(
          FullDiagnosticExportException.unsafe,
        );
      }
      header[keys[index]] = lines[index].substring(separator + 1);
    }
    final body = lines.skip(keys.length).join('\n');
    if (header['schema'] != 'emby-full-diagnostics/v1' ||
        header['platform'] != 'iPadOS' ||
        header['redaction'] != 'best-effort' ||
        !_isUtcTimestamp(header['generatedAtUtc']!) ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(header['appVersion']!) ||
        !RegExp(r'^\d+$').hasMatch(header['buildNumber']!) ||
        !{'true', 'false'}.contains(header['truncated']) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(header['sha256']!) ||
        sha256.convert(utf8.encode(body)).toString() != header['sha256'] ||
        FullDiagnosticRedactor.containsSensitiveContent(body)) {
      throw const FullDiagnosticExportException(
        FullDiagnosticExportException.unsafe,
      );
    }
  }

  static bool _isUtcTimestamp(String value) {
    final parsed = DateTime.tryParse(value);
    return parsed != null && parsed.isUtc && parsed.toIso8601String() == value;
  }
}

class FullDiagnosticRedactor {
  const FullDiagnosticRedactor._();

  static String redact(String value) {
    var result = value.replaceAll('<redacted-url>', '<redacted>');
    result = result.replaceAll('\r', '');
    result = result.replaceAllMapped(
      RegExp(
        r'^.*(?:password|pw|username|account|accountname|accesstoken|token|x-emby-token|api_key|authorization|basic|bearer|cookie|deviceid|device_id|serverurl|baseurl|address|host|hostname|url|ip).*$',
        caseSensitive: false,
        multiLine: true,
      ),
      (_) => '<redacted>',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'(?:password|pw|username|account|accountname|accesstoken|token|x-emby-token|api_key|authorization|cookie|deviceid|device_id|serverurl|baseurl|address|host|hostname|url|ip)\s*(?:=|:|%3d)\s*[^\s,}\]]+',
        caseSensitive: false,
      ),
      (_) => '<redacted>',
    );
    result = result.replaceAll(
      RegExp(r'(?:https?|wss?)://[^\s<>\"]+', caseSensitive: false),
      '<redacted>',
    );
    result = result.replaceAll(
      RegExp(r'(?:https?|wss?)%3a%2f%2f[^\s<>\"]+', caseSensitive: false),
      '<redacted>',
    );
    result = result.replaceAll(
      RegExp(r'(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)'),
      '<redacted>',
    );
    result = result.replaceAll(
      RegExp(r'\b(?:localhost|emby):\d{2,5}\b', caseSensitive: false),
      '<redacted>',
    );
    result = result.replaceAll(
      RegExp(r'\b[a-z0-9.-]+\.[a-z]{2,}:\d{2,5}\b', caseSensitive: false),
      '<redacted>',
    );
    result = result.replaceAll(
      RegExp(
        r'(?:[a-z]:[\\/]|[\\/](?:home|users|private|var|tmp|data|documents|library)[\\/])[^\s\r\n]*',
        caseSensitive: false,
      ),
      '<redacted>',
    );
    result = result.replaceAll(
      RegExp(
        r'\"session(?:json|object|data)?\"\s*:|\bsession\s+(?:json|object|data)\b|\bsession\s*[:=]\s*[\{\[]',
        caseSensitive: false,
      ),
      '<redacted>',
    );
    result = result.replaceAll(
      RegExp(
        r'\"(?:request|response)(?:body|headers?)\"\s*:|\b(?:request|response)\s+(?:body|headers?)\b',
        caseSensitive: false,
      ),
      '<redacted>',
    );
    if (containsSensitiveContent(result)) {
      throw const FullDiagnosticExportException(
        FullDiagnosticExportException.unsafe,
      );
    }
    return result;
  }

  @visibleForTesting
  static bool containsSensitiveContent(String value) {
    final patterns = <RegExp>[
      RegExp(
        r'\b(?:password|pw|username|account|accountname|accesstoken|token|x-emby-token|api_key|authorization|basic|bearer|cookie|deviceid|device_id|serverurl|baseurl|address|host|hostname|url|ip)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'(?:https?|wss?)://|(?:https?|wss?)%3a%2f%2f',
        caseSensitive: false,
      ),
      RegExp(r'(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)'),
      RegExp(r'\b(?:localhost|emby):\d{2,5}\b', caseSensitive: false),
      RegExp(r'\b[a-z0-9.-]+\.[a-z]{2,}:\d{2,5}\b', caseSensitive: false),
      RegExp(
        r'(?:[a-z]:[\\/]|[\\/](?:home|users|private|var|tmp|data|documents|library)[\\/])',
        caseSensitive: false,
      ),
      RegExp(
        r'\bsession\s*(?:json|object|data)\b|\bsession\s*[:=]\s*[\{\[]',
        caseSensitive: false,
      ),
      RegExp(
        r'\b(?:request|response)\s+(?:body|headers?)\b',
        caseSensitive: false,
      ),
    ];
    if (patterns.any((pattern) => pattern.hasMatch(value))) return true;
    return _containsIpv6(value);
  }

  static bool _containsIpv6(String value) {
    final candidates = RegExp(r'[0-9a-fA-F:]{2,}').allMatches(value);
    for (final match in candidates) {
      final candidate = match.group(0)!;
      if (!candidate.contains(':') || candidate.contains(':::')) continue;
      final compressed = candidate.contains('::');
      final groups =
          (compressed ? candidate.replaceFirst('::', ':') : candidate)
              .split(':')
              .where((group) => group.isNotEmpty)
              .toList();
      if (groups.every(
            (group) =>
                group.length <= 4 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(group),
          ) &&
          (compressed ? groups.length <= 7 : groups.length == 8)) {
        return true;
      }
    }
    return false;
  }
}
