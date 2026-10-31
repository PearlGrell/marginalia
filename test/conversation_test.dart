import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marginalia/companion/book_memory.dart';
import 'package:marginalia/companion/conversation.dart';
import 'package:marginalia/companion/retrieval.dart';
import 'package:marginalia/readium/readium.dart';

/// A model that writes [replies] in turn (in two pieces, as a real one streams), keeping the
/// prompts it was given; [full] says which follow-ups find the conversation full. [once] gives
/// [aside].
class _Scripted implements CompanionModel {
  _Scripted(this.replies, {this.full = const {}, this.aside});

  final List<String> replies;
  final Set<int> full;
  final String? aside;
  final prompts = <(String, bool)>[];
  var _calls = 0;

  @override
  bool get remembers => true;

  @override
  int get freshChars => 3000;

  @override
  int get followUpChars => 1000;

  @override
  Stream<String> write(String prompt, {required bool fresh, required int maxTokens}) async* {
    final call = _calls++;
    prompts.add((prompt, fresh));
    if (!fresh && full.contains(call)) throw const ConversationFull();
    final reply = replies.removeAt(0);
    yield reply.substring(0, reply.length ~/ 2);
    yield reply;
  }

  @override
  Future<String?> once(String prompt, {required int maxTokens}) async {
    prompts.add((prompt, true));
    return aside;
  }

  @override
  Future<void> cancel() async {}
}

