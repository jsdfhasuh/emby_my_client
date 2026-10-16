import '../core/token_redactor.dart';
import 'playback_state.dart';

enum NativeStartupStep {
  idle,
  binding,
  resolving,
  cacheSetup,
  engineOpen,
  waitingReady,
  tracks,
  presentation,
  resumeSeek,
  playbackIntent,
  ready,
  cleanup,
}

/// Passive, bounded evidence. Never exports native text, URLs, paths or IDs.
/// The step is where Dart received the message, not proof of its native origin.
class NativeFailureEvidence {
  int? _generation;
  final _logs = <int, int>{};
  final _errorsRecorded = <int>{};

  // Setup errors can be nonterminal. Keep independent, bounded evidence for
  // actual media startup, runtime and cleanup in the same generation.
  static int _group(NativeStartupStep step) => switch (step) {
    NativeStartupStep.idle ||
    NativeStartupStep.binding ||
    NativeStartupStep.resolving ||
    NativeStartupStep.cacheSetup => 0,
    NativeStartupStep.ready => 2,
    NativeStartupStep.cleanup => 3,
    _ => 1,
  };

  String? record({
    required String message,
    required bool fromLog,
    required int generation,
    required int inputEpoch,
    required PlaybackPhase phase,
    required NativeStartupStep step,
    required bool lifecycleSuspended,
  }) {
    if (_generation != generation) {
      _generation = generation;
      _logs.clear();
      _errorsRecorded.clear();
    }
    final safe = TokenRedactor.redact(message);
    final parsed = RegExp(
      r'^PlayerLog\(prefix: ([^,]+), level: ([^,]+), text: ',
    ).firstMatch(safe);
    final level = fromLog ? parsed?.group(2) : 'error';
    if (level != 'error' && level != 'fatal') {
      return null;
    }
    final group = _group(step);
    if (fromLog ? (_logs[group] ?? 0) >= 8 : _errorsRecorded.contains(group)) {
      return null;
    }
    if (fromLog) {
      _logs[group] = (_logs[group] ?? 0) + 1;
    } else {
      _errorsRecorded.add(group);
    }
    const prefixes = {
      'file',
      'ffmpeg',
      'vd',
      'ad',
      'cplayer',
      'stream',
      'demux',
      'mkv',
      'lavf',
      'ao',
      'ao/opensles',
      'ao/audiotrack',
      'ao/null',
      'vo',
      'vo/gpu',
      'vo/gpu/opengl',
      'options',
      'sub',
      'osd/libass',
    };
    final rawPrefix = parsed?.group(1);
    final prefix = prefixes.contains(rawPrefix) ? rawPrefix : 'other';
    final lower = safe.toLowerCase();
    final kind = _kind(lower);
    return 'event=playback_native_failure channel=${fromLog ? 'log' : 'error'} '
        'prefix=$prefix level=$level kind=$kind phase=${phase.name} '
        'step=${step.name} generation=${generation.clamp(0, 999999)} '
        'inputEpoch=${inputEpoch.clamp(0, 999999)} '
        'lifecycleSuspended=$lifecycleSuspended';
  }

  static String _kind(String lower) {
    if (lower == 'playback cache probe did not settle') {
      return 'cache_probe_unsettled';
    }
    if (lower.contains('failed to create file cache')) {
      return 'file_cache_failed';
    }
    if (lower.contains('no such file') || lower.contains('file not found')) {
      return 'file_missing';
    }
    if (lower.contains('permission denied') ||
        lower.contains('access denied')) {
      return 'permission_denied';
    }
    if (lower.contains('property not found')) {
      return 'property_missing';
    }
    if (lower.contains('invalid parameter') ||
        lower.contains('out of range') ||
        lower.contains('option value')) {
      return 'invalid_option';
    }
    if (lower.contains('has been disposed')) {
      return 'disposed';
    }
    if (lower.contains('decoder') &&
        (lower.contains('not found') || lower.contains('not available'))) {
      return 'decoder_missing';
    }
    if (lower.contains('decoder') &&
        (lower.contains('fail') || lower.contains('error'))) {
      return 'decoder_failed';
    }
    if (lower.contains('audio output') &&
        (lower.contains('fail') || lower.contains('error'))) {
      return 'audio_output_failed';
    }
    if (lower.contains('video output') &&
        (lower.contains('fail') || lower.contains('error'))) {
      return 'video_output_failed';
    }
    if (lower.contains('failed to open') || lower.contains('error opening')) {
      return 'open_failed';
    }
    if (lower.contains('unrecognized file format') ||
        lower.contains('invalid data')) {
      return 'invalid_media';
    }
    if (lower.contains('command') &&
        (lower.contains('fail') || lower.contains('error'))) {
      return 'command_failed';
    }
    if (lower.contains('input/output error') || lower.contains('i/o error')) {
      return 'io_error';
    }
    if (lower.contains('cannot allocate') || lower.contains('out of memory')) {
      return 'out_of_memory';
    }
    return 'other';
  }
}
