/// A highlight from a Kindle's `My Clippings.txt`, with the note written on it, if any.
class KindleClipping {
  const KindleClipping({
    required this.title,
    this.author,
    required this.text,
    this.note,
    this.start,
    this.end,
  });

  /// The book's title and author as the Kindle wrote them.
  final String title;
  final String? author;
  final String text;
  final String? note;

  /// Kindle locations the highlight spans.
  final int? start;
  final int? end;

  KindleClipping withNote(String note) =>
      KindleClipping(title: title, author: author, text: text, note: note, start: start, end: end);
}

/// The highlights in a `My Clippings.txt`, in the file's order, with each note joined to the
/// highlight it was written on (the one ending at the note's location). Bookmarks, notes on
/// nothing, and highlights a later one replaced (the Kindle keeps both when one is extended)
/// are left out.
List<KindleClipping> parseKindleClippings(String file) {
  final highlights = <KindleClipping>[];
  final notes = <({String title, int? at, String text})>[];
  for (final entry in file.replaceAll('﻿', '').replaceAll('\r\n', '\n').split(RegExp(r'^=+\s*$', multiLine: true))) {
    final lines = entry.split('\n').map((l) => l.trimRight()).toList();
    while (lines.isNotEmpty && lines.first.trim().isEmpty) {
      lines.removeAt(0);
    }
    if (lines.length < 2) continue;
    final (title, author) = _titleAndAuthor(lines[0].trim());
    final meta = lines[1];
    final text = lines.skip(2).join('\n').trim();
    if (text.isEmpty) continue;
    final location = RegExp(r'(?:location|loc\.|Location|Loc\.)\s*(\d+)(?:\s*-\s*(\d+))?', caseSensitive: false).firstMatch(meta);
    final start = location == null ? null : int.tryParse(location[1]!);
    final end = location?[2] == null ? start : _fullEnd(start!, location![2]!);
    final kind = meta.toLowerCase();
    if (kind.contains('bookmark')) continue;
    if (kind.contains('note') && !kind.contains('highlight')) {
      notes.add((title: title, at: start, text: text));
      continue;
    }
    highlights.add(KindleClipping(title: title, author: author, text: text, start: start, end: end));
  }

  // An extended highlight is saved again whole: keep only the longest of those that overlap
  // and contain one another.
  final kept = <KindleClipping>[];
  for (final h in highlights) {
    final i = kept.indexWhere((k) => k.title == h.title && (k.text.contains(h.text) || h.text.contains(k.text)));
    if (i < 0) {
      kept.add(h);
    } else if (h.text.length > kept[i].text.length) {
      kept[i] = h;
    }
  }

  for (final n in notes) {
    final i = kept.lastIndexWhere(
      (h) => h.title == n.title && n.at != null && h.start != null && h.start! <= n.at! && n.at! <= (h.end ?? h.start!),
    );
    if (i >= 0) kept[i] = kept[i].withNote(kept[i].note == null ? n.text : '${kept[i].note}\n\n${n.text}');
  }
  return kept;
}

/// "Dune (Herbert, Frank)" → ("Dune", "Herbert, Frank"); a title with no author in brackets
/// is all title.
(String, String?) _titleAndAuthor(String line) {
  final m = RegExp(r'^(.*\S)\s*\(([^()]*)\)$').firstMatch(line);
  return m == null ? (line, null) : (m[1]!, m[2]!.trim().isEmpty ? null : m[2]!.trim());
}

/// Kindles write "1234-56" for 1234 to 1256.
int? _fullEnd(int start, String end) {
  final value = int.tryParse(end);
  if (value == null) return start;
  if (value >= start) return value;
  final digits = end.length;
  final base = start - start % _pow10(digits);
  final full = base + value;
  return full >= start ? full : full + _pow10(digits);
}

int _pow10(int n) {
  var v = 1;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

/// A title as compared between the Kindle and the library: lowercased, letters and digits
/// only, without a subtitle or anything in brackets.
String comparableTitle(String title) => title
    .toLowerCase()
    .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ')
    .split(RegExp(r'[:;]| - '))
    .first
    .replaceFirst(RegExp(r'^\s*(the|a|an)\s+'), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

/// Whether a Kindle title and a library title are the same book.
bool sameTitle(String kindle, String library) {
  final a = comparableTitle(kindle), b = comparableTitle(library);
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  return a.length >= 8 && b.length >= 8 && (a.startsWith(b) || b.startsWith(a));
}

/// What to search the book for to find [text]: its first words, up to [max] characters and
/// not past the end of its first paragraph (a search doesn't cross paragraphs), with spaces
/// made plain.
String searchQueryFor(String text, {int max = 120}) {
  final first = text.trim().split(RegExp(r'\n\s*\n|\n')).first.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (first.length <= max) return first;
  final cut = first.lastIndexOf(' ', max);
  return first.substring(0, cut < 40 ? max : cut);
}
