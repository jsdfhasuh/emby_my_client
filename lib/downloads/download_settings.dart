import 'package:shared_preferences/shared_preferences.dart';

import '../core/server_scope.dart';

class DownloadSettings {
  const DownloadSettings({this.wifiOnly = true});

  final bool wifiOnly;

  DownloadSettings copyWith({bool? wifiOnly}) =>
      DownloadSettings(wifiOnly: wifiOnly ?? this.wifiOnly);
}

abstract interface class DownloadSettingsStore {
  Future<DownloadSettings> load(ServerScope scope);

  Future<void> save(ServerScope scope, DownloadSettings settings);
}

class SharedPreferencesDownloadSettingsStore implements DownloadSettingsStore {
  SharedPreferencesDownloadSettingsStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<DownloadSettings> load(ServerScope scope) async {
    return DownloadSettings(
      wifiOnly: await _preferences.getBool(_wifiOnlyKey(scope)) ?? true,
    );
  }

  @override
  Future<void> save(ServerScope scope, DownloadSettings settings) =>
      _preferences.setBool(_wifiOnlyKey(scope), settings.wifiOnly);

  String _wifiOnlyKey(ServerScope scope) =>
      'downloads.${scope.databaseKey}.wifiOnly';
}

class MemoryDownloadSettingsStore implements DownloadSettingsStore {
  final Map<ServerScope, DownloadSettings> _settings = {};

  @override
  Future<DownloadSettings> load(ServerScope scope) async =>
      _settings[scope] ?? const DownloadSettings();

  @override
  Future<void> save(ServerScope scope, DownloadSettings settings) async {
    _settings[scope] = settings;
  }
}
