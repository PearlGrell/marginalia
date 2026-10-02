import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// Where the reader is with a book.
enum ReadingStatus {
  wantToRead('Want to read'),
  reading('Reading'),
  finished('Finished'),
  abandoned('Abandoned');

  const ReadingStatus(this.label);

  final String label;
}

/// Where a book came from.
enum BookSource { import, gutenberg, standardebooks, opds, shared }

class StringListConverter extends TypeConverter<List<String>, String> {
  const StringListConverter();

  @override
  List<String> fromSql(String fromDb) => (jsonDecode(fromDb) as List).cast<String>();

  @override
  String toSql(List<String> value) => jsonEncode(value);
}

/// Every record carries `updatedAt` and `deleted` (soft deletes), so sync can merge newest
/// changes per field and spread removals to other devices.
@DataClassName('Book')
class Books extends Table {
  /// SHA-256 of the EPUB file.
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get authors => text().map(const StringListConverter())();

  /// Title without a leading article, lowercased, for sorting.
  TextColumn get sortTitle => text()();

  /// First author's surname first, lowercased, for sorting.
  TextColumn get sortAuthor => text()();
  TextColumn get language => text().nullable()();
  TextColumn get description => text().nullable()();

  /// The EPUB on this device, if it is here.
  TextColumn get filePath => text().nullable()();
  IntColumn get fileSize => integer().withDefault(const Constant(0))();
  TextColumn get coverPath => text().nullable()();

  /// The EPUB and cover in the user's Google Drive app folder, once uploaded.
  TextColumn get driveFileId => text().nullable()();
  TextColumn get driveCoverId => text().nullable()();

  /// ARGB tint picked from the cover.
  IntColumn get coverColor => integer().nullable()();
  TextColumn get source => textEnum<BookSource>().withDefault(Constant(BookSource.import.name))();
  TextColumn get sourceId => text().nullable()();
  TextColumn get series => text().nullable()();
  RealColumn get seriesIndex => real().nullable()();

  /// The reader's own labels ("to lend", "comfort reads").
  TextColumn get tags => text().map(const StringListConverter()).withDefault(const Constant('[]'))();
  TextColumn get status => textEnum<ReadingStatus>().nullable()();

  /// 0 to 10: the rating in half stars.
  IntColumn get ratingHalves => integer().withDefault(const Constant(0))();
  BoolColumn get favorite => boolean().withDefault(const Constant(false))();

  /// Through the whole book, 0 to 1.
  RealColumn get progress => real().withDefault(const Constant(0))();

  /// Readium Locator JSON of the last position on this device.
  TextColumn get lastLocator => text().nullable()();
  DateTimeColumn get addedAt => dateTime()();
  DateTimeColumn get lastOpenedAt => dateTime().nullable()();

