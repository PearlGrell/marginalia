import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../readium/readium.dart';
import 'companion.dart';
import 'conversation.dart';
import 'gemma.dart';
import 'people.dart';

/// One of the book's story chapters: its place in the reading order, its number among the
/// story chapters (what the reader sees: "Ch 3 of 12") and its title.
class StoryChapter {
  const StoryChapter({required this.index, required this.number, required this.title});

  /// Reading-order index.
  final int index;

  /// 1-based, among story chapters only.
  final int number;
  final String title;

  Map<String, Object?> toJson() => {'i': index, 'n': number, 't': title};

  static StoryChapter fromJson(Map<String, Object?> json) =>
      StoryChapter(index: json['i']! as int, number: json['n']! as int, title: json['t']! as String);
}

/// Front and back matter: not part of the story, so never kept, summarised or searched.
final _notStory = RegExp(
  r'project gutenberg|table of contents|^contents$|copyright|licen[cs]e|title ?page|^cover$|dedication|colophon|about the (author|publisher)|also by',
  caseSensitive: false,
);

/// The book's story chapters, from its reading order and table of contents: items longer than a
/// page whose title doesn't say front or back matter, numbered as the reader sees them.
List<StoryChapter> storyChaptersOf(PublicationInfo publication) {
  final titles = <String, String>{};
  void walk(List<TocEntry> entries) {
    for (final e in entries) {
      titles.putIfAbsent(_path(e.href), () => e.title.trim());
      walk(e.children);
    }
  }

  walk(publication.toc);
  final out = <StoryChapter>[];
  for (final (index, chapter) in publication.chapters.indexed) {
    if (chapter.count <= 1) continue;
    final path = _path(chapter.href);
    final title = titles[path] ?? titles.entries.where((e) => e.key.endsWith(path) || path.endsWith(e.key)).firstOrNull?.value ?? '';
    if (title.isNotEmpty && _notStory.hasMatch(title)) continue;
    out.add(StoryChapter(index: index, number: out.length + 1, title: title));
  }
  return out;
}

String _path(String href) => href.split('#').first.replaceFirst(RegExp(r'^/+'), '');

/// Where the reader is: a reading-order index and how far through it.
typedef Place = ({int chapter, double progression});

/// What the companion keeps of a book, on the phone, as it's read: the text a page at a time
/// (`text.jsonl`, never the whole book at once), how far each chapter is kept (`state.json`) and
/// each finished chapter's summary (`summaries.json`). Chapters before the reader's page that
/// weren't paged through (a jump ahead) are filled in later, a chapter at a time.
class BookMemory {
  BookMemory(this.bookId);

  final String bookId;

  Future<Directory> _dir() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/companion/$bookId');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String name) async => File('${(await _dir()).path}/$name');

