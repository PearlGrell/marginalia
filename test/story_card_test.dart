import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/share/story_card.dart';

void main() {
  Future<void> pumpCard(WidgetTester tester, String quote, {String? note, StoryStyle style = StoryStyle.paper}) =>
      tester.pumpWidget(
        MaterialApp(
          // As in the share sheet: scaled to fit, laid out at its own 360 × 640.
          home: FittedBox(
            child: StoryCard(
              style: style,
              content: StoryContent(
                quote: quote,
                note: note,
                title: "Alice's Adventures in Wonderland",
                author: 'Lewis Carroll',
                accent: const Color(0xFFF2D46B),
                coverColor: const Color(0xFF2F4A3A),
              ),
            ),
          ),
        ),
      );

  testWidgets('a short quote fits the card', (tester) async {
    await pumpCard(tester, 'Curiouser and curiouser!');
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(StoryCard)), const Size(360, 640));
  });

  testWidgets('a long passage with a note still fits, in every style', (tester) async {
    final long = List.filled(18, 'Alice was beginning to get very tired of sitting by her sister.').join(' ');
    for (final style in StoryStyle.values) {
      await pumpCard(tester, long, note: 'This is the whole book in a sentence. ' * 6, style: style);
      expect(tester.takeException(), isNull, reason: style.name);
    }
  });
}
