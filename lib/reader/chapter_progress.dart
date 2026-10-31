import '../companion/book_memory.dart';
import '../readium/readium.dart';

/// Where the reader is in the chapter, for under the page: "Ch 4 of 22 · 6 pages, 12 min
/// left". Chapters are the book's story chapters, as the companion counts them (see
/// [storyChaptersOf]): front and back matter aren't counted. Null on a page too short to say
/// (a cover, a contents page) or that isn't in a chapter.
String? chapterProgress(
  PublicationInfo publication, {
  required String href,
  int? position,
  double? progression,
  required double secondsPerPosition,
}) {
  final chapter = publication.chapterFor(href);
  if (chapter == null || chapter.count <= 1) return null;
  final sections = _sections[publication] ??= storyChaptersOf(publication);
  final file = publication.chapters.indexOf(chapter);
  // The file's first chapter (later ones in it start somewhere on its pages), or, for a file
  // with none of its own, the one before it carries on.
  final inFile = sections.where((s) => s.index == file);
  final section = inFile.isNotEmpty
      ? inFile.where((s) => s.isStory).firstOrNull
      : sections.where((s) => s.index < file).lastOrNull;
  if (section == null || !section.isStory) return null;
  final number = 'Ch ${section.number} of ${sections.where((s) => s.isStory).length}';

  final double remaining;
  if (position != null && position >= chapter.start && position <= chapter.end) {
    remaining = (chapter.end - position).toDouble();
  } else if (progression != null) {
    remaining = chapter.count * (1 - progression.clamp(0.0, 1.0));
  } else {
    return number;
  }
  final pages = remaining.round();
  if (pages < 1) return '$number · last page';
  final time = _duration((remaining * secondsPerPosition / 60).round());
  return '$number · $pages ${pages == 1 ? 'page' : 'pages'}, $time left';
}

/// "12 min", "3 h 5 min", "under a minute".
String _duration(int minutes) => switch (minutes) {
  < 1 => 'under a minute',
  < 60 => '$minutes min',
  _ => minutes % 60 == 0 ? '${minutes ~/ 60} h' : '${minutes ~/ 60} h ${minutes % 60} min',
};

/// The time left in the whole book at the reader's pace, and when they'd finish it at the
/// rate they've been reading lately: "4 h 10 min left in the book · done by Friday at your
/// pace". [secondsReadByDay] is how long was read on each of the last [days] days (any book);
/// with too little reading lately to go on, just the time left. Null at the very end.
String? bookTimeLeft({
  required int positionsLeft,
  required double secondsPerPosition,
  required Iterable<int> secondsReadByDay,
  required DateTime now,
  int days = 14,
}) {
  if (positionsLeft < 1) return null;
  final secondsLeft = positionsLeft * secondsPerPosition;
  final left = '${_duration((secondsLeft / 60).round())} left in the book';
  final perDay = secondsReadByDay.fold(0, (a, b) => a + b) / days;
  // Under five minutes a day lately: no date worth promising.
  if (perDay < 5 * 60) return left;
  final daysNeeded = (secondsLeft / perDay).ceil();
  if (daysNeeded > 365) return left;
  final today = DateTime(now.year, now.month, now.day);
  final finish = DateTime(today.year, today.month, today.day + daysNeeded - 1);
  final when = switch (daysNeeded) {
    1 => 'today',
    2 => 'tomorrow',
    < 7 => 'by ${_weekdays[finish.weekday - 1]}',
    _ => 'by ${finish.day} ${_months[finish.month - 1]}',
  };
  return '$left · done $when at your pace';
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Seconds read on each of the [days] days up to and including [now]'s, from [sessions]
/// (by the day each started).
List<int> secondsByDay(Iterable<({DateTime startedAt, int seconds})> sessions, DateTime now, {int days = 14}) {
  final today = DateTime(now.year, now.month, now.day);
  final out = List.filled(days, 0);
  for (final s in sessions) {
    final day = DateTime(s.startedAt.year, s.startedAt.month, s.startedAt.day);
    // Rounded: a day with a clock change is 23 or 25 hours.
    final ago = (today.difference(day).inHours + 12) ~/ 24;
    if (ago >= 0 && ago < days) out[ago] += s.seconds;
  }
  return out;
}

/// Each book's sections, worked out once (this runs on every page).
final _sections = Expando<List<StoryChapter>>();