  Future<Map<String, Object?>> _state() async {
    final file = await _file('state.json');
    if (!await file.exists()) return {};
    try {
      return (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();
    } on FormatException {
      return {};
    }
  }

  Future<void> _saveState(Map<String, Object?> state) async => (await _file('state.json')).writeAsString(jsonEncode(state));

  Future<List<StoryChapter>> chapters() async => [
    for (final c in (await _state())['chapters'] as List? ?? const []) StoryChapter.fromJson((c as Map).cast()),
  ];

  /// How far each chapter's text is kept (its last paragraph's progression), and which are
  /// kept to the end.
  Future<({Map<int, double> upTo, Set<int> complete})> kept() async {
    final state = await _state();
    return (
      upTo: {
        for (final e in ((state['upTo'] as Map?) ?? const {}).entries) int.parse(e.key as String): (e.value as num).toDouble(),
      },
      complete: {for (final c in (state['complete'] as List?) ?? const []) c as int},
    );
  }

  Future<void> setChapters(List<StoryChapter> chapters) async {
    await _saveState((await _state())..['chapters'] = [for (final c in chapters) c.toJson()]);
    // Whole chapters kept by an earlier version: the page-by-page text replaces them.
    await for (final f in (await _dir()).list()) {
      if (f is File && RegExp(r'chapter-\d+\.json$').hasMatch(f.path)) await f.delete();
    }
  }

  Future<void> _append(List<({int chapter, double progression, String text})> paragraphs) async {
    if (paragraphs.isEmpty) return;
    final out = StringBuffer();
    for (final p in paragraphs) {
      out.writeln(jsonEncode({'c': p.chapter, 'p': p.progression, 't': p.text}));
    }
    await (await _file('text.jsonl')).writeAsString(out.toString(), mode: FileMode.append, flush: true);
  }

  /// Keeps chapter [chapter]'s text up to [progression] (all of it at 1), reading out of the
  /// book only what isn't kept yet. True when that finished the chapter.
  Future<bool> keep(Readium readium, String publicationId, int chapter, double progression) async {
    final state = await _state();
    final upTo = ((state['upTo'] as Map?) ?? {}).cast<String, Object?>();
    final complete = {for (final c in (state['complete'] as List?) ?? const []) c as int};
    if (complete.contains(chapter)) return false;
    final from = (upTo['$chapter'] as num?)?.toDouble() ?? -1;
    if (progression <= from) return false;
    final paragraphs = await readium.textRange(
      publicationId,
      fromChapter: chapter,
      afterProgression: from,
      toProgression: progression,
    );
    await _append(paragraphs);
    final reached = paragraphs.isEmpty ? progression : paragraphs.last.progression;
    upTo['$chapter'] = progression >= 1 ? 1.0 : (reached > from ? reached : from);
    final finished = progression >= 1;
    if (finished) complete.add(chapter);
    await _saveState(
      state
        ..['upTo'] = upTo
        ..['complete'] = complete.toList(),
    );
    return finished;
  }

  /// Summaries by reading-order index ('' for a chapter with nothing to tell).
  Future<Map<int, String>> summaries() async {
    final file = await _file('summaries.json');
    if (!await file.exists()) return {};
    return {
      for (final MapEntry(:key, :value) in (jsonDecode(await file.readAsString()) as Map).entries)
        int.parse(key as String): value as String,
    };
  }

  Future<void> keepSummary(int chapter, String summary) async {
    final all = await summaries()..[chapter] = summary;
    await (await _file('summaries.json')).writeAsString(jsonEncode({for (final e in all.entries) '${e.key}': e.value}));
  }

  /// Chapter [chapter]'s kept paragraphs, in order.
  Future<List<String>> chapterText(int chapter) async => [
    for (final p in await _paragraphs()) if (p.chapter == chapter) p.text,
  ];

  Future<List<({int chapter, double progression, String text})>> _paragraphs() async {
    final file = await _file('text.jsonl');
    if (!await file.exists()) return const [];
    return _parse(await file.readAsString());
  }

  /// Everything kept of the book, when it's removed from the library.
  Future<void> forget() async {
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// The book so far, at [place], built off the UI thread from what's kept: never anything past
  /// [place] (when the reader went back), and story chapters only, numbered as the reader sees
  /// them.
  Future<BookData> load({required Place place, required String title, String? authors}) async {
    final dir = (await _dir()).path;
    return Isolate.run(() => buildBookData(dir, place, title, authors));
  }
}

List<({int chapter, double progression, String text})> _parse(String jsonl) => [
  for (final line in const LineSplitter().convert(jsonl))
    if (line.isNotEmpty)
      if (jsonDecode(line) case {'c': final int c, 'p': final num p, 't': final String t}) (chapter: c, progression: p.toDouble(), text: t),
];

/// Everything the companion sheet shows, worked out at once (in an isolate).
class BookData {
  const BookData({
    required this.book,
    required this.people,
    required this.chapters,
    required this.current,
    required this.keySentences,
  });

  final BookSoFar book;
  final List<Person> people;

  /// The story chapters up to the reader's, with their numbers and titles.
  final List<StoryChapter> chapters;

  /// The chapter the reader is in, if it's a story chapter.
  final StoryChapter? current;

  /// A few of each chapter's own sentences (by number), for when it has no summary yet.
  final Map<int, List<String>> keySentences;
}

/// [BookData] from the files kept in [dir] (see [BookMemory.load]; public for tests).
Future<BookData> buildBookData(String dir, Place place, String title, String? authors) async {
  Future<String?> read(String name) async {
    final file = File('$dir/$name');
    return await file.exists() ? file.readAsString() : null;
  }

  final state = (jsonDecode(await read('state.json') ?? '{}') as Map).cast<String, Object?>();
  final chapters = [
    for (final c in (state['chapters'] as List?) ?? const []) StoryChapter.fromJson((c as Map).cast()),
  ];
  final byIndex = {for (final c in chapters) c.index: c};
  final summariesJson = (jsonDecode(await read('summaries.json') ?? '{}') as Map).cast<String, Object?>();

  // Never past the page: the reader may have gone back.
  bool before(int chapter, double progression) =>
      chapter < place.chapter || chapter == place.chapter && progression <= place.progression;
  final kept = [
    for (final p in _parse(await read('text.jsonl') ?? ''))
      if (byIndex.containsKey(p.chapter) && before(p.chapter, p.progression)) p,
  ]..sort((a, b) => a.chapter != b.chapter ? a.chapter.compareTo(b.chapter) : a.progression.compareTo(b.progression));

  // Story numbers from here on: chapter N is paragraph chapter N - 1.
  final paragraphs = [for (final p in kept) (chapter: byIndex[p.chapter]!.number - 1, text: p.text)];
  final current = byIndex[place.chapter];
  final upTo = [for (final c in chapters) if (c.index <= place.chapter) c];
  final book = BookSoFar(
    title: title,
    authors: authors,
    paragraphs: paragraphs,
    summaries: {
      for (final e in summariesJson.entries)
        if (byIndex[int.parse(e.key)] case final c? when c.index < place.chapter) c.number - 1: e.value! as String,
    },
    titles: {for (final c in upTo) c.number: c.title},
    chapterNow: current?.number,
  );
  return BookData(
    book: book,
    people: peopleIn(book.index),
    chapters: upTo,
    current: current,
    keySentences: {
      for (final c in upTo)
        if (c.index < place.chapter && !summariesJson.containsKey('${c.index}')) c.number: book.keySentences(c.number),
    },
  );
}

/// Keeps a book's text as it's read: a page at a time after each turn (a moment after, so
/// flicking through doesn't read anything), and the chapters before the page that weren't
/// paged through, one at a time in the background. Finished chapters get their summaries
/// (see [ChapterSummaries]).
class BookKeeper {
  BookKeeper({
    required this.bookId,
    required this.publication,
    required this.title,
    this.authors,
    required this.onChapterFinished,
  }) : memory = BookMemory(bookId);

  final String bookId;
  final PublicationInfo publication;
  final String title;
  final String? authors;
  final BookMemory memory;
  final void Function(int chapter) onChapterFinished;

  static const _readium = Readium();

  late final List<StoryChapter> _chapters = storyChaptersOf(publication);
  late final Set<int> _story = {for (final c in _chapters) c.index};
  Future<void>? _ready;
  Timer? _debounce;
  Place? _pending;
  Future<void> _work = Future.value();
  var _filling = false;
  final _tried = <int>{};
  var _closed = false;

  /// Where [location] is, as a reading-order index and progression.
  Place? placeOf(ReaderLocation location) {
    final chapter = publication.chapterFor(location.href);
    if (chapter == null) return null;
    return (chapter: publication.chapters.indexOf(chapter), progression: location.progression ?? 0);
  }

  Future<void> _start() => _ready ??= memory.setChapters(_chapters);

  /// The reader is at [location]: keep the page, a moment from now.
  void reached(ReaderLocation location) {
    final place = placeOf(location);
    if (place == null) return;
    _pending = place;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1200), flush);
  }

