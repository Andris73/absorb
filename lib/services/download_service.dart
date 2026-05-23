import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'api_service.dart';
import 'audio_player_service.dart';
import 'download_notification_service.dart';

enum DownloadStatus { none, downloading, downloaded, error }

class DownloadInfo {
  final String itemId;
  final DownloadStatus status;
  final double progress;
  final List<String> localPaths;
  final String? sessionData;
  // Metadata for offline display
  final String? title;
  final String? author;
  final String? coverUrl;
  final String? localCoverPath;
  final String? localDirPath;
  final String? libraryId;

  DownloadInfo({
    required this.itemId,
    this.status = DownloadStatus.none,
    this.progress = 0,
    this.localPaths = const [],
    this.sessionData,
    this.title,
    this.author,
    this.coverUrl,
    this.localCoverPath,
    this.localDirPath,
    this.libraryId,
  });

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'status': status.index,
        'localPaths': localPaths,
        'sessionData': sessionData,
        'title': title,
        'author': author,
        'coverUrl': coverUrl,
        'localCoverPath': localCoverPath,
        if (localDirPath != null) 'localDirPath': localDirPath,
        if (libraryId != null) 'libraryId': libraryId,
      };

  factory DownloadInfo.fromJson(Map<String, dynamic> json) {
    String? title = json['title'] as String?;
    String? author = json['author'] as String?;
    String? coverUrl = json['coverUrl'] as String?;

    // Fallback: extract metadata from cached sessionData for old downloads
    if ((title == null || title.isEmpty) && json['sessionData'] != null) {
      try {
        final session = jsonDecode(json['sessionData'] as String) as Map<String, dynamic>;
        // Try session-level metadata first
        final sessionMeta = session['mediaMetadata'] as Map<String, dynamic>?;
        if (sessionMeta != null) {
          title ??= sessionMeta['title'] as String?;
          author ??= sessionMeta['authorName'] as String?;
        }
        // Try libraryItem path
        if (title == null || title.isEmpty) {
          final libItem = session['libraryItem'] as Map<String, dynamic>? ?? {};
          final media = libItem['media'] as Map<String, dynamic>? ?? {};
          final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
          title ??= metadata['title'] as String?;
          author ??= metadata['authorName'] as String?;
        }
        // Try direct displayTitle/displayAuthor
        title ??= session['displayTitle'] as String?;
        author ??= session['displayAuthor'] as String?;
      } catch (_) {}
    }

    return DownloadInfo(
      itemId: json['itemId'] as String,
      status: DownloadStatus.values[json['status'] as int? ?? 0],
      localPaths: (json['localPaths'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      sessionData: _stripLibraryItem(json['sessionData'] as String?),
      title: title,
      author: author,
      coverUrl: coverUrl,
      localCoverPath: json['localCoverPath'] as String?,
      localDirPath: json['localDirPath'] as String?,
      libraryId: json['libraryId'] as String?,
    );
  }
}

class _QueuedDownload {
  final ApiService api;
  final String itemId;
  final String title;
  final String? author;
  final String? coverUrl;
  final String? episodeId;
  final String? libraryId;

  _QueuedDownload({
    required this.api,
    required this.itemId,
    required this.title,
    this.author,
    this.coverUrl,
    this.episodeId,
    this.libraryId,
  });
}

/// Strip the bulky `libraryItem` from persisted session data.
/// For podcasts this contains ALL episodes and can be hundreds of KB.
String? _stripLibraryItem(String? sessionJson) {
  if (sessionJson == null) return null;
  try {
    final session = jsonDecode(sessionJson) as Map<String, dynamic>;
    if (session.containsKey('libraryItem')) {
      session.remove('libraryItem');
      return jsonEncode(session);
    }
  } catch (_) {}
  return sessionJson;
}

/// Sanitize a string for use as a filesystem directory/file name.
String _sanitizePath(String name) {
  // Replace filesystem-illegal characters with underscore
  var s = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  // Collapse multiple underscores/spaces
  s = s.replaceAll(RegExp(r'[_\s]+'), ' ').trim();
  // Fallback for empty result
  if (s.isEmpty) s = 'Unknown';
  // Limit length to avoid filesystem issues
  if (s.length > 100) s = s.substring(0, 100).trim();
  return s;
}

class DownloadService extends ChangeNotifier {
  static final DownloadService _instance = DownloadService._();
  factory DownloadService() => _instance;
  DownloadService._();

  final Map<String, DownloadInfo> _downloads = {};
  final Set<String> _activeDownloadIds = {};
  final Map<String, http.Client> _httpClients = {};
  final Set<String> _cancelledIds = {};
  final Map<String, int> _downloadSlots = {};
  String? _customDownloadPath;

  /// Queue of pending download requests.
  final List<_QueuedDownload> _queue = [];

  /// The current download directory path, or null if using default.
  String? get customDownloadPath => _customDownloadPath;

  /// Get the effective download base directory.
  ///
  /// On iOS, audio files live in the app group container so the widget
  /// extension and the native player core can read them. We fall back to
  /// Documents/ if the app group lookup fails (entitlement not yet rolled
  /// out, etc.) so existing users don't lose their downloads.
  Future<String> get downloadBasePath async {
    if (_customDownloadPath != null && _customDownloadPath!.isNotEmpty) {
      return _customDownloadPath!;
    }
    if (Platform.isIOS) {
      final groupPath = await _iosAppGroupAudioBase();
      if (groupPath != null) return groupPath;
    }
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/downloads';
  }

  /// Always returns the internal app directory for cover caching.
  /// Covers are stored here even when audio uses a custom external path,
  /// because external storage may have permission restrictions.
  Future<String> get _internalBasePath async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/downloads';
  }

  /// Set a custom download location. Pass null to revert to default.
  Future<void> setCustomDownloadPath(String? path) async {
    _customDownloadPath = path;
    final prefs = await SharedPreferences.getInstance();
    if (path != null && path.isNotEmpty) {
      await prefs.setString('custom_download_path', path);
    } else {
      await prefs.remove('custom_download_path');
    }
    notifyListeners();
  }

  /// Get a human-readable label for the current download location.
  Future<String> get downloadLocationLabel async {
    if (_customDownloadPath != null && _customDownloadPath!.isNotEmpty) {
      // Shorten the path for display
      final path = _customDownloadPath!;
      // Try to show a friendly path relative to common roots
      if (path.contains('/emulated/0/')) {
        return path.split('/emulated/0/').last;
      }
      if (path.contains('/storage/')) {
        return path.split('/storage/').last;
      }
      // Last two segments
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.length >= 2) {
        return '${segments[segments.length - 2]}/${segments.last}';
      }
      return path;
    }
    return 'App Internal Storage (Default)';
  }

  /// Calculate total size of all downloaded files.
  Future<int> get totalDownloadSize async {
    int total = 0;
    for (final info in _downloads.values) {
      if (info.status == DownloadStatus.downloaded) {
        for (final path in info.localPaths) {
          try {
            final file = File(path);
            if (file.existsSync()) {
              total += file.lengthSync();
            }
          } catch (_) {}
        }
      }
    }
    return total;
  }

  /// Calculate total file size for a single download item.
  int getItemFileSize(String itemId) {
    final info = _downloads[itemId];
    if (info == null || info.status != DownloadStatus.downloaded) return 0;
    int total = 0;
    for (final path in info.localPaths) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          total += file.lengthSync();
        }
      } catch (_) {}
    }
    return total;
  }

  static const _storageChannel = MethodChannel('com.absorb.storage');
  static const _widgetChannel = MethodChannel('com.absorb.widget');

  /// Cached iOS app group container path. Populated lazily by
  /// [_iosAppGroupAudioBase] and cleared if the lookup fails so we retry
  /// (the app group entitlement may roll in mid-session).
  String? _iosAppGroupContainerPath;

  /// Stops iCloud from backing up an audio file. Audiobooks are large and
  /// re-downloadable from the user's ABS server, so eating their iCloud
  /// quota would only cause problems (system backup breaks once quota is
  /// hit). iOS-only no-op elsewhere.
  Future<void> _excludeFromBackup(String path) async {
    if (!Platform.isIOS) return;
    try {
      await _widgetChannel.invokeMethod<bool>(
        'excludeFromBackup',
        {'path': path},
      );
    } catch (e) {
      debugPrint('[Download] excludeFromBackup failed for $path: $e');
    }
  }

  /// Returns the iOS app group's audio directory (`<group>/audio/downloads`),
  /// or null on Android / when the app group entitlement isn't available.
  /// Audio downloads live here so the native player core can read them
  /// from the widget extension (the widget can't reach Documents/).
  Future<String?> _iosAppGroupAudioBase() async {
    if (!Platform.isIOS) return null;
    var groupPath = _iosAppGroupContainerPath;
    if (groupPath == null) {
      try {
        groupPath = await _widgetChannel.invokeMethod<String>('getGroupContainerPath');
      } catch (e) {
        debugPrint('[Download] getGroupContainerPath failed: $e');
        return null;
      }
      if (groupPath == null || groupPath.isEmpty) return null;
      _iosAppGroupContainerPath = groupPath;
    }
    final dir = Directory('$groupPath/audio/downloads');
    if (!dir.existsSync()) {
      try {
        dir.createSync(recursive: true);
      } catch (e) {
        debugPrint('[Download] create app group audio dir failed: $e');
        return null;
      }
    }
    return dir.path;
  }

  /// Get device storage info: {totalBytes, availableBytes}. Returns null on failure.
  static Future<Map<String, int>?> getDeviceStorage() async {
    try {
      final result = await _storageChannel.invokeMethod('getDeviceStorage');
      if (result is Map) {
        return {
          'totalBytes': (result['totalBytes'] as num).toInt(),
          'availableBytes': (result['availableBytes'] as num).toInt(),
        };
      }
    } catch (e) {
      debugPrint('[Download] getDeviceStorage error: $e');
    }
    return null;
  }

  DownloadInfo getInfo(String itemId) =>
      _downloads[itemId] ?? DownloadInfo(itemId: itemId);

  bool isDownloaded(String itemId) =>
      _downloads[itemId]?.status == DownloadStatus.downloaded;

  bool isDownloading(String itemId) =>
      _downloads[itemId]?.status == DownloadStatus.downloading;

  double downloadProgress(String itemId) =>
      _downloads[itemId]?.progress ?? 0;

  /// Get all downloaded items (for home screen display).
  List<DownloadInfo> get downloadedItems =>
      _downloads.values
          .where((d) => d.status == DownloadStatus.downloaded)
          .toList();

  /// Get actively downloading items (in progress right now).
  List<DownloadInfo> get activeDownloads =>
      _downloads.values
          .where((d) => d.status == DownloadStatus.downloading && _activeDownloadIds.contains(d.itemId))
          .toList();

  /// Get queued items (waiting for a download slot).
  List<DownloadInfo> get queuedDownloads =>
      _queue.map((q) => _downloads[q.itemId]).whereType<DownloadInfo>().toList();

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _customDownloadPath = prefs.getString('custom_download_path');
    final json = prefs.getString('downloads');
    if (json != null) {
      try {
        final map = jsonDecode(json) as Map<String, dynamic>;
        for (final entry in map.entries) {
          final info =
              DownloadInfo.fromJson(entry.value as Map<String, dynamic>);
          debugPrint('[Download] Loaded: ${entry.key} '
              'title="${info.title}" author="${info.author}" '
              'cover=${info.coverUrl != null ? "yes" : "null"} '
              'sessionData=${info.sessionData != null ? "${info.sessionData!.length} chars" : "null"}');
          if (info.status == DownloadStatus.downloaded) {
            _downloads[entry.key] = info;
          } else {
            debugPrint('[Download] Skipping stale ${info.status} entry: ${entry.key}');
          }
        }
      } catch (e) {
        debugPrint('[Download] Init error: $e');
      }
    }
    // On iOS, remap paths when the app container UUID changes after updates
    await _migrateIOSPaths();

    // On iOS, move existing audio downloads from Documents/ into the app
    // group container so the widget / native player core can read them.
    // Runs in background so it doesn't block init() if the user has many
    // gigabytes of downloaded books to relocate.
    if (Platform.isIOS) {
      unawaited(_migrateIOSAudioToAppGroup());
    }

    // Re-save to persist any metadata extracted from sessionData
    if (_downloads.isNotEmpty) await _save();
    notifyListeners();

    // Validate files and clean up orphans in background after startup
    _validateDownloads();
  }

  /// On iOS, the app container UUID changes on every update, which breaks
  /// stored absolute paths. Detect stale prefixes and remap to the current
  /// container path so downloads survive TestFlight / App Store updates.
  Future<void> _migrateIOSPaths() async {
    if (!Platform.isIOS || _downloads.isEmpty) return;

    final appDir = await getApplicationDocumentsDirectory();
    final currentPrefix = appDir.path; // .../Documents

    bool changed = false;
    final entries = Map<String, DownloadInfo>.from(_downloads);

    for (final entry in entries.entries) {
      final info = entry.value;
      bool needsUpdate = false;

      // Remap localPaths
      final newPaths = <String>[];
      for (final path in info.localPaths) {
        final remapped = _remapIOSPath(path, currentPrefix);
        newPaths.add(remapped);
        if (remapped != path) needsUpdate = true;
      }

      final newCoverPath = info.localCoverPath != null
          ? _remapIOSPath(info.localCoverPath!, currentPrefix)
          : null;
      if (newCoverPath != info.localCoverPath) needsUpdate = true;

      final newDirPath = info.localDirPath != null
          ? _remapIOSPath(info.localDirPath!, currentPrefix)
          : null;
      if (newDirPath != info.localDirPath) needsUpdate = true;

      if (needsUpdate) {
        _downloads[entry.key] = DownloadInfo(
          itemId: info.itemId,
          status: info.status,
          localPaths: newPaths,
          sessionData: info.sessionData,
          title: info.title,
          author: info.author,
          coverUrl: info.coverUrl,
          localCoverPath: newCoverPath,
          localDirPath: newDirPath,
          libraryId: info.libraryId,
        );
        changed = true;
      }
    }

    if (changed) {
      debugPrint('[Download] Migrated iOS paths to current container');
      await _save();
    }
  }

  /// Move existing audio files from Documents/ to the iOS app group container
  /// so the widget extension / native player core can read them. Files that
  /// fail to move stay in Documents/ where they continue to play through
  /// Flutter; we'll retry on the next launch. Atomic per-file via
  /// `File.rename()` (works because both directories are on APFS).
  Future<void> _migrateIOSAudioToAppGroup() async {
    if (!Platform.isIOS || _downloads.isEmpty) return;

    final groupBase = await _iosAppGroupAudioBase();
    if (groupBase == null) {
      debugPrint('[Download] App group not available, skipping audio migration');
      return;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final docsBase = '${appDir.path}/downloads';

    int moved = 0;
    int failed = 0;
    bool changed = false;
    final entries = Map<String, DownloadInfo>.from(_downloads);

    for (final entry in entries.entries) {
      final info = entry.value;
      if (info.status != DownloadStatus.downloaded) continue;

      final newPaths = <String>[];
      bool needsUpdate = false;
      for (final oldPath in info.localPaths) {
        // Already in app group? Keep as-is.
        if (oldPath.startsWith(groupBase)) {
          newPaths.add(oldPath);
          continue;
        }
        // Not under Documents/downloads/? Leave alone (custom path or odd).
        if (!oldPath.startsWith(docsBase)) {
          newPaths.add(oldPath);
          continue;
        }
        // Build the parallel path under the app group.
        final relative = oldPath.substring(docsBase.length);
        final newPath = '$groupBase$relative';
        try {
          final oldFile = File(oldPath);
          if (!oldFile.existsSync()) {
            // Old file gone; leave the path untouched and let the validator
            // mark it broken later.
            newPaths.add(oldPath);
            continue;
          }
          // Make sure parent dirs exist on the destination side.
          final parent = Directory(newPath.substring(0, newPath.lastIndexOf('/')));
          if (!parent.existsSync()) parent.createSync(recursive: true);
          // If dest exists already (partial prior run), remove it first.
          final newFile = File(newPath);
          if (newFile.existsSync()) {
            try { newFile.deleteSync(); } catch (_) {}
          }
          await oldFile.rename(newPath);
          await _excludeFromBackup(newPath);
          newPaths.add(newPath);
          needsUpdate = true;
          moved++;
        } catch (e) {
          debugPrint('[Download] Audio migration failed for $oldPath: $e');
          newPaths.add(oldPath);
          failed++;
        }
      }

      if (needsUpdate) {
        _downloads[entry.key] = DownloadInfo(
          itemId: info.itemId,
          status: info.status,
          progress: info.progress,
          localPaths: newPaths,
          sessionData: info.sessionData,
          title: info.title,
          author: info.author,
          coverUrl: info.coverUrl,
          localCoverPath: info.localCoverPath,
          localDirPath: info.localDirPath,
          libraryId: info.libraryId,
        );
        changed = true;
      }
    }

    if (changed) {
      debugPrint('[Download] App group audio migration: moved=$moved failed=$failed');
      await _save();
      notifyListeners();
    }
  }

  /// Replace a stale iOS container prefix with the current one.
  /// Paths contain `.../Documents/...` and we split on `/Documents/` then
  /// rejoin with the current prefix.
  String _remapIOSPath(String path, String currentPrefix) {
    if (path.startsWith(currentPrefix)) return path;
    final marker = '/Documents/';
    final idx = path.indexOf(marker);
    if (idx < 0) return path;
    return '$currentPrefix/${path.substring(idx + marker.length)}';
  }

  /// Validate that downloaded files still exist on disk and clean up orphans.
  /// Runs in background so it doesn't block app startup.
  Future<void> _validateDownloads() async {
    try {
      final orphanIds = <String>[];
      final entries = Map<String, DownloadInfo>.from(_downloads);
      for (final entry in entries.entries) {
        if (entry.value.status != DownloadStatus.downloaded) continue;
        bool allExist = true;
        for (final path in entry.value.localPaths) {
          try {
            final exists = await File(path).exists()
                .timeout(const Duration(seconds: 3));
            if (!exists) {
              allExist = false;
              break;
            }
          } catch (_) {
            // Timeout or permission error — treat as missing
            allExist = false;
            break;
          }
        }
        if (!allExist) {
          debugPrint('[Download] Files missing for ${entry.key}, removing');
          _downloads.remove(entry.key);
          orphanIds.add(entry.key);
        }
      }
      if (orphanIds.isNotEmpty) {
        await _save();
        notifyListeners();
        // Clean up partial/orphaned files on disk
        final basePath = await downloadBasePath;
        final internalBase = await _internalBasePath;
        for (final id in orphanIds) {
          debugPrint('[Download] Cleaning up orphaned entry: $id');
          try {
            final dir = Directory('$basePath/$id');
            if (await dir.exists()) await dir.delete(recursive: true);
          } catch (_) {}
          try {
            final coverDir = Directory('$internalBase/$id');
            if (await coverDir.exists()) await coverDir.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[Download] Validation error: $e');
    }
  }

  /// Try to fill in missing metadata from the API (for old downloads).
  Future<void> enrichMetadata(ApiService api) async {
    bool changed = false;
    final entries = Map<String, DownloadInfo>.from(_downloads);
    for (final entry in entries.entries) {
      final info = entry.value;
      if (info.status != DownloadStatus.downloaded) continue;

      bool needsUpdate = false;
      String? title = info.title;
      String? author = info.author;
      String? coverUrl = info.coverUrl;
      String? localCoverPath = info.localCoverPath;

      // For podcast episodes, the itemId is a composite "showUUID-episodeId".
      // Extract the library item ID (first 36 chars = UUID) for API calls.
      final apiItemId = info.itemId.length > 36
          ? info.itemId.substring(0, 36)
          : info.itemId;

      // Enrich missing title/author from server
      if (title == null || title.isEmpty) {
        try {
          final item = await api.getLibraryItem(apiItemId);
          if (item != null) {
            final media = item['media'] as Map<String, dynamic>? ?? {};
            final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
            title = metadata['title'] as String? ?? title;
            author = metadata['authorName'] as String? ?? author;
            coverUrl = api.getCoverUrl(apiItemId);
            needsUpdate = true;
            debugPrint('[Download] Enriched metadata for ${info.itemId}: $title');
          }
        } catch (e) {
          debugPrint('[Download] Enrich failed for ${info.itemId}: $e');
        }
      }

      // Cache cover in internal storage if not already cached
      if (localCoverPath == null || !File(localCoverPath).existsSync()) {
        final internalBase = await _internalBasePath;
        final existingCover = File('$internalBase/${info.itemId}/cover.jpg');
        if (existingCover.existsSync()) {
          // Already on disk from a previous download, just not tracked
          localCoverPath = existingCover.path;
          needsUpdate = true;
        } else {
          // Also check the custom download path (old downloads may have cover there)
          final basePath = await downloadBasePath;
          final oldCover = File('$basePath/${info.itemId}/cover.jpg');
          if (oldCover.existsSync()) {
            localCoverPath = oldCover.path;
            needsUpdate = true;
          } else {
            // Download from server into internal storage
            final url = coverUrl ?? api.getCoverUrl(apiItemId);
            try {
              final resp = await http.get(Uri.parse(url), headers: api.mediaHeaders)
                  .timeout(const Duration(seconds: 10));
              if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
                final dir = Directory('$internalBase/${info.itemId}');
                if (!dir.existsSync()) dir.createSync(recursive: true);
                final coverFile = File('${dir.path}/cover.jpg');
                await coverFile.writeAsBytes(resp.bodyBytes);
                final evicted = PaintingBinding.instance.imageCache
                    .evict(FileImage(coverFile));
                localCoverPath = coverFile.path;
                needsUpdate = true;
                debugPrint('[Download] Cached cover for ${info.itemId} '
                    '(${resp.bodyBytes.length} bytes, evict=$evicted)');
              }
            } catch (e) {
              debugPrint('[Download] Cover cache failed for ${info.itemId}: $e');
            }
          }
        }
      }

      if (needsUpdate) {
        _downloads[entry.key] = DownloadInfo(
          itemId: info.itemId,
          status: info.status,
          localPaths: info.localPaths,
          sessionData: info.sessionData,
          title: title ?? info.title,
          author: author ?? info.author,
          coverUrl: coverUrl ?? info.coverUrl,
          localCoverPath: localCoverPath,
          libraryId: info.libraryId,
        );
        changed = true;
      }
    }
    if (changed) {
      await _save();
      notifyListeners();
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{};
    for (final entry in _downloads.entries) {
      if (entry.value.status == DownloadStatus.downloaded) {
        map[entry.key] = entry.value.toJson();
      }
    }
    await prefs.setString('downloads', jsonEncode(map));
  }

  List<String>? getLocalPaths(String itemId) {
    final info = _downloads[itemId];
    if (info == null || info.status != DownloadStatus.downloaded) return null;
    return info.localPaths;
  }

  String? getCachedSessionData(String itemId) {
    return _downloads[itemId]?.sessionData;
  }

  /// Get the local cover file path for a downloaded item.
  /// Checks the persisted path first, then probes internal and download dirs.
  Future<String?> getLocalCoverPath(String itemId) async {
    final info = _downloads[itemId];
    if (info == null || info.status != DownloadStatus.downloaded) return null;

    // Check persisted path
    if (info.localCoverPath != null && File(info.localCoverPath!).existsSync()) {
      return info.localCoverPath;
    }

    // Check internal storage (where covers are now cached)
    final internalBase = await _internalBasePath;
    final internalCover = File('$internalBase/$itemId/cover.jpg');
    if (internalCover.existsSync()) return internalCover.path;

    // Check custom download path (old downloads may have cover there)
    final basePath = await downloadBasePath;
    if (basePath != internalBase) {
      final customCover = File('$basePath/$itemId/cover.jpg');
      if (customCover.existsSync()) return customCover.path;
    }

    return null;
  }

  /// Returns null on success, error message string on failure.
  /// For podcast episodes, pass [episodeId] so the correct API endpoint is used.
  Future<String?> downloadItem({
    required ApiService api,
    required String itemId,
    required String title,
    String? author,
    String? coverUrl,
    String? episodeId,
    String? libraryId,
  }) async {
    if (_activeDownloadIds.contains(itemId)) return null;
    if (isDownloaded(itemId)) return null;
    // Already queued — don't duplicate
    if (_queue.any((q) => q.itemId == itemId)) return null;

    // Check wifi-only setting
    final wifiOnly = await PlayerSettings.getWifiOnlyDownloads();
    if (wifiOnly) {
      final connectivity = await Connectivity().checkConnectivity();
      if (!connectivity.contains(ConnectivityResult.wifi)) {
        return 'Downloads are set to Wi-Fi only. Connect to Wi-Fi or change this in Settings.';
      }
    }

    final maxConcurrent = await PlayerSettings.getMaxConcurrentDownloads();

    // If at capacity, queue this one
    if (_activeDownloadIds.length >= maxConcurrent) {
      _queue.add(_QueuedDownload(
        api: api,
        itemId: itemId,
        title: title,
        author: author,
        coverUrl: coverUrl,
        episodeId: episodeId,
        libraryId: libraryId,
      ));
      _downloads[itemId] = DownloadInfo(
        itemId: itemId,
        status: DownloadStatus.downloading,
        progress: 0,
        title: title,
        author: author,
        coverUrl: coverUrl,
        libraryId: libraryId,
      );
      notifyListeners();
      return null;
    }

    // Launch immediately (fire-and-forget so caller doesn't block)
    unawaited(_executeDownload(
      api: api,
      itemId: itemId,
      title: title,
      author: author,
      coverUrl: coverUrl,
      episodeId: episodeId,
      libraryId: libraryId,
    ));
    return null;
  }

  /// Fill free download slots from the queue.
  Future<void> _processQueue() async {
    final maxConcurrent = await PlayerSettings.getMaxConcurrentDownloads();
    while (_queue.isNotEmpty && _activeDownloadIds.length < maxConcurrent) {
      final next = _queue.removeAt(0);
      // Skip if cancelled/removed while waiting
      if (isDownloaded(next.itemId)) continue;
      if (_activeDownloadIds.contains(next.itemId)) continue;
      unawaited(_executeDownload(
        api: next.api, itemId: next.itemId, title: next.title,
        author: next.author, coverUrl: next.coverUrl, episodeId: next.episodeId,
        libraryId: next.libraryId,
      ));
    }
  }

  /// Assign the lowest free notification slot (0–4).
  int _assignSlot(String itemId) {
    for (int i = 0; i < 5; i++) {
      if (!_downloadSlots.containsValue(i)) {
        _downloadSlots[itemId] = i;
        return i;
      }
    }
    // Fallback (shouldn't happen with max 5 concurrent)
    _downloadSlots[itemId] = 0;
    return 0;
  }

  Future<void> _executeDownload({
    required ApiService api,
    required String itemId,
    required String title,
    String? author,
    String? coverUrl,
    String? episodeId,
    String? libraryId,
  }) async {
    _activeDownloadIds.add(itemId);
    _cancelledIds.remove(itemId);
    final slot = _assignSlot(itemId);
    final client = http.Client();
    _httpClients[itemId] = client;

    _downloads[itemId] = DownloadInfo(
      itemId: itemId,
      status: DownloadStatus.downloading,
      progress: 0,
      title: title,
      author: author,
      coverUrl: coverUrl,
      libraryId: libraryId,
    );
    notifyListeners();

    // Show per-download notification + foreground service
    final notif = DownloadNotificationService();
    try {
      await notif.startDownload(slot: slot, title: title, author: author);
    } catch (e) {
      debugPrint('[Download] startDownload non-fatal error: $e');
    }

    Directory? bookDir;
    try {
      // For episodes, itemId is a composite key like 'podcastId-episodeId'.
      // Extract the real library item ID for the API call.
      final apiItemId = episodeId != null
          ? itemId.substring(0, itemId.length - episodeId.length - 1)
          : itemId;
      final sessionData = episodeId != null
          ? await api.startEpisodePlaybackSession(apiItemId, episodeId)
          : await api.startPlaybackSession(apiItemId);
      if (sessionData == null) throw Exception('Failed to start session');

      final audioTracks = sessionData['audioTracks'] as List<dynamic>?;
      if (audioTracks == null || audioTracks.isEmpty) {
        throw Exception('No audio tracks');
      }

      final basePath = await downloadBasePath;
      final dirName = (author != null && author.isNotEmpty)
          ? '${_sanitizePath(author)}/${_sanitizePath(title)}'
          : _sanitizePath(title);
      bookDir = Directory('$basePath/$dirName');
      if (!bookDir.existsSync()) {
        bookDir.createSync(recursive: true);
      }

      // Cache the cover image in internal storage for offline use (lockscreen, Android Auto).
      // Always use internal path — custom external paths may lack write permission.
      String? localCoverPath;
      if (coverUrl != null && coverUrl.isNotEmpty) {
        try {
          final coverResp = await http.get(Uri.parse(coverUrl), headers: api.mediaHeaders)
              .timeout(const Duration(seconds: 10));
          if (coverResp.statusCode == 200 && coverResp.bodyBytes.isNotEmpty) {
            final internalBase = await _internalBasePath;
            final coverDir = Directory('$internalBase/$itemId');
            if (!coverDir.existsSync()) coverDir.createSync(recursive: true);
            final coverFile = File('${coverDir.path}/cover.jpg');
            await coverFile.writeAsBytes(coverResp.bodyBytes);
            localCoverPath = coverFile.path;
            debugPrint('[Download] Cached cover image: $localCoverPath');
          }
        } catch (e) {
          debugPrint('[Download] Cover cache failed (non-fatal): $e');
        }
      }

      final localPaths = List<String?>.filled(audioTracks.length, null);

      // Track progress per-track for overall calculation
      final trackProgress = List<double>.filled(audioTracks.length, 0.0);
      int lastNotifPercent = -1;
      DateTime lastUIUpdate = DateTime.now();

      Future<void> showProgressSafe(double progress) async {
        try {
          await notif.updateProgress(
            slot: slot,
            title: title,
            author: author,
            progress: progress,
          );
        } catch (e) {
          debugPrint('[Download] updateProgress non-fatal error: $e');
        }
      }

      void updateProgress() {
        final overall = trackProgress.reduce((a, b) => a + b) / audioTracks.length;
        final now = DateTime.now();
        // Throttle UI updates to max ~4/sec
        if (now.difference(lastUIUpdate).inMilliseconds > 250) {
          lastUIUpdate = now;
          _downloads[itemId] = DownloadInfo(
            itemId: itemId,
            status: DownloadStatus.downloading,
            progress: overall,
            title: title,
            author: author,
            coverUrl: coverUrl,
            libraryId: libraryId,
          );
          notifyListeners();
        }
        // Throttle notification to every 2%
        final pct = (overall * 50).round();
        if (pct != lastNotifPercent) {
          lastNotifPercent = pct;
          unawaited(showProgressSafe(overall));
        }
      }

      Future<void> downloadTrack(int i) async {
        final track = audioTracks[i] as Map<String, dynamic>;
        final contentUrl = track['contentUrl'] as String? ?? '';
        final fullUrl = api.buildTrackUrl(contentUrl);

        // Try to get the original filename from track metadata first
        final trackMeta = track['metadata'] as Map<String, dynamic>?;
        var originalName = trackMeta?['filename'] as String? ?? '';
        // Fallback: extract from contentUrl path
        if (originalName.isEmpty) {
          final contentPath = Uri.tryParse(contentUrl)?.path ?? contentUrl;
          originalName = Uri.decodeComponent(contentPath.split('/').last);
          if (originalName.contains('?')) originalName = originalName.split('?').first;
        }

        final String fileName;
        if (originalName.isNotEmpty && originalName.contains('.')) {
          fileName = _sanitizePath(originalName.replaceAll(RegExp(r'\.[^.]+$'), ''))
              + originalName.substring(originalName.lastIndexOf('.'));
        } else {
          final mimeType = track['mimeType'] as String? ?? 'audio/mpeg';
          final ext = mimeType.contains('mp4')
              ? 'm4a'
              : mimeType.contains('flac')
                  ? 'flac'
                  : mimeType.contains('ogg')
                      ? 'ogg'
                      : 'mp3';
          fileName = 'track_${i.toString().padLeft(3, '0')}.$ext';
        }

        final filePath = '${bookDir!.path}/$fileName';
        final file = File(filePath);

        debugPrint('[Download] Track ${i + 1}/${audioTracks.length}: $fullUrl');

        final request = http.Request('GET', Uri.parse(fullUrl));
        api.mediaHeaders.forEach((key, value) => request.headers[key] = value);
        final response = await client.send(request)
            .timeout(const Duration(seconds: 30));

        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode} for track ${i + 1}');
        }

        final totalBytes = response.contentLength ?? -1;
        int receivedBytes = 0;
        final sink = file.openWrite();
        try {
          await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
            sink.add(chunk);
            receivedBytes += chunk.length;
            trackProgress[i] = totalBytes > 0 ? receivedBytes / totalBytes : 0.5;
            updateProgress();
          }
        } finally {
          await sink.close();
        }
        localPaths[i] = filePath;
        await _excludeFromBackup(filePath);
      }

      // Download tracks in parallel batches of 3
      const trackConcurrency = 3;
      for (int batch = 0; batch < audioTracks.length; batch += trackConcurrency) {
        if (_cancelledIds.contains(itemId)) break;
        final end = (batch + trackConcurrency).clamp(0, audioTracks.length);
        await Future.wait([
          for (int i = batch; i < end; i++) downloadTrack(i),
        ]);
      }

      // Final UI update
      _downloads[itemId] = DownloadInfo(
        itemId: itemId,
        status: DownloadStatus.downloading,
        progress: 1.0,
        title: title,
        author: author,
        coverUrl: coverUrl,
        libraryId: libraryId,
      );
      notifyListeners();

      final completedPaths = localPaths.whereType<String>().toList();

      final sessionId = sessionData['id'] as String?;
      if (sessionId != null) {
        try {
          await api.closePlaybackSession(sessionId)
              .timeout(const Duration(seconds: 10));
        } catch (_) {}
      }

      // Strip large nested objects from session data before persisting.
      // libraryItem contains the full item (with ALL episodes for podcasts)
      // and can be hundreds of KB - storing one per downloaded episode
      // bloats SharedPreferences and can cause ANR/OOM.
      final slimSession = Map<String, dynamic>.from(sessionData);
      slimSession.remove('libraryItem');

      _downloads[itemId] = DownloadInfo(
        itemId: itemId,
        status: DownloadStatus.downloaded,
        localPaths: completedPaths,
        sessionData: jsonEncode(slimSession),
        title: title,
        author: author,
        coverUrl: coverUrl,
        localCoverPath: localCoverPath,
        localDirPath: bookDir.path,
        libraryId: libraryId,
      );
      await _save();
      notifyListeners();

      // Show completion notification
      try {
        await notif.finishDownload(slot: slot, title: title);
      } catch (_) {}

      // If this book is currently streaming, hot-swap to local files
      try {
        final player = AudioPlayerService();
        if (player.currentItemId == itemId && player.hasBook) {
          await player.switchToLocal(itemId);
        }
      } catch (_) {}

      debugPrint('[Download] Complete: $title (${completedPaths.length} files)');
    } catch (e) {
      // Clean up partial files on any failure
      try {
        if (bookDir != null && bookDir.existsSync()) {
          bookDir.deleteSync(recursive: true);
          final parent = bookDir.parent;
          if (parent.existsSync() && parent.listSync().isEmpty) {
            parent.deleteSync();
          }
        }
      } catch (_) {}

      if (_cancelledIds.contains(itemId)) {
        debugPrint('[Download] Cancelled: $title');
        _downloads.remove(itemId);
        try {
          await notif.cancelDownload(slot);
        } catch (_) {}
      } else {
        final isStorageFull = e.toString().contains('No space left') ||
            e.toString().contains('ENOSPC');
        final isPermissionDenied = e.toString().contains('Permission denied') ||
            e.toString().contains('Operation not permitted') ||
            e.toString().contains('error = 13') ||
            e.toString().contains('errno = 1');
        final errorMsg = isStorageFull
            ? 'Not enough storage space'
            : isPermissionDenied
                ? 'Permission denied - check download location in Settings'
                : 'Download failed';
        debugPrint('[Download] Error: $e');
        _downloads[itemId] = DownloadInfo(
          itemId: itemId,
          status: DownloadStatus.error,
          title: title,
          author: author,
          coverUrl: coverUrl,
        );
        // Show error notification
        try {
          await notif.finishDownload(
            slot: slot,
            title: title,
            success: false,
            errorMessage: '$errorMsg: $title',
          );
        } catch (notifErr) {
          debugPrint('[Download] finishDownload non-fatal error: $notifErr');
        }
      }
    }

    _activeDownloadIds.remove(itemId);
    _downloadSlots.remove(itemId);
    try { _httpClients[itemId]?.close(); } catch (_) {}
    _httpClients.remove(itemId);
    _cancelledIds.remove(itemId);

    notifyListeners();

    // Fill freed slot from queue
    unawaited(_processQueue());
  }

  Future<void> deleteDownload(String itemId, {bool skipStopCheck = false}) async {
    final info = _downloads[itemId];
    if (info == null) return;

    // Stop playback if this item is currently playing to avoid crashes
    if (!skipStopCheck) {
      final player = AudioPlayerService();
      if (player.currentItemId == itemId ||
          (itemId.length > 36 && player.currentItemId == itemId.substring(0, 36))) {
        await player.stop();
      }
    }

    for (final path in info.localPaths) {
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }

    // Remove the download directory (new-style path from DownloadInfo, or legacy UUID path)
    try {
      final dirPath = info.localDirPath;
      if (dirPath != null && Directory(dirPath).existsSync()) {
        Directory(dirPath).deleteSync(recursive: true);
        // Clean up empty parent (Author folder) if it's now empty
        final parent = Directory(dirPath).parent;
        if (parent.existsSync() && parent.listSync().isEmpty) {
          parent.deleteSync();
        }
      } else {
        // Legacy fallback: UUID-based directory
        final basePath = await downloadBasePath;
        final bookDir = Directory('$basePath/$itemId');
        if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
      }
    } catch (_) {}

    try {
      final internalBase = await _internalBasePath;
      final coverDir = Directory('$internalBase/$itemId');
      final coverFile = File('$internalBase/$itemId/cover.jpg');
      // FileImage caches by path; evict so a re-download at the same path renders fresh.
      if (coverFile.existsSync()) {
        final evicted = PaintingBinding.instance.imageCache
            .evict(FileImage(coverFile));
        debugPrint('[Download] evict cover ${coverFile.path} -> $evicted');
      }
      if (coverDir.existsSync()) coverDir.deleteSync(recursive: true);
    } catch (e) {
      debugPrint('[Download] cover cleanup failed: $e');
    }

    _downloads.remove(itemId);
    await _save();
    notifyListeners();
  }

  void cancelDownload(String itemId) {
    if (_activeDownloadIds.contains(itemId)) {
      _cancelledIds.add(itemId);
      _httpClients[itemId]?.close();
      _httpClients.remove(itemId);
      // Notification cleanup happens in _executeDownload's catch block
    }
    // Remove from queue if it was waiting
    _queue.removeWhere((q) => q.itemId == itemId);
    _downloads.remove(itemId);
    notifyListeners();
  }
}
