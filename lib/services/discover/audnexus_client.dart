/// Audnexus lookup for series position/year enrichment by ASIN.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Series membership as reported by Audnexus.
class AudnexusSeries {
  final String? asin;
  final String name;
  final double? position;

  const AudnexusSeries({this.asin, required this.name, this.position});
}

/// Subset of an Audnexus book record used for series tracking.
class AudnexusBook {
  final String title;

  /// First 4-digit year found in `releaseDate`.
  final int? year;
  final AudnexusSeries? seriesPrimary;
  final AudnexusSeries? seriesSecondary;

  const AudnexusBook({
    required this.title,
    this.year,
    this.seriesPrimary,
    this.seriesSecondary,
  });
}

/// Fetches book metadata from api.audnex.us. All failures return null so
/// callers fall back to ABS-provided data.
class AudnexusClient {
  final http.Client _client = http.Client();

  void dispose() => _client.close();

  /// GET /books/{asin}. Region is pinned to `us`; a mismatched region 404s.
  Future<AudnexusBook?> book(String asin) async {
    try {
      final resp = await _client.get(
        Uri.parse('https://api.audnex.us/books/$asin?region=us'),
        headers: const {'User-Agent': 'Absorb/1.0'},
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;

      int? year;
      final release = data['releaseDate'] as String? ?? '';
      final m = RegExp(r'\d{4}').firstMatch(release);
      if (m != null) year = int.tryParse(m.group(0)!);

      AudnexusSeries? series(dynamic raw) {
        if (raw is! Map<String, dynamic>) return null;
        final name = raw['name'] as String? ?? '';
        if (name.isEmpty) return null;
        final pos = raw['position'];
        double? position;
        if (pos is num) position = pos.toDouble();
        if (pos is String) position = double.tryParse(pos);
        return AudnexusSeries(
          asin: raw['asin'] as String?,
          name: name,
          position: position,
        );
      }

      return AudnexusBook(
        title: data['title'] as String? ?? '',
        year: year,
        seriesPrimary: series(data['seriesPrimary']),
        seriesSecondary: series(data['seriesSecondary']),
      );
    } catch (_) {
      return null;
    }
  }
}
