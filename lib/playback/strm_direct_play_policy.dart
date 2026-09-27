import '../models/emby_models.dart';

enum SourceClassification { confirmedStrm, confirmedRegular, unknown }

enum PlaybackResolveFailure {
  sourceIdentityUnresolved,
  sourceIdentityConflict,
  sourceMissing,
  invalidSourceRequest,
  serverDenied,
  rateLimited,
  noCompatibleStream,
  serverError,
  sourceRequiresOpening,
  nativeRequestPolicyUnsupported,
  cancelled,
  budgetExceeded,
}

/// Fixed categories only: never include response paths, credentials or names.
class PlaybackResolveException implements Exception {
  const PlaybackResolveException(this.failure);
  final PlaybackResolveFailure failure;

  @override
  String toString() => 'PlaybackResolveException(${failure.name})';
}

/// Source-scoped evidence. An item-level STRM flag is deliberately insufficient
/// for a multi-version item. Only a fresh, unambiguous detail can supply a path.
abstract final class StrmDirectPlayPolicy {
  static const regularExtensions = {
    'mp4',
    'mkv',
    'mov',
    'm4v',
    'webm',
    'ts',
    'm2ts',
    'avi',
  };

  static bool hasStrmEvidence(PlaybackMediaSource source) =>
      source.container?.trim().toLowerCase() == 'strm' ||
      _extension(source.path) == 'strm';

  static SourceClassification classify(
    PlaybackMediaSource source, {
    EmbyItem? freshDetail,
    SourceClassification previous = SourceClassification.unknown,
  }) {
    if (source.id.isEmpty) {
      throw const PlaybackResolveException(
        PlaybackResolveFailure.sourceIdentityUnresolved,
      );
    }
    PlaybackMediaSource? detailSource;
    var singleSource = false;
    if (freshDetail != null) {
      validateIdentities(freshDetail.mediaSources);
      detailSource = fixedSource(freshDetail.mediaSources, source.id);
      singleSource = freshDetail.mediaSources.length == 1;
    }
    final detailStrm =
        detailSource != null &&
        (hasStrmEvidence(detailSource) ||
            (singleSource && _extension(freshDetail?.path) == 'strm'));
    if (previous == SourceClassification.confirmedStrm ||
        hasStrmEvidence(source) ||
        detailStrm) {
      return SourceClassification.confirmedStrm;
    }
    if (detailSource == null) return SourceClassification.unknown;
    final ownPath = detailSource.path;
    final path = ownPath == null || ownPath.isEmpty
        ? (singleSource ? freshDetail?.path : null)
        : ownPath;
    if (detailSource.protocol?.toLowerCase() == 'file' &&
        _isAbsoluteFile(path) &&
        regularExtensions.contains(_extension(path))) {
      return SourceClassification.confirmedRegular;
    }
    return SourceClassification.unknown;
  }

  static void validateIdentities(List<PlaybackMediaSource> sources) {
    final ids = <String>{};
    for (final source in sources) {
      if (source.id.trim().isEmpty) {
        throw const PlaybackResolveException(
          PlaybackResolveFailure.sourceIdentityUnresolved,
        );
      }
      if (!ids.add(source.id)) {
        throw const PlaybackResolveException(
          PlaybackResolveFailure.sourceIdentityConflict,
        );
      }
    }
  }

  static PlaybackMediaSource fixedSource(
    List<PlaybackMediaSource> sources,
    String id,
  ) {
    validateIdentities(sources);
    final matches = sources.where((source) => source.id == id);
    if (matches.isEmpty) {
      throw const PlaybackResolveException(
        PlaybackResolveFailure.sourceMissing,
      );
    }
    return matches.single;
  }

  static PlaybackMediaSource selectOnce(
    List<PlaybackMediaSource> sources, {
    String? requestedId,
  }) {
    validateIdentities(sources);
    if (requestedId != null) return fixedSource(sources, requestedId);
    if (sources.isEmpty) {
      throw const PlaybackResolveException(
        PlaybackResolveFailure.sourceIdentityUnresolved,
      );
    }
    for (final predicate in <bool Function(PlaybackMediaSource)>[
      (source) => source.supportsDirectPlay,
      (source) => source.directStreamUrl?.isNotEmpty == true,
      hasStrmEvidence,
      (source) => source.transcodingUrl?.isNotEmpty == true,
    ]) {
      for (final source in sources) {
        if (predicate(source)) return source;
      }
    }
    return sources.first;
  }

  /// All three strict compatibility bodies retain the complete constraint.
  static List<Map<String, dynamic>> strictPayloads({
    required String userId,
    required Map<String, dynamic> deviceProfile,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    bool subtitleDisabled = false,
    int startTimeTicks = 0,
    int maxStreamingBitrate = 120000000,
  }) {
    final minimal = <String, dynamic>{
      'UserId': userId,
      'MediaSourceId': ?mediaSourceId,
      'StartTimeTicks': startTimeTicks,
      'AudioStreamIndex': ?audioStreamIndex,
      'SubtitleStreamIndex': subtitleDisabled ? -1 : subtitleStreamIndex,
      'EnableDirectPlay': true,
      'EnableDirectStream': false,
      'EnableTranscoding': false,
      'AutoOpenLiveStream': false,
    }..removeWhere((_, value) => value == null);
    final common = {...minimal, 'MaxStreamingBitrate': maxStreamingBitrate};
    return List.unmodifiable([
      Map<String, dynamic>.unmodifiable({
        ...common,
        'DeviceProfile': deviceProfile,
      }),
      Map<String, dynamic>.unmodifiable(common),
      Map<String, dynamic>.unmodifiable(minimal),
    ]);
  }

  static void requireDirectRequest({required bool forceTranscode}) {
    if (forceTranscode) {
      throw const PlaybackResolveException(
        PlaybackResolveFailure.invalidSourceRequest,
      );
    }
  }

  static void requireNoServerResource(PlaybackMediaSource source) {
    if (source.requiresOpening ||
        source.openToken != null ||
        source.isInfiniteStream ||
        source.liveStreamId != null) {
      throw const PlaybackResolveException(
        PlaybackResolveFailure.sourceRequiresOpening,
      );
    }
  }

  static void checkError(String? code) {
    if (code == null || code.isEmpty) return;
    throw PlaybackResolveException(switch (code) {
      'NotAllowed' => PlaybackResolveFailure.serverDenied,
      'RateLimitExceeded' => PlaybackResolveFailure.rateLimited,
      'NoCompatibleStream' => PlaybackResolveFailure.noCompatibleStream,
      _ => PlaybackResolveFailure.serverError,
    });
  }

  static String? _extension(String? path) {
    if (path == null || path.isEmpty) return null;
    final clean = path.split(RegExp(r'[?#]')).first.replaceAll('\\', '/');
    final name = clean.split('/').last;
    return name.contains('.') ? name.split('.').last.toLowerCase() : null;
  }

  static bool _isAbsoluteFile(String? path) =>
      path != null &&
      !path.contains('://') &&
      (path.startsWith('/') ||
          path.startsWith(r'\\') ||
          RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path));
}
