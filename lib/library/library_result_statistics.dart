import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'library_browse_state.dart';
import 'library_scroll_position_controller.dart';

enum LibraryLocalScanStatus {
  inactive,
  scanning,
  interrupted,
  paginationStalled,
  complete,
}

@immutable
class LibraryResultStatistics {
  const LibraryResultStatistics({
    required this.state,
    required this.loadedCount,
    this.totalCount,
    this.scannedCount = 0,
    this.sourceTotalCount,
    this.scanStatus = LibraryLocalScanStatus.inactive,
    this.dirty = false,
    this.unknownClassificationCount = 0,
  }) : assert(loadedCount >= 0),
       assert(totalCount == null || totalCount >= 0),
       assert(scannedCount >= 0),
       assert(sourceTotalCount == null || sourceTotalCount >= 0),
       assert(unknownClassificationCount >= 0);

  final LibraryBrowseState state;
  final int loadedCount;
  final int? totalCount;
  final int scannedCount;
  final int? sourceTotalCount;
  final LibraryLocalScanStatus scanStatus;
  final bool dirty;
  final int unknownClassificationCount;

  bool get isLocalScan => state.localFilter != LibraryLocalMediaFilter.all;

  bool get isLocalScanComplete =>
      isLocalScan && scanStatus == LibraryLocalScanStatus.complete;

  bool get hasExactLocalTotal =>
      isLocalScanComplete && !dirty && unknownClassificationCount == 0;

  int? get effectiveTotal {
    if (dirty) return null;
    if (isLocalScan && !hasExactLocalTotal) return null;
    if (hasExactLocalTotal) return loadedCount;
    final total = totalCount;
    return total == null ? null : math.max(total, loadedCount);
  }

  LibraryPositionPresentation present(LibraryPositionSnapshot snapshot) {
    if (isLocalScan && !hasExactLocalTotal) {
      return LibraryPositionPresentation(
        rangeLabel: '${snapshot.firstVisible}\u2013${snapshot.lastVisible}',
        totalLabel: primaryResultLabel,
        statusLabel: scanProgressLabel,
      );
    }

    if (dirty) {
      return LibraryPositionPresentation(
        rangeLabel: _rangeLabel(state, snapshot),
        statusLabel: '结果已变化，请刷新统计',
      );
    }

    final total = effectiveTotal;
    final last = snapshot.lastVisible;
    final remaining = total == null ? null : math.max(0, total - last);
    final percentage = total == null || total <= 0
        ? null
        : (last / total * 100).round().clamp(0, 100);

    return LibraryPositionPresentation(
      rangeLabel: _rangeLabel(state, snapshot),
      totalLabel: total == null ? null : _totalLabel(state, total),
      remainingLabel: remaining == null
          ? null
          : state.playedFilter == LibraryPlayedFilter.unplayed &&
                state.scope != LibraryBrowseScope.directory
          ? '还剩 ${_formatCount(remaining)} 项'
          : _showsFilteredRemaining(state)
          ? '筛选结果还剩 ${_formatCount(remaining)} 项'
          : '还剩 ${_formatCount(remaining)} 项',
      percentageLabel: _showsPercentage(state) && percentage != null
          ? '$percentage%'
          : null,
    );
  }

  String get primaryResultLabel {
    if (isLocalScan) {
      if (hasExactLocalTotal) {
        return _localLabel(state, '共 ${_formatCount(loadedCount)} 项');
      }
      if (scanStatus == LibraryLocalScanStatus.paginationStalled) {
        return _localLabel(state, '分页异常');
      }
      if (scanStatus == LibraryLocalScanStatus.interrupted) {
        return _localLabel(state, '扫描已暂停');
      }
      if (dirty || unknownClassificationCount > 0) {
        return _localLabel(state, '统计待确认');
      }
      return _localLabel(state, '统计中');
    }
    if (dirty) {
      return '已加载 ${_formatCount(loadedCount)} 项，结果已变化，请刷新统计';
    }
    final total = effectiveTotal;
    if (total == null) {
      return loadedCount == 0 ? '正在统计' : '已加载 ${_formatCount(loadedCount)} 项';
    }
    final formattedTotal = _formatCount(total);
    if (state.mediaType == LibraryMediaType.photo &&
        state.scope != LibraryBrowseScope.favorites &&
        state.scope.supportsMediaFilters) {
      return '图片共 $formattedTotal 项';
    }
    return switch (state.scope) {
      LibraryBrowseScope.directory => '目录共 $formattedTotal 项',
      LibraryBrowseScope.genres => '分类共 $formattedTotal 项',
      LibraryBrowseScope.tags => '标签共 $formattedTotal 项',
      LibraryBrowseScope.favorites => '收藏共 $formattedTotal 项',
      LibraryBrowseScope.media || LibraryBrowseScope.facet
          when state.playedFilter == LibraryPlayedFilter.unplayed =>
        '未播放共 $formattedTotal 项',
      LibraryBrowseScope.media || LibraryBrowseScope.facet
          when state.playedFilter == LibraryPlayedFilter.played =>
        '已播放共 $formattedTotal 项',
      LibraryBrowseScope.media ||
      LibraryBrowseScope.facet => '共 $formattedTotal 项',
    };
  }

