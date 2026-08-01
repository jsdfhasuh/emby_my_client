import 'package:shared_preferences/shared_preferences.dart';

import '../core/server_scope.dart';

class LibraryCategorySettings {
  const LibraryCategorySettings({
    this.showMovies = false,
    this.showSeries = false,
    this.showVideos = false,
    this.showFavorites = true,
    this.showFolders = true,
  });

  final bool showMovies;
  final bool showSeries;
  final bool showVideos;
  final bool showFavorites;
  final bool showFolders;

  LibraryCategorySettings copyWith({
    bool? showMovies,
    bool? showSeries,
    bool? showVideos,
    bool? showFavorites,
    bool? showFolders,
  }) => LibraryCategorySettings(
    showMovies: showMovies ?? this.showMovies,
    showSeries: showSeries ?? this.showSeries,
    showVideos: showVideos ?? this.showVideos,
    showFavorites: showFavorites ?? this.showFavorites,
    showFolders: showFolders ?? this.showFolders,
  );

  @override
  bool operator ==(Object other) =>
      other is LibraryCategorySettings &&
      other.showMovies == showMovies &&
      other.showSeries == showSeries &&
      other.showVideos == showVideos &&
      other.showFavorites == showFavorites &&
      other.showFolders == showFolders;

  @override
  int get hashCode => Object.hash(
    showMovies,
    showSeries,
    showVideos,
    showFavorites,
    showFolders,
  );
}

abstract interface class LibraryCategorySettingsStore {
  Future<LibraryCategorySettings> load(ServerScope scope);

  Future<void> save(ServerScope scope, LibraryCategorySettings settings);

  Future<void> clear(ServerScope scope);
}

class SharedPreferencesLibraryCategorySettingsStore
    implements LibraryCategorySettingsStore {
  SharedPreferencesLibraryCategorySettingsStore({
    SharedPreferencesAsync? preferences,
  }) : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<LibraryCategorySettings> load(ServerScope scope) async {
    const defaults = LibraryCategorySettings();
    return LibraryCategorySettings(
      showMovies:
          await _preferences.getBool(_key(scope, 'movies')) ??
          defaults.showMovies,
      showSeries:
          await _preferences.getBool(_key(scope, 'series')) ??
          defaults.showSeries,
      showVideos:
          await _preferences.getBool(_key(scope, 'videos')) ??
          defaults.showVideos,
      showFavorites:
          await _preferences.getBool(_key(scope, 'favorites')) ??
          defaults.showFavorites,
      showFolders:
          await _preferences.getBool(_key(scope, 'folders')) ??
          defaults.showFolders,
    );
  }

  @override
  Future<void> save(ServerScope scope, LibraryCategorySettings settings) async {
    await Future.wait([
      _preferences.setBool(_key(scope, 'movies'), settings.showMovies),
      _preferences.setBool(_key(scope, 'series'), settings.showSeries),
      _preferences.setBool(_key(scope, 'videos'), settings.showVideos),
      _preferences.setBool(_key(scope, 'favorites'), settings.showFavorites),
      _preferences.setBool(_key(scope, 'folders'), settings.showFolders),
    ]);
  }

  @override
  Future<void> clear(ServerScope scope) async {
    await Future.wait([
      _preferences.remove(_key(scope, 'movies')),
      _preferences.remove(_key(scope, 'series')),
      _preferences.remove(_key(scope, 'videos')),
      _preferences.remove(_key(scope, 'favorites')),
      _preferences.remove(_key(scope, 'folders')),
    ]);
  }

  String _key(ServerScope scope, String category) =>
      'library.${scope.databaseKey}.category.$category';
}

class MemoryLibraryCategorySettingsStore
    implements LibraryCategorySettingsStore {
  final Map<ServerScope, LibraryCategorySettings> _settings = {};

  @override
  Future<LibraryCategorySettings> load(ServerScope scope) async =>
      _settings[scope] ?? const LibraryCategorySettings();

  @override
  Future<void> save(ServerScope scope, LibraryCategorySettings settings) async {
    _settings[scope] = settings;
  }

  @override
  Future<void> clear(ServerScope scope) async {
    _settings.remove(scope);
  }
}
