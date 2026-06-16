import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../widgets/absorb_page_header.dart';
import '../widgets/overlay_toast.dart';
import 'admin_library_edit_screen.dart';

/// Library management: list, reorder (drag), create, edit, delete.
class AdminLibrariesScreen extends StatefulWidget {
  final List<dynamic> libraries;
  const AdminLibrariesScreen({super.key, required this.libraries});

  @override
  State<AdminLibrariesScreen> createState() => _AdminLibrariesScreenState();
}

class _AdminLibrariesScreenState extends State<AdminLibrariesScreen> {
  List<Map<String, dynamic>> _libraries = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _libraries = widget.libraries.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    _refresh();
  }

  Future<void> _refresh() async {
    final api = context.read<AuthProvider>().apiService;
    if (api == null) return;
    setState(() => _loading = true);
    final libs = await api.getLibraries();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _libraries = libs.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    });
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _libraries.removeAt(oldIndex);
      _libraries.insert(newIndex, item);
    });
    final api = context.read<AuthProvider>().apiService;
    if (api == null) return;
    final order = [
      for (var i = 0; i < _libraries.length; i++) {'id': _libraries[i]['id'], 'newOrder': i + 1}
    ];
    final ok = await api.reorderLibraries(order);
    if (!mounted || ok) return;
    showOverlayToast(context, AppLocalizations.of(context)!.libReorderFailed,
        icon: Icons.error_outline_rounded);
    _refresh();
  }

  Future<void> _openEditor([Map<String, dynamic>? library]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AdminLibraryEditScreen(library: library)),
    );
    if (changed == true) _refresh();
  }

  Future<void> _delete(Map<String, dynamic> lib) async {
    final l = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.libDeleteTitle),
        content: Text(l.libDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final api = context.read<AuthProvider>().apiService;
    if (api == null) return;
    final success = await api.deleteLibrary(lib['id'].toString());
    if (!mounted) return;
    showOverlayToast(context, success ? l.libDeleted : l.libDeleteFailed,
        icon: success ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded);
    if (success) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
            child: Row(children: [
              Expanded(child: AbsorbPageHeader(title: l.adminLibrariesManage, padding: EdgeInsets.zero)),
              IconButton(
                icon: Icon(Icons.add_rounded, color: cs.primary),
                tooltip: l.libNewTitle,
                onPressed: () => _openEditor(),
              ),
              IconButton(
                icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _libraries.isEmpty
                ? Center(
                    child: Text(l.libNoneYet,
                        style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                    itemCount: _libraries.length,
                    onReorder: _reorder,
                    itemBuilder: (context, i) {
                      final lib = _libraries[i];
                      final folders = (lib['folders'] as List?)?.length ?? 0;
                      final isPodcast = lib['mediaType'] == 'podcast';
                      return Container(
                        key: ValueKey(lib['id']),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                            color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
                        child: ListTile(
                          onTap: () => _openEditor(lib),
                          leading: Icon(isPodcast ? Icons.podcasts_rounded : Icons.menu_book_rounded,
                              color: cs.primary),
                          title: Text(lib['name']?.toString() ?? '–',
                              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                              '${isPodcast ? l.libMediaPodcast : l.libMediaBook} · ${l.libFolderCount(folders)}',
                              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              icon: Icon(Icons.delete_outline_rounded, color: cs.onSurfaceVariant),
                              onPressed: () => _delete(lib),
                            ),
                            ReorderableDragStartListener(
                              index: i,
                              child: Icon(Icons.drag_handle_rounded, color: cs.onSurface.withValues(alpha: 0.3)),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}
