import 'dart:math' as math;

import 'companion.dart';

/// A passage of the book: a paragraph, or a piece of a long one, or a few short ones together.
class Chunk {
  const Chunk({required this.index, required this.chapter, required this.text});

  /// Its place in the book, in reading order.
  final int index;

  /// Its chapter, 1-based in reading order.
  final int chapter;
  final String text;
}

const _stopwords = {
  'a', 'an', 'the', 'and', 'or', 'but', 'if', 'of', 'to', 'in', 'on', 'at', 'by', 'for', 'with', 'about',
  'from', 'into', 'over', 'after', 'before', 'as', 'is', 'was', 'are', 'were', 'be', 'been', 'being', 'am',
  'do', 'does', 'did', 'has', 'have', 'had', 'not', 'no', 'so', 'than', 'then', 'there', 'this', 'that',
  'these', 'those', 'it', 'its', 'he', 'him', 'his', 'she', 'her', 'hers', 'they', 'them', 'their', 'we',
  'us', 'our', 'you', 'your', 'i', 'me', 'my', 'who', 'whom', 'whose', 'what', 'which', 'when', 'where',
  'why', 'how', 'all', 'any', 'some', 'can', 'could', 'would', 'should', 'will', 'shall', 'may', 'might',
  'must', 'said', 'up', 'out', 'down', 'off', 'just', 'very', 'too', 'also', 'again', 'tell', 'happened',
  'happen', 'happens', 'book', 'story', 'chapter', 'mr', 'mrs', 'miss',
};

final _wordPattern = RegExp(r"[\p{L}\p{N}]+(?:['’][\p{L}]+)?", unicode: true);

/// The words of [text] to search by: lowercased, without the common ones, and plainly stemmed
/// ("Harry's" and "Harry", "wands" and "wand", are the same word).
List<String> searchTerms(String text) => [
  for (final m in _wordPattern.allMatches(text.toLowerCase()))
    if (_stem(m[0]!) case final w when w.length > 1 && !_stopwords.contains(w)) w,
];

String _stem(String word) {
  var w = word.replaceAll(RegExp(r"['’]s$"), '').replaceAll('’', "'");
  if (w.length > 4 && w.endsWith('s') && !w.endsWith('ss') && !w.endsWith('us')) w = w.substring(0, w.length - 1);
  return w;
}

/// The book up to the reader's page, searchable: every passage, and how well each matches a
/// question (BM25, with a lean towards what was read lately). It's built in a moment, on the
/// phone, from the text alone: nothing to download and nothing past the page to leak.
class BookIndex {
  BookIndex(List<Paragraph> paragraphs) : chunks = _chunk(paragraphs) {
    var total = 0;
    for (final c in chunks) {
      final counts = <String, int>{};
      for (final t in searchTerms(c.text)) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
      _counts.add(counts);
      _lengths.add(counts.values.fold(0, (a, b) => a + b));
      total += _lengths.last;
      for (final t in counts.keys) {
        _df[t] = (_df[t] ?? 0) + 1;
      }
    }
    _averageLength = chunks.isEmpty ? 1 : math.max(1, total / chunks.length);
  }

  final List<Chunk> chunks;
  final _counts = <Map<String, int>>[];
  final _lengths = <int>[];
  final _df = <String, int>{};
  late final double _averageLength;

  bool get isEmpty => chunks.isEmpty;

  /// Paragraphs as passages: long ones split at sentences, short ones (dialogue) joined to the
  /// next in the same chapter, so each says enough on its own.
  static List<Chunk> _chunk(List<Paragraph> paragraphs) {
    const short = 220, long = 900, piece = 550;
    final out = <Chunk>[];
    var pending = '';
    var pendingChapter = -1;

    void add(int chapter, String text) => out.add(Chunk(index: out.length, chapter: chapter + 1, text: text));

    void flush() {
      if (pending.isNotEmpty) add(pendingChapter, pending);
      pending = '';
    }

    for (final p in paragraphs) {
      final text = p.text.trim();
      if (text.isEmpty) continue;
      if (p.chapter != pendingChapter) flush();
      pendingChapter = p.chapter;
      if (text.length > long) {
        flush();
        var buffer = '';
        for (final s in sentencesOf(text)) {
          if (buffer.isNotEmpty && buffer.length + s.length > piece) {
            add(p.chapter, buffer);
            buffer = '';
          }
          buffer = buffer.isEmpty ? s : '$buffer $s';
        }
        if (buffer.isNotEmpty) add(p.chapter, buffer);
        continue;
      }
      pending = pending.isEmpty ? text : '$pending\n$text';
      if (pending.length >= short) flush();
    }
    flush();
    return out;
  }

  double _idf(String term) {
    final df = _df[term] ?? 0;
    return math.log(1 + (chunks.length - df + 0.5) / (df + 0.5));
  }

  /// The passages that best match [query], best first, at most [limit]. [recency] leans towards
  /// later passages (0 for none).
  List<Chunk> search(String query, {int limit = 8, double recency = 0.25}) {
    final terms = searchTerms(query).toSet();
    if (terms.isEmpty || chunks.isEmpty) return const [];
    const k1 = 1.2, b = 0.75;
    final scored = <(Chunk, double)>[];
    for (var i = 0; i < chunks.length; i++) {
      var score = 0.0;
      for (final t in terms) {
        final tf = _counts[i][t];
        if (tf == null) continue;
        score += _idf(t) * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * _lengths[i] / _averageLength));
      }
      if (score > 0) scored.add((chunks[i], score * (1 + recency * i / chunks.length)));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final s in scored.take(limit)) s.$1];
  }

  /// Passages that name [name] (all its words, as whole words), in reading order.
  List<Chunk> mentioning(String name) {
    final words = [
      for (final w in name.split(RegExp(r'\s+')))
        if (w.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '') case final c when c.isNotEmpty)
          RegExp('(?<![\\p{L}\\p{N}])${RegExp.escape(c)}(?![\\p{L}\\p{N}])', caseSensitive: false, unicode: true),
    ];
    if (words.isEmpty) return const [];
    return [
      for (final c in chunks)
        if (words.every((w) => w.hasMatch(c.text))) c,
    ];
  }

  /// Whether [question] is about something the book so far has: one of its telling words (not
  /// a common one, and not in most of the book) comes up in it.
  bool knows(String question) {
    for (final term in searchTerms(question)) {
      final df = _df[term] ?? 0;
      if (df > 0 && df <= math.max(2, chunks.length * 0.6)) return true;
    }
    return false;
  }

  /// The last [count] passages: where the reader is.
  List<Chunk> latest(int count) => chunks.sublist(math.max(0, chunks.length - count));
}
