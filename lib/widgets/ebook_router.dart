import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/ebook_cache.dart';
import 'ebook_reader_view.dart';
import 'pdf_reader_view.dart';
import 'foliate_reader_view.dart';
import 'overlay_toast.dart';

/// Lower-cased ebook format (no dot) for an ABS ebookFile. Shares the cache's
/// format-first derivation so the router, cache and readers can never disagree
/// on what a file is.
String ebookExt(Map<String, dynamic>? ebookFile) {
  if (ebookFile == null) return '';
  final ext = ebookExtFromFile(ebookFile);
  return ext.startsWith('.') ? ext.substring(1) : ext;
}

/// Formats the in-app reader can open. EPUB uses the full reader, PDF the
/// dedicated PDF viewer, and foliate-js covers MOBI/AZW3/CBZ. These match the
/// ebook types Audiobookshelf actually serves (epub, pdf, mobi, azw3, cbr, cbz).
/// CBR is RAR-based and foliate-js can't read it, so it stays a download.
const _foliateFormats = {'mobi', 'azw3', 'cbz'};
final _readableFormats = {'epub', 'pdf', ..._foliateFormats};

bool canReadEbook(Map<String, dynamic>? ebookFile) =>
    ebookFile != null && _readableFormats.contains(ebookExt(ebookFile));

/// Routes an ebook to the right reader for its format, or toasts when the
/// format isn't supported in-app.
void openEbookReader(
  BuildContext context, {
  required String itemId,
  required String title,
  required Map<String, dynamic> ebookFile,
}) {
  final ext = ebookExt(ebookFile);
  final Widget viewer;
  if (ext == 'epub') {
    viewer = EbookReaderView(itemId: itemId, title: title, ebookFile: ebookFile);
  } else if (ext == 'pdf') {
    viewer = PdfReaderView(itemId: itemId, title: title, ebookFile: ebookFile);
  } else if (_foliateFormats.contains(ext)) {
    viewer = FoliateReaderView(itemId: itemId, title: title, ebookFile: ebookFile);
  } else {
    showOverlayToast(context, AppLocalizations.of(context)!.readerFormatUnsupported,
        icon: Icons.menu_book_outlined);
    return;
  }
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(builder: (_) => viewer),
  );
}