  /// Keeps what's waiting now (before the companion opens, so it has the page on screen).
  Future<void> flush() {
    _debounce?.cancel();
    final place = _pending;
    _pending = null;
    if (place == null) return _work;
    return _work = _work.then((_) => _keep(place)).catchError((_) {});
  }

  Future<void> _keep(Place place) async {
    if (_closed) return;
    await _start();
    if (!_story.contains(place.chapter)) return;
    // The chapter before, if the reader just turned out of it: kept to its end now.
    final previous = _chapters.where((c) => c.index < place.chapter).lastOrNull;
    if (previous != null) {
      final (:upTo, :complete) = await memory.kept();
      if (!complete.contains(previous.index) && upTo.containsKey(previous.index)) {
        if (await memory.keep(_readium, publication.id, previous.index, 1)) onChapterFinished(previous.index);
      }
    }
    await memory.keep(_readium, publication.id, place.chapter, place.progression);
    unawaited(_fillGaps(place.chapter));
  }

  /// Chapters before [chapter] not kept to their end (jumped over, or read before the app kept
  /// books): kept now, nearest first, one chapter a step with a pause between.
  Future<void> _fillGaps(int chapter) async {
    if (_filling) return;
    _filling = true;
    try {
      while (!_closed) {
        final (:upTo, :complete) = await memory.kept();
        final gap = _chapters.reversed
            .where((c) => c.index < chapter && !complete.contains(c.index) && !_tried.contains(c.index))
            .firstOrNull;
        if (gap == null) break;
        // Once each while the book is open: one that can't be read isn't tried over and over.
        _tried.add(gap.index);
        await (_work = _work.then((_) async {
          if (await memory.keep(_readium, publication.id, gap.index, 1)) onChapterFinished(gap.index);
        }).catchError((_) {}));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    } finally {
      _filling = false;
    }
  }

  void close() {
    _closed = true;
    _debounce?.cancel();
  }
}

/// Writes chapter summaries in the background, from the kept text: one at a time, newest first,
/// with whichever model the phone has (none: nothing). The reader keeps the text; nothing is
/// read out of the book here.
class ChapterSummaries extends Notifier<int> {
  /// Bumped each time a summary is written, for what shows them.
  @override
  int build() => 0;

