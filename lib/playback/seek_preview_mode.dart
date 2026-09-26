enum SeekPreviewMode { automatic, serverOnly, off }

SeekPreviewMode seekPreviewModeFromJson(dynamic value) {
  final name = value?.toString();
  if (name == SeekPreviewMode.off.name) return SeekPreviewMode.off;
  return SeekPreviewMode.serverOnly;
}

extension SeekPreviewModeNormalization on SeekPreviewMode {
  SeekPreviewMode get normalized => this == SeekPreviewMode.off
      ? SeekPreviewMode.off
      : SeekPreviewMode.serverOnly;
}
