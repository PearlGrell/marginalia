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

  /// Asks the system for it (or waits on a download already under way): ready once it's
  /// there, or why not.
  Future<({bool ready, String? error})> download() async {
    try {
      return (ready: await _channel.invokeMethod<bool>('download') ?? false, error: null);
    } on PlatformException catch (e) {
      return (ready: false, error: e.message);
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

/// A model's [answer], tidied: without a lead-in ("Here's a recap:") or a last sentence it
/// didn't finish.
String tidyAnswer(String answer) {
  var text = answer.trim();
  // Table rows and rules, and a closing line about the reader's questions: not the answer.
  text = text
      .split('\n')
      .where((line) => !RegExp(r'^\s*\|').hasMatch(line) && !RegExp(r'^\s*[-=*_]{3,}\s*$').hasMatch(line))
      .join('\n')
      .trim();
  text = text.replaceFirst(
    RegExp(r'[^.!?\n]*\b(questions? (might|would|could)|would you like|anything else|let me know)[^\n]*\?\s*$', caseSensitive: false),
    '',
  ).trim();
  final leadIn = RegExp(r"^(here(?:'|’)?s|here is|sure|okay|ok)\b[^:\n]{0,80}:\s*", caseSensitive: false);
  text = text.replaceFirst(leadIn, '');
  if (!RegExp(r'[.!?…]["”’)]?$').hasMatch(text)) {
    final end = text.lastIndexOf(RegExp(r'[.!?…]["”’)]?\s'));
    if (end > 0) text = text.substring(0, end + 1);
  }
  return text.isEmpty ? answer.trim() : text;
}
