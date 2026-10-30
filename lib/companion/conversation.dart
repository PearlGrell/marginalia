import 'dart:async';
import 'dart:math' as math;

import 'companion.dart';
import 'retrieval.dart';

/// What the reader asked.
enum AskKind { recap, who, free }

class Ask {
  const Ask(this.kind, this.text, {this.name});

  /// "Recap so far": what has happened in the chapter the reader is in.
  const Ask.recap() : this(AskKind.recap, 'Recap the story so far');

  /// "Who is …".
  Ask.who(String name) : this(AskKind.who, 'Who is $name?', name: name);

  /// A question in words, read for what it asks: "who's Dobby?" is a who, "recap" a recap.
  factory Ask.parse(String typed) {
    final text = typed.trim();
    final who = RegExp(r"^(?:who(?:'s|’s| is| was)|tell me about)\s+(.+?)[?.!]*$", caseSensitive: false).firstMatch(text);
    if (who != null) return Ask(AskKind.who, text, name: who.group(1)!.trim());
    if (RegExp(r'^(recap|summari[sz]e|summary|what has happened|what.s happened)', caseSensitive: false).hasMatch(text)) {
      return Ask(AskKind.recap, text);
    }
    return Ask(AskKind.free, text);
  }

  final AskKind kind;

  /// The question as the reader sees it.
  final String text;
  final String? name;

  /// How long its answer may be, in tokens: a small model can run on for minutes otherwise.
  int get maxTokens => switch (kind) {
    AskKind.recap => 160,
    AskKind.who => 200,
    AskKind.free => 160,
  };
}

/// The model, writing an answer to a prompt: the text so far, as it comes.
abstract class CompanionModel {
  /// It keeps the conversation (a follow-up only needs what's new).
  bool get remembers;

  /// How much of the book goes into a prompt that starts a conversation, and into a follow-up.
  int get freshChars;
  int get followUpChars;

  /// The answer so far, each time more is written, at most [maxTokens] long. Fails with
  /// [ConversationFull] when a follow-up doesn't fit what it remembers; [fresh] starts the
  /// conversation over.
  Stream<String> write(String prompt, {required bool fresh, required int maxTokens});

  /// An answer to [prompt] on its own, outside the conversation (null if none came).
  Future<String?> once(String prompt, {required int maxTokens});

  /// Stops the answer being written.
  Future<void> cancel();
}

/// A follow-up didn't fit: the conversation starts over.
class ConversationFull implements Exception {
  const ConversationFull();
}

/// The model couldn't answer.
class ModelFailed implements Exception {
  const ModelFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

class Turn {
  Turn(this.ask);

  final Ask ask;
  String answer = '';
  String? error;
  bool done = false;

  /// What the book says that bears on it: shown instead of an answer when there's no model.
  List<Chunk> passages = const [];
}

/// The book up to the reader's page, and what the model is told about it. Made once when the
/// companion opens on a book, so every question is scoped to that book and that page. Chapters
/// are story chapters, numbered as the reader sees them (front and back matter left out).
class BookSoFar {
  BookSoFar({
    required this.title,
    this.authors,
    required List<Paragraph> paragraphs,
    this.summaries = const {},
    this.titles = const {},
    this.chapterNow,
  }) : _paragraphs = paragraphs,
       index = BookIndex(paragraphs);

  final String title;
  final String? authors;

  /// Summaries of the chapters finished, by chapter number - 1 ('' for nothing to tell).
  final Map<int, String> summaries;

  /// Chapter titles by number, from the book's contents.
  final Map<int, String> titles;

  /// The chapter the reader is in, when known (else the last one with text).
  final int? chapterNow;
  final List<Paragraph> _paragraphs;
  final BookIndex index;

  bool get isEmpty => index.isEmpty;

  /// The chapter the reader is in (1-based, as the reader sees it).
  int get chapter => chapterNow ?? (_paragraphs.isEmpty ? 0 : _paragraphs.last.chapter + 1);

  /// "chapter 3, "A Caucus-Race and a Long Tale"", for prompts.
  String chapterName(int number) => chapterLabel(number, titleOf(number));

