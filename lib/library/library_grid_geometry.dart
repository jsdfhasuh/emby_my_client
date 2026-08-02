import 'package:flutter/widgets.dart';

const libraryMediaGridGeometry = LibraryMediaGridGeometry();

class LibraryMediaGridGeometry
    extends SliverGridDelegateWithMaxCrossAxisExtent {
  const LibraryMediaGridGeometry({
    this.padding = const EdgeInsets.all(16),
    super.maxCrossAxisExtent = 180,
    super.childAspectRatio = 0.52,
    super.crossAxisSpacing = 12,
    super.mainAxisSpacing = 18,
  });

  final EdgeInsets padding;
}
