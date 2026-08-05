import 'dart:async';

import 'package:emby_my_client/core/diagnostic_log.dart';
import 'package:emby_my_client/core/sign_in_diagnostics.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/data/session_store.dart';
import 'package:emby_my_client/discovery/emby_server_discovery.dart';
import 'package:emby_my_client/models/discovered_server.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:emby_my_client/ui/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device ID read failure does not authenticate', () async {
    final storage = _FakeSessionStorage()
      ..readFailures['emby_device_id_v1'] = PlatformException(code: '-34018');
    var authenticateCalls = 0;
    final controller = _controller(
      storage,
      authenticator:
          ({
            required serverUrl,
            required username,
            required password,
            required deviceId,
            required deviceName,
          }) async {
            authenticateCalls++;
            return _session;
          },
    );
    addTearDown(controller.dispose);

    await expectLater(
      controller.signIn(
        serverUrl: 'http://192.168.1.20:8096',
        username: 'user',
        password: 'password',
      ),
      throwsA(
        isA<SignInFailure>()
            .having((error) => error.stage, 'stage', SignInStage.deviceIdRead)
            .having(
              (error) => error.reason,
              'reason',
              SignInFailureReason.secureStorageMissingEntitlement,
            ),
      ),
    );
    expect(authenticateCalls, 0);
  });

  test('device ID write failure does not authenticate', () async {
    final storage = _FakeSessionStorage()
      ..writeFailures['emby_device_id_v1'] = StateError(
        'password=secret deviceId=device-secret',
      );
    var authenticateCalls = 0;
    final controller = _controller(
      storage,
      authenticator:
          ({
            required serverUrl,
            required username,
            required password,
            required deviceId,
            required deviceName,
          }) async {
            authenticateCalls++;
            return _session;
          },
    );
    addTearDown(controller.dispose);

    await expectLater(
      controller.signIn(
        serverUrl: 'http://192.168.1.20:8096',
        username: 'user',
        password: 'password',
      ),
      throwsA(
        isA<SignInFailure>()
            .having((error) => error.stage, 'stage', SignInStage.deviceIdWrite)
            .having(
              (error) => error.reason,
              'reason',
              SignInFailureReason.secureStorageUnexpected,
            ),
      ),
    );
    expect(authenticateCalls, 0);
  });

  test('session write failure does not enter the signed-in state', () async {
    final storage = _FakeSessionStorage()
      ..values['emby_device_id_v1'] = 'existing-device'
      ..writeFailures['emby_session_v1'] = PlatformException(
        code: 'write_failed',
      );
    var authenticateCalls = 0;
    final controller = _controller(
      storage,
      authenticator:
          ({
            required serverUrl,
            required username,
            required password,
            required deviceId,
            required deviceName,
          }) async {
            authenticateCalls++;
            return _session;
          },
    );
    addTearDown(controller.dispose);

    await expectLater(
      controller.signIn(
        serverUrl: 'http://192.168.1.20:8096',
        username: 'user',
        password: 'password',
      ),
      throwsA(
        isA<SignInFailure>()
            .having((error) => error.stage, 'stage', SignInStage.sessionSave)
            .having(
              (error) => error.reason,
              'reason',
              SignInFailureReason.secureStorageUnexpected,
            ),
      ),
    );
    expect(authenticateCalls, 1);
    expect(controller.isSignedIn, isFalse);
    expect(storage.values, isNot(contains('emby_session_v1')));
  });

  test('startup session read failure stays logged out', () async {
    final logLines = <String>[];
    DiagnosticLog.instance.setTestSink(logLines.add);
    addTearDown(() => DiagnosticLog.instance.setTestSink(null));
    final storage = _FakeSessionStorage()
      ..readFailures['emby_session_v1'] = StateError(
        'password=secret AccessToken=token-secret',
      );
    final controller = _controller(storage);
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(controller.isSignedIn, isFalse);
    expect(controller.isInitializing, isFalse);
    final failure = const SecureStorageFailure(
      operation: SecureStorageOperation.readSession,
      reason: SecureStorageFailureReason.unexpected,
    );
    expect(failure.toString(), isNot(contains('secret')));
    final logText = logLines.join('\n');
    expect(
      logLines.any(
        (line) =>
            line.contains('event=session_restore_failure') &&
            line.contains('stage=SESSION_READ'),
      ),
      isTrue,
    );
    expect(logText, isNot(contains('secret')));
    expect(logText, isNot(contains('token-secret')));
  });

  test('corrupt session cleanup failure is contained and classified', () async {
    final logLines = <String>[];
    DiagnosticLog.instance.setTestSink(logLines.add);
    addTearDown(() => DiagnosticLog.instance.setTestSink(null));
    final storage = _FakeSessionStorage()
      ..values['emby_session_v1'] = '{not-json'
      ..deleteFailures['emby_session_v1'] = PlatformException(
        code: 'delete_failed',
        details: 'Token=token-secret',
      );
    final store = SessionStore(sessionStorage: storage);

    await expectLater(store.loadSession(), completion(isNull));
    expect(storage.deleteCalls, 1);
    final logText = logLines.join('\n');
    expect(
      logLines.any(
        (line) =>
            line.contains('stage=SESSION_DELETE') &&
            line.contains('event=session_delete_failure') &&
            line.contains('reason=secure_storage_unexpected'),
      ),
      isTrue,
    );
    expect(logText, isNot(contains('delete_failed')));
    expect(logText, isNot(contains('token-secret')));
  });

  test(
    'only strict PlatformException values classify as missing entitlement',
    () {
      expect(
        SessionStore.classifyPlatformException(
          PlatformException(code: '-34018'),
        ),
        SecureStorageFailureReason.missingEntitlement,
      );
      expect(
        SessionStore.classifyPlatformException(
          PlatformException(code: 'keychain', details: -34018),
        ),
        SecureStorageFailureReason.missingEntitlement,
      );
      expect(
        SessionStore.classifyPlatformException(
          PlatformException(
            code: 'keychain',
            message: 'OSStatus error -34018.',
          ),
        ),
        SecureStorageFailureReason.missingEntitlement,
      );
      expect(
        SessionStore.classifyPlatformException(
          PlatformException(code: 'keychain', message: 'id-340180'),
        ),
        SecureStorageFailureReason.unexpected,
      );
    },
  );

  test('non PlatformException text cannot claim missing entitlement', () async {
    final storage = _FakeSessionStorage()
      ..readFailures['emby_device_id_v1'] = StateError('OSStatus -34018');
    final store = SessionStore(sessionStorage: storage);

    await expectLater(
      store.readDeviceId(),
      throwsA(
        isA<SecureStorageFailure>().having(
          (error) => error.reason,
          'reason',
          SecureStorageFailureReason.unexpected,
        ),
      ),
    );
  });

  test(
    'secure failures and diagnostic redaction do not retain sensitive values',
    () {
      const password = 'password-secret';
      const token = 'access-token-secret';
      const username = 'private-user';
      const deviceId = 'device-secret';
      final redacted = DiagnosticLog.redact(
        '{"password":"$password","Pw":"$password",'
        '"AccessToken":"$token","username":"$username",'
        '"deviceId":"$deviceId"} '
        'Authorization: Bearer $token '
        'https://private.example.test/login?api_key=$token',
      );

      expect(redacted, isNot(contains(password)));
      expect(redacted, isNot(contains(token)));
      expect(redacted, isNot(contains(username)));
      expect(redacted, isNot(contains(deviceId)));
      expect(
        const SecureStorageFailure(
          operation: SecureStorageOperation.writeSession,
          reason: SecureStorageFailureReason.unexpected,
        ).toString(),
        isNot(contains(password)),
      );
    },
  );

  test('diagnostic redaction covers Authorization header forms', () {
    const basicCredential = 'basic-credential-secret';
    const bearerToken = 'bearer-token-secret';
    final redacted = DiagnosticLog.redact(
      'Authorization: Basic $basicCredential\n'
      'Authorization: Bearer $bearerToken\n'
      '{"Authorization":"Bearer $bearerToken",'
      '"authorization":"Basic $basicCredential"}',
    );

    expect(redacted, isNot(contains(basicCredential)));
    expect(redacted, isNot(contains(bearerToken)));
    expect(redacted, contains('Authorization: <redacted>'));
    expect(redacted, contains('"Authorization":"<redacted>"'));
    expect(redacted, contains('"authorization":"<redacted>"'));
  });

  test(
    'EmbyApiException remains the original authentication failure type',
    () async {
      final storage = _FakeSessionStorage()
        ..values['emby_device_id_v1'] = 'existing-device';
      const failure = EmbyApiException('用户名或密码错误，或账号没有登录权限', statusCode: 401);
      final controller = _controller(
        storage,
        authenticator:
            ({
              required serverUrl,
              required username,
              required password,
              required deviceId,
              required deviceName,
            }) async {
              throw failure;
            },
      );
      addTearDown(controller.dispose);

      await expectLater(
        controller.signIn(
          serverUrl: 'http://192.168.1.20:8096',
          username: 'user',
          password: 'password',
        ),
        throwsA(same(failure)),
      );
    },
  );

  test('unexpected sign-in errors use only fixed safe log fields', () async {
    final logLines = <String>[];
    DiagnosticLog.instance.setTestSink(logLines.add);
    addTearDown(() => DiagnosticLog.instance.setTestSink(null));
    final storage = _FakeSessionStorage()
      ..values['emby_device_id_v1'] = 'existing-device';
    const rawDetails =
        'error=raw-error message=raw-message details=raw-details '
        'stackTrace=raw-stack';
    final controller = _controller(
      storage,
      authenticator:
          ({
            required serverUrl,
            required username,
            required password,
            required deviceId,
            required deviceName,
          }) async {
            throw StateError(rawDetails);
          },
    );
    addTearDown(controller.dispose);

    await expectLater(
      controller.signIn(
        serverUrl: 'http://192.168.1.20:8096',
        username: 'user',
        password: 'password',
      ),
      throwsA(
        isA<SignInFailure>()
            .having((error) => error.stage, 'stage', SignInStage.authenticate)
            .having(
              (error) => error.reason,
              'reason',
              SignInFailureReason.unknown,
            ),
      ),
    );

    final logText = logLines.join('\n');
    expect(
      logLines.any(
        (line) =>
            line.contains('event=sign_in_failure') &&
            line.contains('stage=AUTHENTICATE'),
      ),
      isTrue,
    );
    expect(logText, isNot(contains('raw-error')));
    expect(logText, isNot(contains('raw-message')));
    expect(logText, isNot(contains('raw-details')));
    expect(logText, isNot(contains('raw-stack')));
  });

  test(
    'already signed-in state rejects without clearing or authenticating',
    () async {
      final storage = _FakeSessionStorage()
        ..values['emby_device_id_v1'] = 'existing-device'
        ..values['emby_session_v1'] = jsonSession(_session);
      var authenticateCalls = 0;
      final controller = _controller(
        storage,
        authenticator:
            ({
              required serverUrl,
              required username,
              required password,
              required deviceId,
              required deviceName,
            }) async {
              authenticateCalls++;
              return _session;
            },
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final deleteCallsBefore = storage.deleteCalls;
      final saveCallsBefore = storage.writeCalls;

      await expectLater(
        controller.signIn(
          serverUrl: 'http://other.example.test',
          username: 'other',
          password: 'other-password',
        ),
        throwsA(
          isA<SignInFailure>().having(
            (error) => error.reason,
            'reason',
            SignInFailureReason.alreadySignedIn,
          ),
        ),
      );
      expect(authenticateCalls, 0);
      expect(storage.deleteCalls, deleteCallsBefore);
      expect(storage.writeCalls, saveCallsBefore);
      expect(controller.isSignedIn, isTrue);
    },
  );

  test(
    'a concurrent sign-in is rejected before it reads second credentials',
    () async {
      final storage = _FakeSessionStorage()
        ..values['emby_device_id_v1'] = 'existing-device';
      final authentication = Completer<EmbySession>();
      var authenticateCalls = 0;
      final controller = _controller(
        storage,
        authenticator:
            ({
              required serverUrl,
              required username,
              required password,
              required deviceId,
              required deviceName,
            }) {
              authenticateCalls++;
              return authentication.future;
            },
      );
      addTearDown(controller.dispose);

      final first = controller.signIn(
        serverUrl: 'http://192.168.1.20:8096',
        username: 'first',
        password: 'first-password',
      );
      await expectLater(
        controller.signIn(
          serverUrl: 'http://other.example.test',
          username: 'second',
          password: 'second-password',
        ),
        throwsA(
          isA<SignInFailure>().having(
            (error) => error.reason,
            'reason',
            SignInFailureReason.alreadyInProgress,
          ),
        ),
      );
      expect(authenticateCalls, 1);
      authentication.complete(_session);
      await first;
    },
  );

  testWidgets('iPad secure storage failure shows a fixed diagnostic code', (
    tester,
  ) async {
    final controller = _UiFailureController(
      const SignInFailure(
        stage: SignInStage.deviceIdRead,
        reason: SignInFailureReason.secureStorageMissingEntitlement,
      ),
    );
    addTearDown(controller.dispose);
    await _submit(tester, controller, PlatformCapabilities.ipad);

    expect(
      find.text('无法使用系统安全存储，登录信息不能安全保存。请记录诊断码并安装修复构建；除非验收步骤明确要求，请不要卸载现有版本。'),
      findsOneWidget,
    );
    expect(find.text('LOGIN-DID-READ-KC-MISSING'), findsOneWidget);
  });

  testWidgets('iPad device ID write failure shows its Gate A code', (
    tester,
  ) async {
    final controller = _UiFailureController(
      const SignInFailure(
        stage: SignInStage.deviceIdWrite,
        reason: SignInFailureReason.secureStorageMissingEntitlement,
      ),
    );
    addTearDown(controller.dispose);
    await _submit(tester, controller, PlatformCapabilities.ipad);

    expect(find.text('登录失败，请稍后重试'), findsNothing);
    expect(
      find.text('无法使用系统安全存储，登录信息不能安全保存。请记录诊断码并安装修复构建；除非验收步骤明确要求，请不要卸载现有版本。'),
      findsOneWidget,
    );
    expect(find.text('LOGIN-DID-WRITE-KC-MISSING'), findsOneWidget);
  });

  testWidgets('iPad session save failure shows its Gate A code', (
    tester,
  ) async {
    final controller = _UiFailureController(
      const SignInFailure(
        stage: SignInStage.sessionSave,
        reason: SignInFailureReason.secureStorageMissingEntitlement,
      ),
    );
    addTearDown(controller.dispose);
    await _submit(tester, controller, PlatformCapabilities.ipad);

    expect(
      find.text('无法使用系统安全存储，登录信息不能安全保存。请记录诊断码并安装修复构建；除非验收步骤明确要求，请不要卸载现有版本。'),
      findsOneWidget,
    );
    expect(find.text('LOGIN-SESSION-SAVE-KC-MISSING'), findsOneWidget);
  });

  testWidgets('Android secure storage failure keeps the generic fallback', (
    tester,
  ) async {
    final controller = _UiFailureController(
      const SignInFailure(
        stage: SignInStage.deviceIdRead,
        reason: SignInFailureReason.secureStorageMissingEntitlement,
      ),
    );
    addTearDown(controller.dispose);
    await _submit(tester, controller, PlatformCapabilities.android);

    expect(find.text('登录失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('LOGIN-'), findsNothing);
    expect(find.textContaining('安全存储'), findsNothing);
  });

  testWidgets('iPad authentication failure keeps the API message and code', (
    tester,
  ) async {
    final controller = _UiApiFailureController(
      const EmbyApiException('用户名或密码错误，或账号没有登录权限', statusCode: 401),
    );
    addTearDown(controller.dispose);
    await _submit(tester, controller, PlatformCapabilities.ipad);

    expect(find.text('用户名或密码错误，或账号没有登录权限'), findsOneWidget);
    expect(find.text('LOGIN-AUTH'), findsOneWidget);
  });

  testWidgets('iPad activation failure shows its fixed message and code', (
    tester,
  ) async {
    final controller = _UiFailureController(
      const SignInFailure(
        stage: SignInStage.activate,
        reason: SignInFailureReason.activationFailed,
      ),
    );
    addTearDown(controller.dispose);
    await _submit(tester, controller, PlatformCapabilities.ipad);

    expect(find.text('登录初始化失败，请重试；如持续出现，请提供诊断码。'), findsOneWidget);
    expect(find.text('LOGIN-ACTIVATE'), findsOneWidget);
  });

  testWidgets('iPad unknown failure keeps generic text with fixed code', (
    tester,
  ) async {
    final controller = _UiFailureController(
      const SignInFailure(
        stage: SignInStage.authenticate,
        reason: SignInFailureReason.unknown,
      ),
    );
    addTearDown(controller.dispose);
    await _submit(tester, controller, PlatformCapabilities.ipad);

    expect(find.text('登录失败，请稍后重试'), findsOneWidget);
    expect(find.text('LOGIN-UNKNOWN'), findsOneWidget);
  });

  testWidgets('iPad raw StateError gets the fixed unknown diagnostic code', (
    tester,
  ) async {
    final controller = _UiRawFailureController(StateError('raw-secret-error'));
    addTearDown(controller.dispose);
    await _submit(tester, controller, PlatformCapabilities.ipad);

    expect(find.text('登录失败，请稍后重试'), findsOneWidget);
    expect(find.text('LOGIN-UNKNOWN'), findsOneWidget);
    expect(find.textContaining('raw-secret-error'), findsNothing);
  });

  testWidgets('Android raw Exception keeps the generic fallback', (
    tester,
  ) async {
    final controller = _UiRawFailureController(Exception('raw-secret-error'));
    addTearDown(controller.dispose);
    await _submit(tester, controller, PlatformCapabilities.android);

    expect(find.text('登录失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('LOGIN-'), findsNothing);
    expect(find.textContaining('raw-secret-error'), findsNothing);
  });
}

final _session = EmbySession(
  serverUrl: 'http://192.168.1.20:8096',
  serverName: 'Test Emby',
  serverId: 'server-id',
  userId: 'user-id',
  username: 'user',
  accessToken: 'token',
  deviceId: 'existing-device',
);

AppController _controller(
  _FakeSessionStorage storage, {
  SignInAuthenticator? authenticator,
}) => AppController(
  store: SessionStore(sessionStorage: storage),
  capabilities: PlatformCapabilities.ipad,
  authenticator: authenticator,
);

String jsonSession(EmbySession session) =>
    '{"serverUrl":"${session.serverUrl}","serverName":"${session.serverName}",'
    '"serverId":"${session.serverId}","userId":"${session.userId}",'
    '"username":"${session.username}","accessToken":"${session.accessToken}",'
    '"deviceId":"${session.deviceId}"}';

Future<void> _submit(
  WidgetTester tester,
  AppController controller,
  PlatformCapabilities capabilities,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: LoginScreen(
        controller: controller,
        capabilities: capabilities,
        discovery: _EmptyDiscovery(),
      ),
    ),
  );
  await tester.pump();
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), '192.168.1.20:8096');
  await tester.enterText(fields.at(1), 'user');
  await tester.enterText(fields.at(2), 'password');
  await tester.tap(find.text('登录'));
  await tester.pumpAndSettle();
}

