import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/emby_models.dart';
import 'playback_controller.dart';
import 'playback_state.dart';
import 'subtitle_preferences.dart';
import 'subtitle_preferences_repository.dart';
import 'subtitle_target.dart';

/// Resolves preferences only against the current resolved source/input. No
/// persisted native IDs or server ordinals cross an input boundary.
class SubtitlePreferenceBinding extends ChangeNotifier {
  SubtitlePreferenceBinding({
    required this.controller,
    required this.session,
    required this.repository,
  }) {
    controller.subtitlePreferences = this;
    controller.addListener(_changed);
    unawaited(_load());
  }
  final PlaybackController controller;
  final EmbySession session;
  final SubtitlePreferencesRepository repository;
  SubtitlePreferenceSnapshot? snapshot;
  SubtitlePreferenceResolution? resolution;
  String? saveError;
  bool _disposed = false, _manual = false, _pendingSave = false, _busy = false;
  String? _source, _resolvedSource;
  int? _inputEpoch;
  // A confirmed manual choice is useful immediately, even while its durable
  // write is pending. Store only fingerprints, never input-bound targets.
  final _confirmedChoices = <String, SubtitleRememberedChoice>{};
  int _manualRevision = 0;
  SubtitlePreferences get preferences =>
      snapshot?.preferences ?? const SubtitlePreferences();
  bool get _current => !_disposed && controller.acceptsSubtitlePreferences;

  Future<void> _load() async {
    try {
      final value = await repository.load(session);
      if (!_current) return;
      snapshot = value;
      notifyListeners();
      _changed();
    } catch (_) {
      if (!_current) return;
      saveError = '字幕偏好暂时无法读取，本次仍可手动选择';
      notifyListeners();
    }
  }

  void manualSelectionRequested() {
    _manual = true;
    _pendingSave = true;
    _manualRevision++;
    // Selecting the already-applied row need not emit a controller event.
    scheduleMicrotask(_changed);
  }

  void _changed() {
    if (!_current) return;
    final state = controller.state;
    final plan = state.plan;
    if (plan == null || plan.mediaSourceId.isEmpty || snapshot == null) return;
    final epoch = controller.subtitleInputEpoch;
    final sourceChanged = _source != plan.mediaSourceId;
    if (sourceChanged || _inputEpoch != epoch) {
      if (_source != null) {
        // A manual server selection may require reopening a transcoded input.
        // Keep that pending intent until the new input confirms it. A native
        // or local target cannot cross this boundary and must be re-resolved.
        final pendingServerChoice =
            !sourceChanged &&
            _pendingSave &&
            (state.desiredSubtitleSelection.source ==
                    SubtitleSelectionSource.explicit ||
                state.desiredSubtitleSelection.isDisabled);
        _manual = pendingServerChoice;
        _pendingSave = pendingServerChoice;
        _manualRevision++;
      }
      _source = plan.mediaSourceId;
      _inputEpoch = epoch;
      _resolvedSource = null;
      resolution = null;
    }
    if (_pendingSave &&
        _confirmed(state) &&
        state.desiredSubtitleSelection.inputEpoch == epoch) {
      _pendingSave = false;
      final choice = _catalog(plan).capture(state.desiredSubtitleSelection);
      if (choice != null) {
        _confirmedChoices[plan.mediaSourceId] = choice;
        unawaited(_remember(plan.mediaSourceId, choice));
      }
      return;
    }
    if (_busy ||
        _manual ||
        state.phase != PlaybackPhase.ready ||
        _resolvedSource == plan.mediaSourceId) {
      return;
    }
    // An explicit entry/remote selection wins over automatic preferences.
    if (state.desiredSubtitleSelection.source !=
        SubtitleSelectionSource.serverDefault) {
      return;
    }
    resolution = _catalog(plan).resolve(
      remembered:
          _confirmedChoices[plan.mediaSourceId] ??
          snapshot!.rememberedFor(
            itemId: controller.item.id,
            mediaSourceId: plan.mediaSourceId,
          ),
      preferences: preferences,
    );
    final choice = resolution!.selection;
    if (choice == null) {
      notifyListeners();
      return;
    }
    _busy = true;
    final revision = _manualRevision;
    final source = plan.mediaSourceId;
    // Leave the controller listener before changing state or starting native IO.
    scheduleMicrotask(() async {
      try {
        if (!_current ||
            _manual ||
            revision != _manualRevision ||
            controller.state.plan?.mediaSourceId != source ||
            controller.subtitleInputEpoch != epoch) {
          return;
        }
        _resolvedSource = source;
        if (choice.target case final NativeSubtitleTrack target) {
          await controller.selectNativeSubtitle(target, automatic: true);
        } else if (choice.target case final LocalExternalAsset target) {
          await controller.selectLocalSubtitle(target, automatic: true);
        } else {
          await controller.selectSubtitleStream(
            choice.isDisabled ? null : choice.streamIndex,
            automatic: true,
          );
        }
      } finally {
        _busy = false;
        if (_current) {
          notifyListeners();
          // A different input can reach ready while the old apply is pending.
          // Reconsider that current input after releasing the in-flight guard.
          _changed();
        }
      }
    });
  }

  SubtitleChoiceCatalog _catalog(PlaybackPlan plan) =>
      SubtitleChoiceCatalog.fromPlayback(
        plan: plan,
        nativeTracks: controller.nativeSubtitleChoices,
        localAssets: controller.localSubtitleChoices,
      );

  static bool _confirmed(PlaybackState state) => const {
    SubtitleSelectionStatus.appliedEmbedded,
    SubtitleSelectionStatus.appliedExternal,
    SubtitleSelectionStatus.appliedServer,
    SubtitleSelectionStatus.disabled,
  }.contains(state.subtitleSelectionStatus);

  Future<void> _remember(String source, SubtitleRememberedChoice choice) async {
    try {
      final value = await repository.remember(
        session,
        itemId: controller.item.id,
        mediaSourceId: source,
        choice: choice,
        expectedGeneration: snapshot!.generation,
      );
      if (!_current) return;
      snapshot = value;
      saveError = null;
      notifyListeners();
    } catch (_) {
      if (!_current) return;
      saveError = '本次字幕已选择，但记忆保存失败';
      notifyListeners();
    }
  }

  Future<void> setPreferences(SubtitlePreferences value) async {
    final current = snapshot;
    if (!_current || current == null) return;
    try {
      final saved = await repository.setPreferences(
        session,
        value,
        expectedGeneration: current.generation,
      );
      if (!_current) return;
      snapshot = saved;
      saveError = null;
      notifyListeners();
    } catch (_) {
      if (!_current) return;
      saveError = '字幕偏好保存失败，请稍后重试';
      notifyListeners();
    }
  }

  Future<void> forgetCurrentChoice() async {
    final current = snapshot, plan = controller.state.plan;
    if (!_current || current == null || plan == null) return;
    final choiceAtRequest = _confirmedChoices[plan.mediaSourceId];
    try {
      final saved = await repository.forget(
        session,
        itemId: controller.item.id,
        mediaSourceId: plan.mediaSourceId,
        expectedGeneration: current.generation,
      );
      if (!_current) return;
      snapshot = saved;
      if (identical(_confirmedChoices[plan.mediaSourceId], choiceAtRequest)) {
        _confirmedChoices.remove(plan.mediaSourceId);
      }
      saveError = null;
      notifyListeners();
    } catch (_) {
      if (!_current) return;
      saveError = '清除字幕记忆失败，请稍后重试';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_changed);
    super.dispose();
  }
}