  /// When the book was last read on any of the user's devices (synced), for
  /// "Continue reading". [progress] follows the device that read it last.
  DateTimeColumn get lastReadAt => dateTime().nullable()();
  DateTimeColumn get finishedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  /// Changed on this device and not yet sent. Records from other devices arrive clean, so
  /// sync never sends them back.
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('Collection')
class Collections extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  /// Changed on this device and not yet sent. Records from other devices arrive clean, so
  /// sync never sends them back.
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('BookCollection')
class BookCollections extends Table {
  TextColumn get bookId => text().references(Books, #id)();
  TextColumn get collectionId => text().references(Collections, #id)();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  /// Changed on this device and not yet sent. Records from other devices arrive clean, so
  /// sync never sends them back.
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {bookId, collectionId};
}

enum AnnotationType { highlight, note, bookmark }

/// Highlights, notes and bookmarks. Each has its own id, so ones made on two devices at once
/// all survive a sync; the Readium locator plus the surrounding text lets a highlight be
/// found again if the layout changes.
@DataClassName('Annotation')
class Annotations extends Table {
  TextColumn get id => text()();
  TextColumn get bookId => text().references(Books, #id)();
  TextColumn get type => textEnum<AnnotationType>()();

  /// Readium Locator JSON.
  TextColumn get locator => text()();
  TextColumn get selectedText => text().nullable()();
  TextColumn get textBefore => text().nullable()();
  TextColumn get textAfter => text().nullable()();

  /// A [HighlightColor] name.
  TextColumn get color => text().nullable()();
  TextColumn get note => text().nullable()();
  TextColumn get chapterTitle => text().nullable()();

  /// Through the whole book, 0 to 1, for ordering.
  RealColumn get progression => real().nullable()();

  /// Readium position, for matching bookmarks to pages.
  IntColumn get position => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  /// Changed on this device and not yet sent. Records from other devices arrive clean, so
  /// sync never sends them back.
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// A stretch of reading, for stats and streaks. Recorded per device; every device sees all.
@DataClassName('ReadingSession')
class ReadingSessions extends Table {
  TextColumn get id => text()();
  TextColumn get bookId => text()();
  TextColumn get deviceName => text().nullable()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime()();

  /// Time actually reading: long pauses don't count.
  IntColumn get seconds => integer()();

  /// Pages turned forward (Readium positions, about a page each).
  IntColumn get pages => integer().withDefault(const Constant(0))();
  RealColumn get startProgress => real().nullable()();
  RealColumn get endProgress => real().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// A word saved from Define, with spaced-repetition review state.
@DataClassName('VocabularyWord')
class Words extends Table {
  /// `<language>:<word>`, so saving a word twice keeps one card.
  TextColumn get id => text()();
  TextColumn get word => text()();
  TextColumn get language => text().withDefault(const Constant('en'))();
  TextColumn get partOfSpeech => text().nullable()();
  TextColumn get definition => text().nullable()();

  /// The sentence it was found in.
  TextColumn get context => text().nullable()();
  TextColumn get bookId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  /// When it's next due for review.
  DateTimeColumn get dueAt => dateTime()();
  RealColumn get intervalDays => real().withDefault(const Constant(0))();
  RealColumn get ease => real().withDefault(const Constant(2.5))();
  IntColumn get reps => integer().withDefault(const Constant(0))();
  IntColumn get lapses => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Shelves the library fills by itself.
enum SmartShelf {
  almostFinished('Almost finished'),
  notStarted('Not started'),
  recentlyAdded('Added this month'),
  seriesInProgress('Series to continue');

  const SmartShelf(this.label);

  final String label;
}

enum LibrarySort {
  recent('Recently read'),
  title('Title'),
  author('Author'),
  added('Date added'),
  series('Series'),
  rating('Rating'),
  progress('Progress');

  const LibrarySort(this.label);

  final String label;
}

/// What the library shows.
class LibraryQuery {
  const LibraryQuery({
    this.status,
    this.favoritesOnly = false,
    this.collectionId,
    this.search = '',
    this.sort = LibrarySort.recent,
    this.tag,
    this.shelf,
  });

  final ReadingStatus? status;
  final bool favoritesOnly;
  final String? collectionId;
  final String search;
  final LibrarySort sort;
  final String? tag;
  final SmartShelf? shelf;

  /// Narrowed to some of the books (search aside).
  bool get filtered =>
      status != null || favoritesOnly || collectionId != null || tag != null || shelf != null;

  @override
  bool operator ==(Object other) =>
      other is LibraryQuery &&
      other.status == status &&
      other.favoritesOnly == favoritesOnly &&
      other.collectionId == collectionId &&
      other.search == search &&
      other.sort == sort &&
      other.tag == tag &&
      other.shelf == shelf;

  @override
  int get hashCode => Object.hash(status, favoritesOnly, collectionId, search, sort, tag, shelf);
}

class CollectionWithCount {
  const CollectionWithCount(this.collection, this.count);

  final Collection collection;
  final int count;
}

@DriftDatabase(tables: [Books, Collections, BookCollections, Annotations, ReadingSessions, Words])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? driftDatabase(name: 'marginalia'));

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.createTable(annotations);
      if (from < 3) {
        await m.addColumn(books, books.driveFileId);
        await m.addColumn(books, books.driveCoverId);
      }
      if (from < 4) {
        await m.addColumn(books, books.lastReadAt);
        await customStatement('UPDATE books SET last_read_at = last_opened_at');
      }
      if (from < 5) {
        // Everything counts as changed once, so each device re-sends what it knows (this
        // repairs Drive ids that older builds could overwrite).
        await m.addColumn(books, books.dirty);
        await m.addColumn(collections, collections.dirty);
        await m.addColumn(bookCollections, bookCollections.dirty);
        await m.addColumn(annotations, annotations.dirty);
      }
      if (from < 6) {
        await m.addColumn(books, books.tags);
        await m.createTable(readingSessions);
        await m.createTable(words);
      }
    },
  );

  // ---- Books ----

  Stream<List<Book>> watchBooks(LibraryQuery q) {
    final query = select(books)..where((b) => b.deleted.equals(false));
    if (q.status case final status?) query.where((b) => b.status.equalsValue(status));
    if (q.favoritesOnly) query.where((b) => b.favorite.equals(true));
    if (q.collectionId case final collection?) {
      query.where(
        (b) => b.id.isInQuery(
          selectOnly(bookCollections)
            ..addColumns([bookCollections.bookId])
            ..where(
              bookCollections.collectionId.equals(collection) &
                  bookCollections.deleted.equals(false),
            ),
        ),
      );
    }
    if (q.tag case final tag?) {
      // Tags are stored as a JSON list: match the quoted name.
      query.where((b) => b.tags.like('%${jsonEncode(tag).replaceAll('%', r'\%').replaceAll('_', r'\_')}%'));
    }
    if (q.shelf case final shelf?) {
      Expression<bool> notFinished($BooksTable b) =>
          b.status.isNull() | b.status.equalsValue(ReadingStatus.finished).not();
      switch (shelf) {
        case SmartShelf.almostFinished:
          query.where((b) => b.progress.isBiggerOrEqualValue(0.75) & notFinished(b));
        case SmartShelf.notStarted:
          query.where(
            (b) =>
                b.progress.equals(0) &
                (b.status.isNull() | b.status.equalsValue(ReadingStatus.wantToRead)),
          );
        case SmartShelf.recentlyAdded:
          query.where(
            (b) => b.addedAt.isBiggerOrEqualValue(DateTime.now().subtract(const Duration(days: 30))),
          );
        case SmartShelf.seriesInProgress:
          // Unfinished books in a series where at least one book has been read.
          query.where(
            (b) =>
                b.series.isNotNull() &
                notFinished(b) &
                b.series.isInQuery(
                  selectOnly(books)
                    ..addColumns([books.series])
                    ..where(
                      books.deleted.equals(false) &
                          books.series.isNotNull() &
                          (books.status.equalsValue(ReadingStatus.finished) |
                              books.progress.isBiggerThanValue(0)),
                    ),
                ),
          );
      }
    }
    final search = q.search.trim().toLowerCase();
    if (search.isNotEmpty) {
      final pattern = '%${search.replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      query.where(
        (b) =>
            b.title.lower().like(pattern) |
            b.authors.lower().like(pattern) |
            b.series.lower().like(pattern),
      );
    }
    query.orderBy(switch (q.sort) {
      LibrarySort.recent => [
        (b) => OrderingTerm(expression: b.lastReadAt, mode: OrderingMode.desc, nulls: NullsOrder.last),
        (b) => OrderingTerm.desc(b.addedAt),
      ],
      LibrarySort.title => [(b) => OrderingTerm.asc(b.sortTitle)],
      LibrarySort.author => [(b) => OrderingTerm.asc(b.sortAuthor), (b) => OrderingTerm.asc(b.sortTitle)],
      LibrarySort.added => [(b) => OrderingTerm.desc(b.addedAt)],
      LibrarySort.series => [
        (b) => OrderingTerm(expression: b.series, nulls: NullsOrder.last),
        (b) => OrderingTerm.asc(b.seriesIndex),
        (b) => OrderingTerm.asc(b.sortTitle),
      ],
      LibrarySort.rating => [(b) => OrderingTerm.desc(b.ratingHalves), (b) => OrderingTerm.asc(b.sortTitle)],
      LibrarySort.progress => [(b) => OrderingTerm.desc(b.progress), (b) => OrderingTerm.asc(b.sortTitle)],
    });
    return query.watch();
  }

  /// The book to offer first: the one read most recently, on any device, and not finished.
  Stream<Book?> watchContinueReading() {
    final query = select(books)
      ..where(
        (b) =>
            b.deleted.equals(false) &
            b.lastReadAt.isNotNull() &
            (b.status.isNull() |
                (b.status.equalsValue(ReadingStatus.finished).not() &
                    b.status.equalsValue(ReadingStatus.abandoned).not())),
      )
      ..orderBy([(b) => OrderingTerm.desc(b.lastReadAt)])
      ..limit(1);
    return query.watchSingleOrNull();
  }

  Stream<Book?> watchBook(String id) =>
      (select(books)..where((b) => b.id.equals(id))).watchSingleOrNull();

  Future<Book?> getBook(String id) =>
      (select(books)..where((b) => b.id.equals(id))).getSingleOrNull();

  /// The library's copy of a catalog book, if it has one.
  Future<Book?> findBySource(BookSource source, String sourceId) => (select(books)
        ..where(
          (b) =>
              b.source.equalsValue(source) & b.sourceId.equals(sourceId) & b.deleted.equals(false),
        )
        ..limit(1))
      .getSingleOrNull();

  Stream<Book?> watchBySource(BookSource source, String sourceId) => (select(books)
        ..where(
          (b) =>
              b.source.equalsValue(source) & b.sourceId.equals(sourceId) & b.deleted.equals(false),
        )
        ..limit(1))
      .watchSingleOrNull();

  /// All series names in the library, for suggestions when editing.
  Future<List<String>> seriesNames() async {
    final query = selectOnly(books, distinct: true)
      ..addColumns([books.series])
      ..where(books.series.isNotNull() & books.deleted.equals(false))
      ..orderBy([OrderingTerm.asc(books.series)]);
    return [for (final row in await query.get()) row.read(books.series)!];
  }

  /// Every tag in the library, most used first.
  Stream<List<String>> watchTags() => (select(books)..where((b) => b.deleted.equals(false))).watch().map((list) {
    final counts = <String, int>{};
    for (final b in list) {
      for (final t in b.tags) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    return counts.keys.toList()..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : a.toLowerCase().compareTo(b.toLowerCase());
    });
  });

