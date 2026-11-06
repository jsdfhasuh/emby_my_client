import 'dart:convert';

import 'package:emby_my_client/core/export_credential_redactor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final field in [
    'password',
    'passwd',
    'pwd',
    'pw',
    'secret',
    'client_secret',
    'credential',
    'credentials',
    'token',
    'access_token',
    'accesstoken',
    'refresh_token',
    'x-emby-token',
    'api_key',
    'apikey',
    'signature',
    'sig',
    'session_id',
    'sessionid',
  ]) {
    for (final quote in ['"', "'"]) {
      test('unfinished $field with $quote is redacted through EOF', () {
        final prefix = 'Service failed: {$quote$field$quote:$quote';
        final safe = ExportCredentialRedactor.redact(
          '${prefix}private-credential',
        );

        expect(safe, '$prefix<redacted>');
        expect(ExportCredentialRedactor.redact(safe), safe);
      });
    }
  }

  test('unfinished quoted credential consumes a multiline tail', () {
    const prefix = 'Service failed\n{"client_secret":"';
    final safe = ExportCredentialRedactor.redact(
      '${prefix}private-first-line\nprivate-second-line\n',
    );

    expect(safe, '$prefix<redacted>');
    expect(ExportCredentialRedactor.redact(safe), safe);
  });

  test('unfinished encoded credentials retain original safe source spans', () {
    const prefix = '{"client_secret":"';
    const value = 'private/se&cret';
    for (final encode in <String Function(String)>[
      Uri.encodeComponent,
      (text) => Uri.encodeComponent(Uri.encodeComponent(text)),
      _jsonFragment,
      (text) => _jsonFragment(_jsonFragment(text)),
      (text) => Uri.encodeComponent(_jsonFragment(text)),
      (text) => _jsonFragment(Uri.encodeComponent(text)),
    ]) {
      final safe = ExportCredentialRedactor.redact(encode('$prefix$value'));

      expect(safe, '${encode(prefix)}<redacted>');
      expect(ExportCredentialRedactor.redact(safe), safe);
    }
  });

  test('complete credentials stay redacted without changing safe messages', () {
    const raw =
        '{"password":"private-password","client_secret":"private-secret",'
        '"message":"Storage read failed"}';
    final safe = ExportCredentialRedactor.redact(raw);

    expect(
      safe,
      '{"password":"<redacted>","client_secret":"<redacted>",'
      '"message":"Storage read failed"}',
    );
    expect(ExportCredentialRedactor.redact(safe), safe);
    const message = 'Storage read failed for /media/movie.mp4';
    expect(ExportCredentialRedactor.redact(message), message);
  });
}

String _jsonFragment(String text) {
  final encoded = jsonEncode(text);
  return encoded.substring(1, encoded.length - 1);
}
