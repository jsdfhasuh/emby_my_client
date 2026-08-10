import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/diagnostic_log.dart';
import '../core/server_capabilities.dart';
import '../core/server_scope.dart';
import '../core/sign_in_diagnostics.dart';
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
import '../library/library_local_media_scan_service.dart';
import '../models/emby_models.dart';
import '../offline/offline_progress_sync.dart';
import '../platform/platform_capabilities.dart';
import '../playback/playback_settings_repository.dart';
import '../settings/library_category_settings.dart';

typedef SignInAuthenticator =
    Future<EmbySession> Function({
      required String serverUrl,
      required String username,
      required String password,
      required String deviceId,
      required String deviceName,
    });

typedef SignInApiFactory =
    EmbyApi Function(EmbySession session, ServerScope scope);

typedef DownloadServiceFactory =
    DownloadService Function(EmbyApi api, ServerScope scope);

Future<EmbySession> _defaultAuthenticate({
  required String serverUrl,
  required String username,
  required String password,
  required String deviceId,
  required String deviceName,
}) => EmbyApi.authenticate(
  serverUrl: serverUrl,
  username: username,
  password: password,
  deviceId: deviceId,
  deviceName: deviceName,
);

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({
    SessionStore? store,
    LocalDatabase? database,
    ClientRegistry<EmbyApi>? clients,
    LibraryCategorySettingsStore? libraryCategorySettingsStore,
    PlaybackSettingsRepository? playbackSettingsRepository,
    AccountDataCleanup? accountDataCleanup,
    PlatformCapabilities? capabilities,
    SignInAuthenticator? authenticator,
    SignInApiFactory? apiFactory,
    DownloadServiceFactory? downloadServiceFactory,
    LibraryScanServiceFactory? libraryScanServiceFactory,
  }) : _store = store ?? SessionStore(capabilities: capabilities),
       _database = database ?? LocalDatabase(),
       _libraryCategorySettingsStore = libraryCategorySettingsStore,
       _playbackSettingsRepository =
           playbackSettingsRepository ?? PlaybackSettingsRepository(),
       _accountDataCleanup = accountDataCleanup,
       _capabilities = capabilities ?? PlatformCapabilities.current(),
       _authenticate = authenticator ?? _defaultAuthenticate,
       _apiFactory = apiFactory,
       _downloadServiceFactory = downloadServiceFactory,
       _libraryScanServiceFactory = libraryScanServiceFactory,
       _clients =
           clients ??
           ClientRegistry<EmbyApi>(disposeClient: (api) => api.dispose()) {
    _capabilitiesRepository = ServerCapabilitiesRepository(_database);
    _downloadRepository = DownloadRepository(_database);
  }

  final SessionStore _store;
  final PlatformCapabilities _capabilities;
  final SignInAuthenticator _authenticate;
  final SignInApiFactory? _apiFactory;
  final DownloadServiceFactory? _downloadServiceFactory;
  final LibraryScanServiceFactory? _libraryScanServiceFactory;
  final LocalDatabase _database;
  final PlaybackSettingsRepository _playbackSettingsRepository;
  final ClientRegistry<EmbyApi> _clients;
  LibraryCategorySettingsStore? _libraryCategorySettingsStore;
  AccountDataCleanup? _accountDataCleanup;
  late final ServerCapabilitiesRepository _capabilitiesRepository;
  late final DownloadRepository _downloadRepository;
  EmbySession? _session;
  ServerScope? _scope;
  ServerCapabilities? _serverCapabilities;
  DownloadService? _downloads;
  LibraryLocalMediaScanService? _libraryScanService;
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
  bool _signInInProgress = false;

  EmbySession? get session => _session;
  ServerScope? get scope => _scope;
  ServerCapabilities? get serverCapabilities => _serverCapabilities;
  DownloadService? get downloads => _downloads;
  LibraryLocalMediaScanService? get libraryScanService => _libraryScanService;
  LibraryCategorySettings get libraryCategorySettings =>
      _libraryCategorySettings;
  bool get isInitializing => _isInitializing;
  bool get isSignedIn => _session != null;
  bool get localDatabaseAvailable => _localDatabaseAvailable;
  PlaybackSettingsRepository get playbackSettingsRepository =>
      _playbackSettingsRepository;
  EmbyApi get api => _clients.requireClient(_scope!);

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      await _openLocalDatabase();
      _recordSafeStage(
        component: SafeDiagnosticComponent.storage,
        event: SafeDiagnosticEvent.signInStageStart,
        stage: SignInStage.sessionRead,
      );
      final session = await _store.loadSession();
      _recordSafeStage(
        component: SafeDiagnosticComponent.storage,
        event: SafeDiagnosticEvent.signInStageSuccess,
        stage: SignInStage.sessionRead,
      );
      if (session != null) {
        await _activateSession(session);
      }
      if (!_observingLifecycle) {
        WidgetsBinding.instance.addObserver(this);
        _observingLifecycle = true;
      }
    } on SecureStorageFailure catch (error) {
      _recordSafeFailure(
        component: SafeDiagnosticComponent.storage,
        event: SafeDiagnosticEvent.sessionRestoreFailure,
        stage: SignInStage.sessionRead,
        reason: safeReasonForStorage(error.reason),
        errorType: SafeDiagnosticErrorType.secureStorageFailure,
      );
      _resetSessionState();
    } catch (_) {
      _recordSafeFailure(
        component: SafeDiagnosticComponent.storage,
        event: SafeDiagnosticEvent.sessionRestoreFailure,
        stage: SignInStage.sessionRead,
        reason: SafeDiagnosticReason.unknown,
        errorType: SafeDiagnosticErrorType.unknown,
      );
      _resetSessionState();
    } finally {
      _isInitializing = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> signIn({
    required String serverUrl,
    required String username,
    required String password,
  }) {
    _recordSafeStage(
      event: SafeDiagnosticEvent.signInStageStart,
      stage: SignInStage.preflight,
    );
    if (_signInInProgress) {
      final failure = const SignInFailure(
        stage: SignInStage.preflight,
        reason: SignInFailureReason.alreadyInProgress,
      );
      _recordSignInFailure(failure);
      return Future<void>.error(failure);
    }
    if (_session != null || _scope != null || _clients.scopes.isNotEmpty) {
      final failure = const SignInFailure(
        stage: SignInStage.preflight,
        reason: SignInFailureReason.alreadySignedIn,
      );
      _recordSignInFailure(failure);
      return Future<void>.error(failure);
    }

    _recordSafeStage(
      event: SafeDiagnosticEvent.signInStageSuccess,
      stage: SignInStage.preflight,
    );
    _signInInProgress = true;
    final operation = _runSignIn(
      serverUrl: serverUrl,
      username: username,
      password: password,
    );
    return operation.whenComplete(() => _signInInProgress = false);
  }

  Future<void> _runSignIn({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final existingDeviceId = await _runSignInStage<String?>(
      stage: SignInStage.deviceIdRead,
      fallbackReason: SignInFailureReason.secureStorageUnexpected,
      action: _store.readDeviceId,
    );
    final deviceId = existingDeviceId == null || existingDeviceId.isEmpty
        ? _store.generateDeviceId()
        : existingDeviceId;
    if (existingDeviceId == null || existingDeviceId.isEmpty) {
      await _runSignInStage<void>(
        stage: SignInStage.deviceIdWrite,
        fallbackReason: SignInFailureReason.secureStorageUnexpected,
        action: () => _store.writeDeviceId(deviceId),
      );
    }

    final session = await _runSignInStage<EmbySession>(
      stage: SignInStage.authenticate,
      fallbackReason: SignInFailureReason.unknown,
      action: () => _authenticate(
        serverUrl: serverUrl,
        username: username.trim(),
        password: password,
        deviceId: deviceId,
        deviceName: _capabilities.embyDeviceName,
      ),
    );

    final prepared =
        await _runSignInStage<
          ({
            ServerScope scope,
            LibraryCategorySettings settings,
            ServerCapabilities capabilities,
            EmbyApi api,
          })
        >(
          stage: SignInStage.sessionPrepare,
          fallbackReason: SignInFailureReason.sessionPrepareFailed,
          action: () async {
            final scope = ServerScope.fromSession(session);
            final settings = await _restoreLibraryCategorySettings(
              scope,
              safeLogging: true,
            );
            final capabilities = await _restoreCapabilities(
              session,
              safeLogging: true,
            );
            final api =
                _apiFactory?.call(session, scope) ?? _createApi(session, scope);
            try {
              _clients.register(scope, api);
            } catch (_) {
              await _disposeAttemptApi(api);
              rethrow;
            }
            return (
              scope: scope,
              settings: settings,
              capabilities: capabilities,
              api: api,
            );
          },
        );

    try {
      await _runSignInStage<void>(
        stage: SignInStage.sessionSave,
        fallbackReason: SignInFailureReason.sessionSaveFailed,
        action: () => _store.saveSession(session),
      );
    } catch (_) {
      await _rollbackSignInAttempt(prepared.scope, prepared.api);
      rethrow;
    }

    _commitSignIn(
      session: session,
      scope: prepared.scope,
      settings: prepared.settings,
      capabilities: prepared.capabilities,
      api: prepared.api,
    );
  }

  void _commitSignIn({
    required EmbySession session,
    required ServerScope scope,
    required LibraryCategorySettings settings,
    required ServerCapabilities capabilities,
    required EmbyApi api,
  }) {
    _session = session;
    _scope = scope;
    _serverCapabilities = capabilities;
    _libraryCategorySettings = settings;
    _activateLibraryScanService(api, scope);
    if (!_disposed) notifyListeners();
    unawaited(_activateDownloadsSafely(api, scope));
    unawaited(_startRealtimeSafely(api));
  }

  Future<void> _activateDownloadsSafely(EmbyApi api, ServerScope scope) async {
    try {
      await _activateDownloads(api, scope, safeLogging: true);
    } catch (_) {
      _recordSafeFailure(
        component: SafeDiagnosticComponent.auth,
        event: SafeDiagnosticEvent.signInFailure,
        stage: SignInStage.activate,
        reason: SafeDiagnosticReason.activationFailed,
        errorType: SafeDiagnosticErrorType.signInFailure,
      );
    }
  }

  Future<void> _rollbackSignInAttempt(ServerScope scope, EmbyApi api) async {
    try {
      if (_clients.contains(scope)) {
        await _clients.unregister(scope);
      } else {
        await _disposeAttemptApi(api);
      }
    } catch (_) {
      _recordSafeFailure(
        component: SafeDiagnosticComponent.auth,
        event: SafeDiagnosticEvent.signInFailure,
        stage: SignInStage.rollback,
        reason: SafeDiagnosticReason.unknown,
        errorType: SafeDiagnosticErrorType.signInFailure,
      );
    }
  }

  Future<void> _disposeAttemptApi(EmbyApi api) async {
    try {
      await api.dispose();
    } catch (_) {
      _recordSafeFailure(
        component: SafeDiagnosticComponent.auth,
        event: SafeDiagnosticEvent.signInFailure,
        stage: SignInStage.rollback,
        reason: SafeDiagnosticReason.unknown,
        errorType: SafeDiagnosticErrorType.signInFailure,
      );
    }
  }

  Future<void> _startRealtimeSafely(EmbyApi api) async {
    try {
      await api.realtime.start();
    } catch (_) {
      _recordSafeFailure(
        component: SafeDiagnosticComponent.auth,
        event: SafeDiagnosticEvent.signInFailure,
        stage: SignInStage.activate,
        reason: SafeDiagnosticReason.activationFailed,
        errorType: SafeDiagnosticErrorType.signInFailure,
      );
    }
  }

  Future<T> _runSignInStage<T>({
    required SignInStage stage,
    required SignInFailureReason fallbackReason,
    required Future<T> Function() action,
  }) async {
    _recordSafeStage(event: SafeDiagnosticEvent.signInStageStart, stage: stage);
    try {
      final result = await action();
      _recordSafeStage(
        event: SafeDiagnosticEvent.signInStageSuccess,
        stage: stage,
      );
      return result;
    } on SecureStorageFailure catch (error) {
      final failure = SignInFailure.fromSecureStorage(stage, error);
      _recordSignInFailure(failure);
      throw failure;
    } on EmbyApiException {
      _recordSafeFailure(
        component: SafeDiagnosticComponent.auth,
        event: SafeDiagnosticEvent.signInFailure,
        stage: stage,
        reason: SafeDiagnosticReason.embyApiFailure,
        errorType: SafeDiagnosticErrorType.embyApiException,
      );
      rethrow;
    } catch (_) {
      final failure = SignInFailure(stage: stage, reason: fallbackReason);
      _recordSignInFailure(failure);
      throw failure;
    }
  }

  void _recordSignInFailure(SignInFailure failure) {
    _recordSafeFailure(
      component: SafeDiagnosticComponent.auth,
      event: SafeDiagnosticEvent.signInFailure,
      stage: failure.stage,
      reason: safeReasonForSignIn(failure.reason),
      errorType: failure.errorType == 'SecureStorageFailure'
          ? SafeDiagnosticErrorType.secureStorageFailure
          : SafeDiagnosticErrorType.signInFailure,
    );
  }

  void _recordSafeFailure({
    required SafeDiagnosticComponent component,
    required SafeDiagnosticEvent event,
    required SignInStage stage,
    required SafeDiagnosticReason reason,
    required SafeDiagnosticErrorType errorType,
  }) {
    DiagnosticLog.instance.safeFailure(
      component: component,
      event: event,
      stage: stage,
      reason: reason,
      errorType: errorType,
    );
  }

  void _recordSafeStage({
    SafeDiagnosticComponent component = SafeDiagnosticComponent.auth,
    required SafeDiagnosticEvent event,
    required SignInStage stage,
  }) {
    DiagnosticLog.instance.safeStage(
      component: component,
      event: event,
      stage: stage,
      reason: SafeDiagnosticReason.unknown,
      errorType: SafeDiagnosticErrorType.unknown,
    );
  }

  void _resetSessionState() {
    _session = null;
    _scope = null;
    _serverCapabilities = null;
    _libraryCategorySettings = const LibraryCategorySettings();
  }

  Future<void> signOut() async {
    final current = _session;
    final currentScope = _scope;
    final currentApi = currentScope == null
        ? null
        : _clients.clientFor(currentScope);
    await _shutdownLibraryScanService();
    await _shutdownDownloads(stopExecutor: true);
    if (current != null) {
      await _playbackSettingsRepository.deactivate(current);
    }
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
    await _shutdownLibraryScanService();
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
        _activateLibraryScanService(currentApi, currentScope);
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
    await _shutdownLibraryScanService();
    final expiredSession = _session;
    if (expiredSession != null) {
      await _playbackSettingsRepository.deactivate(expiredSession);
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
    final api = _apiFactory?.call(session, scope) ?? _createApi(session, scope);
    _session = session;
    _scope = scope;
    _serverCapabilities = await _restoreCapabilities(session);
    _libraryCategorySettings = await _restoreLibraryCategorySettings(scope);
    _clients.register(scope, api);
    _activateLibraryScanService(api, scope);
    await _activateDownloads(api, scope, safeLogging: true);
    unawaited(_startRealtimeSafely(api));
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
    ServerScope scope, {
    bool safeLogging = false,
  }) async {
    try {
      return await _categorySettingsStore.load(scope);
    } catch (error, stackTrace) {
      if (safeLogging) {
        _recordSafeFailure(
          component: SafeDiagnosticComponent.storage,
          event: SafeDiagnosticEvent.signInFailure,
          stage: SignInStage.sessionPrepare,
          reason: SafeDiagnosticReason.sessionPrepareFailed,
          errorType: SafeDiagnosticErrorType.signInFailure,
        );
      } else {
        DiagnosticLog.instance.error(
          'storage',
          'Failed to restore library category settings',
          error: error,
          stackTrace: stackTrace,
        );
      }
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
        playbackSettingsRepository: _playbackSettingsRepository,
      );

  EmbyApi _createApi(EmbySession session, ServerScope scope) {
    late final EmbyApi api;
    api = EmbyApi(
      session,
      deviceName: _capabilities.embyDeviceName,
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

  Future<ServerCapabilities> _restoreCapabilities(
    EmbySession session, {
    bool safeLogging = false,
  }) async {
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
      if (safeLogging) {
        _recordSafeFailure(
          component: SafeDiagnosticComponent.storage,
          event: SafeDiagnosticEvent.signInFailure,
          stage: SignInStage.activate,
          reason: SafeDiagnosticReason.activationFailed,
          errorType: SafeDiagnosticErrorType.signInFailure,
        );
      } else {
        DiagnosticLog.instance.error(
          'storage',
          'Failed to restore server capability metadata',
          error: error,
          stackTrace: stackTrace,
        );
      }
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

  Future<void> _activateDownloads(
    EmbyApi api,
    ServerScope scope, {
    bool safeLogging = false,
  }) async {
    if (!_localDatabaseAvailable) return;
    DownloadService? service;
    try {
      final created =
          _downloadServiceFactory?.call(api, scope) ??
          DownloadService(
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
      service = created;
      await created.initialize();
      if (_disposed ||
          _scope != scope ||
          !identical(_clients.clientFor(scope), api)) {
        await created.shutdown();
        created.dispose();
        return;
      }
      _downloads = created;
      _offlineProgressSync = OfflineProgressSync(
        api: api,
        scope: scope,
        store: _downloadRepository,
      );
      unawaited(_syncOfflineProgress());
    } catch (error, stackTrace) {
      service?.dispose();
      if (safeLogging) {
        _recordSafeFailure(
          component: SafeDiagnosticComponent.auth,
          event: SafeDiagnosticEvent.signInFailure,
          stage: SignInStage.activate,
          reason: SafeDiagnosticReason.activationFailed,
          errorType: SafeDiagnosticErrorType.signInFailure,
        );
      } else {
        DiagnosticLog.instance.error(
          'download',
          'Failed to initialize offline downloads',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  void _activateLibraryScanService(EmbyApi api, ServerScope scope) {
    if (_disposed || _scope != scope || _libraryScanService != null) return;
    try {
      _libraryScanService =
          _libraryScanServiceFactory?.call(api, scope) ??
          LibraryLocalMediaScanService(api: api, scope: scope);
    } catch (error, stackTrace) {
      DiagnosticLog.instance.error(
        'library-scan',
        'Failed to initialize local media scan service',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _shutdownLibraryScanService() async {
    final service = _libraryScanService;
    _libraryScanService = null;
    if (service == null) return;
    await service.cancelAll();
    service.dispose();
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
        _libraryScanService?.resumeAll();
        if (realtime != null) unawaited(realtime.setForeground(true));
        if (_downloads != null) unawaited(_downloads!.refresh());
        unawaited(_syncOfflineProgress());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _libraryScanService?.pauseAll();
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
    await _shutdownLibraryScanService();
    await _shutdownDownloads();
    await _clients.dispose();
    await _playbackSettingsRepository.dispose();
    await _database.close();
  }
}
