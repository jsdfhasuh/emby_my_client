import 'package:flutter/rendering.dart';

const libraryMediaGridGeometry = LibraryMediaGridGeometry();
const libraryPhotoGridGeometry = LibraryPhotoGridGeometry();
const libraryMixedGridGeometry = LibraryMixedGridGeometry();
const libraryDirectoryGridGeometry = LibraryDirectoryGridGeometry();
const libraryFacetGridGeometry = LibraryFacetGridGeometry();

const libraryIPadMediaGridGeometry = LibraryMediaGridGeometry(
  crossAxisCount: 5,
  childAspectRatio: 0.5,
);
const libraryIPadPhotoGridGeometry = LibraryPhotoGridGeometry(
  crossAxisCount: 5,
);
const libraryIPadMixedGridGeometry = LibraryMixedGridGeometry(
  crossAxisCount: 5,
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
    this.mainAxisExtent,
    required this.crossAxisSpacing,
    required this.mainAxisSpacing,
  }) : assert(maxCrossAxisExtent > 0),
       assert(crossAxisCount == null || crossAxisCount > 0);

  final EdgeInsets padding;
  final double maxCrossAxisExtent;
  final int? crossAxisCount;
  final double childAspectRatio;
  final double? mainAxisExtent;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final fixedCount = crossAxisCount;
    if (fixedCount != null) {
      return SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: fixedCount,
        childAspectRatio: childAspectRatio,
        mainAxisExtent: mainAxisExtent,
        crossAxisSpacing: crossAxisSpacing,
        mainAxisSpacing: mainAxisSpacing,
      ).getLayout(constraints);
    }
    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxCrossAxisExtent,
      childAspectRatio: childAspectRatio,
      mainAxisExtent: mainAxisExtent,
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
      mainAxisExtent != oldDelegate.mainAxisExtent ||
      crossAxisSpacing != oldDelegate.crossAxisSpacing ||
      mainAxisSpacing != oldDelegate.mainAxisSpacing;
}

double libraryMediaPosterGridMainAxisExtent({
  required double availableWidth,
  required int crossAxisCount,
  required double crossAxisSpacing,
  required double titleLineHeight,
  required double subtitleLineHeight,
}) {
  final cellWidth =
      (availableWidth - crossAxisSpacing * (crossAxisCount - 1)) /
      crossAxisCount;
  const posterHeightFactor = 3 / 2;
  const posterToTitleSpacing = 8.0;
  const titleLineCount = 2;
  const titleToSubtitleSpacing = 2.0;
  const bottomPadding = 4.0;
  return cellWidth * posterHeightFactor +
      posterToTitleSpacing +
      titleLineHeight * titleLineCount +
      titleToSubtitleSpacing +
      subtitleLineHeight +
      bottomPadding;
}

LibraryMediaGridGeometry libraryIPadMediaGridGeometryForViewport({
  required double availableWidth,
  required double titleLineHeight,
  required double subtitleLineHeight,
}) {
  final base = libraryIPadMediaGridGeometry;
  return LibraryMediaGridGeometry(
    padding: base.padding,
    maxCrossAxisExtent: base.maxCrossAxisExtent,
    crossAxisCount: base.crossAxisCount,
    childAspectRatio: base.childAspectRatio,
    mainAxisExtent: libraryMediaPosterGridMainAxisExtent(
      availableWidth: availableWidth,
      crossAxisCount: base.crossAxisCount!,
      crossAxisSpacing: base.crossAxisSpacing,
      titleLineHeight: titleLineHeight,
      subtitleLineHeight: subtitleLineHeight,
    ),
    crossAxisSpacing: base.crossAxisSpacing,
    mainAxisSpacing: base.mainAxisSpacing,
  );
}

class LibraryMediaGridGeometry extends LibraryGridGeometry {
  const LibraryMediaGridGeometry({
    super.padding = const EdgeInsets.all(16),
    super.maxCrossAxisExtent = 180,
    super.crossAxisCount,
    super.childAspectRatio = 0.46,
    super.mainAxisExtent,
    super.crossAxisSpacing = 12,
    super.mainAxisSpacing = 18,
  });
}

class LibraryPhotoGridGeometry extends LibraryGridGeometry {
  const LibraryPhotoGridGeometry({
    super.padding = const EdgeInsets.all(16),
    super.maxCrossAxisExtent = 220,
    super.crossAxisCount,
    super.childAspectRatio = 1,
    super.mainAxisExtent,
    super.crossAxisSpacing = 12,
    super.mainAxisSpacing = 12,
  });
}

class LibraryMixedGridGeometry extends LibraryGridGeometry {
  const LibraryMixedGridGeometry({
    super.padding = const EdgeInsets.all(16),
    super.maxCrossAxisExtent = 300,
    super.crossAxisCount,
    super.childAspectRatio = 4 / 3,
    super.mainAxisExtent,
    super.crossAxisSpacing = 12,
    super.mainAxisSpacing = 12,
  });
}

class LibraryDirectoryGridGeometry extends LibraryGridGeometry {
  const LibraryDirectoryGridGeometry({
    super.padding = const EdgeInsets.all(16),
    super.maxCrossAxisExtent = 280,
    super.crossAxisCount,
    super.childAspectRatio = 1.45,
    super.mainAxisExtent,
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
    super.mainAxisExtent,
    super.crossAxisSpacing = 12,
    super.mainAxisSpacing = 12,
  });
}
