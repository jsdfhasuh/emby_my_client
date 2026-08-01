import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../images/emby_image_cache.dart';
import '../../images/emby_image_request.dart';
import '../../models/emby_models.dart';

class EmbyImage extends StatelessWidget {
  const EmbyImage({
    super.key,
    required this.request,
    this.fit = BoxFit.cover,
    this.icon = Icons.movie_outlined,
    this.alignment = Alignment.center,
    this.fadeInDuration = const Duration(milliseconds: 180),
  });

  final EmbyImageRequest? request;
  final BoxFit fit;
  final IconData icon;
  final Alignment alignment;
  final Duration fadeInDuration;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: const Color(0xFF202629),
      child: Center(
        child: Icon(icon, color: const Color(0xFF70797D), size: 32),
      ),
    );
    final imageRequest = request;
    if (imageRequest == null) return placeholder;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? (constraints.maxWidth * dpr).round()
            : imageRequest.decodeWidth;
        final maxHeight = constraints.maxHeight.isFinite
            ? (constraints.maxHeight * dpr).round()
            : imageRequest.decodeHeight;
        final cacheWidth = maxWidth.clamp(64, imageRequest.decodeWidth);
        final cacheHeight = maxHeight.clamp(64, imageRequest.decodeHeight);
        return CachedNetworkImage(
          imageUrl: imageRequest.uri.toString(),
          httpHeaders: imageRequest.headers,
          cacheKey: imageRequest.cacheKey,
          cacheManager: embyImageCacheManager,
          errorListener: imageRequest.errorListener,
          memCacheWidth: cacheWidth,
          memCacheHeight: cacheHeight,
          fit: fit,
          alignment: alignment,
          fadeInDuration: fadeInDuration,
          placeholder: (_, _) => placeholder,
          errorWidget: (_, _, _) => placeholder,
        );
      },
    );
  }
}

class MediaPosterCard extends StatelessWidget {
  const MediaPosterCard({
    super.key,
    required this.item,
    required this.imageRequest,
    required this.onTap,
    this.width = 132,
  });

  final EmbyItem item;
  final EmbyImageRequest? imageRequest;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    EmbyImage(request: imageRequest),
                    if (item.userData.isPlayed)
                      const Positioned(
                        top: 7,
                        right: 7,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0xDD55B948),
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.check, size: 14),
                          ),
                        ),
                      ),
                    if (item.userData.isFavorite)
                      const Positioned(
                        top: 7,
                        left: 7,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0xDD9A3D46),
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.favorite, size: 14),
                          ),
                        ),
                      ),
                    if (item.isStrm)
                      Positioned(
                        left: 7,
                        bottom: item.progress > 0 && item.progress < 1 ? 9 : 7,
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0xD9000000),
                            borderRadius: BorderRadius.all(Radius.circular(3)),
                          ),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            child: Text(
                              'STRM',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (item.progress > 0 && item.progress < 1)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: item.progress,
                          minHeight: 4,
                          backgroundColor: Colors.black54,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              item.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF9DA6A9)),
            ),
          ],
        ),
      ),
    );
  }
}

class MediaGrid extends StatelessWidget {
  const MediaGrid({
    super.key,
    required this.items,
    required this.imageRequestFor,
    required this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.shrinkWrap = false,
    this.physics,
  });

  final List<EmbyItem> items;
  final EmbyImageRequest? Function(EmbyItem item) imageRequestFor;
  final ValueChanged<EmbyItem> onTap;
  final EdgeInsets padding;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: padding,
      shrinkWrap: shrinkWrap,
      physics: physics,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.52,
        crossAxisSpacing: 12,
        mainAxisSpacing: 18,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return MediaPosterCard(
          item: item,
          width: double.infinity,
          imageRequest: imageRequestFor(item),
          onTap: () => onTap(item),
        );
      },
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
  });

  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: const Color(0xFF778084)),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (message != null) ...[
              const SizedBox(height: 7),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF9DA6A9)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              size: 42,
              color: Color(0xFFE2A93B),
            ),
            const SizedBox(height: 14),
            Text(
              error.toString(),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFC8CECF)),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
