/// Readable text from a bit of book HTML (a description, a footnote): paragraphs and line
/// breaks become new lines, tags go, and entities are decoded.
String htmlToText(String html) {
  var s = html
      .replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>', caseSensitive: false, dotAll: true), '')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(p|div|li|h[1-6]|blockquote|aside|section|tr)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  s = s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'), (m) {
    final code = m[1]!;
    if (code.startsWith('#x') || code.startsWith('#X')) {
      return String.fromCharCode(int.tryParse(code.substring(2), radix: 16) ?? 0x3F);
    }
    if (code.startsWith('#')) return String.fromCharCode(int.tryParse(code.substring(1)) ?? 0x3F);
    return _entities[code] ?? m[0]!;
  });
  return s
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t\r\f]+'), ' ').trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

const _entities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'mdash': '—',
  'ndash': '–',
  'hellip': '…',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
  'laquo': '«',
  'raquo': '»',
  'copy': '©',
  'eacute': 'é',
  'egrave': 'è',
  'agrave': 'à',
  'ccedil': 'ç',
  'uuml': 'ü',
  'ouml': 'ö',
  'auml': 'ä',
  'szlig': 'ß',
  'dagger': '†',
  'Dagger': '‡',
  'sect': '§',
  'para': '¶',
};
