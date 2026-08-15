import 'package:emby_my_client/discovery/emby_server_discovery.dart';
import 'package:emby_my_client/models/discovered_server.dart';
import 'package:emby_my_client/platform/platform_capabilities.dart';
import 'package:emby_my_client/state/app_controller.dart';
import 'package:emby_my_client/ui/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'short iPad viewport scrolls the focused password above the keyboard',
    (tester) async {
      final controller = _FakeLoginController(
        capabilities: PlatformCapabilities.ipad,
      );
      final viewport = ValueNotifier<_ViewportConfig>(
        const _ViewportConfig(
          size: Size(600, 500),
          bottomInset: 220,
          textScale: 2,
        ),
      );
      addTearDown(controller.dispose);
      addTearDown(viewport.dispose);
      await _pumpLogin(tester, controller, viewport);

      final passwordKey = find.byKey(
        const ValueKey<String>('login-password-field'),
      );
      final visibleBottom = viewport.value.size.height - 220;
      final initialRect = tester.getRect(passwordKey);
      expect(initialRect.bottom > visibleBottom - 8, isTrue);
      expect(initialRect.bottom, greaterThan(initialRect.top));
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey<String>('login-scroll-view')),
      );
      final initialOffset = scrollView.controller!.offset;

      await tester.showKeyboard(passwordKey);
      await _pumpScrollAnimation(tester);

      final focusedRect = tester.getRect(passwordKey);
      expect(focusedRect.top, greaterThanOrEqualTo(8));
      expect(focusedRect.bottom, lessThanOrEqualTo(visibleBottom - 8));
      expect(focusedRect.bottom, greaterThan(focusedRect.top));
      expect(scrollView.controller!.offset, greaterThan(initialOffset));
      expect(tester.takeException(), isNull);

      await tester.binding.setSurfaceSize(const Size(500, 600));
      viewport.value = viewport.value.copyWith(size: const Size(500, 600));
      await _pumpScrollAnimation(tester);

      final rotatedRect = tester.getRect(passwordKey);
      expect(rotatedRect.top, greaterThanOrEqualTo(8));
      expect(rotatedRect.bottom, lessThanOrEqualTo(600 - 220 - 8));
      expect(_editableText(tester, passwordKey).focusNode.hasFocus, isTrue);
      expect(_editableText(tester, passwordKey).controller.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('iPad fields stay above a landscape keyboard in sequence', (
    tester,
  ) async {
    final controller = _FakeLoginController(
      capabilities: PlatformCapabilities.ipad,
    );
    final viewport = ValueNotifier<_ViewportConfig>(
      const _ViewportConfig(size: Size(1194, 834), bottomInset: 360),
    );
    addTearDown(controller.dispose);
    addTearDown(viewport.dispose);
    await _pumpLogin(tester, controller, viewport);

    for (final keyName in const [
      'login-server-field',
      'login-username-field',
      'login-password-field',
    ]) {
      final field = find.byKey(ValueKey<String>(keyName));
      await tester.showKeyboard(field);
      await _pumpScrollAnimation(tester);
      final rect = tester.getRect(field);
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(rect.bottom, lessThanOrEqualTo(834 - 360 - 8));
      expect(rect.bottom, greaterThan(rect.top));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'landscape iPad keyboard keeps the login button reachable after a user drag',
    (tester) async {
      final controller = _FakeLoginController(
        capabilities: PlatformCapabilities.ipad,
      );
      final viewport = ValueNotifier<_ViewportConfig>(
        const _ViewportConfig(size: Size(1194, 834), bottomInset: 360),
      );
      addTearDown(controller.dispose);
      addTearDown(viewport.dispose);
      await _pumpLogin(tester, controller, viewport);

      await tester.enterText(
        find.byKey(const ValueKey<String>('login-server-field')),
        '192.0.2.10:8096',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-username-field')),
        'fixture-user',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-password-field')),
        'fixture-password',
      );
      await tester.showKeyboard(
        find.byKey(const ValueKey<String>('login-password-field')),
      );
      await _pumpScrollAnimation(tester);
      await tester.drag(
        find.byKey(const ValueKey<String>('login-scroll-view')),
        const Offset(0, -600),
      );
      await tester.pump();

      final button = find.byKey(const ValueKey<String>('login-submit-button'));
      final buttonRect = tester.getRect(button);
      expect(buttonRect.top, greaterThanOrEqualTo(8));
      expect(buttonRect.bottom, lessThanOrEqualTo(834 - 360 - 8));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(controller.signInCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rotating a focused password preserves text and focus', (
    tester,
  ) async {
    final controller = _FakeLoginController(
      capabilities: PlatformCapabilities.ipad,
    );
    final viewport = ValueNotifier<_ViewportConfig>(
      const _ViewportConfig(size: Size(1194, 834), bottomInset: 360),
    );
    addTearDown(controller.dispose);
    addTearDown(viewport.dispose);
    await _pumpLogin(tester, controller, viewport);

    final passwordKey = find.byKey(
      const ValueKey<String>('login-password-field'),
    );
    await tester.enterText(passwordKey, 'not-a-real-secret');
    await tester.showKeyboard(passwordKey);
    await _pumpScrollAnimation(tester);

    await tester.binding.setSurfaceSize(const Size(834, 1194));
    viewport.value = viewport.value.copyWith(
      size: const Size(834, 1194),
      bottomInset: 320,
    );
    await _pumpScrollAnimation(tester);

    final password = _editableText(tester, passwordKey);
    final rect = tester.getRect(passwordKey);
    expect(password.focusNode.hasFocus, isTrue);
    expect(password.controller.text, 'not-a-real-secret');
    expect(rect.top, greaterThanOrEqualTo(8));
    expect(rect.bottom, lessThanOrEqualTo(1194 - 320 - 8));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'text scaling and compact threshold keep the full form available',
    (tester) async {
      final controller = _FakeLoginController(
        capabilities: PlatformCapabilities.ipad,
      );
      final viewport = ValueNotifier<_ViewportConfig>(
        const _ViewportConfig(size: Size(834, 1194), bottomInset: 0),
      );
      addTearDown(controller.dispose);
      addTearDown(viewport.dispose);
      await _pumpLogin(tester, controller, viewport);

      for (final scale in const [1.0, 1.3, 2.0]) {
        viewport.value = viewport.value.copyWith(textScale: scale);
        await tester.pump();
        await tester.showKeyboard(
          find.byKey(const ValueKey<String>('login-password-field')),
        );
        viewport.value = viewport.value.copyWith(bottomInset: 320);
        await _pumpScrollAnimation(tester);
        final rect = tester.getRect(
          find.byKey(const ValueKey<String>('login-password-field')),
        );
        expect(rect.top, greaterThanOrEqualTo(8));
        expect(rect.bottom, lessThanOrEqualTo(1194 - 320 - 8));
        expect(tester.takeException(), isNull);
        FocusManager.instance.primaryFocus?.unfocus();
        viewport.value = viewport.value.copyWith(bottomInset: 0);
        await tester.pump();
      }

      await tester.binding.setSurfaceSize(const Size(600, 599));
      viewport.value = viewport.value.copyWith(size: const Size(600, 599));
      await tester.pump();
      expect(find.text('登录你的媒体服务器'), findsNothing);

      await tester.binding.setSurfaceSize(const Size(600, 601));
      viewport.value = viewport.value.copyWith(size: const Size(600, 601));
      await tester.pump();
      expect(find.text('登录你的媒体服务器'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rotating a focused password from portrait to landscape preserves the field',
    (tester) async {
      final controller = _FakeLoginController(
        capabilities: PlatformCapabilities.ipad,
      );
      final viewport = ValueNotifier<_ViewportConfig>(
        const _ViewportConfig(size: Size(834, 1194), bottomInset: 320),
      );
      addTearDown(controller.dispose);
      addTearDown(viewport.dispose);
      await _pumpLogin(tester, controller, viewport);

      final passwordKey = find.byKey(
        const ValueKey<String>('login-password-field'),
      );
      await tester.enterText(passwordKey, 'fixture-password');
      await tester.showKeyboard(passwordKey);
      await _pumpScrollAnimation(tester);

      await tester.binding.setSurfaceSize(const Size(1194, 834));
      viewport.value = viewport.value.copyWith(
        size: const Size(1194, 834),
        bottomInset: 360,
      );
      await _pumpScrollAnimation(tester);

      final password = _editableText(tester, passwordKey);
      final rect = tester.getRect(passwordKey);
      expect(password.focusNode.hasFocus, isTrue);
      expect(password.controller.text, 'fixture-password');
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(rect.bottom, lessThanOrEqualTo(834 - 360 - 8));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android discovery remains available in a compact keyboard view',
    (tester) async {
      final controller = _FakeLoginController(
        capabilities: PlatformCapabilities.android,
      );
      final viewport = ValueNotifier<_ViewportConfig>(
        const _ViewportConfig(size: Size(360, 640), bottomInset: 260),
      );
      addTearDown(controller.dispose);
      addTearDown(viewport.dispose);
      await _pumpLogin(
        tester,
        controller,
        viewport,
        discovery: _FakeDiscovery(),
      );

      expect(find.text('Living Room Emby'), findsOneWidget);
      expect(find.text('Guest Room Emby'), findsOneWidget);
      final usernameKey = find.byKey(
        const ValueKey<String>('login-username-field'),
      );
      await tester.showKeyboard(usernameKey);
      await _pumpScrollAnimation(tester);
      final rect = tester.getRect(usernameKey);
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(rect.bottom, lessThanOrEqualTo(640 - 260 - 8));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android 360 by 800 keeps discovery visible without a keyboard', (
    tester,
  ) async {
    final controller = _FakeLoginController(
      capabilities: PlatformCapabilities.android,
    );
    final viewport = ValueNotifier<_ViewportConfig>(
      const _ViewportConfig(size: Size(360, 800)),
    );
    addTearDown(controller.dispose);
    addTearDown(viewport.dispose);
    await _pumpLogin(tester, controller, viewport, discovery: _FakeDiscovery());
    await tester.pumpAndSettle();

    expect(find.text('Emby 客户端'), findsOneWidget);
    expect(find.text('Living Room Emby'), findsOneWidget);
    await tester.tap(find.text('Living Room Emby'));
    await tester.pump();
    expect(
      _editableText(
        tester,
        find.byKey(const ValueKey<String>('login-server-field')),
      ).controller.text,
      'http://192.0.2.10:8096',
    );
    expect(controller.signInCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focused Android field can select discovery without submitting', (
    tester,
  ) async {
    final controller = _FakeLoginController(
      capabilities: PlatformCapabilities.android,
    );
    final viewport = ValueNotifier<_ViewportConfig>(
      const _ViewportConfig(size: Size(360, 800), bottomInset: 260),
    );
    addTearDown(controller.dispose);
    addTearDown(viewport.dispose);
    await _pumpLogin(tester, controller, viewport, discovery: _FakeDiscovery());
    await tester.pumpAndSettle();

    final usernameKey = find.byKey(
      const ValueKey<String>('login-username-field'),
    );
    await tester.showKeyboard(usernameKey);
    await _pumpScrollAnimation(tester);
    await tester.tap(find.text('Living Room Emby'));
    await tester.pump();

    expect(
      _editableText(
        tester,
        find.byKey(const ValueKey<String>('login-server-field')),
      ).controller.text,
      'http://192.0.2.10:8096',
    );
    expect(controller.signInCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty compact iPad form exposes all validators and keeps login inactive',
    (tester) async {
      final controller = _FakeLoginController(
        capabilities: PlatformCapabilities.ipad,
      );
      final viewport = ValueNotifier<_ViewportConfig>(
        const _ViewportConfig(size: Size(600, 500), bottomInset: 220),
      );
      addTearDown(controller.dispose);
      addTearDown(viewport.dispose);
      await _pumpLogin(tester, controller, viewport);

      final scrollKey = find.byKey(const ValueKey<String>('login-scroll-view'));
      await tester.drag(scrollKey, const Offset(0, -1000));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('login-submit-button')),
      );
      await tester.pumpAndSettle();
      for (var index = 0; index < 3; index++) {
        await tester.drag(scrollKey, const Offset(0, -300));
        await tester.pump();
      }

      for (final text in const ['请输入服务器地址', '请输入用户名', '请输入密码']) {
        expect(find.text(text), findsOneWidget);
      }
      final buttonRect = tester.getRect(
        find.byKey(const ValueKey<String>('login-submit-button')),
      );
      expect(buttonRect.top, greaterThanOrEqualTo(8));
      expect(buttonRect.bottom, lessThanOrEqualTo(500 - 220 - 8));
      expect(controller.signInCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dragging the login scroll view dismisses the keyboard', (
    tester,
  ) async {
    final controller = _FakeLoginController(
      capabilities: PlatformCapabilities.ipad,
    );
    final viewport = ValueNotifier<_ViewportConfig>(
      const _ViewportConfig(size: Size(600, 500), bottomInset: 220),
    );
    addTearDown(controller.dispose);
    addTearDown(viewport.dispose);
    await _pumpLogin(tester, controller, viewport);

    final passwordKey = find.byKey(
      const ValueKey<String>('login-password-field'),
    );
    await tester.showKeyboard(passwordKey);
    await _pumpScrollAnimation(tester);
    await tester.drag(
      find.byKey(const ValueKey<String>('login-scroll-view')),
      const Offset(0, -120),
    );
    await tester.pump();

    expect(_editableText(tester, passwordKey).focusNode.hasFocus, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical iPad layout exposes the button after a user drag', (
    tester,
  ) async {
    final controller = _FakeLoginController(
      capabilities: PlatformCapabilities.ipad,
    );
    final viewport = ValueNotifier<_ViewportConfig>(
      const _ViewportConfig(
        size: Size(834, 1194),
        bottomInset: 320,
        textScale: 2,
      ),
    );
    addTearDown(controller.dispose);
    addTearDown(viewport.dispose);
    await _pumpLogin(tester, controller, viewport);

    await tester.enterText(
      find.byKey(const ValueKey<String>('login-server-field')),
      '192.0.2.10:8096',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-username-field')),
      'tester',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password-field')),
      'password',
    );
    await tester.drag(
      find.byKey(const ValueKey<String>('login-scroll-view')),
      const Offset(0, -500),
    );
    await tester.pump();

    final buttonKey = find.byKey(const ValueKey<String>('login-submit-button'));
    final buttonRect = tester.getRect(buttonKey);
    expect(buttonRect.top, greaterThanOrEqualTo(8));
    expect(buttonRect.bottom, lessThanOrEqualTo(1194 - 320 - 8));
    await tester.tap(buttonKey);
    await tester.pumpAndSettle();
    expect(controller.signInCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'error content and retry button remain accessible in a short view',
    (tester) async {
      final controller = _FakeLoginController(
        capabilities: PlatformCapabilities.ipad,
        failure: StateError('do-not-display-this'),
      );
      final viewport = ValueNotifier<_ViewportConfig>(
        const _ViewportConfig(
          size: Size(600, 500),
          bottomInset: 220,
          textScale: 2,
        ),
      );
      addTearDown(controller.dispose);
      addTearDown(viewport.dispose);
      await _pumpLogin(tester, controller, viewport);

      await tester.enterText(
        find.byKey(const ValueKey<String>('login-server-field')),
        '192.0.2.10:8096',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-username-field')),
        'tester',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-password-field')),
        'password',
      );
      final scrollKey = find.byKey(const ValueKey<String>('login-scroll-view'));
      await tester.drag(scrollKey, const Offset(0, -500));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('login-submit-button')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('login-error')), findsOneWidget);
      expect(find.text('登录失败，请稍后重试'), findsOneWidget);
      expect(find.textContaining('do-not-display-this'), findsNothing);

      await tester.drag(scrollKey, const Offset(0, -500));
      await tester.pump();
      final errorRect = tester.getRect(
        find.byKey(const ValueKey<String>('login-error')),
      );
      final buttonRect = tester.getRect(
        find.byKey(const ValueKey<String>('login-submit-button')),
      );
      expect(errorRect.top, greaterThanOrEqualTo(8));
      expect(buttonRect.bottom, lessThanOrEqualTo(500 - 220 - 8));
      expect(controller.signInCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tap outside dismisses the keyboard and the password eye keeps focus',
    (tester) async {
      final controller = _FakeLoginController(
        capabilities: PlatformCapabilities.ipad,
      );
      final viewport = ValueNotifier<_ViewportConfig>(
        const _ViewportConfig(size: Size(600, 500), bottomInset: 220),
      );
      addTearDown(controller.dispose);
      addTearDown(viewport.dispose);
      await _pumpLogin(tester, controller, viewport);

      final passwordKey = find.byKey(
        const ValueKey<String>('login-password-field'),
      );
      await tester.showKeyboard(passwordKey);
      await _pumpScrollAnimation(tester);
      await tester.tap(find.byTooltip('显示密码'));
      await tester.pump();
      expect(_editableText(tester, passwordKey).focusNode.hasFocus, isTrue);
      final passwordRect = tester.getRect(passwordKey);
      expect(passwordRect.top, greaterThanOrEqualTo(8));
      expect(passwordRect.bottom, lessThanOrEqualTo(500 - 220 - 8));

      await tester.tapAt(const Offset(590, 20));
      await tester.pump();
      expect(_editableText(tester, passwordKey).focusNode.hasFocus, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Next and Done use the existing focus chain and submit once', (
    tester,
  ) async {
    final controller = _FakeLoginController(
      capabilities: PlatformCapabilities.ipad,
    );
    final viewport = ValueNotifier<_ViewportConfig>(
      const _ViewportConfig(size: Size(834, 1194)),
    );
    addTearDown(controller.dispose);
    addTearDown(viewport.dispose);
    await _pumpLogin(tester, controller, viewport);

    final serverKey = find.byKey(const ValueKey<String>('login-server-field'));
    final usernameKey = find.byKey(
      const ValueKey<String>('login-username-field'),
    );
    final passwordKey = find.byKey(
      const ValueKey<String>('login-password-field'),
    );
    await tester.enterText(serverKey, '192.0.2.10:8096');
    await tester.enterText(usernameKey, 'tester');
    await tester.enterText(passwordKey, 'password');
    await tester.tap(serverKey);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(_editableText(tester, usernameKey).focusNode.hasFocus, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(_editableText(tester, passwordKey).focusNode.hasFocus, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(controller.signInCalls, 1);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpLogin(
  WidgetTester tester,
  _FakeLoginController controller,
  ValueNotifier<_ViewportConfig> viewport, {
  EmbyServerDiscovery? discovery,
}) async {
  await tester.binding.setSurfaceSize(viewport.value.size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      builder: (context, child) => ValueListenableBuilder<_ViewportConfig>(
        valueListenable: viewport,
        builder: (context, config, _) {
          final data = MediaQuery.of(context).copyWith(
            viewInsets: EdgeInsets.only(bottom: config.bottomInset),
            textScaler: TextScaler.linear(config.textScale),
          );
          return MediaQuery(data: data, child: child!);
        },
      ),
      home: LoginScreen(
        controller: controller,
        capabilities: controller.capabilities,
        discovery: discovery ?? _EmptyDiscovery(),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpScrollAnimation(WidgetTester tester) async {
  for (var index = 0; index < 12; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

EditableText _editableText(WidgetTester tester, Finder field) =>
    tester.widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );

class _ViewportConfig {
  const _ViewportConfig({
    required this.size,
    this.bottomInset = 0,
    this.textScale = 1,
  });

  final Size size;
  final double bottomInset;
  final double textScale;

  _ViewportConfig copyWith({
    Size? size,
    double? bottomInset,
    double? textScale,
  }) => _ViewportConfig(
    size: size ?? this.size,
    bottomInset: bottomInset ?? this.bottomInset,
    textScale: textScale ?? this.textScale,
  );
}

class _FakeLoginController extends AppController {
  _FakeLoginController({required this.capabilities, this.failure})
    : super(capabilities: capabilities);

  final PlatformCapabilities capabilities;
  final Object? failure;
  int signInCalls = 0;

  @override
  Future<void> signIn({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    signInCalls++;
    if (failure != null) throw failure!;
  }
}

class _FakeDiscovery extends EmbyServerDiscovery {
  @override
  Future<EmbyDiscoveryResult> discover({
    EmbyDiscoveryCancellation? cancellation,
  }) async => const EmbyDiscoveryResult(
    status: EmbyDiscoveryStatus.found,
    servers: [
      DiscoveredServer(
        id: 'living-room',
        name: 'Living Room Emby',
        address: 'http://192.0.2.10:8096',
      ),
      DiscoveredServer(
        id: 'guest-room',
        name: 'Guest Room Emby',
        address: 'http://192.0.2.11:8096',
      ),
    ],
  );
}

class _EmptyDiscovery extends EmbyServerDiscovery {
  @override
  Future<EmbyDiscoveryResult> discover({
    EmbyDiscoveryCancellation? cancellation,
  }) async => const EmbyDiscoveryResult(status: EmbyDiscoveryStatus.notFound);
}
