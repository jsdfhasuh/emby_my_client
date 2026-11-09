import 'package:flutter/material.dart';

import '../../library/library_watch_status.dart';

/// Shared overlays keep directory, mixed-media and photo cards consistent.
class LibraryWatchStatusOverlay extends StatelessWidget {
  const LibraryWatchStatusOverlay({
    super.key,
    required this.status,
    required this.isFavorite,
  });

  final LibraryWatchStatus? status;
  final bool isFavorite;

  @override
  Widget build(BuildContext context) {
    final currentStatus = status;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (isFavorite)
              const Positioned(
                top: 8,
                left: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xDD9A3D46),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(5),
                    child: Icon(Icons.favorite, size: 15, color: Colors.white),
                  ),
                ),
              ),
            if (currentStatus != null)
              Positioned(
                top: 8,
                left: isFavorite ? 42 : 8,
                right: 8,
                child: Align(
                  alignment: Alignment.topRight,
                  child: LibraryWatchStatusBadge(status: currentStatus),
                ),
              ),
            if (currentStatus?.progress case final progress?)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  key: const ValueKey('library-watch-progress'),
                  value: progress,
                  minHeight: 4,
                  color: const Color(0xFFFFC35C),
                  backgroundColor: Colors.black54,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class LibraryWatchStatusBadge extends StatelessWidget {
  const LibraryWatchStatusBadge({super.key, required this.status});

  final LibraryWatchStatus status;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (status.state) {
      LibraryWatchState.unwatched => (
        const Color(0xED30383E),
        status.isPhoto
            ? Icons.visibility_off_outlined
            : Icons.play_circle_outline,
      ),
      LibraryWatchState.inProgress => (
        const Color(0xED754C10),
        Icons.timelapse,
      ),
      LibraryWatchState.watched => (
        const Color(0xED20644F),
        status.isPhoto ? Icons.visibility_outlined : Icons.check,
      ),
    };
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.topRight,
      child: DecoratedBox(
        key: const ValueKey('library-watch-status'),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                status.label,
                maxLines: 1,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reserves room for the status badge and fits metadata in compact grid cells.
class LibraryEntryCardCaption extends StatelessWidget {
  const LibraryEntryCardCaption({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.hasTopBadge,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool hasTopBadge;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 12,
    right: 12,
    top: hasTopBadge ? 48 : 8,
    bottom: 10,
    child: LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.bottomLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.bottomLeft,
          child: SizedBox(
            width: constraints.maxWidth,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Icon(icon, size: 20, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFD7DEE1),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