  /// What the model is told before a conversation about this book.
  String get instructions =>
      'You are the reading companion in an e-reader, talking with someone who is reading "$title"'
      '${authors == null || authors!.isEmpty ? '' : ' by $authors'}. They are in ${chapterName(chapter)}. '
      'All you know about the book is in the passages you are given (chapter number in brackets), which '
      'stop at their page: never mention or hint at anything that happens later, and do not use anything '
      'you may know about this book, its sequels or films from elsewhere. Talk only about this book. '
      'Write warm, plain prose to the reader, with no introduction such as "Here is" or "Sure", and no '
      'mention of passages or these instructions.';

  /// The story so far: each finished chapter by its summary (or a few of its sentences), more
  /// of the chapter the reader is in.
  List<Chunk> storySoFar({int recentChapters = 2}) {
    final out = <Chunk>[];
    for (final MapEntry(key: number, value: paragraphs) in _byChapter.entries) {
      final summary = summaries[number - 1];
      // Before the chapter's passages in reading order (see [readingOrder]).
      if (summary != null && number < chapter) {
        if (summary.isNotEmpty) out.add(Chunk(index: -1000, chapter: number, text: summary));
        continue;
      }
      final recent = number > chapter - recentChapters;
      for (final (i, s) in recapSentences(paragraphs, chapters: 1, count: recent ? 6 : 2).indexed) {
        out.add(Chunk(index: i - 1000, chapter: number, text: s));
      }
    }
    return out;
  }

  /// The paragraphs of each chapter (1-based), in order.
  late final Map<int, List<Paragraph>> _byChapter = () {
    final out = <int, List<Paragraph>>{};
    for (final p in _paragraphs) {
      (out[p.chapter + 1] ??= []).add(p);
    }
    return out;
  }();

  /// The chapters with text so far (1-based), in order.
  Iterable<int> get chapters => _byChapter.keys;

  /// Chapter [number]'s title: from the contents, else its first line when that reads like one.
  String? titleOf(int number) {
    final title = titles[number];
    if (title != null && title.trim().isNotEmpty) return title.trim();
    return chapterTitle([for (final p in _byChapter[number] ?? const <Paragraph>[]) p.text]);
  }

  /// A few of chapter [number]'s own sentences, when it has no summary.
  List<String> keySentences(int number, {int count = 3}) =>
      recapSentences(_byChapter[number] ?? const [], chapters: 1, count: count);
}

/// Chapter [number] for a prompt: 'chapter 3, "A Caucus-Race and a Long Tale"', or its title
/// alone when that already names it ('"CHAPTER 1. Loomings."': the book's own numbering, which
/// front matter and parts can make differ from ours).
String chapterLabel(int number, String? title) {
  if (title == null || title.trim().isEmpty) return 'chapter $number';
  final t = title.trim();
  if (RegExp(r'^(chapter|letter|book|part|stave|canto|section)\b', caseSensitive: false).hasMatch(t)) return '"$t"';
  return 'chapter $number, "$t"';
}

/// A chapter's title: its first line, when that reads like one ("CHAPTER III. A Caucus-Race").
String? chapterTitle(List<String> paragraphs) {
  final first = paragraphs.firstOrNull?.trim();
  if (first == null || first.length > 90 || RegExp(r'[.!?]["”’]?$').hasMatch(first) && first.length > 40) return null;
  return first;
}

/// Passages in the order they come in the book.
int readingOrder(Chunk a, Chunk b) {
  final byChapter = a.chapter.compareTo(b.chapter);
  return byChapter != 0 ? byChapter : a.index.compareTo(b.index);
}

/// Questions out of a model's reply, however it laid them out (a line each, a list, numbered,
/// or a table): each cut at its question mark, cleaned of markup.
List<String> parseQuestions(String reply) {
  final out = <String>[];
  for (final piece in reply.split(RegExp(r'\n|\|'))) {
    var q = piece.replaceAll(RegExp(r'[*_`#>]'), '').replaceFirst(RegExp(r'^[\s\-–—•\d.):]+'), '').trim();
    final mark = q.indexOf('?');
    if (mark < 0) continue;
    q = q.substring(0, mark + 1).trim();
    if (RegExp(r'^-+$').hasMatch(q) || q.toLowerCase().startsWith('question')) continue;
    out.add(q);
  }
  return out;
}

/// A conversation about the book: each question gets the passages that bear on it, found in
/// the whole book up to the reader's page (retrieval, not the model looking), then the model
/// answers in its words. Follow-ups carry on the same conversation, with only what's new.
class Conversation {
  Conversation({required this.book, required this.model});

