import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/companion/book_memory.dart';
import 'package:marginalia/companion/people.dart';
import 'package:marginalia/companion/previously.dart';
import 'package:marginalia/companion/retrieval.dart';

Person _person(String name, List<int> byChapter, int first) => Person(
  name: name,
  mentions: byChapter.fold(0, (a, b) => a + b),
  byChapter: byChapter,
  firstSeen: Chunk(index: 0, chapter: first, text: ''),
  firstSentence: '',
);

void main() {
  test('the reminder tells the last chapter by its summary, then the chapter so far', () async {
    final dir = await Directory.systemTemp.createTemp('book');
    File('${dir.path}/state.json').writeAsStringSync(jsonEncode({
      'chapters': [
        {'i': 1, 'n': 1, 't': 'Down the Rabbit-Hole'},
        {'i': 2, 'n': 2, 't': 'The Pool of Tears'},
      ],
    }));
    File('${dir.path}/text.jsonl').writeAsStringSync([
      {'c': 1, 'p': 0.2, 't': 'Alice was beginning to get very tired of sitting by her sister on the bank.'},
      {'c': 2, 'p': 0.3, 't': 'Alice swam about in the pool of tears she had wept, with the Mouse beside her.'},
    ].map(jsonEncode).join('\n'));
    File('${dir.path}/section-summaries.json').writeAsStringSync(jsonEncode({'0': 'Alice follows a White Rabbit down a hole.'}));
    final data = await buildBookData(dir.path, (chapter: 2, progression: 0.5), 'Alice', null);

    final previously = previouslyOn(data)!;
    expect(previously.heading, 'Previously in Alice');
    expect(previously.text, startsWith('Alice follows a White Rabbit down a hole.'));
    expect(previously.text, contains('Then: Alice swam about in the pool of tears'));
    await dir.delete(recursive: true);
  });

  test('nothing kept, nothing to remind', () async {
    final dir = await Directory.systemTemp.createTemp('book');
    final data = await buildBookData(dir.path, (chapter: 0, progression: 0), 'Alice', null);
    expect(previouslyOn(data), isNull);
    await dir.delete(recursive: true);
  });

  test('a chapter’s cast, most named first, and who first comes in there', () {
    final people = [
      _person('Alice', [5, 9, 2], 1),
      _person('Mouse', [0, 4, 0], 2),
      _person('Dodo', [0, 0, 6], 3),
    ];
    expect(chapterCast(people, 2), ['Alice', 'Mouse']);
    expect(chapterCast(people, 3), ['Dodo', 'Alice']);
    expect(firstAppearances(people, 2), ['Mouse']);
    expect(chapterCast(people, 9), isEmpty);
  });
}
