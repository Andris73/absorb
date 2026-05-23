import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/ebook_annotation_service.dart';
import '../services/scoped_prefs.dart';

class EbookReaderView extends StatefulWidget {
  final String itemId;
  final String title;
  final Map<String, dynamic> ebookFile;
  /// When true, renders without a Scaffold wrapper / SafeArea / SystemChrome
  /// changes — for use inside another widget like the absorbing card back.
  final bool embedded;
  /// Replaces the back button's behavior. Defaults to Navigator.pop in
  /// full-screen mode; in embedded mode the host should provide one (e.g. to
  /// flip the card back to the front face).
  final VoidCallback? onClose;
  /// Only shown in embedded mode. Tap surfaces an "expand to full screen"
  /// affordance the host can wire up.
  final VoidCallback? onExpand;
  /// If provided, opens the reader at this exact CFI instead of the saved
  /// progress location. Used to hand off position between embedded and
  /// full-screen instances.
  final String? initialCfi;
  /// Fires whenever the reader's position changes. Used by hosts to mirror
  /// position across paired reader instances.
  final ValueChanged<String>? onPositionChanged;

  const EbookReaderView({
    super.key,
    required this.itemId,
    required this.title,
    required this.ebookFile,
    this.embedded = false,
    this.onClose,
    this.onExpand,
    this.initialCfi,
    this.onPositionChanged,
  });

  @override
  State<EbookReaderView> createState() => EbookReaderViewState();
}

class EbookReaderViewState extends State<EbookReaderView> {
  /// Latest known position of the reader. Null until the first relocate fires.
  String? get currentCfi => _currentCfi;
  /// Asks the controller for the *live* current location. More accurate than
  /// [currentCfi] right after a page flip, since onRelocated may not have
  /// caught up yet. Returns null if the controller isn't ready or errors.
  Future<String?> getLiveCfi() async {
    try {
      final loc = await _epubController?.getCurrentLocation();
      return loc?.startCfi ?? _currentCfi;
    } catch (_) {
      return _currentCfi;
    }
  }
  /// Jump the reader to a specific CFI. Safe to call before the EPUB has loaded;
  /// the controller no-ops in that case.
  void seekTo(String cfi) => _epubController?.display(cfi: cfi);
  EpubController? _epubController;
  bool _loading = true;
  String? _error;
  File? _cachedFile;
  String? _initialCfi;
  bool _showControls = false;
  List<EpubChapter> _chapters = [];
  double _progress = 0;
  int _chapterPage = 0;
  int _chapterPageTotal = 0;

  // Annotations
  final _annotationService = EbookAnnotationService();
  List<EbookAnnotation> _annotations = [];
  bool _hasBookmarkAtCurrent = false;
  String? _currentCfi;

  // Selection state for highlight menu
  String? _selectionText;
  String? _selectionCfi;
  Rect? _selectionRect;
  // Track touch start position to distinguish taps from swipes
  double? _touchDownX;
  double? _touchDownY;

  // Key to force-rebuild EpubViewer when layout mode changes
  int _viewerKey = 0;

  // Reader settings
  int _fontSize = 16;
  double _lineHeight = 1.4;
  int _margin = 16;

  static const _kFontSize = 'ereader_fontSize';
  static const _kLineHeight = 'ereader_lineHeight';
  static const _kMargin = 'ereader_margin';

  @override
  void initState() {
    super.initState();
    _epubController = EpubController();
    _loadInitialLocation();
    _loadSettings().then((_) => _downloadAndOpen());
    _setFullscreen(true);
  }

  Future<void> _loadSettings() async {
    _fontSize = await ScopedPrefs.getInt(_kFontSize) ?? 16;
    _lineHeight = await ScopedPrefs.getDouble(_kLineHeight) ?? 1.4;
    _margin = await ScopedPrefs.getInt(_kMargin) ?? 16;
    if (mounted) setState(() {});
  }

  EpubTheme _buildTheme(bool isDark) {
    return EpubTheme.custom(
      foregroundColor: isDark ? Colors.white : Colors.black,
      backgroundDecoration: BoxDecoration(
        color: isDark ? Colors.black : Colors.white,
      ),
      customCss: {
        'body': {
          'color': isDark ? '#ffffff' : '#000000',
          'background': isDark ? '#000000' : '#ffffff',
          'line-height': '$_lineHeight',
          'padding': '${_margin}px !important',
          'margin': '0px !important',
          'box-sizing': 'border-box !important',
          'max-width': '100vw !important',
          'overflow-x': 'hidden !important',
          '-webkit-overflow-scrolling': 'touch',
          'will-change': 'scroll-position',
        },
        'p, div, span, h1, h2, h3, h4, h5, h6, li, td, th, a, em, strong, blockquote': {
          'color': 'inherit !important',
        },
      },
    );
  }

