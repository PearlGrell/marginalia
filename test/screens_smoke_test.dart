import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/data/database.dart';
import 'package:marginalia/data/library.dart';
import 'package:marginalia/library/watched_folders.dart';
import 'package:marginalia/notes/notes_screen.dart';
import 'package:marginalia/reader/custom_theme_screen.dart';
import 'package:marginalia/reader/reader_sheets.dart';
import 'package:marginalia/stats/stats_screen.dart';
import 'package:marginalia/storage/local_store.dart';
import 'package:marginalia/theme/app_theme.dart';
import 'package:marginalia/words/review_screen.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// The new screens build with real data and without layout errors, on a phone-sized screen.
void main() {
  late AppDatabase db;
  late LocalStore store;

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    store = await LocalStore.open();
    db = AppDatabase(NativeDatabase.memory());
    final now = DateTime.now();
    await db.insertBook(
      BooksCompanion.insert(
        id: 'b1',
        title: 'Middlemarch',
        authors: const ['George Eliot'],
        sortTitle: 'middlemarch',
        sortAuthor: 'eliot, george',
        addedAt: now,
        updatedAt: now,
        coverColor: const Value(0xFF2F4A3A),
        progress: const Value(0.42),
        tags: const Value(['classics']),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await db.saveAnnotation(
        AnnotationsCompanion.insert(
          id: 'a$i',
          bookId: 'b1',
          type: i == 0 ? AnnotationType.note : AnnotationType.highlight,
          locator: '{"href":"c1.xhtml","type":"application/xhtml+xml"}',
          selectedText: Value('A passage that matters, number $i, long enough to wrap onto a second line.'),
          note: Value(i == 0 ? 'Worth coming back to.' : null),
          color: const Value('green'),
          chapterTitle: const Value('Prelude'),
          progression: Value(0.1 * i),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    for (var d = 0; d < 10; d++) {
      final start = now.subtract(Duration(days: d, hours: 1));
      await db.saveSession(
        ReadingSessionsCompanion.insert(
          id: 's$d',
          bookId: 'b1',
          startedAt: start,
          endedAt: start.add(const Duration(minutes: 30)),
          seconds: 1500,
          updatedAt: now,
          pages: const Value(25),
        ),
      );
    }
    await db.saveWord(
      WordsCompanion.insert(
        id: 'en:ardent',
        word: 'ardent',
        createdAt: now,
        dueAt: now.subtract(const Duration(hours: 1)),
        updatedAt: now,
        partOfSpeech: const Value('adjective'),
        definition: const Value('characterized by intense emotion'),
        context: const Value('Her ardent nature turned all her small allowance of knowledge into principle.'),
      ),
    );
  });

  tearDown(() async => db.close());

  Future<void> show(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          localStoreProvider.overrideWithValue(store),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: screen),
      ),
    );
    // Let the database streams deliver.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
  }

  // Drift's streams clean up on timers: unmount and let them run before the test ends.
  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('Notes: highlights across books, and the word list', (tester) async {
    await show(tester, const NotesScreen());
    expect(find.text('Middlemarch'), findsWidgets);
    expect(find.text('Worth coming back to.'), findsOneWidget);
    await tester.tap(find.text('Words'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('ardent'), findsOneWidget);
    expect(find.text('1 word to review'), findsOneWidget);
    await done(tester);
  });

  testWidgets('Stats: this month, then this week', (tester) async {
    await show(tester, const StatsScreen());
    expect(find.textContaining('days'), findsWidgets);
    await tester.tap(find.text('This week'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.text('Middlemarch'), findsWidgets);
    await done(tester);
  });

  testWidgets('Review: a card, turned', (tester) async {
    await show(tester, const ReviewScreen());
    expect(find.text('ardent'), findsOneWidget);
    await tester.tap(find.text('Show meaning'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.text('Good'), findsOneWidget);
    await done(tester);
  });

  testWidgets('Reading settings and the custom page', (tester) async {
    await show(tester, const Scaffold(body: ReaderSettingsList(inSheet: false, coverColor: Color(0xFF2F4A3A))));
    expect(find.text('Cover'), findsOneWidget);
    expect(find.text('Two pages side by side'), findsOneWidget);
    await show(tester, const CustomThemeScreen());
    expect(find.textContaining('Contrast'), findsOneWidget);
    await done(tester);
  });

  testWidgets('Watched folders, empty', (tester) async {
    await show(tester, const WatchedFoldersScreen());
    expect(find.text('Watch a folder'), findsOneWidget);
    await done(tester);
  });
}
