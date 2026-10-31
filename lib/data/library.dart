import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../storage/local_store.dart';
import '../library/calibre.dart';
import 'database.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final libraryQueryProvider = NotifierProvider<LibraryQueryNotifier, LibraryQuery>(
  LibraryQueryNotifier.new,
);

/// The library's filters and search reset each launch; its sort order is remembered.
class LibraryQueryNotifier extends Notifier<LibraryQuery> {
  static const _sortKey = 'library.sort';

  @override
  LibraryQuery build() {
    final saved = ref.read(localStoreProvider).readJson(_sortKey);
    final sort = LibrarySort.values.where((s) => s.name == saved).firstOrNull;
    return LibraryQuery(sort: sort ?? LibrarySort.recent);
  }

  void set(LibraryQuery query) {
    if (query.sort != state.sort) {
      ref.read(localStoreProvider).writeJson(_sortKey, query.sort.name);
    }
    state = query;
  }
}

final booksProvider = StreamProvider<List<Book>>(
  (ref) => ref.watch(databaseProvider).watchBooks(ref.watch(libraryQueryProvider)),
);

final continueReadingProvider = StreamProvider<Book?>(
  (ref) => ref.watch(databaseProvider).watchContinueReading(),
);

final collectionsProvider = StreamProvider<List<CollectionWithCount>>(
  (ref) => ref.watch(databaseProvider).watchCollections(),
);

final bookProvider = StreamProvider.family<Book?, String>(
  (ref, id) => ref.watch(databaseProvider).watchBook(id),
);

/// Every book in the library by id.
final allBooksProvider = StreamProvider<Map<String, Book>>(
  (ref) => ref.watch(databaseProvider).watchAllBooks().map((list) => {for (final b in list) b.id: b}),
);

final tagsProvider = StreamProvider<List<String>>((ref) => ref.watch(databaseProvider).watchTags());

final bookCollectionIdsProvider = StreamProvider.family<Set<String>, String>(
  (ref, id) => ref.watch(databaseProvider).watchCollectionIdsFor(id),
);

/// The native side of importing (see `LibraryChannel.kt`).
class _NativeLibrary {
  static const _channel = MethodChannel('marginalia/library');

  Future<List<String>> pickFiles() async =>
      (await _channel.invokeListMethod<String>('pickFiles')) ?? const [];

  Future<String?> pickFolder() => _channel.invokeMethod<String>('pickFolder');

  Future<List<({String uri, String name})>> scanFolder(String uri) async {
    final list = await _channel.invokeListMethod<Map<Object?, Object?>>('scanFolder', {
      'uri': uri,
    });
    return [
      for (final item in list ?? const <Map<Object?, Object?>>[])
        (uri: item['uri']! as String, name: item['name']! as String),
    ];
  }

  /// Every book under [uri], each with its Calibre `metadata.opf` text, if it has one.
  Future<List<({String uri, String name, String? opf})>> scanCalibre(String uri) async {
    final list = await _channel.invokeListMethod<Map<Object?, Object?>>('scanFolder', {'uri': uri, 'opf': true});
    return [
      for (final item in list ?? const <Map<Object?, Object?>>[])
        (uri: item['uri']! as String, name: item['name']! as String, opf: item['opf'] as String?),
    ];
  }

  /// The text of a file the reader picks, or null.
  Future<String?> pickTextFile() => _channel.invokeMethod<String>('pickTextFile');

  Future<Map<Object?, Object?>> importFile(String uri) async =>
      (await _channel.invokeMapMethod<Object?, Object?>('importFile', {'uri': uri}))!;

  /// A book another app asked to open, once.
  Future<({String uri, String name})?> takeOpenedFile() async {
    final m = await _channel.invokeMapMethod<String, String>('takeOpenedFile');
    return m == null ? null : (uri: m['uri']!, name: m['name']!);
  }
}

/// Progress of the import under way, if any.
class ImportProgress {
  const ImportProgress({
    this.total = 0,
    this.done = 0,
    this.added = 0,
    this.duplicates = 0,
    this.failed = 0,
    this.current,
    this.running = false,
  });

  final int total;
  final int done;
  final int added;
  final int duplicates;
  final int failed;

  /// Name of the file being imported.
  final String? current;
  final bool running;

  ImportProgress copyWith({
    int? total,
    int? done,
    int? added,
    int? duplicates,
    int? failed,
    String? current,
    bool? running,
  }) => ImportProgress(
    total: total ?? this.total,
    done: done ?? this.done,
    added: added ?? this.added,
    duplicates: duplicates ?? this.duplicates,
    failed: failed ?? this.failed,
    current: current ?? this.current,
    running: running ?? this.running,
  );

  String get summary {
    final parts = [
      if (added > 0) '$added ${added == 1 ? 'book' : 'books'} added',
      if (duplicates > 0) '$duplicates already in your library',
      if (failed > 0) "$failed couldn't be read",
    ];
    return parts.isEmpty ? 'No books found' : parts.join(' · ');
  }
}