class _FakeSessionStorage implements SessionStorage {
  final Map<String, String> values = <String, String>{};
  final Map<String, Object> readFailures = <String, Object>{};
  final Map<String, Object> writeFailures = <String, Object>{};
  final Map<String, Object> deleteFailures = <String, Object>{};
  int writeCalls = 0;
  int deleteCalls = 0;

  @override
  Future<String?> read(String key) async {
    final failure = readFailures[key];
    if (failure != null) throw failure;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeCalls++;
    final failure = writeFailures[key];
    if (failure != null) throw failure;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleteCalls++;
    final failure = deleteFailures[key];
    if (failure != null) throw failure;
    values.remove(key);
  }
}

class _UiFailureController extends AppController {
  _UiFailureController(this.failure)
    : super(capabilities: PlatformCapabilities.android);

  final SignInFailure failure;

  @override
  Future<void> signIn({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    throw failure;
  }
}

class _UiApiFailureController extends AppController {
  _UiApiFailureController(this.failure)
    : super(capabilities: PlatformCapabilities.android);

  final EmbyApiException failure;

  @override
  Future<void> signIn({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    throw failure;
  }
}

class _UiRawFailureController extends AppController {
  _UiRawFailureController(this.failure)
    : super(capabilities: PlatformCapabilities.android);

  final Object failure;

  @override
  Future<void> signIn({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    throw failure;
  }
}

class _EmptyDiscovery extends EmbyServerDiscovery {
  @override
  Future<List<DiscoveredServer>> discover() async => const [];
}
