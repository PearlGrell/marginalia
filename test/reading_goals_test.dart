import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/data/database.dart';
import 'package:marginalia/stats/reading_goals.dart';
import 'package:marginalia/stats/reading_stats.dart';
import 'package:marginalia/stats/streak_reminder.dart';

ReadingSession sitting(String id, DateTime start, int seconds) => ReadingSession(
  id: id,
  bookId: 'b',
  startedAt: start,
  endedAt: start.add(Duration(seconds: seconds)),
  seconds: seconds,
  pages: 0,
  updatedAt: start,
  deleted: false,
  dirty: false,
);

Book finished(String id, DateTime at) => Book(
  id: id,
  title: id,
  authors: const ['A'],
  sortTitle: id,
  sortAuthor: 'a',
  addedAt: at,
  updatedAt: at,
  progress: 1,
  status: ReadingStatus.finished,
  finishedAt: at,
  favorite: false,
  deleted: false,
  dirty: false,
  tags: const [],
  source: BookSource.import,
  fileSize: 0,
  ratingHalves: 0,
);

void main() {
  group('goals', () {
    final now = DateTime(2026, 7, 2, 21); // about halfway through the year

    test('today counts this day\'s reading against the daily minutes', () {
      final progress = GoalProgress.of(
        [sitting('1', DateTime(2026, 7, 2, 8), 600), sitting('2', DateTime(2026, 7, 1, 8), 3000)],
        const [],
        const ReadingGoals(dailyMinutes: 20),
        now: now,
      );
      expect(progress.todaySeconds, 600);
      expect(progress.today, closeTo(0.5, 1e-9));
      expect(progress.year, isNull);
    });

    test('the yearly goal says whether the pace keeps up', () {
      final books = [for (var i = 0; i < 9; i++) finished('b$i', DateTime(2026, 3, i + 1))];
      final progress = GoalProgress.of(const [], books, const ReadingGoals(yearlyBooks: 12), now: now);
      expect(progress.booksThisYear, 9);
      expect(progress.pace, '3 ahead');
      expect(GoalProgress.of(const [], books.take(6).toList(), const ReadingGoals(yearlyBooks: 12), now: now).pace, 'on track');
    });

    test('goals survive a round trip through the account', () {
      const goals = ReadingGoals(dailyMinutes: 30, yearlyBooks: 24);
      final back = ReadingGoals.fromJson(goals.toJson());
      expect((back.dailyMinutes, back.yearlyBooks), (30, 24));
      expect(ReadingGoals.fromJson(null).any, isFalse);
    });
  });

  group('evening reminder', () {
    final now = DateTime(2026, 10, 14, 20);

    test('nudges when a streak would end tonight', () {
      final sessions = [sitting('1', DateTime(2026, 10, 12, 8), 600), sitting('2', DateTime(2026, 10, 13, 8), 600)];
      expect(StreakReminder.message(sessions, const ReadingGoals(), now: now), contains('2-day streak'));
    });

    test('says nothing once today is read, unless the daily goal is still short', () {
      final sessions = [sitting('1', DateTime(2026, 10, 13, 8), 600), sitting('2', DateTime(2026, 10, 14, 8), 300)];
      expect(StreakReminder.message(sessions, const ReadingGoals(), now: now), isNull);
      expect(StreakReminder.message(sessions, const ReadingGoals(dailyMinutes: 20), now: now), contains('15 more minutes'));
    });

    test('with no streak and no goal there is nothing to keep', () {
      expect(StreakReminder.message(const [], const ReadingGoals(), now: now), isNull);
    });

    test('the next check is today at the time, or tomorrow once it has passed', () {
      const reminder = StreakReminder(enabled: true, minuteOfDay: 20 * 60 + 30);
      expect(reminder.nextAfter(DateTime(2026, 10, 14, 9)), DateTime(2026, 10, 14, 20, 30));
      expect(reminder.nextAfter(DateTime(2026, 10, 14, 21)), DateTime(2026, 10, 15, 20, 30));
    });
  });

  test('a sitting recap says time, pages and words saved', () {
    expect(sittingRecap(seconds: 18 * 60, fromPage: 42, toPage: 61, words: 3), '18 min · pg 42–61 · 3 words saved');
    expect(sittingRecap(seconds: 300, fromPage: 10, toPage: 10), '5 min');
  });

  test('words saved from a book since a time are counted', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    Future<void> save(String id, String book, DateTime at) => db.saveWord(
      WordsCompanion.insert(id: id, word: id, createdAt: at, dueAt: at, updatedAt: at, bookId: Value(book)),
    );
    await save('a', 'b1', DateTime(2026, 10, 14, 9));
    await save('b', 'b1', DateTime(2026, 10, 14, 11));
    await save('c', 'b2', DateTime(2026, 10, 14, 11));
    expect(await db.countWords('b1', since: DateTime(2026, 10, 14, 10)), 1);
  });
}
