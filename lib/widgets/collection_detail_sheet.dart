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
import 'book_detail_sheet.dart';
import 'stackable_sheet.dart';

class CollectionDetailSheet extends StatefulWidget {
  final String collectionId;
  final ScrollController? scrollController;

  const CollectionDetailSheet({
    super.key,
    required this.collectionId,
    this.scrollController,
  });

  static void show(BuildContext context, String collectionId) {
    showStackableSheet(
      context: context,
      useSafeArea: true,
      showHandle: true,
      maxChildSize: 0.95,
      builder: (context, scrollController) => CollectionDetailSheet(
        collectionId: collectionId,
        scrollController: scrollController,
      ),
    );
  }

  @override
  State<CollectionDetailSheet> createState() => _CollectionDetailSheetState();
}

class _CollectionDetailSheetState extends State<CollectionDetailSheet> {
  bool _reordering = false;
  bool _gridView = false;
  List<Map<String, dynamic>>? _reorderItems;

  Future<void> _removeItem(LibraryProvider lib, String libraryItemId) async {
    await lib.removeFromCollection(widget.collectionId, libraryItemId);
  }

  Future<void> _deleteCollection(BuildContext context, LibraryProvider lib) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.deleteCollection),
        content: Text(l.deleteCollectionContent),
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
      final status = await lib.deleteCollection(widget.collectionId);
      if (!context.mounted) return;
      if (status == 200) {
        Navigator.pop(context);
      } else if (status == 403) {
        showOverlayToast(context, l.deletePermissionRequired,
            icon: Icons.lock_outline_rounded);
      } else {
        showOverlayToast(context, l.deleteCollectionFailed,
            icon: Icons.error_outline_rounded);
      }
    }
  }

  void _startReorder(List<dynamic> books) {
    setState(() {
      _reordering = true;
      _reorderItems = books
          .map((b) => Map<String, dynamic>.from(b as Map))
          .toList();
    });
  }

  Future<void> _saveReorder(LibraryProvider lib) async {
    if (_reorderItems != null) {
      final bookIds = _reorderItems!
          .map((b) => b['id'] as String? ?? '')
          .where((id) => id.isNotEmpty)
          .toList();
      await lib.reorderCollectionBooks(widget.collectionId, bookIds);
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
    final auth = context.read<AuthProvider>();
    // Both gated at isAdmin in the UI; server returns 403 when admin lacks
    // the `delete` permission flag and we show a friendly toast then.
    final canEditCollection = auth.isAdmin;
    final canDeleteCollection = auth.isAdmin;

    final collection = lib.collections.cast<Map<String, dynamic>>().where(
      (c) => c['id'] == widget.collectionId,
    ).firstOrNull;

    if (collection == null) {
      return Center(child: Text(l.collectionNotFound));
    }

    final name = collection['name'] as String? ?? l.collectionDetailDefaultName;
    final description = collection['description'] as String? ?? '';
    final books = (collection['books'] as List<dynamic>?) ?? [];

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
          ] else ...[
            if (canDeleteCollection) ...[
              GestureDetector(
                onTap: () => _deleteCollection(context, lib),
                child: Icon(Icons.delete_outline_rounded, size: 20,
                  color: cs.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
            ],
            Icon(Icons.collections_bookmark_rounded, size: 20, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(name, style: tt.titleMedium?.copyWith(
                fontWeight: FontWeight.w600, color: cs.onSurface,
              )),
            ),
            Text(l.collectionDetailBookCount(books.length),
              style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () => setState(() => _gridView = !_gridView),
              child: Icon(
                _gridView ? Icons.view_list_rounded : Icons.grid_view_rounded,
                size: 20, color: cs.onSurfaceVariant),
            ),
            if (canEditCollection && books.length > 1) ...[
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () => _startReorder(books),
                child: Icon(Icons.tune_rounded, size: 20,
                  color: cs.onSurfaceVariant),
              ),
            ],
          ],
        ]),
      ),
      if (!_reordering && description.isNotEmpty) ...[
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(description,
            style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            maxLines: 2, overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
      const SizedBox(height: 12),
      Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.3),
        indent: 20, endIndent: 20),
      // Content
      Expanded(
        child: _reordering
            ? _buildReorderList(cs, tt, lib, l)
            : _gridView
                ? _buildGrid(cs, tt, lib, books, l)
                : _buildItemList(cs, tt, lib, books, l, canEditCollection: canEditCollection),
      ),
    ]);
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
        final book = items[index];
        final itemId = book['id'] as String? ?? '';
        final media = book['media'] as Map<String, dynamic>? ?? {};
        final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
        final title = metadata['title'] as String? ?? l.unknown;
        final coverUrl = lib.getCoverUrl(itemId);

        return Container(
          key: ValueKey(itemId),
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
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
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
            title: Text(
              title,
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

  Widget _buildItemList(ColorScheme cs, TextTheme tt, LibraryProvider lib, List<dynamic> books, AppLocalizations l, {required bool canEditCollection}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final doneColor = isDark ? Colors.greenAccent[400]! : Colors.green.shade700;

    return ListView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4).copyWith(bottom: 40),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index] as Map<String, dynamic>;
        final itemId = book['id'] as String? ?? '';
        final media = book['media'] as Map<String, dynamic>? ?? {};
        final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
        final title = metadata['title'] as String? ?? l.unknown;
        final author = metadata['authorName'] as String? ?? '';
        final coverUrl = lib.getCoverUrl(itemId);
        final isExplicit = PlayerSettings.showExplicitBadge && metadata['explicit'] == true;
        final progress = lib.getProgress(itemId);
        final isFinished = lib.getProgressData(itemId)?['isFinished'] == true;
        final isDownloaded = DownloadService().isDownloaded(itemId);

        final card = Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            elevation: 0,
            color: cs.surfaceContainerHigh,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => showBookDetailSheet(context, itemId),
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
                                  Text(l.collectionDetailDone, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: doneColor)),
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
                          Text(title,
                            maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface)),
                          const SizedBox(height: 4),
                          Text(author,
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
        );

        final isOnAbsorbing = lib.isOnAbsorbingList(itemId);

        if (!canEditCollection) {
          return Dismissible(
            key: ValueKey('absorb-$itemId'),
            direction: isOnAbsorbing ? DismissDirection.none : DismissDirection.startToEnd,
            confirmDismiss: (_) async {
              await lib.addToAbsorbingQueue(itemId);
              lib.absorbingItemCache[itemId] = Map<String, dynamic>.from(book);
              HapticFeedback.mediumImpact();
              if (context.mounted) {
                showOverlayToast(context, Wording.of(context).collectionDetailAddedToAbsorbing(title), icon: Icons.add_circle_outline_rounded);
              }
              return false;
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
            child: card,
          );
        }

        return Dismissible(
          key: ValueKey(itemId),
          direction: isOnAbsorbing ? DismissDirection.endToStart : DismissDirection.horizontal,
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.startToEnd) {
              await lib.addToAbsorbingQueue(itemId);
              lib.absorbingItemCache[itemId] = Map<String, dynamic>.from(book);
              HapticFeedback.mediumImpact();
              if (context.mounted) {
                showOverlayToast(context, Wording.of(context).collectionDetailAddedToAbsorbing(title), icon: Icons.add_circle_outline_rounded);
              }
              return false;
            }
            _removeItem(lib, itemId);
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
          child: card,
        );
      },
    );
  }

  Widget _buildGrid(ColorScheme cs, TextTheme tt, LibraryProvider lib, List<dynamic> books, AppLocalizations l) {
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
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index] as Map<String, dynamic>;
        final itemId = book['id'] as String? ?? '';
        final media = book['media'] as Map<String, dynamic>? ?? {};
        final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
        final title = metadata['title'] as String? ?? l.unknown;
        final author = metadata['authorName'] as String? ?? '';
        final coverUrl = lib.getCoverUrl(itemId);
        final isExplicit = PlayerSettings.showExplicitBadge && metadata['explicit'] == true;
        final progress = lib.getProgress(itemId);
        final isFinished = lib.getProgressData(itemId)?['isFinished'] == true;
        final isDownloaded = DownloadService().isDownloaded(itemId);

        return GestureDetector(
          onTap: () => showBookDetailSheet(context, itemId),
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
                                Text(l.collectionDetailDone, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: doneColor)),
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
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: tt.labelSmall?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface)),
              if (author.isNotEmpty)
                Text(author, maxLines: 1, overflow: TextOverflow.ellipsis,
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
      child: Icon(Icons.book_rounded, size: 20,
        color: cs.onSurfaceVariant.withValues(alpha: 0.3)),
    );
  }
}
