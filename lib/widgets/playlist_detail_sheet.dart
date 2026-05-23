import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'overlay_toast.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../l10n/app_localizations.dart';
import '../services/wording.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';
import '../services/download_service.dart';
import '../screens/app_shell.dart';
import 'book_detail_sheet.dart';
import 'episode_list_sheet.dart';
import 'stackable_sheet.dart';

class PlaylistDetailSheet extends StatefulWidget {
  final String playlistId;
  final ScrollController? scrollController;

  const PlaylistDetailSheet({
    super.key,
    required this.playlistId,
    this.scrollController,
  });

  static void show(BuildContext context, String playlistId) {
    showStackableSheet(
      context: context,
      useSafeArea: true,
      showHandle: true,
      maxChildSize: 0.95,
      builder: (context, scrollController) => PlaylistDetailSheet(
        playlistId: playlistId,
        scrollController: scrollController,
      ),
    );
  }

  @override
  State<PlaylistDetailSheet> createState() => _PlaylistDetailSheetState();
}

class _PlaylistDetailSheetState extends State<PlaylistDetailSheet> {
  bool _reordering = false;
  bool _gridView = false;
  List<Map<String, dynamic>>? _reorderItems;
  bool _selectMode = false;
  final Set<String> _selectedKeys = {}; // "libraryItemId" or "libraryItemId-episodeId"
  bool _isBatchUpdating = false;

  /// Find episode data from the playlist item's top-level 'episode' field,
  /// or from the library item's media.episodes array as fallback.
  Map<String, dynamic>? _findEpisode(Map<String, dynamic> playlistItem, Map<String, dynamic> libraryItem, String episodeId) {
    // Server includes episode as top-level field on playlist items
    final topEp = playlistItem['episode'] as Map<String, dynamic>?;
    if (topEp != null) return topEp;
    // Fallback: look in library item's episodes array
    final media = libraryItem['media'] as Map<String, dynamic>? ?? {};
    final episodes = media['episodes'] as List<dynamic>? ?? [];
    return episodes.cast<Map<String, dynamic>>().where(
      (e) => e['id'] == episodeId,
    ).firstOrNull;
  }

  /// Get episode title from playlist item data.
  String? _getEpisodeTitle(Map<String, dynamic> playlistItem, Map<String, dynamic> libraryItem, String episodeId) {
    return _findEpisode(playlistItem, libraryItem, episodeId)?['title'] as String?;
  }

  /// Open the correct detail sheet for a playlist item.
  void _openItem(Map<String, dynamic> playlistItem, Map<String, dynamic> libraryItem, String libraryItemId, String? episodeId) {
    if (episodeId != null) {
      final ep = _findEpisode(playlistItem, libraryItem, episodeId);
      if (ep != null) {
        EpisodeDetailSheet.show(context, libraryItem, ep);
      } else {
        EpisodeListSheet.show(context, libraryItem);
      }
    } else {
      showBookDetailSheet(context, libraryItemId);
    }
  }

  String _itemKey(Map<String, dynamic> item) {
    final libraryItemId = item['libraryItemId'] as String? ?? '';
    final episodeId = item['episodeId'] as String?;
    return episodeId != null ? '$libraryItemId-$episodeId' : libraryItemId;
  }

