import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/data/database.dart';
import 'package:marginalia/data/library.dart';
import 'package:marginalia/dictionary/dictionary.dart';
import 'package:marginalia/reader/dictionary_sheet.dart';
import 'package:marginalia/theme/app_theme.dart';
import 'package:sqlite3/sqlite3.dart';

/// A dictionary of two words, the first defined by the second.
Dictionary twoWords() {
  final db = sqlite3.openInMemory()
    ..execute('''
      CREATE TABLE entries (id INTEGER PRIMARY KEY, lemma TEXT NOT NULL, pos TEXT NOT NULL);
      CREATE TABLE forms (form TEXT NOT NULL, entry INTEGER NOT NULL);
      CREATE TABLE senses (entry INTEGER NOT NULL, rank INTEGER NOT NULL, synset INTEGER NOT NULL);
      CREATE TABLE synsets (id INTEGER PRIMARY KEY, definition TEXT NOT NULL, examples TEXT);
      INSERT INTO entries VALUES (1, 'ephemeral', 'a'), (2, 'brief', 'a');
      INSERT INTO forms VALUES ('ephemeral', 1), ('brief', 2);
      INSERT INTO senses VALUES (1, 0, 10), (2, 0, 20);
      INSERT INTO synsets VALUES (10, 'brief', NULL), (20, 'of short duration', NULL);
    ''');
  return Dictionary.over(db);
}

void main() {
  testWidgets('a word in a meaning looks itself up, and back returns', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final dictionary = twoWords();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          dictionaryProvider.overrideWith((ref) async => dictionary),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDefinitionSheet(context, 'ephemeral', language: 'en'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('ephemeral'), findsOneWidget);

    // Tap "brief" in the meaning: it's looked up in the same sheet.
    await tester.tap(find.text('brief'));
    await tester.pumpAndSettle();
    expect(find.text('of short duration'), findsOneWidget);
    expect(find.text('from “ephemeral”'), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);

    // System back returns to the first word rather than closing the sheet.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('ephemeral'), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);

    // And then closes it.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await db.close();
    dictionary.close();
  });
}
