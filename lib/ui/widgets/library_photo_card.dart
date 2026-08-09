import 'package:flutter/material.dart';

import '../../images/emby_image_request.dart';
import '../../models/emby_models.dart';
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
    return Semantics(
      button: true,
      label: '查看图片：${item.name}',
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
              if (item.userData.isFavorite)
                const Positioned(top: 8, left: 8, child: _PhotoFavoriteBadge()),
              Positioned(
                left: 12,
                right: 12,
                bottom: 10,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Icon(
                      Icons.image_outlined,
                      size: 20,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Text(
                            '图片',
                            maxLines: 1,
                            style: TextStyle(
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
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoFavoriteBadge extends StatelessWidget {
  const _PhotoFavoriteBadge();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(color: Color(0xDD9A3D46), shape: BoxShape.circle),
    child: Padding(
      padding: EdgeInsets.all(5),
      child: Icon(Icons.favorite, size: 15, color: Colors.white),
    ),
  );
}
