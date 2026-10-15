import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/companion/companion.dart';

void main() {
  final book = <Paragraph>[
    (chapter: 1, text: 'Miss Brooke had that kind of beauty which seems to be thrown into relief by poor dress. Her sister Celia was more worldly.'),
    (chapter: 1, text: 'Dorothea knew many passages of Pascal by heart. Celia laughed at her for it.'),
    (chapter: 2, text: 'Mr. Casaubon came to dinner at Tipton Grange. He was a scholar, writing a Key to All Mythologies.'),
    (chapter: 2, text: 'Dorothea listened to Mr. Casaubon with growing admiration. The Key to All Mythologies seemed to her a noble work.'),
    (chapter: 3, text: 'Sir James Chettam rode over to see Dorothea, but she spoke only of the Key to All Mythologies and its author.'),
    (chapter: 3, text: 'Celia guessed before anyone that Dorothea would marry Mr. Casaubon, and said so to Sir James.'),
  ];

  test('sentences split after their ends, quotes and all', () {
    expect(sentencesOf('He came. “Who?” she asked. Nobody knew!'), ['He came.', '“Who?” she asked.', 'Nobody knew!']);
  });

  test('a recap takes its sentences from the latest chapters, in order', () {
    final recap = recapSentences(book, chapters: 2, count: 3);
    expect(recap, hasLength(3));
    expect(recap.every((s) => !s.contains('Pascal') && !s.contains('beauty')), isTrue);
    final positions = [for (final s in recap) book.indexWhere((p) => p.text.contains(s))];
    expect(positions, orderedEquals([...positions]..sort()));
  });

  test('answers lose a lead-in and a sentence left unfinished', () {
    expect(
      tidyAnswer("Here's a three-to-five-sentence recap: Alice follows the Rabbit. She falls a long way. Then she"),
      'Alice follows the Rabbit. She falls a long way.',
    );
    expect(tidyAnswer('Celia is Dorothea’s younger sister.'), 'Celia is Dorothea’s younger sister.');
    // Nothing to keep after trimming: the answer as it came.
    expect(tidyAnswer('Celia is'), 'Celia is');
  });
}
