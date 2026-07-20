/// Decides whether ABB results are already in the user's ABS library.
library;

import '../api_service.dart';
import 'abb_models.dart';
import 'title_matching.dart';

/// Checks ABB results against the ABS library via search. Fails open: any
/// error, timeout or offline state treats the title as NOT owned so results
/// are never hidden by infrastructure problems.
class LibraryOwnershipService {
  /// Session cache: `normalizedCoreTitle|normalizedAuthor` -> owned.
  final _cache = <String, bool>{};

  String _key(String title, String author) =>
      '${normalizeTitle(coreTitle(title))}|${normalizeTitle(author)}';

  /// True when a book matching [title]/[author] exists in the library.
  Future<bool> isOwned(
      String title, String author, ApiService api, String libraryId) async {
    final key = _key(title, author);
    final cached = _cache[key];
    if (cached != null) return cached;
    final owned = await _checkOwned(title, author, api, libraryId);
    _cache[key] = owned;
    return owned;
  }

  Future<bool> _checkOwned(
      String title, String author, ApiService api, String libraryId) async {
    try {
      final core = coreTitle(title);
      if (core.isEmpty) return false;
      final search = await api.searchLibrary(libraryId, core, limit: 10);
      final books = search?['book'] as List<dynamic>? ?? [];
      for (final b in books) {
        final libraryItem =
            (b as Map<String, dynamic>)['libraryItem'] as Map<String, dynamic>? ?? {};
        final media = libraryItem['media'] as Map<String, dynamic>? ?? {};
        final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
        final ownedTitle = metadata['title'] as String? ?? '';
        final ownedAuthor = metadata['authorName'] as String? ?? '';
        if (ownedTitle.isEmpty) continue;
        if (titlesMatch(core, ownedTitle) &&
            authorsMatch(author, ownedAuthor)) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Drop results already in the library. Checks are deduped on the cache
  /// key and run in parallel (they hit the user's own ABS server, not ABB).
  Future<List<AbbSearchResult>> filterUnowned(
      List<AbbSearchResult> results, ApiService api, String libraryId) async {
    final pending = <String, Future<bool>>{};
    for (final r in results) {
      final key = _key(r.title, r.author ?? '');
      if (_cache.containsKey(key) || pending.containsKey(key)) continue;
      pending[key] = _checkOwned(r.title, r.author ?? '', api, libraryId);
    }
    for (final entry in pending.entries) {
      _cache[entry.key] = await entry.value;
    }
    return results
        .where((r) => _cache[_key(r.title, r.author ?? '')] != true)
        .toList();
  }
}