/// Imports books: copies each file in under its fingerprint, skips ones already in the
/// library, and records what the library shows.
class LibraryImporter extends Notifier<ImportProgress> {
  final _native = _NativeLibrary();

  @override
  ImportProgress build() => const ImportProgress();

  AppDatabase get _db => ref.read(databaseProvider);

  /// Returns null if nothing was picked.
  Future<ImportProgress?> importFiles() async {
    final uris = await _native.pickFiles();
    if (uris.isEmpty) return null;
    return _importAll([for (final uri in uris) (uri: uri, name: _nameOf(uri))]);
  }

  /// A whole folder, subfolders included. Returns null if nothing was picked.
  Future<ImportProgress?> importFolder() async {
    final folder = await _native.pickFolder();
    if (folder == null) return null;
    state = const ImportProgress(running: true, current: 'Looking for books…');
    final files = await _native.scanFolder(folder);
    return _importAll(files);
  }

  /// A Calibre library folder: its books, with what Calibre knows of each (series, tags,
  /// rating, description) added to what the book's file says. Books already here get
  /// Calibre's series, tags and rating too. Returns null if nothing was picked.
  Future<ImportProgress?> importCalibreLibrary() async {
    final folder = await _native.pickFolder();
    if (folder == null) return null;
    state = const ImportProgress(running: true, current: 'Looking for books…');
    final files = await _native.scanCalibre(folder);
    state = ImportProgress(total: files.length, running: true);
    for (final file in files) {
      state = state.copyWith(current: file.name);
      try {
        final (:added, :id) = await _importOne(file.uri, file.name);
        if (file.opf case final opf?) {
          if (parseCalibreOpf(opf) case final metadata?) await _applyCalibre(id, metadata);
        }
        state = state.copyWith(
          added: state.added + (added ? 1 : 0),
          duplicates: state.duplicates + (added ? 0 : 1),
        );
      } on PlatformException {
        state = state.copyWith(failed: state.failed + 1);
      }
      state = state.copyWith(done: state.done + 1);
    }
    final finished = state.copyWith(running: false);
    state = finished;
    return finished;
  }

  /// Calibre's series, tags, rating and description for book [id]: tags join the book's own;
  /// the rest fill in what's missing (a rating or series set here is kept).
  Future<void> _applyCalibre(String id, CalibreMetadata m) async {
    final book = await _db.getBook(id);
    if (book == null) return;
    final tags = {...book.tags, ...m.tags}.toList();
    await _db.updateBook(
      id,
      BooksCompanion(
        series: book.series == null && m.series != null ? Value(m.series) : const Value.absent(),
        seriesIndex: book.series == null && m.seriesIndex != null ? Value(m.seriesIndex) : const Value.absent(),
        tags: tags.length != book.tags.length ? Value(tags) : const Value.absent(),
        ratingHalves: book.ratingHalves == 0 && m.ratingHalves != null ? Value(m.ratingHalves!) : const Value.absent(),
        description: (book.description ?? '').trim().isEmpty && m.description != null
            ? Value(m.description)
            : const Value.absent(),
      ),
    );
  }

  /// The text of a file the reader picks (a Kindle's My Clippings.txt), or null.
  Future<String?> pickTextFile() => _native.pickTextFile();

  /// Picks a file for [book] and keeps it only if it is that book (same fingerprint).
  Future<bool> linkFile(Book book) async {
    final uris = await _native.pickFiles();
    if (uris.isEmpty) return false;
    final m = await _native.importFile(uris.first);
    if (m['id'] != book.id) {
      // A different book: don't keep its copy unless the library has it.
      if (await _db.getBook(m['id']! as String) == null) {
        for (final path in [m['path'], m['coverPath']].whereType<String>()) {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
      }
      return false;
    }
    await _db.setLocalFields(book.id, BooksCompanion(filePath: Value(m['path'] as String?)));
    return true;
  }

  /// Files already chosen (a watched folder's new books, say).
  Future<ImportProgress> importUris(List<({String uri, String name})> files) => _importAll(files);

  /// The bundled public-domain sample.
  Future<ImportProgress> importSample() async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/alice.epub');
    final data = await rootBundle.load('assets/books/alice.epub');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return _importAll([(uri: Uri.file(file.path).toString(), name: 'alice.epub')]);
  }

  /// A book downloaded from a catalog. Returns its library id.
  Future<String> importDownloaded(File file, {required BookSource source, required String sourceId}) async {
    final uri = Uri.file(file.path).toString();
    final (:id, added: _) = await _importOne(uri, file.uri.pathSegments.last, source: source, sourceId: sourceId);
    if (await file.exists()) await file.delete();
    return id;
  }

