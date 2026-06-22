import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../widgets/absorb_page_header.dart';
import '../widgets/filesystem_picker_screen.dart';
import '../widgets/overlay_toast.dart';

/// Create or edit a library. Pass [library] (the GET /api/libraries object) to
/// edit; omit it to create. Returns true via Navigator.pop when a change was
/// saved so the caller can refresh.
class AdminLibraryEditScreen extends StatefulWidget {
  final Map<String, dynamic>? library;
  const AdminLibraryEditScreen({super.key, this.library});

  @override
  State<AdminLibraryEditScreen> createState() => _AdminLibraryEditScreenState();
}

class _AdminLibraryEditScreenState extends State<AdminLibraryEditScreen> {
  // The full ABS library icon set (client store globals.js libraryIcons).
  static const _icons = [
    'database', 'audiobookshelf', 'books-1', 'books-2', 'book-1', 'microphone-1',
    'microphone-3', 'radio', 'podcast', 'rss', 'headphones', 'music', 'file-picture',
    'rocket', 'power', 'star', 'heart',
  ];

  // ABS uses its own icon font; map each name to the nearest Material icon for display.
  static IconData _absIcon(String name) {
    switch (name) {
      case 'audiobookshelf': return Icons.library_books_rounded;
      case 'books-1': return Icons.menu_book_rounded;
      case 'books-2': return Icons.auto_stories_rounded;
      case 'book-1': return Icons.book_rounded;
      case 'microphone-1': return Icons.mic_rounded;
      case 'microphone-3': return Icons.mic_external_on_rounded;
      case 'radio': return Icons.radio_rounded;
      case 'podcast': return Icons.podcasts_rounded;
      case 'rss': return Icons.rss_feed_rounded;
      case 'headphones': return Icons.headphones_rounded;
      case 'music': return Icons.music_note_rounded;
      case 'file-picture': return Icons.image_rounded;
      case 'rocket': return Icons.rocket_launch_rounded;
      case 'power': return Icons.power_rounded;
      case 'star': return Icons.star_rounded;
      case 'heart': return Icons.favorite_rounded;
      case 'database':
      default: return Icons.storage_rounded;
    }
  }

  bool get _isEdit => widget.library != null;

  final _name = TextEditingController();
  String _mediaType = 'book';
  String _provider = 'google';
  String _icon = 'database';
  // Each folder: existing -> {id, fullPath}; new -> {fullPath}.
  List<Map<String, dynamic>> _folders = [];
  List<String> _originalFolderIds = [];

  // settings
  num _coverAspectRatio = 1.0;
  bool _disableWatcher = false;
  bool _skipAsin = false;
  bool _skipIsbn = false;
  bool _hideSingleSeries = false;
  bool _audiobooksOnly = false;
  bool _epubScripted = false;
  bool _laterBooksOnly = false;
  final _podcastRegion = TextEditingController();
  final _markPercent = TextEditingController();
  final _markTime = TextEditingController();
  final _autoScan = TextEditingController();

