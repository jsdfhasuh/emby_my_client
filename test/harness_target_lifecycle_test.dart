import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/harness_touch.dart';

void main() {
  testWidgets('legacy retained target fails when frame replaces menu content', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Column(children: [Text('subtitle')])),
    );
    final retained = tester.element(find.text('subtitle'));
    final frame = Completer<void>();
    final operation = () async {
      await Scrollable.ensureVisible(
        retained,
        duration: const Duration(milliseconds: 200),
      );
      await frame.future;
      retained.findRenderObject();
    }();
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: Text('loading'))),
    );
    expect(retained.mounted, isFalse);
    final assertion = expectLater(
      operation,
      throwsA(
        isA<FlutterError>().having(
          (e) => e.toString(),
          'message',
          contains('Cannot get renderObject of inactive element'),
        ),
      ),
    );
    frame.complete();
    await assertion;
  });
  for (final boundary in ['ensure-visible', 'end-of-frame']) {
    testWidgets(
      'reacquires replaced target after $boundary before one real tap',
      (tester) async {
        var taps = 0;
        Element? acted;
        var downs = 0;
        var ups = 0;
        Widget ready(int generation) => MaterialApp(
          home: Scaffold(
            body: Center(
              key: ValueKey(generation),
              child: Listener(
                onPointerDown: (_) => downs++,
                onPointerUp: (_) => ups++,
                child: TextButton(
                  onPressed: () => taps++,
                  child: const Text('subtitle'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(ready(1));
        final retired = tester.element(find.text('subtitle'));
        final barrier = Completer<void>();
        var ensureCount = 0;
        var frameCount = 0;
        Element? locate() => find.text('subtitle').evaluate().firstOrNull;
        final operation = actOnCurrentHarnessTarget(
          locate: locate,
          ready: (_) => true,
          ensureVisible: (element) async {
            await Scrollable.ensureVisible(element);
            if (++ensureCount == 1 && boundary == 'ensure-visible') {
              await barrier.future;
            }
          },
          endOfFrame: () async {
            if (++frameCount == 1 && boundary == 'end-of-frame') {
              await barrier.future;
            }
          },
          act: (element) {
            acted = element;
            final box = element.findRenderObject()! as RenderBox;
            dispatchHarnessTap(
              position: box.localToGlobal(box.size.center(Offset.zero)),
              pointer: 12000,
              viewId: tester.view.viewId,
              timestamp: () => Duration.zero,
            );
          },
        );
        await tester.pump();
        await tester.pumpWidget(
          const MaterialApp(home: Center(child: Text('loading'))),
        );
        expect(retired.mounted, isFalse);
        barrier.complete();
        await tester.pump();
        expect([downs, ups, taps], [0, 0, 0]);
        await tester.pumpWidget(ready(2));
        await tester.pump(const Duration(milliseconds: 40));
        await operation;
        await tester.pumpAndSettle();
        expect(acted, isNot(same(retired)));
        expect([downs, ups, taps], [1, 1, 1]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('missing target reaches deadline without pointer dispatch', (
    tester,
  ) async {
    var dispatched = false;
    await expectLater(
      actOnCurrentHarnessTarget(
        locate: () => null,
        ready: (_) => true,
        ensureVisible: (_) async {},
        endOfFrame: () async {},
        act: (_) => dispatched = true,
        timeout: Duration.zero,
      ),
      throwsStateError,
    );
    expect(dispatched, isFalse);
  });
}
