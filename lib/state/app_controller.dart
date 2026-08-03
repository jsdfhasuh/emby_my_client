import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/diagnostic_log.dart';
import '../core/server_capabilities.dart';
import '../core/server_scope.dart';
import '../data/account_data_cleanup.dart';
import '../data/client_registry.dart';
import '../data/emby_api.dart';
import '../data/local_database.dart';
import '../data/server_capabilities_repository.dart';
import '../data/session_store.dart';
import '../downloads/download_repository.dart';
import '../downloads/download_service.dart';
import '../downloads/download_assets.dart';
import '../downloads/download_preflight.dart';
import '../downloads/download_settings.dart';
import '../downloads/foreground_download_executor.dart';
import '../models/emby_models.dart';
import '../offline/offline_progress_sync.dart';
import '../platform/platform_capabilities.dart';
import '../settings/library_category_settings.dart';

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({
    SessionStore? store,
    LocalDatabase? database,
    ClientRegistry<EmbyApi>? clients,
    LibraryCategorySettingsStore? libraryCategorySettingsStore,
    AccountDataCleanup? accountDataCleanup,
    PlatformCapabilities? capabilities,
  }) : _store = store ?? SessionStore(capabilities: capabilities),
       _database = database ?? LocalDatabase(),
       _libraryCategorySettingsStore = libraryCategorySettingsStore,
       _accountDataCleanup = accountDataCleanup,
       _capabilities = capabilities ?? PlatformCapabilities.current(),
       _clients =
           clients ??
           ClientRegistry<EmbyApi>(disposeClient: (api) => api.dispose()) {
    _capabilitiesRepository = ServerCapabilitiesRepository(_database);
    _downloadRepository = DownloadRepository(_database);
  }

  final SessionStore _store;
  final PlatformCapabilities _capabilities;
  final LocalDatabase _database;
  final ClientRegistry<EmbyApi> _clients;
  LibraryCategorySettingsStore? _libraryCategorySettingsStore;
  AccountDataCleanup? _accountDataCleanup;
  late final ServerCapabilitiesRepository _capabilitiesRepository;
  late final DownloadRepository _downloadRepository;
  EmbySession? _session;
  ServerScope? _scope;
  ServerCapabilities? _serverCapabilities;
  DownloadService? _downloads;
  OfflineProgressSync? _offlineProgressSync;
  LibraryCategorySettings _libraryCategorySettings =
      const LibraryCategorySettings();
  Future<void>? _offlineSyncOperation;
  bool _offlineSyncIncludesDeferred = false;
  bool _offlineDeferredSyncRequested = false;
  bool _isInitializing = true;
  bool _observingLifecycle = false;
  bool _localDatabaseAvailable = false;
  bool _disposed = false;
  Future<void>? _initialization;
  Future<void>? _accountDataDeletion;

  EmbySession? get session => _session;
  ServerScope? get scope => _scope;
  ServerCapabilities? get serverCapabilities => _serverCapabilities;
  DownloadService? get downloads => _downloads;
  LibraryCategorySettings get libraryCategorySettings =>
      _libraryCategorySettings;
  bool get isInitializing => _isInitializing;
  bool get isSignedIn => _session != null;
  bool get localDatabaseAvailable => _localDatabaseAvailable;
  EmbyApi get api => _clients.requireClient(_scope!);

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      await _openLocalDatabase();
      final session = await _store.loadSession();
      if (session != null) {
        await _activateSession(session);
      }
      if (!_observingLifecycle) {
        WidgetsBinding.instance.addObserver(this);
        _observingLifecycle = true;
      }
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'startup',
        'Failed to restore the Emby session',
        error: error,
        stackTrace: stackTrace,
      );
      _session = null;
      _scope = null;
      _serverCapabilities = null;
      _libraryCategorySettings = const LibraryCategorySettings();
    } finally {
      _isInitializing = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> signIn({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final deviceId = await _store.getOrCreateDeviceId();
    final session = await EmbyApi.authenticate(
      serverUrl: serverUrl,
      username: username.trim(),
      password: password,
      deviceId: deviceId,
    );
    final scope = ServerScope.fromSession(session);
    final libraryCategorySettings = await _restoreLibraryCategorySettings(
      scope,
    );
    await _store.saveSession(session);
    final api = _createApi(session, scope);
    final previousScope = _scope;
    await _shutdownDownloads(stopExecutor: true);
    if (previousScope != null) {
      await _clients.unregister(previousScope);
    }
    _session = session;
    _scope = scope;
    _serverCapabilities = await _restoreCapabilities(session);
    _libraryCategorySettings = libraryCategorySettings;
    _clients.register(scope, api);
    await _activateDownloads(api, scope);
    unawaited(api.realtime.start());
    if (!_disposed) notifyListeners();
  }

  Future<void> signOut() async {
    final current = _session;
    final currentScope = _scope;
    final currentApi = currentScope == null
        ? null
        : _clients.clientFor(currentScope);
    await _shutdownDownloads(stopExecutor: true);
    if (current != null) {
      try {
        await currentApi?.logout();
      } catch (_) {
        // Local sign-out must still succeed when the server is unavailable.
      }
    }
    if (currentScope != null) await _clients.unregister(currentScope);
    await _store.clearSession();
    _session = null;
    _scope = null;
    _serverCapabilities = null;
    _libraryCategorySettings = const LibraryCategorySettings();
    if (!_disposed) notifyListeners();
  }

  Future<void> deleteCurrentAccountData() {
    final active = _accountDataDeletion;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _deleteCurrentAccountData().whenComplete(() {
      if (identical(_accountDataDeletion, operation)) {
        _accountDataDeletion = null;
      }
    });
    _accountDataDeletion = operation;
    return operation;
  }

  Future<void> _deleteCurrentAccountData() async {
    final currentSession = _session;
    final currentScope = _scope;
    if (currentSession == null || currentScope == null) {
      throw StateError('当前没有已登录的 Emby 会话');
    }
    final currentApi = _clients.clientFor(currentScope);
    await _shutdownDownloads(stopExecutor: true, requireExecutorStopped: true);
    try {
      await _accountDataCleaner.delete(
        scope: currentScope,
        session: currentSession,
      );
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'storage',
        'Failed to delete scoped account data scope=${currentScope.logLabel}',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_disposed && _scope == currentScope && currentApi != null) {
        try {
          await _activateDownloads(currentApi, currentScope);
        } catch (restoreError, restoreStackTrace) {
          DiagnosticLog.instance.error(
            'download',
            'Failed to restore downloads after account cleanup failure',
            error: restoreError,
            stackTrace: restoreStackTrace,
          );
        }
      }
      rethrow;
    }

    try {
      await currentApi?.logout();
    } catch (_) {
      // Local account data has already been deleted; remote logout is best effort.
    }
    await _clients.unregister(currentScope);
    if (_scope != currentScope) return;
    await _store.clearSession();
    _session = null;
    _scope = null;
    _serverCapabilities = null;
    _libraryCategorySettings = const LibraryCategorySettings();
    if (!_disposed) notifyListeners();
  }

  Future<void> _expireSession(ServerScope scope, EmbyApi source) async {
    if (_scope != scope || !identical(_clients.clientFor(scope), source)) {
      return;
    }
    _session = null;
    _scope = null;
    _serverCapabilities = null;
    _libraryCategorySettings = const LibraryCategorySettings();
    await _shutdownDownloads(stopExecutor: true);
    await _clients.unregister(scope);
    await _store.clearSession();
    if (!_disposed) notifyListeners();
  }

  Future<void> _activateSession(EmbySession session) async {
    final scope = ServerScope.fromSession(session);
    final api = _createApi(session, scope);
    _session = session;
    _scope = scope;
    _serverCapabilities = await _restoreCapabilities(session);
    _libraryCategorySettings = await _restoreLibraryCategorySettings(scope);
    _clients.register(scope, api);
    await _activateDownloads(api, scope);
    unawaited(api.realtime.start());
  }

  Future<void> updateLibraryCategorySettings(
    LibraryCategorySettings settings,
  ) async {
    final scope = _scope;
    if (scope == null) throw StateError('当前没有已登录的 Emby 会话');
    await _categorySettingsStore.save(scope, settings);
    if (_disposed || _scope != scope) return;
    _libraryCategorySettings = settings;
    notifyListeners();
  }

  Future<LibraryCategorySettings> _restoreLibraryCategorySettings(
    ServerScope scope,
  ) async {
    try {
      return await _categorySettingsStore.load(scope);
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'storage',
        'Failed to restore library category settings',
        error: error,
        stackTrace: stackTrace,
      );
      return const LibraryCategorySettings();
    }
  }

  LibraryCategorySettingsStore get _categorySettingsStore =>
      _libraryCategorySettingsStore ??=
          SharedPreferencesLibraryCategorySettingsStore();

  AccountDataCleanup get _accountDataCleaner =>
      _accountDataCleanup ??= AccountDataCleanup(
        database: _database,
        libraryCategorySettingsStore: _categorySettingsStore,
      );

  EmbyApi _createApi(EmbySession session, ServerScope scope) {
    late final EmbyApi api;
    api = EmbyApi(
      session,
      onSessionExpired: () => _expireSession(scope, api),
      onRemoteCapabilitiesReported: () => _confirmRemoteControl(scope, api),
      onRealtimeConnected: () async {
        if (_disposed ||
            _scope != scope ||
            !identical(_clients.clientFor(scope), api)) {
          return;
        }
        await _syncOfflineProgress(includeDeferred: true);
      },
    );
    return api;
  }

  Future<ServerCapabilities> _restoreCapabilities(EmbySession session) async {
    final baseline = ServerCapabilities.fromSession(session);
    if (!_localDatabaseAvailable) return baseline;
    try {
      final restored = await _capabilitiesRepository.load(baseline.scope);
      final result =
          restored?.withServerMetadata(
            productName: session.productName,
            serverVersion: session.serverVersion,
          ) ??
          baseline;
      await _capabilitiesRepository.save(result);
      return result;
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'storage',
        'Failed to restore server capability metadata',
        error: error,
        stackTrace: stackTrace,
      );
      return baseline;
    }
  }

  Future<void> _confirmRemoteControl(ServerScope scope, EmbyApi source) async {
    if (_disposed ||
        _scope != scope ||
        !identical(_clients.clientFor(scope), source)) {
      return;
    }
    final current = _serverCapabilities;
    if (current == null || current.scope != scope) return;
    final updated = current.observe(
      ServerFeature.remoteControl,
      CapabilitySupport.supported,
      source: 'sessions-capabilities-full',
    );
    _serverCapabilities = updated;
    if (!_disposed && _localDatabaseAvailable) {
      try {
        await _capabilitiesRepository.save(updated);
      } catch (error, stackTrace) {
        DiagnosticLog.instance.error(
          'storage',
          'Failed to persist server capability evidence',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (!_disposed && _scope == scope) notifyListeners();
  }

  Future<void> _openLocalDatabase() async {
    try {
      await _database.open();
      _localDatabaseAvailable = true;
    } catch (error, stackTrace) {
      _localDatabaseAvailable = false;
      DiagnosticLog.instance.error(
        'storage',
        'Local database is unavailable; online mode remains available',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _activateDownloads(EmbyApi api, ServerScope scope) async {
    if (!_localDatabaseAvailable) return;
    final service = DownloadService(
      api: api,
      scope: scope,
      repository: _downloadRepository,
      assetService: EmbyDownloadAssetService(api),
      preflight: PlatformDownloadPreflight(),
      settingsStore: SharedPreferencesDownloadSettingsStore(),
      executor: _capabilities.supportsAndroidForegroundDownloadExecutor
          ? ForegroundDownloadExecutor(capabilities: _capabilities)
          : null,
    );
    try {
      await service.initialize();
      _downloads = service;
      _offlineProgressSync = OfflineProgressSync(
        api: api,
        scope: scope,
        store: _downloadRepository,
      );
      unawaited(_syncOfflineProgress());
    } catch (error, stackTrace) {
      service.dispose();
      DiagnosticLog.instance.error(
        'download',
        'Failed to initialize offline downloads',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _shutdownDownloads({
    bool stopExecutor = false,
    bool requireExecutorStopped = false,
  }) async {
    final service = _downloads;
    if (service != null && stopExecutor) {
      final stopped = await service.stopExecutor();
      if (requireExecutorStopped && !stopped) {
        throw StateError('Android 下载服务仍在运行，请稍后重试');
      }
    } else if (service == null &&
        stopExecutor &&
        _capabilities.supportsAndroidForegroundDownloadExecutor) {
      final executor = ForegroundDownloadExecutor(capabilities: _capabilities);
      try {
        await executor.stop();
        if (requireExecutorStopped && await executor.isRunning) {
          throw StateError('Android 下载服务仍在运行，请稍后重试');
        }
      } finally {
        await executor.dispose();
      }
    }
    _downloads = null;
    _offlineProgressSync = null;
    final syncOperation = _offlineSyncOperation;
    if (syncOperation != null) await syncOperation;
    if (service == null) return;
    await service.shutdown();
    service.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final scope = _scope;
    final realtime = scope == null ? null : _clients.clientFor(scope)?.realtime;
    switch (state) {
      case AppLifecycleState.resumed:
        if (realtime != null) unawaited(realtime.setForeground(true));
        if (_downloads != null) unawaited(_downloads!.refresh());
        unawaited(_syncOfflineProgress());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (realtime != null) unawaited(realtime.setForeground(false));
    }
  }

  Future<void> _syncOfflineProgress({bool includeDeferred = false}) {
    if (includeDeferred && !_offlineSyncIncludesDeferred) {
      _offlineDeferredSyncRequested = true;
    }
    final active = _offlineSyncOperation;
    if (active != null) return active;
    final shouldIncludeDeferred = _offlineDeferredSyncRequested;
    _offlineDeferredSyncRequested = false;
    _offlineSyncIncludesDeferred = shouldIncludeDeferred;
    final operation = _runOfflineProgressSync(
      includeDeferred: shouldIncludeDeferred,
    );
    _offlineSyncOperation = operation;
    return operation.whenComplete(() {
      if (identical(_offlineSyncOperation, operation)) {
        _offlineSyncOperation = null;
        _offlineSyncIncludesDeferred = false;
        if (_offlineDeferredSyncRequested && !_disposed) {
          unawaited(_syncOfflineProgress());
        }
      }
    });
  }

  Future<void> _runOfflineProgressSync({required bool includeDeferred}) async {
    final sync = _offlineProgressSync;
    if (sync == null || _disposed) return;
    try {
      final result = await sync.sync(includeDeferred: includeDeferred);
      if (result.synced > 0) {
        DiagnosticLog.instance.info(
          'offline-sync',
          'Synced ${result.synced} offline progress record(s)',
        );
      }
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'offline-sync',
        'Offline progress synchronization failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _localDatabaseAvailable = false;
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observingLifecycle = false;
    }
    unawaited(_disposeResources());
    super.dispose();
  }

  Future<void> _disposeResources() async {
    await _shutdownDownloads();
    await _clients.dispose();
    await _database.close();
  }
}
