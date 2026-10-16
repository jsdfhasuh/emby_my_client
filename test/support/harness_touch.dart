import 'package:flutter/gestures.dart';

/// Dispatch a complete touch in one event-loop turn, without a timed hold.
/// A delay between down and up can let an overdue tooltip long-press timer win
/// after a slow pointer-down dispatch. Settling the UI belongs after release.
void dispatchHarnessTap({
  required Offset position,
  required int pointer,
  required int viewId,
  required Duration Function() timestamp,
}) {
  final binding = GestureBinding.instance;
  binding.handlePointerEvent(
    PointerDownEvent(
      pointer: pointer,
      position: position,
      viewId: viewId,
      timeStamp: timestamp(),
    ),
  );
  binding.handlePointerEvent(
    PointerUpEvent(
      pointer: pointer,
      position: position,
      viewId: viewId,
      timeStamp: timestamp(),
    ),
  );
}
