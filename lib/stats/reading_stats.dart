import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;

import '../data/database.dart';

/// Times one sitting with a book. Time counts while pages are turning; a long pause (the
/// phone put down) counts as [idleCap] at most, so a session never claims time not spent
/// reading.
class SessionRecorder {
  SessionRecorder({required this.bookId, required DateTime now, double? progress})
    : startedAt = now,
      _last = now,
      startProgress = progress,
      endProgress = progress;

  static const idleCap = Duration(minutes: 4);

  /// Shorter sittings (opening a book to check something) aren't sessions.
  static const minimum = Duration(seconds: 45);

  final String bookId;
  final DateTime startedAt;
  final double? startProgress;
  double? endProgress;
  DateTime _last;
  Duration _active = Duration.zero;
  int pages = 0;

  Duration get active => _active;

  void _tick(DateTime now) {
    final gap = now.difference(_last);
    if (!gap.isNegative) _active += gap > idleCap ? idleCap : gap;
    _last = now;
  }

  /// The reader moved: [advanced] positions forward (a page is about one).
  void activity(DateTime now, {int advanced = 0, double? progress}) {
    _tick(now);
    if (advanced > 0 && advanced <= 3) pages += advanced;
    if (progress != null) endProgress = progress;
  }

  /// Ends the sitting; null if it was too short to count.
  ReadingSessionsCompanion? finish(DateTime now, {required String id, String? deviceName}) {
    _tick(now);
    if (_active < minimum) return null;
    return ReadingSessionsCompanion.insert(
      id: id,
      bookId: bookId,
      startedAt: startedAt,
      endedAt: now,
      seconds: _active.inSeconds,
      updatedAt: now,
    ).copyWith(
      pages: Value(pages),
      startProgress: Value(startProgress),
      endProgress: Value(endProgress),
      deviceName: Value(deviceName),
    );
  }
}

/// A span of days to look at.
class StatsPeriod {
  const StatsPeriod(this.label, this.from, this.to);

  /// Inclusive start (midnight) and exclusive end.
  final DateTime from;
  final DateTime to;
  final String label;

  static DateTime day(DateTime t) => DateTime(t.year, t.month, t.day);

  static StatsPeriod week(DateTime now) {
    final start = day(now).subtract(Duration(days: now.weekday - 1));
    return StatsPeriod('This week', start, start.add(const Duration(days: 7)));
  }

  static StatsPeriod month(DateTime now) => StatsPeriod(
    _monthName(now.month) + (now.year == DateTime.now().year ? '' : ' ${now.year}'),
    DateTime(now.year, now.month),
    DateTime(now.year, now.month + 1),
  );

  static StatsPeriod year(DateTime now) => StatsPeriod('${now.year}', DateTime(now.year), DateTime(now.year + 1));

  static StatsPeriod allTime(DateTime first, DateTime now) =>
      StatsPeriod('All time', day(first), day(now).add(const Duration(days: 1)));

  static StatsPeriod range(DateTime from, DateTime to) => StatsPeriod(
    '${from.day} ${_monthName(from.month).substring(0, 3)} – ${to.day} ${_monthName(to.month).substring(0, 3)}'
        '${to.year == DateTime.now().year ? '' : ' ${to.year}'}',
    day(from),
    day(to).add(const Duration(days: 1)),
  );

  int get days => to.difference(from).inHours ~/ 24;

  bool contains(DateTime t) => !t.isBefore(from) && t.isBefore(to);

  static String _monthName(int m) => const [
    'January', 'February', 'March', 'April', 'May', 'June', //
    'July', 'August', 'September', 'October', 'November', 'December',
  ][m - 1];
}

/// Reading in a period, worked out from sessions (and books, for what was finished).
class ReadingStats {
  ReadingStats._({
    required this.period,
    required this.seconds,
    required this.pages,
    required this.sessions,
    required this.perDay,
    required this.perBook,
    required this.finished,
    required this.currentStreak,
    required this.bestStreak,
    required this.longestSession,
  });

  factory ReadingStats.of(
    List<ReadingSession> all,
    List<Book> books,
    StatsPeriod period, {
    required DateTime now,
  }) {
    final inPeriod = [for (final s in all) if (!s.deleted && period.contains(s.startedAt)) s];
    final perDay = <DateTime, int>{};
    final perBook = <String, int>{};
    var seconds = 0;
    var pages = 0;
    var longest = 0;
    for (final s in inPeriod) {
      seconds += s.seconds;
      pages += s.pages;
      longest = math.max(longest, s.seconds);
      final d = StatsPeriod.day(s.startedAt);
      perDay[d] = (perDay[d] ?? 0) + s.seconds;
      perBook[s.bookId] = (perBook[s.bookId] ?? 0) + s.seconds;
    }
    final (current, best) = streaks(all, now);
    return ReadingStats._(
      period: period,
      seconds: seconds,
      pages: pages,
      sessions: inPeriod.length,
      perDay: perDay,
      perBook: perBook,
      finished: [
        for (final b in books)
          if (!b.deleted && b.status == ReadingStatus.finished && b.finishedAt != null && period.contains(b.finishedAt!)) b,
      ]..sort((a, b) => a.finishedAt!.compareTo(b.finishedAt!)),
      currentStreak: current,
      bestStreak: best,
      longestSession: longest,
    );
  }

  final StatsPeriod period;
  final int seconds;
  final int pages;
  final int sessions;

  /// Seconds read on each day (midnight keys).
  final Map<DateTime, int> perDay;

  /// Seconds per book id.
  final Map<String, int> perBook;
  final List<Book> finished;
  final int currentStreak;
  final int bestStreak;
  final int longestSession;

  int get daysRead => perDay.values.where((s) => s >= streakMinimum).length;

  /// Book ids, most read first.
  List<String> get topBooks => perBook.keys.toList()..sort((a, b) => perBook[b]!.compareTo(perBook[a]!));

  /// A day counts toward a streak with a minute of reading.
  static const streakMinimum = 60;

  /// Days in a row with reading, up to today (or yesterday, if today's reading hasn't
  /// happened yet), and the longest such run ever.
  static (int current, int best) streaks(List<ReadingSession> sessions, DateTime now) {
    final perDay = <DateTime, int>{};
    for (final s in sessions) {
      if (s.deleted) continue;
      final d = StatsPeriod.day(s.startedAt);
      perDay[d] = (perDay[d] ?? 0) + s.seconds;
    }
    final days = (perDay.entries.where((e) => e.value >= streakMinimum).map((e) => e.key).toList()..sort());
    var best = 0;
    var run = 0;
    DateTime? previous;
    for (final d in days) {
      run = previous != null && _daysBetween(previous, d) == 1 ? run + 1 : 1;
      best = math.max(best, run);
      previous = d;
    }
    final today = StatsPeriod.day(now);
    final last = days.isEmpty ? null : days.last;
    final current = last != null && _daysBetween(last, today) <= 1 ? run : 0;
    return (current, best);
  }

  // Calendar days apart, safe across daylight-saving changes.
  static int _daysBetween(DateTime a, DateTime b) =>
      DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
}

/// "3 h 20 min", "45 min", "under a minute".
String formatDuration(int seconds) {
  final minutes = (seconds / 60).round();
  if (minutes < 1) return seconds > 0 ? 'under a minute' : '0 min';
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours h' : '$hours h $rest min';
}