  String? get scanProgressLabel {
    if (!isLocalScan || hasExactLocalTotal) return null;
    final sourceTotal = sourceTotalCount ?? totalCount;
    return sourceTotal == null
        ? '已扫描 ${_formatCount(scannedCount)} 项'
        : '已扫描 ${_formatCount(scannedCount)} / '
              '${_formatCount(sourceTotal)} 项';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryResultStatistics &&
          state == other.state &&
          loadedCount == other.loadedCount &&
          totalCount == other.totalCount &&
          scannedCount == other.scannedCount &&
          sourceTotalCount == other.sourceTotalCount &&
          scanStatus == other.scanStatus &&
          dirty == other.dirty &&
          unknownClassificationCount == other.unknownClassificationCount;

  @override
  int get hashCode => Object.hash(
    state,
    loadedCount,
    totalCount,
    scannedCount,
    sourceTotalCount,
    scanStatus,
    dirty,
    unknownClassificationCount,
  );
}

String _rangeLabel(LibraryBrowseState state, LibraryPositionSnapshot snapshot) {
  final prefix = _rangePrefix(state);
  final range = '${snapshot.firstVisible}\u2013${snapshot.lastVisible}';
  return prefix.isEmpty ? range : '$prefix $range';
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
      LibraryMediaType.photo => '收藏图片',
    };
  }
  if (state.playedFilter == LibraryPlayedFilter.unplayed) return '未播放';
  if (state.playedFilter == LibraryPlayedFilter.played) return '已播放';
  if (state.localFilter == LibraryLocalMediaFilter.strm) return 'STRM';
  if (state.localFilter == LibraryLocalMediaFilter.regular) return '普通媒体';
  return '';
}

String _totalLabel(LibraryBrowseState state, int total) {
  if (state.localFilter != LibraryLocalMediaFilter.all) {
    return _localLabel(state, '共 ${_formatCount(total)} 项');
  }
  if (state.mediaType == LibraryMediaType.photo &&
      state.scope != LibraryBrowseScope.favorites &&
      state.scope.supportsMediaFilters) {
    return '图片共 ${_formatCount(total)} 项';
  }
  return switch (state.scope) {
    LibraryBrowseScope.directory => '目录共 ${_formatCount(total)} 项',
    LibraryBrowseScope.genres => '分类共 ${_formatCount(total)} 项',
    LibraryBrowseScope.tags => '标签共 ${_formatCount(total)} 项',
    LibraryBrowseScope.media ||
    LibraryBrowseScope.favorites ||
    LibraryBrowseScope.facet => '共 ${_formatCount(total)} 项',
  };
}

String _localContextLabel(LibraryBrowseState state) =>
    state.localFilter == LibraryLocalMediaFilter.strm ? 'STRM' : '普通媒体';

String _localLabel(LibraryBrowseState state, String suffix) {
  final context = _localContextLabel(state);
  return context == 'STRM' ? '$context $suffix' : '$context$suffix';
}

bool _showsFilteredRemaining(LibraryBrowseState state) =>
    state.scope == LibraryBrowseScope.favorites ||
    state.playedFilter == LibraryPlayedFilter.played ||
    (state.mediaType != LibraryMediaType.all &&
        state.mediaType != LibraryMediaType.photo);

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
