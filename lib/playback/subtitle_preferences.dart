import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/emby_models.dart';
import 'playback_state.dart';
import 'subtitle_target.dart';
import 'subtitle_track_labels.dart';
import 'track_mapper.dart';

enum SubtitleLanguagePreference {
  chinese,
  simplifiedChinese,
  traditionalChinese,
  bilingualChinese,
  serverDefault,
}

enum SubtitleForcedPreference { avoid, allow, prefer }

class SubtitlePreferences {
  const SubtitlePreferences({
    this.language = SubtitleLanguagePreference.chinese,
    this.forced = SubtitleForcedPreference.avoid,
  });

  final SubtitleLanguagePreference language;
  final SubtitleForcedPreference forced;

  SubtitlePreferences copyWith({
    SubtitleLanguagePreference? language,
    SubtitleForcedPreference? forced,
  }) => SubtitlePreferences(
    language: language ?? this.language,
    forced: forced ?? this.forced,
  );

  Map<String, Object> toJson() => {
    'language': language.name,
    'forced': forced.name,
  };

  factory SubtitlePreferences.fromJson(Object? value) {
    final json = value is Map ? value : const {};
    return SubtitlePreferences(
      language:
          SubtitleLanguagePreference.values
              .where((value) => value.name == json['language'])
              .firstOrNull ??
          SubtitleLanguagePreference.chinese,
      forced:
          SubtitleForcedPreference.values
              .where((value) => value.name == json['forced'])
              .firstOrNull ??
          SubtitleForcedPreference.avoid,
    );
  }
}

enum RememberedSubtitleKind { disabled, server, native, localExternal }

/// Contains only a metadata digest. Native IDs, URLs and local paths are not
/// stable across opens and must never be persisted as track identity.
class SubtitleRememberedChoice {
  const SubtitleRememberedChoice.disabled()
    : kind = RememberedSubtitleKind.disabled,
      fingerprint = null;

  const SubtitleRememberedChoice._(this.kind, this.fingerprint);

  final RememberedSubtitleKind kind;
  final String? fingerprint;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (fingerprint != null) 'fingerprint': fingerprint,
  };

  static SubtitleRememberedChoice? fromJson(Object? value) {
    if (value is! Map) return null;
    final kind = RememberedSubtitleKind.values
        .where((entry) => entry.name == value['kind'])
        .firstOrNull;
    if (kind == null) return null;
    if (kind == RememberedSubtitleKind.disabled) {
      return const SubtitleRememberedChoice.disabled();
    }
    final fingerprint = value['fingerprint'];
    if (fingerprint is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
      return null;
    }
    return SubtitleRememberedChoice._(kind, fingerprint);
  }
}

enum SubtitlePreferenceStatus { matched, unavailable, ambiguous, serverDefault }

enum SubtitlePreferenceOrigin { remembered, preference }

class SubtitlePreferenceResolution {
  const SubtitlePreferenceResolution({
    required this.status,
    required this.origin,
    this.selection,
  });

  final SubtitlePreferenceStatus status;
  final SubtitlePreferenceOrigin origin;
  final SubtitleSelection? selection;
}

/// Build after resolving the source, and rebuild after a native track update.
/// Returned native/local targets retain the current input binding. The caller
/// must still guard against a manual choice, source switch or retired session.
class SubtitleChoiceCatalog {
  SubtitleChoiceCatalog._(this.mediaSourceId, this._candidates);

