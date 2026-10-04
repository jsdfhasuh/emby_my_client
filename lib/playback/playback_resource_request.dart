import 'dart:io';
import 'dart:convert';
import '../core/token_redactor.dart';

import '../core/server_scope.dart';
import '../core/strm_diagnostics.dart';
import '../models/emby_models.dart';
import 'strm_direct_play_policy.dart';
import 'source_startup_progress.dart';

/// Identity is deliberately stronger than ServerScope: a new login cannot
/// consume a snapshot or late response produced by the old API object.
class PlaybackResourceIdentity {
  const PlaybackResourceIdentity({
    required this.scope,
    required this.apiSession,
    required this.itemId,
    required this.sourceId,
    required this.itemSession,
    required this.generation,
  });

  final ServerScope scope;
  final Object apiSession;
  final String itemId;
  final String sourceId;
  final Object itemSession;
  final int generation;

  bool sameSource(PlaybackResourceIdentity other) =>
      scope == other.scope &&
      identical(apiSession, other.apiSession) &&
      itemId == other.itemId &&
      sourceId == other.sourceId &&
      identical(itemSession, other.itemSession);

  bool sameAttempt(PlaybackResourceIdentity other) =>
      sameSource(other) && generation == other.generation;
}

/// Validation parses a copy; the string handed to a future native adapter must
/// remain [rawUrl]. Uri.toString / media_kit.Media normalization is not lossless.
class PlaybackResourceRequest {
  PlaybackResourceRequest({
    required this.rawUrl,
    required Map<String, String> headers,
    required this.identity,
    required this.embyServer,
    this.isSessionActive,
    StrmTrace? trace,
    this.diagnosticTask,
  }) : isProgressive = false,
       trace = trace ?? StrmTrace(),
       headers = _validateHeaders(headers) {
    TokenRedactor.registerCredentials(rawUrl);
    TokenRedactor.registerCredentials(jsonEncode(headers));
    validateDestination(rawUrl, embyServer: embyServer);
  }

  /// A selected ordinary Emby progressive plan, never a STRM source path.
  /// Callers must first establish finite, non-live progressive eligibility
  /// from the same selected plan and bind its API/item attempt in [identity].
  PlaybackResourceRequest.progressive({
    required this.rawUrl,
    required Map<String, String> headers,
    required this.identity,
    required this.embyServer,
    this.isSessionActive,
    StrmTrace? trace,
    this.diagnosticTask,
  }) : isProgressive = true,
       trace = trace ?? StrmTrace(),
       headers = _validateHeaders(headers, allowEmbyAuthentication: true) {
    TokenRedactor.registerCredentials(rawUrl);
    TokenRedactor.registerCredentials(jsonEncode(headers));
    _validateProgressiveInitial();
  }

  final StrmTrace trace;
  final SourceStartupProgress startupProgress = SourceStartupProgress();
  final int? diagnosticTask;
  final String rawUrl;
  final Map<String, String> headers;
  final PlaybackResourceIdentity identity;
  final Uri embyServer;
  final bool isProgressive;
  bool _nativeFallbackRevoked = false;

  /// Sticky evidence for the entire selected request, including failed opens.
  /// A native retry cannot safely replay authenticated URLs after a redirect
  /// has demonstrated that their chain crosses the server's authority.
  bool get allowsNativeFallback => isProgressive && !_nativeFallbackRevoked;

  /// A policy/authentication/source-identity rejection remains disqualifying
  /// even when it came from a suppressed speculative transfer.
  void revokeNativeFallback() {
    if (isProgressive) _nativeFallbackRevoked = true;
  }

  void markCrossOriginRedirect() {
    revokeNativeFallback();
  }

  final bool Function()? isSessionActive;
  bool get sessionActive => isSessionActive?.call() ?? true;

  @override
  String toString() => isProgressive
      ? 'PlaybackResourceRequest(progressive)'
      : 'PlaybackResourceRequest(sourceDirect)';

