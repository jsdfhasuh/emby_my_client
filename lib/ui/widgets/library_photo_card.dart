import 'package:flutter/material.dart';

import '../../images/emby_image_request.dart';
import '../../models/emby_models.dart';
import '../../library/library_watch_status.dart';
import 'library_watch_status_badge.dart';
import 'media_widgets.dart';

class LibraryPhotoCard extends StatelessWidget {
  const LibraryPhotoCard({
    super.key,
    required this.item,
    required this.imageRequest,
    required this.onTap,
  });

  final EmbyItem item;
  final EmbyImageRequest? imageRequest;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final request = imageRequest;
    final status = LibraryWatchStatus.forItem(item);
    return Semantics(
      button: true,
      label: '查看图片：${item.name}${status == null ? '' : '，${status.label}'}',
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (request != null) ...[
                ColorFiltered(
                  key: const ValueKey('library-photo-image-underlay'),
                  colorFilter: const ColorFilter.mode(
                    Color(0x99000000),
                    BlendMode.darken,
                  ),
                  child: EmbyImage(request: request, fit: BoxFit.cover),
                ),
                EmbyImage(
                  key: const ValueKey('library-photo-image-foreground'),
                  request: request,
                  fit: BoxFit.contain,
                  icon: Icons.image_outlined,
                ),
              ] else
                ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.image_outlined, size: 42),
                ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xE6000000)],
                  ),
                ),
              ),
              LibraryWatchStatusOverlay(
                status: status,
                isFavorite: item.userData.isFavorite,
              ),
              LibraryEntryCardCaption(
                title: item.name,
                subtitle: '图片',
                icon: Icons.image_outlined,
                hasTopBadge: status != null || item.userData.isFavorite,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
