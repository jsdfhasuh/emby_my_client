import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'diagnostic_log.dart';
import 'sign_in_diagnostics.dart';

const _maxSafeReportBytes = 256 * 1024;
const _maxSafeReportRecords = 1000;

class SafeDiagnosticExportException implements Exception {
  const SafeDiagnosticExportException(this.code);

  static const read = 'DIAG-EXPORT-READ';
  static const unsafe = 'DIAG-EXPORT-UNSAFE';
  static const write = 'DIAG-EXPORT-WRITE';
  static const share = 'DIAG-EXPORT-SHARE';
  static const busy = 'DIAG-EXPORT-BUSY';

  final String code;

  @override
  String toString() => code;
}

class SafeDiagnosticMetadata {
  const SafeDiagnosticMetadata({
    required this.appVersion,
    required this.buildNumber,
  });

  final String appVersion;
  final String buildNumber;
}

abstract interface class SafeDiagnosticMetadataProvider {
  Future<SafeDiagnosticMetadata> read();
}

class MethodChannelSafeDiagnosticMetadataProvider
    implements SafeDiagnosticMetadataProvider {
  const MethodChannelSafeDiagnosticMetadataProvider();

  static const channel = MethodChannel('emby_my_client/safe_diagnostic_export');

  @override
  Future<SafeDiagnosticMetadata> read() async {
    try {
      final values = await channel.invokeMapMethod<String, Object?>('metadata');
      final appVersion = values?['appVersion'];
      final buildNumber = values?['buildNumber'];
      if (appVersion is! String || buildNumber is! String) {
        throw const SafeDiagnosticExportException(
          SafeDiagnosticExportException.unsafe,
        );
      }
      return SafeDiagnosticMetadata(
        appVersion: appVersion,
        buildNumber: buildNumber,
      );
    } on SafeDiagnosticExportException {
      rethrow;
    } catch (_) {
      throw const SafeDiagnosticExportException(
        SafeDiagnosticExportException.unsafe,
      );
    }
  }
}

abstract interface class SafeDiagnosticShareGateway {
  Future<SafeDiagnosticShareOutcome> share(
    SafeDiagnosticReport report, {
    required SafeDiagnosticPopoverAnchor anchor,
  });
}

enum SafeDiagnosticShareOutcome { completed, cancelled }

