import 'package:flutter/widgets.dart';

const libraryMediaGridGeometry = LibraryMediaGridGeometry();
const libraryDirectoryGridGeometry = LibraryDirectoryGridGeometry();
const libraryFacetGridGeometry = LibraryFacetGridGeometry();

abstract class LibraryGridGeometry
    extends SliverGridDelegateWithMaxCrossAxisExtent {
  const LibraryGridGeometry({
    required this.padding,
    required super.maxCrossAxisExtent,
    required super.childAspectRatio,
    required super.crossAxisSpacing,
    required super.mainAxisSpacing,
  });

  final EdgeInsets padding;
}

class LibraryMediaGridGeometry extends LibraryGridGeometry {
  const LibraryMediaGridGeometry({
    super.padding = const EdgeInsets.all(16),
    super.maxCrossAxisExtent = 180,
    super.childAspectRatio = 0.52,
    super.crossAxisSpacing = 12,
    super.mainAxisSpacing = 18,
  });
}

class LibraryDirectoryGridGeometry extends LibraryGridGeometry {
  const LibraryDirectoryGridGeometry({
    super.padding = const EdgeInsets.all(16),
    super.maxCrossAxisExtent = 280,
    super.childAspectRatio = 1.45,
    super.crossAxisSpacing = 12,
    super.mainAxisSpacing = 12,
  });
}

class LibraryFacetGridGeometry extends LibraryGridGeometry {
  const LibraryFacetGridGeometry({
    super.padding = const EdgeInsets.all(16),
    super.maxCrossAxisExtent = 240,
    super.childAspectRatio = 1.45,
    super.crossAxisSpacing = 12,
    super.mainAxisSpacing = 12,
  });
}
