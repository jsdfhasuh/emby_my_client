import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness_touch.dart';

void main() {
  // A controlled driver fault, not a claim that CI build 195 experienced this
  // exact stall. Keep the old protocol as a negative control: it must trigger
  // the tooltip instead of opening the button when dispatch itself is slow.
  for (final legacy in [true, false]) {
    testWidgets(
      '${legacy ? "legacy delayed" : "single turn"} tap under slow pointer dispatch',
      (tester) async {
        var taps = 0;
        var doubleTaps = 0;
        var tooltips = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Listener(
                // The button/tooltip recognizers receive down first. Simulate
                // synchronous dispatch work after their timers have been armed.
                onPointerDown: (_) => sleep(const Duration(milliseconds: 650)),
                child: GestureDetector(
                  onDoubleTap: () => doubleTaps++,
                  child: Center(
                    child: Tooltip(
                      message: 'Playback options',
                      onTriggered: () => tooltips++,
                      child: IconButton(
                        key: const ValueKey('options'),
                        icon: const Icon(Icons.settings),
                        onPressed: () => taps++,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final point = tester.getCenter(find.byKey(const ValueKey('options')));
        final clock = Stopwatch()..start();
        await tester.runAsync(() async {
          if (legacy) {
            GestureBinding.instance.handlePointerEvent(
              PointerDownEvent(
                pointer: 10000,
                position: point,
                viewId: tester.view.viewId,
                timeStamp: clock.elapsed,
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 40));
            GestureBinding.instance.handlePointerEvent(
              PointerUpEvent(
                pointer: 10000,
                position: point,
                viewId: tester.view.viewId,
                timeStamp: clock.elapsed,
              ),
            );
          } else {
            dispatchHarnessTap(
              position: point,
              pointer: 10000,
              viewId: tester.view.viewId,
              timestamp: () => clock.elapsed,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 350));
        });
        await tester.pumpAndSettle();
        expect(taps, legacy ? 0 : 1);
        expect(tooltips, legacy ? 1 : 0);
        expect(doubleTaps, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