  List<String> _providers = const ['google', 'audible', 'openlibrary', 'itunes', 'audnexus', 'fantlab'];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final lib = widget.library;
    if (lib != null) {
      _name.text = (lib['name'] as String?) ?? '';
      _mediaType = (lib['mediaType'] as String?) ?? 'book';
      _provider = (lib['provider'] as String?) ?? 'google';
      _icon = (lib['icon'] as String?) ?? 'database';
      _folders = ((lib['folders'] as List?) ?? [])
          .whereType<Map>()
          .map((f) => {'id': f['id'], 'fullPath': f['fullPath']})
          .toList();
      _originalFolderIds = _folders.map((f) => f['id'].toString()).toList();
      final s = (lib['settings'] as Map?)?.cast<String, dynamic>() ?? {};
      _coverAspectRatio = (s['coverAspectRatio'] as num?) ?? 1;
      _disableWatcher = s['disableWatcher'] as bool? ?? false;
      _skipAsin = s['skipMatchingMediaWithAsin'] as bool? ?? false;
      _skipIsbn = s['skipMatchingMediaWithIsbn'] as bool? ?? false;
      _hideSingleSeries = s['hideSingleBookSeries'] as bool? ?? false;
      _audiobooksOnly = s['audiobooksOnly'] as bool? ?? false;
      _epubScripted = s['epubsAllowScriptedContent'] as bool? ?? false;
      _laterBooksOnly = s['onlyShowLaterBooksInContinueSeries'] as bool? ?? false;
      _podcastRegion.text = (s['podcastSearchRegion'] as String?) ?? 'us';
      final pct = s['markAsFinishedPercentComplete'];
      _markPercent.text = pct == null ? '' : '$pct';
      _markTime.text = '${s['markAsFinishedTimeRemaining'] ?? 10}';
      _autoScan.text = (s['autoScanCronExpression'] as String?) ?? '';
    } else {
      _markTime.text = '10';
      _podcastRegion.text = 'us';
    }
    _loadProviders();
  }

  Future<void> _loadProviders() async {
    final api = context.read<AuthProvider>().apiService;
    if (api == null) return;
    final list = await api.getMetadataProviders();
    if (!mounted) return;
    setState(() {
      _providers = list;
      if (!_providers.contains(_provider)) _providers = [_provider, ..._providers];
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _podcastRegion.dispose();
    _markPercent.dispose();
    _markTime.dispose();
    _autoScan.dispose();
    super.dispose();
  }

  Map<String, dynamic> _settings() {
    final pctText = _markPercent.text.trim();
    final base = <String, dynamic>{
      'coverAspectRatio': _coverAspectRatio,
      'disableWatcher': _disableWatcher,
      'markAsFinishedPercentComplete': pctText.isEmpty ? null : num.tryParse(pctText),
      'markAsFinishedTimeRemaining': num.tryParse(_markTime.text.trim()) ?? 10,
      'autoScanCronExpression': _autoScan.text.trim().isEmpty ? null : _autoScan.text.trim(),
    };
    if (_mediaType == 'podcast') {
      base['podcastSearchRegion'] = _podcastRegion.text.trim().isEmpty ? 'us' : _podcastRegion.text.trim();
    } else {
      base.addAll({
        'skipMatchingMediaWithAsin': _skipAsin,
        'skipMatchingMediaWithIsbn': _skipIsbn,
        'hideSingleBookSeries': _hideSingleSeries,
        'audiobooksOnly': _audiobooksOnly,
        'epubsAllowScriptedContent': _epubScripted,
        'onlyShowLaterBooksInContinueSeries': _laterBooksOnly,
      });
    }
    return base;
  }

  Future<void> _addFolder() async {
    final path = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const FilesystemPickerScreen()),
    );
    if (path == null || !mounted) return;
    if (_folders.any((f) => f['fullPath'] == path)) return;
    setState(() => _folders = [..._folders, {'fullPath': path}]);
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context)!;
    if (_name.text.trim().isEmpty) {
      showOverlayToast(context, l.libNameRequired, icon: Icons.error_outline_rounded);
      return;
    }
    if (_folders.isEmpty) {
      showOverlayToast(context, l.libNoFolders, icon: Icons.error_outline_rounded);
      return;
    }

    // Warn before removing folders on edit (server cascades item deletion).
    if (_isEdit) {
      final keptIds = _folders.where((f) => f['id'] != null).map((f) => f['id'].toString()).toSet();
      final removed = _originalFolderIds.where((id) => !keptIds.contains(id)).toList();
      if (removed.isNotEmpty) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l.libRemoveFoldersTitle),
            content: Text(l.libRemoveFoldersBody),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.remove)),
            ],
          ),
        );
        if (ok != true) return;
      }
    }

    final api = context.read<AuthProvider>().apiService;
    if (api == null) return;
    setState(() => _saving = true);

    final body = <String, dynamic>{
      'name': _name.text.trim(),
      'mediaType': _mediaType,
      'icon': _icon,
      'provider': _provider,
      'folders': _folders,
      'settings': _settings(),
    };

    bool ok;
    if (_isEdit) {
      ok = await api.updateLibrary(widget.library!['id'].toString(), body);
    } else {
      // folders on create only need fullPath
      body['folders'] = _folders.map((f) => {'fullPath': f['fullPath']}).toList();
      ok = (await api.createLibrary(body)) != null;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    final msg = _isEdit
        ? (ok ? l.libUpdated : l.libUpdateFailed)
        : (ok ? l.libCreated : l.libCreateFailed);
    showOverlayToast(context, msg,
        icon: ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;
    final isPodcast = _mediaType == 'podcast';

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
            child: Row(children: [
              Expanded(child: AbsorbPageHeader(
                  title: _isEdit ? l.libEditTitle : l.libNewTitle, padding: EdgeInsets.zero)),
              IconButton(
                icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              children: [
                TextField(controller: _name,
                    decoration: InputDecoration(labelText: l.libName)),
                const SizedBox(height: 16),

                // Media type — fixed once a library has items.
                Text(l.libMediaType, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 6),
                if (_isEdit)
                  Chip(label: Text(isPodcast ? l.libMediaPodcast : l.libMediaBook))
                else
                  SegmentedButton<String>(
                    segments: [
                      ButtonSegment(value: 'book', label: Text(l.libMediaBook), icon: const Icon(Icons.menu_book_rounded)),
                      ButtonSegment(value: 'podcast', label: Text(l.libMediaPodcast), icon: const Icon(Icons.podcasts_rounded)),
                    ],
                    selected: {_mediaType},
                    onSelectionChanged: (s) => setState(() => _mediaType = s.first),
                  ),
                const SizedBox(height: 16),

                Row(children: [
                  Expanded(child: _labeledDropdown(cs, tt, l.libProvider, _provider, _providers,
                      (v) => setState(() => _provider = v))),
                  const SizedBox(width: 12),
                  Expanded(child: _iconDropdown(cs, tt, _icon,
                      _icons.contains(_icon) ? _icons : [_icon, ..._icons],
                      (v) => setState(() => _icon = v))),
                ]),
                const SizedBox(height: 20),

                // ── Folders ──
                Text(l.libFolders, style: tt.labelLarge?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7), fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(children: [
                    if (_folders.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(l.libNoFolders,
                            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
                      ),
                    ..._folders.map((f) => ListTile(
                          dense: true,
                          leading: Icon(Icons.folder_rounded, color: cs.primary.withValues(alpha: 0.8)),
                          title: Text(f['fullPath']?.toString() ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: IconButton(
                            icon: Icon(Icons.close_rounded, size: 18, color: cs.onSurfaceVariant),
                            onPressed: () => setState(() => _folders = _folders.where((x) => x != f).toList()),
                          ),
                        )),
                    TextButton.icon(
                      onPressed: _addFolder,
                      icon: const Icon(Icons.add_rounded),
                      label: Text(l.libAddFolder),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),

                // ── Advanced ──
                Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: Text(l.libAdvanced, style: tt.titleSmall),
                    children: [
                      _coverShape(cs, tt, l),
                      _switch(tt, l.libDisableWatcher, _disableWatcher, (v) => setState(() => _disableWatcher = v)),
                      if (!isPodcast) ...[
                        _switch(tt, l.libSkipAsin, _skipAsin, (v) => setState(() => _skipAsin = v)),
                        _switch(tt, l.libSkipIsbn, _skipIsbn, (v) => setState(() => _skipIsbn = v)),
                        _switch(tt, l.libHideSingleSeries, _hideSingleSeries, (v) => setState(() => _hideSingleSeries = v)),
                        _switch(tt, l.libAudiobooksOnly, _audiobooksOnly, (v) => setState(() => _audiobooksOnly = v)),
                        _switch(tt, l.libEpubScripted, _epubScripted, (v) => setState(() => _epubScripted = v)),
                        _switch(tt, l.libLaterBooksOnly, _laterBooksOnly, (v) => setState(() => _laterBooksOnly = v)),
                      ],
                      if (isPodcast) ...[
                        const SizedBox(height: 8),
                        TextField(controller: _podcastRegion,
                            decoration: InputDecoration(labelText: l.libPodcastRegion, hintText: 'us')),
                      ],
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(child: TextField(
                          controller: _markPercent,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: l.libMarkPercent),
                        )),
                        const SizedBox(width: 12),
                        Expanded(child: TextField(
                          controller: _markTime,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: l.libMarkTime),
                        )),
                      ]),
                      const SizedBox(height: 12),
                      TextField(controller: _autoScan,
                          decoration: InputDecoration(labelText: l.libAutoScan, hintText: '0 0 * * *')),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary))
                        : const Icon(Icons.save_rounded, size: 18),
                    label: Text(_isEdit ? l.libUpdate : l.libCreate),
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _coverShape(ColorScheme cs, TextTheme tt, AppLocalizations l) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(child: Text(l.libCoverShape, style: tt.bodyMedium)),
          // ABS BookCoverAspectRatio enum: SQUARE = 1, STANDARD = 0.
          SegmentedButton<num>(
            segments: [
              ButtonSegment(value: 1, label: Text(l.libCoverSquare)),
              ButtonSegment(value: 0, label: Text(l.libCoverStandard)),
            ],
            selected: {_coverAspectRatio == 0 ? 0 : 1},
            onSelectionChanged: (s) => setState(() => _coverAspectRatio = s.first),
          ),
        ]),
      );

  Widget _switch(TextTheme tt, String label, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: tt.bodyMedium),
        value: value,
        onChanged: onChanged,
      );

  Widget _iconDropdown(ColorScheme cs, TextTheme tt, String value,
          List<String> options, ValueChanged<String> onChanged) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(AppLocalizations.of(context)!.libIcon, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        DropdownButton<String>(
          value: options.contains(value) ? value : options.first,
          isExpanded: true,
          borderRadius: BorderRadius.circular(12),
          items: options
              .map((o) => DropdownMenuItem(
                    value: o,
                    child: Row(children: [
                      Icon(_absIcon(o), size: 18, color: cs.onSurfaceVariant),
                      const SizedBox(width: 10),
                      Flexible(child: Text(o, overflow: TextOverflow.ellipsis)),
                    ]),
                  ))
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ]);

  Widget _labeledDropdown(ColorScheme cs, TextTheme tt, String label, String value,
          List<String> options, ValueChanged<String> onChanged) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        DropdownButton<String>(
          value: options.contains(value) ? value : options.first,
          isExpanded: true,
          borderRadius: BorderRadius.circular(12),
          items: options.map((o) => DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis))).toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ]);
}
