import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/data/database.dart';
import 'package:marginalia/stats/year_review.dart';

Book _book(String id, String author) => Book(
  id: id,
  title: 'Book $id',
  authors: [author],
  sortTitle: id,
  sortAuthor: author,
  format: 'epub',
  fileSize: 0,
  source: BookSource.import,
  tags: const [],
  ratingHalves: 0,
  favorite: false,
  progress: 0,
  addedAt: DateTime(2026),
  updatedAt: DateTime(2026),
  deleted: false,
  dirty: false,
);

ReadingSession _session(String id, String book, DateTime start, int seconds) => ReadingSession(
  id: id,
  bookId: book,
  startedAt: start,
  endedAt: start.add(Duration(seconds: seconds)),
  seconds: seconds,
  pages: 0,
  updatedAt: start,
  deleted: false,
  dirty: false,
);

Annotation _highlight(String id, String text, DateTime at, {String? note}) => Annotation(
  id: id,
  bookId: 'a',
  type: note == null ? AnnotationType.highlight : AnnotationType.note,
  locator: '{}',
  selectedText: text,
  note: note,
  createdAt: at,
  updatedAt: at,
  deleted: false,
  dirty: false,
);

void main() {
  final now = DateTime(2026, 10, 31, 12);

  test('the best month, the author read most and the year’s longest streak', () {
    final review = YearReview.of(
      year: 2026,
      sessions: [
        _session('1', 'a', DateTime(2026, 3, 1, 20), 600),
        _session('2', 'a', DateTime(2026, 3, 2, 20), 600),
        _session('3', 'a', DateTime(2026, 3, 3, 20), 600),
        _session('4', 'b', DateTime(2026, 7, 9, 20), 1200),
        // Last year's: not counted.
        _session('5', 'b', DateTime(2025, 12, 31, 20), 9000),
      ],
      books: [_book('a', 'Mary Shelley'), _book('b', 'Bram Stoker')],
      annotations: const [],
      words: const [],
      now: now,
    );
    expect(review.bestMonth, 'March');
    expect(review.bestMonthSeconds, 1800);
    expect(review.topAuthor, 'Mary Shelley');
    expect(review.yearStreak, 3);
    expect(review.stats.seconds, 3000);
  });

  test('the quote is one with a note if there is one, never a fragment', () {
    final at = DateTime(2026, 5, 1);
    final long = 'It was on a dreary night of November that I beheld the accomplishment of my toils.';
    final noted = 'Beware; for I am fearless, and therefore powerful, she said.';
    expect(YearReview.pickQuote([_highlight('1', long, at), _highlight('2', 'Too short', at)])?.id, '1');
    expect(YearReview.pickQuote([_highlight('1', long, at), _highlight('2', noted, at, note: 'yes')])?.id, '2');
    expect(YearReview.pickQuote([_highlight('1', 'Too short', at)]), isNull);
  });

  test('longest run of days', () {
    expect(YearReview.longestRun([DateTime(2026, 1, 1), DateTime(2026, 1, 2), DateTime(2026, 1, 4)]), 2);
    expect(YearReview.longestRun(const []), 0);
  });
}