  Future<void> insertBook(BooksCompanion book) => into(books).insertOnConflictUpdate(book);

  /// A change to sync: stamps the time and marks it to send.
  Future<void> updateBook(String id, BooksCompanion changes) =>
      (update(books)..where((b) => b.id.equals(id))).write(
        changes.copyWith(updatedAt: Value(DateTime.now()), dirty: const Value(true)),
      );

  /// Fields that only concern this device (where its file and cover are): not synced.
  Future<void> setLocalFields(String id, BooksCompanion fields) =>
      (update(books)..where((b) => b.id.equals(id))).write(fields);

  // ---- Annotations ----

  /// A book's highlights, notes and bookmarks in reading order.
  Stream<List<Annotation>> watchAnnotations(String bookId) {
    final query = select(annotations)
      ..where((a) => a.bookId.equals(bookId) & a.deleted.equals(false))
      ..orderBy([
        (a) => OrderingTerm(expression: a.progression, nulls: NullsOrder.last),
        (a) => OrderingTerm.asc(a.createdAt),
      ]);
    return query.watch();
  }

  Future<Annotation?> getAnnotation(String id) =>
      (select(annotations)..where((a) => a.id.equals(id))).getSingleOrNull();

  Future<void> saveAnnotation(AnnotationsCompanion annotation) =>
      into(annotations).insertOnConflictUpdate(
        annotation.copyWith(updatedAt: Value(DateTime.now()), dirty: const Value(true)),
      );

