import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'scoped_prefs.dart';
import 'user_account_service.dart';

/// Stores user-chosen metadata overrides locally per item.
/// These override server metadata that is empty or wrong, without
/// modifying the server itself. Persisted via ScopedPrefs (user-scoped).
class MetadataOverrideService {
  // Singleton
  static final MetadataOverrideService _instance = MetadataOverrideService._();
  factory MetadataOverrideService() => _instance;
  MetadataOverrideService._();

  static const _prefix = 'metadata_override_';

  /// Synchronous cache of cover overrides, keyed by item id. Populated by
  /// [loadAll] on startup/account switch and kept in sync by save/delete.
  /// Lets [coverUrlFor] resolve a local cover without an async prefs read,
  /// so the library grid and absorbing card can apply the override too.
  final Map<String, String> _coverCache = {};

  /// Synchronous lookup of a local cover override for an item, or null.
  /// Handles composite keys (e.g. `<itemId><episodeId>`) by also checking
  /// the 36-char base item id the override is stored under.
  String? coverUrlFor(String itemId) {
    final direct = _coverCache[itemId];
    if (direct != null && direct.isNotEmpty) return direct;
    if (itemId.length > 36) {
      final base = _coverCache[itemId.substring(0, 36)];
      if (base != null && base.isNotEmpty) return base;
    }
    return null;
  }

  /// Load every stored override's cover into [_coverCache]. Call on startup
  /// and whenever the active account changes. Mirrors the bookmark service's
  /// scoped-key enumeration so it only reads the active user's overrides.
  Future<void> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final scope = UserAccountService().activeScopeKey;
    final fullPrefix = scope.isEmpty ? _prefix : '$scope:$_prefix';
    _coverCache.clear();
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(fullPrefix)) continue;
      final itemId = key.substring(fullPrefix.length);
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final cover = map['coverUrl'];
        if (cover != null && cover.toString().isNotEmpty) {
          _coverCache[itemId] = cover.toString();
        }
      } catch (_) {}
    }
    debugPrint(
        '[MetadataOverride] Loaded ${_coverCache.length} cover override(s) for scope "$scope"');
  }

  /// Save a metadata override for an item. Only non-null fields are stored.
  Future<void> save(String itemId, Map<String, dynamic> override) async {
    // Merge with any existing override
    final existing = await get(itemId);
    final merged = <String, dynamic>{...?existing, ...override};
    // Remove null values
    merged.removeWhere((_, v) => v == null);
    await ScopedPrefs.setString('$_prefix$itemId', jsonEncode(merged));
    // Keep the sync cover cache in step so grid/card covers update at once.
    final cover = merged['coverUrl'];
    if (cover != null && cover.toString().isNotEmpty) {
      _coverCache[itemId] = cover.toString();
    } else {
      _coverCache.remove(itemId);
    }
    debugPrint('[MetadataOverride] Saved override for $itemId: ${merged.keys.join(', ')}');
  }

  /// Get a metadata override for an item, or null if none exists.
  Future<Map<String, dynamic>?> get(String itemId) async {
    final raw = await ScopedPrefs.getString('$_prefix$itemId');
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Delete a metadata override for an item.
  Future<void> delete(String itemId) async {
    await ScopedPrefs.remove('$_prefix$itemId');
    _coverCache.remove(itemId);
  }

  /// Check if an item has a local override.
  Future<bool> hasOverride(String itemId) async {
    return await ScopedPrefs.containsKey('$_prefix$itemId');
  }

  /// Apply overrides to a server item map. Modifies in place and returns it.
  Map<String, dynamic> applyOverrides(
      Map<String, dynamic> item, Map<String, dynamic> override) {
    final media = item['media'] as Map<String, dynamic>? ?? {};
    final metadata =
        Map<String, dynamic>.from(media['metadata'] as Map<String, dynamic>? ?? {});

    // Apply override value (always replaces server value)
    void applyField(String metaKey, String overrideKey) {
      final replacement = override[overrideKey];
      if (replacement != null && replacement.toString().isNotEmpty) {
        metadata[metaKey] = replacement;
      }
    }

    applyField('title', 'title');
    applyField('authorName', 'author');
    applyField('narratorName', 'narrator');
    applyField('description', 'description');
    applyField('publisher', 'publisher');
    applyField('publishedYear', 'publishedYear');
    applyField('asin', 'asin');
    applyField('isbn', 'isbn');

    // Genres
    final overrideGenres = override['genres'] as List<dynamic>?;
    if (overrideGenres != null && overrideGenres.isNotEmpty) {
      metadata['genres'] = overrideGenres;
    }

    // Series
    final overrideSeries = override['series'] as List<dynamic>?;
    if (overrideSeries != null && overrideSeries.isNotEmpty) {
      metadata['series'] = overrideSeries;
    }

    // Write back
    final updatedMedia = Map<String, dynamic>.from(media);
    updatedMedia['metadata'] = metadata;
    item['media'] = updatedMedia;

    // Cover URL override (stored separately since it's not in metadata)
    if (override['coverUrl'] != null) {
      item['_localCoverUrl'] = override['coverUrl'];
    }

    return item;
  }
}
