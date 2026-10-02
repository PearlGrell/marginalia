import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

import 'dictionary_pack.dart';

/// One meaning of a word.
class Sense {
  const Sense({required this.definition, required this.examples, required this.synonyms});

  final String definition;
  final List<String> examples;

  /// Other words with this meaning.
  final List<String> synonyms;
}

/// A word as a part of speech, with its meanings, most common first.
class DictionaryEntry {
  const DictionaryEntry({required this.lemma, required this.partOfSpeech, required this.senses});

  final String lemma;
  final String partOfSpeech;
  final List<Sense> senses;
}

/// The offline English dictionary: Open English WordNet (CC BY 4.0), downloaded and built
/// on the phone by [DictionaryPack]. Lookups never use the network.
class Dictionary {
  Dictionary._(this._db);

  final Database _db;

  static Future<Dictionary?> open() async {
    final file = await DictionaryPack.file();
    if (!await file.exists()) return null;
    return Dictionary._(sqlite3.open(file.path, mode: OpenMode.readOnly));
  }

  static const _partsOfSpeech = {
    'n': 'noun',
    'v': 'verb',
    'a': 'adjective',
    's': 'adjective',
    'r': 'adverb',
  };

  /// Entries for [word] as written, or for its base form ("walked" finds "walk").
  List<DictionaryEntry> lookUp(String word) {
    final cleaned = word
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r"^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$", unicode: true), '')
        .replaceAll('’', "'");
    if (cleaned.isEmpty) return const [];
    for (final candidate in [cleaned, ...baseForms(cleaned)]) {
      final entries = _entries(candidate);
      if (entries.isNotEmpty) return entries;
    }
    return const [];
  }

  List<DictionaryEntry> _entries(String form) {
    final rows = _db.select(
      '''
      SELECT e.id, e.lemma, e.pos, s.id AS synset, s.definition, s.examples
      FROM forms f
      JOIN entries e ON e.id = f.entry
      JOIN senses x ON x.entry = e.id
      JOIN synsets s ON s.id = x.synset
      WHERE f.form = ?
      ORDER BY e.id, x.rank
      ''',
      [form],
    );
    final byEntry = <int, (String, String, List<Sense>)>{};
    for (final row in rows) {
      final id = row['id'] as int;
      final senses = (byEntry[id] ??= (
        row['lemma'] as String,
        _partsOfSpeech[row['pos']] ?? row['pos'] as String,
        <Sense>[],
      )).$3;
      if (senses.length >= 6) continue;
      final lemma = row['lemma'] as String;
      senses.add(
        Sense(
          definition: row['definition'] as String,
          examples: (row['examples'] as String?)?.split('\n') ?? const [],
          synonyms: _synonyms(row['synset'] as int, except: lemma),
        ),
      );
    }
    // Merge the 'a' and 's' adjective entries of one lemma.
    final merged = <String, DictionaryEntry>{};
    for (final (lemma, pos, senses) in byEntry.values) {
      final key = '$lemma|$pos';
      final existing = merged[key];
      merged[key] = DictionaryEntry(
        lemma: lemma,
        partOfSpeech: pos,
        senses: [...?existing?.senses, ...senses].take(6).toList(),
      );
    }
    return merged.values.toList();
  }

  List<String> _synonyms(int synset, {required String except}) => [
    for (final row in _db.select(
      '''
      SELECT DISTINCT e.lemma FROM senses x JOIN entries e ON e.id = x.entry
      WHERE x.synset = ? AND e.lemma != ? LIMIT 5
      ''',
      [synset, except],
    ))
      row['lemma'] as String,
  ];

  void close() => _db.close();
}

/// Possible base forms of an inflected word, by WordNet's detachment rules
/// ("cities" → city, "running" → run, "happier" → happy). Irregular forms are in the data.
List<String> baseForms(String word) {
  const rules = [
    ('ies', 'y'), ('es', ''), ('es', 'e'), ('s', ''), ('ses', 's'), ('xes', 'x'), //
    ('zes', 'z'), ('ches', 'ch'), ('shes', 'sh'), ('men', 'man'),
    ('ied', 'y'), ('ed', ''), ('ed', 'e'), ('ing', ''), ('ing', 'e'),
    ('ier', 'y'), ('er', ''), ('er', 'e'), ('iest', 'y'), ('est', ''), ('est', 'e'),
    ("'s", ''), ('ly', ''), ('ily', 'y'),
  ];
  final results = <String>[];
  for (final (suffix, ending) in rules) {
    if (word.length > suffix.length + 1 && word.endsWith(suffix)) {
      final stem = word.substring(0, word.length - suffix.length);
      results.add('$stem$ending');
      // "running" → "runn" → "run": undo a doubled consonant.
      if (ending.isEmpty &&
          stem.length > 2 &&
          stem[stem.length - 1] == stem[stem.length - 2] &&
          !'aeiou'.contains(stem[stem.length - 1])) {
        results.add(stem.substring(0, stem.length - 1));
      }
    }
  }
  return results;
}

/// The dictionary, or null until its pack is downloaded.
final dictionaryProvider = FutureProvider<Dictionary?>((ref) async {
  final installed = ref.watch(dictionaryPackProvider.select((s) => s.status == PackStatus.installed));
  if (!installed) return null;
  final dictionary = await Dictionary.open();
  if (dictionary != null) ref.onDispose(dictionary.close);
  return dictionary;
});
