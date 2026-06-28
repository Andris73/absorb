// Lenient, typo-tolerant matching shared by the library search and the
// add-books picker.
//
// Matching is:
//  - token-based, so query words can be in any order
//    ("peregrine museum" finds "Miss Peregrine's Museum of Wonders"),
//  - punctuation/diacritic-insensitive (commas, apostrophes, accents ignored),
//  - tolerant of small typos via a bounded edit distance.

const Map<String, String> _diacritics = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ø': 'o', 'ō': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
  'ñ': 'n', 'ç': 'c', 'ß': 'ss', 'æ': 'ae', 'œ': 'oe', 'ý': 'y', 'ÿ': 'y',
};

// Strip common punctuation to spaces, but keep letters of any script (so CJK
// titles aren't wiped). Apostrophes include the curly variant.
final RegExp _punct = RegExp("['\"’‘`,:;.!?\\-_/\\\\()\\[\\]{}&+@#%^*~|<>=—–]");
final RegExp _ws = RegExp(r'\s+');

String normalizeForSearch(String input) {
  if (input.isEmpty) return '';
  final lower = input.toLowerCase();
  final sb = StringBuffer();
  for (final ch in lower.split('')) {
    sb.write(_diacritics[ch] ?? ch);
  }
  return sb
      .toString()
      .replaceAll(_punct, ' ')
      .replaceAll(_ws, ' ')
      .trim();
}

List<String> tokenize(String normalized) =>
    normalized.isEmpty ? const [] : normalized.split(' ');

/// Bounded Levenshtein distance. Returns [max] + 1 as soon as the distance is
/// known to exceed [max], so it stays cheap for typo checks on short tokens.
int boundedLevenshtein(String a, String b, int max) {
  final la = a.length, lb = b.length;
  if ((la - lb).abs() > max) return max + 1;
  if (la == 0) return lb;
  if (lb == 0) return la;
  var prev = List<int>.generate(lb + 1, (i) => i);
  var curr = List<int>.filled(lb + 1, 0);
  for (var i = 1; i <= la; i++) {
    curr[0] = i;
    var rowMin = curr[0];
    final ca = a.codeUnitAt(i - 1);
    for (var j = 1; j <= lb; j++) {
      final cost = ca == b.codeUnitAt(j - 1) ? 0 : 1;
      var v = prev[j - 1] + cost;
      final del = prev[j] + 1;
      final ins = curr[j - 1] + 1;
      if (del < v) v = del;
      if (ins < v) v = ins;
      curr[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > max) return max + 1;
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[lb];
}

/// Best match of query token [q] against any of [tokens]:
/// 4 exact, 3 prefix, 2 substring, 1.5/1 fuzzy (edit distance 1/2), 0 none.
double bestTokenScore(String q, List<String> tokens) {
  double best = 0;
  final maxD = q.length >= 7 ? 2 : (q.length >= 4 ? 1 : 0);
  for (final t in tokens) {
    double s;
    if (t == q) {
      s = 4;
    } else if (t.startsWith(q)) {
      s = 3;
    } else if (q.length >= 3 && t.contains(q)) {
      s = 2;
    } else if (maxD > 0) {
      final d = boundedLevenshtein(q, t, maxD);
      s = d <= maxD ? (d == 1 ? 1.5 : 1.0) : 0;
    } else {
      s = 0;
    }
    if (s > best) best = s;
    if (best >= 4) break;
  }
  return best;
}

// Short, common words that shouldn't, on their own, exclude a match - so
// "the peregrine museum" still finds "Miss Peregrine's Museum of Wonders".
const Set<String> _stopWords = {
  'the', 'a', 'an', 'of', 'and', 'or', 'to', 'in', 'on', 'for', 'with',
  'at', 'by', 'from', 'as', 'is',
};

/// Score a target (pre-normalized) against the query tokens. Every meaningful
/// query word must match somewhere (AND semantics keeps noise down), but short
/// or stop words are optional - they add to the score when present and are
/// ignored when absent. Returns null when the item shouldn't appear at all.
/// [titleMatch] is true when a query token matched the title (or subtitle), so
/// the caller can keep "Books" sections to title hits.
({double score, bool titleMatch})? scoreTokens({
  required List<String> qTokens,
  required String normQuery,
  required String normTitle,
  required List<String> titleTokens,
  required List<String> authorTokens,
  required List<String> seriesTokens,
}) {
  if (qTokens.isEmpty) return null;
  double total = 0;
  bool titleMatch = false;
  int matched = 0;
  for (final q in qTokens) {
    final ts = bestTokenScore(q, titleTokens);
    final aScore = bestTokenScore(q, authorTokens) * 0.6;
    final sScore = bestTokenScore(q, seriesTokens) * 0.5;
    var best = ts;
    if (aScore > best) best = aScore;
    if (sScore > best) best = sScore;
    final optional = q.length <= 2 || _stopWords.contains(q);
    if (best <= 0) {
      if (!optional) return null; // a meaningful query word didn't match
      continue; // ignore an unmatched short/stop word
    }
    matched++;
    if (ts > 0) titleMatch = true;
    total += optional ? best * 0.5 : best;
  }
  if (matched == 0) return null;
  // Whole-query phrase bonus so close, contiguous matches rank first.
  if (normTitle == normQuery) {
    total += 8;
  } else if (normTitle.startsWith(normQuery)) {
    total += 6;
  } else if (normTitle.contains(normQuery)) {
    total += 5;
  }
  // Nudge shorter titles up so an exact short title beats a long one that
  // merely contains the words.
  total += 1.0 / (1 + titleTokens.length);
  return (score: total, titleMatch: titleMatch);
}
