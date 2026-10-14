import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/data/database.dart';
import 'package:marginalia/data/library.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> add(
    String id, {
    double progress = 0,
    ReadingStatus? status,
    String? series,
    List<String> tags = const [],
    DateTime? addedAt,
  }) => db.insertBook(
    BooksCompanion.insert(
      id: id,
      title: id,
      authors: const ['A'],
      sortTitle: sortableTitle(id),
      sortAuthor: 'a',
      addedAt: addedAt ?? DateTime(2020),
      updatedAt: DateTime(2020),
      progress: Value(progress),
      status: Value(status),
      series: Value(series),
      tags: Value(tags),
    ),
  );

  Future<Set<String>> ids(LibraryQuery q) async => {for (final b in await db.watchBooks(q).first) b.id};

  test('smart shelves', () async {
    await add('almost', progress: 0.8, status: ReadingStatus.reading);
    await add('done', progress: 1, status: ReadingStatus.finished);
    await add('fresh', addedAt: DateTime.now());
    await add('untouched');
    await add('wanted', status: ReadingStatus.wantToRead);
    await add('series1', series: 'Discworld', status: ReadingStatus.finished, progress: 1);
    await add('series2', series: 'Discworld');
    await add('otherSeries', series: 'Unread series');

    expect(await ids(const LibraryQuery(shelf: SmartShelf.almostFinished)), {'almost'});
    expect(
      await ids(const LibraryQuery(shelf: SmartShelf.notStarted)),
      {'fresh', 'untouched', 'wanted', 'series2', 'otherSeries'},
    );
    expect(await ids(const LibraryQuery(shelf: SmartShelf.recentlyAdded)), {'fresh'});
    expect(await ids(const LibraryQuery(shelf: SmartShelf.seriesInProgress)), {'series2'});
  });

  test('tags filter and list, most used first', () async {
    await add('a', tags: ['comfort', 'to lend']);
    await add('b', tags: ['comfort']);
    await add('c', tags: ['comfortable']);
    expect(await ids(const LibraryQuery(tag: 'comfort')), {'a', 'b'});
    expect(await db.watchTags().first, ['comfort', 'comfortable', 'to lend']);
  });

  test('a book with no status still counts for Continue reading', () async {
    await add('x');
    await db.updateBook('x', BooksCompanion(lastReadAt: Value(DateTime.now())));
    expect((await db.watchContinueReading().first)?.id, 'x');
  });

  test('sessions and words are stored, due words come back in order', () async {
    final now = DateTime.now();
    await db.saveSession(
      ReadingSessionsCompanion.insert(
        id: 's1',
        bookId: 'a',
        startedAt: now.subtract(const Duration(minutes: 20)),
        endedAt: now,
        seconds: 1200,
        updatedAt: now,
      ),
    );
    expect((await db.allSessions()).single.seconds, 1200);
    expect((await db.dirtySessions()).length, 1);

    for (final (id, due) in [('en:b', now.subtract(const Duration(days: 1))), ('en:a', now.subtract(const Duration(days: 3))), ('en:c', now.add(const Duration(days: 2)))]) {
      await db.saveWord(
        WordsCompanion.insert(id: id, word: id.substring(3), createdAt: now, dueAt: due, updatedAt: now),
      );
    }
    expect([for (final w in await db.dueWords(now)) w.id], ['en:a', 'en:b']);
    await db.deleteWord('en:a');
    expect([for (final w in await db.dueWords(now)) w.id], ['en:b']);
  });

  test('old sittings move to ids named by book, pages and time, and copies become one', () async {
    final start = DateTime.utc(2026, 10, 1, 8);
    ReadingSessionsCompanion sitting(String id, int seconds) => ReadingSessionsCompanion.insert(
      id: id,
      bookId: 'b',
      startedAt: start,
      endedAt: start.add(Duration(seconds: seconds)),
      seconds: seconds,
      updatedAt: start,
    );
    // Saved twice under random ids (older versions), and once in the earlier id form with
    // pages only in its id.
    await db.saveSession(sitting('k3x9', 1200));
    await db.saveSession(sitting('k3xa', 1200));
    await db.saveSession(
      sitting('b(pg-4-9)(20261001T090000Z)', 600).copyWith(
        startedAt: Value(start.add(const Duration(hours: 1))),
        endedAt: Value(start.add(const Duration(hours: 1, minutes: 10))),
      ),
    );

    await db.normalizeSessions();
    final live = {for (final s in await db.allSessions()) s.id: s};
    expect(live.keys, {'(b)(page-?-?)(20261001T080000Z)', '(b)(page-4-9)(20261001T090000Z)'});
    expect(live['(b)(page-4-9)(20261001T090000Z)']!.startPosition, 4);
    expect(live['(b)(page-4-9)(20261001T090000Z)']!.endPosition, 9);
    // The old records are deleted rather than removed, so the move syncs; all of it is sent.
    final dirty = {for (final s in await db.dirtySessions()) s.id: s.deleted};
    expect(dirty['k3x9'], isTrue);
    expect(dirty['k3xa'], isTrue);
    expect(dirty['b(pg-4-9)(20261001T090000Z)'], isTrue);
    expect(dirty['(b)(page-?-?)(20261001T080000Z)'], isFalse);

    // Running again changes nothing.
    await db.markSent(sentBooks: const [], sentCollections: const [], sentLinks: const [], sentAnnotations: const [], sentSessions: await db.dirtySessions());
    await db.normalizeSessions();
    expect(await db.dirtySessions(), isEmpty);
  });

  test('upgrading keeps old sittings under their new ids, and learns each book’s format', () async {
    await db.close();
    final start = DateTime.utc(2026, 10, 1, 8).millisecondsSinceEpoch ~/ 1000;
    db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          // The sessions table as version 6 had it, with one sitting.
          raw.execute('''
            CREATE TABLE reading_sessions (
              id TEXT NOT NULL PRIMARY KEY, book_id TEXT NOT NULL, device_name TEXT,
              started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL, seconds INTEGER NOT NULL,
              pages INTEGER NOT NULL DEFAULT 0, start_progress REAL, end_progress REAL,
              updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
              dirty INTEGER NOT NULL DEFAULT 1)''');
          raw.execute(
            "INSERT INTO reading_sessions (id, book_id, started_at, ended_at, seconds, updated_at, dirty) "
            "VALUES ('k3x9', 'b', $start, ${start + 600}, 600, $start, 0)",
          );
          // Books as far as the later steps touch them.
          raw.execute('CREATE TABLE books (id TEXT NOT NULL PRIMARY KEY, file_path TEXT)');
          raw.execute("INSERT INTO books VALUES ('e', '/lib/e.epub'), ('p', '/lib/p.PDF'), ('c', '/lib/c.cbz')");
          raw.execute('PRAGMA user_version = 6');
        },
      ),
    );
    final live = await db.allSessions();
    expect([for (final s in live) s.id], ['(b)(page-?-?)(20261001T080000Z)']);
    expect(live.single.seconds, 600);
    // Each book's format comes from its file.
    final formats = await db.customSelect('SELECT id, format FROM books ORDER BY id').get();
    expect({for (final r in formats) r.read<String>('id'): r.read<String>('format')}, {'c': 'cbz', 'e': 'epub', 'p': 'pdf'});
  });
}
