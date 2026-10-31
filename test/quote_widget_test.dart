import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/data/database.dart';
import 'package:marginalia/notes/quote_widget.dart';

void main() {
  final t = DateTime(2026, 10, 1);
  final book = Book(
    id: 'b',
    title: 'Frankenstein',
    authors: const ['Mary Shelley'],
    sortTitle: 'frankenstein',
    sortAuthor: 'shelley, mary',
    format: 'epub',
    fileSize: 0,
    source: BookSource.import,
    tags: const [],
    ratingHalves: 0,
    favorite: false,
    progress: 0,
    addedAt: t,
    updatedAt: t,
    deleted: false,
    dirty: false,
  );
  Annotation note(String id, String text, {AnnotationType type = AnnotationType.highlight, String book = 'b'}) =>
      Annotation(
        id: id,
        bookId: book,
        type: type,
        locator: '{"href":"c1.xhtml"}',
        selectedText: text,
        createdAt: t,
        updatedAt: t,
        deleted: false,
        dirty: false,
      );

  test('highlights that read on their own, with their book and place', () {
    const good = 'Beware; for I am fearless, and therefore powerful.';
    final quotes = widgetQuotes([
      note('1', good),
      note('2', 'Too short'),
      note('3', 'x' * 400),
      note('4', good, type: AnnotationType.bookmark),
      note('5', good, book: 'gone'),
    ], {'b': book});
    expect(quotes, [
      {'text': good, 'title': 'Frankenstein', 'bookId': 'b', 'locator': '{"href":"c1.xhtml"}'},
    ]);
  });
}
