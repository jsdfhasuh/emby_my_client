import 'dart:io';

import '../core/server_scope.dart';
import '../core/strm_diagnostics.dart';
import '../models/emby_models.dart';
import 'strm_direct_play_policy.dart';

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
  }) : trace = trace ?? StrmTrace(),
       headers = _validateHeaders(headers) {
    validateDestination(rawUrl, embyServer: embyServer);
  }

  final StrmTrace trace;
  final int? diagnosticTask;
  final String rawUrl;
  final Map<String, String> headers;
  final PlaybackResourceIdentity identity;
  final Uri embyServer;
  final bool Function()? isSessionActive;
  bool get sessionActive => isSessionActive?.call() ?? true;

  @override
  String toString() => 'PlaybackResourceRequest(sourceDirect)';

  static void validateDestination(String raw, {required Uri embyServer}) {
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

  static Map<String, String> _validateHeaders(Map<String, String> headers) {
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
      'x-emby-token',
      'x-emby-authorization',
      'x-mediabrowser-token',
    };
    for (final entry in headers.entries) {
      final key = entry.key.toLowerCase();
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(entry.key) ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(entry.value) ||
          reserved.contains(key) ||
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
