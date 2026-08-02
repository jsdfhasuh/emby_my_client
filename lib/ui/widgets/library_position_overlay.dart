import 'package:flutter/material.dart';

import '../../library/library_scroll_position_controller.dart';

class LibraryPositionOverlay extends StatefulWidget {
  const LibraryPositionOverlay({
    super.key,
    required this.controller,
    this.fadeDuration = const Duration(milliseconds: 180),
  });

  final LibraryScrollPositionController controller;
  final Duration fadeDuration;

  @override
  State<LibraryPositionOverlay> createState() => _LibraryPositionOverlayState();
}

class _LibraryPositionOverlayState extends State<LibraryPositionOverlay> {
  bool _renderPanel = false;

  @override
  void initState() {
    super.initState();
    _renderPanel =
        widget.controller.isVisible && widget.controller.snapshot != null;
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(LibraryPositionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChanged);
    _renderPanel =
        widget.controller.isVisible && widget.controller.snapshot != null;
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    setState(() {
      if (widget.controller.snapshot == null) {
        _renderPanel = false;
      } else if (widget.controller.isVisible) {
        _renderPanel = true;
      }
    });
  }

  void _handleFadeEnd() {
    if (!mounted || widget.controller.isVisible || !_renderPanel) return;
    setState(() => _renderPanel = false);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        key: const ValueKey('library-position-ignore-pointer'),
        child: SafeArea(
          minimum: const EdgeInsets.only(right: 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: AnimatedOpacity(
              key: const ValueKey('library-position-overlay'),
              opacity: widget.controller.isVisible ? 1 : 0,
              duration: widget.fadeDuration,
              curve: Curves.easeOut,
              onEnd: _handleFadeEnd,
              child: _renderPanel && widget.controller.snapshot != null
                  ? _LibraryPositionPanel(snapshot: widget.controller.snapshot!)
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryPositionPanel extends StatelessWidget {
  const _LibraryPositionPanel({required this.snapshot});

  final LibraryPositionSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final percentage = snapshot.percentage;
    return Container(
      key: const ValueKey('library-position-panel'),
      constraints: const BoxConstraints(minWidth: 96),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.6)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2E000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${snapshot.firstVisible}\u2013${snapshot.lastVisible}',
            key: const ValueKey('library-position-range'),
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (snapshot.totalCount case final total?) ...[
            const SizedBox(height: 2),
            Text(
              '共 ${_formatCount(total)} 项',
              key: const ValueKey('library-position-total'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
          if (percentage != null) ...[
            const SizedBox(height: 2),
            Text(
              '$percentage%',
              key: const ValueKey('library-position-percentage'),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: colors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _formatCount(int value) {
  final digits = value.toString();
  final output = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) output.write(',');
    output.write(digits[index]);
  }
  return output.toString();
}
