import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/library/calibre.dart';
import 'package:marginalia/library/kindle_clippings.dart';

const _clippings = '''﻿Frankenstein (Shelley, Mary)\r
- Your Highlight on page 12 | Location 170-172 | Added on Monday, 3 April 2023 10:00:00\r
\r
Beware; for I am fearless, and therefore powerful.\r
==========\r
Frankenstein (Shelley, Mary)\r
- Your Note on page 12 | Location 172 | Added on Monday, 3 April 2023 10:01:00\r
\r
The creature's whole argument.\r
==========\r
Frankenstein (Shelley, Mary)\r
- Your Bookmark on page 40 | Location 600 | Added on Monday, 3 April 2023 11:00:00\r
\r
\r
==========\r
Dracula: A Mystery Story (Bram Stoker)\r
- Your Highlight at location 1200-1203 | Added on Tuesday, 4 April 2023 21:00:00\r
\r
I am the master of this house\r
==========\r
Dracula: A Mystery Story (Bram Stoker)\r
- Your Highlight at location 1200-1206 | Added on Tuesday, 4 April 2023 21:00:30\r
\r
I am the master of this house and I bid you welcome.\r
==========\r
''';

void main() {
  group('Kindle clippings', () {
    final clippings = parseKindleClippings(_clippings);

    test('highlights with their books and notes; bookmarks left out', () {
      expect(clippings.length, 2);
      final first = clippings.first;
      expect(first.title, 'Frankenstein');
      expect(first.author, 'Shelley, Mary');
      expect(first.text, 'Beware; for I am fearless, and therefore powerful.');
      expect(first.note, "The creature's whole argument.");
      expect((first.start, first.end), (170, 172));
    });

    test('an extended highlight replaces the shorter one', () {
      expect(clippings.last.text, 'I am the master of this house and I bid you welcome.');
      expect(clippings.last.note, isNull);
    });

    test('titles match the library without subtitles, articles or punctuation', () {
      expect(sameTitle('Dracula: A Mystery Story', 'Dracula'), isTrue);
      expect(sameTitle('The Picture of Dorian Gray', 'Picture of Dorian Gray, The'), isTrue);
      expect(sameTitle('Emma', 'Emma (Penguin Classics)'), isTrue);
      expect(sameTitle('Emma', 'Persuasion'), isFalse);
    });

    test('the search is the opening words, within the first paragraph', () {
      expect(searchQueryFor('Short one.\nSecond paragraph.'), 'Short one.');
      final long = List.filled(40, 'word').join(' ');
      final query = searchQueryFor(long, max: 60);
      expect(query.length, lessThanOrEqualTo(60));
      expect(long.startsWith(query), isTrue);
    });
  });

  group('Calibre metadata.opf', () {
    const opf = '''<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>The Fellowship of the Ring</dc:title>
    <dc:creator opf:role="aut">J. R. R. Tolkien</dc:creator>
    <dc:description>&lt;p&gt;The first part of &lt;b&gt;The Lord of the Rings&lt;/b&gt;.&lt;/p&gt;&lt;p&gt;Frodo sets out.&lt;/p&gt;</dc:description>
    <dc:subject>Fantasy</dc:subject>
    <dc:subject>Classics</dc:subject>
    <meta name="calibre:series" content="The Lord of the Rings"/>
    <meta name="calibre:series_index" content="1.0"/>
    <meta name="calibre:rating" content="8.0"/>
  </metadata>
</package>''';

    test('series, tags, rating and description', () {
      final m = parseCalibreOpf(opf)!;
      expect(m.title, 'The Fellowship of the Ring');
      expect(m.authors, ['J. R. R. Tolkien']);
      expect(m.series, 'The Lord of the Rings');
      expect(m.seriesIndex, 1.0);
      expect(m.ratingHalves, 8);
      expect(m.tags, ['Fantasy', 'Classics']);
      expect(m.description, 'The first part of The Lord of the Rings.\n\nFrodo sets out.');
    });

    test('not an OPF, nothing', () {
      expect(parseCalibreOpf('not xml at all <'), isNull);
      expect(parseCalibreOpf('<html><body/></html>'), isNull);
    });
  });
}
