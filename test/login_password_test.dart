import 'dart:async';

import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/discovery/emby_server_discovery.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:emby_my_client/ui/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final addAccount in [false, true]) {
    for (final password in [
      '',
      'fixture-password',
      '  fixture password  ',
      '   ',
    ]) {
      testWidgets('mode=$addAccount forwards exact password "$password"', (
        tester,
      ) async {
        final controller = _Controller();
        await _pump(tester, controller, addAccount: addAccount);
        await _fill(tester, password: password);
        await _submit(tester);

        expect(controller.calls, [
          (
            addAccount: addAccount,
            username: 'fixture-user',
            password: password,
          ),
        ]);
        expect(find.byKey(const ValueKey('login-error')), findsNothing);
      });
    }

    for (final field in ['server', 'username']) {
      for (final value in ['', '   ']) {
        testWidgets('mode=$addAccount rejects $field "$value"', (tester) async {
          final controller = _Controller();
          await _pump(tester, controller, addAccount: addAccount);
          await _fill(tester);
          await tester.enterText(
            find.byKey(ValueKey('login-$field-field')),
            value,
          );
          await _submit(tester);

          expect(controller.calls, isEmpty);
          expect(
            find.text(field == 'server' ? '请输入服务器地址' : '请输入用户名'),
            findsOneWidget,
          );
          expect(find.text('请输入密码'), findsNothing);
        });
      }
    }

    for (final failure in [
      const EmbyApiException('用户名或密码错误，或账号没有登录权限', statusCode: 401),
      const EmbyApiException(
        '无法连接 Emby 服务器，请检查地址和网络',
        isConnectionFailure: true,
      ),
    ]) {
      testWidgets(
        'mode=$addAccount displays failure and allows retry: ${failure.message}',
        (tester) async {
          final controller = _Controller()..failure = failure;
          await _pump(tester, controller, addAccount: addAccount);
          await _fill(tester);
          await _submit(tester);

          expect(controller.calls.single.password, '');
          expect(find.text(failure.message), findsOneWidget);
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const ValueKey('login-submit-button')),
                )
                .onPressed,
            isNotNull,
          );
          controller.failure = null;
          await _submit(tester);
          expect(controller.calls, hasLength(2));
          expect(find.byKey(const ValueKey('login-error')), findsNothing);
        },
      );
    }

    testWidgets(
      'mode=$addAccount guards button and keyboard while empty-password request is pending',
      (tester) async {
        final gate = Completer<void>();
        final controller = _Controller()..gate = gate;
        await _pump(tester, controller, addAccount: addAccount);
        await _fill(tester);
        final password = find.byKey(const ValueKey('login-password-field'));
        await tester.showKeyboard(password);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        // A second callback can arrive before a frame disables the button.
        tester
            .widget<EditableText>(
              find.descendant(
                of: password,
                matching: find.byType(EditableText),
              ),
            )
            .onSubmitted!('');
        await tester.pump();

        expect(controller.calls, hasLength(1));
        expect(controller.calls.single.password, '');
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('login-submit-button')),
              )
              .onPressed,
          isNull,
        );
        gate.complete();
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('login-submit-button')),
              )
              .onPressed,
          isNotNull,
        );
      },
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Controller controller, {
  required bool addAccount,
}) async {
  addTearDown(controller.dispose);
  await tester.binding.setSurfaceSize(const Size(600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: LoginScreen(
        controller: controller,
        addAccountMode: addAccount,
        capabilities: PlatformCapabilities.ipad,
        discovery: _EmptyDiscovery(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.text('密码（可留空）'), findsOneWidget);
}

Future<void> _fill(WidgetTester tester, {String password = ''}) async {
  await tester.enterText(
    find.byKey(const ValueKey('login-server-field')),
    'https://emby.example.test',
  );
  await tester.enterText(
    find.byKey(const ValueKey('login-username-field')),
    'fixture-user',
  );
  await tester.enterText(
    find.byKey(const ValueKey('login-password-field')),
    password,
  );
}

Future<void> _submit(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('login-submit-button'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

class _Controller extends AppController {
  final List<({bool addAccount, String username, String password})> calls = [];
  EmbyApiException? failure;
  Completer<void>? gate;

  Future<void> _submit(
    bool addAccount,
    String username,
    String password,
  ) async {
    calls.add((addAccount: addAccount, username: username, password: password));
    await gate?.future;
    if (failure != null) throw failure!;
  }

  @override
  Future<void> signIn({
    required String serverUrl,
    required String username,
    required String password,
  }) => _submit(false, username, password);

  @override
  Future<void> addAccount({
    required String serverUrl,
    required String username,
    required String password,
  }) => _submit(true, username, password);
}

class _EmptyDiscovery extends EmbyServerDiscovery {
  @override
  Future<EmbyDiscoveryResult> discover({
    EmbyDiscoveryCancellation? cancellation,
  }) async => const EmbyDiscoveryResult(status: EmbyDiscoveryStatus.notFound);
}
