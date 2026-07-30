import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../core/diagnostic_log.dart';
import '../core/server_capabilities.dart';
import '../core/server_scope.dart';
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

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({
    SessionStore? store,
    LocalDatabase? database,
    ClientRegistry<EmbyApi>? clients,
  }) : _store = store ?? SessionStore(),
       _database = database ?? LocalDatabase(),
       _clients =
           clients ??
           ClientRegistry<EmbyApi>(disposeClient: (api) => api.dispose()) {
    _capabilitiesRepository = ServerCapabilitiesRepository(_database);
    _downloadRepository = DownloadRepository(_database);
  }

  final SessionStore _store;
  final LocalDatabase _database;
  final ClientRegistry<EmbyApi> _clients;
  late final ServerCapabilitiesRepository _capabilitiesRepository;
  late final DownloadRepository _downloadRepository;
  EmbySession? _session;
  ServerScope? _scope;
  ServerCapabilities? _serverCapabilities;
  DownloadService? _downloads;
  OfflineProgressSync? _offlineProgressSync;
  Future<void>? _offlineSyncOperation;
  bool _isInitializing = true;
  bool _observingLifecycle = false;
  bool _localDatabaseAvailable = false;
  bool _disposed = false;
  Future<void>? _initialization;

  EmbySession? get session => _session;
  ServerScope? get scope => _scope;
  ServerCapabilities? get serverCapabilities => _serverCapabilities;
  DownloadService? get downloads => _downloads;
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
    if (!_disposed) notifyListeners();
  }

  Future<void> _expireSession(ServerScope scope) async {
    if (_scope != scope) return;
    _session = null;
    _scope = null;
    _serverCapabilities = null;
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
    _clients.register(scope, api);
    await _activateDownloads(api, scope);
    unawaited(api.realtime.start());
  }

  EmbyApi _createApi(EmbySession session, ServerScope scope) => EmbyApi(
    session,
    onSessionExpired: () => _expireSession(scope),
    onRemoteCapabilitiesReported: () => _confirmRemoteControl(scope),
  );

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

  Future<void> _confirmRemoteControl(ServerScope scope) async {
    if (_disposed || _scope != scope || !_clients.contains(scope)) return;
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
      executor: Platform.isAndroid ? ForegroundDownloadExecutor() : null,
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

  Future<void> _shutdownDownloads({bool stopExecutor = false}) async {
    final service = _downloads;
    _downloads = null;
    _offlineProgressSync = null;
    final syncOperation = _offlineSyncOperation;
    if (syncOperation != null) await syncOperation;
    if (service == null) return;
    if (stopExecutor) await service.stopExecutor();
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
        unawaited(_syncOfflineProgress());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (realtime != null) unawaited(realtime.setForeground(false));
    }
  }

  Future<void> _syncOfflineProgress() {
    final active = _offlineSyncOperation;
    if (active != null) return active;
    final operation = _runOfflineProgressSync();
    _offlineSyncOperation = operation;
    return operation.whenComplete(() {
      if (identical(_offlineSyncOperation, operation)) {
        _offlineSyncOperation = null;
      }
    });
  }

  Future<void> _runOfflineProgressSync() async {
    final sync = _offlineProgressSync;
    if (sync == null || _disposed) return;
    try {
      final result = await sync.sync();
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
