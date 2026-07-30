import 'package:flutter/material.dart';

class TrickplayPreview extends StatelessWidget {
  const TrickplayPreview({
    super.key,
    required this.image,
    required this.thumbnailWidth,
    required this.thumbnailHeight,
    required this.columns,
    required this.rows,
    required this.column,
    required this.row,
  });

  final ImageProvider image;
  final int thumbnailWidth;
  final int thumbnailHeight;
  final int columns;
  final int rows;
  final int column;
  final int row;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: thumbnailWidth / thumbnailHeight,
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final sheetWidth = constraints.maxWidth * columns;
            final sheetHeight = constraints.maxHeight * rows;
            final alignmentX = columns <= 1
                ? 0.0
                : -1 + (2 * column / (columns - 1));
            final alignmentY = rows <= 1 ? 0.0 : -1 + (2 * row / (rows - 1));
            return OverflowBox(
              minWidth: sheetWidth,
              maxWidth: sheetWidth,
              minHeight: sheetHeight,
              maxHeight: sheetHeight,
              alignment: Alignment(alignmentX, alignmentY),
              child: Image(
                image: image,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => const ColoredBox(
                  color: Color(0xFF252A2C),
                  child: Center(child: Icon(Icons.broken_image_outlined)),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
