import 'package:emby_my_client/playback/player_session_coordinator.dart';
import 'package:emby_my_client/playback/playback_operation_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'recreation preserves the item session and switching replaces it',
    () async {
      final coordinator = PlayerSessionCoordinator();
      final initial = coordinator.beginInitialItem();
      late PlaybackItemSession recreated;
      late PlaybackItemSession switched;
      var closes = 0;

      await coordinator.recreateCurrent(
        closeCurrent: () async => closes++,
        reopen: (session) async => recreated = session,
      );
      await coordinator.switchItem(
        closeCurrent: () async => closes++,
        openNext: (session) async => switched = session,
      );

      expect(recreated.id, initial.id);
      expect(switched.id, isNot(initial.id));
      expect(coordinator.currentSession?.id, switched.id);
      expect(closes, 2);
    },
  );

  test(
    'resource recreation preserves and validates the current session',
    () async {
      final coordinator = PlayerSessionCoordinator();
      final session = coordinator.beginInitialItem();

      final value = await coordinator.recreateCurrentResource(
        sessionId: session.id,
        recreate: () async => 'replacement',
      );

      expect(value, 'replacement');
      expect(coordinator.currentSession?.id, session.id);
      await expectLater(
        coordinator.recreateCurrentResource(
          sessionId: const PlaybackItemSessionId('stale'),
          recreate: () async => 'invalid',
        ),
        throwsStateError,
      );
    },
  );

  test('shutdown closes once and prevents later item work', () async {
    final coordinator = PlayerSessionCoordinator();
    coordinator.beginInitialItem();
    var closes = 0;
    var opens = 0;

    await Future.wait([
      coordinator.shutdown(() async => closes++),
      coordinator.shutdown(() async => closes++),
    ]);
    await coordinator.switchItem(
      closeCurrent: () async => closes++,
      openNext: (_) async => opens++,
    );

    expect(closes, 1);
    expect(opens, 0);
    expect(coordinator.currentSession, isNull);
  });
}
