import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:emby_my_client/downloads/download_integrity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prefers SHA-256 when a Digest header contains multiple algorithms', () {
    final sha256Digest = _digest(sha256);
    final md5Digest = _digest(md5);

    final integrity = downloadIntegrityFromHeaders({
      'digest': 'md5=$md5Digest, sha-256=$sha256Digest',
    }, isPartialResponse: false);

    expect(integrity?.algorithm, 'sha-256');
    expect(integrity?.digest, sha256Digest);
  });

  test('parses structured Repr-Digest on a partial response', () {
    final digest = _digest(sha256);

    final integrity = downloadIntegrityFromHeaders({
      'repr-digest': 'sha-256=:$digest:',
    }, isPartialResponse: true);

    expect(integrity?.algorithm, 'sha-256');
    expect(integrity?.digest, digest);
  });

  test('uses a valid Content-MD5 for a complete response', () {
    final digest = _digest(md5);

    final integrity = downloadIntegrityFromHeaders({
      'content-md5': digest,
    }, isPartialResponse: false);

    expect(integrity?.algorithm, 'md5');
    expect(integrity?.digest, digest);
  });

  test('does not treat partial content digests as whole-file digests', () {
    final sha256Digest = _digest(sha256);
    final md5Digest = _digest(md5);

    final integrity = downloadIntegrityFromHeaders({
      'content-digest': 'sha-256=:$sha256Digest:',
      'content-md5': md5Digest,
    }, isPartialResponse: true);

    expect(integrity, isNull);
  });

  test('ignores unsupported and malformed digest values', () {
    final integrity = downloadIntegrityFromHeaders(const {
      'digest': 'sha-512=not-base64, sha-256=dG9vLXNob3J0',
      'content-md5': 'not-base64',
    }, isPartialResponse: false);

    expect(integrity, isNull);
  });
}

String _digest(Hash hash) => base64Encode(hash.convert(_bytes).bytes);

const _bytes = <int>[1, 2, 3, 4, 5];
