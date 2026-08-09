import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openLibraryFilter(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('library-filter-button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> applyLibraryFilter(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('library-filter-apply')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> selectLibraryMediaType(
  WidgetTester tester,
  String mediaType,
) async {
  await tester.tap(find.byKey(ValueKey('library-media-type-$mediaType')));
  await tester.pump();
}

Future<void> selectLibraryLocalFilter(
  WidgetTester tester,
  String localFilter,
) async {
  await tester.tap(find.byKey(ValueKey('library-filter-$localFilter')));
  await tester.pump();
}

Future<void> selectLibraryPlayedFilter(
  WidgetTester tester,
  String playedFilter,
) async {
  await tester.tap(find.byKey(ValueKey('library-played-$playedFilter')));
  await tester.pump();
}