  final BookSoFar book;
  final CompanionModel model;
  final turns = <Turn>[];

  /// Passages the model has already been given in this conversation.
  final _given = <String>{};
  var _started = false;

  /// Questions already suggested or asked, so none comes twice.
  final _suggested = <String>{};

  /// The passages for [ask], most telling first, within [budget] characters.
  List<Chunk> passagesFor(Ask ask, int budget) {
    final List<Chunk> ranked;
    switch (ask.kind) {
      case AskKind.recap:
        // Where things stand, then the story back through the chapters (their summaries).
        ranked = [...book.index.latest(3), ...book.storySoFar().reversed];
      case AskKind.who:
        final named = book.index.mentioning(ask.name!);
        ranked = [
          ...named.take(2), // how they come in
          ...named.skip(math.max(2, named.length - 3)), // where they are now
          ...book.index.search(ask.name!, limit: 6),
        ];
      case AskKind.free:
        ranked = book.index.search(_query(ask), limit: 10);
    }
    final kept = <Chunk>[];
    final seen = <String>{};
    var length = 0;
    for (final c in ranked) {
      if (!seen.add(c.text) || length + c.text.length + 8 > budget) continue;
      kept.add(c);
      length += c.text.length + 8;
    }
    return kept;
  }

  /// What a free question searches by; a follow-up ("why did she leave?") also by who and what
  /// the last turn was about.
  String _query(Ask ask) {
    if (turns.length < 2) return ask.text;
    final last = turns[turns.length - 2];
    final names = RegExp(r"\b[A-Z][\p{L}'’]+", unicode: true)
        .allMatches('${last.ask.text} ${last.answer}')
        .map((m) => m[0]!)
        .where((w) => !const {'The', 'He', 'She', 'They', 'It', 'In', 'When', 'Then', 'But', 'And', 'A'}.contains(w))
        .toSet()
        .take(4);
    return '${ask.text} ${names.join(' ')}';
  }

  /// Asks [ask]: the answer so far, as it's written. The turn is in [turns] from the start.
  Stream<Turn> ask(Ask ask) async* {
    final turn = Turn(ask);
    turns.add(turn);
    _suggested.add(_key(ask.text));
    final fresh = !_started || !model.remembers;
    var passages = passagesFor(ask, fresh ? model.freshChars : model.followUpChars);
    turn.passages = [...passages]..sort(readingOrder);
    final unanswerable = switch (ask.kind) {
      AskKind.who when passages.isEmpty => '“${ask.name}” doesn’t come up in the book up to here.',
      AskKind.recap when passages.isEmpty => 'There’s not enough read yet for a recap.',
      // Nothing in the book so far to answer from: said, rather than made up.
      AskKind.free when passages.isEmpty || !book.index.knows(ask.text) => 'The book so far doesn’t say.',
      _ => null,
    };
    if (unanswerable != null) {
      turn
        ..error = unanswerable
        ..done = true;
      yield turn;
      return;
    }
    yield turn;
    try {
      try {
        await for (final text in model.write(prompt(ask, passages, fresh: fresh), fresh: fresh, maxTokens: ask.maxTokens)) {
          turn.answer = _clean(text);
          yield turn;
        }
      } on ConversationFull {
        // No room left to carry on: start over, with the conversation so far in brief.
        _given.clear();
        passages = passagesFor(ask, model.freshChars);
        await for (final text in model.write(prompt(ask, passages, fresh: true), fresh: true, maxTokens: ask.maxTokens)) {
          turn.answer = _clean(text);
          yield turn;
        }
      }
      _started = true;
      turn.answer = tidyAnswer(turn.answer);
    } on ModelFailed catch (e) {
      turn.error = e.message;
    }
    turn.done = true;
    yield turn;
  }

