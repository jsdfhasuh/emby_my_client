import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../library/library_alphabet_filter.dart';

class LibraryAlphabetNavigation extends StatefulWidget {
  const LibraryAlphabetNavigation({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final LibraryAlphabetFilter selected;
  final ValueChanged<LibraryAlphabetFilter> onSelected;

  @override
  State<LibraryAlphabetNavigation> createState() =>
      _LibraryAlphabetNavigationState();
}

class _LibraryAlphabetNavigationState extends State<LibraryAlphabetNavigation> {
  bool _expanded = false;
  LibraryAlphabetFilter? _preview;

  void _expand() {
    if (_expanded) return;
    setState(() => _expanded = true);
  }

  void _collapse() {
    if (!_expanded && _preview == null) return;
    setState(() {
      _expanded = false;
      _preview = null;
    });
  }

  void _showPreview(LibraryAlphabetFilter filter) {
    if (_preview == filter) return;
    setState(() => _preview = filter);
  }

  void _previewAt(double localY, double height) {
    if (height <= 0) return;
    final index = (localY / height * libraryAlphabetFilters.length)
        .floor()
        .clamp(0, libraryAlphabetFilters.length - 1);
    _showPreview(libraryAlphabetFilters[index]);
  }

  void _commit(LibraryAlphabetFilter filter) {
    setState(() {
      _expanded = false;
      _preview = null;
    });
    widget.onSelected(filter);
  }

  void _commitPreview() {
    final preview = _preview;
    if (preview == null) {
      _collapse();
      return;
    }
    _commit(preview);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      key: const ValueKey('library-alphabet-navigation'),
      child: SafeArea(
        minimum: const EdgeInsets.only(right: 8, top: 8, bottom: 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final railHeight = math.min(600.0, constraints.maxHeight);
            return Stack(
              children: [
                if (_expanded)
                  Positioned.fill(
                    child: GestureDetector(
                      key: const ValueKey('library-alphabet-barrier'),
                      behavior: HitTestBehavior.translucent,
                      onTap: _collapse,
                    ),
                  ),
                Align(
                  alignment: _expanded
                      ? Alignment.centerRight
                      : const Alignment(1, 0.55),
                  child: _expanded
                      ? _AlphabetRail(
                          height: railHeight,
                          selected: widget.selected,
                          preview: _preview,
                          onPreview: _showPreview,
                          onPreviewAt: _previewAt,
                          onCommit: _commit,
                          onCommitPreview: _commitPreview,
                          onCancelPreview: () {
                            if (_preview == null) return;
                            setState(() => _preview = null);
                          },
                        )
                      : _AlphabetButton(onPressed: _expand),
                ),
                if (_preview case final preview?)
                  IgnorePointer(
                    child: Center(child: _AlphabetPreview(filter: preview)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class LibraryAlphabetFilterChip extends StatelessWidget {
  const LibraryAlphabetFilterChip({
    super.key,
    required this.filter,
    required this.onClear,
  });

  final LibraryAlphabetFilter filter;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InputChip(
          key: const ValueKey('library-alphabet-filter-chip'),
          label: Text('首字母：${libraryAlphabetDisplayLabel(filter)}'),
          deleteIcon: const Icon(Icons.close, size: 18),
          deleteButtonTooltipMessage: '清除首字母筛选',
          onDeleted: onClear,
        ),
      ),
    );
  }
}

class _AlphabetButton extends StatelessWidget {
  const _AlphabetButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh.withValues(alpha: 0.96),
      elevation: 3,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: Tooltip(
        message: '按首字母筛选',
        child: Semantics(
          button: true,
          label: '按首字母筛选',
          child: InkWell(
            key: const ValueKey('library-alphabet-button'),
            onTap: onPressed,
            onLongPress: onPressed,
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.sort_by_alpha),
            ),
          ),
        ),
      ),
    );
  }
}

class _AlphabetRail extends StatelessWidget {
  const _AlphabetRail({
    required this.height,
    required this.selected,
    required this.preview,
    required this.onPreview,
    required this.onPreviewAt,
    required this.onCommit,
    required this.onCommitPreview,
    required this.onCancelPreview,
  });

  final double height;
  final LibraryAlphabetFilter selected;
  final LibraryAlphabetFilter? preview;
  final ValueChanged<LibraryAlphabetFilter> onPreview;
  final void Function(double localY, double height) onPreviewAt;
  final ValueChanged<LibraryAlphabetFilter> onCommit;
  final VoidCallback onCommitPreview;
  final VoidCallback onCancelPreview;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh.withValues(alpha: 0.98),
      elevation: 5,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        key: const ValueKey('library-alphabet-rail'),
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (details) =>
            onPreviewAt(details.localPosition.dy, height),
        onVerticalDragUpdate: (details) =>
            onPreviewAt(details.localPosition.dy, height),
        onVerticalDragEnd: (_) => onCommitPreview(),
        onVerticalDragCancel: onCancelPreview,
        child: MouseRegion(
          onHover: (event) => onPreviewAt(event.localPosition.dy, height),
          onExit: (_) => onCancelPreview(),
          child: SizedBox(
            width: 46,
            height: height,
            child: Column(
              children: [
                for (final filter in libraryAlphabetFilters)
                  Expanded(
                    child: _AlphabetOption(
                      filter: filter,
                      selected: selected == filter,
                      previewed: preview == filter,
                      onPreview: () => onPreview(filter),
                      onCommit: () => onCommit(filter),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AlphabetOption extends StatelessWidget {
  const _AlphabetOption({
    required this.filter,
    required this.selected,
    required this.previewed,
    required this.onPreview,
    required this.onCommit,
  });

  final LibraryAlphabetFilter filter;
  final bool selected;
  final bool previewed;
  final VoidCallback onPreview;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = libraryAlphabetDisplayLabel(filter);
    return Semantics(
      button: true,
      selected: selected,
      label: filter.isAll ? '全部首字母' : '首字母 $label',
      child: InkWell(
        key: ValueKey('library-alphabet-option-${_filterKey(filter)}'),
        onTapDown: (_) => onPreview(),
        onTap: onCommit,
        child: ColoredBox(
          color: previewed
              ? colors.primaryContainer
              : selected
              ? colors.secondaryContainer
              : Colors.transparent,
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                color: previewed
                    ? colors.onPrimaryContainer
                    : selected
                    ? colors.onSecondaryContainer
                    : colors.onSurfaceVariant,
                fontSize: 10,
                height: 1,
                fontWeight: previewed || selected
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AlphabetPreview extends StatelessWidget {
  const _AlphabetPreview({required this.filter});

  final LibraryAlphabetFilter filter;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = libraryAlphabetDisplayLabel(filter);
    return Container(
      key: const ValueKey('library-alphabet-preview'),
      width: 96,
      height: 96,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
        boxShadow: const [
          BoxShadow(
            color: Color(0x3D000000),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        label,
        key: const ValueKey('library-alphabet-preview-label'),
        style: Theme.of(context).textTheme.displaySmall?.copyWith(
          fontSize: filter.isAll ? 24 : 48,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String libraryAlphabetDisplayLabel(LibraryAlphabetFilter filter) =>
    switch (filter) {
      AllItems() => '全部',
      SymbolsItems() => '#',
      LetterItems(:final letter) => letter,
    };

String _filterKey(LibraryAlphabetFilter filter) => switch (filter) {
  AllItems() => 'all',
  SymbolsItems() => 'symbols',
  LetterItems(:final letter) => letter.toLowerCase(),
};
