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

  test('chapters are the contents’ story chapters, not every longer file', () {
    // A dedication the contents leave out, longer than a page, then two chapters linked by
    // #fragment, then a copyright page.
    const linked = PublicationInfo(
      id: 'q',
      title: 'Book',
      authors: [],
      language: 'en',
      isRightToLeft: false,
      toc: [
        TocEntry(title: 'Book', href: 'title.xhtml#t', children: []),
        TocEntry(title: 'Chapter 1 - The Storm', href: 'c1.xhtml#a', children: []),
        TocEntry(title: 'Chapter 2 - The Wreck', href: 'c2.xhtml#b', children: []),
        TocEntry(title: 'Copyright page', href: 'rights.xhtml#c', children: []),
      ],
      chapters: [
        ChapterPositions(href: 'title.xhtml', start: 1, count: 1),
        ChapterPositions(href: 'dedication.xhtml', start: 2, count: 2),
        ChapterPositions(href: 'c1.xhtml', start: 4, count: 20),
        ChapterPositions(href: 'c2.xhtml', start: 24, count: 10),
        ChapterPositions(href: 'rights.xhtml', start: 34, count: 2),
      ],
    );
    expect(chapterProgress(linked, href: 'dedication.xhtml', position: 2, secondsPerPosition: 60), isNull);
    expect(chapterProgress(linked, href: 'c1.xhtml', position: 23, secondsPerPosition: 60), 'Ch 1 of 2 · last page');
    expect(chapterProgress(linked, href: 'c2.xhtml', position: 24, secondsPerPosition: 60), startsWith('Ch 2 of 2'));
    expect(chapterProgress(linked, href: 'rights.xhtml', position: 34, secondsPerPosition: 60), isNull);
  });

  test('without a position, the progression through the chapter is used', () {
    expect(
      chapterProgress(book, href: 'c3.xhtml', progression: 0.5, secondsPerPosition: 150),
      'Ch 3 of 3 · 15 pages, 38 min left',
    );
  });
}