  Future<void> updateAnnotation(String id, AnnotationsCompanion changes) =>
      (update(annotations)..where((a) => a.id.equals(id))).write(
        changes.copyWith(updatedAt: Value(DateTime.now()), dirty: const Value(true)),
      );

  /// Starts a book over: no position, progress or status. With [removeAnnotations], its
  /// highlights, notes and bookmarks go too (soft-deleted, so other devices drop them).
  Future<void> resetReading(String bookId, {required bool removeAnnotations}) =>
      transaction(() async {
    await (update(books)..where((b) => b.id.equals(bookId))).write(
      BooksCompanion(
        progress: const Value(0),
        lastLocator: const Value(null),
        lastOpenedAt: const Value(null),
        lastReadAt: const Value(null),
        status: const Value(null),
        finishedAt: const Value(null),
        updatedAt: Value(DateTime.now()),
        dirty: const Value(true),
      ),
    );
    if (removeAnnotations) {
      await (update(annotations)..where((a) => a.bookId.equals(bookId))).write(
        AnnotationsCompanion(
          deleted: const Value(true),
          updatedAt: Value(DateTime.now()),
          dirty: const Value(true),
        ),
      );
    }
  });

  /// Soft delete, so the removal reaches other devices.
  Future<void> deleteAnnotation(String id) =>
      updateAnnotation(id, const AnnotationsCompanion(deleted: Value(true)));

