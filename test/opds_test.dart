import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/discover/gutenberg.dart' show CatalogException;
import 'package:marginalia/discover/opds.dart';

const _feed = '''<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
  <id>urn:example:root</id>
  <title>Example Library</title>
  <link rel="next" href="/opds/new?page=2" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
  <link rel="search" href="/opds/search.xml" type="application/opensearchdescription+xml"/>
  <entry>
    <title>Science Fiction</title>
    <id>urn:example:sf</id>
    <link rel="subsection" href="/opds/subjects/sf" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
  </entry>
  <entry>
    <title>The Time Machine</title>
    <id>urn:example:book:35</id>
    <author><name>H. G. Wells</name></author>
    <summary>A traveller goes &lt;em&gt;forward&lt;/em&gt;.</summary>
    <link rel="http://opds-spec.org/image" href="https://cdn.example.org/35.jpg" type="image/jpeg"/>
    <link rel="http://opds-spec.org/image/thumbnail" href="covers/35-small.jpg" type="image/jpeg"/>
    <link rel="http://opds-spec.org/acquisition/open-access" href="/books/35.kepub" type="application/kepub+zip"/>
    <link rel="http://opds-spec.org/acquisition/open-access" href="/books/35.epub" type="application/epub+zip"/>
  </entry>
</feed>''';

void main() {
  final base = Uri.parse('https://library.example.org/opds/root.xml');

  test('a feed gives its sections, its books and where to go next', () {
    final feed = OpdsFeed.parse(_feed, base);
    expect(feed.title, 'Example Library');
    expect(feed.next.toString(), 'https://library.example.org/opds/new?page=2');
    expect(feed.search.toString(), 'https://library.example.org/opds/search.xml');

    final section = feed.entries.first;
    expect(section.isBook, isFalse);
    expect(section.feed.toString(), 'https://library.example.org/opds/subjects/sf');

    final book = feed.entries.last;
    expect(book.isBook, isTrue);
    expect(book.author, 'H. G. Wells');
    expect(book.cover.toString(), 'https://cdn.example.org/35.jpg');
    expect(book.thumbnail.toString(), 'https://library.example.org/opds/covers/35-small.jpg');
    // The first edition the library can open, not the first listed.
    expect(book.readable!.href.toString(), 'https://library.example.org/books/35.epub');
  });

  test('a page that is not a catalog says so', () {
    expect(() => OpdsFeed.parse('<html><body>Hello</body></html>', base), throwsA(isA<CatalogException>()));
    expect(() => OpdsFeed.parse('not xml at all', base), throwsA(isA<CatalogException>()));
  });

  test('search templates are filled in, with optional parameters left empty', () {
    final description = '''<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
      <Url type="text/html" template="https://library.example.org/search?q={searchTerms}"/>
      <Url type="application/atom+xml" template="/opds/search?q={searchTerms}&amp;page={startPage?}"/>
    </OpenSearchDescription>''';
    final template = openSearchTemplate(description)!;
    expect(
      fillSearchTemplate(template, 'time travel', base).toString(),
      'https://library.example.org/opds/search?q=time+travel&page=',
    );
  });
}
