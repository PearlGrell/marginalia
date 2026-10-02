import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/reader/search_sheet.dart';
import 'package:marginalia/util/html_text.dart';

void main() {
  group('htmlToText', () {
    test('keeps paragraphs and decodes entities', () {
      const html = '<aside epub:type="footnote"><p>1. See <i>Ulysses</i>, p.&nbsp;12 &amp; '
          'the &ldquo;notes&rdquo;.</p><p>Second&#8212;line &#x2026;</p></aside>';
      expect(htmlToText(html), '1. See Ulysses, p. 12 & the “notes”.\nSecond—line …');
    });

    test('line breaks and stray whitespace', () {
      expect(htmlToText('a<br/>b<br>  c  \n\n\n\n d'), 'a\nb\nc\n\nd');
    });

    test('drops scripts and styles', () {
      expect(htmlToText('<style>p{}</style><p>Text</p><script>x()</script>'), 'Text');
    });
  });

  group('search snippets', () {
    test('cut at word boundaries', () {
      final before = 'word ' * 40;
      final snippet = snippetBefore(before, length: 20);
      expect(snippet.startsWith('…'), isTrue);
      expect(snippet.length, lessThanOrEqualTo(21));
      expect(snippet.contains('wor d'), isFalse);
      expect(snippetAfter('a short tail'), 'a short tail');
      expect(snippetAfter('one two three four', length: 9), 'one two…');
    });
  });
}
