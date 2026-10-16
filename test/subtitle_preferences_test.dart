import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/playback_engine.dart';
import 'package:emby_my_client/playback/playback_state.dart';
import 'package:emby_my_client/playback/subtitle_preferences.dart';
import 'package:emby_my_client/playback/subtitle_target.dart';
import 'package:emby_my_client/playback/subtitle_track_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unknown forced flags and conflicting language never auto-select', () {
    expect(
      _catalog([
        {'Index': 2, 'Type': 'Subtitle', 'Language': 'chi'},
      ]).resolve().status,
      SubtitlePreferenceStatus.unavailable,
    );
    expect(
      _catalog([_stream(2, language: 'eng', title: '简体中文')]).resolve().status,
      SubtitlePreferenceStatus.unavailable,
    );
    expect(
      _catalog([_stream(2, language: 'chi', title: 'Forced')]).resolve().status,
      SubtitlePreferenceStatus.unavailable,
    );
  });
  test('default Chinese preference selects one supported non-forced track', () {
    final result = _catalog([
      _stream(2, language: 'eng'),
      _stream(9, language: 'zho'),
    ]).resolve();
    expect(result.status, SubtitlePreferenceStatus.matched);
    expect(result.selection?.streamIndex, 9);
    expect(result.origin, SubtitlePreferenceOrigin.preference);
  });

  test('bare Chinese is never assumed simplified or traditional', () {
    final catalog = _catalog([_stream(2, language: 'zho')]);
    for (final preference in [
      SubtitleLanguagePreference.simplifiedChinese,
      SubtitleLanguagePreference.traditionalChinese,
      SubtitleLanguagePreference.bilingualChinese,
    ]) {
      expect(
        catalog
            .resolve(preferences: SubtitlePreferences(language: preference))
            .status,
        SubtitlePreferenceStatus.unavailable,
      );
    }
    expect(
      describeSubtitleLanguage(language: 'chi').script,
      ChineseSubtitleScript.unknown,
    );
  });

  test('script and bilingual preferences require explicit evidence', () {
    final catalog = _catalog([
      _stream(2, language: 'zh-Hans'),
      _stream(3, language: 'zh-Hant'),
      _stream(4, language: 'zho', title: '中英双语'),
    ]);
    for (final (preference, expected) in [
      (SubtitleLanguagePreference.simplifiedChinese, 2),
      (SubtitleLanguagePreference.traditionalChinese, 3),
      (SubtitleLanguagePreference.bilingualChinese, 4),
    ]) {
      expect(
        catalog
            .resolve(preferences: SubtitlePreferences(language: preference))
            .selection
            ?.streamIndex,
        expected,
      );
    }
    expect(catalog.resolve().status, SubtitlePreferenceStatus.ambiguous);
  });

  test('conflicting script hints never win an automatic preference', () {
    final catalog = _catalog([_stream(1, language: 'zh-Hans', title: '繁体中文')]);
    expect(catalog.resolve().status, SubtitlePreferenceStatus.unavailable);
    expect(
      describeSubtitleLanguage(language: 'zh-Hans', title: '繁体中文').label,
      contains('冲突'),
    );
  });

  test('forced policy is explicit and ties remain ambiguous', () {
    final catalog = _catalog([
      _stream(2, language: 'chi'),
      _stream(3, language: 'chi', forced: true),
    ]);
    expect(catalog.resolve().selection?.streamIndex, 2);
    expect(
      catalog
          .resolve(
            preferences: const SubtitlePreferences(
              forced: SubtitleForcedPreference.allow,
            ),
          )
          .status,
      SubtitlePreferenceStatus.ambiguous,
    );
    expect(
      catalog
          .resolve(
            preferences: const SubtitlePreferences(
              forced: SubtitleForcedPreference.prefer,
            ),
          )
          .selection
          ?.streamIndex,
      3,
    );
    expect(
      _catalog([_stream(3, language: 'chi', forced: true)]).resolve().status,
      SubtitlePreferenceStatus.unavailable,
    );
  });

  test('remembered server choice follows metadata through index reorder', () {
    final original = _catalog([_stream(2, title: 'Original', language: 'eng')]);
    final choice = original.capture(const SubtitleSelection.explicitStream(2));
    expect(choice, isNotNull);
    final changed = _catalog([
      _stream(2, title: 'Different', language: 'chi'),
      _stream(18, title: 'Original', language: 'eng')
        ..['DisplayTitle'] = 'new server label',
    ]);
    final result = changed.resolve(remembered: choice);
    expect(result.status, SubtitlePreferenceStatus.matched);
    expect(result.selection?.streamIndex, 18);
    expect(result.origin, SubtitlePreferenceOrigin.remembered);
  });

  test('deleted, changed and other-source tracks do not restore', () {
    final saved = _catalog([
      _stream(2, title: 'Original'),
    ]).capture(const SubtitleSelection.explicitStream(2));
    for (final catalog in [
      _catalog([]),
      _catalog([_stream(2, title: 'Changed')]),
      _catalog([_stream(2, title: 'Original', codec: 'ass')]),
      _catalog([_stream(2, title: 'Original')], source: 'other-source'),
    ]) {
      expect(
        catalog.resolve(remembered: saved).status,
        SubtitlePreferenceStatus.unavailable,
      );
    }
  });

  test('duplicate metadata and duplicate IDs never restore by position', () {
    final saved = _catalog([
      _stream(2, title: 'Original'),
    ]).capture(const SubtitleSelection.explicitStream(2));
    final duplicateMetadata = _catalog([
      _stream(2, title: 'Original'),
      _stream(3, title: 'Original'),
    ]);
    expect(
      duplicateMetadata.resolve(remembered: saved).status,
      SubtitlePreferenceStatus.ambiguous,
    );
    final duplicateIds = _catalog([
      _stream(2, title: 'Original'),
      _stream(2, title: 'Different'),
    ]);
    expect(
      duplicateIds.capture(const SubtitleSelection.explicitStream(2)),
      isNull,
    );
    expect(
      duplicateIds.resolve(remembered: saved).status,
      SubtitlePreferenceStatus.ambiguous,
    );
  });

  test('disabled choice overrides language preference and round-trips', () {
    final saved = _catalog([
      _stream(2),
    ]).capture(const SubtitleSelection.disabled());
    final restored = SubtitleRememberedChoice.fromJson(saved!.toJson());
    expect(
      _catalog([
        _stream(5),
      ]).resolve(remembered: restored).selection?.isDisabled,
      isTrue,
    );
    expect(
      SubtitleRememberedChoice.fromJson({
        'kind': 'native',
        'fingerprint': 'bad',
      }),
      isNull,
    );
    expect(SubtitleRememberedChoice.fromJson({'kind': 'future'}), isNull);
  });

  test('native restore rebinds metadata to current ID, never persists ID', () {
    final old = _native(id: '81', title: 'Original', epoch: 1);
    final oldCatalog = SubtitleChoiceCatalog.fromPlayback(
      plan: _plan([]),
      nativeTracks: [old],
    );
    final saved = oldCatalog.capture(SubtitleSelection.nativeTrack(old));
    expect(saved, isNotNull);
    expect(saved!.toJson().toString(), isNot(contains('Original')));
    expect(saved.toJson().containsKey('id'), isFalse);
    final current = _native(id: '99', title: 'Original', epoch: 2);
    final catalog = SubtitleChoiceCatalog.fromPlayback(
      plan: _plan([]),
      nativeTracks: [current],
    );
    final selected = catalog.resolve(remembered: saved).selection?.target;
    expect(selected, same(current));
    expect(catalog.capture(SubtitleSelection.nativeTrack(old)), isNull);
    expect(
      catalog.resolve().status,
      SubtitlePreferenceStatus.unavailable,
      reason: 'forced metadata is unknown for native tracks',
    );
  });

  test('native reused ID and duplicate metadata cannot bypass fingerprint', () {
    final old = _native(id: '81', title: 'Original');
    final saved = SubtitleChoiceCatalog.fromPlayback(
      plan: _plan([]),
      nativeTracks: [old],
    ).capture(SubtitleSelection.nativeTrack(old));
    final changed = SubtitleChoiceCatalog.fromPlayback(
      plan: _plan([]),
      nativeTracks: [_native(id: '81', title: 'Different')],
    );
    expect(
      changed.resolve(remembered: saved).status,
      SubtitlePreferenceStatus.unavailable,
    );
    final duplicate = SubtitleChoiceCatalog.fromPlayback(
      plan: _plan([]),
      nativeTracks: [
        _native(id: '82', title: 'Original'),
        _native(id: '83', title: 'Original'),
      ],
    );
    expect(
      duplicate.resolve(remembered: saved).status,
      SubtitlePreferenceStatus.ambiguous,
    );
  });

  test('local asset restore ignores path changes and uses current binding', () {
    final old = LocalExternalAsset(
      2,
      Uri.file('/private/old.srt'),
      _binding(1),
    );
    final plan = _plan([_stream(2, title: 'Original', external: true)]);
    final saved = SubtitleChoiceCatalog.fromPlayback(
      plan: plan,
      localAssets: [old],
    ).capture(SubtitleSelection.localExternal(old));
    expect(saved!.toJson().toString(), isNot(contains('/private/')));
    final current = LocalExternalAsset(
      7,
      Uri.file('/private/new.srt'),
      _binding(2),
    );
    final catalog = SubtitleChoiceCatalog.fromPlayback(
      plan: _plan([_stream(7, title: 'Original', external: true)]),
      localAssets: [current],
    );
    expect(catalog.resolve(remembered: saved).selection?.target, same(current));
    final online = _catalog([_stream(12, title: 'Original', external: true)]);
    expect(online.resolve(remembered: saved).selection?.streamIndex, 12);
  });

  test('empty identity and server-default choices cannot be remembered', () {
    final empty = _catalog([
      {'Index': 2, 'Type': 'Subtitle', 'Codec': 'srt'},
    ]);
    expect(empty.capture(const SubtitleSelection.explicitStream(2)), isNull);
    expect(
      _catalog([
        _stream(2),
      ]).capture(const SubtitleSelection.followServerDefault()),
      isNull,
    );
    expect(
      _catalog([
        _stream(2),
      ], source: '').capture(const SubtitleSelection.disabled()),
      isNull,
    );
  });

  test('invalid preference fields fall back independently', () {
    final value = SubtitlePreferences.fromJson({
      'language': 'future',
      'forced': 'prefer',
    });
    expect(value.language, SubtitleLanguagePreference.chinese);
    expect(value.forced, SubtitleForcedPreference.prefer);
    expect(SubtitlePreferences.fromJson(value.toJson()).forced, value.forced);
    expect(
      _catalog([_stream(2)])
          .resolve(
            preferences: const SubtitlePreferences(
              language: SubtitleLanguagePreference.serverDefault,
            ),
          )
          .status,
      SubtitlePreferenceStatus.serverDefault,
    );
  });
}

