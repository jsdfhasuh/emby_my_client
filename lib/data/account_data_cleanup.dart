import 'dart:io';

import 'package:path/path.dart' as path;

import '../core/server_scope.dart';
import '../downloads/download_path_policy.dart';
import '../downloads/download_settings.dart';
import '../models/emby_models.dart';
import '../playback/playback_settings.dart';
import '../search/search_history_store.dart';
import '../settings/library_category_settings.dart';
import 'local_database.dart';

class AccountDataCleanup {
  AccountDataCleanup({
    required LocalDatabase database,
    Future<Directory> Function(ServerScope scope)? directoryResolver,
    DownloadSettingsStore? downloadSettingsStore,
    LibraryCategorySettingsStore? libraryCategorySettingsStore,
    SearchHistoryStore? searchHistoryStore,
    PlaybackSettingsStore? playbackSettingsStore,
  }) : _database = database,
       _directoryResolver = directoryResolver ?? defaultDownloadDirectory,
       _downloadSettingsStore =
           downloadSettingsStore ?? SharedPreferencesDownloadSettingsStore(),
       _libraryCategorySettingsStore =
           libraryCategorySettingsStore ??
           SharedPreferencesLibraryCategorySettingsStore(),
       _searchHistoryStore =
           searchHistoryStore ?? SharedPreferencesSearchHistoryStore(),
       _playbackSettingsStore =
           playbackSettingsStore ?? PlaybackSettingsStore();

  final LocalDatabase _database;
  final Future<Directory> Function(ServerScope scope) _directoryResolver;
  final DownloadSettingsStore _downloadSettingsStore;
  final LibraryCategorySettingsStore _libraryCategorySettingsStore;
  final SearchHistoryStore _searchHistoryStore;
  final PlaybackSettingsStore _playbackSettingsStore;

  Future<void> delete({
    required ServerScope scope,
    required EmbySession session,
  }) async {
    if (ServerScope.fromSession(session) != scope) {
      throw ArgumentError('Session and account scope do not match');
    }

    final directory = await _directoryResolver(scope);
    final resolvedPath = path.normalize(directory.absolute.path);
    if (path.basename(resolvedPath) != scope.databaseKey) {
      throw StateError('Refusing to delete an unexpected account directory');
    }
    final entityType = await FileSystemEntity.type(
      resolvedPath,
      followLinks: false,
    );
    if (entityType != FileSystemEntityType.notFound) {
      if (entityType != FileSystemEntityType.directory) {
        throw StateError('Refusing to delete an invalid account directory');
      }
      final parentPolicy = DownloadPathPolicy(directory.parent);
      if (!parentPolicy.contains(resolvedPath) ||
          !await parentPolicy.resolvesWithinRoot(directory)) {
        throw StateError('Refusing to delete an unsafe account directory');
      }
      await directory.delete(recursive: true);
    }

    await _database.deleteScopeData(scope);
    await Future.wait([
      _downloadSettingsStore.clear(scope),
      _libraryCategorySettingsStore.clear(scope),
      _searchHistoryStore.clear(scope),
      _playbackSettingsStore.clear(session),
    ]);
  }
}
