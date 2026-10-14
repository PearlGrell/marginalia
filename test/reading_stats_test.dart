import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/data/database.dart';
import 'package:marginalia/stats/reading_stats.dart';

ReadingSession session(
  String id,
  DateTime start,
  int seconds, {
  String book = 'a',
  int pages = 0,
  int? from,
  int? to,
}) => ReadingSession(
  id: id,
  bookId: book,
  startedAt: start,
  endedAt: start.add(Duration(seconds: seconds)),
  seconds: seconds,
  pages: pages,
  startPosition: from,
  endPosition: to,
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
      final s = r.finish(t0.add(const Duration(minutes: 63)));
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

    test('a sitting is named by its book, pages and start, so it saves only once', () {
      const book = '3f9a1c07';
      final r = SessionRecorder(bookId: book, now: DateTime.utc(2026, 10, 14, 7, 23, 1), position: 12);
      r.activity(DateTime.utc(2026, 10, 14, 7, 30), advanced: 1, position: 13);
      expect(r.id, '($book)(page-12-13)(20261014T072301Z)');
      // Another book read at the same pages and time is a different sitting.
      expect(SessionRecorder(bookId: 'b81e4d2a', now: r.startedAt, position: 12).id, startsWith('(b81e4d2a)(page-12-'));
      final s = r.finish(DateTime.utc(2026, 10, 14, 7, 31))!;
      expect(s.id.value, r.id);
      expect((s.startPosition.value, s.endPosition.value), (12, 13));
    });

    test('opening a book for a moment is not a session', () {
      final r = SessionRecorder(bookId: 'a', now: t0);
      expect(r.finish(t0.add(const Duration(seconds: 20))), isNull);
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

  test('sittings that overlap in time count that time once', () {
    final now = DateTime(2026, 10, 20);
    final sessions = [
      session('old-random-id', DateTime(2026, 10, 1, 8), 1200, pages: 10),
      // The same sitting under its new id: an exact copy, dropped.
      session('(a)(page-1-11)(20261001T080000Z)', DateTime(2026, 10, 1, 8), 1200, pages: 10),
      // Read on a second device during the first sitting: merged with it, 08:00-08:25.
      session('2', DateTime(2026, 10, 1, 8, 10), 900, pages: 2),
      // The same book read again later that day is a sitting of its own.
      session('3', DateTime(2026, 10, 1, 21), 600, pages: 4),
    ];
    final stats = ReadingStats.of(sessions, const [], StatsPeriod.month(now), now: now);
    expect(stats.sessions, 2);
    expect(stats.seconds, 25 * 60 + 600);
  });

  test('pages read twice count once', () {
    ReadingSession read(String book, int from, int to, int day, int turns) =>
        session('$book$day', DateTime(2026, 10, day, 8), 600, book: book, pages: turns, from: from, to: to);
    expect(
      pagesRead([
        read('a', 10, 20, 11, 10),
        read('a', 15, 30, 12, 15), // pages 15-20 again
        read('a', 40, 45, 13, 5),
        // A jump through the book is not reading: only the turns count.
        read('b', 1, 300, 14, 5),
        // Saved before ids had pages: its turns.
        session('old', DateTime(2026, 10, 15), 600, book: 'c', pages: 7),
      ]),
      20 + 5 + 5 + 7,
    );
  });

  test('each book shows its pages read and the ranges they came from', () {
    final now = DateTime(2026, 10, 20);
    final stats = ReadingStats.of(
      [
        session('1', DateTime(2026, 10, 2, 8), 600, pages: 10, from: 10, to: 20),
        session('2', DateTime(2026, 10, 3, 8), 900, pages: 15, from: 15, to: 30),
        session('3', DateTime(2026, 10, 4, 8), 300, pages: 5, from: 40, to: 45),
      ],
      const [],
      StatsPeriod.month(now),
      now: now,
    );
    expect(stats.pages, 25);
    expect(stats.pagesPerBook['a'], 25);
    expect(stats.rangesPerBook['a'], [(10, 30), (40, 45)]);
    expect(pageRanges(stats.rangesPerBook['a']!), 'pg 10–30, 40–45');
    expect(pageRanges([(1, 2), (3, 4), (5, 6), (7, 8)]), 'pg 1–2, 3–4, 5–6 +1 more');
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