  /// One question's prompt. A fresh one has the book's instructions and the conversation so
  /// far, in brief; a follow-up only what the model hasn't seen yet.
  String prompt(Ask ask, List<Chunk> passages, {required bool fresh}) {
    if (fresh) _given.clear();
    final unseen = [
      for (final c in [...passages]..sort(readingOrder))
        if (_given.add(c.text)) c,
    ];
    final guide = switch (ask.kind) {
      AskKind.recap =>
        'In two to four sentences, say what has happened so far in ${this.book.chapterName(this.book.chapter)}, '
            'picking up from the chapters before, and where things stand at the reader\'s page.',
      AskKind.who =>
        'Say who ${ask.name} is in three to five sentences: who they are, what they have done so far, and how '
            'they relate to the other characters.',
      AskKind.free =>
        'Answer the question directly in your first sentence, then say in one or two sentences what in the '
            'book shows it. If the book so far does not say, tell the reader so.',
    };
    final book = unseen.isEmpty ? '' : [for (final c in unseen) '[${c.chapter}] ${c.text}'].join('\n');
    final earlier = [
      for (final t in turns)
        if (t.ask != ask && t.answer.isNotEmpty) 'They asked: ${t.ask.text}\nYou said: ${_brief(t.answer)}',
    ];
    if (fresh) {
      return [
        this.book.instructions,
        if (book.isNotEmpty) 'From the book, up to the reader\'s page (chapter number in brackets):\n$book',
        if (earlier.isNotEmpty) 'Earlier in this conversation:\n${earlier.skip(math.max(0, earlier.length - 2)).join('\n')}',
        'The reader asks: ${ask.text}\n$guide',
      ].join('\n\n');
    }
    return [
      if (book.isNotEmpty) 'More from the book (chapter number in brackets):\n$book',
      'The reader asks: ${ask.text}\n$guide',
    ].join('\n\n');
  }

  /// Up to three questions a curious reader might have now, after [after] (the recap, or an
  /// answer): about the chapter they're in, naming who or what they're about, each one
  /// answerable from the book so far (checked against it) and none asked or suggested before.
  /// [people] are who's in this chapter, new ones marked.
  Future<List<String>> suggest({required String after, required List<String> people}) async {
    final key = book.keySentences(book.chapter, count: 8);
    final prompt = [
      'These are key sentences from ${book.chapterName(book.chapter)} of "${book.title}", up to where '
          'someone has read:\n${[for (final s in key) '- $s'].join('\n')}',
      if (people.isNotEmpty) 'Who is in it: ${people.join(', ')}.',
      'What they were just told:\n$after',
      'Write three short questions a curious reader might have at this point about what has happened: why '
          'someone did something, how two characters are connected, or what something means. Each must name '
          'who or what it is about, and be answerable from what they have read (not about what happens next). '
          'One question per line, nothing else. For example:\nWhy did the Mouse get offended?\nHow did Alice '
          'end up in the pool of tears?',
    ].join('\n\n');
    final reply = await model.once(prompt, maxTokens: 60);
    if (reply == null) return const [];
    return [
      for (final q in parseQuestions(reply))
        if (_worthAsking(q)) q,
    ].take(3).toList();
  }

  /// A question to show: a sensible length, about something the book so far has, and new.
  bool _worthAsking(String question) {
    final words = question.split(RegExp(r'\s+')).length;
    if (words < 4 || words > 16) return false;
    if (!book.index.knows(question)) return false;
    return _suggested.add(_key(question));
  }

  static String _key(String question) => question.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

  static String _brief(String answer) => answer.length <= 320 ? answer : '${answer.substring(0, 320)}…';

  /// Text being written, without a lead-in ("Here's a recap:") even while it comes.
  static String _clean(String text) =>
      text.trimLeft().replaceFirst(RegExp(r"^(here(?:'|’)?s|here is|sure|okay|ok)\b[^:\n]{0,80}:\s*", caseSensitive: false), '');
}

/// Gemini Nano as the companion's model: it reads a lot at once, but doesn't keep the
/// conversation (each question carries what came before, in brief).
class NanoModel implements CompanionModel {
  const NanoModel();

  static const _nano = Nano();

  @override
  bool get remembers => false;

  @override
  int get freshChars => 9000;

  @override
  int get followUpChars => 9000;

  @override
  Stream<String> write(String prompt, {required bool fresh, required int maxTokens}) async* {
    final text = await _nano.generate(prompt);
    if (text == null) throw const ModelFailed('Gemini Nano gave no answer.');
    yield text;
  }

  @override
  Future<String?> once(String prompt, {required int maxTokens}) => _nano.generate(prompt);

  @override
  Future<void> cancel() async {}
}
