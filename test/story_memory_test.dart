import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/companion/book_memory.dart';
import 'package:marginalia/companion/explain.dart';
import 'package:marginalia/companion/story_memory.dart';

void main() {
  const sections = [
    StoryChapter(key: 0, index: 1, number: 1, title: 'Down the Rabbit-Hole'),
    StoryChapter(key: 1, index: 2, number: 2, title: 'The Pool of Tears'),
    StoryChapter(key: 2, index: 3, number: 3, title: 'A Caucus-Race'),
  ];

  test('the story carries on chapter by chapter; who’s who is written for the last', () async {
    final dir = await Directory.systemTemp.createTemp('story');
    final paragraphs = <KeptParagraph>[
      (chapter: 1, progression: 0.1, text: 'Alice was tired. Then Alice saw a White Rabbit run by.'),
      (chapter: 2, progression: 0.1, text: 'Alice cried a pool of tears. The Mouse swam past Alice.'),
      (chapter: 2, progression: 0.5, text: 'Alice spoke to the Mouse about her cat. Alice frightened the Mouse.'),
    ];
    final prompts = <String>[];
    await catchUpStories(
      dir: dir.path,
      title: 'Alice',
      sections: sections,
      paragraphs: paragraphs,
      placed: const [0, 1, 1],
      finished: const {0, 1},
      summaries: const {0: 'Alice follows a White Rabbit down a hole.', 1: 'Alice cries a pool of tears and meets the Mouse.'},
      generate: (prompt, _) async {
        prompts.add(prompt);
        return prompt.contains('who') && prompt.contains('Alice is')
            ? 'Alice is a curious girl who fell down a rabbit hole.'
            : 'Story through ${prompts.length}.';
      },
    );
    final stories = await readStories(dir.path);
    expect(stories.keys, {0, 1});
    expect(stories[0]!.story, 'Story through 1.');
    // The second chapter's story is written from the first's.
    expect(prompts[1], contains('Story through 1.'));
    expect(stories[1]!.people.keys, contains('Alice'));
    // Nothing from the chapter not yet finished went in.
    expect(prompts.join(), isNot(contains('Caucus')));
    await dir.delete(recursive: true);
  });

  test('at the page, the snapshot of the last chapter finished before it', () {
    final stories = {
      0: const StorySnapshot(story: 'one'),
      2: const StorySnapshot(story: 'three'),
    };
    expect(storyBefore(stories, sections.take(2))?.story, 'one');
    expect(storyBefore(stories, sections)?.story, 'three');
    expect(storyBefore(stories, const []), isNull);
  });

  test('a profile is found by any of the name’s words', () {
    const s = StorySnapshot(story: '', people: {'Mr. Darcy': 'Proud.'});
    expect(s.profileOf('mr. darcy'), 'Proud.');
    expect(s.profileOf('Darcy'), 'Proud.');
    expect(s.profileOf('Bingley'), isNull);
  });

  test('snapshots survive a save and load', () async {
    final dir = await Directory.systemTemp.createTemp('story');
    await writeStories(dir.path, {4: const StorySnapshot(story: 'So far.', people: {'Emma': 'Clever.'})});
    expect(jsonDecode(File('${dir.path}/story.json').readAsStringSync()), {
      '4': {'s': 'So far.', 'p': {'Emma': 'Clever.'}},
    });
    expect((await readStories(dir.path))[4]!.people['Emma'], 'Clever.');
    await dir.delete(recursive: true);
  });

  test('explaining a passage gives the model what’s around it and the story so far, and no more', () {
    final prompt = explainPrompt(
      title: 'Pride and Prejudice',
      selected: 'entailed',
      paragraph: 'Mr. Bennet’s property was entailed, in default of heirs male, on a distant relation.',
      story: 'The Bennets have five daughters and no son.',
    );
    expect(prompt, contains('"entailed"'));
    expect(prompt, contains('in default of heirs male'));
    expect(prompt, contains('five daughters'));
    expect(prompt, contains('Never mention or hint at anything that happens later'));
  });
}
