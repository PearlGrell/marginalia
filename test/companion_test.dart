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

  test('a name’s first and latest mentions, as a whole word', () {
    final celia = mentionsOf('celia', book, first: 1, latest: 1);
    expect(celia.count, 3);
    expect(celia.first.single, startsWith('Her sister Celia'));
    expect(celia.latest.single, startsWith('Celia guessed'));
    // Part of another word isn't a mention.
    expect(mentionsOf('Dor', book).none, isTrue);
  });

  test('a recap takes its sentences from the latest chapters, in order', () {
    final recap = recapSentences(book, chapters: 2, count: 3);
    expect(recap, hasLength(3));
    expect(recap.every((s) => !s.contains('Pascal') && !s.contains('beauty')), isTrue);
    final positions = [for (final s in recap) book.indexWhere((p) => p.text.contains(s))];
    expect(positions, orderedEquals([...positions]..sort()));
  });

  test('prompts carry only the passages, and ask for nothing beyond them', () {
    final prompt = whoPrompt('Celia', 'Middlemarch', mentionsOf('Celia', book));
    expect(prompt, contains('Middlemarch'));
    expect(prompt, contains('- Her sister Celia was more worldly.'));
    expect(prompt, contains('say nothing about anything later in the book'));
    expect(prompt, isNot(contains('Pascal by heart')));
  });
}
