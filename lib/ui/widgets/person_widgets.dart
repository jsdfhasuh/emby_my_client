import 'package:flutter/material.dart';

import '../../images/emby_image_request.dart';
import '../../models/emby_models.dart';
import 'media_widgets.dart';

class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.imageRequest,
    this.borderRadius = 6,
  });

  final EmbyImageRequest? imageRequest;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: EmbyImage(
        request: imageRequest,
        icon: Icons.person_outline_rounded,
      ),
    );
  }
}

class CastCard extends StatelessWidget {
  const CastCard({
    super.key,
    required this.person,
    required this.imageRequest,
    this.onTap,
  });

  final EmbyPerson person;
  final EmbyImageRequest? imageRequest;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final nameHeight = textScaler.scale(13) * 1.2 * 2;
    final roleHeight = textScaler.scale(11) * 1.25 * 2;
    final content = SizedBox(
      width: 104,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 144,
            child: PersonAvatar(imageRequest: imageRequest),
          ),
          const SizedBox(height: 7),
          SizedBox(
            height: nameHeight,
            child: Text(
              person.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (person.role != null) ...[
            const SizedBox(height: 3),
            SizedBox(
              height: roleHeight,
              child: Text(
                person.role!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF9DA6A9),
                  fontSize: 11,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    final handleTap = onTap;
    if (handleTap == null) return content;
    return Stack(
      children: [
        content,
        Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: ValueKey('cast-link-${person.id}'),
              onTap: handleTap,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ],
    );
  }
}

class CastRow extends StatelessWidget {
  const CastRow({
    super.key,
    required this.people,
    required this.imageRequestFor,
    required this.onTap,
  });

  final List<EmbyPerson> people;
  final EmbyImageRequest? Function(EmbyPerson person) imageRequestFor;
  final ValueChanged<EmbyPerson> onTap;

  @override
  Widget build(BuildContext context) {
    final cast = people
        .where((person) => person.isCast)
        .toList(growable: false);
    if (cast.isEmpty) return const SizedBox.shrink();
    final textScaler = MediaQuery.textScalerOf(context);
    final listHeight =
        154 + textScaler.scale(13) * 1.2 * 2 + textScaler.scale(11) * 1.25 * 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '演员',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: listHeight,
          child: ListView.separated(
            key: const Key('cast-list'),
            scrollDirection: Axis.horizontal,
            itemCount: cast.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final person = cast[index];
              return CastCard(
                key: ValueKey('cast-${person.id ?? '$index-${person.name}'}'),
                person: person,
                imageRequest: imageRequestFor(person),
                onTap: person.isNavigable ? () => onTap(person) : null,
              );
            },
          ),
        ),
      ],
    );
  }
}
