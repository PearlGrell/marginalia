import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/companion/conversation.dart';
import 'package:marginalia/companion/people.dart';
import 'package:marginalia/companion/retrieval.dart';

void main() {
  final index = BookIndex(const [
    (chapter: 0, text: 'Alice was beginning to get very tired of sitting by her sister on the bank. Then the White Rabbit ran close by her.'),
    (chapter: 0, text: 'Down went Alice after the White Rabbit, never once considering how she was to get out again.'),
    (chapter: 1, text: 'Alas! It was too late to wish that, and Alice cried. Soon the White Rabbit came back, and Alice spoke to it.'),
    (chapter: 1, text: 'She called after the White Rabbit, but Alice could not catch it. Alas, she thought.'),
    (chapter: 2, text: 'The Mouse swam away. Alice called softly after the Mouse, and the Mouse turned round.'),
  ]);

  test('people are the names said mid-sentence, most named first, with where they come up', () {
    final people = peopleIn(index);
    expect(people.map((p) => p.name), containsAllInOrder(['Alice', 'White Rabbit']));
    expect(people.map((p) => p.name), contains('Mouse'));
    // "Alas" starts sentences but isn't anyone; "Rabbit" is the White Rabbit.
    expect(people.map((p) => p.name), isNot(contains('Alas')));
    expect(people.map((p) => p.name), isNot(contains('Rabbit')));
    final rabbit = people.firstWhere((p) => p.name == 'White Rabbit');
    expect(rabbit.byChapter, [2, 2, 0]);
    expect(rabbit.firstSeen.chapter, 1);
  });

  test('questions come out of a reply however it lays them out', () {
    // As Gemma wrote them on the phone: a markdown table.
    const reply = '| Question |\n|---|\n| Why did Alice fall down an incredibly deep well? |\n'
        '| What did Alice’s brother say about mice? |\n| How did Alice’s brother’s Latin Grammar help her?';
    expect(parseQuestions(reply), [
      'Why did Alice fall down an incredibly deep well?',
      'What did Alice’s brother say about mice?',
      'How did Alice’s brother’s Latin Grammar help her?',
    ]);
    expect(parseQuestions('1. **Why did the Mouse swim away?**\n2) Who is Dinah? Alice’s cat.'), [
      'Why did the Mouse swim away?',
      'Who is Dinah?',
    ]);
  });

  test('contractions and titles aren’t people; a possessive is the person', () {
    final index = BookIndex(const [
      (chapter: 0, text: '“I’m late,” said the Rabbit. Alice thought, “I’ll follow it,” and so Alice did.'),
      (chapter: 0, text: 'Then Alice’s sister called. “I’m here,” said Alice, but Alice’s sister had gone.'),
      (chapter: 1, text: 'Alice’s Adventures went on. “I’ve no idea,” said Alice to the Mouse, and the Mouse sniffed.'),
      (chapter: 1, text: 'The Mouse sniffed again. “I’ll tell you,” said the Mouse, and Alice listened to the Mouse.'),
    ]);
    final names = peopleIn(index).map((p) => p.name).toList();
    expect(names, containsAll(['Alice', 'Mouse']));
    expect(names.where((n) => n.contains("'") || n.contains('’') || n.startsWith('I')), isEmpty);
    final alice = peopleIn(index).firstWhere((p) => p.name == 'Alice');
    expect(alice.firstSentence, startsWith('Alice thought'));
  });
}
