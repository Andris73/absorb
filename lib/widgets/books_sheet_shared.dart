import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';

/// Helpers shared by the book-list sheets (author, narrator, series).

/// Register cover cache-busting and has-cover info for one book.
void registerBookCover(LibraryProvider lib, Map<String, dynamic> book) {
  final id = book['id'] as String?;
  if (id == null) return;
  final ts = book['updatedAt'] as num?;
  if (ts != null) lib.registerUpdatedAt(id, ts.toInt());
  final coverPath = (book['media'] as Map<String, dynamic>?)?['coverPath'] as String?;
  lib.registerHasCover(id, coverPath != null && coverPath.isNotEmpty);
}

void registerBookCovers(LibraryProvider lib, Iterable<Map<String, dynamic>> books) {
  for (final book in books) {
    registerBookCover(lib, book);
  }
}

/// Standard grid delegate for book grids inside sheets.
SliverGridDelegateWithFixedCrossAxisCount sheetBookGridDelegate(
  BuildContext context, {
  double childAspectRatio = 0.55,
}) {
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: (MediaQuery.of(context).size.width / 130).floor().clamp(3, 10),
    mainAxisSpacing: 8,
    crossAxisSpacing: 8,
    childAspectRatio: childAspectRatio,
  );
}

/// List/grid toggle row shown under a sheet header. Persists the choice via
/// [PlayerSettings.setSheetGridView]; [leading] is an optional control pinned
/// to the left (e.g. a group-by-series toggle).
Widget sheetViewModeBar(
  BuildContext context, {
  required bool gridView,
  required ValueChanged<bool> onChanged,
  Widget? leading,
  EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(16, 0, 16, 4),
}) {
  final cs = Theme.of(context).colorScheme;
  final l = AppLocalizations.of(context)!;
  Widget layoutBtn(IconData icon, bool grid, String tooltip) {
    final active = gridView == grid;
    return IconButton(
      icon: Icon(icon, size: 20, color: active ? cs.primary : cs.onSurfaceVariant),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: () {
        onChanged(grid);
        PlayerSettings.setSheetGridView(grid);
      },
    );
  }
  return Padding(
    padding: padding,
    child: Row(
      children: [
        if (leading != null) leading,
        const Spacer(),
        layoutBtn(Icons.view_list_rounded, false, l.authorBooksList),
        layoutBtn(Icons.apps_rounded, true, l.authorBooksGrid),
      ],
    ),
  );
}

/// Round-avatar header used by the author and narrator sheets:
/// 72px avatar, name, book count, optional trailing action.
Widget sheetPersonHeader(
  BuildContext context, {
  required Widget avatar,
  required String title,
  String? subtitle,
  Widget? trailing,
}) {
  final cs = Theme.of(context).colorScheme;
  final tt = Theme.of(context).textTheme;
  return Padding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        avatar,
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              Text(title,
                  style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    subtitle,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) trailing,
      ],
    ),
  );
}

/// Scrollable "no books" body that keeps the header widgets visible.
Widget sheetEmptyBooksList(
  BuildContext context, {
  required ScrollController controller,
  required List<Widget> headerWidgets,
  required double bottomPad,
}) {
  final cs = Theme.of(context).colorScheme;
  final tt = Theme.of(context).textTheme;
  final l = AppLocalizations.of(context)!;
  return ListView(
    controller: controller,
    padding: EdgeInsets.fromLTRB(0, 0, 0, bottomPad),
    children: [
      ...headerWidgets,
      Center(
        child: Padding(
          padding: const EdgeInsets.only(top: 48),
          child: Text(l.noBooksFound,
              style: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
        ),
      ),
    ],
  );
}