void main() {
  final book = BookSoFar(
    title: 'Middlemarch',
    authors: 'George Eliot',
    paragraphs: const [
      (chapter: 0, text: 'Miss Brooke had that kind of beauty which seems to be thrown into relief by poor dress. Her sister Celia was more worldly, and the two lived with their uncle at Tipton Grange.'),
      (chapter: 0, text: 'Dorothea knew many passages of Pascal by heart. Celia laughed at her for it, and thought her sister too fond of renouncing things.'),
      (chapter: 1, text: 'Mr. Casaubon came to dinner at Tipton Grange. He was a scholar, writing a Key to All Mythologies, and he spoke of it at length.'),
      (chapter: 1, text: 'Dorothea listened to Mr. Casaubon with growing admiration. The Key to All Mythologies seemed to her a noble work, and its author a great soul.'),
      (chapter: 2, text: 'Sir James Chettam rode over to see Dorothea, but she spoke only of the Key to All Mythologies and its author, and Sir James went home puzzled.'),
      (chapter: 2, text: 'Celia guessed before anyone that Dorothea would marry Mr. Casaubon, and said so to Sir James, who would not believe it.'),
    ],
  );

  test('the book is searched as a whole, best passage first, words not parts of words', () {
    expect(book.index.search('mythologies scholar').first.text, contains('He was a scholar'));
    expect(book.index.search('Dor'), isEmpty);
    expect(book.index.mentioning('Sir James').map((c) => c.chapter).toSet(), {3});
    expect(searchTerms("Harry's wands"), ['harry', 'wand']);
  });

  test('typed questions are read for what they ask', () {
    expect(Ask.parse('who is Celia?').kind, AskKind.who);
    expect(Ask.parse("Who's Mr. Casaubon").name, 'Mr. Casaubon');
    expect(Ask.parse('recap please').kind, AskKind.recap);
    expect(Ask.parse('Why does Dorothea admire him?').kind, AskKind.free);
  });

  test('the first question starts the conversation with the book; a follow-up sends only what is new', () async {
    final model = _Scripted([
      'Here is who she is: Celia is Dorothea’s younger sister.',
      'Because she thinks his work is noble.',
    ]);
    final conversation = Conversation(book: book, model: model);

    final first = await conversation.ask(Ask.who('Celia')).last;
    expect(first.answer, 'Celia is Dorothea’s younger sister.');
    expect(first.done, isTrue);
    final (opening, fresh) = model.prompts.first;
    expect(fresh, isTrue);
    expect(opening, contains('"Middlemarch" by George Eliot'));
    expect(opening, contains('They are in chapter 3'));
    expect(opening, contains('[1] Miss Brooke'));

    final second = await conversation.ask(Ask.parse('Why does Dorothea admire Casaubon?')).last;
    expect(second.answer, 'Because she thinks his work is noble.');
    final (followUp, carriedOn) = model.prompts.last;
    expect(carriedOn, isFalse);
    expect(followUp, isNot(contains('reading companion')));
    expect(followUp, contains('growing admiration'));
    // Already given in this conversation: not sent again.
    expect(followUp, isNot(contains('Miss Brooke had that kind of beauty')));
  });

  test('when the conversation is full, it starts over with the earlier turns in brief', () async {
    final model = _Scripted(['Celia is Dorothea’s sister.', 'He is a scholar.'], full: {1});
    final conversation = Conversation(book: book, model: model);
    await conversation.ask(Ask.who('Celia')).last;
    final turn = await conversation.ask(Ask.who('Casaubon')).last;

    expect(turn.answer, 'He is a scholar.');
    final (prompt, fresh) = model.prompts.last;
    expect(fresh, isTrue);
    expect(prompt, contains('reading companion'));
    expect(prompt, contains('They asked: Who is Celia?'));
  });

  test('a name that never comes up gets no model at all', () async {
    final model = _Scripted([]);
    final turn = await Conversation(book: book, model: model).ask(Ask.who('Lydgate')).last;
    expect(turn.error, contains('Lydgate'));
    expect(model.prompts, isEmpty);
  });

  test('a finished chapter with a summary is told by its summary', () {
    final summarised = BookSoFar(
      title: 'Middlemarch',
      paragraphs: [
        for (final c in [0, 1, 2]) (chapter: c, text: 'Chapter ${c + 1} has Dorothea and Celia talking at length about the Grange.'),
      ],
      summaries: const {0: 'Dorothea and Celia divide their mother’s jewels.'},
    );
    final story = summarised.storySoFar().map((c) => c.text).toList();
    expect(story, contains('Dorothea and Celia divide their mother’s jewels.'));
    expect(story.where((s) => s.startsWith('Chapter 1 ')), isEmpty);
  });

  test('a recap covers every chapter and ends where the reader is', () {
    final passages = Conversation(book: book, model: _Scripted([])).passagesFor(const Ask.recap(), 3000)
      ..sort(readingOrder);
    expect(passages.map((c) => c.chapter).toSet(), {1, 2, 3});
    expect(passages.last.text, contains('Celia guessed'));
  });

  test('files marked kept with none of their text (a build that could not read it) are kept again', () async {
    final dir = await Directory.systemTemp.createTemp('book');
    final text = File('${dir.path}/text.jsonl')
      ..writeAsStringSync('${jsonEncode({'c': 2, 'p': 0.4, 't': 'Alice was beginning to get very tired.'})}\n');
    final summaries = File('${dir.path}/section-summaries.json')..writeAsStringSync(jsonEncode({'0': '', '1': 'Alice falls.'}));
    final state = <String, Object?>{
      'upTo': {'2': 0.4, '3': 1.0, '4': 0.6},
      'complete': [3],
    };
    await repairKept(state, text, summaries);

    expect(state['upTo'], {'2': 0.4});
    expect(state['complete'], isEmpty);
    expect(jsonDecode(summaries.readAsStringSync()), {'1': 'Alice falls.'});
    await dir.delete(recursive: true);
  });

  test('the book so far names chapters as the reader sees them, and stops at the page', () async {
    final dir = await Directory.systemTemp.createTemp('book');
    File('${dir.path}/state.json').writeAsStringSync(jsonEncode({
      'chapters': [
        {'i': 2, 'n': 1, 't': 'CHAPTER I. Down the Rabbit-Hole'},
        {'i': 3, 'n': 2, 't': 'CHAPTER II. The Pool of Tears'},
        {'i': 4, 'n': 3, 't': 'CHAPTER III. A Caucus-Race and a Long Tale'},
      ],
    }));
    File('${dir.path}/text.jsonl').writeAsStringSync([
      // The Gutenberg header (reading-order 0) isn't a story chapter: left out.
      {'c': 0, 'p': 0.1, 't': 'The Project Gutenberg eBook of Alice in Wonderland.'},
      {'c': 2, 'p': 0.2, 't': 'Alice was beginning to get very tired of sitting by her sister on the bank.'},
      {'c': 3, 'p': 0.5, 't': 'Alice swam about in the pool of tears she had wept, with the Mouse beside her.'},
      {'c': 4, 'p': 0.3, 't': 'The Dodo proposed a Caucus-race, and everyone ran about until they were dry.'},
      // Kept from before the reader went back: past the page now.
      {'c': 4, 'p': 0.9, 't': 'The Mouse told its long and sad tale at last.'},
    ].map(jsonEncode).join('\n'));
    final data = await buildBookData(dir.path, (chapter: 4, progression: 0.5), 'Alice', null);

    expect(data.current?.number, 3);
    expect(data.book.chapter, 3);
    expect(data.book.titleOf(3), 'CHAPTER III. A Caucus-Race and a Long Tale');
    // Its own title names it, so that's all the model is told (the book's numbering, not ours).
    expect(data.book.instructions, contains('They are in "CHAPTER III. A Caucus-Race and a Long Tale"'));
    final text = data.book.index.chunks.map((c) => c.text).join(' ');
    expect(text, isNot(contains('Project Gutenberg')));
    expect(text, isNot(contains('long and sad tale')));
    expect(text, contains('Caucus-race'));
    await dir.delete(recursive: true);
  });

  // As many EPUBs have it (Calibre's, for one): every chapter in the contents is a link into its
  // file (#fragment), and a dedication the contents leave out comes before the first.
  PublicationInfo fragmentLinkedBook() {
    ChapterPositions file(int i, int count) => ChapterPositions(href: 'text/part$i.html', start: 1, count: count);
    return PublicationInfo(
      id: 'x',
      title: 'The Lighthouse Keeper',
      authors: const ['A. Writer'],
      language: 'en',
      isRightToLeft: false,
      toc: const [
        TocEntry(title: 'The Lighthouse Keeper', href: 'text/part0.html#a', children: []),
        TocEntry(title: 'Chapter 1 - The Storm', href: 'text/part2.html#b', children: []),
        TocEntry(title: 'Chapter 2 - The Wreck', href: 'text/part3.html#c', children: []),
        TocEntry(title: 'Copyright page', href: 'text/part4.html#d', children: []),
      ],
      chapters: [file(0, 1), file(1, 2), file(2, 9), file(3, 9), file(4, 1)],
    );
  }

  test('a dedication the contents leave out isn’t a chapter', () {
    final sections = storyChaptersOf(fragmentLinkedBook());
    expect(
      [for (final s in sections) if (s.isStory) (s.number, s.title)],
      [(1, 'Chapter 1 - The Storm'), (2, 'Chapter 2 - The Wreck')],
    );
  });

  test('the reader’s chapter is their page’s, with nothing of it kept yet', () async {
    final dir = await Directory.systemTemp.createTemp('book');
    File('${dir.path}/state.json').writeAsStringSync(jsonEncode({
      'chapters': [for (final c in storyChaptersOf(fragmentLinkedBook())) c.toJson()],
    }));
    File('${dir.path}/text.jsonl').writeAsStringSync([
      {'c': 1, 'p': 0.0, 't': 'For my mother, who kept the light.'},
      {'c': 2, 'p': 0.1, 't': 'The storm came in off the sea a little after dark.'},
    ].map(jsonEncode).join('\n'));
    final data = await buildBookData(dir.path, (chapter: 3, progression: 0.5), 'The Lighthouse Keeper', null);

    expect(data.current?.title, 'Chapter 2 - The Wreck');
    expect(data.current?.number, 2);
    await dir.delete(recursive: true);
  });

  test('suggested questions are only ones the book so far can answer, each once', () async {
    final model = _Scripted(
      ['Celia is Dorothea’s younger sister.'],
      aside: '| Question |\n|---|\n| Why does Dorothea admire Mr. Casaubon? |\n'
          '1. What did the dragon eat for breakfast?\n- Why does Dorothea admire Mr. Casaubon?\n'
          '* What is the Key to All Mythologies about?',
    );
    final conversation = Conversation(book: book, model: model);
    await conversation.ask(Ask.who('Celia')).last;
    final questions = await conversation.suggest(after: 'Celia is Dorothea’s younger sister.', people: const ['Celia']);

    expect(questions, ['Why does Dorothea admire Mr. Casaubon?', 'What is the Key to All Mythologies about?']);
    // Asked again, they're not suggested twice.
    expect(await conversation.suggest(after: '…', people: const []), isEmpty);
  });

  test('a question the book so far can’t answer gets no model, and says so', () async {
    final model = _Scripted([]);
    final turn = await Conversation(book: book, model: model).ask(Ask.parse('What did the dragon eat?')).last;
    expect(turn.error, 'The book so far doesn’t say.');
    expect(model.prompts, isEmpty);
  });
}
