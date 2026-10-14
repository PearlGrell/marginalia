import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;

import '../data/database.dart';

/// Times one sitting with a book. Time counts while pages are turning; a long pause (the
/// phone put down) counts as [idleCap] at most, so a session never claims time not spent
/// reading.
class SessionRecorder {
  SessionRecorder({required this.bookId, required DateTime now, double? progress, int? position})
    : startedAt = now,
      _last = now,
      startProgress = progress,
      endProgress = progress,
      startPosition = position,
      endPosition = position;

  static const idleCap = Duration(minutes: 4);

  /// Shorter sittings (opening a book to check something) aren't sessions.
  static const minimum = Duration(seconds: 45);

  final String bookId;
  final DateTime startedAt;
  final double? startProgress;
  double? endProgress;

  /// Readium positions (about a page each) where the sitting began and ended.
  final int? startPosition;
  int? endPosition;
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
  void activity(DateTime now, {int advanced = 0, double? progress, int? position}) {
    _tick(now);
    if (advanced > 0 && advanced <= 3) pages += advanced;
    if (progress != null) endProgress = progress;
    if (position != null) endPosition = position;
  }

  /// See [readingSessionId].
  String get id => readingSessionId(
    bookId: bookId,
    startedAt: startedAt,
    startPosition: startPosition,
    endPosition: endPosition,
  );

  /// Ends the sitting; null if it was too short to count.
  ReadingSessionsCompanion? finish(DateTime now, {String? deviceName}) {
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
      startPosition: Value(startPosition),
      endPosition: Value(endPosition),
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
    required this.pagesPerBook,
    required this.rangesPerBook,
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
    final sessions = dedupeSessions(all);
    final inPeriod = [for (final s in sessions) if (period.contains(s.startedAt)) s];
    final sittings = mergeSittings(inPeriod);
    final perDay = <DateTime, int>{};
    final perBook = <String, int>{};
    var seconds = 0;
    var longest = 0;
    for (final s in sittings) {
      seconds += s.seconds;
      longest = math.max(longest, s.seconds);
      final d = StatsPeriod.day(s.startedAt);
      perDay[d] = (perDay[d] ?? 0) + s.seconds;
      perBook[s.bookId] = (perBook[s.bookId] ?? 0) + s.seconds;
    }
    final (current, best) = streaks(sessions, now);
    final pages = pagesReadPerBook(inPeriod);
    final ranges = <String, List<(int, int)>>{};
    for (final s in inPeriod) {
      if (pageRange(s) case final range?) (ranges[s.bookId] ??= []).add(range);
    }
    return ReadingStats._(
      period: period,
      seconds: seconds,
      pages: pages.values.fold(0, (a, b) => a + b),
      pagesPerBook: pages,
      rangesPerBook: {for (final MapEntry(:key, :value) in ranges.entries) key: mergeRanges(value)},
      sessions: sittings.length,
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

  /// Pages read per book id, each page once (see [pagesReadPerBook]).
  final Map<String, int> pagesPerBook;

  /// The pages read in each book, merged, in order (Readium positions).
  final Map<String, List<(int, int)>> rangesPerBook;
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
    for (final s in mergeSittings(dedupeSessions(sessions))) {
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

/// Every sitting, each once. Stats add up all of them; only exact copies of one sitting
/// (the same book, start and length, saved under an older random id as well as its own)
/// are dropped. Deleted sessions are left out.
List<ReadingSession> dedupeSessions(Iterable<ReadingSession> sessions) {
  final seen = <String>{};
  return [
    for (final s in sessions)
      if (!s.deleted && seen.add('${s.bookId}|${s.startedAt.millisecondsSinceEpoch ~/ 1000}|${s.seconds}')) s,
  ];
}

/// Sittings with one book that overlap in time (read on two devices, or saved twice) merged
/// into one: it spans them all, and its time is the time they cover together, never more
/// than they add up to. Sittings that don't overlap are kept as they are.
List<ReadingSession> mergeSittings(Iterable<ReadingSession> sessions) {
  final byBook = <String, List<ReadingSession>>{};
  for (final s in sessions) {
    (byBook[s.bookId] ??= []).add(s);
  }
  final merged = <ReadingSession>[];
  for (final list in byBook.values) {
    list.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    var run = [list.first];
    var end = list.first.endedAt;
    void close() {
      if (run.length == 1) return merged.add(run.single);
      final start = run.first.startedAt;
      final total = run.fold(0, (sum, s) => sum + s.seconds);
      merged.add(
        run.first.copyWith(
          endedAt: end,
          seconds: math.min(total, end.difference(start).inSeconds),
          pages: run.fold<int>(0, (sum, s) => sum + s.pages),
        ),
      );
    }

    for (final s in list.skip(1)) {
      if (s.startedAt.isBefore(end)) {
        run.add(s);
        if (s.endedAt.isAfter(end)) end = s.endedAt;
      } else {
        close();
        run = [s];
        end = s.endedAt;
      }
    }
    close();
  }
  return merged..sort((a, b) => a.startedAt.compareTo(b.startedAt));
}

/// The pages a sitting moved forward through; null for sittings recorded before pages were
/// kept, or that didn't move forward.
(int, int)? pageRange(ReadingSession s) {
  final (from, to) = (s.startPosition, s.endPosition);
  return from != null && to != null && to > from ? (from, to) : null;
}

/// Page ranges merged into the fewest that cover them, in order.
List<(int, int)> mergeRanges(Iterable<(int, int)> ranges) {
  final sorted = ranges.toList()..sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[];
  for (final (from, to) in sorted) {
    if (merged.isNotEmpty && from <= merged.last.$2) {
      if (to > merged.last.$2) merged.last = (merged.last.$1, to);
    } else {
      merged.add((from, to));
    }
  }
  return merged;
}

/// Pages read in [sessions], per book: the page ranges of its sittings merged, so pages
/// read twice count once. A book's ranges never count for more than the page turns they
/// took, so a jump through the book isn't reading. Sittings without a range count their
/// page turns.
Map<String, int> pagesReadPerBook(Iterable<ReadingSession> sessions) {
  final ranges = <String, List<(int, int)>>{};
  final turns = <String, int>{};
  final pages = <String, int>{};
  for (final s in sessions) {
    if (pageRange(s) case final range?) {
      (ranges[s.bookId] ??= []).add(range);
      turns[s.bookId] = (turns[s.bookId] ?? 0) + s.pages;
    } else {
      pages[s.bookId] = (pages[s.bookId] ?? 0) + s.pages;
    }
  }
  for (final MapEntry(key: book, value: list) in ranges.entries) {
    final covered = mergeRanges(list).fold(0, (sum, r) => sum + r.$2 - r.$1);
    pages[book] = (pages[book] ?? 0) + math.min(covered, turns[book]!);
  }
  return pages;
}

int pagesRead(Iterable<ReadingSession> sessions) => pagesReadPerBook(sessions).values.fold(0, (a, b) => a + b);

/// "pg 10–30, 40–45", the first few ranges and how many more.
String pageRanges(List<(int, int)> ranges, {int shown = 3}) {
  final listed = [for (final (from, to) in ranges.take(shown)) '$from–$to'].join(', ');
  return ranges.length > shown ? 'pg $listed +${ranges.length - shown} more' : 'pg $listed';
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
