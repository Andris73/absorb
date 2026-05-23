import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';

/// Bottom sheet that lets the user pick which playlist drives the playlist
/// queue mode. Writes the choice via [PlayerSettings.setQueuePlaylistId];
/// callers are responsible for flipping `bookQueueMode`/`podcastQueueMode`
/// to `'playlist'` if they want to *enter* playlist mode at the same time.
class QueuePlaylistPickerSheet extends StatefulWidget {
  const QueuePlaylistPickerSheet({super.key});

  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String?>(
      context: context,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      isScrollControlled: true,
      builder: (_) => const QueuePlaylistPickerSheet(),
    );
  }

  @override
  State<QueuePlaylistPickerSheet> createState() => _QueuePlaylistPickerSheetState();
}

class _QueuePlaylistPickerSheetState extends State<QueuePlaylistPickerSheet> {
  String? _activeId;
  bool _loadedActive = false;

  @override
  void initState() {
    super.initState();
    _loadActive();
    // Make sure the playlist list is current.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<LibraryProvider>().loadPlaylists();
    });
  }

  Future<void> _loadActive() async {
    final id = await PlayerSettings.getQueuePlaylistId();
    if (mounted) setState(() {
      _activeId = id;
      _loadedActive = true;
    });
  }

  Future<void> _choose(String id) async {
    await PlayerSettings.setQueuePlaylistId(id);
    if (mounted) Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;
    final lib = context.watch<LibraryProvider>();
    final playlists = lib.playlists;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.24),
              borderRadius: BorderRadius.circular(2),
            ),
          )),
          Text(l.queuePlaylistPickerTitle, style: tt.titleMedium?.copyWith(
            color: cs.onSurface, fontWeight: FontWeight.w600,
          )),
          const SizedBox(height: 12),
          if (lib.isLoadingPlaylists && playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (playlists.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(l.queuePlaylistNone, style: tt.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              )),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: playlists.length,
                itemBuilder: (_, i) {
                  final p = playlists[i] as Map<String, dynamic>;
                  final id = p['id'] as String? ?? '';
                  final name = p['name'] as String? ?? l.playlistPickerPlaylistFallback;
                  final items = (p['items'] as List<dynamic>?) ?? const [];
                  final active = _loadedActive && id == _activeId;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: GestureDetector(
                      onTap: id.isEmpty ? null : () => _choose(id),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: cs.onSurface.withValues(alpha: active ? 0.10 : 0.06),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: active
                                ? cs.primary.withValues(alpha: 0.5)
                                : cs.onSurface.withValues(alpha: 0.1),
                          ),
                        ),
                        child: Row(children: [
                          Icon(
                            active ? Icons.check_circle_rounded : Icons.playlist_play_rounded,
                            size: 18,
                            color: active ? cs.primary : cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.bodyMedium?.copyWith(
                              color: cs.onSurface,
                              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                            ),
                          )),
                          Text(
                            l.playlistDetailItemCount(items.length),
                            style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ]),
                      ),
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
