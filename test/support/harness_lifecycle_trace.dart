// Test-only extraction: never retain source lines, trace IDs, URLs or paths.
Map<String, Object>? safeHarnessLifecycleEvent(String line) {
  const fields = <String, Map<String, Set<String>>>{
    'playback_ready': {
      'method': {'DirectPlay', 'DirectStream', 'Transcode'},
    },
    'app_lifecycle_changed': {
      'lifecycleState': {'resumed', 'inactive', 'hidden', 'paused', 'detached'},
    },
    'playback_cache_budget_guard_reached': {
      'reason': {'budget'},
    },
    'playback_cache_low_space': {
      'reason': {'lowSpace'},
    },
    'playback_cache_memory_pressure': {
      'reason': {'memoryPressure'},
    },
    'playback_seek_recovery_pending': {},
    'playback_seek_recovery_started': {},
    'playback_seek_recovery_succeeded': {},
    'playback_seek_recovery_failed': {},
    'playback_native_failure': {
      'channel': {'log', 'error'},
      'prefix': {
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
        'other',
      },
      'level': {'error', 'fatal'},
      'kind': {
        'cache_probe_unsettled',
        'file_cache_failed',
        'file_missing',
        'permission_denied',
        'property_missing',
        'invalid_option',
        'disposed',
        'decoder_missing',
        'decoder_failed',
        'audio_output_failed',
        'video_output_failed',
        'open_failed',
        'invalid_media',
        'command_failed',
        'io_error',
        'out_of_memory',
        'other',
      },
      'phase': {
        'idle',
        'resolving',
        'opening',
        'waitingForReady',
        'retryingWithTranscode',
        'seekingResume',
        'ready',
        'stopping',
        'failed',
        'recoveryPending',
        'recovering',
      },
      'step': {
        'idle',
        'binding',
        'resolving',
        'cacheSetup',
        'engineOpen',
        'waitingReady',
        'tracks',
        'presentation',
        'resumeSeek',
        'playbackIntent',
        'ready',
        'cleanup',
      },
      'lifecycleSuspended': {'true', 'false'},
    },
    'playback_engine_error': {
      'stage': {'native_open', 'native_read'},
      'outcome': {'failed'},
    },
  };
  final tokens = <String, String>{
    for (final match in RegExp(
      r'(?:^|\s)([A-Za-z]+)=([^\s]+)',
    ).allMatches(line))
      match[1]!: match[2]!,
  };
  final event = tokens['event'];
  final allowed = fields[event];
  if (event == null || allowed == null) return null;
  final result = <String, Object>{'event': event};
  for (final entry in allowed.entries) {
    final value = tokens[entry.key];
    if (value == null || !entry.value.contains(value)) return null;
    result[entry.key] = value;
  }
  if (event == 'playback_native_failure') {
    for (final name in ['generation', 'inputEpoch']) {
      final value = tokens[name];
      if (value == null || !RegExp(r'^[0-9]{1,6}$').hasMatch(value)) {
        return null;
      }
      result[name] = int.parse(value);
    }
  }
  if (event == 'playback_cache_memory_pressure' ||
      event == 'playback_cache_low_space' ||
      event == 'playback_cache_budget_guard_reached') {
    const subtitleEnums = {
      'subtitleStatus': {
        'notApplied',
        'applying',
        'waitingForTracks',
        'appliedNone',
        'appliedEmbedded',
        'appliedExternal',
        'appliedServer',
        'disabled',
        'failed',
      },
      'subtitleSource': {
        'serverDefault',
        'explicit',
        'native',
        'localExternal',
        'disabled',
      },
    };
    for (final entry in subtitleEnums.entries) {
      final value = tokens[entry.key];
      if (value != null && entry.value.contains(value)) {
        result[entry.key] = value;
      }
    }
    for (final name in ['subtitleRevision', 'inputEpoch']) {
      final value = tokens[name];
      if (value != null && RegExp(r'^[0-9]{1,10}$').hasMatch(value)) {
        result[name] = int.parse(value);
      }
    }
  }
  const fingerprints = {
    'seek_failed',
    'partial_file',
    'input_output_error',
    'packet_read_error',
    'http-inflate',
    'log-overflow',
    'dns-resolution',
    'http-open',
    'other',
  };
  final fingerprint = tokens['fingerprint'];
  if (fingerprint != null && fingerprints.contains(fingerprint)) {
    result['fingerprint'] = fingerprint;
  }
  return result;
}