  Future<void> _batchMarkFinished(bool finished, LibraryProvider lib) async {
    if (_selectedKeys.isEmpty) return;
    final api = context.read<AuthProvider>().apiService;
    if (api == null) return;

    setState(() => _isBatchUpdating = true);

    final playlist = lib.playlists.cast<Map<String, dynamic>>().where(
      (p) => p['id'] == widget.playlistId,
    ).firstOrNull;
    final items = (playlist?['items'] as List<dynamic>?) ?? [];

    for (final key in List<String>.from(_selectedKeys)) {
      final item = items.cast<Map<String, dynamic>>().where(
        (i) => _itemKey(i) == key,
      ).firstOrNull;
      if (item == null) continue;

      final libraryItemId = item['libraryItemId'] as String? ?? '';
      final episodeId = item['episodeId'] as String?;
      final libraryItem = item['libraryItem'] as Map<String, dynamic>?;
      final media = libraryItem?['media'] as Map<String, dynamic>? ?? {};
      final duration = (media['duration'] as num?)?.toDouble() ?? 0;

      if (episodeId != null) {
        if (finished) {
          await api.updateEpisodeProgress(libraryItemId, episodeId,
            currentTime: duration, duration: duration, isFinished: true);
          lib.markFinishedLocally('$libraryItemId-$episodeId', skipAutoAdvance: true);
        } else {
          final pd = lib.getProgressData('$libraryItemId-$episodeId');
          final ct = (pd?['currentTime'] as num?)?.toDouble() ?? 0;
          await api.updateEpisodeProgress(libraryItemId, episodeId,
            currentTime: ct, duration: duration, isFinished: false);
        }
      } else {
        if (finished) {
          await api.markFinished(libraryItemId, duration);
          lib.markFinishedLocally(libraryItemId, skipAutoAdvance: true);
        } else {
          final pd = lib.getProgressData(libraryItemId);
          final ct = (pd?['currentTime'] as num?)?.toDouble() ?? 0;
          await api.markNotFinished(libraryItemId, currentTime: ct, duration: duration);
        }
      }
    }

    await lib.refresh();
    if (mounted) {
      final count = _selectedKeys.length;
      final l = AppLocalizations.of(context)!;
      setState(() {
        _isBatchUpdating = false;
        _selectMode = false;
        _selectedKeys.clear();
      });
      showOverlayToast(
        context,
        finished
            ? l.playlistDetailItemsMarkedFinished(count)
            : l.playlistDetailItemsMarkedUnfinished(count),
        icon: finished ? Icons.check_circle_rounded : Icons.undo_rounded,
      );
    }
  }

  Future<void> _batchRemove(LibraryProvider lib) async {
    if (_selectedKeys.isEmpty) return;
    setState(() => _isBatchUpdating = true);

    final playlist = lib.playlists.cast<Map<String, dynamic>>().where(
      (p) => p['id'] == widget.playlistId,
    ).firstOrNull;
    final items = (playlist?['items'] as List<dynamic>?) ?? [];

    for (final key in List<String>.from(_selectedKeys)) {
      final item = items.cast<Map<String, dynamic>>().where(
        (i) => _itemKey(i) == key,
      ).firstOrNull;
      if (item == null) continue;
      final libraryItemId = item['libraryItemId'] as String? ?? '';
      final episodeId = item['episodeId'] as String?;
      await lib.removeFromPlaylist(widget.playlistId, libraryItemId, episodeId: episodeId);
    }

    if (mounted) {
      final count = _selectedKeys.length;
      final l = AppLocalizations.of(context)!;
      setState(() {
        _isBatchUpdating = false;
        _selectMode = false;
        _selectedKeys.clear();
      });
      showOverlayToast(
        context,
        l.playlistDetailItemsRemoved(count),
        icon: Icons.playlist_remove_rounded,
      );
    }
  }

  Future<void> _removeItem(
    LibraryProvider lib,
    String libraryItemId, {
    String? episodeId,
  }) async {
    await lib.removeFromPlaylist(
      widget.playlistId, libraryItemId, episodeId: episodeId,
    );
  }