  /// Validate every request, including redirects, against this exact input's
  /// authority. A separate input constructor argument cannot widen it.
  void validateTarget(String raw) {
    if (!isProgressive) {
      validateDestination(raw, embyServer: embyServer);
      return;
    }
    final uri = _validateNetworkDestination(raw);
    final path = _progressivePath(
      uri,
      raw: raw,
      strict: uri.origin == embyServer.origin,
    );
    if (_segmentedPath(path)) _invalid();
    if (uri.origin == embyServer.origin) {
      if (path != _progressivePath(Uri.parse(rawUrl), raw: rawUrl)) _invalid();
      _validateSelectedQuery(uri, redirect: true);
    } else if (RegExp(
      r'(^|/)(videos/[^/]+/(stream|master|main|hls|hls1)(\.|/|$)|items/[^/]+/(download|file)(/|$))',
      caseSensitive: false,
    ).hasMatch(path)) {
      _invalid();
    }
  }

  /// DNS validation uses the same literal-address rules as admission without
  /// pretending the resolved IP is a newly authorized server URL.
  void validateResolvedAddress(InternetAddress address) {
    final host = address.type == InternetAddressType.IPv6
        ? '[${address.address}]'
        : address.address;
    _validateNetworkDestination('http://$host/');
  }

  /// Once a redirect chain leaves the authenticated origin, credentials are
  /// not restored on return. Preserve unrelated opaque URL signing syntax.
  String redirectTarget(String raw, {required bool credentialsAllowed}) {
    if (!isProgressive || credentialsAllowed) return raw;
    _validateNetworkDestination(raw);
    final question = raw.indexOf('?');
    if (question < 0) return raw;
    final original = Uri.parse(rawUrl);
    final secrets = <String>{
      for (final entry in original.queryParametersAll.entries)
        if (_credentialQueryKeys.contains(entry.key.toLowerCase()))
          ...entry.value.where((value) => value.isNotEmpty),
      for (final entry in headers.entries)
        if (_credentialHeaderKeys.contains(entry.key.toLowerCase()) &&
            entry.value.isNotEmpty)
          entry.value,
    };
    try {
      final kept = raw.substring(question + 1).split('&').where((part) {
        final equals = part.indexOf('=');
        final name = Uri.decodeQueryComponent(
          equals < 0 ? part : part.substring(0, equals),
        ).toLowerCase();
        final value = equals < 0
            ? ''
            : Uri.decodeQueryComponent(part.substring(equals + 1));
        return !_credentialQueryKeys.contains(name) && !secrets.contains(value);
      }).toList();
      return '${raw.substring(0, question)}${kept.isEmpty ? '' : '?${kept.join('&')}'}';
    } on FormatException {
      _invalid();
    }
  }

  static const _credentialQueryKeys = {
    'api_key',
    'api-key',
    'apikey',
    'token',
    'accesstoken',
    'x-emby-token',
    'x-mediabrowser-token',
    'x-emby-authorization',
    'authorization',
    'access_token',
  };
  static const _credentialHeaderKeys = {
    'x-emby-token',
    'x-mediabrowser-token',
    'x-emby-authorization',
    'authorization',
    'cookie',
  };

  void _validateProgressiveInitial() {
    final uri = _validateNetworkDestination(rawUrl);
    _validateNetworkDestination(embyServer.toString());
    if (embyServer.hasQuery ||
        embyServer.hasFragment ||
        uri.origin != embyServer.origin ||
        identity.itemId.isEmpty ||
        RegExp(r'[/\\%?#\s]').hasMatch(identity.itemId) ||
        identity.sourceId.isEmpty) {
      _invalid();
    }
    final base = _progressivePath(embyServer).replaceFirst(RegExp(r'/+$'), '');
    final path = _progressivePath(uri, raw: rawUrl);
    final segments = path.startsWith('$base/')
        ? path.substring(base.length + 1).split('/')
        : const <String>[];
    // Base paths and item IDs are exact, while Emby's resource names are
    // case-insensitive. Only the selected item's progressive stream is eligible.
    if (segments.length != 3 ||
        segments[0].toLowerCase() != 'videos' ||
        segments[1] != identity.itemId ||
        !RegExp(
          r'^stream(?:\.(?:mp4|m4v|mov|mkv|webm|avi|ts|m2ts|mts))?$',
          caseSensitive: false,
        ).hasMatch(segments[2])) {
      _invalid();
    }
    _validateSelectedQuery(uri);
  }

