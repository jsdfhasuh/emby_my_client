import 'dart:convert';

/// Sanitizes a display copy only. Decoded views carry source spans, so URL
/// spelling, query order, paths and non-token fields are never reserialized.
abstract final class TokenRedactor {
  static const marker = '<redacted-token>';
  static final Set<String> _known = {};
  static final _field = RegExp(
    r'''(?<![a-z0-9_-])(?:token|access_token|accesstoken|x-emby-token|api_key)["']?\s*[:=]\s*(?:"([^"]*)"|'([^']*)'|([^\s&;,}\[\]"']+))''',
    caseSensitive: false,
  );
  static final _bearer = RegExp(
    r'''\bBearer\s+([^\s,;"']+)''',
    caseSensitive: false,
  );
  static final _array = RegExp(
    r'''(?<![a-z0-9_-])(?:token|access_token|accesstoken|x-emby-token|api_key)["']?\s*[:=]\s*\[([^\]]*)\]''',
    caseSensitive: false,
  );

  static void register(String token) {
    if (token.isNotEmpty && token != marker) _known.add(token);
  }

  static void registerCredentials(String text) {
    // Opaque query values may contain non-UTF-8 bytes. Credential discovery
    // is diagnostic-only and must not invalidate an otherwise legal request.
    try {
      _registerCredentials(text);
    } catch (_) {
      // Named token fields are still sanitized by the source-span matcher.
    }
  }

  static void _registerCredentials(String text) {
    final uri = Uri.tryParse(text);
    if (uri != null && uri.hasScheme && uri.hasAuthority) {
      for (final entry in uri.queryParametersAll.entries) {
        if (const {
          'token',
          'access_token',
          'accesstoken',
          'x-emby-token',
          'api_key',
        }.contains(entry.key.toLowerCase())) {
          for (final value in entry.value) {
            register(value);
          }
        } else {
          for (final value in entry.value) {
            if (value.startsWith('http://') || value.startsWith('https://')) {
              registerCredentials(value);
            }
          }
        }
      }
      return;
    }
    try {
      final json = jsonDecode(text);
      if (json is Map) {
        for (final entry in json.entries) {
          if (const {
            'token',
            'access_token',
            'accesstoken',
            'x-emby-token',
            'api_key',
          }.contains(entry.key.toString().toLowerCase())) {
            for (final value
                in entry.value is List ? entry.value as List : [entry.value]) {
              if (value is String) register(value);
            }
          } else if (entry.value is String) {
            registerCredentials(entry.value as String);
          }
        }
        return;
      }
    } catch (_) {
      /* Header text is not JSON. */
    }
    var view = _TokenView.original(text);
    while (true) {
      final next = view.decode();
      if (next.text == view.text) break;
      view = next;
    }
    for (final pattern in [_field, _bearer]) {
      for (final match in pattern.allMatches(view.text)) {
        for (var i = 1; i <= match.groupCount; i++) {
          final value = match[i];
          if (value != null) register(value);
        }
      }
    }
  }

  static String redact(String input) {
    final views = <_TokenView>[_TokenView.original(input)];
    // Every decoding step shortens the text; no arbitrary nesting cutoff.
    while (true) {
      final next = views.last.decode();
      if (next.text == views.last.text) break;
      views.add(next);
    }
    final ranges = <(int, int)>[];
    void capture(_TokenView view, int start, int end) {
      if (end <= start || view.text.substring(start, end) == marker) return;
      ranges.add((view.starts[start], view.ends[end - 1]));
    }

    for (final view in views) {
      for (final array in _array.allMatches(view.text)) {
        final values = array[1]!;
        final start = array.end - values.length - 1;
        for (final quoted in RegExp(
          r'''["']([^"']*)["']''',
        ).allMatches(values)) {
          final value = quoted[1]!;
          capture(
            view,
            start + quoted.start + 1,
            start + quoted.start + 1 + value.length,
          );
        }
      }
      for (final pattern in [_field, _bearer]) {
        for (final match in pattern.allMatches(view.text)) {
          for (var group = 1; group <= match.groupCount; group++) {
            final value = match[group];
            if (value == null || value.isEmpty || value == marker) continue;
            final start =
                match.end -
                value.length -
                (pattern == _field && group < 3 ? 1 : 0);
            capture(view, start, start + value.length);
          }
        }
      }
      // Known authentication tokens are also removed from unlabelled errors,
      // Cookie values and response text, including encoded representations.
      for (final token in _known) {
        var from = 0;
        while (from < view.text.length) {
          final start = view.text.indexOf(token, from);
          if (start < 0) break;
          from = start + token.length;
          final before = start == 0 ? '' : view.text[start - 1];
          final after = from == view.text.length ? '' : view.text[from];
          final tail = view.text.substring(from);
          if (RegExp(r'[a-zA-Z0-9_-]').hasMatch(before) ||
              RegExp(r'[a-zA-Z0-9_-]').hasMatch(after) ||
              RegExp(r'''^["']?\s*[:=]''').hasMatch(tail) ||
              (start >= 10 &&
                  view.text.substring(start - 10, start) == '<redacted-')) {
            continue;
          }
          capture(view, start, from);
        }
      }
    }
    if (ranges.isEmpty) return input;
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final range in ranges) {
      if (merged.isNotEmpty && range.$1 <= merged.last.$2) {
        final old = merged.removeLast();
        merged.add((old.$1, range.$2 > old.$2 ? range.$2 : old.$2));
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
    return result.toString();
  }

  static String escapeControls(String value, {bool preserveLines = false}) =>
      value.replaceAllMapped(RegExp(r'[\x00-\x1f\x7f]'), (m) {
        final code = m[0]!.codeUnitAt(0);
        if (preserveLines && code == 10) return '\n';
        return switch (code) {
          10 => r'\n',
          13 => r'\r',
          9 => r'\t',
          _ => '\\u${code.toRadixString(16).padLeft(4, '0')}',
        };
      });
}

class _TokenView {
  _TokenView(this.text, this.starts, this.ends);
  factory _TokenView.original(String text) => _TokenView(
    text,
    List.generate(text.length, (i) => i),
    List.generate(text.length, (i) => i + 1),
  );
  final String text;
  final List<int> starts, ends;
  _TokenView decode() {
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
    return _TokenView(output.toString(), first, last);
  }
}