  final _queue = <(String, String, String?)>[];
  Future<void>? _running;

  /// Summarises book [bookId]'s finished chapters that have no summary yet.
  void catchUp({required String bookId, required String title, String? authors}) {
    if (!_queue.any((q) => q.$1 == bookId)) _queue.add((bookId, title, authors));
    _running ??= _run().whenComplete(() => _running = null);
  }

  Future<void> _run() async {
    while (_queue.isNotEmpty) {
      final (bookId, title, authors) = _queue.removeAt(0);
      try {
        await _summarise(bookId, title, authors);
      } catch (_) {
        // Next time a chapter is finished.
      }
    }
  }

  Future<void> _summarise(String bookId, String title, String? authors) async {
    final nano = await const Nano().status() == NanoStatus.available;
    if (!nano && !ref.read(gemmaProvider).installed) return;
    final memory = BookMemory(bookId);
    final chapters = await memory.chapters();
    final (:upTo, :complete) = await memory.kept();
    final done = await memory.summaries();
    for (final chapter in chapters.reversed) {
      if (!complete.contains(chapter.index) || done.containsKey(chapter.index)) continue;
      final text = await memory.chapterText(chapter.index);
      if (text.fold(0, (n, p) => n + p.length) < 600) {
        await memory.keepSummary(chapter.index, '');
        continue;
      }
      final prompt = _prompt(title, authors, chapter, text);
      final summary = nano
          ? await const Nano().generate(prompt)
          : await ref.read(gemmaProvider.notifier).once(prompt, maxTokens: 90);
      if (summary == null || summary.trim().isEmpty) return;
      await memory.keepSummary(chapter.index, tidyAnswer(summary));
      state++;
    }
    if (!nano) await ref.read(gemmaProvider.notifier).releaseIfIdle();
  }

  static String _prompt(String title, String? authors, StoryChapter chapter, List<String> text) {
    final key = recapSentences([for (final p in text) (chapter: 0, text: p)], chapters: 1, count: 14);
    final passages = StringBuffer();
    for (final s in key) {
      if (passages.length + s.length > 2400) break;
      passages.writeln('- $s');
    }
    final name = chapter.title.isEmpty ? 'chapter ${chapter.number}' : 'chapter ${chapter.number}, "${chapter.title}"';
    return 'These are the key sentences, in order, of $name of "$title"'
        '${authors == null || authors.isEmpty ? '' : ' by $authors'}.\n\n$passages\n'
        'Summarise what happens in this chapter in two or three plain sentences: who is involved and what '
        'they do. Use only these sentences. No introduction, no lists.';
  }
}

final chapterSummariesProvider = NotifierProvider<ChapterSummaries, int>(ChapterSummaries.new);