class SafeDiagnosticPopoverAnchor {
  const SafeDiagnosticPopoverAnchor({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  Map<String, Object> toArguments() => <String, Object>{
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };
}

class MethodChannelSafeDiagnosticShareGateway
    implements SafeDiagnosticShareGateway {
  const MethodChannelSafeDiagnosticShareGateway();

  @override
  Future<SafeDiagnosticShareOutcome> share(
    SafeDiagnosticReport report, {
    required SafeDiagnosticPopoverAnchor anchor,
  }) async {
    try {
      final outcome = await MethodChannelSafeDiagnosticMetadataProvider.channel
          .invokeMethod<String>('share', <String, Object>{
            'content': report.content,
            ...anchor.toArguments(),
          });
      return switch (outcome) {
        'completed' => SafeDiagnosticShareOutcome.completed,
        'cancelled' => SafeDiagnosticShareOutcome.cancelled,
        _ => throw const SafeDiagnosticExportException(
          SafeDiagnosticExportException.unsafe,
        ),
      };
    } on PlatformException catch (error) {
      throw SafeDiagnosticExportException(_nativeErrorCode(error.code));
    } catch (_) {
      rethrow;
    }
  }

  static String _nativeErrorCode(String code) => switch (code) {
    SafeDiagnosticExportException.unsafe =>
      SafeDiagnosticExportException.unsafe,
    SafeDiagnosticExportException.write => SafeDiagnosticExportException.write,
    SafeDiagnosticExportException.busy => SafeDiagnosticExportException.busy,
    SafeDiagnosticExportException.share => SafeDiagnosticExportException.share,
    _ => SafeDiagnosticExportException.share,
  };
}

class SafeDiagnosticReport {
  const SafeDiagnosticReport({
    required this.filename,
    required this.content,
    required this.sha256,
    required this.appVersion,
    required this.buildNumber,
    required this.recordCount,
    required this.truncated,
    required this.records,
  });

  final String filename;
  final String content;
  final String sha256;
  final String appVersion;
  final String buildNumber;
  final int recordCount;
  final bool truncated;
  final List<SafeDiagnosticRecord> records;
}

class SafeDiagnosticExportService {
  SafeDiagnosticExportService({
    SafeDiagnosticEventSource? source,
    SafeDiagnosticMetadataProvider? metadataProvider,
    String? appVersion,
    String? buildNumber,
  }) : _source = source ?? DiagnosticLog.instance,
       _metadataProvider =
           metadataProvider ??
           const MethodChannelSafeDiagnosticMetadataProvider(),
       _metadata = appVersion == null && buildNumber == null
           ? null
           : SafeDiagnosticMetadata(
               appVersion: appVersion ?? '',
               buildNumber: buildNumber ?? '',
             );

  final SafeDiagnosticEventSource _source;
  final SafeDiagnosticMetadataProvider _metadataProvider;
  final SafeDiagnosticMetadata? _metadata;

  Future<SafeDiagnosticReport> buildReport({DateTime? generatedAtUtc}) async {
    final metadata = await _readMetadata();
    _validateMetadata(metadata);
    final records = await _readRecords();
    final selected = List<SafeDiagnosticRecord>.of(records);
    var truncated = false;
    if (selected.length > _maxSafeReportRecords) {
      selected.removeRange(0, selected.length - _maxSafeReportRecords);
      truncated = true;
    }

    final timestamp = (generatedAtUtc ?? DateTime.now()).toUtc();
    while (true) {
      final content = _encodeReport(
        metadata: metadata,
        generatedAtUtc: timestamp,
        records: selected,
        truncated: truncated,
      );
      if (utf8.encode(content).length <= _maxSafeReportBytes) {
        validateSnapshot(content);
        return SafeDiagnosticReport(
          filename: _filename(metadata.buildNumber, timestamp),
          content: content,
          sha256: sha256.convert(utf8.encode(content)).toString(),
          appVersion: metadata.appVersion,
          buildNumber: metadata.buildNumber,
          recordCount: selected.length,
          truncated: truncated,
          records: List<SafeDiagnosticRecord>.unmodifiable(selected),
        );
      }
      if (selected.isEmpty) {
        throw const SafeDiagnosticExportException(
          SafeDiagnosticExportException.unsafe,
        );
      }
      selected.removeAt(0);
      truncated = true;
    }
  }

  Future<void> clearSafeEvents() async {
    try {
      await _source.clearSafeEvents();
    } catch (_) {
      throw const SafeDiagnosticExportException(
        SafeDiagnosticExportException.write,
      );
    }
  }

  @visibleForTesting
  static void validateSnapshot(String content) {
    if (utf8.encode(content).length > _maxSafeReportBytes ||
        content.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw const SafeDiagnosticExportException(
        SafeDiagnosticExportException.unsafe,
      );
    }
    final decoded = _decodeMap(content);
    const keys = {
      'schema',
      'generatedAtUtc',
      'appVersion',
      'buildNumber',
      'platform',
      'recordCount',
      'truncated',
      'records',
    };
    if (decoded.length != keys.length ||
        !decoded.keys.toSet().containsAll(keys)) {
      throw const SafeDiagnosticExportException(
        SafeDiagnosticExportException.unsafe,
      );
    }
    final schema = decoded['schema'];
    final generatedAtUtc = decoded['generatedAtUtc'];
    final appVersion = decoded['appVersion'];
    final buildNumber = decoded['buildNumber'];
    final platform = decoded['platform'];
    final recordCount = decoded['recordCount'];
    final truncated = decoded['truncated'];
    final recordsValue = decoded['records'];
    if (schema != 'emby-safe-diagnostics/v1' ||
        generatedAtUtc is! String ||
        appVersion is! String ||
        buildNumber is! String ||
        platform != 'iPadOS' ||
        recordCount is! int ||
        truncated is! bool ||
        recordsValue is! List ||
        !_isUtcTimestamp(generatedAtUtc) ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(appVersion) ||
        !RegExp(r'^\d+$').hasMatch(buildNumber) ||
        recordCount != recordsValue.length ||
        recordCount < 0 ||
        recordCount > _maxSafeReportRecords) {
      throw const SafeDiagnosticExportException(
        SafeDiagnosticExportException.unsafe,
      );
    }
    try {
      for (final value in recordsValue) {
        SafeDiagnosticRecord.fromJson(value);
      }
    } on SafeDiagnosticValidationException {
      throw const SafeDiagnosticExportException(
        SafeDiagnosticExportException.unsafe,
      );
    }
    if (_containsSensitiveContent(content)) {
      throw const SafeDiagnosticExportException(
        SafeDiagnosticExportException.unsafe,
      );
    }
  }

  Future<SafeDiagnosticMetadata> _readMetadata() async {
    try {
      return _metadata ?? await _metadataProvider.read();
    } on SafeDiagnosticExportException {
      rethrow;
    } catch (_) {
      throw const SafeDiagnosticExportException(
        SafeDiagnosticExportException.unsafe,
      );
    }
  }

  Future<List<SafeDiagnosticRecord>> _readRecords() async {
    try {
      return List<SafeDiagnosticRecord>.of(await _source.readSafeEvents());
    } on SafeDiagnosticValidationException {
      throw const SafeDiagnosticExportException(
        SafeDiagnosticExportException.unsafe,
      );
    } on SafeDiagnosticExportException {
      rethrow;
    } catch (_) {
      throw const SafeDiagnosticExportException(
        SafeDiagnosticExportException.read,
      );
    }
  }

  static void _validateMetadata(SafeDiagnosticMetadata metadata) {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(metadata.appVersion) ||
        !RegExp(r'^\d+$').hasMatch(metadata.buildNumber)) {
      throw const SafeDiagnosticExportException(
        SafeDiagnosticExportException.unsafe,
      );
    }
  }

  static String _encodeReport({
    required SafeDiagnosticMetadata metadata,
    required DateTime generatedAtUtc,
    required List<SafeDiagnosticRecord> records,
    required bool truncated,
  }) => jsonEncode(<String, Object>{
    'schema': 'emby-safe-diagnostics/v1',
    'generatedAtUtc': generatedAtUtc.toUtc().toIso8601String(),
    'appVersion': metadata.appVersion,
    'buildNumber': metadata.buildNumber,
    'platform': 'iPadOS',
    'recordCount': records.length,
    'truncated': truncated,
    'records': records.map((record) => record.toJson()).toList(growable: false),
  });

  static String _filename(String buildNumber, DateTime timestamp) {
    final utc = timestamp.toUtc();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${utc.year.toString().padLeft(4, '0')}'
        '${twoDigits(utc.month)}${twoDigits(utc.day)}T'
        '${twoDigits(utc.hour)}${twoDigits(utc.minute)}${twoDigits(utc.second)}Z';
    return 'emby-safe-diagnostics-v1-b$buildNumber-$stamp.json';
  }

  static Map<String, Object?> _decodeMap(String content) {
    try {
      final value = jsonDecode(content);
      if (value is! Map) throw const FormatException();
      final map = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key is! String) throw const FormatException();
        map[entry.key as String] = entry.value;
      }
      return map;
    } catch (_) {
      throw const SafeDiagnosticExportException(
        SafeDiagnosticExportException.unsafe,
      );
    }
  }

  static bool _isUtcTimestamp(String value) {
    final parsed = DateTime.tryParse(value);
    return parsed != null && parsed.isUtc && parsed.toIso8601String() == value;
  }

  static bool _containsSensitiveContent(String value) {
    final patterns = <RegExp>[
      RegExp(
        r'''\b(?:password|pw|username|account|accountname|accesstoken|token|x-emby-token|api_key|authorization|basic|bearer|cookie|deviceid|device_id|serverurl|baseurl|address|host|hostname)\b''',
        caseSensitive: false,
      ),
      RegExp(r'\b(?:url|ip)\b', caseSensitive: false),
      RegExp(
        r'''"(?:password|pw|account|accountName|username|accessToken|token|api_key|x-emby-token|authorization|cookie|deviceId|serverUrl|baseUrl)"\s*:''',
        caseSensitive: false,
      ),
      RegExp(
        r'(?:https?|wss?)://|(?:https?|wss?)%3a%2f%2f',
        caseSensitive: false,
      ),
      RegExp(r'(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)'),
      RegExp(
        r'\b[0-9a-f]{1,4}(?::[0-9a-f]{0,4}){2,7}\b|(?<![0-9a-f])::1\b',
        caseSensitive: false,
      ),
      RegExp(
        r'''\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}:\d{2,5}\b|\b(?:localhost|emby):\d{2,5}\b|\[[0-9a-f:]+\]:\d{2,5}''',
        caseSensitive: false,
      ),
      RegExp(r'\b(?:localhost|emby):\d{2,5}\b', caseSensitive: false),
      RegExp(
        r'''(?:[a-z]:\\|/(?:home|users|private|var|tmp|data|documents|library)(?:/|\\)|\\Users\\|\\private\\|\\var\\|\\tmp\\)''',
        caseSensitive: false,
      ),
      RegExp(r'\bsession\s*(?:json|object|data)\b', caseSensitive: false),
      RegExp(
        r'''"session(?:json|object|data)?"\s*:|\b(?:request|response)\s+(?:body|headers?)\b|"(?:request|response)(?:body|headers?)"\s*:''',
        caseSensitive: false,
      ),
      RegExp(r'\\(?:r|n|u000[0-9a-f]{1,4})', caseSensitive: false),
    ];
    return patterns.any((pattern) => pattern.hasMatch(value));
  }
}
