import '../../models/emby_models.dart';

class TrickplayFrame {
  const TrickplayFrame({
    required this.sheetIndex,
    required this.tileIndex,
    required this.column,
    required this.row,
    required this.samplePosition,
  });

  final int sheetIndex;
  final int tileIndex;
  final int column;
  final int row;
  final Duration samplePosition;

  @override
  bool operator ==(Object other) =>
      other is TrickplayFrame &&
      other.sheetIndex == sheetIndex &&
      other.tileIndex == tileIndex &&
      other.column == column &&
      other.row == row &&
      other.samplePosition == samplePosition;

  @override
  int get hashCode =>
      Object.hash(sheetIndex, tileIndex, column, row, samplePosition);
}

class TrickplayFrameResolver {
  const TrickplayFrameResolver._();

  static TrickplayFrame? resolve({
    required Duration position,
    required Duration duration,
    required EmbyTrickplayResolution resolution,
  }) {
    final interval = resolution.intervalMilliseconds;
    final columns = resolution.tileColumns;
    final rows = resolution.tileRows;
    final thumbnailCount = resolution.thumbnailCount;
    if (duration <= Duration.zero ||
        interval <= 0 ||
        columns <= 0 ||
        rows <= 0 ||
        thumbnailCount != null && thumbnailCount <= 0) {
      return null;
    }

    final tilesPerImage = columns * rows;
    if (tilesPerImage <= 0) return null;

    final durationMilliseconds = duration.inMilliseconds;
    if (durationMilliseconds <= 0) return null;

    final theoreticalTileCount = _ceilDivide(durationMilliseconds, interval);
    final availableTileCount = thumbnailCount == null
        ? theoreticalTileCount
        : _min(theoreticalTileCount, thumbnailCount);
    if (availableTileCount <= 0) return null;

    final positionMilliseconds = position.inMilliseconds < 0
        ? 0
        : position.inMilliseconds > durationMilliseconds
        ? durationMilliseconds
        : position.inMilliseconds;
    var tileIndex = positionMilliseconds ~/ interval;
    if (tileIndex >= availableTileCount) tileIndex = availableTileCount - 1;

    final tileOffset = tileIndex % tilesPerImage;
    return TrickplayFrame(
      sheetIndex: tileIndex ~/ tilesPerImage,
      tileIndex: tileIndex,
      column: tileOffset % columns,
      row: tileOffset ~/ columns,
      samplePosition: Duration(milliseconds: tileIndex * interval),
    );
  }

  static int _ceilDivide(int value, int divisor) =>
      value ~/ divisor + (value % divisor == 0 ? 0 : 1);

  static int _min(int left, int right) => left < right ? left : right;
}
