/// Minimal Transmission RPC client for adding and monitoring torrents.
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// HTTP 401 from the RPC endpoint - bad username/password.
class TransmissionAuthException implements Exception {
  final String message;
  const TransmissionAuthException(this.message);
  @override
  String toString() => 'TransmissionAuthException: $message';
}

/// Transport failure or RPC-level `result != "success"`.
class TransmissionRpcException implements Exception {
  final String message;
  const TransmissionRpcException(this.message);
  @override
  String toString() => 'TransmissionRpcException: $message';
}

/// Transmission torrent status ints.
abstract final class TransmissionStatus {
  static const stopped = 0;
  static const checkWaiting = 1;
  static const checking = 2;
  static const downloadWaiting = 3;
  static const downloading = 4;
  static const seedWaiting = 5;
  static const seeding = 6;
  static const isolated = 7;

  /// Persisted status key used by the download tracker:
  /// "seeding", "stopped" or "downloading".
  static String key(int status) {
    switch (status) {
      case seeding:
      case seedWaiting:
        return 'seeding';
      case stopped:
      case isolated:
        return 'stopped';
      default:
        return 'downloading';
    }
  }
}

/// Talks to `{baseUrl}/transmission/rpc`, handling the 409 session-id
/// handshake transparently.
class TransmissionClient {
  /// [baseUrl] is the daemon root, e.g. `http://nas:9091`. Credentials are
  /// optional; when [username] is non-empty basic auth is sent.
  TransmissionClient({
    required String baseUrl,
    this.username = '',
    this.password = '',
  }) : _rpcUrl = Uri.parse(
            '${baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl}/transmission/rpc');

  final Uri _rpcUrl;
  final String username;
  final String password;
  final http.Client _client = http.Client();
  String? _sessionId;

  void dispose() => _client.close();

  Map<String, String> get _headers {
    final h = <String, String>{'Content-Type': 'application/json'};
    final sid = _sessionId;
    if (sid != null) h['X-Transmission-Session-Id'] = sid;
    if (username.isNotEmpty) {
      h['Authorization'] =
          'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    }
    return h;
  }

  Future<Map<String, dynamic>> _rpc(
      String method, Map<String, dynamic> arguments) async {
    final body = jsonEncode({'method': method, 'arguments': arguments});
    var resp = await _client
        .post(_rpcUrl, headers: _headers, body: body)
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode == 409) {
      _sessionId = resp.headers['x-transmission-session-id'];
      resp = await _client
          .post(_rpcUrl, headers: _headers, body: body)
          .timeout(const Duration(seconds: 30));
    }
    if (resp.statusCode == 401) {
      throw const TransmissionAuthException('Invalid credentials (401)');
    }
    if (resp.statusCode != 200) {
      throw TransmissionRpcException('HTTP ${resp.statusCode} from $method');
    }
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    if (decoded['result'] != 'success') {
      throw TransmissionRpcException(
          '$method failed: ${decoded['result']}');
    }
    return decoded['arguments'] as Map<String, dynamic>? ?? {};
  }

  /// Connection test; returns the session settings map.
  Future<Map<String, dynamic>> sessionGet() => _rpc('session-get', {});

  /// Add a magnet link. A `torrent-duplicate` response counts as success
  /// (the torrent is already there, which is what the caller wanted).
  Future<({int id, String hashString})> torrentAdd(
      String magnetUri, String downloadDir) async {
    final args = await _rpc('torrent-add', {
      'filename': magnetUri,
      'download-dir': downloadDir,
    });
    final added = (args['torrent-added'] ?? args['torrent-duplicate'])
        as Map<String, dynamic>?;
    if (added == null) {
      throw const TransmissionRpcException(
          'torrent-add returned no torrent-added/torrent-duplicate');
    }
    return (
      id: (added['id'] as num?)?.toInt() ?? 0,
      hashString: added['hashString'] as String? ?? '',
    );
  }

  /// Fetch progress/status fields for the given torrent ids.
  Future<List<Map<String, dynamic>>> torrentGet(List<int> ids) async {
    final args = await _rpc('torrent-get', {
      'ids': ids,
      'fields': [
        'id', 'name', 'hashString', 'status', 'percentDone',
        'rateDownload', 'rateUpload', 'error', 'errorString',
        'uploadRatio', 'seedRatioLimit', 'seedRatioMode',
      ],
    });
    return (args['torrents'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
  }

  Future<void> torrentRemove(List<int> ids,
      {bool deleteLocalData = false}) async {
    await _rpc('torrent-remove', {
      'ids': ids,
      'delete-local-data': deleteLocalData,
    });
  }

  /// Target upload ratio for a torrent: its own limit when per-torrent mode
  /// (seedRatioMode == 1) with a positive limit, else 1.0.
  static double seedTarget(int seedRatioMode, double seedRatioLimit) =>
      (seedRatioMode == 1 && seedRatioLimit > 0) ? seedRatioLimit : 1.0;

  /// 0..1 progress toward the seed target.
  static double seedProgress(double uploadRatio, double target) =>
      (uploadRatio < 0 ? 0.0 : uploadRatio / max(target, 0.01))
          .clamp(0.0, 1.0);

  /// Expand a download-path template (`{author}/{series}/{title}` by default)
  /// into an absolute path under `/downloads/audiobooks`. Values are
  /// sanitized for the filesystem; missing values become "Unknown".
  static String buildDownloadPath({
    required String template,
    String? author,
    String? narrator,
    String? series,
    String? title,
    String? year,
  }) {
    String seg(String? v) {
      final s =
          (v ?? '').replaceAll(RegExp(r'[/\\:*?"<>|]'), ' ').trim();
      return s.isEmpty ? 'Unknown' : s;
    }

    var path = template
        .replaceAll('{author}', seg(author))
        .replaceAll('{narrator}', seg(narrator))
        .replaceAll('{series}', seg(series))
        .replaceAll('{title}', seg(title))
        .replaceAll('{year}', seg(year));
    final segments =
        path.split('/').where((s) => s.trim().isNotEmpty).toList();
    path = '/downloads/audiobooks/${segments.join('/')}';
    while (path.contains('//')) {
      path = path.replaceAll('//', '/');
    }
    return path;
  }
}