  // ---- Sync ----

  Future<List<Book>> allBooks() => select(books).get();

  /// Marks every record to send again (a one-time repair after a sync format change).
  Future<void> markAllDirty() => transaction(() async {
    await update(books).write(const BooksCompanion(dirty: Value(true)));
    await update(collections).write(const CollectionsCompanion(dirty: Value(true)));
    await update(bookCollections).write(const BookCollectionsCompanion(dirty: Value(true)));
    await update(annotations).write(const AnnotationsCompanion(dirty: Value(true)));
    await update(readingSessions).write(const ReadingSessionsCompanion(dirty: Value(true)));
    await update(words).write(const WordsCompanion(dirty: Value(true)));
  });

  Future<List<Book>> dirtyBooks() => (select(books)..where((b) => b.dirty.equals(true))).get();

  Future<List<Collection>> dirtyCollections() =>
      (select(collections)..where((c) => c.dirty.equals(true))).get();

  Future<List<BookCollection>> dirtyBookCollections() =>
      (select(bookCollections)..where((c) => c.dirty.equals(true))).get();

  Future<List<Annotation>> dirtyAnnotations() =>
      (select(annotations)..where((a) => a.dirty.equals(true))).get();

  Future<List<ReadingSession>> dirtySessions() =>
      (select(readingSessions)..where((s) => s.dirty.equals(true))).get();

  Future<List<VocabularyWord>> dirtyWords() => (select(words)..where((w) => w.dirty.equals(true))).get();

  /// After sending: clean, unless the record changed again meanwhile.
  Future<void> markSent({
    required Iterable<Book> sentBooks,
    required Iterable<Collection> sentCollections,
    required Iterable<BookCollection> sentLinks,
    required Iterable<Annotation> sentAnnotations,
    Iterable<ReadingSession> sentSessions = const [],
    Iterable<VocabularyWord> sentWords = const [],
  }) => transaction(() async {
    for (final b in sentBooks) {
      await (update(books)..where((t) => t.id.equals(b.id) & t.updatedAt.equals(b.updatedAt)))
          .write(const BooksCompanion(dirty: Value(false)));
    }
    for (final c in sentCollections) {
      await (update(collections)..where((t) => t.id.equals(c.id) & t.updatedAt.equals(c.updatedAt)))
          .write(const CollectionsCompanion(dirty: Value(false)));
    }
    for (final l in sentLinks) {
      await (update(bookCollections)
            ..where(
              (t) =>
                  t.bookId.equals(l.bookId) &
                  t.collectionId.equals(l.collectionId) &
                  t.updatedAt.equals(l.updatedAt),
            ))
          .write(const BookCollectionsCompanion(dirty: Value(false)));
    }
    for (final a in sentAnnotations) {
      await (update(annotations)..where((t) => t.id.equals(a.id) & t.updatedAt.equals(a.updatedAt)))
          .write(const AnnotationsCompanion(dirty: Value(false)));
    }
    for (final s in sentSessions) {
      await (update(readingSessions)..where((t) => t.id.equals(s.id) & t.updatedAt.equals(s.updatedAt)))
          .write(const ReadingSessionsCompanion(dirty: Value(false)));
    }
    for (final w in sentWords) {
      await (update(words)..where((t) => t.id.equals(w.id) & t.updatedAt.equals(w.updatedAt)))
          .write(const WordsCompanion(dirty: Value(false)));
    }
  });

