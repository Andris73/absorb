import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Cover image for an ABB result: cached network image inside a themed
/// card, with a grey book-icon placeholder while loading or on error.
class AbbCover extends StatelessWidget {
  final String? url;
  final double radius;

  const AbbCover({super.key, this.url, this.radius = 8});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = Container(
      color: cs.surfaceContainerHigh,
      child: Icon(
        Icons.menu_book_rounded,
        size: 28,
        color: cs.onSurfaceVariant.withValues(alpha: 0.3),
      ),
    );
    final coverUrl = url;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: coverUrl == null || coverUrl.isEmpty
          ? placeholder
          : CachedNetworkImage(
              imageUrl: coverUrl,
              fit: BoxFit.cover,
              placeholder: (_, __) => placeholder,
              errorWidget: (_, __, ___) => placeholder,
            ),
    );
  }
}
