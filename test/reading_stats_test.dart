import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/data/database.dart';
import 'package:marginalia/stats/reading_stats.dart';

ReadingSession session(String id, DateTime start, int seconds, {String book = 'a', int pages = 0}) => ReadingSession(
  id: id,
  bookId: book,
  startedAt: start,
  endedAt: start.add(Duration(seconds: seconds)),
  seconds: seconds,
  pages: pages,
  updatedAt: start,
  deleted: false,
  dirty: false,
);

void main() {
  group('SessionRecorder', () {
    final t0 = DateTime(2026, 10, 3, 20);

    test('counts reading time, capping long pauses', () {
      final r = SessionRecorder(bookId: 'a', now: t0, progress: 0.1);
      r.activity(t0.add(const Duration(minutes: 1)), advanced: 1, progress: 0.11);
      r.activity(t0.add(const Duration(minutes: 2)), advanced: 1, progress: 0.12);
      // Put down for an hour, then one more page.
      r.activity(t0.add(const Duration(minutes: 62)), advanced: 1, progress: 0.13);
      final s = r.finish(t0.add(const Duration(minutes: 63)), id: 's');
      expect(s, isNotNull);
      expect(s!.seconds.value, (2 + 4 + 1) * 60);
      expect(s.pages.value, 3);
      expect(s.startProgress.value, 0.1);
      expect(s.endProgress.value, 0.13);
    });

    test('a jump through the book is not pages read', () {
      final r = SessionRecorder(bookId: 'a', now: t0);
      r.activity(t0.add(const Duration(minutes: 1)), advanced: 120);
      expect(r.pages, 0);
    });

    test('opening a book for a moment is not a session', () {
      final r = SessionRecorder(bookId: 'a', now: t0);
      expect(r.finish(t0.add(const Duration(seconds: 20)), id: 's'), isNull);
    });
  });

  group('streaks', () {
    test('count days in a row with a minute of reading, through today or yesterday', () {
      final now = DateTime(2026, 10, 10, 9);
      final sessions = [
        // An old run of three days.
        session('1', DateTime(2026, 9, 1, 21), 600),
        session('2', DateTime(2026, 9, 2, 21), 600),
        session('3', DateTime(2026, 9, 3, 21), 600),
        // Thirty seconds doesn't count.
        session('4', DateTime(2026, 9, 4, 21), 30),
        // The current run: yesterday and the two days before.
        session('5', DateTime(2026, 10, 7, 22), 900),
        session('6', DateTime(2026, 10, 8, 7), 300),
        session('7', DateTime(2026, 10, 9, 23, 30), 1200),
      ];
      expect(ReadingStats.streaks(sessions, now), (3, 3));
      // A day missed breaks it.
      expect(ReadingStats.streaks(sessions, DateTime(2026, 10, 11, 9)), (0, 3));
    });

    test('nothing read is no streak', () {
      expect(ReadingStats.streaks(const [], DateTime(2026)), (0, 0));
    });
  });

  test('stats for a period', () {
    final now = DateTime(2026, 10, 20);
    final sessions = [
      session('1', DateTime(2026, 9, 30, 22), 3600, book: 'old'),
      session('2', DateTime(2026, 10, 1, 8), 1200, book: 'a', pages: 10),
      session('3', DateTime(2026, 10, 1, 21), 600, book: 'b', pages: 4),
      session('4', DateTime(2026, 10, 15, 21), 2400, book: 'b', pages: 20),
    ];
    final stats = ReadingStats.of(sessions, const [], StatsPeriod.month(DateTime(2026, 10, 5)), now: now);
    expect(stats.seconds, 4200);
    expect(stats.pages, 34);
    expect(stats.sessions, 3);
    expect(stats.daysRead, 2);
    expect(stats.topBooks, ['b', 'a']);
    expect(stats.perDay[DateTime(2026, 10, 1)], 1800);
    expect(stats.longestSession, 2400);
  });

  test('periods', () {
    final week = StatsPeriod.week(DateTime(2026, 10, 3)); // a Saturday
    expect(week.from, DateTime(2026, 9, 28));
    expect(week.days, 7);
    expect(StatsPeriod.month(DateTime(2026, 2, 10)).days, 28);
    expect(StatsPeriod.range(DateTime(2026, 1, 5), DateTime(2026, 1, 7)).days, 3);
  });

  test('durations read naturally', () {
    expect(formatDuration(0), '0 min');
    expect(formatDuration(20), 'under a minute');
    expect(formatDuration(45 * 60), '45 min');
    expect(formatDuration(3 * 3600 + 20 * 60), '3 h 20 min');
    expect(formatDuration(7200), '2 h');
  });
}