  /// A book another app asked to open, if there's one waiting: added to the library (or
  /// found there). Returns its library id.
  Future<String?> importOpenedFile() async {
    final file = await _native.takeOpenedFile();
    if (file == null) return null;
    return (await _importOne(file.uri, file.name)).id;
  }

  Future<ImportProgress> _importAll(List<({String uri, String name})> files) async {
    state = ImportProgress(total: files.length, running: true);
    for (final file in files) {
      state = state.copyWith(current: file.name);
      try {
        final (:added, id: _) = await _importOne(file.uri, file.name);
        state = state.copyWith(
          added: state.added + (added ? 1 : 0),
          duplicates: state.duplicates + (added ? 0 : 1),
        );
      } on PlatformException {
        state = state.copyWith(failed: state.failed + 1);
      }
      state = state.copyWith(done: state.done + 1);
    }
    final finished = state.copyWith(running: false);
    state = finished;
    return finished;
  }

  /// The book's library id, and whether it was added (false if it was already there).
  Future<({bool added, String id})> _importOne(
    String uri,
    String fileName, {
    BookSource source = BookSource.import,
    String? sourceId,
  }) async {
    final m = await _native.importFile(uri);
    final id = m['id']! as String;
    final existing = await _db.getBook(id);
    if (existing != null && !existing.deleted) {
      // A book known from another device: this file is its copy (same fingerprint).
      if (existing.filePath == null || !await File(existing.filePath!).exists()) {
        await _db.setLocalFields(
          id,
          BooksCompanion(
            filePath: Value(m['path'] as String?),
            coverPath: existing.coverPath == null
                ? Value(m['coverPath'] as String?)
                : const Value.absent(),
          ),
        );
      }
      if (sourceId != null && existing.sourceId == null) {
        await _db.updateBook(id, BooksCompanion(source: Value(source), sourceId: Value(sourceId)));
      }
      return (added: false, id: id);
    }

    final title = (m['title'] as String?) ?? _titleFromFileName(fileName);
    final authors = ((m['authors'] as List?) ?? const []).cast<String>();
    final now = DateTime.now();
    await _db.insertBook(
      BooksCompanion.insert(
        id: id,
        title: title,
        authors: authors,
        sortTitle: sortableTitle(title),
        sortAuthor: sortableAuthor(authors),
        language: Value(m['language'] as String?),
        description: Value(m['description'] as String?),
        filePath: Value(m['path'] as String?),
        format: Value(bookFormatOf(m['path'] as String? ?? fileName)),
        fileSize: Value((m['fileSize'] as num?)?.toInt() ?? 0),
        coverPath: Value(m['coverPath'] as String?),
        coverColor: Value((m['coverColor'] as num?)?.toInt()),
        series: Value(m['series'] as String?),
        seriesIndex: Value((m['seriesIndex'] as num?)?.toDouble()),
        source: Value(source),
        sourceId: Value(sourceId),
        addedAt: existing?.addedAt ?? now,
        updatedAt: now,
        // A book removed earlier comes back with its reading history.
        status: Value(existing?.status),
        ratingHalves: Value(existing?.ratingHalves ?? 0),
        favorite: Value(existing?.favorite ?? false),
        progress: Value(existing?.progress ?? 0),
        lastLocator: Value(existing?.lastLocator),
        lastOpenedAt: Value(existing?.lastOpenedAt),
        deleted: const Value(false),
      ),
    );
    return (added: true, id: id);
  }

  /// Removes a book from the library and frees its space on this device.
  Future<void> remove(Book book) async {
    await _db.updateBook(book.id, const BooksCompanion(deleted: Value(true)));
    for (final path in [book.filePath, book.coverPath]) {
      if (path == null) continue;
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  static String _nameOf(String uri) {
    final decoded = Uri.decodeFull(uri);
    final slash = decoded.lastIndexOf(RegExp(r'[/:]'));
    return slash < 0 ? decoded : decoded.substring(slash + 1);
  }

  static String _titleFromFileName(String name) => name
      .replaceAll(RegExp(r'\.(epub|pdf|cbz)$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[_]+'), ' ')
      .trim();
}

final libraryImporterProvider = NotifierProvider<LibraryImporter, ImportProgress>(
  LibraryImporter.new,
);

/// "The Hobbit" sorts under H.
String sortableTitle(String title) =>
    title.trim().toLowerCase().replaceFirst(RegExp(r'^(the|a|an)\s+'), '');

/// Surname first ("tolkien, j. r. r."), taking the last word as the surname; names already
/// written surname-first keep their order.
String sortableAuthor(List<String> authors) {
  if (authors.isEmpty) return '\u{FFFF}';
  final name = authors.first.trim().toLowerCase();
  if (name.contains(',')) return name;
  final parts = name.split(RegExp(r'\s+'));
  if (parts.length < 2) return name;
  return '${parts.last}, ${parts.sublist(0, parts.length - 1).join(' ')}';
}