  /// Every book in the library, for the Drive overview.
  Stream<List<Book>> watchAllBooks() => (select(books)
        ..where((b) => b.deleted.equals(false))
        ..orderBy([(b) => OrderingTerm.asc(b.sortTitle)]))
      .watch();

  /// Books here whose file isn't in the cloud yet.
  Future<List<Book>> booksToUpload() => (select(books)
        ..where((b) => b.deleted.equals(false) & b.driveFileId.isNull() & b.filePath.isNotNull())
        ..orderBy([(b) => OrderingTerm.desc(b.lastOpenedAt), (b) => OrderingTerm.desc(b.addedAt)]))
      .get();

  /// Writes a record that came from another device, as it was there (clean: not sent back).
  Future<void> putBook(BooksCompanion book) =>
      into(books).insertOnConflictUpdate(book.copyWith(dirty: const Value(false)));

  Future<void> putCollection(CollectionsCompanion c) =>
      into(collections).insertOnConflictUpdate(c.copyWith(dirty: const Value(false)));

  Future<void> putBookCollection(BookCollectionsCompanion c) =>
      into(bookCollections).insertOnConflictUpdate(c.copyWith(dirty: const Value(false)));

  Future<void> putAnnotation(AnnotationsCompanion a) =>
      into(annotations).insertOnConflictUpdate(a.copyWith(dirty: const Value(false)));

  Future<void> putSession(ReadingSessionsCompanion s) =>
      into(readingSessions).insertOnConflictUpdate(s.copyWith(dirty: const Value(false)));

  Future<void> putWord(WordsCompanion w) => into(words).insertOnConflictUpdate(w.copyWith(dirty: const Value(false)));

  Future<ReadingSession?> getSession(String id) =>
      (select(readingSessions)..where((s) => s.id.equals(id))).getSingleOrNull();

  Future<Collection?> getCollection(String id) =>
      (select(collections)..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<BookCollection?> getBookCollection(String bookId, String collectionId) =>
      (select(bookCollections)
            ..where((c) => c.bookId.equals(bookId) & c.collectionId.equals(collectionId)))
          .getSingleOrNull();

  // ---- Collections ----

  Stream<List<CollectionWithCount>> watchCollections() {
    final count = bookCollections.bookId.count();
    final query = select(collections).join([
      leftOuterJoin(
        bookCollections,
        bookCollections.collectionId.equalsExp(collections.id) &
            bookCollections.deleted.equals(false),
      ),
    ])
      ..where(collections.deleted.equals(false))
      ..addColumns([count])
      ..groupBy([collections.id])
      ..orderBy([OrderingTerm.asc(collections.sortOrder), OrderingTerm.asc(collections.name)]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          CollectionWithCount(row.readTable(collections), row.read(count) ?? 0),
      ],
    );
  }

  Stream<Set<String>> watchCollectionIdsFor(String bookId) {
    final query = select(bookCollections)
      ..where((c) => c.bookId.equals(bookId) & c.deleted.equals(false));
    return query.watch().map((rows) => {for (final r in rows) r.collectionId});
  }

  Future<String> createCollection(String name) async {
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final last = await (selectOnly(collections)..addColumns([collections.sortOrder.max()]))
        .map((r) => r.read(collections.sortOrder.max()))
        .getSingleOrNull();
    await into(collections).insert(
      CollectionsCompanion.insert(
        id: id,
        name: name,
        sortOrder: Value((last ?? 0) + 1),
        updatedAt: DateTime.now(),
      ),
    );
    return id;
  }

  Future<void> renameCollection(String id, String name) =>
      (update(collections)..where((c) => c.id.equals(id))).write(
        CollectionsCompanion(
          name: Value(name),
          updatedAt: Value(DateTime.now()),
          dirty: const Value(true),
        ),
      );

