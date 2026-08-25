enum SeekPreviewMode { automatic, serverOnly, off }

SeekPreviewMode seekPreviewModeFromJson(dynamic value) {
  final name = value?.toString();
  for (final mode in SeekPreviewMode.values) {
    if (mode.name == name) return mode;
  }
  return SeekPreviewMode.automatic;
}
