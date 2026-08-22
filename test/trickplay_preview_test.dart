import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:emby_my_client/data/emby_api.dart';
import 'package:emby_my_client/models/emby_models.dart';
import 'package:emby_my_client/playback/trickplay/trickplay_detail_hydrator.dart';
import 'package:emby_my_client/playback/trickplay/trickplay_frame_resolver.dart';
import 'package:emby_my_client/playback/trickplay/trickplay_preview_controller.dart';
import 'package:emby_my_client/ui/widgets/trickplay_preview.dart';
import 'package:emby_my_client/ui/widgets/horizontal_seek_preview_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TrickplayFrameResolver', () {
    const resolution = EmbyTrickplayResolution(
      width: 320,
      height: 180,
      tileColumns: 2,
      tileRows: 2,
      intervalMilliseconds: 10000,
      thumbnailCount: 5,
    );

    test('maps zero, interval, same-sheet, and cross-sheet boundaries', () {
      final duration = const Duration(seconds: 60);

      expect(
        TrickplayFrameResolver.resolve(
          position: Duration.zero,
          duration: duration,
          resolution: resolution,
        ),
        _frame(sheetIndex: 0, tileIndex: 0, column: 0, row: 0),
      );
      expect(
        TrickplayFrameResolver.resolve(
          position: const Duration(seconds: 10),
          duration: duration,
          resolution: resolution,
        ),
        _frame(sheetIndex: 0, tileIndex: 1, column: 1, row: 0),
      );
      expect(
        TrickplayFrameResolver.resolve(
          position: const Duration(milliseconds: 39999),
          duration: duration,
          resolution: resolution,
        ),
        _frame(sheetIndex: 0, tileIndex: 3, column: 1, row: 1),
      );
      expect(
        TrickplayFrameResolver.resolve(
          position: const Duration(milliseconds: 40000),
          duration: duration,
          resolution: resolution,
        ),
        _frame(sheetIndex: 1, tileIndex: 4, column: 0, row: 0),
      );
    });

    test('bounds the final partial sheet by ThumbnailCount', () {
      final frame = TrickplayFrameResolver.resolve(
        position: const Duration(seconds: 59),
        duration: const Duration(seconds: 60),
        resolution: resolution,
      );

      expect(frame, isNotNull);
      expect(frame!.tileIndex, 4);
      expect(frame.sheetIndex, 1);
      expect(frame.column, 0);
      expect(frame.row, 0);
      expect(frame.samplePosition, const Duration(seconds: 40));
    });

    test('uses duration bounds when ThumbnailCount is absent', () {
      const withoutCount = EmbyTrickplayResolution(
        width: 320,
        height: 180,
        tileColumns: 2,
        tileRows: 2,
        intervalMilliseconds: 10000,
      );

      final frame = TrickplayFrameResolver.resolve(
        position: const Duration(seconds: 60),
        duration: const Duration(seconds: 60),
        resolution: withoutCount,
      );

      expect(frame?.tileIndex, 5);
      expect(frame?.sheetIndex, 1);
      expect(frame?.column, 1);
      expect(frame?.row, 0);
    });

    test(
      'clamps negative and oversized positions and handles large values',
      () {
        expect(
          TrickplayFrameResolver.resolve(
            position: const Duration(seconds: -1),
            duration: const Duration(seconds: 60),
            resolution: resolution,
          )?.tileIndex,
          0,
        );
        expect(
          TrickplayFrameResolver.resolve(
            position: const Duration(hours: 100000),
            duration: const Duration(seconds: 60),
            resolution: resolution,
          )?.tileIndex,
          4,
        );
      },
    );

    test('rejects invalid grid, interval, duration, and count values', () {
      final invalids = [
        resolution.copyWithForTest(tileColumns: 0),
        resolution.copyWithForTest(tileRows: 0),
        resolution.copyWithForTest(intervalMilliseconds: 0),
        resolution.copyWithForTest(thumbnailCount: 0),
      ];

      for (final invalid in invalids) {
        expect(
          TrickplayFrameResolver.resolve(
            position: Duration.zero,
            duration: const Duration(seconds: 1),
            resolution: invalid,
          ),
          isNull,
        );
      }
      expect(
        TrickplayFrameResolver.resolve(
          position: Duration.zero,
          duration: Duration.zero,
          resolution: resolution,
        ),
        isNull,
      );
    });
  });

  group('TrickplayPreviewController', () {
    test('does not present an old sheet with new coordinates', () async {
      final controller = TrickplayPreviewController<String>();
      final firstLoad = Completer<String>();
      final secondLoad = Completer<String>();
      final first = _request(sheetIndex: 0, tileIndex: 1);
      final second = _request(sheetIndex: 1, tileIndex: 2);

      final firstRequest = controller.request(
        request: first,
        load: (_) => firstLoad.future,
      );
      await Future<void>.delayed(Duration.zero);
      firstLoad.complete('sheet-a');
      await firstRequest;
      expect(controller.state.sheet, 'sheet-a');
      expect(controller.state.frame, first.frame);

      final secondRequest = controller.request(
        request: second,
        load: (_) => secondLoad.future,
      );
      expect(controller.state.status, TrickplayPreviewStatus.loading);
      expect(controller.state.sheet, isNull);
      expect(controller.state.frame, isNull);

      secondLoad.complete('sheet-b');
      await secondRequest;
      expect(controller.state.status, TrickplayPreviewStatus.ready);
      expect(controller.state.sheet, 'sheet-b');
      expect(controller.state.frame, second.frame);
    });

    test('latest request wins when an older request completes last', () async {
      final controller = TrickplayPreviewController<String>();
      final oldLoad = Completer<String>();
      final newLoad = Completer<String>();

      final oldRequest = controller.request(
        request: _request(sheetIndex: 0, tileIndex: 0),
        load: (_) => oldLoad.future,
      );
      final newFrame = _request(sheetIndex: 1, tileIndex: 0);
      final newRequest = controller.request(
        request: newFrame,
        load: (_) => newLoad.future,
      );

      newLoad.complete('new-sheet');
      await newRequest;
      oldLoad.complete('old-sheet');
      await oldRequest;

      expect(controller.state.sheet, 'new-sheet');
      expect(controller.state.frame, newFrame.frame);
    });

    test('a new scrub session invalidates the previous request', () async {
      final controller = TrickplayPreviewController<String>();
      final load = Completer<String>();
      final request = controller.request(
        request: _request(sheetIndex: 0, tileIndex: 0),
        load: (_) => load.future,
      );

      controller.beginScrubSession();
      load.complete('stale-sheet');
      await request;

      expect(controller.state.status, TrickplayPreviewStatus.idle);
      expect(controller.state.sheet, isNull);
    });

    test(
      'reset and dispose invalidate stale results without notifying again',
      () async {
        final controller = TrickplayPreviewController<String>();
        final load = Completer<String>();
        var notifications = 0;
        controller.addListener((_) => notifications++);
        final request = controller.request(
          request: _request(sheetIndex: 0, tileIndex: 0),
          load: (_) => load.future,
        );
        controller.resetResource();
        final afterReset = notifications;
        controller.dispose();
        load.complete('stale-sheet');
        await request;

        expect(controller.state.sheet, isNull);
        expect(notifications, afterReset);
      },
    );

    test(
      'loader failures become an unavailable preview state per scrub session',
      () async {
        final controller = TrickplayPreviewController<String>();
        var attempts = 0;

        await controller.request(
          request: _request(sheetIndex: 0, tileIndex: 0),
          load: (_) {
            attempts++;
            return Future<String>.error(StateError('decode failure'));
          },
        );
        await controller.request(
          request: _request(sheetIndex: 0, tileIndex: 1),
          load: (_) {
            attempts++;
            return Future<String>.error(StateError('decode failure'));
          },
        );

        expect(controller.state.status, TrickplayPreviewStatus.unavailable);
        expect(controller.state.sheet, isNull);
        expect(controller.state.frame, isNull);
        expect(attempts, 1);

        controller.beginScrubSession();
        await controller.request(
          request: _request(sheetIndex: 0, tileIndex: 2),
          load: (_) {
            attempts++;
            return Future<String>.error(StateError('decode failure'));
          },
        );
        expect(attempts, 2);
      },
    );
  });

  group('TrickplayDetailHydrator', () {
    test('requests each item at most once and resolves detail', () async {
      var requests = 0;
      EmbyItem? resolved;
      final hydrator = TrickplayDetailHydrator(
        fetch: (_) async {
          requests++;
          return _detailItem;
        },
      );

      await Future.wait([
        hydrator.hydrate(
          item: _plainItem,
          isCurrent: () => true,
          onResolved: (item) => resolved = item,
        ),
        hydrator.hydrate(
          item: _plainItem,
          isCurrent: () => true,
          onResolved: (item) => resolved = item,
        ),
      ]);

      expect(requests, 1);
      expect(resolved?.trickplay, isNotNull);
    });

    test('drops a detail result after the current item changes', () async {
      final response = Completer<EmbyItem>();
      var current = true;
      EmbyItem? resolved;
      final hydrator = TrickplayDetailHydrator(fetch: (_) => response.future);
      final request = hydrator.hydrate(
        item: _plainItem,
        isCurrent: () => current,
        onResolved: (item) => resolved = item,
      );

      current = false;
      response.complete(_detailItem);
      await request;

      expect(resolved, isNull);
    });

    test(
      'does not turn a failed detail request into a playback failure',
      () async {
        Object? failure;
        final hydrator = TrickplayDetailHydrator(
          fetch: (_) => Future<EmbyItem>.error(StateError('offline')),
        );

        await hydrator.hydrate(
          item: _plainItem,
          isCurrent: () => true,
          onResolved: (_) => fail('detail must not resolve'),
          onFailure: (error) => failure = error,
        );

        expect(failure, isA<StateError>());
      },
    );
  });

  test('decodes and selects all cells of a deterministic 2x2 sprite', () async {
    final codec = await ui.instantiateImageCodec(_spriteBytes());
    final frame = await codec.getNextFrame();
    final data = (await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    const colors = [
      Color(0xFFFF0000),
      Color(0xFF00FF00),
      Color(0xFF0000FF),
      Color(0xFFFFFF00),
    ];
    const cells = [(0, 0), (1, 0), (0, 1), (1, 1)];

    for (var index = 0; index < cells.length; index++) {
      final (column, row) = cells[index];
      final alignment = trickplayCellAlignment(
        columns: 2,
        rows: 2,
        column: column,
        row: row,
      );
      expect(alignment.x, column == 0 ? -1 : 1);
      expect(alignment.y, row == 0 ? -1 : 1);
      final sourceX = column * 8 + 4;
      final sourceY = row * 8 + 4;
      final offset = ((sourceY * 16) + sourceX) * 4;
      final actual = Color.fromARGB(
        data[offset + 3],
        data[offset],
        data[offset + 1],
        data[offset + 2],
      );
      expect(actual, colors[index]);
    }
    frame.image.dispose();
    codec.dispose();
  });

  testWidgets('renders time fallback without Trickplay', (tester) async {
    final api = EmbyApi(_session, dio: Dio());
    addTearDown(api.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: HorizontalSeekPreviewOverlay(
          api: api,
          item: _plainItem,
          plan: null,
          playerItemGeneration: 'item-generation',
          startPosition: Duration.zero,
          targetPosition: const Duration(seconds: 5),
          duration: const Duration(minutes: 1),
          horizontalDragDx: 10,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('+5 秒'), findsOneWidget);
    expect(find.text('0:05 / 1:00'), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
  });
}

TrickplayFrame _frame({
  required int sheetIndex,
  required int tileIndex,
  required int column,
  required int row,
}) => TrickplayFrame(
  sheetIndex: sheetIndex,
  tileIndex: tileIndex,
  column: column,
  row: row,
  samplePosition: Duration(seconds: tileIndex * 10),
);

TrickplayPreviewRequest _request({
  required int sheetIndex,
  required int tileIndex,
}) {
  final frame = _frame(
    sheetIndex: sheetIndex,
    tileIndex: tileIndex,
    column: tileIndex % 2,
    row: (tileIndex ~/ 2) % 2,
  );
  return TrickplayPreviewRequest(
    identity: TrickplaySheetIdentity(
      playerItemGeneration: 'item-generation',
      itemId: 'item-1',
      mediaSourceId: 'source-1',
      resolutionWidth: 320,
      sheetIndex: sheetIndex,
    ),
    frame: frame,
  );
}

Uint8List _spriteBytes() {
  final rows = <List<int>>[];
  const colors = [
    [255, 0, 0, 255],
    [0, 255, 0, 255],
    [0, 0, 255, 255],
    [255, 255, 0, 255],
  ];
  for (var y = 0; y < 16; y++) {
    final row = <int>[0];
    for (var x = 0; x < 16; x++) {
      final color = colors[(x ~/ 8) + (y ~/ 8) * 2];
      row.addAll(color);
    }
    rows.add(row);
  }
  final raw = rows.expand((row) => row).toList(growable: false);
  final compressed = ZLibCodec().encode(raw);
  return _png(width: 16, height: 16, compressedData: compressed);
}

Uint8List _png({
  required int width,
  required int height,
  required List<int> compressedData,
}) {
  final output = BytesBuilder();
  output.add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  output.add(
    _pngChunk('IHDR', [..._u32(width), ..._u32(height), 8, 6, 0, 0, 0]),
  );
  output.add(_pngChunk('IDAT', compressedData));
  output.add(_pngChunk('IEND', const []));
  return output.toBytes();
}

List<int> _pngChunk(String type, List<int> data) {
  final typeBytes = type.codeUnits;
  return [
    ..._u32(data.length),
    ...typeBytes,
    ...data,
    ..._u32(_crc32([...typeBytes, ...data])),
  ];
}

List<int> _u32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff).toUnsigned(32);
}

