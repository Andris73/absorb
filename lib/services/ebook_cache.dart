import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'api_service.dart';

/// Downloads an Audiobookshelf ebook file to a temp cache and returns it,
/// reusing the cached copy when present. Follows redirects manually so the auth
/// headers survive the hop. Throws with a message on failure.
Future<File> fetchEbookToCache(
  ApiService api,
  String itemId,
  Map<String, dynamic> ebookFile,
  String title,
) async {
  final ino = ebookFile['ino'] as String?;
  if (ino == null) throw Exception('No ebook file found');

  final ebookName = (ebookFile['metadata'] as Map<String, dynamic>?)?['filename'] as String?
      ?? ebookFile['name'] as String?
      ?? 'book';
  final ext = ebookName.contains('.')
      ? ebookName.substring(ebookName.lastIndexOf('.'))
      : '';
  final safeTitle = title.replaceAll(RegExp(r'[^\w\s-]'), '').trim();

  final cacheDir = await getTemporaryDirectory();
  final cachedFile = File('${cacheDir.path}/ereader_$safeTitle$ext');
  if (cachedFile.existsSync() && await cachedFile.length() > 0) return cachedFile;

  final cleanBase = api.baseUrl.endsWith('/')
      ? api.baseUrl.substring(0, api.baseUrl.length - 1)
      : api.baseUrl;
  final url = '$cleanBase/api/items/$itemId/file/$ino';

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
    final sink = cachedFile.openWrite();
    try {
      await response.stream.pipe(sink);
    } finally {
      await sink.close();
    }
  } finally {
    client.close();
  }
  return cachedFile;
}
