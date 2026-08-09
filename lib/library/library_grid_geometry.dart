import 'package:flutter/rendering.dart';

const libraryMediaGridGeometry = LibraryMediaGridGeometry();
const libraryDirectoryGridGeometry = LibraryDirectoryGridGeometry();
const libraryFacetGridGeometry = LibraryFacetGridGeometry();

const libraryIPadMediaGridGeometry = LibraryMediaGridGeometry(
  crossAxisCount: 5,
  childAspectRatio: 0.44,
);
const libraryIPadDirectoryGridGeometry = LibraryDirectoryGridGeometry(
  crossAxisCount: 5,
  childAspectRatio: 1.25,
);
const libraryIPadFacetGridGeometry = LibraryFacetGridGeometry(
  crossAxisCount: 5,
  childAspectRatio: 1.3,
);

abstract class LibraryGridGeometry extends SliverGridDelegate {
  const LibraryGridGeometry({
    required this.padding,
    required this.maxCrossAxisExtent,
    required this.crossAxisCount,
    required this.childAspectRatio,
    required this.crossAxisSpacing,
    required this.mainAxisSpacing,
  }) : assert(maxCrossAxisExtent > 0),
       assert(crossAxisCount == null || crossAxisCount > 0);

  final EdgeInsets padding;
  final double maxCrossAxisExtent;
  final int? crossAxisCount;
  final double childAspectRatio;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final fixedCount = crossAxisCount;
    if (fixedCount != null) {
      return SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: fixedCount,
        childAspectRatio: childAspectRatio,
        crossAxisSpacing: crossAxisSpacing,
        mainAxisSpacing: mainAxisSpacing,
      ).getLayout(constraints);
    }
    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxCrossAxisExtent,
      childAspectRatio: childAspectRatio,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
    ).getLayout(constraints);
  }

  @override
  bool shouldRelayout(covariant LibraryGridGeometry oldDelegate) =>
      padding != oldDelegate.padding ||
      maxCrossAxisExtent != oldDelegate.maxCrossAxisExtent ||
      crossAxisCount != oldDelegate.crossAxisCount ||
      childAspectRatio != oldDelegate.childAspectRatio ||
      crossAxisSpacing != oldDelegate.crossAxisSpacing ||
      mainAxisSpacing != oldDelegate.mainAxisSpacing;
}

class LibraryMediaGridGeometry extends LibraryGridGeometry {
  const LibraryMediaGridGeometry({
    super.padding = const EdgeInsets.all(16),
    super.maxCrossAxisExtent = 180,
    super.crossAxisCount,
    super.childAspectRatio = 0.46,
    super.crossAxisSpacing = 12,
    super.mainAxisSpacing = 18,
  });
}

class LibraryDirectoryGridGeometry extends LibraryGridGeometry {
  const LibraryDirectoryGridGeometry({
    super.padding = const EdgeInsets.all(16),
    super.maxCrossAxisExtent = 280,
    super.crossAxisCount,
    super.childAspectRatio = 1.45,
    super.crossAxisSpacing = 12,
    super.mainAxisSpacing = 12,
  });
}

class LibraryFacetGridGeometry extends LibraryGridGeometry {
  const LibraryFacetGridGeometry({
    super.padding = const EdgeInsets.all(16),
    super.maxCrossAxisExtent = 240,
    super.crossAxisCount,
    super.childAspectRatio = 1.45,
    super.crossAxisSpacing = 12,
    super.mainAxisSpacing = 12,
  });
}
