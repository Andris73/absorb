import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/rmab_service.dart';

/// Small status pill for an RMAB request, used in search result rows, request
/// list rows, and book detail banners. Maps the raw server status string to a
/// visual group + label.
class RmabRequestStatusChip extends StatelessWidget {
  const RmabRequestStatusChip({
    super.key,
    required this.rawStatus,
    this.dense = true,
  });

  /// Raw status string from the server (e.g. `pending`, `downloading`).
  final String rawStatus;

  /// `true` for compact in-list use; `false` for a more prominent banner-style
  /// chip with a leading icon.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;

    final spec = _specFor(rawStatus, cs, l);

    final bg = spec.color.withValues(alpha: 0.16);
    final fg = spec.color;

    return Container(
      padding: dense
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3)
          : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(dense ? 6 : 8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!dense) ...[
            Icon(spec.icon, size: 14, color: fg),
            const SizedBox(width: 6),
          ],
          Text(
            spec.label,
            style: (dense ? tt.labelSmall : tt.labelMedium)?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  _ChipSpec _specFor(String raw, ColorScheme cs, AppLocalizations l) {
    final group = raw.rmabGroup;
    switch (group) {
      case RmabStatusGroup.active:
        return _ChipSpec(l.rmabStatusActive, cs.primary, Icons.sync_rounded);
      case RmabStatusGroup.waiting:
        return _ChipSpec(
          l.rmabStatusWaiting,
          cs.tertiary,
          Icons.hourglass_top_rounded,
        );
      case RmabStatusGroup.completed:
        // Distinguish 'available' (matched in library) from 'downloaded'
        final label = raw == 'available'
            ? l.rmabStatusAvailable
            : l.rmabStatusDownloaded;
        return _ChipSpec(label, Colors.green.shade600, Icons.check_circle_rounded);
      case RmabStatusGroup.failed:
        return _ChipSpec(l.rmabStatusFailed, cs.error, Icons.error_outline_rounded);
      case RmabStatusGroup.cancelled:
        final label = raw == 'denied'
            ? l.rmabStatusDenied
            : l.rmabStatusCancelled;
        return _ChipSpec(label, cs.onSurfaceVariant, Icons.block_rounded);
      case null:
        // `warn` falls here, plus anything unknown
        return _ChipSpec(
          raw.isEmpty ? l.rmabStatusUnknown : raw,
          cs.tertiary,
          Icons.info_outline_rounded,
        );
    }
  }
}

class _ChipSpec {
  const _ChipSpec(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;
}
