import 'dart:math' as math;

import 'package:flutter/services.dart';

/// A paragraph of the book read so far, with its chapter (reading-order index).
typedef Paragraph = ({int chapter, String text});

/// Gemini Nano on this phone: there, ready to fetch (the system does it, once), on its way,
/// or not on this phone.
enum NanoStatus { available, downloadable, downloading, unavailable }

/// The reading companion's model, Gemini Nano, the phone's own (see `CompanionChannel.kt`).
/// Nothing leaves the phone.
class Nano {
  const Nano();

  static const _channel = MethodChannel('marginalia/companion');

  Future<NanoStatus> status() async {
    try {
      final name = await _channel.invokeMethod<String>('status');
      return NanoStatus.values.where((s) => s.name == name).firstOrNull ?? NanoStatus.unavailable;
    } on PlatformException {
      return NanoStatus.unavailable;
    } on MissingPluginException {
      return NanoStatus.unavailable;
    }
  }

  /// Asks the system for it; true once it's ready.
  Future<bool> download() async {
    try {
      return await _channel.invokeMethod<bool>('download') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Its answer to [prompt], or null if it couldn't give one.
  Future<String?> generate(String prompt) async {
    try {
      final text = (await _channel.invokeMethod<String>('generate', {'prompt': prompt}))?.trim();
      return text == null || text.isEmpty ? null : text;
    } on PlatformException {
      return null;
    }
  }
}

/// A sentence's end: its stop (and closing quote), then space, then a new sentence's start
/// ("“Who?” she asked" goes on).
final _sentenceEnd = RegExp(r'(?<=[.!?…]["”’)]?)\s+(?=["“‘(\p{Lu}\p{N}])', unicode: true);

/// [text] in sentences.
List<String> sentencesOf(String text) => [
  for (final s in text.split(_sentenceEnd))
    if (s.trim().isNotEmpty) s.trim(),
];

/// Where a name comes up in the book so far: its first sentences there, and the latest.
class Mentions {
  const Mentions({required this.count, required this.first, required this.latest});

  /// Sentences that name it.
  final int count;

  /// Where it's introduced.
  final List<String> first;

  /// The most recent, in reading order.
  final List<String> latest;

  bool get none => count == 0;

  List<String> get all => [...first, ...latest];
}

/// The sentences of [paragraphs] that name [name] (as a whole word, any case).
Mentions mentionsOf(String name, List<Paragraph> paragraphs, {int first = 3, int latest = 4}) {
  final words = name.trim();
  if (words.isEmpty) return const Mentions(count: 0, first: [], latest: []);
  final pattern = RegExp('(?<![\\p{L}\\p{N}])${RegExp.escape(words)}(?![\\p{L}\\p{N}])', caseSensitive: false, unicode: true);
  final found = [
    for (final p in paragraphs)
      for (final s in sentencesOf(p.text))
        if (pattern.hasMatch(s)) s,
  ];
  final head = found.take(first).toList();
  final tail = found.skip(head.length).toList();
  return Mentions(
    count: found.length,
    first: head,
    latest: tail.skip(math.max(0, tail.length - latest)).toList(),
  );
}

const _stopwords = {
  'that', 'this', 'with', 'have', 'from', 'they', 'were', 'what', 'when', 'your', 'said', 'there', 'their',
  'would', 'could', 'should', 'about', 'which', 'been', 'into', 'them', 'then', 'than', 'only', 'some', 'very',
  'will', 'more', 'like', 'just', 'over', 'such', 'even', 'much', 'most', 'other', 'upon', 'those', 'these',
  'here', 'where', 'while', 'after', 'before', 'again', 'still', 'never', 'always', 'every', 'being', 'through',
  'himself', 'herself', 'itself', 'myself', 'yourself', 'themselves', 'shall', 'might', 'must', 'does', 'done',
};

final _word = RegExp(r"[\p{L}][\p{L}'’]{3,}", unicode: true);

/// What the latest [chapters] chapters of [paragraphs] come to, in their own sentences:
/// the [count] that carry most of what's particular to them (names, places, the words they
/// keep coming back to, weighed against the rest of the book), in reading order.
List<String> recapSentences(List<Paragraph> paragraphs, {int chapters = 2, int count = 8}) {
  if (paragraphs.isEmpty) return const [];
  final last = paragraphs.last.chapter;
  final recent = paragraphs.where((p) => p.chapter > last - chapters).toList();

  // How many paragraphs of the whole text each word turns up in, for how telling it is.
  final seenIn = <String, int>{};
  for (final p in paragraphs) {
    for (final w in {for (final m in _word.allMatches(p.text)) m[0]!.toLowerCase()}) {
      seenIn[w] = (seenIn[w] ?? 0) + 1;
    }
  }
  double weight(String w) => math.log(paragraphs.length / (1 + (seenIn[w.toLowerCase()] ?? 0))) + 1;

  final sentences = [
    for (final p in recent)
      for (final s in sentencesOf(p.text))
        if (s.length >= 40 && s.length <= 400) s,
  ];
  final often = <String, int>{};
  for (final s in sentences) {
    for (final m in _word.allMatches(s)) {
      final w = m[0]!.toLowerCase();
      if (!_stopwords.contains(w)) often[w] = (often[w] ?? 0) + 1;
    }
  }

  double score(String s) {
    final words = {
      for (final m in _word.allMatches(s))
        if (!_stopwords.contains(m[0]!.toLowerCase())) m[0]!,
    };
    if (words.isEmpty) return 0;
    var total = 0.0;
    for (final w in words) {
      final name = w[0] == w[0].toUpperCase() && w[0] != w[0].toLowerCase();
      total += (often[w.toLowerCase()] ?? 0) * weight(w) * (name ? 1.5 : 1);
    }
    return total / math.sqrt(words.length);
  }

  final ranked = [for (final (i, s) in sentences.indexed) (i, score(s))]..sort((a, b) => b.$2.compareTo(a.$2));
  final chosen = ranked.take(count).map((r) => r.$1).toList()..sort();
  return [for (final i in chosen) sentences[i]];
}

String _passages(Iterable<String> sentences, {int maxChars = 5000}) {
  final out = StringBuffer();
  for (final s in sentences) {
    if (out.length + s.length > maxChars) break;
    out.writeln('- $s');
  }
  return out.toString();
}

/// For the model: who [name] is, from [mentions] only.
String whoPrompt(String name, String title, Mentions mentions) =>
    'Someone is reading the book "$title". Below are the passages that mention $name, from the '
    'start of the book up to where they are reading. Using only these passages, say who $name is '
    'in two to four sentences: who they are and how they relate to the others. Do not guess, and '
    'say nothing about anything later in the book.\n\n'
    'Passages:\n${_passages(mentions.all)}';

/// For the model: what has happened lately, from [sentences] only.
String recapPrompt(String title, List<String> sentences) =>
    'Someone is reading the book "$title" and wants a reminder of what has happened in the '
    'last chapter or two. Below are key sentences from those chapters, in order, up to where they '
    'are reading. Using only these, recap the story so far in three to five sentences, plainly. Do '
    'not guess, and say nothing about anything later in the book.\n\n'
    'Sentences:\n${_passages(sentences)}';