  void _validateSelectedQuery(Uri uri, {bool redirect = false}) {
    try {
      final selected = <String, List<String>>{
        for (final entry in Uri.parse(rawUrl).queryParametersAll.entries)
          entry.key.toLowerCase(): entry.value,
      };
      final target = <String, List<String>>{};
      for (final entry in uri.queryParametersAll.entries) {
        final name = entry.key.toLowerCase();
        if (target.containsKey(name)) _invalid();
        target[name] = entry.value;
        if (name == 'mediasourceid' &&
            entry.value.any((value) => value != identity.sourceId)) {
          _invalid();
        }
        if (name == 'livestreamid' ||
            (name == 'transcodingprotocol' &&
                entry.value.any(
                  (value) =>
                      const {'hls', 'dash'}.contains(value.toLowerCase()),
                ))) {
          _invalid();
        }
      }
      if (redirect) {
        for (final key in const {
          'mediasourceid',
          'playsessionid',
          'static',
          'audiostreamindex',
          'subtitlestreamindex',
          'starttimeticks',
        }) {
          if (jsonEncode(selected[key]) != jsonEncode(target[key])) _invalid();
        }
      }
    } on FormatException {
      _invalid();
    }
  }

  static String _progressivePath(Uri uri, {String? raw, bool strict = true}) {
    try {
      var encoded = uri.path;
      if (raw != null) {
        final start = raw.indexOf(RegExp(r'[/?#]'), raw.indexOf('://') + 3);
        final question = raw.indexOf('?', start < 0 ? 0 : start);
        encoded = start < 0 || raw[start] != '/'
            ? ''
            : raw.substring(start, question < 0 ? raw.length : question);
      }
      final path = Uri.decodeComponent(encoded);
      if (strict &&
          (RegExp(r'[\x00-\x20\x7f\\%]').hasMatch(path) ||
              path.split('/').any((part) => part == '.' || part == '..') ||
              RegExp(r'%2f|%5c', caseSensitive: false).hasMatch(encoded))) {
        _invalid();
      }
      return path;
    } on FormatException {
      _invalid();
    }
  }

  static bool _segmentedPath(String path) => RegExp(
    r'\.(strm|m3u8?|mpd|ismc?)(/|$)|(^|/)(hls|hls1|dash|manifest)(/|\.|$)',
    caseSensitive: false,
  ).hasMatch(path);

  static void validateDestination(String raw, {required Uri embyServer}) {
    final uri = _validateNetworkDestination(raw);
    if (uri.origin == embyServer.origin) {
      var base = embyServer.path.replaceFirst(RegExp(r'/+$'), '');
      if (base == '/') base = '';
      final path = Uri.decodeComponent(uri.path).toLowerCase();
      final prefix = '${base.toLowerCase()}/';
      if (path.startsWith(prefix)) {
        final resource = path.substring(prefix.length);
        if (RegExp(
              r'^videos/[^/]+/(stream|master|main|hls|hls1)(\.|/|$)',
            ).hasMatch(resource) ||
            RegExp(r'^items/[^/]+/(download|file)(/|$)').hasMatch(resource)) {
          _invalid();
        }
      }
    }
  }

  static Uri _validateNetworkDestination(String raw) {
    final uri = Uri.tryParse(raw);
    if (raw.isEmpty ||
        RegExp(r'[\x00-\x20\x7f\\]').hasMatch(raw) ||
        uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.path.toLowerCase().endsWith('.strm')) {
      _invalid();
    }
    var host = uri.host.toLowerCase();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.contains('%')) {
      _invalid();
    }
    final address = InternetAddress.tryParse(host);
    if (address != null) {
      final bytes = address.rawAddress;
      final mapped =
          bytes.length == 16 &&
          bytes.take(10).every((value) => value == 0) &&
          bytes[10] == 255 &&
          bytes[11] == 255;
      final ipv4 = bytes.length == 4
          ? bytes
          : mapped
          ? bytes.sublist(12)
          : null;
      if (address.isLoopback ||
          bytes.every((value) => value == 0) ||
          (ipv4 != null && (ipv4.first == 127 || ipv4.first == 0))) {
        _invalid();
      }
    } else if (RegExp(r'^(0x[0-9a-f]+|[0-9.]+)$').hasMatch(host)) {
      // Ambiguous numeric host spellings must not reach resolver-specific IPv4
      // interpretation (127.1, integer, octal, hexadecimal).
      _invalid();
    }
    return uri;
  }

  static Map<String, String> _validateHeaders(
    Map<String, String> headers, {
    bool allowEmbyAuthentication = false,
  }) {
    final names = <String>{};
    const reserved = {
      'host',
      'content-length',
      'connection',
      'transfer-encoding',
      'keep-alive',
      'proxy-connection',
      'proxy-authorization',
      'proxy-authenticate',
      'te',
      'trailer',
      'upgrade',
      'range',
    };
    for (final entry in headers.entries) {
      final key = entry.key.toLowerCase();
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(entry.key) ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(entry.value) ||
          reserved.contains(key) ||
          (!allowEmbyAuthentication &&
              const {
                'x-emby-token',
                'x-emby-authorization',
                'x-mediabrowser-token',
              }.contains(key)) ||
          !names.add(key)) {
        _invalid();
      }
    }
    return Map.unmodifiable(headers);
  }

  static Never _invalid() => throw const PlaybackResolveException(
    PlaybackResolveFailure.invalidSourceRequest,
  );
}

