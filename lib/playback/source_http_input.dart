import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'playback_resource_request.dart';

/// Progressive input only. HTTP is never delegated to libmpv/FFmpeg. Each
/// bounded Range request (including a seek) repeats destination/auth policy.
class SourceHttpInput {
  SourceHttpInput(this.request, {required this.embyServer}) {
    _client
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 10)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = _connect;
  }

  final PlaybackResourceRequest request;
  final Uri embyServer;
  final HttpClient _client = HttpClient();
  bool _wasClosed = false;
  bool get _closed => _wasClosed || !request.sessionActive;
  int? _size;
  String? _validator;
  Uint8List? _prefix;
  String? format;
  int get size => _size!;

  /// Text subtitle fetch on the same controlled socket/TLS transport. Headers
  /// here are independently authorized by the subtitle owner, never copied
  /// from the video request. Every redirect is checked before sending.
  Future<Uint8List> downloadText({
    required Map<String, String> headers,
    bool Function(String)? authorizeHeaders,
  }) async {
    Future<Uint8List> fetch() async {
      _client.autoUncompress = true;
      var raw = request.rawUrl;
      final origin = Uri.parse(raw).origin;
      var includeHeaders = true;
      final visited = <String>{};
      for (var jumps = 0; jumps <= 5; jumps++) {
        if (_closed) throw const SourceInputException('cancelled');
        PlaybackResourceRequest.validateDestination(
          raw,
          embyServer: embyServer,
        );
        if (!visited.add(raw)) {
          throw const SourceInputException('redirect_loop');
        }
        final uri = OpaqueHttpUri(raw);
        includeHeaders =
            includeHeaders &&
            uri.origin == origin &&
            (authorizeHeaders?.call(raw) ?? true);
        final outbound = await _client.getUrl(uri);
        outbound.followRedirects = false;
        if (includeHeaders) {
          headers.forEach((name, value) => outbound.headers.set(name, value));
        }
        final response = await outbound.close();
        if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.listen((_) {}).cancel();
          if (location == null || jumps == 5) {
            throw const SourceInputException('redirect_limit');
          }
          final next = resolveRawLocation(raw, location);
          if (uri.scheme == 'https' && Uri.parse(next).scheme != 'https') {
            throw const SourceInputException('tls_downgrade');
          }
          raw = next;
          continue;
        }
        if (response.statusCode != 200 ||
            response.contentLength > 10 * 1024 * 1024) {
          await response.listen((_) {}).cancel();
          throw const SourceInputException('subtitle_response');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (_closed || bytes.length + chunk.length > 10 * 1024 * 1024) {
            throw const SourceInputException('subtitle_limit');
          }
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      }
      throw const SourceInputException('redirect_limit');
    }

    try {
      return await fetch().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          close();
          throw const SourceInputException('subtitle_timeout');
        },
      );
    } catch (_) {
      throw const SourceInputException('subtitle_download');
    } finally {
      close();
    }
  }

  Future<void> prepare() async {
    _prefix = await _range(0, 262144);
    format = progressiveFormat(_prefix!);
    if (format == null) {
      close();
      throw const SourceInputException('unsupported_container');
    }
  }

  Future<Uint8List> read(int offset, int count) async {
    if (_closed) throw const SourceInputException('cancelled');
    if (offset < 0 || count <= 0 || count > 262144 || offset >= size) {
      throw const SourceInputException('invalid_range');
    }
    final prefix = _prefix;
    if (prefix != null && offset < prefix.length) {
      final end = (offset + count).clamp(0, prefix.length);
      return Uint8List.sublistView(prefix, offset, end);
    }
    return _range(offset, count);
  }

  Future<Uint8List> _range(int offset, int count) async {
    try {
      return await _fetch(offset, count).timeout(
        const Duration(seconds: 25),
        onTimeout: () {
          close();
          throw const SourceInputException('timeout');
        },
      );
    } on SourceInputException {
      rethrow;
    } catch (_) {
      // Native/UI/diagnostics must never receive a signed URL from io errors.
      throw const SourceInputException('transport');
    }
  }

  Future<Uint8List> _fetch(int offset, int count) async {
    var raw = request.rawUrl;
    final originalOrigin = Uri.parse(raw).origin;
    var credentialsAllowed = true;
    final visited = <String>{};
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (_closed) throw const SourceInputException('cancelled');
      PlaybackResourceRequest.validateDestination(raw, embyServer: embyServer);
      if (!visited.add(raw)) throw const SourceInputException('redirect_loop');
      final uri = OpaqueHttpUri(raw);
      credentialsAllowed = credentialsAllowed && uri.origin == originalOrigin;
      final outbound = await _client.getUrl(uri);
      outbound.followRedirects = false;
      outbound.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      outbound.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$offset-${offset + count - 1}',
      );
      if (_validator != null) {
        outbound.headers.set(HttpHeaders.ifRangeHeader, _validator!);
      }
      if (credentialsAllowed) {
        request.headers.forEach(
          (name, value) => outbound.headers.set(name, value),
        );
      }
      final response = await outbound.close();
      if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        // Cancel, don't drain an unbounded redirect body.
        await response.listen((_) {}).cancel();
        if (location == null || redirects == 5) {
          throw const SourceInputException('redirect_limit');
        }
        final next = resolveRawLocation(raw, location);
        if (uri.scheme == 'https' && Uri.parse(next).scheme != 'https') {
          throw const SourceInputException('tls_downgrade');
        }
        raw = next;
        continue;
      }
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
        response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
      );
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      if (response.statusCode != 206 ||
          range == null ||
          (encoding != null && encoding != 'identity')) {
        await response.listen((_) {}).cancel();
        throw SourceInputException(
          response.statusCode == 401 || response.statusCode == 403
              ? 'source_denied'
              : 'range_unsupported',
        );
      }
      final start = int.parse(range[1]!);
      final end = int.parse(range[2]!);
      final total = int.parse(range[3]!);
      if (start != offset ||
          end < start ||
          end >= offset + count ||
          total <= end ||
          (_size != null && _size != total)) {
        await response.listen((_) {}).cancel();
        throw const SourceInputException('source_changed');
      }
      final etag = response.headers.value(HttpHeaders.etagHeader);
      final validator = etag != null && !etag.startsWith('W/')
          ? etag
          : response.headers.value(HttpHeaders.lastModifiedHeader);
      if (_validator != null && validator != _validator) {
        await response.listen((_) {}).cancel();
        throw const SourceInputException('source_changed');
      }
      _validator ??= validator;
      _size = total;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (_closed || bytes.length + chunk.length > end - start + 1) {
          throw const SourceInputException('body_limit');
        }
        bytes.add(chunk);
      }
      if (bytes.length != end - start + 1) {
        throw const SourceInputException('truncated');
      }
      return bytes.takeBytes();
    }
    throw const SourceInputException('redirect_limit');
  }

  Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    if (_closed || proxyHost != null) {
      throw const SourceInputException('cancelled');
    }
    final addresses = await InternetAddress.lookup(uri.host);
    if (_closed || addresses.isEmpty) {
      throw const SourceInputException('destination');
    }
    // Validate resolved addresses too: DNS must not bypass the literal checks.
    for (final address in addresses) {
      final host = address.type == InternetAddressType.IPv6
          ? '[${address.address}]'
          : address.address;
      PlaybackResourceRequest.validateDestination(
        'http://$host/',
        embyServer: embyServer,
      );
    }
    final task = await Socket.startConnect(addresses.first, uri.port);
    Socket? active;
    var cancelled = false;
    final future = task.socket.then<Socket>((socket) async {
      active = socket;
      if (_closed || cancelled) {
        socket.destroy();
        throw const SourceInputException('cancelled');
      }
      if (uri.scheme == 'https') {
        final secured = await SecureSocket.secure(socket, host: uri.host);
        active = secured;
        if (_closed || cancelled) {
          secured.destroy();
          throw const SourceInputException('cancelled');
        }
        return secured;
      }
      return socket;
    });
    return ConnectionTask.fromSocket(future, () {
      cancelled = true;
      task.cancel();
      active?.destroy();
    });
  }

  void close() {
    _wasClosed = true;
    _prefix = null;
    _client.close(force: true);
  }

  /// Restrict the demuxer too: playlists/concat can otherwise open subresources
  /// behind the stream callback. The engine forces this sniffed container.
  static String? progressiveFormat(Uint8List bytes) {
    bool at(int start, List<int> value) =>
        bytes.length >= start + value.length &&
        List.generate(
          value.length,
          (i) => bytes[start + i] == value[i],
        ).every((v) => v);
    if (at(4, [0x66, 0x74, 0x79, 0x70])) return 'mov';
    if (at(0, [0x1a, 0x45, 0xdf, 0xa3])) return 'matroska';
    if (at(0, [82, 73, 70, 70]) && at(8, [65, 86, 73, 32])) return 'avi';
    if (bytes.length > 376 &&
        bytes[0] == 0x47 &&
        bytes[188] == 0x47 &&
        bytes[376] == 0x47) {
      return 'mpegts';
    }
    return null;
  }
}

