/// AudiobookBay scraper: search, genre browsing, and detail-page parsing.
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'abb_models.dart';
import 'title_matching.dart' show stripTrailingAuthor;

/// The mirror returned a Cloudflare challenge (HTTP 503/403). The scraper
/// cannot pass it; the user should try a different mirror.
class AbbCloudflareException implements Exception {
  final String message;
  const AbbCloudflareException(this.message);
  @override
  String toString() => 'AbbCloudflareException: $message';
}

/// Non-200 response that is not a Cloudflare challenge.
class AbbPageLoadException implements Exception {
  final String message;
  const AbbPageLoadException(this.message);
  @override
  String toString() => 'AbbPageLoadException: $message';
}

/// A detail page was fetched but no torrent info hash could be extracted.
class AbbNoInfoHashException implements Exception {
  final String url;
  const AbbNoInfoHashException(this.url);
  @override
  String toString() => 'AbbNoInfoHashException: no info hash on $url';
}

const _defaultTrackers = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://tracker.internetwarriors.net:1337/announce',
  'udp://tracker.leechers-paradise.org:6969/announce',
  'udp://tracker.coppersurfer.tk:6969/announce',
  'udp://tracker.pirateparty.gr:6969/announce',
  'udp://tracker.cyberia.is:6969/announce',
];

/// Scrapes an AudiobookBay mirror. All methods throw [AbbCloudflareException]
/// or [AbbPageLoadException] on fetch failure.
class AbbClient {
  /// [baseUrl] is the mirror root, e.g. `https://audiobookbay.lu`.
  AbbClient(String baseUrl) : _base = _trimSlash(baseUrl);

  final String _base;
  final http.Client _client = http.Client();

