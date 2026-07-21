import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/discover/abb_models.dart';
import '../../services/discover/series_tracking_service.dart';
import '../../services/player_settings.dart';
import 'abb_book_detail_view.dart';
import 'abb_series_view.dart';

/// Whether the Discover ABB integration is configured (mirror URL set).
Future<bool> abbConfigured() async =>
    (await PlayerSettings.getAbbServerUrl()).isNotEmpty;

/// Book-menu tile that looks the book up on AudiobookBay. Shared by the
/// Audible series sheet and the Upcoming Releases screen.
ListTile abbFindBookTile(
  BuildContext context, {
  required String seriesName,
  required Map<String, dynamic> book,
}) {
  final cs = Theme.of(context).colorScheme;
  final l = AppLocalizations.of(context)!;
  var tapped = false;
  return ListTile(
    leading: Icon(Icons.travel_explore_rounded, color: cs.primary, size: 22),
    title: Text(l.audibleSeriesFindOnAbb,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
    dense: true,
    visualDensity: VisualDensity.compact,
    onTap: () {
      // A second tap during the pop animation would pop the series sheet.
      if (tapped) return;
      tapped = true;
      Navigator.pop(context);
      findBookOnAbb(
        context,
        seriesName: seriesName,
        title: book['title'] as String? ?? '',
        author: book['authors'] as String? ?? '',
      );
    },
  );
}

/// Look a specific book up on AudiobookBay and open its detail page, falling
/// back to the series listing when no confident title match is found.
Future<void> findBookOnAbb(
  BuildContext context, {
  required String seriesName,
  required String title,
  required String author,
}) async {
  final abbUrl = await PlayerSettings.getAbbServerUrl();
  if (abbUrl.isEmpty || !context.mounted) return;

  final l = AppLocalizations.of(context)!;
  // Lead author only: co-author/translator noise hurts the ABB match rate.
  final leadAuthor = author.split(',').first.trim();

  // The dialog is popped through its own route context so it can't leak if
  // the caller's context dies mid-resolve; `done` covers the race where the
  // lookup finishes before the dialog's first build.
  BuildContext? dialogContext;
  var done = false;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) {
      dialogContext = c;
      if (done) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (c.mounted) Navigator.of(c).pop();
        });
      }
      return PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(children: [
            const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 16),
            Expanded(child: Text(l.discoverFindingOnAbb)),
          ]),
        ),
      );
    },
  ));

  AbbSearchResult? found;
  try {
    found = await SeriesTrackingService.instance.resolveBook(
      abbBaseUrl: abbUrl,
      seriesName: seriesName,
      title: title,
      author: leadAuthor,
    );
  } catch (e) {
    // Fall through to the series listing, which surfaces its own errors.
    debugPrint('[ABB] resolveBook failed: $e');
  }

  done = true;
  final d = dialogContext;
  if (d != null && d.mounted) Navigator.of(d).pop();
  if (!context.mounted) return;

  final best = found;
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => best != null
        ? AbbBookDetailView(result: best)
        : AbbSeriesView(seriesName: seriesName, author: leadAuthor),
  ));
}
