import 'dart:async';

import 'package:emby_my_client/playback/subtitle_application_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'B23 native A late side effect precedes the final disable; B is coalesced',
    () async {
      final queue = SubtitleApplicationQueue();
      final aGate = Completer<void>();
      var revision = 1;
      String? actual;
      final writes = <String>[];
      final a = queue.submit(
        isCurrent: () => revision == 1,
        apply: () async {
          writes.add('A submitted');
          await aGate.future;
          actual =
              'A'; // The actual native effect occurs after Dart intent changes.
          writes.add('A applied');
        },
      );
      final aExpectation = expectLater(
        a,
        throwsA(isA<SubtitleApplicationSuperseded>()),
      );
      revision = 2;
      final b = queue.submit(
        isCurrent: () => revision == 2,
        apply: () async {
          actual = 'B';
          writes.add('B applied');
        },
      );
      final bExpectation = expectLater(
        b,
        throwsA(isA<SubtitleApplicationSuperseded>()),
      );
      revision = 3;
      final off = queue.submit(
        isCurrent: () => revision == 3,
        apply: () async {
          actual = null;
          writes.add('off applied');
        },
      );
      expect(writes, ['A submitted']);
      aGate.complete();
      await Future.wait([aExpectation, bExpectation, off]);
      expect(writes, ['A submitted', 'A applied', 'off applied']);
      expect(actual, isNull);
    },
  );

  test(
    'B25 caller timeout does not permit a concurrent native write',
    () async {
      final queue = SubtitleApplicationQueue();
      final gate = Completer<void>();
      var actual = 'initial';
      final first = queue.submit(
        isCurrent: () => true,
        apply: () async {
          await gate.future;
          actual = 'A';
        },
      );
      await expectLater(
        first.timeout(const Duration(milliseconds: 5)),
        throwsA(isA<TimeoutException>()),
      );
      final off = queue.submit(
        isCurrent: () => true,
        apply: () async {
          actual = 'off';
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(actual, 'initial');
      gate.complete();
      await first;
      await off;
      expect(actual, 'off');
    },
  );

  test(
    'retirement invalidates a queued write without undoing in-flight work',
    () async {
      final queue = SubtitleApplicationQueue();
      final gate = Completer<void>();
      var active = true;
      var calls = 0;
      final first = queue.submit(
        isCurrent: () => active,
        apply: () => gate.future,
      );
      final firstDone = expectLater(
        first,
        throwsA(isA<SubtitleApplicationSuperseded>()),
      );
      final next = queue.submit(
        isCurrent: () => active,
        apply: () async {
          calls++;
        },
      );
      final nextDone = expectLater(
        next,
        throwsA(isA<SubtitleApplicationSuperseded>()),
      );
      active = false;
      gate.complete();
      await Future.wait([firstDone, nextDone]);
      expect(calls, 0);
    },
  );
}
