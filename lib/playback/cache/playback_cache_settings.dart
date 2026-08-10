enum PlaybackCacheMode {
  automatic,
  memoryOnly,
  spaceSaving,
  balanced,
  aggressive,
  custom,
}

class PlaybackCacheSettings {
  const PlaybackCacheSettings({
    this.mode = PlaybackCacheMode.automatic,
    this.customForwardSeconds = defaultForwardSeconds,
    this.customBackwardSeconds = defaultBackwardSeconds,
    this.customSessionTargetBytes = defaultSessionTargetBytes,
    this.reservedFreeBytes = defaultReservedFreeBytes,
  });

  static const int minForwardSeconds = 30;
  static const int maxForwardSeconds = 900;
  static const int minBackwardSeconds = 15;
  static const int maxBackwardSeconds = 600;
  static const int minSessionTargetBytes = 128 * 1024 * 1024;
  static const int maxSessionTargetBytes = 4 * 1024 * 1024 * 1024;
  static const int minReservedFreeBytes = 1 * 1024 * 1024 * 1024;
  static const int maxReservedFreeBytes = 8 * 1024 * 1024 * 1024;

  static const int defaultForwardSeconds = 180;
  static const int defaultBackwardSeconds = 120;
  static const int defaultSessionTargetBytes = 512 * 1024 * 1024;
  static const int defaultReservedFreeBytes = 2 * 1024 * 1024 * 1024;

  final PlaybackCacheMode mode;
  final int customForwardSeconds;
  final int customBackwardSeconds;
  final int customSessionTargetBytes;
  final int reservedFreeBytes;

  factory PlaybackCacheSettings.fromJsonValue(Object? value) {
    if (value is! Map) return const PlaybackCacheSettings();
    return PlaybackCacheSettings(
      mode: _modeFromJson(value['mode']),
      customForwardSeconds: _clampedInt(
        value['forwardSeconds'],
        fallback: defaultForwardSeconds,
        minimum: minForwardSeconds,
        maximum: maxForwardSeconds,
      ),
      customBackwardSeconds: _clampedInt(
        value['backwardSeconds'],
        fallback: defaultBackwardSeconds,
        minimum: minBackwardSeconds,
        maximum: maxBackwardSeconds,
      ),
      customSessionTargetBytes: _clampedInt(
        value['sessionTargetBytes'],
        fallback: defaultSessionTargetBytes,
        minimum: minSessionTargetBytes,
        maximum: maxSessionTargetBytes,
      ),
      reservedFreeBytes: _clampedInt(
        value['reservedFreeBytes'],
        fallback: defaultReservedFreeBytes,
        minimum: minReservedFreeBytes,
        maximum: maxReservedFreeBytes,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'forwardSeconds': customForwardSeconds,
    'backwardSeconds': customBackwardSeconds,
    'sessionTargetBytes': customSessionTargetBytes,
    'reservedFreeBytes': reservedFreeBytes,
  };
}

PlaybackCacheMode _modeFromJson(Object? value) {
  final name = value is String ? value : '';
  for (final mode in PlaybackCacheMode.values) {
    if (mode.name == name) return mode;
  }
  return PlaybackCacheMode.automatic;
}

int _clampedInt(
  Object? value, {
  required int fallback,
  required int minimum,
  required int maximum,
}) {
  final parsed = switch (value) {
    int number => number,
    num number => number.toInt(),
    String text => int.tryParse(text),
    _ => null,
  };
  return (parsed ?? fallback).clamp(minimum, maximum);
}
