class EmbyImageRequest {
  const EmbyImageRequest({
    required this.uri,
    required this.headers,
    required this.cacheKey,
    required this.decodeWidth,
    required this.decodeHeight,
    this.errorListener,
  });

  static const widthBuckets = <int>[384, 512, 900, 1200, 1280, 1920, 2560];

  final Uri uri;
  final Map<String, String> headers;
  final String cacheKey;
  final int decodeWidth;
  final int decodeHeight;
  final void Function(Object error)? errorListener;

  static int bucketWidth(int requestedWidth) {
    final width = requestedWidth.clamp(widthBuckets.first, widthBuckets.last);
    for (final bucket in widthBuckets) {
      if (bucket >= width) return bucket;
    }
    return widthBuckets.last;
  }

  @override
  String toString() =>
      'EmbyImageRequest(cacheKey: $cacheKey, '
      'decodeWidth: $decodeWidth, decodeHeight: $decodeHeight)';
}
