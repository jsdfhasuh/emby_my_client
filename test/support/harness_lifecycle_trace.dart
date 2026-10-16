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
