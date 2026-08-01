import 'dart:async';

import '../core/diagnostic_log.dart';
import '../core/server_scope.dart';
import '../data/emby_api.dart';
import '../downloads/download_models.dart';
import '../downloads/download_repository.dart';
import '../models/emby_models.dart';

class OfflineProgressSyncResult {
  const OfflineProgressSyncResult({
    required this.synced,
    required this.failed,
    required this.superseded,
  });

  final int synced;
  final int failed;
  final int superseded;
}

class OfflineProgressSync {
  OfflineProgressSync({
    required this.api,
    required this.scope,
    required DownloadStore store,
    this.retryDelay = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _store = store,
       _now = now ?? DateTime.now;

  final EmbyApi api;
  final ServerScope scope;
  final DownloadStore _store;
  final Duration retryDelay;
  final DateTime Function() _now;
  Future<OfflineProgressSyncResult>? _operation;

  Future<OfflineProgressSyncResult> sync({bool includeDeferred = false}) {
    final active = _operation;
    if (active != null) return active;
    final operation = _sync(includeDeferred: includeDeferred);
    _operation = operation;
    return operation.whenComplete(() {
      if (identical(_operation, operation)) _operation = null;
    });
  }

  Future<OfflineProgressSyncResult> _sync({
    required bool includeDeferred,
  }) async {
    final startedAt = _now().toUtc();
    final pending = await _store.listPendingProgress(
      scope,
      now: startedAt,
      includeDeferred: includeDeferred,
    );
    if (pending.isEmpty) {
      return const OfflineProgressSyncResult(
        synced: 0,
        failed: 0,
        superseded: 0,
      );
    }
    final offlineItems = {
      for (final item in await _store.listOfflineItems(scope))
        item.itemId: item,
    };
    late final Map<String, EmbyUserData> serverUserData;
    try {
      serverUserData = await api.getUserDataForItems(
        pending.map((record) => record.itemId),
      );
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'offline-sync',
        'Failed to read server progress for ${pending.length} item(s)',
        error: error,
        stackTrace: stackTrace,
      );
      var failed = 0;
      var superseded = 0;
      for (final record in pending) {
        if (await _markFailedIfUnchanged(record, startedAt)) {
          failed++;
        } else {
          superseded++;
        }
      }
      return OfflineProgressSyncResult(
        synced: 0,
        failed: failed,
        superseded: superseded,
      );
    }

    var synced = 0;
    var failed = 0;
    var superseded = 0;
    for (final record in pending) {
      final media = offlineItems[record.itemId];
      if (media == null) {
        if (await _saveIfUnchanged(
          record,
          record.copyWith(syncStatus: 'synced', clearRetryAfter: true),
        )) {
          synced++;
        } else {
          superseded++;
        }
        continue;
      }
      final syncing = record.copyWith(
        syncStatus: 'syncing',
        clearRetryAfter: true,
      );
      if (!await _saveIfUnchanged(record, syncing)) {
        superseded++;
        continue;
      }
      try {
        final server = serverUserData[record.itemId];
        if (server?.isPlayed == true) {
          final adopted = record.copyWith(
            positionTicks: 0,
            played: true,
            syncStatus: 'synced',
            clearRetryAfter: true,
          );
          if (await _saveIfUnchanged(syncing, adopted)) {
            synced++;
          } else {
            superseded++;
          }
          continue;
        }
        final serverPosition = server?.playbackPositionTicks ?? 0;
        if (!record.played && serverPosition > record.positionTicks) {
          final adopted = record.copyWith(
            positionTicks: serverPosition,
            played: false,
            syncStatus: 'synced',
            clearRetryAfter: true,
          );
          if (await _saveIfUnchanged(syncing, adopted)) {
            synced++;
          } else {
            superseded++;
          }
          continue;
        }
        if (record.played) {
          await api.userData.setPlayed(record.itemId, played: true);
        } else if (record.positionTicks > 0) {
          await api.reportOfflineProgress(
            itemId: record.itemId,
            mediaSourceId: media.mediaSourceId,
            positionTicks: record.positionTicks,
          );
        }
        if (await _saveIfUnchanged(
          syncing,
          record.copyWith(syncStatus: 'synced', clearRetryAfter: true),
        )) {
          synced++;
        } else {
          superseded++;
        }
      } catch (error, stackTrace) {
        DiagnosticLog.instance.error(
          'offline-sync',
          'Failed to sync offline progress item=${record.itemId}',
          error: error,
          stackTrace: stackTrace,
        );
        if (await _markFailedIfUnchanged(syncing, startedAt)) {
          failed++;
        } else {
          superseded++;
        }
      }
    }
    return OfflineProgressSyncResult(
      synced: synced,
      failed: failed,
      superseded: superseded,
    );
  }

  Future<bool> _markFailedIfUnchanged(
    OfflineProgressRecord original,
    DateTime now,
  ) {
    return _saveIfUnchanged(
      original,
      original.copyWith(syncStatus: 'failed', retryAfter: now.add(retryDelay)),
    );
  }

  Future<bool> _saveIfUnchanged(
    OfflineProgressRecord expected,
    OfflineProgressRecord replacement,
  ) => _store.saveProgressIfUnchanged(expected, replacement);
}
