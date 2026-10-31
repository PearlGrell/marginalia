import 'package:xml/xml.dart';

/// What Calibre knows about a book that the book's own file may not say: from the
/// `metadata.opf` it keeps beside each book in its library folder.
class CalibreMetadata {
  const CalibreMetadata({
    this.title,
    this.authors = const [],
    this.description,
    this.tags = const [],
    this.series,
    this.seriesIndex,
    this.ratingHalves,
  });

  final String? title;
  final List<String> authors;
  final String? description;
  final List<String> tags;
  final String? series;
  final double? seriesIndex;

  /// 0 to 10, as the library keeps ratings (Calibre's own scale: two per star).
  final int? ratingHalves;
}

/// Calibre's `metadata.opf`, or null if it isn't one.
CalibreMetadata? parseCalibreOpf(String opf) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(opf);
  } on XmlException {
    return null;
  }
  final metadata = doc.findAllElements('metadata', namespaceUri: '*').firstOrNull;
  if (metadata == null) return null;

  Iterable<String> dc(String name) => metadata
      .findElements(name, namespaceUri: 'http://purl.org/dc/elements/1.1/')
      .map((e) => e.innerText.trim())
      .where((t) => t.isNotEmpty);

  // Calibre writes `<meta name="calibre:series" content="…"/>`; newer versions also
  // `<meta property="calibre:series">…</meta>`.
  String? meta(String name) {
    for (final e in metadata.findElements('meta', namespaceUri: '*')) {
      if (e.getAttribute('name') == name) {
        final content = e.getAttribute('content')?.trim();
        if (content != null && content.isNotEmpty) return content;
      }
      if (e.getAttribute('property') == name) {
        final content = e.innerText.trim();
        if (content.isNotEmpty) return content;
      }
    }
    return null;
  }

  final rating = double.tryParse(meta('calibre:rating') ?? '');
  final description = dc('description').firstOrNull;
  return CalibreMetadata(
    title: dc('title').firstOrNull,
    authors: dc('creator').toList(),
    description: description == null ? null : plainText(description),
    tags: dc('subject').toSet().toList(),
    series: meta('calibre:series'),
    seriesIndex: double.tryParse(meta('calibre:series_index') ?? ''),
    ratingHalves: rating == null || rating <= 0 ? null : rating.round().clamp(1, 10),
  );
}

/// Calibre keeps descriptions as HTML: the text of it, paragraphs on their own lines.
String plainText(String html) => html
    .replaceAll(RegExp(r'<\s*(/p|/div)\s*>', caseSensitive: false), '\n\n')
    .replaceAll(RegExp(r'<\s*(br|/li)\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .replaceAll(RegExp(r'\n\s*\n+'), '\n\n')
    .trim();