  factory SubtitleChoiceCatalog.fromPlayback({
    required PlaybackPlan plan,
    List<NativeSubtitleTrack> nativeTracks = const [],
    List<LocalExternalAsset> localAssets = const [],
  }) {
    final candidates = <_Candidate>[];
    final tracks = const TrackMapper().fromPlan(plan, 'subtitle');
    for (final track in tracks) {
      final locals = localAssets.where((asset) => asset.index == track.index);
      final local = locals.length == 1 ? locals.single : null;
      final kind = local == null
          ? RememberedSubtitleKind.server
          : RememberedSubtitleKind.localExternal;
      candidates.add(
        _Candidate(
          kind: kind,
          selection: local == null
              ? SubtitleSelection.explicitStream(track.index)
              : SubtitleSelection.localExternal(local),
          fingerprint: _fingerprint(
            sourceId: plan.mediaSourceId,
            title: track.originalTitle,
            language: track.language,
            codec: track.codec,
            forced: subtitleStreamFlag(plan, track, 'IsForced'),
            external: subtitleStreamFlag(plan, track, 'IsExternal'),
          ),
          language: describeSubtitleLanguage(
            language: track.language,
            title: track.originalTitle ?? track.displayTitle,
            isForced: subtitleStreamFlag(plan, track, 'IsForced'),
          ),
          selectable:
              tracks.where((other) => other.index == track.index).length == 1 &&
              locals.length <= 1,
        ),
      );
    }
    for (final target in nativeTracks) {
      candidates.add(
        _Candidate(
          kind: RememberedSubtitleKind.native,
          selection: SubtitleSelection.nativeTrack(target),
          fingerprint: _fingerprint(
            sourceId: plan.mediaSourceId,
            title: target.track.title,
            language: target.track.language,
            codec: target.track.codec,
          ),
          language: describeSubtitleLanguage(
            language: target.track.language,
            title: target.track.title,
          ),
          selectable:
              nativeTracks
                  .where((other) => other.track.id == target.track.id)
                  .length ==
              1,
        ),
      );
    }
    return SubtitleChoiceCatalog._(plan.mediaSourceId, candidates);
  }

  final String mediaSourceId;
  final List<_Candidate> _candidates;

  /// Call only after the controller confirms this manual choice was applied.
  /// Ambiguous fingerprints may be saved but will never be restored by order.
  SubtitleRememberedChoice? capture(SubtitleSelection selection) {
    if (mediaSourceId.trim().isEmpty) return null;
    if (selection.isDisabled) return const SubtitleRememberedChoice.disabled();
    if (selection.source == SubtitleSelectionSource.serverDefault) return null;
    final matches = _candidates
        .where(
          (candidate) =>
              candidate.selectable &&
              _sameSelection(candidate.selection, selection),
        )
        .toList();
    if (matches.length != 1 || matches.single.fingerprint == null) return null;
    return SubtitleRememberedChoice._(
      matches.single.kind,
      matches.single.fingerprint,
    );
  }

  SubtitlePreferenceResolution resolve({
    SubtitleRememberedChoice? remembered,
    SubtitlePreferences preferences = const SubtitlePreferences(),
  }) {
    if (remembered != null) {
      if (remembered.kind == RememberedSubtitleKind.disabled) {
        return const SubtitlePreferenceResolution(
          status: SubtitlePreferenceStatus.matched,
          origin: SubtitlePreferenceOrigin.remembered,
          selection: SubtitleSelection.disabled(),
        );
      }
      final matches = _candidates
          .where(
            (candidate) =>
                _sameKind(candidate.kind, remembered.kind) &&
                candidate.fingerprint == remembered.fingerprint,
          )
          .toList();
      return _resolveMatches(matches, SubtitlePreferenceOrigin.remembered);
    }
    if (preferences.language == SubtitleLanguagePreference.serverDefault) {
      return const SubtitlePreferenceResolution(
        status: SubtitlePreferenceStatus.serverDefault,
        origin: SubtitlePreferenceOrigin.preference,
      );
    }
    // Server rows may describe the same native track. Never treat those two
    // namespaces as independent competing candidates or merge their IDs.
    final server = _candidates
        .where((candidate) => candidate.kind != RememberedSubtitleKind.native)
        .toList();
    var matches = (server.isNotEmpty ? server : _candidates).where((candidate) {
      final language = candidate.language;
      if (!language.isChinese ||
          language.script == ChineseSubtitleScript.conflicting) {
        return false;
      }
      if (preferences.forced == SubtitleForcedPreference.avoid &&
          language.forced != false) {
        return false;
      }
      return switch (preferences.language) {
        SubtitleLanguagePreference.chinese => true,
        SubtitleLanguagePreference.simplifiedChinese =>
          language.script == ChineseSubtitleScript.simplified,
        SubtitleLanguagePreference.traditionalChinese =>
          language.script == ChineseSubtitleScript.traditional,
        SubtitleLanguagePreference.bilingualChinese => language.isBilingual,
        SubtitleLanguagePreference.serverDefault => false,
      };
    }).toList();
    if (preferences.forced == SubtitleForcedPreference.prefer) {
      final forced = matches
          .where((candidate) => candidate.language.forced == true)
          .toList();
      if (forced.isNotEmpty) matches = forced;
    }
    return _resolveMatches(matches, SubtitlePreferenceOrigin.preference);
  }
}