  static String _trimSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  // Cloudflare blocks non-browser user agents, hence the Safari UA.
  static const _headers = {
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) '
            'Version/18.0 Mobile/15E148 Safari/604.1',
  };

  void dispose() => _client.close();

  Future<dom.Document> _fetchDoc(Uri url) async {
    final resp = await _client
        .get(url, headers: _headers)
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode == 503 || resp.statusCode == 403) {
      throw AbbCloudflareException(
          'Cloudflare challenge (${resp.statusCode}) at $url');
    }
    if (resp.statusCode != 200) {
      throw AbbPageLoadException('HTTP ${resp.statusCode} at $url');
    }
    return html_parser.parse(resp.body);
  }

  /// Search via the path form `{base}/search/{query}/`. The `?s=` form 301s
  /// to the homepage on some mirrors and drops the query, so this is primary.
  Future<List<AbbSearchResult>> search(String query) async {
    final url = Uri.parse('$_base/search/${Uri.encodeComponent(query)}/');
    return _parseResultRows(await _fetchDoc(url));
  }

  /// Search via the `?s=` query form. The literal `cat=undefined,undefined`
  /// is required by the site. Series resolution tries this form first, then
  /// [search], keeping whichever parses non-empty.
  Future<List<AbbSearchResult>> searchAlternate(String query) async {
    final url = Uri.parse(
        '$_base/?s=${Uri.encodeQueryComponent(query)}&cat=undefined,undefined');
    return _parseResultRows(await _fetchDoc(url));
  }

  /// Parse the homepage navigation menu into browsable genres.
  Future<List<AbbGenre>> genres() async {
    final doc = await _fetchDoc(Uri.parse('$_base/'));
    const anchor = "a[href*='/audio-books/type/']";
    var links = <dom.Element>[];
    for (final container in const [
      '#nav-menu .menu-item',
      '.nav-menu',
      '.menu-header-container',
      '#menu-header-menu',
      '.menu',
    ]) {
      links = doc.querySelectorAll('$container $anchor');
      if (links.isNotEmpty) break;
    }
    if (links.isEmpty) links = doc.querySelectorAll(anchor);

    final seen = <String>{};
    final out = <AbbGenre>[];
    for (final a in links) {
      final href = a.attributes['href'];
      if (href == null) continue;
      final segments = Uri.parse('$_base/').resolve(href).pathSegments;
      final typeIdx = segments.indexOf('type');
      if (typeIdx < 0 || typeIdx + 1 >= segments.length) continue;
      final slug = segments[typeIdx + 1];
      final name = a.text.trim();
      if (slug.isEmpty || name.isEmpty || !seen.add(slug)) continue;
      out.add(AbbGenre(slug: slug, name: name));
    }
    return out;
  }

  /// Listing page for a genre slug. [page] >= 2 fetches `page/{n}/`.
  Future<List<AbbSearchResult>> genreListing(String slug, {int page = 1}) async {
    var url = '$_base/audio-books/type/$slug/';
    if (page >= 2) url += 'page/$page/';
    return _parseResultRows(await _fetchDoc(Uri.parse(url)));
  }

  List<AbbSearchResult> _parseResultRows(dom.Document doc) {
    var rows = doc.querySelectorAll('#content .post');
    if (rows.isEmpty) rows = doc.querySelectorAll('#content article.post');
    if (rows.isEmpty) rows = doc.querySelectorAll('.post');

    final base = Uri.parse('$_base/');
    final out = <AbbSearchResult>[];
    for (final row in rows) {
      dom.Element? link;
      for (final sel in const [
        '.postTitle h2 a',
        '.post-title h2 a',
        'h2 a',
        '.entry-title a',
      ]) {
        link = row.querySelector(sel);
        if (link != null) break;
      }
      final href = link?.attributes['href'];
      if (link == null || href == null) continue;
      final title = link.text.trim();
      if (title.isEmpty) continue;
      final detailUrl = base.resolve(href).toString();
      final segments = Uri.parse(detailUrl).pathSegments
          .where((s) => s.isNotEmpty)
          .toList();
      final id = segments.isNotEmpty ? segments.last : detailUrl;

      final meta = row.querySelector('.postContent')?.text ??
          row.querySelector('.entry-content')?.text ??
          row.querySelector('.post-excerpt')?.text ??
          '';
      String? field(String label) {
        final m = RegExp('$label:\\s*([^\\n]+)', caseSensitive: false)
            .firstMatch(meta);
        final v = m?.group(1)?.trim();
        return (v == null || v.isEmpty) ? null : v;
      }

      int? year;
      final yearText = field('Year');
      if (yearText != null) {
        year = int.tryParse(
            RegExp(r'\d{4}').firstMatch(yearText)?.group(0) ?? '');
      }

      final img = row.querySelector('img[src]');
      final coverUrl = img != null
          ? base.resolve(img.attributes['src']!).toString()
          : null;

      var explicit = false;
      final info = row.querySelector('.postInfo')?.text;
      if (info != null) {
        final cut = info.toLowerCase().indexOf('language:');
        final before = cut >= 0 ? info.substring(0, cut) : info;
        explicit = before.toLowerCase().contains('sex scenes');
      }

      out.add(AbbSearchResult(
        id: id,
        title: title,
        author: field('Author'),
        narrator: field('Narrator'),
        series: field('Series'),
        year: year,
        coverUrl: coverUrl,
        detailUrl: detailUrl,
        explicit: explicit,
      ));
    }
    return out;
  }

  /// Scrape a detail page. Throws [AbbNoInfoHashException] when no torrent
  /// info hash can be found.
  Future<AbbBookDetail> bookDetail(String detailUrl) async {
    final doc = await _fetchDoc(Uri.parse(detailUrl));
    final base = Uri.parse(detailUrl);

    final infoHash = _extractInfoHash(doc);
    if (infoHash == null) throw AbbNoInfoHashException(detailUrl);

    var title = doc
        .querySelector("meta[property='og:title']")
        ?.attributes['content']
        ?.trim();
    if (title == null || title.isEmpty) {
      for (final sel in const ['.postTitle h1', '.entry-title', 'h1']) {
        title = doc.querySelector(sel)?.text.trim();
        if (title != null && title.isNotEmpty) break;
      }
    }
    if (title == null || title.isEmpty) title = 'Unknown';

    String? textOf(String selector) {
      final t = doc.querySelector(selector)?.text.trim();
      return (t == null || t.isEmpty) ? null : t;
    }

    final author =
        textOf('span.author') ?? textOf('.author, [class*=author]');
    final narrators = doc
        .querySelectorAll('span.narrator')
        .map((e) => e.text.trim())
        .where((t) => t.isNotEmpty)
        .join(', ');

    String? description;
    final desc = doc.querySelector('.desc, [itemprop=description]');
    if (desc != null) {
      final paras = desc
          .querySelectorAll('p')
          .where((p) =>
              p.querySelector(
                  '.author,.narrator,.format,.bitrate,.is_abridged') ==
              null)
          .map((p) => p.text.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      if (paras.isNotEmpty) description = paras.join('\n\n');
    }

    String? fileSize;
    for (final tr in doc.querySelectorAll('table tr')) {
      final cells = tr.children;
      if (cells.length < 2) continue;
      if (cells[0].text.toLowerCase().contains('file size')) {
        final v = cells[1].text.trim();
        if (v.isNotEmpty) fileSize = v;
        break;
      }
    }

    String? coverUrl;
    final coverSrc = doc.querySelector('img[itemprop=image]')?.attributes['src'] ??
        doc.querySelector("meta[property='og:image']")?.attributes['content'] ??
        doc
            .querySelector(
                '.postContent .center img, img.cover, [class*=cover] img, .poster img')
            ?.attributes['src'];
    if (coverSrc != null && coverSrc.isNotEmpty) {
      coverUrl = base.resolve(coverSrc).toString();
    }

    var trackers = <String>[];
    for (final el in doc.querySelectorAll(
        "a[href^='udp://'], a[href^='http://tracker'], a[href^='https://tracker'], "
        '.tracker-list li, .trackers a')) {
      final t = (el.attributes['href'] ?? el.text).trim();
      if (t.isNotEmpty && !trackers.contains(t)) trackers.add(t);
    }
    if (trackers.isEmpty) trackers = List.of(_defaultTrackers);

    final comments = <AbbComment>[];
    for (final li in doc.querySelectorAll('ul.commentList > li')) {
      final commentAuthor = li
          .querySelector('.commentAuthor, [itemprop=name]')
          ?.text
          .trim();
      if (commentAuthor == null || commentAuthor.isEmpty) continue;
      var body = li.querySelector('[itemprop=reviewBody]')?.text.trim();
      if (body == null) {
        final paras = li.querySelectorAll('.commentRight p');
        if (paras.isNotEmpty) body = paras.last.text.trim();
      }
      comments.add(AbbComment(
        author: commentAuthor,
        date: li.querySelector('[itemprop=dateCreated]')?.text.trim(),
        body: body,
        rating: li.querySelectorAll('img[src*=star_on]').length,
        avatarUrl: li
            .querySelector('.commentLeft img, img.avatar')
            ?.attributes['src'],
      ));
    }

    var explicit =
        doc.querySelector("div.postInfo a[href*='sex-scenes']") != null;
    if (!explicit) {
      explicit = doc.querySelectorAll('div.postInfo a[rel~=category]').any(
          (a) => a.text.trim().toLowerCase() == 'sex scenes');
    }

    return AbbBookDetail(
      infoHash: infoHash,
      title: title,
      author: author,
      narrator: narrators.isEmpty ? null : narrators,
      format: textOf('span.format, [itemprop=encodingFormat]'),
      bitrate: textOf('span.bitrate'),
      abridged: textOf('span.is_abridged'),
      language: textOf('span.language'),
      description: description,
      fileSize: fileSize,
      coverUrl: coverUrl,
      trackers: trackers,
      explicit: explicit,
      canonicalUrl: detailUrl,
      comments: comments,
    );
  }

  static final _hex40 = RegExp(r'^[a-fA-F0-9]{40}$');

  String? _extractInfoHash(dom.Document doc) {
    final magnet =
        doc.querySelector("a[href^='magnet:']")?.attributes['href'];
    if (magnet != null) {
      final idx = magnet.indexOf('urn:btih:');
      if (idx >= 0 && magnet.length >= idx + 9 + 40) {
        final hash = magnet.substring(idx + 9, idx + 9 + 40);
        if (_hex40.hasMatch(hash)) return hash;
      }
    }
    final magnetLink = doc.querySelector('#magnetLink')?.text.trim();
    if (magnetLink != null && _hex40.hasMatch(magnetLink)) return magnetLink;
    final code = doc.querySelector('code')?.text.trim();
    if (code != null && _hex40.hasMatch(code)) return code;
    return RegExp(r'[a-fA-F0-9]{40}')
        .firstMatch(doc.body?.text ?? '')
        ?.group(0);
  }

  /// Build a magnet URI from an info hash, display name and tracker list.
  static String buildMagnet(
      String infoHash, String title, List<String> trackers) {
    final sb = StringBuffer('magnet:?xt=urn:btih:$infoHash');
    sb.write('&dn=${Uri.encodeComponent(title)}');
    for (final t in trackers) {
      sb.write('&tr=${Uri.encodeComponent(t)}');
    }
    return sb.toString();
  }

  /// Heuristic extraction of "(series name, book number)" from an ABB
  /// listing title, e.g. "Dungeon Crawler Carl, Book 3 - Matt Dinniman".
  /// Returns null when no book number is present.
  static ({String name, double number})? parseSeriesFromTitle(String title) {
    final stripped = stripTrailingAuthor(title).trim();
    final m = RegExp(
      r'^(?<series>.*?)[\s,]+(?:book|vol\.?|volume|#)?\s*(?<num>\d+(?:\.\d+)?)(?:\s*[:\-\u2013\u2014].*)?$',
      caseSensitive: false,
    ).firstMatch(stripped);
    if (m == null) return null;
    final number = double.tryParse(m.namedGroup('num') ?? '');
    if (number == null) return null;

    var series = m.namedGroup('series') ?? '';
    series = series.replaceAll(
        RegExp(r'^[\s,:\-\u2013\u2014\t]+|[\s,:\-\u2013\u2014\t]+$'), '');
    // "{Title}: {Series}, Book N" - keep the segment after the last separator.
    var cut = -1;
    for (final sep in const [': ', ' - ', ' \u2013 ', ' \u2014 ']) {
      final i = series.lastIndexOf(sep);
      if (i >= 0 && i + sep.length > cut) cut = i + sep.length;
    }
    if (cut > 0 && cut < series.length) series = series.substring(cut).trim();
    if (series.isEmpty) return null;
    return (name: series, number: number);
  }
}
