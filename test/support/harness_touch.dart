import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

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

/// Resolve a live target before dispatch, including after every asynchronous
/// preparation boundary. Once [act] begins there is no retry or second tap.
Future<void> actOnCurrentHarnessTarget({
  required Element? Function() locate,
  required bool Function(Element) ready,
  required Future<void> Function(Element) ensureVisible,
  required Future<void> Function() endOfFrame,
  required void Function(Element) act,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  ModalRoute<dynamic>? owner;
  var ownerCaptured = false;
  bool current(Element element) =>
      element.mounted &&
      identical(element, locate()) &&
      identical(ModalRoute.of(element), owner);
  Duration remaining() {
    final value = deadline.difference(DateTime.now());
    if (value <= Duration.zero) {
      throw StateError('UI timeout: tap target preparation');
    }
    return value;
  }

  while (true) {
    remaining();
    final element = locate();
    if (element == null || !element.mounted || !ready(element)) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      continue;
    }
    final route = ModalRoute.of(element);
    if (ownerCaptured && !identical(route, owner)) {
      throw StateError('Tap target moved to a different route');
    }
    owner = route;
    ownerCaptured = true;
    await ensureVisible(element).timeout(remaining());
    if (!current(element)) continue;
    await endOfFrame().timeout(remaining());
    if (!current(element) || !ready(element)) continue;
    remaining();
    // Keep validation, hit-testing and the actual pointer pair synchronous.
    act(element);
    return;
  }
}
