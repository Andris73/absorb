import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'api_service.dart';

/// File extension (with leading dot) for an ABS ebookFile, or '' if unknown.
/// Prefers the explicit `ebookFormat` field over the filename extension so a
/// mis-named file can't be treated as the wrong format downstream (foliate-js
/// tells CBZ and EPUB apart purely by the served filename).
String ebookExtFromFile(Map<String, dynamic> ebookFile) {
  final fmt = (ebookFile['ebookFormat'] as String?)?.toLowerCase();
  if (fmt != null && fmt.isNotEmpty) return '.$fmt';
  final name = (ebookFile['metadata'] as Map<String, dynamic>?)?['filename'] as String?
      ?? ebookFile['name'] as String?
      ?? '';
  return name.contains('.') ? name.substring(name.lastIndexOf('.')).toLowerCase() : '';
}

/// Formats the in-app readers can open. EPUB uses the full reader, PDF the
/// dedicated viewer, and foliate-js covers MOBI/AZW3/CBZ. CBR is RAR-based
/// and foliate-js can't read it, so it's recognized but stays download-only.
const foliateEbookFormats = {'mobi', 'azw3', 'cbz'};
const readableEbookFormats = {'epub', 'pdf', ...foliateEbookFormats};
const allEbookFormats = {...readableEbookFormats, 'cbr'};

/// The ebook to use for a library item: the server's primary (media.ebookFile)
/// when set, otherwise the best supplementary ebook from libraryFiles - epub
/// first (mirroring the server's own primary pick), then the first readable
/// format, then any ebook file (a CBR can still be saved to device).
/// Audiobooks-only libraries mark every ebook supplementary and never set a
/// primary, so without this fallback those books always showed "no ebook".
Map<String, dynamic>? resolveEbookFile(Map<String, dynamic>? item) {
  if (item == null) return null;
  final media = item['media'] as Map<String, dynamic>?;
  final primary = media?['ebookFile'] as Map<String, dynamic>?;
  if (primary != null) return primary;
  Map<String, dynamic>? firstReadable;
  Map<String, dynamic>? firstEbook;
  for (final f in (item['libraryFiles'] as List<dynamic>? ?? const [])) {
    if (f is! Map<String, dynamic>) continue;
    final ext = ebookExtFromFile(f);
    final fmt = ext.startsWith('.') ? ext.substring(1) : ext;
    if (!allEbookFormats.contains(fmt)) continue;
    if (fmt == 'epub') return f;
    if (readableEbookFormats.contains(fmt)) firstReadable ??= f;
    firstEbook ??= f;
  }
  return firstReadable ?? firstEbook;
}

Future<Directory> _ebookCacheDir() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}/ebook_cache');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// Persistent cache path for an item's ebook, keyed by itemId so it's stable
/// across sessions. Lives in app support (not temp, not iCloud-backed docs) so
/// once an ebook is here it stays available offline.
Future<File> ebookCacheFileFor(String itemId, Map<String, dynamic> ebookFile) async {
  final dir = await _ebookCacheDir();
  return File('${dir.path}/$itemId${ebookExtFromFile(ebookFile)}');
}

/// True if the item's ebook is already cached on disk (readable offline).
Future<bool> isEbookCached(String itemId, Map<String, dynamic> ebookFile) async {
  final f = await ebookCacheFileFor(itemId, ebookFile);
  return f.existsSync() && await f.length() > 0;
}

/// Returns the cached ebook, downloading it if not already present. The download
/// is atomic (written to a .part file then renamed) so an interrupted transfer
/// never leaves a half-written file that looks complete. Once fetched the ebook
/// stays available offline.
Future<File> fetchEbookToCache(
  ApiService api,
  String itemId,
  Map<String, dynamic> ebookFile,
  String title,
) async {
  final cachedFile = await ebookCacheFileFor(itemId, ebookFile);
  if (cachedFile.existsSync() && await cachedFile.length() > 0) {
    debugPrint('[EbookCache] cache hit item=$itemId bytes=${await cachedFile.length()}');
    return cachedFile;
  }

  final ino = ebookFile['ino'] as String?;
  if (ino == null) throw Exception('No ebook file found');

  final cleanBase = api.baseUrl.endsWith('/')
      ? api.baseUrl.substring(0, api.baseUrl.length - 1)
      : api.baseUrl;
  final url = '$cleanBase/api/items/$itemId/file/$ino';

  debugPrint('[EbookCache] downloading item=$itemId url=$url');
  final startedAt = DateTime.now();
  final partFile = File('${cachedFile.path}.part');
  final request = http.Request('GET', Uri.parse(url));
  request.followRedirects = false;
  api.mediaHeaders.forEach((k, v) => request.headers[k] = v);
  final client = http.Client();
  try {
    var response = await client.send(request);
    var redirects = 0;
    while ([301, 302, 303, 307, 308].contains(response.statusCode) && redirects < 5) {
      final location = response.headers['location'];
      if (location == null) break;
      final redirectUrl = Uri.parse(url).resolve(location);
      final rReq = http.Request('GET', redirectUrl);
      api.mediaHeaders.forEach((k, v) => rReq.headers[k] = v);
      rReq.followRedirects = false;
      response = await client.send(rReq);
      redirects++;
    }
    if (response.statusCode != 200) {
      throw Exception('Failed to download ebook (${response.statusCode})');
    }
    final ct = response.headers['content-type'] ?? '';
    if (ct.contains('text/html')) throw Exception('Server returned an error page');
    final sink = partFile.openWrite();
    try {
      await response.stream.pipe(sink);
    } finally {
      await sink.close();
    }
    if (cachedFile.existsSync()) await cachedFile.delete();
    await partFile.rename(cachedFile.path);
    final secs = DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
    debugPrint('[EbookCache] downloaded item=$itemId bytes=${await cachedFile.length()} in ${secs}s');
  } finally {
    client.close();
    if (partFile.existsSync()) {
      try { await partFile.delete(); } catch (_) {}
    }
  }
  return cachedFile;
}

/// Removes any cached ebook for [itemId] (used when a download is removed).
Future<void> deleteCachedEbook(String itemId) async {
  try {
    final dir = await _ebookCacheDir();
    if (!dir.existsSync()) return;
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (name == itemId || name.startsWith('$itemId.')) {
        try { await f.delete(); } catch (_) {}
      }
    }
  } catch (_) {}
}
