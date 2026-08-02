sealed class LibraryAlphabetFilter {
  const LibraryAlphabetFilter();

  String? get nameStartsWith;
  String? get nameLessThan;
  Object? get _equalityValue;

  bool get isAll => this is AllItems;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryAlphabetFilter &&
          runtimeType == other.runtimeType &&
          _equalityValue == other._equalityValue;

  @override
  int get hashCode => Object.hash(runtimeType, _equalityValue);
}

final class AllItems extends LibraryAlphabetFilter {
  const AllItems();

  @override
  String? get nameStartsWith => null;

  @override
  String? get nameLessThan => null;

  @override
  Object? get _equalityValue => null;
}

final class SymbolsItems extends LibraryAlphabetFilter {
  const SymbolsItems();

  @override
  String? get nameStartsWith => null;

  @override
  String get nameLessThan => 'A';

  @override
  Object get _equalityValue => '#';
}

final class LetterItems extends LibraryAlphabetFilter {
  factory LetterItems(String letter) =>
      LetterItems._(normalizeLibraryAlphabetLetter(letter));

  const LetterItems._(this.letter);

  final String letter;

  @override
  String get nameStartsWith => letter;

  @override
  String? get nameLessThan => null;

  @override
  Object get _equalityValue => letter;
}

final List<LibraryAlphabetFilter> libraryAlphabetFilters = List.unmodifiable([
  const AllItems(),
  const SymbolsItems(),
  for (var code = 65; code <= 90; code++)
    LetterItems(String.fromCharCode(code)),
]);

String normalizeLibraryAlphabetLetter(String value) {
  final normalized = value.trim().toUpperCase();
  if (normalized.length != 1) {
    throw ArgumentError.value(value, 'letter', 'Expected one ASCII letter.');
  }
  final code = normalized.codeUnitAt(0);
  if (code < 65 || code > 90) {
    throw ArgumentError.value(value, 'letter', 'Expected one ASCII letter.');
  }
  return normalized;
}