/// Evidence obtained from a prepared and container-validated HTTP input.
class VerifiedSourceInput {
  const VerifiedSourceInput({required this.request, required this.sizeBytes});

  final PlaybackResourceRequest request;

  /// Total size from a validated finite Content-Range, not the .strm file size.
  final int sizeBytes;
}

/// URL, headers and metadata always come from this single authorized response.
/// No copyWith accepts individual URL/header replacements.
class SelectedSourceSnapshot {
  SelectedSourceSnapshot({
    required PlaybackMediaSource source,
    required PlaybackResourceIdentity identity,
    required Uri embyServer,
    required this.playSessionId,
    bool Function()? isSessionActive,
    StrmTrace? trace,
  }) : request = PlaybackResourceRequest(
         trace: trace,
         rawUrl: source.path ?? '',
         headers: source.requiredHttpHeaders,
         identity: identity,
         embyServer: embyServer,
         isSessionActive: isSessionActive,
       ),
       mediaStreams = List.unmodifiable(
         source.mediaStreams.map(
           (stream) => Map<String, dynamic>.unmodifiable(stream),
         ),
       ),
       duration = source.runTimeTicks == null
           ? null
           : Duration(microseconds: source.runTimeTicks! ~/ 10),
       sizeBytes = source.container?.toLowerCase() == 'strm'
           ? null
           : source.size {
    if (identity.sourceId != source.id) {
      throw const PlaybackResolveException(
        PlaybackResolveFailure.sourceIdentityConflict,
      );
    }
    if (source.requiresOpening ||
        source.openToken != null ||
        source.isInfiniteStream ||
        source.liveStreamId != null) {
      throw const PlaybackResolveException(
        PlaybackResolveFailure.sourceRequiresOpening,
      );
    }
  }

  final PlaybackResourceRequest request;
  final String? playSessionId;
  final List<Map<String, dynamic>> mediaStreams;
  final Duration? duration;
  final int? sizeBytes;
}

enum NativeRequestCapability { tested, unsupported, unverified }

/// This is evidence, not a bypass switch. No production adapter is certified.
class NativeSourceRequestEvidence {
  const NativeSourceRequestEvidence({
    this.rawUrl = NativeRequestCapability.unverified,
    this.cleanHeaders = NativeRequestCapability.unverified,
    this.perRequestDestination = NativeRequestCapability.unverified,
    this.perTargetAuthentication = NativeRequestCapability.unverified,
    this.boundedRedirects = NativeRequestCapability.unverified,
  });

  final NativeRequestCapability rawUrl;
  final NativeRequestCapability cleanHeaders;
  final NativeRequestCapability perRequestDestination;
  final NativeRequestCapability perTargetAuthentication;
  final NativeRequestCapability boundedRedirects;

  void requireControlledProgressive() {
    if ([
      rawUrl,
      cleanHeaders,
      perRequestDestination,
      perTargetAuthentication,
      boundedRedirects,
    ].any((capability) => capability != NativeRequestCapability.tested)) {
      throw const PlaybackResolveException(
        PlaybackResolveFailure.nativeRequestPolicyUnsupported,
      );
    }
  }
}
