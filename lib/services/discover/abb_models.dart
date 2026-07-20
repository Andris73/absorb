/// Data models for AudiobookBay (ABB) scraping results.
library;

/// A browsable ABB genre, parsed from the site's navigation menu.
class AbbGenre {
  /// URL slug, e.g. `science-fiction` (path segment after `/type/`).
  final String slug;
  final String name;

  const AbbGenre({required this.slug, required this.name});
}

/// One row from an ABB search or genre listing page.
class AbbSearchResult {
  /// Last path segment of [detailUrl]; stable identifier for dedupe.
  final String id;
  final String title;
  final String? author;
  final String? narrator;
  final String? series;
  final int? year;
  final String? coverUrl;

  /// Absolute URL of the detail page; pass to `AbbClient.bookDetail`.
  final String detailUrl;
  final bool explicit;

  const AbbSearchResult({
    required this.id,
    required this.title,
    this.author,
    this.narrator,
    this.series,
    this.year,
    this.coverUrl,
    required this.detailUrl,
    this.explicit = false,
  });
}

/// Full detail-page scrape, including the torrent info hash.
class AbbBookDetail {
  /// 40-char hex BitTorrent info hash.
  final String infoHash;
  final String title;
  final String? author;
  final String? narrator;
  final String? format;
  final String? bitrate;
  final String? abridged;
  final String? language;
  final String? description;
  final String? fileSize;
  final String? coverUrl;
  final List<String> trackers;
  final bool explicit;
  final String canonicalUrl;
  final List<AbbComment> comments;

  const AbbBookDetail({
    required this.infoHash,
    required this.title,
    this.author,
    this.narrator,
    this.format,
    this.bitrate,
    this.abridged,
    this.language,
    this.description,
    this.fileSize,
    this.coverUrl,
    this.trackers = const [],
    this.explicit = false,
    required this.canonicalUrl,
    this.comments = const [],
  });
}

/// A user comment on an ABB detail page.
class AbbComment {
  final String author;
  final String? date;
  final String? body;

  /// Star rating 0-5 (count of lit star images).
  final int rating;
  final String? avatarUrl;

  const AbbComment({
    required this.author,
    this.date,
    this.body,
    this.rating = 0,
    this.avatarUrl,
  });
}
