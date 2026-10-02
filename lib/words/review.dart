/// How well a word was remembered in review.
enum ReviewGrade {
  again('Again'),
  hard('Hard'),
  good('Good'),
  easy('Easy');

  const ReviewGrade(this.label);

  final String label;
}

/// Where a word is in its reviews.
class ReviewState {
  const ReviewState({
    this.intervalDays = 0,
    this.ease = 2.5,
    this.reps = 0,
    this.lapses = 0,
    required this.dueAt,
  });

  /// Days until the next review, as last scheduled.
  final double intervalDays;

  /// How quickly the interval grows (SM-2's ease factor), 1.3 or more.
  final double ease;

  /// Reviews in a row remembered.
  final int reps;

  /// Times forgotten after being learned.
  final int lapses;
  final DateTime dueAt;
}

/// Spaced repetition, after SM-2: remembered words come back after longer and longer gaps
/// (1 day, 3 days, then growing by the ease), forgotten ones come back in ten minutes.
ReviewState scheduleReview(ReviewState s, ReviewGrade grade, DateTime now) {
  switch (grade) {
    case ReviewGrade.again:
      return ReviewState(
        intervalDays: 0,
        ease: (s.ease - 0.2).clamp(1.3, 3.0),
        reps: 0,
        lapses: s.reps > 0 ? s.lapses + 1 : s.lapses,
        dueAt: now.add(const Duration(minutes: 10)),
      );
    case ReviewGrade.hard:
      final interval = s.reps == 0 ? 1.0 : (s.intervalDays * 1.2).clamp(1.0, 3650.0);
      return _after(interval, ease: (s.ease - 0.15).clamp(1.3, 3.0), s: s, now: now);
    case ReviewGrade.good:
      final interval = switch (s.reps) {
        0 => 1.0,
        1 => 3.0,
        _ => (s.intervalDays * s.ease).clamp(1.0, 3650.0),
      };
      return _after(interval, ease: s.ease, s: s, now: now);
    case ReviewGrade.easy:
      final interval = s.reps == 0 ? 4.0 : (s.intervalDays * s.ease * 1.3).clamp(1.0, 3650.0);
      return _after(interval, ease: (s.ease + 0.15).clamp(1.3, 3.0), s: s, now: now);
  }
}

ReviewState _after(double interval, {required double ease, required ReviewState s, required DateTime now}) =>
    ReviewState(
      intervalDays: interval,
      ease: ease,
      reps: s.reps + 1,
      lapses: s.lapses,
      dueAt: now.add(Duration(minutes: (interval * 24 * 60).round())),
    );

/// "in 3 days", for showing when a grade would bring the word back.
String reviewGap(ReviewState next, DateTime now) {
  final minutes = next.dueAt.difference(now).inMinutes;
  if (minutes < 60) return '$minutes min';
  final days = (minutes / (24 * 60)).round();
  if (days < 1) return '${(minutes / 60).round()} h';
  if (days < 31) return '$days d';
  if (days < 365) return '${(days / 30).round()} mo';
  return '${(days / 365).toStringAsFixed(1)} y';
}

/// The sentence around a word, from the text before and after a selection.
String contextSentence(String? before, String word, String? after) {
  final head = (before ?? '').replaceAll(RegExp(r'\s+'), ' ');
  final tail = (after ?? '').replaceAll(RegExp(r'\s+'), ' ');
  final start = head.lastIndexOf(RegExp(r'[.!?…]["”’)]?\s'));
  final end = RegExp(r'[.!?…]').firstMatch(tail)?.end;
  final sentence = '${start < 0 ? head : head.substring(start + 1)}$word${end == null ? tail : tail.substring(0, end)}';
  final trimmed = sentence.trim();
  return trimmed.length > 300 ? '${trimmed.substring(0, 300).trimRight()}…' : trimmed;
}
