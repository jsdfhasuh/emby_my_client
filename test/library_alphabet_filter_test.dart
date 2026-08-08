import 'package:emby_my_client/library/library_alphabet_filter.dart';
import 'package:emby_my_client/library/library_browse_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes letters and compares alphabet filters by value', () {
    expect(LetterItems(' m '), LetterItems('M'));
    expect(LetterItems('m').hashCode, LetterItems('M').hashCode);
    expect(LetterItems('z').nameStartsWith, 'Z');
    expect(LetterItems('z').nameLessThan, isNull);
    expect(const SymbolsItems().nameStartsWith, isNull);
    expect(const SymbolsItems().nameLessThan, 'A');
    expect(const AllItems().isAll, isTrue);
    expect(const SymbolsItems().isAll, isFalse);
  });

  test('rejects non-ASCII and multi-character letters', () {
    for (final value in ['', '#', 'AB', 'é', '中']) {
      expect(() => LetterItems(value), throwsArgumentError);
    }
  });

  test(
    'library state includes alphabet state in equality and filter count',
    () {
      final lower = LibraryBrowseState(alphabetFilter: LetterItems('m'));
      final upper = LibraryBrowseState(alphabetFilter: LetterItems('M'));
      const all = LibraryBrowseState();

      expect(lower, upper);
      expect(lower.activeFilterCount, 1);
      expect(all.activeFilterCount, 0);
      expect(
        lower.copyWith(alphabetFilter: const AllItems()),
        const LibraryBrowseState(),
      );
    },
  );
}
