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
    expect(result.percentageLabel, '48%');
    expect(result.remainingLabel, '还剩 52 项');
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
    expect(unplayed.percentageLabel, '48%');

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
    expect(favoriteMovies.percentageLabel, '48%');
  });

  test('directory, genre and tag totals use their own result space', () {
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
      expect(result.remainingLabel, '还剩 52 项');
      expect(result.percentageLabel, '48%');
    }
  });

  test('photo results use photo totals and the last visible position', () {
    final result = const LibraryResultStatistics(
      state: LibraryBrowseState(mediaType: LibraryMediaType.photo),
      loadedCount: 60,
      totalCount: 100,
    ).present(snapshot);

    expect(result.rangeLabel, '25–48');
    expect(result.totalLabel, '图片共 100 项');
    expect(result.remainingLabel, '还剩 52 项');
    expect(result.percentageLabel, '48%');
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
    expect(result.remainingLabel, '还剩 0 项');
    expect(result.percentageLabel, '100%');
  });

  test('local scans report facts only until a complete result exists', () {
    for (final entry in const [
      (LibraryLocalScanStatus.scanning, '已扫描 60 / 200 项'),
      (LibraryLocalScanStatus.interrupted, '已扫描 60 / 200 项'),
    ]) {
      final statistics = LibraryResultStatistics(
        state: const LibraryBrowseState(
          localFilter: LibraryLocalMediaFilter.strm,
        ),
        loadedCount: 12,
        totalCount: 200,
        scannedCount: 60,
        scanStatus: entry.$1,
      );
      final result = statistics.present(snapshot);
      expect(result.rangeLabel, '25–48');
      expect(
        result.totalLabel,
        entry.$1 == LibraryLocalScanStatus.interrupted
            ? 'STRM 扫描已暂停'
            : 'STRM 统计中',
      );
      expect(result.statusLabel, entry.$2);
      expect(result.remainingLabel, isNull);
      expect(result.percentageLabel, isNull);
      expect(statistics.primaryResultLabel, result.totalLabel);
      expect(statistics.primaryResultLabel, isNot(contains('已匹配')));
      expect(statistics.scanProgressLabel, entry.$2);
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
    expect(complete.totalLabel, 'STRM 共 12 项');
    expect(complete.remainingLabel, '还剩 6 项');
    expect(complete.percentageLabel, '50%');
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
      expect(result.rangeLabel, '25–48');
      expect(result.remainingLabel, isNull);
      expect(result.percentageLabel, isNull);
      expect(statistics.primaryResultLabel, contains('统计待确认'));
    }

    expect(
      const LibraryResultStatistics(
        state: LibraryBrowseState(localFilter: LibraryLocalMediaFilter.regular),
        loadedCount: 8,
        scannedCount: 60,
        scanStatus: LibraryLocalScanStatus.complete,
        unknownClassificationCount: 2,
      ).present(snapshot).statusLabel,
      '已扫描 60 项',
    );
    expect(
      const LibraryResultStatistics(
        state: LibraryBrowseState(localFilter: LibraryLocalMediaFilter.strm),
        loadedCount: 8,
        scannedCount: 60,
        scanStatus: LibraryLocalScanStatus.complete,
        dirty: true,
      ).present(snapshot).statusLabel,
      '已扫描 60 项',
    );
  });

  test(
    'pagination stalls expose a fixed local status without exact totals',
    () {
      const statistics = LibraryResultStatistics(
        state: LibraryBrowseState(localFilter: LibraryLocalMediaFilter.strm),
        loadedCount: 8,
        scannedCount: 60,
        sourceTotalCount: 200,
        scanStatus: LibraryLocalScanStatus.paginationStalled,
      );

      final result = statistics.present(snapshot);
      expect(statistics.primaryResultLabel, 'STRM 分页异常');
      expect(statistics.scanProgressLabel, '已扫描 60 / 200 项');
      expect(result.totalLabel, 'STRM 分页异常');
      expect(result.remainingLabel, isNull);
      expect(result.percentageLabel, isNull);
    },
  );

  test('regular scans use separate primary and progress labels', () {
    const statistics = LibraryResultStatistics(
      state: LibraryBrowseState(localFilter: LibraryLocalMediaFilter.regular),
      loadedCount: 76,
      scannedCount: 1200,
      sourceTotalCount: 3768,
      scanStatus: LibraryLocalScanStatus.scanning,
    );

    expect(statistics.primaryResultLabel, '普通媒体统计中');
    expect(statistics.scanProgressLabel, '已扫描 1,200 / 3,768 项');
    expect(statistics.primaryResultLabel, isNot(contains('已匹配')));
  });

  test('ordinary dirty totals stop presenting exact statistics', () {
    const statistics = LibraryResultStatistics(
      state: LibraryBrowseState(),
      loadedCount: 60,
      totalCount: 120,
      dirty: true,
    );

    expect(statistics.effectiveTotal, isNull);
    final result = statistics.present(snapshot);
    expect(result.rangeLabel, '25–48');
    expect(result.totalLabel, isNull);
    expect(result.remainingLabel, isNull);
    expect(result.percentageLabel, isNull);
    expect(result.statusLabel, '结果已变化，请刷新统计');
    expect(statistics.primaryResultLabel, '已加载 60 项，结果已变化，请刷新统计');
  });
}