class SourceInputException implements Exception {
  const SourceInputException(this.code);
  final String code;
  @override
  String toString() => 'SourceInputException($code)';
}

/// HttpClient uses path/query for the wire request. Keep the opaque spelling
/// while delegating host/TLS semantics to the parsed validation copy.
class OpaqueHttpUri implements Uri {
  OpaqueHttpUri(this.raw) : parsed = Uri.parse(raw) {
    final authorityEnd = raw.indexOf(RegExp(r'[/?#]'), raw.indexOf('://') + 3);
    final target = authorityEnd < 0 ? '' : raw.substring(authorityEnd);
    final question = target.indexOf('?');
    path = question < 0 ? target : target.substring(0, question);
    query = question < 0 ? '' : target.substring(question + 1);
    hasQuery = question >= 0;
  }
  final String raw;
  final Uri parsed;
  @override
  late final String path;
  @override
  late final String query;
  @override
  late final bool hasQuery;
  @override
  String get scheme => parsed.scheme;
  @override
  String get host => parsed.host;
  @override
  int get port => parsed.port;
  @override
  String get origin => parsed.origin;
  @override
  String get authority => parsed.authority;
  @override
  String get userInfo => parsed.userInfo;
  @override
  bool get hasFragment => parsed.hasFragment;
  @override
  bool get hasAuthority => true;
  @override
  bool get hasPort => parsed.hasPort;
  @override
  bool get isAbsolute => true;
  @override
  String get fragment => parsed.fragment;
  @override
  Uri removeFragment() => this;
  @override
  bool isScheme(String value) => parsed.isScheme(value);
  @override
  String toString() => raw;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw const SourceInputException('uri_operation');
}

String resolveRawLocation(String base, String location) {
  if (RegExp(r'^https?://').hasMatch(location)) return location;
  final current = OpaqueHttpUri(base);
  if (location.startsWith('//')) return '${current.scheme}:$location';
  final prefix = '${current.scheme}://${current.authority}';
  if (location.startsWith('?')) return '$prefix${current.path}$location';
  if (location.isEmpty ||
      location.contains('#') ||
      RegExp(r'^[^/]*:').hasMatch(location)) {
    throw const SourceInputException('redirect_location');
  }
  final split = location.indexOf('?');
  final path = split < 0 ? location : location.substring(0, split);
  final query = split < 0 ? '' : location.substring(split);
  final combined = path.startsWith('/')
      ? path
      : '${current.path.substring(0, current.path.lastIndexOf('/') + 1)}$path';
  final segments = <String>[];
  for (final segment in combined.split('/')) {
    if (segment == '..') {
      if (segments.length > 1) segments.removeLast();
    } else if (segment != '.') {
      segments.add(segment);
    }
  }
  return '$prefix/${segments.join('/').replaceFirst(RegExp(r'^/'), '')}$query';
}
