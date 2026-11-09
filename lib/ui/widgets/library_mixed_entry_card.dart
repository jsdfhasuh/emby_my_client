import 'package:flutter/material.dart';

import '../../images/emby_image_request.dart';
import '../../models/emby_models.dart';
import '../../library/library_watch_status.dart';
import 'library_watch_status_badge.dart';
import 'media_widgets.dart';

class LibraryMixedEntryCard extends StatelessWidget {
  const LibraryMixedEntryCard({
    super.key,
    required this.item,
    required this.imageRequest,
    required this.onTap,
  });

  final EmbyItem item;
  final EmbyImageRequest? imageRequest;
  final VoidCallback onTap;

  IconData get icon => switch (item.type) {
    'Folder' || 'CollectionFolder' => Icons.folder_outlined,
    'PhotoAlbum' => Icons.photo_album_outlined,
    'Photo' => Icons.image_outlined,
    'Movie' => Icons.movie_outlined,
    'Series' => Icons.tv_outlined,
    'Episode' => Icons.play_circle_outline,
    'Video' => Icons.videocam_outlined,
    _ => Icons.insert_drive_file_outlined,
  };

  String get subtitle => switch (item.type) {
    'Folder' || 'CollectionFolder' => '目录',
    'PhotoAlbum' => '相册',
    'Photo' => '图片',
    'Movie' => item.productionYear?.toString() ?? '电影',
    'Series' when item.userData.unplayedItemCount > 0 =>
      '${item.userData.unplayedItemCount} 集未播放',
    'Series' => item.productionYear?.toString() ?? '剧集',
    'Episode' => item.subtitle.isEmpty ? '单集' : item.subtitle,
    'Video' => item.runtimeLabel ?? item.productionYear?.toString() ?? '视频',
    _ => '媒体',
  };

  @override
  Widget build(BuildContext context) {
    final request = imageRequest;
    final status = LibraryWatchStatus.forItem(item);
    final action = item.isFolder
        ? '打开目录'
        : item.isPhoto
        ? '查看图片'
        : '查看媒体';
    return Semantics(
      button: true,
      label: '$action：${item.name}${status == null ? '' : '，${status.label}'}',
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (request != null) ...[
                ColorFiltered(
                  key: const ValueKey('library-mixed-image-underlay'),
                  colorFilter: const ColorFilter.mode(
                    Color(0x99000000),
                    BlendMode.darken,
                  ),
                  child: EmbyImage(request: request, fit: BoxFit.cover),
                ),
                EmbyImage(
                  key: const ValueKey('library-mixed-image-foreground'),
                  request: request,
                  fit: BoxFit.contain,
                  icon: icon,
                ),
              ] else
                ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Icon(icon, size: 42),
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
                subtitle: subtitle,
                icon: icon,
                hasTopBadge: status != null || item.userData.isFavorite,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
