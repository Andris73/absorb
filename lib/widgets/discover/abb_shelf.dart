import 'package:flutter/material.dart';

import '../../services/discover/abb_models.dart';
import 'abb_cover.dart';

const double _cardWidth = 110;
const double _coverHeight = _cardWidth * 1.5;

/// Horizontal shelf of ABB results, mirroring HomeSection's header and
/// scroll conventions but taking ABB models instead of ABS item maps.
class AbbShelf extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<AbbSearchResult> results;
  final void Function(AbbSearchResult) onTap;

  const AbbShelf({
    super.key,
    required this.title,
    required this.icon,
    required this.results,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AbbShelfHeader(title: title, icon: icon),
          const SizedBox(height: 12),
          SizedBox(
            height: _coverHeight + 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              physics: const BouncingScrollPhysics(),
              itemCount: results.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final r = results[index];
                return SizedBox(
                  width: _cardWidth,
                  child: _AbbShelfCell(result: r, onTap: () => onTap(r)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Section header shared by ABB shelves and the downloads section:
/// icon + titleSmall label + hairline rule.
class AbbShelfHeader extends StatelessWidget {
  final String title;
  final IconData icon;

  const AbbShelfHeader({super.key, required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Icon(icon, size: 16, color: cs.primary.withValues(alpha: 0.7)),
          const SizedBox(width: 8),
          Text(
            title,
            style: tt.titleSmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: cs.onSurface.withValues(alpha: 0.8),
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 0.5,
              color: cs.outlineVariant.withValues(alpha: 0.2),
            ),
          ),
        ],
      ),
    );
  }
}

class _AbbShelfCell extends StatelessWidget {
  final AbbSearchResult result;
  final VoidCallback onTap;

  const _AbbShelfCell({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: _cardWidth,
            height: _coverHeight,
            child: AbbCover(url: result.coverUrl),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              result.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tt.labelMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
