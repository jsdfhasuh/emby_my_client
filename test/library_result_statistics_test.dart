import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:emby_my_client/library/library_result_statistics.dart';
import 'package:emby_my_client/library/library_scroll_position_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const snapshot = LibraryPositionSnapshot(
    firstVisible: 25,
    lastVisible: 48,
    loadedCount: 60,
    totalCount: 100,
  );

  test('ordinary media shows range, total and percentage', () {
    final result = const LibraryResultStatistics(
      state: LibraryBrowseState(),
      loadedCount: 60,
      totalCount: 100,
    ).present(snapshot);

    expect(result.rangeLabel, '25–48');
    expect(result.totalLabel, '共 100 项');
    expect(result.percentageLabel, '37%');
    expect(result.remainingLabel, isNull);
  });

  test('unplayed, played and favorites use distinct remaining semantics', () {
    final unplayed = LibraryResultStatistics(
      state: const LibraryBrowseState(
        playedFilter: LibraryPlayedFilter.unplayed,
      ),
      loadedCount: 60,
      totalCount: 100,
    ).present(snapshot);
    expect(unplayed.rangeLabel, '未播放 25–48');
    expect(unplayed.remainingLabel, '还剩 52 项');
    expect(unplayed.percentageLabel, '37%');

    final played = LibraryResultStatistics(
      state: const LibraryBrowseState(playedFilter: LibraryPlayedFilter.played),
      loadedCount: 60,
      totalCount: 100,
    ).present(snapshot);
    expect(played.rangeLabel, '已播放 25–48');
    expect(played.remainingLabel, '筛选结果还剩 52 项');
    expect(played.percentageLabel, isNull);

    final favoriteMovies = LibraryResultStatistics(
      state: const LibraryBrowseState(
        scope: LibraryBrowseScope.favorites,
        mediaType: LibraryMediaType.movie,
      ),
      loadedCount: 60,
      totalCount: 100,
    ).present(snapshot);
    expect(favoriteMovies.rangeLabel, '收藏电影 25–48');
    expect(favoriteMovies.remainingLabel, '筛选结果还剩 52 项');
  });

  test('directory, genre and tag totals never use media remaining labels', () {
    for (final entry in const [
      (LibraryBrowseScope.directory, '目录共 100 项'),
      (LibraryBrowseScope.genres, '分类共 100 项'),
      (LibraryBrowseScope.tags, '标签共 100 项'),
    ]) {
      final result = LibraryResultStatistics(
        state: LibraryBrowseState(scope: entry.$1),
        loadedCount: 60,
        totalCount: 100,
      ).present(snapshot);
      expect(result.rangeLabel, '25–48');
      expect(result.totalLabel, entry.$2);
      expect(result.remainingLabel, isNull);
      expect(result.percentageLabel, '37%');
    }
  });

  test('effective total never falls below the loaded result count', () {
    const statistics = LibraryResultStatistics(
      state: LibraryBrowseState(),
      loadedCount: 60,
      totalCount: 20,
    );
    const loadedSnapshot = LibraryPositionSnapshot(
      firstVisible: 49,
      lastVisible: 60,
      loadedCount: 60,
      totalCount: 60,
    );

    expect(statistics.effectiveTotal, 60);
    final result = statistics.present(loadedSnapshot);
    expect(result.totalLabel, '共 60 项');
    expect(result.percentageLabel, '91%');
  });

  test('local scans report facts only until a complete result exists', () {
    for (final entry in const [
      (LibraryLocalScanStatus.scanning, '继续统计中'),
      (LibraryLocalScanStatus.interrupted, '统计中断，可重试'),
    ]) {
      final result = LibraryResultStatistics(
        state: const LibraryBrowseState(
          localFilter: LibraryLocalMediaFilter.strm,
        ),
        loadedCount: 12,
        totalCount: 200,
        scannedCount: 60,
        scanStatus: entry.$1,
      ).present(snapshot);
      expect(result.rangeLabel, '已匹配 12 项');
      expect(result.totalLabel, '已扫描 60/200 项');
      expect(result.statusLabel, entry.$2);
      expect(result.remainingLabel, isNull);
      expect(result.percentageLabel, isNull);
    }

    final complete =
        LibraryResultStatistics(
          state: const LibraryBrowseState(
            localFilter: LibraryLocalMediaFilter.strm,
          ),
          loadedCount: 12,
          totalCount: 200,
          scannedCount: 200,
          scanStatus: LibraryLocalScanStatus.complete,
        ).present(
          const LibraryPositionSnapshot(
            firstVisible: 1,
            lastVisible: 6,
            loadedCount: 12,
            totalCount: 12,
          ),
        );
    expect(complete.rangeLabel, 'STRM 1–6');
    expect(complete.totalLabel, '共 12 项');
    expect(complete.remainingLabel, '筛选结果还剩 6 项');
    expect(complete.percentageLabel, '29%');
  });

  test('unknown and dirty scans never claim an exact local total', () {
    for (final statistics in [
      const LibraryResultStatistics(
        state: LibraryBrowseState(localFilter: LibraryLocalMediaFilter.regular),
        loadedCount: 8,
        scannedCount: 60,
        sourceTotalCount: 60,
        scanStatus: LibraryLocalScanStatus.complete,
        unknownClassificationCount: 2,
      ),
      const LibraryResultStatistics(
        state: LibraryBrowseState(localFilter: LibraryLocalMediaFilter.strm),
        loadedCount: 8,
        scannedCount: 60,
        sourceTotalCount: 60,
        scanStatus: LibraryLocalScanStatus.complete,
        dirty: true,
      ),
    ]) {
      final result = statistics.present(snapshot);
      expect(statistics.effectiveTotal, isNull);
      expect(result.rangeLabel, '已匹配 8 项');
      expect(result.remainingLabel, isNull);
      expect(result.percentageLabel, isNull);
    }

    expect(
      const LibraryResultStatistics(
        state: LibraryBrowseState(localFilter: LibraryLocalMediaFilter.regular),
        loadedCount: 8,
        scannedCount: 60,
        scanStatus: LibraryLocalScanStatus.complete,
        unknownClassificationCount: 2,
      ).present(snapshot).statusLabel,
      '有 2 项无法判断',
    );
    expect(
      const LibraryResultStatistics(
        state: LibraryBrowseState(localFilter: LibraryLocalMediaFilter.strm),
        loadedCount: 8,
        scannedCount: 60,
        scanStatus: LibraryLocalScanStatus.complete,
        dirty: true,
      ).present(snapshot).statusLabel,
      '结果已变化，请刷新统计',
    );
  });
}
