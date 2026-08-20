/// Fuzzy title/author matching shared by ownership filtering and
/// series-tracking ABB resolution.
library;

import 'dart:math';

const _stopwords = {'the', 'a', 'an', 'of', 'and', 'to', 'in', 'or'};

const _diacritics = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ø': 'o', 'ō': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
  'ý': 'y', 'ÿ': 'y',
  'ñ': 'n', 'ç': 'c', 'š': 's', 'ž': 'z', 'æ': 'ae', 'œ': 'oe', 'ß': 'ss',
};

/// Lowercase alphanumerics only. Used as an equality key for titles.
String normalizeTitle(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Fold common accented characters to their ASCII base.
String foldDiacritics(String s) {
  final sb = StringBuffer();
  for (final rune in s.runes) {
    final ch = String.fromCharCode(rune);
    sb.write(_diacritics[ch] ?? ch);
  }
  return sb.toString();
}

/// Lowercased, diacritic-folded word tokens with stopwords and
/// single-character *letter* fragments dropped. Digits are kept regardless
/// of length - "4" is a meaningful volume number, not filler like "a".
List<String> tokenize(String s) {
  final folded = foldDiacritics(s.toLowerCase());
  return folded
      .replaceAll(RegExp(r'[^a-z0-9]'), ' ')
      .split(RegExp(r'\s+'))
      .where((t) =>
          (t.length >= 2 || _digits.hasMatch(t)) && !_stopwords.contains(t))
      .toList();
}

final _digits = RegExp(r'^[0-9]+$');

/// Overlap score of [wanted] against [candidate]: 1.0 when every wanted
/// token appears in the candidate, otherwise shared / wanted count.
///
/// A volume/book number is the one token that distinguishes otherwise
/// near-identical listings ("Vol. 4" vs "Vol. 6" share every other word),
/// so if [wanted] names one, [candidate] must carry that same number
/// (compared numerically, so "04" matches "4") - word overlap alone isn't
/// enough to call it a match.
double score(String wanted, String candidate) {
  final w = tokenize(wanted).toSet();
  if (w.isEmpty) return 0;
  final c = tokenize(candidate).toSet();
  final wantedNumbers = w.where(_digits.hasMatch).map(int.parse).toSet();
  if (wantedNumbers.isNotEmpty) {
    final candidateNumbers = c.where(_digits.hasMatch).map(int.parse).toSet();
    if (!wantedNumbers.every(candidateNumbers.contains)) return 0;
  }
  final shared = w.intersection(c).length;
  if (shared == w.length) return 1.0;
  return shared / w.length;
}

/// Loose title equality used for library ownership checks.
bool titlesMatch(String a, String b) {
  final ta = tokenize(a).toSet();
  final tb = tokenize(b).toSet();
  if (ta.isEmpty || tb.isEmpty) return false;
  if (ta.length == tb.length && ta.containsAll(tb)) return true;
  final ja = (ta.toList()..sort()).join(' ');
  final jb = (tb.toList()..sort()).join(' ');
  if (ja.contains(jb) || jb.contains(ja)) return true;
  final smaller = min(ta.length, tb.length);
  final shared = ta.intersection(tb).length;
  return shared == smaller && smaller >= 2;
}

/// Author equality for ownership checks. When either side is empty the
/// title match alone suffices, so this returns true.
bool authorsMatch(String a, String b) {
  final ta = tokenize(a).toSet();
  final tb = tokenize(b).toSet();
  if (ta.isEmpty || tb.isEmpty) return true;
  final smaller = min(ta.length, tb.length);
  final shared = ta.intersection(tb).length;
  return shared >= max(1, smaller - 1);
}

/// Strip the trailing " - Author" segment ABB appends to listing titles.
/// Recognises hyphen, en-dash and em-dash separators.
String stripTrailingAuthor(String title) {
  var idx = -1;
  for (final sep in const [' - ', ' \u2013 ', ' \u2014 ']) {
    final i = title.lastIndexOf(sep);
    if (i > idx) idx = i;
  }
  return idx > 0 ? title.substring(0, idx) : title;
}

/// Reduce an ABB listing title to its core book title: drop the trailing
/// author, bracketed noise, volume/book numbering and edition words.
/// Colon subtitles are kept on purpose - they disambiguate short titles.
String coreTitle(String abbTitle) {
  var t = stripTrailingAuthor(abbTitle);
  t = t.replaceAll(RegExp(r'\([^)]*\)'), ' ');
  t = t.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
  t = t.replaceAll(
      RegExp(r'\b(book|vol|volume|part|episode|no|number)\b\.?\s*#?\d+.*$',
          caseSensitive: false),
      ' ');
  t = t.replaceAll(RegExp(r'#\s*\d+.*$'), ' ');
  t = t.replaceAll(
      RegExp(r'\b(unabridged|abridged|audiobook|a novel)\b',
          caseSensitive: false),
      ' ');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}
