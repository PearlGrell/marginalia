import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/library.dart';
import 'review.dart';

final wordsProvider = StreamProvider<List<VocabularyWord>>((ref) => ref.watch(databaseProvider).watchWords());

final dueCountProvider = StreamProvider<int>((ref) => ref.watch(databaseProvider).watchDueCount());

/// The word list: words saved from Define, reviewed with spaced repetition. Synced.
class WordStore {
  WordStore(this._db);

  final AppDatabase _db;

  static String idFor(String word, String language) =>
      '${language.split(RegExp('[-_]')).first.toLowerCase()}:${word.trim().toLowerCase()}';

  Future<bool> isSaved(String word, String language) async {
    final w = await _db.getWord(idFor(word, language));
    return w != null && !w.deleted;
  }

  /// Saves [word]; saving it again updates its meaning and keeps its review progress.
  Future<void> save({
    required String word,
    String language = 'en',
    String? partOfSpeech,
    String? definition,
    String? context,
    String? bookId,
  }) async {
    final id = idFor(word, language);
    final existing = await _db.getWord(id);
    final now = DateTime.now();
    if (existing != null && !existing.deleted) {
      await _db.updateWord(
        id,
        WordsCompanion(
          partOfSpeech: Value(partOfSpeech ?? existing.partOfSpeech),
          definition: Value(definition ?? existing.definition),
          context: Value(context ?? existing.context),
        ),
      );
      return;
    }
    await _db.saveWord(
      WordsCompanion.insert(
        id: id,
        word: word.trim(),
        language: Value(language.split(RegExp('[-_]')).first.toLowerCase()),
        partOfSpeech: Value(partOfSpeech),
        definition: Value(definition),
        context: Value(context),
        bookId: Value(bookId),
        createdAt: now,
        // New words are ready to review straight away.
        dueAt: now,
        updatedAt: now,
        deleted: const Value(false),
        intervalDays: const Value(0),
        ease: const Value(2.5),
        reps: const Value(0),
        lapses: const Value(0),
      ),
    );
  }

  Future<void> remove(String id) => _db.deleteWord(id);

  Future<void> grade(VocabularyWord word, ReviewGrade grade) {
    final next = scheduleReview(stateOf(word), grade, DateTime.now());
    return _db.updateWord(
      word.id,
      WordsCompanion(
        intervalDays: Value(next.intervalDays),
        ease: Value(next.ease),
        reps: Value(next.reps),
        lapses: Value(next.lapses),
        dueAt: Value(next.dueAt),
      ),
    );
  }

  static ReviewState stateOf(VocabularyWord w) =>
      ReviewState(intervalDays: w.intervalDays, ease: w.ease, reps: w.reps, lapses: w.lapses, dueAt: w.dueAt);
}

final wordStoreProvider = Provider<WordStore>((ref) => WordStore(ref.watch(databaseProvider)));
