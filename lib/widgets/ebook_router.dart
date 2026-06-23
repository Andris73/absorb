import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'ebook_reader_view.dart';
import 'pdf_reader_view.dart';
import 'overlay_toast.dart';

/// Lower-cased ebook format for an ABS ebookFile - prefers the explicit
/// `ebookFormat` field, falls back to the filename extension.
String ebookExt(Map<String, dynamic>? ebookFile) {
  if (ebookFile == null) return '';
  final fmt = (ebookFile['ebookFormat'] as String?)?.toLowerCase();
  if (fmt != null && fmt.isNotEmpty) return fmt;
  final fn = (ebookFile['metadata'] as Map<String, dynamic>?)?['filename'] as String?
      ?? ebookFile['name'] as String?;
  if (fn == null || !fn.contains('.')) return '';
  return fn.substring(fn.lastIndexOf('.') + 1).toLowerCase();
}

/// Formats the in-app reader can open today. EPUB uses the full reader, PDF the
/// dedicated PDF viewer. Anything else falls back to download / send-to-e-reader.
const _readableFormats = {'epub', 'pdf'};

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
  final Widget viewer;
  switch (ebookExt(ebookFile)) {
    case 'epub':
      viewer = EbookReaderView(itemId: itemId, title: title, ebookFile: ebookFile);
    case 'pdf':
      viewer = PdfReaderView(itemId: itemId, title: title, ebookFile: ebookFile);
    default:
      showOverlayToast(context, AppLocalizations.of(context)!.readerFormatUnsupported,
          icon: Icons.menu_book_outlined);
      return;
  }
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(builder: (_) => viewer),
  );
}
