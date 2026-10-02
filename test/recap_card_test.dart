import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/data/database.dart';
import 'package:marginalia/stats/reading_stats.dart';
import 'package:marginalia/stats/recap_card.dart';

void main() {
  Book book(String id, {DateTime? finished}) => Book(
    id: id,
    title: 'A rather long book title number $id',
    authors: const ['Someone'],
    sortTitle: id,
    sortAuthor: 's',
    fileSize: 0,
    source: BookSource.import,
    tags: const [],
    ratingHalves: 0,
    favorite: false,
    progress: finished == null ? 0.4 : 1,
    status: finished == null ? ReadingStatus.reading : ReadingStatus.finished,
    finishedAt: finished,
    coverColor: 0xFF2F4A3A,
    addedAt: DateTime(2026),
    updatedAt: DateTime(2026),
    deleted: false,
    dirty: false,
  );

  testWidgets('a recap of a busy month fits the card, in both styles', (tester) async {
    final now = DateTime(2026, 10, 28);
    final books = {for (var i = 0; i < 7; i++) '$i': book('$i', finished: i < 3 ? DateTime(2026, 10, 3 + i) : null)};
    final sessions = [
      for (var d = 1; d <= 28; d++)
        ReadingSession(
          id: '$d',
          bookId: '${d % 7}',
          startedAt: DateTime(2026, 10, d, 21),
          endedAt: DateTime(2026, 10, d, 22),
          seconds: 1800 + d * 60,
          pages: 30,
          updatedAt: now,
          deleted: false,
          dirty: false,
        ),
    ];
    final stats = ReadingStats.of(sessions, books.values.toList(), StatsPeriod.month(now), now: now);
    expect(stats.currentStreak, 28);
    for (final style in RecapStyle.values) {
      await tester.pumpWidget(
        MaterialApp(home: FittedBox(child: RecapCard(stats: stats, books: books, style: style, now: now))),
      );
      expect(tester.takeException(), isNull, reason: style.name);
      expect(tester.getSize(find.byType(RecapCard)), const Size(360, 640));
    }
  });
}
