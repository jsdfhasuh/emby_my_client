import 'dart:async';

import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/photos/photo_viewed_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('only the displayed current photo is marked after one second', (
    tester,
  ) async {
    final writes = <(String, bool)>[];
    final saved = <(String, bool)>[];
    final controller = PhotoViewedController(
      writeViewed: (id, viewed) async => writes.add((id, viewed)),
      onSaved: (id, viewed) => saved.add((id, viewed)),
    );
    addTearDown(controller.dispose);
    controller.activate(_photo('current'));
    controller.imageDisplayed('prefetched', true);
    await tester.pump(const Duration(seconds: 2));
    expect(writes, isEmpty);

    controller.imageDisplayed('current', true);
    await tester.pump(const Duration(milliseconds: 999));
    expect(writes, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(writes, [('current', true)]);
    expect(saved, [('current', true)]);
    expect(controller.isViewed, isTrue);

    controller.imageDisplayed('current', false);
    controller.imageDisplayed('current', true);
    controller.activate(_photo('other'));
    controller.activate(_photo('current'));
    controller.imageDisplayed('current', true);
    await tester.pump(const Duration(seconds: 2));
    expect(writes, hasLength(1));
  });

  testWidgets(
    'quick page changes and failed image loads never count as viewed',
    (tester) async {
      final writes = <String>[];
      final controller = PhotoViewedController(
        writeViewed: (id, viewed) async => writes.add(id),
        onSaved: (_, _) {},
      );
      addTearDown(controller.dispose);
      controller.activate(_photo('quick'));
      controller.imageDisplayed('quick', true);
      await tester.pump(const Duration(milliseconds: 600));
      controller.activate(_photo('failed'));
      controller.imageDisplayed('failed', false);
      await tester.pump(const Duration(seconds: 2));
      expect(writes, isEmpty);
      controller.activate(_photo('settled'));
      controller.imageDisplayed('settled', true);
      await tester.pump(const Duration(seconds: 1));
      expect(writes, ['settled']);
    },
  );

  testWidgets('background or scrolling resets the entire viewing interval', (
    tester,
  ) async {
    final writes = <String>[];
    final controller = PhotoViewedController(
      writeViewed: (id, viewed) async => writes.add(id),
      onSaved: (_, _) {},
    );
    addTearDown(controller.dispose);
    controller.activate(_photo('photo'));
    controller.imageDisplayed('photo', true);
    await tester.pump(const Duration(milliseconds: 700));
    controller.setForeground(false);
    await tester.pump(const Duration(seconds: 2));
    expect(writes, isEmpty);
    controller.setForeground(true);
    await tester.pump(const Duration(milliseconds: 999));
    expect(writes, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(writes, ['photo']);
  });

  testWidgets(
    'save failure keeps the previous state and supports explicit retry',
    (tester) async {
      var attempts = 0;
      final saved = <bool>[];
      final controller = PhotoViewedController(
        writeViewed: (_, _) async {
          attempts++;
          if (attempts == 1) throw StateError('server unavailable');
        },
        onSaved: (_, viewed) => saved.add(viewed),
      );
      addTearDown(controller.dispose);
      controller.activate(_photo('photo'));
      controller.imageDisplayed('photo', true);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.isViewed, isFalse);
      expect(controller.error, isNotNull);
      expect(saved, isEmpty);
      controller.imageDisplayed('photo', false);
      controller.imageDisplayed('photo', true);
      await tester.pump(const Duration(seconds: 2));
      expect(attempts, 1);

      expect(await controller.markCurrent(viewed: true), isTrue);
      expect(controller.isViewed, isTrue);
      expect(controller.error, isNull);
      expect(saved, [true]);
      expect(attempts, 2);
    },
  );

  testWidgets(
    'manual unviewed remains unviewed after redisplay and navigation',
    (tester) async {
      final writes = <(String, bool)>[];
      final controller = PhotoViewedController(
        writeViewed: (id, viewed) async => writes.add((id, viewed)),
        onSaved: (_, _) {},
      );
      addTearDown(controller.dispose);
      controller.activate(_photo('photo', viewed: true));
      controller.imageDisplayed('photo', true);
      expect(await controller.markCurrent(viewed: false), isTrue);
      expect(controller.isViewed, isFalse);
      controller.setForeground(false);
      controller.setForeground(true);
      controller.activate(_photo('other'));
      controller.activate(_photo('photo', viewed: true));
      controller.imageDisplayed('photo', true);
      await tester.pump(const Duration(seconds: 2));
      expect(controller.isViewed, isFalse);
      expect(writes, [('photo', false)]);
    },
  );

  testWidgets('finish waits for in-flight writes and does not start new ones', (
    tester,
  ) async {
    final gate = Completer<void>();
    final saved = <String>[];
    final controller = PhotoViewedController(
      writeViewed: (_, _) => gate.future,
      onSaved: (id, _) => saved.add(id),
    );
    addTearDown(controller.dispose);
    controller.activate(_photo('photo'));
    controller.imageDisplayed('photo', true);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.isSaving, isTrue);
    expect(controller.isViewed, isFalse);
    var finished = false;
    final finishing = controller.finish().then((_) => finished = true);
    await tester.pump();
    expect(finished, isFalse);
    expect(await controller.markCurrent(viewed: false), isFalse);
    gate.complete();
    await tester.pump();
    await finishing;
    expect(saved, ['photo']);
    expect(controller.isViewed, isTrue);
    expect(controller.isSaving, isFalse);
  });

  testWidgets('disposing cancels a pending visibility timer', (tester) async {
    final writes = <String>[];
    final controller = PhotoViewedController(
      writeViewed: (id, viewed) async => writes.add(id),
      onSaved: (_, _) {},
    );
    controller.activate(_photo('photo'));
    controller.imageDisplayed('photo', true);
    await tester.pump(const Duration(milliseconds: 500));
    controller.dispose();
    await tester.pump(const Duration(seconds: 2));
    expect(writes, isEmpty);
  });

  testWidgets('finish bounds a stalled write and reports IDs needing refresh', (
    tester,
  ) async {
    final gate = Completer<void>();
    final saved = <String>[];
    final controller = PhotoViewedController(
      writeViewed: (_, _) => gate.future,
      onSaved: (id, _) => saved.add(id),
    );
    controller.activate(_photo('stalled'));
    controller.imageDisplayed('stalled', true);
    await tester.pump(const Duration(seconds: 1));
    final finishing = controller.finish();
    await tester.pump(const Duration(seconds: 3));
    expect(await finishing, {'stalled'});
    expect(controller.isViewed, isFalse);
    expect(saved, isEmpty);
    controller.dispose();
    gate.completeError(StateError('late failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

EmbyItem _photo(String id, {bool viewed = false}) => EmbyItem(
  id: id,
  name: id,
  type: 'Photo',
  imageTags: const {},
  backdropImageTags: const [],
  genres: const [],
  userData: EmbyUserData(isPlayed: viewed),
);
