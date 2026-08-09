import 'package:emby_my_client/library/library_raw_page_cursor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('known totals advance by raw rows and complete at the total', () {
    final first = advanceLibraryRawPageCursor(
      currentStartIndex: 0,
      rawItemCount: 60,
      pageSize: 60,
      reportedTotalCount: 61,
    );
    expect(first.nextStartIndex, 60);
    expect(first.totalCount, 61);
    expect(first.disposition, LibraryRawPageDisposition.hasMore);

    final last = advanceLibraryRawPageCursor(
      currentStartIndex: first.nextStartIndex,
      currentTotalCount: first.totalCount,
      rawItemCount: 1,
      pageSize: 60,
    );
    expect(last.nextStartIndex, 61);
    expect(last.disposition, LibraryRawPageDisposition.complete);
  });

  test('known-total empty page stalls without moving its retry cursor', () {
    final result = advanceLibraryRawPageCursor(
      currentStartIndex: 60,
      currentTotalCount: 61,
      reportedTotalCount: 61,
      rawItemCount: 0,
      pageSize: 60,
    );

    expect(result.nextStartIndex, 60);
    expect(result.hasMore, isFalse);
    expect(result.paginationStalled, isTrue);
  });

  test('unknown totals use full and short raw pages as the contract', () {
    final full = advanceLibraryRawPageCursor(
      currentStartIndex: 0,
      rawItemCount: 60,
      pageSize: 60,
    );
    final short = advanceLibraryRawPageCursor(
      currentStartIndex: 60,
      rawItemCount: 12,
      pageSize: 60,
    );
    final empty = advanceLibraryRawPageCursor(
      currentStartIndex: 72,
      rawItemCount: 0,
      pageSize: 60,
    );

    expect(full.disposition, LibraryRawPageDisposition.hasMore);
    expect(short.disposition, LibraryRawPageDisposition.complete);
    expect(empty.disposition, LibraryRawPageDisposition.complete);
  });

  test('a changed reported total permanently marks the result dirty', () {
    final changed = advanceLibraryRawPageCursor(
      currentStartIndex: 60,
      currentTotalCount: 120,
      reportedTotalCount: 121,
      rawItemCount: 60,
      pageSize: 60,
    );
    final next = advanceLibraryRawPageCursor(
      currentStartIndex: changed.nextStartIndex,
      currentTotalCount: changed.totalCount,
      reportedTotalCount: 121,
      rawItemCount: 1,
      pageSize: 60,
      dirty: changed.dirty,
    );

    expect(changed.totalChanged, isTrue);
    expect(changed.dirty, isTrue);
    expect(next.totalChanged, isFalse);
    expect(next.dirty, isTrue);
  });

  test('invalid cursor inputs fail before any pagination decision', () {
    expect(
      () => advanceLibraryRawPageCursor(
        currentStartIndex: -1,
        rawItemCount: 0,
        pageSize: 60,
      ),
      throwsArgumentError,
    );
    expect(
      () => advanceLibraryRawPageCursor(
        currentStartIndex: 0,
        rawItemCount: -1,
        pageSize: 60,
      ),
      throwsArgumentError,
    );
    expect(
      () => advanceLibraryRawPageCursor(
        currentStartIndex: 0,
        rawItemCount: 0,
        pageSize: 0,
      ),
      throwsArgumentError,
    );
  });
}
