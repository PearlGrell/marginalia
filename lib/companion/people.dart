import 'companion.dart';
import 'retrieval.dart';

/// Someone (or somewhere) the book names, as far as the reader has read.
class Person {
  const Person({
    required this.name,
    required this.mentions,
    required this.byChapter,
    required this.firstSeen,
    required this.firstSentence,
  });

  final String name;

  /// How often the book names them, up to the reader's page.
  final int mentions;

  /// Mentions in each chapter, 1-based (index 0 is chapter 1).
  final List<int> byChapter;

  /// Where they come in.
  final Chunk firstSeen;

  /// The first sentence that names them.
  final String firstSentence;
}

/// [match] as a name: "The Mouse" is the Mouse, "Alice's" (and "Alice's Adventures") is Alice;
/// null for a contraction ("I'm", "I'll").
String? _asName(String match) {
  final words = match.replaceAll('’', "'").replaceFirst(RegExp(r'^(?:The|A|An|And|But|Then|When|Poor|Old|Young)\s+'), '').split(RegExp(r'\s+'));
  final kept = <String>[];
  for (final word in words) {
    if (!word.contains("'")) {
      kept.add(word);
      continue;
    }
    // A possessive ends the name; anything else with an apostrophe isn't one.
    if (word.endsWith("'s")) {
      kept.add(word.substring(0, word.length - 2));
    } else if (kept.isEmpty) {
      return null;
    }
    break;
  }
  final name = kept.join(' ').trim();
  return name.length < 2 ? null : name;
}

const _titles = r'(?:Mr|Mrs|Ms|Miss|Dr|Sir|Lady|Lord|Professor|Uncle|Aunt|Madame|Monsieur|Captain|Colonel|King|Queen|Prince|Princess)\.?';

/// A name: capitalised words in a row, maybe after a title ("Mr. Casaubon", "Sir James Chettam").
final _name = RegExp("(?:$_titles\\s+)?[A-Z][\\p{Ll}'’]+(?:\\s+[A-Z][\\p{Ll}'’]+){0,2}", unicode: true);

/// Capitalised words that aren't names.
const _notNames = {
  'I', 'The', 'A', 'An', 'And', 'But', 'Or', 'If', 'Then', 'When', 'Where', 'What', 'Who', 'Why', 'How', 'Oh',
  'Yes', 'No', 'Well', 'Now', 'There', 'This', 'That', 'These', 'Those', 'It', 'He', 'She', 'They', 'We',
  'You', 'His', 'Her', 'Their', 'Our', 'Your', 'My', 'Chapter', 'Monday', 'Tuesday', 'Wednesday',
  'Thursday', 'Friday', 'Saturday', 'Sunday', 'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December', 'God', 'Lord', 'Sir', 'Madam', 'Mr',
  'Mrs', 'Miss', 'English', 'French', 'Christmas', 'Dear', 'Good', 'Perhaps', 'Indeed', 'Still', 'Just',
};

/// The people and places of [index], most named first: names said mid-sentence (so not just a
/// capitalised first word) at least [atLeast] times, that aren't mostly ordinary words.
List<Person> peopleIn(BookIndex index, {int limit = 30, int atLeast = 3}) {
  final counts = <String, int>{};
  final midSentence = <String>{};
  final firstChunk = <String, Chunk>{};
  final firstSentence = <String, String>{};
  final chapters = <String, Map<int, int>>{};
  final lowerCounts = <String, int>{};
  var lastChapter = 1;

  for (final chunk in index.chunks) {
    lastChapter = chunk.chapter;
    for (final m in RegExp(r'\b[a-z]+\b').allMatches(chunk.text)) {
      lowerCounts[m[0]!] = (lowerCounts[m[0]!] ?? 0) + 1;
    }
    for (final sentence in sentencesOf(chunk.text)) {
      for (final m in _name.allMatches(sentence)) {
        // "The Mouse" is the Mouse.
        final name = _asName(m[0]!);
        if (name == null) continue;
        if (_notNames.contains(name)) continue;
        counts[name] = (counts[name] ?? 0) + 1;
        if (m.start > 0 && !RegExp(r'["“‘(]\s*$').hasMatch(sentence.substring(0, m.start))) midSentence.add(name);
        firstChunk.putIfAbsent(name, () => chunk);
        firstSentence.putIfAbsent(name, () => sentence);
        final byChapter = chapters[name] ??= {};
        byChapter[chunk.chapter] = (byChapter[chunk.chapter] ?? 0) + 1;
      }
    }
  }

  final names = counts.keys.where((name) {
    if (!midSentence.contains(name) || counts[name]! < atLeast) return false;
    // An ordinary word that starts sentences ("Alas"), said in lower case as often.
    final lower = lowerCounts[name.toLowerCase()] ?? 0;
    return !name.contains(' ') ? lower * 3 < counts[name]! : true;
  }).toList();

  // "James" mostly said as part of "Sir James" is "Sir James".
  names.removeWhere(
    (short) => !short.contains(' ') && names.any((long) => long != short && long.split(RegExp(r'\s+')).contains(short) && counts[long]! * 2 >= counts[short]!),
  );

  names.sort((a, b) => counts[b]!.compareTo(counts[a]!));
  return [
    for (final name in names.take(limit))
      Person(
        name: name,
        mentions: counts[name]!,
        byChapter: [for (var c = 1; c <= lastChapter; c++) chapters[name]![c] ?? 0],
        firstSeen: firstChunk[name]!,
        firstSentence: firstSentence[name]!,
      ),
  ];
}
