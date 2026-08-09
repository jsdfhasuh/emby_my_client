// ignore_for_file: depend_on_referenced_packages

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class SharedPreferencesAsyncTestBackend {
  SharedPreferencesAsyncTestBackend._(this._previous, this.preferences);

  factory SharedPreferencesAsyncTestBackend.install({
    Map<String, Object> initialValues = const {},
  }) {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(initialValues);
    return SharedPreferencesAsyncTestBackend._(
      previous,
      SharedPreferencesAsync(),
    );
  }

  final SharedPreferencesAsyncPlatform? _previous;
  final SharedPreferencesAsync preferences;

  void restore() {
    SharedPreferencesAsyncPlatform.instance = _previous;
  }
}
