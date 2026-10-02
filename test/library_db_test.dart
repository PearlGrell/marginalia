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
}