  Future<void> _deletePlaylist(BuildContext context, LibraryProvider lib) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.deletePlaylist),
        content: Text(l.deletePlaylistContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await lib.deletePlaylist(widget.playlistId);
      if (context.mounted) Navigator.pop(context);
    }
  }

  void _startReorder(List<dynamic> items) {
    setState(() {
      _reordering = true;
      _reorderItems = items
          .map((i) => Map<String, dynamic>.from(i as Map))
          .toList();
    });
  }

  Future<void> _saveReorder(LibraryProvider lib) async {
    if (_reorderItems != null) {
      await lib.reorderPlaylistItems(widget.playlistId, _reorderItems!);
    }
    if (mounted) Navigator.pop(context);
  }

  void _cancelReorder() {
    setState(() {
      _reordering = false;
      _reorderItems = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;
    final lib = context.watch<LibraryProvider>();

    final playlist = lib.playlists.cast<Map<String, dynamic>>().where(
      (p) => p['id'] == widget.playlistId,
    ).firstOrNull;

    if (playlist == null) {
      return ListView(controller: widget.scrollController, children: [
        const SizedBox(height: 80),
        Center(child: Text(l.playlistNotFound)),
      ]);
    }

    final name = playlist['name'] as String? ?? l.playlistDetailDefaultName;
    final items = (playlist['items'] as List<dynamic>?) ?? [];

    return Column(children: [
      const SizedBox(height: 4),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(children: [
          if (_reordering) ...[
            GestureDetector(
              onTap: _cancelReorder,
              child: Text(l.cancel, style: tt.labelMedium?.copyWith(
                color: cs.onSurfaceVariant, fontWeight: FontWeight.w500,
              )),
            ),
            const Spacer(),
            Text(name, style: tt.titleMedium?.copyWith(
              fontWeight: FontWeight.w600, color: cs.onSurface,
            )),
            const Spacer(),
            GestureDetector(
              onTap: () => _saveReorder(lib),
              child: Text(l.done, style: tt.labelMedium?.copyWith(
                color: cs.primary, fontWeight: FontWeight.w600,
              )),
            ),
          ] else if (_selectMode) ...[
            GestureDetector(
              onTap: () => setState(() {
                _selectMode = false;
                _selectedKeys.clear();
              }),
              child: Icon(Icons.close_rounded, size: 20, color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
            Text(l.selectedCount(_selectedKeys.length),
              style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                setState(() {
                  if (_selectedKeys.length == items.length) {
                    _selectedKeys.clear();
                  } else {
                    _selectedKeys.clear();
                    for (final i in items) {
                      _selectedKeys.add(_itemKey(i as Map<String, dynamic>));
                    }
                  }
                });
              },
              child: Text(l.selectAll,
                style: TextStyle(fontSize: 12, color: cs.primary, fontWeight: FontWeight.w500)),
            ),
            const Spacer(),
          ] else ...[
            GestureDetector(
              onTap: () => _deletePlaylist(context, lib),
              child: Icon(Icons.delete_outline_rounded, size: 20,
                color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Icon(Icons.playlist_play_rounded, size: 20, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(name, style: tt.titleMedium?.copyWith(
                fontWeight: FontWeight.w600, color: cs.onSurface,
              )),
            ),
            Text(l.playlistDetailItemCount(items.length),
              style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() => _gridView = !_gridView),
              child: Icon(
                _gridView ? Icons.view_list_rounded : Icons.grid_view_rounded,
                size: 20, color: cs.onSurfaceVariant),
            ),
            if (items.length > 1) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _selectMode = true),
                child: Icon(Icons.checklist_rounded, size: 20,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _startReorder(items),
                child: Icon(Icons.tune_rounded, size: 20,
                  color: cs.onSurfaceVariant),
              ),
            ],
          ],
        ]),
      ),
      const SizedBox(height: 12),
      Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.3),
        indent: 20, endIndent: 20),
      if (!_reordering && !_selectMode)
        _buildPlayButton(cs, lib, items, l),
      // Content
      Expanded(
        child: _reordering
            ? _buildReorderList(cs, tt, lib, l)
            : _selectMode
                ? _buildSelectList(cs, tt, lib, items, l)
                : _gridView
                    ? _buildGrid(cs, tt, lib, items, l)
                    : _buildItemList(cs, tt, lib, items, l),
      ),
      // Batch action bar
      if (_selectMode && _selectedKeys.isNotEmpty)
        Container(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + MediaQuery.of(context).viewPadding.bottom),
          decoration: BoxDecoration(
            color: cs.surfaceContainer,
            border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.3))),
          ),
          child: _isBatchUpdating
              ? Center(child: SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary)))
              : Row(children: [
                  Expanded(child: FilledButton.tonalIcon(
                    onPressed: () => _batchMarkFinished(true, lib),
                    icon: const Icon(Icons.check_circle_rounded, size: 18),
                    label: Text(l.finished),
                    style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: OutlinedButton.icon(
                    onPressed: () => _batchMarkFinished(false, lib),
                    icon: const Icon(Icons.radio_button_unchecked_rounded, size: 18),
                    label: Text(l.playlistDetailUnfinished),
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                  )),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => _batchRemove(lib),
                    icon: Icon(Icons.playlist_remove_rounded, color: cs.error),
                    tooltip: l.playlistDetailRemoveFromPlaylist,
                    style: IconButton.styleFrom(
                      backgroundColor: cs.error.withValues(alpha: 0.1),
                    ),
                  ),
                ]),
        ),
    ]);
  }

  Widget _buildPlayButton(
    ColorScheme cs,
    LibraryProvider lib,
    List<dynamic> items,
    AppLocalizations l,
  ) {
    final firstIdx = lib.firstUnfinishedPlaylistIndex(items);
    final allFinished = items.isNotEmpty && firstIdx < 0;
    final enabled = items.isNotEmpty && firstIdx >= 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: enabled
              ? () async {
                  HapticFeedback.selectionClick();
                  // Pop the sheet first; otherwise auto-expand pushes the
                  // expanded player on top of us and our pop closes it.
                  final playlistId = widget.playlistId;
                  Navigator.pop(context);
                  AppShell.goToAbsorbingGlobal();
                  await PlayerSettings.setQueueModePlaylist(playlistId);
                  await lib.playPlaylistFromStart(playlistId);
                }
              : null,
          icon: Icon(allFinished
              ? Icons.check_circle_outline_rounded
              : Icons.play_arrow_rounded),
          label: Text(allFinished ? l.playlistAllFinished : l.playlistPlayAction),
        ),
      ),
    );
  }

  Widget _buildReorderList(ColorScheme cs, TextTheme tt, LibraryProvider lib, AppLocalizations l) {
    final items = _reorderItems!;
    return ReorderableListView.builder(
      padding: EdgeInsets.only(top: 8, bottom: 8 + MediaQuery.of(context).viewPadding.bottom),
      onReorderStart: (_) => HapticFeedback.mediumImpact(),
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex--;
          final item = items.removeAt(oldIndex);
          items.insert(newIndex, item);
        });
      },
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final libraryItemId = item['libraryItemId'] as String? ?? '';
        final episodeId = item['episodeId'] as String?;
        final libraryItem = item['libraryItem'] as Map<String, dynamic>?;
        if (libraryItem == null) {
          return SizedBox.shrink(key: ValueKey('$libraryItemId-${episodeId ?? ''}-$index'));
        }

        final media = libraryItem['media'] as Map<String, dynamic>? ?? {};
        final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
        final title = metadata['title'] as String? ?? l.unknown;
        final coverUrl = lib.getCoverUrl(libraryItemId);

        String? episodeTitle;
        if (episodeId != null) {
          episodeTitle = _getEpisodeTitle(item, libraryItem, episodeId);
        }

        return Container(
          key: ValueKey('$libraryItemId-${episodeId ?? ''}'),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
          ),
          child: ListTile(
            dense: true,
            leading: SizedBox(
              width: 36, height: 36,
              child: Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: coverUrl != null
                      ? (coverUrl.startsWith('/')
                          ? Image.file(File(coverUrl), fit: BoxFit.cover, width: 36, height: 36,
                              errorBuilder: (_, __, ___) => _placeholder(cs))
                          : Image.network(coverUrl, fit: BoxFit.cover, width: 36, height: 36,
                              headers: lib.mediaHeaders,
                              errorBuilder: (_, __, ___) => _placeholder(cs)))
                      : _placeholder(cs),
                ),
                if (PlayerSettings.showExplicitBadge && metadata['explicit'] == true)
                  Positioned(
                    top: 2, right: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(l.bookCardExplicitBadge, style: const TextStyle(color: Colors.white, fontSize: 7, fontWeight: FontWeight.w800)),
                    ),
                  ),
              ]),
            ),
            title: Text(
              episodeTitle ?? title,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                color: cs.onSurface),
            ),
            trailing: ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(Icons.drag_handle_rounded, size: 18,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectList(ColorScheme cs, TextTheme tt, LibraryProvider lib, List<dynamic> items, AppLocalizations l) {
    return ListView.builder(
      controller: widget.scrollController,
      padding: EdgeInsets.only(bottom: (_selectedKeys.isNotEmpty ? 64.0 : 32.0) + MediaQuery.of(context).viewPadding.bottom),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index] as Map<String, dynamic>;
        final libraryItemId = item['libraryItemId'] as String? ?? '';
        final episodeId = item['episodeId'] as String?;
        final libraryItem = item['libraryItem'] as Map<String, dynamic>?;
        if (libraryItem == null) return const SizedBox.shrink();

        final media = libraryItem['media'] as Map<String, dynamic>? ?? {};
        final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
        final title = metadata['title'] as String? ?? l.unknown;
        final author = metadata['authorName'] as String? ?? '';
        final coverUrl = lib.getCoverUrl(libraryItemId);
        final key = _itemKey(item);
        final selected = _selectedKeys.contains(key);

        String? episodeTitle;
        if (episodeId != null) {
          episodeTitle = _getEpisodeTitle(item, libraryItem, episodeId);
        }

        return InkWell(
          onTap: () => setState(() {
            if (selected) { _selectedKeys.remove(key); } else { _selectedKeys.add(key); }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(children: [
              Checkbox(
                value: selected,
                onChanged: (v) => setState(() {
                  if (v == true) { _selectedKeys.add(key); } else { _selectedKeys.remove(key); }
                }),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 40, height: 40,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: coverUrl != null
                      ? (coverUrl.startsWith('/')
                          ? Image.file(File(coverUrl), fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _placeholder(cs))
                          : Image.network(coverUrl, fit: BoxFit.cover,
                              headers: lib.mediaHeaders,
                              errorBuilder: (_, __, ___) => _placeholder(cs)))
                      : _placeholder(cs),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(episodeTitle ?? title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: cs.onSurface)),
                  Text(episodeTitle != null ? title : author, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                ],
              )),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildItemList(ColorScheme cs, TextTheme tt, LibraryProvider lib, List<dynamic> items, AppLocalizations l) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final doneColor = isDark ? Colors.greenAccent[400]! : Colors.green.shade700;

    return ListView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4).copyWith(bottom: 40),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index] as Map<String, dynamic>;
        final libraryItemId = item['libraryItemId'] as String? ?? '';
        final episodeId = item['episodeId'] as String?;
        final libraryItem = item['libraryItem'] as Map<String, dynamic>?;

        if (libraryItem == null) return const SizedBox.shrink();

        final media = libraryItem['media'] as Map<String, dynamic>? ?? {};
        final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
        final title = metadata['title'] as String? ?? l.unknown;
        final author = metadata['authorName'] as String? ?? '';
        final coverUrl = lib.getCoverUrl(libraryItemId);
        final progressKey = episodeId != null ? '$libraryItemId-$episodeId' : libraryItemId;
        final progress = lib.getProgress(progressKey);
        final isFinished = lib.getProgressData(progressKey)?['isFinished'] == true;
        final isDownloaded = DownloadService().isDownloaded(libraryItemId);

        String? episodeTitle;
        if (episodeId != null) {
          episodeTitle = _getEpisodeTitle(item, libraryItem, episodeId);
        }

        final isOnAbsorbing = lib.isOnAbsorbingList(progressKey);
        return Dismissible(
          key: ValueKey('$libraryItemId-${episodeId ?? ''}'),
          direction: DismissDirection.horizontal,
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.startToEnd) {
              if (isOnAbsorbing) return false;
              await lib.addToAbsorbingQueue(progressKey);
              lib.absorbingItemCache[progressKey] = Map<String, dynamic>.from(libraryItem);
              HapticFeedback.mediumImpact();
              if (context.mounted) {
                showOverlayToast(context, Wording.of(context).playlistDetailAddedToAbsorbing(episodeTitle ?? title), icon: Icons.add_circle_outline_rounded);
              }
              return false;
            }
            // endToStart = delete
            _removeItem(lib, libraryItemId, episodeId: episodeId);
            return true;
          },
          background: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 20),
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.add_circle_outline_rounded, color: cs.primary),
          ),
          secondaryBackground: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: cs.error.withValues(alpha: 0.1),
            child: Icon(Icons.delete_rounded, color: cs.error),
          ),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              elevation: 0,
              color: cs.surfaceContainerHigh,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _openItem(item, libraryItem, libraryItemId, episodeId),
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  height: 112,
                  child: Row(children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: Stack(children: [
                        Positioned.fill(
                          child: coverUrl != null
                              ? (coverUrl.startsWith('/')
                                  ? Image.file(File(coverUrl), fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => _placeholder(cs))
                                  : CachedNetworkImage(
                                      imageUrl: coverUrl, fit: BoxFit.cover,
                                      httpHeaders: lib.mediaHeaders,
                                      placeholder: (_, __) => _placeholder(cs),
                                      errorWidget: (_, __, ___) => _placeholder(cs),
                                    ))
                              : _placeholder(cs),
                        ),
                        if (progress > 0 && !isFinished)
                          Positioned(
                            left: 0, right: 0, bottom: 0,
                            child: LinearProgressIndicator(
                              value: progress.clamp(0.0, 1.0),
                              minHeight: 3,
                              backgroundColor: Colors.black38,
                              valueColor: AlwaysStoppedAnimation(cs.primary),
                            ),
                          ),
                        if (isFinished || isDownloaded)
                          Positioned(
                            left: 0, right: 0, bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: 0.85),
                                    Colors.black.withValues(alpha: 0.0),
                                  ],
                                ),
                              ),
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                if (isFinished)
                                  Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                                    Icon(Icons.check_circle_rounded, size: 10, color: doneColor),
                                    const SizedBox(width: 3),
                                    Text(l.playlistDetailDone, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: doneColor)),
                                  ]),
                                if (isDownloaded)
                                  Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                                    Icon(Icons.download_done_rounded, size: 10, color: cs.primary),
                                    const SizedBox(width: 3),
                                    Text(l.saved, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: cs.primary)),
                                  ]),
                              ]),
                            ),
                          ),
                      ]),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(episodeTitle ?? title,
                              maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface)),
                            const SizedBox(height: 4),
                            Text(episodeTitle != null ? title : author,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGrid(ColorScheme cs, TextTheme tt, LibraryProvider lib, List<dynamic> items, AppLocalizations l) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final doneColor = isDark ? Colors.greenAccent[400]! : Colors.green.shade700;

    return GridView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4)
          .copyWith(bottom: 40),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.62,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index] as Map<String, dynamic>;
        final libraryItemId = item['libraryItemId'] as String? ?? '';
        final episodeId = item['episodeId'] as String?;
        final libraryItem = item['libraryItem'] as Map<String, dynamic>?;
        if (libraryItem == null) return const SizedBox.shrink();

        final media = libraryItem['media'] as Map<String, dynamic>? ?? {};
        final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
        final title = metadata['title'] as String? ?? l.unknown;
        final author = metadata['authorName'] as String? ?? '';
        final coverUrl = lib.getCoverUrl(libraryItemId);
        final isExplicit = PlayerSettings.showExplicitBadge && metadata['explicit'] == true;
        final progressKey = episodeId != null ? '$libraryItemId-$episodeId' : libraryItemId;
        final progress = lib.getProgress(progressKey);
        final isFinished = lib.getProgressData(progressKey)?['isFinished'] == true;
        final isDownloaded = DownloadService().isDownloaded(libraryItemId);

        String? episodeTitle;
        if (episodeId != null) {
          episodeTitle = _getEpisodeTitle(item, libraryItem, episodeId);
        }

        return GestureDetector(
          onTap: () => _openItem(item, libraryItem, libraryItemId, episodeId),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(children: [
                    Positioned.fill(
                      child: coverUrl != null
                          ? (coverUrl.startsWith('/')
                              ? Image.file(File(coverUrl), fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => _placeholder(cs))
                              : CachedNetworkImage(
                                  imageUrl: coverUrl, fit: BoxFit.cover,
                                  httpHeaders: lib.mediaHeaders,
                                  placeholder: (_, __) => _placeholder(cs),
                                  errorWidget: (_, __, ___) => _placeholder(cs),
                                ))
                          : _placeholder(cs),
                    ),
                    if (isExplicit)
                      Positioned(
                        top: 4, right: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(l.bookCardExplicitBadge, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
                        ),
                      ),
                    if (progress > 0 && !isFinished)
                      Positioned(
                        left: 0, right: 0, bottom: 0,
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 3,
                          backgroundColor: Colors.black38,
                          valueColor: AlwaysStoppedAnimation(cs.primary),
                        ),
                      ),
                    if (isFinished || isDownloaded)
                      Positioned(
                        left: 0, right: 0, bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.85),
                                Colors.black.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            if (isFinished)
                              Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.check_circle_rounded, size: 10, color: doneColor),
                                const SizedBox(width: 3),
                                Text(l.playlistDetailDone, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: doneColor)),
                              ]),
                            if (isDownloaded)
                              Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.download_done_rounded, size: 10, color: cs.primary),
                                const SizedBox(width: 3),
                                Text(l.saved, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: cs.primary)),
                              ]),
                          ]),
                        ),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 6),
              Text(episodeTitle ?? title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: tt.labelSmall?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface)),
              if ((episodeTitle != null ? title : author).isNotEmpty)
                Text(episodeTitle != null ? title : author, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: tt.labelSmall?.copyWith(fontSize: 10, color: cs.onSurfaceVariant)),
            ],
          ),
        );
      },
    );
  }

  Widget _placeholder(ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHigh,
      child: Icon(Icons.music_note_rounded, size: 20,
        color: cs.onSurfaceVariant.withValues(alpha: 0.3)),
    );
  }
}
