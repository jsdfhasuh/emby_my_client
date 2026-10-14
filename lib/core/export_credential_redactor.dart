import 'dart:convert';

import 'token_redactor.dart';

/// Redacts only the Android export copy. URL query values are all treated as
/// private, including values reached through nested percent/JSON encoding.
abstract final class ExportCredentialRedactor {
  static const marker = '<redacted>';
  static final _fields = RegExp(
    r'''(?<![a-z0-9_-])(?:password|passwd|pwd|pw|secret|client_secret|credential|credentials|token|access_token|accesstoken|refresh_token|x-emby-token|api_key|apikey|signature|sig|session_id|sessionid)["']?\s*[:=]\s*(?:"([^"\r\n]*)"|'([^'\r\n]*)'|([^\s&;,}\[\]"']+))''',
    caseSensitive: false,
  );
  static final _arrays = RegExp(
    r'''(?<![a-z0-9_-])(?:password|passwd|pwd|pw|secret|credential|credentials|token|access_token|refresh_token|authorization|cookie|set-cookie)["']?\s*[:=]\s*(\[[^\r\n]*?\])''',
    caseSensitive: false,
  );
  static final _headers = RegExp(
    r'''(?<![a-z0-9_-])(?:authorization|proxy-authorization|cookie|set-cookie)["']?\s*[:=]\s*(?:"([^"\r\n]*)"|'([^'\r\n]*)'|([^\r\n}\]]+))''',
    caseSensitive: false,
  );
  static final _query = RegExp(
    r'''[?&;][a-z0-9_%.-]+=([^\s&#"'<>\]\}]+)''',
    caseSensitive: false,
  );
  static final _userInfo = RegExp(
    r'''https?://([^/\s@]+)@''',
    caseSensitive: false,
  );
  static final _basic = RegExp(
    r'\b(?:Basic|Bearer)\s+([a-z0-9+/=_-]+)',
    caseSensitive: false,
  );

  static String redact(String raw) {
    final input = TokenRedactor.redact(raw);
    final views = <_ExportView>[_ExportView.original(input)];
    while (true) {
      final next = views.last.decode();
      if (next.text == views.last.text) break;
      views.add(next);
    }
    final ranges = <(int, int)>[];
    for (final view in views) {
      for (final pattern in [
        _fields,
        _arrays,
        _headers,
        _query,
        _userInfo,
        _basic,
      ]) {
        for (final match in pattern.allMatches(view.text)) {
          for (var group = 1; group <= match.groupCount; group++) {
            final value = match[group];
            if (value == null ||
                value.isEmpty ||
                value.trim() == marker ||
                value.trim() == TokenRedactor.marker) {
              continue;
            }
            final suffix = pattern == _userInfo
                ? 1
                : ((pattern == _fields || pattern == _headers) && group < 3
                      ? 1
                      : 0);
            final start = match.end - value.length - suffix;
            ranges.add((
              view.starts[start],
              view.ends[start + value.length - 1],
            ));
          }
        }
      }
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final range in ranges) {
      if (merged.isNotEmpty && range.$1 <= merged.last.$2) {
        final last = merged.removeLast();
        merged.add((last.$1, range.$2 > last.$2 ? range.$2 : last.$2));
      } else {
        merged.add(range);
      }
    }
    final result = StringBuffer();
    var offset = 0;
    for (final range in merged) {
      result.write(input.substring(offset, range.$1));
      result.write(marker);
      offset = range.$2;
    }
    result.write(input.substring(offset));
    return TokenRedactor.escapeControls(result.toString(), preserveLines: true);
  }
}

class _ExportView {
  _ExportView(this.text, this.starts, this.ends);
  factory _ExportView.original(String text) => _ExportView(
    text,
    List.generate(text.length, (i) => i),
    List.generate(text.length, (i) => i + 1),
  );
  final String text;
  final List<int> starts, ends;
  _ExportView decode() {
    final output = StringBuffer();
    final first = <int>[], last = <int>[];
    final escape = RegExp(r'%[0-9a-fA-F]{2}|\\u[0-9a-fA-F]{4}|\\["\\/nrt]');
    var at = 0;
    for (final match in escape.allMatches(text)) {
      if (match.start < at) continue;
      for (var i = at; i < match.start; i++) {
        output.write(text[i]);
        first.add(starts[i]);
        last.add(ends[i]);
      }
      var end = match.end;
      String decoded;
      final raw = match[0]!;
      if (raw.startsWith('%')) {
        final byte = int.parse(raw.substring(1), radix: 16);
        final size = byte < 128
            ? 1
            : byte >= 240
            ? 4
            : byte >= 224
            ? 3
            : 2;
        final bytes = <int>[byte];
        while (bytes.length < size &&
            end + 3 <= text.length &&
            RegExp(
              r'^%[0-9a-fA-F]{2}$',
            ).hasMatch(text.substring(end, end + 3))) {
          bytes.add(int.parse(text.substring(end + 1, end + 3), radix: 16));
          end += 3;
        }
        try {
          decoded = utf8.decode(bytes);
        } catch (_) {
          decoded = raw;
          end = match.end;
        }
      } else if (raw.startsWith(r'\u')) {
        decoded = String.fromCharCode(int.parse(raw.substring(2), radix: 16));
      } else {
        decoded = switch (raw[1]) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          _ => raw[1],
        };
      }
      output.write(decoded);
      for (var i = 0; i < decoded.length; i++) {
        first.add(starts[match.start]);
        last.add(ends[end - 1]);
      }
      at = end;
    }
    for (var i = at; i < text.length; i++) {
      output.write(text[i]);
      first.add(starts[i]);
      last.add(ends[i]);
    }
    return _ExportView(output.toString(), first, last);
  }
}
