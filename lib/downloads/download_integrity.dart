import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class DownloadIntegrity {
  const DownloadIntegrity._({required this.algorithm, required this.digest});

  final String algorithm;
  final String digest;

  static DownloadIntegrity? fromStored(String? algorithm, String? digest) {
    if (algorithm == null || digest == null) return null;
    return _fromEncoded(algorithm, digest);
  }

  static DownloadIntegrity? _fromEncoded(String algorithm, String encoded) {
    final normalizedAlgorithm = algorithm.trim().toLowerCase();
    final expectedLength = switch (normalizedAlgorithm) {
      'sha-256' => 32,
      'md5' => 16,
      _ => null,
    };
    if (expectedLength == null || encoded.isEmpty) return null;
    try {
      final bytes = base64Decode(encoded);
      if (bytes.length != expectedLength) return null;
      return DownloadIntegrity._(
        algorithm: normalizedAlgorithm,
        digest: base64Encode(bytes),
      );
    } on FormatException {
      return null;
    }
  }

  int get strength => switch (algorithm) {
    'sha-256' => 2,
    'md5' => 1,
    _ => 0,
  };

  @override
  bool operator ==(Object other) =>
      other is DownloadIntegrity &&
      other.algorithm == algorithm &&
      other.digest == digest;

  @override
  int get hashCode => Object.hash(algorithm, digest);
}

DownloadIntegrity? downloadIntegrityFromHeaders(
  Map<String, String> headers, {
  required bool isPartialResponse,
}) {
  final candidates = <DownloadIntegrity>[];
  _addDigestHeader(candidates, headers['repr-digest']);
  _addDigestHeader(candidates, headers['digest']);
  if (!isPartialResponse) {
    _addDigestHeader(candidates, headers['content-digest']);
    final contentMd5 = headers['content-md5'];
    if (contentMd5 != null) {
      final parsed = DownloadIntegrity._fromEncoded('md5', contentMd5.trim());
      if (parsed != null) candidates.add(parsed);
    }
  }
  if (candidates.isEmpty) return null;
  var preferred = candidates.first;
  for (final candidate in candidates.skip(1)) {
    if (candidate.strength > preferred.strength) preferred = candidate;
  }
  return preferred;
}

DownloadIntegrity preferDownloadIntegrity(
  DownloadIntegrity current,
  DownloadIntegrity candidate,
) => candidate.strength > current.strength ? candidate : current;

bool downloadIntegrityChanged(
  DownloadIntegrity current,
  DownloadIntegrity candidate,
) =>
    current.algorithm == candidate.algorithm &&
    current.digest != candidate.digest;

Future<bool> verifyDownloadIntegrity(
  File file,
  DownloadIntegrity integrity,
) async {
  final hash = switch (integrity.algorithm) {
    'sha-256' => sha256,
    'md5' => md5,
    _ => throw ArgumentError.value(
      integrity.algorithm,
      'integrity.algorithm',
      'Unsupported download integrity algorithm',
    ),
  };
  final actual = await hash.bind(file.openRead()).first;
  return base64Encode(actual.bytes) == integrity.digest;
}

void _addDigestHeader(List<DownloadIntegrity> output, String? value) {
  if (value == null || value.trim().isEmpty) return;
  for (final member in value.split(',')) {
    final separator = member.indexOf('=');
    if (separator <= 0) continue;
    final algorithm = member.substring(0, separator).trim().toLowerCase();
    var encoded = member.substring(separator + 1).trim();
    final parameter = encoded.indexOf(';');
    if (parameter >= 0) encoded = encoded.substring(0, parameter).trim();
    if (encoded.length >= 2 &&
        ((encoded.startsWith(':') && encoded.endsWith(':')) ||
            (encoded.startsWith('"') && encoded.endsWith('"')))) {
      encoded = encoded.substring(1, encoded.length - 1);
    }
    final parsed = DownloadIntegrity._fromEncoded(algorithm, encoded);
    if (parsed != null) output.add(parsed);
  }
}