Map<String, dynamic> _stream(
  int index, {
  String? title,
  String language = 'chi',
  String codec = 'srt',
  bool forced = false,
  bool external = false,
}) => {
  'Index': index,
  'Type': 'Subtitle',
  'Language': language,
  'Codec': codec,
  'IsForced': forced,
  'IsExternal': external,
  'Title': ?title,
};

PlaybackPlan _plan(
  List<Map<String, dynamic>> streams, {
  String source = 'source',
}) => PlaybackPlan(
  uri: Uri.parse('https://example.test/video'),
  mediaSourceId: source,
  playSessionId: null,
  method: PlayMethod.directPlay,
  usesServerAuthentication: false,
  mediaStreams: streams,
  transcodingReasons: const [],
  availableMediaSources: const [],
);

SubtitleChoiceCatalog _catalog(
  List<Map<String, dynamic>> streams, {
  String source = 'source',
}) => SubtitleChoiceCatalog.fromPlayback(plan: _plan(streams, source: source));

final _engine = _Engine();
final _session = Object();
SubtitleInputBinding _binding(int epoch) => SubtitleInputBinding(
  itemId: 'item',
  itemSession: _session,
  engine: _engine,
  generation: 1,
  inputEpoch: epoch,
);
NativeSubtitleTrack _native({
  required String id,
  required String title,
  int epoch = 1,
}) => NativeSubtitleTrack(
  EngineTrack(id: id, title: title, language: 'chi', codec: 'srt'),
  _binding(epoch),
);

class _Engine implements PlaybackEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
