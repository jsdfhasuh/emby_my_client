import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'library_browse_state.dart';
import 'library_scroll_position_controller.dart';

enum LibraryLocalScanStatus { inactive, scanning, interrupted, complete }

@immutable
class LibraryResultStatistics {
  const LibraryResultStatistics({
    required this.state,
    required this.loadedCount,
    this.totalCount,
    this.scannedCount = 0,
    this.scanStatus = LibraryLocalScanStatus.inactive,
  }) : assert(loadedCount >= 0),
       assert(totalCount == null || totalCount >= 0),
       assert(scannedCount >= 0);

  final LibraryBrowseState state;
  final int loadedCount;
  final int? totalCount;
  final int scannedCount;
  final LibraryLocalScanStatus scanStatus;

  bool get isLocalScan => state.localFilter != LibraryLocalMediaFilter.all;

  bool get isLocalScanComplete =>
      isLocalScan && scanStatus == LibraryLocalScanStatus.complete;

  int? get effectiveTotal {
    if (isLocalScan && !isLocalScanComplete) return null;
    if (isLocalScanComplete) return loadedCount;
    final total = totalCount;
    return total == null ? null : math.max(total, loadedCount);
  }

  LibraryPositionPresentation present(LibraryPositionSnapshot snapshot) {
    if (isLocalScan && !isLocalScanComplete) {
      final sourceTotal = totalCount;
      return LibraryPositionPresentation(
        rangeLabel: '已匹配 $loadedCount 项',
        totalLabel: sourceTotal == null
            ? '已扫描 $scannedCount 项'
            : '已扫描 $scannedCount/$sourceTotal 项',
        statusLabel: scanStatus == LibraryLocalScanStatus.interrupted
            ? '统计中断，可重试'
            : '继续统计中',
      );
    }

    final total = effectiveTotal;
    final first = snapshot.firstVisible;
    final last = snapshot.lastVisible;
    final prefix = _rangePrefix(state);
    final remaining = total == null ? null : math.max(0, total - last);
    final percentage = total == null || total <= 0
        ? null
        : ((first + last) / 2 / total * 100).round().clamp(0, 100);
    final showFilteredRemaining = _showsFilteredRemaining(state);

    return LibraryPositionPresentation(
      rangeLabel: prefix.isEmpty
          ? '$first\u2013$last'
          : '$prefix $first\u2013$last',
      totalLabel: total == null ? null : _totalLabel(state, total),
      remainingLabel: remaining == null
          ? null
          : state.playedFilter == LibraryPlayedFilter.unplayed &&
                state.scope != LibraryBrowseScope.directory
          ? '还剩 ${_formatCount(remaining)} 项'
          : showFilteredRemaining
          ? '筛选结果还剩 ${_formatCount(remaining)} 项'
          : null,
      percentageLabel: _showsPercentage(state) && percentage != null
          ? '$percentage%'
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryResultStatistics &&
          state == other.state &&
          loadedCount == other.loadedCount &&
          totalCount == other.totalCount &&
          scannedCount == other.scannedCount &&
          scanStatus == other.scanStatus;

  @override
  int get hashCode =>
      Object.hash(state, loadedCount, totalCount, scannedCount, scanStatus);
}

@immutable
class LibraryPositionPresentation {
  const LibraryPositionPresentation({
    required this.rangeLabel,
    this.totalLabel,
    this.remainingLabel,
    this.percentageLabel,
    this.statusLabel,
  });

  final String rangeLabel;
  final String? totalLabel;
  final String? remainingLabel;
  final String? percentageLabel;
  final String? statusLabel;
}

String _rangePrefix(LibraryBrowseState state) {
  if (state.scope == LibraryBrowseScope.favorites) {
    return switch (state.mediaType) {
      LibraryMediaType.all => '收藏',
      LibraryMediaType.movie => '收藏电影',
      LibraryMediaType.series => '收藏剧集',
      LibraryMediaType.video => '收藏视频',
    };
  }
  if (state.playedFilter == LibraryPlayedFilter.unplayed) return '未播放';
  if (state.playedFilter == LibraryPlayedFilter.played) return '已播放';
  if (state.localFilter == LibraryLocalMediaFilter.strm) return 'STRM';
  if (state.localFilter == LibraryLocalMediaFilter.regular) return '普通媒体';
  return switch (state.mediaType) {
    LibraryMediaType.all => '',
    LibraryMediaType.movie => '电影',
    LibraryMediaType.series => '剧集',
    LibraryMediaType.video => '视频',
  };
}

String _totalLabel(LibraryBrowseState state, int total) =>
    switch (state.scope) {
      LibraryBrowseScope.directory => '目录共 ${_formatCount(total)} 项',
      LibraryBrowseScope.genres => '分类共 ${_formatCount(total)} 项',
      LibraryBrowseScope.tags => '标签共 ${_formatCount(total)} 项',
      LibraryBrowseScope.media ||
      LibraryBrowseScope.favorites ||
      LibraryBrowseScope.facet => '共 ${_formatCount(total)} 项',
    };

bool _showsFilteredRemaining(LibraryBrowseState state) =>
    state.scope == LibraryBrowseScope.favorites ||
    state.playedFilter == LibraryPlayedFilter.played ||
    state.mediaType != LibraryMediaType.all ||
    state.localFilter != LibraryLocalMediaFilter.all;

bool _showsPercentage(LibraryBrowseState state) => switch (state.scope) {
  LibraryBrowseScope.directory ||
  LibraryBrowseScope.genres ||
  LibraryBrowseScope.tags => true,
  LibraryBrowseScope.media ||
  LibraryBrowseScope.favorites ||
  LibraryBrowseScope.facet => state.playedFilter != LibraryPlayedFilter.played,
};

String _formatCount(int value) {
  final digits = value.toString();
  final output = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) output.write(',');
    output.write(digits[index]);
  }
  return output.toString();
}