class _Candidate {
  const _Candidate({
    required this.kind,
    required this.selection,
    required this.fingerprint,
    required this.language,
    required this.selectable,
  });
  final RememberedSubtitleKind kind;
  final SubtitleSelection selection;
  final String? fingerprint;
  final SubtitleLanguageInfo language;
  final bool selectable;
}

SubtitlePreferenceResolution _resolveMatches(
  List<_Candidate> matches,
  SubtitlePreferenceOrigin origin,
) => SubtitlePreferenceResolution(
  status: matches.isEmpty
      ? SubtitlePreferenceStatus.unavailable
      : matches.length != 1 || !matches.single.selectable
      ? SubtitlePreferenceStatus.ambiguous
      : SubtitlePreferenceStatus.matched,
  origin: origin,
  selection: matches.length == 1 && matches.single.selectable
      ? matches.single.selection
      : null,
);

String? _fingerprint({
  required String sourceId,
  String? title,
  String? language,
  String? codec,
  bool? forced,
  bool? external,
}) {
  String? normalize(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim().toLowerCase();
  final normalizedLanguage = switch (normalize(language)) {
    'und' || 'unknown' => null,
    'chi' || 'zho' => 'zh',
    'eng' => 'en',
    final value => value,
  };
  final normalizedCodec = switch (normalize(codec)) {
    'subrip' => 'srt',
    'webvtt' => 'vtt',
    final value => value,
  };
  final normalizedTitle = switch (normalize(title)) {
    'subtitle' || 'subtitles' || '字幕' || 'unknown' => null,
    final value => value,
  };
  // Codec alone cannot identify a remembered track.
  if (normalizedTitle == null && normalizedLanguage == null) return null;
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            sourceId,
            normalizedTitle,
            normalizedLanguage,
            normalizedCodec,
            forced,
            external,
          ]),
        ),
      )
      .toString();
}

bool _sameSelection(SubtitleSelection left, SubtitleSelection right) {
  if (left.source != right.source) return false;
  if (left.target case final NativeSubtitleTrack first) {
    final second = right.target;
    return second is NativeSubtitleTrack &&
        first.track.id == second.track.id &&
        _sameBinding(first.binding, second.binding);
  }
  if (left.target case final LocalExternalAsset first) {
    final second = right.target;
    return second is LocalExternalAsset &&
        first.index == second.index &&
        first.uri == second.uri &&
        _sameBinding(first.binding, second.binding);
  }
  return left.streamIndex == right.streamIndex;
}

bool _sameBinding(SubtitleInputBinding left, SubtitleInputBinding right) =>
    left.itemId == right.itemId &&
    identical(left.itemSession, right.itemSession) &&
    identical(left.engine, right.engine) &&
    left.generation == right.generation &&
    left.inputEpoch == right.inputEpoch;

bool _sameKind(RememberedSubtitleKind left, RememberedSubtitleKind right) =>
    left == right ||
    ((left == RememberedSubtitleKind.server ||
            left == RememberedSubtitleKind.localExternal) &&
        (right == RememberedSubtitleKind.server ||
            right == RememberedSubtitleKind.localExternal));