  Future<void> deleteCollection(String id) => transaction(() async {
    final now = DateTime.now();
    await (update(collections)..where((c) => c.id.equals(id))).write(
      CollectionsCompanion(deleted: const Value(true), updatedAt: Value(now), dirty: const Value(true)),
    );
    await (update(bookCollections)..where((c) => c.collectionId.equals(id))).write(
      BookCollectionsCompanion(
        deleted: const Value(true),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  });

  Future<void> setInCollection(String bookId, String collectionId, bool inCollection) =>
      into(bookCollections).insertOnConflictUpdate(
        BookCollectionsCompanion.insert(
          bookId: bookId,
          collectionId: collectionId,
          updatedAt: DateTime.now(),
          deleted: Value(!inCollection),
          dirty: const Value(true),
        ),
      );

  // ---- Reading sessions ----

  Future<void> saveSession(ReadingSessionsCompanion session) => into(readingSessions).insertOnConflictUpdate(
    session.copyWith(updatedAt: Value(DateTime.now()), dirty: const Value(true)),
  );

  /// Sessions that started in [from, to), oldest first.
  Stream<List<ReadingSession>> watchSessions({DateTime? from, DateTime? to}) {
    final query = select(readingSessions)..where((s) => s.deleted.equals(false));
    if (from != null) query.where((s) => s.startedAt.isBiggerOrEqualValue(from));
    if (to != null) query.where((s) => s.startedAt.isSmallerThanValue(to));
    query.orderBy([(s) => OrderingTerm.asc(s.startedAt)]);
    return query.watch();
  }

  Future<List<ReadingSession>> allSessions() =>
      (select(readingSessions)..where((s) => s.deleted.equals(false))).get();

  // ---- Words ----

  Stream<List<VocabularyWord>> watchWords() => (select(words)
        ..where((w) => w.deleted.equals(false))
        ..orderBy([(w) => OrderingTerm.desc(w.createdAt)]))
      .watch();

  /// Words due for review at [now], the longest overdue first.
  Future<List<VocabularyWord>> dueWords(DateTime now) => (select(words)
        ..where((w) => w.deleted.equals(false) & w.dueAt.isSmallerOrEqualValue(now))
        ..orderBy([(w) => OrderingTerm.asc(w.dueAt)]))
      .get();

  Stream<int> watchDueCount() => (select(words)..where((w) => w.deleted.equals(false))).watch().map((list) {
    final now = DateTime.now();
    return list.where((w) => !w.dueAt.isAfter(now)).length;
  });

  Future<VocabularyWord?> getWord(String id) => (select(words)..where((w) => w.id.equals(id))).getSingleOrNull();

  Future<void> saveWord(WordsCompanion word) =>
      into(words).insertOnConflictUpdate(word.copyWith(updatedAt: Value(DateTime.now()), dirty: const Value(true)));

  Future<void> updateWord(String id, WordsCompanion changes) => (update(words)..where((w) => w.id.equals(id))).write(
    changes.copyWith(updatedAt: Value(DateTime.now()), dirty: const Value(true)),
  );

  Future<void> deleteWord(String id) => updateWord(id, const WordsCompanion(deleted: Value(true)));

  // ---- All notes ----

  /// Highlights and notes across every book, newest first.
  Stream<List<Annotation>> watchAllNotes() => (select(annotations)
        ..where(
          (a) => a.deleted.equals(false) & a.type.equalsValue(AnnotationType.bookmark).not(),
        )
        ..orderBy([(a) => OrderingTerm.desc(a.createdAt)]))
      .watch();

  Future<List<Annotation>> notesFor(String bookId) => (select(annotations)
        ..where(
          (a) =>
              a.bookId.equals(bookId) &
              a.deleted.equals(false) &
              a.type.equalsValue(AnnotationType.bookmark).not(),
        )
        ..orderBy([
          (a) => OrderingTerm(expression: a.progression, nulls: NullsOrder.last),
          (a) => OrderingTerm.asc(a.createdAt),
        ]))
      .get();

  Future<List<Collection>> allCollections() =>
      (select(collections)..where((c) => c.deleted.equals(false))).get();

  Future<List<BookCollection>> allBookCollections() =>
      (select(bookCollections)..where((c) => c.deleted.equals(false))).get();

  Future<List<Annotation>> allAnnotations() =>
      (select(annotations)..where((a) => a.deleted.equals(false))).get();

  Future<List<VocabularyWord>> allWords() => (select(words)..where((w) => w.deleted.equals(false))).get();
}
