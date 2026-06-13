import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/bookmark_service.dart';
import '../services/bookmark_preview_player.dart';

/// Result of [BookmarkDetailDialog]. [action] is 'jump' (caller should seek
/// there) or 'saved' (stay put, refresh). [position] is the possibly-nudged
/// bookmark time in seconds. The dialog returns null when closed without saving.
typedef BookmarkDetailResult = ({String action, double position});

/// Rich bookmark detail editor shared by the standalone Bookmarks screen and the
/// in-player bookmark sheet: roomy title/note, a -5/-1/+1/+5 fine time nudge
/// (synced to the server), and inline preview playback that auditions the spot
/// without moving the user's real position. Persists on Save/Jump, then pops a
/// [BookmarkDetailResult].
class BookmarkDetailDialog extends StatefulWidget {
  final String itemId;
  final Bookmark bookmark;
  final ApiService? api;
  const BookmarkDetailDialog({
    super.key,
    required this.itemId,
    required this.bookmark,
    this.api,
  });

  @override
  State<BookmarkDetailDialog> createState() => _BookmarkDetailDialogState();
}

class _BookmarkDetailDialogState extends State<BookmarkDetailDialog> {
  late final TextEditingController _titleC;
  late final TextEditingController _noteC;
  late double _seconds;
  late final BookmarkPreviewPlayer _preview;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleC = TextEditingController(text: widget.bookmark.title);
    _noteC = TextEditingController(text: widget.bookmark.note ?? '');
    // Clamp a stray negative position to 0 so it shows 0:00 (not "59:59") and
    // self-heals to 0 if the user saves.
    _seconds = widget.bookmark.positionSeconds < 0 ? 0.0 : widget.bookmark.positionSeconds;
    _preview = BookmarkPreviewPlayer(itemId: widget.itemId, api: widget.api)
      ..addListener(_onPreview);
  }

  void _onPreview() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _preview.removeListener(_onPreview);
    _preview.dispose();
    _titleC.dispose();
    _noteC.dispose();
    super.dispose();
  }

  String _fmt(double s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s.toInt() % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    }
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  void _nudge(double delta) {
    setState(() => _seconds = (_seconds + delta).clamp(0.0, double.infinity));
    _preview.stop(); // next Listen uses the new time
  }

  Future<void> _togglePreview() async {
    try {
      await _preview.toggleAt(_seconds);
    } catch (e) {
      debugPrint('[BookmarkPreview] toggle failed: $e');
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l.bookmarkPreviewFailed),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _persist() async {
    setState(() => _saving = true);
    await _preview.stop();
    final newTitle =
        _titleC.text.trim().isEmpty ? widget.bookmark.title : _titleC.text.trim();
    final newNote = _noteC.text.trim();
    final svc = BookmarkService();
    await svc.updateBookmark(
      itemId: widget.itemId,
      bookmarkId: widget.bookmark.id,
      title: newTitle,
      note: newNote.isEmpty ? null : newNote,
      api: widget.api,
    );
    if ((_seconds - widget.bookmark.positionSeconds).abs() >= 0.05) {
      await svc.moveBookmark(
        itemId: widget.itemId,
        bookmarkId: widget.bookmark.id,
        newPositionSeconds: _seconds,
        api: widget.api,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final tt = Theme.of(context).textTheme;
    return AlertDialog(
      scrollable: true,
      title: Text(l.editBookmark),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _titleC,
              decoration: InputDecoration(
                  labelText: l.titleLabel, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteC,
              minLines: 4,
              maxLines: 10,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: l.noteOptionalLabel,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              _nudgeBtn('-5', () => _nudge(-5)),
              _nudgeBtn('-1', () => _nudge(-1)),
              Expanded(
                child: Center(
                  child: Text(
                    _fmt(_seconds),
                    style: tt.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFeatures: [const FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              _nudgeBtn('+1', () => _nudge(1)),
              _nudgeBtn('+5', () => _nudge(5)),
            ]),
            const SizedBox(height: 4),
            Center(
              child: TextButton.icon(
                icon: _preview.isLoading
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(_preview.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded),
                label: Text(_preview.isPlaying ? l.bookmarkPause : l.bookmarkListen),
                onPressed: _preview.isLoading ? null : _togglePreview,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving
              ? null
              : () async {
                  await _preview.stop();
                  if (mounted) Navigator.pop(context);
                },
          child: Text(l.bookmarksScreenClose),
        ),
        TextButton(
          onPressed: _saving
              ? null
              : () async {
                  await _persist();
                  if (mounted) {
                    Navigator.pop(context, (action: 'saved', position: _seconds));
                  }
                },
          child: Text(l.save),
        ),
        FilledButton(
          onPressed: _saving
              ? null
              : () async {
                  await _persist();
                  if (mounted) {
                    Navigator.pop(context, (action: 'jump', position: _seconds));
                  }
                },
          child: Text(l.bookmarksJump),
        ),
      ],
    );
  }

  Widget _nudgeBtn(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          minimumSize: const Size(44, 38),
        ),
        child: Text(label),
      ),
    );
  }
}
