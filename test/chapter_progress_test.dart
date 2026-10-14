import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/reader/chapter_progress.dart';
import 'package:marginalia/readium/readium.dart';

void main() {
  // A cover (one position), a contents page (one), then three chapters.
  const book = PublicationInfo(
    id: 'p',
    title: 'Book',
    authors: [],
    language: 'en',
    isRightToLeft: false,
    toc: [],
    chapters: [
      ChapterPositions(href: 'cover.xhtml', start: 1, count: 1),
      ChapterPositions(href: 'toc.xhtml', start: 2, count: 1),
      ChapterPositions(href: 'c1.xhtml', start: 3, count: 20),
      ChapterPositions(href: 'c2.xhtml', start: 23, count: 10),
      ChapterPositions(href: 'c3.xhtml', start: 33, count: 30),
    ],
  );

  test('chapters are counted without the cover and contents', () {
    expect(
      chapterProgress(book, href: 'c2.xhtml#part', position: 26, secondsPerPosition: 60),
      'Ch 2 of 3 · 6 pages, 6 min left',
    );
  });

  test('short pages say nothing, and the last page says so', () {
    expect(chapterProgress(book, href: 'cover.xhtml', position: 1, secondsPerPosition: 60), isNull);
    expect(chapterProgress(book, href: 'c1.xhtml', position: 22, secondsPerPosition: 60), 'Ch 1 of 3 · last page');
  });

  test('without a position, the progression through the chapter is used', () {
    expect(
      chapterProgress(book, href: 'c3.xhtml', progression: 0.5, secondsPerPosition: 150),
      'Ch 3 of 3 · 15 pages, 38 min left',
    );
  });
}