extension on EmbyTrickplayResolution {
  EmbyTrickplayResolution copyWithForTest({
    int? tileColumns,
    int? tileRows,
    int? intervalMilliseconds,
    int? thumbnailCount,
  }) => EmbyTrickplayResolution(
    width: width,
    height: height,
    tileColumns: tileColumns ?? this.tileColumns,
    tileRows: tileRows ?? this.tileRows,
    intervalMilliseconds: intervalMilliseconds ?? this.intervalMilliseconds,
    thumbnailCount: thumbnailCount ?? this.thumbnailCount,
  );
}

const _plainItem = EmbyItem(
  id: 'item-1',
  name: 'Item',
  type: 'Movie',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
);

const _session = EmbySession(
  serverUrl: 'https://emby.example.test',
  serverName: 'Test Emby',
  serverId: 'server-1',
  userId: 'user-1',
  username: 'tester',
  accessToken: 'access-token',
  deviceId: 'device-1',
);

const _detailItem = EmbyItem(
  id: 'item-1',
  name: 'Item',
  type: 'Movie',
  imageTags: {},
  backdropImageTags: [],
  genres: [],
  userData: EmbyUserData(),
  trickplay: EmbyTrickplay({
    'source-1': [
      EmbyTrickplayResolution(
        width: 320,
        height: 180,
        tileColumns: 2,
        tileRows: 2,
        intervalMilliseconds: 10000,
      ),
    ],
  }),
);
