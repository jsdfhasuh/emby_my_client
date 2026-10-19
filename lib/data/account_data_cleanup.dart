import 'dart:io';

import 'package:path/path.dart' as path;

import '../core/server_scope.dart';
import '../downloads/download_path_policy.dart';
import '../downloads/download_settings.dart';
import '../downloads/download_connection.dart';
import '../models/emby_models.dart';
import '../playback/playback_settings_repository.dart';
import '../playback/subtitle_preferences_repository.dart';
import '../search/search_history_store.dart';
import '../settings/library_category_settings.dart';
import '../settings/library_sort_preferences.dart';
import 'local_database.dart';
import '../images/emby_image_cache.dart';

class AccountDataCleanup {
  AccountDataCleanup({
    required LocalDatabase database,
    Future<Directory> Function(ServerScope scope)? directoryResolver,
    DownloadSettingsStore? downloadSettingsStore,
    LibraryCategorySettingsStore? libraryCategorySettingsStore,
    LibrarySortPreferenceStore? librarySortPreferenceStore,
    SearchHistoryStore? searchHistoryStore,
    PlaybackSettingsRepository? playbackSettingsRepository,
    SubtitlePreferencesRepository? subtitlePreferencesRepository,
    Future<void> Function(ServerScope)? clearImages,
    Future<void> Function(ServerScope)? clearDownloadConnection,
  }) : _database = database,
       _clearImages = clearImages ?? embyImageCacheManager.clearScope,
       _clearDownloadConnection =
           clearDownloadConnection ?? _deleteDownloadConnection,
       _directoryResolver = directoryResolver ?? defaultDownloadDirectory,
       _downloadSettingsStore =
           downloadSettingsStore ?? SharedPreferencesDownloadSettingsStore(),
       _libraryCategorySettingsStore =
           libraryCategorySettingsStore ??
           SharedPreferencesLibraryCategorySettingsStore(),
       _librarySortPreferenceStore =
           librarySortPreferenceStore ??
           SharedPreferencesLibrarySortPreferenceStore(),
       _searchHistoryStore =
           searchHistoryStore ?? SharedPreferencesSearchHistoryStore(),
       _playbackSettingsRepository =
           playbackSettingsRepository ?? PlaybackSettingsRepository(),
       _subtitlePreferencesRepository =
           subtitlePreferencesRepository ??
           SubtitlePreferencesRepository.instance;

  final LocalDatabase _database;
  final Future<void> Function(ServerScope) _clearImages;
  final Future<void> Function(ServerScope) _clearDownloadConnection;
  final Future<Directory> Function(ServerScope scope) _directoryResolver;
  final DownloadSettingsStore _downloadSettingsStore;
  final LibraryCategorySettingsStore _libraryCategorySettingsStore;
  final LibrarySortPreferenceStore _librarySortPreferenceStore;
  final SearchHistoryStore _searchHistoryStore;
  final PlaybackSettingsRepository _playbackSettingsRepository;
  final SubtitlePreferencesRepository _subtitlePreferencesRepository;

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
    }

    // Fail before deleting files if playback or a download still owns the route.
    await _clearDownloadConnection(scope);
    if (entityType != FileSystemEntityType.notFound) {
      await directory.delete(recursive: true);
    }

    await _database.deleteScopeData(scope);
    await _clearImages(scope);
    await Future.wait([
      _downloadSettingsStore.clear(scope),
      _libraryCategorySettingsStore.clear(scope),
      _librarySortPreferenceStore.clear(scope),
      _searchHistoryStore.clear(scope),
      _playbackSettingsRepository.deleteAccountSettings(session),
      _subtitlePreferencesRepository.deleteAccountPreferences(session),
    ]);
  }
}

Future<void> _deleteDownloadConnection(ServerScope scope) async {
  final manager = DownloadConnectionManager.instance;
  if (manager.supported) await manager.delete(scope);
}