  void _applySettings() {
    _epubController?.setFontSize(fontSize: _fontSize.toDouble());
    final isDark = Theme.of(context).brightness == Brightness.dark;
    _epubController?.updateTheme(theme: _buildTheme(isDark));
  }

  Future<void> _updateFontSize(int size) async {
    setState(() => _fontSize = size);
    _epubController?.setFontSize(fontSize: size.toDouble());
    await ScopedPrefs.setInt(_kFontSize, size);
  }

  Future<void> _updateLineHeight(double height) async {
    setState(() => _lineHeight = height);
    _applySettings();
    await ScopedPrefs.setDouble(_kLineHeight, height);
  }

  Future<void> _updateMargin(int margin) async {
    setState(() => _margin = margin);
    _applySettings();
    await ScopedPrefs.setInt(_kMargin, margin);
  }

  @override
  void dispose() {
    // Restore system UI when leaving
    _setFullscreen(false);
    super.dispose();
  }

  void _setFullscreen(bool fullscreen) {
    if (widget.embedded) return; // host owns system chrome
    if (fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      // Explicitly show top + bottom bars. edgeToEdge alone doesn't reliably
      // undo immersiveSticky on every Android version.
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
  }

  void _loadInitialLocation() {
    // Explicit initialCfi (e.g. handoff from another reader instance) wins.
    if (widget.initialCfi != null && widget.initialCfi!.isNotEmpty) {
      _initialCfi = widget.initialCfi;
      return;
    }
    final lib = context.read<LibraryProvider>();
    final progressData = lib.getProgressData(widget.itemId);
    final loc = progressData?['ebookLocation'] as String?;
    if (loc != null && loc.isNotEmpty) {
      _initialCfi = loc;
    }
  }

  Future<void> _downloadAndOpen() async {
    try {
      final auth = context.read<AuthProvider>();
      final api = auth.apiService;
      if (api == null) {
        setState(() { _error = 'Not connected to server'; _loading = false; });
        return;
      }

      final ino = widget.ebookFile['ino'] as String?;
      if (ino == null) {
        setState(() { _error = 'No ebook file found'; _loading = false; });
        return;
      }

      final ebookName = widget.ebookFile['metadata']?['filename'] as String?
          ?? widget.ebookFile['name'] as String?
          ?? 'book.epub';
      final ext = ebookName.contains('.')
          ? ebookName.substring(ebookName.lastIndexOf('.'))
          : '.epub';
      final safeTitle = widget.title.replaceAll(RegExp(r'[^\w\s-]'), '').trim();

      final cacheDir = await getTemporaryDirectory();
      final cachedFile = File('${cacheDir.path}/ereader_$safeTitle$ext');

      if (!cachedFile.existsSync()) {
        final cleanBase = api.baseUrl.endsWith('/')
            ? api.baseUrl.substring(0, api.baseUrl.length - 1)
            : api.baseUrl;
        final url = '$cleanBase/api/items/${widget.itemId}/file/$ino';

        final request = http.Request('GET', Uri.parse(url));
        request.followRedirects = false;
        api.mediaHeaders.forEach((k, v) => request.headers[k] = v);
        final client = http.Client();
        try {
          var response = await client.send(request);

          // Follow redirects preserving auth headers
          var redirects = 0;
          while ([301, 302, 303, 307, 308].contains(response.statusCode) && redirects < 5) {
            final location = response.headers['location'];
            if (location == null) break;
            final redirectUrl = Uri.parse(url).resolve(location);
            final rReq = http.Request('GET', redirectUrl);
            api.mediaHeaders.forEach((k, v) => rReq.headers[k] = v);
            rReq.followRedirects = false;
            response = await client.send(rReq);
            redirects++;
          }

          if (response.statusCode != 200) {
            setState(() { _error = 'Failed to download ebook (${response.statusCode})'; _loading = false; });
            return;
          }

          final ct = response.headers['content-type'] ?? '';
          if (ct.contains('text/html')) {
            setState(() { _error = 'Server returned an error page'; _loading = false; });
            return;
          }

          final sink = cachedFile.openWrite();
          try {
            await response.stream.pipe(sink);
          } finally {
            await sink.close();
          }
        } finally {
          client.close();
        }
      }

      if (mounted) {
        setState(() {
          _cachedFile = cachedFile;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('[EbookReader] Error: $e');
      if (mounted) {
        setState(() { _error = 'Error loading ebook: $e'; _loading = false; });
      }
    }
  }

  void _syncProgress(String cfi, double progress) {
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) return;
    api.updateEbookProgress(
      widget.itemId,
      ebookLocation: cfi,
      ebookProgress: progress,
    );
  }

  Future<void> _loadAnnotations() async {
    _annotations = await _annotationService.getAnnotations(widget.itemId);
    if (mounted) setState(() {});
  }

  void _restoreHighlights() {
    for (final a in _annotations) {
      if (a.type == AnnotationType.highlight && a.color != null) {
        _epubController?.addHighlight(
          cfi: a.cfi,
          color: Color(int.parse('FF${a.color!.hex.substring(1)}', radix: 16)),
          opacity: 0.35,
        );
      }
    }
  }

  // ── Locations cache ───────────────────────────────────────────────
  // epub.js spends ~7s on first open building a CFI index for progress
  // tracking, during which scrolling can produce visible jumps. Cache the
  // index next to the EPUB file so subsequent opens are instant.
  String? _locationsCachePath() {
    final f = _cachedFile;
    if (f == null) return null;
    return '${f.path}.locations.json';
  }

  Future<String?> _loadCachedLocations() async {
    final path = _locationsCachePath();
    if (path == null) return null;
    final f = File(path);
    if (!await f.exists()) return null;
    try {
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCachedLocations(String json) async {
    final path = _locationsCachePath();
    if (path == null) return;
    try {
      await File(path).writeAsString(json);
    } catch (_) {}
  }

  Future<void> _setupLocations() async {
    final cached = await _loadCachedLocations();
    if (!mounted) return;
    if (cached != null && cached.isNotEmpty) {
      debugPrint('[Reader] Locations: loading cached (${cached.length} bytes)');
      final injected = jsonEncode(cached);
      _epubController?.webViewController?.evaluateJavascript(source: '''
        (function() {
          try { rendition.book.locations.load($injected); }
          catch (e) { console.error('locations.load failed', e); }
        })();
      ''');
      return;
    }
    debugPrint('[Reader] Locations: no cache, generating...');
    _epubController?.webViewController?.addJavaScriptHandler(
      handlerName: 'locationsGenerated',
      callback: (args) async {
        if (args.isEmpty) return;
        final data = args[0] as String?;
        if (data != null && data.isNotEmpty) {
          debugPrint('[Reader] Locations: caching ${data.length} bytes');
          await _saveCachedLocations(data);
        }
      },
    );
    _epubController?.webViewController?.evaluateJavascript(source: '''
      (function() {
        rendition.book.locations.generate(1024).then(function() {
          var data = rendition.book.locations.save();
          window.flutter_inappwebview.callHandler('locationsGenerated', data);
        }).catch(function(e) { console.error('locations.generate failed', e); });
      })();
    ''');
  }

  void _setupPageInfoHandler() {
    _epubController?.webViewController?.addJavaScriptHandler(
      handlerName: 'pageInfo',
      callback: (args) {
        if (!mounted || args.isEmpty) return;
        final data = args[0] as Map<String, dynamic>?;
        if (data == null) return;
        final page = data['page'] as int? ?? 0;
        final total = data['total'] as int? ?? 0;
        // Brief total=0 reports happen at chapter handoffs; keep the last
        // valid count visible rather than blanking the indicator.
        if (total == 0 && _chapterPageTotal > 0) return;
        if (page != _chapterPage || total != _chapterPageTotal) {
          setState(() {
            _chapterPage = page;
            _chapterPageTotal = total;
          });
        }
      },
    );
    _epubController?.webViewController?.evaluateJavascript(
      source: '''
        (function() {
          rendition.on('relocated', function(location) {
            if (location && location.start && location.start.displayed) {
              window.flutter_inappwebview.callHandler('pageInfo', {
                page: location.start.displayed.page,
                total: location.start.displayed.total
              });
            }
          });
        })();
      ''',
    );
  }

  Future<void> _addHighlight(HighlightColor color) async {
    if (_selectionCfi == null || _selectionText == null) return;
    final annotation = await _annotationService.addHighlight(
      itemId: widget.itemId,
      cfi: _selectionCfi!,
      selectedText: _selectionText!,
      color: color,
    );
    _epubController?.addHighlight(
      cfi: annotation.cfi,
      color: Color(int.parse('FF${color.hex.substring(1)}', radix: 16)),
      opacity: 0.35,
    );
    _annotations.insert(0, annotation);
    _clearSelection();
    if (mounted) setState(() {});
  }

  Future<void> _removeHighlight(EbookAnnotation annotation) async {
    _epubController?.removeHighlight(cfi: annotation.cfi);
    await _annotationService.delete(
      itemId: widget.itemId,
      annotationId: annotation.id,
    );
    _annotations.removeWhere((a) => a.id == annotation.id);
    if (mounted) setState(() {});
  }

  Future<void> _toggleBookmark() async {
    final cfi = _currentCfi;
    if (cfi == null) return;

    if (_hasBookmarkAtCurrent) {
      // Remove existing bookmark at this location
      final existing = _annotations.where(
        (a) => a.type == AnnotationType.bookmark && a.cfi == cfi,
      ).toList();
      for (final bm in existing) {
        await _annotationService.delete(
          itemId: widget.itemId,
          annotationId: bm.id,
        );
        _annotations.removeWhere((a) => a.id == bm.id);
      }
    } else {
      final annotation = await _annotationService.addBookmark(
        itemId: widget.itemId,
        cfi: cfi,
      );
      _annotations.insert(0, annotation);
    }
    _updateBookmarkState();
    if (mounted) setState(() {});
  }

  void _updateBookmarkState() {
    final cfi = _currentCfi;
    _hasBookmarkAtCurrent = cfi != null &&
        _annotations.any((a) => a.type == AnnotationType.bookmark && a.cfi == cfi);
  }

  void _clearSelection() {
    _selectionText = null;
    _selectionCfi = null;
    _selectionRect = null;
  }

  Widget _divider(ColorScheme cs) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Container(width: 1, height: 24, color: cs.onSurface.withValues(alpha: 0.15)),
  );

  void _copySelection() {
    if (_selectionText == null) return;
    Clipboard.setData(ClipboardData(text: _selectionText!));
    setState(() => _clearSelection());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)),
    );
  }

  void _searchSelection() {
    if (_selectionText == null) return;
    final query = Uri.encodeComponent(_selectionText!.trim());
    launchUrl(Uri.parse('https://www.google.com/search?q=$query'), mode: LaunchMode.externalApplication);
    setState(() => _clearSelection());
  }

  void _defineSelection() {
    if (_selectionText == null) return;
    final word = _selectionText!.trim().split(RegExp(r'\s+')).first;
    final query = Uri.encodeComponent('define $word');
    launchUrl(Uri.parse('https://www.google.com/search?q=$query'), mode: LaunchMode.externalApplication);
    setState(() => _clearSelection());
  }

  void _onSelection(String text, String cfi, Rect selRect, Rect vRect) {
    if (text.trim().isEmpty) return;
    setState(() {
      _selectionText = text;
      _selectionCfi = cfi;
      _selectionRect = selRect;
    });
  }

  Future<void> _addNoteToAnnotation(EbookAnnotation annotation) async {
    final controller = TextEditingController(text: annotation.note ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Note'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Add a note...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) {
      await _annotationService.updateNote(
        itemId: widget.itemId,
        annotationId: annotation.id,
        note: result.isEmpty ? null : result,
      );
      annotation.note = result.isEmpty ? null : result;
      if (mounted) setState(() {});
    }
  }

  void _navigateToChapter(String href) {
    final escaped = href.replaceAll("'", "\\'");
    _epubController?.webViewController?.evaluateJavascript(
      source: '''
        (function() {
          rendition.display('$escaped').then(function() {
            rendition.resize();
          });
        })();
      ''',
    );
  }

  List<EpubChapter> _flattenChapters(List<EpubChapter> chapters) {
    final flat = <EpubChapter>[];
    for (final ch in chapters) {
      flat.add(ch);
      if (ch.subitems.isNotEmpty) {
        flat.addAll(_flattenChapters(ch.subitems));
      }
    }
    return flat;
  }

  void _showChapterList() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Chapters', style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _chapters.length,
                itemBuilder: (ctx, i) {
                  final ch = _chapters[i];
                  return ListTile(
                    title: Text(ch.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    dense: true,
                    onTap: () {
                      Navigator.pop(ctx);
                      _navigateToChapter(ch.href);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettingsSheet() {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 32, height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Reader Settings', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 20),

                // Font size
                Row(children: [
                  Icon(Icons.text_fields_rounded, size: 20, color: cs.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Text('Font Size', style: tt.bodyMedium),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.remove_rounded, size: 20, color: cs.onSurfaceVariant),
                    onPressed: _fontSize > 10 ? () {
                      setSheetState(() {});
                      _updateFontSize(_fontSize - 1);
                    } : null,
                  ),
                  Text('$_fontSize', style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  IconButton(
                    icon: Icon(Icons.add_rounded, size: 20, color: cs.onSurfaceVariant),
                    onPressed: _fontSize < 32 ? () {
                      setSheetState(() {});
                      _updateFontSize(_fontSize + 1);
                    } : null,
                  ),
                ]),
                const SizedBox(height: 8),

                // Line height
                Row(children: [
                  Icon(Icons.format_line_spacing_rounded, size: 20, color: cs.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Text('Line Spacing', style: tt.bodyMedium),
                  const Spacer(),
                  Text(_lineHeight.toStringAsFixed(1), style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ]),
                Slider(
                  value: _lineHeight,
                  min: 1.0,
                  max: 2.5,
                  divisions: 15,
                  onChanged: (v) {
                    setSheetState(() {});
                    _updateLineHeight(double.parse(v.toStringAsFixed(1)));
                  },
                ),
                const SizedBox(height: 8),

                // Margins
                Row(children: [
                  Icon(Icons.padding_rounded, size: 20, color: cs.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Text('Margins', style: tt.bodyMedium),
                  const Spacer(),
                  Text('${_margin}px', style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ]),
                Slider(
                  value: _margin.toDouble(),
                  min: 0,
                  max: 48,
                  divisions: 12,
                  onChanged: (v) {
                    setSheetState(() {});
                    _updateMargin(v.round());
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAnnotationsSheet() {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final highlights = _annotations.where((a) => a.type == AnnotationType.highlight).toList();
    final bookmarks = _annotations.where((a) => a.type == AnnotationType.bookmark).toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        builder: (ctx, scrollController) => DefaultTabController(
          length: 2,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    Text('Annotations', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text(
                      '${_annotations.length}',
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              TabBar(
                tabs: [
                  Tab(text: 'Highlights (${highlights.length})'),
                  Tab(text: 'Bookmarks (${bookmarks.length})'),
                ],
                labelColor: cs.primary,
                unselectedLabelColor: cs.onSurfaceVariant,
                indicatorColor: cs.primary,
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    // Highlights tab
                    highlights.isEmpty
                        ? Center(child: Text('No highlights yet', style: TextStyle(color: cs.onSurfaceVariant)))
                        : ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: highlights.length,
                            itemBuilder: (ctx, i) {
                              final h = highlights[i];
                              return Dismissible(
                                key: ValueKey(h.id),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 16),
                                  color: cs.error,
                                  child: Icon(Icons.delete_rounded, color: cs.onError),
                                ),
                                onDismissed: (_) => _removeHighlight(h),
                                child: ListTile(
                                  leading: Container(
                                    width: 4,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: Color(int.parse('FF${h.color!.hex.substring(1)}', radix: 16)),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  title: Text(
                                    h.selectedText ?? '',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: tt.bodyMedium,
                                  ),
                                  subtitle: h.note != null && h.note!.isNotEmpty
                                      ? Text(h.note!, maxLines: 1, overflow: TextOverflow.ellipsis,
                                          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))
                                      : null,
                                  dense: true,
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _epubController?.display(cfi: h.cfi);
                                  },
                                  onLongPress: () => _addNoteToAnnotation(h),
                                ),
                              );
                            },
                          ),

                    // Bookmarks tab
                    bookmarks.isEmpty
                        ? Center(child: Text('No bookmarks yet', style: TextStyle(color: cs.onSurfaceVariant)))
                        : ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: bookmarks.length,
                            itemBuilder: (ctx, i) {
                              final bm = bookmarks[i];
                              final date = '${bm.createdAt.month}/${bm.createdAt.day}/${bm.createdAt.year}';
                              return Dismissible(
                                key: ValueKey(bm.id),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 16),
                                  color: cs.error,
                                  child: Icon(Icons.delete_rounded, color: cs.onError),
                                ),
                                onDismissed: (_) async {
                                  await _annotationService.delete(
                                    itemId: widget.itemId,
                                    annotationId: bm.id,
                                  );
                                  _annotations.removeWhere((a) => a.id == bm.id);
                                  _updateBookmarkState();
                                  if (mounted) setState(() {});
                                },
                                child: ListTile(
                                  leading: Icon(Icons.bookmark_rounded, color: cs.primary),
                                  title: Text(
                                    bm.note ?? 'Bookmark',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: tt.bodyMedium,
                                  ),
                                  subtitle: Text(date, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                                  dense: true,
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _epubController?.display(cfi: bm.cfi);
                                  },
                                  onLongPress: () => _addNoteToAnnotation(bm),
                                ),
                              );
                            },
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Wraps a body in a Scaffold for full-screen mode, or returns it directly
  /// (sized to fill the parent) for embedded mode.
  Widget _wrap(Widget body, Color bg, {PreferredSizeWidget? appBar}) {
    if (widget.embedded) {
      return ColoredBox(color: bg, child: body);
    }
    // Don't resize for the keyboard — epub.js reflows when the WebView
    // resizes, which would shift the visible page when the search keyboard
    // pops up. The bottom sheet positions itself above the keyboard via
    // MediaQuery.viewInsets, so it stays visible regardless.
    return Scaffold(
      backgroundColor: bg,
      appBar: appBar,
      body: body,
      resizeToAvoidBottomInset: false,
    );
  }

  /// SafeArea is only needed in full-screen mode — embedded callers manage
  /// their own insets.
  Widget _maybeSafeArea({required Widget child, bool top = true, bool bottom = true}) {
    if (widget.embedded) return child;
    return SafeArea(top: top, bottom: bottom, child: child);
  }

  void _handleClose() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;

    if (_loading) {
      return _wrap(
        const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        bg,
        appBar: AppBar(
          title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          backgroundColor: Colors.transparent,
        ),
      );
    }

    if (_error != null || _cachedFile == null) {
      return _wrap(
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(_error ?? 'Unknown error', textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant)),
          ),
        ),
        bg,
        appBar: AppBar(title: Text(widget.title)),
      );
    }

    // EpubViewer + overlays. SafeAreas around the viewer and overlays are
    // skipped in embedded mode (the host card already insets us).
    final viewerBody = Stack(
      children: [
          // Epub viewer with safe area padding for camera cutouts
          _maybeSafeArea(
            child: SizedBox.expand(
              child: EpubViewer(
              key: ValueKey(_viewerKey),
              epubSource: EpubSource.fromFile(_cachedFile!),
              epubController: _epubController!,
              initialCfi: _initialCfi,
              displaySettings: EpubDisplaySettings(
                flow: EpubFlow.paginated,
                snap: true,
                useSnapAnimationAndroid: false,
                theme: _buildTheme(isDark),
              ),
              onChaptersLoaded: (chapters) {
                if (mounted) setState(() => _chapters = _flattenChapters(chapters));
              },
              suppressNativeContextMenu: true,
              onSelection: _onSelection,
              onDeselection: () {
                if (mounted) setState(() => _clearSelection());
              },
              onAnnotationClicked: (cfi, rect) {
                final match = _annotations.where(
                  (a) => a.type == AnnotationType.highlight && a.cfi == cfi,
                ).firstOrNull;
                if (match != null) _addNoteToAnnotation(match);
              },
              onEpubLoaded: () {
                _applySettings();
                // Re-anchor to the requested CFI after settings reflow the text.
                // Consume _initialCfi so this only happens once — otherwise any
                // re-fire of onEpubLoaded would yank the user back to the start.
                final once = _initialCfi;
                if (once != null && once.isNotEmpty) {
                  _initialCfi = null;
                  _epubController?.display(cfi: once);
                }
                _loadAnnotations().then((_) => _restoreHighlights());
                _setupPageInfoHandler();
                _setupLocations();
              },
              onRelocated: (value) {
                if (mounted) {
                  _currentCfi = value.startCfi;
                  _updateBookmarkState();
                  setState(() => _progress = value.progress);
                  _syncProgress(value.startCfi, value.progress);
                  widget.onPositionChanged?.call(value.startCfi);
                }
              },
              onTouchDown: (x, y) {
                _touchDownX = x;
                _touchDownY = y;
              },
              onTouchUp: (x, y) {
                final dx = _touchDownX != null ? (x - _touchDownX!).abs() : 1.0;
                final dy = _touchDownY != null ? (y - _touchDownY!).abs() : 1.0;
                _touchDownX = null;
                _touchDownY = null;
                if (dx > 0.05 || dy > 0.05) return;
                if (x < 0.25) {
                  _epubController?.prev();
                } else if (x > 0.75) {
                  _epubController?.next();
                } else {
                  _toggleControls();
                }
              },
            ),
          )),

          // Top bar overlay
          AnimatedOpacity(
            opacity: _showControls ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !_showControls,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [bg.withValues(alpha: 1.0), bg.withValues(alpha: 0.6)],
                  ),
                ),
                child: _maybeSafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            widget.embedded ? Icons.flip_to_front_rounded : Icons.arrow_back_rounded,
                            color: cs.onSurface,
                          ),
                          onPressed: _handleClose,
                        ),
                        if (widget.embedded && widget.onExpand != null)
                          IconButton(
                            icon: Icon(Icons.fullscreen_rounded, color: cs.onSurface),
                            tooltip: 'Expand',
                            onPressed: widget.onExpand,
                          ),
                        Expanded(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cs.onSurface,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            _hasBookmarkAtCurrent
                                ? Icons.bookmark_rounded
                                : Icons.bookmark_border_rounded,
                            color: _hasBookmarkAtCurrent ? cs.primary : cs.onSurface,
                          ),
                          onPressed: _toggleBookmark,
                        ),
                        IconButton(
                          icon: Icon(Icons.sticky_note_2_outlined, color: cs.onSurface),
                          onPressed: _showAnnotationsSheet,
                        ),
                        IconButton(
                          icon: Icon(Icons.text_fields_rounded, color: cs.onSurface),
                          onPressed: _showSettingsSheet,
                        ),
                        if (_chapters.isNotEmpty)
                          IconButton(
                            icon: Icon(Icons.list_rounded, color: cs.onSurface),
                            onPressed: _showChapterList,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Bottom progress bar overlay
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [bg.withValues(alpha: 1.0), bg.withValues(alpha: 0.6)],
                    ),
                  ),
                  child: _maybeSafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: _progress.clamp(0.0, 1.0),
                              minHeight: 3,
                              backgroundColor: cs.onSurface.withValues(alpha: 0.1),
                              valueColor: AlwaysStoppedAnimation(cs.primary),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              if (_chapterPageTotal > 0)
                                Text(
                                  '$_chapterPage / $_chapterPageTotal',
                                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                                )
                              else
                                const SizedBox.shrink(),
                              Text(
                                '${(_progress * 100).toStringAsFixed(1)}%',
                                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Selection toolbar - appears when text is selected
          if (_selectionRect != null && _selectionCfi != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: (widget.embedded ? 0 : MediaQuery.of(context).padding.bottom) + 16,
              child: Center(
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(28),
                  color: cs.surfaceContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final color in HighlightColor.values)
                          _HighlightColorButton(
                            color: Color(int.parse('FF${color.hex.substring(1)}', radix: 16)),
                            onTap: () => _addHighlight(color),
                          ),
                        _divider(cs),
                        IconButton(
                          icon: Icon(Icons.copy_rounded, size: 20, color: cs.onSurfaceVariant),
                          onPressed: _copySelection,
                          tooltip: 'Copy',
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          icon: Icon(Icons.search_rounded, size: 20, color: cs.onSurfaceVariant),
                          onPressed: _searchSelection,
                          tooltip: 'Search',
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          icon: Icon(Icons.menu_book_rounded, size: 20, color: cs.onSurfaceVariant),
                          onPressed: _defineSelection,
                          tooltip: 'Define',
                          visualDensity: VisualDensity.compact,
                        ),
                        _divider(cs),
                        IconButton(
                          icon: Icon(Icons.close_rounded, size: 20, color: cs.onSurfaceVariant),
                          onPressed: () => setState(() => _clearSelection()),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    return _wrap(viewerBody, bg);
  }
}

class _HighlightColorButton extends StatelessWidget {
  final Color color;
  final VoidCallback onTap;

  const _HighlightColorButton({required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.black.withValues(alpha: 0.15),
              width: 1,
            ),
          ),
        ),
      ),
    );
  }
}
