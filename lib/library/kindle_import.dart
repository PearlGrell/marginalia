import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/library.dart';
import '../readium/readium.dart';
import '../theme/tokens.dart';
import 'kindle_clippings.dart';

/// What a Kindle import did.
class KindleImportResult {
  const KindleImportResult({
    required this.added,
    required this.already,
    required this.notFound,
    required this.books,
    required this.missingBooks,
  });

  /// Highlights added, and ones already in the library.
  final int added;
  final int already;

  /// Highlights whose words weren't found in the library's copy (another edition).
  final int notFound;

  /// Books highlights were added to.
  final int books;

  /// Kindle titles with no EPUB of that name in the library.
  final List<String> missingBooks;
}

/// Brings a Kindle's highlights (and the notes on them) into the library's copies of the same
/// books, each found in the book's text so it's drawn in the page like one made here.
class KindleImporter {
  KindleImporter(this._db, {Readium readium = const Readium()}) : _readium = readium;

  final AppDatabase _db;
  final Readium _readium;

  Future<KindleImportResult> run(String clippingsFile, {void Function(String status)? onProgress}) async {
    final clippings = parseKindleClippings(clippingsFile);
    final books = [for (final b in await _db.allBooks()) if (!b.deleted && b.format == 'epub') b];

    final byTitle = <String, List<KindleClipping>>{};
    for (final c in clippings) {
      (byTitle[c.title] ??= []).add(c);
    }
    var added = 0, already = 0, notFound = 0, touched = 0;
    final missing = <String>[];
    var created = DateTime.now();
    for (final MapEntry(key: title, value: highlights) in byTitle.entries) {
      final book = books.where((b) => sameTitle(title, b.title)).firstOrNull;
      final path = book?.filePath;
      if (book == null || path == null || !File(path).existsSync()) {
        missing.add(title);
        continue;
      }
      onProgress?.call(book.title);
      final have = {for (final a in await _db.notesFor(book.id)) _plain(a.selectedText ?? '')};
      final PublicationInfo publication;
      try {
        publication = await _readium.open(path);
      } on ReadiumException {
        missing.add(title);
        continue;
      }
      var addedHere = 0;
      try {
        for (final h in highlights) {
          if (have.contains(_plain(h.text))) {
            already++;
            continue;
          }
          final found = await _find(publication.id, h.text);
          if (found == null) {
            notFound++;
            continue;
          }
          // In the Kindle's order, a moment apart, so they list as they were made.
          created = created.add(const Duration(milliseconds: 1));
          await _db.saveAnnotation(
            AnnotationsCompanion.insert(
              id: 'kindle-${created.microsecondsSinceEpoch.toRadixString(36)}',
              bookId: book.id,
              type: h.note == null ? AnnotationType.highlight : AnnotationType.note,
              locator: found.locator,
              selectedText: Value(h.text),
              textBefore: Value(found.before),
              textAfter: Value(found.after),
              color: Value(HighlightColor.yellow.name),
              note: Value(h.note),
              chapterTitle: Value(found.title),
              progression: Value(found.progression),
              createdAt: created,
              updatedAt: created,
            ),
          );
          have.add(_plain(h.text));
          added++;
          addedHere++;
        }
      } finally {
        await _readium.close(publication.id);
      }
      if (addedHere > 0) touched++;
    }
    return KindleImportResult(added: added, already: already, notFound: notFound, books: touched, missingBooks: missing);
  }

  /// The highlight's place: its opening words, or failing that a shorter stretch of them
  /// (the Kindle's punctuation can differ from the book's further in).
  Future<({String locator, String? title, String? before, String? after, double? progression})?> _find(
    String publicationId,
    String text,
  ) async {
    for (final max in const [120, 60]) {
      final query = searchQueryFor(text, max: max);
      if (query.length < 8) return null;
      try {
        final found = await _readium.find(publicationId, query);
        if (found != null) return found;
      } on PlatformException {
        return null;
      }
    }
    return null;
  }

  static String _plain(String text) => text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Settings › Library: picks a My Clippings.txt and brings its highlights in, saying how it
/// went.
Future<void> importKindleHighlights(BuildContext context, WidgetRef ref) async {
  final String? file;
  try {
    file = await ref.read(libraryImporterProvider.notifier).pickTextFile();
  } on PlatformException {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That file couldn’t be read.')));
    }
    return;
  }
  if (file == null || !context.mounted) return;
  if (parseKindleClippings(file).isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('No highlights found'),
        content: const Text(
          'Pick “My Clippings.txt” from your Kindle: connect it to your computer or phone with a cable '
          'and it’s in the “documents” folder.',
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
    return;
  }

  final status = ValueNotifier<String>('Reading your clippings…');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: Space.lg),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (context, value, _) => Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  KindleImportResult? result;
  Object? error;
  try {
    result = await KindleImporter(ref.read(databaseProvider)).run(file, onProgress: (title) => status.value = 'Finding highlights in $title…');
  } catch (e) {
    error = e;
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(result == null ? 'The import stopped' : 'Kindle highlights'),
      content: SingleChildScrollView(
        child: Text(
          result == null
              ? 'Something went wrong: $error'
              : [
                  result.added == 0
                      ? 'No new highlights.'
                      : '${result.added} ${result.added == 1 ? 'highlight' : 'highlights'} added to '
                            '${result.books} ${result.books == 1 ? 'book' : 'books'}. Find them in Notes and in the page.',
                  if (result.already > 0) '${result.already} were already here.',
                  if (result.notFound > 0)
                    '${result.notFound} couldn’t be found in your copy: it may be a different edition from the Kindle’s.',
                  if (result.missingBooks.isNotEmpty)
                    'Not in your library as an EPUB (add them, then import again):\n'
                        '${[for (final t in result.missingBooks.take(12)) '• $t'].join('\n')}'
                        '${result.missingBooks.length > 12 ? '\n…and ${result.missingBooks.length - 12} more' : ''}',
                ].join('\n\n'),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    ),
  );
}
