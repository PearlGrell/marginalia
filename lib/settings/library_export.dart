import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/library.dart';
import '../notes/notes_export.dart';
import '../share/file_export.dart';
import '../storage/local_store.dart';
import '../theme/tokens.dart';

/// Everything in one zip, to keep or to move elsewhere:
///
///     books/Title - Author.epub     every book on this phone
///     covers/<id>.jpg
///     notes/Title.md                each book's highlights and notes
///     library.json                  books, collections, notes, bookmarks, reading time, words
///     README.txt                    what's inside, and books that are only in the cloud
class LibraryExport {
  LibraryExport(this._db, this._store);

  final AppDatabase _db;
  final LocalStore _store;

  /// Builds the zip; returns its path.
  Future<String> build({required void Function(String) onStep}) async {
    onStep('Gathering your library');
    final books = [for (final b in await _db.allBooks()) if (!b.deleted) b]
      ..sort((a, b) => a.sortTitle.compareTo(b.sortTitle));
    final annotations = await _db.allAnnotations();
    final collections = await _db.allCollections();
    final links = await _db.allBookCollections();
    final sessions = await _db.allSessions();
    final words = await _db.allWords();

    final files = <(String, String)>[]; // (path on phone, name in zip)
    final texts = <(String, String)>[]; // (name in zip, content)
    final usedNames = <String>{};
    String unique(String name, String ext) {
      var candidate = '$name$ext';
      for (var i = 2; usedNames.contains(candidate.toLowerCase()); i++) {
        candidate = '$name ($i)$ext';
      }
      usedNames.add(candidate.toLowerCase());
      return candidate;
    }

    final missing = <Book>[];
    final entries = <Map<String, Object?>>[];
    for (final b in books) {
      final base = safeFileName(b.authors.isEmpty ? b.title : '${b.title} - ${b.authors.first}');
      String? epub;
      if (b.filePath case final path? when await File(path).exists()) {
        epub = 'books/${unique(base, '.epub')}';
        files.add((path, epub));
      } else {
        missing.add(b);
      }
      String? cover;
      if (b.coverPath case final path? when await File(path).exists()) {
        cover = 'covers/${b.id}.jpg';
        files.add((path, cover));
      }
      final notes = [
        for (final a in annotations)
          if (a.bookId == b.id && a.type != AnnotationType.bookmark) a,
      ]..sort((x, y) => (x.progression ?? 2).compareTo(y.progression ?? 2));
      String? notesFile;
      if (notes.isNotEmpty) {
        notesFile = 'notes/${unique(safeFileName(b.title), '.md')}';
        texts.add((notesFile, notesMarkdown([BookNotes(b, notes)])));
      }
      entries.add({
        'id': b.id,
        'title': b.title,
        'authors': b.authors,
        'language': b.language,
        'series': b.series,
        'seriesIndex': b.seriesIndex,
        'tags': b.tags,
        'status': b.status?.name,
        'rating': b.ratingHalves / 2,
        'favorite': b.favorite,
        'progress': b.progress,
        'addedAt': b.addedAt.toIso8601String(),
        'finishedAt': b.finishedAt?.toIso8601String(),
        'lastReadAt': b.lastReadAt?.toIso8601String(),
        'file': epub,
        'cover': cover,
        'notes': notesFile,
        'source': b.source.name,
        'sourceId': b.sourceId,
      });
    }

    final json = const JsonEncoder.withIndent('  ').convert({
      'format': 'marginalia-export',
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'books': entries,
      'collections': [
        for (final c in collections)
          {
            'id': c.id,
            'name': c.name,
            'books': [for (final l in links) if (l.collectionId == c.id) l.bookId],
          },
      ],
      'annotations': [
        for (final a in annotations)
          {
            'id': a.id,
            'bookId': a.bookId,
            'type': a.type.name,
            'text': a.selectedText,
            'note': a.note,
            'color': a.color,
            'chapter': a.chapterTitle,
            'progression': a.progression,
            'locator': a.locator,
            'createdAt': a.createdAt.toIso8601String(),
          },
      ],
      'sessions': [
        for (final s in sessions)
          {
            'bookId': s.bookId,
            'startedAt': s.startedAt.toIso8601String(),
            'endedAt': s.endedAt.toIso8601String(),
            'seconds': s.seconds,
            'pages': s.pages,
            'device': s.deviceName,
          },
      ],
      'words': [
        for (final w in words)
          {
            'word': w.word,
            'language': w.language,
            'partOfSpeech': w.partOfSpeech,
            'definition': w.definition,
            'context': w.context,
            'savedAt': w.createdAt.toIso8601String(),
          },
      ],
      'readerSettings': _store.readJson('reader.preferences'),
    });
    texts.add(('library.json', json));
    texts.add(('README.txt', _readme(books.length - missing.length, missing)));

    final now = DateTime.now();
    final target = await shareableFile(
      'Marginalia ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.zip',
    );
    onStep('Packing ${files.where((f) => f.$2.startsWith('books/')).length} books');
    final path = target.path;
    // Zipping a whole library takes a while: off the UI thread.
    await Isolate.run(() => writeZip(path, files, texts));
    return path;
  }

  static String _readme(int included, List<Book> missing) => [
    'Your Marginalia library, exported ${DateTime.now().toIso8601String().substring(0, 10)}.',
    '',
    'books/      $included EPUB ${included == 1 ? 'file' : 'files'}, readable in any EPUB reader',
    'notes/      each book’s highlights and notes as Markdown',
    'covers/     cover images',
    'library.json  everything else: books, collections, notes, bookmarks, reading time, saved words',
    if (missing.isNotEmpty) ...[
      '',
      'Not included (not on this phone; open them once to download, then export again):',
      for (final b in missing) '  - ${b.title}${b.authors.isEmpty ? '' : ' by ${b.authors.join(', ')}'}',
    ],
  ].join('\n');
}

/// Writes the zip: [files] are (path, name in zip), [texts] are (name, content). EPUBs and
/// images are already compressed, so they're stored as they are.
void writeZip(String path, List<(String, String)> files, List<(String, String)> texts) {
  final encoder = ZipFileEncoder()..create(path);
  for (final (source, name) in files) {
    encoder.addFileSync(File(source), name, 0);
  }
  for (final (name, content) in texts) {
    encoder.addArchiveFile(ArchiveFile.string(name, content));
  }
  encoder.closeSync();
}

/// Builds the export, with progress, then offers to save or send it.
Future<void> exportLibrary(BuildContext context, WidgetRef ref) async {
  final step = ValueNotifier('Starting');
  final navigator = Navigator.of(context);
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
            Expanded(child: ValueListenableBuilder(valueListenable: step, builder: (_, s, _) => Text(s))),
          ],
        ),
      ),
    ),
  );
  String? path;
  Object? error;
  try {
    path = await LibraryExport(ref.read(databaseProvider), ref.read(localStoreProvider)).build(onStep: (s) => step.value = s);
  } catch (e) {
    error = e;
  } finally {
    navigator.pop();
  }
  if (!context.mounted) return;
  if (path == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't export: $error")));
    return;
  }
  await offerExistingFile(
    context,
    path: path,
    name: path.split(Platform.pathSeparator).last.split('/').last,
    mimeType: 'application/zip',
    title: 'Your library is packed',
  );
}
