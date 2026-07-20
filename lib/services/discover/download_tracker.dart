/// Persistent tracking of Discover downloads sent to Transmission.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../scoped_prefs.dart';

const _prefsKey = 'discoverActiveDownloads';

/// One torrent the user started from Discover.
class TrackedDownload {
  final int torrentId;
  final String infoHash;
  final String title;
  final String author;

  /// "downloading", "seeding" or "stopped".
  String status;

  /// 0..1 download progress.
  double progress;
  final DateTime addedAt;
  final String downloadPath;
  bool isFinished;

  TrackedDownload({
    required this.torrentId,
    required this.infoHash,
    required this.title,
    required this.author,
    this.status = 'downloading',
    this.progress = 0,
    required this.addedAt,
    required this.downloadPath,
    this.isFinished = false,
  });

  Map<String, dynamic> toJson() => {
        'torrentId': torrentId,
        'infoHash': infoHash,
        'title': title,
        'author': author,
        'status': status,
        'progress': progress,
        'addedAt': addedAt.toIso8601String(),
        'downloadPath': downloadPath,
        'isFinished': isFinished,
      };

  factory TrackedDownload.fromJson(Map<String, dynamic> json) =>
      TrackedDownload(
        torrentId: (json['torrentId'] as num?)?.toInt() ?? 0,
        infoHash: json['infoHash'] as String? ?? '',
        title: json['title'] as String? ?? '',
        author: json['author'] as String? ?? '',
        status: json['status'] as String? ?? 'downloading',
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.now(),
        downloadPath: json['downloadPath'] as String? ?? '',
        isFinished: json['isFinished'] as bool? ?? false,
      );
}

/// Singleton store of tracked downloads, persisted via [ScopedPrefs].
/// Notifies listeners on every mutation so the UI can rebuild.
class DownloadTracker extends ChangeNotifier {
  DownloadTracker._();
  static final DownloadTracker instance = DownloadTracker._();

  final List<TrackedDownload> _items = [];
  Future<void>? _load;

  // Memoized so concurrent callers await the same load instead of racing it.
  Future<void> _ensureLoaded() => _load ??= _loadItems();

  Future<void> _loadItems() async {
    try {
      final raw = await ScopedPrefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as List<dynamic>;
      _items
        ..clear()
        ..addAll(decoded.map(
            (e) => TrackedDownload.fromJson(e as Map<String, dynamic>)));
    } catch (e) {
      debugPrint('[DownloadTracker] load failed: $e');
    }
  }

  Future<void> _save() async {
    await ScopedPrefs.setString(
        _prefsKey, jsonEncode(_items.map((d) => d.toJson()).toList()));
  }

  /// Upsert by info hash. Re-tracking an existing hash resets it to
  /// "downloading" at 0 progress (e.g. the user re-added the torrent).
  Future<void> track({
    required int torrentId,
    required String infoHash,
    required String title,
    required String author,
    required String downloadPath,
  }) async {
    await _ensureLoaded();
    _items.removeWhere((d) => d.infoHash == infoHash);
    _items.add(TrackedDownload(
      torrentId: torrentId,
      infoHash: infoHash,
      title: title,
      author: author,
      addedAt: DateTime.now(),
      downloadPath: downloadPath,
    ));
    await _save();
    notifyListeners();
  }

  /// Update progress/status for a hash. Marks the download finished once
  /// progress reaches 1.0 or Transmission moves it to seeding/stopped.
  Future<void> updateProgress(
      String infoHash, double progress, String status) async {
    await _ensureLoaded();
    for (final d in _items) {
      if (d.infoHash != infoHash) continue;
      d.progress = progress;
      d.status = status;
      if (progress >= 1 || status == 'seeding' || status == 'stopped') {
        d.isFinished = true;
      }
      await _save();
      notifyListeners();
      return;
    }
  }

  Future<void> remove(String infoHash) async {
    await _ensureLoaded();
    final before = _items.length;
    _items.removeWhere((d) => d.infoHash == infoHash);
    if (_items.length == before) return;
    await _save();
    notifyListeners();
  }

  /// All tracked downloads, newest first.
  Future<List<TrackedDownload>> all() async {
    await _ensureLoaded();
    final out = List.of(_items)
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return out;
  }
}
